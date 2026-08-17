# Vivaldi General Quirks (CDP / Prefs / Live State)

Field notes for automating Vivaldi 8.x (Chromium 150) over Chrome DevTools Protocol
(CDP), collected while building the save/restore tooling. Companion to
`docs/important/changing-vivaldi-vertical-tab-bar-size.md` and
`docs/important/changing-vivaldi-zoom.md`.

## 1. The chrome is an internal extension — and a CDP target

Vivaldi's entire UI (tab bar, address bar, panels) is an internal extension whose pages
show up as targets on `/json/list`. The extension id is stable across releases:

`mpognobbkildjkofajifpdfhcoklimli`

| Target | URL | Purpose |
|--------|-----|---------|
| `window.html` | `chrome-extension://mpognobbkildjkofajifpdfhcoklimli/window.html` | Per-window chrome — tab bar, address bar, webview container |
| `main.html` | `chrome-extension://mpognobbkildjkofajifpdfhcoklimli/main.html` | Shared UI |
| workers | `background-service-worker-56`, etc. | Extension service workers |

Attach to `window.html` to reach the real chrome DOM and the `window.vivaldi` APIs. The
**page** targets (regular `https://` tabs) are separate — zoom the page from
`window.html` via `chrome.tabs`, not by evaluating on the page itself.

`window.vivaldi` exposes a rich API surface, including: `prefs`, `zoom`, `tabsPrivate`,
`windowPrivate`, `settings`, `sitePermissions`, `themePrivate`, `menuContent`, etc.

## 2. On-disk `Preferences` is stale — live state is authoritative

`~/Library/Application Support/Vivaldi/Default/Preferences` is written **lazily**. It can
say one thing while the running browser does another:

- During testing the file reported tab-bar `position: 0` (top) while the live value
  (via `window.html`) was `left`.
- The default page zoom lives at `partition.default_zoom_level` in that file, stored as a
  **zoom level** (`level = log(factor) / log(1.2)`, e.g. `1.6` → `≈2.5779`) — stale by
  nature. Read live values with `window.vivaldi.prefs.get(...)` / the `zoom` module.

Always treat the on-disk file as a hint, never as the source of truth.

## 3. `vivaldi.prefs` semantics

- `window.vivaldi.prefs.get(path, cb)` returns `{ store, value, defaultValue }`.
- `window.vivaldi.prefs.set({ path, value }, ...)` **writes the stored value but does not
  re-render state-driven UI**. The rendered UI (e.g. tab-bar width) is driven by React
  component state that is only initialized from the pref at mount and only mutated by
  user interaction. Use a real interaction (trusted CDP drag) or a chrome reload instead.
- Some prefs are `syncable.*` (e.g. `syncable.vivaldi.mouse_wheel.page_zoom`); synced
  values can overwrite what you wrote.

## 4. Synthetic events are untrusted — `setPointerCapture` throws

Dispatching `new PointerEvent(...)` via `el.dispatchEvent()` fails wherever Vivaldi's UI
calls `setPointerCapture(pointerId)` (tab-bar resize handle, etc.): synthetic events have
no real active pointer, the call throws, and the rest of the handler never runs.

Use CDP **`Input.dispatchMouseEvent`** to inject *trusted* input at the browser level so
pointer capture works:

```
mouseMoved → mousePressed → (stepped mouseMoved…) → mouseReleased
```

For plain-`MouseEvent` listeners that track `mousemove`/`mouseup` on `window` (VS Code
sashes), synthetic events are fine — that's the difference between the two targets.

## 5. The zoom module

`window.vivaldi.zoom` (only reachable from `window.html`):

```js
getDefaultZoom / setDefaultZoom        // default page zoom (persisted)
getVivaldiUIZoom / setVivaldiUIZoom    // whole-chrome zoom (persisted)
onDefaultZoomChanged / onUIZoomChanged  // events
```

- Factors, not percents (`1.6` = 160%).
- UI zoom and default zoom are **independent** — setting one never changes the other.
- `getVivaldiUIZoom` can return FP artifacts (`1.6000000000000005`); compare with
  tolerance, e.g. `abs(after - target) < 0.01`.
- `chrome.tabs` (query / getZoom / setZoom) is available in the `window.html` context, so
  per-tab zoom needs no second attachment. Per-tab zoom even works on Vivaldi's own
  `chrome-extension://` tabs.

## 6. Miscellaneous

- `window.vivaldi.tabsPrivate` handles tab internals (`get`, `update`, `onPageZoom`, …
  ) but has **no** `setZoom`; use `chrome.tabs` for zoom.
- `vivaldi.appearance.density` is UI *density* (Comfortable/Compact), not zoom.
- `vivaldi.webpages.tab_zoom.enabled` (default `true`) and
  `vivaldi.mouse_wheel.page_zoom` (default `true`) govern zoom behavior, not zoom values.
- Zoom commands exist as actions (`COMMAND_MAIN_ZOOM_IN/OUT/RESET`) with shortcuts
  (`meta++`, `meta+-`, `meta+0`) — command/action dispatch is another way to trigger
  zoom, but the `zoom` module gives direct value control.
- `prefs_definitions.json` lives at
  `/Applications/Vivaldi.app/Contents/Frameworks/Vivaldi Framework.framework/Versions/<ver>/Resources/vivaldi/prefs_definitions.json`
  — the authoritative pref schema (and action defaults).

## Related

- `docs/important/changing-vivaldi-zoom.md` — the zoom APIs in detail
- `docs/important/changing-vivaldi-vertical-tab-bar-size.md` — tab-bar width, trusted drag
  mechanics