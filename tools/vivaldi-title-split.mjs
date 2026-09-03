// Combine tab number + title split + styling for Vivaldi's tab bar.
// Injects CSS and JS into window.html CDP target.
// Usage:  node vivaldi-title-split.mjs [on|off|status]   (default: on)

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';

const arg = process.argv[2] ?? 'on';
const PORT = Number(process.env.CDP_PORT) || 9222;

// Persist the refresh button's position per CDP port (XDG config dir).
const xdgConfig = process.env.XDG_CONFIG_HOME || join(homedir(), '.config');
const btnPosFile = join(xdgConfig, 'vscode-cdp-automator', 'vivaldi-tab-split', `btn-pos-${PORT}.json`);

function readBtnPos() {
  try {
    if (existsSync(btnPosFile)) {
      const p = JSON.parse(readFileSync(btnPosFile, 'utf8'));
      if (typeof p.left === 'number' && typeof p.top === 'number') return p;
    }
  } catch (err) {}
  return null;
}

function writeBtnPos(left, top) {
  try {
    mkdirSync(join(btnPosFile, '..'), { recursive: true });
    writeFileSync(btnPosFile, JSON.stringify({ left, top, port: PORT }, null, 2));
  } catch (err) {}
}

async function targets() {
  const list = await fetch(`http://127.0.0.1:${PORT}/json/list`).then(r => r.json());
  return list.filter(t => (t.url ?? '').includes('window.html'));
}

const NEW_H = 38;
const GAP = 0;
const HEIGHT_CSS = `.tab-strip .tab-position { --Height: ${NEW_H}px !important; }`;
// IMPORTANT: never mutate `.title` children — Vivaldi's framework owns that text
// node, and overwriting .innerHTML makes a later framework re-render (e.g. the
// rename triggered by double-click) call removeChild on the dead node → crash
// (NotFoundError: removeChild). All numbering/splitting is rendered through
// ::before / ::after pseudo-elements fed by CSS custom props we set on
// `.tab-position.style` (--tnum/--tmain/--tsub/--ttxt). Custom props survive a
// framework re-render (same trick already used for --PositionY), so the
// framework's tracked children stay intact.
const STYLE = `
.tab-strip .tab-position .favicon, .tab-strip .tab-position .tab-audio, .tab-strip .tab-position .page-progress-indicator { display: none !important; }
.tab-strip .tab-position .title { display: block !important; flex: 1 1 auto !important; height: auto !important; font-size: 0 !important; line-height: 1 !important; padding: 0 8px !important; position: relative; -webkit-mask-image: -webkit-linear-gradient(90deg, rgb(255,255,255) calc(100% - 30px), rgba(0,0,0,0) 100%) !important; mask-image: linear-gradient(90deg, rgb(255,255,255) calc(100% - 30px), rgba(0,0,0,0) 100%) !important; }
.tab-strip .tab-position .title::before { content: var(--tnum, "") var(--tmain, ""); display: block; color: inherit; font-weight: 700; font-size: 11px; line-height: 1; }
.tab-strip .tab-position .title::after { content: var(--tsub, ""); display: block; color: inherit; font-weight: 400; font-size: 12px; line-height: 1; }
.tab-header { height: auto !important; flex-basis: auto !important; overflow: visible !important; } .tab-position .tab { height: auto !important; flex-basis: auto !important; max-height: none !important; overflow: visible !important; justify-content: center !important; padding: 2px 0 !important; }
.tab-strip .tab-position { border-bottom: 1px solid rgba(255,255,255,0.12); }
.tab-strip .tab-position.tab-group-end { border-bottom: 2px solid var(--colorAccentBg, #aaa); }
.tab-strip { border-right: none !important; }
#tabs-tabbar-container { border-right: 1px solid rgba(255,255,255,0.18) !important; }
#tab-split-refresh-btn { position: fixed; bottom: 43px; width: 30px; height: 30px; min-width: 30px; border: 1px solid var(--colorFg, #fff); border-radius: 8px; background: rgba(0, 0, 0, 0); color: var(--colorFg, #fff); font-size: 16px; cursor: grab; z-index: 9999; opacity: 0.9; line-height: 1; display: flex; align-items: center; justify-content: center; padding: 0; user-select: none; touch-action: none; box-sizing: border-box; }
#tab-split-refresh-btn:active { cursor: grabbing; }
#tab-split-refresh-btn:hover { background: rgba(255, 255, 255, 0.12); opacity: 1; }
${HEIGHT_CSS}
`.trim();

