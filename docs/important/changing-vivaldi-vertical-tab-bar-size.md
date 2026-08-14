# Changing Vivaldi's Vertical Tab Bar Size (Live, via CDP)

Tested on **Vivaldi 8.1.4087.64** (macOS, Chromium 150) with the browser launched with
`--remote-debugging-port=9222`.

## Problem

There is **no** supported API to set Vivaldi's tab-bar width. Worse, the two
"obvious" shortcuts both silently fail:

1. Writing the pref `vivaldi.tabs.bar.width` via `vivaldi.prefs.set(...)` **does update
   the stored value** but **does not re-render** the tab bar. The rendered width is
   driven by a React component's `state.tabBarWidth`, which is only initialized from the
   pref at mount and only mutated by the resize drag handler.
2. Dispatching synthetic `PointerEvent`s with `el.dispatchEvent(...)` **fails** because
   the resize handler calls `setPointerCapture(pointerId)` on `pointerdown`, and the
   browser throws on untrusted (synthetic) events with no real pointer.

The only reliable way to resize live is to **simulate a real drag on the resize handle
using CDP `Input.dispatchMouseEvent`**, which produces *trusted* input events.

## Key discovery: Vivaldi's chrome is a CDP target

Unlike stock Chrome, Vivaldi implements its entire browser chrome (tab bar, address bar,
etc.) as an internal extension whose UI is reachable over CDP. On a running instance:

```bash
curl -s http://127.0.0.1:9222/json/list | python3 -m json.tool
```

Look for `"type": "app"` entries:

| Target | URL | Purpose |
|--------|-----|---------|
| `window.html` | `chrome-extension://mpognobbkildjkofajifpdfhcoklimli/window.html` | The window chrome — tab bar, address bar, webview container |
| `main.html` | `chrome-extension://mpognobbkildjkofajifpdfhcoklimli/main.html` | Shared UI |

The extension id `mpognobbkildjkofajifpdfhcoklimli` is Vivaldi's internal UI extension
and is stable across Vivaldi releases (it is the same for everyone).

Grab the `webSocketDebuggerUrl` for `window.html` and attach a WebSocket client to it.
`Runtime.evaluate` from here runs in the chrome UI's renderer, so you can read/write the
tab-bar DOM directly.

### Inspecting the chrome state

Useful things reachable only from the `window.html` context:

- `document.querySelector('#browser').className` — carries `tabs-left` / `tabs-right` /
  `tabs-top` / `tabs-bottom` (the **live** tab-bar position; the on-disk `Preferences`
  can be stale).
- `window.vivaldi.prefs.get('vivaldi.tabs.bar.width', cb)` — the **live** pref value
  (returns `{ value, store, defaultValue }`).
- `window.vivaldi.prefs.set({ path: 'vivaldi.tabs.bar.width', value: 320 })` — writes the
  pref, but (see above) does **not** resize the UI.

## DOM structure of the vertical tab bar

With the tab bar on the left (`#browser` has class `tabs-left`):

```
#tabs-tabbar-container.left            (inline style width: Npx; height: stretch)
└── #tabs-container.left
    ├── .tab-strip                     (the actual tab list)
    │   └── .tab-position > .tab-wrapper ...
    ├── .toolbar.toolbar-tabbar-after  (new-tab button, flexible spacer)
    └── ...
#webview-container                     (x == tab-bar width; the page content)
```

The resize handle is a `button.SlideBar.SlideBar--FullHeight` (≈7px wide, full height)
sitting on the tab bar's right edge. Dragging it resizes the panel.

## The resize mechanism (from Vivaldi's bundle)

The `SlideBar` component binds these handlers (native listeners, capture phase):

- `pointerdown` → `handlePointerDown`: `setPointerCapture(pointerId)`, adds a
  `pointermove` listener, calls `onStart()`.
- `pointermove` → `handlePointerMove`: if `!e.buttons` → stop; else
  `t = e.pageX + offset`, then `onSlidebarPosition(t, ...)` (throttled, via rAF).
- `pointerup` → `handleStop`: `releasePointerCapture`, removes the move listener, calls
  `onStop()`.

The tab-bar component's position handler for a left/right bar is:

```js
case "left":  this.setTabBarWidth(Math.min(e - s.left, MAX), /*writePref=*/false); break;
case "right": this.setTabBarWidth(Math.min(s.right - e, MAX), /*writePref=*/false); break;
```

where `e = pageX + offset` and `s = #tabs-tabbar-container.getBoundingClientRect()`.
For a left bar `s.left === 0`, so the new width is simply `pageX + offset`. The actual
render uses `getWidth() = clamp(state.tabBarWidth, minSize, 680)`.

The `SlideBar` is rendered with `offset: 1`, therefore:

> **New width = `pageX + 1`** (left layout)

`onStop()` (`handleSliderUp`) persists the result by writing
`vivaldi.tabs.bar.width = Math.round(state.tabBarWidth)`.

## Why `Input.dispatchMouseEvent` and not synthetic events

