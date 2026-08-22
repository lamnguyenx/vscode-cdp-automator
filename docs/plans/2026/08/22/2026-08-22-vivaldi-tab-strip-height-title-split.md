# Vivaldi Tab Strip Customization — Height, Centering & Auto-Trigger

Date: 2026-08-22  
Tool: `tools/vivaldi-title-split.mjs`  
Vivaldi 8.1.4087.64 / Chromium 150 / `--remote-debugging-port=9222` / `window.html` (`mpognobbkildjkofajifpdfhcoklimli`)

## Context

`vivaldi-title-split.mjs` injects CSS+JS into Vivaldi's chrome (`window.html` CDP target) to:
- number tabs `1. …`
- split titles on ` - ` into `tab-main-title` + `tab-subtitle`
- hide favicons/audio.

Request chain (same session):

1. “tab a bit higher but content still vertically centered” (vertical tab bar `tabs-left`)
2. “no space between number and 1st split: `1.  APPLE` → `1.APPLE`”
3. After `+` new tab: scrollbar appeared though space ample, “Blank Page” tooltip overlayed, `1.` numbering stale until manual re-run.
4. After adding observer: browser froze (`subtree:true` loop).
5. After removing observer: new-tab button hidden at `y1113`.
6. After `fucking around` (12 tabs): dashes on `9./10. Blank Page` — stray `progress` bar.

## Key Discovery: Tab Strip Layout

```
#tabs-container.left [--spacerRows]
 ├─ .toolbar.toolbar-tabbar-before (h3)
 ├─ .resize (flex, inline max-height: n*32, contains tab-strip)  ← Vivaldi JS sets inline from tab count
 │   └─ .tab-strip > SPAN* > .tab-position[style="--Height:31px; --PositionY:N*31px"] (absolute, transform: translateY(var(--PositionY)), height:var(--Height))
 │        └─ .tab-wrapper (flex row, max-height: calc(var(--Height)-densityGap) → 30.35)
 │            └─ .tab (flex 1 1 0%, flex-flow:column, height:auto → stretches to wrapper)
 │                └─ .tab-header (flex row, align-items:center, h27.3) → .title (+ .favicon, progress, audio)
 └─ .toolbar.toolbar-tabbar-after (flex:1 filler, h688 when resize tight, contains .newtab button at y=resize.bottom)
```

- `--Height`/`--PositionY` are per-position inline styles from React. `height:var(--Height)` on `.tab-position`.
- `.tab-wrapper` max-height derives from `--Height` (`calc(31-0.65)=30.35`).
- `.tab` is `flex:1 1 0%` column inside wrapper → stretches to wrapper height.
- `.resize` max-height is `n * (31+1 border)` = `312` for 8, `287` for 9 — set by Vivaldi JS on tab count changes.

## Trials & Errors

### 1. Padding on `.tab` (failed)

```css
.tab-position .tab { padding:6px 0 !important; }
.tab-wrapper { max-height:none !important; }
```

Title `y` moved `+6` but `tab`/`wrapper` stayed `30.35px` (flex stretch capped by `--Height` 31). Content overflowed `overflow:visible`. `tab` is not `height:auto` content-sized when parent is absolute+flex — heights are driven by `--Height`.

### 2. Bumping `--Height`/`--PositionY` inline (partial)

Set `pos.style.setProperty('--Height','38px')` + `PositionY=i*38`. Tab grew to `37.35` (38-0.65), `strip` stayed `256` (old `max-height:287` inline for 9 tabs). New 9th tab kept `31/248` (stale) → overlapped `7@228`, `8@266` → scrollbar `scrollHeight 304 > client 287` → vertical scrollbar + “Blank Page” tooltip at `y248` overlaying.

Also needed `strip`/`resize` height to match.

### 3. `justify-content:center` for centering (success)

`.tab` is column flex with single child `.tab-header` (27.3). With `height:37.35`, `justify-content:center` gives perfect center:
`tab center 56.51 vs header 56.50 diff 0.01`.

Without it, title stayed `y37.83` top-aligned (`diff 5px`).

### 4. `margin-right:0` on `.tab-number` (success)

`.tab-number { margin-right:5px → 0 }` removed gap `1. ` → `1.` (internal ` APPLE` space preserved from `first`).

### 5. `MutationObserver` with `subtree:true` → freeze

```js
new MutationObserver(apply).observe(strip,{childList:true,subtree:true})
```

`apply` does `t.innerHTML = num+...` inside `title` (subtree of `strip`). Observer fired on its own writes → infinite loop, main thread blocked. `Runtime.evaluate` timed out, `DOM.getDocument` timed out. Recovered via `Page.reload` (window.html reloaded) then `Target.closeTarget` (window detached `attached:false`). Required `pkill Vivaldi; open -a Vivaldi --args --remote-debugging-port=9222`.

**Lesson:** never observe `subtree` when mutating descendants. Observe only `childList` on `strip` (SPAN wrappers added).

### 6. `max-height:none` → toolbar hidden (failed)

`HEIGHT_CSS += "#tabs-container .resize { max-height:none !important; }"` made `resize`/`strip` `1075px` (full window), `toolbar` collapsed to `h3 y1113` (button off-screen). New-tab button appeared “fucked”.

