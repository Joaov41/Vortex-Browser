import Combine
import SwiftUI
import UIKit
import WebKit

@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    let id: UUID
    @Published var title: String
    @Published var address: String
    @Published var url: URL?
    @Published var favicon: UIImage?
    @Published var thumbnail: UIImage?
    @Published var isIncognito: Bool
    @Published var isReaderMode = false
    @Published var isDarkMode = false
    @Published var hasDarkModeOverride = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var groupID: UUID?
    @Published private(set) var showsHibernationIndicator: Bool

    var lastThumbnailSize: CGSize = .zero
    var lastAppliedDarkMode: Bool?
    var webAIProvider: WebAIProvider?
    private(set) var liveWebView: AIWebView?
    private(set) var lastUsedAt = Date()
    private(set) var savedScrollPosition: CGFloat = 0
    private(set) var isHibernated = true
    private(set) var isActivelyPlayingMedia = false

    var liveWebViewCounted: Bool { liveWebView != nil }

    private var canGoBackObserver: NSKeyValueObservation?
    private var canGoForwardObserver: NSKeyValueObservation?
    private var useDesktopUserAgent: Bool
    private var pendingScrollRestoration = false

    init(
        id: UUID = UUID(),
        title: String,
        url: URL? = nil,
        isIncognito: Bool = false,
        useDesktopUserAgent: Bool = false,
        groupID: UUID? = nil,
        isRestoredSessionTab: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        address = url?.absoluteString ?? ""
        self.isIncognito = isIncognito
        self.groupID = groupID
        showsHibernationIndicator = isRestoredSessionTab

        self.useDesktopUserAgent = useDesktopUserAgent
        // WebKit is created lazily. Restoring a large session therefore creates metadata only.
        isHibernated = true
    }

    var isBlank: Bool { url == nil && liveWebView?.url == nil }

    var currentURL: URL? { liveWebView?.url ?? url }

    func touch(at date: Date = Date()) {
        lastUsedAt = date
    }

    @discardableResult
    func activateWebView() -> AIWebView {
        if let liveWebView {
            touch()
            return liveWebView
        }

        let configuration = makeConfiguration()
        let created = AIWebView(frame: .zero, configuration: configuration)
        created.customUserAgent = useDesktopUserAgent ? Self.desktopUserAgent : Self.mobileUserAgent
        created.allowsLinkPreview = !isIncognito
        created.allowsBackForwardNavigationGestures = true

        AdBlockService.shared.configureWebView(created)
        if !isIncognito {
            PasswordManager.shared.configureWebView(created)
        }
        DarkModeService.shared.configureWebView(created)
        FontSizeService.shared.configureWebView(created)

        canGoBackObserver = created.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self, weak webView] in
                self?.canGoBack = webView?.canGoBack ?? false
            }
        }
        canGoForwardObserver = created.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self, weak webView] in
                self?.canGoForward = webView?.canGoForward ?? false
            }
        }

        liveWebView = created
        isHibernated = false
        showsHibernationIndicator = false
        isActivelyPlayingMedia = false
        pendingScrollRestoration = true
        touch()
        return created
    }

    func setUserAgentPreference(_ useDesktop: Bool) {
        useDesktopUserAgent = useDesktop
        liveWebView?.customUserAgent = useDesktop ? Self.desktopUserAgent : Self.mobileUserAgent
    }

    func restoreScrollPositionIfNeeded(on webView: WKWebView) {
        restoreScrollPositionIfNeeded(on: webView, attempt: 0)
    }

    private func restoreScrollPositionIfNeeded(on webView: WKWebView, attempt: Int) {
        guard pendingScrollRestoration else { return }
        let y = savedScrollPosition
        guard y > 0 else {
            pendingScrollRestoration = false
            return
        }

        // Site privacy policy installation can cause one immediate reload after didFinish. Wait for
        // the final render and non-zero content size before consuming the one-shot restoration.
        let maximumY = max(0, webView.scrollView.contentSize.height - webView.scrollView.bounds.height)
        guard !webView.isLoading, maximumY > 0 || attempt >= 5 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak webView] in
                guard let self, let webView, self.liveWebView === webView else { return }
                self.restoreScrollPositionIfNeeded(on: webView, attempt: attempt + 1)
            }
            return
        }

        pendingScrollRestoration = false
        DispatchQueue.main.async { [weak webView] in
            guard let webView, !webView.isLoading else { return }
            webView.scrollView.setContentOffset(
                CGPoint(x: webView.scrollView.contentOffset.x, y: min(y, maximumY)),
                animated: false
            )
        }
    }

    func recordScrollPosition(_ value: CGFloat) {
        savedScrollPosition = max(0, value)
    }

    func recordMediaPlaybackState(_ isPlaying: Bool) {
        isActivelyPlayingMedia = isPlaying
    }

    /// WebKit's public asynchronous media state is authoritative. A suspended or paused page can be
    /// recreated safely; a playing page remains resident so audio/video is never interrupted.
    func refreshMediaPlaybackState() async -> Bool {
        guard let liveWebView else {
            isActivelyPlayingMedia = false
            return false
        }
        let result: Bool = await withCheckedContinuation { continuation in
            liveWebView.requestMediaPlaybackState { state in
                continuation.resume(returning: state == .playing)
            }
        }
        isActivelyPlayingMedia = result
        return result
    }

    /// Persists URL, title, thumbnail and scroll, then releases WebKit. V1 does not persist arbitrary
    /// JavaScript/form/back-forward-list state.
    func hibernate(shouldProceed: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        guard let webView = liveWebView else {
            isHibernated = true
            return false
        }

        url = webView.url ?? url
        address = url?.absoluteString ?? address
        title = webView.title ?? title
        savedScrollPosition = max(0, webView.scrollView.contentOffset.y)

        if webView.url != nil {
            await captureSnapshot(from: webView)
        }

        // Selection, split state, loading and media can all change while the asynchronous snapshot
        // is in flight. Recheck at the last possible moment before releasing WebKit.
        guard !Task.isCancelled,
              shouldProceed(),
              liveWebView === webView,
              !webView.isLoading,
              !isIncognito,
              webAIProvider == nil,
              !(await refreshMediaPlaybackState()) else { return false }
        canGoBackObserver?.invalidate()
        canGoForwardObserver?.invalidate()
        canGoBackObserver = nil
        canGoForwardObserver = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.scrollView.delegate = nil
        webView.scrollView.refreshControl = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        liveWebView = nil
        isHibernated = true
        showsHibernationIndicator = true
        isActivelyPlayingMedia = false
        pendingScrollRestoration = true
        canGoBack = false
        canGoForward = false
        return true
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        if isIncognito {
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.allowsAirPlayForMediaPlayback = false
            configuration.dataDetectorTypes = []
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: IncognitoMode.shared.getPrivacyScript(),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        } else {
            configuration.websiteDataStore = .default()
        }
        return configuration
    }

    private func captureSnapshot(from webView: WKWebView) async {
        let configuration = WKSnapshotConfiguration()
        let size = webView.scrollView.bounds.size
        if size.width > 1, size.height > 1 {
            configuration.snapshotWidth = NSNumber(value: 280)
        }
        guard let image: UIImage = await withCheckedContinuation({ continuation in
            webView.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }), liveWebView === webView else { return }

        let scale = image.scale
        let pixelWidth = image.size.width * scale
        let pixelHeight = image.size.height * scale
        let targetHeight = min(pixelHeight, pixelWidth * 0.75)
        let cropRect = CGRect(x: 0, y: 0, width: pixelWidth, height: targetHeight)
        if let cgImage = image.cgImage, let cropped = cgImage.cropping(to: cropRect) {
            thumbnail = UIImage(cgImage: cropped, scale: scale, orientation: image.imageOrientation)
        } else {
            thumbnail = image
        }
        lastThumbnailSize = size
    }
}

