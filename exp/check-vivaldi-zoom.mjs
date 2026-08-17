const list = await fetch('http://127.0.0.1:9222/json/list').then(r => r.json());
const win = list.find(t => t.url.includes('window.html'));
if (!win) { console.log('no window.html target'); process.exit(1); }
const ws = new WebSocket(win.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (method, params) => new Promise((res, rej) => { const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })); });
ws.onmessage = (ev) => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result); } };
ws.onopen = async () => {
  const ev = (expr) => send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }).then(r => r?.result?.value);
  console.log('UI zoom:      ', await ev(`new Promise(r => window.vivaldi.zoom.getVivaldiUIZoom(x => r(JSON.stringify(x))))`));
  console.log('default zoom: ', await ev(`new Promise(r => window.vivaldi.zoom.getDefaultZoom(x => r(JSON.stringify(x))))`));
  const tabs = JSON.parse(await ev(`new Promise(r => chrome.tabs.query({}, t => r(JSON.stringify(t.map(x => ({id: x.id, url: x.url?.slice(0,60), active: x.active}))))))`));
  for (const t of tabs) {
    const z = await ev(`new Promise(r => chrome.tabs.getZoom(${t.id}, f => r(JSON.stringify(f))))`);
    console.log(`tab ${t.id} zoom=${z}${t.active ? ' [active]' : ''}  ${t.url}`);
  }
  ws.close();
};
setTimeout(() => process.exit(1), 8000);
