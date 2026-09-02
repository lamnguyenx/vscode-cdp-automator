# 2026-09-02: Stale `--ttxt` Color Snapshot Makes Tab Text Invisible After Activation Change

**Status:** CLOSED — fixed in `tools/vivaldi-title-split.mjs` (pseudo-element `color: inherit` replaces snapshot)

## Summary

After running `vivaldi-title-split.mjs on`, clicking a different tab leaves the previously-active tab's custom-rendered title text invisible: black text stays black on its now-dark inactive background, and the newly-active tab's white text stays white on its now-light active background. The original built-in Vivaldi title (hidden via `font-size:0`) keeps the correct color and tracks the active state live — only our replacement rendering breaks.

## Repro

1. `CDP_PORT=9023 node tools/vivaldi-title-split.mjs on`
2. Click tab A (becomes active, light bg, black text — correct)
3. Click tab B

**Expected:** tab A goes inactive (dark bg) → its title color flips back to white automatically; tab B goes active → its title flips to black.
**Actual:** tab A's title stays black on the dark inactive bg → invisible. Tab B's title stays white on the light active bg → invisible.

User's specific settings at the time: Vivaldi theme configured so active tab = light bg + auto-black text, inactive tab = dark bg + auto-white text. Reproducible on the default theme too.

## Root Cause

The `apply` loop read the theme text color once and snapshot it as a literal **string literal** into a CSS custom property:

```js
pos.style.setProperty('--ttxt', getComputedStyle(t.closest('.tab') ?? t).color);
```

And the CSS consumed that frozen value:

```css
.title::before { color: var(--ttxt, #e6e6e6); ... }
.title::after  { color: var(--ttxt, #e6e6e6); ... }
```

`--ttxt` thus captured `rgb(0,0,0)` while the tab was active and `rgb(255,255,255)` while inactive — frozen at whatever the tab's state was when `on` last ran. When Vivaldi's own CSS flipped `.tab`'s `color` on activation change, our pseudo-elements kept reading the stale custom property and never followed.

### Evidence

Computed styles immediately after `on` (user reports invisible text on click):

| idx | active | `.tab` bg | `.tab` color | `--ttxt` (frozen) |
|-----|--------|-----------|--------------|-------------------|
| 0   | no     | dark      | `rgb(255,255,255)` | `rgb(255,255,255)` |
| 1   | yes    | light     | `rgb(0,0,0)`       | `rgb(0,0,0)`       |
| 2   | no     | dark      | `rgb(255,255,255)` | `rgb(255,255,255)` |

Clicking a different tab flips `.tab`'s live `color`, but every `--ttxt` value above is a fixed string on `.tab-position.style` and never recomputes. The newly-active tab (say idx 0) keeps its frozen `rgb(255,255,255)` text color against the new light active background → invisible.

## Fix

Two changes, both in `STYLE` / `applyTabSplit`:

**1. Drop `color: transparent` on `.title` and let pseudo-elements inherit:**

```diff
- .title { ... color: transparent !important; font-size: 0 !important; ... }
+ .title { ... font-size: 0 !important; ... }
- .title::before { ... color: var(--ttxt, #e6e6e6); ... }
- .title::after  { ... color: var(--ttxt, #e6e6e6); ... }
+ .title::before { ... color: inherit; ... }
+ .title::after  { ... color: inherit; ... }
```

`::before` / `::after` inherit `color` from `.title`, which inherits from `.tab`, which is exactly the element Vivaldi's theme color logic targets. Result: pseudo-elements track the live theme color automatically.

**2. Stop writing `--ttxt`.** Remove the `pos.style.setProperty('--ttxt', …)` line from the apply loop and the matching `removeProperty('--ttxt')` from the `off` path. Also drop the `--ttxt` fallback default in CSS (no longer referenced).

### Why `font-size:0` alone is enough

The previous version set **both** `color: transparent` and `font-size: 0` on `.title`. The intent was "belt and suspenders" hiding of the framework text node. But `color: transparent` was the culprit: pseudo-elements inherit `color` from the originating element, so `::before { color: inherit }` would have inherited `transparent` (not the theme color from `.tab`) and nothing would have been visible at all.

`font-size: 0` alone fully hides the live text node (zero-height line box, no glyph rendered) while leaving `color` alone to inherit cleanly. Never combine the two and then try to use the element's own inherited color for pseudo-elements — the transparent override short-circuits the inherit chain.

## Verification

After fix:

| idx | active | `.tab` bg | `.title` color (now inherited live) |
|-----|--------|-----------|--------------------------------------|
| 0   | no     | dark      | `rgb(255,255,255)` ✓ |
| 1   | yes    | light     | `rgb(0,0,0)` ✓ |
| 2   | no     | dark      | `rgb(255,255,255)` ✓ |

Clicking different tabs now flips text color in real time with no `on` rerun needed — pure CSS inheritance does the work.

## Impact

- All users of `vivaldi-title-split.mjs` on themes where active/inactive tabs have distinct `color` (default theme included — accent-color active state switches text to a darker shade).
- Single-instance fix; no migration needed (the stale `--ttxt` props left on disk from prior runs are simply ignored once the CSS stops referencing them).
- Reduced per-tab work: one fewer `setProperty` per tab per `on` run.

## Lesson

Snapshotting any color/style into a CSS custom property is a **one-direction lock**: the value freezes the moment it's written. Live values that should follow theme/active/hover state must be obtained through CSS inheritance (`color: inherit`, `currentColor`, `var()` chained to a parent custom prop that the framework updates) — never re-read via `getComputedStyle` on the JS side and re-serialized into another custom prop.
