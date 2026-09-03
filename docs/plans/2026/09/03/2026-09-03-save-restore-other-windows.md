# Save / Restore Geometry of All Other Mac Windows

Date: 2026-09-03
Tool: `vscode-ui-resizer/vscode-ui-resizer.swift` (`vscode-ui-resizer.exe`)
Companion docs: `README.md`, `docs/important/mac-display-management.md`, `docs/important/window-identification-and-launch-badge.md`

## TL;DR

`vscode-ui-resizer` already saves/restores per-display geometry for VS Code windows, Vivaldi windows, and the per-tab internal layout of both. This change extends the same store to **every other GUI app's windows** on the Mac, so the whole desktop comes back on `restore-all`.

Two new subcommands:

```
vscode-ui-resizer.exe save-windows              Save pos & size of every open non-VSCode/non-Vivaldi GUI window
vscode-ui-resizer.exe restore-windows           Apply saved geometry to windows of already-running apps
```

Both are folded into `save-all` / `restore-all` as a new stage.

## Scope decisions (from requirements gathering)

| Question | Decision |
|---|---|
| Which apps to track | All running GUI apps (`activationPolicy == .regular`), excluding VS Code bundles + Vivaldi (already handled separately) |
| Window matching | Positional by index inside the app's `AXWindows` array, keyed by `bundleIdentifier` |
| Absent apps on restore | Skip, log a warning. Never launch anything. |
| Surface | New `save-windows` / `restore-windows` subcommands; added to `save-all` / `restore-all`. |
| Retry count | Default **5** retries at 3px tolerance (same as `restore-win`). |

## Config schema change

`DisplayConfig` gains one optional field:

```swift
struct DisplayConfig: Codable {
    var window: WindowInfo?
    var layout: LayoutConfig?
    var codeServerLayout: LayoutConfig?
    var vivaldi: VivaldiConfig?
    var otherWindows: [String: [WindowInfo]]?   // NEW: bundle ID -> ordered windows
}
```

- Keyed by `bundleIdentifier` (stable across launches; PID is not).
- Value is the **ordered** list of `WindowInfo` for that app, in `AXWindows` array order (this is z-order). Reuses the existing `WindowInfo` struct — no new codable type.
- Persists in the same `~/.config/vscode-cdp-automator/config.json` store, under the same per-display-fingerprint key as everything else. Legacy migration is unaffected (the field is optional; absent in old configs decodes to `nil`).

## Implementation pieces

### a) New helper: `findOtherApps()`

Mirrors `findVSCodeWindows()` / `findVivaldiWindows()`. Filters `NSWorkspace.shared.runningApplications` by:

- `activationPolicy == .regular` (GUI apps with a Dock icon; excludes menu-bar/System/background daemons).
- `bundleIdentifier != nil` and not in `VSCODE_BUNDLES`.
- `bundleIdentifier != VIVALDI_BUNDLE_ID`.
- `AXWindows` is non-empty (an app with no currently open window contributes nothing).

Returns an array of `(bundleID, pid, appEl, windows: [AXUIElement])`.

### b) Shared geometry-apply helper (refactor)

Both `cmdRestoreWin` (lines ~1022-1051) and `cmdRestoreVivaldi` (lines ~1886-1911) inline the same retry loop: set `AXPosition` + `AXSize`, sleep, read back, compare at 3px tolerance, retry up to N times. Extract to:

```swift
func applyWindowGeometry(
    _ win: AXUIElement,
    target: WindowInfo,
    globalPos: CGPoint,
    maxRetries: Int = 5,
    exitFullScreen: Bool = true,
    prefix: String
) -> Bool
```

Behavior preserved exactly (`exitFullScreen(win)` if needed; same tolerances; same `#N: pos=… size=… [OK|RETRY]` log format). Both old call sites switch to calling this; `cmdRestoreWindows` uses it too. Behavioral parity is the whole point — no functional change to VS Code / Vivaldi restore paths.

### c) `cmdSaveWindows()`

Mirrors `cmdSaveWin`:

