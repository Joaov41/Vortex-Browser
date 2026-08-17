import Foundation
import WebKit
import SwiftUI
import Combine

@MainActor
final class ThirdPartyCookieBlocker: NSObject, ObservableObject {
    static let shared = ThirdPartyCookieBlocker()

    // Keep the iOS 27+ WebKit content-extension path disabled. The cookie
    // pruning fallback below remains available when this setting is enabled.
    private static var nativeRuleListsSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
    }

    @AppStorage("blockThirdPartyCookies") var isEnabled: Bool = false {
        didSet {
            if isEnabled != oldValue {
                if isEnabled {
                    enableBlocking()
                } else {
                    disableBlocking()
                }
            }
        }
    }

    private var registeredWebViews: NSHashTable<WKWebView> = NSHashTable.weakObjects()
    private var webViewHosts: [ObjectIdentifier: String] = [:]
    private let contentRuleListStore: WKContentRuleListStore?
    private let ruleListIdentifier = "thirdPartyCookieBlocker"
    private var ruleList: WKContentRuleList?
    private var supportsRuleList: Bool = true

    override init() {
        self.contentRuleListStore = Self.nativeRuleListsSupported
            ? WKContentRuleListStore.default()
            : nil
        super.init()
        supportsRuleList = Self.nativeRuleListsSupported
        if isEnabled {
            enableBlocking()
        }
    }

    func register(webView: WKWebView) {
        registeredWebViews.add(webView)
        if isEnabled {
            applyRuleListIfAvailable(to: webView)
        }
    }

    func updateHost(for webView: WKWebView, url: URL?) {
        let id = ObjectIdentifier(webView)
        if let host = url?.host?.lowercased() {
            webViewHosts[id] = host
        } else {
            webViewHosts[id] = nil
        }

        guard shouldUseFallback,
              !SitePrivacyStore.shared.isCookieBlockingAllowed(for: url) else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        pruneCookies(in: store)
    }

    func setProtectionEnabled(_ enabled: Bool, for webView: WKWebView) {
        guard isEnabled else { return }
        if enabled {
            applyRuleListIfAvailable(to: webView)
            if shouldUseFallback {
                pruneCookies(in: webView.configuration.websiteDataStore.httpCookieStore)
            }
        } else if let ruleList {
            webView.configuration.userContentController.remove(ruleList)
        }
    }

    private var shouldUseFallback: Bool {
        isEnabled && !supportsRuleList
    }

    private func enableBlocking() {
        guard Self.nativeRuleListsSupported else {
            supportsRuleList = false
            pruneAllStores()
            return
        }

        if supportsRuleList {
            if let ruleList {
                applyRuleListToAll(ruleList)
            } else {
                Task {
                    await loadRuleListIfNeeded()
                    if ruleList == nil {
                        supportsRuleList = false
                        pruneAllStores()
                    }
                }
            }
        } else {
            pruneAllStores()
        }
    }

    private func disableBlocking() {
        if let ruleList {
            removeRuleListFromAll(ruleList)
        }
    }

    private func applyRuleListIfAvailable(to webView: WKWebView) {
        guard isEnabled else { return }
        guard Self.nativeRuleListsSupported else { return }
        guard let ruleList else {
            Task { await loadRuleListIfNeeded() }
            return
        }
        webView.configuration.userContentController.add(ruleList)
    }

    private func applyRuleListToAll(_ ruleList: WKContentRuleList) {
        for webView in registeredWebViews.allObjects {
            webView.configuration.userContentController.add(ruleList)
        }
    }

    private func removeRuleListFromAll(_ ruleList: WKContentRuleList) {
        for webView in registeredWebViews.allObjects {
            webView.configuration.userContentController.remove(ruleList)
        }
    }

    private func loadRuleListIfNeeded() async {
        if ruleList != nil || !supportsRuleList || !Self.nativeRuleListsSupported { return }
        do {
            if let cached = try? await lookupContentRuleListAsync(forIdentifier: ruleListIdentifier) {
                ruleList = cached
                if isEnabled, let ruleList {
                    applyRuleListToAll(ruleList)
                }
                return
            }
            let json = thirdPartyCookieRuleJSON()
            let compiled = try await compileContentRuleListAsync(
                forIdentifier: ruleListIdentifier,
                encodedContentRuleList: json
            )
            ruleList = compiled
            if let ruleList, isEnabled {
                applyRuleListToAll(ruleList)
            } else if compiled == nil {
                supportsRuleList = false
            }
        } catch {
            supportsRuleList = false
        }
    }

    private func thirdPartyCookieRuleJSON() -> String {
        let rules: [[String: Any]] = [
            [
                "trigger": [
                    "url-filter": ".*",
                    "load-type": ["third-party"]
                ],
                "action": [
                    "type": "block-cookies"
                ]
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func pruneAllStores() {
        let stores = Set(registeredWebViews.allObjects.map { $0.configuration.websiteDataStore.httpCookieStore })
        for store in stores {
            pruneCookies(in: store)
        }
    }

    private func pruneCookies(in store: WKHTTPCookieStore) {
        let allowedHosts = allowedHosts(for: store)
        guard !allowedHosts.isEmpty else { return }
        store.getAllCookies { [weak self] cookies in
            guard let self else { return }
            for cookie in cookies {
                let domain = self.normalizedCookieDomain(cookie.domain)
                if !self.isAllowed(domain: domain, allowedHosts: allowedHosts) {
                    store.delete(cookie)
                }
            }
        }
    }

    private func allowedHosts(for store: WKHTTPCookieStore) -> Set<String> {
        var hosts = Set<String>()
        for webView in registeredWebViews.allObjects {
            guard webView.configuration.websiteDataStore.httpCookieStore === store else { continue }
            let id = ObjectIdentifier(webView)
            if let host = webViewHosts[id], !host.isEmpty {
                hosts.insert(host)
            }
        }
        return hosts
    }

    private func normalizedCookieDomain(_ domain: String) -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix(".") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private func isAllowed(domain: String, allowedHosts: Set<String>) -> Bool {
        guard !domain.isEmpty else { return false }
        for host in allowedHosts {
            if host == domain { return true }
            if host.hasSuffix("." + domain) { return true }
            if domain.hasSuffix("." + host) { return true }
        }
        return false
    }

    private func lookupContentRuleListAsync(forIdentifier identifier: String) async throws -> WKContentRuleList? {
        try await withCheckedThrowingContinuation { continuation in
            guard let store = contentRuleListStore else {
                continuation.resume(returning: nil)
                return
            }
            store.lookUpContentRuleList(forIdentifier: identifier) { ruleList, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ruleList)
                }
            }
        }
    }

    private func compileContentRuleListAsync(
        forIdentifier identifier: String,
        encodedContentRuleList: String
    ) async throws -> WKContentRuleList? {
        try await withCheckedThrowingContinuation { continuation in
            guard let store = contentRuleListStore else {
                continuation.resume(returning: nil)
                return
            }
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedContentRuleList
            ) { ruleList, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ruleList)
                }
            }
        }
    }
}