async function attach(wsUrl) {
  const ws = new WebSocket(wsUrl);
  let id = 0;
  const pending = new Map();
  const send = (method, params) => new Promise((res, rej) => {
    const i = ++id;
    pending.set(i, { res, rej });
    ws.send(JSON.stringify({ id: i, method, params }));
  });
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id); pending.delete(m.id);
      m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result);
    }
  };
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  const ev = async (expr) => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }))?.result?.value;
  return { ws, ev };
}

const apply = async (t) => {
  const { ws, ev } = await attach(t.webSocketDebuggerUrl);
  if (arg === 'status') {
    const st = await ev(`(() => { const el = document.getElementById('tab-title-split'); return el ? 'on' : 'off'; })()`);
    console.log(`${t.id.slice(0, 8)}: ${st}`);
  } else if (arg === 'off') {
    await ev(`(() => {
      document.getElementById('tab-title-split')?.remove();
      document.getElementById('tab-split-refresh-btn')?.remove();
      document.getElementById('tab-order-numbers')?.remove();
      window._tabSplitObserver?.disconnect(); delete window._tabSplitObserver;
      if (window._tabSplitInterval) { clearInterval(window._tabSplitInterval); delete window._tabSplitInterval; }
      document.querySelectorAll('.tab-strip .tab-position').forEach(pos => {
        pos.style.removeProperty('--PositionY');
        pos.style.removeProperty('--tnum');
        pos.style.removeProperty('--tmain');
        pos.style.removeProperty('--tsub');
        pos.classList.remove('tab-group-end');
      });
      document.querySelectorAll('.tab-strip .tab-position .title').forEach(t => {
        // During on we never mutate .title children — only set font-size:0
        // on the element so the live text hides behind pseudo-elements. So there
        // is nothing to restore here; just drop the stale cache attribute.
        t.removeAttribute('data-orig-title');
      });
      const resize = document.querySelector('.tab-strip')?.parentElement;
      if (resize && resize.classList.contains('resize')) resize.style.removeProperty('max-height');
      return 'ok';
    })()`);
    console.log(`${t.id.slice(0, 8)}: off`);
  } else {
    const savedPos = readBtnPos();
    await ev(`(() => {
      const SAVED_POS = ${JSON.stringify(savedPos)};
      const old = document.getElementById('tab-title-split');
      if (old) old.remove();
      const style = document.createElement('style');
      style.id = 'tab-title-split';
      style.textContent = ${JSON.stringify(STYLE)};
      document.head.appendChild(style);
      const NEW_H_INNER = ${NEW_H};
      const GAP_INNER = ${GAP};
      const strip = document.querySelector('.tab-strip');
      const resize = strip?.parentElement;
      const getGroup = (txt) => {
        if (!txt || txt.trim() === 'Blank Page') return 'blank';
        return txt.split(' - ')[0].trim();
      };
      const applyTabSplit = () => {
        const positions = [...document.querySelectorAll('.tab-strip .tab-position')];
        positions.forEach(p => p.classList.remove('tab-group-end'));
        let offset = 0;
        let prevGroup = null;
        let totalGaps = 0;
        const groups = positions.map(p => {
          const t = p.querySelector('.title');
          return getGroup(t ? t.textContent : '');
        });
        positions.forEach((pos, idx) => {
          const group = groups[idx];
          if (idx > 0 && group !== prevGroup) {
            offset += GAP_INNER;
            totalGaps++;
            positions[idx-1].classList.add('tab-group-end');
          }
          pos.style.setProperty('--PositionY', (idx * NEW_H_INNER + offset) + 'px', 'important');
          prevGroup = group;
        });
        let visibleIdx = 0;
        positions.forEach((pos) => {
          const t = pos.querySelector('.title');
          if (!t) return;
          // Read the live textContent every run — never mutate .title's
          // children (the framework owns them; touching them triggers a
          // removeChild crash on re-render). font-size:0 on .title keeps the
          // text node intact and framework-updated but visually hidden, so our
          // pseudo-elements are the only visible rendering. No cache means
          // tab-title updates (navigation) are picked up on the next rerun.
          const txt = t.textContent;
          if (!txt || txt.trim() === '' || txt.trim() === 'Blank Page') {
            pos.style.setProperty('--tnum', '""');
            pos.style.setProperty('--tmain', '""');
            pos.style.setProperty('--tsub', '""');
            return;
          }
          visibleIdx++;
          pos.style.setProperty('--tnum', JSON.stringify(visibleIdx + '.'));
          if (txt.includes(' - ')) {
            const [first, ...rest] = txt.split(' - ');
            pos.style.setProperty('--tmain', JSON.stringify(first));
            pos.style.setProperty('--tsub', JSON.stringify(rest.join(' - ')));
          } else {
            pos.style.setProperty('--tmain', JSON.stringify(txt));
            pos.style.setProperty('--tsub', '""');
          }
        });
        if (resize && resize.classList.contains('resize')) {
          const n = positions.length;
          resize.style.setProperty('max-height', (n * (NEW_H_INNER + 1) + totalGaps * GAP_INNER) + 'px');
        }
      };
      applyTabSplit();
      // inject refresh button — remove any stale one (may carry old handlers)
      const oldBtn = document.getElementById('tab-split-refresh-btn');
      if (oldBtn) oldBtn.remove();
      const btn = document.createElement('button');
      btn.id = 'tab-split-refresh-btn';
      btn.textContent = '↻';
      btn.title = 'Refresh tab split layout';
      // drag to reposition (threshold 4px distinguishes drag from click)
      // Uses Pointer Events + setPointerCapture so the button keeps receiving
      // moves even when the cursor outruns its 30px box (Vivaldi hit-tests the
      // coords, not the moved element — without capture, moves beyond the box
      // are delivered to whatever is underneath instead).
      let dragState = null;
      let wasDragged = false;
      const savePos = () => {
        try {
          window._tabSplitBtnPos = { left: parseFloat(btn.style.left), top: parseFloat(btn.style.top) };
        } catch (err) {}
      };
      const snapToEdge = () => {
        const w = window.innerWidth, h = window.innerHeight;
        const bw = btn.offsetWidth, bh = btn.offsetHeight;
        const cx = btn.offsetLeft + bw / 2, cy = btn.offsetTop + bh / 2;
        const m = 4;  // margin from the edge
        const clampX = (x) => Math.max(m, Math.min(x, w - bw - m));
        const clampY = (y) => Math.max(m, Math.min(y, h - bh - m));
        const dLeft = cx, dRight = w - cx, dTop = cy, dBottom = h - cy;
        const min = Math.min(dLeft, dRight, dTop, dBottom);
        if (min === dLeft) {
          btn.style.left = m + 'px';
          btn.style.top = clampY(cy - bh / 2) + 'px';
        } else if (min === dRight) {
          btn.style.left = (w - bw - m) + 'px';
          btn.style.top = clampY(cy - bh / 2) + 'px';
        } else if (min === dTop) {
          btn.style.top = m + 'px';
          btn.style.left = clampX(cx - bw / 2) + 'px';
        } else {
          btn.style.top = (h - bh - m) + 'px';
          btn.style.left = clampX(cx - bw / 2) + 'px';
        }
        btn.style.bottom = 'auto';
        savePos();
      };
      btn.addEventListener('pointerdown', (e) => {
        e.stopPropagation();
        // NOTE: no preventDefault — it cancels the drag gesture and CDP stops
        // delivering mousemove/pointermove. user-select:none handles selection.
        btn.setPointerCapture(e.pointerId);
        const startX = e.clientX, startY = e.clientY;
        const origLeft = btn.offsetLeft, origTop = btn.offsetTop;
        dragState = { startX, startY, origLeft, origTop, moved: false };
        wasDragged = false;
      });
      // window-capture fallback: CDP-synthesized mouse events don't respect
      // setPointerCapture in Vivaldi's window.html, so moves may not reach the
      // button. A capture-phase window mousemove sees every move regardless.
      window.addEventListener('mousemove', (e) => {
        if (!dragState) return;
        const dx = e.clientX - dragState.startX, dy = e.clientY - dragState.startY;
        if (Math.abs(dx) > 4 || Math.abs(dy) > 4) dragState.moved = true;
        btn.style.left = (dragState.origLeft + dx) + 'px';
        btn.style.top = (dragState.origTop + dy) + 'px';
        btn.style.bottom = 'auto';
      }, true);
      btn.addEventListener('pointermove', (e) => {
        if (!dragState) return;
        const dx = e.clientX - dragState.startX, dy = e.clientY - dragState.startY;
        if (Math.abs(dx) > 4 || Math.abs(dy) > 4) dragState.moved = true;
        btn.style.left = (dragState.origLeft + dx) + 'px';
        btn.style.top = (dragState.origTop + dy) + 'px';
        btn.style.bottom = 'auto';
      });
      btn.addEventListener('pointerup', (e) => {
        if (!dragState) return;
        wasDragged = !!dragState.moved;
        dragState = null;
        if (e.pointerId !== undefined) { try { btn.releasePointerCapture(e.pointerId); } catch (err) {} }
        if (wasDragged) snapToEdge();
      });
      window.addEventListener('mouseup', (e) => {
        if (!dragState) return;
        wasDragged = !!dragState.moved;
        dragState = null;
        if (wasDragged) snapToEdge();
      }, true);
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        if (wasDragged) { wasDragged = false; return; }  // drag, not click
        applyTabSplit();
      });
      document.body.appendChild(btn);
      // initial position: restore saved position (from XDG file, injected as
      // SAVED_POS), else default = left-aligned + vertically centered.
      if (SAVED_POS && typeof SAVED_POS.left === 'number' && typeof SAVED_POS.top === 'number') {
        btn.style.left = SAVED_POS.left + 'px';
        btn.style.top = SAVED_POS.top + 'px';
        btn.style.bottom = 'auto';
      } else {
        const bw = btn.offsetWidth, bh = btn.offsetHeight;
        btn.style.left = '4px';
        btn.style.top = Math.max(4, Math.round((window.innerHeight - bh) / 2)) + 'px';
        btn.style.bottom = 'auto';
      }
      // manual rerun only — clean up any previous auto observers/intervals
      if (window._tabSplitObserver) { window._tabSplitObserver.disconnect(); delete window._tabSplitObserver; }
      if (window._tabSplitInterval) { clearInterval(window._tabSplitInterval); delete window._tabSplitInterval; }
      return 'ok';
    })()`);
    // persist the button's latest position (the page stashes it in
    // _tabSplitBtnPos on every drag end) so the next `on` restores it.
    const cur = await ev(`(() => window._tabSplitBtnPos ? JSON.stringify(window._tabSplitBtnPos) : null)()`);
    if (cur) {
      try {
        const p = JSON.parse(cur);
        if (typeof p.left === 'number' && typeof p.top === 'number') writeBtnPos(p.left, p.top);
      } catch (err) {}
    }
    console.log(`${t.id.slice(0, 8)}: on`);
  }
  ws.close();
};

const wins = await targets();
if (!wins.length) { console.error('no window.html target on port ' + PORT); process.exit(1); }
await Promise.all(wins.map(apply));