import Foundation

/// Commands added for the Apple Intelligence browser schemas: load a URL in a given tab,
/// close specific tabs, delete saved bookmarks and clear history. Regular tabs and
/// Favorites only; private tabs and web AI pages are never targets.
@MainActor
extension BrowserIntentExecutor {
    static let maximumSchemaTabTargets = 20
    static let maximumBookmarkDeletes = 100

    func executeSchemaCommand(
        _ command: BrowserIntentCommand,
        confirm: BrowserIntentConfirmation
    ) async throws -> BrowserIntentOutput {
        switch command {
        case .loadURLInTab(let url, let tabID):
            return try loadURL(url, inTab: tabID)
        case .closeTabs(let tabIDs):
            return try await closeTabs(tabIDs, confirm: confirm)
        case .deleteBookmarks(let bookmarkIDs):
            return try await deleteBookmarks(bookmarkIDs, confirm: confirm)
        case .clearHistory(let since):
            return try await clearHistory(since: since, confirm: confirm)
        case .renameBookmark(let bookmarkID, let title):
            return try renameBookmark(bookmarkID, to: title)
        default:
            throw BrowserIntentError.unsupported("Unsupported command.")
        }
    }

    func loadURL(_ url: URL, inTab tabID: UUID) throws -> BrowserIntentOutput {
        guard AgentTaskURLParser.isAllowedStartURL(url) else {
            throw BrowserIntentError.invalidInput("Provide a valid http or https address without credentials.")
        }
        guard let tab = regularTabs().first(where: { $0.id == tabID }) else {
            throw BrowserIntentError.emptyResult("That tab is no longer open in Vortyra.")
        }
        viewModel.selectTab(tab)
        viewModel.navigate(to: url, in: tab)
        callbacks.onTabSelected(tab.id)
        return output("Loaded the website in the tab.")
    }

    func closeTabs(_ tabIDs: [UUID], confirm: BrowserIntentConfirmation) async throws -> BrowserIntentOutput {
        let requested = Set(tabIDs)
        guard !requested.isEmpty, requested.count <= Self.maximumSchemaTabTargets else {
            throw BrowserIntentError.invalidInput(
                "Choose between 1 and \(Self.maximumSchemaTabTargets) tabs to close."
            )
        }
        let targets = regularTabs().filter { requested.contains($0.id) }
        guard !targets.isEmpty else {
            throw BrowserIntentError.emptyResult("None of those tabs are open in Vortyra anymore.")
        }
        let captured = Set(targets.map(\.id))
        guard regularTabs().contains(where: { !captured.contains($0.id) }) else {
            throw BrowserIntentError.lastAccessibleTab
        }
        var bindings: [CloseBinding] = []
        for tab in targets {
            bindings.append(try await closeBinding(for: tab))
        }
        let count = captured.count
        try await confirm("Close \(count) tab\(count == 1 ? "" : "s")? Their page state will be lost.")
        for binding in bindings {
            try await validateCloseBinding(binding)
        }
        guard regularTabs().contains(where: { !captured.contains($0.id) }) else {
            throw BrowserIntentError.lastAccessibleTab
        }
        for tab in targets {
            viewModel.closeTab(tab)
        }
        if let selected = viewModel.tabs.first(where: { $0.id == viewModel.selectedTabID }),
           selected.isIncognito || selected.webAIProvider != nil || captured.contains(selected.id),
           let repair = regularTabs().first {
            viewModel.selectTab(repair)
        }
        return output("Closed \(count) tab\(count == 1 ? "" : "s").")
    }

    func deleteBookmarks(_ bookmarkIDs: [UUID], confirm: BrowserIntentConfirmation) async throws -> BrowserIntentOutput {
        let requested = Set(bookmarkIDs)
        guard !requested.isEmpty, requested.count <= Self.maximumBookmarkDeletes else {
            throw BrowserIntentError.invalidInput(
                "Choose between 1 and \(Self.maximumBookmarkDeletes) bookmarks to delete."
            )
        }
        let targets = viewModel.favorites.filter { requested.contains($0.id) }
        guard !targets.isEmpty else {
            throw BrowserIntentError.emptyResult("None of those bookmarks are saved in Vortyra anymore.")
        }
        let count = targets.count
        try await confirm("Delete \(count) bookmark\(count == 1 ? "" : "s") from Favorites? This cannot be undone.")
        try Task.checkCancellation()
        guard isCurrent() else { throw BrowserIntentError.stalePage }
        // Read again after the prompt: the list may have changed while it was open.
        let current = viewModel.favorites.filter { requested.contains($0.id) }
        for favorite in current {
            viewModel.removeFromFavorites(favorite)
        }
        return output("Deleted \(current.count) bookmark\(current.count == 1 ? "" : "s") from Favorites.")
    }

    func renameBookmark(_ bookmarkID: UUID, to rawTitle: String) throws -> BrowserIntentOutput {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= BrowserSpotlightLimits.maximumTitleCharacters else {
            throw BrowserIntentError.invalidInput(
                "Provide a bookmark name between 1 and \(BrowserSpotlightLimits.maximumTitleCharacters) characters."
            )
        }
        guard let favorite = viewModel.favorites.first(where: { $0.id == bookmarkID }) else {
            throw BrowserIntentError.emptyResult("That bookmark is no longer saved in Vortyra.")
        }
        viewModel.renameFavorite(favorite, to: title)
        return output("Renamed the bookmark.")
    }

    /// Clears regular browsing history visits, from `since` onward or all of them when nil.
    /// HistoryStore posts a change notification, which the Spotlight indexer uses to drop the entries.
    func clearHistory(since: Date?, confirm: BrowserIntentConfirmation) async throws -> BrowserIntentOutput {
        let message = since == nil
            ? "Clear all Vortyra browsing history on this device? This cannot be undone."
            : "Clear the last hour of Vortyra browsing history on this device?"
        try await confirm(message)
        try Task.checkCancellation()
        guard isCurrent() else { throw BrowserIntentError.stalePage }
        historyStore.clear(since: since)
        return output(since == nil ? "Cleared all browsing history." : "Cleared the last hour of browsing history.")
    }
}
