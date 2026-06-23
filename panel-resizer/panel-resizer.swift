import Cocoa
import Foundation

// MARK: - Constants

let CONFIG_PATH = NSString(string: "~/.config/vscode/panel-and-bar-sides.json").expandingTildeInPath

let VSCODE_BUNDLES = [
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.microsoft.VSCodeExploration",
    "com.microsoft.VSCode.Oss",
    "com.visualstudio.code.oss",
]

// MARK: - Native window helpers

func axGetString(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? String
}

func getFrontmostVSCodeTitle() -> String? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication,
          let bid = frontApp.bundleIdentifier,
          VSCODE_BUNDLES.contains(bid)
    else { return nil }

    let appEl = AXUIElementCreateApplication(frontApp.processIdentifier)

    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, "AXFocusedWindow" as CFString, &focused) == .success,
          let fw = focused
    else { return nil }

    let win = fw as! AXUIElement

    if let title = axGetString(win, "AXTitle"), !title.isEmpty {
        return title
    }

    var main: CFTypeRef?
    if AXUIElementCopyAttributeValue(appEl, "AXMainWindow" as CFString, &main) == .success,
       let mw = main {
        return axGetString(mw as! AXUIElement, "AXTitle")
    }

    return nil
}

// MARK: - CDP helpers

func fetchTargets(port: Int) -> [[String: Any]] {
    guard let url = URL(string: "http://localhost:\(port)/json"),
          let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
        fputs("Cannot reach CDP on port \(port)\n", stderr)
        exit(1)
    }
    let windows = json.filter { ($0["url"] as? String)?.hasSuffix("workbench.html") ?? false }
    guard !windows.isEmpty else {
        fputs("No workbench windows found on port \(port)\n", stderr)
        exit(1)
    }
    return windows
}

func wsRecv(_ task: URLSessionWebSocketTask) -> String {
    let sem = DispatchSemaphore(value: 0)
    var raw = ""
    task.receive { result in
        if case .success(let msg) = result, case .string(let s) = msg { raw = s }
        sem.signal()
    }
    sem.wait()
    return raw
}

func wsSend(_ task: URLSessionWebSocketTask, _ text: String, waitForId id: Int? = nil) -> String {
    let sem = DispatchSemaphore(value: 0)
    task.send(.string(text)) { _ in sem.signal() }
    sem.wait()

    guard let mid = id else {
        return wsRecv(task)
    }

    for _ in 0..<500 {
        let raw = wsRecv(task)
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        if dict["id"] as? Int == mid { return raw }
    }
    return "{}"
}

func evalJS(_ task: URLSessionWebSocketTask, _ expression: String) -> String {
    let reqObj: [String: Any] = [
        "id": 99,
        "method": "Runtime.evaluate",
        "params": ["expression": expression, "returnByValue": true]
    ]
    guard let reqData = try? JSONSerialization.data(withJSONObject: reqObj),
          let reqStr = String(data: reqData, encoding: .utf8)
    else { return "null" }

    let raw = wsSend(task, reqStr, waitForId: 99)

    guard let data = raw.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = dict["result"] as? [String: Any],
          let inner = result["result"] as? [String: Any]
    else { return "null" }

    return inner["value"] as? String ?? "null"
}

func enableRuntime(_ task: URLSessionWebSocketTask) {
    _ = wsSend(task, "{\"id\":0,\"method\":\"Runtime.enable\"}", waitForId: 0)
}

func newWebSocket(_ urlStr: String) -> URLSessionWebSocketTask? {
    guard let url = URL(string: urlStr) else { return nil }
    let task = URLSession.shared.webSocketTask(with: url)
    task.resume()
    return task
}

// MARK: - Save

func cmdSave(port: Int) {
    guard let activeTitle = getFrontmostVSCodeTitle() else {
        fputs("Frontmost app is not VS Code.\n", stderr)
        exit(1)
    }

    let windows = fetchTargets(port: port)

    guard let t = windows.first(where: { ($0["title"] as? String) == activeTitle })
            ?? windows.first,
          let wsUrl = t["webSocketDebuggerUrl"] as? String,
          let task = newWebSocket(wsUrl)
    else { exit(1) }
    defer { task.cancel(with: .normalClosure, reason: nil) }

    let title = (t["title"] as? String) ?? "unknown"
    print("Saving from: \(title)")

    enableRuntime(task)

    let raw = evalJS(task, """
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
    """)

    guard let rawData = raw.data(using: .utf8),
          var data = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any]
    else { exit(1) }

    data["_window_title"] = title

    let dir = (CONFIG_PATH as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted)
    else { exit(1) }
    try? jsonData.write(to: URL(fileURLWithPath: CONFIG_PATH), options: .atomic)

    let sidebar = (data["sidebar"] as? [String: Any])?["width"] ?? "?"
    let panel = (data["panel"] as? [String: Any])?["width"] ?? "?"
    let editor = (data["editor"] as? [String: Any])?["width"] ?? "?"
    let activity = (data["activitybar"] as? [String: Any])?["width"] ?? "?"
    let sbPos = data["sidebar_position"] as? String ?? "?"
    let pnPos = data["panel_position"] as? String ?? "?"

    print("\nSaved \"\(title)\" to \(CONFIG_PATH):")
    print("  sidebar:  \(sidebar)px (\(sbPos))")
    print("  panel:    \(panel)px (\(pnPos))")
    print("  editor:   \(editor)px")
    print("  activity: \(activity)px")
}

// MARK: - Restore

