# Vivaldi In-Page Refresh Button + Theme-Colored Group Separator

Date: 2026-09-03
Tool: `tools/vivaldi-title-split.mjs`
Vivaldi 8.1.x / Chromium 150 / `--remote-debugging-port=9023` / `window.html` (`mpognobbkildjkofajifpdfhcoklimli`)
Companion docs: `docs/important/how-to-test-vivaldi-side-tab-bar.md`, `docs/important/vivaldi/how-to-record-tab-dragging-video.md`, `docs/plans/2026/09/02/2026-09-02-non-destructive-title-rendering.md`

## TL;DR

Changes landed in `tools/vivaldi-title-split.mjs`:

1. **Group separator simplified**: the 40px vertical gap between tab groups (`GAP = 40`) is gone — `GAP = 0`. Group boundaries are now a single **2px line colored with the active theme** (`var(--colorAccentBg)`), verified by VLM against the live screenshot. This collapsed the tab strip from 315px to 195px for a 5-tab session.
2. **In-page refresh button (↻)**: `on` now injects a small button into `window.html`. Clicking it re-runs `applyTabSplit()` **directly in the page** — no shelling out, no second CDP round-trip.
3. **Draggable + edge-snapping**: the button can be dragged anywhere (iPhone-AssistiveTouch style) and snaps to the nearest viewport edge on release, clamped so it never goes off-screen.
4. **Position persisted on disk**: per-CDP-port XDG config file; default placement (no config yet) is left-aligned + vertically centered.

The "dynamically fetched CDP" from the original request ended up being even simpler: the CDP session is only needed to **inject** the button once; after that the button is fully self-contained in-page.

## 1. Group separator: 40px gap → 2px theme line

### Before

```js
const GAP = 40;   // vertical offset inserted at every group boundary
```

The `--PositionY` arithmetic accumulated `offset += GAP` per group change, and `.tab-group-end` drew a `1px solid rgba(255,255,255,0.45)` border. Visually: 40px of dead space between groups.

### After

```js
const GAP = 0;
```

```css
.tab-strip .tab-position.tab-group-end { border-bottom: 2px solid var(--colorAccentBg, #aaa); }
```

- `offset` no longer grows, so rows pack at the uniform `NEW_H = 38` pitch.
- The separator is the border itself — 2px, theme accent.
- The `resize { max-height }` formula `n * (NEW_H+1) + totalGaps * GAP` still works; `totalGaps * 0` vanishes.

### VLM verification

Before: VLM reported `~56565B 1px` lines and couldn't distinguish separators from the active-tab glow. After: probed the computed style directly to confirm `2px solid rgb(122, 160, 255)` (= `#7aa0ff` = `var(--colorHighlightBg)`), then switched to `--colorAccentBg` (`#cfcfcf`) per user preference. Final VLM pass confirmed three clean 2px lines, no gaps.

## 2. Theme color discovery (how we found the right vars)

Vivaldi's theme custom properties are **not** on `:root` — they're set on `#browser` (and inherited down). Probing `getComputedStyle(document.documentElement)` returns empty strings. The working recipe:

1. Scan `document.styleSheets` for any `--*` var matching `/accent|highlight|color/i` → gives the *aliases* (e.g. `--colorTabBar: var(--colorAccentBg)`).
2. Resolve actual values by reading `getComputedStyle(document.querySelector('#browser'))` for each var name.

Notable resolved theme colors on this install:

| Var | Resolved | Meaning |
|-----|----------|---------|
| `--colorAccentBg` | `#cfcfcf` | accent base (light grey) — used for the group separator |
| `--colorAccentFg` | `#000000` | contrast text on accent |
| `--colorHighlightBg` | `#7aa0ff` | selection/highlight blue |
| `--colorBg` | `#363536` | chrome background |
| `--colorBgLight` | `#3a393a` | lighter background |
| `--colorFg` | `#d3d9e3` | primary text (white-ish) |
| `--colorFgFaded` | `#c9cfd8` | secondary text |

