import Cocoa
import Foundation

// MARK: - Display Layout Save

func cmdSaveDisplayLayout() -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/displayplacer")
    p.arguments = ["list"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        fputs("displayplacer not found: \(error)\n", stderr)
        return EXIT_PRECONDITION
    }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        fputs("displayplacer list failed\n", stderr)
        return EXIT_FAILED
    }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    // Verify displayplacer produced output we can parse
    let hasCmd = out.components(separatedBy: "\n").contains { $0.hasPrefix("displayplacer ") }
    guard hasCmd else {
        fputs("No displayplacer command in output\n", stderr)
        return EXIT_FAILED
    }

    let fingerPrint = displayFingerprint()
    var store = loadConfigStore()
    var entry = store[fingerPrint] ?? DisplayConfig()

    // Parse displayplacer list structured output into our JSON format
    let displays = parseDisplayplacerList(out)
    entry.monitors = DisplayLayout(displays: displays)

    store[fingerPrint] = entry
    guard saveConfigStore(store) else { return EXIT_FAILED }

    print("Saved \(displays.count) display(s) to \(CONFIG_PATH)")
    for d in displays {
        print("  \(d.id.prefix(8))... \(d.resolution) @(\(d.origin.x),\(d.origin.y)) rot=\(d.rotation)°")
    }
    return EXIT_OK
}