func readCurrent(_ task: URLSessionWebSocketTask) -> [String: Int] {
    let raw = evalJS(task, """
    (() => {
        const r = {};
        ['sidebar', 'panel', 'editor'].forEach(p => {
            const el = document.querySelector('.part.' + p);
            if (el) r[p] = Math.round(el.getBoundingClientRect().width);
        });
        return JSON.stringify(r);
    })()
    """)
    guard let data = raw.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
    else { return [:] }
    return dict
}

func solveSashMapping(_ task: URLSessionWebSocketTask) -> [String: Int] {
    let raw = evalJS(task, """
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
    """)
    var smap: [String: Int] = [:]
    guard let data = raw.data(using: .utf8),
          let mapping = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return smap }
    for s in mapping {
        guard let btw = s["between"] as? String, let idx = s["idx"] as? Int else { continue }
        if btw == "sidebar|editor" || btw == "editor|sidebar" { smap["sidebar_editor"] = idx }
        else if btw == "editor|panel" || btw == "panel|editor" { smap["editor_panel"] = idx }
    }
    return smap
}

func dragSash(_ task: URLSessionWebSocketTask, sashIdx: Int, dx: Int) {
    guard dx != 0 else { return }
    _ = evalJS(task, """
    (() => {
        const all = document.querySelectorAll('.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical:not(.disabled)');
        const sash = all[\(sashIdx)];
        if (!sash) return JSON.stringify({error:'no sash at \(sashIdx)'});
        const b = sash.getBoundingClientRect();
        const cx = b.left + b.width / 2;
        const cy = b.top + b.height / 2;
        const w = document.defaultView;
        sash.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, clientX: cx, clientY: cy, button: 0}));
        w.dispatchEvent(new MouseEvent('mousemove',   {bubbles: true, clientX: cx + \(dx), clientY: cy, button: 0}));
        w.dispatchEvent(new MouseEvent('mouseup',     {bubbles: true, clientX: cx + \(dx), clientY: cy, button: 0}));
        return 'ok';
    })()
    """)
}

func restoreWindow(wsUrl: String, tSidebar: Int, tPanel: Int, label: String) {
    let prefix = label.isEmpty ? "" : "[\(label)] "
    guard let task = newWebSocket(wsUrl) else { return }
    defer { task.cancel(with: .normalClosure, reason: nil) }

    enableRuntime(task)

    var smap = solveSashMapping(task)
    if smap["sidebar_editor"] == nil { smap["sidebar_editor"] = 0 }
    if smap["editor_panel"] == nil { smap["editor_panel"] = 1 }

    let cur = readCurrent(task)
    let sb = cur["sidebar"] ?? 0
    let pn = cur["panel"] ?? 0
    let ed = cur["editor"] ?? 0
    print("\(prefix)current: sb=\(sb) panel=\(pn) editor=\(ed)")

    let dx_p = pn - tPanel
    if dx_p != 0 {
        let sign = dx_p > 0 ? "+" : ""
        print("\(prefix) dragging panel sash by \(sign)\(dx_p)")
        dragSash(task, sashIdx: smap["editor_panel"]!, dx: dx_p)
    }

    let dx_s = tSidebar - sb
    if dx_s != 0 {
        let sign = dx_s > 0 ? "+" : ""
        print("\(prefix) dragging sidebar sash by \(sign)\(dx_s)")
        dragSash(task, sashIdx: smap["sidebar_editor"]!, dx: dx_s)
    }

    let final = readCurrent(task)
    let fsb = final["sidebar"] ?? 0
    let fpn = final["panel"] ?? 0
    let fed = final["editor"] ?? 0
    let ok = fsb == tSidebar && fpn == tPanel
    print("\(prefix)final:   sb=\(fsb) panel=\(fpn) editor=\(fed)  \(ok ? "OK" : "MISSING")")
}

func cmdRestore(port: Int) {
    guard FileManager.default.fileExists(atPath: CONFIG_PATH) else {
        fputs("No saved sizes at \(CONFIG_PATH). Run 'panel-resizer save' first.\n", stderr)
        exit(1)
    }

    guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: CONFIG_PATH)),
          let target = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let sidebar = target["sidebar"] as? [String: Any],
          let panel = target["panel"] as? [String: Any]
    else { exit(1) }

    let tSidebar = sidebar["width"] as? Int ?? 0
    let tPanel = panel["width"] as? Int ?? 0

    let windows = fetchTargets(port: port)
    print("Restoring \(windows.count) window(s) to sidebar=\(tSidebar)px  panel=\(tPanel)px\n")

    for (idx, t) in windows.enumerated() {
        guard let wsUrl = t["webSocketDebuggerUrl"] as? String else { continue }
        let title = (t["title"] as? String) ?? "unknown"
        print("[\(idx)] \(title)")
        restoreWindow(wsUrl: wsUrl, tSidebar: tSidebar, tPanel: tPanel, label: "\(idx)")
        print("")
    }
}

// MARK: - Main

func usage() -> Never {
    let prog = (CommandLine.arguments[0] as NSString).lastPathComponent
    print("Usage:")
    print("  \(prog) save [port]     Save layout of the active VS Code window")
    print("  \(prog) restore [port]  Restore saved layout to all VS Code windows")
    print("")
    print("Default port: 9333")
    print("Config: ~/.config/vscode/panel-and-bar-sides.json")
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

let port: Int = {
    if args.count >= 3, let p = Int(args[2]) { return p }
    return 9333
}()

switch args[1] {
case "save":
    cmdSave(port: port)
case "restore":
    cmdRestore(port: port)
default:
    usage()
}
