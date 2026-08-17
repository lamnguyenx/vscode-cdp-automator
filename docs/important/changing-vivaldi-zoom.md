# Changing Vivaldi Zoom (UI + Site) Programmatically

Tested on **Vivaldi 8.1.4087.64** (macOS, Chromium 150) with the browser launched
with `--remote-debugging-port=9222`.

## Problem

Vivaldi has no external API to set its UI zoom or the page zoom of its tabs.
But — like the tab bar (`docs/important/changing-vivaldi-vertical-tab-bar-size.md`) —
the whole browser chrome is an internal extension reachable over CDP, and it exposes
a dedicated zoom module: **`window.vivaldi.zoom`**.

## Key discovery: `window.vivaldi.zoom`

Attach a WebSocket client to the `window.html` chrome target (see
`docs/important/changing-vivaldi-vertical-tab-bar-size.md` for how to find it) and run
`Runtime.evaluate`. The module exposes exactly what we need:

```js
Object.keys(window.vivaldi.zoom)
// ["getDefaultZoom", "getVivaldiUIZoom", "onDefaultZoomChanged",
//  "onUIZoomChanged", "setDefaultZoom", "setVivaldiUIZoom"]
```

There are three independent zoom levels:

| Level | Get | Set | Scope |
|-------|-----|-----|-------|
| **UI zoom** | `getVivaldiUIZoom()` | `setVivaldiUIZoom(factor)` | Entire browser chrome (tab bar, toolbar, etc.), persisted |
| **Default site zoom** | `getDefaultZoom()` | `setDefaultZoom(factor)` | Zoom applied to pages, persisted |
| **Per-tab zoom** | `chrome.tabs.getZoom(tabId)` | `chrome.tabs.setZoom(tabId, factor)` | One open tab, applied live |

`chrome.tabs` (query / getZoom / setZoom) is available in the `window.html` context, so
no separate attachment is needed. Enumerate tabs with `chrome.tabs.query({})`.

## API usage

The zoom module methods are callback-based. Wrap them in a `Promise` and pass
`awaitPromise: true` to `Runtime.evaluate`:

```js
// read
new Promise(r => window.vivaldi.zoom.getVivaldiUIZoom(x => r(JSON.stringify(x))))   // → 1.6
new Promise(r => window.vivaldi.zoom.getDefaultZoom(x => r(JSON.stringify(x))))      // → 1.6

// write
window.vivaldi.zoom.setVivaldiUIZoom(1.2, () => {})
window.vivaldi.zoom.setDefaultZoom(1.25, () => {})

// per-tab
new Promise(r => chrome.tabs.query({}, t => r(JSON.stringify(t.map(x => x.id)))))
new Promise(r => chrome.tabs.setZoom(tabId, 1.6, () => r('ok')))
new Promise(r => chrome.tabs.getZoom(tabId, f => r(JSON.stringify(f))))
```

In the Swift tool the `evalJS` helper sends `awaitPromise: true`, so these expressions
work directly.

## Verification & tolerance

`getVivaldiUIZoom` can return floating-point artifacts (`1.6000000000000005`), so verify
with a small tolerance instead of exact equality:

```js
Math.abs(after - factor) < 0.01
```

`setZoom` / `setDefaultZoom` / `setVivaldiUIZoom` all apply immediately and can be
confirmed by an immediate read-back.

## Set-all-tabs-to-default

```js
const def = await getDefaultZoom();
const tabs = await chrome.tabs.query({});
for (const t of tabs) await chrome.tabs.setZoom(t.id, def);
```

Verified end-to-end on 5 open tabs: perturbing the active tab to 2.0, then applying the
default zoom, read back all tabs at the target factor.

## Persistence

- **UI zoom** and **default zoom** are persisted by Vivaldi automatically when set
  through the module. No manual pref write needed.
- On disk, the default page zoom is Chromium's `partition.default_zoom_level` in
  `~/Library/Application Support/Vivaldi/Default/Preferences`. It is stored as a
  **zoom level** (log scale): `level = log(factor) / log(1.2)`. E.g. `1.6` →
  `≈ 2.5779`. Like the tab-bar width, the on-disk file is written lazily and can be
  stale — treat `getDefaultZoom()` as authoritative.
- UI zoom and default zoom are **not coupled**: setting the UI zoom does not change the
  default page zoom, and vice versa (verified).

## Tool integration

The zoom save/restore is built into `vscode-ui-resizer/vscode-ui-resizer.swift`:

```bash
./vscode-ui-resizer.exe save-vivaldi-zoom [port]     # UI zoom + default zoom → config
./vscode-ui-resizer.exe restore-vivaldi-zoom [port]  # restore both, then apply default to all tabs
```

`save-all` / `restore-all` include these steps automatically. Values are stored per
display fingerprint in `~/.config/vscode-cdp-automator/config.json` under
`vivaldi.uiZoom` / `vivaldi.defaultZoom`.

## Gotchas

- **`Runtime.evaluate` must await the promise** (`awaitPromise: true`), or the callback
  result never arrives and you get `null`.
- **Factor, not percent.** All APIs take/return scale factors (`1.6`), not `160`.
- **Set callbacks may pass `undefined`** — ignore the return value of the setters and
  verify via read-back instead.
- **Per-tab zoom applies to all tabs, including internal `chrome-extension://` tabs.**
  `chrome.tabs.setZoom` succeeds on Vivaldi's settings tab too.

## Related

- `docs/important/changing-vivaldi-vertical-tab-bar-size.md` — finding & attaching to the
  `window.html` chrome target
- `docs/important/vivaldi-general-quirks.md` — Vivaldi's CDP/live-prefs quirks