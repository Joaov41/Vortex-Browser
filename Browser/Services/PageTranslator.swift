import Foundation
import NaturalLanguage
import Translation
import WebKit

/// Translates a page in place with Apple's on-device Translation framework. Text never
/// leaves the device. The page's text nodes are collected from the app's own content
/// world, translated in batches, and written back; "Show Original" restores them.
@MainActor
enum PageTranslator {
    struct Segment {
        let id: Int
        let leading: String
        let text: String
        let trailing: String
        /// Lower comes first: text on screen, then below it, then above, then hidden.
        let priority: Double
    }

    enum PreparationError: Error {
        case noText
        case alreadyInTargetLanguage(String)
        case unsupported(from: String, to: String)
    }

    struct Plan {
        let source: Locale.Language
        let target: Locale.Language
        let sourceName: String
        let segments: [Segment]
        /// The faster model is used only when it's already on the device; asking iOS
        /// to fetch it failed with an internal error on iPadOS 26.
        let lowLatencyInstalled: Bool
    }

    static var targetLanguage: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    static func displayName(for language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Collects the page's text and works out which language to translate from.
    static func prepare(in webView: WKWebView) async throws -> Plan {
        let segments = await collectSegments(in: webView, onlyNew: false)
        guard !segments.isEmpty else { throw PreparationError.noText }

        let sample = segments.lazy.map(\.text).joined(separator: " ").prefix(4000)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample))
        guard let dominant = recognizer.dominantLanguage else { throw PreparationError.noText }

