# Non-Destructive Tab Title Rendering (pseudo-elements + custom props)

Date: 2026-09-02
Tool: `tools/vivaldi-title-split.mjs`
Vivaldi 8.1.4087.70 / Chromium 150 / `--remote-debugging-port=9023` / `window.html` (`mpognobbkildjkofajifpdfhcoklimli`)
Predecessor writeup: `docs/plans/2026/08/22/2026-08-22-vivaldi-tab-strip-height-title-split.md`

## TL;DR

The previous approach rewrote `.title.innerHTML = "<span>...</span><br><span>...</span>"` and injected `<div class="tab-gap">` siblings into `.tab-strip`. Both are framework-owned DOM. A later React re-render in Vivaldi's UI layer (triggered by **double-click → tab rename mode**, or domain gap reflows) tried to reconcile its own vDOM against the rewritten children, hit a node it no longer tracked, and threw `Failed to execute 'removeChild' on 'Node': The node to be removed is not a child of this node.` — hard-crashing the whole browser chrome (white/empty `#app`, requires full restart; CDP `Page.reload` does NOT recover it).

This session replaces every mutation of React-tracked DOM with: **CSS custom properties on `.tab-position.style`** (set via `setProperty`/`removeProperty`, which React safely reconciles) + **`::before`/`::after` pseudo-elements** (framework-invisible). No framework-owned children are touched anywhere. Double-click rename now works.

Secondary changes: line/padding tuning, number/title spacing, removable `CDP_PORT` env var, don't-reload-`window.html` lesson.

## The crash chain

1. `on` ran `applyTabSplit()`, which for every `.tab-position` did **`t.innerHTML = num + '<span class="tab-main-title">…</span><br><span class="tab-subtitle">…</span>'`** on `.title`.
2. It also did **`strip.appendChild(gap)`** inserting `<div class="tab-gap">` into `.tab-strip` between group boundaries.
3. `.title` and `.tab-strip` are React-managed in Vivaldi's bundle.js. The framework holds internal references to the text node and child set it created.
4. Double-click on a tab title triggers React's edit/rename-mode re-render. The reconciler walks what it thinks the children should be, calls `removeChild(node)` to clear, and the node is no longer a direct child of the parent we expect → throws the `NotFoundError` shown below → React ErrorBoundary unmounts the entire chrome → blank UI.

```
NotFoundError: Failed to execute 'removeChild' on 'Node': The node to be removed is not a child of this node.
    at ql (chrome-extension://mpognobbkildjkofajifpdfhcoklimli/bundle.js:1:5629634)
    at Ul (...)
    ...
```

## Fix #1 — Stop clobbering `.title` children

The React-tracked node inside `<span class="title">` is a single `#text` node with the page title (verified via CDP inspection: `childNodes: 1, firstChild: "#text 🌲PP - empty2"`).

Replace the previous innerHTML/table-injection hack with a **render-via-pseudo-elements** approach:

