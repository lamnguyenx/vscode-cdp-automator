// Combine tab number + title split + styling for Vivaldi's tab bar.
// Injects CSS and JS into window.html CDP target.
// Usage:  node vivaldi-title-split.mjs [on|off|status]   (default: on)

const arg = process.argv[2] ?? 'on';
const PORT = 9222;

async function targets() {
  const list = await fetch(`http://127.0.0.1:${PORT}/json/list`).then(r => r.json());
  return list.filter(t => (t.url ?? '').includes('window.html'));
}

const NEW_H = 38;
const GAP = 40;
const HEIGHT_CSS = `.tab-strip .tab-position { --Height: ${NEW_H}px !important; }`;
const STYLE = `
.tab-strip .tab-position .favicon, .tab-strip .tab-position .tab-audio, .tab-strip .tab-position .page-progress-indicator { display: none !important; } .tab-strip .tab-position .title { display: block !important; flex: 1 1 auto !important; height: auto !important; -webkit-mask-image: -webkit-linear-gradient(90deg, rgb(255,255,255) calc(100% - 30px), rgba(0,0,0,0) 100%) !important; mask-image: linear-gradient(90deg, rgb(255,255,255) calc(100% - 30px), rgba(0,0,0,0) 100%) !important; } .tab-header { height: auto !important; flex-basis: auto !important; overflow: visible !important; } .tab-position .tab { height: auto !important; flex-basis: auto !important; max-height: none !important; overflow: visible !important; justify-content: center !important; }
.tab-strip .tab-position { border-bottom: 1px solid white; }
.tab-gap { position: absolute; left: 0; right: 0; height: 8px; pointer-events: none; border-bottom: 1px solid white; }
.tab-strip { border-right: none !important; }
#tabs-tabbar-container { border-right: 1px solid white !important; }
.tab-main-title { font-weight: bold; font-size: 80%; }
.tab-subtitle { font-size: inherit; }
.tab-number { font-weight: 700; color: #8b8b8b; font-size: 80%; margin-right: 0; }
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
      document.querySelectorAll('.tab-strip .tab-position').forEach(pos => { pos.style.removeProperty('--PositionY'); pos.classList.remove('tab-group-end'); });
      document.querySelectorAll('.tab-strip .tab-position .title').forEach(t => {
        const orig = t.getAttribute('data-orig-title');
        if (orig) t.textContent = orig;
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
        strip.querySelectorAll('.tab-gap').forEach(g => g.remove());
        positions.forEach(p => p.classList.remove('tab-group-end'));
        let offset = 0;
        let prevGroup = null;
        let totalGaps = 0;
        const groups = positions.map(p => {
          const t = p.querySelector('.title');
          const raw = t ? (t.getAttribute('data-orig-title') || t.textContent) : '';
          return getGroup(raw);
        });
        positions.forEach((pos, idx) => {
          const group = groups[idx];
          if (idx > 0 && group !== prevGroup) {
            offset += GAP_INNER;
            totalGaps++;
            positions[idx-1].classList.add('tab-group-end');
            const gap = document.createElement('div');
            gap.className = 'tab-gap';
            gap.style.top = (idx * NEW_H_INNER + offset - GAP_INNER) + 'px';
            gap.style.height = GAP_INNER + 'px';
            strip.appendChild(gap);
          }
          pos.style.setProperty('--PositionY', (idx * NEW_H_INNER + offset) + 'px', 'important');
          prevGroup = group;
        });
        let visibleIdx = 0;
        positions.forEach((pos) => {
          const t = pos.querySelector('.title');
          if (!t) return;
          const isNew = !t.getAttribute('data-orig-title');
          const txt = isNew ? t.textContent : t.getAttribute('data-orig-title');
          if (isNew) t.setAttribute('data-orig-title', txt);
          if (txt.trim() === 'Blank Page') {
            if (isNew) t.innerHTML = '';
            return;
          }
          visibleIdx++;
          const num = '<span class="tab-number">' + visibleIdx + '.</span>';
          if (isNew) {
            if (txt.includes(' - ')) {
              const [first, ...rest] = txt.split(' - ');
              t.innerHTML = num + '<span class="tab-main-title">' + first + '</span><br><span class="tab-subtitle">' + rest.join(' - ') + '</span>';
            } else {
              t.innerHTML = num + txt;
            }
          } else {
            const n = t.querySelector('.tab-number');
            if (n) n.textContent = visibleIdx + '.';
            else {
              if (txt.includes(' - ')) {
                const [first, ...rest] = txt.split(' - ');
                t.innerHTML = num + '<span class="tab-main-title">' + first + '</span><br><span class="tab-subtitle">' + rest.join(' - ') + '</span>';
              } else {
                t.innerHTML = num + txt;
              }
            }
          }
        });
        if (resize && resize.classList.contains('resize')) {
          const n = positions.length;
          resize.style.setProperty('max-height', (n * (NEW_H_INNER + 1) + totalGaps * GAP_INNER) + 'px');
        }
      };
      applyTabSplit();
      if (window._tabSplitObserver) { window._tabSplitObserver.disconnect(); delete window._tabSplitObserver; }
      if (window._tabSplitInterval) { clearInterval(window._tabSplitInterval); delete window._tabSplitInterval; }
      {
        let debounce;
        const debouncedApply = () => {
          clearTimeout(debounce);
          debounce = setTimeout(() => {
            window._tabSplitObserver.disconnect();
            applyTabSplit();
            window._tabSplitObserver.observe(strip, {childList:true, subtree:true, characterData:true});
          }, 300);
        };
        window._tabSplitObserver = new MutationObserver(debouncedApply);
        window._tabSplitObserver.observe(strip, {childList:true, subtree:true, characterData:true});
        window._tabSplitInterval = setInterval(applyTabSplit, 800);
      }
      const newTabBtn = document.querySelector('.toolbar.toolbar-tabbar-after .button-toolbar.newtab button');
      if (newTabBtn && !newTabBtn._tabSplitWired) {
        newTabBtn._tabSplitWired = true;
        newTabBtn.addEventListener('click', () => setTimeout(applyTabSplit, 300));
      }
      return 'ok';
    })()`);
    console.log(`${t.id.slice(0, 8)}: on`);
  }
  ws.close();
};

const wins = await targets();
if (!wins.length) { console.error('no window.html target on port ' + PORT); process.exit(1); }
await Promise.all(wins.map(apply));