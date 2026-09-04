# vscode-cdp-automator

Save and restore **window geometry** and **internal UI layout** for VS Code, code-server tabs, and Vivaldi — keyed per display arrangement. macOS-only (uses Accessibility API + Chrome DevTools Protocol).

## Build

```bash
make vscode-ui-resizer
```

Produces `vscode-ui-resizer/vscode-ui-resizer.exe`.

## Usage

Default CDP ports: **9333** for VS Code, **9222** for code-server / Vivaldi.

```
vscode-ui-resizer.exe save-win                        Save all open VS Code windows pos & size (title-matched on restore)
vscode-ui-resizer.exe restore-win [port]              Apply to all VS Code windows (title-first, positional fallback)
vscode-ui-resizer.exe save-layout [port]              Save sidebar/panel widths + zoom
vscode-ui-resizer.exe restore-layout [port]           Restore to all VS Code windows
vscode-ui-resizer.exe save-codeserver-layout [port]   Save active code-server tab layout
vscode-ui-resizer.exe restore-codeserver-layout [port] Restore to all code-server tabs
vscode-ui-resizer.exe save-vivaldi [port]             Save Vivaldi window + vertical tab bar
vscode-ui-resizer.exe restore-vivaldi [port]          Restore Vivaldi window + tab bar
vscode-ui-resizer.exe save-vivaldi-zoom [port]        Save Vivaldi UI + default page zoom
vscode-ui-resizer.exe restore-vivaldi-zoom [port]     Restore zoom and apply to every tab
vscode-ui-resizer.exe save-windows                    Save pos & size of all other open GUI app windows
vscode-ui-resizer.exe restore-windows                 Apply saved geometry to windows of already-running apps (title-matched)
vscode-ui-resizer.exe vivaldi-tab-numbers [port]      Inject tab-order numbers into tab strip
vscode-ui-resizer.exe save-all [port]                 Run all save steps in sequence (in-process)
vscode-ui-resizer.exe restore-all [port]              Run all restore steps in sequence (in-process)
vscode-ui-resizer.exe list-displays                   Print connected screens
```