func parseDisplayplacerList(_ text: String) -> [MonitorEntry] {
    var displays: [MonitorEntry] = []
    var current: (id: String?, cid: String?, sid: String?, type: String?, res: String?, hz: Int?, depth: Int?, scaling: String?, ox: Int?, oy: Int?, rot: Int?, enabled: Bool?)?

    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Persistent screen id: ") {
            if let c = current, let id = c.id, let res = c.res, let ox = c.ox, let oy = c.oy, let rot = c.rot, let hz = c.hz {
                displays.append(MonitorEntry(
                    id: id, contextual_id: c.cid, serial_id: c.sid, type: c.type,
                    resolution: res, hertz: hz, color_depth: c.depth ?? 8,
                    scaling: c.scaling ?? "off",
                    origin: MonitorOrigin(x: ox, y: oy),
                    rotation: rot, enabled: c.enabled ?? true
                ))
            }
            current = (String(trimmed.dropFirst("Persistent screen id: ".count)), nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
        } else if trimmed.hasPrefix("Contextual screen id: ") {
            current?.cid = String(trimmed.dropFirst("Contextual screen id: ".count))
        } else if trimmed.hasPrefix("Serial screen id: ") {
            current?.sid = String(trimmed.dropFirst("Serial screen id: ".count))
        } else if trimmed.hasPrefix("Type: ") {
            current?.type = String(trimmed.dropFirst("Type: ".count))
        } else if trimmed.hasPrefix("Resolution: ") {
            current?.res = String(trimmed.dropFirst("Resolution: ".count))
        } else if trimmed.hasPrefix("Hertz: ") {
            current?.hz = Int(String(trimmed.dropFirst("Hertz: ".count)))
        } else if trimmed.hasPrefix("Color Depth: ") {
            current?.depth = Int(String(trimmed.dropFirst("Color Depth: ".count)))
        } else if trimmed.hasPrefix("Scaling: ") {
            current?.scaling = String(trimmed.dropFirst("Scaling: ".count))
        } else if trimmed.hasPrefix("Origin: (") {
            let rest = trimmed.dropFirst("Origin: (".count)
            if let closeIdx = rest.firstIndex(of: ")") {
                let coords = rest[..<closeIdx]
                let parts = coords.split(separator: ",")
                if parts.count >= 2 {
                    current?.ox = Int(parts[0].trimmingCharacters(in: .whitespaces))
                    current?.oy = Int(parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
        } else if trimmed.hasPrefix("Rotation: ") {
            current?.rot = Int(String(trimmed.dropFirst("Rotation: ".count)))
        } else if trimmed.hasPrefix("Enabled: ") {
            current?.enabled = trimmed.dropFirst("Enabled: ".count) == "true"
        }
    }
    if let c = current, let id = c.id, let res = c.res, let ox = c.ox, let oy = c.oy, let rot = c.rot, let hz = c.hz {
        displays.append(MonitorEntry(
            id: id, contextual_id: c.cid, serial_id: c.sid, type: c.type,
            resolution: res, hertz: hz, color_depth: c.depth ?? 8,
            scaling: c.scaling ?? "off",
            origin: MonitorOrigin(x: ox, y: oy),
            rotation: rot, enabled: c.enabled ?? true
        ))
    }
    return displays
}

// MARK: - Display Layout Restore

func readCurrentDisplays() -> [MonitorEntry] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/displayplacer")
    p.arguments = ["list"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        return []
    }
    guard p.terminationStatus == 0 else { return [] }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return parseDisplayplacerList(out)
}

func applyRule(_ rule: MonitorRule, to current: [MonitorEntry]) -> [MonitorEntry] {
    var xCursor = rule.layout.origin.x
    var overrides: [String: (x: Int, y: Int, rotation: Int)] = [:]
    for member in rule.layout.members {
        overrides[member.id] = (x: xCursor, y: rule.layout.origin.y, rotation: member.rotation)
        xCursor += member.width
    }
    return current.map { entry in
        guard let ov = overrides[entry.id] else { return entry }
        return MonitorEntry(
            id: entry.id,
            contextual_id: entry.contextual_id,
            serial_id: entry.serial_id,
            type: entry.type,
            resolution: entry.resolution,
            hertz: entry.hertz,
            color_depth: entry.color_depth,
            scaling: entry.scaling,
            origin: MonitorOrigin(x: ov.x, y: ov.y),
            rotation: ov.rotation,
            enabled: entry.enabled
        )
    }
}

func runDisplayplacer(_ displays: [MonitorEntry]) -> Int32 {
    let parts = displays.map { d -> String in
        "id:\(d.id) res:\(d.resolution) hz:\(d.hertz) color_depth:\(d.color_depth) enabled:true scaling:off origin:(\(d.origin.x),\(d.origin.y)) degree:\(d.rotation)"
    }
    let cmd = "/opt/homebrew/bin/displayplacer " + parts.map { "\"\($0)\"" }.joined(separator: " ")
    print("Running: \(cmd)")

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    do {
        try p.run()
    } catch {
        fputs("Failed to run displayplacer: \(error)\n", stderr)
        return EXIT_FAILED
    }
    p.waitUntilExit()

    if p.terminationStatus == 0 {
        print("Display layout restored (\(displays.count) displays)")
    } else {
        fputs("displayplacer exited with code \(p.terminationStatus)\n", stderr)
        return EXIT_FAILED
    }
    return EXIT_OK
}

func cmdRestoreDisplayLayout() -> Int32 {
    let store = loadConfigStore()
    let fingerPrint = displayFingerprint()

    // Path 1: saved snapshot exists → use it
    if let layout = store[fingerPrint]?.monitors, !layout.displays.isEmpty {
        return runDisplayplacer(layout.displays)
    }

    // Path 2: no snapshot → try rules
    let current = readCurrentDisplays()
    guard !current.isEmpty else {
        fputs("Cannot read current displays.\n", stderr)
        return EXIT_FAILED
    }
    let currentIds = Set(current.map { $0.id })
    let rules = loadConfigRules()
    for rule in rules {
        let required = Set(rule.match.all_of)
        guard required.isSubset(of: currentIds) else { continue }

        let n = required.count
        print("No snapshot for current display layout; rule '\(rule.name ?? "(unnamed)")' matched (\(n)/\(n) UUIDs present). Applying rule layout.")
        if verboseLogging {
            for m in rule.layout.members {
                print("  \(m.id.prefix(8))... → rot \(m.rotation)° at slot width=\(m.width)")
            }
        }

        let target = applyRule(rule, to: current)
        return runDisplayplacer(target)
    }

    fputs("Skipping restore-displays: no saved display layout and no matching rule.\n", stderr)
    return EXIT_PRECONDITION
}

// MARK: - Check if display layout changed

func displayLayoutChanged() -> Bool {
    let store = loadConfigStore()
    let fp = displayFingerprint()
    return store[fp]?.monitors != nil
}

// MARK: - Save All

func runSubCommand(_ args: [String]) -> Int32 {
    fflush(stdout)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    proc.arguments = args
    do {
        try proc.run()
    } catch {
        fputs("Failed to run subcommand \(args.joined(separator: " ")): \(error)\n", stderr)
        return EXIT_FAILED
    }
    proc.waitUntilExit()
    return proc.terminationStatus
}

func gitRoot() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["rev-parse", "--show-toplevel"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
    } catch { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (out?.isEmpty == false) ? out : nil
}

func repoRoot() -> String? {
    let fm = FileManager.default
    let exeURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let exeDir = exeURL.deletingLastPathComponent()
    // Prefer exe-relative locations and git root; CWD last (untrusted).
    var candidates: [String] = [
        exeDir.path,
        exeDir.deletingLastPathComponent().path,
    ]
    if let gr = gitRoot() { candidates.append(gr) }
    candidates.append(fm.currentDirectoryPath)
    for c in candidates {
        var isDir: ObjCBool = false
        let full = c + "/tools/vivaldi-title-split.mjs"
        if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
            if verboseLogging { fputs("repoRoot: \(c)\n", stderr) }
            return c
        }
    }
    return nil
}

func runNodeTool(_ args: [String]) -> Int32 {
    fflush(stdout)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["node"] + args
    do {
        try proc.run()
    } catch {
        fputs("Failed to run node: \(error)\n", stderr)
        return EXIT_FAILED
    }
    proc.waitUntilExit()
    return proc.terminationStatus
}

func runVivaldiTitleSplit() -> Int32 {
    guard let root = repoRoot() else {
        print("tools/vivaldi-title-split.mjs not found")
        return 1
    }
    return runNodeTool([root + "/tools/vivaldi-title-split.mjs"])
}

