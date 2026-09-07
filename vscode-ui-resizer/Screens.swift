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

// MARK: - Display Fingerprint (name-based, stable across UUID rotation)

func displayFingerprint() -> String {
    let names = NSScreen.screens
        .map { $0.localizedName.isEmpty ? "Display" : $0.localizedName }
        .sorted()
    return names.joined(separator: "\n")
}

func lookupDisplayEntry(in store: [String: DisplayConfig]) -> (key: String, entry: DisplayConfig, source: String)? {
    let fp = displayFingerprint()
    if let e = store[fp] { return (fp, e, "matched") }
    if store.count == 1, let (k, v) = store.first {
        fputs("No saved config for current display layout; using the only available saved config.\n", stderr)
        print("\nCurrent layout:\n\(fp)\n")
        return (k, v, "single-fallback")
    }
    return nil
}

