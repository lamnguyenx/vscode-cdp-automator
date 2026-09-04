import Cocoa
import Foundation

// MARK: - Vivaldi Tab Bar (via window.html CDP target)

struct VivaldiTabBarState {
    let width: Int
    let position: String
    let handleX: Double
    let handleY: Double
}

func readVivaldiTabBarState(_ task: URLSessionWebSocketTask) -> VivaldiTabBarState? {
    let raw = evalJS(task, """
    (() => {
        const c = document.querySelector('#tabs-tabbar-container');
        const bar = document.querySelector('.SlideBar');
        const browser = document.querySelector('#browser');
        let pos = 'unknown';
        if (browser) {
            const m = browser.className.match(/tabs-(left|right|top|bottom)/);
            if (m) pos = m[1];
        }
        if (!c || !bar) return JSON.stringify(null);
        const cr = c.getBoundingClientRect();
        const br = bar.getBoundingClientRect();
        return JSON.stringify({ width: Math.round(cr.width), position: pos, hx: br.x + br.width / 2, hy: br.y + br.height / 2 });
    })()
    """)
    guard let data = raw.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let width = dict["width"] as? Int,
          let position = dict["position"] as? String,
          let hx = dict["hx"] as? Double,
          let hy = dict["hy"] as? Double
    else { return nil }
    return VivaldiTabBarState(width: width, position: position, handleX: hx, handleY: hy)
}

func cdpInputMouseEvent(_ task: URLSessionWebSocketTask, _ id: Int, _ type: String, _ x: Double, _ y: Double, _ button: String, _ buttons: Int, _ clickCount: Int) {
    let obj: [String: Any] = [
        "id": id,
        "method": "Input.dispatchMouseEvent",
        "params": ["type": type, "x": x, "y": y, "button": button, "buttons": buttons, "clickCount": clickCount]
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let str = String(data: data, encoding: .utf8)
    else { return }
    _ = wsSend(task, str, waitForId: id)
}

func resizeVivaldiTabBar(_ task: URLSessionWebSocketTask, targetWidth: Int) -> Bool {
    guard let state = readVivaldiTabBarState(task) else {
        fputs("    tab bar not visible or resize handle missing\n", stderr)
        return false
    }
    guard state.position == "left" || state.position == "right" else {
        fputs("    tab bar is not vertical (position=\(state.position))\n", stderr)
        return false
    }

    let dx = targetWidth - state.width
    if dx == 0 {
        print("    tab bar already at \(state.width)px")
        return true
    }

    let endX = state.position == "right" ? state.handleX - Double(dx) : state.handleX + Double(dx)
    let y = state.handleY

    var id = 200
    cdpInputMouseEvent(task, id, "mouseMoved", state.handleX, y, "none", 0, 0); id += 1
    cdpInputMouseEvent(task, id, "mousePressed", state.handleX, y, "left", 1, 1); id += 1
    let steps = 12
    for i in 1...steps {
        let ix = state.handleX + (endX - state.handleX) * Double(i) / Double(steps)
        cdpInputMouseEvent(task, id, "mouseMoved", ix, y, "left", 1, 0); id += 1
        Thread.sleep(forTimeInterval: 0.015)
    }
    cdpInputMouseEvent(task, id, "mouseReleased", endX, y, "left", 0, 1); id += 1
    Thread.sleep(forTimeInterval: 0.2)

    if let after = readVivaldiTabBarState(task) {
        print("    tab bar width: \(state.width)px → \(after.width)px")
        return abs(after.width - targetWidth) <= 2
    }
    return true
}

// MARK: - Vivaldi Zoom (via window.html CDP target)

func readVivaldiUIZoom(_ task: URLSessionWebSocketTask) -> Double? {
    let raw = evalJS(task, "new Promise(r => window.vivaldi.zoom.getVivaldiUIZoom(x => r(JSON.stringify(x))))")
    return Double(raw)
}

func readVivaldiDefaultZoom(_ task: URLSessionWebSocketTask) -> Double? {
    let raw = evalJS(task, "new Promise(r => window.vivaldi.zoom.getDefaultZoom(x => r(JSON.stringify(x))))")
    return Double(raw)
}

func setVivaldiUIZoom(_ task: URLSessionWebSocketTask, _ factor: Double) {
    _ = evalJS(task, "new Promise(r => window.vivaldi.zoom.setVivaldiUIZoom(\(factor), () => r('ok')))")
}

func setVivaldiDefaultZoom(_ task: URLSessionWebSocketTask, _ factor: Double) {
    _ = evalJS(task, "new Promise(r => window.vivaldi.zoom.setDefaultZoom(\(factor), () => r('ok')))")
}

func vivaldiTabIDs(_ task: URLSessionWebSocketTask) -> [Int] {
    let raw = evalJS(task, """
    new Promise(r => chrome.tabs.query({}, t => r(JSON.stringify(t.map(x => x.id)))))
    """)
    guard let data = raw.data(using: .utf8),
          let ids = try? JSONDecoder().decode([Int].self, from: data)
    else { return [] }
    return ids
}

func readVivaldiTabZoom(_ task: URLSessionWebSocketTask, _ tabId: Int) -> Double? {
    let raw = evalJS(task, "new Promise(r => chrome.tabs.getZoom(\(tabId), f => r(JSON.stringify(f))))")
    return Double(raw)
}

func setVivaldiTabZoom(_ task: URLSessionWebSocketTask, _ tabId: Int, _ factor: Double) -> Bool {
    _ = evalJS(task, "new Promise(r => chrome.tabs.setZoom(\(tabId), \(factor), () => r('ok')))")
    if let after = readVivaldiTabZoom(task, tabId) {
        return abs(after - factor) < 0.01
    }
    return false
}

// MARK: - Vivaldi Tab Numbers (via window.html CDP target)

let VIVALDI_TAB_NUMBER_STYLE = """
.tab-strip { counter-reset: tabidx; }
.tab-strip .tab-position { counter-increment: tabidx; }
.tab-strip .tab-position .title::before { content: counter(tabidx) ". "; margin-right: 5px; font-weight: 700; color: #8b8b8b; }
""".trimmingCharacters(in: .whitespacesAndNewlines)

func jsStringLiteral(_ s: String) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: [s]),
          var str = String(data: data, encoding: .utf8),
          str.count >= 2 else { return nil }
    str.removeFirst()
    str.removeLast()
    return str
}

