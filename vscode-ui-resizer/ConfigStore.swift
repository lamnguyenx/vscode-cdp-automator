import Cocoa
import Foundation
import Yams

// MARK: - Constants

let VSCODE_BUNDLES = [
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.microsoft.VSCodeExploration",
    "com.microsoft.VSCode.Oss",
    "com.visualstudio.code.oss",
]

let VIVALDI_BUNDLE_ID = "com.vivaldi.Vivaldi"

let CONFIG_PATH = NSString(string: "~/.config/vscode-cdp-automator/config.yaml").expandingTildeInPath
let LEGACY_JSON_CONFIG_PATH = NSString(string: "~/.config/vscode-cdp-automator/config.json").expandingTildeInPath
let MONITOR_RULES_FILENAME = "monitor-rules.yaml"
let LEGACY_WIN_CONFIG_PATH = NSString(string: "~/.config/vscode/windows.json").expandingTildeInPath
let LEGACY_LAYOUT_CONFIG_PATH = NSString(string: "~/.config/vscode/panel-and-bar-sides.json").expandingTildeInPath
let USER_SETTINGS_PATH = NSString(string: "~/Library/Application Support/Code/User/settings.json").expandingTildeInPath
let ZOOM_LEVEL_KEY = "window.zoomLevel"
let CODESERVER_PORT = 9222
let AX_TIMEOUT: Float = 3.0

let EXIT_OK: Int32 = 0
let EXIT_FAILED: Int32 = 1
let EXIT_PRECONDITION: Int32 = 2

nonisolated(unsafe) var verboseLogging = false

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

struct MonitorEntry: Codable {
    let id: String
    let contextual_id: String?
    let serial_id: String?
    let type: String?
    let resolution: String
    let hertz: Int
    let color_depth: Int
    let scaling: String
    let origin: MonitorOrigin
    let rotation: Int
    let enabled: Bool
}

struct MonitorOrigin: Codable {
    let x: Int
    let y: Int
}

struct DisplayLayout: Codable {
    let displays: [MonitorEntry]
}

// MARK: - Monitor Rules

struct MonitorRule: Codable {
    var name: String?
    var match: MonitorRuleMatch
    var layout: MonitorRuleLayout
}

struct MonitorRuleMatch: Codable {
    var all_of: [String]
}

struct MonitorRuleLayout: Codable {
    var type: String
    var origin: MonitorOrigin
    var members: [MonitorRuleMember]
}

struct MonitorRuleMember: Codable {
    var id: String
    var rotation: Int
    var width: Int
}

let builtinMonitorPresets: [MonitorRule] = [
    MonitorRule(
        name: "eink-row",
        match: MonitorRuleMatch(all_of: [
            "12DF9D18-D36A-4B71-B782-384E1AA1DDA7",
            "CA80224C-2647-4420-8DC2-2CC0F710BC17",
            "4E09C07E-CA1F-461A-B1A8-EDC759F564CE",
        ]),
        layout: MonitorRuleLayout(
            type: "row",
            origin: MonitorOrigin(x: -1080, y: 0),
            members: [
                MonitorRuleMember(id: "12DF9D18-D36A-4B71-B782-384E1AA1DDA7", rotation: 90,  width: 1080),
                MonitorRuleMember(id: "CA80224C-2647-4420-8DC2-2CC0F710BC17", rotation: 90,  width: 1080),
                MonitorRuleMember(id: "4E09C07E-CA1F-461A-B1A8-EDC759F564CE", rotation: 270, width: 1080),
            ]
        )
    )
]

struct DisplayConfig: Codable {
    var window: WindowInfo? = nil
    var windows: [WindowInfo]? = nil
    var layout: LayoutConfig? = nil
    var codeServerLayout: LayoutConfig? = nil
    var vivaldi: VivaldiConfig? = nil
    var otherWindows: [String: [WindowInfo]]? = nil
    var monitors: DisplayLayout? = nil
}

