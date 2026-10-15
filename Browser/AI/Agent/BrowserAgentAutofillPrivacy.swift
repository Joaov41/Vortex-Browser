import Foundation
import WebKit

struct BrowserAgentPageContextBinding: Equatable {
    let tabID: UUID
    let webViewIdentity: ObjectIdentifier
    let urlKey: String

    init(tabID: UUID, webView: WKWebView, url: URL) {
        self.tabID = tabID
        self.webViewIdentity = ObjectIdentifier(webView)
        self.urlKey = BrowserAgentPageContextBinding.normalizedURL(url)
    }

    private static func normalizedURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }
}

@MainActor
enum BrowserAgentModelEgress {
    enum Decision: Equatable {
        case allowed(String?)
        case blocked
    }

    /// Every page-derived source must still belong to the same tab, WebView,
    /// and URL when it reaches a model boundary. Filled tabs stay withheld for
    /// their lifetime, including after a verified navigation.
    static func evaluate(
        _ text: String?,
        captured: BrowserAgentPageContextBinding?,
        current: BrowserAgentPageContextBinding?,
        privacy: BrowserAgentAutofillPrivacy
    ) -> Decision {
        guard let captured else {
            return .allowed(text.map(privacy.redactKnownValues))
        }
        guard captured == current,
              !privacy.withholdsPageData(tabID: captured.tabID) else {
            return .blocked
        }
        return .allowed(text.map(privacy.redactKnownValues))
    }
}

/// Native guard for page-derived model context after an approved profile fill.
/// While a filled document is active, all page data is blocked. After a
/// different agent-world document nonce is verified, text is still redacted
/// and screenshots stay disabled for that tab/WebView for its lifetime.
@MainActor
final class BrowserAgentAutofillPrivacy {
    static let shared = BrowserAgentAutofillPrivacy()

    struct FillBinding: Equatable {
        let fillID: UUID
        let tabID: UUID
        let webViewIdentity: ObjectIdentifier
        let runID: UUID
        let pageURL: String?
        let originalDocumentNonce: String
    }

    struct Reconciliation: Equatable {
        let fillID: UUID
        let tabID: UUID
        let webViewIdentity: ObjectIdentifier
        let originalWebViewIdentity: ObjectIdentifier
        let isReplacementWebView: Bool
        let navigationURL: String
        let originalDocumentNonce: String
    }

    private final class Record {
        weak var webView: WKWebView?
        var activeFill: FillBinding?
        var values: Set<String>
        var screenshotRestricted: Bool
        var releasedDocumentNonce: String?

        init(webView: WKWebView, values: Set<String>) {
            self.webView = webView
            self.values = values
            self.screenshotRestricted = true
        }
    }

    private struct Scope: Hashable {
        let tabID: UUID
        let webViewIdentity: ObjectIdentifier
    }

    private struct ProtectedFetchOrigin: Hashable {
        let websiteDataStoreIdentity: ObjectIdentifier
        let origin: String
    }

    private final class WeakWebsiteDataStore {
        weak var value: WKWebsiteDataStore?

        init(_ value: WKWebsiteDataStore) {
            self.value = value
        }
    }

    private var records: [UUID: (scope: Scope, record: Record)] = [:]
    /// Kept for the process lifetime so closing or hibernating a filled tab
    /// cannot make an echoed value reappear in another tab's title/history.
    private var knownValues: Set<String> = []
    /// The policy follows a store while the browser still owns it without
    /// extending the lifetime of an ephemeral/incognito store after its tabs
    /// close. Object identity is checked on every match to guard identifier reuse.
    private var protectedFetchDataStores: [ProtectedFetchOrigin: WeakWebsiteDataStore] = [:]