`synthetic dispatchEvent(new PointerEvent(...))` breaks at `setPointerCapture` because
there is no real active pointer — the call throws and the rest of `handlePointerDown`
never runs. CDP's `Input.dispatchMouseEvent` injects *trusted* input at the browser
level, so pointer capture works and the move listener receives the drag.

## Working script

Attach to the `window.html` WebSocket URL and send a press → move → release sequence:

```js
// resize-vivaldi-tabbar.mjs  (Node >= 22, uses the global WebSocket)
const url = process.argv[2];          // ws://127.0.0.1:9222/devtools/page/<ID>
const endX = parseFloat(process.argv[3]);  // target width - 1  (see formula)

const ws = new WebSocket(url);
let id = 0;
const pending = new Map();
const send = (method, params) => new Promise((res, rej) => {
  const i = ++id;
  pending.set(i, { res, rej });
  ws.send(JSON.stringify({ id: i, method, params }));
});
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) {
    const p = pending.get(m.id); pending.delete(m.id);
    m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result);
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

ws.onopen = async () => {
  try {
    // 1. locate the resize handle and compute a grab point
    const { result } = await send('Runtime.evaluate', {
      expression: `(() => { const b = document.querySelector('.SlideBar');
        const r = b.getBoundingClientRect();
        return { x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width }; })()`,
      returnByValue: true,
    });
    const { x: startX, y } = result.value;

    // 2. trusted drag
    await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: startX, y, button: 'none', buttons: 0 });
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: startX, y, button: 'left', buttons: 1, clickCount: 1 });
    const steps = 12;
    for (let i = 1; i <= steps; i++) {
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: startX + (endX - startX) * (i / steps), y, button: 'left', buttons: 1 });
      await sleep(15);
    }
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: endX, y, button: 'left', buttons: 0, clickCount: 1 });
    await sleep(200);

    const check = await send('Runtime.evaluate', {
      expression: `Math.round(document.querySelector('#tabs-tabbar-container').getBoundingClientRect().width)`,
      returnByValue: true,
    });
    console.log('tab bar width =', check.result.value);
    ws.close();
  } catch (e) { console.error(e.message); ws.close(); }
};
```

Usage:

```bash
node resize-vivaldi-tabbar.mjs "$WS_URL" 370   # widen to ~371px
node resize-vivaldi-tabbar.mjs "$WS_URL" 247   # shrink back to ~248px
```

`$WS_URL` is the `webSocketDebuggerUrl` from `/json/list` for the `window.html` target.

## Width formula & limits

- Left/right bar: **width = `pageX + 1`**. To target a width `W`, drop the pointer at
  `x = W - 1`.
- `getWidth()` clamps the result to `[getMinimumTabSize() * (substrip ? 2 : 1) +
  overflow, 680]`. With two-level (substrip) tabs the minimum is doubled; the maximum is
  hard-capped at **680px**.
- The persisted pref is `Math.round(state.tabBarWidth)`, so the stored value can differ
  by ±1px from the rendered pixel width.

## Pref reference (from `prefs_definitions.json`)

Vivaldi ships its pref schema at
`/Applications/Vivaldi.app/Contents/Frameworks/Vivaldi Framework.framework/Versions/<ver>/Resources/vivaldi/prefs_definitions.json`.

| Pref | Type | Meaning |
|------|------|---------|
| `vivaldi.tabs.bar.position` | enum | `top=0, left=1, right=2, bottom=3` |
| `vivaldi.tabs.bar.width` | integer | Vertical tab-bar width (default `360`) |
| `vivaldi.tabs.bar.height` | integer | Horizontal tab-bar height (default `30`) |
| `vivaldi.tabs.bar.slider_xpos` | integer | Vertical substrip split position (default `90`) |
| `vivaldi.tabs.bar.slider_ypos` | integer | Horizontal substrip split position (default `30`) |

## Gotchas

- **On-disk `Preferences` is stale.** `~/Library/Application Support/Vivaldi/Default/Preferences`
  is written lazily; the live value (via `vivaldi.prefs.get` in the `window.html` context)
  is authoritative. During our session the file said `position: 0` (`top`) while the live
  value was `left`.
- **`vivaldi.prefs.set` on `width` does not resize.** It changes the stored pref only;
  the UI is state-driven. Use the drag (or a chrome reload) to make it take effect.
- **Substrip changes the geometry.** With `tabs-stacking-mode = substrip` active, the
  effective minimum width is doubled, and `slider_xpos`/`slider_ypos` control the inner
  split between the two levels.
- **The tab bar must be visible** (`vivaldi.tabs.visible`) and positioned left/right for
  `.SlideBar--FullHeight` to exist; a top/bottom bar uses `.SlideBar--FullWidth` and the
  `top`/`bottom` branches of `onSlidebarPosition` (which set height instead of width).

## Related

- VS Code sash-drag technique (same trusted-event idea, but VS Code uses plain
  `MouseEvent` on `window`, not pointer capture):
  `docs/lessons/2026-06-22-cdp-sash-drag.md`
