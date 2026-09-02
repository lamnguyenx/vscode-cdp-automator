# How to Test Vivaldi's Side Tab Bar (via CDP + VLM)

This is the canonical recipe for iterating visually on the Vivaldi vertical tab strip without manually screenshotting / eyeballing every change. Tested with Vivaldi 8.1.x on Linux; same flow works on macOS.

Companion docs:
- `docs/important/vivaldi-tab-strip-customization.md` — DOM structure + resize mechanics
- `docs/plans/2026/09/02/2026-09-02-non-destructive-title-rendering.md` — the design this recipe was built for

## Prerequisites

### 1. Launch Vivaldi with a CDP port

The browser must expose a DevTools Protocol endpoint on a known port:

```bash
/opt/vivaldi/vivaldi-bin \
  --remote-debugging-port=9023 \
  --user-data-dir=$HOME/.local/share/vivaldi-cdp-profiles/cdp-9023 \
  --ignore-certificate-errors
```

(macos: `/Applications/Vivaldi.app/Contents/MacOS/Vivaldi`)

`tools/vivaldi-title-split.mjs` defaults to port 9222. Override with `CDP_PORT=<n>` env var:

```bash
CDP_PORT=9023 node tools/vivaldi-title-split.mjs on|off|status
```

### 2. Verify CDP is up

```bash
curl -s http://127.0.0.1:9023/json/version
```

Returns `{ "Browser": "Chrome/8.1.x", ... }`. If empty, Vivaldi isn't ready yet (wait ~5-8s after launch).

### 3. Pick a vision-capable model for the VLM step

Two options known to work with `opencode run`:

- `VAI 1/Qwen3-VL-32B-Instruct-FP8` — vision only
- `opencode-go/muse-spark-1.2-contributor` — vision + reasoning, with `--variant minimal|low|medium|high|xhigh`

For visual layout review, `high` is the sweet spot. `xhigh` adds latency without much extra signal.

## Iteration loop

The unit of work is: change something → re-apply → capture → ask the VLM. Each step is one bash call.

### Step A — change something in `tools/vivaldi-title-split.mjs`

Edit `STYLE`, the `applyTabSplit` loop, or constants (`NEW_H`, `GAP`). The tool is **idempotent** — `on` removes any prior `#tab-title-split` element before re-injecting — so you do not need to run `off` first.

### Step B — re-apply to the live browser

```bash
CDP_PORT=9023 node tools/vivaldi-title-split.mjs on
```

Stdout reports per-window target IDs (`DBF8150E: on`). Keep these to correlate with later CDP probes if needed.

### Step C — capture a screenshot

Two scopes are useful: the **whole browser chrome** (sanity check that the rest of the UI is fine) and the **tab bar only** (the actual subject of review).

#### Full browser

