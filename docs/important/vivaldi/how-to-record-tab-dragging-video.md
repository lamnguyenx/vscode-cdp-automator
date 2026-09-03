# How to Record a Tab-Dragging Video (Real OS Cursor)

Record the Vivaldi vertical tab strip while a tab is being dragged — with the **real OS cursor visible** — for visual review, demos, or bug reports. Linux/X11 only.

Companion doc: `docs/important/how-to-test-vivaldi-side-tab-bar.md` — same CDP setup; this one adds screen capture around a synthetic drag.

## Why a hybrid approach (don't try xdotool alone)

Chromium on Linux filters synthetic X SendEvents. `xdotool click` / `xdotool mousedown` reach the compositor but are **ignored by Vivaldi's tab DnD handler** — the tab strip just sits there while the cursor bounces harmlessly.

But `xdotool mousemove` *does* move the real cursor, and `ffmpeg -f x11grab -draw_mouse 1` composites that cursor into the captured framebuffer. So:

- **CDP `Input.dispatchMouseEvent`** performs the actual drag (trusted input through Blink's pipeline — the same channel `vscode-ui-resizer` uses for Vivaldi's resize handle).
- **`xdotool mousemove`** mirrors the same coordinates in lockstep, purely so the OS cursor shows up in the video.
- **`ffmpeg -f x11grab`** records the region.

Net result: real-looking cursor in the video, real drag semantics underneath.

## Prerequisites

### 1. Vivaldi on CDP

```bash
/opt/vivaldi/vivaldi-bin \
  --remote-debugging-port=9023 \
  --user-data-dir=$HOME/.local/share/vivaldi-cdp-profiles/cdp-9023 \
  --ignore-certificate-errors
```

Wait ~5-8s, then verify:

```bash
curl -s http://127.0.0.1:9023/json/version
```

### 2. System ffmpeg (NOT conda's)

The conda ffmpeg at `/opt/conda/bin/ffmpeg` is built **without** `x11grab`. Ubuntu's system ffmpeg at `/usr/bin/ffmpeg` has it. Verify:

```bash
/usr/bin/ffmpeg -hide_banner -demuxers 2>/dev/null | grep -i x11grab
#   D  x11grab         X11 screen capture, using XCB
```

The recording script hard-codes `/usr/bin/ffmpeg` for this reason.

### 3. `xdotool` and `xwininfo`

```bash
which xdotool xwininfo    # /usr/bin/xdotool, /usr/bin/xwininfo
echo "DISPLAY=$DISPLAY"   # must be set (e.g. :0) — X11, not Wayland
```

Wayland: no known path. The recipe is X11-only because of `x11grab` + `xdotool`.

### 4. The title-split styling applied

The tab strip is taller with group separators once `tools/vivaldi-title-split.mjs on` has run. Re-run it right before recording so the strip reflects the post-styling layout:

```bash
CDP_PORT=9023 node tools/vivaldi-title-split.mjs on
```

This matters because the capture region is sized to the styled strip (38px rows + 40px group gaps), not Vivaldi's default 31px rows.

## The recording script

Save as `/tmp/record_drag_realcursor.mjs`. Edit `SRC_IDX` / `DST_IDX` (0-based visual positions) at the top, then `node /tmp/record_drag_realcursor.mjs`.

