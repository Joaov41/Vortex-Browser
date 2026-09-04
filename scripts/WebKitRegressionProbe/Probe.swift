import SwiftUI
import WebKit
import Network

/// Deliberately separate bundle and data store: never touches Vortex's cookies,
/// preferences or tabs. HTTP fixtures are served only over device loopback.
@main
struct ProbeApp: App {
    @StateObject private var probe = RuleProbe()
    var body: some Scene {
        WindowGroup {
            ScrollView { Text(probe.log).font(.system(.body, design: .monospaced)).padding() }
                .task { await probe.run() }
        }
    }
}

@MainActor
final class RuleProbe: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var log = "Vortex isolated WebKit compatibility probe\n"
    private var running = false
    private var navigation: CheckedContinuation<Void, Error>?
    private func report(_ text: String) {
        log += text + "\n"
        print("VORTEX_PROBE: " + text)
        fflush(stdout)
    }

    func run() async {
        guard !running else { return }
        running = true
        report("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        report("Creating native rule store")
        guard let store = WKContentRuleListStore.default() else { report("FAIL: no rule store"); return }
        do {
            let json = """
            [{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block-cookies"}}]
            """
            report("Compiling block-cookies rule")
            let rule: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
                store.compileContentRuleList(forIdentifier: "isolated-cookie-probe-v1", encodedContentRuleList: json) { rule, error in
                    if let rule { continuation.resume(returning: rule) }
                    else { continuation.resume(throwing: error ?? NSError(domain: "Probe", code: 1)) }
                }
            }
            report("Compiled; beginning attach/load/remove/teardown cycles")
            for cycle in 1...6 {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.userContentController.add(rule)
                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
                webView.navigationDelegate = self
                try await withCheckedThrowingContinuation { continuation in
                    navigation = continuation
                    webView.loadHTMLString("<html><body>Isolated cycle \(cycle)<iframe srcdoc='child frame'></iframe></body></html>", baseURL: URL(string: "https://probe.invalid"))
                }
                let text = try await webView.evaluateJavaScript("document.body.innerText")
                report("Cycle \(cycle): loaded \(String(describing: text))")
                configuration.userContentController.remove(rule)
                webView.navigationDelegate = nil
            }
            let server = LoopbackServer()
            let port = try await server.start()
            defer { server.stop() }
            let service = ThirdPartyCookieBlocker()
            try require(service.isSupported, "Production service rejected verified OS/SDK")
            service.isEnabled = false
            let allCookiesRule: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
                store.compileContentRuleList(
                    forIdentifier: "isolated-cookie-positive-control-v1",
                    encodedContentRuleList: "[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block-cookies\"}}]"
                ) { rule, error in
                    if let rule { continuation.resume(returning: rule) }
                    else { continuation.resume(throwing: error ?? NSError(domain: "Probe", code: 3)) }
                }
            }
            for persistent in [false, true] {
                let config = WKWebViewConfiguration()
                config.websiteDataStore = persistent ? .default() : .nonPersistent()
                let webView = WKWebView(frame: .zero, configuration: config)
                webView.navigationDelegate = self
                let cookieStore = config.websiteDataStore.httpCookieStore
                for host in ["127.0.0.1", "localhost"] {
                    let cookie = HTTPCookie(properties: [
                        .domain: host, .path: "/", .name: "probe-session", .value: "synthetic-session",
                        .expires: Date().addingTimeInterval(3600)
                    ])!
                    await cookieStore.setCookie(cookie)
                }
                let url = URL(string: "http://127.0.0.1:\(port)/page")!
                let baseline = try await loadCookiePage(url, in: webView)
                try require(baseline.first.contains("probe-session=synthetic-session"), "Baseline first-party cookie missing")
                config.userContentController.add(allCookiesRule)
                let control = try await loadCookiePage(url, in: webView)
                try require(control.first.isEmpty, "Native block-cookies positive control failed")
                config.userContentController.remove(allCookiesRule)
                config.userContentController.add(rule)
                let protected = try await loadCookiePage(url, in: webView)
                try require(protected.first.contains("probe-session=synthetic-session"), "Third-party rule blocked first-party session")
                try require(protected.third.isEmpty, "Third-party request sent cookies")
                config.userContentController.remove(rule)
                let restored = try await loadCookiePage(url, in: webView)
                try require(restored.first.contains("probe-session=synthetic-session"), "Removing rule lost session")
                let retained = await cookieStore.allCookies()
                try require(retained.filter { $0.name == "probe-session" }.count == 2, "Rule deleted stored cookies")
                report("PASS \(persistent ? "persistent" : "private"): first-party retained, native positive control blocked, third-party empty, removal preserved cookies. Baseline third-party empty=\(baseline.third.isEmpty)")
                service.register(webView: webView)
                service.setProtectionEnabled(false, for: webView)
                service.isEnabled = true
                try await Task.sleep(for: .milliseconds(300))
                try require(service.isSupported, "Production service failed to prepare rules")
                for enabled in [false, true, false, true] {
                    service.setProtectionEnabled(enabled, for: webView)
                    service.register(webView: webView)
                    let session = try await loadCookiePage(url, in: webView)
                    try require(session.first.contains("probe-session=synthetic-session"), "Production service lost first-party session")
                }
                service.isEnabled = false
                report("PASS production service: supported, prepared, repeated registration and site toggles preserved session")
                webView.navigationDelegate = nil
            }
            report("PASS: lifecycle and cookie fixtures. Real-site OAuth compatibility remains a manual smoke test.")
            exit(0)
        } catch { report("FAIL: \(error)"); exit(1) }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "Probe", code: 4, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private func loadCookiePage(_ url: URL, in webView: WKWebView) async throws -> (first: String, third: String) {
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        for _ in 0..<100 {
            if let data = try await webView.evaluateJavaScript("window.cookieResults") as? [String: String],
               let first = data["first"], let third = data["third"] { return (first, third) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "Probe.CookieTimeout", code: 5)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.resume()
        self.navigation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error)
        self.navigation = nil
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        report("FAIL: web content process terminated")
        navigation?.resume(throwing: NSError(domain: "Probe.WebContentTerminated", code: 2))
        navigation = nil
    }
}

