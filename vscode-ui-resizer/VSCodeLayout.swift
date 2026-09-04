import Cocoa
import Foundation

// MARK: - Restore Eligibility

struct Eligibility {
    let sidebarOnLeft: Bool
    let panelOnRight: Bool
    let maximized: Bool
}

func readEligibility(_ task: URLSessionWebSocketTask) -> Eligibility? {
    let raw = evalJS(task, """
    (() => {
        const sb = document.querySelector('.part.sidebar');
        const pn = document.querySelector('.part.panel');
        const ed = document.querySelector('.part.editor');
        const sbOnLeft = !!sb && sb.classList.contains('left') && sb.getBoundingClientRect().width > 5;
        const pnOnRight = !!pn && pn.classList.contains('right') && pn.getBoundingClientRect().width > 5;
        let maximized = false;
        if (pn && ed) {
            const pb = pn.getBoundingClientRect();
            const eb = ed.getBoundingClientRect();
            if ((eb.width < 5 && pb.width > 50) || (eb.height < 5 && pb.height > 50)) maximized = true;
            const btn = pn.querySelector('.actions-container .action-label.codicon-panel-maximize');
            if (btn && btn.classList.contains('checked')) maximized = true;
        }
        return JSON.stringify({ sbOnLeft, pnOnRight, maximized });
    })()
    """)
    guard let data = raw.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sb = dict["sbOnLeft"] as? Bool,
          let pn = dict["pnOnRight"] as? Bool,
          let mx = dict["maximized"] as? Bool
    else { return nil }
    return Eligibility(sidebarOnLeft: sb, panelOnRight: pn, maximized: mx)
}

func normalizedTitle(_ title: String) -> String {
    // Longest suffixes first so " — Visual Studio Code - Insiders" is not
    // partially stripped by the bare " — Visual Studio Code" entry.
    let suffixes = [
        " — Visual Studio Code - Exploration",
        " — Visual Studio Code - Insiders",
        " — Visual Studio Code - OSS",
        " — Visual Studio Code",
        " — VSCodium",
    ]
    var t = title
    for suffix in suffixes {
        if t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
            break
        }
    }
    // Fallback for any remaining embedded occurrence (older titles).
    for suffix in suffixes {
        t = t.replacingOccurrences(of: suffix, with: "")
    }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Zoom Helpers

func zoomLevelFromFactor(_ factor: Double) -> Double {
    return log(factor) / log(1.2)
}

func zoomLevelFromPercent(_ percent: Double) -> Double {
    return log(percent / 100.0) / log(1.2)
}

func roundToZoomGrid(_ percent: Double) -> Double {
    return (percent / 5.0).rounded() * 5.0
}

func readZoomFactor(_ task: URLSessionWebSocketTask) -> Double? {
    let raw = evalJS(task, """
    (() => {
        const el = document.querySelector('.part.titlebar');
        if (!el) return 'null';
        return el.style.getPropertyValue('--zoom-factor') || 'null';
    })()
    """)
    return Double(raw)
}

func verifyZoomLevel(_ task: URLSessionWebSocketTask, targetLevel: Double) -> Bool {
    guard let factor = readZoomFactor(task) else { return false }
    return abs(factor - pow(1.2, targetLevel)) < 0.01
}

func stripJSONComments(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    var i = text.startIndex
    var inString = false
    var escaped = false
    while i < text.endIndex {
        let c = text[i]
        if inString {
            out.append(c)
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { inString = false }
            i = text.index(after: i)
            continue
        }
        if c == "\"" { inString = true; out.append(c); i = text.index(after: i); continue }
        if c == "/" {
            let n = text.index(after: i)
            if n < text.endIndex {
                let d = text[n]
                if d == "/" {
                    // line comment: skip to end of line, keep newline
                    var j = text.index(after: n)
                    while j < text.endIndex && text[j] != "\n" { j = text.index(after: j) }
                    i = j
                    continue
                } else if d == "*" {
                    var j = text.index(after: n)
                    var closed = false
                    while j < text.endIndex {
                        if text[j] == "*" {
                            let k = text.index(after: j)
                            if k < text.endIndex && text[k] == "/" {
                                j = text.index(after: k)
                                closed = true
                                break
                            }
                        }
                        j = text.index(after: j)
                    }
                    if !closed { break }
                    out.append(" ")
                    i = j
                    continue
                }
            }
        }
        out.append(c)
        i = text.index(after: i)
    }
    return out
}

