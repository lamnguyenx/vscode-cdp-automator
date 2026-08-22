# Customizing Vivaldi's Tab Strip (Height, Centering, Numbering)

Tested on **Vivaldi 8.1.4087.64** (Chromium 150, macOS) via `window.html` CDP target (`mpognobbkildjkofajifpdfhcoklimli`).

Companion to `changing-vivaldi-vertical-tab-bar-size.md`, `changing-vivaldi-zoom.md`, `vivaldi-general-quirks.md`.

## Layout

```
#tabs-container.left
 ├─ .toolbar.toolbar-tabbar-before
 ├─ .resize[style="max-height: n*32px"]  ← set by Vivaldi JS from tab count
 │   └─ .tab-strip > SPAN* > .tab-position[style="--Height:31px; --PositionY:N*31px"]
 │        └─ .tab-wrapper (max-height: calc(var(--Height) - densityGap))
 │            └─ .tab (flex 1 1 0%, flex-flow:column, stretches to wrapper)
 │                └─ .tab-header (flex row, align-items:center) → progress, favicon, .title
 └─ .toolbar.toolbar-tabbar-after (flex filler, .newtab button at top)
```

- `--Height`/`--PositionY` are per-position inline vars. `.tab-position { height:var(--Height); transform:translateY(var(--PositionY)) }`.
- Absolute positioning: strip children don't contribute to parent height → `.resize` max-height must be set explicitly.
- `progress.page-progress-indicator` is `absolute y~370 h2` inside `.tab-header`; visible on blank pages as a dash.

## Making Tabs Taller but Vertically Centered

1. Override heights via CSS `!important` (beats inline):

```css
.tab-strip .tab-position { --Height: 38px !important; }
.tab-strip > span:nth-child(1) .tab-position { --PositionY: 0px !important; }
.tab-strip > span:nth-child(2) .tab-position { --PositionY: 38px !important; }
/* ... up to 50 */
```

Why `> SPAN:nth-child`? `.tab-position` is not direct child of `.tab-strip`; React wraps each in a `SPAN`.

2. Center content: `.tab` is column flex with single child `.tab-header`. Add:

```css
.tab-position .tab { justify-content: center !important; }
```

Result `37.35` (38 - densityGap) centered diff `0.01` vs `27.3`.

3. Tighten container one-shot (no `max-height:none` — that makes `resize`/`strip` `1075px` and `toolbar` collapses to `3px y1113`):

```js
const n = document.querySelectorAll('.tab-strip .tab-position').length;
document.querySelector('.tab-strip').parentElement.style.setProperty('max-height', (n * (38+1)) + 'px');
```

## Numbering & Splitting Without Hanging

- Number gap: `.tab-number { margin-right:0 }` (`1. ` → `1.`).
- Progress dash: hide `progress` (`display:none`), otherwise visible as strikethrough in taller tabs.
- Observer pitfall: `new MutationObserver(apply).observe(strip,{childList:true,subtree:true})` where `apply` does `t.innerHTML=...` inside `strip` subtree → infinite loop → browser freeze (`Runtime.evaluate` timeout, required `Page.reload`).

Safe:

```js
new MutationObserver(apply).observe(strip,{childList:true}); // not subtree
newTabBtn.addEventListener('click',()=>setTimeout(apply,300));
```

`childList` on `strip` catches new `SPAN` wrappers; title writes inside don't re-trigger.

## Tool

`tools/vivaldi-title-split.mjs` injects `HEIGHT_CSS` (50 nth-child rules) + `STYLE` (hide favicon/audio/progress, center, number) + one-shot split/number/tighten + safe observer.

```bash
node tools/vivaldi-title-split.mjs on   # 38px, centered, 1.APPLE, no progress, auto on +
node tools/vivaldi-title-split.mjs off  # restores titles, clears observer/resize
```

## Gotchas

- Inline `max-height` on `.resize` is stale after new tabs → scrollbar `304>287` even though space ample. Re-tighten or re-run `on`.
- `tab-wrapper` max-height follows `--Height`; no extra override needed.
- CSS `!important` on custom props beats inline without `!important` — use for reactive heights.