@MainActor
final class LoopbackServer {
    private var listener: NWListener?
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                connection.start(queue: .main)
                self.receive(connection, accumulated: Data())
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .main)
        }
    }
    func stop() { listener?.cancel() }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
            Task { @MainActor in
                let requestData = accumulated + (data ?? Data())
                let request = String(decoding: requestData, as: UTF8.self)
                guard request.contains("\r\n\r\n") else {
                    if complete || error != nil || requestData.count > 32768 { connection.cancel() }
                    else { self.receive(connection, accumulated: requestData) }
                    return
                }
                let lines = request.components(separatedBy: "\r\n")
                let cookie = lines.first { $0.lowercased().hasPrefix("cookie:") }
                    .map { String($0.dropFirst(7)) } ?? ""
                let port = self.listener!.port!.rawValue
                let echo = lines[0].contains("/echo")
                let literal = String(data: try! JSONEncoder().encode(cookie), encoding: .utf8)!
                let body = echo ? cookie : """
                <html><body>Cookie fixture<script>
                window.cookieResults={first:\(literal)};
                fetch('http://localhost:\(port)/echo',{credentials:'include',cache:'no-store'})
                  .then(r=>r.text()).then(t=>window.cookieResults.third=t);
                </script></body></html>
                """
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: \(echo ? "text/plain" : "text/html"); charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: http://127.0.0.1:\(port)\r\nAccess-Control-Allow-Credentials: true\r\nConnection: close\r\n\r\n"
                connection.send(content: Data((headers + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