func writeZoomLevelToUserSettings(_ level: Double) -> Bool {
    let value = String(format: "%.17g", level)
    let settingsURL = URL(fileURLWithPath: USER_SETTINGS_PATH)
    let fm = FileManager.default

    guard let origData = try? Data(contentsOf: settingsURL),
          var text = String(data: origData, encoding: .utf8) else {
        fputs("Cannot read \(USER_SETTINGS_PATH)\n", stderr)
        return false
    }

    // Backup first; never write without a recoverable copy.
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let backupURL = URL(fileURLWithPath: USER_SETTINGS_PATH + ".bak-\(stamp)")
    do {
        try fm.copyItem(at: settingsURL, to: backupURL)
        if verboseLogging { fputs("Backed up settings to \(backupURL.path)\n", stderr) }
    } catch {
        fputs("Cannot back up \(USER_SETTINGS_PATH): \(error); aborting zoom write.\n", stderr)
        return false
    }

    // Validate parseability (JSONC-tolerant) before mutating.
    let stripped = stripJSONComments(text)
    guard (try? JSONSerialization.jsonObject(with: Data(stripped.utf8))) is [String: Any] else {
        fputs("settings.json does not parse (even after stripping comments); aborting, backup at \(backupURL.path).\n", stderr)
        return false
    }

    let pattern = "\"\(ZOOM_LEVEL_KEY)\"\\s*:\\s*[+-]?[0-9]*\\.?[0-9]+([eE][+-]?[0-9]+)?"
    if let range = text.range(of: pattern, options: .regularExpression) {
        text.replaceSubrange(range, with: "\"\(ZOOM_LEVEL_KEY)\": \(value)")
    } else if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
        // Insert after opening brace, preserving indentation style of first key if found.
        if let brace = text.firstIndex(of: "{") {
            let insertAt = text.index(after: brace)
            text.insert(contentsOf: "\n    \"\(ZOOM_LEVEL_KEY)\": \(value),", at: insertAt)
        } else {
            fputs("Unexpected settings file format (no '{'). Backup at \(backupURL.path).\n", stderr)
            return false
        }
    } else {
        fputs("Unexpected settings file format (no leading '{'). Backup at \(backupURL.path).\n", stderr)
        return false
    }

    // Re-validate after edit.
    let reStripped = stripJSONComments(text)
    guard let obj = try? JSONSerialization.jsonObject(with: Data(reStripped.utf8)) as? [String: Any],
          (obj[ZOOM_LEVEL_KEY] as? NSNumber) != nil else {
        fputs("Edited settings.json failed validation; restoring backup.\n", stderr)
        try? fm.removeItem(at: settingsURL)
        try? fm.copyItem(at: backupURL, to: settingsURL)
        return false
    }

    do {
        try text.write(to: settingsURL, atomically: true, encoding: .utf8)
        return true
    } catch {
        fputs("Failed to write \(USER_SETTINGS_PATH): \(error); backup at \(backupURL.path).\n", stderr)
        return false
    }
}

// MARK: - Save Window

func makeWindowInfo(title: String, pid: pid_t, pos: CGPoint, size: CGSize) -> WindowInfo {
    var label = normalizedTitle(title)
    if label.isEmpty { label = "untitled" }
    let (screenFrame, relX, relY, _) = describeScreen(containing: pos, size: size)
    return WindowInfo(
        title: title,
        pid: pid,
        x: Double(pos.x),
        y: Double(pos.y),
        width: Double(size.width),
        height: Double(size.height),
        screenFrame: screenFrame,
        screenRelativeX: relX,
        screenRelativeY: relY,
        label: label
    )
}

func cmdSaveWin() -> Int32 {
    guard requireAXTrust() else { return EXIT_PRECONDITION }
    let all = findVSCodeWindows()
    guard !all.isEmpty else {
        fputs("Skipping save-win: no VS Code window found.\n", stderr)
        return EXIT_PRECONDITION
    }

    // Build infos from live AX reads (preserves per-window geometry).
    var infos: [WindowInfo] = []
    for (win, _, title, pid) in all {
        guard let pos = axGetPoint(win, "AXPosition"),
              let size = axGetSize(win, "AXSize") else {
            fputs("Could not read position/size for \"\(title)\", skipping.\n", stderr)
            continue
        }
        infos.append(makeWindowInfo(title: title, pid: pid, pos: pos, size: size))
    }
    guard !infos.isEmpty else {
        fputs("Could not read window position/size.\n", stderr)
        return EXIT_FAILED
    }

    let fingerPrint = displayFingerprint()

    var store = loadConfigStore()
    var entry = store[fingerPrint] ?? DisplayConfig(window: nil, windows: nil, layout: nil)
    entry.windows = infos
    entry.window = infos.first
    store[fingerPrint] = entry

    guard saveConfigStore(store) else { return EXIT_FAILED }

    print("Saved \(infos.count) window(s) → \(CONFIG_PATH)")
    for info in infos {
        print("  \"\(info.label)\" pos=(\(Int(info.x)), \(Int(info.y)))  size=\(Int(info.width))x\(Int(info.height))  screen: \(info.screenFrame)")
    }
    print("")
    print("Display layout:")
    print(fingerPrint)
    return EXIT_OK
}

// MARK: - Restore Window

