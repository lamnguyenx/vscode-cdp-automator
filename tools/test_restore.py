"""Test the full restore-layout flow against a specific VS Code window."""
import asyncio
import json
import sys
import urllib.request

import websockets


async def cdp_call(ws, method, params=None, call_id=99, timeout=10):
    msg = {"id": call_id, "method": method}
    if params:
        msg["params"] = params
    await ws.send(json.dumps(msg))

    deadline = asyncio.get_event_loop().time() + timeout
    while asyncio.get_event_loop().time() < deadline:
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=1.0)
        except asyncio.TimeoutError:
            continue
        resp = json.loads(raw)
        if resp.get("id") == call_id:
            return resp
    return {}


async def cdp_eval(ws, expression, timeout=10):
    resp = await cdp_call(ws, "Runtime.evaluate",
                          {"expression": expression, "returnByValue": True},
                          timeout=timeout)
    try:
        return resp["result"]["result"]["value"]
    except (KeyError, TypeError):
        return None


async def test_restore(target_ws_url, t_sidebar, t_panel):
    async with websockets.connect(target_ws_url, ping_interval=None) as ws:
        await cdp_call(ws, "Runtime.enable", call_id=0, timeout=30)

        # Step 1: solveSashMapping (same JS as Swift code)
        solve_js = """
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
        """
        mapping_raw = await cdp_eval(ws, solve_js)
        mapping = json.loads(mapping_raw) if mapping_raw else []
        print("solveSashMapping result:")
        print(json.dumps(mapping, indent=2))

        smap = {}
        for s in mapping:
            btw = s.get("between", "")
            idx = s.get("idx", -1)
            if btw in ("sidebar|editor", "editor|sidebar"):
                smap["sidebar_editor"] = idx
            elif btw in ("editor|panel", "panel|editor"):
                smap["editor_panel"] = idx

        if "sidebar_editor" not in smap:
            smap["sidebar_editor"] = 0
        if "editor_panel" not in smap:
            smap["editor_panel"] = 1

        print(f"\nsmap: {smap}")

        # Step 2: readCurrent (same JS as Swift code)
        read_js = """
        (() => {
            const r = {};
            ['sidebar', 'panel', 'editor'].forEach(p => {
                const el = document.querySelector('.part.' + p);
                if (el) r[p] = Math.round(el.getBoundingClientRect().width);
            });
            return JSON.stringify(r);
        })()
        """
        cur_raw = await cdp_eval(ws, read_js)
        cur = json.loads(cur_raw) if cur_raw else {}
        print(f"readCurrent: {cur}")

        # Step 3: compute deltas
        sb = cur.get("sidebar", 0)
        pn = cur.get("panel", 0)
        ed = cur.get("editor", 0)

        dx_p = pn - t_panel
        dx_s = t_sidebar - sb

        print(f"\nDeltas: dx_s={dx_s} (sb {sb}→{t_sidebar}), dx_p={dx_p} (panel {pn}→{t_panel})")

        # Step 4: dragSash for panel (if needed) then sidebar (if needed)
        # Panel drag
        if dx_p != 0:
            drag_js = f"""
            (() => {{
                const all = document.querySelectorAll('.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical:not(.disabled)');
                const sash = all[{smap["editor_panel"]}];
                if (!sash) return JSON.stringify({{error:'no sash at {smap["editor_panel"]}'}});
                const b = sash.getBoundingClientRect();
                const cx = b.left + b.width / 2;
                const cy = b.top + b.height / 2;
                const w = document.defaultView;
                sash.dispatchEvent(new MouseEvent('mousedown', {{bubbles: true, clientX: cx, clientY: cy, button: 0}}));
                w.dispatchEvent(new MouseEvent('mousemove',   {{bubbles: true, clientX: cx + {dx_p}, clientY: cy, button: 0}}));
                w.dispatchEvent(new MouseEvent('mouseup',     {{bubbles: true, clientX: cx + {dx_p}, clientY: cy, button: 0}}));
                return 'ok';
            }})()
            """
            result = await cdp_eval(ws, drag_js)
            print(f"Panel drag result: {result}")

        # Sidebar drag
        if dx_s != 0:
            drag_js = f"""
            (() => {{
                const all = document.querySelectorAll('.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical:not(.disabled)');
                const sash = all[{smap["sidebar_editor"]}];
                if (!sash) return JSON.stringify({{error:'no sash at {smap["sidebar_editor"]}'}});
                const b = sash.getBoundingClientRect();
                const cx = b.left + b.width / 2;
                const cy = b.top + b.height / 2;
                const w = document.defaultView;
                sash.dispatchEvent(new MouseEvent('mousedown', {{bubbles: true, clientX: cx, clientY: cy, button: 0}}));
                w.dispatchEvent(new MouseEvent('mousemove',   {{bubbles: true, clientX: cx + {dx_s}, clientY: cy, button: 0}}));
                w.dispatchEvent(new MouseEvent('mouseup',     {{bubbles: true, clientX: cx + {dx_s}, clientY: cy, button: 0}}));
                return 'ok';
            }})()
            """
            result = await cdp_eval(ws, drag_js)
            print(f"Sidebar drag result: {result}")

        # Step 5: verify
        await asyncio.sleep(0.3)
        verify_raw = await cdp_eval(ws, read_js)
        verify = json.loads(verify_raw) if verify_raw else {}
        print(f"\nAfter drag: {verify}")
        ok = verify.get("sidebar") == t_sidebar and verify.get("panel") == t_panel
        print(f"Target match: {'YES' if ok else 'NO'}")


async def main():
    port = 9333
    label_filter = "web-live-translator"

    resp = urllib.request.urlopen(f"http://localhost:{port}/json")
    targets = json.loads(resp.read())
    workbenches = [t for t in targets if (t.get("url") or "").endswith("workbench.html")]
    if label_filter:
        workbenches = [t for t in workbenches if label_filter.lower() in (t.get("title") or "").lower()]

    if not workbenches:
        print("No matching targets")
        return

    # Read saved targets from config
    config_path = "/Users/lamnt45/.config/vscode/panel-and-bar-sides.json"
    with open(config_path) as f:
        config = json.load(f)
    t_sidebar = config["sidebar"]["width"]
    t_panel = config["panel"]["width"]
    print(f"Saved layout targets: sidebar={t_sidebar}px, panel={t_panel}px")
    print(f"Saved window title: {config.get('_window_title', '?')}\n")

    for t in workbenches:
        ws_url = t.get("webSocketDebuggerUrl")
        title = t.get("title", "?")
        if ws_url:
            print(f"=== {title} ===")
            await test_restore(ws_url, t_sidebar, t_panel)
            print()


if __name__ == "__main__":
    asyncio.run(main())
