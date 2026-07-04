# CDP Resize: Simulating Sash Drags to Control VS Code Sidebar & Panel

## Problem

VS Code extensions **cannot** programmatically get or set sidebar/panel pixel sizes. No API exists for this. But when VS Code is launched with `--remote-debugging-port=9333`, Chrome DevTools Protocol (CDP) gives full JavaScript evaluation power in the renderer, and you can simulate mouse drags on the internal `Sash` splitter elements.

## Setup

```bash
code --remote-debugging-port=9333
# Optionally: --enable-smoke-test-driver (registers window.driver, suppresses dialogs)
```

Then connect via CDP WebSocket. The tools use Python's `websockets` library.

## Multiple Windows → Pick the Right Target

When multiple VS Code windows are open, each is a separate CDP target. Query `http://localhost:PORT/json` and filter by `url` ending in `workbench.html`. Present titles to the user and let them pick.

## Sash Drag Mechanics

### DOM Structure

```
.monaco-grid-view
  └── .monaco-split-view2.horizontal (middle section)
        ├── .sash-container
        │     ├── .monaco-sash.vertical (between parts)
        │     ├── .monaco-sash.vertical
        │     └── ...
        └── .split-view-container
              ├── .split-view-view → #workbench.parts.activitybar
              ├── .split-view-view → #workbench.parts.sidebar
              ├── .split-view-view → #workbench.parts.editor
              ├── .split-view-view → #workbench.parts.panel
              └── ...
```

### Sash Event Model

The `Sash` class at `src/vs/base/browser/ui/sash/sash.ts` listens for:

| Event | Target | Purpose |
|-------|--------|---------|
| `mousedown` | `.monaco-sash` element | Starts the drag |
| `mousemove` | `window` (document.defaultView) | Tracks drag position |
| `mouseup` | `window` | Ends the drag |

**Crucial:** You must dispatch `mousedown` on the sash itself, but `mousemove` and `mouseup` on `window`. Use `MouseEvent`, not `PointerEvent`.

### Drag Direction

Sizing is **pixel-based**, not percentage. In a horizontal `SplitView`, views are laid out left-to-right. Dragging sash `i`:

| Drag direction | Effect on view `i` (left) | Effect on view `i+1` (right) |
|---------------|--------------------------|------------------------------|
| RIGHT (+dx) | Grows by dx | Shrinks by dx |
| LEFT (−dx) | Shrinks by dx | Grows by dx |

For our layout (activitybar | sidebar | editor | panel):

```
sash 0: sidebar | editor  ←→  shrink sidebar = drag LEFT;  grow sidebar = drag RIGHT
sash 1: editor  | panel   ←→  shrink panel  = drag RIGHT;  grow panel  = drag LEFT
```

### Identifying Sashes

Use `:not(.disabled)` to skip fixed sashes. Match sashes to parts by finding which part's right edge is closest to the sash's center (left neighbor) and which part's left edge is closest (right neighbor).

### THE BUG: Index Mismatch

Both the "solve mapping" function and the "drag" function must use the **same selector**. If one filters `:not(.disabled)` and the other doesn't, the sash indices won't match and you'll drag the wrong (or disabled) sash — silently failing.

Always use:
```js
document.querySelectorAll(
  '.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical:not(.disabled)'
);
```

### THE BUG: Floating-Point Precision in Sash-Part Mapping

`getBoundingClientRect()` returns sub-pixel floating-point values (e.g. `1674.619140625`). When a sash center (`cx`) and a part edge (`.right` / `.left`) are visually on the same pixel boundary, their computed difference (`dL = cx - r.right` or `dR = r.left - cx`) can be a tiny negative number like `-0.0049`. The `>= 0` check then fails, and the algorithm picks the wrong neighbor (e.g. `sidebar|panel` instead of `editor|panel`).

**Fix:** Add a `-0.5` tolerance:
```js
if (dL >= -0.5 && dL < bestL) { bestL = dL; leftName = name; }
if (dR >= -0.5 && dR < bestR) { bestR = dR; rightName = name; }
```

## CDP Drag JavaScript

```js
(() => {
    const all = document.querySelectorAll(
      '.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical:not(.disabled)'
    );
    const sash = all[sashIndex];
    const b = sash.getBoundingClientRect();
    const cx = b.left + b.width / 2;
    const cy = b.top + b.height / 2;
    const w = document.defaultView;  // window — NOT the sash element

    sash.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, clientX: cx, clientY: cy, button: 0}));
    w.dispatchEvent(new MouseEvent('mousemove', {bubbles: true, clientX: cx + dx, clientY: cy, button: 0}));
    w.dispatchEvent(new MouseEvent('mouseup',   {bubbles: true, clientX: cx + dx, clientY: cy, button: 0}));
})()
```

One `mousemove` jump is enough — no need for stepping (the `SplitView` handles the delta in one frame).

## Part Selectors

| Part | Selector |
|------|----------|
| Sidebar | `.part.sidebar` or `#workbench\.parts\.sidebar` |
| Panel | `.part.panel` or `#workbench\.parts\.panel` |
| Editor | `.part.editor` |
| Activity bar | `.part.activitybar` |
| Panel position | Check classes: `.right`, `.left`, `.bottom`, `.top` |

## Key Files in VS Code Source

| Purpose | File |
|---------|------|
| Layout service (internal) | `src/vs/workbench/services/layout/browser/layoutService.ts` |
| Workbench layout | `src/vs/workbench/browser/layout.ts` |
| Sash component | `src/vs/base/browser/ui/sash/sash.ts` |
| SplitView/GridView | `src/vs/base/browser/ui/grid/grid.ts` |
| Parts enum | `src/vs/workbench/services/layout/browser/layoutService.ts:21` |
| CDP-friendly driver API | `src/vs/workbench/services/driver/common/driver.ts` |

## Limitations

- Sizing is absolute-pixel only; percentage support requires calculating from workbench dimensions
- Panel position (right/left/bottom/top) changes the grid structure — the restore script assumes panel is in the same horizontal split as sidebar/editor (right or left position). Panel in bottom/top position requires targeting a different `.monaco-sash.horizontal` in a nested vertical split.
- VS Code re-lays out on window resize; saved absolute pixel sizes won't adapt
