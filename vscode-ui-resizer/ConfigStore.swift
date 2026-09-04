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

let VIVALDI_BUNDLE_ID = "com.vivaldi.Vivaldi"

let CONFIG_PATH = NSString(string: "~/.config/vscode-cdp-automator/config.json").expandingTildeInPath
let LEGACY_WIN_CONFIG_PATH = NSString(string: "~/.config/vscode/windows.json").expandingTildeInPath
let LEGACY_LAYOUT_CONFIG_PATH = NSString(string: "~/.config/vscode/panel-and-bar-sides.json").expandingTildeInPath
let USER_SETTINGS_PATH = NSString(string: "~/Library/Application Support/Code/User/settings.json").expandingTildeInPath
let ZOOM_LEVEL_KEY = "window.zoomLevel"
let CODESERVER_PORT = 9222
let AX_TIMEOUT: Float = 3.0

let EXIT_OK: Int32 = 0
let EXIT_FAILED: Int32 = 1
let EXIT_PRECONDITION: Int32 = 2

var verboseLogging = false

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

struct VivaldiConfig: Codable {
    var tabBarWidth: Int?
    var tabBarPosition: String?
    var window: WindowInfo?
    var uiZoom: Double?
    var defaultZoom: Double?
}

struct DisplayConfig: Codable {
    var window: WindowInfo? = nil
    var windows: [WindowInfo]? = nil
    var layout: LayoutConfig? = nil
    var codeServerLayout: LayoutConfig? = nil
    var vivaldi: VivaldiConfig? = nil
    var otherWindows: [String: [WindowInfo]]? = nil
}

func loadConfigStore() -> [String: DisplayConfig] {
    if FileManager.default.fileExists(atPath: CONFIG_PATH) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: CONFIG_PATH))
            let store = try JSONDecoder().decode([String: DisplayConfig].self, from: data)
            return store
        } catch {
            fputs("Config at \(CONFIG_PATH) is corrupt (\(error)); leaving untouched, using empty store.\n", stderr)
            return [:]
        }
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

func screenFrameString(_ f: NSRect) -> String {
    return "x=\(Int(f.origin.x)) y=\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"
}

struct ScreenRef {
    let displayID: CGDirectDisplayID?
    let framePt: NSRect
    let scale: CGFloat
}

func screenRef(for screen: NSScreen) -> ScreenRef {
    var displayID: CGDirectDisplayID?
    var scale: CGFloat = screen.backingScaleFactor
    if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
        displayID = num
        if let mode = CGDisplayCopyDisplayMode(num), mode.pixelWidth > 0 {
            let frameW = max(screen.frame.width, 1)
            scale = CGFloat(mode.pixelWidth) / frameW
        }
    }
    if scale <= 0 { scale = 1 }
    return ScreenRef(displayID: displayID, framePt: screen.frame, scale: scale)
}

func resolveGlobalPosition(from info: WindowInfo) -> (point: CGPoint, source: PositionSource) {
    if let rx = info.screenRelativeX, let ry = info.screenRelativeY {
        for screen in NSScreen.screens {
            let f = screen.frame
            if screenFrameString(f) == info.screenFrame {
                return (CGPoint(x: f.origin.x + rx, y: f.origin.y + ry), .matched)
            }
        }
        // Legacy v1 keys stored pixel sizes in the frame string; try point-equality
        // within 1pt plus relative-offset fallback to primary.
        if let primary = NSScreen.screens.first {
            let f = primary.frame
            return (CGPoint(x: f.origin.x + rx, y: f.origin.y + ry), .rawFallback)
        }
    }
    return (CGPoint(x: info.x, y: info.y), .rawFallback)
}

func legacyResolveGlobalPosition(from info: WindowInfo) -> CGPoint {
    return resolveGlobalPosition(from: info).point
}

func isPositionOnScreen(_ pt: CGPoint) -> Bool {
    return NSScreen.screens.contains(where: { $0.frame.contains(pt) })
}

enum PositionSource: String {
    case matched
    case rawFallback
    case clamped
}

func clampToVisible(_ pt: CGPoint, size: CGSize) -> (point: CGPoint, source: PositionSource) {
    if isPositionOnScreen(pt) { return (pt, .matched) }
    // Try keeping size on-screen: clamp top-left into main visible frame with margin.
    let margin: CGFloat = 50
    if let main = NSScreen.screens.first {
        let vf = main.visibleFrame
        var x = pt.x
        var y = pt.y
        x = min(max(x, vf.minX), max(vf.minX, vf.maxX - margin))
        y = min(max(y, vf.minY), max(vf.minY, vf.maxY - margin))
        let clamped = CGPoint(x: x, y: y)
        if isPositionOnScreen(clamped) { return (clamped, .clamped) }
        return (CGPoint(x: vf.origin.x + margin, y: vf.origin.y + margin), .clamped)
    }
    return (pt, .rawFallback)
}

func screenMatchingFrame(_ frameStr: String) -> NSScreen? {
    return NSScreen.screens.first(where: { screenFrameString($0.frame) == frameStr })
}

func resolveAndClamp(from info: WindowInfo) -> (point: CGPoint, source: PositionSource) {
    let (pt, src) = resolveGlobalPosition(from: info)
    if isPositionOnScreen(pt) { return (pt, src) }
    // Matched-screen path: arrangement is the same as at save time, so trust
    // saved coords within tolerance. Strict contains() rejects near-misses
    // (menu-bar gap ~27px, exclusive max edges) that were valid at save;
    // clamping those to main moves windows to the wrong display.
    if src == .matched, let screen = screenMatchingFrame(info.screenFrame) {
        let f = screen.frame
        let tol: CGFloat = 60
        if f.insetBy(dx: -tol, dy: -tol).contains(pt) { return (pt, src) }
        let rect = CGRect(origin: pt, size: CGSize(width: info.width, height: info.height))
        if !f.intersection(rect).isNull { return (pt, src) }
        // Genuinely off its screen: clamp into it, not main.
        let vf = screen.visibleFrame
        let margin: CGFloat = 50
        let x = min(max(pt.x, vf.minX), max(vf.minX, vf.maxX - margin))
        let y = min(max(pt.y, vf.minY), max(vf.minY, vf.maxY - margin))
        return (CGPoint(x: x, y: y), .clamped)
    }
    let fallback = CGPoint(x: info.x, y: info.y)
    if isPositionOnScreen(fallback) { return (fallback, .rawFallback) }
    let size = CGSize(width: info.width, height: info.height)
    let (clamped, _) = clampToVisible(fallback, size: size)
    return (clamped, .clamped)
}

