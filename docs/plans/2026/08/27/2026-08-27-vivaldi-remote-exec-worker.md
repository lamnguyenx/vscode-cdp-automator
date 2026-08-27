# Remote-Execute Worker: Replace SSH Port Forwarding with On-Remote Execution + Node Path Cache

**Date:** 2026-08-27 · **File:** `tools/show-cdp-ports.mjs` · **Docs:** `docs/important/window-identification-and-launch-badge.md`

## Problem

1. `--ssh pp` hangs while displaying badges. Root cause: `pp` has several CDP listeners that accept TCP but never speak HTTP/WS (confirmed: ports `9024, 9032, 9330, 9334, 9338`; 9032 shows `Recv-Q=3`). The tool's `fetch` (line 169) and WS open (line 192) have **no timeouts** → infinite hang.
2. The whole port-forwarding layer (`probePort`, `ensureForward`, `tunnels[]`, port-choice collision logic) exists only to reach a remote debug port — but `pp` has **node v24.9.0** (conda/brew/miniforge), so we can just **run the script on the remote** and talk to `127.0.0.1:PORT` natively.

## Decision

**Kill the forwarding layer entirely. Self-copy the script to the remote and execute it there** with the remote's node. Cache the discovered node binary path per resolved host to avoid re-discovery ssh round-trips.

### Verified feasibility (2026-08-27, against `pp`)

| Path | Version |
|---|---|
| `/opt/conda/bin/node` | v24.9.0 |
| `/home/linuxbrew/.linuxbrew/bin/node` | v26.7.0 |
| `/data/docker/miniforge-3.12/bin/node` | v24.9.0 |

Gotcha: `ssh pp 'node --version'` **fails** (non-TTY, `.bashrc` early-returns) and `bash -lc` also fails. Only `bash -ic "command -v node"` (forces interactive rc sourcing) + explicit-path fallback list works. **Node floor: v18+** (global `fetch`/`WebSocket`/`AbortController`).

## Architecture (as implemented)

```
LAUNCHER (local node)
 ├─ local instances → run in-process (same worker code path, no ssh, no copy)
 └─ for each --ssh host:
     a. ssh -G host → resolved cache key (user@hostname:port)
     b. node ← resolveRemoteNode(host, key)
        ├─ cache hit → ssh host 'test -x && --version' (1 cheap ssh)
        │              ├─ valid & ≥v18 → reuse, no refetch
        │              └─ invalid/missing → refetch (below)
        └─ cache miss → ssh host 'bash -ic "command -v node"' + fallback list
                        → warn "cache miss pp" → write cache
     c. TMP ← ssh host 'd=$(mktemp -d) && echo $d/worker.mjs'   (dir, not --suffix)
     d. self-copy: cat self.mjs | ssh host "cat > $TMP"
     e. spawn ssh host "VWT_HOST=host VWT_BADGE_CFG=<base64> NODE TMP --worker [orig args];
        rm -f TMP; rmdir <dir>"
        stdio inherit → tagged streaming output
WORKER (remote node, same file, --worker)
 ├─ LOCAL_OS discovery (own /proc or ps)
 ├─ attach 127.0.0.1:PORT natively (no tunnels)
 ├─ inject badge DOM; host tag from VWT_HOST env, badge config from VWT_BADGE_CFG
 └─ self-cleanup: rm -f + rmdir after exit; badge removed by heartbeat watchdog if pipe dies
```

Deviations from the original sketch:
- Host tag + badge config pass via **env** (`VWT_HOST`, `VWT_BADGE_CFG` base64 JSON), not
  `--host-tag`/`--os` CLI flags (avoids shell-quoting hazards for custom titles).
- Worker file lives in a `mktemp -d` dir (portable across GNU/BSD mktemp), removed by
  `rm -f` + `rmdir` after exit; the launcher also tracks every created tmp dir and `rm -rf`s
  them in cleanup (covers the kill-between-copy-and-dispatch race).
- `show` defaults to a **3s auto-exit** (configurable via `~/.config/cdp-show-badge/config.json`)
  so a killed parent can never orphan a worker; badges also carry a page-side **heartbeat
  watchdog** (worker refreshes every 2s; badge self-removes within ~6s of it stopping), covering
  the case where the ssh pipe dies and the worker can no longer reach CDP.
- Signal handlers (SIGINT/SIGTERM/SIGHUP) are registered up-front, before any worker waits, so
  `kill`/`Ctrl+C` always tears down. Cleanup uses a 1s deadline for the badge-removal RPC so a
  half-open socket can't stall exit.

