import Cocoa
import Foundation

// MARK: - Accessibility Helpers

func checkAXTrust() -> Bool {
    guard AXIsProcessTrusted() else {
        fputs("Accessibility permission missing: grant in System Settings > Privacy & Security > Accessibility, then re-run.\n", stderr)
        return false
    }
    return true
}

func requireAXTrust() -> Bool {
    return checkAXTrust()
}

func applyAXTimeout(_ el: AXUIElement) {
    AXUIElementSetMessagingTimeout(el, AX_TIMEOUT)
}

func axGetString(_ el: AXUIElement, _ attr: String) -> String? {
    applyAXTimeout(el)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? String
}

func axGetArray(_ el: AXUIElement, _ attr: String) -> [AXUIElement]? {
    applyAXTimeout(el)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? [AXUIElement]
}

func axGetPoint(_ el: AXUIElement, _ attr: String) -> CGPoint? {
    applyAXTimeout(el)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
          let raw = v,
          CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let axVal = raw as! AXValue
    var pt = CGPoint.zero
    guard AXValueGetValue(axVal, .cgPoint, &pt) else { return nil }
    return pt
}

func axGetSize(_ el: AXUIElement, _ attr: String) -> CGSize? {
    applyAXTimeout(el)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
          let raw = v,
          CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let axVal = raw as! AXValue
    var sz = CGSize.zero
    guard AXValueGetValue(axVal, .cgSize, &sz) else { return nil }
    return sz
}

func axCast(_ ref: CFTypeRef?) -> AXUIElement? {
    guard let ref = ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
    return (ref as! AXUIElement)
}

func axSetPoint(_ el: AXUIElement, _ attr: String, _ pt: CGPoint) -> Bool {
    applyAXTimeout(el)
    var p = pt
    guard let val = withUnsafePointer(to: &p, { AXValueCreate(.cgPoint, $0) }) else { return false }
    let err = AXUIElementSetAttributeValue(el, attr as CFString, val)
    if err != .success && verboseLogging {
        fputs("AXSet \(attr) -> \(err.rawValue)\n", stderr)
    }
    return err == .success
}

func axSetSize(_ el: AXUIElement, _ attr: String, _ sz: CGSize) -> Bool {
    applyAXTimeout(el)
    var s = sz
    guard let val = withUnsafePointer(to: &s, { AXValueCreate(.cgSize, $0) }) else { return false }
    let err = AXUIElementSetAttributeValue(el, attr as CFString, val)
    if err != .success && verboseLogging {
        fputs("AXSet \(attr) -> \(err.rawValue)\n", stderr)
    }
    return err == .success
}

func axGetBool(_ el: AXUIElement, _ attr: String) -> Bool? {
    applyAXTimeout(el)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? Bool
}

func isFullScreen(_ win: AXUIElement) -> Bool {
    return axGetBool(win, "AXFullScreen") == true
}

func exitFullScreen(_ win: AXUIElement) -> Bool {
    applyAXTimeout(win)
    let err = AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanFalse)
    if err != .success && err != .cannotComplete {
        if verboseLogging { fputs("exitFullScreen set -> \(err.rawValue)\n", stderr) }
    }
    for _ in 0..<30 {
        Thread.sleep(forTimeInterval: 0.25)
        if !isFullScreen(win) { return true }
    }
    return !isFullScreen(win)
}

func axGetPID(_ el: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return pid
}

// MARK: - Window Geometry Apply (shared retry loop)

