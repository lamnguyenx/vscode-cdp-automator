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

### 8. New-tab auto-trigger (final)

User: “have to run `on` again after `+`”. Added safe observer:

```js
const applyTabSplit = () => {
  document.querySelectorAll('.tab-position').forEach((pos,idx)=>{
    const t=pos.querySelector('.title');
    if(!t.getAttribute('data-orig-title')){ /* split */ } else { n.textContent=(idx+1)+'.' }
  });
  resize.style.setProperty('max-height', n*(38+1)+'px');
};
window._tabSplitObserver = new MutationObserver(applyTabSplit);
observer.observe(strip,{childList:true}); // not subtree
newTabBtn.addEventListener('click',()=>setTimeout(applyTabSplit,300));
```

Verified via `Input.dispatchMouseEvent` click on `newtab` button: `9→10` tabs `1. … 10.Blank Page` `y342` `resize 390` no hang.

## Final Solution (pure HTML/CSS/JS, no hanging observer)

`tools/vivaldi-title-split.mjs` (`git diff --cached`):

- `NEW_H=38` constant.
- `HEIGHT_CSS`: 50× `.tab-strip > span:nth-child(N) .tab-position { --PositionY: (N-1)*38 !important }` + `--Height:38px !important`. `!important` beats inline, handles new tabs instantly via CSS without JS.
- `STYLE`: hides `favicon, tab-audio, page-progress-indicator`; `tab { justify-content:center }`; `tab-number margin-right:0`; includes `HEIGHT_CSS`.
- `on`: injects style, one-shot split+numbering, one-shot `resize.max-height = n*39`, installs `childList` observer + `newtab` click fallback.
- `off`: removes style, disconnects observer, restores titles, clears `resize.max-height`.

Result (live `2F408BE7`):
- `tab 37.35` (was 30.35) centered diff `0.01`
- `strip/resize 312` (8 tabs) → `351` (9) → `390` (10) no scrollbar when space ample, toolbar `y427.6 h30` visible
- `1. APPLE` no gap, `progress` gone

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
