import Cocoa
import Foundation

// MARK: - CDP Helpers

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

func httpGetJSON(_ urlString: String, timeout: TimeInterval = 3.0) -> Any? {
    return httpGetJSONWithStatus(urlString, timeout: timeout).json
}

func httpGetJSONWithStatus(_ urlString: String, timeout: TimeInterval = 3.0) -> (json: Any?, status: Int?, error: String?) {
    guard let url = URL(string: urlString) else { return (nil, nil, "bad URL") }
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    let box = Box<Any?>(nil)
    let statusBox = Box<Int?>(nil)
    let errorBox = Box<String?>(nil)
    let sem = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: req) { data, response, error in
        defer { sem.signal() }
        if let error = error as NSError? {
            errorBox.value = error.localizedDescription
            if verboseLogging { fputs("httpGet \(urlString) error: \(error)\n", stderr) }
        }
        if let http = response as? HTTPURLResponse {
            statusBox.value = http.statusCode
            if http.statusCode != 200 {
                errorBox.value = "HTTP \(http.statusCode)"
                if verboseLogging {
                    let snippet = data.flatMap { String(data: $0, encoding: .utf8)?.prefix(300).description } ?? ""
                    fputs("httpGet \(urlString) HTTP \(http.statusCode): \(snippet)\n", stderr)
                }
                return
            }
        }
        if let data = data {
            do {
                box.value = try JSONSerialization.jsonObject(with: data)
            } catch {
                errorBox.value = "JSON parse: \(error)"
            }
        }
    }
    task.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    return (box.value, statusBox.value, errorBox.value)
}

func tryFetchTargets(port: Int) -> [[String: Any]]? {
    guard let json = httpGetJSON("http://localhost:\(port)/json") as? [[String: Any]]
    else { return nil }
    return json.filter { ($0["url"] as? String)?.hasSuffix("workbench.html") ?? false }
}

func tryFetchCodeServerTargets(port: Int) -> [[String: Any]]? {
    guard let json = httpGetJSON("http://localhost:\(port)/json") as? [[String: Any]]
    else { return nil }
    return json.filter { target in
        guard (target["type"] as? String) == "page" else { return false }
        let urlStr = (target["url"] as? String) ?? ""
        return urlStr.contains("?folder=") || urlStr.contains("?workspace=")
    }
}

func tryFetchVivaldiWindowTargets(port: Int) -> [[String: Any]]? {
    guard let json = httpGetJSON("http://localhost:\(port)/json/list") as? [[String: Any]]
    else { return nil }
    return json.filter { target in
        ((target["url"] as? String) ?? "").contains("window.html")
    }
}

func isActiveTab(_ task: URLSessionWebSocketTask) -> Bool {
    let raw = evalJS(task, "String(document.hasFocus())")
    return raw == "true"
}

func isVisibleTab(_ task: URLSessionWebSocketTask) -> Bool {
    let raw = evalJS(task, "String(document.visibilityState === 'visible')")
    return raw == "true"
}

func wsRecv(_ task: URLSessionWebSocketTask) -> String {
    return wsRecvOpt(task) ?? ""
}

func wsRecvOpt(_ task: URLSessionWebSocketTask) -> String? {
    let sem = DispatchSemaphore(value: 0)
    let box = Box<String?>(nil)
    task.receive { result in
        if case .success(let msg) = result, case .string(let s) = msg { box.value = s }
        sem.signal()
    }
    if sem.wait(timeout: .now() + 5) == .timedOut {
        return nil
    }
    return box.value
}

private let cdpIdLock = NSLock()
nonisolated(unsafe) private var cdpNextId: Int = 1000

func nextCdpId() -> Int {
    cdpIdLock.lock()
    defer { cdpIdLock.unlock() }
    cdpNextId += 1
    return cdpNextId
}

func wsSend(_ task: URLSessionWebSocketTask, _ text: String, waitForId id: Int? = nil) -> String {
    let sem = DispatchSemaphore(value: 0)
    let sendBox = Box<Error?>(nil)
    task.send(.string(text)) { err in
        if let err = err { sendBox.value = err }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 5)
    if let err = sendBox.value {
        if verboseLogging { fputs("wsSend failed: \(err)\n", stderr) }
        return "{}"
    }

    guard let mid = id else {
        return wsRecv(task)
    }

    for _ in 0..<50 {
        guard let raw = wsRecvOpt(task) else { break }
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        // Match by decoded id only (no substring matching); ignore events.
        if let got = dict["id"] as? Int, got == mid {
            return raw
        } else if dict["id"] == nil {
            continue
        } else {
            continue
        }
    }
    return "{}"
}

final class CdpSession {
    let task: URLSessionWebSocketTask
    private var nextId: Int = 1
    private let lock = NSLock()
    init(_ task: URLSessionWebSocketTask) { self.task = task }
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        return nextId
    }
    @discardableResult
    func send(method: String, params: [String: Any] = [:]) -> [String: Any]? {
        let id = next()
        let obj: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let raw = wsSend(task, str, waitForId: id)
        guard let rdata = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: rdata) as? [String: Any] else { return nil }
        return dict
    }
    func evaluate(_ expression: String) -> String {
        return evalJS(task, expression)
    }
    func cancel() { task.cancel(with: .normalClosure, reason: nil) }
}

func evalJS(_ task: URLSessionWebSocketTask, _ expression: String) -> String {
    let mid = nextCdpId()
    let reqObj: [String: Any] = [
        "id": mid,
        "method": "Runtime.evaluate",
        "params": ["expression": expression, "returnByValue": true, "awaitPromise": true]
    ]
    guard let reqData = try? JSONSerialization.data(withJSONObject: reqObj),
          let reqStr = String(data: reqData, encoding: .utf8)
    else { return "null" }

    let raw = wsSend(task, reqStr, waitForId: mid)

    guard let data = raw.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = dict["result"] as? [String: Any],
          let inner = result["result"] as? [String: Any]
    else { return "null" }

    return inner["value"] as? String ?? "null"
}

func enableRuntime(_ task: URLSessionWebSocketTask) {
    _ = wsSend(task, "{\"id\":0,\"method\":\"Runtime.enable\"}", waitForId: 0)
}

func cdpSendMethod(_ task: URLSessionWebSocketTask, _ id: Int, _ method: String, _ params: [String: Any] = [:]) {
    let obj: [String: Any] = ["id": id, "method": method, "params": params]
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let str = String(data: data, encoding: .utf8)
    else { return }
    _ = wsSend(task, str, waitForId: id)
}

func bringTabToFront(_ task: URLSessionWebSocketTask) {
    cdpSendMethod(task, 301, "Page.bringToFront")
}

func newWebSocket(_ urlStr: String) -> URLSessionWebSocketTask? {
    guard let url = URL(string: urlStr) else { return nil }
    let task = URLSession.shared.webSocketTask(with: url)
    task.resume()
    return task
}

