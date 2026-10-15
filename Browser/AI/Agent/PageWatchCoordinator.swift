import Foundation

protocol PageWatchClock {
    var now: Date { get }
}

struct SystemPageWatchClock: PageWatchClock {
    var now: Date { Date() }
}

/// Owns page-watch creation, editing, due checks and the schedule. Views, intents and the background task all go through it.
@MainActor
final class PageWatchCoordinator {
    @MainActor static let shared = PageWatchCoordinator()

    static let backgroundWatchLimit = 5
    nonisolated static let backgroundBudget: TimeInterval = 25
    static let minimumBackgroundInterval: TimeInterval = 3_600
    static let activationInterval: TimeInterval = 15 * 60

    struct RunSummary: Equatable {
        var checked = 0
        var changedTitles: [String] = []
        var failedTitles: [String] = []

        /// The text returned by Check Watched Pages.
        var intentMessage: String {
            guard !changedTitles.isEmpty else { return "No watched pages changed." }
            return "Changed: " + changedTitles.joined(separator: ", ") + "."
        }
    }

    enum RecordedResult: Equatable {
        case baseline
        case unchanged
        case changed
        case failed(String)
        case skipped(String)
        case missing
    }

    private let storeProvider: @MainActor () throws -> PageWatchStore
    private let checker: PageWatchChecker
    private let notifier: PageWatchNotifying
    private let clock: PageWatchClock
    private let scheduler: @MainActor (Date?) -> Void
    private var inFlight: Set<UUID> = []
    private var isRunningDueChecks = false
    private var lastActivationCheck: Date?

    /// Defaults are built in the body, which runs on the main actor; tests pass fakes for each seam.
    init(
        storeProvider: (@MainActor () throws -> PageWatchStore)? = nil,
        checker: PageWatchChecker? = nil,
        notifier: PageWatchNotifying? = nil,
        clock: PageWatchClock? = nil,
        scheduler: (@MainActor (Date?) -> Void)? = nil
    ) {
        self.storeProvider = storeProvider ?? { try PageWatchStoreLocation.makeDefaultStore() }
        self.checker = checker ?? PageWatchChecker()
        self.notifier = notifier ?? UserNotificationPageWatchNotifier()
        self.clock = clock ?? SystemPageWatchClock()
        self.scheduler = scheduler ?? { PageWatchBackgroundScheduler.schedule(earliest: $0) }
    }

    /// The earliest moment a background refresh should run: the first due text watch, never sooner than an hour away.
    static func nextBackgroundRefreshDate(for watches: [PageWatch], now: Date) -> Date? {
        guard let due = watches.filter(\.isBackgroundEligible).map(\.nextDueDate).min() else { return nil }
        return max(due, now.addingTimeInterval(minimumBackgroundInterval))
    }

    func watches() throws -> [PageWatch] {
        let store = try storeProvider()
        try store.load()
        return store.watches
    }

    func nextBackgroundRefreshDate() throws -> Date? {
        Self.nextBackgroundRefreshDate(for: try watches(), now: clock.now)
    }

    // MARK: Creating and editing

    /// Creates a text watch for a web page. Used by Watch Page; the sheet builds its own watch and calls `createWatch`.
    func createTextWatch(
        url: URL,
        title: String?,
        interval: PageWatchInterval,
        notify: Bool
    ) throws -> PageWatch {
        guard PageWatch.isWebURL(url) else {
            throw PageWatchCheckError.notWebPage
        }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackTitle = url.host ?? url.absoluteString
        let watch = PageWatch(
            title: String((trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle).prefix(PageWatch.maximumTitleCharacters)),
            url: url,
            mode: .text(selector: nil),
            interval: interval,
            notify: notify,
            createdAt: clock.now
        )
        try createWatch(watch)
        return watch
    }

    /// Adds a new watch. The store enforces the limit of \(PageWatch.maximumWatches) watches.
    func createWatch(_ watch: PageWatch) throws {
        let store = try storeProvider()
        try store.addWatch(watch)
        scheduler(try? nextBackgroundRefreshDate())
    }

