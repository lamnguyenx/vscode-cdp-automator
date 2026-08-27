// Pin Vivaldi's OS window-bar title so it stops following the active tab.
// Vivaldi drives the window title via window.html's `document.title = ...`; we write the
// desired value into the <title> element (what the OS actually displays) and then install a
// no-op setter on `document.title` so Vivaldi can never overwrite it. No observers/intervals.
//
// Usage:
//   node show-cdp-ports.mjs show                       # attach all auto-discovered (local + --ssh hosts)
//   node show-cdp-ports.mjs show <ports...>            # local ports only
//   node show-cdp-ports.mjs on     <ports...>          # pin each to "Vivaldi :<port>", then flash badge
//   node show-cdp-ports.mjs "<text>" <ports...>        # pin each to <text>, then flash badge
//   node show-cdp-ports.mjs off     <ports...>         # restore active-tab behaviour
//   node show-cdp-ports.mjs status   <ports...>        # report current lock state
//   --ssh host1,host2,...                                   # also discover & badge remote hosts
//   --refresh-node                                          # force re-discovery of remote node binaries
// Defaults: mode=on; ports auto-discovered from running processes. Numeric args are ports.
//
// Remote model: the script self-copies to each --ssh host and executes there with the remote's
// node (>= v18), so it talks to the remote's 127.0.0.1:<port> directly — no ssh -L forwarding.
// The resolved node binary per remote is cached at ~/.cache/show-cdp-ports/node-paths.json,
// keyed by resolved user@hostname:port from `ssh -G`, and only refetched when the cached path
// disappears or --refresh-node is passed. Worker mode is internal: the launcher invokes
//   VWT_HOST=<host> <node> <tmp.mjs> --worker [<orig args>]
// on the remote; the worker runs the same local discovery/attach/badge code.

import { readdirSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execSync, execFileSync, spawn } from 'node:child_process';

const argv = process.argv.slice(2);

// internal worker flags (stripped before main parsing)
const workerMode = argv.includes('--worker');
const workerHostTag = process.env.VWT_HOST || null;
const refreshNode = argv.includes('--refresh-node');
const cli = argv.filter(a => a !== '--worker' && a !== '--refresh-node');