Exit codes: `0` ok, `1` failed, `2` precondition (AX denied / CDP unreachable / no saved data). `save-all` / `restore-all` report per-stage `OK/FAILED/SKIPPED` and fail only on real failures (skips don't fail). All commands accept `--verbose` for AX/CDP diagnostics.

## Config

Single store at `~/.config/vscode-cdp-automator/config.json`, keyed by a display fingerprint v2 (`[x,y] WxHpt @Scalex rot° name`, points + scale; v1 pixel-size keys read as legacy alias). Each entry keeps `window` (legacy first window) + `windows` (all VS Code windows), `layout`, `codeServerLayout`, `vivaldi`, and `otherWindows` (a `bundleID -> [window]` map for every other GUI app, restored title-first with positional fallback). Legacy configs under `~/.config/vscode/` are auto-migrated on first load. Corrupt main config is never overwritten — it logs and uses an empty store.

## How it works

- **Window position/size** — macOS Accessibility API (`AXPosition` / `AXSize`), verified by read-back at 3px tolerance (sets report success even when silently dropped, and width/height can fail independently). Save classifies the display size-aware: exact top-left hit → largest window-rect overlap → nearest screen, so edge-sitting windows are never stored `off-screen` while displays exist. Restore trusts fingerprint-matched coordinates within 60px (clamping into the *matched* screen, never main), and `applyWindowGeometry` breaks display-fill/maximized state with one large height change before walking size in ≤400px steps — large single jumps are silently ignored, so spanning restores converge instead of sticking on one display. Requires Accessibility permission (exit 2 with hint otherwise). See [2026-09-04 restore geometry round-trip bug](docs/issues/bugs/2026/09/04/2026-09-04-restore-window-geometry-roundtrip-CLOSED.md).
- **VS Code sidebar/panel widths** — CDP `Runtime.evaluate` discovery of Monaco sash indices, then synthetic `MouseEvent` `mousedown → mousemove → mouseup` on `window` (VS Code sashes listen for plain MouseEvents). Sash-mapping misses abort instead of guessing indices.
- **Vivaldi tab bar** — CDP `Input.dispatchMouseEvent` (trusted input), because Vivaldi's resize handle calls `setPointerCapture` and rejects synthetic events.
- **Zoom** — VS Code: backup + JSONC-tolerant edit of `settings.json` `window.zoomLevel` (validates before/after, restores backup on failure); Vivaldi: `window.vivaldi.zoom` + `chrome.tabs.setZoom` over `window.html` target.
- **Other windows** — every running `.regular` GUI app (excluding VS Code + Vivaldi) has its windows enumerated via `AXWindows`, keyed by `bundleIdentifier` and stored positionally. Restore is title-first with positional fallback. Restore only positions windows of apps already running; absent apps log a warning and are skipped (never launched).
- **Eligibility gating** — windows are skipped unless sidebar-left / panel-right / not-maximized, so orthogonal layouts are never clobbered.

## Tools

Helper scripts for inspection and debugging (not required by the main binary):

- `tools/cdp_inspect.py` — dump VS Code sash / part / grid geometry over CDP.
- `tools/test_restore.py` — Python port of the layout-restore flow for iteration.
- `tools/show-cdp-ports.mjs` — discover Vivaldi/Chromium instances by `--remote-debugging-port`, pin window titles to `:PORT`, flash launch-args badge. Supports `--ssh host1,host2` (self-copies to each remote; no port forwarding).
- `tools/check-vivaldi-zoom.mjs` — print UI / default / per-tab zoom.
- `tools/inspect-vivaldi-tabs.mjs` — dump `.tab-position` DOM.
- `tools/vivaldi-title-split.mjs` — see [Vivaldi title split](#vivaldi-title-split).

## Vivaldi title split

`tools/vivaldi-title-split.mjs` reshapes Vivaldi's vertical tab strip into taller, two-line, numbered, group-separated rows. It injects CSS + a one-shot DOM pass into the `window.html` CDP target on port 9222 (Vivaldi 8.x / Chromium 150).

```
node tools/vivaldi-title-split.mjs [on|off|status]   # default: on
```

### What `on` does

**1. Injects `<style id="tab-title-split">`** — durable CSS that:

- Sets `--Height: 38px !important` on every `.tab-position` (overrides Vivaldi's inline `--Height:31px`; `!important` beats inline, see `docs/important/vivaldi-general-quirks.md` §6).
- Hides `.favicon`, `.tab-audio`, `.page-progress-indicator` — they clip badly in taller rows.
- Makes `.title` a block with `flex:1 1 auto`, `height:auto`, and a right-edge `mask-image` gradient (fades last 30px so long titles trail off cleanly).
- Relaxes `.tab-header` / `.tab` height/flex constraints and centers content vertically via `justify-content:center`.
- Adds structural styling: white border-bottom on each row, `#tabs-tabbar-container` right border, bold/smaller `.tab-main-title`, normal-weight `.tab-subtitle`, gray-bold `.tab-number`.

**2. Runs `applyTabSplit()` one-shot** (the JS payload):

- **Grouping**: reads each tab's raw title (cached on `.title[data-orig-title]`), splits on ` - `, treats the first segment as the group key. `Blank Page` is its own group and is rendered empty.
- **Repositioning**: Vivaldi lays out `.tab-position` absolutely via inline `--PositionY:N*31px`. The script recomputes `--PositionY = idx*38 + offset` (px, `!important`) so rows use the new height.
- **Group separators**: when the group changes between consecutive tabs, inserts a `.tab-gap` div (40px tall, white border-bottom) and marks the previous row `tab-group-end`. `offset` accumulates so subsequent `--PositionY` values stay correct.
- **Title rewrite**: saves original text to `data-orig-title`, then sets `.innerHTML` to a numbered span + `<span class="tab-main-title">first part</span><br><span class="tab-subtitle">rest joined by ' - '</span>`. Single-segment titles get `N. text` only. Visible (non-blank) tabs are numbered sequentially starting at 1.
- **Container resize**: Vivaldi sets `.resize { max-height: n*32 }` from its own JS; the script writes `max-height: n*(38+1) + totalGaps*40` (`GAP=40`) so the strip actually fits all rows at the new height. Without this the strip keeps the old max-height and a stale scrollbar appears.

**3. Tears down any prior automation** — disconnects `window._tabSplitObserver` and clears `window._tabSplitInterval`. Current model is **manual rerun only** (no live observers); see "Why manual rerun" below.

### What `off` undoes

- Removes the `<style id="tab-title-split">` and the older `<style id="tab-order-numbers">`.
- Disconnects observer / clears interval.
- Clears every `.tab-position` `--PositionY` inline override and `tab-group-end` class.
- Restores each `.title` `textContent` from `data-orig-title`, then drops the attribute.
- Removes `.resize { max-height }` override.

### What `status` reports

Prints `on` / `off` per window by checking whether `#tab-title-split` exists in the DOM.

### Why manual rerun (not live observers)

Vivaldi re-renders `.tab-position` (rewriting `--PositionY` and `.title` text) on tab open/close/reorder/pin. The natural reflex is a `MutationObserver` on `.tab-strip` to re-run `applyTabSplit()`, but:

- An observer with `subtree:true` fires on the same `.title.innerHTML` mutation it just performed → **infinite loop → browser freeze → required `Page.reload`** to recover.
- Mitigations tried (debounce + `childList`-only + `setInterval` re-check) were fragile and still occasionally looped; all removed in favor of an explicit, **idempotent one-shot** pass (`on` is safe to re-run).
- Re-run after tabs change: `node tools/vivaldi-title-split.mjs on`. The `restore-all` and `save-all` shell commands do this automatically as their final step (see `runVivaldiTitleSplit()` in `vscode-ui-resizer.swift`).

### Constants

| Name | Value | Meaning |
|------|-------|---------|
| `NEW_H` | `38` | New tab row height (px), up from Vivaldi's 31. |
| `GAP` | `40` | Vertical gap inserted between tab groups (px). |

### Internals

- Connects to every `window.html` target on port 9222 (`/json/list` filtered by URL), `Promise.all`-applies in parallel.
- CDP transport is a minimal `attach()` / `send` / `onmessage` promise-pending map over raw `WebSocket`. No retry, no timeout — if the target is stale the script hangs; reconnect by re-running.
- State on the page side is kept minimal: `<style id>` markers plus per-tab `data-orig-title`. Nothing else persists across reloads.

See `docs/plans/2026/08/22/2026-08-22-vivaldi-tab-strip-height-title-split.md` for the full trial-and-error log, and `docs/important/vivaldi-tab-strip-customization.md` for the canonical DOM notes.

## Launching targets with CDP

VS Code / Electron / Vivaldi must be started with `--remote-debugging-port=<port>`. The port must match what you pass to the commands above.

## Docs

Field notes and implementation logs live under `docs/`:

- `docs/important/` — durable references: Vivaldi CDP/prefs quirks, zoom APIs, tab-bar resize mechanics, tab-strip customization.
- `docs/lessons/`, `docs/plans/`, `docs/issues/bugs/` — dated writeups, e.g. [2026-09-04 restore window geometry round-trip](docs/issues/bugs/2026/09/04/2026-09-04-restore-window-geometry-roundtrip-CLOSED.md) (off-screen misclassification, matched-screen clamping, maximized break-fill + stepped resize).
