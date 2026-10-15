import Foundation
import WebKit

/// Narrow access to the browser models used by Browser Agent's optional tools.
/// Every lookup is scoped to the privacy mode of the tab that began the run.
@MainActor
final class BrowserAgentBrowserAdapter {
    struct Tab: Equatable, Identifiable {
        let id: UUID
        let title: String
        let url: String?
        let isSelected: Bool
        let groupID: UUID?
    }

    struct Group: Equatable, Identifiable {
        let id: UUID
        let title: String
        let tabCount: Int
    }

    struct Bookmark: Equatable, Identifiable {
        let id: UUID
        let title: String
        let url: String
        let folderID: UUID?
    }

    struct BookmarkFolder: Equatable, Identifiable {
        let id: UUID
        let title: String
        let parentID: UUID?
    }

    struct Download: Equatable, Identifiable {
        let id: UUID
        let filename: String
        let sourceURL: String?
        let state: String
        let progress: Double
        let failure: String?
    }

    struct HistoryMatch: Equatable, Identifiable {
        let id: UUID
        let title: String
        let url: String
        let visitedAt: Date
    }

    enum AccessError: LocalizedError, Equatable {
        case unsupportedStartingTab
        case runNotStarted
        case staleOrUnsupportedTab
        case staleSource
        case privateFeatureUnavailable
        case historyUnavailableInPrivate
        case invalidQuery
        case lastAccessibleTab
        case unknownGroup
        case unknownBookmark
        case unknownDownload
        case invalidURL
        case downloadFailed(String)
        case fileTooLarge
        case fileWriteFailed
        case exportQueueRejected

        var errorDescription: String? {
            switch self {
            case .unsupportedStartingTab:
                return "This page is not an available browser tab for the agent. The existing page tools are still available."
            case .runNotStarted:
                return "This browser feature is unavailable for the current agent run."
            case .staleOrUnsupportedTab:
                return "That tab is no longer available in this run's browsing context. Refresh the tab list and try again."
            case .staleSource:
                return "The source tab is no longer available in this run's browsing context."
            case .privateFeatureUnavailable:
                return "Groups and Favorites are unavailable during private browsing because those changes persist outside the private session."
            case .historyUnavailableInPrivate:
                return "History search is unavailable during private browsing."
            case .invalidQuery:
                return "Provide a search query between 1 and 240 characters."
            case .lastAccessibleTab:
                return "The last tab in this run's privacy mode cannot be closed."
            case .unknownGroup:
                return "That tab group is no longer available. Refresh the group list and try again."
            case .unknownBookmark:
                return "That Favorite is no longer available. Refresh the list and try again."
            case .unknownDownload:
                return "That download is no longer available in this browsing context."
            case .invalidURL:
                return "This action needs a valid http or https web address."
            case .downloadFailed(let reason):
                return "The browser could not start that download: \(reason)"
            case .fileTooLarge:
                return "The generated file exceeds the browser's export size limit."
            case .fileWriteFailed:
                return "The browser could not prepare the export file."
            case .exportQueueRejected:
                return "The browser could not add the export to its Files save queue."
            }
        }
    }

    typealias ReaderModeAction = @MainActor (UUID, Bool) async throws -> Void
    typealias TranslationAction = @MainActor (UUID, String?, @escaping @MainActor () -> Bool) async throws -> String
    typealias TranslationStatusAction = @MainActor (UUID) -> String
    typealias OriginalPageAction = @MainActor (UUID) async throws -> Void
    typealias SplitPairAction = @MainActor (UUID, UUID, Bool) -> Void

    private let viewModel: BrowserViewModel
    private let downloadManager: BrowserDownloadManager
    private let historyStore: HistoryStore
    private let onTabSelected: (UUID) -> Void
    private let onSplitPairOpened: SplitPairAction?
    private let readerModeAction: ReaderModeAction?
    private let translationAction: TranslationAction?
    private let translationStatusAction: TranslationStatusAction?
    private let originalPageAction: OriginalPageAction?
    private var runIsIncognito: Bool?
    private var startingTabID: UUID?