func applyWindowGeometry(
    _ win: AXUIElement,
    target: WindowInfo,
    globalPos: CGPoint,
    maxRetries: Int = 5,
    firstSleep: TimeInterval = 0.15,
    retrySleep: TimeInterval = 0.2,
    verboseFullscreen: Bool = true
) -> Bool {
    if isFullScreen(win) {
        print("    full-screen detected, exiting...")
        let exited = exitFullScreen(win)
        if verboseFullscreen {
            if !exited {
                print("    WARNING: could not exit full-screen, position/size may fail")
            } else {
                print("    exited full-screen")
            }
        }
    }

    var ok = false
    // Break display-fill (maximized) state first: a window filling its display
    // (both dims ≈ display size) silently drops size changes, snapping back to
    // fill — even small stepped ones. A single large height change escapes the
    // fill state, after which the stepped walk below converges (verified).
    if let curSize0 = axGetSize(win, "AXSize"), let curPos0 = axGetPoint(win, "AXPosition") {
        let scr = NSScreen.screens.first(where: { $0.frame.contains(curPos0) })
            ?? NSScreen.screens.min(by: { edgeDistance(curPos0, $0.frame) < edgeDistance(curPos0, $1.frame) })
        if let f = scr?.frame,
           abs(curSize0.width - f.width) < 60 && abs(curSize0.height - f.height) < 60 {
            let breakH = max(400.0, curSize0.height - 900.0)
            if abs(breakH - curSize0.height) > 100 {
                _ = axSetSize(win, "AXSize", CGSize(width: curSize0.width, height: breakH))
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
    }
    for attempt in 1...maxRetries {
        let posSet = axSetPoint(win, "AXPosition", globalPos)
        // Grow/shrink large size deltas incrementally: big single AXSize jumps
        // (roughly 800px+ on width, e.g. single-display -> 3-display span) are
        // silently ignored, while steps of ~400px apply reliably. Walk the
        // size up so each step commits before the next begins.
        let targetSize = CGSize(width: target.width, height: target.height)
        var sizeSet = true
        if let curSize = axGetSize(win, "AXSize") {
            let dw = targetSize.width - curSize.width
            let dh = targetSize.height - curSize.height
            let steps = max(1, Int(ceil(max(abs(dw) / 400.0, abs(dh) / 400.0))))
            if steps > 1 {
                for s in 1...steps {
                    let t = Double(s) / Double(steps)
                    let interim = CGSize(width: curSize.width + dw * t,
                                         height: curSize.height + dh * t)
                    sizeSet = axSetSize(win, "AXSize", interim) && sizeSet
                    Thread.sleep(forTimeInterval: 0.1)
                }
            } else {
                sizeSet = axSetSize(win, "AXSize", targetSize)
            }
        } else {
            sizeSet = axSetSize(win, "AXSize", targetSize)
        }
        if !posSet || !sizeSet {
            // .notAllowed / .invalidUIElement are permanent; don't burn retries.
            if verboseLogging {
                fputs("    AX set failed (pos=\(posSet) size=\(sizeSet)), retrying...\n", stderr)
            }
        }

        Thread.sleep(forTimeInterval: attempt == 1 ? firstSleep : retrySleep)

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
    return ok
}

// MARK: - Devhost Detection

nonisolated(unsafe) private var devHostCommandCache: [pid_t: String]?
nonisolated(unsafe) private var devHostCommandCachePopulated = false

func devHostCommandMap() -> [pid_t: String] {
    if let cached = devHostCommandCache { return cached }
    var map: [pid_t: String] = [:]
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-ax", "-o", "pid=,command="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        fputs("Warning: could not run /bin/ps for dev-host detection: \(error)\n", stderr)
        devHostCommandCache = map
        devHostCommandCachePopulated = true
        return map
    }
    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""
    for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let pidInt = Int32(parts[0]) else { continue }
        map[pidInt] = String(parts[1])
    }
    devHostCommandCache = map
    devHostCommandCachePopulated = true
    _ = devHostCommandCachePopulated
    return map
}

func isDevHostProcess(pid: pid_t) -> Bool {
    let map = devHostCommandMap()
    if let cmd = map[pid] {
        return cmd.contains("--extensionDevelopmentPath")
    }
    // Fallback to single-pid query if pid missing from bulk listing (race).
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
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
        applyAXTimeout(appEl)
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
    guard let frontApp = NSWorkspace.shared.frontmostApplication,
          let bid = frontApp.bundleIdentifier,
          VSCODE_BUNDLES.contains(bid) else {
        fputs("Frontmost app is not VS Code.\n", stderr)
        return nil
    }

    if isDevHostProcess(pid: frontApp.processIdentifier) {
        fputs("Frontmost app is a VS Code dev host instance.\n", stderr)
        return nil
    }

    let appEl = AXUIElementCreateApplication(frontApp.processIdentifier)
    applyAXTimeout(appEl)

    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, "AXFocusedWindow" as CFString, &focused) == .success,
          let fw = focused,
          let win = axCast(fw) else {
        fputs("Could not get focused VS Code window.\n", stderr)
        return nil
    }

    applyAXTimeout(win)
    var title = axGetString(win, "AXTitle") ?? ""
    if title.isEmpty {
        var main: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, "AXMainWindow" as CFString, &main) == .success,
           let mw = main,
           let mainWin = axCast(mw) {
            applyAXTimeout(mainWin)
            title = axGetString(mainWin, "AXTitle") ?? ""
        }
    }

    return (win, title, frontApp.processIdentifier)
}

