import AppIntents
import Foundation

/// Schema bookmark entity. Backed by the same Favorites data and queries as `BookmarkEntity`,
/// which stays unchanged for the Spotlight index and existing Shortcuts.
@AppEntity(schema: .browser.bookmark)
struct BrowserSchemaBookmarkEntity: AppEntity, Identifiable, Sendable {
    static let defaultQuery = BrowserSchemaBookmarkQuery()

    let id: String
    var name: String
    var url: URL

    init(id: String, name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }

    init(bookmark: BookmarkEntity) {
        self.init(id: bookmark.id, name: bookmark.title, url: bookmark.url)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct BrowserSchemaBookmarkQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [BrowserSchemaBookmarkEntity] {
        try await BookmarkEntityQuery().entities(for: identifiers).map(BrowserSchemaBookmarkEntity.init(bookmark:))
    }

    func suggestedEntities() async throws -> [BrowserSchemaBookmarkEntity] {
        try await BookmarkEntityQuery().suggestedEntities().map(BrowserSchemaBookmarkEntity.init(bookmark:))
    }

    func entities(matching string: String) async throws -> [BrowserSchemaBookmarkEntity] {
        try await BookmarkEntityQuery().entities(matching: string).map(BrowserSchemaBookmarkEntity.init(bookmark:))
    }
}

/// Schema tab entity for live regular tabs of the one active window. Private tabs and web AI pages
/// never appear, so `isPrivate` is always false.
@AppEntity(schema: .browser.tab)
struct BrowserSchemaTabEntity: AppEntity, Identifiable, Sendable {
    static let defaultQuery = BrowserSchemaTabQuery()

    let id: String
    var name: String
    var url: URL?
    var isPrivate: Bool

    init(id: String, name: String, url: URL?) {
        self.id = id
        self.name = name
        self.url = url
        self.isPrivate = false
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

enum BrowserSchemaTabEntities {
    @MainActor
    static func entities(from tabs: [BrowserTab]) -> [BrowserSchemaTabEntity] {
        BrowserOpenTabEntities.eligibleTabs(tabs).map { tab in
            let url = tab.currentURL.flatMap { BrowserSpotlightText.isIndexableWebURL($0) ? $0 : nil }
            return BrowserSchemaTabEntity(
                id: tab.id.uuidString,
                name: BrowserSpotlightText.boundedTitle(tab.title, fallback: "New Tab"),
                url: url
            )
        }
    }
}

extension BrowserSchemaTabEntity {
    /// The live regular tab with this id, read after a command ran. Nil when it is gone or private.
    @MainActor
    static func liveTab(id: UUID) -> BrowserSchemaTabEntity? {
        BrowserSchemaTabEntities.entities(from: BrowserIntentRuntime.shared.liveTabs())
            .first { $0.id == id.uuidString }
    }
}

struct BrowserSchemaTabQuery: EntityStringQuery {
    private static let resultLimit = 100

    func entities(for identifiers: [String]) async throws -> [BrowserSchemaTabEntity] {
        let requested = Set(identifiers)
        let all = await liveTabEntities()
        return Array(all.filter { requested.contains($0.id) }.prefix(Self.resultLimit))
    }

    func suggestedEntities() async throws -> [BrowserSchemaTabEntity] {
        let all = await liveTabEntities()
        return Array(all.prefix(Self.resultLimit))
    }

    func entities(matching string: String) async throws -> [BrowserSchemaTabEntity] {
        let all = await liveTabEntities()
        let matches = all.filter { $0.name.localizedCaseInsensitiveContains(string) }
        return Array(matches.prefix(Self.resultLimit))
    }

    private func liveTabEntities() async -> [BrowserSchemaTabEntity] {
        await MainActor.run {
            BrowserSchemaTabEntities.entities(from: BrowserIntentRuntime.shared.liveTabs())
        }
    }
}