func enableVivaldiTabNumbers(port: Int) -> Bool {
    guard let targets = tryFetchVivaldiWindowTargets(port: port), !targets.isEmpty else {
        fputs("Skipping tab numbers: no Vivaldi window.html target on CDP port \(port).\n", stderr)
        return false
    }

    var allOk = true
    guard let styleLiteral = jsStringLiteral(VIVALDI_TAB_NUMBER_STYLE) else {
        fputs("Failed to encode tab-number CSS.\n", stderr)
        return false
    }
    for (idx, t) in targets.enumerated() {
        guard let wsUrl = t["webSocketDebuggerUrl"] as? String,
              let task = newWebSocket(wsUrl)
        else { continue }

        let expr = """
        (() => {
            let el = document.getElementById('tab-order-numbers');
            if (!el) { el = document.createElement('style'); el.id = 'tab-order-numbers'; document.head.appendChild(el); }
            el.textContent = \(styleLiteral);
            return document.getElementById('tab-order-numbers') ? 'ok' : 'fail';
        })()
        """
        let raw = evalJS(task, expr)
        task.cancel(with: .normalClosure, reason: nil)

        let ok = raw == "ok"
        print("[\(idx)] tab numbers: \(ok ? "on" : "FAILED")")
        if !ok { allOk = false }
    }
    return allOk
}

func cmdVivaldiTabNumbers(port: Int) -> Int32 {
    if enableVivaldiTabNumbers(port: port) { return EXIT_OK }
    return EXIT_FAILED
}

// MARK: - Save Vivaldi

