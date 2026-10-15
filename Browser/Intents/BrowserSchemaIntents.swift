import AppIntents
import Foundation

/// Apple Intelligence browser schema intents. They are added beside the native intents, which keep
/// their names, titles and phrases. Each schema intent delegates its parameter-to-command mapping to
/// `BrowserSchemaCommands`, so tests can check it with plain values. Destructive commands confirm
/// inside the executor, through the same `requestConfirmation` path as the other intents. Private
/// tabs are never created, returned or targeted by these intents.
extension AppIntent {
    /// Runs commands in order through the shared runtime and returns the last output.
    func performBrowserCommands(_ commands: [BrowserIntentCommand]) async throws -> BrowserIntentOutput {
        guard !commands.isEmpty else {
            throw BrowserIntentError.unsupported("This action has nothing to run.")
        }
        var lastOutput: BrowserIntentOutput?
        for command in commands {
            lastOutput = try await BrowserIntentRuntime.shared.perform(command) { message in
                try await self.browserIntentConfirmation(message: message)
            }
        }
        guard let lastOutput else {
            throw BrowserIntentError.unsupported("This action has nothing to run.")
        }
        return lastOutput
    }
}

/// Pure mapping from schema parameters to executor commands. The schema intents delegate here,
/// and tests call it directly with plain values.
enum BrowserSchemaCommands {
    nonisolated static func identifier(_ raw: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else { throw BrowserIntentError.stalePage }
        return id
    }

    static func createTab(url: URL?, isPrivate: Bool) throws -> [BrowserIntentCommand] {
        guard !isPrivate else {
            throw BrowserIntentError.invalidInput(
                "Vortyra creates regular tabs with this action. Use New Private Vortyra Tab for a private tab."
            )
        }
        if let url {
            return [.openURL(url)]
        }
        return [.newTab]
    }

    static func loadURL(_ url: URL, inTab tab: String) throws -> [BrowserIntentCommand] {
        let tabID = try identifier(tab)
        return [.loadURLInTab(url, tabID)]
    }

    /// Find runs on the selected page, so the tab is selected first.
    static func findOnPage(_ phrase: String, inTab tab: String) throws -> [BrowserIntentCommand] {
        let tabID = try identifier(tab)
        return [.switchToTab(tabID), .findText(phrase)]
    }

    /// Bookmarking reads the selected tab, so the tab is selected first.
    static func bookmarkTab(_ tab: String) throws -> [BrowserIntentCommand] {
        let tabID = try identifier(tab)
        return [.switchToTab(tabID), .bookmark(nil)]
    }

    static func openBookmark(url: URL, inTab tab: String?) throws -> [BrowserIntentCommand] {
        guard BrowserSpotlightText.isIndexableWebURL(url) else {
            throw BrowserIntentError.invalidInput("This bookmark is not a web address Vortyra can open.")
        }
        guard let tab else { return [.openURL(url)] }
        let tabID = try identifier(tab)
        return [.loadURLInTab(url, tabID)]
    }

    static func switchTab(_ tab: String) throws -> [BrowserIntentCommand] {
        let tabID = try identifier(tab)
        return [.switchToTab(tabID)]
    }

    static func closeTabs(_ tabs: [String]) throws -> [BrowserIntentCommand] {
        let ids = try tabs.map(identifier)
        return [.closeTabs(ids)]
    }

    static func search(_ term: String) -> [BrowserIntentCommand] {
        [.search(term)]
    }

    static func deleteBookmarks(_ bookmarks: [String]) throws -> [BrowserIntentCommand] {
        let ids = try bookmarks.map(identifier)
        return [.deleteBookmarks(ids)]
    }

    static func clearHistory(_ timeFrame: BrowserClearHistoryTimeFrame, now: Date) -> [BrowserIntentCommand] {
        switch timeFrame {
        case .lastHour:
            return [.clearHistory(now.addingTimeInterval(-3_600))]
        case .allTime:
            return [.clearHistory(nil)]
        }
    }
}

@AppEnum(schema: .browser.clearHistoryTimeFrame)
enum BrowserClearHistoryTimeFrame: String, AppEnum {
    case lastHour
    case allTime

    static let caseDisplayRepresentations: [BrowserClearHistoryTimeFrame: DisplayRepresentation] = [
        .lastHour: "Last Hour",
        .allTime: "All Time"
    ]
}

@AppIntent(schema: .browser.createTab)
struct CreateBrowserTabSchemaIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Tab in Vortyra"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "URL")
    var url: URL?

    /// Required by the schema. Private tabs are never returned as entities, so only regular tabs are created here.
    @Parameter(title: "Private", default: false)
    var isPrivate: Bool

    func commands() throws -> [BrowserIntentCommand] {
        try BrowserSchemaCommands.createTab(url: url, isPrivate: isPrivate)
    }

    func perform() async throws -> some IntentResult & ReturnsValue<BrowserSchemaTabEntity> {
        let output = try await performBrowserCommands(try commands())
        guard let tabID = output.resultTabID else {
            throw BrowserIntentError.emptyResult("The tab was opened, but Vortyra could not return it.")
        }
        guard let tab = await MainActor.run(body: { BrowserSchemaTabEntity.liveTab(id: tabID) }) else {
            throw BrowserIntentError.emptyResult("The tab was opened, but Vortyra could not return it.")
        }
        return .result(value: tab, dialog: IntentDialog(stringLiteral: output.text))
    }
}

