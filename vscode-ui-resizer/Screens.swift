import Cocoa
import Foundation

// MARK: - Screen Description

func describeScreen(containing point: CGPoint, size: CGSize? = nil) -> (frame: String, relativeX: Double, relativeY: Double, onScreen: Bool) {
    let screens = NSScreen.screens
    // 1. Exact top-left hit (existing behavior).
    for screen in screens {
        if screen.frame.contains(point) {
            let f = screen.frame
            return (screenFrameString(f), Double(point.x - f.origin.x), Double(point.y - f.origin.y), true)
        }
    }
    // 2. Largest window-rect overlap (handles top-left just outside, e.g. menu-bar
    // gap or bottom-edge-exclusive misses like Ghostty/Tailscale/Gemini).
    if let size, size.width > 0, size.height > 0 {
        let rect = CGRect(origin: point, size: size)
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let inter = screen.frame.intersection(rect)
            if !inter.isNull {
                let area = inter.width * inter.height
                if area > bestArea {
                    bestArea = area
                    best = screen
                }
            }
        }
        if let hit = best, bestArea > 0 {
            let f = hit.frame
            return (screenFrameString(f), Double(point.x - f.origin.x), Double(point.y - f.origin.y), true)
        }
    }
    // 3. Nearest screen by edge distance (covers zero-overlap edge cases, e.g.
    // window top exactly on a screen's exclusive max edge). Never return
    // "off-screen" while displays exist, so restore has a frame to match.
    if let nearest = screens.min(by: {
        edgeDistance(point, $0.frame) < edgeDistance(point, $1.frame)
    }) {
        let f = nearest.frame
        return (screenFrameString(f), Double(point.x - f.origin.x), Double(point.y - f.origin.y), false)
    }
    return ("off-screen", Double(point.x), Double(point.y), false)
}

func edgeDistance(_ p: CGPoint, _ r: NSRect) -> CGFloat {
    let dx = max(r.minX - p.x, 0, p.x - r.maxX)
    let dy = max(r.minY - p.y, 0, p.y - r.maxY)
    return dx * dx + dy * dy
}

// MARK: - Display Fingerprint (v2: points + scale, v1 legacy alias)

func displayFingerprint() -> String {
    struct DisplayLine {
        let x: Int
        let y: Int
        let wPt: Int
        let hPt: Int
        let scale: Double
        let rot: Int
        let name: String
        let isMain: Bool
    }

    let screens = NSScreen.screens
    var displays: [DisplayLine] = []

    for (idx, screen) in screens.enumerated() {
        let frame = screen.frame
        let name = screen.localizedName.isEmpty ? "Display" : screen.localizedName
        let isMain = (idx == 0)

        var rotation = 0
        var scale: Double = Double(screen.backingScaleFactor)
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            rotation = Int(CGDisplayRotation(screenNumber))
            if let mode = CGDisplayCopyDisplayMode(screenNumber), frame.width > 0 {
                scale = Double(mode.pixelWidth) / Double(frame.width)
            }
        }
        if scale <= 0 { scale = 1 }

        displays.append(DisplayLine(
            x: Int(frame.origin.x),
            y: Int(frame.origin.y),
            wPt: Int(frame.width),
            hPt: Int(frame.height),
            scale: scale,
            rot: rotation,
            name: name,
            isMain: isMain
        ))
    }

    displays.sort { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }

    return displays.map { d in
        let xStr = String(format: "%5d", d.x)
        let yStr = String(format: "%3d", d.y)
        let marker = d.isMain ? " *" : ""
        let scaleStr = String(format: "%.2f", d.scale)
        return "[\(xStr),\(yStr)] \(d.wPt)x\(d.hPt)pt @\(scaleStr)x \(d.rot)°  \(d.name)\(marker)"
    }.joined(separator: "\n")
}

func legacyDisplayFingerprint() -> String {
    // v1 format (points origin + pixel size, no scale) — read-only alias for migration.
    struct DisplayLine {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
        let rot: Int
        let name: String
        let isMain: Bool
    }
    let screens = NSScreen.screens
    var displays: [DisplayLine] = []
    for (idx, screen) in screens.enumerated() {
        let frame = screen.frame
        let name = screen.localizedName.isEmpty ? "Display" : screen.localizedName
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
        if rotation == 90 || rotation == 270 { swap(&physW, &physH) }
        displays.append(DisplayLine(x: Int(frame.origin.x), y: Int(frame.origin.y), w: physW, h: physH, rot: rotation, name: name, isMain: idx == 0))
    }
    displays.sort { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
    return displays.map { d in
        let xStr = String(format: "%5d", d.x)
        let yStr = String(format: "%3d", d.y)
        let marker = d.isMain ? "*" : " "
        return "[\(xStr),\(yStr)] \(d.w)x\(d.h) \(d.rot)°  \(d.name)\(marker)"
    }.joined(separator: "\n")
}

func lookupDisplayEntry(in store: [String: DisplayConfig]) -> (key: String, entry: DisplayConfig, source: String)? {
    let fp = displayFingerprint()
    if let e = store[fp] { return (fp, e, "matched") }
    let legacy = legacyDisplayFingerprint()
    if legacy != fp, let e = store[legacy] {
        fputs("Using legacy display fingerprint; re-save to migrate to v2.\n", stderr)
        return (legacy, e, "legacy")
    }
    if store.count == 1, let (k, v) = store.first {
        fputs("No saved config for current display layout; using the only available saved config.\n", stderr)
        print("\nCurrent layout:\n\(fp)\n")
        return (k, v, "single-fallback")
    }
    return nil
}

