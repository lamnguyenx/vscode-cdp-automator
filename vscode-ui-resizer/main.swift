import Cocoa
import Foundation

// MARK: - Main

func usage() -> Never {
    let prog = (CommandLine.arguments[0] as NSString).lastPathComponent
    print("Usage:")
    print("  \(prog) [--verbose] save-win               Save position & size of all VS Code windows")
    print("  \(prog) [--verbose] restore-win [port]     Apply saved position & size to eligible VS Code windows (title-matched)")
    print("  \(prog) [--verbose] save-layout [port]     Save panel/sidebar layout of the active VS Code window")
    print("  \(prog) [--verbose] restore-layout [port]  Restore saved panel/sidebar layout to all VS Code windows")
    print("  \(prog) [--verbose] save-codeserver-layout [port]   Save layout of the active code-server tab in Chrome")
    print("  \(prog) [--verbose] restore-codeserver-layout [port]  Restore layout to all code-server tabs")
    print("  \(prog) [--verbose] save-vivaldi [port]    Save Vivaldi tab-bar width & window geometry")
    print("  \(prog) [--verbose] restore-vivaldi [port] Restore Vivaldi tab-bar width & window geometry")
    print("  \(prog) [--verbose] save-vivaldi-zoom [port]    Save Vivaldi UI zoom & default page zoom")
    print("  \(prog) [--verbose] restore-vivaldi-zoom [port] Restore Vivaldi UI zoom, default zoom, and apply it to all tabs")
    print("  \(prog) [--verbose] save-windows           Save pos & size of all other open GUI app windows")
    print("  \(prog) [--verbose] restore-windows        Apply saved geometry to windows of already-running apps (title-matched)")
    print("  \(prog) [--verbose] vivaldi-tab-numbers [port]  Enable tab order numbers in Vivaldi's tab bar")
    print("  \(prog) [--verbose] save-all [port]        Save both window and layout in one call")
    print("  \(prog) [--verbose] restore-all [port]     Restore window then layout with proper timing")
    print("  \(prog) list-displays          List connected displays with their frames")
    print("")
    print("Default CDP port: 9333")
    print("Default code-server CDP port: \(CODESERVER_PORT)")
    print("Config: ~/.config/vscode-cdp-automator/config.json")
    print("Exit codes: 0 ok, 1 failed, 2 precondition (AX denied / CDP unreachable / no saved data)")
    exit(1)
}

var rawArgs = CommandLine.arguments
if let vi = rawArgs.firstIndex(of: "--verbose") {
    verboseLogging = true
    rawArgs.remove(at: vi)
}
let args = rawArgs
guard args.count >= 2 else { usage() }

let cdpPort: () -> Int = {
    if args.count >= 3, let p = Int(args[2]) { return p }
    return 9333
}

let codeServerPort: () -> Int = {
    if args.count >= 3, let p = Int(args[2]) { return p }
    return CODESERVER_PORT
}

let exitCode: Int32 = {
    switch args[1] {
    case "save-win":
        return cmdSaveWin()
    case "restore-win":
        return cmdRestoreWin(port: cdpPort())
    case "save-layout":
        return cmdSaveLayout(port: cdpPort())
    case "restore-layout":
        return cmdRestoreLayout(port: cdpPort())
    case "save-codeserver-layout":
        return cmdSaveCodeServerLayout(port: codeServerPort())
    case "restore-codeserver-layout":
        return cmdRestoreCodeServerLayout(port: codeServerPort())
    case "save-vivaldi":
        return cmdSaveVivaldi(port: codeServerPort())
    case "restore-vivaldi":
        return cmdRestoreVivaldi(port: codeServerPort())
    case "save-vivaldi-zoom":
        return cmdSaveVivaldiZoom(port: codeServerPort())
    case "restore-vivaldi-zoom":
        return cmdRestoreVivaldiZoom(port: codeServerPort())
    case "save-windows":
        return cmdSaveWindows()
    case "restore-windows":
        return cmdRestoreWindows()
    case "vivaldi-tab-numbers":
        return cmdVivaldiTabNumbers(port: codeServerPort())
    case "save-all":
        return cmdSaveAll(port: cdpPort())
    case "restore-all":
        return cmdRestoreAll(port: cdpPort())
    case "list-displays":
        return cmdListDisplays()
    default:
        usage()
    }
}()
exit(exitCode)