// parse --ssh host1,host2,... and everything else as positional args
const sshHosts = [];
const positional = [];
let time = null;
for (let i = 0; i < cli.length; i++) {
  if (cli[i] === '--ssh') {
    if (cli[i + 1]) sshHosts.push(...cli[++i].split(',').map(s => s.trim()).filter(Boolean));
  } else if (cli[i] === '--time' && cli[i + 1]) {
    time = Number(cli[++i]);
  } else if (/^--time=(.+)$/.test(cli[i])) {
    time = Number(RegExp.$1);
  } else {
    positional.push(cli[i]);
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

// ----- badge config (~/.config/cdp-show-badge/config.json) ------------------
// Keys (all optional): time (show auto-exit seconds, default 30), opacity (0..1, default 0.7),
// width (max badge width px, default 448), position {top|bottom|left|right} px
// (default {bottom:19, right:19}). Remote workers receive it via VWT_BADGE_CFG (base64 JSON)
// from the launcher, so only the local file matters.
const BADGE_DEFAULTS = { time: 3, opacity: 0.8, width: 300, position: { bottom: 30, right: 30 } };

function loadBadgeConfig(envCfg) {
  if (envCfg) {
    try { return JSON.parse(Buffer.from(envCfg, 'base64').toString('utf8')); } catch {}
  }
  try {
    const raw = JSON.parse(readFileSync(
      path.join(os.homedir(), '.config', 'cdp-show-badge', 'config.json'), 'utf8'));
    const pos = { ...BADGE_DEFAULTS.position, ...(raw.position ?? {}) };
    if (pos.top != null) delete pos.bottom;
    if (pos.left != null) delete pos.right;
    return {
      time: raw.time ?? BADGE_DEFAULTS.time,
      opacity: raw.opacity ?? BADGE_DEFAULTS.opacity,
      width: raw.width ?? BADGE_DEFAULTS.width,
      position: pos,
    };
  } catch {
    return { ...BADGE_DEFAULTS, position: { ...BADGE_DEFAULTS.position } };
  }
}

const badgeCfg = loadBadgeConfig(process.env.VWT_BADGE_CFG);

// show mode defaults to a configurable auto-exit so a killed parent can never orphan a worker
// (local or remote): the worker's own timer self-terminates it. --time overrides.
if (mode === 'show' && !time) time = badgeCfg.time;

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

// ----- remote execution (no port forwarding) --------------------------------
// We self-copy this script to the remote and run it there with the remote's node, so the
// worker talks to the remote's 127.0.0.1:<port> directly. The node binary is cached per
// resolved host (user@hostname:port) in ~/.cache/show-cdp-ports/node-paths.json.

const NODE_FALLBACKS = [
  '/opt/conda/bin/node',
  '/home/linuxbrew/.linuxbrew/bin/node',
  '/usr/local/bin/node',
  '/usr/bin/node',
  '/opt/homebrew/bin/node',
];

const CACHE_DIR = path.join(os.homedir(), '.cache', 'show-cdp-ports');
const CACHE_FILE = path.join(CACHE_DIR, 'node-paths.json');

const isGoodNode = v => { const m = /^v?(\d+)/.exec((v ?? '').trim()); return !!(m && +m[1] >= 18); };

function sshExec(host, cmd, timeout = 15000) {
  return execFileSync('ssh', ['-o', 'ConnectTimeout=8', host, cmd],
    { encoding: 'utf8', timeout, stdio: ['pipe', 'pipe', 'pipe'] });
}

function loadNodeCache() {
  try { return JSON.parse(readFileSync(CACHE_FILE, 'utf8')); } catch { return {}; }
}
function saveNodeCache(c) {
  try {
    mkdirSync(CACHE_DIR, { recursive: true });
    writeFileSync(CACHE_FILE, JSON.stringify(c, null, 2));
  } catch {}
}

// resolve ssh alias -> cache key (user@hostname:port via `ssh -G`)
function resolveSSHHost(alias) {
  try {
    const g = execFileSync('ssh', ['-G', alias], { encoding: 'utf8', timeout: 10000, stdio: ['pipe', 'pipe', 'pipe'] });
    const get = re => { const m = g.match(re); return m ? m[1] : null; };
    const user = get(/^user (.+)$/m) || process.env.USER || '';
    const host = get(/^hostname (.+)$/m) || alias;
    const port = get(/^port (\d+)$/m) || '22';
    return `${user}@${host}:${port}`;
  } catch {
    return alias;
  }
}

// resolve (or rediscover) a usable node binary for `host`. Returns path or null.
function resolveRemoteNode(host, key, refresh = false) {
  const cache = loadNodeCache();
  const entry = cache[key];
  if (!refresh && entry && entry.node) {
    try {
      const v = sshExec(host, `test -x "${entry.node}" && "${entry.node}" --version`, 10000).trim();
      if (isGoodNode(v)) return entry.node;
    } catch {}
    console.error(`[${host}] cache miss: node at "${entry.node}" gone/unusable — refetching`);
  } else if (refresh) {
    console.error(`[${host}] --refresh-node: forcing re-discovery`);
  }
  let node = null;
  try {
    // .bashrc early-returns on non-TTY; `bash -ic` forces interactive rc sourcing (conda/brew).
    const out = sshExec(host, 'bash -ic "command -v node" 2>/dev/null', 15000)
      .split('\n').map(s => s.trim()).filter(Boolean);
    const cand = out[out.length - 1];
    if (cand) { const v = sshExec(host, `"${cand}" --version`, 10000).trim(); if (isGoodNode(v)) node = cand; }
  } catch {}
  if (!node) {
    for (const p of NODE_FALLBACKS) {
      try { const v = sshExec(host, `test -x "${p}" && "${p}" --version`, 10000).trim(); if (isGoodNode(v)) { node = p; break; } } catch {}
    }
  }
  if (!node) { console.error(`[${host}] no node >= v18 found — skipping host`); return null; }
  const version = sshExec(host, `"${node}" --version`, 10000).trim();
  cache[key] = { node, version, ts: Math.floor(Date.now() / 1000) };
  saveNodeCache(cache);
  console.error(`[${host}] cached node ${version} at ${node}`);
  return node;
}

// copy self to a unique tmp dir on the remote; returns the remote worker path
function selfCopyToRemote(host) {
  const self = readFileSync(new URL(import.meta.url), 'utf8');
  const workerPath = sshExec(host, `d=$(mktemp -d) && printf '%s' "$d/worker.mjs"`, 15000).trim();
  execFileSync('ssh', ['-o', 'ConnectTimeout=8', host, `cat > ${workerPath}`],
    { input: self, encoding: 'utf8', timeout: 15000 });
  return workerPath;
}

// spawn the worker on the remote (inherit stdio so tagged logs stream back)
function dispatchRemoteWorker(host, node, workerPath, args) {
  const esc = s => `'${String(s).replace(/'/g, `'\\''`)}'`;
  const cfgB64 = Buffer.from(JSON.stringify(badgeCfg)).toString('base64');
  const dir = workerPath.replace(/\/worker\.mjs$/, '');
  const remote = `VWT_HOST=${esc(host)} VWT_BADGE_CFG=${esc(cfgB64)} "${node}" "${workerPath}" --worker ${args.map(esc).join(' ')}; rm -f "${workerPath}"; rmdir "${dir}" 2>/dev/null`;
  const child = spawn('ssh', ['-o', 'ConnectTimeout=8', '-T', host, remote], { stdio: 'inherit' });
  child.on('error', e => console.error(`[${host}] ssh spawn error: ${e.message}`));
  return child;
}

const instances = [];
if (explicitPorts.length) {
  instances.push(...discoverLocal().filter(i => explicitPorts.includes(i.port)));
} else {
  // when no explicit ports, always include local — remote hosts are handled by spawned workers
  instances.push(...discoverLocal());
}
// worker mode: retag local instances as belonging to the remote host (badge @host + logs)
if (workerHostTag) for (const i of instances) i.host = workerHostTag;

// ----- CDP helpers -----------------------------------------------------------
const fetchJson = async (url, ms = 2000) => {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ms);
  try {
    const r = await fetch(url, { signal: ctrl.signal });
    return await r.json();
  } catch (e) {
    throw new Error(`no CDP response (${e.name === 'AbortError' ? `timeout > ${ms}ms` : e.message})`);
  } finally {
    clearTimeout(timer);
  }
};

async function targets(PORT, broad = false) {
  const list = await fetchJson(`http://127.0.0.1:${PORT}/json/list`);
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
  await new Promise((res, rej) => {
    const timer = setTimeout(() => { try { ws.close(); } catch {}; rej(new Error('WebSocket open timeout (3s)')); }, 3000);
    ws.onopen = () => { clearTimeout(timer); res(); };
    ws.onerror = () => { clearTimeout(timer); rej(new Error('WebSocket connection error')); };
  });
  const ev = async (expr) => {
    const race = new Promise((_, rej) => setTimeout(() => rej(new Error('evaluate timeout (5s)')), 5000));
    return await Promise.race([
      send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }).then(r => r?.result?.value),
      race,
    ]);
  };
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
  const OPACITY = JSON.stringify(badgeCfg.opacity);
  const MAXW = JSON.stringify(badgeCfg.width);
  const POS = JSON.stringify(badgeCfg.position);
  await ev(`(() => {
    const DURATION = 5000;
    const PERSIST = ${persist};
    const HOST = ${HOST};
    const OS = ${OS};
    const OPACITY = ${OPACITY};
    const MAXW = ${MAXW};
    const POS = ${POS};
    document.getElementById('vivaldi-launch-badge')?.remove();
    const box = document.createElement('div');
    box.id = 'vivaldi-launch-badge';
    const pos = [];
    if (POS.top != null) pos.push('top:' + POS.top + 'px');
    if (POS.bottom != null) pos.push('bottom:' + POS.bottom + 'px');
    if (POS.left != null) pos.push('left:' + POS.left + 'px');
    if (POS.right != null) pos.push('right:' + POS.right + 'px');
    box.style.cssText = 'position:fixed;' + pos.join(';') + ';z-index:2147483647;' +
      'background:rgba(18,18,22,0.94);color:#fff;font-family:"JetBrains Mono","Fira Code","SF Mono","Cascadia Code","Source Code Pro",ui-monospace,Menlo,Consolas,monospace;' +
      'border:1px solid rgba(255,255,255,0.18);border-radius:13px;padding:16px 22px 0;' +
      'min-width:176px;max-width:' + MAXW + 'px;box-shadow:0 10px 38px rgba(0,0,0,0.65);' +
      'backdrop-filter:blur(8px);overflow:hidden;transition:opacity .45s ease;opacity:0;';
    const meta = document.createElement('div');
    meta.style.cssText = 'display:flex;gap:6px;align-items:center;margin-bottom:2px;';
    if (HOST) {
      const h = document.createElement('span');
      h.textContent = '@' + HOST;
      h.style.cssText = 'font-size:11px;font-weight:600;color:#ffb84e;';
      meta.appendChild(h);
    }
    if (OS) {
      const o = document.createElement('span');
      o.textContent = OS;
      o.style.cssText = 'font-size:9px;font-weight:600;color:#7ee787;background:rgba(126,231,135,0.12);padding:0 6px;border-radius:6px;text-transform:uppercase;letter-spacing:1px;';
      meta.appendChild(o);
    }
    if (meta.children.length) box.appendChild(meta);
    const big = document.createElement('div');
    big.textContent = ':${PORT}';
    big.style.cssText = 'font-size:54px;font-weight:800;line-height:1;color:#4ea1ff;letter-spacing:-2px;';
    const sub = document.createElement('div');
    sub.textContent = 'launch args';
    sub.style.cssText = 'font-size:9px;text-transform:uppercase;letter-spacing:2px;opacity:.55;margin-top:5px;';
    const pre = document.createElement('pre');
    pre.textContent = ${ARGS}.length ? ${ARGS}.join('\\n') : '(unknown)';
    pre.style.cssText = 'margin:10px 0 14px;font-size:10px;line-height:1.5;opacity:.9;white-space:pre-wrap;word-break:break-all;';
    box.append(big, sub, pre);
    if (!PERSIST) {
      const bar = document.createElement('div');
      bar.style.cssText = 'height:3px;background:rgba(255,255,255,0.1);margin:0 -22px;';
      const fill = document.createElement('div');
      fill.style.cssText = 'height:100%;width:100%;background:#4ea1ff;';
      bar.appendChild(fill);
      box.appendChild(bar);
    } else {
      const hint = document.createElement('div');
      hint.id = 'vivaldi-launch-badge-hint';
      hint.style.cssText = 'font-size:9px;opacity:.5;margin:0 0 11px;';
      hint.textContent = ${countdown} > 0 ? 'closing in ' + ${countdown} + 's…' : 'Ctrl+C to exit';
      box.appendChild(hint);
      if (${countdown} > 0) {
        let remaining = ${countdown};
        const timer = setInterval(() => {
          if (!box.isConnected) { clearInterval(timer); return; }
          remaining = remaining - 1;
          if (remaining > 0) hint.textContent = 'closing in ' + remaining + 's…';
          else clearInterval(timer);
        }, 1000);
      }
    }
    document.body.appendChild(box);
    if (PERSIST) {
      // heartbeat watchdog: the worker refreshes __vivaldiBadgeHeartbeat every 2s; if it ever
      // stops (worker killed, ssh pipe died), the badge removes itself within ~6s.
      window.__vivaldiBadgeHeartbeat = Date.now();
      if (!window.__vivaldiBadgeWatchdog) {
        window.__vivaldiBadgeWatchdog = setInterval(() => {
          if (box.isConnected && Date.now() - window.__vivaldiBadgeHeartbeat > 6000) box.remove();
        }, 1000);
      }
    }
    requestAnimationFrame(() => {
      box.style.opacity = String(OPACITY);
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
      const hb = setInterval(() => {
        ev(`window.__vivaldiBadgeHeartbeat = Date.now()`).catch(() => {});
      }, 2000);
      attached.push({ ws, ev, hb });
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

const broad = mode === 'show';
console.log('instances:',
  instances.map(i => `${i.port}${i.host ? '@' + i.host : ''}(${i.os})`).join(' '));

if (!instances.length) {
  if (workerMode) { console.error('no --remote-debugging-port processes found on this host'); process.exit(1); }
  if (!sshHosts.length) { console.error('no --remote-debugging-port processes found (local or via --ssh)'); process.exit(1); }
}

const applyAll = async (insts) => {
  await Promise.all(insts.map(async (inst) => {
    const tag = `[${inst.port}${inst.host ? '@' + inst.host : ''}${inst.os ? ' ' + inst.os : ''}]`;
    let ts;
    try {
      ts = await targets(inst.port, broad);
    } catch (e) {
      console.error(`${tag} target unresponsive (${e.message}) — skipping`);
      return;
    }
    if (!ts.length) { console.error(`${tag} no attachable target — skipping`); return; }
    for (const t of ts) await apply(inst, t);
  }));
};

// apply to local instances (in worker mode these are the remote's own instances)
await applyAll(instances);

// launcher only: dispatch remote workers (self-copy + run on the remote). Worker mode skips this.
const remoteWorkers = [];
const remoteTmpDirs = [];
if (!workerMode && sshHosts.length) {
  for (const host of sshHosts) {
    const key = resolveSSHHost(host);
    const node = resolveRemoteNode(host, key, refreshNode);
    if (!node) continue;
    let tmp;
    try { tmp = selfCopyToRemote(host); } catch (e) { console.error(`[${host}] self-copy failed: ${e.message}`); continue; }
    remoteTmpDirs.push({ host, tmp });
    const workerArgs = [...positional];
    if (time) workerArgs.push('--time', String(time));
    remoteWorkers.push({ child: dispatchRemoteWorker(host, node, tmp, workerArgs), host, tmp });
  }
}

// cleanup — idempotent; runs on SIGINT/SIGTERM/SIGHUP or the --time timer
const cleanup = async () => {
  if (cleanup._done) return; cleanup._done = true;
  await Promise.all(attached.map(async ({ ws, ev, hb }) => {
    if (hb) clearInterval(hb);
    if (ws.readyState === WebSocket.OPEN) {
      // short deadline: a dead tunnel (killed parent) leaves the socket half-open but
      // unresponsive; the page-side heartbeat watchdog removes the badge anyway (~6s).
      const race = new Promise((_, rej) => setTimeout(() => rej(new Error('cleanup ev timeout')), 1000));
      try { await Promise.race([ev(`document.getElementById('vivaldi-launch-badge')?.remove()`), race]); } catch {}
    }
    try { ws.close(); } catch {}
  }));
  for (const { child } of remoteWorkers) { try { child.kill('SIGTERM'); } catch {} }
  for (const { host, tmp } of remoteTmpDirs) { try { sshExec(host, `rm -rf "${tmp.replace(/\/worker\.mjs$/, '')}"`, 8000); } catch {} }
  process.exit(0);
};

// register handlers up-front so kill/Ctrl+C always tears down, even while waiting on workers
process.on('SIGINT', cleanup);
process.on('SIGTERM', cleanup);
process.on('SIGHUP', cleanup);

if (time && time > 0) {
  console.log(`auto-exit in ${time}s`);
  setTimeout(cleanup, time * 1000);
}

// stay alive as long as there is something persistent (open WS connections, running workers).
// non-persistent modes (on/off/status) fall through and exit.
while (attached.length || remoteWorkers.length) {
  if (!attached.length) {
    // remote workers are the only thing keeping us up — wait for their exit
    await Promise.all(remoteWorkers.map(({ child }) => new Promise(res => child.on('exit', res))));
    break;
  }
  await new Promise(r => setTimeout(r, 500));
}
process.exit(0);
