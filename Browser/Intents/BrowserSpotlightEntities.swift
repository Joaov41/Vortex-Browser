import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Bounds shared by every Spotlight-facing entity.
enum BrowserSpotlightLimits {
    static let maximumTitleCharacters = 240
    static let maximumURLCharacters = 2_048
    static let maximumFavoritesBytes = 8_000_000
    static let maximumIndexedBookmarks = 2_000
    static let maximumIndexedSavedTasks = 500
    static let maximumIndexedHistoryEntries = 500
    static let maximumQueryResults = 100
}

enum BrowserSpotlightText {
    /// Only plain web pages are indexed or opened: http or https, no credentials, bounded length.
    static func isIndexableWebURL(_ url: URL) -> Bool {
        AgentTaskURLParser.isAllowedStartURL(url)
            && url.absoluteString.count <= BrowserSpotlightLimits.maximumURLCharacters
    }

    static func boundedTitle(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? fallback : trimmed
        return String(source.prefix(BrowserSpotlightLimits.maximumTitleCharacters))
    }
}

/// Reads bookmarks from the same UserDefaults keys the Favorites UI writes.
enum BrowserSpotlightBookmarkStorage {
    static let favoritesKey = "browser_favorites"

    static func favorites(from defaults: UserDefaults) throws -> [Favorite] {
        guard let data = defaults.data(forKey: favoritesKey) else { return [] }
        // Favicons are stored inline, so this limit is larger than the folder limit.
        guard data.count <= BrowserSpotlightLimits.maximumFavoritesBytes else {
            throw BrowserIntentEntityError.oversizedStorage
        }
        guard let decoded = try? JSONDecoder().decode([Favorite].self, from: data) else {
            throw BrowserIntentEntityError.malformedStorage
        }
        return decoded
    }

    /// Web bookmarks with their folder paths. Malformed storage throws; it is never guessed at.
    static func bookmarks(from defaults: UserDefaults) throws -> [BookmarkEntity] {
        let favorites = try favorites(from: defaults)
        guard !favorites.isEmpty else { return [] }
        let paths = try BrowserIntentEntityStorage.folderPaths(from: defaults)
        return BookmarkEntity.indexable(from: favorites, folderPaths: paths)
    }
}

struct BookmarkEntity: IndexedEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bookmark"
    static let defaultQuery = BookmarkEntityQuery()

    let id: String
    let title: String
    let url: URL
    let folderPath: String?

    init(id: String, title: String, url: URL, folderPath: String?) {
        self.id = id
        self.title = title
        self.url = url
        self.folderPath = folderPath
    }

    private var subtitleText: String {
        folderPath ?? (url.host ?? url.absoluteString)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitleText)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.url)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = subtitleText
        attributes.contentURL = url
        return attributes
    }

    static func indexable(from favorites: [Favorite], folderPaths: [UUID: String]) -> [BookmarkEntity] {
        var entities: [BookmarkEntity] = []
        for favorite in favorites where BrowserSpotlightText.isIndexableWebURL(favorite.url) {
            if entities.count >= BrowserSpotlightLimits.maximumIndexedBookmarks { break }
            let fallback = favorite.url.host ?? favorite.url.absoluteString
            let folderPath = favorite.folderID.flatMap { folderPaths[$0] }.map {
                String($0.prefix(BrowserSpotlightLimits.maximumTitleCharacters))
            }
            entities.append(
                BookmarkEntity(
                    id: favorite.id.uuidString,
                    title: BrowserSpotlightText.boundedTitle(favorite.title, fallback: fallback),
                    url: favorite.url,
                    folderPath: folderPath
                )
            )
        }
        return entities
    }
}

struct BookmarkEntityQuery: EntityStringQuery {
    private let defaultsProvider: @Sendable () -> UserDefaults

    init() {
        self.init(defaultsProvider: { .standard })
    }

    init(defaultsProvider: @escaping @Sendable () -> UserDefaults) {
        self.defaultsProvider = defaultsProvider
    }

    func entities(for identifiers: [String]) async throws -> [BookmarkEntity] {
        let requested = Set(identifiers)
        let matches = try BrowserSpotlightBookmarkStorage.bookmarks(from: defaultsProvider())
            .filter { requested.contains($0.id) }
        return Array(matches.prefix(BrowserSpotlightLimits.maximumQueryResults))
    }

    func suggestedEntities() async throws -> [BookmarkEntity] {
        let all = try BrowserSpotlightBookmarkStorage.bookmarks(from: defaultsProvider())
        return Array(all.prefix(BrowserSpotlightLimits.maximumQueryResults))
    }

    func entities(matching string: String) async throws -> [BookmarkEntity] {
        let matches = try BrowserSpotlightBookmarkStorage.bookmarks(from: defaultsProvider())
            .filter {
                $0.title.localizedCaseInsensitiveContains(string)
                    || ($0.folderPath?.localizedCaseInsensitiveContains(string) ?? false)
                    || $0.url.absoluteString.localizedCaseInsensitiveContains(string)
            }
        return Array(matches.prefix(BrowserSpotlightLimits.maximumQueryResults))
    }
}

struct OpenBookmarkInVortyraIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Bookmark in Vortyra"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Bookmark")
    var target: BookmarkEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target) in Vortyra")
    }

    func perform() async throws -> some IntentResult {
        guard BrowserSpotlightText.isIndexableWebURL(target.url) else {
            throw BrowserIntentError.invalidInput("This bookmark is not a web address Vortyra can open.")
        }
        _ = try await performBrowserIntent(.openURL(target.url))
        return .result()
    }
}

