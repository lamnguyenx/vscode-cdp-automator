# vscode-ui-resizer Revamp Plan

Date: 2026-09-04
Tool: `vscode-ui-resizer/vscode-ui-resizer.swift` (`vscode-ui-resizer.exe`, currently 2397 lines, single file)
Source: code review of 2026-09-04 (force-unwraps, fingerprint coordinate mixing, unsafe settings edit, index-based matching, CDP/WS fragility, exit-code contract, Swift 6 concurrency)
Companion docs: `README.md`, `Makefile`, `docs/plans/2026/09/03/2026-09-03-save-restore-other-windows.md`

## TL;DR

`vscode-ui-resizer.swift` works but has accumulated structural debt: one 2397-line file, crash-prone force-unwraps/casts, a display fingerprint that mixes points with pixels, a regex edit of the user's `settings.json`, positional (index-based) restore for other-apps windows, fragile CDP websocket ID matching, and an exit-code contract where `save-all` / `restore-all` can never fail.

This plan revamps it in place (no behavior redesign, no new features) in 5 phases:

- **P0 Safety** — eliminate crashes, deprecated API, add AX permission check.
- **P1 Correctness** — fingerprint coordinate space, on-screen clamp, multi-window semantics, safe zoom write, CDP request IDs.
- **P2 Robustness** — exit codes, subprocess handling, `repoRoot` security, AX return-code checks, sash fallback.
- **P3 Maintainability** — split single file into modules, dedupe helpers, unify fingerprint lookup.
- **P4 Concurrency / hygiene** — Swift 6 `Sendable` fixes, `httpGetJSON` error handling, `ps` caching.

Config schema stays backward compatible. Fingerprint change ships with a dual-read migration. Each phase builds with `make vscode-ui-resizer` and is manually verifiable.

> Status: **PLAN ONLY — awaiting review. No implementation started.**

## Goals

1. No more crash paths on unexpected AX/CDP/JSON input (`as!`, `!`, `try!` gone).
2. Display fingerprint is self-consistent (single coordinate space) with migration for old keys.
3. Windows never restored off-screen invisibly.
4. `settings.json` zoom write cannot corrupt the file (backup + validate + JSONC-tolerant).
5. `restore-windows` no longer mis-assigns geometry to the wrong window.
6. `save-all` / `restore-all` exit status reflects real failures.
7. File split into reviewable modules, still built by one `make` target.
8. Zero new user-facing commands or config keys (internal refactor + bug fixes only).

## Non-goals / out of scope

- No new subcommands, flags, or config fields.
- No window stacking (z-order) restoration — still geometry only.
- No launching of absent apps on restore (existing policy kept).
- No minimized/fullscreen state preservation (existing policy kept).
- No live observers for Vivaldi tab strip (manual rerun model kept).
- No migration to Swift Package Manager unless reviewer prefers it (default: stay on `swiftc`, multi-file glob).
- No Linux support — still macOS-only (Cocoa + AX).

## Findings inventory (what the review found)

Ordered by severity. Line numbers refer to the reviewed revision (~2397 lines).