```bash
cat > /tmp/record_drag_realcursor.mjs <<'EOF'
// Hybrid real-cursor recording:
//   - CDP Input.dispatchMouseEvent does the actual drag (works on Vivaldi).
//   - xdotool mousemove mirrors the same coords in lockstep so the OS cursor
//     rides along (x11grab draws the OS cursor into the framebuffer).
// xdotool click would be ignored by Chromium (synthetic SendEvents filtered),
// so we keep the press/release on CDP and only let xdotool do mousemove.
const PORT = 9023;
const SRC_IDX = 4;   // 0-based visual position of source tab
const DST_IDX = 0;   // 0-based visual position: drop ABOVE this tab
const OUT_VID = 'exp/screenshots/2026/09/03/tab-drag-realcursor.mp4';

import { mkdirSync, existsSync } from 'fs';
import { execSync } from 'child_process';
if (!existsSync('exp/screenshots/2026/09/03')) mkdirSync('exp/screenshots/2026/09/03', { recursive: true });

const list = await fetch(`http://127.0.0.1:${PORT}/json/list`).then(r => r.json());
const t = list.filter(x => (x.url ?? '').includes('window.html'))[0];
if (!t) { console.error('no window.html target'); process.exit(1); }
const ws = new WebSocket(t.webSocketDebuggerUrl);
let id = 0; const pend = new Map();
const send = (m, p) => new Promise((res, rej) => {
  const i = ++id; pend.set(i, { res, rej });
  ws.send(JSON.stringify({ id: i, method: m, params: p }));
});
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pend.has(m.id)) {
    const p = pend.get(m.id); pend.delete(m.id);
    m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result);
  }
};
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
const ev = async (x) => (await send('Runtime.evaluate', { expression: x, returnByValue: true, awaitPromise: true }))?.result?.value;
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// --- geometry ---
const geom = JSON.parse(await ev(`(() => {
  const positions = [...document.querySelectorAll('.tab-strip .tab-position')];
  const src = positions[${SRC_IDX}];
  const dst = positions[${DST_IDX}];
  if (!src || !dst) return JSON.stringify({ err: 'no src or dst' });
  const s = src.getBoundingClientRect();
  const d = dst.getBoundingClientRect();
  return JSON.stringify({
    cssX: Math.round(s.left + s.width / 2),
    cssSy: Math.round(s.top + s.height / 2),
    cssDy: Math.round(d.top + d.height * 0.15),  // ~15% into top edge -> "drop above"
    stripL: Math.round(Math.min(s.left, d.left) - 7),
    stripR: Math.round(Math.max(s.right, d.right) + 7),
    stripTop: Math.round(Math.min(s.top, d.top) - 4),
    stripBot: Math.round(Math.max(s.bottom, d.bottom) + 4),
    srcText: (src.querySelector('.title')?.textContent ?? '').trim().slice(0,30),
    dstText: (dst.querySelector('.title')?.textContent ?? '').trim().slice(0,30),
  });
})()`));
if (geom.err) { console.error(geom.err); ws.close(); process.exit(1); }

// --- find the chrome window (largest window owned by the process) ---
// `xdotool search --name Vivaldi` also matches tooltips/popup children; pick
// the biggest window by area instead — that's always the chrome.
const VIVALDI_PID = 115808;  // replace with your `pgrep -f remote-debugging-port=9023`
const wins = execSync(`xdotool search --pid ${VIVALDI_PID}`).toString().trim().split('\n');
let bestWin = null, bestArea = 0;
for (const w of wins) {
  const info = execSync(`xwininfo -id ${w} 2>/dev/null`).toString();
  const x = +info.match(/Absolute upper-left X:\s+(\S+)/)?.[1];
  const y = +info.match(/Absolute upper-left Y:\s+(\S+)/)?.[1];
  const W = +info.match(/Width:\s+(\S+)/)?.[1];
  const H = +info.match(/Height:\s+(\S+)/)?.[1];
  if (!W || !H) continue;
  if (W * H > bestArea) { bestArea = W * H; bestWin = { id: w, x, y, W, H }; }
}
if (!bestWin) { console.error('no chrome window found'); process.exit(1); }
const ROOT_X = bestWin.x, ROOT_Y = bestWin.y;
console.log(`chrome ${bestWin.W}x${bestWin.H} root origin: (${ROOT_X}, ${ROOT_Y})`);

const X = geom.cssX, SY = geom.cssSy, DY = geom.cssDy;

// capture region in root coord space (x264 requires even dimensions)
const CX = geom.stripL + ROOT_X - 5;
const CY = geom.stripTop + ROOT_Y - 5;
let CW = (geom.stripR - geom.stripL) + 10;
let CH = 340;  // grab generously — styled strip with group gaps is taller than default
if (CW % 2) CW++; if (CH % 2) CH++;
console.log(`capture region: ${CW}x${CH} @ root (${CX},${CY})`);

const press = (p) => send('Input.dispatchMouseEvent', p);
const osCursor = (cx, cy) => execSync(`xdotool mousemove ${cx + ROOT_X} ${cy + ROOT_Y}`);

