import WebKit
import SwiftUI
import Combine
import CryptoKit

// MARK: - Filter List Model
struct FilterList: Codable, Identifiable, Sendable {
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

enum AdBlockRuntimePolicy {
    static func isProtectionActive(globalEnabled: Bool, sitePaused: Bool) -> Bool {
        globalEnabled && !sitePaused
    }
}

nonisolated enum AdBlockContentRulePolicy {
    struct Target: Equatable, Sendable {
        let host: String
        let path: String?
    }

    static func target(from rawValue: String) -> Target? {
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        let urlString = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: urlString),
              let rawHost = components.host else { return nil }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty,
              host.unicodeScalars.allSatisfy({ isASCIIHostnameScalar($0) }) else { return nil }

        let rawPath = components.percentEncodedPath
        let path = rawPath.isEmpty || rawPath == "/" ? nil : rawPath
        return Target(host: host, path: path)
    }

    static func urlFilter(for target: Target) -> String {
        let escapedHost = NSRegularExpression.escapedPattern(for: target.host)
        var filter = "^https?://(?:[^/:?#@]+\\.)*\(escapedHost)(?::[0-9]+)?"
        if let path = target.path {
            filter += NSRegularExpression.escapedPattern(for: path)
        }
        return filter + "(?:[/?#]|$)"
    }

    private static func isASCIIHostnameScalar(_ scalar: UnicodeScalar) -> Bool {
        guard scalar.isASCII else { return false }
        switch scalar.value {
        case 0x30...0x39, 0x61...0x7A, 0x2D, 0x2E: // 0-9, a-z, -, .
            return true
        default:
            return false
        }
    }
}

@MainActor
class AdBlockService: NSObject, ObservableObject {
    static let shared = AdBlockService()