| # | Area | Location | Problem | Severity |
|---|---|---|---|---|
| F1 | Crashes | `:176,186` `axGetPoint/Size` (`v as! AXValue`) | Wrong AX type crashes process | Critical |
| F2 | Crashes | `:420,426,433,452,463,505,512` (`fw as! AXUIElement`) | Same | Critical |
| F3 | Crashes | `:411,416,438` (`frontApp!`) | TOCTOU nil | Critical |
| F4 | Crashes | `:815-820` (`try!` in `jsStringLiteral`) | Same | High |
| F5 | Crashes | `:1505,1507,1514` (`epIdx!`/`seIdx!`) | Wrong-sash drag or crash | Critical |
| F6 | API | `:359` (`task.launchPath`) | Deprecated, warns/fails under Swift 6 | Medium |
| F7 | Fingerprint | `:298-352` | `x/y` in points, `w/h` in pixels (Retina mismatch); `screen == mainScreen` identity; `name*` marker w/o space | High |
| F8 | Geometry | `:130-145`, `:283-294` | Screen match via `Int()`-truncated string equality; off-screen case double-offsets in `resolveGlobalPosition` | High |
| F9 | Geometry | `:1046-1048`, `:1907-1909`, `:2185-2187` | Fallback coords never checked on-screen; `globalPos != resolvedPos` detection is coincidental | High |
| F10 | Multi-window | `:982-1000` save vs `:1067-1088` restore | Saves 1 frontmost window, applies same rect to N windows (stacking) | High |
| F11 | Matching | `:2083`, `:2180-2183` | `otherWindows` stores `pid: 0`, restores by index; `AXWindows` order unstable | High |
| F12 | Settings | `:932-958` | Regex edit of JSONC `settings.json`, hardcoded indent, no backup/validation | Critical |
| F13 | CDP | `:611-653` | `wsSend` substring `"id":N` match, 500x5s loop; `evalJS` hardcodes `id: 99` | High |
| F14 | HTTP | `:546-562` | `httpGetJSON` ignores status/errors, data-race on `result`, dead `cancel()` | Medium |
| F15 | Concurrency | `:1775-1794`, `:1609-1633` | Mutable capture `activeWSURL`/`zoomResults` across GCD — Swift 6 `Sendable` errors | Medium |
| F16 | CLI | `:2247-2306` | Skips `return` (exit 0) so `save-all`/`restore-all` failure checks never fire | High |
| F17 | Subprocess | `:2208-2237` | `try? proc.run()` swallowed, `CommandLine.arguments[0]` w/o symlink resolve, `repoRoot` trusts CWD first (arbitrary node exec) | High |
| F18 | Sash | `:1439-1440` | `seIdx=0`, `epIdx=1` silent guess when mapping fails | High |
| F19 | Duplication | `:404-470`, `:493-518`, 7x fingerprint-fallback blocks | 3x frontmost-window impls, 7x copy-pasted store-lookup fallback | Medium |
| F20 | Perf | `:356-372` | `/bin/ps` per app for dev-host check | Low |

## Design decisions (need reviewer sign-off)

| Question | Proposed decision | Alternative |
|---|---|---|
| Build: stay on `swiftc` or move to SwiftPM? | **Stay on `swiftc`, compile `vscode-ui-resizer/*.swift` glob** (one-line `Makefile` change, keeps `.exe` convention, no new toolchain) | SwiftPM `Package.swift` — better long-term, but new layout + docs churn |
| Fingerprint v2 format? | **Add `framePt` (points) + `framePx` (pixels) + `scale` + `screenID`, keep old string as legacy alias**; read tries v2 then v1 | In-place fix (breaks all existing keys, forces re-save) |
| Multi-window save semantics? | **Save all open VS Code windows as ordered list** (`windows: [WindowInfo]`), restore matched by title, fallback to positional | Keep single-window save, but restore only to matched-title window (smaller change, leaves stacking for N>1) |
| `otherWindows` matching? | **Match by normalized title first, then index for untitled**; store `pid` removal kept (do not store pid) | Store `CGWindowID` (unstable across launches, no better) |
| Zoom write? | **Backup + JSONC-strip-comments + decode → mutate → encode path for that key only, preserving rest byte-for-byte when possible; abort on parse failure** | Shell out to `code --list-settings` / dedicated JSONC lib (new dependency) |
| CDP client? | **Minimal `CdpSession` struct with monotonically increasing `id`, typed `send<T: Decodable>`, 5s timeout, disconnect on mismatch** — no third-party dep | Adopt `URLSessionWebSocketTask` async/await rewrite (bigger diff) |

If reviewer disagrees on any row, that phase pauses until resolved — the rest can still land.

## Implementation pieces

### P0 — Safety (crash elimination, no behavior change)

**P0-a. Replace all force-casts/unwraps.**

- `axGetPoint` / `axGetSize` (`:171-187`):
  ```swift
  guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
  let axVal = v as! AXValue  // -> safe: (v as? AXValue) or CF cast
  ```
  Same for every `fw as! AXUIElement` / `mw as! AXUIElement` — `guard let win = focused as? AXUIElement`.
