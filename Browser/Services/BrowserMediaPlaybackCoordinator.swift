import UIKit
import WebKit

/// Owns media observations for the lifetime of a tab, including when its SwiftUI wrapper is absent.
@MainActor
final class BrowserMediaPlaybackCoordinator: NSObject, WKScriptMessageHandler {
    static let shared = BrowserMediaPlaybackCoordinator()
    private static let handlerName = "vortexMediaPlayback"
    private static let traceHandlerName = "vortexMediaTrace"
    private static let resumeHandlerName = "vortexMediaResume"
    private let tracing = CommandLine.arguments.contains("--trace-background-media")
    private var traceLines: [String] = []

    private final class Entry {
        weak var tab: BrowserTab?
        weak var webView: WKWebView?
        var playing = false
        var pictureInPicture = false
        var revision = 0
        var lastPlaybackAt = Date.distantPast
        var lastResumeAt = Date.distantPast

        init(tab: BrowserTab, webView: WKWebView) {
            self.tab = tab
            self.webView = webView
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(tab: BrowserTab, webView: WKWebView) {
        guard !tab.isIncognito, tab.webAIProvider == nil else { return }
        entries = entries.filter { $0.value.webView != nil }
        let key = ObjectIdentifier(webView)
        guard entries[key] == nil else { return }
        entries[key] = Entry(tab: tab, webView: webView)
        let controller = webView.configuration.userContentController
        controller.add(self, contentWorld: .defaultClient, name: Self.handlerName)
        controller.add(self, name: Self.resumeHandlerName)
        if tracing { controller.add(self, name: Self.traceHandlerName) }
        installMonitor(in: webView)
    }

    func unregister(_ webView: WKWebView) {
        entries.removeValue(forKey: ObjectIdentifier(webView))
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .defaultClient)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.resumeHandlerName)
        if tracing { webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.traceHandlerName) }
    }

    func stop(_ webView: WKWebView) {
        webView.evaluateJavaScript("globalThis.__vortexBackgroundMedia?.cancelAutomaticResume();") { [weak webView] _, _ in
            webView?.pauseAllMediaPlayback()
            webView?.closeAllMediaPresentations(completionHandler: nil)
        }
    }

    func protects(_ webView: WKWebView) -> Bool {
        if webView.fullscreenState != .notInFullscreen { return true }
        guard let entry = entries[ObjectIdentifier(webView)] else { return false }
        return entry.pictureInPicture || entry.playing
    }

    private func installMonitor(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        let marker = "// Vortex media monitor\n"
        let source = marker + Self.monitorScript()
        let existing = controller.userScripts
        ManagedUserScript.replaceAppScripts(
            existing.filter { !$0.source.hasPrefix(marker) && !$0.source.hasPrefix("// Vortex background media\n") },
            in: controller
        )
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: false, in: .defaultClient))
        if let url = Bundle.main.url(forResource: "background-media", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            let traceSource = tracing ? "globalThis.__vortexMediaTrace = value => window.webkit.messageHandlers.vortexMediaTrace.postMessage(value);\n" : ""
            let backgroundSource = "// Vortex background media\n" + traceSource + script + "\n" + configurationScript
            controller.addUserScript(WKUserScript(source: backgroundSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            webView.evaluateJavaScript(backgroundSource, completionHandler: nil)
        } else {
            assertionFailure("Background playback support could not be loaded.")
        }
        // Existing documents are updated without navigation or interrupting the player.
        webView.evaluateJavaScript(Self.monitorScript(), in: nil, in: .defaultClient, completionHandler: nil)
    }

    private var configurationScript: String {
        "globalThis.__vortexBackgroundMedia?.setEnabled(true);"
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if tracing, message.name == Self.traceHandlerName {
            recordTrace(message)
            return
        }
        if message.name == Self.resumeHandlerName {
            guard let webView = message.webView,
                  let entry = entries[ObjectIdentifier(webView)],
                  UIApplication.shared.applicationState != .active,
                  entry.playing || Date().timeIntervalSince(entry.lastPlaybackAt) < 4,
                  Date().timeIntervalSince(entry.lastResumeAt) > 1 else { return }
            entry.lastResumeAt = Date()
            // WebKit's public app-initiated evaluation supplies the playback gesture context.
            // The page function also rechecks the exact paused element and transition deadline.
            webView.evaluateJavaScript("globalThis.__vortexBackgroundMedia?.resumeAfterPermissionRejection();",
                                       in: message.frameInfo, in: .page, completionHandler: nil)
            return
        }
        guard message.name == Self.handlerName,
              let webView = message.webView,
              let entry = entries[ObjectIdentifier(webView)],
              let body = message.body as? [String: Bool] else { return }
        entry.pictureInPicture = body["pip"] == true
        // Also update existing iframe players when they next emit a media event.
        webView.evaluateJavaScript(configurationScript, in: message.frameInfo, in: .page, completionHandler: nil)
        entry.revision += 1
        let revision = entry.revision
        // Observe WebKit's player without activating or deactivating a competing app audio session.
        webView.requestMediaPlaybackState { [weak self, weak webView, weak entry] state in
            guard let self, let webView, let entry,
                  self.entries[ObjectIdentifier(webView)] === entry,
                  revision == entry.revision else { return }
            let wasPlaying = entry.playing
            entry.playing = state == .playing || (wasPlaying && body["playing"] == true)
            if entry.playing || wasPlaying { entry.lastPlaybackAt = Date() }
            entry.tab?.recordMediaPlaybackState(entry.playing)
        }
    }

    private func recordTrace(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        // Opt-in local diagnostic capture: timings/state only, never URLs, titles or page text.
        let allowed = Set(["event", "time", "paused", "visibility", "enabled", "explicit", "attempted", "error", "inputAge", "mode"])
        var record = body.filter { allowed.contains($0.key) }
        record = record.mapValues { value in
            if let string = value as? String { return String(string.prefix(80)) }
            return value is NSNumber ? value : "invalid"
        }
        record["appState"] = UIApplication.shared.applicationState.rawValue
        record["timestamp"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys),
              let line = String(data: data, encoding: .utf8) else { return }
        traceLines.append(line)
        if traceLines.count > 250 { traceLines.removeFirst(traceLines.count - 250) }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("vortex-media-trace.jsonl")
        try? traceLines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func monitorScript() -> String {
        """
        (() => {
            if (globalThis.__vortexMediaMonitor) {
                globalThis.__vortexMediaMonitor.report();
                return;
            }
            const state = { report: null };
            state.report = () => {
                const media = [...document.querySelectorAll('video,audio')];
                const playing = media.some(m => !m.paused && !m.ended && !m.muted && m.volume > 0);
                const pip = !!document.pictureInPictureElement || media.some(m => m.webkitPresentationMode === 'picture-in-picture');
                window.webkit.messageHandlers.vortexMediaPlayback.postMessage({playing, pip});
            };
            globalThis.__vortexMediaMonitor = state;
            for (const event of ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange',
                                 'enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged']) {
                document.addEventListener(event, state.report, true);
            }
            document.addEventListener('DOMContentLoaded', state.report, {once: true});
            state.report();
        })();
        """
    }
}