    init(
        viewModel: BrowserViewModel,
        downloadManager: BrowserDownloadManager,
        onTabSelected: @escaping (UUID) -> Void,
        historyStore: HistoryStore? = nil,
        onSplitPairOpened: SplitPairAction? = nil,
        readerModeAction: ReaderModeAction? = nil,
        translationAction: TranslationAction? = nil,
        translationStatusAction: TranslationStatusAction? = nil,
        originalPageAction: OriginalPageAction? = nil
    ) {
        self.viewModel = viewModel
        self.downloadManager = downloadManager
        self.historyStore = historyStore ?? .shared
        self.onTabSelected = onTabSelected
        self.onSplitPairOpened = onSplitPairOpened
        self.readerModeAction = readerModeAction
        self.translationAction = translationAction
        self.translationStatusAction = translationStatusAction
        self.originalPageAction = originalPageAction
    }

    /// Fixes the run privacy boundary to the starting tab. Failure disables only new tools.
    @discardableResult
    func beginRun(in webView: WKWebView) -> Bool {
        guard let tab = viewModel.tabs.first(where: { $0.liveWebView === webView }),
              tab.webAIProvider == nil else {
            runIsIncognito = nil
            startingTabID = nil
            return false
        }
        runIsIncognito = tab.isIncognito
        startingTabID = tab.id
        return true
    }

    func endRun() {
        runIsIncognito = nil
        startingTabID = nil
    }

    var runIncognitoMode: Bool? { runIsIncognito }

    /// Reads the real tab mode before beginRun fixes the adapter scope. This is
    /// also used when the starting tab is a web-provider tab that the optional
    /// agent adapter intentionally refuses to manage.
    func startingTabIsIncognito(for webView: WKWebView) -> Bool? {
        viewModel.tabs.first(where: { $0.liveWebView === webView })?.isIncognito
    }

    func availableTabs(redact: ((String) -> String)? = nil) throws -> [Tab] {
        guard let runIsIncognito else { throw AccessError.runNotStarted }
        return viewModel.tabs.compactMap { tab in
            guard tab.isIncognito == runIsIncognito, tab.webAIProvider == nil else { return nil }
            return Tab(
                id: tab.id,
                title: Self.safeTitle(redact?(tab.title) ?? tab.title, limit: 120),
                url: tab.currentURL.flatMap { Self.safeMetadataURL($0, redacting: redact) },
                isSelected: viewModel.selectedTabID == tab.id,
                groupID: runIsIncognito ? nil : tab.groupID
            )
        }.prefix(60).map { $0 }
    }

    func tabTitle(id: UUID, redact: ((String) -> String)? = nil) throws -> String {
        guard let tab = allowedTab(id: id) else { throw AccessError.staleOrUnsupportedTab }
        return Self.safeTitle(redact?(tab.title) ?? tab.title, limit: 120)
    }

    /// Uses the model's normal selection path so a hibernated tab is activated and protected.
    func switchToTab(id rawID: String) throws -> (webView: WKWebView, tabID: UUID, needsRestoreWait: Bool, expectedURL: URL?) {
        guard let id = UUID(uuidString: rawID), let tab = allowedTab(id: id) else {
            throw AccessError.staleOrUnsupportedTab
        }
        let wasHibernated = tab.liveWebView == nil
        let expectedURL = tab.currentURL
        viewModel.selectTab(tab)
        let webView = tab.activateWebView()
        guard tab.liveWebView === webView, allowedTab(id: id) === tab else {
            throw AccessError.staleOrUnsupportedTab
        }
        onTabSelected(id)
        return (webView, id, wasHibernated && expectedURL != nil, expectedURL)
    }