extension AgentTaskEntity {
    /// Display metadata only, as for the existing entity. Task text and start URLs stay in the store.
    static func indexable(from tasks: [SavedAgentTask]) -> [AgentTaskEntity] {
        tasks.prefix(BrowserSpotlightLimits.maximumIndexedSavedTasks).map { task in
            AgentTaskEntity(
                id: task.id.uuidString,
                title: BrowserSpotlightText.boundedTitle(task.title, fallback: "Saved browser task")
            )
        }
    }
}

/// Queues a saved task through the same validation and queue as Run Saved Browser Task.
struct OpenSavedAgentTaskIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Saved Browser Task"
    static let description = IntentDescription(
        "Queue a saved browser task in Vortyra, the same way Run Saved Browser Task does."
    )
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Saved Task")
    var target: AgentTaskEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open saved task \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        let queuedTitle = try await MainActor.run { () throws -> String in
            try AgentTaskIntentRuntime.queueSavedTask(target)
        }
        return .result(dialog: "Queued \(queuedTitle). Vortyra will continue when it is ready.")
    }
}

/// A live tab in the active Vortyra window. Not indexed, because tabs are volatile.
struct OpenTabEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Open Tab"
    static let defaultQuery = OpenTabEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

enum BrowserOpenTabEntities {
    /// Regular tabs only: private tabs and web AI provider pages never become entities.
    @MainActor
    static func eligibleTabs(_ tabs: [BrowserTab]) -> [BrowserTab] {
        tabs.filter { !$0.isIncognito && $0.webAIProvider == nil }
    }

    @MainActor
    static func entities(from tabs: [BrowserTab]) -> [OpenTabEntity] {
        eligibleTabs(tabs).map { tab in
            OpenTabEntity(
                id: tab.id.uuidString,
                title: BrowserSpotlightText.boundedTitle(tab.title, fallback: "New Tab")
            )
        }
    }
}

struct OpenTabEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [OpenTabEntity] {
        let requested = Set(identifiers)
        let all = await liveTabEntities()
        return Array(all.filter { requested.contains($0.id) }.prefix(BrowserSpotlightLimits.maximumQueryResults))
    }

    func suggestedEntities() async throws -> [OpenTabEntity] {
        let all = await liveTabEntities()
        return Array(all.prefix(BrowserSpotlightLimits.maximumQueryResults))
    }

    func entities(matching string: String) async throws -> [OpenTabEntity] {
        let all = await liveTabEntities()
        let matches = all.filter { $0.title.localizedCaseInsensitiveContains(string) }
        return Array(matches.prefix(BrowserSpotlightLimits.maximumQueryResults))
    }

    private func liveTabEntities() async -> [OpenTabEntity] {
        await MainActor.run {
            BrowserOpenTabEntities.entities(from: BrowserIntentRuntime.shared.liveTabs())
        }
    }
}

struct SwitchToVortyraTabIntent: OpenIntent {
    static let title: LocalizedStringResource = "Switch to Vortyra Tab"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Tab")
    var target: OpenTabEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch to \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: target.id) else { throw BrowserIntentError.stalePage }
        _ = try await performBrowserIntent(.switchToTab(id))
        return .result()
    }
}

/// A recorded page visit. Indexed only while the History setting is on.
struct HistoryEntity: IndexedEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "History Page"
    static let defaultQuery = HistoryEntityQuery()

    let id: String
    let title: String
    let url: URL

    init(id: String, title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }

    private var subtitleText: String {
        url.host ?? url.absoluteString
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitleText)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.url)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = subtitleText
        attributes.contentURL = url
        return attributes
    }

    /// Newest entries first, bounded. Private-tab visits never reach HistoryStore.
    static func indexable(from entries: [HistoryEntry]) -> [HistoryEntity] {
        var result: [HistoryEntity] = []
        for entry in entries where BrowserSpotlightText.isIndexableWebURL(entry.url) {
            if result.count >= BrowserSpotlightLimits.maximumIndexedHistoryEntries { break }
            result.append(
                HistoryEntity(
                    id: entry.id.uuidString,
                    title: BrowserSpotlightText.boundedTitle(entry.title, fallback: entry.url.host ?? entry.url.absoluteString),
                    url: entry.url
                )
            )
        }
        return result
    }
}

struct HistoryEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [HistoryEntity] {
        let requested = Set(identifiers)
        let all = await currentEntities()
        return Array(all.filter { requested.contains($0.id) }.prefix(BrowserSpotlightLimits.maximumQueryResults))
    }

    func suggestedEntities() async throws -> [HistoryEntity] {
        let all = await currentEntities()
        return Array(all.prefix(BrowserSpotlightLimits.maximumQueryResults))
    }

    func entities(matching string: String) async throws -> [HistoryEntity] {
        let all = await currentEntities()
        let matches = all.filter {
            $0.title.localizedCaseInsensitiveContains(string)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(string)
        }
        return Array(matches.prefix(BrowserSpotlightLimits.maximumQueryResults))
    }

    /// Returns nothing while the History setting is off, so history is not exposed to Shortcuts either.
    private func currentEntities() async -> [HistoryEntity] {
        await MainActor.run {
            guard BrowserSpotlightSettings.isEnabled(.history) else { return [] }
            return HistoryEntity.indexable(from: HistoryStore.shared.entries)
        }
    }
}

struct OpenHistoryEntryInVortyraIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open History Page in Vortyra"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "History Page")
    var target: HistoryEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target) in Vortyra")
    }

    func perform() async throws -> some IntentResult {
        guard BrowserSpotlightText.isIndexableWebURL(target.url) else {
            throw BrowserIntentError.invalidInput("This history entry is not a web address Vortyra can open.")
        }
        _ = try await performBrowserIntent(.openURL(target.url))
        return .result()
    }
}