func cmdRestoreWin(port: Int) -> Int32 {
    guard requireAXTrust() else { return EXIT_PRECONDITION }
    let store = loadConfigStore()
    guard !store.isEmpty else {
        fputs("Skipping restore-win: no saved data at \(CONFIG_PATH).\n", stderr)
        return EXIT_PRECONDITION
    }

    guard let (_, entry, _) = lookupDisplayEntry(in: store) else {
        fputs("Skipping restore-win: no saved window for current display layout.\n", stderr)
        return EXIT_PRECONDITION
    }
    let savedList: [WindowInfo] = entry.windows ?? (entry.window.map { [$0] } ?? [])
    guard !savedList.isEmpty else {
        fputs("Skipping restore-win: saved entry has no windows.\n", stderr)
        return EXIT_PRECONDITION
    }

    let current = findVSCodeWindows()
    guard !current.isEmpty else {
        fputs("Skipping restore-win: no VS Code windows currently open.\n", stderr)
        return EXIT_PRECONDITION
    }

    var eligibilityByTitle: [String: Eligibility] = [:]
    if let targets = tryFetchTargets(port: port) {
        for t in targets {
            guard let wsUrl = t["webSocketDebuggerUrl"] as? String,
                  let title = t["title"] as? String,
                  let task = newWebSocket(wsUrl)
            else { continue }
            if let el = readEligibility(task) {
                eligibilityByTitle[normalizedTitle(title)] = el
            }
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    print("Applying to \(current.count) open window(s) from \(savedList.count) saved:\n")

    var anyFailed = false
    // Title-first matching; positional fallback among still-unmatched.
    var unmatchedSaved = savedList
    for i in 0..<current.count {
        let (win, _, title, _) = current[i]
        let norm = normalizedTitle(title)

        print("[\(i+1)] \"\(title)\"")

        if let el = eligibilityByTitle[norm] {
            if el.maximized {
                print("    skipped: panel is maximized (full-width)")
                continue
            }
            if !el.sidebarOnLeft {
                print("    skipped: primary sidebar not on the left")
                continue
            }
            if !el.panelOnRight {
                print("    skipped: panel not on the right")
                continue
            }
        }

        let target: WindowInfo
        let matchKind: String
        if let idx = unmatchedSaved.firstIndex(where: { normalizedTitle($0.title) == norm || $0.label == norm }) {
            target = unmatchedSaved.remove(at: idx)
            matchKind = "title"
        } else if savedList.count == 1, let only = savedList.first {
            target = only
            matchKind = "single"
        } else if !unmatchedSaved.isEmpty {
            target = unmatchedSaved.removeFirst()
            matchKind = "positional-fallback"
        } else {
            print("    skipped: no saved geometry left unmatched")
            continue
        }

        let (pt, src) = resolveAndClamp(from: target)
        if verboseLogging || src != .matched {
            print("    match=\(matchKind) source=\(src.rawValue) target: pos=(\(Int(pt.x)), \(Int(pt.y))) size=\(Int(target.width))x\(Int(target.height))")
        } else {
            print("    target: pos=(\(Int(pt.x)), \(Int(pt.y)))  size=\(Int(target.width))x\(Int(target.height))")
        }
        let ok = applyWindowGeometry(win, target: target, globalPos: pt)
        if !ok { anyFailed = true }
        print("")
    }
    return anyFailed ? EXIT_FAILED : EXIT_OK
}

// MARK: - Save Layout

func readLayoutFromTab(_ task: URLSessionWebSocketTask) -> LayoutConfig? {
    let raw = evalJS(task, """
    (() => {
        const r = {};
        ['sidebar', 'panel', 'editor', 'activitybar', 'auxiliarybar'].forEach(p => {
            const el = document.querySelector('.part.' + p);
            if (el) {
                const b = el.getBoundingClientRect();
                r[p] = { width: Math.round(b.width), height: Math.round(b.height) };
                if (p === 'panel') {
                    if (el.classList.contains('right')) r.panel_position = 'right';
                    else if (el.classList.contains('left')) r.panel_position = 'left';
                    else if (el.classList.contains('bottom')) r.panel_position = 'bottom';
                    else if (el.classList.contains('top')) r.panel_position = 'top';
                }
                if (p === 'sidebar') {
                    r.sidebar_position = el.classList.contains('right') ? 'right' : 'left';
                }
            }
        });
        const wb = document.querySelector('.monaco-workbench');
        if (wb) {
            const b = wb.getBoundingClientRect();
            r.workbench = { width: Math.round(b.width), height: Math.round(b.height) };
        }
        return JSON.stringify(r, null, 2);
    })()
    """)

    guard let rawData = raw.data(using: .utf8),
          let data = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any]
    else { return nil }

    func partSize(_ key: String) -> PartSize? {
        guard let p = data[key] as? [String: Any],
              let w = p["width"] as? Int,
              let h = p["height"] as? Int
        else { return nil }
        return PartSize(width: w, height: h)
    }

    var layout = LayoutConfig()
    layout.sidebar = partSize("sidebar")
    layout.panel = partSize("panel")
    layout.editor = partSize("editor")
    layout.activitybar = partSize("activitybar")
    layout.auxiliarybar = partSize("auxiliarybar")
    layout.workbench = partSize("workbench")
    layout.sidebar_position = data["sidebar_position"] as? String
    layout.panel_position = data["panel_position"] as? String

    if let factor = readZoomFactor(task) {
        let pct = roundToZoomGrid(factor * 100.0)
        layout.zoom_level = zoomLevelFromPercent(pct)
        layout.zoom_percent = Int(pct)
    }

    if layout.sidebar == nil && layout.panel == nil && layout.editor == nil {
        return nil
    }

    return layout
}

func cmdSaveLayout(port: Int) -> Int32 {
    guard let activeTitle = getFrontmostVSCodeTitle() else {
        fputs("Skipping save-layout: frontmost app is not VS Code.\n", stderr)
        return EXIT_PRECONDITION
    }

    guard let windows = tryFetchTargets(port: port), !windows.isEmpty else {
        fputs("Skipping save-layout: cannot reach VS Code CDP on port \(port).\n", stderr)
        return EXIT_PRECONDITION
    }

    guard let t = windows.first(where: { ($0["title"] as? String) == activeTitle })
            ?? windows.first,
          let wsUrl = t["webSocketDebuggerUrl"] as? String,
          let task = newWebSocket(wsUrl)
    else {
        fputs("Skipping save-layout: could not connect to a VS Code window.\n", stderr)
        return EXIT_PRECONDITION
    }
    defer { task.cancel(with: .normalClosure, reason: nil) }

    let title = (t["title"] as? String) ?? "unknown"
    print("Saving from: \(title)")

    guard let layout = readLayoutFromTab(task) else {
        fputs("Skipping save-layout: could not read layout from \(title) (workbench not ready?).\n", stderr)
        return EXIT_PRECONDITION
    }

    let fingerPrint = displayFingerprint()
    var store = loadConfigStore()
    var entry = store[fingerPrint] ?? DisplayConfig(window: nil, layout: nil)
    entry.layout = layout
    store[fingerPrint] = entry
    guard saveConfigStore(store) else { return EXIT_FAILED }

    let sidebar = layout.sidebar?.width ?? 0
    let panel = layout.panel?.width ?? 0
    let editor = layout.editor?.width ?? 0
    let activity = layout.activitybar?.width ?? 0
    let sbPos = layout.sidebar_position ?? "?"
    let pnPos = layout.panel_position ?? "?"

    print("\nSaved \"\(title)\" to \(CONFIG_PATH):")
    print("  sidebar:  \(sidebar)px (\(sbPos))")
    print("  panel:    \(panel)px (\(pnPos))")
    print("  editor:   \(editor)px")
    print("  activity: \(activity)px")
    if let zoom = layout.zoom_percent {
        print("  zoom:     \(zoom)%")
    }
    return EXIT_OK
}

// MARK: - Restore Layout

func readCurrent(_ task: URLSessionWebSocketTask) -> [String: Int] {
    let raw = evalJS(task, """
    (() => {
        const r = {};
        ['sidebar', 'panel', 'editor'].forEach(p => {
            const el = document.querySelector('.part.' + p);
            if (el) r[p] = Math.round(el.getBoundingClientRect().width);
        });
        return JSON.stringify(r);
    })()
    """)
    guard let data = raw.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
    else { return [:] }
    return dict
}

func readPanelPosition(_ task: URLSessionWebSocketTask) -> String {
    let raw = evalJS(task, """
    (() => {
        const el = document.querySelector('.part.panel');
        if (!el) return 'none';
        if (el.classList.contains('right')) return 'right';
        if (el.classList.contains('left')) return 'left';
        if (el.classList.contains('bottom')) return 'bottom';
        return 'other';
    })()
    """)
    return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
}

func solveSashMappingHorizontal(_ task: URLSessionWebSocketTask) -> [String: Int] {
    let raw = evalJS(task, """
    (() => {
        const all = document.querySelectorAll('.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical:not(.disabled)');
        const parts = ['sidebar', 'panel', 'editor', 'activitybar', 'auxiliarybar'];
        const rects = {};
        parts.forEach(p => {
            const el = document.querySelector('.part.' + p);
            if (el) rects[p] = el.getBoundingClientRect();
        });
        const results = [];
        all.forEach((sash, i) => {
            const b = sash.getBoundingClientRect();
            const cx = b.left + b.width / 2;
            let leftName = '?', rightName = '?';
            let bestL = Infinity, bestR = Infinity;
            for (const [name, r] of Object.entries(rects)) {
                if (r.width === 0 && r.height === 0) continue;
                const dL = cx - r.right;
                const dR = r.left - cx;
                if (dL >= -0.5 && dL < bestL) { bestL = dL; leftName = name; }
                if (dR >= -0.5 && dR < bestR) { bestR = dR; rightName = name; }
            }
            results.push({ idx: i, between: leftName + '|' + rightName, cx: Math.round(cx) });
        });
        return JSON.stringify(results);
    })()
    """)
    return parseSashMappingResult(raw)
}

func solveSashMappingVertical(_ task: URLSessionWebSocketTask) -> [String: Int] {
    let raw = evalJS(task, """
    (() => {
        const all = document.querySelectorAll('.monaco-grid-view .monaco-split-view2.vertical .sash-container .monaco-sash.horizontal:not(.disabled)');
        const parts = ['sidebar', 'panel', 'editor', 'activitybar', 'auxiliarybar'];
        const rects = {};
        parts.forEach(p => {
            const el = document.querySelector('.part.' + p);
            if (el) rects[p] = el.getBoundingClientRect();
        });
        const results = [];
        all.forEach((sash, i) => {
            const b = sash.getBoundingClientRect();
            const cy = b.top + b.height / 2;
            let aboveName = '?', belowName = '?';
            let bestA = Infinity, bestB = Infinity;
            for (const [name, r] of Object.entries(rects)) {
                if (r.width === 0 && r.height === 0) continue;
                const dA = cy - r.bottom;
                const dB = r.top - cy;
                if (dA >= -0.5 && dA < bestA) { bestA = dA; aboveName = name; }
                if (dB >= -0.5 && dB < bestB) { bestB = dB; belowName = name; }
            }
            results.push({ idx: i, between: aboveName + '|' + belowName, cy: Math.round(cy) });
        });
        return JSON.stringify(results);
    })()
    """)
    return parseSashMappingResult(raw)
}

func parseSashMappingResult(_ raw: String) -> [String: Int] {
    var smap: [String: Int] = [:]
    guard let data = raw.data(using: .utf8),
          let mapping = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return smap }
    for s in mapping {
        guard let btw = s["between"] as? String, let idx = s["idx"] as? Int else { continue }
        if btw == "sidebar|editor" || btw == "editor|sidebar" { smap["sidebar_editor"] = idx }
        else if btw == "editor|panel" || btw == "panel|editor" { smap["editor_panel"] = idx }
    }
    return smap
}

