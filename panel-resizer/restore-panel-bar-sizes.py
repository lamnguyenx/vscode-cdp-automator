#!/usr/bin/env python3
"""
Restore VS Code sidebar & panel sizes via CDP.
Reads target sizes from ~/.config/vscode/panel-and-bar-sides.json
"""

import asyncio, json, websockets, os, sys, urllib.request

CONFIG_PATH = os.path.expanduser("~/.config/vscode/panel-and-bar-sides.json")


async def eval_js(ws, expr, mid=99):
    await ws.send(json.dumps({"id": mid, "method": "Runtime.evaluate",
        "params": {"expression": expr, "returnByValue": True}}))
    for _ in range(500):
        m = json.loads(await ws.recv())
        if m.get("id") == mid:
            return m["result"]["result"].get("value", m["result"])


def list_workbench_targets(port):
    try:
        with urllib.request.urlopen(f"http://localhost:{port}/json", timeout=3) as f:
            targets = json.loads(f.read())
    except Exception as e:
        print(f"Cannot reach CDP on port {port}: {e}")
        sys.exit(1)
    windows = [(i, t) for i, t in enumerate(targets) if t.get("url", "").endswith("workbench.html")]
    if not windows:
        print(f"No workbench windows found on port {port}")
        sys.exit(1)
    return windows


async def get_window_sizes(ws_url):
    async with websockets.connect(ws_url, max_size=2**20) as ws:
        await ws.send(json.dumps({"id": 0, "method": "Runtime.enable"}))
        for _ in range(200):
            if json.loads(await ws.recv()).get("id") == 0:
                break
        return json.loads(await eval_js(ws, """
        (() => {
            const r = {};
            ['sidebar', 'panel', 'editor'].forEach(p => {
                const el = document.querySelector('.part.' + p);
                if (el) r[p] = Math.round(el.getBoundingClientRect().width);
            });
            return JSON.stringify(r);
        })()
        """))


async def show_window_sizes(port, windows):
    print("Current sizes across windows:\n")
    for idx, t in windows:
        title = t.get("title", "unknown")
        try:
            sizes = await get_window_sizes(t["webSocketDebuggerUrl"])
            print(f"  [{idx}] {title}")
            print(f"      sidebar={sizes.get('sidebar','?')}px  panel={sizes.get('panel','?')}px  editor={sizes.get('editor','?')}px")
        except Exception as e:
            print(f"  [{idx}] {title}  (unreachable: {e})")
    print()


async def pick_target(port, saved_title=None):
    windows = list_workbench_targets(port)
    if len(windows) == 1:
        return windows[0][1]["webSocketDebuggerUrl"]

    await show_window_sizes(port, windows)

    hint = f" (saved from \"{saved_title}\")" if saved_title else ""
    print(f"Pick a window{hint} [0-{len(windows)-1}]: ", end="", flush=True)
    try:
        choice = int(sys.stdin.readline().strip())
    except (ValueError, EOFError):
        sys.exit(1)
    if choice < 0 or choice >= len(windows):
        print("Invalid choice")
        sys.exit(1)
    return windows[choice][1]["webSocketDebuggerUrl"]


async def drag_sash(ws, sash_idx, dx):
    """Drag the sash at sash_idx (among NON-DISABLED vertical sashes)."""
    if dx == 0:
        return
    await eval_js(ws, f"""
    (() => {{
        const all = document.querySelectorAll('.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical:not(.disabled)');
        const sash = all[{sash_idx}];
        if (!sash) return JSON.stringify({{error:'no sash at {sash_idx}'}});
        const b = sash.getBoundingClientRect();
        const cx = b.left + b.width / 2;
        const cy = b.top + b.height / 2;
        const w = document.defaultView;
        sash.dispatchEvent(new MouseEvent('mousedown', {{bubbles: true, clientX: cx, clientY: cy, button: 0}}));
        w.dispatchEvent(new MouseEvent('mousemove',   {{bubbles: true, clientX: cx + {dx}, clientY: cy, button: 0}}));
        w.dispatchEvent(new MouseEvent('mouseup',     {{bubbles: true, clientX: cx + {dx}, clientY: cy, button: 0}}));
        return 'ok';
    }})()
    """)


