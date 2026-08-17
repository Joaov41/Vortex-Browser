import Combine
import Foundation
import WebKit

@MainActor
final class SitePrivacyStore: ObservableObject {
    static let shared = SitePrivacyStore()

    @Published private(set) var adBlockingPausedHosts: Set<String>
    @Published private(set) var cookieBlockingAllowedHosts: Set<String>

    private let adBlockingKey = "site_privacy_ad_blocking_paused_hosts_v1"
    private let cookieBlockingKey = "site_privacy_cookie_blocking_allowed_hosts_v1"

    private init() {
        adBlockingPausedHosts = Set(UserDefaults.standard.stringArray(forKey: adBlockingKey) ?? [])
        cookieBlockingAllowedHosts = Set(UserDefaults.standard.stringArray(forKey: cookieBlockingKey) ?? [])
    }

    func host(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func isAdBlockingPaused(for url: URL?) -> Bool {
        guard let host = host(for: url) else { return false }
        return matches(host, in: adBlockingPausedHosts)
    }

    func isCookieBlockingAllowed(for url: URL?) -> Bool {
        guard let host = host(for: url) else { return false }
        return matches(host, in: cookieBlockingAllowedHosts)
    }

    func setAdBlockingPaused(_ paused: Bool, for url: URL?, webView: WKWebView) {
        guard let host = host(for: url) else { return }
        update(host, included: paused, in: &adBlockingPausedHosts)
        UserDefaults.standard.set(adBlockingPausedHosts.sorted(), forKey: adBlockingKey)
        applyPolicies(to: webView, url: url, reloadIfChanged: true)
    }

    func setCookieBlockingAllowed(_ allowed: Bool, for url: URL?, webView: WKWebView) {
        guard let host = host(for: url) else { return }
        update(host, included: allowed, in: &cookieBlockingAllowedHosts)
        UserDefaults.standard.set(cookieBlockingAllowedHosts.sorted(), forKey: cookieBlockingKey)
        applyPolicies(to: webView, url: url, reloadIfChanged: true)
    }

    func applyPolicies(to webView: WKWebView, url: URL?, reloadIfChanged: Bool = false) {
        let adBlockingEnabled = !isAdBlockingPaused(for: url)
        let cookieBlockingEnabled = !isCookieBlockingAllowed(for: url)
        AdBlockService.shared.setProtectionEnabled(adBlockingEnabled, for: webView)
        ThirdPartyCookieBlocker.shared.setProtectionEnabled(cookieBlockingEnabled, for: webView)

        let value = adBlockingEnabled ? "0" : "1"
        let script = """
        (function() {
          try {
            const key = '__vortexAdBlockDisabled';
            const previous = localStorage.getItem(key);
            localStorage.setItem(key, '\(value)');
            // A normal first visit already starts with protection enabled, so it
            // should not be reloaded just to persist the default. A saved paused
            // site does need one reload so its exception takes effect from
            // document start.
            return previous !== '\(value)' && (previous !== null || '\(value)' === '1');
          } catch (_) {
            return false;
          }
        })();
        """
        webView.evaluateJavaScript(script) { changed, _ in
            guard reloadIfChanged, (changed as? Bool) == true else { return }
            Task { @MainActor in webView.reload() }
        }
    }

    private func matches(_ host: String, in set: Set<String>) -> Bool {
        set.contains { candidate in
            host == candidate || host.hasSuffix("." + candidate)
        }
    }

    private func update(_ host: String, included: Bool, in set: inout Set<String>) {
        if included {
            set.insert(host)
        } else {
            set.remove(host)
        }
    }
}
