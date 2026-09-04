# 2026-09-04: Restored Windows Land on Wrong Display / Refuse to Resize (geometry round-trip)

**Status:** CLOSED — fixed in `vscode-ui-resizer/` (`Screens.swift`, `ConfigStore.swift`, `AX.swift`, `Vivaldi.swift`). See [README § How it works](../../../../../../README.md#how-it-works).

## Summary

`save-all` → `restore-all` did not put windows back. One user-visible symptom, three distinct defects found by probing live windows against `~/.config/vscode-cdp-automator/config.json`:

1. Ghostty / Gemini / Tailscale saved with `"screenFrame": "off-screen"` while visibly on-screen; restore moved them to the main display.
2. Vivaldi's 3240×1889 3-display span restored stuck at 1080×1920 on one display (position correct, width frozen).
3. From a maximized (display-filling) start state, restore changed nothing at all — every `AXSize` set silently dropped.

## Repro

Display set: 5 displays, v2 fingerprint `[-1080,0] EINK (1) / [0,0] EINK (4)* / [683,-1080] EINK (3) / [1080,0] EINK (2) / [2160,269] LG ULTRAFINE`.

1. Arrange Ghostty on LG, Vivaldi spanning EINK 1+4+2 (`-1080,31 3240x1889`).
2. `save-all` from a GUI terminal.
3. Maximize Vivaldi on a single monitor (or reboot to single-screen-sized windows).
4. `restore-all` / `restore-vivaldi` / `restore-windows`.

**Expected:** every window returns to saved pos/size.
**Actual:** Ghostty/Tailscale land on main; Vivaldi stays 1080 wide; from maximized, nothing moves (`[RETRY]` → `FAILED`).

## Root Cause

### A. Save side: `describeScreen` tested only the top-left point (`Screens.swift`)

```swift
if screen.frame.contains(point) { ... }
return ("off-screen", ...)
```

`CGRect.contains` excludes the max edge, and the AX top-left point of a real window can sit just outside its display: Ghostty/Tailscale at y=242 vs LG starting at y=269 (27px menu-bar gap), Gemini at y=1920 exactly on EINK(2)'s exclusive bottom edge. All three saved as `off-screen` with raw coords as the relative offset — unrecoverable on restore.

### B. Restore side: `resolveAndClamp` rejected near-misses, clamped to main (`ConfigStore.swift`)

Even with a correct `screenFrame` stored, the resolved point (e.g. LG origin + rel `(1,-27)` = `(2161,242)`) failed the same strict `contains()` check, fell through to `clampToVisible` — which clamps into the **main** display, not the matched one. Right frame in, wrong display out.

### C. Apply side: large `AXSize` jumps ignored; fill state snaps back (`AX.swift`)

Probed live against the Vivaldi window (AX returns success in all cases — the drops are silent):

| request (from) | result | note |
|---|---|---|
| `{2000,1889}` from `1080x1920` fill | unchanged | width jump +920 dropped |
| `{800,1000}` from `1080x1920` fill | `1080x1000` | height applied, width −280 dropped |
| `{1079,1000}` from `1080x1000` | applied | tiny delta ok once unfilled |
| `+50…+500` walks from unfilled | all applied | up to full `3240` span |
| 6× `+360` steps from `1080x1920` fill | all dropped | step size irrelevant while filling |
| `{1080,1889}` (Δ31) from fill | snapped back to `1920` | small deviation reverts |
| `{1080,1000}` (Δ920) from fill | sticks | large change escapes fill |

So: (1) width jumps of ~800px+ are dropped even unfilled, (2) a display-filling window (both dims ≈ display size) snaps deviations back unless the change is large. The old code did one-shot pos+size with 3–5 identical retries — the same failing operation, converging never. Manual pre-spanning "fixed" it only by shrinking the delta.

## Fix

All in `vscode-ui-resizer/`, all verified live (see Verification):

**1. Size-aware `describeScreen` (`Screens.swift`)** — signature `describeScreen(containing:size:)`, all three callers (`OtherWindows.swift`, `VSCodeLayout.swift` `makeWindowInfo`, `Vivaldi.swift` `cmdSaveVivaldi`) pass the window size. Falls through exact hit → largest window-rect overlap → nearest screen by edge distance (`edgeDistance`). `"off-screen"` is now returned only when there are no displays at all, so restore always has a frame to match.

**2. Tolerant `resolveAndClamp` (`ConfigStore.swift`)** — new `screenMatchingFrame()` helper. When the fingerprint matched, points within 60px of the matched screen (or whose window rect overlaps it) are accepted as-is; a genuinely-off point clamps into the **matched** screen's visible frame instead of main. Unmatched/legacy path unchanged.

**3. Break-fill + ≤400px stepped resize in `applyWindowGeometry` (`AX.swift`)** — shared by every restore path (VS Code, Vivaldi, other-windows), so all apps benefit. Before the retry loop: if current size matches its display on both axes (±60px), drop height by 900px (min 400) to escape fill. Then walk size in ≤400px steps with 0.1s settle each; no interleaved position sets (unverified, dropped in favor of the probed recipe).

**4. Vivaldi retry budget (`Vivaldi.swift`)** — `restore-vivaldi` used 3 attempts at 0.1s/0.15s while everything else uses 5; bumped to 5 attempts at 0.15s/0.25s to give the stepped walk settle time.

## Verification

- Ghostty re-save now stores `screenFrame: x=2160 y=269 2560x1440` (LG), rel `(1,-27)` — no more `off-screen`.
- Tolerance simulation over the 5-display layout: Ghostty→LG, Tailscale→LG, Gemini→EINK(2), all accepted as matched.
- Live from maximized fill: break-fill `1080x1920 → 1080x989`, then `#1: pos=(-1080,31) size=3240x1889 [OK]` — converged on the first attempt; `make vscode-ui-resizer` clean.
- `save-all` from a GUI-less session still skips AX-dependent stages without clobbering stored `otherWindows` (separate environment limitation, not this bug).

## Impact

- Any maximized window on any app could previously never be restored (defect C); any window saved from an edge coordinate restored to the wrong display (defects A+B). All three fixes are in shared code, no per-app special-casing, no config migration (old `off-screen` entries still restore via the fallback path, just less precisely).
- Side effect: restores of maximized windows briefly flicker (shrink then regrow) — inherent to the break-fill recipe.

## Lesson

Never trust a single AX read-back dimension as "the window moved": `AXSize`/`AXPosition` sets return success even when silently dropped or snapped back — only the read-back tells the truth, and width/height can fail independently. And never classify a window's display by one corner point: probe the rect (overlap), then the nearest display, and on restore trust a fingerprint-matched coordinate within tolerance instead of re-validating it with a stricter test than the save path used.
