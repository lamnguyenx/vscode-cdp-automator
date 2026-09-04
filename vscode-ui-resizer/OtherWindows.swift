import Cocoa
import Foundation

// MARK: - Save Other Windows

func cmdSaveWindows() -> Int32 {
    guard requireAXTrust() else { return EXIT_PRECONDITION }
    let apps = findOtherApps()
    guard !apps.isEmpty else {
        fputs("Skipping save-windows: no other GUI app windows found.\n", stderr)
        return EXIT_PRECONDITION
    }

    var byBundle: [String: [WindowInfo]] = [:]
    var order: [String] = []

    for (bundleID, _, _, windows) in apps {
        var infos: [WindowInfo] = []
        for win in windows {
            if axGetBool(win, "AXMinimized") == true { continue }
            guard let pos = axGetPoint(win, "AXPosition"),
                  let size = axGetSize(win, "AXSize")
            else { continue }

            let title = axGetString(win, "AXTitle") ?? ""
            let (screenFrame, relX, relY, _) = describeScreen(containing: pos)
            let label = title.isEmpty ? bundleID : title

            infos.append(WindowInfo(
                title: title,
                pid: 0,
                x: Double(pos.x),
                y: Double(pos.y),
                width: Double(size.width),
                height: Double(size.height),
                screenFrame: screenFrame,
                screenRelativeX: relX,
                screenRelativeY: relY,
                label: label
            ))
        }
        if !infos.isEmpty {
            if byBundle[bundleID] == nil { order.append(bundleID) }
            byBundle[bundleID] = infos
        }
    }

    guard !byBundle.isEmpty else {
        fputs("Skipping save-windows: no positional windows found (all minimized or no geometry).\n", stderr)
        return EXIT_PRECONDITION
    }

    let fingerPrint = displayFingerprint()
    var store = loadConfigStore()
    var entry = store[fingerPrint] ?? DisplayConfig(window: nil, windows: nil, layout: nil)
    entry.otherWindows = byBundle
    store[fingerPrint] = entry
    guard saveConfigStore(store) else { return EXIT_FAILED }

    let totalWindows = byBundle.values.reduce(0) { $0 + $1.count }
    print("Saved \(totalWindows) window(s) across \(byBundle.count) app(s) → \(CONFIG_PATH)\n")
    for bid in order {
        let count = byBundle[bid]?.count ?? 0
        print("  \(bid.padding(toLength: 36, withPad: " ", startingAt: 0)) \(count) window(s)")
    }
    print("\nDisplay layout:")
    print(fingerPrint)
    return EXIT_OK
}

// MARK: - Restore Other Windows

func cmdRestoreWindows() -> Int32 {
    guard requireAXTrust() else { return EXIT_PRECONDITION }
    let store = loadConfigStore()
    guard !store.isEmpty else {
        fputs("Skipping restore-windows: no saved data at \(CONFIG_PATH).\n", stderr)
        return EXIT_PRECONDITION
    }

    guard let (_, entry, _) = lookupDisplayEntry(in: store),
          let saved = entry.otherWindows else {
        fputs("Skipping restore-windows: no saved other-windows for current display layout.\n", stderr)
        return EXIT_PRECONDITION
    }

    guard !saved.isEmpty else {
        fputs("Skipping restore-windows: saved config has no other-windows.\n", stderr)
        return EXIT_PRECONDITION
    }

    let runningByBundle: [String: NSRunningApplication] = {
        var m: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier { m[bid] = app }
        }
        return m
    }()

    let bundleOrder = saved.keys.sorted()
    print("Restoring \(saved.count) app(s):\n")

    var anyFailed = false
    for (idx, bundleID) in bundleOrder.enumerated() {
        let savedWindows = saved[bundleID] ?? []
        guard let app = runningByBundle[bundleID] else {
            print("[\(idx+1)/\(bundleOrder.count)] \(bundleID)  ⚠ not running, skipped")
            anyFailed = true
            continue
        }

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        applyAXTimeout(appEl)
        guard let currentWindows = axGetArray(appEl, "AXWindows"), !currentWindows.isEmpty else {
            print("[\(idx+1)/\(bundleOrder.count)] \(bundleID)  ⚠ no open windows, skipped")
            anyFailed = true
            continue
        }

        print("[\(idx+1)/\(bundleOrder.count)] \(bundleID)  (\(savedWindows.count) saved, \(currentWindows.count) open)")

        // Title-first matching: build live title list, match saved titles, fallback positional.
        let liveTitles: [String] = currentWindows.map { axGetString($0, "AXTitle") ?? "" }
        var used = Set<Int>()
        var pairs: [(win: AXUIElement, target: WindowInfo, kind: String)] = []
        for target in savedWindows {
            var chosen: Int?
            var kind = "positional-fallback"
            let candidates = liveTitles.enumerated().filter { !used.contains($0.offset) }
            if !target.title.isEmpty,
               let hit = candidates.first(where: { $0.element == target.title }) {
                chosen = hit.offset
                kind = "title"
            } else if !target.label.isEmpty && target.label != bundleID,
                      let hit = candidates.first(where: { $0.element == target.label }) {
                chosen = hit.offset
                kind = "title"
            }
            if chosen == nil {
                if let free = candidates.first?.offset { chosen = free }
            }
            if let c = chosen {
                used.insert(c)
                pairs.append((currentWindows[c], target, kind))
            }
        }
        _ = liveTitles
        for (i, pair) in pairs.enumerated() {
            let (pt, src) = resolveAndClamp(from: pair.target)
            print("  [\(i+1)/\(savedWindows.count)] match=\(pair.kind) source=\(src.rawValue) \"\(pair.target.title)\"")
            let ok = applyWindowGeometry(pair.win, target: pair.target, globalPos: pt)
            if !ok { anyFailed = true }
        }
        if currentWindows.count > savedWindows.count {
            print("  \(currentWindows.count - savedWindows.count) extra open window(s) left in place")
        } else if savedWindows.count > pairs.count {
            print("  \(savedWindows.count - pairs.count) extra saved window(s) have no current match")
        }
        print("")
    }

    return anyFailed ? EXIT_FAILED : EXIT_OK
}

