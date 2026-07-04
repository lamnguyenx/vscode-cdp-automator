"""Inspect VS Code DOM structure via CDP — sashes, parts, grid layout."""
import asyncio
import json
import sys
import urllib.request

import websockets


async def cdp_call(ws, method, params=None, call_id=99, timeout=10):
    """Send a method call and wait for the matching id response with timeout."""
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
    print(f"Timeout waiting for id={call_id} (method={method})", file=sys.stderr)
    return {}


async def cdp_eval(ws, expression):
    resp = await cdp_call(ws, "Runtime.evaluate",
                          {"expression": expression, "returnByValue": True})
    try:
        return resp["result"]["result"]["value"]
    except (KeyError, TypeError):
        print(f"Eval failed: {json.dumps(resp)[:300]}", file=sys.stderr)
        return None


async def inspect_target(ws_url, label=""):
    print(f"Connecting to {ws_url[:60]}...", file=sys.stderr)
    async with websockets.connect(ws_url, ping_interval=None) as ws:
        await cdp_call(ws, "Runtime.enable", call_id=0, timeout=30)

        js = """
        (() => {
            const r = {};

            const ndSashes = document.querySelectorAll(
                '.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical:not(.disabled)');
            const allSashes = document.querySelectorAll(
                '.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical');

            // All sashes
            r.sashes_all = [];
            allSashes.forEach((s, i) => {
                const b = s.getBoundingClientRect();
                r.sashes_all.push({
                    idx: i,
                    disabled: s.classList.contains('disabled'),
                    left: Math.round(b.left),
                    width: Math.round(b.width),
                    cx: Math.round(b.left + b.width / 2)
                });
            });

            // Non-disabled
            r.sashes_nd = [];
            ndSashes.forEach((s, i) => {
                const b = s.getBoundingClientRect();
                r.sashes_nd.push({
                    ndIdx: i,
                    left: Math.round(b.left),
                    width: Math.round(b.width),
                    cx: Math.round(b.left + b.width / 2)
                });
            });

            // Parts
            const parts = ['sidebar', 'panel', 'editor', 'activitybar', 'auxiliarybar'];
            r.parts = {};
            parts.forEach(p => {
                const el = document.querySelector('.part.' + p);
                if (el) {
                    const b = el.getBoundingClientRect();
                    r.parts[p] = {
                        left: Math.round(b.left), right: Math.round(b.right),
                        top: Math.round(b.top), bottom: Math.round(b.bottom),
                        width: Math.round(b.width), height: Math.round(b.height)
                    };
                } else {
                    r.parts[p] = null;
                }
            });

            // Map non-disabled sashes to parts
            r.sash_part_map = [];
            ndSashes.forEach((sash, i) => {
                const b = sash.getBoundingClientRect();
                const cx = b.left + b.width / 2;
                let leftName = '?', rightName = '?';
                let bestL = Infinity, bestR = Infinity;
                for (const [name, pr] of Object.entries(r.parts)) {
                    if (!pr || (pr.width === 0 && pr.height === 0)) continue;
                    const dL = cx - pr.right;
                    const dR = pr.left - cx;
                    if (dL >= -0.5 && dL < bestL) { bestL = dL; leftName = name; }
                    if (dR >= -0.5 && dR < bestR) { bestR = dR; rightName = name; }
                }
                r.sash_part_map.push({
                    ndIdx: i, between: leftName + '|' + rightName,
                    leftDist: Math.round(bestL), rightDist: Math.round(bestR)
                });
            });

            // Panel position
            const panelEl = document.querySelector('.part.panel');
            if (panelEl) {
                if (panelEl.classList.contains('right')) r.panel_position = 'right';
                else if (panelEl.classList.contains('left')) r.panel_position = 'left';
                else if (panelEl.classList.contains('bottom')) r.panel_position = 'bottom';
                else if (panelEl.classList.contains('top')) r.panel_position = 'top';
                else r.panel_position = 'unknown';

                const parentSplit = panelEl.closest('.monaco-split-view2');
                if (parentSplit) {
                    r.panel_orient = parentSplit.classList.contains('horizontal') ? 'horizontal' : 'vertical';
                }
            }

            // All grid splits
            r.grid_splits = [];
            document.querySelectorAll('.monaco-grid-view .monaco-split-view2').forEach((sv, i) => {
                const b = sv.getBoundingClientRect();
                r.grid_splits.push({
                    idx: i,
                    orient: sv.classList.contains('horizontal') ? 'H' : 'V',
                    left: Math.round(b.left), top: Math.round(b.top),
                    width: Math.round(b.width), height: Math.round(b.height),
                    sashes: sv.querySelectorAll(':scope > .sash-container > .monaco-sash').length
                });
            });

            // Workbench dimensions
            const wb = document.querySelector('.monaco-workbench');
            if (wb) {
                const b = wb.getBoundingClientRect();
                r.workbench = {
                    left: Math.round(b.left), top: Math.round(b.top),
                    width: Math.round(b.width), height: Math.round(b.height)
                };
            }

            return JSON.stringify(r, null, 2);
        })()
        """

        result = await cdp_eval(ws, js)
        if label:
            print(f"\n=== {label} ===")
        if result:
            print(result)
        else:
            print("(no result)")


async def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9333
    label_filter = sys.argv[2] if len(sys.argv) > 2 else None

    resp = urllib.request.urlopen(f"http://localhost:{port}/json")
    targets = json.loads(resp.read())
    workbenches = [t for t in targets if (t.get("url") or "").endswith("workbench.html")]

    if label_filter:
        workbenches = [t for t in workbenches if label_filter.lower() in (t.get("title") or "").lower()]

    if not workbenches:
        print("No matching workbench targets found.")
        titles = [t["title"] for t in targets if (t.get("url") or "").endswith("workbench.html")]
        print("Available:", titles)
        return

    for t in workbenches:
        ws_url = t.get("webSocketDebuggerUrl")
        if ws_url:
            title = t.get("title", "?")
            await inspect_target(ws_url, title)


if __name__ == "__main__":
    asyncio.run(main())
