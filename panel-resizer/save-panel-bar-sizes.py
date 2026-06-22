#!/usr/bin/env python3
"""
Save VS Code sidebar & panel sizes via CDP.
Sizes are written to ~/.config/vscode/panel-and-bar-sides.json
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


def pick_target(port):
    windows = list_workbench_targets(port)
    if len(windows) == 1:
        _, t = windows[0]
        title = t.get("title", "unknown")
        print(f"One window open: {title}")
        return t["webSocketDebuggerUrl"], title

    print(f"{len(windows)} VS Code windows open:\n")
    for idx, t in windows:
        title = t.get("title", "unknown")
        print(f"  [{idx}] {title}")
    print()
    try:
        choice = int(input(f"Pick a window [0-{len(windows)-1}]: ").strip())
    except (ValueError, EOFError):
        sys.exit(1)
    if choice < 0 or choice >= len(windows):
        print("Invalid choice")
        sys.exit(1)
    t = windows[choice][1]
    return t["webSocketDebuggerUrl"], t.get("title", "unknown")


async def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9333
    ws_url, title = pick_target(port)

    async with websockets.connect(ws_url, max_size=2**20) as ws:
        await ws.send(json.dumps({"id": 0, "method": "Runtime.enable"}))
        for _ in range(200):
            if json.loads(await ws.recv()).get("id") == 0:
                break

        data = json.loads(await eval_js(ws, """
        (() => {
            const r = {};
            ['sidebar', 'panel', 'editor', 'activitybar', 'auxiliarybar'].forEach(p => {
                const el = document.querySelector('.part.' + p);
                if (el) {
                    const b = el.getBoundingClientRect();
                    r[p] = { width: Math.round(b.width), height: Math.round(b.height) };
                    if (p === 'panel') {
                        if (el.classList.contains('right')) r.panel_position = 'right';
                        else if (el.classList.contains('left')) r.panel_position = 'left';
                        else if (el.classList.contains('bottom')) r.panel_position = 'bottom';
                        else if (el.classList.contains('top')) r.panel_position = 'top';
                    }
                    if (p === 'sidebar') {
                        r.sidebar_position = el.classList.contains('right') ? 'right' : 'left';
                    }
                }
            });
            const wb = document.querySelector('.monaco-workbench');
            if (wb) {
                const b = wb.getBoundingClientRect();
                r.workbench = { width: Math.round(b.width), height: Math.round(b.height) };
            }
            return JSON.stringify(r, null, 2);
        })()
        """))

    data["_window_title"] = title

    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, "w") as f:
        json.dump(data, f, indent=2)

    print(f"\nSaved \"{title}\" to {CONFIG_PATH}:")
    print(f"  sidebar:  {data.get('sidebar', {}).get('width', '?')}px ({data.get('sidebar_position', '?')})")
    print(f"  panel:    {data.get('panel', {}).get('width', '?')}px ({data.get('panel_position', '?')})")
    print(f"  editor:   {data.get('editor', {}).get('width', '?')}px")
    print(f"  activity: {data.get('activitybar', {}).get('width', '?')}px")


if __name__ == "__main__":
    asyncio.run(main())