    @discardableResult
    func quarantineBeforeFill(
        tabID: UUID,
        webView: WKWebView,
        runID: UUID,
        pageURL: URL?,
        documentNonce: String,
        profileValues: [String: String],
        websiteDataStore: WKWebsiteDataStore? = nil
    ) -> FillBinding {
        let scope = Scope(tabID: tabID, webViewIdentity: ObjectIdentifier(webView))
        let record = records[tabID]?.record ?? Record(webView: webView, values: [])
        record.webView = webView
        record.values.formUnion(profileValues.values.filter { !$0.isEmpty })
        knownValues.formUnion(profileValues.values.filter { !$0.isEmpty })
        let binding = FillBinding(
            fillID: UUID(),
            tabID: tabID,
            webViewIdentity: ObjectIdentifier(webView),
            runID: runID,
            pageURL: pageURL?.absoluteString,
            originalDocumentNonce: documentNonce
        )
        record.activeFill = binding
        record.releasedDocumentNonce = nil
        records[tabID] = (scope, record)
        if let websiteDataStore, let pageURL, let origin = Self.httpOrigin(pageURL) {
            protectedFetchDataStores = protectedFetchDataStores.filter { $0.value.value != nil }
            let key = ProtectedFetchOrigin(
                websiteDataStoreIdentity: ObjectIdentifier(websiteDataStore),
                origin: origin
            )
            protectedFetchDataStores[key] = WeakWebsiteDataStore(websiteDataStore)
        }
        return binding
    }

    func isQuarantined(tabID: UUID, webView: WKWebView) -> Bool {
        records[tabID]?.record.activeFill != nil
    }

    func isQuarantined(tabID: UUID) -> Bool {
        records[tabID]?.record.activeFill != nil
    }

    func allowsScreenshot(tabID: UUID, webView: WKWebView) -> Bool {
        records[tabID]?.record.screenshotRestricted != true
    }

    func allowsScreenshot(tabID: UUID) -> Bool {
        records[tabID]?.record.screenshotRestricted != true
    }

    func withholdsPageData(tabID: UUID) -> Bool {
        records[tabID]?.record.screenshotRestricted == true
    }

    /// The filled tab's retained profile values, longest first, so the agent
    /// content world can replace them before any page text is clipped.
    func redactionValues(tabID: UUID) -> [String] {
        guard let record = records[tabID]?.record else { return [] }
        return record.values.sorted { $0.utf8.count > $1.utf8.count }
    }

    func blocksBackgroundFetch(url: URL, startingDataStore: WKWebsiteDataStore) -> Bool {
        guard let origin = Self.httpOrigin(url) else { return false }
        protectedFetchDataStores = protectedFetchDataStores.filter { $0.value.value != nil }
        let key = ProtectedFetchOrigin(
            websiteDataStoreIdentity: ObjectIdentifier(startingDataStore),
            origin: origin
        )
        guard let protectedStore = protectedFetchDataStores[key]?.value else { return false }
        return protectedStore === startingDataStore
    }

    var hasKnownValues: Bool { !knownValues.isEmpty }

    /// Nil means the page is still quarantined. Otherwise all known raw and
    /// percent-encoded values are replaced before the text can leave native code.
    func modelText(_ text: String, tabID: UUID, webView: WKWebView) -> String? {
        guard records[tabID]?.record.activeFill == nil else { return nil }
        return Self.redact(text, values: knownValues)
    }

    func modelText(_ text: String, tabID: UUID) -> String? {
        guard records[tabID]?.record.activeFill == nil else { return nil }
        return Self.redact(text, values: knownValues)
    }

    /// Applies the retained process-local profile-value guard to tool output,
    /// tab metadata, and model context that may combine multiple tabs.
    func redactKnownValues(_ text: String) -> String {
        Self.redact(text, values: knownValues)
    }

    /// Redacts complete known values before a caller applies any character or
    /// byte cap. This prevents a clipped prefix of a profile value from
    /// escaping when the cap would otherwise split the value in half.
    func redactThenBound(_ text: String, using bound: (String) -> String) -> String {
        bound(redactKnownValues(text))
    }

    /// Removes complete profile echoes, then strips a trailing partial echo if
    /// an upstream extractor already clipped its input at a size boundary.
    func redactPotentiallyTruncated(_ text: String, wasTruncated: Bool) -> String {
        let redacted = redactKnownValues(text)
        guard wasTruncated, !knownValues.isEmpty else { return redacted }
        let variants = knownValues.flatMap(Self.encodedVariants)
        let reversedText = redacted.reversed()
        let longestTrailingMatch = variants.reduce(into: 0) { best, variant in
            let count = zip(reversedText, variant).prefix { pair in pair.0 == pair.1 }.count
            best = max(best, count)
        }
        guard longestTrailingMatch > 0 else { return redacted }
        return String(redacted.dropLast(longestTrailingMatch))
    }