// --- 1) start ffmpeg x11grab (draw_mouse=1 default; OS cursor composited) ---
const FF = '/usr/bin/ffmpeg';   // conda ffmpeg lacks x11grab
const ffCmd = `setsid ${FF} -y -f x11grab -framerate 20 -draw_mouse 1 -video_size ${CW}x${CH} -i :0.0+${CX},${CY} -c:v libx264 -preset fast -pix_fmt yuv420p ${OUT_VID} >/tmp/ff.log 2>&1 & echo $!`;
const ffPid = execSync(ffCmd).toString().trim();
console.log(`ffmpeg pid=${ffPid}`);
await sleep(900);

// --- 2) synthetic drag (CDP) with cursor mirror (xdotool) ---
console.log('cursor->source + mousePressed');
osCursor(X, SY); await sleep(80);
await press({ type: 'mousePressed', x: X, y: SY, button: 'left', buttons: 1, clickCount: 1 });
await sleep(60);

console.log('jitter for dragstart');
osCursor(X, SY + 4);
await press({ type: 'mouseMoved', x: X, y: SY + 4, button: 'none', buttons: 1 });
await sleep(90);

console.log('drag...');
const STEPS = 24;
for (let i = 1; i <= STEPS; i++) {
  const f = i / STEPS;
  const y = Math.round(SY + (DY - SY) * f);
  osCursor(X, y);                         // visual cursor
  await press({ type: 'mouseMoved', x: X, y, button: 'none', buttons: 1 }); // does the work
  await sleep(28);
}
await sleep(80);
osCursor(X, DY);
console.log('mouseReleased');
await press({ type: 'mouseReleased', x: X, y: DY, button: 'left', buttons: 0, clickCount: 1 });
await sleep(600);

// --- 3) graceful ffmpeg close ---
try { process.kill(Number(ffPid), 'SIGINT'); } catch {}
await sleep(400);
ws.close();
console.log('done:', OUT_VID);
EOF
```

## Running

```bash
# 1. apply styling first so the strip is at full styled height
CDP_PORT=9023 node tools/vivaldi-title-split.mjs on

# 2. record (edit SRC_IDX / DST_IDX inside the script first)
node /tmp/record_drag_realcursor.mjs

# 3. sanity check the reorder happened
curl -s http://127.0.0.1:9023/json/list | jq -r '.[] | select(.type=="page") | .title'
```

## Gotchas

### `/opt/conda/bin/ffmpeg` is missing `x11grab`

Conda's build is configured `--disable-libavdevice` (or the XCB plugin isn't linked). Use `/usr/bin/ffmpeg` (Ubuntu 4.4.2-) which has `x11grab` enabled. Hard-coded in the script.

### `xdotool search --name Vivaldi` returns the wrong window

Filters match every window whose title contains "Vivaldi" — including popup/tooltip children at root (0,0). Picking the **largest window by area** owned by the PID reliably returns the chrome.

### x264 rejects odd dimensions

`width not divisible by 2 (135x188) → Error initializing output stream`. Round both `CW` and `CH` up to even numbers before passing to `-video_size`.

### ffmpeg writes 0 bytes if killed before moov

`SIGKILL` skips the mp4 trailer; the file is unplayable. Use **SIGINT** so ffmpeg flushes the moov atom on exit (`Exiting normally, received signal 2.`).

### xdotool click doesn't work on Chromium tabs

Synthetic X button events have a SendEvent flag that Chromium's input pipeline filters out. Only **mousemove** from xdotool reaches the framebuffer (via the compositor's cursor sprite); button state must come from CDP. Do not try to replace the CDP press/release with `xdotool mousedown 1` — the tab won't drag.

### Strip reshapes after the drop

Vivaldi's React reconciler rewrites inline `--PositionY` and drops the `tab-group-end` class on the post-drop re-render, so the styled 38px rows + group gaps revert to Vivaldi's default 31px pitch *for the tabs it touched*. The video still captures the pre-drop styling; rerun `on` to restore it for the next iteration.

### `VIVALDI_PID` is hard-coded

Replace `115808` in the script with your current PID, or fetch it dynamically:

```js
const VIVALDI_PID = execSync("pgrep -f 'remote-debugging-port=9023' | head -1").toString().trim();
```

## Verifying the video

```bash
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,nb_frames,duration \
  -of default=nw=1 exp/screenshots/2026/09/03/tab-drag-realcursor.mp4
```

Expect ~3s, ~60 frames, 136×340 (or whatever your strip dimensions resolve to). Cursor should be visible tracking the source tab upward.