func migrateOldJSON() {
    let fm = FileManager.default
    let jsonPath = LEGACY_JSON_CONFIG_PATH
    guard fm.fileExists(atPath: jsonPath) else { return }
    guard !fm.fileExists(atPath: CONFIG_PATH) else {
        // Already have YAML; remove old JSON
        try? fm.removeItem(atPath: jsonPath)
        return
    }

    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        // Decode as generic JSON to rename displayLayout → monitors
        if let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var migrated = raw
            for (key, val) in raw {
                if var entry = val as? [String: Any] {
                    if let dl = entry["displayLayout"] {
                        entry["monitors"] = dl
                        entry.removeValue(forKey: "displayLayout")
                    }
                    migrated[key] = entry
                }
            }
            let migratedData = try JSONSerialization.data(withJSONObject: migrated)
            let decoder = YAMLDecoder()
            let store = try decoder.decode([String: DisplayConfig].self, from: migratedData)
            if saveConfigStore(store) {
                try fm.removeItem(atPath: jsonPath)
                fputs("Migrated \(jsonPath) → \(CONFIG_PATH)\n", stderr)
            }
        }
    } catch {
        fputs("Failed to migrate \(jsonPath): \(error)\n", stderr)
    }
}

func loadConfigStore() -> [String: DisplayConfig] {
    migrateOldJSON()

    if FileManager.default.fileExists(atPath: CONFIG_PATH) {
        do {
            let data = try String(contentsOf: URL(fileURLWithPath: CONFIG_PATH), encoding: .utf8)
            let store = try YAMLDecoder().decode([String: DisplayConfig].self, from: data)
            return pruneOldFingerprintKeys(store)
        } catch {
            fputs("Config at \(CONFIG_PATH) is corrupt (\(error)); leaving untouched, using empty store.\n", stderr)
            return pruneOldFingerprintKeys([:])
        }
    }

    var store: [String: DisplayConfig] = [:]

    // Migrate legacy configs into the current fingerprint key
    let fp = displayFingerprint()
    var entry = DisplayConfig()

    if let data = try? Data(contentsOf: URL(fileURLWithPath: LEGACY_WIN_CONFIG_PATH)) {
        if let dict = try? JSONDecoder().decode([String: WindowInfo].self, from: data) {
            let infos = Array(dict.values)
            entry.windows = infos
            entry.window = infos.first
        } else if let win = try? JSONDecoder().decode(WindowInfo.self, from: data) {
            entry.window = win
            entry.windows = [win]
        }
    }

    if let data = try? Data(contentsOf: URL(fileURLWithPath: LEGACY_LAYOUT_CONFIG_PATH)),
       let layout = try? JSONDecoder().decode(LayoutConfig.self, from: data) {
        entry.layout = layout
    }

    store[fp] = entry

    if !store.isEmpty {
        _ = saveConfigStore(store)
        fputs("Migrated legacy configs to \(CONFIG_PATH)\n", stderr)
    }

    return store
}

func pruneOldFingerprintKeys(_ store: [String: DisplayConfig]) -> [String: DisplayConfig] {
    let hasNewKey = store.keys.contains { $0.contains(" - ") || $0.range(of: "^[0-9A-F]{8}\\.\\.\\.", options: .regularExpression) != nil }
    if !hasNewKey { return store }
    return store.filter { $0.key.contains(" - ") || $0.key.range(of: "^[0-9A-F]{8}\\.\\.\\.", options: .regularExpression) != nil }
}

func findRulesFile() -> String? {
    let fm = FileManager.default
    let exeURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let exeDir = exeURL.deletingLastPathComponent()
    var candidates: [String] = [
        exeDir.path,
        exeDir.deletingLastPathComponent().path,
    ]
    if let gr = gitRoot() { candidates.append(gr) }
    candidates.append(fm.currentDirectoryPath)
    for c in candidates {
        let full = c + "/\(MONITOR_RULES_FILENAME)"
        if fm.fileExists(atPath: full) { return full }
    }
    return nil
}

func loadConfigRules() -> [MonitorRule] {
    if let path = findRulesFile(),
       let data = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8),
       let rules = try? YAMLDecoder().decode([MonitorRule].self, from: data),
       !rules.isEmpty {
        return rules
    }
    return builtinMonitorPresets
}

func saveConfigStore(_ store: [String: DisplayConfig]) -> Bool {
    let encoder = YAMLEncoder()

    guard let yaml = try? encoder.encode(store) else { return false }

    let dir = (CONFIG_PATH as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try yaml.write(to: URL(fileURLWithPath: CONFIG_PATH), atomically: true, encoding: .utf8)
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