- `findFrontmostVSCodeWindow` (`:404-439`): bind once:
  ```swift
  guard let frontApp = NSWorkspace.shared.frontmostApplication, ... else { return nil }
  ```
  Remove all `frontApp!`.
- `jsStringLiteral` (`:815-821`): `try?` + `guard`, return `"\"\""` or `nil` on failure; callers handle `nil` as eval failure.
- Files: `AX.swift` (new), `CDP.swift` (new) after split; pre-split, same file.

**P0-b. Deprecated `launchPath` (`:356-372`).**

- `isDevHostProcess`: `task.executableURL = URL(fileURLWithPath: "/bin/ps")`. Add `task.qualityOfService = .utility`? Keep sync (CLI), but handle `try/catch` with stderr log instead of silent `false`.

**P0-c. AX permission preflight.**

- New `checkAXTrust() -> Bool` at top of every `save-win` / `restore-win` / `save-windows` / `restore-windows` / `save-vivaldi` path:
  ```swift
  guard AXIsProcessTrusted() else {
      fputs("Accessibility permission missing: grant in System Settings > Privacy & Security > Accessibility.\n", stderr)
      exit(2)
  }
  ```
- New exit code `2` = environment/precondition failure (distinct from `1` = operation failed). Document in `usage()`.

**P0-d. Loud config decode errors (`loadConfigStore:75-111`).**

- Today `try?` conflates "no file" with "corrupt file" then overwrites via migration. Change to: `do/catch`, on decode error `fputs("corrupt config at ...: <error>; leaving untouched\n")` + return `[:]` without writing. Only auto-migrate when legacy files exist and main store absent.

Verification (P0): `make vscode-ui-resizer`; run each command with AX revoked (expect exit 2 + clear message); feed corrupt `config.json` (expect no overwrite); `rg -n 'as!|try!|frontApp!' vscode-ui-resizer/` returns empty.

### P1 — Correctness

**P1-a. Fingerprint v2 (`displayFingerprint:298-352`, `resolveGlobalPosition:130-145`, `describeScreen:283-294`).**

- Store per screen: `originPt`, `sizePt`, `sizePx`, `scale (px/pt)`, `rotation`, `name`, `isMain` (via `CGDisplayIsMain`), `displayID`.
- Fingerprint string v2: keep human-readable lines but derive from points + scale, e.g. `[x,y] PTxPTH @Nx (rot° name*)`. Keep `describeScreen`/`resolveGlobalPosition` on `CGRect` values, not formatted strings: new `ScreenRef { id, framePt }`, match by `displayID` first, then by `framePt` equality within 1pt, then fallback.
- Migration: `loadConfigStore` reads v2 key, else tries legacy v1 string key, else single-entry fallback. New saves write v2 only. Log `migrated fingerprint v1 -> v2` once.
- Fix `screen == mainScreen` → `screen.localizedName` + `CGDisplayIsMain(screenNumber)` or first-screen convention documented in one place.
- Fix off-screen double-offset: `describeScreen` returns `ScreenRef?`; `resolveGlobalPosition` returns `CGPoint?` (nil when off-screen); callers handle nil explicitly (see P1-b).

**P1-b. Never place off-screen (`cmdRestoreWin:1042-1048`, Vivaldi `:1907-1909`, other `:2185-2187`).**

- New helper:
  ```swift
  func clampToVisible(_ pt: CGPoint, size: CGSize) -> CGPoint
  ```
  Uses `NSScreen.screens` visible frames; if neither resolved nor fallback is on-screen, clamp fallback into main screen with 50px margin. Always log which branch was taken (`matched screen / raw coords / clamped to main`).
- Replace `globalPos != resolvedPos` heuristic with explicit enum `PositionSource { matched, rawFallback, clamped }`.

**P1-c. Multi-window save/restore semantics (see decision table).**