struct Favorite: Identifiable, Codable {
    let id: UUID
    let title: String
    let url: URL
    let dateAdded: Date
    var favicon: Data?

    init(id: UUID = UUID(), title: String, url: URL, dateAdded: Date, favicon: Data? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.dateAdded = dateAdded
        self.favicon = favicon
    }
}

struct BrowserTabGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date

    init(id: UUID = UUID(), title: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }
}

struct RecentlyClosedTab: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let url: URL
    let groupID: UUID?
    let closedAt: Date
}

enum BrowserTabScope: Hashable {
    case all
    case ungrouped
    case group(UUID)
}

enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckDuckGo

    static let defaultsKey = "browser_default_search_engine_v1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        }
    }

    var homeURL: URL {
        switch self {
        case .google:
            return URL(string: "https://www.google.com")!
        case .duckDuckGo:
            return URL(string: "https://duckduckgo.com")!
        }
    }

    func searchURL(for query: String) -> URL? {
        var components = URLComponents(url: homeURL, resolvingAgainstBaseURL: false)
        components?.path = self == .google ? "/search" : "/"
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

private struct BrowserSessionSnapshot: Codable {
    struct Tab: Codable {
        let id: UUID
        let title: String
        let url: URL
        let groupID: UUID?
    }

    let tabs: [Tab]
    let selectedTabID: UUID?
}

@MainActor
final class BrowserViewModel: ObservableObject {
    /// iPad has a relatively small WebContent-process budget when many pages are open. Eight live
    /// views keeps the foreground experience responsive while leaving the remaining tabs metadata-only.
    static let defaultLiveWebViewBudget = 8

    @Published var tabs: [BrowserTab] = []
    @Published var selectedTabID: UUID?
    @Published var showSafari = false
    @Published var safariURL: URL?
    @Published var favorites: [Favorite] = []
    @Published var tabGroups: [BrowserTabGroup] = []
    @Published var recentlyClosedTabs: [RecentlyClosedTab] = []
    @Published var defaultSearchEngine: BrowserSearchEngine {
        didSet {
            defaults.set(defaultSearchEngine.rawValue, forKey: BrowserSearchEngine.defaultsKey)
        }
    }

    var isSplitViewActive = false

    private var useDesktopUserAgent = false
    private let favoritesKey = "browser_favorites"
    private let groupsKey = "browser_tab_groups_v1"
    private let recentlyClosedKey = "browser_recently_closed_v1"
    private let sessionKey = "browser_session_v1"
    private let defaults: UserDefaults
    private var protectedTabIDs = Set<UUID>()
    private var enforcementTask: Task<Void, Never>?
    private var memoryWarningObserver: NSObjectProtocol?

    var liveTabCount: Int { tabs.reduce(into: 0) { if $1.liveWebView != nil { $0 += 1 } } }
    var hibernatedTabCount: Int { tabs.count - liveTabCount }
    var liveWebViewBudget = BrowserViewModel.defaultLiveWebViewBudget {
        didSet { enforceWebViewBudget() }
    }

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        defaultSearchEngine = BrowserSearchEngine(
            rawValue: userDefaults.string(forKey: BrowserSearchEngine.defaultsKey) ?? ""
        ) ?? .google
        loadFavorites()
        loadGroups()
        loadRecentlyClosedTabs()
        if !restoreSession() {
            openInitialTab()
        }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        enforcementTask?.cancel()
    }

    var selectedIndex: Int? {
        guard let id = selectedTabID else { return nil }
        return tabs.firstIndex(where: { $0.id == id })
    }

    func tabs(matching searchText: String, scope: BrowserTabScope) -> [BrowserTab] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tabs.filter { tab in
            let matchesGroup: Bool
            switch scope {
            case .all:
                matchesGroup = true
            case .ungrouped:
                matchesGroup = tab.groupID == nil
            case .group(let groupID):
                matchesGroup = tab.groupID == groupID
            }
            let matchesSearch = normalizedSearch.isEmpty
                || tab.title.lowercased().contains(normalizedSearch)
                || tab.address.lowercased().contains(normalizedSearch)
                || (tab.currentURL?.absoluteString.lowercased().contains(normalizedSearch) == true)
            return matchesGroup && matchesSearch
        }
    }

    func setUserAgentPreference(_ useDesktop: Bool) {
        useDesktopUserAgent = useDesktop
        tabs.forEach { $0.setUserAgentPreference(useDesktop) }
        enforceWebViewBudget()
    }

    func updateProtectedTabIDs(_ ids: Set<UUID>) {
        protectedTabIDs = ids
        if let selectedTabID { protectedTabIDs.insert(selectedTabID) }
        enforceWebViewBudget()
    }

    func selectTab(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        selectedTabID = tab.id
        tab.touch()
        protectedTabIDs.insert(tab.id)
        _ = tab.activateWebView()
        enforceWebViewBudget()
    }

    /// Activates only the selected tab. Reopening a session never eagerly recreates inactive pages.
    func activateSelectedTab() {
        guard let selectedTabID,
              let tab = tabs.first(where: { $0.id == selectedTabID }) else { return }
        protectedTabIDs.insert(selectedTabID)
        _ = tab.activateWebView()
        enforceWebViewBudget()
    }

    func enforceWebViewBudget(aggressive: Bool = false) {
        enforcementTask?.cancel()
        let target = aggressive ? max(1, liveWebViewBudget / 2) : liveWebViewBudget
        enforcementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let candidates = self.evictionCandidateTabs()

            var liveCount = self.liveTabCount
            for tab in candidates where liveCount > target {
                if Task.isCancelled { return }
                // Re-evaluate WebKit's media state immediately before eviction.
                if await tab.refreshMediaPlaybackState() { continue }
                guard !self.protectedTabIDs.contains(tab.id), tab.id != self.selectedTabID else { continue }
                if await tab.hibernate(shouldProceed: { [weak self, weak tab] in
                    guard let self, let tab else { return false }
                    return !self.protectedTabIDs.contains(tab.id)
                        && tab.id != self.selectedTabID
                        && !tab.isIncognito
                        && tab.webAIProvider == nil
                        && tab.liveWebView?.isLoading != true
                }) { liveCount -= 1 }
            }
        }
    }

    /// Stable, synchronous portion of the policy exposed for focused tests and diagnostics. Media
    /// playback is rechecked asynchronously in `enforceWebViewBudget` immediately before release.
    func evictionCandidateIDs() -> [UUID] {
        evictionCandidateTabs().map(\.id)
    }

    private func evictionCandidateTabs() -> [BrowserTab] {
        let protected = protectedTabIDs.union(selectedTabID.map { [$0] } ?? [])
        return tabs
            .filter { $0.liveWebView != nil }
            .filter { !protected.contains($0.id) }
            .filter { !$0.isIncognito && $0.webAIProvider == nil }
            .filter { !$0.isActivelyPlayingMedia }
            .filter { $0.liveWebView?.isLoading != true }
            .sorted { $0.lastUsedAt < $1.lastUsedAt }
    }

    func handleMemoryWarning() {
        enforceWebViewBudget(aggressive: true)
    }

    func addTabBlank() {
        let homeURL = defaultSearchEngine.homeURL
        let tab = BrowserTab(
            title: "New Tab",
            url: homeURL,
            useDesktopUserAgent: useDesktopUserAgent
        )
        tab.address = homeURL.absoluteString
        tabs.append(tab)
        selectedTabID = tab.id
        protectedTabIDs.insert(tab.id)
        saveSession()
        enforceWebViewBudget()
    }

    func openFavoriteInNewTab(_ favorite: Favorite, groupID: UUID? = nil) {
        let tab = BrowserTab(
            title: favorite.title,
            url: favorite.url,
            useDesktopUserAgent: useDesktopUserAgent,
            groupID: groupID
        )
        if let data = favorite.favicon { tab.favicon = UIImage(data: data) }
        tabs.append(tab)
        selectedTabID = tab.id
        protectedTabIDs.insert(tab.id)
        if tab.favicon == nil { fetchFavicon(for: tab) }
        saveSession()
        enforceWebViewBudget()
    }

    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if !tab.isIncognito, let url = tab.currentURL {
            recentlyClosedTabs.insert(
                RecentlyClosedTab(
                    id: UUID(),
                    title: tab.title,
                    url: url,
                    groupID: tab.groupID,
                    closedAt: Date()
                ),
                at: 0
            )
            recentlyClosedTabs = Array(recentlyClosedTabs.prefix(30))
            saveRecentlyClosedTabs()
        }

        tabs.remove(at: index)
        protectedTabIDs.remove(tab.id)
        if tabs.isEmpty {
            addTabBlank()
        } else {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
            protectedTabIDs.insert(selectedTabID!)
            saveSession()
        }
        enforceWebViewBudget()
    }

    func reopenRecentlyClosed(_ record: RecentlyClosedTab) {
        let tab = BrowserTab(
            title: record.title,
            url: record.url,
            useDesktopUserAgent: useDesktopUserAgent,
            groupID: tabGroups.contains(where: { $0.id == record.groupID }) ? record.groupID : nil
        )
        tabs.append(tab)
        selectedTabID = tab.id
        protectedTabIDs.insert(tab.id)
        recentlyClosedTabs.removeAll { $0.id == record.id }
        saveRecentlyClosedTabs()
        saveSession()
        enforceWebViewBudget()
    }

    func clearRecentlyClosed() {
        recentlyClosedTabs.removeAll()
        saveRecentlyClosedTabs()
    }

    @discardableResult
    func createTabGroup(title: String) -> BrowserTabGroup {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = BrowserTabGroup(title: trimmed.isEmpty ? "New Group" : trimmed)
        tabGroups.append(group)
        saveGroups()
        return group
    }

    func renameTabGroup(_ group: BrowserTabGroup, title: String) {
        guard let index = tabGroups.firstIndex(where: { $0.id == group.id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tabGroups[index].title = trimmed
        saveGroups()
    }

    func deleteTabGroup(_ group: BrowserTabGroup) {
        tabGroups.removeAll { $0.id == group.id }
        tabs.filter { $0.groupID == group.id }.forEach { $0.groupID = nil }
        saveGroups()
        saveSession()
    }

    func move(_ tab: BrowserTab, to groupID: UUID?) {
        tab.groupID = groupID
        // BrowserViewModel's filtered sidebar data depends on child tab state. Publish the parent
        // change so a selected group recomputes immediately after a tab is moved.
        objectWillChange.send()
        saveSession()
    }

    func submitAddress(_ text: String, for tab: BrowserTab) {
        guard let url = destinationURL(from: text) else { return }
        navigate(to: url, in: tab)
    }

    func navigate(to url: URL, in tab: BrowserTab) {
        if !tab.isIncognito && handleAuthIfNeeded(for: url) { return }
        tab.url = url
        tab.address = url.absoluteString
        protectedTabIDs.insert(tab.id)
        let webView = tab.activateWebView()
        saveSession()

        if !AdBlockService.shared.isReady {
            Task {
                for _ in 0..<30 {
                    if AdBlockService.shared.isReady { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                await MainActor.run { _ = webView.load(URLRequest(url: url)) }
            }
        } else {
            webView.load(URLRequest(url: url))
        }
        fetchFavicon(for: tab)
        enforceWebViewBudget()
    }

    func fetchFavicon(for tab: BrowserTab) {
        guard let host = tab.url?.host,
              let faviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(host)") else { return }
        URLSession.shared.dataTask(with: faviconURL) { data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            Task { @MainActor in tab.favicon = image }
        }.resume()
    }

    func captureTabThumbnail(for tab: BrowserTab, targetSize: CGSize? = nil) {
        guard !tab.isBlank, let webView = tab.liveWebView else { return }
        let configuration = WKSnapshotConfiguration()
        let effectiveSize = targetSize ?? webView.scrollView.bounds.size
        guard effectiveSize.width > 1, effectiveSize.height > 1 else { return }
        configuration.snapshotWidth = NSNumber(value: 280)
        webView.takeSnapshot(with: configuration) { image, _ in
            guard let image else { return }
            let scale = image.scale
            let pixelWidth = image.size.width * scale
            let pixelHeight = image.size.height * scale
            let targetHeight = min(pixelHeight, pixelWidth * 0.75)
            let cropRect = CGRect(x: 0, y: 0, width: pixelWidth, height: targetHeight)
            let output: UIImage
            if let cgImage = image.cgImage, let cropped = cgImage.cropping(to: cropRect) {
                output = UIImage(cgImage: cropped, scale: scale, orientation: image.imageOrientation)
            } else {
                output = image
            }
            Task { @MainActor in
                tab.lastThumbnailSize = effectiveSize
                tab.thumbnail = output
            }
        }
    }

    func handleAuthIfNeeded(for url: URL) -> Bool {
        false
    }

    func addToFavorites(_ tab: BrowserTab) {
        guard let url = tab.currentURL, !favorites.contains(where: { $0.url == url }) else { return }
        favorites.append(
            Favorite(
                title: tab.title,
                url: url,
                dateAdded: Date(),
                favicon: tab.favicon?.pngData()
            )
        )
        saveFavorites()
    }

    func removeFromFavorites(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
        saveFavorites()
    }

    func isFavorite(_ url: URL?) -> Bool {
        guard let url else { return false }
        return favorites.contains { $0.url == url }
    }

    func saveSession() {
        let persistentTabs = tabs.compactMap { tab -> BrowserSessionSnapshot.Tab? in
            guard !tab.isIncognito, tab.webAIProvider == nil, let url = tab.currentURL else { return nil }
            return .init(id: tab.id, title: tab.title, url: url, groupID: tab.groupID)
        }
        let selectedID = persistentTabs.contains(where: { $0.id == selectedTabID }) ? selectedTabID : persistentTabs.first?.id
        let snapshot = BrowserSessionSnapshot(tabs: persistentTabs, selectedTabID: selectedID)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: sessionKey)
        }
    }

    private func openInitialTab() {
        let start = defaultSearchEngine.homeURL
        let tab = BrowserTab(
            title: defaultSearchEngine.displayName,
            url: start,
            useDesktopUserAgent: useDesktopUserAgent
        )
        tabs = [tab]
        selectedTabID = tab.id
        protectedTabIDs.insert(tab.id)
        fetchFavicon(for: tab)
    }

    private func restoreSession() -> Bool {
        guard let data = defaults.data(forKey: sessionKey),
              let snapshot = try? JSONDecoder().decode(BrowserSessionSnapshot.self, from: data),
              !snapshot.tabs.isEmpty else { return false }
        tabs = snapshot.tabs.map { saved in
            BrowserTab(
                id: saved.id,
                title: saved.title,
                url: saved.url,
                useDesktopUserAgent: useDesktopUserAgent,
                groupID: tabGroups.contains(where: { $0.id == saved.groupID }) ? saved.groupID : nil,
                isRestoredSessionTab: true
            )
        }
        selectedTabID = tabs.contains(where: { $0.id == snapshot.selectedTabID }) ? snapshot.selectedTabID : tabs.first?.id
        if let selectedTabID { protectedTabIDs.insert(selectedTabID) }
        tabs.forEach(fetchFavicon)
        return true
    }

    func destinationURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        if trimmed.lowercased() == "localhost" || trimmed.contains(".") {
            return URL(string: "https://\(trimmed)")
        }
        return defaultSearchEngine.searchURL(for: trimmed)
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            defaults.set(data, forKey: favoritesKey)
        }
    }

    private func loadFavorites() {
        guard let data = defaults.data(forKey: favoritesKey),
              let decoded = try? JSONDecoder().decode([Favorite].self, from: data) else { return }
        favorites = decoded
    }

    private func saveGroups() {
        if let data = try? JSONEncoder().encode(tabGroups) {
            defaults.set(data, forKey: groupsKey)
        }
    }

    private func loadGroups() {
        guard let data = defaults.data(forKey: groupsKey),
              let decoded = try? JSONDecoder().decode([BrowserTabGroup].self, from: data) else { return }
        tabGroups = decoded
    }

    private func saveRecentlyClosedTabs() {
        if let data = try? JSONEncoder().encode(recentlyClosedTabs) {
            defaults.set(data, forKey: recentlyClosedKey)
        }
    }

    private func loadRecentlyClosedTabs() {
        guard let data = defaults.data(forKey: recentlyClosedKey),
              let decoded = try? JSONDecoder().decode([RecentlyClosedTab].self, from: data) else { return }
        recentlyClosedTabs = decoded
    }
}
