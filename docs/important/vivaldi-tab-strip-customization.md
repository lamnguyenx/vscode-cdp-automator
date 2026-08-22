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
- Progress dash: hide `progress` (`display:none`), otherwise visible as strikethrough in taller tabs (`absolute y369 h2`).
- Observer pitfall: `new MutationObserver(apply).observe(strip,{childList:true,subtree:true})` where `apply` does `t.innerHTML=...` inside `strip` subtree → infinite loop → browser freeze (`Runtime.evaluate` timeout, required `Page.reload` + `Target.closeTarget`).

Safe (current): `childList+subtree+characterData` with disconnect/re-observe + `setInterval 800` fallback + `setProperty(...,'important')`:

```js
let debounce;
const debounced = ()=>{clearTimeout(debounce); debounce=setTimeout(()=>{
  observer.disconnect(); applyTabSplit();
  observer.observe(strip,{childList:true,subtree:true,characterData:true});
},300)};
new MutationObserver(debounced).observe(strip,{childList:true,subtree:true,characterData:true});
setInterval(applyTabSplit,800);
newTabBtn.addEventListener('click',()=>setTimeout(applyTabSplit,300));
```

## Domain Grouping with Gaps

- Group key: `txt.split(' - ')[0]` → ` APPLE`/`🌲PP`/`🍊 NUC`/`blank`. `GAP=16` (`<38`).
- `PositionY = idx*38 + gapsBefore*16` (`!important`), `tab-gap` fake blank `div` (`h16, top = idx*38+offset-16, border-bottom:1px white`) inserted at each `group[i]!==group[i-1]` (cleared each run). `tab-position` gets `tab-group-end` for `::after` alternative (now unused, kept for `overflow:visible`).
- `resize.max-height = n*39 + totalGaps*16` (tight, `1px` border per tab). `1px` CSS → `0.606px` computed at UI zoom `1.6` (`1/1.65`), matches tab default; `1.6px` gives `1px` on screen.
- Example `9` tabs `APPLE3,PP5,NUC1` → `2` gaps at `114`/`320` `h16` as `tab-gap` fake tabs.

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
