// Show tab order numbers in Vivaldi's tab bar (via the window.html CDP target).
// Pure-CSS trick: a counter-reset/increment rule + a ::before on .title, so the
// real tab-title text is untouched. Survives React re-renders and renumbers on
// reorder/close/new-tab. Not persisted — re-inject after a browser restart.
//
// Usage:  node vivaldi-tab-numbers.mjs [on|off|status]   (default: on)

const arg = process.argv[2] ?? 'on';
const PORT = 9222;

async function targets() {
  const list = await fetch(`http://127.0.0.1:${PORT}/json/list`).then(r => r.json());
  return list.filter(t => (t.url ?? '').includes('window.html'));
}

const STYLE = `
.tab-strip { counter-reset: tabidx; }
.tab-strip .tab-position { counter-increment: tabidx; }
.tab-strip .tab-position .title::before { content: counter(tabidx) ". "; margin-right: 5px; font-weight: 700; color: #8b8b8b; }
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
  const style = `document.getElementById('tab-order-numbers')?.textContent ?? null`;
  if (arg === 'status') {
    const st = await ev(`(() => { const el = document.getElementById('tab-order-numbers'); return el ? 'on' : 'off'; })()`);
    console.log(`${t.id.slice(0, 8)}: numbers ${st}`);
  } else if (arg === 'off') {
    await ev(`(() => { const el = document.getElementById('tab-order-numbers'); if (el) el.remove(); return 'ok'; })()`);
    console.log(`${t.id.slice(0, 8)}: numbers off`);
  } else {
    await ev(`(() => {
      let el = document.getElementById('tab-order-numbers');
      if (!el) { el = document.createElement('style'); el.id = 'tab-order-numbers'; document.head.appendChild(el); }
      el.textContent = ${JSON.stringify(STYLE)};
      return 'ok';
    })()`);
    console.log(`${t.id.slice(0, 8)}: numbers on`);
  }
  ws.close();
};

const wins = await targets();
if (!wins.length) { console.error('no window.html target on port ' + PORT); process.exit(1); }
await Promise.all(wins.map(apply));