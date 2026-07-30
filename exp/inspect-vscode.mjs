const TARGET_ID = 'BD3D1CEF951B56654F4D0FD283D31AAF';
const WS_URL = `ws://localhost:9333/devtools/page/${TARGET_ID}`;

const ws = new WebSocket(WS_URL);
let msgId = 1;
const pending = new Map();

function send(method, params = {}) {
  const id = msgId++;
  ws.send(JSON.stringify({ id, method, params }));
  return id;
}

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg);
    pending.delete(msg.id);
  }
};

ws.onopen = async () => {
  const css = `body { max-width: 500px !important; margin: 0 auto !important; padding: 0 20px !important; }
div.mermaid-wrapper { max-width: 100vw !important; width: 100vw !important; position: relative !important; left: 50% !important; transform: translateX(-50%) !important; overflow: visible !important; }
img, video { max-width: 100vw !important; width: 100vw !important; position: relative !important; left: 50% !important; transform: translateX(-50%) !important; }`;

  const result = await cdp('Runtime.evaluate', {
    expression: `(() => { const iframe = document.getElementById('active-frame').contentDocument; const old = iframe.getElementById('_injected-text-width'); if (old) old.remove(); const style = iframe.createElement('style'); style.id = '_injected-text-width'; style.textContent = \`${css}\`; iframe.head.appendChild(style); return 'CSS re-injected'; })()`,
    returnByValue: true
  });

  console.log(JSON.stringify(result, null, 2));
  ws.close();
};

function cdp(method, params) {
  return new Promise((resolve) => {
    const id = send(method, params);
    pending.set(id, resolve);
  });
}

setTimeout(() => { ws.close(); process.exit(1); }, 5000);
