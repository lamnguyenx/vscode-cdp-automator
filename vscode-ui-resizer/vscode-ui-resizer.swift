import Cocoa
import Foundation

// MARK: - Constants

let VSCODE_BUNDLES = [
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.microsoft.VSCodeExploration",
    "com.microsoft.VSCode.Oss",
    "com.visualstudio.code.oss",
]

let WIN_CONFIG_PATH = NSString(string: "~/.config/vscode/windows.json").expandingTildeInPath
let LAYOUT_CONFIG_PATH = NSString(string: "~/.config/vscode/panel-and-bar-sides.json").expandingTildeInPath

// MARK: - Window Data

struct WindowInfo: Codable {
    let title: String
    let pid: Int32
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let screenFrame: String
    let screenRelativeX: Double?
    let screenRelativeY: Double?
    let label: String
}

func resolveGlobalPosition(from info: WindowInfo) -> CGPoint {
    if let rx = info.screenRelativeX, let ry = info.screenRelativeY {
        for screen in NSScreen.screens {
            let f = screen.frame
            let frameStr = "x=\(Int(f.origin.x)) y=\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"
            if frameStr == info.screenFrame {
                return CGPoint(x: f.origin.x + rx, y: f.origin.y + ry)
            }
        }
        if let primary = NSScreen.screens.first {
            let f = primary.frame
            return CGPoint(x: f.origin.x + rx, y: f.origin.y + ry)
        }
    }
    return CGPoint(x: info.x, y: info.y)
}

func isPositionOnScreen(_ pt: CGPoint) -> Bool {
    return NSScreen.screens.contains(where: { $0.frame.contains(pt) })
}

// MARK: - Accessibility Helpers

func axGetString(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? String
}

func axGetArray(_ el: AXUIElement, _ attr: String) -> [AXUIElement]? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? [AXUIElement]
}

func axGetPoint(_ el: AXUIElement, _ attr: String) -> CGPoint? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    var pt = CGPoint.zero
    guard AXValueGetValue(v as! AXValue, .cgPoint, &pt) else { return nil }
    return pt
}

func axGetSize(_ el: AXUIElement, _ attr: String) -> CGSize? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    var sz = CGSize.zero
    guard AXValueGetValue(v as! AXValue, .cgSize, &sz) else { return nil }
    return sz
}

func axSetPoint(_ el: AXUIElement, _ attr: String, _ pt: CGPoint) {
    var p = pt
    if let val = withUnsafePointer(to: &p, { AXValueCreate(.cgPoint, $0) }) {
        AXUIElementSetAttributeValue(el, attr as CFString, val)
    }
}

func axSetSize(_ el: AXUIElement, _ attr: String, _ sz: CGSize) {
    var s = sz
    if let val = withUnsafePointer(to: &s, { AXValueCreate(.cgSize, $0) }) {
        AXUIElementSetAttributeValue(el, attr as CFString, val)
    }
}

func axGetBool(_ el: AXUIElement, _ attr: String) -> Bool? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? Bool
}

func isFullScreen(_ win: AXUIElement) -> Bool {
    return axGetBool(win, "AXFullScreen") == true
}

func exitFullScreen(_ win: AXUIElement) {
    AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanFalse)
    for _ in 0..<30 {
        Thread.sleep(forTimeInterval: 0.25)
        if !isFullScreen(win) { break }
    }
}

func axGetPID(_ el: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return pid
}

// MARK: - Screen Description

func describeScreen(containing point: CGPoint) -> (frame: String, relativeX: Double, relativeY: Double) {
    for screen in NSScreen.screens {
        if screen.frame.contains(point) {
            let f = screen.frame
            let frameStr = "x=\(Int(f.origin.x)) y=\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"
            let rx = Double(point.x - f.origin.x)
            let ry = Double(point.y - f.origin.y)
            return (frameStr, rx, ry)
        }
    }
    return ("off-screen", Double(point.x), Double(point.y))
}

// MARK: - Find VS Code Windows