Lesson: when injecting styles into `window.html`, use `var(--colorFg)` / `var(--colorAccentBg)` etc. with a fallback — they cascade from `#browser` to any descendant, including our `#tab-title-split` `<style>` rules.

## 3. The in-page refresh button (↻)

### Motivation

The splitter's manual-rerun model (no live observers — see the crash history in `2026-09-02-non-destructive-title-rendering.md`) means every tab reorder / open / close needs `CDP_PORT=9023 node tools/vivaldi-title-split.mjs on` to re-number and re-group. This session's ask: a button in the Vivaldi panel that does the re-run without the shell.

### Design: inject once via CDP, self-contained after

The button is created and appended to `document.body` (NOT into any React-owned subtree — appending to `.tab-strip` or `.title` parents crashes the chrome, see the 09-02 writeup) by the `on` CDP payload:

```js
btn = document.createElement('button');
btn.id = 'tab-split-refresh-btn';
btn.textContent = '↻';
btn.addEventListener('click', (e) => {
  e.stopPropagation();
  if (wasDragged) { wasDragged = false; return; }  // drag, not click
  applyTabSplit();                                  // re-run split in-page
});
document.body.appendChild(btn);
```

- **No CDP at click time.** `applyTabSplit` is a closure defined in the same injected eval; the click handler calls it directly. The only CDP involvement is the injection itself (and `off`'s removal).
- **Always recreated on `on`**: any stale `#tab-split-refresh-btn` is removed first (`oldBtn.remove()`), then a fresh one is created. This matters because the button's handlers close over the eval's `dragState`/`wasDragged`/`applyTabSplit` — an old button injected by a previous tool version would carry stale closures. This bit us in practice: a button created before the drag code existed kept its old no-drag click handler after re-runs.
- **Theme-correct appearance**: cloned from Vivaldi's own "search tabs" toolbar button (`#tabs_button`'s closest `button`), then modified per user request:
  - `30x30px`, `min-width: 30px`, `border-radius: 8px`
  - `background: transparent`, `border: 1px solid var(--colorFg)` (1px border in the icon color, added on request)
  - `color: var(--colorFg)` (resolves to white)
  - `cursor: grab` / `grabbing` while dragging
  - hover: `rgba(255,255,255,0.12)` background, full opacity
- **Position**: `position: fixed`, restored from config (see §5) or defaulted to left-aligned + vertically centered.

### 3a. Dragging + edge snapping (AssistiveTouch-style)

Drag implementation uses **Pointer Events + `setPointerCapture`**, with a capture-phase `window` `mousemove`/`mouseup` fallback:

```js
btn.addEventListener('pointerdown', (e) => {
  e.stopPropagation();                    // NOTE: no preventDefault (see below)
  btn.setPointerCapture(e.pointerId);
  dragState = { startX: e.clientX, startY: e.clientY,
                origLeft: btn.offsetLeft, origTop: btn.offsetTop, moved: false };
  wasDragged = false;
});
window.addEventListener('mousemove', (e) => { /* same move math */ }, true);
btn.addEventListener('pointermove', (e) => { /* same move math */ });
window.addEventListener('mouseup', (e) => { /* finalize + snap */ }, true);
```

- **4px move threshold** distinguishes click from drag (`dragState.moved` → `wasDragged`); the click handler skips `applyTabSplit()` after a drag. The `wasDragged` flag is captured on mouseup *before* the click event fires (mouseup → click order), so the click handler sees the correct value.
- **Snap on release**: `snapToEdge()` computes the button center's distance to all four viewport edges and moves it to the nearest edge with a 4px margin; the perpendicular axis is clamped (`clampX`/`clampY`) so the button never goes off-screen — dragging into a corner lands it fully visible.

### CDP input quirks discovered (important for testing)

These only bite when driving the drag via CDP `Input.dispatchMouseEvent`; real mouse input is unaffected:

