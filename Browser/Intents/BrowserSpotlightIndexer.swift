import AppIntents
import CoreSpotlight
import Foundation

extension Notification.Name {
    /// Posted by BrowserViewModel whenever Favorites or Favorite folders are saved.
    static let browserFavoritesDidChange = Notification.Name("BrowserFavoritesDidChange")
    /// Posted by AgentTaskStore after a saved task is added, updated or deleted.
    static let savedAgentTasksDidChange = Notification.Name("SavedAgentTasksDidChange")
    /// Posted by HistoryStore after a visit is recorded, removed or cleared.
    static let browserHistoryDidChange = Notification.Name("BrowserHistoryDidChange")
}

enum BrowserSpotlightKind: String, CaseIterable, Sendable {
    case bookmarks
    case savedTasks
    case history
}

enum BrowserSpotlightSettings {
    static let bookmarksKey = "spotlight.bookmarks.enabled"
    static let savedTasksKey = "spotlight.savedTasks.enabled"
    static let historyKey = "spotlight.history.enabled"

    static func key(for kind: BrowserSpotlightKind) -> String {
        switch kind {
        case .bookmarks: return bookmarksKey
        case .savedTasks: return savedTasksKey
        case .history: return historyKey
        }
    }

    /// Bookmarks and saved tasks default on; history defaults off. Absent keys use these defaults.
    static func isEnabled(_ kind: BrowserSpotlightKind, defaults: UserDefaults = .standard) -> Bool {
        if let stored = defaults.object(forKey: key(for: kind)) as? Bool {
            return stored
        }
        return kind != .history
    }
}

/// The part of CoreSpotlight the indexer uses. Tests inject a fake; the app uses CoreSpotlightIndexClient.
@MainActor
protocol SpotlightIndexClient {
    func indexBookmarks(_ entities: [BookmarkEntity]) async throws
    func indexSavedTasks(_ entities: [AgentTaskEntity]) async throws
    func indexHistory(_ entities: [HistoryEntity]) async throws
    func deleteEntities(_ kind: BrowserSpotlightKind, identifiers: [String]) async throws
    func deleteAllEntities(_ kind: BrowserSpotlightKind) async throws
}

