import AppIntents
import Foundation
import XCTest
@testable import Browser

/// Records what the indexer asks for. Never touches the real CoreSpotlight index.
@MainActor
final class FakeSpotlightIndexClient: SpotlightIndexClient {
    private var store: [BrowserSpotlightKind: [String: String]] = [:]
    private var purges: [BrowserSpotlightKind: Int] = [:]

    func indexBookmarks(_ entities: [BookmarkEntity]) async throws {
        for entity in entities { store[.bookmarks, default: [:]][entity.id] = entity.title }
    }

    func indexSavedTasks(_ entities: [AgentTaskEntity]) async throws {
        for entity in entities { store[.savedTasks, default: [:]][entity.id] = entity.title }
    }

    func indexHistory(_ entities: [HistoryEntity]) async throws {
        for entity in entities { store[.history, default: [:]][entity.id] = entity.title }
    }

    func deleteEntities(_ kind: BrowserSpotlightKind, identifiers: [String]) async throws {
        for identifier in identifiers { store[kind]?.removeValue(forKey: identifier) }
    }

    func deleteAllEntities(_ kind: BrowserSpotlightKind) async throws {
        purges[kind, default: 0] += 1
        store[kind] = [:]
    }

    func identifiers(_ kind: BrowserSpotlightKind) -> Set<String> {
        Set(store[kind, default: [:]].keys)
    }

    func title(_ kind: BrowserSpotlightKind, id: String) -> String? {
        store[kind]?[id]
    }

    func purgeCount(_ kind: BrowserSpotlightKind) -> Int {
        purges[kind, default: 0]
    }
}

/// Lets a test change what the indexer reads, the way saving or clearing would.
@MainActor
private final class SourceBox {
    var tasks: [SavedAgentTask] = []
    var history: [HistoryEntry] = []
}

