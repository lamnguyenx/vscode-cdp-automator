// Combine tab number + title split + styling for Vivaldi's tab bar.
// Injects CSS and JS into window.html CDP target.
// Usage:  node vivaldi-title-split.mjs [on|off|status]   (default: on)

const arg = process.argv[2] ?? 'on';
const PORT = 9222;

async function targets() {
  const list = await fetch(`http://127.0.0.1:${PORT}/json/list`).then(r => r.json());
  return list.filter(t => (t.url ?? '').includes('window.html'));
}

const STYLE = `
.tab-strip .tab-position .favicon, .tab-strip .tab-position .tab-audio { display: none !important; } .tab-strip .tab-position .title { display: block !important; flex: 1 1 auto !important; height: auto !important; -webkit-mask-image: -webkit-linear-gradient(90deg, rgb(255,255,255) calc(100% - 30px), rgba(0,0,0,0) 100%) !important; mask-image: linear-gradient(90deg, rgb(255,255,255) calc(100% - 30px), rgba(0,0,0,0) 100%) !important; } .tab-header { height: auto !important; flex-basis: auto !important; overflow: visible !important; } .tab-position .tab { height: auto !important; flex-basis: auto !important; max-height: none !important; overflow: visible !important; } 
.tab-strip .tab-position { border-bottom: 1px solid white; }
.tab-strip { border-right: none !important; }
#tabs-tabbar-container { border-right: 1px solid white !important; }
.tab-main-title { font-weight: bold; font-size: 80%; }
.tab-subtitle { font-size: inherit; }
.tab-number { font-weight: 700; color: #8b8b8b; font-size: 80%; margin-right: 5px; }
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
      document.querySelectorAll('.tab-strip .tab-position .title').forEach(t => {
        const orig = t.getAttribute('data-orig-title');
        if (orig) t.textContent = orig;
        t.removeAttribute('data-orig-title');
      });
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
      document.querySelectorAll('.tab-strip .tab-position').forEach((pos, idx) => {
        const t = pos.querySelector('.title');
        if (!t || t.getAttribute('data-orig-title')) return;
        const txt = t.textContent;
        t.setAttribute('data-orig-title', txt);
        const num = '<span class="tab-number">' + (idx + 1) + '.</span>';
        if (txt.includes(' - ')) {
          const [first, ...rest] = txt.split(' - ');
          t.innerHTML = num + '<span class=\"tab-main-title\">' + first + '</span><br><span class=\"tab-subtitle\">' + rest.join(' - ') + '</span>';
        } else {
          t.innerHTML = num + t.textContent;
        }
      });
      return 'ok';
    })()`);
    console.log(`${t.id.slice(0, 8)}: on`);
  }
  ws.close();
};

const wins = await targets();
if (!wins.length) { console.error('no window.html target on port ' + PORT); process.exit(1); }
await Promise.all(wins.map(apply));