1. Iterate `findOtherApps()`.
2. For each window in `AXWindows` order:
   - Skip if `AXMinimized == true` (minimized windows have no stable geometry and won't restore deterministically).
   - Skip if `AXPosition` / `AXSize` unreadable.
   - Build a `WindowInfo` using the same `describeScreen(containing:)` + `resolveGlobalPosition` machinery already used for VS Code / Vivaldi windows — multi-monitor save/restore works the same way.
3. Group by `bundleID`; write into `store[fingerPrint].otherWindows[bundleID]`.
4. Save the store; print a per-app summary (bundle ID, count, totals) plus the display fingerprint block (consistent with `cmdSaveWin`'s output style).

### d) `cmdRestoreWindows()`

Mirrors `cmdRestoreWin`:

1. Fingerprint lookup with the same "single available saved config" fallback that all other restore commands already use (see `cmdRestoreWin` lines ~949-959).
2. Build a `bundleID -> pid_t` map from `NSWorkspace.shared.runningApplications`.
3. For each saved bundle ID:
   - If the app is **not running**, print `⚠ <bundleID> not running, skipped` and move on. (Never launches anything.)
   - Else iterate its `AXWindows` and apply geometry positionally via `applyWindowGeometry`, zipping against the saved list. Index `i` of saved windows maps to index `i` of current windows. Extras on either side are ignored with a note.
4. Log per-window: `[i/N] bundleID  pos=(x, y)  size=WxH  [OK|RETRY|FAILED]`.

### e) Wire-up

- `cmdSaveAll` (line ~2082): add a `save-windows` stage after `save-vivaldi-zoom`. Failure short-circuits the same way the existing stages do.
- `cmdRestoreAll` (line ~2108): add a `restore-windows` stage after `restore-vivaldi` and before `restore-codeserver-layout` (VS Code + Vivaldi first, then other apps, then code-server tabs that drive layout over CDP).
- `switch args[1]` (line ~2188): add two cases — `save-windows` -> `cmdSaveWindows()` and `restore-windows` -> `cmdRestoreWindows()`. Neither takes a port arg.
- `usage()` (line ~2151): add two lines documenting the new subcommands.

## Edge cases handled

| Case | Behavior |
|---|---|
| Multi-monitor save → restore to a different arrangement | Same `describeScreen` / `resolveGlobalPosition` / `isPositionOnScreen` fallback as VS Code. Restored to the screen with matching fingerprint if present; else falls back to raw coords. |
| Fullscreen window | `applyWindowGeometry` exits fullscreen before applying (preserves current VS Code / Vivaldi behavior). |
| Minimized window | Skipped on save. On restore, a minimized window is left where it is (we don't un-minimize). |
| App has fewer current windows than saved | Only positions up to `current.count`; extras are ignored, logged. |
| App has more current windows than saved | Extras are left in place. |
| App resists `AXPosition` / `AXSize` (System Settings, some preference panels) | Logs `FAILED after 5 attempts`, continues to the next window / app. |
| Window with no title | Fine — `WindowInfo.title` becomes `""`, `label` falls back to the bundle ID for logging. |
| Fingerprint not in store, only one saved config | Same "use the only available saved config" fallback used by every other restore command. |
| Fingerprint not in store, multiple saved configs | Same skip-with-stderr-message behavior. |

## Explicitly out of scope

- **No launching of absent apps.** Restore only operates on windows of apps already running. The user opens their working set, then runs `restore-all`.
- **No minimized/fullscreen state preservation.** We just don't save minimized windows and exit fullscreen before applying.
- **No per-app special handling.** Every bundle ID gets the same generic `AXPosition` / `AXSize` treatment. If a specific app misbehaves it logs `FAILED` and continues; no per-bundle overrides.
- **No window stacking order restoration.** `AXWindows` order is z-order and is not deliberately restored; we just apply geometry in array order.

## Files touched

- `vscode-ui-resizer/vscode-ui-resizer.swift`
  - `DisplayConfig`: +1 field (`otherWindows`).
  - +1 helper: `findOtherApps()`.
  - +1 shared helper: `applyWindowGeometry()`; `cmdRestoreWin` and `cmdRestoreVivaldi` refactored to call it (behavior preserved).
  - +2 commands: `cmdSaveWindows()`, `cmdRestoreWindows()`.
  - `cmdSaveAll` / `cmdRestoreAll` / `switch args[1]` / `usage()`: wired up.
- `README.md`: two new lines under "Usage" + a sentence in the "How it works" block.
- This doc.

## Verification

1. Build: `make vscode-ui-resizer` (swiftc).
2. Open a handful of GUI apps (Finder, Terminal, Notes, Messages, etc.) with **non-default** window positions.
3. `./vscode-ui-resizer.exe save-windows` — check the per-app summary and that `~/.config/vscode-cdp-automator/config.json` now has a non-empty `otherWindows` map under the current display fingerprint.
4. Move/drag those windows somewhere else.
5. `./vscode-ui-resizer.exe restore-windows` — every tracked app's window snaps back. Log shows `[i/N] … [OK]` per window.
6. Quit one of the tracked apps; re-run `restore-windows` — verify it logs `⚠ <bundleID> not running, skipped` and leaves the rest alone.
7. Multi-monitor: change arrangement in System Settings, run `restore-windows` — verify the saved-screen-not-found fallback kicks in (logged) and windows still land somewhere sensible.
8. Run `save-all`, then `restore-all` — verify the new stage slots in cleanly between Vivaldi and code-server stages, and the final exit status reflects failures correctly.

## Followups

- If a specific app persistently fails (e.g. System Settings panels), consider adding a small `AXPosition`/`AXSize` reject list (bundle IDs we skip on save to avoid noise). Defer until observed.
- Consider widening `WindowInfo` with `AXMinimized` if we ever want to remember minimized state. Currently out of scope.