func dragSashHorizontal(_ task: URLSessionWebSocketTask, sashIdx: Int, dx: Int) {
    guard dx != 0 else { return }
    _ = evalJS(task, """
    (() => {
        const all = document.querySelectorAll('.monaco-grid-view .monaco-split-view2.horizontal .sash-container .monaco-sash.vertical:not(.disabled)');
        const sash = all[\(sashIdx)];
        if (!sash) return JSON.stringify({error:'no sash at \(sashIdx)', count: all.length});
        const b = sash.getBoundingClientRect();
        const cx = b.left + b.width / 2;
        const cy = b.top + b.height / 2;
        const w = document.defaultView;
        sash.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, clientX: cx, clientY: cy, button: 0}));
        w.dispatchEvent(new MouseEvent('mousemove',   {bubbles: true, clientX: cx + \(dx), clientY: cy, button: 0}));
        w.dispatchEvent(new MouseEvent('mouseup',     {bubbles: true, clientX: cx + \(dx), clientY: cy, button: 0}));
        return 'ok';
    })()
    """)
}

func dragSashVertical(_ task: URLSessionWebSocketTask, sashIdx: Int, dy: Int) {
    guard dy != 0 else { return }
    _ = evalJS(task, """
    (() => {
        const all = document.querySelectorAll('.monaco-grid-view .monaco-split-view2.vertical .sash-container .monaco-sash.horizontal:not(.disabled)');
        const sash = all[\(sashIdx)];
        if (!sash) return JSON.stringify({error:'no sash at \(sashIdx)', count: all.length});
        const b = sash.getBoundingClientRect();
        const cx = b.left + b.width / 2;
        const cy = b.top + b.height / 2;
        const w = document.defaultView;
        sash.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, clientX: cx, clientY: cy, button: 0}));
        w.dispatchEvent(new MouseEvent('mousemove',   {bubbles: true, clientX: cx, clientY: cy + \(dy), button: 0}));
        w.dispatchEvent(new MouseEvent('mouseup',     {bubbles: true, clientX: cx, clientY: cy + \(dy), button: 0}));
        return 'ok';
    })()
    """)
}