func findVSCodeWindows() -> [(window: AXUIElement, app: AXUIElement, title: String, pid: pid_t)] {
    var results: [(AXUIElement, AXUIElement, String, pid_t)] = []

    let apps = NSWorkspace.shared.runningApplications.filter { app in
        guard let bid = app.bundleIdentifier else { return false }
        return VSCODE_BUNDLES.contains(bid)
    }

    for app in apps {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = axGetArray(appEl, "AXWindows") else { continue }

        for win in windows {
            var title = axGetString(win, "AXTitle") ?? ""
            if title.isEmpty {
                title = axGetString(win, "AXRoleDescription") ?? "untitled"
            }

            results.append((win, appEl, title, app.processIdentifier))
        }
    }

    return results
}

func findFrontmostVSCodeWindow() -> (window: AXUIElement, title: String, pid: pid_t)? {
    let frontApp = NSWorkspace.shared.frontmostApplication
    guard let bid = frontApp?.bundleIdentifier, VSCODE_BUNDLES.contains(bid) else {
        fputs("Frontmost app is not VS Code.\n", stderr)
        return nil
    }

    let appEl = AXUIElementCreateApplication(frontApp!.processIdentifier)

    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, "AXFocusedWindow" as CFString, &focused) == .success,
          let fw = focused else {
        fputs("Could not get focused VS Code window.\n", stderr)
        return nil
    }

    let win = fw as! AXUIElement
    var title = axGetString(win, "AXTitle") ?? ""
    if title.isEmpty {
        var main: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, "AXMainWindow" as CFString, &main) == .success,
           let mw = main {
            title = axGetString(mw as! AXUIElement, "AXTitle") ?? ""
        }
    }

    return (win, title, frontApp!.processIdentifier)
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

// MARK: - CDP Helpers

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

// MARK: - Save Window