async def solve_sash_mapping(ws):
    mapping = json.loads(await eval_js(ws, """
    (() => {
        const all = document.querySelectorAll('.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical:not(.disabled)');
        const parts = ['sidebar', 'panel', 'editor', 'activitybar', 'auxiliarybar'];
        const rects = {};
        parts.forEach(p => {
            const el = document.querySelector('.part.' + p);
            if (el) rects[p] = el.getBoundingClientRect();
        });
        const results = [];
        all.forEach((sash, i) => {
            const b = sash.getBoundingClientRect();
            const cx = b.left + b.width / 2;
            let leftName = '?', rightName = '?';
            let bestL = Infinity, bestR = Infinity;
            for (const [name, r] of Object.entries(rects)) {
                if (r.width === 0 && r.height === 0) continue;
                const dL = cx - r.right;
                const dR = r.left - cx;
                if (dL >= 0 && dL < bestL) { bestL = dL; leftName = name; }
                if (dR >= 0 && dR < bestR) { bestR = dR; rightName = name; }
            }
            results.push({ idx: i, between: leftName + '|' + rightName, cx: Math.round(cx) });
        });
        return JSON.stringify(results);
    })()
    """))
    smap = {}
    for s in mapping:
        if s["between"] in ("sidebar|editor", "editor|sidebar"):
            smap["sidebar_editor"] = s["idx"]
        elif s["between"] in ("editor|panel", "panel|editor"):
            smap["editor_panel"] = s["idx"]
    return smap


async def read_current(ws):
    return json.loads(await eval_js(ws, """
    (() => {
        const r = {};
        ['sidebar', 'panel', 'editor'].forEach(p => {
            const el = document.querySelector('.part.' + p);
            if (el) r[p] = Math.round(el.getBoundingClientRect().width);
        });
        return JSON.stringify(r);
    })()
    """))


async def main():
    if not os.path.isfile(CONFIG_PATH):
        print(f"No saved sizes at {CONFIG_PATH}. Run save-panel-bar-sizes.py first.")
        sys.exit(1)

    with open(CONFIG_PATH) as f:
        target = json.load(f)

    t_sidebar = target["sidebar"]["width"]
    t_panel = target["panel"]["width"]
    saved_title = target.get("_window_title", None)

    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9333
    ws_url = await pick_target(port, saved_title)
    print(f"Target: sidebar={t_sidebar}px  panel={t_panel}px")

    async with websockets.connect(ws_url, max_size=2**20) as ws:
        await ws.send(json.dumps({"id": 0, "method": "Runtime.enable"}))
        for _ in range(200):
            if json.loads(await ws.recv()).get("id") == 0:
                break

        smap = await solve_sash_mapping(ws)
        if "sidebar_editor" not in smap or "editor_panel" not in smap:
            smap.setdefault("sidebar_editor", 0)
            smap.setdefault("editor_panel", 1)

        cur = await read_current(ws)
        print(f"  current: sb={cur['sidebar']} panel={cur['panel']} editor={cur['editor']}")

        dx_p = cur["panel"] - t_panel
        if dx_p != 0:
            print(f"  dragging panel sash by {dx_p:+d}")
            await drag_sash(ws, smap["editor_panel"], dx_p)

        dx_s = t_sidebar - cur["sidebar"]
        if dx_s != 0:
            print(f"  dragging sidebar sash by {dx_s:+d}")
            await drag_sash(ws, smap["sidebar_editor"], dx_s)

        final = await read_current(ws)
        ok = final["sidebar"] == t_sidebar and final["panel"] == t_panel
        print(f"  final:   sb={final['sidebar']} panel={final['panel']} editor={final['editor']}  "
              f"{'OK' if ok else 'MISSING'}")


if __name__ == "__main__":
    asyncio.run(main())