func getFrontmostVSCodeTitle() -> String? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication,
          let bid = frontApp.bundleIdentifier,
          VSCODE_BUNDLES.contains(bid)
    else { return nil }

    let appEl = AXUIElementCreateApplication(frontApp.processIdentifier)
    applyAXTimeout(appEl)

    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, "AXFocusedWindow" as CFString, &focused) == .success,
          let fw = focused,
          let win = axCast(fw)
    else { return nil }

    applyAXTimeout(win)

    if let title = axGetString(win, "AXTitle"), !title.isEmpty {
        return title
    }

    var main: CFTypeRef?
    if AXUIElementCopyAttributeValue(appEl, "AXMainWindow" as CFString, &main) == .success,
       let mw = main,
       let mainWin = axCast(mw) {
        applyAXTimeout(mainWin)
        return axGetString(mainWin, "AXTitle")
    }

    return nil
}

// MARK: - Find Vivaldi Windows

func findVivaldiWindows() -> [(window: AXUIElement, app: AXUIElement, title: String, pid: pid_t)] {
    var results: [(AXUIElement, AXUIElement, String, pid_t)] = []

    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == VIVALDI_BUNDLE_ID }

    for app in apps {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        applyAXTimeout(appEl)
        guard let windows = axGetArray(appEl, "AXWindows") else { continue }

        for win in windows {
            let title = axGetString(win, "AXTitle") ?? ""
            results.append((win, appEl, title, app.processIdentifier))
        }
    }

    return results
}

func findFrontmostVivaldiWindow() -> (window: AXUIElement, title: String, pid: pid_t)? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication,
          frontApp.bundleIdentifier == VIVALDI_BUNDLE_ID
    else { return nil }

    let appEl = AXUIElementCreateApplication(frontApp.processIdentifier)
    applyAXTimeout(appEl)

    var focused: CFTypeRef?
    if AXUIElementCopyAttributeValue(appEl, "AXFocusedWindow" as CFString, &focused) == .success,
       let fw = focused,
       let win = axCast(fw) {
        applyAXTimeout(win)
        return (win, axGetString(win, "AXTitle") ?? "", frontApp.processIdentifier)
    }

    var main: CFTypeRef?
    if AXUIElementCopyAttributeValue(appEl, "AXMainWindow" as CFString, &main) == .success,
       let mw = main,
       let win = axCast(mw) {
        applyAXTimeout(win)
        return (win, axGetString(win, "AXTitle") ?? "", frontApp.processIdentifier)
    }

    return nil
}

// MARK: - Find Other (Generic) App Windows

func findOtherApps() -> [(bundleID: String, pid: pid_t, appEl: AXUIElement, windows: [AXUIElement])] {
    var results: [(String, pid_t, AXUIElement, [AXUIElement])] = []

    let apps = NSWorkspace.shared.runningApplications.filter { app in
        guard app.activationPolicy == .regular,
              let bid = app.bundleIdentifier
        else { return false }
        if VSCODE_BUNDLES.contains(bid) { return false }
        if bid == VIVALDI_BUNDLE_ID { return false }
        return true
    }

    for app in apps {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        applyAXTimeout(appEl)
        guard let windows = axGetArray(appEl, "AXWindows"), !windows.isEmpty else { continue }
        results.append((app.bundleIdentifier!, app.processIdentifier, appEl, windows))
    }

    return results
}