    func sanitized(_ dataset: BrowserAgentDataset) -> BrowserAgentDataset {
        let links = dataset.links.map { link in
            BrowserAgentDataset.Link(
                text: redactPotentiallyTruncated(link.text, wasTruncated: dataset.wasTruncated),
                url: redactPotentiallyTruncated(link.url, wasTruncated: dataset.wasTruncated),
                title: redactPotentiallyTruncated(link.title, wasTruncated: dataset.wasTruncated)
            )
        }
        let tables = dataset.tables.map { table in
            BrowserAgentDataset.HTMLTable(
                index: table.index,
                title: redactPotentiallyTruncated(table.title, wasTruncated: table.wasTruncated),
                layoutNote: table.layoutNote.map { redactPotentiallyTruncated($0, wasTruncated: table.wasTruncated) },
                headers: table.headers.map { redactPotentiallyTruncated($0, wasTruncated: table.wasTruncated) },
                rows: table.rows.map { row in
                    row.map { redactPotentiallyTruncated($0, wasTruncated: table.wasTruncated) }
                },
                sourceRowCount: table.sourceRowCount,
                wasTruncated: table.wasTruncated
            )
        }
        let title = redactPotentiallyTruncated(dataset.title, wasTruncated: dataset.wasTruncated)
        return BrowserAgentDataset(
            id: dataset.id,
            kind: dataset.kind,
            title: title,
            pageTitle: redactPotentiallyTruncated(dataset.pageTitle, wasTruncated: dataset.wasTruncated),
            sourceURL: redactPotentiallyTruncated(dataset.sourceURL, wasTruncated: dataset.wasTruncated),
            sourceTabID: dataset.sourceTabID,
            capturedAt: dataset.capturedAt,
            wasTruncated: dataset.wasTruncated,
            truncationReasons: dataset.truncationReasons,
            links: links,
            tables: tables,
            fetchedText: dataset.fetchedText.map {
                redactPotentiallyTruncated($0, wasTruncated: dataset.wasTruncated)
            }
        )
    }

    func sanitized(_ content: PageContentExtractor.ExtractedPageContent) -> PageContentExtractor.ExtractedPageContent {
        PageContentExtractor.ExtractedPageContent(
            title: content.title.map { redactPotentiallyTruncated($0, wasTruncated: $0.count >= 300) },
            body: redactPotentiallyTruncated(content.body, wasTruncated: content.body.count >= 60_000),
            redditCommentCount: content.redditCommentCount,
            redditCoverage: content.redditCoverage
        )
    }

    func reconciliation(
        for tabID: UUID,
        webView: WKWebView,
        navigationURL: URL,
        isCurrentTabWebView: Bool = false
    ) -> Reconciliation? {
        guard let record = records[tabID]?.record,
              let binding = record.activeFill,
              (record.webView === webView || isCurrentTabWebView),
              webView.url == navigationURL else { return nil }
        return Reconciliation(
            fillID: binding.fillID,
            tabID: tabID,
            webViewIdentity: ObjectIdentifier(webView),
            originalWebViewIdentity: binding.webViewIdentity,
            isReplacementWebView: binding.webViewIdentity != ObjectIdentifier(webView),
            navigationURL: navigationURL.absoluteString,
            originalDocumentNonce: binding.originalDocumentNonce
        )
    }

    /// Clears only the exact fill that was observed before an asynchronous
    /// nonce read. A second fill, replacement WebView, or newer run makes the
    /// callback stale and leaves quarantine in place.
    @discardableResult
    func releaseAfterVerifiedNavigation(
        _ reconciliation: Reconciliation,
        tabID: UUID,
        webView: WKWebView,
        currentURL: URL?,
        documentNonce: String,
        isCurrentTabWebView: Bool = false
    ) -> Bool {
        guard reconciliation.tabID == tabID,
              reconciliation.webViewIdentity == ObjectIdentifier(webView),
              reconciliation.navigationURL == currentURL?.absoluteString,
              (!reconciliation.isReplacementWebView || isCurrentTabWebView),
              reconciliation.originalDocumentNonce != documentNonce,
              let record = records[tabID]?.record,
              (record.webView === webView || (reconciliation.isReplacementWebView && isCurrentTabWebView)),
              let active = record.activeFill,
              active.fillID == reconciliation.fillID,
              active.tabID == tabID,
              active.webViewIdentity == reconciliation.originalWebViewIdentity,
              active.pageURL != nil,
              active.originalDocumentNonce == reconciliation.originalDocumentNonce else {
            return false
        }
        record.webView = webView
        records[tabID] = (Scope(tabID: tabID, webViewIdentity: ObjectIdentifier(webView)), record)
        record.activeFill = nil
        record.releasedDocumentNonce = documentNonce
        return true
    }