func cmdSaveWin() {
    guard let (win, title, pid) = findFrontmostVSCodeWindow() else {
        exit(1)
    }

    guard let pos = axGetPoint(win, "AXPosition"),
          let size = axGetSize(win, "AXSize") else {
        fputs("Could not read window position/size.\n", stderr)
        exit(1)
    }

    var label = title
        .replacingOccurrences(of: " — Visual Studio Code", with: "")
        .replacingOccurrences(of: " — Visual Studio Code - Insiders", with: "")
        .replacingOccurrences(of: " — Visual Studio Code - Exploration", with: "")
    if label.isEmpty { label = "untitled" }

    let (screenFrame, relX, relY) = describeScreen(containing: pos)

    let info = WindowInfo(
        title: title,
        pid: pid,
        x: Double(pos.x),
        y: Double(pos.y),
        width: Double(size.width),
        height: Double(size.height),
        screenFrame: screenFrame,
        screenRelativeX: relX,
        screenRelativeY: relY,
        label: label
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let json: Data
    do {
        json = try encoder.encode(info)
    } catch {
        fputs("Failed to encode JSON: \(error)\n", stderr)
        exit(1)
    }

    let dir = (WIN_CONFIG_PATH as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try json.write(to: URL(fileURLWithPath: WIN_CONFIG_PATH), options: .atomic)
    } catch {
        fputs("Failed to write \(WIN_CONFIG_PATH): \(error)\n", stderr)
        exit(1)
    }

    print("Saved → \(WIN_CONFIG_PATH)")
    print("  \"\(info.label)\"")
    print("  pos=(\(Int(info.x)), \(Int(info.y)))  size=\(Int(info.width))x\(Int(info.height))")
    print("  screen: \(info.screenFrame)")
}

// MARK: - Restore Window

func cmdRestoreWin() {
    guard FileManager.default.fileExists(atPath: WIN_CONFIG_PATH) else {
        fputs("No saved data at \(WIN_CONFIG_PATH). Run 'save-win' first.\n", stderr)
        exit(1)
    }

    let target: WindowInfo
    do {
        let jsonData = try Data(contentsOf: URL(fileURLWithPath: WIN_CONFIG_PATH))
        target = try JSONDecoder().decode(WindowInfo.self, from: jsonData)
    } catch {
        fputs("Failed to read saved data: \(error)\n", stderr)
        exit(1)
    }

    let current = findVSCodeWindows()
    guard !current.isEmpty else {
        fputs("No VS Code windows currently open.\n", stderr)
        exit(1)
    }

    let resolvedPos = resolveGlobalPosition(from: target)
    let fallbackPos = CGPoint(x: target.x, y: target.y)
    let globalPos = isPositionOnScreen(resolvedPos) ? resolvedPos : fallbackPos

    if globalPos != resolvedPos {
        print("Saved screen not found; falling back to raw coordinates.")
    }

    print("Applying to \(current.count) open window(s):")
    print("  target: pos=(\(Int(globalPos.x)), \(Int(globalPos.y)))  size=\(Int(target.width))x\(Int(target.height))\n")

    for i in 0..<current.count {
        let (win, _, title, _) = current[i]

        print("[\(i+1)] \"\(title)\"")

        if isFullScreen(win) {
            print("    full-screen detected, exiting...")
            exitFullScreen(win)
            if isFullScreen(win) {
                print("    WARNING: could not exit full-screen, position/size may fail")
            } else {
                print("    exited full-screen")
            }
        }

        let maxRetries = 5
        var ok = false
        for attempt in 1...maxRetries {
            axSetPoint(win, "AXPosition", globalPos)
            axSetSize(win, "AXSize", CGSize(width: target.width, height: target.height))

            if attempt == 1 {
                Thread.sleep(forTimeInterval: 0.15)
            } else {
    Thread.sleep(forTimeInterval: 0.2)
            }

            if let newPos = axGetPoint(win, "AXPosition"),
               let newSize = axGetSize(win, "AXSize") {
                let posOk = abs(newPos.x - globalPos.x) < 3 && abs(newPos.y - globalPos.y) < 3
                let sizeOk = abs(newSize.width - CGFloat(target.width)) < 3 && abs(newSize.height - CGFloat(target.height)) < 3
                let status = (posOk && sizeOk) ? "OK" : "RETRY"
                print("    #\(attempt): pos=(\(Int(newPos.x)), \(Int(newPos.y)))  size=\(Int(newSize.width))x\(Int(newSize.height))  [\(status)]")
                if posOk && sizeOk {
                    ok = true
                    break
                }
            } else {
                print("    #\(attempt): could not read back")
            }
        }
        if !ok {
            print("    FAILED after \(maxRetries) attempts")
        }
        print("")
    }
}

// MARK: - Save Layout

func cmdSaveLayout(port: Int) {
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

    let dir = (LAYOUT_CONFIG_PATH as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted)
    else { exit(1) }
    try? jsonData.write(to: URL(fileURLWithPath: LAYOUT_CONFIG_PATH), options: .atomic)

    let sidebar = (data["sidebar"] as? [String: Any])?["width"] ?? "?"
    let panel = (data["panel"] as? [String: Any])?["width"] ?? "?"
    let editor = (data["editor"] as? [String: Any])?["width"] ?? "?"
    let activity = (data["activitybar"] as? [String: Any])?["width"] ?? "?"
    let sbPos = data["sidebar_position"] as? String ?? "?"
    let pnPos = data["panel_position"] as? String ?? "?"

    print("\nSaved \"\(title)\" to \(LAYOUT_CONFIG_PATH):")
    print("  sidebar:  \(sidebar)px (\(sbPos))")
    print("  panel:    \(panel)px (\(pnPos))")
    print("  editor:   \(editor)px")
    print("  activity: \(activity)px")
}

// MARK: - Restore Layout

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

func restoreLayoutWindow(wsUrl: String, tSidebar: Int, tPanel: Int, label: String) {
    let prefix = label.isEmpty ? "" : "[\(label)] "
    guard let task = newWebSocket(wsUrl) else { return }
    defer { task.cancel(with: .normalClosure, reason: nil) }

    enableRuntime(task)

    var smap = solveSashMapping(task)
    if smap["sidebar_editor"] == nil { smap["sidebar_editor"] = 0 }
    if smap["editor_panel"] == nil { smap["editor_panel"] = 1 }

    let maxRetries = 5
    var ok = false
    for attempt in 1...maxRetries {
        let cur = readCurrent(task)
        let sb = cur["sidebar"] ?? 0
        let pn = cur["panel"] ?? 0
        let ed = cur["editor"] ?? 0

        let dx_p = pn - tPanel
        let dx_s = tSidebar - sb

        if attempt == 1 {
            print("\(prefix)current: sb=\(sb) panel=\(pn) editor=\(ed)")
        }

        if dx_p != 0 {
            let sign = dx_p > 0 ? "+" : ""
            print("\(prefix) dragging panel sash by \(sign)\(dx_p)")
            dragSash(task, sashIdx: smap["editor_panel"]!, dx: dx_p)
        }

        if dx_s != 0 {
            let sign = dx_s > 0 ? "+" : ""
            print("\(prefix) dragging sidebar sash by \(sign)\(dx_s)")
            dragSash(task, sashIdx: smap["sidebar_editor"]!, dx: dx_s)
        }

        if dx_p == 0 && dx_s == 0 {
            print("\(prefix)already at target — OK")
            ok = true
            break
        }

        if attempt == 1 {
            Thread.sleep(forTimeInterval: 0.3)
        } else {
            Thread.sleep(forTimeInterval: 0.6)
        }

        let final = readCurrent(task)
        let fsb = final["sidebar"] ?? 0
        let fpn = final["panel"] ?? 0
        let fed = final["editor"] ?? 0
        ok = fsb == tSidebar && fpn == tPanel
        let status = ok ? "OK" : "RETRY"
        print("\(prefix)final:   sb=\(fsb) panel=\(fpn) editor=\(fed)  [\(status)]")

        if ok { break }
    }
    if !ok {
        print("\(prefix)FAILED after \(maxRetries) attempts")
    }
}

func cmdRestoreLayout(port: Int) {
    guard FileManager.default.fileExists(atPath: LAYOUT_CONFIG_PATH) else {
        fputs("No saved sizes at \(LAYOUT_CONFIG_PATH). Run 'save-layout' first.\n", stderr)
        exit(1)
    }

    guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: LAYOUT_CONFIG_PATH)),
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
        restoreLayoutWindow(wsUrl: wsUrl, tSidebar: tSidebar, tPanel: tPanel, label: "\(idx)")
        print("")
    }
}