```bash
node - <<'EOF'
import { writeFileSync, mkdirSync } from 'fs';
const PORT = 9023;
const list = await fetch(`http://127.0.0.1:${PORT}/json/list`).then(r=>r.json());
const t = list.filter(x=>(x.url??'').includes('window.html'))[0];
const ws = new WebSocket(t.webSocketDebuggerUrl);
let id=0; const pend=new Map();
const send=(m,p)=>new Promise((res,rej)=>{const i=++id; pend.set(i,{res,rej}); ws.send(JSON.stringify({id:i,method:m,params:p}));});
ws.onmessage=e=>{const m=JSON.parse(e.data); if(m.id&&pend.has(m.id)){const p=pend.get(m.id); pend.delete(m.id); m.error?p.rej(new Error(JSON.stringify(m.error))):p.res(m.result);}};
await new Promise((r,j)=>{ws.onopen=r; ws.onerror=j;});
const { data } = await send('Page.captureScreenshot', { format: 'png' });
ws.close();
const epoch = Math.floor(Date.now()/1000);
const dir = 'exp/screenshots/2026/09/02';
mkdirSync(dir, { recursive: true });
const path = `${dir}/2026-09-02-${epoch}-full.png`;
writeFileSync(path, Buffer.from(data, 'base64'));
console.log(path);
EOF
```

#### Tab bar only (recommended — smaller image, faster VLM round-trip)

```bash
node - <<'EOF'
import { writeFileSync, mkdirSync } from 'fs';
const PORT = 9023;
const list = await fetch(`http://127.0.0.1:${PORT}/json/list`).then(r=>r.json());
const t = list.filter(x=>(x.url??'').includes('window.html'))[0];
const ws = new WebSocket(t.webSocketDebuggerUrl);
let id=0; const pend=new Map();
const send=(m,p)=>new Promise((res,rej)=>{const i=++id; pend.set(i,{res,rej}); ws.send(JSON.stringify({id:i,method:m,params:p}));});
ws.onmessage=e=>{const m=JSON.parse(e.data); if(m.id&&pend.has(m.id)){const p=pend.get(m.id); pend.delete(m.id); m.error?p.rej(new Error(JSON.stringify(m.error))):p.res(m.result);}};
await new Promise((r,j)=>{ws.onopen=r; ws.onerror=j;});
const ev=async(x)=>(await send('Runtime.evaluate',{expression:x,returnByValue:true,awaitPromise:true}))?.result?.value;
const box = JSON.parse(await ev(`(() => {
  const el = document.getElementById('tabs-tabbar-container') || document.querySelector('.tab-strip')?.parentElement?.parentElement;
  if (!el) return 'null';
  const r = el.getBoundingClientRect();
  return JSON.stringify({ x: r.left, y: r.top, w: r.width, h: r.height });
})()`));
const { data } = await send('Page.captureScreenshot', { format: 'png', clip: { x: box.x, y: box.y, width: box.w, height: box.h, scale: 1 } });
ws.close();
const epoch = Math.floor(Date.now()/1000);
const dir = 'exp/screenshots/2026/09/02';
mkdirSync(dir, { recursive: true });
const path = `${dir}/2026-09-02-${epoch}-tabbar.png`;
writeFileSync(path, Buffer.from(data, 'base64'));
console.log(path);
EOF
```

**Important**: clip coords are CSS pixels relative to the `window.html` viewport, not the OSD. Cropping in JavaScript via `sharp` etc. is unnecessary — `Page.captureScreenshot` accepts a `clip` and does it natively.

### Step D — ask the VLM for feedback

The prompt matters. Be concrete about what to look for; the model can't read your mind.

```bash
opencode run -m "opencode-go/muse-spark-1.2-contributor" --variant high --thinking \
  "Vivaldi vertical tab bar after CSS injection. Focus on: (1) vertical spacing between line 1 (number+main) and line 2 (subtitle) — too tight / loose / good? (2) padding around text inside each row. Ignore hierarchy and weight. Brief, concrete." \
  -f "exp/screenshots/2026/09/02/<path>.png"