    /// Changes the editable fields of a stored watch. Its baseline is kept unless the checked content changes
    /// (a different selector or saved task), so an edit alone never reports a change.
    @discardableResult
    func editWatch(
        id: UUID,
        title: String,
        interval: PageWatchInterval,
        notify: Bool,
        mode: PageWatchMode
    ) throws -> PageWatch {
        let store = try storeProvider()
        try store.load()
        guard var watch = try store.watch(id: id) else { throw PageWatchStoreError.missingWatch }
        watch.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PageWatch.maximumTitleCharacters))
        watch.interval = interval
        watch.notify = notify
        if watch.mode != mode {
            watch.mode = mode
            watch.lastValueHash = nil
            watch.lastValuePreview = nil
            watch.lastValueSource = nil
            watch.lastChangeAt = nil
            watch.lastError = nil
        }
        try store.updateWatch(watch)
        scheduler(try? nextBackgroundRefreshDate())
        return watch
    }

    func deleteWatch(id: UUID) throws {
        let store = try storeProvider()
        try store.deleteWatch(id: id)
        scheduler(try? nextBackgroundRefreshDate())
    }

    /// Asks for notification permission the first time a watch with notifications on is saved.
    func prepareNotifications(for notify: Bool) async {
        guard notify else { return }
        await notifier.prepareForNotifications()
    }

    // MARK: Checking

    /// Checks every due watch in order. Background runs check only text watches without a selector.
    func checkDueWatches(
        mode: PageWatchChecker.Mode,
        limit: Int? = nil,
        deadline: Date? = nil
    ) async throws -> RunSummary {
        guard !isRunningDueChecks else { return RunSummary() }
        isRunningDueChecks = true
        defer { isRunningDueChecks = false }

        let store = try storeProvider()
        try store.load()
        let now = clock.now
        let candidates = store.watches
            .filter { $0.isDue(now: now) && (mode == .foreground || $0.isBackgroundEligible) }
            .sorted { $0.nextDueDate < $1.nextDueDate }

        var summary = RunSummary()
        for watch in candidates {
            if Task.isCancelled { break }
            if let limit, summary.checked >= limit { break }
            let remaining = deadline.map { $0.timeIntervalSince(clock.now) } ?? PageWatchChecker.defaultTimeout
            if deadline != nil, remaining < 1 { break }
            guard !inFlight.contains(watch.id) else { continue }
            summary.checked += 1
            switch await check(watch: watch, mode: mode, timeout: min(PageWatchChecker.defaultTimeout, remaining), store: store) {
            case .changed:
                summary.changedTitles.append(watch.title)
            case .failed:
                summary.failedTitles.append(watch.title)
            case .baseline, .unchanged, .skipped, .missing:
                break
            }
        }
        scheduler(try? nextBackgroundRefreshDate())
        return summary
    }

    /// The summary text returned by Check Watched Pages.
    func checkDueWatchesMessage() async throws -> String {
        try await checkDueWatches(mode: .foreground).intentMessage
    }

    /// Check Now for one watch, always in the foreground.
    func checkWatch(id: UUID) async throws -> RecordedResult {
        let store = try storeProvider()
        try store.load()
        guard let watch = store.watches.first(where: { $0.id == id }) else { return .missing }
        guard !inFlight.contains(id) else { return .skipped("This page is already being checked.") }
        return await check(watch: watch, mode: .foreground, timeout: PageWatchChecker.defaultTimeout, store: store)
    }

    /// Foreground check of all due watches, at most once per 15 minutes. Pass `isIdle` false while an agent run is active.
    func checkOnActivation(isIdle: Bool) async -> RunSummary? {
        guard isIdle, !isRunningDueChecks else { return nil }
        let now = clock.now
        if let lastActivationCheck, now.timeIntervalSince(lastActivationCheck) < Self.activationInterval {
            return nil
        }
        lastActivationCheck = now
        return try? await checkDueWatches(mode: .foreground)
    }

    /// One background run: at most `backgroundWatchLimit` due text watches within the time budget.
    func runBackgroundRefresh(budget: TimeInterval = PageWatchCoordinator.backgroundBudget) async -> RunSummary? {
        let deadline = clock.now.addingTimeInterval(budget)
        return try? await checkDueWatches(mode: .background, limit: Self.backgroundWatchLimit, deadline: deadline)
    }

    private func check(
        watch: PageWatch,
        mode: PageWatchChecker.Mode,
        timeout: TimeInterval,
        store: PageWatchStore
    ) async -> RecordedResult {
        inFlight.insert(watch.id)
        defer { inFlight.remove(watch.id) }
        let outcome = await checker.check(watch, mode: mode, timeout: timeout)
        let now = clock.now
        do {
            try store.load()
            guard let latest = try store.watch(id: watch.id) else { return .missing }
            switch outcome {
            case .observed(let observation):
                let update = PageWatchEvaluator.apply(observation, to: latest, at: now)
                try store.updateWatch(update.watch)
                guard update.didChange else {
                    return update.isBaseline ? .baseline : .unchanged
                }
                if update.watch.notify {
                    await notifier.notifyChanged(update.watch, preview: observation.preview)
                }
                return .changed
            case .failed(let message):
                try store.updateWatch(PageWatchEvaluator.recordFailure(message, on: latest, at: now))
                return .failed(message)
            case .skipped(let reason):
                return .skipped(reason)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
