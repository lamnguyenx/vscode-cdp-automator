import Cocoa
import Foundation

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
    let failed = [lr, wr, cr, vr, zr, owr].filter { $0 != EXIT_OK && $0 != EXIT_PRECONDITION }
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
    let failed = [wr, lr, vr, zr, owr, cr].filter { $0 != EXIT_OK && $0 != EXIT_PRECONDITION }

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

