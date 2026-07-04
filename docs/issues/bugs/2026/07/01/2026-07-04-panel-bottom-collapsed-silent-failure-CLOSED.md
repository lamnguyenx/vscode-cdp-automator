# 2026-07-04: restore-layout Fails Silently on Bottom-Positioned & Collapsed Panels

**Status:** CLOSED — fixed in `vscode-ui-resizer/vscode-ui-resizer.swift`

## Summary

`restore-layout` silently fails (no error, no resize) when targeting VS Code windows whose panel is in the `bottom` position or collapsed (`width=0` / `height=0`). Two distinct failure modes, same symptom: 5 retry attempts with zero-effect drags, then `FAILED`.

## Root Cause 1: Panel at Bottom (Missing Selector)

The sash-mapping selector only looked for **vertical** sashes in **horizontal** split-views:

```js
'.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical'
```

When the panel is at the **bottom**, the visual layout is:

```
.monaco-grid-view
  .monaco-split-view2.vertical (main vertical split)
    ├── .monaco-split-view2.horizontal (top: activitybar | sidebar | editor)
    └── .part.panel (bottom)
```

The sash controlling panel height is a **horizontal** sash in a **vertical** split — invisible to the selector. The mapping returned no `editor|panel` entry; the fallback `epIdx = 1` pointed to a sash inside the sidebar's internal vertical split instead.

### Fix

Added `solveSashMappingVertical`, `dragSashVertical`, and `readPanelPosition`. At restore time, the panel position is detected (right/left vs bottom) and the appropriate mapping + drag variant is used. Drag deltas for bottom panels use `clientY` (vertical drag) instead of `clientX`.

Key additions:
```diff
+ func solveSashMappingVertical(_ task: URLSessionWebSocketTask) -> [String: Int]
+ func dragSashVertical(_ task: URLSessionWebSocketTask, sashIdx: Int, dy: Int)
+ func readPanelPosition(_ task: URLSessionWebSocketTask) -> String
```

`cmdRestoreLayout` now reads `panel_position` from the saved config: if `"bottom"` / `"top"`, the target uses `panel["height"]` instead of `panel["width"]`.

## Root Cause 2: Collapsed Panel → Silent Failure Cascade

When a panel is collapsed (`width=0` for right/left, `height=0` for bottom), no `editor|panel` sash exists in the DOM. The fallback `epIdx = 1` targeted a non-existent element.

### The Cascade

1. `solveSashMapping` → no `editor_panel` found → fallback `epIdx = 1`
2. `dragSash(all[1])` → `all[1]` is `undefined` → JS returns `{error: 'no sash at 1'}`
3. `evalJS` can't extract `result.result.value` (it's an object, not a string) → returns `"null"`
4. `readCurrent` parses `"null"` → `[:]` (empty dict)
5. All values default to `0` → `dx_p = 0 - 675 = -675`, `dx_s = 964 - 0 = +964`
6. Drags execute on wrong (or non-existent) sash indices → no effect
7. Next `readCurrent` also fails → zeros → deltas recomputed from zeros → loop forever

### Concurrent Failure Mode: CDP Console Flooding

The same `wsSend` receive loop handles ALL CDP messages on the shared process WebSocket. Extensions spamming `console.log` generated 700+ `Runtime.consoleAPICalled` events per connection. With a 500-iteration drain loop, `wsSend` exhausted its budget scanning console spam before reaching the actual `id:99` response — `evalJS` returned `{}` → `"null"` → `[:]` → all zeros.

### Fix

**Collapsed panel guard:** Before entering the retry loop, check if `panel == 0 && target > 0 && smap["editor_panel"] == nil` and skip with a clear message instead of 5 silent retries.

**Zero-read guard:** If `readCurrent` returns `{sidebar:0, panel:0, editor:0}` for 3 consecutive reads, skip the window.

**String pre-filter in `wsSend`:** Instead of `JSONSerialization`-parsing every message (expensive for 700+ events), do a cheap `String.contains("\"id\":\(mid)")` check first. Only the matching message gets deserialized. This keeps the 500-iteration limit sufficient for any realistic console flood:

```swift
let needle = "\"id\":\(mid)"
for _ in 0..<500 {
    let raw = wsRecv(task)
    if !raw.contains(needle) { continue }   // cheap string scan, skip 99.9%
    guard let data = raw.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          dict["id"] as? Int == mid
    else { continue }
    return raw
}
```

## Verification

After fix, all 6 VS Code windows in the test instance respond cleanly:

```
[2] 🍉 - book-designing-web-apis - book-designing-web-apis
    (panel at bottom — using vertical sashes)
    panel is collapsed (height=0) and no editor|panel sash found — expand panel first, then re-run

[5] 🍉 - web-live-translator - web-live-translator
    workbench not ready (zero values), retrying...
    workbench not ready (zero values), retrying...
    panel is collapsed (width=0) and no editor|panel sash found — expand panel first, then re-run
```

Windows at target return `already at target — OK` immediately. Collapsed windows get a clear, actionable message instead of 5× `RETRY` + `FAILED`.