@MainActor
final class SpotlightEntityTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "SpotlightEntityTests.\(UUID().uuidString)"))
    }

    private func makeIndexer(
        defaults: UserDefaults,
        client: FakeSpotlightIndexClient,
        source: SourceBox? = nil
    ) -> BrowserSpotlightIndexer {
        let box = source ?? SourceBox()
        return BrowserSpotlightIndexer(
            client: client,
            defaults: defaults,
            savedTasks: { box.tasks },
            history: { box.history },
            debounce: .milliseconds(1)
        )
    }

    private func historyEntry(_ url: String, title: String = "Page") throws -> HistoryEntry {
        HistoryEntry(id: UUID(), url: try XCTUnwrap(URL(string: url)), title: title, visitedAt: Date())
    }

    private func storeFavorites(_ favorites: [Favorite], folders: [FavoriteFolder], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(favorites), forKey: BrowserSpotlightBookmarkStorage.favoritesKey)
        defaults.set(try JSONEncoder().encode(folders), forKey: BrowserIntentEntityStorage.foldersKey)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotlightEntityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Mapping and bounds

    func testBookmarkEntitiesMapFavoritesAndFolderPaths() throws {
        let defaults = try makeDefaults()
        let parent = FavoriteFolder(title: "Research")
        let child = FavoriteFolder(title: "AI", parentID: parent.id)
        let inChild = Favorite(title: "Paper", url: try XCTUnwrap(URL(string: "https://example.com/paper")), dateAdded: Date(), folderID: child.id)
        let topLevel = Favorite(title: "Home", url: try XCTUnwrap(URL(string: "https://example.org/")), dateAdded: Date())
        try storeFavorites([inChild, topLevel], folders: [parent, child], in: defaults)

        let entities = try BrowserSpotlightBookmarkStorage.bookmarks(from: defaults)

        XCTAssertEqual(entities.count, 2)
        let paper = try XCTUnwrap(entities.first { $0.id == inChild.id.uuidString })
        XCTAssertEqual(paper.title, "Paper")
        XCTAssertEqual(paper.url, inChild.url)
        XCTAssertEqual(paper.folderPath, "Research › AI")
        let home = try XCTUnwrap(entities.first { $0.id == topLevel.id.uuidString })
        XCTAssertNil(home.folderPath)
    }

    func testBookmarkTitleAndURLAreBounded() throws {
        let defaults = try makeDefaults()
        let longTitle = String(repeating: "t", count: 500)
        let longURL = try XCTUnwrap(URL(string: "https://example.com/" + String(repeating: "p", count: 2_100)))
        let kept = Favorite(title: longTitle, url: try XCTUnwrap(URL(string: "https://example.com/ok")), dateAdded: Date())
        let tooLong = Favorite(title: "Too long", url: longURL, dateAdded: Date())
        try storeFavorites([kept, tooLong], folders: [], in: defaults)

        let entities = try BrowserSpotlightBookmarkStorage.bookmarks(from: defaults)

        XCTAssertEqual(entities.count, 1)
        XCTAssertEqual(entities.first?.title.count, BrowserSpotlightLimits.maximumTitleCharacters)
        XCTAssertFalse(entities.contains { $0.id == tooLong.id.uuidString })
    }

    func testNonWebURLsAreExcludedFromBookmarksAndHistory() throws {
        let defaults = try makeDefaults()
        let rejected = [
            "ftp://example.com/file",
            "file:///etc/hosts",
            "javascript:alert(1)",
            "https://user:secret@example.com/"
        ]
        let favorites = try rejected.map { raw in
            Favorite(title: "Rejected", url: try XCTUnwrap(URL(string: raw)), dateAdded: Date())
        } + [Favorite(title: "Allowed", url: try XCTUnwrap(URL(string: "https://example.com/")), dateAdded: Date())]
        try storeFavorites(favorites, folders: [], in: defaults)

        let bookmarks = try BrowserSpotlightBookmarkStorage.bookmarks(from: defaults)
        XCTAssertEqual(bookmarks.map(\.title), ["Allowed"])

        let history = try HistoryEntity.indexable(from: rejected.map { try historyEntry($0) })
        XCTAssertTrue(history.isEmpty)
    }

    func testHistoryEntitiesUseBoundedTitles() throws {
        let entries = [try historyEntry("https://example.com/a", title: String(repeating: "h", count: 400))]

        let entities = HistoryEntity.indexable(from: entries)

        XCTAssertEqual(entities.count, 1)
        XCTAssertEqual(entities.first?.title.count, BrowserSpotlightLimits.maximumTitleCharacters)
    }

    func testMalformedBookmarkStorageThrows() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("not json".utf8), forKey: BrowserSpotlightBookmarkStorage.favoritesKey)

        XCTAssertThrowsError(try BrowserSpotlightBookmarkStorage.bookmarks(from: defaults)) { error in
            XCTAssertEqual(error as? BrowserIntentEntityError, .malformedStorage)
        }
    }

    // MARK: Settings and syncing

    func testSettingsDefaultsApplyWhenKeysAreAbsent() throws {
        let defaults = try makeDefaults()

        XCTAssertTrue(BrowserSpotlightSettings.isEnabled(.bookmarks, defaults: defaults))
        XCTAssertTrue(BrowserSpotlightSettings.isEnabled(.savedTasks, defaults: defaults))
        XCTAssertFalse(BrowserSpotlightSettings.isEnabled(.history, defaults: defaults))
    }

    func testHistoryIsNotIndexedUntilEnabled() async throws {
        let defaults = try makeDefaults()
        let source = SourceBox()
        source.history = [try historyEntry("https://example.com/visited")]
        let client = FakeSpotlightIndexClient()
        let indexer = makeIndexer(defaults: defaults, client: client, source: source)

        indexer.changed(.history)
        await indexer.waitForPendingSyncs()

        let indexed = client.identifiers(.history)
        XCTAssertTrue(indexed.isEmpty)
    }

    func testEnablingHistoryIndexesEntries() async throws {
        let defaults = try makeDefaults()
        let source = SourceBox()
        let first = try historyEntry("https://example.com/one", title: "One")
        let second = try historyEntry("https://example.com/two", title: "Two")
        source.history = [first, second]
        let client = FakeSpotlightIndexClient()
        let indexer = makeIndexer(defaults: defaults, client: client, source: source)

        defaults.set(true, forKey: BrowserSpotlightSettings.historyKey)
        indexer.settingChanged(.history)
        await indexer.waitForPendingSyncs()

        let indexed = client.identifiers(.history)
        XCTAssertEqual(indexed, [first.id.uuidString, second.id.uuidString])
        let title = client.title(.history, id: first.id.uuidString)
        XCTAssertEqual(title, "One")
    }

    func testTurningHistoryOffDeletesOnlyHistory() async throws {
        let defaults = try makeDefaults()
        let source = SourceBox()
        source.history = [try historyEntry("https://example.com/one")]
        let favorite = Favorite(title: "Kept", url: try XCTUnwrap(URL(string: "https://example.com/kept")), dateAdded: Date())
        try storeFavorites([favorite], folders: [], in: defaults)
        defaults.set(true, forKey: BrowserSpotlightSettings.historyKey)
        let client = FakeSpotlightIndexClient()
        let indexer = makeIndexer(defaults: defaults, client: client, source: source)
        await indexer.reindexAll()
        let indexedHistory = client.identifiers(.history)
        XCTAssertFalse(indexedHistory.isEmpty)

        defaults.set(false, forKey: BrowserSpotlightSettings.historyKey)
        indexer.settingChanged(.history)
        await indexer.waitForPendingSyncs()

        let history = client.identifiers(.history)
        XCTAssertTrue(history.isEmpty)
        let bookmarks = client.identifiers(.bookmarks)
        XCTAssertEqual(bookmarks, [favorite.id.uuidString])
    }

    func testTurningBookmarksOffDeletesBookmarkEntities() async throws {
        let defaults = try makeDefaults()
        let favorite = Favorite(title: "Site", url: try XCTUnwrap(URL(string: "https://example.com/")), dateAdded: Date())
        try storeFavorites([favorite], folders: [], in: defaults)
        let client = FakeSpotlightIndexClient()
        let indexer = makeIndexer(defaults: defaults, client: client)
        await indexer.reindexAll()
        let indexedBookmarks = client.identifiers(.bookmarks)
        XCTAssertEqual(indexedBookmarks, [favorite.id.uuidString])

        defaults.set(false, forKey: BrowserSpotlightSettings.bookmarksKey)
        indexer.settingChanged(.bookmarks)
        await indexer.waitForPendingSyncs()

        let remaining = client.identifiers(.bookmarks)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testClearingHistoryDeletesHistoryEntities() async throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: BrowserSpotlightSettings.historyKey)
        let source = SourceBox()
        let first = try historyEntry("https://example.com/one")
        let second = try historyEntry("https://example.com/two")
        source.history = [first, second]
        let client = FakeSpotlightIndexClient()
        let indexer = makeIndexer(defaults: defaults, client: client, source: source)
        indexer.changed(.history)
        await indexer.waitForPendingSyncs()
        let initial = client.identifiers(.history)
        XCTAssertEqual(initial.count, 2)

        // Removing one entry deletes just that entry.
        source.history = [first]
        indexer.changed(.history)
        await indexer.waitForPendingSyncs()
        let afterRemoval = client.identifiers(.history)
        XCTAssertEqual(afterRemoval, [first.id.uuidString])

        // Clearing history deletes the rest.
        source.history = []
        indexer.changed(.history)
        await indexer.waitForPendingSyncs()
        let remaining = client.identifiers(.history)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSavedTaskEntitiesFollowSaveUpdateAndDelete() async throws {
        let defaults = try makeDefaults()
        let fileURL = try temporaryDirectory().appendingPathComponent("AgentTasks.json")
        let store = AgentTaskStore(fileURL: fileURL)
        let source = SourceBox()
        let client = FakeSpotlightIndexClient()
        let indexer = BrowserSpotlightIndexer(
            client: client,
            defaults: defaults,
            savedTasks: {
                try store.load()
                return store.savedTasks
            },
            history: { source.history },
            debounce: .milliseconds(1)
        )
        let task = SavedAgentTask(title: "Check prices", task: "Find the lowest price for the item")

        try store.saveTask(task)
        indexer.changed(.savedTasks)
        await indexer.waitForPendingSyncs()
        let saved = client.identifiers(.savedTasks)
        XCTAssertEqual(saved, [task.id.uuidString])
        let savedTitle = client.title(.savedTasks, id: task.id.uuidString)
        XCTAssertEqual(savedTitle, "Check prices")

        var renamed = task
        renamed.title = "Check fares"
        try store.updateTask(renamed)
        indexer.changed(.savedTasks)
        await indexer.waitForPendingSyncs()
        let updatedTitle = client.title(.savedTasks, id: task.id.uuidString)
        XCTAssertEqual(updatedTitle, "Check fares")

        try store.deleteTask(id: task.id)
        indexer.changed(.savedTasks)
        await indexer.waitForPendingSyncs()
        let remaining = client.identifiers(.savedTasks)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testUnreadableBookmarkStorageLeavesExistingEntitiesUntouched() async throws {
        let defaults = try makeDefaults()
        let favorite = Favorite(title: "Site", url: try XCTUnwrap(URL(string: "https://example.com/")), dateAdded: Date())
        try storeFavorites([favorite], folders: [], in: defaults)
        let client = FakeSpotlightIndexClient()
        let indexer = makeIndexer(defaults: defaults, client: client)
        await indexer.reindexAll()

        defaults.set(Data("corrupt".utf8), forKey: BrowserSpotlightBookmarkStorage.favoritesKey)
        indexer.changed(.bookmarks)
        await indexer.waitForPendingSyncs()

        let indexed = client.identifiers(.bookmarks)
        XCTAssertEqual(indexed, [favorite.id.uuidString])
    }

    func testReindexAllPurgesEachKindOnlyOncePerLaunch() async throws {
        let defaults = try makeDefaults()
        let client = FakeSpotlightIndexClient()
        let indexer = makeIndexer(defaults: defaults, client: client)

        await indexer.reindexAll()
        await indexer.reindexAll()

        for kind in BrowserSpotlightKind.allCases {
            let purgeCount = client.purgeCount(kind)
            XCTAssertEqual(purgeCount, 1, "\(kind) should be purged once per launch")
        }
    }

    // MARK: Private browsing and tab entities

    func testPrivateAndWebAITabsNeverBecomeEntities() throws {
        let regular = BrowserTab(title: "Regular", url: try XCTUnwrap(URL(string: "https://example.com/")))
        let privateTab = BrowserTab(title: "Private", url: try XCTUnwrap(URL(string: "https://private.example/")), isIncognito: true)
        let aiTab = BrowserTab(title: "Assistant", url: try XCTUnwrap(URL(string: "https://chatgpt.com/")))
        aiTab.webAIProvider = .chatgpt

        let eligible = BrowserOpenTabEntities.eligibleTabs([regular, privateTab, aiTab])
        XCTAssertEqual(eligible.map(\.id), [regular.id])

        let entities = BrowserOpenTabEntities.entities(from: [regular, privateTab, aiTab])
        XCTAssertEqual(entities.map(\.id), [regular.id.uuidString])
        XCTAssertEqual(entities.map(\.title), ["Regular"])
    }

    func testCurrentTabIsListedFirstForSiri() {
        let a = BrowserTab(title: "A", url: URL(string: "https://a.example/"))
        let b = BrowserTab(title: "B", url: URL(string: "https://b.example/"))
        let c = BrowserTab(title: "C", url: URL(string: "https://c.example/"))
        let ordered = BrowserIntentRuntime.currentTabFirst([a, b, c], selectedID: c.id)
        XCTAssertEqual(ordered.map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(BrowserIntentRuntime.currentTabFirst([a, b], selectedID: nil).map(\.id), [a.id, b.id])
        XCTAssertEqual(BrowserIntentRuntime.currentTabFirst([a, b], selectedID: UUID()).map(\.id), [a.id, b.id])
    }

}
