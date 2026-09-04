import Foundation
import WebKit
import SwiftUI
import Combine

@MainActor
final class ThirdPartyCookieBlocker: NSObject, ObservableObject {
    static let shared = ThirdPartyCookieBlocker()

    // Use only verified OS/SDK combinations after the historical iOS 27 crash.
    // This does not enable the separate, larger ad-block rule-list path. There is no
    // shared-cookie-store pruning fallback: it cannot distinguish retained
    // first-party sessions from third-party cookies safely.
    private static var nativeRuleListsSupported: Bool {
        NativeCookieRuleCompatibility.isSupported
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

    @Published private(set) var isSupported: Bool

    var unavailabilityReason: String {
        if !Self.nativeRuleListsSupported {
            return "Disabled pending compatibility verification after an earlier iOS 27 WebKit crash. "
                + "Vortex does not delete saved login cookies as a workaround."
        }
        return "WebKit could not load the cookie-blocking rules. Saved login cookies have not been deleted."
    }

    private var registeredWebViews: NSHashTable<WKWebView> = NSHashTable.weakObjects()
    private let contentRuleListStore: WKContentRuleListStore?
    private let ruleListIdentifier = "thirdPartyCookieBlocker"
    private var ruleList: WKContentRuleList?
    private var isLoadingRuleList = false
    private var exemptWebViews: NSHashTable<WKWebView> = NSHashTable.weakObjects()
    private var protectedWebViews: NSHashTable<WKWebView> = NSHashTable.weakObjects()

    override init() {
        self.contentRuleListStore = Self.nativeRuleListsSupported
            ? WKContentRuleListStore.default()
            : nil
        self.isSupported = Self.nativeRuleListsSupported
        super.init()
        if !isSupported {
            isEnabled = false
        } else if isEnabled {
            enableBlocking()
        }
    }

    func register(webView: WKWebView) {
        guard !registeredWebViews.contains(webView) else { return }
        registeredWebViews.add(webView)
        if isEnabled {
            applyRuleListIfAvailable(to: webView)
        }
    }

    func setProtectionEnabled(_ enabled: Bool, for webView: WKWebView) {
        if enabled {
            exemptWebViews.remove(webView)
        } else {
            exemptWebViews.add(webView)
        }
        if enabled && isEnabled && isSupported {
            applyRuleListIfAvailable(to: webView)
        } else if let ruleList {
            webView.configuration.userContentController.remove(ruleList)
            protectedWebViews.remove(webView)
        }
    }

    private func enableBlocking() {
        guard isSupported else {
            isEnabled = false
            return
        }

        if let ruleList {
            applyRuleListToAll(ruleList)
        } else {
            Task { await loadRuleListIfNeeded() }
        }
    }

    private func disableBlocking() {
        if let ruleList {
            removeRuleListFromAll(ruleList)
        }
    }

    private func applyRuleListIfAvailable(to webView: WKWebView) {
        guard isEnabled, isSupported, !exemptWebViews.contains(webView) else { return }
        guard let ruleList else {
            Task { await loadRuleListIfNeeded() }
            return
        }
        guard !protectedWebViews.contains(webView) else { return }
        webView.configuration.userContentController.add(ruleList)
        protectedWebViews.add(webView)
    }

    private func applyRuleListToAll(_ ruleList: WKContentRuleList) {
        for webView in registeredWebViews.allObjects {
            applyRuleListIfAvailable(to: webView)
        }
    }

    private func removeRuleListFromAll(_ ruleList: WKContentRuleList) {
        for webView in registeredWebViews.allObjects {
            webView.configuration.userContentController.remove(ruleList)
        }
        protectedWebViews.removeAllObjects()
    }

    private func loadRuleListIfNeeded() async {
        if ruleList != nil || !isSupported || isLoadingRuleList { return }
        isLoadingRuleList = true
        defer { isLoadingRuleList = false }
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
                markUnsupported()
            }
        } catch {
            markUnsupported()
        }
    }

    private func markUnsupported() {
        isSupported = false
        isEnabled = false
        if let ruleList {
            removeRuleListFromAll(ruleList)
        }
        ruleList = nil
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
