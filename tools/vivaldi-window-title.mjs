// Pin Vivaldi's OS window-bar title so it stops following the active tab.
// Vivaldi drives the window title via window.html's `document.title = ...`; we write the
// desired value into the <title> element (what the OS actually displays) and then install a
// no-op setter on `document.title` so Vivaldi can never overwrite it. No observers/intervals.
// Usage:
//   node vivaldi-window-title.mjs show                       # attach all auto-discovered (local + --ssh hosts)
//   node vivaldi-window-title.mjs show <ports...>            # local ports only
//   node vivaldi-window-title.mjs on     <ports...>          # pin each to "Vivaldi :<port>", then flash badge
//   node vivaldi-window-title.mjs "<text>" <ports...>        # pin each to <text>, then flash badge
//   node vivaldi-window-title.mjs off     <ports...>         # restore active-tab behaviour
//   node vivaldi-window-title.mjs status   <ports...>        # report current lock state
//   --ssh host1,host2,...                                   # also discover & show badges on remote hosts
// Defaults: mode=on; ports auto-discovered from running processes. Numeric args are ports.
// Local discovery reads /proc (Linux); remote discovery uses `ssh host "ps -eo command="`.
// Remote CDP is reached via an on-demand `ssh -L` forward (reused if already forwarded).

import { readdirSync, readFileSync } from 'node:fs';
import net from 'node:net';
import { execSync, spawn } from 'node:child_process';

const argv = process.argv.slice(2);

// parse --ssh host1,host2,... and everything else as positional args
const sshHosts = [];
const positional = [];
let time = null;
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--ssh') {
    if (argv[i + 1]) sshHosts.push(...argv[++i].split(',').map(s => s.trim()).filter(Boolean));
  } else if (argv[i] === '--time' && argv[i + 1]) {
    time = Number(argv[++i]);
  } else if (/^--time=(.+)$/.test(argv[i])) {
    time = Number(RegExp.$1);
  } else {
    positional.push(argv[i]);
  }
}

