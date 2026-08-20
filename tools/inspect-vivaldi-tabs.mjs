const list = await fetch('http://127.0.0.1:9222/json/list').then(r => r.json());
const win = list.find(t => t.url.includes('window.html'));
if (!win) { console.log('no window.html target'); process.exit(1); }
const ws = new WebSocket(win.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (method, params) => new Promise((res, rej) => { const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })); });
ws.onmessage = (ev) => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result); } };
ws.onopen = async () => {
  const ev = async (expr) => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }))?.result?.value;
  const info = await ev(`(() => {
    const strip = document.querySelector('.tab-strip');
    const tabs = [...strip.querySelectorAll('.tab-position')];
    return JSON.stringify(tabs.map((t, i) => {
      const titleEl = t.querySelector('.title');
      return { i, cls: t.className.slice(0,80), title: titleEl ? titleEl.textContent : null,
               titleHtml: titleEl ? titleEl.outerHTML.slice(0,300) : null,
               tabId: t.getAttribute('data-tab-id') };
    }), null, 2);
  })()`);
  console.log(info);
  ws.close();
};
setTimeout(() => process.exit(1), 8000);
