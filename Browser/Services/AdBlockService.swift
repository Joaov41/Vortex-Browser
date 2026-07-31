import WebKit
import SwiftUI
import Combine
import CryptoKit

// MARK: - Filter List Model
struct FilterList: Codable, Identifiable {
    var id: String { url }
    let name: String
    let url: String
    var isEnabled: Bool
    var lastUpdated: Date?
    var ruleCount: Int

    static let defaultLists: [FilterList] = [
        FilterList(name: "EasyList", url: "https://easylist.to/easylist/easylist.txt", isEnabled: true, lastUpdated: nil, ruleCount: 0),
        FilterList(name: "EasyPrivacy", url: "https://easylist.to/easylist/easyprivacy.txt", isEnabled: false, lastUpdated: nil, ruleCount: 0),
        FilterList(name: "Fanboy's Annoyance", url: "https://easylist.to/easylist/fanboy-annoyance.txt", isEnabled: false, lastUpdated: nil, ruleCount: 0)
    ]
}

@MainActor
class AdBlockService: NSObject, ObservableObject {
    static let shared = AdBlockService()

    // iOS 27 currently crashes inside WebKit while initializing or tearing down
    // native content-extension rule trees. Keep the JavaScript blocker enabled
    // there until that WebKit path is safe to use again.
    private static var nativeContentRuleListsSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
    }

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "adBlockEnabled")
            if isEnabled != oldValue {
                updateContentBlockingRules()
            }
        }
    }

    @Published var blockedCount: Int = 0
    @Published var filterLists: [FilterList] = []
    @Published var isUpdatingFilters: Bool = false
    @Published var customRules: [String] = []
    @Published private(set) var isReady: Bool = false

    // Cosmetic selectors parsed from filter lists (## rules)
    private var cosmeticSelectors: [String] = []

    // Cached JavaScript needs regeneration when cosmetic selectors change
    private var cachedBlockingJavaScriptStorage: String?

    private let contentRuleListStore: WKContentRuleListStore?
    private var activeRuleList: WKContentRuleList?
    private var customRuleList: WKContentRuleList?
    private var registeredWebViews: NSHashTable<WKWebView> = NSHashTable.weakObjects()
    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let ruleCacheDirectoryURL: URL
    private let maxStoredNetworkRules = 5_000
    private let maxStoredCosmeticRules = 3_000
    private let maxRuleCacheFileBytes = 1_500_000

    // Cached JavaScript - regenerated when cosmetic selectors change
    private var cachedBlockingJavaScript: String {
        if let cached = cachedBlockingJavaScriptStorage {
            return cached
        }
        let js = generateBlockingJavaScript()
        cachedBlockingJavaScriptStorage = js
        return js
    }

    // MARK: - Comprehensive Ad Network Domains
    private let adNetworkDomains: [String] = [
        // Google Ads
        "doubleclick.net",
        "googlesyndication.com",
        "googletagmanager.com",
        "google-analytics.com",
        "googleadservices.com",
        "googletagservices.com",
        "googleads.g.doubleclick.net",
        "pagead2.googlesyndication.com",
        "adservice.google.com",

        // Facebook/Meta
        "facebook.com/tr",
        "facebook.net/signals",
        "connect.facebook.net/en_US/fbevents",
        "pixel.facebook.com",

        // Amazon
        "amazon-adsystem.com",
        "adsystem.amazon",
        "aax.amazon",
        "assoc-amazon.com",

        // Twitter/X
        "twitter.com/i/adsct",
        "ads-twitter.com",
        "analytics.twitter.com",

        // Pinterest
        "widgets.pinterest.com",
        "ct.pinterest.com",
        "analytics.pinterest.com",

        // Microsoft
        "ads.microsoft.com",
        "bat.bing.com",

        // Major Ad Networks
        "adnxs.com",           // AppNexus
        "criteo.com",
        "criteo.net",
        "pubmatic.com",
        "rubiconproject.com",
        "openx.net",
        "casalemedia.com",
        "contextweb.com",
        "advertising.com",
        "adform.net",
        "adsrvr.org",          // The Trade Desk
        "bidswitch.net",
        "indexww.com",
        "liadm.com",           // LiveIntent
        "lijit.com",
        "mathtag.com",
        "mediamath.com",
        "mookie1.com",
        "moatads.com",
        "smartadserver.com",
        "smaato.net",
        "spotxchange.com",
        "springserve.com",
        "teads.tv",
        "tribalfusion.com",
        "turn.com",
        "undertone.com",
        "yieldmo.com",
        "zedo.com",

        // Content Recommendation (Chumboxes)
        "outbrain.com",
        "taboola.com",
        "revcontent.com",
        "mgid.com",
        "content.ad",
        "zergnet.com",
        "yahoo.com/gemini",

        // Analytics & Tracking
        "scorecardresearch.com",
        "quantserve.com",
        "quantcast.com",
        "bluekai.com",
        "exelator.com",
        "krxd.net",            // Krux/Salesforce DMP
        "rlcdn.com",           // Rapleaf
        "acuityplatform.com",
        "adroll.com",
        "adsymptotic.com",
        "agkn.com",
        "atdmt.com",
        "bkrtx.com",
        "bounceexchange.com",
        "brealtime.com",
        "chartbeat.com",
        "clicktale.net",
        "demdex.net",          // Adobe Audience Manager
        "dotomi.com",
        "efficientfrontier.com",
        "eloqua.com",
        "everesttech.net",
        "exoclick.com",
        "eyeota.net",
        "hotjar.com",
        "hubspot.com/tracking",
        "intercom.io/widget",
        "keen.io",
        "kissmetrics.com",
        "kxcdn.com",
        "marketo.com",
        "mixpanel.com",
        "mxpnl.com",
        "newrelic.com",
        "nr-data.net",
        "omtrdc.net",
        "onetrust.com",
        "optimizely.com",
        "pardot.com",
        "pippio.com",
        "px.ads.linkedin.com",
        "rfihub.com",
        "segment.com",
        "segment.io",
        "sharethis.com",
        "siftscience.com",
        "tapad.com",
        "tidaltv.com",
        "trafficjunky.com",
        "tru.am",
        "truoptik.com",
        "userreport.com",
        "visualwebsiteoptimizer.com",
        "vwo.com",
        "weborama.com",
        "zenaps.com",

        // Reddit-specific (only ad endpoints, not navigation)
        "redditmedia.com/ads",
        "reddit.com/api/v2/ad",

        // Video Ad Networks
        "innovid.com",
        "serving-sys.com",
        "yume.com",
        "telaria.com",
        "freewheel.tv",
        "fwmrm.net",

        // Error Trackers
        "bugsnag.com",
        "notify.bugsnag.com",
        "sentry.io",
        "browser.sentry-cdn.com",
        "ingest.sentry.io",

        // Freshmarketer
        "freshmarketer.com",
        "frstre.com",

        // Yandex
        "mc.yandex.ru",
        "metrika.yandex.ru",
        "yandex.com",
        "yandex.net",

        // Social Trackers
        "mix.com",
        "graph.facebook.com",
        "connect.facebook.net",
        "t.co",
        "platform.twitter.com",
        "syndication.twitter.com",

        // OEM Trackers (Xiaomi)
        "tracking.miui.com",
        "data.mistat.xiaomi.com",

        // OEM Trackers (Huawei)
        "metrics.data.hicloud.com",
        "logservice.hicloud.com",

        // OEM Trackers (Samsung)
        "samsungads.com",
        "samsungacr.com",
        "config.samsungads.com",
        "analytics.samsungknox.com",

        // Additional Amazon
        "aax.amazon-adsystem.com",
        "aax-us-east.amazon-adsystem.com",
        "fls-na.amazon-adsystem.com",
        "s.amazon-adsystem.com",
        "z-na.amazon-adsystem.com",
        "mads.amazon.com",
        "aaxads.com",

        // Additional Facebook/Meta
        "an.facebook.com",
        "staticxx.facebook.com",
        "web.facebook.com",
        "pixel.facebook.com",
        "www.facebook.com/tr",

        // Additional Twitter/X
        "ads.twitter.com",
        "api.twitter.com",
        "static.ads-twitter.com",
        "analytics.twitter.com",

        // Additional Sentry
        "o0.ingest.sentry.io",
        "sentry-cdn.com",
        "cdn.sentry.io",
        "app.getsentry.com",
        "getsentry.com",

        // TikTok/ByteDance
        "ads.tiktok.com",
        "ads-api.tiktok.com",
        "analytics.tiktok.com",
        "ads-sg.tiktok.com",
        "analytics-sg.tiktok.com",
        "business-api.tiktok.com",
        "log.byteoversea.com",
        "byteoversea.com",

        // Yahoo additional
        "udcm.yahoo.com",
        "log.fc.yahoo.com",
        "ads.yahoo.com",
        "analytics.yahoo.com",

        // Yandex additional
        "appmetrica.yandex.ru",
        "appmetrica.yandex.com",

        // Xiaomi regional
        "data.mistat.india.xiaomi.com",
        "data.mistat.rus.xiaomi.com",
        "data.mistat.intl.xiaomi.com",

        // Huawei additional
        "metrics2.data.hicloud.com",
        "grs.hicloud.com",
        "logservice1.hicloud.com",
        "logbak.hicloud.com",
        "hicloud.com",

        // Samsung Health
        "analytics-api.samsunghealthcn.com",
        "samsunghealthcn.com",

        // Google Ads scripts (ads.js, pagead.js)
        "pagead2.googlesyndication.com",
        "adservice.google.com",
        "www.googleadservices.com",
        "partner.googleadservices.com"
    ]

    // MARK: - Comprehensive CSS Selectors
    private let adSelectors: [String] = [
        // Google Ads
        "[id*=\"google_ads\"]",
        "[id*=\"googleads\"]",
        "[class*=\"google-ads\"]",
        "[class*=\"googleads\"]",
        "iframe[src*=\"doubleclick\"]",
        "iframe[src*=\"googlesyndication\"]",
        "iframe[id^=\"google_ads\"]",
        "div.GoogleActiveViewInnerContainer",
        "div[data-google-query-id]",
        "ins.adsbygoogle",

        // Generic Ad Containers
        "[id*=\"ad-container\"]",
        "[class*=\"ad-container\"]",
        "[id*=\"advertisement\"]",
        "[class*=\"advertisement\"]",
        "[id*=\"ad-wrapper\"]",
        "[class*=\"ad-wrapper\"]",
        "[id*=\"ad-slot\"]",
        "[class*=\"ad-slot\"]",
        "[id*=\"adunit\"]",
        "[class*=\"adunit\"]",
        "[id*=\"ad-unit\"]",
        "[class*=\"ad-unit\"]",
        "[id*=\"adbox\"]",
        "[class*=\"adbox\"]",
        "[id*=\"ad-box\"]",
        "[class*=\"ad-box\"]",
        "[data-ad]",
        "[data-ad-slot]",
        "[data-ad-client]",
        "[data-adunit]",
        "[data-advertisement]",

        // Sidebar Ads
        ".sidebar-ad",
        ".side-ad",
        ".sidebar-advertisement",
        "#sidebar-ad",
        "#side-ad",
        ".ad-sidebar",
        ".widget_ads",
        ".widget-ads",

        // Banner Ads
        ".ad-banner",
        ".banner-ad",
        ".top-banner-ad",
        ".bottom-banner-ad",
        ".leaderboard-ad",
        "#banner-ad",
        "#top-ad",
        "#bottom-ad",
        ".header-ad",
        ".footer-ad",

        // Inline/Content Ads
        ".in-article-ad",
        ".inline-ad",
        ".content-ad",
        ".mid-content-ad",
        ".article-ad",
        ".post-ad",
        ".native-ad",
        "[class*=\"native-ad\"]",
        "[class*=\"sponsored-content\"]",
        "[class*=\"sponsored-post\"]",

        // Popup/Modal Ads
        ".ad-modal",
        ".ad-popup",
        ".popup-ad",
        ".interstitial-ad",
        ".overlay-ad",

        // Taboola/Outbrain
        ".taboola",
        ".trc_rbox",
        ".trc_related_container",
        "#taboola-below-article",
        ".OUTBRAIN",
        ".ob-widget",
        ".outbrain-container",

        // Reddit-specific
        "div[data-testid=\"promoted-post\"]",
        "div[data-promoted=\"true\"]",
        "div[id*=\"promoted\"]",
        "div[data-before-content=\"promoted\"]",
        "div.promotedlink",
        "div.promoted",
        "article[data-promoted=\"true\"]",
        "shreddit-ad-post",
        "[is-ads=\"true\"]",
        "div[data-testid=\"premium-banner\"]",
        "div.premium-banner-outer",
        ".promotedlink",
        ".promoted-post",

        // Social Widgets (optional - can be intrusive)
        ".fb-like",
        ".twitter-share",
        ".social-share-ads",

        // Cookie/Consent Banners (optional)
        ".cookie-banner",
        ".cookie-notice",
        ".cookie-consent",
        "#cookie-banner",
        "#cookie-notice",
        ".gdpr-banner",
        ".consent-banner",

        // Newsletter/Subscription Popups
        ".newsletter-popup",
        ".subscribe-popup",
        ".email-capture",
        ".email-popup"
    ]

    override init() {
        self.contentRuleListStore = Self.nativeContentRuleListsSupported
            ? WKContentRuleListStore.default()
            : nil
        self.ruleCacheDirectoryURL = Self.makeRuleCacheDirectoryURL()
        let savedValue = UserDefaults.standard.object(forKey: "adBlockEnabled") as? Bool
        self.isEnabled = savedValue ?? true
        super.init()
        if savedValue == nil {
            UserDefaults.standard.set(true, forKey: "adBlockEnabled")
        }
        loadFilterLists()
        prepareRuleCacheStorage()
        pruneOversizedRuleCaches()
        loadCustomRules()
        // Heavy work (downloads + rule compilation) deferred to prepareAsync()
    }

    /// Call this after the app UI is ready to start downloading filters and compiling rules.
    /// This prevents blocking app startup with network requests and CPU-intensive operations.
    func prepareAsync() {
        guard !isReady else { return }
        Task {
            guard Self.nativeContentRuleListsSupported else {
                // Native rules are intentionally bypassed on iOS 27+.
                // The hardcoded JavaScript blocker remains active in each web view.
                isReady = true
                return
            }
            await downloadMissingFilterLists()
            await loadContentBlockingRules()
            isReady = true
        }
    }

    private static func makeRuleCacheDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL.appendingPathComponent("AdBlockRuleCache", isDirectory: true)
    }

    private func prepareRuleCacheStorage() {
        do {
            try fileManager.createDirectory(at: ruleCacheDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("Failed to create AdBlock cache directory: \(error.localizedDescription)")
        }
        migrateLegacyRuleCachesFromDefaults()
    }

    private enum RuleCacheKind: String {
        case network
        case cosmetic
    }

    private func stableCacheID(for list: FilterList) -> String {
        let input = Data(list.url.utf8)
        let hash = SHA256.hash(data: input)
        return hash.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private func legacyRuleCacheKey(for list: FilterList, kind: RuleCacheKind) -> String {
        switch kind {
        case .network:
            return "filterRules_\(list.url.hashValue)"
        case .cosmetic:
            return "cosmeticRules_\(list.url.hashValue)"
        }
    }

    private func ruleCacheFileURL(for list: FilterList, kind: RuleCacheKind) -> URL {
        ruleCacheDirectoryURL.appendingPathComponent("\(kind.rawValue)_\(stableCacheID(for: list)).json")
    }

    private func migrateLegacyRuleCachesFromDefaults() {
        for list in filterLists {
            for kind in [RuleCacheKind.network, .cosmetic] {
                let legacyKey = legacyRuleCacheKey(for: list, kind: kind)
                if let cached = defaults.stringArray(forKey: legacyKey) {
                    storeRuleCache(cached, for: list, kind: kind)
                }
            }
        }

        for (key, _) in defaults.dictionaryRepresentation() {
            if key.hasPrefix("filterRules_") || key.hasPrefix("cosmeticRules_") {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func loadRuleCache(for list: FilterList, kind: RuleCacheKind) -> [String]? {
        let url = ruleCacheFileURL(for: list, kind: kind)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if data.count > maxRuleCacheFileBytes {
            try? fileManager.removeItem(at: url)
            return nil
        }
        guard let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        switch kind {
        case .network:
            return Array(decoded.prefix(maxStoredNetworkRules))
        case .cosmetic:
            return Array(decoded.prefix(maxStoredCosmeticRules))
        }
    }

    private func storeRuleCache(_ rules: [String], for list: FilterList, kind: RuleCacheKind) {
        let limited: [String]
        switch kind {
        case .network:
            limited = Array(rules.prefix(maxStoredNetworkRules))
        case .cosmetic:
            limited = Array(rules.prefix(maxStoredCosmeticRules))
        }
        guard let data = try? JSONEncoder().encode(limited) else { return }
        guard data.count <= maxRuleCacheFileBytes else {
            print("Skipping oversized \(kind.rawValue) cache (\(data.count) bytes)")
            return
        }
        let url = ruleCacheFileURL(for: list, kind: kind)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to store \(kind.rawValue) cache: \(error.localizedDescription)")
        }
    }

    private func removeRuleCaches(for list: FilterList) {
        try? fileManager.removeItem(at: ruleCacheFileURL(for: list, kind: .network))
        try? fileManager.removeItem(at: ruleCacheFileURL(for: list, kind: .cosmetic))
        defaults.removeObject(forKey: legacyRuleCacheKey(for: list, kind: .network))
        defaults.removeObject(forKey: legacyRuleCacheKey(for: list, kind: .cosmetic))
    }

    private func downloadMissingFilterLists() async {
        for list in filterLists where list.isEnabled {
            let cachedRules = loadRuleCache(for: list, kind: .network)
            if cachedRules == nil || cachedRules?.isEmpty == true {
                await updateFilterList(list)
            }
        }
    }

    // MARK: - Filter List Management

    private func loadFilterLists() {
        if let data = UserDefaults.standard.data(forKey: "filterLists"),
           let lists = try? JSONDecoder().decode([FilterList].self, from: data) {
            filterLists = lists
        } else {
            filterLists = FilterList.defaultLists
            saveFilterLists()
        }
    }

    private func saveFilterLists() {
        if let data = try? JSONEncoder().encode(filterLists) {
            UserDefaults.standard.set(data, forKey: "filterLists")
        }
    }

    private func loadCustomRules() {
        customRules = UserDefaults.standard.stringArray(forKey: "customAdBlockRules") ?? []
    }

    private func saveCustomRules() {
        UserDefaults.standard.set(customRules, forKey: "customAdBlockRules")
    }

    func addCustomRule(_ rule: String) {
        guard !rule.isEmpty && !customRules.contains(rule) else { return }
        customRules.append(rule)
        saveCustomRules()
        Task {
            await compileCustomRules()
        }
    }

    func removeCustomRule(_ rule: String) {
        customRules.removeAll { $0 == rule }
        saveCustomRules()
        Task {
            await compileCustomRules()
        }
    }

    func toggleFilterList(_ list: FilterList) {
        if let index = filterLists.firstIndex(where: { $0.id == list.id }) {
            filterLists[index].isEnabled.toggle()
            saveFilterLists()
            // Invalidate JavaScript cache since cosmetic selectors may have changed
            cachedBlockingJavaScriptStorage = nil
            updateContentBlockingRules()
        }
    }

    func addFilterList(name: String, url: String) {
        let newList = FilterList(name: name, url: url, isEnabled: true, lastUpdated: nil, ruleCount: 0)
        filterLists.append(newList)
        saveFilterLists()
        Task {
            await updateFilterList(newList)
        }
    }

    func removeFilterList(_ list: FilterList) {
        filterLists.removeAll { $0.id == list.id }
        saveFilterLists()
        // Remove cached rules (both network and cosmetic)
        removeRuleCaches(for: list)
        // Invalidate JavaScript cache
        cachedBlockingJavaScriptStorage = nil
        updateContentBlockingRules()
    }

    func updateAllFilterLists() async {
        isUpdatingFilters = true
        for list in filterLists where list.isEnabled {
            await updateFilterList(list)
        }
        isUpdatingFilters = false
        await loadContentBlockingRules()
    }

    /// Clears all cached compiled rules and forces fresh recompilation.
    /// Use this to fix inconsistent blocking issues across devices.
    func clearCacheAndRecompile() async {
        isUpdatingFilters = true

        guard Self.nativeContentRuleListsSupported,
              let contentRuleListStore else {
            cachedBlockingJavaScriptStorage = nil
            isUpdatingFilters = false
            return
        }

        // 1. Clear WebKit website data cache (important: removes cached ad content)
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeFetchCache
        ]
        await dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast)
        print("DEBUG: Cleared WebKit cache")

        // 2. Clear the hash cache to force recompilation
        UserDefaults.standard.removeObject(forKey: "lastCompiledRulesHash")

        // 3. Remove compiled rules from WKContentRuleListStore
        do {
            try await contentRuleListStore.removeContentRuleList(forIdentifier: "adBlockRules")
        } catch {
            print("Failed to remove adBlockRules: \(error)")
        }
        do {
            try await contentRuleListStore.removeContentRuleList(forIdentifier: "customAdBlockRules")
        } catch {
            print("Failed to remove customAdBlockRules: \(error)")
        }

        // 4. Clear JavaScript cache
        cachedBlockingJavaScriptStorage = nil

        // 5. Clear active rule lists
        activeRuleList = nil
        customRuleList = nil

        // 6. Recompile everything fresh
        await loadContentBlockingRules()
        await compileCustomRules()

        // 7. Re-configure all registered WebViews with new rules
        await MainActor.run {
            for webView in registeredWebViews.allObjects {
                // Remove old rules
                webView.configuration.userContentController.removeAllContentRuleLists()

                // Add new rules
                if let ruleList = activeRuleList {
                    webView.configuration.userContentController.add(ruleList)
                }
                if let customList = customRuleList {
                    webView.configuration.userContentController.add(customList)
                }
            }
        }

        isUpdatingFilters = false
        print("DEBUG: Cache cleared and rules recompiled successfully")
    }

    private func updateFilterList(_ list: FilterList) async {
        guard let url = URL(string: list.url) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let content = String(data: data, encoding: .utf8) {
                let parsed = parseFilterList(content)
                storeRuleCache(parsed.networkRules, for: list, kind: .network)
                storeRuleCache(parsed.cosmeticRules, for: list, kind: .cosmetic)

                // Update list metadata
                if let index = filterLists.firstIndex(where: { $0.id == list.id }) {
                    filterLists[index].lastUpdated = Date()
                    filterLists[index].ruleCount = parsed.networkRules.count + parsed.cosmeticRules.count
                    saveFilterLists()
                }

                // Invalidate JavaScript cache since cosmetic rules changed
                cachedBlockingJavaScriptStorage = nil
            }
        } catch {
            print("Failed to update filter list \(list.name): \(error)")
        }
    }

    private func parseFilterList(_ content: String) -> (networkRules: [String], cosmeticRules: [String]) {
        // Parse EasyList/AdBlock Plus format filter lists
        var networkRules: [String] = []
        var cosmeticRules: [String] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and metadata
            if trimmed.isEmpty || trimmed.hasPrefix("!") || trimmed.hasPrefix("[") {
                continue
            }

            // Skip exception rules (@@) and cosmetic exception rules (#@#)
            if trimmed.hasPrefix("@@") || trimmed.contains("#@#") {
                continue
            }

            // Extract cosmetic (element hiding) rules
            if let selector = extractCosmeticSelector(trimmed) {
                cosmeticRules.append(selector)
                continue
            }

            // Convert network rules to regex pattern
            if let pattern = convertToRegex(trimmed) {
                networkRules.append(pattern)
            }
        }

        return (networkRules, cosmeticRules)
    }

    private func extractCosmeticSelector(_ rule: String) -> String? {
        // Handle generic cosmetic rules: ##selector
        if let range = rule.range(of: "##") {
            // Skip domain-specific rules for now (domain##selector) to keep it simple
            // We only want generic ## rules that apply everywhere
            let beforeHash = rule[..<range.lowerBound]
            if beforeHash.isEmpty {
                // Generic rule like ##.ad-container
                let selector = String(rule[range.upperBound...])
                return validateAndCleanSelector(selector)
            }
            // Domain-specific rules (e.g., example.com##.ad) - skip for now
            // These would require domain matching logic
            return nil
        }
        return nil
    }

    private func validateAndCleanSelector(_ selector: String) -> String? {
        let trimmed = selector.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Skip complex selectors that might cause issues
        // Skip procedural cosmetic filters (:has, :contains, :xpath, etc.)
        let unsupportedPatterns = [":has(", ":contains(", ":xpath(", ":style(", ":remove(", ":matches-css(", ":if(", ":if-not(", ":upward(", ":min-text-length("]
        for pattern in unsupportedPatterns {
            if trimmed.contains(pattern) {
                return nil
            }
        }

        // Basic validation - selector should start with valid CSS selector chars
        guard let firstChar = trimmed.first else { return nil }
        let validStarts: Set<Character> = [".", "#", "[", "*", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]
        guard validStarts.contains(firstChar) else { return nil }

        // Escape characters that could break JavaScript strings
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")

        return escaped
    }

    private func convertToRegex(_ rule: String) -> String? {
        var pattern = rule

        // Handle domain anchors
        if pattern.hasPrefix("||") {
            pattern = String(pattern.dropFirst(2))
            pattern = "^https?://([^/]*\\.)?" + NSRegularExpression.escapedPattern(for: pattern)
        } else if pattern.hasPrefix("|") {
            pattern = String(pattern.dropFirst())
            pattern = "^" + NSRegularExpression.escapedPattern(for: pattern)
        } else {
            pattern = NSRegularExpression.escapedPattern(for: pattern)
        }

        // Handle wildcards
        pattern = pattern.replacingOccurrences(of: "\\*", with: ".*")

        // Handle separator
        pattern = pattern.replacingOccurrences(of: "\\^", with: "[^a-zA-Z0-9_.%-]")

        // Handle end anchor
        if pattern.hasSuffix("\\|") {
            pattern = String(pattern.dropLast(2)) + "$"
        }

        return pattern
    }

    private func compileCustomRules() async {
        guard Self.nativeContentRuleListsSupported,
              let contentRuleListStore else { return }

        // Convert custom rules to WebKit content blocker format
        var jsonRules: [[String: Any]] = []

        for rule in customRules {
            let blockRule: [String: Any] = [
                "trigger": [
                    "url-filter": rule
                ],
                "action": [
                    "type": "block"
                ]
            ]
            jsonRules.append(blockRule)
        }

        guard !jsonRules.isEmpty,
              let jsonData = try? JSONSerialization.data(withJSONObject: jsonRules),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        do {
            let ruleList = try await contentRuleListStore.compileContentRuleListAsync(
                forIdentifier: "customAdBlockRules",
                encodedContentRuleList: jsonString
            )
            customRuleList = ruleList
        } catch {
            print("Failed to compile custom rules: \(error)")
        }
    }

    func configureWebView(_ webView: WKWebView) {
        guard isEnabled else { return }

        // Track WebView so we can apply rules later if they're not ready yet
        registeredWebViews.add(webView)

        if Self.nativeContentRuleListsSupported {
            if let ruleList = activeRuleList {
                webView.configuration.userContentController.add(ruleList)
            }

            if let customList = customRuleList {
                webView.configuration.userContentController.add(customList)
            }
        }

        // Add JavaScript to block ads and trackers (cached to avoid regenerating per webview)
        let blockingScript = WKUserScript(
            source: cachedBlockingJavaScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        webView.configuration.userContentController.addUserScript(blockingScript)

        // Add message handler for blocked count
        webView.configuration.userContentController.add(self, name: "adBlockHandler")
    }

    private func generateBlockingJavaScript() -> String {
        let domainsJS = adNetworkDomains.map { "'\($0)'" }.joined(separator: ",\n                ")

        // Combine hardcoded selectors with cosmetic selectors from filter lists
        var allSelectors = adSelectors
        for list in filterLists where list.isEnabled {
            if let cachedCosmetic = loadRuleCache(for: list, kind: .cosmetic) {
                allSelectors.append(contentsOf: cachedCosmetic)
            }
        }
        // Deduplicate selectors
        let uniqueSelectors = Array(Set(allSelectors))
        let selectorsJS = uniqueSelectors.map { "'\($0)'" }.joined(separator: ",\n                    ")

        // Generate additional CSS rules from cosmetic selectors for persistent hiding
        let cosmeticCSS = uniqueSelectors
            .filter { !$0.contains(":") || $0.contains("[") } // Skip pseudo-selectors that might fail
            .prefix(2000) // Limit to avoid massive CSS
            .joined(separator: ",\n                    ")

        return """
        (function() {
            'use strict';

            let blockedCount = 0;
            let lastReportedBlockedCount = 0;
            let notifyTimer = null;
            let mutationCoalesceTimer = null;
            const mutationDebounceMs = 300;
            const safetySweepMs = 30000;
            const notifyThrottleMs = 1000;
            const blockedMarkerAttr = 'data-codex-adblocked';
            const maxDirtyRootsBeforeFullScan = 120;
            const sponsoredTexts = new Set(['sponsored', 'promoted', 'advertisement']);
            const dirtyRoots = new Set();

            // Whitelist for essential services
            const whitelist = [
                'microsoft.com',
                'microsoftonline.com',
                'office.com',
                'office365.com',
                'live.com',
                'outlook.com',
                'apple.com',
                'icloud.com',
                'reddit.com',
                'redditmedia.com',
                'redditstatic.com',
                // AI providers
                'chatgpt.com',
                'chat.openai.com',
                'openai.com',
                'gemini.google.com',
                'bard.google.com'
            ];

            function isWhitelisted(url) {
                return whitelist.some(domain => url.includes(domain));
            }

            // Comprehensive ad and tracking domains
            const blockedDomains = [
                \(domainsJS)
            ];

            // Cosmetic selectors
            const adSelectors = [
                \(selectorsJS)
            ];

            // Pre-validate selectors so one invalid rule doesn't disrupt grouped matching
            const validAdSelectors = [];
            adSelectors.forEach(selector => {
                try {
                    document.querySelector(selector);
                    validAdSelectors.push(selector);
                } catch (e) {}
            });

            // Group selectors to reduce querySelectorAll overhead while preserving fallback behavior
            const selectorGroupSize = 60;
            const selectorGroups = [];
            for (let i = 0; i < validAdSelectors.length; i += selectorGroupSize) {
                selectorGroups.push(validAdSelectors.slice(i, i + selectorGroupSize));
            }

            // Block fetch requests to ad domains
            const originalFetch = window.fetch;
            window.fetch = function(...args) {
                const url = args[0];
                if (typeof url === 'string') {
                    if (isWhitelisted(url)) {
                        return originalFetch.apply(this, args);
                    }
                    for (const domain of blockedDomains) {
                        if (url.includes(domain)) {
                            incrementBlockedCount(1);
                            return Promise.reject(new Error('Blocked by ad blocker'));
                        }
                    }
                }
                return originalFetch.apply(this, args);
            };

            // Block XMLHttpRequest to ad domains
            const originalOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                if (typeof url === 'string' && !isWhitelisted(url)) {
                    for (const domain of blockedDomains) {
                        if (url.includes(domain)) {
                            incrementBlockedCount(1);
                            throw new Error('Blocked by ad blocker');
                        }
                    }
                }
                return originalOpen.apply(this, [method, url, ...rest]);
            };

            // Block WebSocket connections to ad domains
            const OriginalWebSocket = window.WebSocket;
            window.WebSocket = function(url, protocols) {
                if (typeof url === 'string' && !isWhitelisted(url)) {
                    for (const domain of blockedDomains) {
                        if (url.includes(domain)) {
                            incrementBlockedCount(1);
                            throw new Error('Blocked by ad blocker');
                        }
                    }
                }
                return new OriginalWebSocket(url, protocols);
            };

            function flushBlockedNotification() {
                if (blockedCount === lastReportedBlockedCount) {
                    return;
                }
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.adBlockHandler) {
                    window.webkit.messageHandlers.adBlockHandler.postMessage({
                        type: 'blocked',
                        count: blockedCount
                    });
                }
                lastReportedBlockedCount = blockedCount;
            }

            function scheduleBlockedNotification() {
                if (notifyTimer !== null) {
                    return;
                }
                notifyTimer = setTimeout(() => {
                    notifyTimer = null;
                    flushBlockedNotification();
                }, notifyThrottleMs);
            }

            function incrementBlockedCount(amount) {
                blockedCount += amount;
                scheduleBlockedNotification();
            }

            function applyHiddenStyles(element) {
                element.style.setProperty('display', 'none', 'important');
                element.style.setProperty('visibility', 'hidden', 'important');
                element.style.setProperty('height', '0', 'important');
                element.style.setProperty('overflow', 'hidden', 'important');
                element.style.setProperty('pointer-events', 'none', 'important');
            }

            function markAndHide(element) {
                if (!(element instanceof Element)) {
                    return;
                }

                const alreadyBlocked = element.getAttribute(blockedMarkerAttr) === '1';
                applyHiddenStyles(element);

                if (!alreadyBlocked) {
                    element.setAttribute(blockedMarkerAttr, '1');
                    incrementBlockedCount(1);
                }
            }

            function hideBySelectorsInRoot(root) {
                const scope = root || document;

                for (const group of selectorGroups) {
                    if (!group.length) { continue; }
                    const combinedSelector = group.join(',');

                    try {
                        scope.querySelectorAll(combinedSelector).forEach(element => {
                            markAndHide(element);
                        });
                    } catch (e) {
                        // Fallback: one selector in group can still fail on some pages
                        group.forEach(selector => {
                            try {
                                scope.querySelectorAll(selector).forEach(element => {
                                    markAndHide(element);
                                });
                            } catch (e) {}
                        });
                    }
                }
            }

            function hideSponsoredTextInRoot(root) {
                const scope = root || document;
                let candidates = [];

                try {
                    candidates = scope.querySelectorAll('span, div, p');
                } catch (e) {
                    return;
                }

                candidates.forEach(el => {
                    const text = (el.textContent || '').toLowerCase().trim();
                    if (!sponsoredTexts.has(text)) {
                        return;
                    }

                    const parent = el.closest('article, [data-testid*="post"], .post, .card, li, div[class*="item"]');
                    if (parent) {
                        markAndHide(parent);
                    }
                });
            }

            function canonicalRoot(node) {
                if (!node) {
                    return document;
                }
                if (node === document || node === document.documentElement || node === document.body) {
                    return document;
                }
                if (node.nodeType === Node.ELEMENT_NODE) {
                    return node;
                }
                if (node.parentElement) {
                    return node.parentElement;
                }
                return document;
            }

            function addDirtyRoot(node) {
                const root = canonicalRoot(node);

                if (root === document) {
                    dirtyRoots.clear();
                    dirtyRoots.add(document);
                    return;
                }

                if (!(root instanceof Element) || !root.isConnected) {
                    dirtyRoots.clear();
                    dirtyRoots.add(document);
                    return;
                }

                if (dirtyRoots.has(document)) {
                    return;
                }

                for (const existing of dirtyRoots) {
                    if (existing === document) {
                        return;
                    }
                    if (existing instanceof Element && existing.contains(root)) {
                        return;
                    }
                }

                for (const existing of Array.from(dirtyRoots)) {
                    if (existing instanceof Element && root.contains(existing)) {
                        dirtyRoots.delete(existing);
                    }
                }

                dirtyRoots.add(root);

                if (dirtyRoots.size > maxDirtyRootsBeforeFullScan) {
                    dirtyRoots.clear();
                    dirtyRoots.add(document);
                }
            }

            function runPendingScans() {
                const roots = dirtyRoots.size > 0 ? Array.from(dirtyRoots) : [document];
                dirtyRoots.clear();
                injectAdBlockCSS();

                roots.forEach(root => {
                    hideBySelectorsInRoot(root);
                    hideSponsoredTextInRoot(root);
                });
            }

            // Leading-edge: run immediately after idle, then coalesce additional mutations for 300ms.
            function scheduleMutationScan() {
                if (mutationCoalesceTimer !== null) {
                    return;
                }

                runPendingScans();

                mutationCoalesceTimer = setTimeout(() => {
                    mutationCoalesceTimer = null;
                    if (dirtyRoots.size > 0) {
                        scheduleMutationScan();
                    }
                }, mutationDebounceMs);
            }

            // Inject persistent CSS (includes cosmetic filter selectors from EasyList)
            const injectAdBlockCSS = () => {
                if (document.getElementById('adblock-css-rules')) return;
                const style = document.createElement('style');
                style.id = 'adblock-css-rules';
                style.textContent = `
                    /* Comprehensive ad hiding */
                    [id*="google_ads"], [class*="google-ads"], [id*="googleads"], [class*="googleads"],
                    ins.adsbygoogle, .adsbygoogle,
                    [id*="ad-container"], [class*="ad-container"],
                    [id*="ad-wrapper"], [class*="ad-wrapper"],
                    [id*="advertisement"], [class*="advertisement"],
                    [id*="ad-slot"], [class*="ad-slot"],
                    [data-ad], [data-ad-slot], [data-ad-client],
                    .ad-banner, .banner-ad, .sidebar-ad, .side-ad,
                    .taboola, .OUTBRAIN, .ob-widget,
                    .native-ad, [class*="native-ad"],
                    [class*="sponsored-content"], [class*="sponsored-post"],
                    /* Reddit */
                    div[data-testid="promoted-post"], shreddit-ad-post,
                    div[data-promoted="true"], article[data-promoted="true"],
                    .promotedlink, .promoted-post, div.promoted,
                    div[data-testid="premium-banner"],
                    /* Popups */
                    .ad-modal, .ad-popup, .popup-ad, .interstitial-ad,
                    /* Cookie banners */
                    .cookie-banner, .cookie-notice, #cookie-banner,
                    .gdpr-banner, .consent-banner,
                    /* Cosmetic filters from EasyList */
                    \(cosmeticCSS) {
                        display: none !important;
                        visibility: hidden !important;
                        height: 0 !important;
                        overflow: hidden !important;
                        pointer-events: none !important;
                    }
                `;
                if (document.head) {
                    document.head.appendChild(style);
                } else {
                    document.addEventListener('DOMContentLoaded', () => {
                        document.head.appendChild(style);
                    });
                }
            };

            // Combined function
            const runAdBlocking = () => {
                injectAdBlockCSS();
                addDirtyRoot(document);
                runPendingScans();
            };

            // Run on load
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', runAdBlocking);
            } else {
                runAdBlocking();
            }

            // Watch for dynamic content
            const observer = new MutationObserver((mutations) => {
                mutations.forEach(mutation => {
                    if (mutation.type === 'childList') {
                        mutation.addedNodes.forEach(node => addDirtyRoot(node));
                        if (mutation.removedNodes && mutation.removedNodes.length > 0) {
                            addDirtyRoot(mutation.target);
                        }
                    } else if (mutation.type === 'attributes') {
                        addDirtyRoot(mutation.target);
                    } else if (mutation.type === 'characterData') {
                        addDirtyRoot(mutation.target && mutation.target.parentElement ? mutation.target.parentElement : mutation.target);
                    }
                });

                if (dirtyRoots.size > 0) {
                    scheduleMutationScan();
                }
            });

            const startObserver = () => {
                const target = document.documentElement || document.body;
                if (target) {
                    observer.observe(target, {
                        childList: true,
                        subtree: true,
                        attributes: true,
                        attributeFilter: ['class', 'style', 'id', 'hidden', 'src', 'href'],
                        characterData: true
                    });
                }
            };

            if (document.body) {
                startObserver();
            } else {
                document.addEventListener('DOMContentLoaded', startObserver);
            }

            // Re-scan when page becomes visible and on bfcache restore.
            document.addEventListener('visibilitychange', () => {
                if (!document.hidden) {
                    addDirtyRoot(document);
                    scheduleMutationScan();
                }
            });
            window.addEventListener('pageshow', () => {
                addDirtyRoot(document);
                scheduleMutationScan();
            });

            // Low-frequency safety sweep for edge cases that avoid mutation triggers.
            setInterval(() => {
                if (document.hidden) {
                    return;
                }
                addDirtyRoot(document);
                scheduleMutationScan();
            }, safetySweepMs);
        })();
        """
    }

    private func updateContentBlockingRules() {
        Task {
            await loadContentBlockingRules()
        }
    }

    private func loadContentBlockingRules() async {
        guard Self.nativeContentRuleListsSupported,
              let contentRuleListStore else {
            activeRuleList = nil
            customRuleList = nil
            return
        }

        guard isEnabled else {
            activeRuleList = nil
            return
        }

        // Calculate hash of current configuration to check for cache
        let currentHash = calculateContentHash()
        let lastHash = UserDefaults.standard.string(forKey: "lastCompiledRulesHash")

        // Try to load cached rules if hash matches
        if let lastHash = lastHash, lastHash == currentHash {
            do {
                if let cachedList = try? await contentRuleListStore.lookupContentRuleListAsync(forIdentifier: "adBlockRules") {
                    print("DEBUG: AdBlock cache hit! Using existing compiled rules.")
                    await MainActor.run {
                        self.activeRuleList = cachedList
                        // Apply rules to registered WebViews immediately
                        for webView in self.registeredWebViews.allObjects {
                            webView.configuration.userContentController.add(cachedList)
                        }
                    }
                    return
                }
            }
        }

        print("DEBUG: AdBlock cache miss (or changed). Compiling new rules...")

        // Build comprehensive rules
        var jsonRules: [[String: Any]] = []

        // Load rules from enabled filter lists
        for list in filterLists where list.isEnabled {
            if let cachedRules = loadRuleCache(for: list, kind: .network) {
                for pattern in cachedRules {
                    let rule: [String: Any] = [
                        "trigger": [
                            "url-filter": pattern
                        ],
                        "action": [
                            "type": "block"
                        ]
                    ]
                    jsonRules.append(rule)
                }
            }
        }

        // Add domain-based blocking rules - block requests TO ad domains
        // Use simple "contains" matching for maximum reliability
        let domainResourceTypes = normalizedResourceTypes([
            "script", "image", "style-sheet", "raw", "font", "media", "popup", "document"
        ])

        // Create individual rules for each ad domain (simple contains matching)
        for domain in adNetworkDomains {
            // Clean domain - remove paths for proper URL matching
            var cleanDomain = domain.lowercased()
            if let slashIndex = cleanDomain.firstIndex(of: "/") {
                cleanDomain = String(cleanDomain[..<slashIndex])
            }
            cleanDomain = cleanDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !cleanDomain.isEmpty else { continue }

            // Escape dots for regex - use simple "contains" pattern
            let escapedDomain = cleanDomain.replacingOccurrences(of: ".", with: "\\\\.")

            // Simple pattern: match any URL containing this domain
            let domainRule: [String: Any] = [
                "trigger": [
                    "url-filter": escapedDomain,
                    "resource-type": domainResourceTypes
                ],
                "action": [
                    "type": "block"
                ]
            ]
            jsonRules.append(domainRule)
        }

        // URL path patterns
        let pathPatterns = [
            "ads", "advertisement", "adsystem", "adsense", "adserver", "adservice",
            "adtracker", "admanager", "banner", "popup", "popunder", "tracking",
            "analytics", "pixel", "beacon", "telemetry", "sponsored"
        ]
        for pattern in pathPatterns {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            let pathPattern = ".*\\\\/\(escaped)\\\\/.*"
            let pathRule: [String: Any] = [
                "trigger": [
                    "url-filter": pathPattern,
                    "resource-type": normalizedResourceTypes(["script", "image", "xmlhttprequest"])
                ],
                "action": [
                    "type": "block"
                ]
            ]
            jsonRules.append(pathRule)
        }

        // Specific ad network patterns
        let specificPatterns: [(String, [String])] = [
            ("doubleclick\\.net", ["script", "image", "document", "style-sheet", "raw"]),
            ("googlesyndication\\.com", ["script", "image", "document", "style-sheet", "raw"]),
            ("googletagmanager\\.com", ["script"]),
            ("google-analytics\\.com", ["script", "image"]),
            ("facebook\\.com/tr", ["script", "image"]),
            ("facebook\\.net/signals", ["script"]),
            ("amazon-adsystem\\.com", ["script", "image", "document"]),
            ("criteo\\.com", ["script", "image"]),
            ("criteo\\.net", ["script", "image"]),
            ("outbrain\\.com", ["script", "image"]),
            ("taboola\\.com", ["script", "image"]),
            ("adnxs\\.com", ["script", "image", "document"]),
            ("pubmatic\\.com", ["script", "image"]),
            ("rubiconproject\\.com", ["script", "image"]),
            ("openx\\.net", ["script", "image"]),
            ("hotjar\\.com", ["script"]),
            ("mixpanel\\.com", ["script"]),
            ("segment\\.com", ["script"]),
            ("segment\\.io", ["script"]),
            ("chartbeat\\.com", ["script"]),
            ("newrelic\\.com", ["script"]),
            ("nr-data\\.net", ["script"]),
            // Reddit (only ad-specific endpoints)
            ("redditmedia\\.com/ads", ["script", "image", "document"]),
            ("reddit\\.com/api/v2/ad", ["xmlhttprequest", "document"]),
            // Huawei (high priority - these were not being blocked)
            ("hicloud\\.com", ["script", "image", "document", "style-sheet", "raw", "font", "media"]),
            ("metrics\\.data\\.hicloud\\.com", ["script", "image", "document", "raw"]),
            ("metrics2\\.data\\.hicloud\\.com", ["script", "image", "document", "raw"]),
            ("grs\\.hicloud\\.com", ["script", "image", "document", "raw"]),
            ("logservice\\.hicloud\\.com", ["script", "image", "document", "raw"]),
            ("logservice1\\.hicloud\\.com", ["script", "image", "document", "raw"]),
            ("logbak\\.hicloud\\.com", ["script", "image", "document", "raw"]),
            // Google Ads scripts (ads.js, pagead.js)
            ("googlesyndication\\.com", ["script", "image", "document", "style-sheet", "raw"]),
            ("pagead", ["script", "image"]),
            ("ads\\.js", ["script"]),
            ("adsbygoogle", ["script"])
        ]

        for (pattern, resourceTypes) in specificPatterns {
            let rule: [String: Any] = [
                "trigger": [
                    "url-filter": pattern,
                    "resource-type": normalizedResourceTypes(resourceTypes)
                ],
                "action": [
                    "type": "block"
                ]
            ]
            jsonRules.append(rule)
        }

        // Limit rules to avoid hitting WebKit limits (50000 rules max)
        let maxRules = min(jsonRules.count, 50000)
        let limitedRules = Array(jsonRules.prefix(maxRules))

        print("DEBUG: AdBlock attempting to compile \(limitedRules.count) rules (from \(jsonRules.count) total)")

        guard let jsonData = try? JSONSerialization.data(withJSONObject: limitedRules),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("DEBUG: Failed to serialize blocking rules")
            return
        }

        print("DEBUG: JSON size = \(jsonString.count) characters")

        do {
            let ruleList = try await contentRuleListStore.compileContentRuleListAsync(
                forIdentifier: "adBlockRules",
                encodedContentRuleList: jsonString
            )

            // Save hash after successful compilation
            UserDefaults.standard.set(currentHash, forKey: "lastCompiledRulesHash")

            print("DEBUG: Successfully compiled rules. RuleList = \(ruleList != nil ? "valid" : "nil")")

            await MainActor.run {
                self.activeRuleList = ruleList
                // Apply rules to WebViews that were configured before rules were ready
                if let ruleList = ruleList {
                    for webView in self.registeredWebViews.allObjects {
                        webView.configuration.userContentController.add(ruleList)
                    }
                    print("DEBUG: Applied rules to \(self.registeredWebViews.allObjects.count) WebViews")
                }
            }
        } catch {
            print("DEBUG: Failed to compile content blocking rules: \(error)")
            print("DEBUG: Error details: \(error.localizedDescription)")
        }
    }
    
    private func calculateContentHash() -> String {
        var combinedString = ""
        
        // Add enabled lists state
        for list in filterLists where list.isEnabled {
            combinedString += "\(list.url)_\(list.lastUpdated?.timeIntervalSince1970 ?? 0)_"
        }
        
        // Add custom rules state
        combinedString += customRules.joined(separator: "|")
        
        // Add static domains/selectors versioning (bump this if hardcoded lists change)
        combinedString += "_v8_static"
        
        let inputData = Data(combinedString.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func normalizedContentRuleDomains() -> [String] {
        var domains = Set<String>()
        for raw in adNetworkDomains {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty else { continue }

            if let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty, let host = url.host {
                value = host
            } else if let slashIndex = value.firstIndex(of: "/") {
                value = String(value[..<slashIndex])
            }

            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !value.isEmpty else { continue }
            guard value.unicodeScalars.allSatisfy({ isASCIIHostnameScalar($0) }) else { continue }

            domains.insert(value)
            domains.insert("*." + value)
        }

        return domains.sorted()
    }

    private func isASCIIHostnameScalar(_ scalar: UnicodeScalar) -> Bool {
        if scalar.isASCII {
            switch scalar.value {
            case 0x30...0x39, 0x61...0x7A, 0x2D, 0x2E: // 0-9, a-z, -, .
                return true
            default:
                return false
            }
        }
        return false
    }

    private func normalizedResourceTypes(_ raw: [String]) -> [String] {
        let allowed: Set<String> = [
            "document",
            "image",
            "style-sheet",
            "script",
            "font",
            "media",
            "popup",
            "raw"
        ]
        var cleaned: [String] = []
        for value in raw {
            let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered == "xmlhttprequest" {
                if allowed.contains("raw") {
                    cleaned.append("raw")
                }
                continue
            }
            if allowed.contains(lowered) {
                cleaned.append(lowered)
            }
        }
        return Array(Set(cleaned)).sorted()
    }

    private func pruneOversizedRuleCaches() {
        // Legacy cleanup: keep UserDefaults lightweight.
        for (key, _) in defaults.dictionaryRepresentation() {
            if key.hasPrefix("filterRules_") || key.hasPrefix("cosmeticRules_") {
                defaults.removeObject(forKey: key)
            }
        }

        guard let cachedFiles = try? fileManager.contentsOfDirectory(
            at: ruleCacheDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in cachedFiles where fileURL.pathExtension.lowercased() == "json" {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let isRegularFile = values?.isRegularFile ?? false
            let byteSize = values?.fileSize ?? 0
            guard isRegularFile else { continue }
            if byteSize <= 0 || byteSize > maxRuleCacheFileBytes {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }
}

private extension WKContentRuleListStore {
    func lookupContentRuleListAsync(forIdentifier identifier: String) async throws -> WKContentRuleList? {
        try await withCheckedThrowingContinuation { continuation in
            lookUpContentRuleList(forIdentifier: identifier) { ruleList, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ruleList)
                }
            }
        }
    }

    func compileContentRuleListAsync(forIdentifier identifier: String, encodedContentRuleList: String) async throws -> WKContentRuleList? {
        try await withCheckedThrowingContinuation { continuation in
            compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encodedContentRuleList) { ruleList, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ruleList)
                }
            }
        }
    }
}

// MARK: - WKScriptMessageHandler
extension AdBlockService: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let count = body["count"] as? Int else { return }

        Task { @MainActor in
            self.blockedCount = count
        }
    }
}