func elapsed(_ t0: Date) -> String {
    return String(format: "%.2fs", Date().timeIntervalSince(t0))
}

func nowStamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func stageLog(_ t0: Date, _ name: String) {
    print("\n[\(nowStamp()) +\(elapsed(t0))] === \(name) ===")
    fflush(stdout)
}

func waitForWorkbenchReady(_ task: URLSessionWebSocketTask, _ prefix: String) -> Bool {
    let t0 = Date()
    for i in 1...20 {
        let raw = evalJS(task, """
        (() => {
            const wb = document.querySelector('.monaco-workbench');
            if (!wb) return 'missing';
            const r = wb.getBoundingClientRect();
            if (r.width === 0 && r.height === 0) return 'zero';
            return 'ready';
        })()
        """)
        if raw == "ready" {
            print("\(prefix)  waitForWorkbenchReady: ready after \(elapsed(t0))")
            return true
        }
        if i == 1 || i % 5 == 0 {
            print("\(prefix)  waitForWorkbenchReady: not ready (\(raw)) after \(elapsed(t0)), waiting...")
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    print("\(prefix)  waitForWorkbenchReady: NEVER ready after \(elapsed(t0))")
    return false
}

func restoreLayoutWindow(wsUrl: String, tSidebar: Int, tPanel: Int, label: String, bringToFront: Bool = false) {
    let tStart = Date()
    let prefix = label.isEmpty ? "" : "[\(label)] "
    guard let task = newWebSocket(wsUrl) else { return }
    defer { task.cancel(with: .normalClosure, reason: nil) }
    print("\(prefix)  connect: \(elapsed(tStart))")

    if bringToFront {
        bringTabToFront(task)
        print("\(prefix)  bringToFront: \(elapsed(tStart))")
    }

    if !waitForWorkbenchReady(task, prefix) {
        print("\(prefix)workbench never became ready (lazy-loaded/suspended tab), skipping after \(elapsed(tStart))")
        return
    }

    let panelPos = readPanelPosition(task)
    print("\(prefix)  panelPos(\(panelPos)): \(elapsed(tStart))")

    if let el = readEligibility(task) {
        if el.maximized {
            print("\(prefix)panel is maximized (full-width) — skipping this window after \(elapsed(tStart))")
            return
        }
        if !el.sidebarOnLeft {
            print("\(prefix)primary sidebar not on the left — skipping this window after \(elapsed(tStart))")
            return
        }
        if !el.panelOnRight {
            print("\(prefix)panel not on the right — skipping this window after \(elapsed(tStart))")
            return
        }
    }
    print("\(prefix)  eligibility: \(elapsed(tStart))")

    let isBottom = panelPos == "bottom"
    let smap = isBottom ? solveSashMappingVertical(task) : solveSashMappingHorizontal(task)
    print("\(prefix)  sash mapping: \(elapsed(tStart))")
    guard let seIdx = smap["sidebar_editor"], let epIdx = smap["editor_panel"] else {
        print("\(prefix)sash mapping incomplete (sidebar_editor=\(smap["sidebar_editor"].map(String.init) ?? "nil") editor_panel=\(smap["editor_panel"].map(String.init) ?? "nil")) — expand collapsed panels/sidebars first, then re-run. Aborting instead of guessing sash indices.")
        return
    }

    if isBottom {
        print("\(prefix)(panel at bottom — using vertical sashes)")
    }

    let maxRetries = 5
    var ok = false
    var consecutiveZeros = 0
    for attempt in 1...maxRetries {
        let cur = readCurrent(task)
        let sb = cur["sidebar"] ?? 0
        var pn = cur["panel"] ?? 0
        let ed = cur["editor"] ?? 0

        if sb == 0 && pn == 0 && ed == 0 {
            consecutiveZeros += 1
            if consecutiveZeros >= 3 {
                print("\(prefix)workbench not ready (zero values), skipping")
                return
            }
            print("\(prefix)workbench not ready (zero values), retrying...")
            Thread.sleep(forTimeInterval: 0.5)
            continue
        }
        consecutiveZeros = 0

        if attempt == 1 {
            print("\(prefix)current: sb=\(sb) panel=\(pn) editor=\(ed) (after \(elapsed(tStart)))")
        }

        if !isBottom && pn == 0 && tPanel > 0 && smap["editor_panel"] == nil {
            print("\(prefix)panel is collapsed (width=0) and no editor|panel sash found — expand panel first, then re-run")
            return
        }
        if isBottom && pn == 0 && tPanel > 0 && smap["editor_panel"] == nil {
            print("\(prefix)panel is collapsed (height=0) and no editor|panel sash found — expand panel first, then re-run")
            return
        }

        let dx_p: Int
        let dx_s: Int

        if isBottom {
            let rawH = evalJS(task, """
            (() => {
                const el = document.querySelector('.part.panel');
                if (!el) return 0;
                return Math.round(el.getBoundingClientRect().height);
            })()
            """)
            let ph = Int(rawH) ?? 0
            pn = ph
            dx_p = pn - tPanel
            dx_s = tSidebar - sb
        } else {
            dx_p = pn - tPanel
            dx_s = tSidebar - sb
        }

        let tDrag = Date()
        if dx_p != 0 {
            let sign = dx_p > 0 ? "+" : ""
            print("\(prefix) dragging panel sash by \(sign)\(dx_p)")
            if isBottom {
                dragSashVertical(task, sashIdx: epIdx, dy: dx_p)
            } else {
                dragSashHorizontal(task, sashIdx: epIdx, dx: dx_p)
            }
        }

        if dx_s != 0 {
            let sign = dx_s > 0 ? "+" : ""
            print("\(prefix) dragging sidebar sash by \(sign)\(dx_s)")
            dragSashHorizontal(task, sashIdx: seIdx, dx: dx_s)
        }
        print("\(prefix)  drag sent: \(elapsed(tDrag))")

        if dx_p == 0 && dx_s == 0 {
            print("\(prefix)already at target — OK")
            ok = true
            break
        }

        if attempt == 1 {
            Thread.sleep(forTimeInterval: 0.3)
        } else {
            Thread.sleep(forTimeInterval: 0.6)
        }
        print("\(prefix)  settled: \(elapsed(tDrag))")

        let final = readCurrent(task)
        let fsb = final["sidebar"] ?? 0
        var fpn = final["panel"] ?? 0
        let fed = final["editor"] ?? 0

        if isBottom {
            let rawH = evalJS(task, """
            (() => {
                const el = document.querySelector('.part.panel');
                if (!el) return 0;
                return Math.round(el.getBoundingClientRect().height);
            })()
            """)
            fpn = Int(rawH) ?? 0
        }

        print("\(prefix)  verify: \(elapsed(tDrag))")

        ok = fsb == tSidebar && fpn == tPanel
        let status = ok ? "OK" : "RETRY"
        let dimLabel = isBottom ? "h" : ""
        print("\(prefix)final:   sb=\(fsb) panel\(dimLabel)=\(fpn) editor\(dimLabel)=\(fed)  [\(status)]")

        if ok { break }
    }
    if !ok {
        print("\(prefix)FAILED after \(maxRetries) attempts")
    }
    print("\(prefix)done in \(elapsed(tStart))")
}

func cmdRestoreLayout(port: Int) -> Int32 {
    let store = loadConfigStore()
    guard !store.isEmpty else {
        fputs("Skipping restore-layout: no saved data at \(CONFIG_PATH).\n", stderr)
        return EXIT_PRECONDITION
    }

    let fingerPrint = displayFingerprint()

    let layout: LayoutConfig
    if let match = store[fingerPrint]?.layout {
        layout = match
    } else if store.count == 1, let only = store.values.first?.layout {
        fputs("No saved layout for current display layout; using the only available saved config.\n", stderr)
        print("\nCurrent layout:\n\(fingerPrint)\n")
        layout = only
    } else {
        fputs("Skipping restore-layout: no saved layout for current display layout.\n", stderr)
        return EXIT_PRECONDITION
    }

    let tSidebar = layout.sidebar?.width ?? 0
    let savedPanelPos = layout.panel_position ?? ""
    let tPanel: Int
    let panelDimLabel: String
    if savedPanelPos == "bottom" || savedPanelPos == "top" {
        tPanel = layout.panel?.height ?? 0
        panelDimLabel = "h"
    } else {
        tPanel = layout.panel?.width ?? 0
        panelDimLabel = ""
    }
    let tZoomLevel = layout.zoom_level
    let tZoomPercent = layout.zoom_percent

    guard let windows = tryFetchTargets(port: port), !windows.isEmpty else {
        fputs("Skipping restore-layout: cannot reach VS Code CDP on port \(port).\n", stderr)
        return EXIT_PRECONDITION
    }
    print("Restoring \(windows.count) window(s) to sidebar=\(tSidebar)px  panel=\(tPanel)px\(panelDimLabel)\(tZoomPercent.map { "  zoom=\($0)%" } ?? "")\n")

    if let zl = tZoomLevel {
        let roundedPct = roundToZoomGrid(pow(1.2, zl) * 100.0)
        let gridLevel = zoomLevelFromPercent(roundedPct)
        print("Applying zoom \(Int(roundedPct))% (level \(String(format: "%.4f", gridLevel))) via \(USER_SETTINGS_PATH)")
        if writeZoomLevelToUserSettings(gridLevel) {
            Thread.sleep(forTimeInterval: 0.3)
            let zoomQueue = DispatchQueue.global(qos: .userInitiated)
            let zoomGroup = DispatchGroup()
            let zoomLock = NSLock()
            let zoomBox = Box<[Int: Bool]>([:])
            for (idx, t) in windows.enumerated() {
                guard let wsUrl = t["webSocketDebuggerUrl"] as? String else { continue }
                zoomGroup.enter()
                zoomQueue.async {
                    defer { zoomGroup.leave() }
                    guard let task = newWebSocket(wsUrl) else { return }
                    defer { task.cancel(with: .normalClosure, reason: nil) }
                    var ok = false
                    for _ in 1...3 {
                        if verifyZoomLevel(task, targetLevel: gridLevel) {
                            ok = true
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                    zoomLock.lock()
                    zoomBox.value[idx] = ok
                    zoomLock.unlock()
                }
            }
            zoomGroup.wait()
            for idx in windows.indices {
                print("[\(idx)] zoom: \((zoomBox.value[idx] ?? false) ? "OK" : "FAILED after 3 attempts")")
            }
        }
        print("")
    }

    for (idx, t) in windows.enumerated() {
        guard let wsUrl = t["webSocketDebuggerUrl"] as? String else { continue }
        let title = (t["title"] as? String) ?? "unknown"
        print("[\(idx)] \(title)")
        restoreLayoutWindow(wsUrl: wsUrl, tSidebar: tSidebar, tPanel: tPanel, label: "\(idx)")
        print("")
    }
    return EXIT_OK
}

// MARK: - Save Code-Server Layout

func cmdSaveCodeServerLayout(port: Int) -> Int32 {
    guard let targets = tryFetchCodeServerTargets(port: port), !targets.isEmpty else {
        fputs("Skipping save-codeserver-layout: no code-server tabs found on CDP port \(port).\n", stderr)
        return EXIT_PRECONDITION
    }

    let titles = targets.map { ($0["title"] as? String) ?? "unknown" }

    // Prefer the focused tab; use a single Vivaldi window.html connection with chrome.tabs
    var chosen: [String: Any]?
    if let winTargets = tryFetchVivaldiWindowTargets(port: port),
       let t = winTargets.first,
       let wsUrl = t["webSocketDebuggerUrl"] as? String,
       let task = newWebSocket(wsUrl) {
        let raw = evalJS(task, """
        new Promise(r => chrome.tabs.query({active:true}, t => {
            const cur = t.find(x => (x.url||'').includes('?folder=') || (x.url||'').includes('?workspace='));
            const all = [];
            chrome.tabs.query({}, a => {
                all.push(...a.filter(x => (x.url||'').includes('?folder=') || (x.url||'').includes('?workspace=')));
                r(JSON.stringify({ cur: cur?cur.id:null, ids: all.map(x=>x.id) }));
            });
        }))
        """)
        if let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let curIdReal = obj["cur"] as? Int, curIdReal != -1 {
                let curUrlRaw = evalJS(task, "new Promise(r => chrome.tabs.get(\(curIdReal), t => r(JSON.stringify(t.url||''))))")
                if let curUrlData = curUrlRaw.data(using: .utf8),
                   let url = try? JSONSerialization.jsonObject(with: curUrlData) as? String {
                    chosen = targets.first(where: { (($0["url"] as? String) ?? "") == url })
                }
            }
            task.cancel(with: .normalClosure, reason: nil)
        } else {
            task.cancel(with: .normalClosure, reason: nil)
        }
    }
    if chosen == nil {
        chosen = targets.first
    }

    guard chosen != nil else {
        fputs("Could not determine the active code-server tab.\n", stderr)
        fputs("Open tabs:\n", stderr)
        for title in titles { fputs("  - \(title)\n", stderr) }
        return EXIT_PRECONDITION
    }

    guard let chosen2 = chosen, let wsUrl = chosen2["webSocketDebuggerUrl"] as? String,
          let task = newWebSocket(wsUrl)
    else {
        fputs("Could not connect to the active code-server tab.\n", stderr)
        return EXIT_PRECONDITION
    }
    defer { task.cancel(with: .normalClosure, reason: nil) }

    let title = (chosen2["title"] as? String) ?? "unknown"
    print("Saving from (code-server): \(title)")

    guard let layout = readLayoutFromTab(task) else {
        fputs("Could not read code-server layout from \(title).\n", stderr)
        return EXIT_PRECONDITION
    }

    let fingerPrint = displayFingerprint()
    var store = loadConfigStore()
    var entry = store[fingerPrint] ?? DisplayConfig(window: nil, layout: nil)
    entry.codeServerLayout = layout
    store[fingerPrint] = entry
    guard saveConfigStore(store) else { return EXIT_FAILED }

    let sidebar = layout.sidebar?.width ?? 0
    let panel = layout.panel?.width ?? 0
    let editor = layout.editor?.width ?? 0
    let sbPos = layout.sidebar_position ?? "?"
    let pnPos = layout.panel_position ?? "?"

    print("\nSaved code-server \"\(title)\" to \(CONFIG_PATH):")
    print("  sidebar:  \(sidebar)px (\(sbPos))")
    print("  panel:    \(panel)px (\(pnPos))")
    print("  editor:   \(editor)px")
    return EXIT_OK
}

// MARK: - Restore Code-Server Layout

func cmdRestoreCodeServerLayout(port: Int) -> Int32 {
    let store = loadConfigStore()
    guard !store.isEmpty else {
        fputs("Skipping restore-codeserver-layout: no saved data at \(CONFIG_PATH).\n", stderr)
        return EXIT_PRECONDITION
    }

    let fingerPrint = displayFingerprint()

    let layout: LayoutConfig
    if let match = store[fingerPrint]?.codeServerLayout {
        layout = match
    } else if store.count == 1, let only = store.values.first?.codeServerLayout {
        fputs("No saved code-server layout for current display layout; using the only available saved config.\n", stderr)
        print("\nCurrent layout:\n\(fingerPrint)\n")
        layout = only
    } else {
        fputs("Skipping restore-codeserver-layout: no saved code-server layout for current display layout.\n", stderr)
        return EXIT_PRECONDITION
    }

    let tSidebar = layout.sidebar?.width ?? 0
    let savedPanelPos = layout.panel_position ?? ""
    let tPanel: Int
    if savedPanelPos == "bottom" || savedPanelPos == "top" {
        tPanel = layout.panel?.height ?? 0
    } else {
        tPanel = layout.panel?.width ?? 0
    }

    guard let targets = tryFetchCodeServerTargets(port: port), !targets.isEmpty else {
        fputs("Skipping restore-codeserver-layout: no code-server tabs found on CDP port \(port).\n", stderr)
        return EXIT_PRECONDITION
    }
    print("Restoring \(targets.count) code-server tab(s) to sidebar=\(tSidebar)px  panel=\(tPanel)px\n")
    let tCmd = Date()

    let activeBox = Box<String?>(nil)
    let activeLock = NSLock()
    let activeGroup = DispatchGroup()
    let activeQueue = DispatchQueue.global(qos: .userInitiated)
    for t in targets {
        guard let wsUrl = t["webSocketDebuggerUrl"] as? String else { continue }
        activeGroup.enter()
        activeQueue.async {
            defer { activeGroup.leave() }
            guard let task = newWebSocket(wsUrl) else { return }
            let active = isActiveTab(task)
            task.cancel(with: .normalClosure, reason: nil)
            if active {
                activeLock.lock()
                if activeBox.value == nil { activeBox.value = wsUrl }
                activeLock.unlock()
            }
        }
    }
    activeGroup.wait()
    let activeWSURL = activeBox.value
    print("active-tab detection: \(elapsed(tCmd)) (active=\(activeWSURL == nil ? "none" : "found"))")

    for (idx, t) in targets.enumerated() {
        guard let wsUrl = t["webSocketDebuggerUrl"] as? String else { continue }
        let title = (t["title"] as? String) ?? "unknown"
        let tTab = Date()
        print("[\(idx)] \(title)  (starting at \(elapsed(tCmd)))")
        restoreLayoutWindow(wsUrl: wsUrl, tSidebar: tSidebar, tPanel: tPanel, label: "\(idx)", bringToFront: true)
        print("    tab total: \(elapsed(tTab))")
        print("")
    }

    if let activeWSURL, let task = newWebSocket(activeWSURL) {
        bringTabToFront(task)
        task.cancel(with: .normalClosure, reason: nil)
        print("returned focus to active tab: \(elapsed(tCmd))")
    }
    return EXIT_OK
}