func stageResult(_ t0: Date, _ name: String, _ code: Int32) {
    let label: String
    switch code {
    case EXIT_OK: label = "OK"
    case EXIT_PRECONDITION: label = "SKIPPED"
    default: label = "FAILED"
    }
    print("[\(nowStamp()) +\(elapsed(t0))] \(name): \(label) (\(code))")
}

func cmdSaveAll(port: Int) -> Int32 {
    let t0 = Date()
    // In-process orchestration: direct calls, no sub-process re-exec.
    stageLog(t0, "save-monitors")
    let mr = cmdSaveDisplayLayout()
    stageResult(t0, "save-monitors", mr)
    print("")
    stageLog(t0, "save-layout")
    let lr = cmdSaveLayout(port: port)
    stageResult(t0, "save-layout", lr)
    print("")
    stageLog(t0, "save-win")
    let wr = cmdSaveWin()
    stageResult(t0, "save-win", wr)
    print("")
    stageLog(t0, "save-codeserver-layout")
    let cr = cmdSaveCodeServerLayout(port: CODESERVER_PORT)
    stageResult(t0, "save-codeserver-layout", cr)
    print("")
    stageLog(t0, "save-vivaldi")
    let vr = cmdSaveVivaldi(port: CODESERVER_PORT)
    stageResult(t0, "save-vivaldi", vr)
    print("")
    stageLog(t0, "save-vivaldi-zoom")
    let zr = cmdSaveVivaldiZoom(port: CODESERVER_PORT)
    stageResult(t0, "save-vivaldi-zoom", zr)
    print("")
    stageLog(t0, "save-windows")
    let owr = cmdSaveWindows()
    stageResult(t0, "save-windows", owr)
    let failed = [mr, lr, wr, cr, vr, zr, owr].filter { $0 != EXIT_OK && $0 != EXIT_PRECONDITION }
    // Precondition-skips don't fail save-all; real failures do.

    print("")
    stageLog(t0, "vivaldi-title-split")
    _ = runVivaldiTitleSplit()
    print("\n[\(nowStamp()) +\(elapsed(t0))] save-all done")
    return failed.isEmpty ? EXIT_OK : EXIT_FAILED
}

// MARK: - Restore All

func cmdRestoreAll(port: Int) -> Int32 {
    let t0 = Date()

    // 1. Restore monitor layout first
    stageLog(t0, "restore-monitors")
    let mr = cmdRestoreDisplayLayout()
    stageResult(t0, "restore-monitors", mr)
    print("")

    // 2. If monitors were actually repositioned, wait for elements to settle
    let wasChanged = (mr == EXIT_OK)
    if wasChanged {
        print("[\(nowStamp()) +\(elapsed(t0))] Monitors repositioned, waiting 1s for elements to settle...")
        Thread.sleep(forTimeInterval: 1.0)
    }

    stageLog(t0, "restore-win")
    let wr = cmdRestoreWin(port: port)
    stageResult(t0, "restore-win", wr)
    print("")
    Thread.sleep(forTimeInterval: 0.1)
    stageLog(t0, "restore-layout")
    let lr = cmdRestoreLayout(port: port)
    stageResult(t0, "restore-layout", lr)
    print("")
    Thread.sleep(forTimeInterval: 0.1)
    stageLog(t0, "restore-vivaldi")
    let vr = cmdRestoreVivaldi(port: CODESERVER_PORT)
    stageResult(t0, "restore-vivaldi", vr)
    print("")
    Thread.sleep(forTimeInterval: 0.1)
    stageLog(t0, "restore-vivaldi-zoom")
    let zr = cmdRestoreVivaldiZoom(port: CODESERVER_PORT)
    stageResult(t0, "restore-vivaldi-zoom", zr)
    print("")
    Thread.sleep(forTimeInterval: 0.1)
    stageLog(t0, "restore-windows")
    let owr = cmdRestoreWindows()
    stageResult(t0, "restore-windows", owr)
    print("")
    Thread.sleep(forTimeInterval: 0.1)
    stageLog(t0, "restore-codeserver-layout")
    let cr = cmdRestoreCodeServerLayout(port: CODESERVER_PORT)
    stageResult(t0, "restore-codeserver-layout", cr)
    let failed = [mr, wr, lr, vr, zr, owr, cr].filter { $0 != EXIT_OK && $0 != EXIT_PRECONDITION }

    print("")
    stageLog(t0, "vivaldi-title-split")
    _ = runVivaldiTitleSplit()
    print("\n[\(nowStamp()) +\(elapsed(t0))] restore-all done")
    return failed.isEmpty ? EXIT_OK : EXIT_FAILED
}

// MARK: - List Displays

func cmdListDisplays() -> Int32 {
    print("\(NSScreen.screens.count) display(s):\n")
    for (i, screen) in NSScreen.screens.enumerated() {
        let name = screen.localizedName.isEmpty ? "(unnamed)" : screen.localizedName
        let f = screen.frame
        let resolved = "x=\(Int(f.origin.x)) y=\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"
        let isMain = (screen == NSScreen.screens.first) ? " ← main" : ""
        print("[\(i)] \(name)  \(resolved)\(isMain)")
    }
    return EXIT_OK
}