        let source = Locale.Language(identifier: dominant.rawValue)
        var target = targetLanguage
        let sourceName = displayName(for: source)
        if source.languageCode == target.languageCode {
            throw PreparationError.alreadyInTargetLanguage(displayName(for: target))
        }
        let availability = LanguageAvailability()
        if await availability.status(from: source, to: target) == .unsupported {
            // A regional preference (say Portuguese, Portugal) may not be a translation
            // target even when the base language is.
            guard let code = target.languageCode else {
                throw PreparationError.unsupported(from: sourceName, to: displayName(for: target))
            }
            let base = Locale.Language(languageCode: code)
            guard await availability.status(from: source, to: base) != .unsupported else {
                throw PreparationError.unsupported(from: sourceName, to: displayName(for: target))
            }
            target = base
        }
        var lowLatencyInstalled = false
        if #available(iOS 26.4, *) {
            lowLatencyInstalled = await LanguageAvailability(preferredStrategy: .lowLatency)
                .status(from: source, to: target) == .installed
        }
        return Plan(
            source: source,
            target: target,
            sourceName: sourceName,
            segments: segments,
            lowLatencyInstalled: lowLatencyInstalled
        )
    }

    /// Translates what's on screen first and streams each result into the page as soon
    /// as it's ready. Identical strings (menus, "Read more") are translated once.
    /// Returns false when `shouldContinue` stopped it early.
    static func translate(
        _ segments: [Segment],
        with session: TranslationSession,
        in webView: WKWebView,
        progress: (Double) -> Void = { _ in },
        onScreenTranslated: () -> Void = {},
        shouldContinue: () -> Bool
    ) async throws -> Bool {
        var texts: [String] = []
        var segmentsByText: [String: [Segment]] = [:]
        var onScreenCount = 0
        for segment in segments.sorted(by: { $0.priority < $1.priority }) {
            if segmentsByText[segment.text] == nil {
                texts.append(segment.text)
                if segment.priority == 0 {
                    onScreenCount = texts.count
                }
            }
            segmentsByText[segment.text, default: []].append(segment)
        }
        var translated = 0
        var reportedOnScreen = false
        func reportOnScreenIfDone() {
            guard !reportedOnScreen, translated >= onScreenCount else { return }
            reportedOnScreen = true
            onScreenTranslated()
        }

        var pending: [[Any]] = []
        var lastFlush = ContinuousClock.now

        func flush() async {
            guard !pending.isEmpty else { return }
            let updates = pending
            pending = []
            lastFlush = .now
            _ = try? await webView.callAsyncJavaScript(
                applyScript,
                arguments: ["updates": updates],
                in: nil,
                contentWorld: .defaultClient
            )
            progress(Double(translated) / Double(texts.count))
            reportOnScreenIfDone()
        }

        var start = 0
        while start < texts.count {
            guard shouldContinue() else { return false }
            // Small batches for what's on screen so it lands first and never waits
            // behind off-screen text; bigger ones for the rest of the page.
            let end = start < onScreenCount
                ? min(start + 20, onScreenCount)
                : min(start + 120, texts.count)
            let requests = (start..<end).map {
                TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0))
            }
            start = end
            for try await response in session.translate(batch: requests) {
                guard shouldContinue() else { return false }
                guard let index = response.clientIdentifier.flatMap(Int.init),
                      let matches = segmentsByText[texts[index]] else { continue }
                for segment in matches {
                    pending.append([segment.id, segment.leading + response.targetText + segment.trailing])
                }
                translated += 1
                if pending.count >= 40 || ContinuousClock.now - lastFlush > .milliseconds(200) {
                    await flush()
                }
            }
            await flush()
        }
        reportOnScreenIfDone()
        return true
    }

    /// Text the page added since the last collection (infinite scroll, expanded threads).
    static func collectNewSegments(in webView: WKWebView) async -> [Segment] {
        await collectSegments(in: webView, onlyNew: true)
    }

    static func restoreOriginal(in webView: WKWebView) {
        let script = """
        const T = window.__vortexTranslate;
        if (!T) return;
        if (T.observer) T.observer.disconnect();
        T.nodes.forEach((node, i) => { if (node && T.originals[i] != null) node.nodeValue = T.originals[i]; });
        window.__vortexTranslate = null;
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
    }

    private static func collectSegments(in webView: WKWebView, onlyNew: Bool) async -> [Segment] {
        let result = try? await webView.callAsyncJavaScript(
            collectScript,
            arguments: ["onlyNew": onlyNew],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let rows = result as? [[Any]] else { return [] }
        return rows.compactMap { row in
            guard row.count == 3,
                  let id = (row[0] as? NSNumber)?.intValue,
                  let raw = row[1] as? String,
                  let priority = (row[2] as? NSNumber)?.doubleValue else { return nil }
            let leading = String(raw.prefix(while: \.isWhitespace))
            let trailing = String(raw.reversed().prefix(while: \.isWhitespace).reversed())
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Segment(id: id, leading: leading, text: text, trailing: trailing, priority: priority)
        }
    }

    private static let collectScript = """
    const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEXTAREA", "CODE", "PRE", "KBD", "SAMP",
        "VAR", "SVG", "MATH", "TEMPLATE", "INPUT", "SELECT", "OPTION", "CANVAS", "IFRAME"]);
    let T = window.__vortexTranslate;
    if (!T) {
        T = window.__vortexTranslate = { nodes: [], originals: [], seen: new WeakSet(), pending: [] };
        T.observer = new MutationObserver(records => {
            for (const record of records) {
                for (const node of record.addedNodes) T.pending.push(node);
            }
        });
        T.observer.observe(document.body, { childList: true, subtree: true });
    } else if (!onlyNew) {
        T.pending = [];
    }

    function skipped(node) {
        for (let el = node.parentElement; el; el = el.parentElement) {
            if (SKIP.has(el.tagName) || el.isContentEditable) return true;
            if (el.getAttribute("translate") === "no" || el.classList.contains("notranslate")) return true;
        }
        return false;
    }

    const out = [];
    const viewportHeight = window.innerHeight;
    const rankByElement = new Map();
    // On-screen text first, then what's below, then above, then hidden menus.
    function rank(el) {
        if (!el) return 4e9;
        let r = rankByElement.get(el);
        if (r !== undefined) return r;
        const box = el.getBoundingClientRect();
        if (box.width === 0 && box.height === 0) r = 4e9;
        else if (box.bottom >= 0 && box.top <= viewportHeight) r = 0;
        else if (box.top > viewportHeight) r = box.top;
        else r = 2e9 - box.bottom;
        rankByElement.set(el, r);
        return r;
    }
    function collect(root) {
        if (!root) return;
        if (root.nodeType === Node.TEXT_NODE) {
            consider(root);
            return;
        }
        if (root.nodeType !== Node.ELEMENT_NODE) return;
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) consider(node);
    }
    function consider(node) {
        if (T.seen.has(node)) return;
        const value = node.nodeValue;
        if (!value || !/\\p{L}/u.test(value) || skipped(node)) return;
        T.seen.add(node);
        const id = T.nodes.length;
        T.nodes.push(node);
        T.originals.push(value);
        out.push([id, value, rank(node.parentElement)]);
    }

    if (onlyNew) {
        const roots = T.pending;
        T.pending = [];
        for (const root of roots) {
            if (root.isConnected) collect(root);
        }
    } else {
        collect(document.body);
    }
    return out;
    """

    private static let applyScript = """
    const T = window.__vortexTranslate;
    if (!T) return;
    for (const [id, text] of updates) {
        const node = T.nodes[id];
        if (node && node.nodeValue !== text) node.nodeValue = text;
    }
    """
}
