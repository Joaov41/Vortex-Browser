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
        report("SDK: \(Bundle.main.object(forInfoDictionaryKey: "DTSDKBuild") ?? "unknown")")
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
            try await runNativeAdProbe(store: store, server: server, port: port, cookieRule: rule)
            report("PASS: lifecycle, cookie and native script fixtures. Real-site compatibility remains a manual smoke test.")
            exit(0)
        } catch { report("FAIL: \(error)"); exit(1) }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "Probe", code: 4, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private func runNativeAdProbe(store: WKContentRuleListStore, server: LoopbackServer, port: UInt16, cookieRule: WKContentRuleList) async throws {
        guard let url = Bundle.main.url(forResource: "native-ad-rules", withExtension: "json") else {
            throw NSError(domain: "Probe.MissingNativeFixture", code: 10)
        }
        var rules = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        // Positive controls are test-only; they are never added to Browser's filters.
        rules.append(["trigger": ["url-filter": "/blocked-ad\\.js", "resource-type": ["script", "raw", "fetch"], "load-context": ["top-frame"]], "action": ["type": "block"]])
        let exception = IndexedAdBlockRules.parseRule("@@/blocked-ad.js?allow=1$script,domain=127.0.0.1")!
        rules.append(contentsOf: try NativeAdResourceRules.exceptionRules(exception))
        let data = try JSONSerialization.data(withJSONObject: rules)
        let json = String(decoding: data, as: UTF8.self)
        for pass in 1...2 {
            report("Native ad compilation \(pass): \(rules.count) rules, \(data.count) bytes")
            let started = Date()
            let adRule: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
                store.compileContentRuleList(forIdentifier: "isolated-ad-probe-v1", encodedContentRuleList: json) { rule, error in
                    if let rule { continuation.resume(returning: rule) }
                    else { continuation.resume(throwing: error ?? NSError(domain: "Probe.AdCompile", code: 11)) }
                }
            }
            report("Native ad compiled in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            for cycle in 1...4 {
                let config = WKWebViewConfiguration()
                config.websiteDataStore = cycle.isMultiple(of: 2) ? .default() : .nonPersistent()
                config.userContentController.add(cookieRule)
                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
                webView.navigationDelegate = self
                let page = URL(string: "http://127.0.0.1:\(port)/resource-page")!
                let baseline = try await loadResourcePage(page, in: webView)
                try require(baseline["blockedRuns"] == 4 && baseline["allowedRuns"] == 1, "Script baseline did not execute")
                try require(baseline["fetchAllowed"] == 1, "Fetch baseline did not load")
                config.userContentController.add(adRule)
                let before = server.blockedScriptRequests
                let protected = try await loadResourcePage(page, in: webView)
                try require(protected["blockedRuns"] == 1, "Blocked script executed (expected only explicit exception)")
                try require(protected["allowedRuns"] == 1, "Normal script was blocked")
                try require(protected["frameRuns"] == 1, "Native layer overrode child-frame fallback")
                try require(protected["fetchAllowed"] == 0, "Script exception incorrectly allowed a fetch")
                try require(server.blockedScriptRequests == before + 2, "Blocked scripts reached server (expected top-page exception + child-frame fallback)")
                let otherSource = try await loadResourcePage(URL(string: "http://localhost:\(port)/resource-page")!, in: webView)
                try require(otherSource["blockedRuns"] == 0 && otherSource["allowedRuns"] == 1, "Exception escaped its source-site scope")
                config.userContentController.remove(adRule)
                let restored = try await loadResourcePage(page, in: webView)
                try require(restored["blockedRuns"] == 4 && restored["allowedRuns"] == 1, "Removing ad rules did not restore scripts")
                try require(restored["fetchAllowed"] == 1, "Removing ad rules did not restore fetch")
                webView.navigationDelegate = nil
                report("PASS native ad cycle \(pass).\(cycle): pre-request script blocking; production exception keeps path/type/site scope; normal script and child frame preserved; removal restored; cookie rule coexists")
            }
            if pass == 1 && ProcessInfo.processInfo.arguments.contains("--live-supplement-urls") {
                try await runSupplementalURLProbe(adRule: adRule, port: port)
            }
        }
    }

    /// Opt-in real URL checks, using a fresh private store and HEAD requests only.
    /// No Vortex app data or user credentials are read. A baseline network failure
    /// is explicitly inconclusive; it must not be counted as a proven block.
    private func runSupplementalURLProbe(adRule: WKContentRuleList, port: UInt16) async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = self
        defer { webView.navigationDelegate = nil }
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/supplement-page")!))
        }
        let hosts = SupplementalAdResourceRules.entries.map(\.host)
        let literal = String(decoding: try JSONEncoder().encode(hosts), as: UTF8.self)
        let script = """
        window.supplementResults = null;
        Promise.all(\(literal).map(async host => {
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 8000);
            try {
                await fetch('https://' + host + '/', {method:'HEAD',mode:'no-cors',
                    credentials:'omit',cache:'no-store',referrerPolicy:'no-referrer',signal:controller.signal});
                return [host, 'reachable'];
            } catch (error) { return [host, error.name === 'AbortError' ? 'timeout' : 'rejected']; }
            finally { clearTimeout(timer); }
        })).then(values => window.supplementResults = Object.fromEntries(values));
        true;
        """
        func fetchResults() async throws -> [String: String] {
            _ = try await webView.evaluateJavaScript(script)
            for _ in 0..<200 {
                if let values = try await webView.evaluateJavaScript("window.supplementResults") as? [String: String] { return values }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "Probe.SupplementTimeout", code: 13)
        }
        report("Live supplement: checking \(hosts.count) public endpoints with credential-free HEAD requests")
        let baseline = try await fetchResults()
        config.userContentController.add(adRule)
        let protected = try await fetchResults()
        config.userContentController.remove(adRule)
        let restored = try await fetchResults()
        var demonstrated = 0
        for host in hosts {
            try require(protected[host] == "rejected", "Native supplement did not reject " + host)
            let proven = baseline[host] == "reachable" && restored[host] == "reachable"
            if proven { demonstrated += 1 }
            report("\(proven ? "PASS" : "INCONCLUSIVE baseline/restoration") live \(host): before=\(baseline[host] ?? "missing"), native=\(protected[host] ?? "missing"), removed=\(restored[host] ?? "missing")")
        }
        report("Live supplement: \(demonstrated)/\(hosts.count) demonstrated reachable -> native rejected -> reachable; other baseline failures are not credited")
    }

    private func loadResourcePage(_ url: URL, in webView: WKWebView) async throws -> [String: Int] {
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        for _ in 0..<100 {
            if let result = try await webView.evaluateJavaScript("window.resourceDone && window.frameDone && window.fetchAllowed !== -1 ? {blockedRuns:window.blockedRuns,allowedRuns:window.allowedRuns,frameRuns:window.frameRuns,fetchAllowed:window.fetchAllowed} : null") as? [String: Int] { return result }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "Probe.ResourceTimeout", code: 12)
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
    private(set) var blockedScriptRequests = 0
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
                let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                if path.contains("blocked-ad.js") { self.blockedScriptRequests += 1 }
                let echo = lines[0].contains("/echo")
                let literal = String(data: try! JSONEncoder().encode(cookie), encoding: .utf8)!
                var contentType = echo ? "text/plain" : "text/html"
                var body = echo ? cookie : """
                <html><body>Cookie fixture<script>
                window.cookieResults={first:\(literal)};
                fetch('http://localhost:\(port)/echo',{credentials:'include',cache:'no-store'})
                  .then(r=>r.text()).then(t=>window.cookieResults.third=t);
                </script></body></html>
                """
                if path.hasPrefix("/supplement-page") {
                    body = "<html><body>Isolated supplemental URL probe</body></html>"
                } else if path.hasPrefix("/resource-page") {
                    body = """
                    <html><head><script>window.blockedRuns=0;window.allowedRuns=0;window.addEventListener('message',e=>{if(e.data && 'frameRuns' in e.data){window.frameRuns=e.data.frameRuns;window.frameDone=true}});</script>
                    <script src="/blocked-ad.js"></script><script src="/ordinary.js"></script>
                    <script src="http://localhost:\(port)/blocked-ad.js"></script>
                    <script src="/blocked-ad.js?allow=1"></script></head><body>Resource fixture<iframe src="/frame-page"></iframe><script>
                    const script=document.createElement('script');script.src='/blocked-ad.js?dynamic=1';
                    script.onload=script.onerror=()=>window.resourceDone=true;document.head.appendChild(script);
                    window.fetchAllowed=-1;fetch('/blocked-ad.js?allow=1').then(()=>window.fetchAllowed=1).catch(()=>window.fetchAllowed=0);
                    </script></body></html>
                    """
                } else if path.hasPrefix("/frame-page") {
                    body = "<html><head><script>window.blockedRuns=0;</script><script src='/blocked-ad.js?frame=1'></script></head><body><script>parent.postMessage({frameRuns:window.blockedRuns},'*');</script></body></html>"
                } else if path.contains("blocked-ad.js") {
                    contentType = "application/javascript"; body = "window.blockedRuns++;"
                } else if path.hasPrefix("/ordinary.js") {
                    contentType = "application/javascript"; body = "window.allowedRuns++;"
                }
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType); charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: http://127.0.0.1:\(port)\r\nAccess-Control-Allow-Credentials: true\r\nConnection: close\r\n\r\n"
                connection.send(content: Data((headers + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