    /// Closes a tab only when another regular/private tab remains in the run's fixed scope.
    /// BrowserViewModel may select any neighboring tab, so this method repairs selection before
    /// returning to the agent and never leaves it on a provider or another privacy mode.
    func closeTab(id: UUID) throws -> (webView: WKWebView, tabID: UUID, needsRestoreWait: Bool, expectedURL: URL?) {
        guard let runIsIncognito else { throw AccessError.runNotStarted }
        guard let tab = allowedTab(id: id),
              let originalIndex = viewModel.tabs.firstIndex(where: { $0.id == id }) else {
            throw AccessError.staleOrUnsupportedTab
        }
        let inScope = viewModel.tabs.filter { $0.isIncognito == runIsIncognito && $0.webAIProvider == nil }
        guard inScope.count > 1 else { throw AccessError.lastAccessibleTab }

        viewModel.closeTab(tab)
        let remaining = viewModel.tabs.filter { $0.isIncognito == runIsIncognito && $0.webAIProvider == nil }
        guard !remaining.isEmpty else { throw AccessError.lastAccessibleTab }
        let selected = remaining.first(where: { $0.id == viewModel.selectedTabID }) ?? remaining.min { lhs, rhs in
            let lhsIndex = viewModel.tabs.firstIndex(where: { $0.id == lhs.id }) ?? originalIndex
            let rhsIndex = viewModel.tabs.firstIndex(where: { $0.id == rhs.id }) ?? originalIndex
            return abs(lhsIndex - originalIndex) < abs(rhsIndex - originalIndex)
        } ?? remaining[0]
        let wasHibernated = selected.liveWebView == nil
        let expectedURL = selected.currentURL
        viewModel.selectTab(selected)
        let webView = selected.activateWebView()
        guard selected.isIncognito == runIsIncognito, selected.webAIProvider == nil,
              allowedTab(id: selected.id) === selected, selected.liveWebView === webView else {
            throw AccessError.staleOrUnsupportedTab
        }
        onTabSelected(selected.id)
        return (webView, selected.id, wasHibernated && expectedURL != nil, expectedURL)
    }

    func historyMatches(query rawQuery: String, redact: ((String) -> String)? = nil) throws -> [HistoryMatch] {
        guard let runIsIncognito else { throw AccessError.runNotStarted }
        guard !runIsIncognito else { throw AccessError.historyUnavailableInPrivate }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 240 else { throw AccessError.invalidQuery }
        return historyStore.suggestions(for: query, limit: 10).compactMap { entry in
            guard let url = Self.safeMetadataURL(entry.url, redacting: redact) else { return nil }
            return HistoryMatch(
                id: entry.id,
                title: Self.safeTitle(redact?(entry.title) ?? entry.title, limit: 120),
                url: url,
                visitedAt: entry.visitedAt
            )
        }
    }

    func searchURL(query rawQuery: String) throws -> URL {
        guard runIsIncognito != nil else { throw AccessError.runNotStarted }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 240, let url = viewModel.defaultSearchEngine.searchURL(for: query) else {
            throw AccessError.invalidQuery
        }
        return url
    }

