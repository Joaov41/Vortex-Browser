// Runs the actual Swift-embedded JavaScript in an isolated macOS WKWebView.
// Synthetic filters/HTML only; no browser preferences, cookies or network requests.
import {readFileSync, mkdtempSync} from 'node:fs';
import {execFileSync, spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
import vm from 'node:vm';

const adPath = 'Browser/Services/AdBlockService.swift';
const current = readFileSync(adPath, 'utf8');
const baseline = execFileSync('git', ['show', '72dbb02:' + adPath], {encoding: 'utf8'});
function blocker(source, enabled) {
    const start = source.indexOf('return """', source.indexOf('private func generateBlockingJavaScript')) + 10;
    const end = source.indexOf('\n        """', start);
    assert(start > 10 && end > start);
    const values = {
        enabledJavaScript: String(enabled), domainsJSON: JSON.stringify(['ads.invalid']),
        networkRulesJSON: JSON.stringify(Array.from({length: 5000}, (_, i) => 'tracker' + i + '\\.invalid')),
        selectorsJSON: JSON.stringify(['.fixture-ad', ...Array.from({length: 3000}, (_, i) => '.fixture-ad-' + i)]),
        customRulesJSON: '[]', cosmeticCSSJSON: JSON.stringify('.fixture-ad')
    };
    const js = source.slice(start, end).replaceAll('\\\\', '\\').replace(/\\\((\w+)\)/g, (_, name) => {
        assert(name in values, 'Unknown Swift interpolation: ' + name);
        return values[name];
    });
    new vm.Script(js);
    return js;
}
const darkSource = readFileSync('Browser/Services/DarkModeService.swift', 'utf8');
const darkStart = darkSource.indexOf('"""', darkSource.indexOf('func activationScript')) + 3;
const darkEnd = darkSource.indexOf('"""', darkStart);
function activation(enabled) {
    const js = darkSource.slice(darkStart, darkEnd)
        .replaceAll('\\(enabled ? "true" : "false")', String(enabled))
        .replaceAll('\\(enabled)', String(enabled))
        .replaceAll('\\(brightness)', '100').replaceAll('\\(contrast)', '90').replaceAll('\\(sepia)', '10');
    new vm.Script(js);
    return js;
}
const payload = Buffer.from(JSON.stringify({
    oldOn: blocker(baseline, true), oldOff: blocker(baseline, false),
    newOn: blocker(current, true), newOff: blocker(current, false),
    dark: readFileSync('Browser/darkreader.js', 'utf8'), enable: activation(true), disable: activation(false)
})).toString('base64');
const helper = readFileSync('Browser/Utilities/ManagedUserScript.swift', 'utf8');
const compatibility = readFileSync('Browser/Utilities/NativeCookieRuleCompatibility.swift', 'utf8');
const swift = `
import AppKit
import WebKit
${helper}
${compatibility}

@MainActor final class Navigation: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}
enum TestFailure: Error { case failed(String) }
func check(_ value: Bool, _ message: String) throws {
    if !value { throw TestFailure.failed(message) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let payload = try! JSONSerialization.jsonObject(with: Data(base64Encoded: "${payload}")!) as! [String: String]
Task { @MainActor in
    do {
        try check(NativeCookieRuleCompatibility.supports(majorVersion: 26, osBuild: "old", sdkBuild: nil), "Lost iOS 26 support")
        try check(NativeCookieRuleCompatibility.supports(majorVersion: 27, osBuild: "24A5430a", sdkBuild: "24A5380g"), "Verified pair disabled")
        try check(!NativeCookieRuleCompatibility.supports(majorVersion: 27, osBuild: "old", sdkBuild: "24A5380g"), "Untested OS enabled")
        try check(!NativeCookieRuleCompatibility.supports(majorVersion: 27, osBuild: "24A5430a", sdkBuild: "unknown"), "Untested SDK enabled")
        try check(!NativeCookieRuleCompatibility.supports(majorVersion: 28, osBuild: "24A5430a", sdkBuild: "24A5380g"), "Untested major enabled")
        for name in ["before-on-two", "after-on-50-refreshes", "before-off-two", "after-off", "after-early-dark"] {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let controller = config.userContentController
            let measure = "window.probeQueries=0; const query=document.querySelector.bind(document); document.querySelector=function(s){window.probeQueries++;return query(s)}; window.probePeer=true;"
            let peer = WKUserScript(source: measure, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            controller.addUserScript(peer)
            let old = name.hasPrefix("before")
            let off = name.contains("off")
            if old {
                for _ in 0..<2 {
                    controller.addUserScript(WKUserScript(source: payload[off ? "oldOff" : "oldOn"]!, injectionTime: .atDocumentStart, forMainFrameOnly: false))
                }
            } else {
                for index in 0..<50 {
                    ManagedUserScript.install(source: payload[index % 2 == 0 ? "newOff" : "newOn"]!, identifier: "ad-block", in: controller)
                }
                ManagedUserScript.install(source: payload[off ? "newOff" : "newOn"]!, identifier: "ad-block", in: controller)
                try check(controller.userScripts.count == 2, "Accumulating scripts")
                try check(controller.userScripts.first === peer, "Lost peer script identity/order")
                let unchanged = ManagedUserScript.install(source: payload[off ? "newOff" : "newOn"]!, identifier: "ad-block", in: controller)
                try check(!unchanged, "Unchanged script replaced")
            }
            let earlyDark = name.contains("early-dark")
            if earlyDark {
                ManagedUserScript.install(source: payload["dark"]! + ";" + payload["enable"]!, identifier: "dark-mode", in: controller)
                // The page's FIRST inline script must already see dark mode enabled.
            }
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = webView
            window.orderFront(nil)
            let nav = Navigation()
            webView.navigationDelegate = nav
            let html = "<html><head><script>window.darkAtFirstInline = typeof DarkReader !== 'undefined' && DarkReader.isEnabled();requestAnimationFrame(()=>window.firstFrameBackground=getComputedStyle(document.documentElement).backgroundColor);</script></head><body>" + String(repeating: "<article><div>Normal text</div><div class='fixture-ad'>Ad</div></article>", count: 100) + "</body></html>"
            let started = Date()
            try await withCheckedThrowingContinuation { continuation in
                nav.continuation = continuation
                webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.invalid"))
            }
            let loadMS = Int(Date().timeIntervalSince(started) * 1000)
            let values = try await webView.evaluateJavaScript("({css:document.querySelectorAll('#adblock-css-rules').length, queries:window.probeQueries, peer:window.probePeer, earlyDark:window.darkAtFirstInline})") as! [String: Any]
            print("METRIC \\(name): load_ms=\\(loadMS), \\(values)")
            try check(values["peer"] as? Bool == true, "Other browser script did not run")
            if !old {
                try check(values["css"] as? Int == (off ? 0 : 1), "Wrong ad stylesheet count")
                if off { try check(values["queries"] as? Int == 0, "Disabled blocker compiled selectors") }
                let queryCount = values["queries"] as! Int
                _ = try await webView.evaluateJavaScript(payload[off ? "newOff" : "newOn"]!)
                let repeated = try await webView.evaluateJavaScript("window.probeQueries") as! Int
                try check(repeated == queryCount, "Unchanged configuration rebuilt rules")
                _ = try await webView.evaluateJavaScript(payload["newOff"]!)
                let restored = try await webView.evaluateJavaScript("document.querySelectorAll('[data-codex-adblocked]').length") as! Int
                try check(restored == 0, "Disabled blocker left elements hidden")
                _ = try await webView.evaluateJavaScript(payload["newOn"]!)
                let enabledCSS = try await webView.evaluateJavaScript("document.querySelectorAll('#adblock-css-rules').length") as! Int
                try check(enabledCSS == 1, "Enable did not restore one stylesheet")
            }
            if earlyDark {
                try check(values["earlyDark"] as? Bool == true, "Dark mode activated after first page script")
                try await Task.sleep(for: .milliseconds(100))
                let firstFrame = try await webView.evaluateJavaScript("window.firstFrameBackground || ''") as! String
                print("FIRST_FRAME_BACKGROUND \\(firstFrame)")
                try check(firstFrame.hasPrefix("rgb(") && firstFrame != "rgb(255, 255, 255)", "First frame was not opaque/dark")
                _ = try await webView.evaluateJavaScript("window.enableCalls=0;const enable=DarkReader.enable;DarkReader.enable=function(...args){enableCalls++;return enable(...args)};true")
                _ = try await webView.evaluateJavaScript(payload["enable"]!)
                let calls = try await webView.evaluateJavaScript("window.enableCalls") as! Int
                try check(calls == 0, "didFinish fallback re-enabled DarkReader")
                _ = try await webView.evaluateJavaScript(payload["disable"]!)
                let enabled = try await webView.evaluateJavaScript("DarkReader.isEnabled()") as! Bool
                try check(!enabled, "Light override did not disable DarkReader")
            }
            webView.navigationDelegate = nil
            window.orderOut(nil)
        }
        print("PASS: managed ownership, 50 refreshes, CSS uniqueness, disabled fast path, re-enable, early dark and idempotent fallback")
        exit(0)
    } catch { print("FAIL: \\(error)"); exit(1) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("FAIL: WebKit test timeout"); exit(2) }
app.run()
`;
const cache = mkdtempSync('/private/tmp/vortex-webkit-regression-');
const result = spawnSync('swift', ['-module-cache-path', cache, '-'], {input: swift, encoding: 'utf8', timeout: 120000, maxBuffer: 8 * 1024 * 1024});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (result.error) console.error(result.error);
process.exit(result.status ?? 1);