1. **`preventDefault()` on `mousedown`/`pointerdown` cancels the drag gesture** — Chromium stops delivering subsequent `mousemove`/`pointermove` after the first one. Removed; `user-select: none` on the button already handles text selection.
2. **`e.stopPropagation()` on mousedown caused stale-move delivery** in some states — also removed from `pointerdown`.
3. **Moves that jump beyond the 30px button box are dropped.** Vivaldi hit-tests the coordinates (not the moved element), so a CDP move from inside the button to outside lands on whatever is underneath and the event is consumed there. The button follows the cursor during a drag, so this only happens when a single dispatched move spans > ~15px beyond the box. **Test harnesses must use small steps (≤3px)**; the `setPointerCapture` + window-capture fallback covers real mouse use.
4. `Input.dispatchMouseEvent` works fine over tabs (tab drag/reorder tested), but over `<webview>` regions events go to the webview renderer, not `window.html` — don't place test drags over the page content area.

## 4. The CDP "dynamic fetch" story

The original request suggested dynamically fetching the CDP port from the browser. What actually happened:

- The **tool** discovers its targets dynamically: `fetch(http://127.0.0.1:${PORT}/json/list)` filtered by `url.includes('window.html')` — no hardcoded target ID, works for any number of windows.
- The port still comes from `CDP_PORT` env (default `9222`).
- The **button** never needs CDP at all after injection — it's a closure over `applyTabSplit()` in the page. So "dynamically fetch CDP" became "only connect once, then stay in-page".

## 5. Position persistence (XDG config, per port)

The button's position survives restarts via a **config file on disk**, not localStorage (bare `localStorage` is shadowed/null in Vivaldi's `window.html` global scope — `window.localStorage` exists but is the wrong store anyway; a fresh profile would lose it).

- **File**: `$XDG_CONFIG_HOME/vscode-cdp-automator/vivaldi-tab-split/btn-pos-<port>.json` (port in the path, defaults to `~/.config/...`).
- **Write path**: the page stashes the position into `window._tabSplitBtnPos = { left, top }` at the end of every drag (`savePos()` inside `snapToEdge()`). On each `on` run the tool reads that stash via CDP and writes it to the file:
  ```js
  const cur = await ev(`(() => window._tabSplitBtnPos ? JSON.stringify(window._tabSplitBtnPos) : null)()`);
  if (cur) writeBtnPos(p.left, p.top);
  ```
- **Restore path**: `on` reads the file before injecting (`readBtnPos()`) and passes it into the page as `SAVED_POS`; the button is placed there if present.
- **Default** (no config file yet): left-aligned + vertically centered —
  ```js
  btn.style.left = '4px';
  btn.style.top = Math.max(4, Math.round((window.innerHeight - bh) / 2)) + 'px';
  ```
- Verified end-to-end: default `(4, 303)` → drag to right edge → file contains `{"left":661,"top":385,"port":9023}` → `off`+`on` restores `(661, 385)`.

## 6. What this did NOT change

- `NEW_H = 38` unchanged.
- Manual-rerun model unchanged (button is the manual rerun, just without the shell).
- Non-destructive rendering (`::before`/`::after` + custom props) unchanged.
- `on|off|status` interface unchanged.

## Files touched

- `tools/vivaldi-title-split.mjs` — `GAP 40→0`, `.tab-group-end` border → `var(--colorAccentBg)`, button injection/cleanup, drag + edge-snap, XDG position persistence.
- This doc.
- (Earlier today, also: `docs/important/vivaldi/how-to-record-tab-dragging-video.md` — real-cursor drag recording via CDP + xdotool hybrid.)

## Followups

- README's "What `on` does" bullets still describe `GAP=40` gaps; update to match (see also the standing followup to fix the "Title rewrite" bullet for the pseudo-element approach).
- Consider whether `status` should also report the button's presence.
- Button position is viewport-fixed; if Vivaldi's window gets resized so a snapped position falls outside (e.g. narrower window), consider clamping on injection rather than trusting the stored value.