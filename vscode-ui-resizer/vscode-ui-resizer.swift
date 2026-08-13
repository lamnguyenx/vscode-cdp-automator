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

let CONFIG_PATH = NSString(string: "~/.config/vscode-cdp-automator/config.json").expandingTildeInPath
let LEGACY_WIN_CONFIG_PATH = NSString(string: "~/.config/vscode/windows.json").expandingTildeInPath
let LEGACY_LAYOUT_CONFIG_PATH = NSString(string: "~/.config/vscode/panel-and-bar-sides.json").expandingTildeInPath
let USER_SETTINGS_PATH = NSString(string: "~/Library/Application Support/Code/User/settings.json").expandingTildeInPath
let ZOOM_LEVEL_KEY = "window.zoomLevel"
let CODESERVER_PORT = 9222

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

// MARK: - Unified Config Store

struct PartSize: Codable {
    let width: Int
    let height: Int
}

struct LayoutConfig: Codable {
    var sidebar: PartSize?
    var panel: PartSize?
    var editor: PartSize?
    var activitybar: PartSize?
    var auxiliarybar: PartSize?
    var workbench: PartSize?
    var sidebar_position: String?
    var panel_position: String?
    var zoom_level: Double?
    var zoom_percent: Int?
}

struct DisplayConfig: Codable {
    var window: WindowInfo?
    var layout: LayoutConfig?
    var codeServerLayout: LayoutConfig?
}

func loadConfigStore() -> [String: DisplayConfig] {
    if FileManager.default.fileExists(atPath: CONFIG_PATH),
       let data = try? Data(contentsOf: URL(fileURLWithPath: CONFIG_PATH)),
       let store = try? JSONDecoder().decode([String: DisplayConfig].self, from: data) {
        return store
    }

    var store: [String: DisplayConfig] = [:]

    if let data = try? Data(contentsOf: URL(fileURLWithPath: LEGACY_WIN_CONFIG_PATH)) {
        if let dict = try? JSONDecoder().decode([String: WindowInfo].self, from: data) {
            for (key, info) in dict {
                store[key] = DisplayConfig(window: info, layout: nil)
            }
        } else if let legacy = try? JSONDecoder().decode(WindowInfo.self, from: data) {
            store["legacy"] = DisplayConfig(window: legacy, layout: nil)
        }
    }

    if let data = try? Data(contentsOf: URL(fileURLWithPath: LEGACY_LAYOUT_CONFIG_PATH)),
       let layout = try? JSONDecoder().decode(LayoutConfig.self, from: data) {
        if store.isEmpty {
            store["legacy"] = DisplayConfig(window: nil, layout: layout)
        } else {
            for key in store.keys {
                store[key]?.layout = layout
            }
        }
    }

    if !store.isEmpty {
        _ = saveConfigStore(store)
        fputs("Migrated legacy configs to \(CONFIG_PATH)\n", stderr)
    }

    return store
}

func saveConfigStore(_ store: [String: DisplayConfig]) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    guard let data = try? encoder.encode(store) else { return false }

    let dir = (CONFIG_PATH as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: CONFIG_PATH), options: .atomic)
        return true
    } catch {
        fputs("Failed to write \(CONFIG_PATH): \(error)\n", stderr)
        return false
    }
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

// MARK: - Display Fingerprint

func displayFingerprint() -> String {
    struct DisplayLine {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
        let rot: Int
        let name: String
        let isMain: Bool
    }

    let mainScreen = NSScreen.screens.first
    var displays: [DisplayLine] = []

    for screen in NSScreen.screens {
        let frame = screen.frame
        let name = screen.localizedName.isEmpty ? "Display" : screen.localizedName
        let isMain = (screen == mainScreen)

        var rotation = 0
        var physW = Int(frame.width)
        var physH = Int(frame.height)

        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            rotation = Int(CGDisplayRotation(screenNumber))
            if let mode = CGDisplayCopyDisplayMode(screenNumber) {
                physW = mode.pixelWidth
                physH = mode.pixelHeight
            }
        }

        if rotation == 90 || rotation == 270 {
            swap(&physW, &physH)
        }

        displays.append(DisplayLine(
            x: Int(frame.origin.x),
            y: Int(frame.origin.y),
            w: physW,
            h: physH,
            rot: rotation,
            name: name,
            isMain: isMain
        ))
    }

    displays.sort { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }

    return displays.map { d in
        let xStr = String(format: "%5d", d.x)
        let yStr = String(format: "%3d", d.y)
        let marker = d.isMain ? "*" : " "
        return "[\(xStr),\(yStr)] \(d.w)x\(d.h) \(d.rot)°  \(d.name)\(marker)"
    }.joined(separator: "\n")
}

