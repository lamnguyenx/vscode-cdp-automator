// Combine tab number + title split + styling for Vivaldi's tab bar.
// Injects CSS and JS into window.html CDP target.
// Usage:  node vivaldi-title-split.mjs [on|off|status]   (default: on)

const arg = process.argv[2] ?? 'on';
const PORT = Number(process.env.CDP_PORT) || 9222;

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
        // During on we never mutate the .title children — only set font-size:0
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
    await ev(`(() => {
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
      // manual rerun only — clean up any previous auto observers/intervals
      if (window._tabSplitObserver) { window._tabSplitObserver.disconnect(); delete window._tabSplitObserver; }
      if (window._tabSplitInterval) { clearInterval(window._tabSplitInterval); delete window._tabSplitInterval; }
      return 'ok';
    })()`);
    console.log(`${t.id.slice(0, 8)}: on`);
  }
  ws.close();
};

const wins = await targets();
if (!wins.length) { console.error('no window.html target on port ' + PORT); process.exit(1); }
await Promise.all(wins.map(apply));