@MainActor
struct CoreSpotlightIndexClient: SpotlightIndexClient {
    func indexBookmarks(_ entities: [BookmarkEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    func indexSavedTasks(_ entities: [AgentTaskEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    func indexHistory(_ entities: [HistoryEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    func deleteEntities(_ kind: BrowserSpotlightKind, identifiers: [String]) async throws {
        let index = CSSearchableIndex.default()
        switch kind {
        case .bookmarks:
            try await index.deleteAppEntities(identifiedBy: identifiers, ofType: BookmarkEntity.self)
        case .savedTasks:
            try await index.deleteAppEntities(identifiedBy: identifiers, ofType: AgentTaskEntity.self)
        case .history:
            try await index.deleteAppEntities(identifiedBy: identifiers, ofType: HistoryEntity.self)
        }
    }

    func deleteAllEntities(_ kind: BrowserSpotlightKind) async throws {
        let index = CSSearchableIndex.default()
        switch kind {
        case .bookmarks:
            try await index.deleteAppEntities(ofType: BookmarkEntity.self)
        case .savedTasks:
            try await index.deleteAppEntities(ofType: AgentTaskEntity.self)
        case .history:
            try await index.deleteAppEntities(ofType: HistoryEntity.self)
        }
    }
}

/// Keeps Spotlight entities in step with bookmarks, saved tasks and (opt-in) history.
///
/// Each kind is reconciled as a whole: current items are indexed, and identifiers seen before but
/// no longer present are deleted. A disabled kind has all of its entities deleted. Changes are
/// debounced, applies for one kind run one after another, and an unreadable source leaves the
/// existing index untouched.
@MainActor
final class BrowserSpotlightIndexer {
    typealias SavedTaskSource = @MainActor () throws -> [SavedAgentTask]
    typealias HistorySource = @MainActor () -> [HistoryEntry]

    static let shared = BrowserSpotlightIndexer(
        client: CoreSpotlightIndexClient(),
        defaults: .standard,
        savedTasks: {
            let store = try AgentTaskIntentRuntime.makeStore()
            try store.load()
            return store.savedTasks
        },
        history: { HistoryStore.shared.entries }
    )

    private let client: SpotlightIndexClient
    private let defaults: UserDefaults
    private let savedTasksSource: SavedTaskSource
    private let historySource: HistorySource
    private let debounce: Duration
    private var pendingChanges: [BrowserSpotlightKind: Task<Void, Never>] = [:]
    private var applyChain: [BrowserSpotlightKind: Task<Void, Never>] = [:]
    /// Identifiers this process last wrote for each kind. A missing key means unknown (after launch
    /// or a failed write), so the next write purges that kind first.
    private var indexedIDs: [BrowserSpotlightKind: Set<String>] = [:]
    private var didReindexAll = false
    private var observers: [NSObjectProtocol] = []

    init(
        client: SpotlightIndexClient,
        defaults: UserDefaults,
        savedTasks: @escaping SavedTaskSource,
        history: @escaping HistorySource,
        debounce: Duration = .seconds(1)
    ) {
        self.client = client
        self.defaults = defaults
        self.savedTasksSource = savedTasks
        self.historySource = history
        self.debounce = debounce
    }

    /// Listens for change notifications from the stores. Called once from the app, never from tests.
    func startObserving() {
        guard observers.isEmpty else { return }
        let changes: [(Notification.Name, BrowserSpotlightKind)] = [
            (.browserFavoritesDidChange, .bookmarks),
            (.savedAgentTasksDidChange, .savedTasks),
            (.browserHistoryDidChange, .history)
        ]
        observers = changes.map { name, kind in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.changed(kind)
                }
            }
        }
    }

    /// Full rebuild for launch: purges each kind, then indexes what is current. Runs once per launch.
    func reindexAll() async {
        guard !didReindexAll else { return }
        didReindexAll = true
        for kind in BrowserSpotlightKind.allCases {
            await enqueueApply(kind, purge: true)
        }
    }

    /// Called when a toggle changes. Turning a kind off deletes its entities; turning it on indexes them.
    func settingChanged(_ kind: BrowserSpotlightKind) {
        changed(kind)
    }

    /// Schedules a debounced reconcile for one kind. A burst of changes produces one reconcile.
    func changed(_ kind: BrowserSpotlightKind) {
        pendingChanges[kind]?.cancel()
        let delay = debounce
        pendingChanges[kind] = Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.enqueueApply(kind, purge: false)
        }
    }

    /// Waits for debounced changes to reach the index. Used by tests.
    func waitForPendingSyncs() async {
        let pending = Array(pendingChanges.values)
        for task in pending {
            await task.value
        }
    }

    private func enqueueApply(_ kind: BrowserSpotlightKind, purge: Bool) async {
        let previous = applyChain[kind]
        let work = Task { @MainActor [weak self] in
            await previous?.value
            await self?.apply(kind, purge: purge)
        }
        applyChain[kind] = work
        await work.value
    }

    private func apply(_ kind: BrowserSpotlightKind, purge: Bool) async {
        guard BrowserSpotlightSettings.isEnabled(kind, defaults: defaults) else {
            await clear(kind, purge: purge)
            return
        }
        do {
            switch kind {
            case .bookmarks:
                let entities = try BrowserSpotlightBookmarkStorage.bookmarks(from: defaults)
                try await write(kind, ids: entities.map(\.id), purge: purge) {
                    try await self.client.indexBookmarks(entities)
                }
            case .savedTasks:
                let entities = AgentTaskEntity.indexable(from: try savedTasksSource())
                try await write(kind, ids: entities.map(\.id), purge: purge) {
                    try await self.client.indexSavedTasks(entities)
                }
            case .history:
                let entities = HistoryEntity.indexable(from: historySource())
                try await write(kind, ids: entities.map(\.id), purge: purge) {
                    try await self.client.indexHistory(entities)
                }
            }
        } catch {
            // Unreadable or failed: forget what was written so the next write purges first.
            indexedIDs[kind] = nil
        }
    }

    private func write(
        _ kind: BrowserSpotlightKind,
        ids: [String],
        purge: Bool,
        index: () async throws -> Void
    ) async throws {
        let previous = indexedIDs[kind]
        indexedIDs[kind] = nil
        if purge || previous == nil {
            try await client.deleteAllEntities(kind)
        } else if let previous {
            let stale = Array(previous.subtracting(ids))
            if !stale.isEmpty {
                try await client.deleteEntities(kind, identifiers: stale)
            }
        }
        if !ids.isEmpty {
            try await index()
        }
        indexedIDs[kind] = Set(ids)
    }

    private func clear(_ kind: BrowserSpotlightKind, purge: Bool) async {
        let hasEntries = indexedIDs[kind].map { !$0.isEmpty } ?? true
        guard purge || hasEntries else { return }
        indexedIDs[kind] = nil
        do {
            try await client.deleteAllEntities(kind)
            indexedIDs[kind] = []
        } catch {
            indexedIDs[kind] = nil
        }
    }
}