    // iOS 26 retains its existing converter. iOS 27 uses only the separately
    // probed bounded resource layer on the exact tested OS/SDK pair.
    private static var nativeContentRuleListsSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 || NativeAdResourceRules.isSupported
    }

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "adBlockEnabled")
            if isEnabled != oldValue {
                handleConfigurationChange(recompileNativeRules: true)
            }
        }
    }

    @Published var blockedCount: Int = 0
    @Published var filterLists: [FilterList] = []
    @Published var isUpdatingFilters: Bool = false
    @Published var customRules: [String] = []
    @Published private(set) var isReady: Bool = false
    @Published private(set) var indexedDomainCount = 0
    @Published private(set) var indexedPatternCount = 0
    @Published private(set) var indexedOmittedCount = 0
    @Published private(set) var filterUpdateError: String?
    @Published private(set) var nativeResourceRuleCount = 0
    @Published private(set) var nativeResourceStatus = "JavaScript protection"
    private var nativeResourceGeneration = 0
    private var nativeResourceWork: (token: UUID, identity: String, task: Task<WKContentRuleList?, Error>)?
    private var indexedSnapshot = IndexedAdBlockRules.Snapshot()
    private var indexedListURLs = Set<String>()
    private var indexedBuildGeneration = 0
    private static let indexedEngineJavaScript: String = {
        guard let url = Bundle.main.url(forResource: "indexed-adblock", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }()

    // Cosmetic selectors parsed from filter lists (## rules)
    private var cosmeticSelectors: [String] = []

    // Cached JavaScript needs regeneration when cosmetic selectors change
    private var cachedBlockingJavaScriptStorage: String?
    private var isPreparing = false

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
    private let maxJavaScriptNetworkRules = 5_000

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

        // Social Trackers
        "mix.com",
        "graph.facebook.com",
        "connect.facebook.net",
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
        guard !isReady, !isPreparing else { return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            await rebuildIndexedRules()
            await downloadMissingFilterLists()
            await rebuildIndexedRules()
            cachedBlockingJavaScriptStorage = nil
            if Self.nativeContentRuleListsSupported {
                await loadContentBlockingRules()
                await compileCustomRules()
            }
            refreshJavaScriptConfiguration(reloadPages: false)
            isReady = true
            // A v1 indexed cache is still installed above with its conservative
            // semantics. Refresh its provenance only after startup is ready so an
            // offline/slow list cannot delay the first navigation; a successful
            // refresh rebuilds and reapplies the iOS 27 layers in the background.
            Task { [weak self] in
                await self?.refreshProvenanceFilterLists()
            }
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
        try? fileManager.removeItem(at: IndexedAdBlockRules.cacheURL(directory: ruleCacheDirectoryURL, listURL: list.url))
    }

    private func downloadMissingFilterLists() async {
        for list in filterLists where list.isEnabled {
            let directory = ruleCacheDirectoryURL
            let exists = await Task.detached(priority: .utility) {
                IndexedAdBlockRules.load(directory: directory, listURL: list.url) != nil
            }.value
            if !exists { _ = await updateFilterList(list) }
        }
    }

    /// Refresh old indexed documents without making cached protection part of
    /// first-run latency. The old document remains on disk if the request fails.
    private func refreshProvenanceFilterLists() async {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else { return }
        var refreshed = false
        for list in filterLists where list.isEnabled {
            let directory = ruleCacheDirectoryURL
            let needsRefresh = await Task.detached(priority: .utility) {
                IndexedAdBlockRules.load(directory: directory, listURL: list.url)?.needsProvenanceRefresh ?? false
            }.value
            guard needsRefresh else { continue }
            refreshed = (await updateFilterList(list)) || refreshed
        }
        guard refreshed else { return }
        await rebuildIndexedRules()
        cachedBlockingJavaScriptStorage = nil
        if Self.nativeContentRuleListsSupported {
            await loadContentBlockingRules()
        }
        refreshJavaScriptConfiguration(reloadPages: false)
    }

    private func rebuildIndexedRules() async {
        indexedBuildGeneration += 1
        let generation = indexedBuildGeneration
        let urls = filterLists.filter(\.isEnabled).map(\.url)
        let directory = ruleCacheDirectoryURL
        do {
            let result = try await Task.detached(priority: .utility) {
                let loaded = urls.compactMap { url in
                    IndexedAdBlockRules.load(directory: directory, listURL: url).map { (url, $0) }
                }
                let documents = loaded.map { $0.1 }
                let policy: IndexedAdBlockRules.Policy =
                    ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27
                        ? .ios27Scripts
                        : .legacy
                var snapshot = try IndexedAdBlockRules.merge(documents, policy: policy)
                snapshot.omitted += documents.reduce(0) { $0 + $1.unsupported }
                return (snapshot, Set(loaded.map { $0.0 }))
            }.value
            guard generation == indexedBuildGeneration,
                  urls == filterLists.filter(\.isEnabled).map(\.url) else { return }
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
               indexedSnapshot.identity != result.0.identity {
                // A disabled/removed list must not remain effective while replacement compiles.
                nativeResourceGeneration += 1
                replaceActiveRuleList(with: nil)
                nativeResourceRuleCount = 0
            }
            indexedSnapshot = result.0
            indexedListURLs = result.1
            indexedDomainCount = result.0.domains
            indexedPatternCount = result.0.patterns
            indexedOmittedCount = result.0.omitted
            cachedBlockingJavaScriptStorage = nil
        } catch {
            guard generation == indexedBuildGeneration else { return }
            filterUpdateError = "The new rule index exceeded its safety budget. Previous protection is retained."
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
        cachedBlockingJavaScriptStorage = nil
        refreshJavaScriptConfiguration(reloadPages: true)
        Task {
            await compileCustomRules()
        }
    }

    func removeCustomRule(_ rule: String) {
        customRules.removeAll { $0 == rule }
        saveCustomRules()
        cachedBlockingJavaScriptStorage = nil
        refreshJavaScriptConfiguration(reloadPages: true)
        Task {
            await compileCustomRules()
        }
    }

    func toggleFilterList(_ list: FilterList) {
        if let index = filterLists.firstIndex(where: { $0.id == list.id }) {
            filterLists[index].isEnabled.toggle()
            saveFilterLists()
            let updatedList = filterLists[index]
            Task {
                await rebuildIndexedRules()
                cachedBlockingJavaScriptStorage = nil
                refreshJavaScriptConfiguration(reloadPages: true)
                if updatedList.isEnabled {
                    await updateFilterList(updatedList)
                }
                await rebuildIndexedRules()
                await loadContentBlockingRules()
                cachedBlockingJavaScriptStorage = nil
                refreshJavaScriptConfiguration(reloadPages: true)
            }
        }
    }

    func addFilterList(name: String, url: String) {
        let newList = FilterList(name: name, url: url, isEnabled: true, lastUpdated: nil, ruleCount: 0)
        filterLists.append(newList)
        saveFilterLists()
        cachedBlockingJavaScriptStorage = nil
        refreshJavaScriptConfiguration(reloadPages: true)
        Task {
            await updateFilterList(newList)
            await rebuildIndexedRules()
            await loadContentBlockingRules()
            cachedBlockingJavaScriptStorage = nil
            refreshJavaScriptConfiguration(reloadPages: true)
        }
    }

    func removeFilterList(_ list: FilterList) {
        filterLists.removeAll { $0.id == list.id }
        saveFilterLists()
        // Remove cached rules (both network and cosmetic)
        removeRuleCaches(for: list)
        // Invalidate JavaScript cache
        Task {
            await rebuildIndexedRules()
            cachedBlockingJavaScriptStorage = nil
            refreshJavaScriptConfiguration(reloadPages: true)
            await loadContentBlockingRules()
        }
    }

    func updateAllFilterLists() async {
        guard !isUpdatingFilters else { return }
        isUpdatingFilters = true
        filterUpdateError = nil
        for list in filterLists where list.isEnabled {
            await updateFilterList(list)
        }
        isUpdatingFilters = false
        await rebuildIndexedRules()
        await loadContentBlockingRules()
        await compileCustomRules()
        cachedBlockingJavaScriptStorage = nil
        refreshJavaScriptConfiguration(reloadPages: true)
    }

    /// Clears all cached compiled rules and forces fresh recompilation.
    /// Use this to fix inconsistent blocking issues across devices.
    func clearCacheAndRecompile() async {
        guard !isUpdatingFilters else { return }
        isUpdatingFilters = true
        await rebuildIndexedRules()

        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            // Rebuild only our own layer, without deleting website cache or other services' rules.
            defaults.removeObject(forKey: NativeAdResourceRules.hashKey)
            await loadContentBlockingRules()
            cachedBlockingJavaScriptStorage = nil
            refreshJavaScriptConfiguration(reloadPages: true)
            isUpdatingFilters = false
            return
        }

        guard Self.nativeContentRuleListsSupported,
              let contentRuleListStore else {
            cachedBlockingJavaScriptStorage = nil
            refreshJavaScriptConfiguration(reloadPages: true)
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

        // 5. Detach only Vortex's ad-block lists. Other privacy services may
        // have installed their own content rules on the same controller.
        removeNativeRulesFromAllWebViews()
        activeRuleList = nil
        customRuleList = nil

        // 6. Recompile everything fresh
        await loadContentBlockingRules()
        await compileCustomRules()

        cachedBlockingJavaScriptStorage = nil
        refreshJavaScriptConfiguration(reloadPages: true)

        isUpdatingFilters = false
        print("DEBUG: Cache cleared and rules recompiled successfully")
    }

    @discardableResult
    private func updateFilterList(_ list: FilterList) async -> Bool {
        guard let url = URL(string: list.url) else { return false }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode), data.count <= 12_000_000,
                  let content = String(data: data, encoding: .utf8),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else {
                throw IndexedAdBlockRules.IndexError.invalidDownload
            }
            let directory = ruleCacheDirectoryURL
            let result = try await Task.detached(priority: .utility) {
                let document = IndexedAdBlockRules.parse(content)
                let legacy = Self.parseFilterList(content)
                guard document.supportedCount > 0 || !legacy.cosmeticRules.isEmpty else {
                    throw IndexedAdBlockRules.IndexError.invalidDownload
                }
                try IndexedAdBlockRules.store(document, directory: directory, listURL: list.url)
                return (document, legacy)
            }.value
            if filterLists.contains(where: { $0.id == list.id }) {
                let (document, parsed) = result
                storeRuleCache(parsed.networkRules, for: list, kind: .network)
                storeRuleCache(parsed.cosmeticRules, for: list, kind: .cosmetic)

                // Update list metadata
                if let index = filterLists.firstIndex(where: { $0.id == list.id }) {
                    filterLists[index].lastUpdated = Date()
                    filterLists[index].ruleCount = document.supportedCount + min(parsed.cosmeticRules.count, maxStoredCosmeticRules)
                    saveFilterLists()
                }

                // Invalidate JavaScript cache since cosmetic rules changed
                cachedBlockingJavaScriptStorage = nil
                return true
            }
            return false
        } catch {
            filterUpdateError = "Could not update \(list.name). Previous cached rules are retained."
            print("Failed to update filter list \(list.name): \(error)")
            return false
        }
    }

    nonisolated private static func parseFilterList(_ content: String) -> (networkRules: [String], cosmeticRules: [String]) {
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

    nonisolated private static func extractCosmeticSelector(_ rule: String) -> String? {
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

    nonisolated private static func validateAndCleanSelector(_ selector: String) -> String? {
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

        // Configuration is serialized with JSONEncoder later, so returning an
        // already JavaScript-escaped selector would corrupt valid CSS escapes.
        return trimmed
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    nonisolated private static func convertToRegex(_ rule: String) -> String? {
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
        // Arbitrary native custom regexes remain on the unchanged iOS 26 path.
        // iOS 27 custom rules keep the JavaScript fallback until separately validated.
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27,
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

        guard !jsonRules.isEmpty else {
            replaceCustomRuleList(with: nil)
            return
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRules),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        do {
            let ruleList = try await contentRuleListStore.compileContentRuleListAsync(
                forIdentifier: "customAdBlockRules",
                encodedContentRuleList: jsonString
            )
            replaceCustomRuleList(with: ruleList)
        } catch {
            print("Failed to compile custom rules: \(error)")
        }
    }

    func configureWebView(_ webView: WKWebView) {
        let isNewRegistration = !registeredWebViews.contains(webView)
        registeredWebViews.add(webView)

        applyNativeRuleState(to: webView, siteProtectionEnabled: true)
        guard isNewRegistration else { return }

        // Keep one owned script. Disabled tabs retain a cheap runtime that can
        // be enabled later without accumulating old configurations.
        ManagedUserScript.install(
            source: cachedBlockingJavaScript,
            identifier: "ad-block",
            in: webView.configuration.userContentController
        )

        // Add message handler for blocked count
        webView.configuration.userContentController.add(self, name: "adBlockHandler")
    }

    func setProtectionEnabled(_ enabled: Bool, for webView: WKWebView) {
        applyNativeRuleState(to: webView, siteProtectionEnabled: enabled)
    }

    private func handleConfigurationChange(recompileNativeRules: Bool) {
        cachedBlockingJavaScriptStorage = nil
        if !isEnabled {
            removeNativeRulesFromAllWebViews()
        } else {
            for webView in registeredWebViews.allObjects {
                let siteEnabled = !SitePrivacyStore.shared.isAdBlockingPaused(for: webView.url)
                applyNativeRuleState(to: webView, siteProtectionEnabled: siteEnabled)
            }
        }
        refreshJavaScriptConfiguration(reloadPages: true)
        if recompileNativeRules {
            updateContentBlockingRules()
        }
    }

    private func refreshJavaScriptConfiguration(reloadPages: Bool) {
        let source = cachedBlockingJavaScript
        for webView in registeredWebViews.allObjects {
            let changed = ManagedUserScript.install(
                source: source, identifier: "ad-block", in: webView.configuration.userContentController
            )
            guard changed else { continue }
            webView.evaluateJavaScript(source, completionHandler: nil)
            if reloadPages, webView.url != nil {
                webView.reload()
            }
        }
    }

    private func applyNativeRuleState(to webView: WKWebView, siteProtectionEnabled: Bool) {
        guard Self.nativeContentRuleListsSupported else { return }
        let shouldEnable = AdBlockRuntimePolicy.isProtectionActive(
            globalEnabled: isEnabled,
            sitePaused: !siteProtectionEnabled
        )
        if let activeRuleList {
            webView.configuration.userContentController.remove(activeRuleList)
            if shouldEnable {
                webView.configuration.userContentController.add(activeRuleList)
            }
        }
        if let customRuleList {
            webView.configuration.userContentController.remove(customRuleList)
            if shouldEnable {
                webView.configuration.userContentController.add(customRuleList)
            }
        }
    }

    private func removeNativeRulesFromAllWebViews() {
        guard Self.nativeContentRuleListsSupported else { return }
        for webView in registeredWebViews.allObjects {
            if let activeRuleList {
                webView.configuration.userContentController.remove(activeRuleList)
            }
            if let customRuleList {
                webView.configuration.userContentController.remove(customRuleList)
            }
        }
    }

    private func replaceActiveRuleList(with replacement: WKContentRuleList?) {
        let previous = activeRuleList
        for webView in registeredWebViews.allObjects {
            if let previous {
                webView.configuration.userContentController.remove(previous)
            }
        }
        activeRuleList = replacement
        guard isEnabled else { return }
        for webView in registeredWebViews.allObjects {
            let siteEnabled = !SitePrivacyStore.shared.isAdBlockingPaused(for: webView.url)
            applyNativeRuleState(to: webView, siteProtectionEnabled: siteEnabled)
        }
    }

    private func replaceCustomRuleList(with replacement: WKContentRuleList?) {
        let previous = customRuleList
        for webView in registeredWebViews.allObjects {
            if let previous {
                webView.configuration.userContentController.remove(previous)
            }
        }
        customRuleList = replacement
        guard isEnabled else { return }
        for webView in registeredWebViews.allObjects {
            let siteEnabled = !SitePrivacyStore.shared.isAdBlockingPaused(for: webView.url)
            applyNativeRuleState(to: webView, siteProtectionEnabled: siteEnabled)
        }
    }

    private func generateBlockingJavaScript() -> String {
        // Combine hardcoded selectors with cosmetic selectors from filter lists
        var allSelectors = adSelectors
        for list in filterLists where list.isEnabled {
            if let cachedCosmetic = loadRuleCache(for: list, kind: .cosmetic) {
                allSelectors.append(contentsOf: cachedCosmetic)
            }
        }
        // Deduplicate selectors
        let uniqueSelectors = Array(Set(allSelectors)).sorted()
        // Generate additional CSS rules from cosmetic selectors for persistent hiding
        let cosmeticCSS = uniqueSelectors
            .filter { !$0.contains(":") || $0.contains("[") } // Skip pseudo-selectors that might fail
            .prefix(2000) // Limit to avoid massive CSS
            .joined(separator: ",\n                    ")

        let domainsJSON = javaScriptJSON(adNetworkDomains)
        let supplementalRulesJSON = javaScriptJSON(SupplementalAdResourceRules.entries(
            forMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion))
        // Keep the bounded legacy fallback only for lists not yet migrated (including offline
        // partial updates). A migrated list no longer pays for thousands of legacy regexes.
        let networkRulesJSON = javaScriptJSON(enabledJavaScriptNetworkRules())
        let indexedRulesJSON = indexedSnapshot.json
        let indexedEngineJavaScript = Self.indexedEngineJavaScript
        let selectorsJSON = javaScriptJSON(uniqueSelectors)
        let customRulesJSON = javaScriptJSON(customRules)
        let cosmeticCSSJSON = javaScriptJSON(cosmeticCSS)
        let enabledJavaScript = isEnabled ? "true" : "false"
        let versionData = Data((enabledJavaScript + indexedSnapshot.identity + selectorsJSON + customRulesJSON + networkRulesJSON + domainsJSON + supplementalRulesJSON).utf8)
        let configurationVersionJSON = javaScriptJSON(SHA256.hash(data: versionData).map { String(format: "%02x", $0) }.joined())

        return """
        (function() {
            'use strict';

            \(indexedEngineJavaScript)

            const nextConfiguration = {
                version: \(configurationVersionJSON),
                indexedRules: \(indexedRulesJSON),
                enabled: \(enabledJavaScript),
                blockedDomains: \(domainsJSON),
                supplementalRules: \(supplementalRulesJSON),
                networkRules: \(networkRulesJSON),
                adSelectors: \(selectorsJSON),
                customRules: \(customRulesJSON),
                cosmeticCSS: \(cosmeticCSSJSON)
            };
            const existingRuntime = window.__vortexAdBlockRuntime;
            if (existingRuntime && typeof existingRuntime.applyConfiguration === 'function') {
                existingRuntime.applyConfiguration(nextConfiguration);
                return;
            }
            const runtime = Object.assign({}, nextConfiguration);
            runtime.configurationKey = nextConfiguration.version;
            window.__vortexAdBlockRuntime = runtime;

            let blockedCount = 0;
            let lastReportedBlockedCount = 0;
            let notifyTimer = null;
            let mutationCoalesceTimer = null;
            const mutationDebounceMs = 300;
            const safetySweepMs = 30000;
            const notifyThrottleMs = 1000;
            const blockedMarkerAttr = 'data-codex-adblocked';
            const originalStyleAttr = 'data-vortex-adblock-original-style';
            const noOriginalStyleMarker = '__vortex_no_original_style__';
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
                // AI providers
                'chatgpt.com',
                'chat.openai.com',
                'openai.com',
                'gemini.google.com',
                'bard.google.com'
            ];

            function parsedURL(value) {
                try {
                    if (value instanceof Request) { value = value.url; }
                    return new URL(String(value), document.baseURI);
                } catch (_) {
                    return null;
                }
            }

            function hostMatches(host, domain) {
                return host === domain || host.endsWith('.' + domain);
            }

            function siteKey(host) {
                const normalized = (host || '').toLowerCase().replace(/^\\.+|\\.+$/g, '');
                if (!normalized || /^\\d+(?:\\.\\d+){3}$/.test(normalized) || normalized.includes(':')) {
                    return normalized;
                }
                const labels = normalized.split('.');
                return labels.length > 1 ? labels.slice(-2).join('.') : normalized;
            }

            function isSameSite(parsed) {
                return siteKey(parsed.hostname) === siteKey(window.location.hostname);
            }

            function isWhitelisted(url) {
                const parsed = parsedURL(url);
                if (!parsed) { return false; }
                const host = parsed.hostname.toLowerCase();
                if (whitelist.some(domain => hostMatches(host, domain))) { return true; }
                // Preserve social-site functionality only on those sites, not their
                // tracking endpoints embedded on unrelated pages.
                const groups = [['x.com', 'twitter.com', 'twimg.com', 't.co'],
                                ['reddit.com', 'redditmedia.com', 'redditstatic.com']];
                return groups.some(group => group.some(domain => hostMatches(window.location.hostname, domain))
                    && group.some(domain => hostMatches(host, domain)));
            }

            function matchesBlockedDomain(url) {
                const parsed = parsedURL(url);
                if (!parsed) { return false; }
                const host = parsed.hostname.toLowerCase();
                const path = parsed.pathname.toLowerCase();
                return (runtime.blockedDomains || []).some(entry => {
                    const separator = entry.indexOf('/');
                    const domain = (separator >= 0 ? entry.slice(0, separator) : entry).toLowerCase();
                    const requiredPath = separator >= 0 ? entry.slice(separator).toLowerCase() : '';
                    if (!hostMatches(host, domain)) { return false; }
                    if (requiredPath) { return path.includes(requiredPath); }
                    return !isSameSite(parsed);
                });
            }

            function matchesSupplementalDomain(parsed) {
                const host = parsed.hostname.toLowerCase();
                const pageHost = window.location.hostname.toLowerCase();
                return (runtime.supplementalRules || []).some(entry =>
                    hostMatches(host, entry.host)
                    && !isSameSite(parsed)
                    && !entry.firstPartySites.some(site => hostMatches(pageHost, site)));
            }

            const selectorGroupSize = 60;
            const networkRuleGroupSize = 80;
            let selectorGroups = [];
            let networkRuleExpressions = [];
            let customRuleExpressions = [];
            let compiledRulesKey = null;
            let indexedMatcher = null;

            function protectionEnabled() {
                if (!runtime.enabled) { return false; }
                try {
                    return localStorage.getItem('__vortexAdBlockDisabled') !== '1';
                } catch (_) {
                    return true;
                }
            }

            function rebuildRuntimeRules() {
                if (!protectionEnabled()) { return; }
                const rulesKey = runtime.version;
                if (compiledRulesKey === rulesKey) { return; }
                compiledRulesKey = rulesKey;
                indexedMatcher = typeof createVortexRuleIndex === 'function'
                    ? createVortexRuleIndex(runtime.indexedRules || {}) : null;
                const validAdSelectors = [];
                (runtime.adSelectors || []).forEach(selector => {
                    try {
                        document.querySelector(selector);
                        validAdSelectors.push(selector);
                    } catch (_) {}
                });
                selectorGroups = [];
                for (let i = 0; i < validAdSelectors.length; i += selectorGroupSize) {
                    selectorGroups.push(validAdSelectors.slice(i, i + selectorGroupSize));
                }
                networkRuleExpressions = [];
                const patterns = runtime.networkRules || [];
                for (let i = 0; i < patterns.length; i += networkRuleGroupSize) {
                    const group = patterns.slice(i, i + networkRuleGroupSize);
                    try {
                        networkRuleExpressions.push(new RegExp(group.map(rule => '(?:' + rule + ')').join('|'), 'i'));
                    } catch (_) {
                        group.forEach(rule => {
                            try { networkRuleExpressions.push(new RegExp(rule, 'i')); } catch (_) {}
                        });
                    }
                }
                customRuleExpressions = (runtime.customRules || []).flatMap(rule => {
                    try { return [new RegExp(rule, 'i')]; } catch (_) { return []; }
                });
            }

            function shouldBlockURL(url, resourceType = 1) {
                if (!protectionEnabled()) { return false; }
                const parsed = parsedURL(url);
                if (!protectionEnabled() || !parsed || isWhitelisted(parsed.href)) {
                    return false;
                }
                const indexedDecision = indexedMatcher
                    ? indexedMatcher.decide(parsed, new URL(window.location.href), resourceType, !isSameSite(parsed)) : 0;
                if (indexedDecision === -1) { return false; }
                if (indexedDecision === 1 || matchesBlockedDomain(parsed.href) || matchesSupplementalDomain(parsed)) {
                    return true;
                }
                return (!isSameSite(parsed)
                        && networkRuleExpressions.some(expression => expression.test(parsed.href)))
                    || customRuleExpressions.some(expression => expression.test(parsed.href));
            }
            rebuildRuntimeRules();

            // Block fetch requests to ad domains
            const originalFetch = window.fetch;
            window.fetch = function(...args) {
                const url = args[0];
                if (shouldBlockURL(url)) {
                    incrementBlockedCount(1);
                    return Promise.reject(new Error('Blocked by ad blocker'));
                }
                return originalFetch.apply(this, args);
            };

            // Block XMLHttpRequest to ad domains
            const originalOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                if (shouldBlockURL(url)) {
                    incrementBlockedCount(1);
                    throw new Error('Blocked by ad blocker');
                }
                return originalOpen.apply(this, [method, url, ...rest]);
            };

            // Block WebSocket connections to ad domains
            const OriginalWebSocket = window.WebSocket;
            window.WebSocket = function(url, protocols) {
                if (shouldBlockURL(url, 64)) {
                    incrementBlockedCount(1);
                    throw new Error('Blocked by ad blocker');
                }
                return new OriginalWebSocket(url, protocols);
            };

            if (typeof navigator.sendBeacon === 'function') {
                const originalBeacon = navigator.sendBeacon;
                navigator.sendBeacon = function(url, data) {
                    if (shouldBlockURL(url, 128)) {
                        incrementBlockedCount(1);
                        return true;
                    }
                    return originalBeacon.call(this, url, data);
                };
            }

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
                const properties = {
                    display: 'none', visibility: 'hidden', height: '0px', overflow: 'hidden', 'pointer-events': 'none'
                };
                Object.entries(properties).forEach(([name, value]) => {
                    if (element.style.getPropertyValue(name) !== value
                        || element.style.getPropertyPriority(name) !== 'important') {
                        element.style.setProperty(name, value, 'important');
                    }
                });
            }

            function markAndHide(element) {
                if (!(element instanceof Element)) {
                    return;
                }

                const alreadyBlocked = element.getAttribute(blockedMarkerAttr) === '1';
                if (!element.hasAttribute(originalStyleAttr)) {
                    element.setAttribute(
                        originalStyleAttr,
                        element.getAttribute('style') || noOriginalStyleMarker
                    );
                }
                applyHiddenStyles(element);

                if (!alreadyBlocked) {
                    element.setAttribute(blockedMarkerAttr, '1');
                    incrementBlockedCount(1);
                }
            }

            function restoreHiddenElements() {
                document.querySelectorAll('[' + blockedMarkerAttr + '="1"]').forEach(element => {
                    const originalStyle = element.getAttribute(originalStyleAttr);
                    if (originalStyle === noOriginalStyleMarker || originalStyle === null) {
                        element.removeAttribute('style');
                    } else {
                        element.setAttribute('style', originalStyle);
                    }
                    element.removeAttribute(blockedMarkerAttr);
                    element.removeAttribute(originalStyleAttr);
                });
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
                if (!protectionEnabled()) {
                    dirtyRoots.clear();
                    return;
                }
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
                if (!protectionEnabled()) {
                    return;
                }
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
            let cssInsertionPending = false;
            const injectAdBlockCSS = () => {
                if (!protectionEnabled()) return;
                if (document.getElementById('adblock-css-rules')) return;
                if (!document.head) {
                    if (!cssInsertionPending) {
                        cssInsertionPending = true;
                        document.addEventListener('DOMContentLoaded', () => {
                            cssInsertionPending = false;
                            injectAdBlockCSS();
                        }, { once: true });
                    }
                    return;
                }
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
                    ${runtime.cosmeticCSS} {
                        display: none !important;
                        visibility: hidden !important;
                        height: 0 !important;
                        overflow: hidden !important;
                        pointer-events: none !important;
                    }
                `;
                document.head.appendChild(style);
            };

            // Combined function
            const runAdBlocking = () => {
                if (!protectionEnabled()) {
                    document.getElementById('adblock-css-rules')?.remove();
                    restoreHiddenElements();
                    return;
                }
                rebuildRuntimeRules();
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
                if (!protectionEnabled()) { return; }
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
                if (!protectionEnabled()) { return; }
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

            runtime.applyConfiguration = function(configuration) {
                const key = configuration.version;
                if (runtime.configurationKey === key) { return; }
                runtime.configurationKey = key;
                runtime.version = configuration.version;
                runtime.indexedRules = configuration.indexedRules || {};
                observer.disconnect();
                dirtyRoots.clear();
                if (mutationCoalesceTimer !== null) {
                    clearTimeout(mutationCoalesceTimer);
                    mutationCoalesceTimer = null;
                }
                runtime.enabled = configuration.enabled;
                runtime.blockedDomains = configuration.blockedDomains || [];
                runtime.supplementalRules = configuration.supplementalRules || [];
                runtime.networkRules = configuration.networkRules || [];
                runtime.adSelectors = configuration.adSelectors || [];
                runtime.customRules = configuration.customRules || [];
                runtime.cosmeticCSS = configuration.cosmeticCSS || '';
                rebuildRuntimeRules();
                document.getElementById('adblock-css-rules')?.remove();
                restoreHiddenElements();
                if (protectionEnabled()) {
                    runAdBlocking();
                    startObserver();
                }
            };
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
                if (document.hidden || !protectionEnabled()) {
                    return;
                }
                addDirtyRoot(document);
                scheduleMutationScan();
            }, safetySweepMs);
        })();
        """
    }

    private func javaScriptJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }

    private func enabledJavaScriptNetworkRules() -> [String] {
        var rules: [String] = []
        var seen = Set<String>()
        for list in filterLists where list.isEnabled && !indexedListURLs.contains(list.url) {
            guard let cached = loadRuleCache(for: list, kind: .network) else { continue }
            for rule in cached where seen.insert(rule).inserted {
                rules.append(rule)
                if rules.count == maxJavaScriptNetworkRules {
                    return rules
                }
            }
        }
        return rules
    }

    private func updateContentBlockingRules() {
        Task {
            await loadContentBlockingRules()
        }
    }

    private func loadContentBlockingRules() async {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            await loadNativeResourceRules()
            return
        }
        guard Self.nativeContentRuleListsSupported,
              let contentRuleListStore else {
            activeRuleList = nil
            customRuleList = nil
            return
        }

        guard isEnabled else {
            removeNativeRulesFromAllWebViews()
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
                        self.replaceActiveRuleList(with: cachedList)
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
                            "url-filter": pattern,
                            "load-type": ["third-party"]
                        ],
                        "action": [
                            "type": "block"
                        ]
                    ]
                    jsonRules.append(rule)
                }
            }
        }

        // Hard-coded targets use an anchored host boundary. Host-only targets
        // apply only to third-party loads so visiting the service itself still
        // works; path-specific ad endpoints can also be blocked first-party.
        let thirdPartyResourceTypes = normalizedResourceTypes([
            "script", "image", "style-sheet", "raw", "font", "media", "popup", "document"
        ])
        let endpointResourceTypes = normalizedResourceTypes([
            "script", "image", "style-sheet", "raw", "font", "media"
        ])

        for rawTarget in adNetworkDomains {
            guard let target = AdBlockContentRulePolicy.target(from: rawTarget) else { continue }
            var trigger: [String: Any] = [
                "url-filter": AdBlockContentRulePolicy.urlFilter(for: target),
                "resource-type": target.path == nil ? thirdPartyResourceTypes : endpointResourceTypes
            ]
            if target.path == nil {
                trigger["load-type"] = ["third-party"]
            }
            jsonRules.append([
                "trigger": trigger,
                "action": ["type": "block"]
            ])
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
                self.replaceActiveRuleList(with: ruleList)
                print("DEBUG: Applied rules to \(self.registeredWebViews.allObjects.count) WebViews")
            }
        } catch {
            print("DEBUG: Failed to compile content blocking rules: \(error)")
            print("DEBUG: Error details: \(error.localizedDescription)")
        }
    }
    
    private func loadNativeResourceRules() async {
        nativeResourceGeneration += 1
        let generation = nativeResourceGeneration
        guard NativeAdResourceRules.isSupported, let store = contentRuleListStore else {
            replaceActiveRuleList(with: nil)
            nativeResourceRuleCount = 0
            nativeResourceStatus = "JavaScript only: unverified OS/SDK"
            return
        }
        guard isEnabled else {
            removeNativeRulesFromAllWebViews()
            nativeResourceStatus = "Paused"
            return
        }
        let indexIdentity = indexedSnapshot.identity
        let indexJSON = indexedSnapshot.json
        let preferred = adNetworkDomains
        guard indexJSON != "{}" else {
            replaceActiveRuleList(with: nil)
            nativeResourceRuleCount = 0
            nativeResourceStatus = "Waiting for filter index"
            return
        }
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try NativeAdResourceRules.make(indexJSON: indexJSON, preferredHosts: preferred)
            }.value
            guard generation == nativeResourceGeneration, indexIdentity == indexedSnapshot.identity else { return }
            guard snapshot.blocks > 0 else {
                replaceActiveRuleList(with: nil)
                nativeResourceRuleCount = 0
                nativeResourceStatus = "No native resource rules"
                return
            }
            let rule = try await compiledNativeResources(snapshot, store: store)
            guard generation == nativeResourceGeneration, indexIdentity == indexedSnapshot.identity else { return }
            replaceActiveRuleList(with: rule)
            nativeResourceRuleCount = snapshot.blocks
            nativeResourceStatus = isEnabled ? "Active: pre-load resource blocking" : "Paused"
        } catch {
            guard generation == nativeResourceGeneration else { return }
            // Fail to JS-only, rather than attach an incomplete exception set or stale rules.
            replaceActiveRuleList(with: nil)
            nativeResourceRuleCount = 0
            nativeResourceStatus = "JavaScript only: native rules unavailable"
            print("Native resource rules unavailable: \(error)")
        }
    }

    /// Serialize compilation under our own identifier; concurrent list edits share work
    /// but only the latest requested snapshot may be attached to live WebViews.
    private func compiledNativeResources(_ snapshot: NativeAdResourceRules.Snapshot, store: WKContentRuleListStore) async throws -> WKContentRuleList? {
        while let work = nativeResourceWork {
            if work.identity == snapshot.identity { return try await work.task.value }
            _ = try? await work.task.value
            if nativeResourceWork?.token == work.token { nativeResourceWork = nil }
        }
        let token = UUID()
        let task = Task { @MainActor [defaults] () throws -> WKContentRuleList? in
            if defaults.string(forKey: NativeAdResourceRules.hashKey) == snapshot.identity,
               let cached = try? await store.lookupContentRuleListAsync(forIdentifier: NativeAdResourceRules.identifier) {
                return cached
            }
            let rule = try await store.compileContentRuleListAsync(forIdentifier: NativeAdResourceRules.identifier, encodedContentRuleList: snapshot.json)
            guard rule != nil else { throw NativeAdResourceRules.BuildError.safetyBudget }
            defaults.set(snapshot.identity, forKey: NativeAdResourceRules.hashKey)
            return rule
        }
        nativeResourceWork = (token, snapshot.identity, task)
        defer { if nativeResourceWork?.token == token { nativeResourceWork = nil } }
        return try await task.value
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
        combinedString += "_v9_safe_host_boundaries"
        
        let inputData = Data(combinedString.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
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
            // Versioned indexed caches have a separate, larger byte budget and validation.
            if fileURL.lastPathComponent.hasPrefix("indexed_v") { continue }
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
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "adBlockHandler",
              let body = message.body as? [String: Any],
              body["type"] as? String == "blocked",
              let count = body["count"] as? Int,
              (0...1_000_000).contains(count) else { return }
        blockedCount = count
    }
}