func cmdSaveVivaldi(port: Int) -> Int32 {
    var tabBarWidth: Int?
    var tabBarPosition: String?

    if let targets = tryFetchVivaldiWindowTargets(port: port),
       let t = targets.first,
       let wsUrl = t["webSocketDebuggerUrl"] as? String,
       let task = newWebSocket(wsUrl) {
        if let state = readVivaldiTabBarState(task) {
            if state.position == "left" || state.position == "right" {
                tabBarWidth = state.width
                tabBarPosition = state.position
            }
        }
        task.cancel(with: .normalClosure, reason: nil)
    }

    var winInfo: WindowInfo?
    if let (win, title, pid) = findFrontmostVivaldiWindow(),
       let pos = axGetPoint(win, "AXPosition"),
       let size = axGetSize(win, "AXSize") {
        let (screenFrame, relX, relY, _) = describeScreen(containing: pos)
        winInfo = WindowInfo(
            title: title,
            pid: pid,
            x: Double(pos.x),
            y: Double(pos.y),
            width: Double(size.width),
            height: Double(size.height),
            screenFrame: screenFrame,
            screenRelativeX: relX,
            screenRelativeY: relY,
            label: title
        )
    }

    if tabBarWidth == nil && winInfo == nil {
        fputs("Skipping save-vivaldi: no Vivaldi window or vertical tab bar found.\n", stderr)
        return EXIT_PRECONDITION
    }

    let fingerPrint = displayFingerprint()
    var store = loadConfigStore()
    var entry = store[fingerPrint] ?? DisplayConfig(window: nil, layout: nil)
    var v = entry.vivaldi ?? VivaldiConfig()
    if let w = tabBarWidth { v.tabBarWidth = w }
    if let p = tabBarPosition { v.tabBarPosition = p }
    if let wi = winInfo { v.window = wi }
    entry.vivaldi = v
    store[fingerPrint] = entry
    guard saveConfigStore(store) else { return EXIT_FAILED }

    print("Saved Vivaldi → \(CONFIG_PATH)")
    if let w = tabBarWidth, let p = tabBarPosition {
        print("  tab bar:  \(w)px (\(p))")
    }
    if let wi = winInfo {
        print("  window:   pos=(\(Int(wi.x)), \(Int(wi.y)))  size=\(Int(wi.width))x\(Int(wi.height))")
    }
    return EXIT_OK
}

// MARK: - Restore Vivaldi

func cmdRestoreVivaldi(port: Int) -> Int32 {
    guard requireAXTrust() else { return EXIT_PRECONDITION }
    let store = loadConfigStore()
    guard !store.isEmpty else {
        fputs("Skipping restore-vivaldi: no saved data at \(CONFIG_PATH).\n", stderr)
        return EXIT_PRECONDITION
    }

    guard let (_, entry, _) = lookupDisplayEntry(in: store),
          let vivaldi = entry.vivaldi else {
        fputs("Skipping restore-vivaldi: no saved Vivaldi config for current display layout.\n", stderr)
        return EXIT_PRECONDITION
    }

    if let target = vivaldi.window {
        let current = findVivaldiWindows()
        guard !current.isEmpty else {
            fputs("Skipping restore-vivaldi window: no Vivaldi windows currently open.\n", stderr)
            return EXIT_PRECONDITION
        }

        let (globalPos, src) = resolveAndClamp(from: target)

        print("Applying Vivaldi window to \(current.count) open window(s) [\(src.rawValue)]:")
        print("  target: pos=(\(Int(globalPos.x)), \(Int(globalPos.y)))  size=\(Int(target.width))x\(Int(target.height))\n")

        for i in 0..<current.count {
            let (win, _, _, _) = current[i]
            print("[\(i+1)]")

            _ = applyWindowGeometry(
                win,
                target: target,
                globalPos: globalPos,
                maxRetries: 3,
                firstSleep: 0.1,
                retrySleep: 0.15,
                verboseFullscreen: false
            )
            print("")
        }
    }

    if let targetWidth = vivaldi.tabBarWidth,
       let targets = tryFetchVivaldiWindowTargets(port: port) {
        print("Restoring Vivaldi tab bar to \(targetWidth)px across \(targets.count) window(s):")
        for (idx, t) in targets.enumerated() {
            guard let wsUrl = t["webSocketDebuggerUrl"] as? String,
                  let task = newWebSocket(wsUrl)
            else { continue }
            print("[\(idx)]")
            _ = resizeVivaldiTabBar(task, targetWidth: targetWidth)
            task.cancel(with: .normalClosure, reason: nil)
        }
        print("")
    }
    return EXIT_OK
}

// MARK: - Save Vivaldi Zoom