```

Rules:
- **Prompt before `-f`**. `opencode run` parses flags positionally; if prompt comes after `-f` it gets treated as another file path and fails with `Error: File not found: <your prompt>`.
- **Refer to images by delivery order**: `[Image 1]` = first `-f`, `[Image 2]` = second.
- **One topic per call**. Asking about gap + color + numbering in one prompt dilutes the answer; spin up parallel `opencode run` invocations or separate them.
- **Tell the model the rules it shouldn't comment on**. Default VLM feedback drifts to color/contrast/legibility; if you only care about geometry, say "ignore hierarchy/weight/color".

`BrokenPipeError` on stderr after the answer is normal — opencode closes stdout before the agent fully unwinds. The answer is printed before it.

### Step E — repeat

Loop back to A. No restart, no page reload needed — the tool is one-shot and idempotent.

## What to probe (concrete runtime checks)

Beyond VLM, useful to instrument the DOM directly when chasing a bug. All of these use the same CDP WebSocket pattern as step C.

### Verify styling is actually applied

```js
(() => JSON.stringify({
  stylePresent: !!document.getElementById('tab-title-split'),
  styleLen: document.getElementById('tab-title-split')?.textContent.length,
  tabCount: document.querySelectorAll('.tab-strip .tab-position').length,
  sample: [...document.querySelectorAll('.tab-strip .tab-position')].slice(0,3).map(p => ({
    tnum:        p.style.getPropertyValue('--tnum'),
    tmain:       p.style.getPropertyValue('--tmain'),
    tsub:        p.style.getPropertyValue('--tsub'),
    posy:        p.style.getPropertyValue('--PositionY'),
    titleColor:  getComputedStyle(p.querySelector('.title')).color,
    beforeCont:  getComputedStyle(p.querySelector('.title'), '::before').content,
    afterCont:   getComputedStyle(p.querySelector('.title'), '::after').content,
    active:      p.querySelector('.tab')?.classList.contains('active'),
  })),
}))()
```

Sanity: `titleColor` should match `.tab`'s `color` for any active state. If `titleColor` is a frozen/literal, see `2026-09-02-stale-ttxt-color-snapshot-CLOSED.md`.

### Check whether React has crashed the chrome

If a tab-title edit or domain reflow triggered a removeChild crash, the React tree unmounts:

```js
(() => JSON.stringify({
  hasApp:       !!document.querySelector('#app'),
  hasBrowser:   !!document.querySelector('#browser'),
  browserChildren:
    [...document.querySelector('#browser')?.children ?? []]
      .slice(0,5).map(c => c.tagName + '#' + c.id + '.' + (c.className||'').slice(0,40)),
}))()
```

If `browserChildren` is `["DIV.error-boundary"]` and nothing else, the chrome is dead and **must be recovered by restarting the Vivaldi process** — NOT via `Page.reload`. See "Recovery" below.

### Count tabs aware of the styling

```js
document.querySelectorAll('.tab-strip .tab-position').length
```

Tabs added after `on` ran will not carry `--tnum` etc. until you rerun. That's expected (manual-rerun model).

## Things you must NOT do

### Do NOT use `Page.reload` on `window.html`

Vivaldi only injects `bundle.js` during chrome startup. CDP `Page.reload` reloads the static `window.html` shell (CSS + empty `<body>`, no React mount) and leaves you with a permanently blank UI:

```
readyState: complete
headChildren: [META, TITLE, LINK, LINK]   # no <script>!
bodyHTMLlen: 4 ("\n\n\n\n")
```

Recovery is to restart the process. See below.

### Do NOT mutate `.title` children via `innerHTML`

The `.title` element is a React-managed `<span>` whose single text node is tracked in vDOM. Setting `t.innerHTML = "<span>...</span><br><span>...</span>"` replaces that text node with our own; a later framework re-render (e.g. double-click → rename mode) walks its own vDOM map, calls `removeChild` on what it thinks should be there, and crashes with:

```
NotFoundError: Failed to execute 'removeChild' on 'Node':
The node to be removed is not a child of this node.
  at ql (chrome-extension://mpognobbkildjkofajifpdfhcoklimli/bundle.js:1:5629634)
```

Use CSS custom props on `.tab-position.style` + `::before`/`::after` pseudo-elements instead. Pseudo-elements are framework-invisible and custom props survive reconciliation. See `2026-09-02-non-destructive-title-rendering.md` for the full rationale.

### Do NOT `appendChild` into `.tab-strip`

Same crash mechanism as above. `.tab-strip` is React-owned; inserting `<div class="tab-gap">` siblings desyncs the vDOM. Use `.tab-position.classList.toggle('tab-group-end')` + CSS border for group separators.

## Recovery

When the chrome has crashed (you see `<div class="error-boundary">` inside `#browser`, or `#app`/`#browser` are missing) or you've accidentally `Page.reload`-ed:

```bash
# find the top-level vivaldi-bin for this port (not --type=* children)
ps -ef | grep vivaldi-bin | grep remote-debugging-port=9023 | grep -v -- '--type='

# quit it, relaunch with the same flags + a seed URL to dodge restore dialog
kill -TERM <pid>
sleep 4
setsid /opt/vivaldi/vivaldi-bin \
  --remote-debugging-port=9023 \
  --user-data-dir=$HOME/.local/share/vivaldi-cdp-profiles/cdp-9023 \
  --ignore-certificate-errors \
  "https://localhost:9120/?folder=$HOME/git/empty2" \
  >/tmp/vivaldi-9023.log 2>&1 </dev/null &
disown

sleep 8
curl -s http://127.0.0.1:9023/json/version
CDP_PORT=9023 node tools/vivaldi-title-split.mjs on
```

Vivaldi's session restore brings tabs back automatically. On Linux, tab dupe can appear if you pass a URL that was already in the restored session — close the dupe manually.

## Quick reference: the full loop in one shell block

```bash
# edit, then:
CDP_PORT=9023 node tools/vivaldi-title-split.mjs on \
  && node /tmp/capture_tabbar.mjs \
  && opencode run \
       -m "opencode-go/muse-spark-1.2-contributor" \
       --variant high --thinking \
       "Describe the tab bar in <path>.png — spacing, padding, any clipping. Brief." \
       -f "<path>.png"
```

Save the capture script as `/tmp/capture_tabbar.mjs` once (the full source is in step C above) and reuse it.

## Model-specific gotchas

- **muse-spark tends to over-report on contrast/legibility.** Pre-filter by saying "ignore color/weight" when the question is purely geometric.
- **muse-spark cannot see what isn't in the crop.** Tab-bar-only crops miss the surrounding UI context — if the question is "does this fit the overall chrome", capture full-browser.
- **VLM feedback assumes the screenshot reflects the page.** After toggling active states, recapture; after `on` rerun, recapture. The model can't tell staleness from correctness.