// MARK: - Save All

func cmdSaveAll(port: Int) {
    print("=== save-layout ===")
    cmdSaveLayout(port: port)
    print("")
    print("=== save-win ===")
    cmdSaveWin()
}

// MARK: - Restore All

func cmdRestoreAll(port: Int) {
    print("=== restore-win ===")
    cmdRestoreWin()
    print("")
    Thread.sleep(forTimeInterval: 0.5)
    print("=== restore-layout ===")
    cmdRestoreLayout(port: port)
}

// MARK: - List Displays

func cmdListDisplays() {
    print("\(NSScreen.screens.count) display(s):\n")
    for (i, screen) in NSScreen.screens.enumerated() {
        let name = screen.localizedName.isEmpty ? "(unnamed)" : screen.localizedName
        let f = screen.frame
        let resolved = "x=\(Int(f.origin.x)) y=\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"
        let isMain = (screen == NSScreen.screens.first) ? " ← main" : ""
        print("[\(i)] \(name)  \(resolved)\(isMain)")
    }
}

// MARK: - Main

func usage() -> Never {
    let prog = (CommandLine.arguments[0] as NSString).lastPathComponent
    print("Usage:")
    print("  \(prog) save-win               Save position & size of the frontmost VS Code window")
    print("  \(prog) restore-win            Apply saved position & size to all open VS Code windows")
    print("  \(prog) save-layout [port]     Save panel/sidebar layout of the active VS Code window")
    print("  \(prog) restore-layout [port]  Restore saved panel/sidebar layout to all VS Code windows")
    print("  \(prog) save-all [port]        Save both window and layout in one call")
    print("  \(prog) restore-all [port]     Restore window then layout with proper timing")
    print("  \(prog) list-displays          List connected displays with their frames")
    print("")
    print("Default CDP port: 9333")
    print("Window config: ~/.config/vscode/windows.json")
    print("Layout config:  ~/.config/vscode/panel-and-bar-sides.json")
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

let cdpPort: () -> Int = {
    if args.count >= 3, let p = Int(args[2]) { return p }
    return 9333
}

switch args[1] {
case "save-win":
    cmdSaveWin()
case "restore-win":
    cmdRestoreWin()
case "save-layout":
    cmdSaveLayout(port: cdpPort())
case "restore-layout":
    cmdRestoreLayout(port: cdpPort())
case "save-all":
    cmdSaveAll(port: cdpPort())
case "restore-all":
    cmdRestoreAll(port: cdpPort())
case "list-displays":
    cmdListDisplays()
default:
    usage()
}
