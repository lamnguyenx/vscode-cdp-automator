# 2026-07-04: Floating-Point Precision Silently Breaks Sash-Part Mapping in restore-layout

**Status:** CLOSED — fixed in `vscode-ui-resizer/vscode-ui-resizer.swift:557-558`

## Summary

`restore-layout` intermittently fails to resize panels in VS Code windows. The `solveSashMapping` function misidentifies which non-disabled sash separates the editor from the panel, mapping it as `sidebar|panel` instead of `editor|panel`. This causes the drag to target the wrong sash — or with the fallback, to work on index 1 which happens to be correct only if no extra sashes from nested horizontal splits precede it.

## Root Cause

`getBoundingClientRect()` returns sub-pixel floating-point values (e.g. `1674.619140625`).

When a sash center (`cx`) and a part’s edge (`.right` / `.left`) are visually on the same pixel boundary, the computed difference:

```
dL = cx - r.right
```

can be a tiny negative number (e.g. `-0.0048828125`) instead of exactly `0`. The condition `dL >= 0` then fails, so the algorithm skips the correct neighbor and picks the next-closest one — in this case, `sidebar` at `dL = 674` instead of `editor` at `dL ≈ -0.005`.

### Evidence

From the `web-live-translator` window via CDP on port 9333:

| Value | Raw float |
|-------|-----------|
| Sash (idx 1, `editor\|panel`) `cx` | `1674.6142578125` |
| Editor `.right` | `1674.619140625` |
| `dL = cx - editor.right` | **`-0.0048828125`** |
| `dL >= 0` | **`false`** |

The sashes list (3 non-disabled) in DOM order:

| ndIdx | cx | Correct mapping | Buggy mapping |
|-------|-----|-----------------|--------------|
| 0 | 1001 | `sidebar\|editor` | `sidebar\|editor` ✓ |
| 1 | 1675 | `editor\|panel` | `sidebar\|panel` ✗ |
| 2 | 2303 | (inside panel, ignored) | `editor\|?` |

## Fix

Changed `dL >= 0` and `dR >= 0` to `dL >= -0.5` and `dR >= -0.5` in `solveSashMapping`’s JS:

```diff
- if (dL >= 0 && dL < bestL) { bestL = dL; leftName = name; }
- if (dR >= 0 && dR < bestR) { bestR = dR; rightName = name; }
+ if (dL >= -0.5 && dL < bestL) { bestL = dL; leftName = name; }
+ if (dR >= -0.5 && dR < bestR) { bestR = dR; rightName = name; }
```

The `-0.5` tolerance catches sub-pixel floating-point artifacts while not affecting legitimate neighbors (which are typically tens or hundreds of pixels away).

## Impact

- All sash types (sidebar, editor, panel, auxiliary bar) are affected whenever two elements share a pixel boundary
- The `sq_sash_map_fallback` (hardcoded `editor_panel = 1`) masked the issue in common layouts, but failed when nested horizontal splits inside the panel added extra non-disabled sashes to the selector result
- `save-layout` was not affected — it reads `.part.*` bounding rects directly without sash mapping

## Verification

After fix, `solveSashMapping` correctly returns:

```json
[
  {"idx": 0, "between": "sidebar|editor", "cx": 1001},
  {"idx": 1, "between": "editor|panel", "cx": 1675},
  {"idx": 2, "between": "editor|?", "cx": 2303}
]
```

And `restore-layout` successfully resizes panels to target widths.