    /// Reconciles a committed navigation without coupling quarantine release
    /// to an agent controller's lifetime. A per-window caller must confirm
    /// that this exact WebView still belongs to the tab both before and after
    /// the asynchronous document-identity read.
    func reconcileNavigation(
        tabID: UUID,
        webView: WKWebView,
        navigationURL: URL,
        isCurrentTabWebView: @escaping @MainActor () -> Bool
    ) {
        guard isCurrentTabWebView(), webView.url == navigationURL,
              let reconciliation = reconciliation(
                for: tabID,
                webView: webView,
                navigationURL: navigationURL,
                isCurrentTabWebView: true
              ) else { return }

        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, isCurrentTabWebView(), webView.url == navigationURL else { return }
            do {
                let json: String = try await AsyncTimeout.run(
                    seconds: 3,
                    timeoutError: { CancellationError() },
                    operation: { @MainActor in
                        let value = try await webView.callAsyncJavaScript(
                            BrowserAgentPageScript.documentIdentity,
                            arguments: [:],
                            in: nil,
                            contentWorld: BrowserAgentPageScript.world
                        )
                        return value as? String ?? "{}"
                    }
                )
                guard isCurrentTabWebView(), webView.url == navigationURL,
                      let data = json.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let nonce = object["nonce"] as? String, !nonce.isEmpty else { return }
                _ = self.releaseAfterVerifiedNavigation(
                    reconciliation,
                    tabID: tabID,
                    webView: webView,
                    currentURL: webView.url,
                    documentNonce: nonce,
                    isCurrentTabWebView: isCurrentTabWebView()
                )
            } catch {
                // A failed or timed-out identity read keeps the document protected.
            }
        }
    }

    func retainTabs(_ tabIDs: Set<UUID>) {
        records = records.filter { tabIDs.contains($0.key) }
    }

    func hasRecord(tabID: UUID) -> Bool { records[tabID] != nil }

    static func redact(_ text: String, values: some Sequence<String>) -> String {
        var result = text
        let candidates = Set(values.flatMap(encodedVariants).filter { !$0.isEmpty })
            .sorted { $0.utf8.count > $1.utf8.count }
        for value in candidates {
            result = result.replacingOccurrences(of: value, with: "[profile data redacted]")
        }
        return result
    }

    private static func encodedVariants(_ value: String) -> Set<String> {
        var variants: Set<String> = [value]
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) {
            variants.insert(encoded)
            variants.insert(encoded.replacingOccurrences(of: "%20", with: "+"))
            var lowerPercentEscapes = encoded
            if let regex = try? NSRegularExpression(pattern: "%[0-9A-F]{2}") {
                let matches = regex.matches(
                    in: encoded,
                    range: NSRange(encoded.startIndex..., in: encoded)
                )
                for match in matches.reversed() {
                    guard let range = Range(match.range, in: lowerPercentEscapes) else { continue }
                    lowerPercentEscapes.replaceSubrange(range, with: lowerPercentEscapes[range].lowercased())
                }
            }
            variants.insert(lowerPercentEscapes)
            variants.insert(lowerPercentEscapes.replacingOccurrences(of: "%20", with: "+"))
        }
        if let json = try? JSONEncoder().encode(value), json.count >= 2 {
            variants.insert(String(decoding: json.dropFirst().dropLast(), as: UTF8.self))
        }
        let htmlEncoded = value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
        if htmlEncoded != value { variants.insert(htmlEncoded) }
        return variants
    }

    private static func httpOrigin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}