- Default proposal: `DisplayConfig` gains `windows: [WindowInfo]?` (keep `window` as legacy alias for one release).
  - `cmdSaveWin` saves **all** current VS Code windows (ordered, with titles), not just frontmost. Log count.
  - `cmdRestoreWin` matches by `normalizedTitle` first; unmatched windows get positional fallback only if counts equal; otherwise left in place with log. Removes N-windows-stack-onto-one-rect behavior.
  - If reviewer prefers minimal change: keep single save, restore only to title-matched window. Either way the stacking loop goes away.
- Same question applies to Vivaldi (`findVivaldiWindows` loop) — apply same rule.

**P1-d. `otherWindows` title matching (`:2059-2204`).**

- On save: keep `AXWindows` order but also record title + size as match keys.
- On restore: for each saved window, find current window with same normalized title; if exactly one match, apply; if zero/multiple, fall back to index among still-unmatched windows. Log `matched by title` vs `positional fallback` per window. Extras handling unchanged.
- Keep `pid: 0` (do not store pid — unstable). Document in README.

**P1-e. Safe zoom write (`writeZoomLevelToUserSettings:932-958`).**

- Steps: (1) backup `settings.json` to `settings.json.bak-<timestamp>`; (2) strip `//` + `/* */` comments + trailing commas for parsing only; (3) `JSONSerialization` decode to dict; (4) set `window.zoomLevel`; (5) re-read original text and apply minimal textual replacement of that one key via range search on the decoded value's line, else append key; (6) re-parse result to validate; on any failure restore backup + exit 1. Never write on validation failure.
- Alternative if reviewer wants smaller diff: write sibling temp file + `diff` preview + prompt? No — CLI must stay non-interactive; backup + validate is the floor.

**P1-f. CDP request IDs + parsing (`wsSend:611-632`, `evalJS:634-653`, `wsRecv:598-609`).**

- New `CdpSession` (class, one per websocket):
  ```swift
  final class CdpSession {
      private var nextId = 1
      func send(method: String, params: [String: Any]) -> [String: Any]?
      func evaluate(_ js: String) -> String  // wraps Runtime.evaluate, returnByValue+awaitPromise
  }
  ```
  Monotonic IDs, JSON parse + `id ==` check (no substring), single 5s timeout per request, drain-and-ignore non-matching events (e.g. `Page.*`) up to N, then timeout. `evalJS` becomes a method; global `id: 99` / `id: 0,200,301` constants removed.
- `wsRecv` timeout stays 5s but returns `nil` (not `""`) on timeout; callers distinguish timeout from empty string.
- `tryFetchTargets` / `tryFetchCodeServerTargets` / `tryFetchVivaldiWindowTargets`: check HTTP status == 200 + log body snippet on JSON failure at `--verbose` (new flag, see P2).

Verification (P1): multi-monitor re-arrange test (expect `matched` vs `clamped` logs, window visible); Retina vs non-Retina fingerprint stability (disconnect/reconnect, expect same key); corrupt-settings test (expect backup + abort, original untouched); 3-window VS Code save/restore (expect per-title match, no stacking); CDP port closed (expect clean error, no 500-loop hang — time it).

### P2 — Robustness

**P2-a. Exit-code contract (`cmdSaveAll:2247-2272`, `cmdRestoreAll:2276-2306`, all `cmd*`).**

- Convention: `0` ok, `1` operation failed, `2` precondition/environment (AX denied, CDP unreachable, corrupt config). Every `cmd*` returns `Int32` instead of `exit()`-ing deep inside; `main` exits once. Skips that today `return` become `return 1` with stderr reason, except "nothing to do because app not frontmost" stays `0`? Decide per command and document in `usage()` + README table. `save-all`/`restore-all` aggregate with `anyFailed` and print per-stage `OK/FAILED/SKIPPED`.
- Requires changing `runSubCommand` model (see P2-b).

**P2-b. In-process `save-all` / `restore-all` (`runSubCommand:2208-2216`).**

- Replace subprocess re-exec (`CommandLine.arguments[0]` + args) with direct function calls `cmdSaveLayout(port:)` etc. returning status. Removes symlink/CWD fragility, halves process spawn, fixes load-modify-write interleaving visibility.
- If subprocess model must stay (isolation), at minimum: resolve exe via `Bundle.main.executableURL` + `resolvingSymlinksInPath`, check `proc.run()` errors, capture + forward exit codes.

