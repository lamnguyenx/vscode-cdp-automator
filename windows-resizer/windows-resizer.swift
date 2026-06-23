import Cocoa

// MARK: - Constants

let VSCODE_BUNDLES = [
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.microsoft.VSCodeExploration",
    "com.microsoft.VSCode.Oss",
    "com.visualstudio.code.oss",
]

let CONFIG_PATH = NSString(string: "~/.config/vscode/windows.json").expandingTildeInPath

// MARK: - Window Data (Codable for JSON)

struct WindowInfo: Codable {
    let title: String
    let pid: Int32
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let screenFrame: String
    let label: String
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

func axGetPID(_ el: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return pid
}

// MARK: - Screen Description

func describeScreen(containing point: CGPoint) -> String {
    for screen in NSScreen.screens {
        if screen.frame.contains(point) {
            let f = screen.frame
            return "x=\(Int(f.origin.x)) y=\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"
        }
    }
    return "off-screen"
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

// MARK: - Find Frontmost VS Code Window

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
        // Try the main window as fallback
        var main: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, "AXMainWindow" as CFString, &main) == .success,
           let mw = main {
            title = axGetString(mw as! AXUIElement, "AXTitle") ?? ""
        }
    }

    return (win, title, frontApp!.processIdentifier)
}

// MARK: - Save Command

func cmdSave() {
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

    let screen = describeScreen(containing: pos)

    let info = WindowInfo(
        title: title,
        pid: pid,
        x: Double(pos.x),
        y: Double(pos.y),
        width: Double(size.width),
        height: Double(size.height),
        screenFrame: screen,
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

    let dir = (CONFIG_PATH as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try json.write(to: URL(fileURLWithPath: CONFIG_PATH), options: .atomic)
    } catch {
        fputs("Failed to write \(CONFIG_PATH): \(error)\n", stderr)
        exit(1)
    }

    print("Saved → \(CONFIG_PATH)")
    print("  \"\(info.label)\"")
    print("  pos=(\(Int(info.x)), \(Int(info.y)))  size=\(Int(info.width))x\(Int(info.height))")
    print("  screen: \(info.screenFrame)")
}

// MARK: - Restore Command

func cmdRestore() {
    guard FileManager.default.fileExists(atPath: CONFIG_PATH) else {
        fputs("No saved data at \(CONFIG_PATH). Run 'save' first.\n", stderr)
        exit(1)
    }

    let target: WindowInfo
    do {
        let jsonData = try Data(contentsOf: URL(fileURLWithPath: CONFIG_PATH))
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

    print("Applying to \(current.count) open window(s):")
    print("  target: pos=(\(Int(target.x)), \(Int(target.y)))  size=\(Int(target.width))x\(Int(target.height))\n")

    for i in 0..<current.count {
        let (win, _, title, _) = current[i]

        print("[\(i+1)] \"\(title)\"")

        axSetPoint(win, "AXPosition", CGPoint(x: target.x, y: target.y))
        axSetSize(win, "AXSize", CGSize(width: target.width, height: target.height))

        Thread.sleep(forTimeInterval: 0.15)

        if let newPos = axGetPoint(win, "AXPosition"),
           let newSize = axGetSize(win, "AXSize") {
            let posOk = abs(newPos.x - CGFloat(target.x)) < 3 && abs(newPos.y - CGFloat(target.y)) < 3
            let sizeOk = abs(newSize.width - CGFloat(target.width)) < 3 && abs(newSize.height - CGFloat(target.height)) < 3
            let status = (posOk && sizeOk) ? "OK" : "MISMATCH"
            print("    pos=(\(Int(newPos.x)), \(Int(newPos.y)))  size=\(Int(newSize.width))x\(Int(newSize.height))  [\(status)]")
        }
        print("")
    }
}

// MARK: - Main

func usage() -> Never {
    let prog = (CommandLine.arguments[0] as NSString).lastPathComponent
    print("Usage:")
    print("  \(prog) save      Save position & size of the frontmost VS Code window")
    print("  \(prog) restore   Apply saved position & size to all open VS Code windows")
    print("")
    print("Data stored at ~/.config/vscode/windows.json")
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

switch args[1] {
case "save":
    cmdSave()
case "restore":
    cmdRestore()
default:
    usage()
}