const explicitPorts = positional.filter(a => /^\d+$/.test(a)).map(Number);
const words = positional.filter(a => !/^\d+$/.test(a));
let mode = 'on';
let custom = null;
if (words.length) {
  if (/^(on|off|status|show)$/i.test(words[0])) {
    mode = words[0].toLowerCase();
    const w2 = words.slice(1);
    if (w2.length) custom = w2.join(' ');
  } else {
    custom = words.join(' ');
  }
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ----- discovery -------------------------------------------------------------
// returns [{ host, port, args, os }]  (host null = local)
const LOCAL_OS = process.platform === 'darwin' ? 'macos' : 'linux';

function discoverLocal() {
  const out = [];
  if (LOCAL_OS === 'linux') {
    try {
      for (const pid of readdirSync('/proc').filter(d => /^\d+$/.test(d))) {
        let raw;
        try { raw = readFileSync(`/proc/${pid}/cmdline`, 'utf8'); } catch { continue; }
        const parts = raw.replace(/\0/g, ' ').trim().split(/\s+/).filter(Boolean);
        if (parts.length < 2 || parts.join(' ').includes('--type=')) continue;
        const s = parts.join(' ');
        const m = s.match(/--remote-debugging-port=(\d+)/);
        if (m) out.push({ host: null, port: Number(m[1]), args: parts.slice(1), os: 'linux' });
      }
    } catch {}
  } else {
    // macOS local — no /proc, use ps
    for (const inst of parsePs(execSync('ps -eo command=', { encoding: 'utf8' }), null, 'macos')) out.push(inst);
  }
  return out;
}

function parsePs(text, host, os) {
  const out = [];
  for (const line of text.split('\n')) {
    if (!line.includes('--remote-debugging-port') || line.includes('--type=')) continue;
    const parts = line.trim().split(/\s+/).filter(Boolean);
    const m = line.match(/--remote-debugging-port=(\d+)/);
    if (!m) continue;
    const firstFlag = parts.findIndex(p => p.startsWith('--'));
    const args = firstFlag >= 0 ? parts.slice(firstFlag) : parts.slice(1);
    out.push({ host, port: Number(m[1]), args, os });
  }
  return out;
}

function detectRemoteOS(host) {
  try {
    const u = execSync(`ssh -o ConnectTimeout=8 ${host} "uname -s"`,
      { encoding: 'utf8', timeout: 15000, stdio: ['pipe', 'pipe', 'pipe'] }).trim();
    return u === 'Darwin' ? 'macos' : 'linux';
  } catch {
    return null;
  }
}

function discoverRemote(host) {
  const os = detectRemoteOS(host);
  if (!os) { console.error(`[${host}] could not detect OS`); return []; }
  let out = [];
  if (os === 'linux') {
    try {
      // /proc gives null-separated args → one line per process
      const data = execSync(
        `ssh -o ConnectTimeout=8 ${host} 'for d in /proc/[0-9]*; do f="$d/cmdline"; [ -r "$f" ] && { tr "\\\\0" " " < "$f"; echo; }; done 2>/dev/null'`,
        { encoding: 'utf8', timeout: 15000, stdio: ['pipe', 'pipe', 'pipe'] });
      for (const line of data.split('\n')) {
        if (!line.includes('--remote-debugging-port') || line.includes('--type=')) continue;
        const parts = line.trim().split(/\s+/).filter(Boolean);
        const m = line.match(/--remote-debugging-port=(\d+)/);
        if (!m) continue;
        out.push({ host, port: Number(m[1]), args: parts.slice(1), os });
      }
    } catch (e) { console.error(`[${host}] /proc scan failed: ${e.message}`); }
  } else {
    // macOS — use ps
    try {
      const data = execSync(`ssh -o ConnectTimeout=8 ${host} "ps -eo command="`,
        { encoding: 'utf8', timeout: 15000, stdio: ['pipe', 'pipe', 'pipe'] });
      out = parsePs(data, host, os);
    } catch (e) { console.error(`[${host}] ssh/ps failed: ${e.message}`); }
  }
  return out;
}

const instances = [];
if (explicitPorts.length) {
  instances.push(...discoverLocal().filter(i => explicitPorts.includes(i.port)));
} else {
  // when no explicit ports, always include local — --ssh hosts are additive
  instances.push(...discoverLocal());
}
for (const host of sshHosts) instances.push(...discoverRemote(host));

// ----- port forwarding (for remote hosts) ------------------------------------
function probePort(port, host = '127.0.0.1') {
  return new Promise(res => {
    const s = net.connect({ host, port }, () => { s.end(); res(true); });
    s.on('error', () => res(false));
    setTimeout(() => { s.destroy(); res(false); }, 400);
  });
}

const tunnels = [];
async function ensureForward(host, remotePort) {
  if (await probePort(remotePort)) return true;     // already listening (pre-existing forward)
  const child = spawn('ssh', ['-N', '-o', 'ExitOnForwardFailure=yes', '-o', 'ConnectTimeout=8',
    '-o', 'ServerAliveInterval=30',
    '-L', `127.0.0.1:${remotePort}:127.0.0.1:${remotePort}`, host],
    { stdio: ['ignore', 'ignore', 'ignore'] });
  tunnels.push(child);
  for (let i = 0; i < 80; i++) {
    if (child.exitCode !== null) return false;
    if (await probePort(remotePort)) return true;
    await sleep(100);
  }
  return false;
}

// ----- CDP helpers -----------------------------------------------------------
async function targets(PORT, broad = false) {
  const list = await fetch(`http://127.0.0.1:${PORT}/json/list`).then(r => r.json());
  const wins = list.filter(t => t.type === 'app' && (t.url ?? '').includes('window.html'));
  if (wins.length) return wins;
  if (!broad) return [];
  return list.filter(t => t.type === 'page' && t.webSocketDebuggerUrl).slice(0, 1);
}

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

const dropOver = async (ev) => ev(`(() => {
  try { delete document.title; } catch (e) {}
  delete window.__fixedWindowTitle;
  const t = document.querySelector('title');
  if (t) {
    try { delete t.textContent; } catch (e) {}
    try { delete t.innerText; } catch (e) {}
    const fresh = document.createElement('title');
    t.replaceWith(fresh);
  }
  return 'cleared';
})()`);

const flashArgs = async (ev, PORT, args, host = null, os = null, persist = false, countdown = 0) => {
  const ARGS = JSON.stringify(args ?? []);
  const HOST = JSON.stringify(host ?? '');
  const OS = JSON.stringify(os ?? '');
  await ev(`(() => {
    const DURATION = 5000;
    const PERSIST = ${persist};
    const HOST = ${HOST};
    const OS = ${OS};
    document.getElementById('vivaldi-launch-badge')?.remove();
    const box = document.createElement('div');
    box.id = 'vivaldi-launch-badge';
    box.style.cssText = 'position:fixed;bottom:24px;right:24px;z-index:2147483647;' +
      'background:rgba(18,18,22,0.94);color:#fff;font-family:"JetBrains Mono","Fira Code","SF Mono","Cascadia Code","Source Code Pro",ui-monospace,Menlo,Consolas,monospace;' +
      'border:1px solid rgba(255,255,255,0.18);border-radius:16px;padding:20px 28px 0;' +
      'min-width:220px;max-width:560px;box-shadow:0 12px 48px rgba(0,0,0,0.65);' +
      'backdrop-filter:blur(8px);overflow:hidden;transition:opacity .45s ease;opacity:0;';
    const meta = document.createElement('div');
    meta.style.cssText = 'display:flex;gap:8px;align-items:center;margin-bottom:2px;';
    if (HOST) {
      const h = document.createElement('span');
      h.textContent = '@' + HOST;
      h.style.cssText = 'font-size:14px;font-weight:600;color:#ffb84e;';
      meta.appendChild(h);
    }
    if (OS) {
      const o = document.createElement('span');
      o.textContent = OS;
      o.style.cssText = 'font-size:11px;font-weight:600;color:#7ee787;background:rgba(126,231,135,0.12);padding:1px 8px;border-radius:8px;text-transform:uppercase;letter-spacing:1px;';
      meta.appendChild(o);
    }
    if (meta.children.length) box.appendChild(meta);
    const big = document.createElement('div');
    big.textContent = ':${PORT}';
    big.style.cssText = 'font-size:68px;font-weight:800;line-height:1;color:#4ea1ff;letter-spacing:-2px;';
    const sub = document.createElement('div');
    sub.textContent = 'launch args';
    sub.style.cssText = 'font-size:11px;text-transform:uppercase;letter-spacing:2px;opacity:.55;margin-top:6px;';
    const pre = document.createElement('pre');
    pre.textContent = ${ARGS}.length ? ${ARGS}.join('\\n') : '(unknown)';
    pre.style.cssText = 'margin:12px 0 18px;font-size:13px;line-height:1.5;opacity:.9;white-space:pre-wrap;word-break:break-all;';
    box.append(big, sub, pre);
    if (!PERSIST) {
      const bar = document.createElement('div');
      bar.style.cssText = 'height:4px;background:rgba(255,255,255,0.1);margin:0 -28px;';
      const fill = document.createElement('div');
      fill.style.cssText = 'height:100%;width:100%;background:#4ea1ff;';
      bar.appendChild(fill);
      box.appendChild(bar);
    } else {
      const hint = document.createElement('div');
      hint.textContent = ${countdown} > 0 ? 'closing in ' + ${countdown} + 's…' : 'Ctrl+C to exit';
      hint.id = 'vivaldi-launch-badge-hint';
      hint.style.cssText = 'font-size:11px;opacity:.5;margin:0 0 14px;';
      box.appendChild(hint);
    }
    document.body.appendChild(box);
    requestAnimationFrame(() => {
      box.style.opacity = '1';
      if (!PERSIST) {
        const fill = box.lastChild.querySelector('div');
        fill.style.transition = 'width ' + DURATION + 'ms linear';
        fill.style.width = '0%';
      }
    });
    if (!PERSIST) setTimeout(() => { box.style.opacity = '0'; setTimeout(() => box.remove(), 500); }, DURATION);
    return 'shown';
  })()`);
};

const attached = [];

const apply = async (inst, t) => {
  const { host, port: PORT, args, os } = inst;
  const { ws, ev } = await attach(t.webSocketDebuggerUrl);
  const tag = `[${PORT}${host ? '@' + host : ''}${os ? ' ' + os : ''} ${t.id.slice(0, 8)}]`;
  let keepAlive = false;
  try {
    if (mode === 'status') {
      const s = await ev(`(() => {
        const d = Object.getOwnPropertyDescriptor(document, 'title');
        const locked = !!(d && d.get);
        return JSON.stringify({ locked, fixed: window.__fixedWindowTitle ?? null,
          titleEl: document.querySelector('title')?.textContent ?? null });
      })()`);
      console.log(`${tag} ${s}`);
    } else if (mode === 'off') {
      await dropOver(ev);
      const tt = await ev(`(new Promise(r => chrome.tabs.query({ active:true, currentWindow:true },
        tabs => { const tt = tabs && tabs[0] && tabs[0].title || 'Vivaldi';
          document.title = tt; r(tt); })))`);
      console.log(`${tag} off → restored "${tt}"`);
    } else if (mode === 'show') {
      await flashArgs(ev, PORT, args, host, os, true, time);
      console.log(`${tag} showed ${args ? args.length + ' args' : 'unknown'}${time ? ` (${time}s)` : ''} (attached — Ctrl+C to exit)`);
      attached.push({ ws, ev });
      keepAlive = true;
      return;
    } else {
      await dropOver(ev);
      const TITLE = custom ?? `Vivaldi :${PORT}`;
      const ok = await ev(`(() => {
        const F = ${JSON.stringify(TITLE)};
        const t = document.querySelector('title');
        if (t) t.textContent = F;
        try { Object.defineProperty(document, 'title', { configurable: true, get: () => F, set() {} }); } catch (e) {}
        window.__fixedWindowTitle = F;
        return document.querySelector('title')?.textContent ?? null;
      })()`);
      await flashArgs(ev, PORT, args, host, os);
      console.log(`${tag} on → pinned "${ok}"`);
    }
  } catch (e) {
    console.error(`${tag} error: ${e.message}`);
  } finally {
    if (!keepAlive) ws.close();
  }
};

if (!instances.length) {
  console.error('no --remote-debugging-port processes found (local or via --ssh)');
  process.exit(1);
}

// ensure forwards for remote instances, then apply
const broad = mode === 'show';
console.log('instances:',
  instances.map(i => `${i.port}${i.host ? '@' + i.host : ''}(${i.os})`).join(' '));

const ready = [];
for (const inst of instances) {
  if (inst.host) {
    const ok = await ensureForward(inst.host, inst.port);
    if (!ok) { console.error(`[${inst.port}@${inst.host}] forward failed; skipping`); continue; }
  }
  ready.push(inst);
}

await Promise.all((await Promise.all(ready.map(async (inst) =>
  (await targets(inst.port, broad)).map(t => [inst, t])
))).flat().map(([inst, t]) => apply(inst, t)));

// cleanup
const cleanup = async () => {
  if (cleanup._done) return; cleanup._done = true;
  await Promise.all(attached.map(async ({ ws, ev }) => {
    try { await ev(`document.getElementById('vivaldi-launch-badge')?.remove()`); } catch {}
    try { ws.close(); } catch {}
  }));
  for (const c of tunnels) { try { c.kill('SIGTERM'); } catch {} }
  process.exit(0);
};
process.on('SIGINT', cleanup);
process.on('SIGTERM', cleanup);

if (attached.length && time && time > 0) {
  console.log(`auto-exit in ${time}s`);
  setTimeout(cleanup, time * 1000);
}