**P2-c. `repoRoot` + node tool hardening (`:2218-2245`).**

- Search order: exe-dir → exe-parent → git root (`git rev-parse --show-toplevel` with timeout) — never CWD first. Verify `tools/vivaldi-title-split.mjs` exists + is a file (not dir/symlink escape). Log resolved path at `--verbose`. Pin `node` lookup via `PATH`, report version on failure.

**P2-d. AX return codes + sash fallback (`applyWindowGeometry:233-279`, `restoreLayoutWindow:1436-1444`).**

- Check `AXUIElementSetAttributeValue` == `.success`; on failure log `AXError` raw value, skip retries early for `.notAllowed` / `.invalidUIElement`.
- Sash mapping miss (`seIdx/epIdx == nil`): **abort window with clear message** (`panel is collapsed — expand panel first` already exists for one case; extend to all) instead of guessing `0`/`1`. Add `--force-sash-guess` only if reviewer wants the old behavior behind a flag (default off).

**P2-e. Logging parity.**

- Add global `--verbose` flag (default quiet): stage timings (`stageLog` already exists), CDP bodies, AX errors only under verbose. Keeps current default output stable for scripts.

Verification (P2): `save-all` with CDP down → non-zero exit + per-stage table; `restore-windows` with app quit → `SKIPPED`, exit 1 (or 0 per convention doc); collapsed-panel restore → abort message, no sash drag; `repoRoot` from foreign CWD → still finds tool or clean error.

### P3 — Maintainability (file split + dedupe)

Proposed layout (all under `vscode-ui-resizer/`, compiled by `swiftc -o .../*.swift`):

```
vscode-ui-resizer/
  main.swift            # arg parsing, usage(), exit-code aggregation only
  ConfigStore.swift     # WindowInfo, LayoutConfig, VivaldiConfig, DisplayConfig, load/save, migration, fingerprint v1/v2
  Screens.swift         # describeScreen, resolveGlobalPosition, displayFingerprint, clampToVisible, PositionSource
  AX.swift              # applyAXTimeout, axGet*/axSet*, isFullScreen/exitFullScreen, applyWindowGeometry, checkAXTrust, find*Windows
  CDP.swift             # httpGetJSON, tryFetch*Targets, CdpSession, evalJS, cdpSendMethod, bringTabToFront
  VSCodeLayout.swift    # readLayoutFromTab, readCurrent, sash mapping/drag, restoreLayoutWindow, save/restore layout + win + codeserver
  Vivaldi.swift         # tab bar state/resize, zoom, tab numbers, save/restore vivaldi
  OtherWindows.swift    # findOtherApps, save/restore windows
  Orchestration.swift   # save-all/restore-all, runNodeTool/repoRoot, list-displays, shared lookup helpers
```

- `Makefile` change:
  ```make
  vscode-ui-resizer/vscode-ui-resizer.exe: vscode-ui-resizer/*.swift
  	swiftc -o vscode-ui-resizer/vscode-ui-resizer.exe vscode-ui-resizer/*.swift
  ```
- Dedupe in the same pass:
  - One `findFrontmostWindow(matching: [String]) -> (win, title, pid)?`; VS Code + Vivaldi wrappers.
  - One `loadDisplayEntry(for fingerprint:) -> (entry, source)` handling v2 → v1 → single-entry fallback + logging; all 7 restore paths call it.
  - One `normalizedTitle(_:)` handling all known suffixes (`Exploration`, `Insiders`, `OSS`, bare) + table-driven, not chained replaces.
- `README.md`: update build line (glob), exit-code table, fingerprint v2 note, title-matching note for `otherWindows`.

Verification (P3): `make clean && make vscode-ui-resizer`; `rg -n '^func cmd' vscode-ui-resizer/` shows even distribution; no behavior change — full save-all/restore-all cycle diffs clean against pre-split binary (same config keys modulo fingerprint migration).

### P4 — Concurrency / hygiene