## Deletions from `tools/show-cdp-ports.mjs`

- `detectRemoteOS` (94–102)
- `discoverRemote` (104–131)
- `probePort` (143–149), `tunnels[]` (151), `ensureForward` (152–165)
- forward-and-apply loop (339–346)
- tunnel-kill in cleanup (359)
- (~80 lines net)

## Additions to `tools/show-cdp-ports.mjs`

| Function | Purpose |
|---|---|
| `workerMode` / `VWT_HOST` env | internal worker detection + host tag for the badge |
| `resolveSSHHost(alias)` | `ssh -G alias` → `${user}@${hostname}:${port}` key |
| `loadNodeCache()` / `saveNodeCache()` | `~/.cache/show-cdp-ports/node-paths.json` |
| `resolveRemoteNode(host, key)` | cache→test-x→reuse | refetch (`bash -ic` + fallback `[/opt/conda/bin/node, /home/linuxbrew/.linuxbrew/bin/node, /usr/local/bin/node, /usr/bin/node]`) → write cache + warn |
| `selfCopyToRemote(host)` | `mktemp -d` + stdin self-copy → remote worker path |
| `dispatchRemoteWorker(...)` | spawn ssh child with `VWT_HOST` + `VWT_BADGE_CFG` env, stdio inherit, remote self-clean `rm -f`+`rmdir` |
| `loadBadgeConfig()` | `~/.config/cdp-show-badge/config.json` (time/opacity/width/position), forwarded to workers via `VWT_BADGE_CFG` |
| `fetchJson()` / WS/RPC races | timeout guards for every CDP round-trip |
| heartbeat watchdog | page-side `setInterval` self-removing the badge if the worker stops refreshing |

## Timeout hardening (implemented, local + worker)

| Site | Fix |
|---|---|
| `fetch('/json/list')` | AbortController + 2s timeout (`fetchJson`) |
| WS open | 3s timeout race |
| `Runtime.evaluate` (`ev()`) | 5s timeout race |
| cleanup badge-removal RPC | 1s deadline (half-open socket must not stall exit) |

On timeout: `[PORT@host …] target unresponsive, skipping` → continue. A wedged listener becomes
a 2s skip, not a hang.

## Node cache

```json
{
  "lamnt45@localhost:9722": { "node": "/opt/conda/bin/node", "version": "v24.9.0", "ts": 1724760000 }
}
```

- Key: resolved `user@hostname:port` from `ssh -G`
- **No TTL** — only refetch when `test -x`/version check fails
- `--refresh-node` flag: discard entry, force re-discovery
- Warn on every refetch ("cache miss pp")

## CLI (as implemented)

- Keep all existing args; `--ssh h1,h2` now means "run worker on remote"
- Add `--refresh-node`
- Add `--worker` (internal marker) + `VWT_HOST`/`VWT_BADGE_CFG` env vars (internal)
- Add badge config file `~/.config/cdp-show-badge/config.json` (time/opacity/width/position)

## Doc updates (`window-identification-and-launch-badge.md`)

- Replace §"SSH port forwarding" (157–182) with §"Remote execution (no forwarding)"
- Rewrite discovery flowchart (117–133): drop `--ssh → uname` branch; add "spawn worker via ssh"
- Replace forwarding sequenceDiagram (164–182) with self-copy + worker exec sequence
- Update "Cleanup contract" (201–210): tunnel-kill → ssh SIGTERM + `rm $TMP`
- Update CLI table (222): `--ssh` → "executes on remote if node ≥18"; add `--refresh-node`
- Update "Key takeaways" (246–256): forwarding bullet → remote-exec bullet

## Status

**Implemented & verified live 2026-08-27** against `pp` (node v24.9.0 via `/opt/conda/bin`).
All items below landed; the doc `docs/important/window-identification-and-launch-badge.md` was
updated to match.

## Open items / risks (resolved)

- ~~TTY propagation of SIGINT to remote worker via ssh teardown~~ — solved differently: `show`
  defaults to a 3s auto-exit (worker carries its own `--time`), plus a page-side heartbeat
  watchdog removes the badge within ~6s if the pipe dies (even on `kill -9`).
- ~~`--worker` marker name final~~ — settled on `--worker` (with `VWT_HOST`/`VWT_BADGE_CFG` env).
- ~~Parallel `--ssh` dispatch~~ — kept sequential per host (each dispatch is a few ssh calls and
  workers run independently); tagged logs disambiguate interleaving.