// MARK: - Devhost Detection

func isDevHostProcess(pid: pid_t) -> Bool {
    let task = Process()
    task.launchPath = "/bin/ps"
    task.arguments = ["-o", "command=", "-p", "\(pid)"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return false
    }
    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""
    return output.contains("--extensionDevelopmentPath")
}

// MARK: - Find VS Code Windows

func findVSCodeWindows() -> [(window: AXUIElement, app: AXUIElement, title: String, pid: pid_t)] {
    var results: [(AXUIElement, AXUIElement, String, pid_t)] = []

    let apps = NSWorkspace.shared.runningApplications.filter { app in
        guard let bid = app.bundleIdentifier else { return false }
        return VSCODE_BUNDLES.contains(bid)
    }

    for app in apps {
        if isDevHostProcess(pid: app.processIdentifier) { continue }

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

    if isDevHostProcess(pid: frontApp!.processIdentifier) {
        fputs("Frontmost app is a VS Code dev host instance.\n", stderr)
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

func tryFetchTargets(port: Int) -> [[String: Any]]? {
    guard let url = URL(string: "http://localhost:\(port)/json"),
          let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return nil }
    return json.filter { ($0["url"] as? String)?.hasSuffix("workbench.html") ?? false }
}

func tryFetchCodeServerTargets(port: Int) -> [[String: Any]]? {
    guard let url = URL(string: "http://localhost:\(port)/json"),
          let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return nil }
    return json.filter { target in
        guard (target["type"] as? String) == "page" else { return false }
        let urlStr = (target["url"] as? String) ?? ""
        return urlStr.contains("?folder=") || urlStr.contains("?workspace=")
    }
}

func isActiveTab(_ task: URLSessionWebSocketTask) -> Bool {
    let raw = evalJS(task, "String(document.hasFocus())")
    return raw == "true"
}

func isVisibleTab(_ task: URLSessionWebSocketTask) -> Bool {
    let raw = evalJS(task, "String(document.visibilityState === 'visible')")
    return raw == "true"
}

func wsRecv(_ task: URLSessionWebSocketTask) -> String {
    let sem = DispatchSemaphore(value: 0)
    var raw = ""
    task.receive { result in
        if case .success(let msg) = result, case .string(let s) = msg { raw = s }
        sem.signal()
    }
    if sem.wait(timeout: .now() + 5) == .timedOut {
        return ""
    }
    return raw
}

func wsSend(_ task: URLSessionWebSocketTask, _ text: String, waitForId id: Int? = nil) -> String {
    let sem = DispatchSemaphore(value: 0)
    task.send(.string(text)) { _ in sem.signal() }
    _ = sem.wait(timeout: .now() + 5)

    guard let mid = id else {
        return wsRecv(task)
    }

    let needle = "\"id\":\(mid)"
    for _ in 0..<500 {
        let raw = wsRecv(task)
        if raw.isEmpty { break }
        if !raw.contains(needle) { continue }
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["id"] as? Int == mid
        else { continue }
        return raw
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

// MARK: - Restore Eligibility

struct Eligibility {
    let sidebarOnLeft: Bool
    let panelOnRight: Bool
    let maximized: Bool
}

func readEligibility(_ task: URLSessionWebSocketTask) -> Eligibility? {
    let raw = evalJS(task, """
    (() => {
        const sb = document.querySelector('.part.sidebar');
        const pn = document.querySelector('.part.panel');
        const ed = document.querySelector('.part.editor');
        const sbOnLeft = !!sb && sb.classList.contains('left') && sb.getBoundingClientRect().width > 5;
        const pnOnRight = !!pn && pn.classList.contains('right') && pn.getBoundingClientRect().width > 5;
        let maximized = false;
        if (pn && ed) {
            const pb = pn.getBoundingClientRect();
            const eb = ed.getBoundingClientRect();
            if ((eb.width < 5 && pb.width > 50) || (eb.height < 5 && pb.height > 50)) maximized = true;
            const btn = pn.querySelector('.actions-container .action-label.codicon-panel-maximize');
            if (btn && btn.classList.contains('checked')) maximized = true;
        }
        return JSON.stringify({ sbOnLeft, pnOnRight, maximized });
    })()
    """)
    guard let data = raw.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sb = dict["sbOnLeft"] as? Bool,
          let pn = dict["pnOnRight"] as? Bool,
          let mx = dict["maximized"] as? Bool
    else { return nil }
    return Eligibility(sidebarOnLeft: sb, panelOnRight: pn, maximized: mx)
}

func normalizedTitle(_ title: String) -> String {
    var t = title
    for suffix in [" — Visual Studio Code - Exploration", " — Visual Studio Code - Insiders", " — Visual Studio Code"] {
        t = t.replacingOccurrences(of: suffix, with: "")
    }
    return t
}

// MARK: - Zoom Helpers

func zoomLevelFromFactor(_ factor: Double) -> Double {
    return log(factor) / log(1.2)
}

func zoomLevelFromPercent(_ percent: Double) -> Double {
    return log(percent / 100.0) / log(1.2)
}

func roundToZoomGrid(_ percent: Double) -> Double {
    return (percent / 5.0).rounded() * 5.0
}

func readZoomFactor(_ task: URLSessionWebSocketTask) -> Double? {
    let raw = evalJS(task, """
    (() => {
        const el = document.querySelector('.part.titlebar');
        if (!el) return 'null';
        return el.style.getPropertyValue('--zoom-factor') || 'null';
    })()
    """)
    return Double(raw)
}

func verifyZoomLevel(_ task: URLSessionWebSocketTask, targetLevel: Double) -> Bool {
    guard let factor = readZoomFactor(task) else { return false }
    return abs(factor - pow(1.2, targetLevel)) < 0.01
}

func writeZoomLevelToUserSettings(_ level: Double) -> Bool {
    let value = String(format: "%.17g", level)
    let settingsURL = URL(fileURLWithPath: USER_SETTINGS_PATH)

    guard var text = try? String(contentsOf: settingsURL, encoding: .utf8) else {
        fputs("Cannot read \(USER_SETTINGS_PATH)\n", stderr)
        return false
    }

    let pattern = "\"\(ZOOM_LEVEL_KEY)\"\\s*:\\s*[+-]?[0-9]*\\.?[0-9]+([eE][+-]?[0-9]+)?"
    if let range = text.range(of: pattern, options: .regularExpression) {
        text.replaceSubrange(range, with: "\"\(ZOOM_LEVEL_KEY)\": \(value)")
    } else if text.hasPrefix("{") {
        text.insert(contentsOf: "    \"\(ZOOM_LEVEL_KEY)\": \(value),\n", at: text.index(text.startIndex, offsetBy: 1))
    } else {
        fputs("Unexpected settings file format (no leading '{').\n", stderr)
        return false
    }

    do {
        try text.write(to: settingsURL, atomically: true, encoding: .utf8)
        return true
    } catch {
        fputs("Failed to write \(USER_SETTINGS_PATH): \(error)\n", stderr)
        return false
    }
}

// MARK: - Save Window

func cmdSaveWin() {
    guard let (win, title, pid) = findFrontmostVSCodeWindow() else {
        fputs("Skipping save-win: no VS Code window found.\n", stderr)
        return
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

    let fingerPrint = displayFingerprint()

    var store = loadConfigStore()
    var entry = store[fingerPrint] ?? DisplayConfig(window: nil, layout: nil)
    entry.window = info
    store[fingerPrint] = entry

    guard saveConfigStore(store) else { exit(1) }

    print("Saved → \(CONFIG_PATH)")
    print("  \"\(info.label)\"")
    print("  pos=(\(Int(info.x)), \(Int(info.y)))  size=\(Int(info.width))x\(Int(info.height))")
    print("  screen: \(info.screenFrame)")
    print("")
    print("Display layout:")
    print(fingerPrint)
}

// MARK: - Restore Window

func cmdRestoreWin(port: Int) {
    let store = loadConfigStore()
    guard !store.isEmpty else {
        fputs("Skipping restore-win: no saved data at \(CONFIG_PATH).\n", stderr)
        return
    }

    let fingerPrint = displayFingerprint()

    let target: WindowInfo
    if let match = store[fingerPrint]?.window {
        target = match
    } else if store.count == 1, let only = store.values.first?.window {
        fputs("No saved config for current display layout; using the only available saved config.\n", stderr)
        print("\nCurrent layout:\n\(fingerPrint)\n")
        target = only
    } else {
        fputs("Skipping restore-win: no saved window for current display layout.\n", stderr)
        return
    }

    let current = findVSCodeWindows()
    guard !current.isEmpty else {
        fputs("Skipping restore-win: no VS Code windows currently open.\n", stderr)
        return
    }

    let resolvedPos = resolveGlobalPosition(from: target)
    let fallbackPos = CGPoint(x: target.x, y: target.y)
    let globalPos = isPositionOnScreen(resolvedPos) ? resolvedPos : fallbackPos

    if globalPos != resolvedPos {
        print("Saved screen not found; falling back to raw coordinates.")
    }

    var eligibilityByTitle: [String: Eligibility] = [:]
    if let targets = tryFetchTargets(port: port) {
        for t in targets {
            guard let wsUrl = t["webSocketDebuggerUrl"] as? String,
                  let title = t["title"] as? String,
                  let task = newWebSocket(wsUrl)
            else { continue }
            if let el = readEligibility(task) {
                eligibilityByTitle[normalizedTitle(title)] = el
            }
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    print("Applying to \(current.count) open window(s):")
    print("  target: pos=(\(Int(globalPos.x)), \(Int(globalPos.y)))  size=\(Int(target.width))x\(Int(target.height))\n")

    for i in 0..<current.count {
        let (win, _, title, _) = current[i]

        print("[\(i+1)] \"\(title)\"")

        if let el = eligibilityByTitle[normalizedTitle(title)] {
            if el.maximized {
                print("    skipped: panel is maximized (full-width)")
                continue
            }
            if !el.sidebarOnLeft {
                print("    skipped: primary sidebar not on the left")
                continue
            }
            if !el.panelOnRight {
                print("    skipped: panel not on the right")
                continue
            }
        }

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

func readLayoutFromTab(_ task: URLSessionWebSocketTask) -> LayoutConfig? {
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
          let data = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any]
    else { return nil }

    func partSize(_ key: String) -> PartSize? {
        guard let p = data[key] as? [String: Any],
              let w = p["width"] as? Int,
              let h = p["height"] as? Int
        else { return nil }
        return PartSize(width: w, height: h)
    }

    var layout = LayoutConfig()
    layout.sidebar = partSize("sidebar")
    layout.panel = partSize("panel")
    layout.editor = partSize("editor")
    layout.activitybar = partSize("activitybar")
    layout.auxiliarybar = partSize("auxiliarybar")
    layout.workbench = partSize("workbench")
    layout.sidebar_position = data["sidebar_position"] as? String
    layout.panel_position = data["panel_position"] as? String

    if let factor = readZoomFactor(task) {
        let pct = roundToZoomGrid(factor * 100.0)
        layout.zoom_level = zoomLevelFromPercent(pct)
        layout.zoom_percent = Int(pct)
    }

    if layout.sidebar == nil && layout.panel == nil && layout.editor == nil {
        return nil
    }

    return layout
}

func cmdSaveLayout(port: Int) {
    guard let activeTitle = getFrontmostVSCodeTitle() else {
        fputs("Skipping save-layout: frontmost app is not VS Code.\n", stderr)
        return
    }

    guard let windows = tryFetchTargets(port: port), !windows.isEmpty else {
        fputs("Skipping save-layout: cannot reach VS Code CDP on port \(port).\n", stderr)
        return
    }

    guard let t = windows.first(where: { ($0["title"] as? String) == activeTitle })
            ?? windows.first,
          let wsUrl = t["webSocketDebuggerUrl"] as? String,
          let task = newWebSocket(wsUrl)
    else {
        fputs("Skipping save-layout: could not connect to a VS Code window.\n", stderr)
        return
    }
    defer { task.cancel(with: .normalClosure, reason: nil) }

    let title = (t["title"] as? String) ?? "unknown"
    print("Saving from: \(title)")

    guard let layout = readLayoutFromTab(task) else {
        fputs("Skipping save-layout: could not read layout from \(title) (workbench not ready?).\n", stderr)
        return
    }

    let fingerPrint = displayFingerprint()
    var store = loadConfigStore()
    var entry = store[fingerPrint] ?? DisplayConfig(window: nil, layout: nil)
    entry.layout = layout
    store[fingerPrint] = entry
    guard saveConfigStore(store) else { exit(1) }

    let sidebar = layout.sidebar?.width ?? 0
    let panel = layout.panel?.width ?? 0
    let editor = layout.editor?.width ?? 0
    let activity = layout.activitybar?.width ?? 0
    let sbPos = layout.sidebar_position ?? "?"
    let pnPos = layout.panel_position ?? "?"

    print("\nSaved \"\(title)\" to \(CONFIG_PATH):")
    print("  sidebar:  \(sidebar)px (\(sbPos))")
    print("  panel:    \(panel)px (\(pnPos))")
    print("  editor:   \(editor)px")
    print("  activity: \(activity)px")
    if let zoom = layout.zoom_percent {
        print("  zoom:     \(zoom)%")
    }
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

func readPanelPosition(_ task: URLSessionWebSocketTask) -> String {
    let raw = evalJS(task, """
    (() => {
        const el = document.querySelector('.part.panel');
        if (!el) return 'none';
        if (el.classList.contains('right')) return 'right';
        if (el.classList.contains('left')) return 'left';
        if (el.classList.contains('bottom')) return 'bottom';
        return 'other';
    })()
    """)
    return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
}

func solveSashMappingHorizontal(_ task: URLSessionWebSocketTask) -> [String: Int] {
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
                if (dL >= -0.5 && dL < bestL) { bestL = dL; leftName = name; }
                if (dR >= -0.5 && dR < bestR) { bestR = dR; rightName = name; }
            }
            results.push({ idx: i, between: leftName + '|' + rightName, cx: Math.round(cx) });
        });
        return JSON.stringify(results);
    })()
    """)
    return parseSashMappingResult(raw)
}

func solveSashMappingVertical(_ task: URLSessionWebSocketTask) -> [String: Int] {
    let raw = evalJS(task, """
    (() => {
        const all = document.querySelectorAll('.monaco-grid-view .monaco-split-view2.vertical .sash-container .monaco-sash.horizontal:not(.disabled)');
        const parts = ['sidebar', 'panel', 'editor', 'activitybar', 'auxiliarybar'];
        const rects = {};
        parts.forEach(p => {
            const el = document.querySelector('.part.' + p);
            if (el) rects[p] = el.getBoundingClientRect();
        });
        const results = [];
        all.forEach((sash, i) => {
            const b = sash.getBoundingClientRect();
            const cy = b.top + b.height / 2;
            let aboveName = '?', belowName = '?';
            let bestA = Infinity, bestB = Infinity;
            for (const [name, r] of Object.entries(rects)) {
                if (r.width === 0 && r.height === 0) continue;
                const dA = cy - r.bottom;
                const dB = r.top - cy;
                if (dA >= -0.5 && dA < bestA) { bestA = dA; aboveName = name; }
                if (dB >= -0.5 && dB < bestB) { bestB = dB; belowName = name; }
            }
            results.push({ idx: i, between: aboveName + '|' + belowName, cy: Math.round(cy) });
        });
        return JSON.stringify(results);
    })()
    """)
    return parseSashMappingResult(raw)
}

func parseSashMappingResult(_ raw: String) -> [String: Int] {
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

func dragSashHorizontal(_ task: URLSessionWebSocketTask, sashIdx: Int, dx: Int) {
    guard dx != 0 else { return }
    _ = evalJS(task, """
    (() => {
        const all = document.querySelectorAll('.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical:not(.disabled)');
        const sash = all[\(sashIdx)];
        if (!sash) return JSON.stringify({error:'no sash at \(sashIdx)', count: all.length});
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

func dragSashVertical(_ task: URLSessionWebSocketTask, sashIdx: Int, dy: Int) {
    guard dy != 0 else { return }
    _ = evalJS(task, """
    (() => {
        const all = document.querySelectorAll('.monaco-grid-view .monaco-split-view2.vertical .sash-container .monaco-sash.horizontal:not(.disabled)');
        const sash = all[\(sashIdx)];
        if (!sash) return JSON.stringify({error:'no sash at \(sashIdx)', count: all.length});
        const b = sash.getBoundingClientRect();
        const cx = b.left + b.width / 2;
        const cy = b.top + b.height / 2;
        const w = document.defaultView;
        sash.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, clientX: cx, clientY: cy, button: 0}));
        w.dispatchEvent(new MouseEvent('mousemove',   {bubbles: true, clientX: cx, clientY: cy + \(dy), button: 0}));
        w.dispatchEvent(new MouseEvent('mouseup',     {bubbles: true, clientX: cx, clientY: cy + \(dy), button: 0}));
        return 'ok';
    })()
    """)
}

func restoreLayoutWindow(wsUrl: String, tSidebar: Int, tPanel: Int, label: String) {
    let prefix = label.isEmpty ? "" : "[\(label)] "
    guard let task = newWebSocket(wsUrl) else { return }
    defer { task.cancel(with: .normalClosure, reason: nil) }

    let panelPos = readPanelPosition(task)

    if let el = readEligibility(task) {
        if el.maximized {
            print("\(prefix)panel is maximized (full-width) — skipping this window")
            return
        }
        if !el.sidebarOnLeft {
            print("\(prefix)primary sidebar not on the left — skipping this window")
            return
        }
        if !el.panelOnRight {
            print("\(prefix)panel not on the right — skipping this window")
            return
        }
    }

    let isBottom = panelPos == "bottom"
    let smap = isBottom ? solveSashMappingVertical(task) : solveSashMappingHorizontal(task)
    var seIdx = smap["sidebar_editor"]
    var epIdx = smap["editor_panel"]

    if seIdx == nil { seIdx = 0 }
    if epIdx == nil { epIdx = 1 }

    if isBottom {
        print("\(prefix)(panel at bottom — using vertical sashes)")
    }

    let maxRetries = 5
    var ok = false
    var consecutiveZeros = 0
    for attempt in 1...maxRetries {
        let cur = readCurrent(task)
        let sb = cur["sidebar"] ?? 0
        var pn = cur["panel"] ?? 0
        let ed = cur["editor"] ?? 0

        if sb == 0 && pn == 0 && ed == 0 {
            consecutiveZeros += 1
            if consecutiveZeros >= 3 {
                print("\(prefix)workbench not ready (zero values), skipping")
                return
            }
            print("\(prefix)workbench not ready (zero values), retrying...")
            Thread.sleep(forTimeInterval: 0.5)
            continue
        }
        consecutiveZeros = 0

        if attempt == 1 {
            print("\(prefix)current: sb=\(sb) panel=\(pn) editor=\(ed)")
        }

        if !isBottom && pn == 0 && tPanel > 0 && smap["editor_panel"] == nil {
            print("\(prefix)panel is collapsed (width=0) and no editor|panel sash found — expand panel first, then re-run")
            return
        }
        if isBottom && pn == 0 && tPanel > 0 && smap["editor_panel"] == nil {
            print("\(prefix)panel is collapsed (height=0) and no editor|panel sash found — expand panel first, then re-run")
            return
        }

        let dx_p: Int
        let dx_s: Int

        if isBottom {
            let rawH = evalJS(task, """
            (() => {
                const el = document.querySelector('.part.panel');
                if (!el) return 0;
                return Math.round(el.getBoundingClientRect().height);
            })()
            """)
            let ph = Int(rawH) ?? 0
            pn = ph
            dx_p = pn - tPanel
            dx_s = tSidebar - sb
        } else {
            dx_p = pn - tPanel
            dx_s = tSidebar - sb
        }

        if dx_p != 0 {
            let sign = dx_p > 0 ? "+" : ""
            print("\(prefix) dragging panel sash by \(sign)\(dx_p)")
            if isBottom {
                dragSashVertical(task, sashIdx: epIdx!, dy: dx_p)
            } else {
                dragSashHorizontal(task, sashIdx: epIdx!, dx: dx_p)
            }
        }

        if dx_s != 0 {
            let sign = dx_s > 0 ? "+" : ""
            print("\(prefix) dragging sidebar sash by \(sign)\(dx_s)")
            dragSashHorizontal(task, sashIdx: seIdx!, dx: dx_s)
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
        var fpn = final["panel"] ?? 0
        let fed = final["editor"] ?? 0

        if isBottom {
            let rawH = evalJS(task, """
            (() => {
                const el = document.querySelector('.part.panel');
                if (!el) return 0;
                return Math.round(el.getBoundingClientRect().height);
            })()
            """)
            fpn = Int(rawH) ?? 0
        }

        ok = fsb == tSidebar && fpn == tPanel
        let status = ok ? "OK" : "RETRY"
        let dimLabel = isBottom ? "h" : ""
        print("\(prefix)final:   sb=\(fsb) panel\(dimLabel)=\(fpn) editor\(dimLabel)=\(fed)  [\(status)]")

        if ok { break }
    }
    if !ok {
        print("\(prefix)FAILED after \(maxRetries) attempts")
    }
}

func cmdRestoreLayout(port: Int) {
    let store = loadConfigStore()
    guard !store.isEmpty else {
        fputs("Skipping restore-layout: no saved data at \(CONFIG_PATH).\n", stderr)
        return
    }

    let fingerPrint = displayFingerprint()

    let layout: LayoutConfig
    if let match = store[fingerPrint]?.layout {
        layout = match
    } else if store.count == 1, let only = store.values.first?.layout {
        fputs("No saved layout for current display layout; using the only available saved config.\n", stderr)
        print("\nCurrent layout:\n\(fingerPrint)\n")
        layout = only
    } else {
        fputs("Skipping restore-layout: no saved layout for current display layout.\n", stderr)
        return
    }

    let tSidebar = layout.sidebar?.width ?? 0
    let savedPanelPos = layout.panel_position ?? ""
    let tPanel: Int
    let panelDimLabel: String
    if savedPanelPos == "bottom" || savedPanelPos == "top" {
        tPanel = layout.panel?.height ?? 0
        panelDimLabel = "h"
    } else {
        tPanel = layout.panel?.width ?? 0
        panelDimLabel = ""
    }
    let tZoomLevel = layout.zoom_level
    let tZoomPercent = layout.zoom_percent

    guard let windows = tryFetchTargets(port: port), !windows.isEmpty else {
        fputs("Skipping restore-layout: cannot reach VS Code CDP on port \(port).\n", stderr)
        return
    }
    print("Restoring \(windows.count) window(s) to sidebar=\(tSidebar)px  panel=\(tPanel)px\(panelDimLabel)\(tZoomPercent.map { "  zoom=\($0)%" } ?? "")\n")

    if let zl = tZoomLevel {
        let roundedPct = roundToZoomGrid(pow(1.2, zl) * 100.0)
        let gridLevel = zoomLevelFromPercent(roundedPct)
        print("Applying zoom \(Int(roundedPct))% (level \(String(format: "%.4f", gridLevel))) via \(USER_SETTINGS_PATH)")
        if writeZoomLevelToUserSettings(gridLevel) {
            Thread.sleep(forTimeInterval: 1.0)
            for (idx, t) in windows.enumerated() {
                guard let wsUrl = t["webSocketDebuggerUrl"] as? String,
                      let task = newWebSocket(wsUrl)
                else { continue }
                var zoomOk = false
                for _ in 1...5 {
                    if verifyZoomLevel(task, targetLevel: gridLevel) {
                        zoomOk = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                task.cancel(with: .normalClosure, reason: nil)
                print("[\(idx)] zoom: \(zoomOk ? "OK" : "FAILED after 5 attempts")")
            }
        }
        print("")
    }

    for (idx, t) in windows.enumerated() {
        guard let wsUrl = t["webSocketDebuggerUrl"] as? String else { continue }
        let title = (t["title"] as? String) ?? "unknown"
        print("[\(idx)] \(title)")
        restoreLayoutWindow(wsUrl: wsUrl, tSidebar: tSidebar, tPanel: tPanel, label: "\(idx)")
        print("")
    }
}

// MARK: - Save Code-Server Layout

func cmdSaveCodeServerLayout(port: Int) {
    guard let targets = tryFetchCodeServerTargets(port: port), !targets.isEmpty else {
        fputs("Skipping save-codeserver-layout: no code-server tabs found on CDP port \(port).\n", stderr)
        return
    }

    var active: [String: Any]?
    var visible: [String: Any]?
    var titles: [String] = []

    for t in targets {
        let title = (t["title"] as? String) ?? "unknown"
        titles.append(title)
        guard let wsUrl = t["webSocketDebuggerUrl"] as? String,
              let task = newWebSocket(wsUrl)
        else { continue }
        let activeTab = isActiveTab(task)
        let visibleTab = activeTab ? true : isVisibleTab(task)
        task.cancel(with: .normalClosure, reason: nil)
        if activeTab && active == nil {
            active = t
        }
        if visibleTab && visible == nil {
            visible = t
        }
    }

    guard let chosen = active ?? visible else {
        fputs("Could not determine the active code-server tab.\n", stderr)
        fputs("Open tabs:\n", stderr)
        for title in titles { fputs("  - \(title)\n", stderr) }
        return
    }

    guard let wsUrl = chosen["webSocketDebuggerUrl"] as? String,
          let task = newWebSocket(wsUrl)
    else {
        fputs("Could not connect to the active code-server tab.\n", stderr)
        return
    }
    defer { task.cancel(with: .normalClosure, reason: nil) }

    let title = (chosen["title"] as? String) ?? "unknown"
    print("Saving from (code-server): \(title)")

    guard let layout = readLayoutFromTab(task) else {
        fputs("Could not read code-server layout from \(title).\n", stderr)
        return
    }

    let fingerPrint = displayFingerprint()
    var store = loadConfigStore()
    var entry = store[fingerPrint] ?? DisplayConfig(window: nil, layout: nil)
    entry.codeServerLayout = layout
    store[fingerPrint] = entry
    guard saveConfigStore(store) else { exit(1) }

    let sidebar = layout.sidebar?.width ?? 0
    let panel = layout.panel?.width ?? 0
    let editor = layout.editor?.width ?? 0
    let sbPos = layout.sidebar_position ?? "?"
    let pnPos = layout.panel_position ?? "?"

    print("\nSaved code-server \"\(title)\" to \(CONFIG_PATH):")
    print("  sidebar:  \(sidebar)px (\(sbPos))")
    print("  panel:    \(panel)px (\(pnPos))")
    print("  editor:   \(editor)px")
}

// MARK: - Restore Code-Server Layout

func cmdRestoreCodeServerLayout(port: Int) {
    let store = loadConfigStore()
    guard !store.isEmpty else {
        fputs("Skipping restore-codeserver-layout: no saved data at \(CONFIG_PATH).\n", stderr)
        return
    }

    let fingerPrint = displayFingerprint()

    let layout: LayoutConfig
    if let match = store[fingerPrint]?.codeServerLayout {
        layout = match
    } else if store.count == 1, let only = store.values.first?.codeServerLayout {
        fputs("No saved code-server layout for current display layout; using the only available saved config.\n", stderr)
        print("\nCurrent layout:\n\(fingerPrint)\n")
        layout = only
    } else {
        fputs("Skipping restore-codeserver-layout: no saved code-server layout for current display layout.\n", stderr)
        return
    }

    let tSidebar = layout.sidebar?.width ?? 0
    let savedPanelPos = layout.panel_position ?? ""
    let tPanel: Int
    if savedPanelPos == "bottom" || savedPanelPos == "top" {
        tPanel = layout.panel?.height ?? 0
    } else {
        tPanel = layout.panel?.width ?? 0
    }

    guard let targets = tryFetchCodeServerTargets(port: port), !targets.isEmpty else {
        fputs("Skipping restore-codeserver-layout: no code-server tabs found on CDP port \(port).\n", stderr)
        return
    }
    print("Restoring \(targets.count) code-server tab(s) to sidebar=\(tSidebar)px  panel=\(tPanel)px\n")

    for (idx, t) in targets.enumerated() {
        guard let wsUrl = t["webSocketDebuggerUrl"] as? String else { continue }
        let title = (t["title"] as? String) ?? "unknown"
        print("[\(idx)] \(title)")
        restoreLayoutWindow(wsUrl: wsUrl, tSidebar: tSidebar, tPanel: tPanel, label: "\(idx)")
        print("")
    }
}

// MARK: - Save All

func runSubCommand(_ args: [String]) -> Int32 {
    fflush(stdout)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    proc.arguments = args
    try? proc.run()
    proc.waitUntilExit()
    return proc.terminationStatus
}

func cmdSaveAll(port: Int) {
    print("=== save-layout ===")
    let lr = runSubCommand(["save-layout", String(port)])
    print("")
    print("=== save-win ===")
    let wr = runSubCommand(["save-win"])
    print("")
    print("=== save-codeserver-layout ===")
    let cr = runSubCommand(["save-codeserver-layout", String(CODESERVER_PORT)])
    if lr != 0 || wr != 0 || cr != 0 { exit(1) }
}

// MARK: - Restore All

func cmdRestoreAll(port: Int) {
    print("=== restore-win ===")
    let wr = runSubCommand(["restore-win", String(port)])
    print("")
    Thread.sleep(forTimeInterval: 0.5)
    print("=== restore-layout ===")
    let lr = runSubCommand(["restore-layout", String(port)])
    print("")
    Thread.sleep(forTimeInterval: 0.5)
    print("=== restore-codeserver-layout ===")
    let cr = runSubCommand(["restore-codeserver-layout", String(CODESERVER_PORT)])
    if wr != 0 || lr != 0 || cr != 0 { exit(1) }
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
    print("  \(prog) restore-win [port]     Apply saved position & size to eligible VS Code windows")
    print("  \(prog) save-layout [port]     Save panel/sidebar layout of the active VS Code window")
    print("  \(prog) restore-layout [port]  Restore saved panel/sidebar layout to all VS Code windows")
    print("  \(prog) save-codeserver-layout [port]   Save layout of the active code-server tab in Chrome")
    print("  \(prog) restore-codeserver-layout [port]  Restore layout to all code-server tabs")
    print("  \(prog) save-all [port]        Save both window and layout in one call")
    print("  \(prog) restore-all [port]     Restore window then layout with proper timing")
    print("  \(prog) list-displays          List connected displays with their frames")
    print("")
    print("Default CDP port: 9333")
    print("Default code-server CDP port: \(CODESERVER_PORT)")
    print("Config: ~/.config/vscode-cdp-automator/config.json")
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

let cdpPort: () -> Int = {
    if args.count >= 3, let p = Int(args[2]) { return p }
    return 9333
}

let codeServerPort: () -> Int = {
    if args.count >= 3, let p = Int(args[2]) { return p }
    return CODESERVER_PORT
}

switch args[1] {
case "save-win":
    cmdSaveWin()
case "restore-win":
    cmdRestoreWin(port: cdpPort())
case "save-layout":
    cmdSaveLayout(port: cdpPort())
case "restore-layout":
    cmdRestoreLayout(port: cdpPort())
case "save-codeserver-layout":
    cmdSaveCodeServerLayout(port: codeServerPort())
case "restore-codeserver-layout":
    cmdRestoreCodeServerLayout(port: codeServerPort())
case "save-all":
    cmdSaveAll(port: cdpPort())
case "restore-all":
    cmdRestoreAll(port: cdpPort())
case "list-displays":
    cmdListDisplays()
default:
    usage()
}