@AppIntent(schema: .browser.openURLInTab)
struct LoadURLInBrowserTabSchemaIntent: AppIntent {
    static let title: LocalizedStringResource = "Load URL in Vortyra Tab"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "URL")
    var url: URL

    @Parameter(title: "Tab")
    var tab: BrowserSchemaTabEntity

    func commands() throws -> [BrowserIntentCommand] {
        try BrowserSchemaCommands.loadURL(url, inTab: tab.id)
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let output = try await performBrowserCommands(try commands())
        return .result(value: output.text, dialog: IntentDialog(stringLiteral: output.text))
    }
}

@AppIntent(schema: .browser.findOnPage)
struct FindOnBrowserPageSchemaIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Text on Vortyra Page"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Search Text")
    var searchPhrase: String

    @Parameter(title: "Tab")
    var tab: BrowserSchemaTabEntity

    func commands() throws -> [BrowserIntentCommand] {
        try BrowserSchemaCommands.findOnPage(searchPhrase, inTab: tab.id)
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let output = try await performBrowserCommands(try commands())
        return .result(value: output.text, dialog: IntentDialog(stringLiteral: output.text))
    }
}

@AppIntent(schema: .browser.bookmarkTab)
struct BookmarkBrowserTabSchemaIntent: AppIntent {
    static let title: LocalizedStringResource = "Bookmark Vortyra Tab"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Tab")
    var tab: BrowserSchemaTabEntity

    @Parameter(title: "Name")
    var name: String?

    func commands() throws -> [BrowserIntentCommand] {
        try BrowserSchemaCommands.bookmarkTab(tab.id)
    }

    func perform() async throws -> some IntentResult & ReturnsValue<BrowserSchemaBookmarkEntity> {
        let output = try await performBrowserCommands(try commands())
        guard let saved = output.savedBookmark else {
            throw BrowserIntentError.emptyResult("The page was saved, but Vortyra could not return the bookmark.")
        }
        let requested = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !requested.isEmpty {
            _ = try await performBrowserCommands([.renameBookmark(saved.id, requested)])
        }
        let chosen = requested.isEmpty ? saved.title : requested
        let fallback = saved.url.host ?? saved.url.absoluteString
        let displayName = await MainActor.run { BrowserSpotlightText.boundedTitle(chosen, fallback: fallback) }
        let entity = BrowserSchemaBookmarkEntity(id: saved.id.uuidString, name: displayName, url: saved.url)
        return .result(value: entity, dialog: IntentDialog(stringLiteral: output.text))
    }
}

@AppIntent(schema: .browser.openBookmark)
struct OpenBrowserBookmarkSchemaIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Bookmark in Vortyra Tab"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Tab")
    var tab: BrowserSchemaTabEntity?

    @Parameter(title: "Bookmark")
    var target: BrowserSchemaBookmarkEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target) in Vortyra")
    }

    func commands() throws -> [BrowserIntentCommand] {
        try BrowserSchemaCommands.openBookmark(url: target.url, inTab: tab?.id)
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let output = try await performBrowserCommands(try commands())
        return .result(value: output.text, dialog: IntentDialog(stringLiteral: output.text))
    }
}

@AppIntent(schema: .browser.switchTab)
struct SwitchToBrowserTabSchemaIntent: OpenIntent {
    static let title: LocalizedStringResource = "Switch to Tab in Vortyra"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Tab")
    var target: BrowserSchemaTabEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch to \(\.$target)")
    }

    func commands() throws -> [BrowserIntentCommand] {
        try BrowserSchemaCommands.switchTab(target.id)
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let output = try await performBrowserCommands(try commands())
        return .result(value: output.text, dialog: IntentDialog(stringLiteral: output.text))
    }
}

@AppIntent(schema: .browser.closeTabs)
struct CloseBrowserTabsSchemaIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Tabs in Vortyra"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Tabs")
    var target: [BrowserSchemaTabEntity]

    func commands() throws -> [BrowserIntentCommand] {
        try BrowserSchemaCommands.closeTabs(target.map(\.id))
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let output = try await performBrowserCommands(try commands())
        return .result(value: output.text, dialog: IntentDialog(stringLiteral: output.text))
    }
}

/// Replaces the deprecated `.browser.search` schema. Needs iOS 27.
@available(iOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
struct SearchBrowserInAppSchemaIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Web in Vortyra"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Search")
    var criteria: StringSearchCriteria

    func commands() throws -> [BrowserIntentCommand] {
        BrowserSchemaCommands.search(criteria.term)
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let output = try await performBrowserCommands(try commands())
        return .result(value: output.text, dialog: IntentDialog(stringLiteral: output.text))
    }
}

/// Destructive: the executor asks for confirmation before any bookmark is removed.
@AppIntent(schema: .browser.deleteBookmarks)
struct DeleteBrowserBookmarksSchemaIntent: DeleteIntent {
    static let title: LocalizedStringResource = "Delete Vortyra Bookmarks"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    var entities: [BrowserSchemaBookmarkEntity]

    func commands() throws -> [BrowserIntentCommand] {
        try BrowserSchemaCommands.deleteBookmarks(entities.map(\.id))
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let output = try await performBrowserCommands(try commands())
        return .result(value: output.text, dialog: IntentDialog(stringLiteral: output.text))
    }
}

/// Destructive: the executor asks for confirmation before history is cleared. Private tabs never
/// record history, so they have nothing to clear here.
@AppIntent(schema: .browser.clearHistory)
struct ClearBrowserHistorySchemaIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Vortyra History"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Time Frame", default: .lastHour)
    var timeFrame: BrowserClearHistoryTimeFrame

    func commands(now: Date = Date()) -> [BrowserIntentCommand] {
        BrowserSchemaCommands.clearHistory(timeFrame, now: now)
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let output = try await performBrowserCommands(commands())
        return .result(value: output.text, dialog: IntentDialog(stringLiteral: output.text))
    }
}