- Replace GCD + `NSLock` + captured `var` (`:1609-1633`, `:1775-1794`) with structured approach that satisfies Swift 6: either `DispatchQueue.concurrentPerform` with lock-protected final collection built from `Sendable` box, or `async/await` + `withTaskGroup`. Smallest diff: wrap results in `final class Box: @unchecked Sendable`.
- `httpGetJSON`: return `(status, json?, error?)`, enforce `timeout + 1` total via `URLSession` config (not semaphore + `cancel()`), surface `ECONNREFUSED` distinctly for "CDP down" messaging.
- `isDevHostProcess`: cache `ps` output per invocation (one `ps -ax -o pid=,command=` call, parse once, reuse for all VS Code pids) instead of one process per window.
- Add `swiftc -warnings` cleanliness: no `var` mutation warnings, no deprecated API.

Verification (P4): build with `-strict-concurrency=complete` (or Xcode 16 default) with zero warnings; CDP-down path returns in <5s; `save-layout` with 5 windows shows single `ps` invocation (instrument or `dtruss`-free timing check).

## Files touched (summary)

- `vscode-ui-resizer/*.swift` — split from single file (P3); all logic changes above land in the named modules.
- `Makefile` — one-line glob change (P3).
- `README.md` — Usage exit codes, build line, `otherWindows` title-matching, fingerprint v2 note.
- `docs/plans/2026/09/04/2026-09-04-vscode-ui-resizer-revamp.md` — this doc.
- Explicitly untouched: `tools/*`, `_refs/*`, `exp/*`, legacy `~/.config/vscode/*` migration sources.

## Verification (end-to-end acceptance)

1. `make clean && make vscode-ui-resizer` — zero warnings under strict concurrency.
2. Corrupt `config.json` → clean stderr, no overwrite, exit 2.
3. AX revoked → exit 2 with Settings hint on every AX path.
4. Single + triple monitor: save → rearrange → restore → all windows visible, logs show `matched`/`clamped` correctly.
5. 3 VS Code windows with distinct titles: save → scramble → restore → each returns to its own rect (no stacking).
6. Other apps (Finder, Terminal, Notes): save → scramble → restore → title-matched; quit one app → `SKIPPED`, rest OK.
7. Collapsed panel → restore aborts with "expand panel first", no sash drag.
8. `settings.json` with comments: zoom restore preserves comments (or aborts with backup intact — per P1-e outcome), backup file exists.
9. CDP down: every CDP command fails fast (<6s) with "cannot reach … port N", `save-all`/`restore-all` exit non-zero with per-stage table.
10. Pre/post split parity: same display setup, `save-all` output + `config.json` keys identical except fingerprint v2 addition.

## Rollout order

1. P0 alone (safe, reviewable, shippable).
2. P1-a + P1-b (fingerprint + clamp) together — they touch the same helpers.
3. P1-c + P1-d (matching semantics) — needs decision-table sign-off first.
4. P1-e + P1-f (zoom + CDP) — independent, either order.
5. P2 (exit codes + in-process orchestration) — changes scripting behavior, announce.
6. P3 (split) — mechanical, after logic settles to avoid merge churn.
7. P4 (concurrency) — last, needs strict-concurrency build flag on.

## Risks

- Fingerprint v2 orphans old keys if migration misses an alias — mitigated by dual-read + single-entry fallback + logging.
- Title matching can mismatch duplicate titles (two identical VS Code windows) — falls back to positional among ties, logged.
- Minimal-textual zoom edit may still fail on exotic `settings.json` layouts — fails closed (backup + abort), never writes partial JSON.
- In-process `save-all` changes crash isolation (one stage crash kills all) — mitigated by per-stage `do/catch` + status aggregation; subprocess mode kept as fallback if reviewer insists.

## Open questions for reviewer

1. Swiftc-glob vs SwiftPM?
2. Multi-window save: full list vs single + title-matched restore?
3. `otherWindows` title-first matching acceptable, or keep pure positional?
4. Exit-code convention: is breaking `save-all` exit 0-on-skip acceptable, or must skips stay 0?
5. Keep subprocess `save-all` isolation or go in-process?
6. Fingerprint v2 dual-read window: one release or permanent legacy alias?