**Fix:** keep `resize` tight: one-shot `resize.style.setProperty('max-height', n*(NEW_H+1))` (`390` for 10). CSS keeps positions, JS tightens container. Re-tighten on new tabs.

### 7. `progress` dash on blank pages (failed)

After height bump, `progress.page-progress-indicator` (`absolute y369.9 h2 w98`) left visible just below centered title (`y353.2 h14.2`). Showed as strikethrough on `9./10.` only (blank `value=100`).

**Fix:** ` .page-progress-indicator { display:none !important; }` in `STYLE`.

### 8. New-tab auto-trigger (observer debounce)

User: “have to run `on` again after `+`”. Added safe observer:

```js
const applyTabSplit = () => { /* split, number, resize tight */ };
window._tabSplitObserver = new MutationObserver(applyTabSplit);
observer.observe(strip,{childList:true}); // not subtree
newTabBtn.addEventListener('click',()=>setTimeout(applyTabSplit,300));
```

`subtree:true` had frozen (`1. reverted`), `childList` only avoids loop. Still needed `!important` on `--PositionY` and debounce.

### 9. Domain grouping with vertical gap (8→16)

User: group by domain (` APPLE`/`🌲PP`/`🍊 NUC`/`blank` via `txt.split(' - ')[0]`). Added `GAP=8→16`:

```js
const getGroup = txt => !txt||txt.trim()==='Blank Page'?'blank':txt.split(' - ')[0].trim();
let offset=0, prev=null, totalGaps=0;
const groups = positions.map(p=>getGroup(p.querySelector('.title').dataset.origTitle||p.textContent));
positions.forEach((pos,idx)=>{
  if(idx>0 && groups[idx]!==prev) { offset+=16; totalGaps++; }
  pos.style.setProperty('--PositionY', (idx*38+offset)+'px','important');
});
resize.max-height = n*39 + totalGaps*16;
```

Result `9` tabs `0,38,76,130(+8),160,198,236,274,320,366` (`2` gaps).

### 10. Gap border & fake blank tab (user: “gap has border :)” → “just add fake blank tab”)

- First tried `tab-group-end::after { bottom:-8px; 1px white }` — looked “sucks” (double border, 0.6px due to zoom).
- Switched to fake `div.tab-gap` (`position:absolute; height:GAP; border-bottom:1px white`) inserted at `top = idx*38+offset-GAP` for each boundary, cleared on each run. Looks like small blank tab, `8<38`.
- Final gap `16` with `border-bottom:1px white` (reverted from `1.6px` after “oh fuck, undo to 1px” — `1.6` was `1.6/1.65=1px` on screen at UI zoom `1.6`, but user preferred `1px` CSS `0.606px` computed, matching tab default).

### 11. Observer with domain gaps still hanging

New gap logic + `subtree:true` with `1.6px` borders caused new tab at `y341` vs expected `404` (Vivaldi `13*31`). Root: observer set `important` but Vivaldi re-render overwrote after 60ms. Fixed with `setProperty(...,'important')` + debounce `60→300` + `setInterval 800` fallback + `> SPAN:nth-child` CSS removed (now pure JS `important`).

## Final Solution (pure HTML/CSS/JS, no hanging observer)

`tools/vivaldi-title-split.mjs` (`git diff --cached`):

- `NEW_H=38, GAP=16`, `HEIGHT_CSS` only `--Height:38px !important` (positions now JS `important` with gaps).
- `STYLE` hides `favicon, tab-audio, page-progress-indicator`; `tab { justify-content:center }`; `tab-number margin-right:0`; `.tab-gap { position:absolute; height:16; border-bottom:1px white }`.
- `on`: injects style, `applyTabSplit` does: clear old gaps/classes → compute `groups` → set `--PositionY` with `offset`+`important` + `tab-gap` divs at gaps + split/number (visibleIdx) + `resize.max-height = n*39+totalGaps*16` + `MutationObserver` (`childList+subtree+characterData` debounced `300` with disconnect/re-observe + `setInterval 800`) + `newtab` click.
- `off`: removes style, disconnects observer+interval, clears `--PositionY`/`tab-gap`/`tab-group-end`, restores titles, clears `resize`.

Result (live `2F408BE7` `9` tabs):
- `tab 37.35` centered `0.01`, `strip 383` (`9*39+2*16`), gaps at `114/h16` and `320/h16` as `tab-gap` fake tabs with `1px white` border matching tab default (computed `0.606` at UI zoom `1.6`).
- `1.APPLE` no number gap, `progress` gone, `+` auto-numbers via observer+interval.

## Follow-ups

- `docs/important/vivaldi-tab-strip-customization.md` (new) documents the absolute `--Height`/`--PositionY` + `.resize` + `progress` quirks.
- `docs/important/vivaldi-general-quirks.md` §7 added with pointer to new doc.
- New tabs still need at most one re-run if observer missed (e.g., drag-reorder); CSS keeps heights correct even without JS.

## Commands

```bash
node tools/vivaldi-title-split.mjs on      # apply (auto-tight, auto-number)
node tools/vivaldi-title-split.mjs off     # restore
node tools/vivaldi-title-split.mjs status  # 2F408BE7: on/off
# after + new tab, observer auto-runs; fallback: re-run on
```