func cmdSaveVivaldiZoom(port: Int) -> Int32 {
    guard let targets = tryFetchVivaldiWindowTargets(port: port),
          let t = targets.first,
          let wsUrl = t["webSocketDebuggerUrl"] as? String,
          let task = newWebSocket(wsUrl)
    else {
        fputs("Skipping save-vivaldi-zoom: cannot reach Vivaldi window.html on CDP port \(port).\n", stderr)
        return EXIT_PRECONDITION
    }
    defer { task.cancel(with: .normalClosure, reason: nil) }

    guard let uiZoom = readVivaldiUIZoom(task),
          let defaultZoom = readVivaldiDefaultZoom(task)
    else {
        fputs("Skipping save-vivaldi-zoom: could not read zoom values from Vivaldi.\n", stderr)
        return EXIT_PRECONDITION
    }

    let fingerPrint = displayFingerprint()
    var store = loadConfigStore()
    var entry = store[fingerPrint] ?? DisplayConfig(window: nil, layout: nil)
    var v = entry.vivaldi ?? VivaldiConfig()
    v.uiZoom = uiZoom
    v.defaultZoom = defaultZoom
    entry.vivaldi = v
    store[fingerPrint] = entry
    guard saveConfigStore(store) else { return EXIT_FAILED }

    print("Saved Vivaldi zoom → \(CONFIG_PATH)")
    print("  UI zoom:      \(Int((uiZoom * 100).rounded()))%")
    print("  default zoom: \(Int((defaultZoom * 100).rounded()))%")
    return EXIT_OK
}

// MARK: - Restore Vivaldi Zoom

func cmdRestoreVivaldiZoom(port: Int) -> Int32 {
    let store = loadConfigStore()
    guard !store.isEmpty else {
        fputs("Skipping restore-vivaldi-zoom: no saved data at \(CONFIG_PATH).\n", stderr)
        return EXIT_PRECONDITION
    }

    let fingerPrint = displayFingerprint()

    let vivaldi: VivaldiConfig
    if let match = store[fingerPrint]?.vivaldi {
        vivaldi = match
    } else if store.count == 1, let only = store.values.first?.vivaldi {
        fputs("No saved Vivaldi config for current display layout; using the only available saved config.\n", stderr)
        print("\nCurrent layout:\n\(fingerPrint)\n")
        vivaldi = only
    } else {
        fputs("Skipping restore-vivaldi-zoom: no saved Vivaldi config for current display layout.\n", stderr)
        return EXIT_PRECONDITION
    }

    guard let targets = tryFetchVivaldiWindowTargets(port: port),
          let t = targets.first,
          let wsUrl = t["webSocketDebuggerUrl"] as? String,
          let task = newWebSocket(wsUrl)
    else {
        fputs("Skipping restore-vivaldi-zoom: cannot reach Vivaldi window.html on CDP port \(port).\n", stderr)
        return EXIT_PRECONDITION
    }
    defer { task.cancel(with: .normalClosure, reason: nil) }

    if let uiZoom = vivaldi.uiZoom {
        setVivaldiUIZoom(task, uiZoom)
        Thread.sleep(forTimeInterval: 0.3)
        let ok = readVivaldiUIZoom(task).map { abs($0 - uiZoom) < 0.01 } ?? false
        print("UI zoom: \(Int((uiZoom * 100).rounded()))%  \(ok ? "OK" : "FAILED")")
    }

    if let defaultZoom = vivaldi.defaultZoom {
        setVivaldiDefaultZoom(task, defaultZoom)
        Thread.sleep(forTimeInterval: 0.3)
        let ok = readVivaldiDefaultZoom(task).map { abs($0 - defaultZoom) < 0.01 } ?? false
        print("Default zoom: \(Int((defaultZoom * 100).rounded()))%  \(ok ? "OK" : "FAILED")")

        let tabIDs = vivaldiTabIDs(task)
        guard !tabIDs.isEmpty else {
            print("No Vivaldi tabs to apply zoom to.")
            return EXIT_PRECONDITION
        }
        print("Applying default zoom to \(tabIDs.count) tab(s) (batched):")
        let idsExpr = tabIDs.map(String.init).joined(separator: ",")
        let raw = evalJS(task, """
        new Promise(r => {
            const ids = [\(idsExpr)];
            Promise.all(ids.map(id => new Promise(res => chrome.tabs.setZoom(id, \(defaultZoom), () => res(id)))))
                .then(() => Promise.all(ids.map(id => new Promise(res => chrome.tabs.getZoom(id, f => res([id, f]))))))
                .then(rs => r(JSON.stringify(rs)));
        })
        """)
        guard let data = raw.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[Any]]
        else {
            print("  batch zoom failed (unparseable result)")
            return EXIT_PRECONDITION
        }
        for (i, pair) in pairs.enumerated() {
            let id = pair.first as? Int ?? -1
            let f = pair.last as? Double ?? 0
            let good = abs(f - defaultZoom) < 0.01
            print("  [\(i + 1)] tab \(id): \(good ? "OK" : "FAILED")")
        }
    }
    return EXIT_OK
}