    func setDesktopMode(tabID: UUID, enabled: Bool) throws -> (webView: WKWebView, tabID: UUID, expectedURL: URL?) {
        guard let tab = allowedTab(id: tabID),
              let scheme = tab.currentURL?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AccessError.staleOrUnsupportedTab
        }
        let wasHibernated = tab.liveWebView == nil
        let expectedURL = tab.currentURL
        viewModel.selectTab(tab)
        let webView = tab.activateWebView()
        tab.setUserAgentPreference(enabled)
        webView.reload()
        onTabSelected(tabID)
        return (webView, tabID, wasHibernated ? expectedURL : nil)
    }

    func openSplit(
        url: URL,
        besideTabID: UUID
    ) throws -> (webView: WKWebView, tabID: UUID, expectedURL: URL?, secondaryTabID: UUID) {
        guard let runIsIncognito,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              let source = allowedTab(id: besideTabID),
              let sourceIndex = viewModel.tabs.firstIndex(where: { $0.id == besideTabID }) else {
            throw AccessError.invalidURL
        }
        let tab = BrowserTab(
            title: Self.safeTitle(url.host ?? "New Tab", limit: 120),
            url: url,
            isIncognito: runIsIncognito,
            groupID: runIsIncognito ? nil : source.groupID
        )
        viewModel.tabs.insert(tab, at: sourceIndex + 1)
        viewModel.selectTab(tab)
        viewModel.navigate(to: url, in: tab)
        viewModel.setSplitPair(primaryID: source.id, secondaryID: tab.id, isHorizontal: false)
        onSplitPairOpened?(source.id, tab.id, false)
        // The agent keeps working in its original tab; reselecting the primary
        // still presents both split panes.
        viewModel.selectTab(source)
        onTabSelected(source.id)
        return (source.activateWebView(), source.id, nil, tab.id)
    }

    func hideElement(selector: String, tabID: UUID) async throws -> Bool {
        guard let runIsIncognito, let tab = allowedTab(id: tabID),
              let webView = tab.liveWebView else { throw AccessError.staleSource }
        let hidden = await DistractionHider.hide(selector: selector, in: webView, isIncognito: runIsIncognito)
        try validateSource(tabID: tabID)
        return hidden
    }

    func validate(webView: WKWebView) throws -> UUID {
        guard let tab = viewModel.tabs.first(where: { $0.liveWebView === webView }),
              allowedTab(id: tab.id) === tab else {
            throw AccessError.staleSource
        }
        return tab.id
    }

    func validateSource(tabID: UUID) throws {
        guard allowedTab(id: tabID) != nil else { throw AccessError.staleSource }
    }

    func groups() throws -> [Group] {
        try requirePersistentFeatures()
        return viewModel.tabGroups.prefix(60).map { group in
            let count = viewModel.tabs.filter { $0.groupID == group.id && !$0.isIncognito && $0.webAIProvider == nil }.count
            return Group(id: group.id, title: Self.safeTitle(group.title, limit: 120), tabCount: count)
        }
    }

    @discardableResult
    func createGroup(title: String) throws -> Group {
        try requirePersistentFeatures()
        let group = viewModel.createTabGroup(title: bounded(title, limit: 120))
        return Group(id: group.id, title: Self.safeTitle(group.title), tabCount: 0)
    }

    func renameGroup(id: UUID, title: String) throws {
        try requirePersistentFeatures()
        guard let group = viewModel.tabGroups.first(where: { $0.id == id }) else { throw AccessError.unknownGroup }
        viewModel.renameTabGroup(group, title: bounded(title, limit: 120))
    }

    func groupTitle(id: UUID) throws -> String {
        try requirePersistentFeatures()
        guard let group = viewModel.tabGroups.first(where: { $0.id == id }) else { throw AccessError.unknownGroup }
        return Self.safeTitle(group.title, limit: 120)
    }

    func moveTab(id rawID: String, toGroupID rawGroupID: String?) throws {
        try requirePersistentFeatures()
        guard let id = UUID(uuidString: rawID), let tab = allowedTab(id: id) else { throw AccessError.staleOrUnsupportedTab }
        let groupID = rawGroupID.flatMap(UUID.init(uuidString:))
        if let rawGroupID, !rawGroupID.isEmpty, groupID == nil { throw AccessError.unknownGroup }
        if let groupID, !viewModel.tabGroups.contains(where: { $0.id == groupID }) { throw AccessError.unknownGroup }
        viewModel.move(tab, to: groupID)
    }

    func bookmarks() throws -> [Bookmark] {
        try requirePersistentFeatures()
        return viewModel.favorites.prefix(60).map { favorite in
            Bookmark(id: favorite.id, title: Self.safeTitle(favorite.title, limit: 120), url: Self.safeMetadataURL(favorite.url) ?? "", folderID: favorite.folderID)
        }
    }

    func bookmark(id: UUID) throws -> Bookmark {
        try requirePersistentFeatures()
        guard let favorite = viewModel.favorites.first(where: { $0.id == id }) else { throw AccessError.unknownBookmark }
        return Bookmark(id: favorite.id, title: Self.safeTitle(favorite.title, limit: 120), url: Self.safeMetadataURL(favorite.url) ?? "", folderID: favorite.folderID)
    }

    func bookmarkFolders() throws -> [BookmarkFolder] {
        try requirePersistentFeatures()
        return viewModel.favoriteFolders.prefix(60).map { BookmarkFolder(id: $0.id, title: Self.safeTitle($0.title, limit: 120), parentID: $0.parentID) }
    }

    @discardableResult
    func createBookmarkFolder(title: String, parentID: UUID?) throws -> BookmarkFolder {
        try requirePersistentFeatures()
        if let parentID, !viewModel.favoriteFolders.contains(where: { $0.id == parentID }) { throw AccessError.unknownGroup }
        let folder = viewModel.createFavoriteFolder(named: bounded(title, limit: 120), in: parentID)
        return BookmarkFolder(id: folder.id, title: Self.safeTitle(folder.title), parentID: folder.parentID)
    }

    @discardableResult
    func addBookmark(forTabID rawID: String, folderID: UUID?) throws -> UUID? {
        try requirePersistentFeatures()
        guard let id = UUID(uuidString: rawID), let tab = allowedTab(id: id) else { throw AccessError.staleOrUnsupportedTab }
        guard let url = tab.currentURL, BrowserAgentExtractionParser.safeSourceURL(url) != nil else { throw AccessError.invalidURL }
        if let folderID, !viewModel.favoriteFolders.contains(where: { $0.id == folderID }) { throw AccessError.unknownGroup }
        if let existing = viewModel.favorites.first(where: { $0.url == url }) {
            if existing.folderID != folderID { viewModel.moveFavorite(existing, toFolder: folderID) }
            return existing.id
        }
        viewModel.addToFavorites(tab)
        guard let created = viewModel.favorites.first(where: { $0.url == url }) else { return nil }
        if created.folderID != folderID { viewModel.moveFavorite(created, toFolder: folderID) }
        return created.id
    }

    func moveBookmark(id: UUID, toFolderID: UUID?) throws {
        try requirePersistentFeatures()
        guard let bookmark = viewModel.favorites.first(where: { $0.id == id }) else { throw AccessError.unknownBookmark }
        if let toFolderID, !viewModel.favoriteFolders.contains(where: { $0.id == toFolderID }) { throw AccessError.unknownGroup }
        viewModel.moveFavorite(bookmark, toFolder: toFolderID)
    }

    func removeBookmark(id: UUID) throws {
        try requirePersistentFeatures()
        guard let bookmark = viewModel.favorites.first(where: { $0.id == id }) else { throw AccessError.unknownBookmark }
        viewModel.removeFromFavorites(bookmark)
    }

    func downloadItems() throws -> [Download] {
        guard let runIsIncognito else { throw AccessError.runNotStarted }
        return downloadManager.items.filter { $0.isIncognito == runIsIncognito }.suffix(60).map { item in
            Download(
                id: item.id,
                filename: Self.safeTitle(item.filename, limit: 120),
                sourceURL: item.sourceURL.flatMap(Self.safeMetadataURL),
                state: Self.downloadStateName(item.state),
                progress: min(max(item.progress, 0), 1),
                failure: item.failureMessage.map { bounded($0, limit: 240) }
            )
        }
    }

    func cancelDownload(id: UUID) throws {
        guard let runIsIncognito,
              let item = downloadManager.items.first(where: { $0.id == id && $0.isIncognito == runIsIncognito }),
              item.state == .downloading else { throw AccessError.unknownDownload }
        downloadManager.cancelDownload(id: id)
    }

    /// Starts a real WebKit download and registers only the returned WKDownload with the existing manager.
    func startDownload(url rawURL: String, sourceTabID: UUID, isCurrent: @escaping @MainActor () -> Bool) async throws -> UUID {
        guard let url = Self.webURLPreservingQuery(rawURL) else { throw AccessError.invalidURL }
        try validateSource(tabID: sourceTabID)
        guard let runIsIncognito,
              let tab = allowedTab(id: sourceTabID),
              let webView = tab.liveWebView else { throw AccessError.staleSource }
        let existingIDs = Set(downloadManager.items.map(\.id))
        return try await withCheckedThrowingContinuation { continuation in
            webView.startDownload(using: URLRequest(url: url)) { [weak self, weak tab, weak webView] download in
                guard let self else {
                    download.cancel { _ in }
                    continuation.resume(throwing: AccessError.runNotStarted)
                    return
                }
                guard isCurrent(),
                      let tab, let webView, tab.liveWebView === webView,
                      (try? self.validateSource(tabID: sourceTabID)) != nil,
                      tab.isIncognito == runIsIncognito else {
                    download.cancel { _ in }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.downloadManager.register(download, sourceURL: url, isIncognito: runIsIncognito)
                if let item = self.downloadManager.items.last(where: { !existingIDs.contains($0.id) && $0.isIncognito == runIsIncognito }) {
                    continuation.resume(returning: item.id)
                } else {
                    download.cancel { _ in }
                    continuation.resume(throwing: AccessError.downloadFailed("the download manager did not register it"))
                }
            }
        }
    }

    func setReaderMode(tabID: UUID, enabled: Bool) async throws {
        guard let readerModeAction else { throw AccessError.runNotStarted }
        try validateSource(tabID: tabID)
        try await readerModeAction(tabID, enabled)
        try validateSource(tabID: tabID)
    }

    func translatePage(
        tabID: UUID,
        targetLanguage: String?,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async throws -> String {
        guard let translationAction else { throw AccessError.runNotStarted }
        try validateSource(tabID: tabID)
        let result = try await translationAction(tabID, targetLanguage, shouldContinue)
        guard shouldContinue() else { throw CancellationError() }
        try validateSource(tabID: tabID)
        return bounded(result, limit: 500)
    }

    func translationStatus(tabID: UUID) throws -> String {
        try validateSource(tabID: tabID)
        guard let tab = allowedTab(id: tabID) else { throw AccessError.staleSource }
        if let translationStatusAction { return bounded(translationStatusAction(tabID), limit: 180) }
        if let sourceLanguage = tab.translatedFrom {
            return "translated from \(bounded(sourceLanguage, limit: 80))"
        }
        if tab.isTranslating { return "in progress or waiting for the system language download/approval" }
        return "idle"
    }

    func showOriginal(tabID: UUID) async throws {
        guard let originalPageAction else { throw AccessError.runNotStarted }
        try validateSource(tabID: tabID)
        try await originalPageAction(tabID)
        try validateSource(tabID: tabID)
    }

    /// A file written for one export, with the queued Files UI item that represents it.
    struct QueuedExport {
        let id: UUID
        let fileURL: URL
    }

    /// Writes into the current BrowserDownloadManager session and queues its existing Files UI.
    @discardableResult
    func enqueueExport(
        data: Data,
        filename: String,
        sourceURL: URL?,
        sourceTabID: UUID,
        isIncognito: Bool
    ) throws -> UUID {
        try enqueueExportFile(data: data, filename: filename, sourceURL: sourceURL, sourceTabID: sourceTabID, isIncognito: isIncognito).id
    }

    func enqueueExportFile(
        data: Data,
        filename: String,
        sourceURL: URL?,
        sourceTabID: UUID,
        isIncognito: Bool
    ) throws -> QueuedExport {
        try validateSource(tabID: sourceTabID)
        guard runIsIncognito == isIncognito else { throw AccessError.staleSource }
        guard data.count <= BrowserAgentExportService.maximumExportBytes else { throw AccessError.fileTooLarge }
        let destination = downloadManager.uniqueDestinationURL(for: filename)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw AccessError.fileWriteFailed
        }
        do {
            try validateSource(tabID: sourceTabID)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        guard let id = downloadManager.enqueueCompletedFile(
            at: destination,
            suggestedFilename: destination.lastPathComponent,
            sourceURL: sourceURL.flatMap(BrowserAgentExtractionParser.safeSourceURL),
            isIncognito: isIncognito
        ) else {
            try? FileManager.default.removeItem(at: destination)
            throw AccessError.exportQueueRejected
        }
        return QueuedExport(id: id, fileURL: destination)
    }

    private func allowedTab(id: UUID) -> BrowserTab? {
        guard let runIsIncognito else { return nil }
        return viewModel.tabs.first { $0.id == id && $0.isIncognito == runIsIncognito && $0.webAIProvider == nil }
    }

    private func requirePersistentFeatures() throws {
        guard let runIsIncognito else { throw AccessError.runNotStarted }
        guard !runIsIncognito else { throw AccessError.privateFeatureUnavailable }
    }

    private static func downloadStateName(_ state: BrowserDownloadState) -> String {
        switch state {
        case .downloading: return "downloading"
        case .exportPending: return "ready to save"
        case .completed: return "saved"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private static func safeTitle(_ title: String, limit: Int = 240) -> String {
        bounded(title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), limit: limit)
    }

    private static func safeMetadataURL(_ url: URL) -> String? {
        safeMetadataURL(url, redacting: nil)
    }

    private static func safeMetadataURL(_ url: URL, redacting redact: ((String) -> String)?) -> String? {
        guard let safe = BrowserAgentExtractionParser.safeSourceURL(url)?.absoluteString else { return nil }
        let protected = redact?(safe) ?? safe
        guard protected.count > 400 else { return protected }
        return String(protected.prefix(400)) + "…[URL truncated]"
    }

    private func bounded(_ text: String, limit: Int) -> String { Self.bounded(text, limit: limit) }

    private static func bounded(_ text: String, limit: Int) -> String {
        String(text.replacingOccurrences(of: "\u{0000}", with: "").prefix(limit))
    }

    private static func webURLPreservingQuery(_ rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }
}