- `.title { font-size: 0 !important; color: transparent !important; }` — the live `#text` node stays in the DOM (framework-unchanged and framework-updated on navigation), but renders at **zero height** and contributes nothing to the visible layout.
- `::before` renders `var(--tnum) var(--tmain)` (number + main title): `font-size: 11px; font-weight: 700`.
- `::after` renders `var(--tsub)` (subtitle): `font-size: 12px; font-weight: 400`. Note: subtitle is intentionally **larger** than the top line, matching the visual hierarchy found in `8f33a55`.
- Values for `--tnum` / `--tmain` / `--tsub` are written to `.tab-position.style` as CSS custom properties (NOT to `.title.style` — React owns that element's inline `$4`/`$5` props for other purposes; custom props on the ancestor are safer and survive re-render, same trick the script already used for `--PositionY`).
- Theme text color captured once from `.tab` (the parent of `.title`) and exposed as `--ttxt`, because by the time we read it our own CSS has zeroed `.title`'s color.

On each `on` run:

```js
pos.style.setProperty('--tnum',  JSON.stringify(visibleIdx + '.'));
pos.style.setProperty('--tmain', JSON.stringify(first));
pos.style.setProperty('--tsub',  JSON.stringify(rest.join(' - ')));
pos.style.setProperty('--ttxt',  getComputedStyle(t.closest('.tab')).color);
```

`JSON.stringify` produces a properly-quoted CSS string literal — safe against any title text including emoji / quotes / braces.

## Fix #2 — Stop injecting `.tab-gap` siblings

Group separators no longer append DOM nodes into the React-owned `.tab-strip`. Instead:

- The previous tab in a group-change gets `classList.add('tab-group-end')` — setting/removing a class is safe (React reconciles `className` via attribute APIs, never `removeChild`).
- The border itself is pure CSS:
  ```css
  .tab-strip .tab-position { border-bottom: 1px solid rgba(255,255,255,0.12); }
  .tab-strip .tab-position.tab-group-end { border-bottom: 1px solid rgba(255,255,255,0.45); }
  ```
- The `--PositionY` arithmetic still accumulates `offset += GAP` at each group boundary so rows don't collide; the visual gap is now just brighter/more opaque border, not a physical spacer div.

The `off` path also no longer iterates `.tab-strip` children looking for `.tab-gap` to remove — nothing to clean up.

## Fix #3 — Remove the stale `data-orig-title` cache

The earlier design cached `t.textContent` to `data-orig-title` on first sight, then read from that cache ever after. This was destructive in two ways:

1. **Stale titles**: if a tab navigated and Vivaldi updated the framework text node, the script kept rendering the original cached title until `off` + `on` cycled.
2. **`off` wrote textContent**: `t.textContent = orig` to "restore", which also **replaced** the framework's text node with a new one — a second, independent desync vector.

Both removed. Now:

- `on` reads **`t.textContent` live every run** — picks up navigation/title changes automatically, no cache layer in between.
- `off` only removes the `<style>`, custom props, and `.tab-group-end` class. Never writes to `.title` children. The original text has been there all along (just `font-size:0`-hidden), so disabling makes it reappear immediately.
- `data-orig-title` attribute is still dropped if present (one-time cleanup for users upgrading from the old version) but is never set going forward.

## New feature: `CDP_PORT` env var

The script hardcoded `9222`. This session added:

```js
const PORT = Number(process.env.CDP_PORT) || 9222;
```

Default unchanged; `9951c05` instance lives on 9023. Usage:

```
CDP_PORT=9023 node tools/vivaldi-title-split.mjs on|off|status
```

## Visual tuning (per-session feedback loop)

These were iteration tweaks applied via VLM review (`opencode run -m "opencode-go/muse-spark-1.2-contributor" --variant high`):

- **Hiding the hidden line**: the very first attempt set `.title { color: transparent; line-height: 1.25 }` but left `font-size` default. Result: the transparent original text node rendered an **invisible third line** between `::before` and `::after`, making the two visible lines look absurdly far apart. Setting `font-size: 0 !important` on `.title` (and switching pseudos to absolute `px`, since `%` would inherit `0`) collapsed that hidden line and fixed the gap.
- **Line gap**: `line-height: 1` on both `.title` and its pseudos, plus `margin: 0` — no stray vertical whitespace.
- **Padding around titles**: `.title { padding: 0 8px }`, `.tab { padding: 2px 0 }`.
- **Number/title spacing**: `1. 🌲PP` → `1.🌲PP` (drop the trailing space in the `--tnum` string literal).
- **Separator softening**: pure-white borders `→ rgba(255,255,255,0.12)` for normal row, `0.45` for `tab-group-end`, `0.18` for `#tabs-tabbar-container` right border — no longer glaring.
- **Bottom line bigger than top** (intentional, matches `8f33a55`'s accidental-but-good rendering): `::before 11px/700`, `::after 12px/400`.

## Lesson: do NOT `Page.reload` the `window.html` target

During debugging I ran CDP `Page.reload` on the crashed `window.html` to clear the React error-boundary state. **Bad move.** Vivaldi re-injects `bundle.js` only during its own chrome startup; a raw `Page.reload` reloads the static HTML shell (CSS + bare `<body>`) with no React mount, leaving a permanently blank UI:

```
readyState: complete   hasBody: true   bodyHTMLlen: 4 ("\n\n\n\n")
headChildren: [META, TITLE, LINK, LINK]   # no <script>!
```

Recovery required a full process quit + relaunch (`kill -TERM <vivaldi-bin pid>` then re-exec with the same `--remote-debugging-port` / `--user-data-dir` / `--ignore-certificate-errors` flags) — Vivaldi's session restore brought the tabs back.

Rule going forward: if `window.html` ever enters a broken state (empty `#app`, `<div class="error-boundary">` under `#browser`), **restart the Vivaldi process**, do not reload the page via CDP.

## Recovery cheatsheet (self-use)

```bash
# 1. Enumerate instances + ports
ps -ef | grep vivaldi-bin | grep remote-debugging-port

# 2. Quit a specific instance (PID of the top-level vivaldi-bin, not --type=*)
kill -TERM <pid>

# 3. Relaunch with identical flags; pass a seed URL to dodge "restore last session?" dialog if desired
setsid /opt/vivaldi/vivaldi-bin \
  --remote-debugging-port=9023 \
  --user-data-dir=/home/lamnt45/.local/share/vivaldi-cdp-profiles/cdp-9023 \
  --ignore-certificate-errors \
  "https://localhost:9120/?folder=/home/lamnt45/git/empty2" \
  >/tmp/vivaldi-9023.log 2>&1 </dev/null &
disown

# 4. Wait for CDP, then re-apply
sleep 8
curl -s http://127.0.0.1:9023/json/version   # verify
CDP_PORT=9023 node tools/vivaldi-title-split.mjs on
```

## Punchlist diff vs. `8f33a55`

| Area | Before (`8f33a55`) | After |
|------|--------------------|-------|
| `.title` children | `t.innerHTML = "<span>…</span><br><span>…</span>"` | untouched; hidden via `font-size:0`, drawn by `::before`/`::after` |
| Group separators | `strip.appendChild(div.tab-gap)` into `.tab-strip` | class `tab-group-end` on `.tab-position`; border via CSS |
| Origin title caching | `t.setAttribute('data-orig-title', …)` first run, read ever after | read `t.textContent` live every run |
| `off` title restore | `t.textContent = orig` | just remove style + props + attr; live text was never touched |
| CDP port | hardcoded `9222` | `process.env.CDP_PORT \|\| 9222` |
| `.title` line gap | transparent hidden text node between two pseudo blocks = 3 stacked lines | `font-size:0` on `.title` collapses the hidden middle line |
| Number format | `1. 🌲PP` | `1.🌲PP` |
| Subtitle relative size | `.tab-main-title 80%`, `.tab-subtitle inherit` — subtitle LARGER by accident | explicit `::before 11px / 700`, `::after 12px / 400` (subtitle larger, by intent) |
| Border color | `white` (glaring) | `rgba(255,255,255, 0.12 / 0.18 / 0.45)` |

## What this did NOT change

- Constants `NEW_H = 38`, `GAP = 40` untouched.
- `.resize { max-height }` formula (`n * (38+1) + totalGaps * 40`) unchanged.
- The **manual rerun** model — no `MutationObserver`, no `setInterval` — still holds. New tabs added after `on` are unstyled until the next `on` is re-run. Already documented in `docs/important/vivaldi-tab-strip-customization.md:56-58` and `README.md:97-103`.
- `#tab-title-split` `<style>` element ID (used by `status`) unchanged.
- The isolating pattern (separate `window.html` target via `/json/list` filter) unchanged.

## Files touched

- `tools/vivaldi-title-split.mjs` — the substantive rewrite.
- This doc.
- (To follow up, see punchlist below.)

## Followups

- Update `README.md:80` "Title rewrite" bullet to reflect the pseudo-element + custom-prop approach (currently still describes the `innerHTML` rewrite).
- Update `docs/important/vivaldi-tab-strip-customization.md` anywhere it mentions `.tab-main-title` / `.tab-subtitle` / `.tab-number` / `innerHTML` — these classes/scripts no longer exist.
- Consider warning the user (or pinning) in `restore-all`/`save-all` shell flow against issuing `Page.reload` on the `window.html` target.
