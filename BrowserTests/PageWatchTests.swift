import XCTest
@testable import Browser

/// Fixed time for every test. Advancing it is how a test makes a watch due.
nonisolated private final class FakeClock: PageWatchClock, @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

@MainActor
private final class FakeForeground: PageWatchForegroundLoading {
    var text = "Price 4"
    var error: Error?
    private(set) var selectors: [String?] = []

    func loadText(url: URL, selector: String?) async throws -> String {
        selectors.append(selector)
        if let error { throw error }
        return text
    }
}

nonisolated private final class FakeBackground: PageWatchBackgroundFetching, @unchecked Sendable {
    var defaultHTML = "<html><body><p>Price 4</p></body></html>"
    var pages: [String: String] = [:]
    /// Runs before each fetch, so a test can spend the background budget.
    var beforeFetch: (() -> Void)?
    private(set) var requestedURLs: [URL] = []

    func fetchText(url: URL, timeout: TimeInterval) async throws -> PageWatchFetchedPage {
        requestedURLs.append(url)
        beforeFetch?()
        let html = pages[url.absoluteString] ?? defaultHTML
        return PageWatchFetchedPage(text: PageWatchText.visibleText(fromHTML: html), finalURL: url)
    }
}

@MainActor
private final class FakeAgent: PageWatchAgentRunning {
    var outcome: AgentRunWaitOutcome = .timedOut
    private(set) var calls = 0

    func runSavedTask(_ task: SavedAgentTask, timeout: Duration) async -> AgentRunWaitOutcome {
        calls += 1
        return outcome
    }
}

@MainActor
private final class FakeNotifier: PageWatchNotifying {
    private(set) var notified: [(title: String, preview: String)] = []
    private(set) var prepareCalls = 0

    func prepareForNotifications() async {
        prepareCalls += 1
    }

    func notifyChanged(_ watch: PageWatch, preview: String) async {
        notified.append((title: watch.title, preview: preview))
    }
}

@MainActor
private final class FlaggedOrigins {
    var blockedHosts: Set<String> = []
}

@MainActor
private struct Harness {
    let store: PageWatchStore
    let foreground: FakeForeground
    let background: FakeBackground
    let agent: FakeAgent
    let notifier: FakeNotifier
    let clock: FakeClock
    let origins: FlaggedOrigins
    let coordinator: PageWatchCoordinator
    let savedTaskID: UUID
}

@MainActor
final class PageWatchTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 10_000)

    private func makeStore() throws -> (PageWatchStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageWatchTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("PageWatches.json")
        return (PageWatchStore(fileURL: fileURL), fileURL)
    }

    private func makeWatch(
        title: String = "Prices",
        url: String = "https://example.com/prices",
        mode: PageWatchMode = .text(selector: nil),
        interval: PageWatchInterval = .daily,
        notify: Bool = true,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        lastCheckedAt: Date? = nil
    ) -> PageWatch {
        PageWatch(
            title: title,
            url: URL(string: url)!,
            mode: mode,
            interval: interval,
            notify: notify,
            createdAt: createdAt,
            lastCheckedAt: lastCheckedAt
        )
    }

    private func makeHarness() throws -> Harness {
        let (store, _) = try makeStore()
        let foreground = FakeForeground()
        let background = FakeBackground()
        let agent = FakeAgent()
        let notifier = FakeNotifier()
        let clock = FakeClock(now: start)
        let origins = FlaggedOrigins()
        let savedTaskID = UUID()
        let checker = PageWatchChecker(
            foreground: foreground,
            background: background,
            agent: agent,
            savedTask: { id in SavedAgentTask(id: id, title: "Saved", task: "Find the price") },
            isBlockedOrigin: { url in origins.blockedHosts.contains(url.host ?? "") }
        )
        let coordinator = PageWatchCoordinator(
            storeProvider: { store },
            checker: checker,
            notifier: notifier,
            clock: clock,
            scheduler: { _ in }
        )
        return Harness(
            store: store,
            foreground: foreground,
            background: background,
            agent: agent,
            notifier: notifier,
            clock: clock,
            origins: origins,
            coordinator: coordinator,
            savedTaskID: savedTaskID
        )
    }

    private func makeSnapshot(outcome: String, isPrivate: Bool = false) -> BrowserAgentController.CompletionSnapshot {
        BrowserAgentController.CompletionSnapshot(
            runID: UUID(),
            task: "Find the price",
            outcome: outcome,
            actions: [],
            date: Date(timeIntervalSinceReferenceDate: 2_000),
            backend: "test",
            preset: "standard",
            startURL: nil,
            isPrivate: isPrivate,
            savedTaskID: nil,
            sources: [],
            requestID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 1_900),
            status: .completed,
            exportedFiles: []
        )
    }

    // MARK: Store

    func testStoreRoundTripsWatches() throws {
        let (store, fileURL) = try makeStore()
        let watch = makeWatch(mode: .text(selector: "#price"), interval: .weekly, notify: false)
        try store.addWatch(watch)

        let restored = PageWatchStore(fileURL: fileURL)
        try restored.load()
        XCTAssertEqual(restored.watches, [watch])
    }

    func testStoreEnforcesTwentyWatchLimit() throws {
        let (store, _) = try makeStore()
        for index in 0..<PageWatch.maximumWatches {
            try store.addWatch(makeWatch(url: "https://example.com/\(index)"))
        }
        XCTAssertThrowsError(try store.addWatch(makeWatch(url: "https://example.com/extra"))) { error in
            XCTAssertEqual(error as? PageWatchStoreError, .watchLimitReached)
        }
        XCTAssertEqual(store.watches.count, PageWatch.maximumWatches)
    }

    func testStoreDecodesDocumentWithoutOptionalFields() throws {
        let (store, fileURL) = try makeStore()
        let id = UUID()
        let json = """
        {"version":1,"watches":[{"id":"\(id.uuidString)","title":"Prices","url":"https://example.com/prices",\
        "mode":{"text":{}},"interval":"daily","notify":true,"createdAt":1000}]}
        """
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)

        try store.load()
        XCTAssertEqual(store.watches.map(\.id), [id])
        XCTAssertNil(store.watches.first?.lastValueHash)
        XCTAssertNil(store.watches.first?.lastValueSource)
        XCTAssertEqual(store.watches.first?.mode, .text(selector: nil))
    }

    func testCorruptDocumentIsReportedAndNeverOverwritten() throws {
        let (store, fileURL) = try makeStore()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("not json at all".utf8)
        try garbage.write(to: fileURL)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? PageWatchStoreError, .corruptData)
        }
        XCTAssertThrowsError(try store.addWatch(makeWatch())) { error in
            XCTAssertEqual(error as? PageWatchStoreError, .corruptData)
        }
        XCTAssertThrowsError(try store.deleteWatch(id: UUID()))
        XCTAssertEqual(try Data(contentsOf: fileURL), garbage)
    }

    func testUnsupportedVersionIsReportedAndNeverOverwritten() throws {
        let (store, fileURL) = try makeStore()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = Data(#"{"version":2,"watches":[]}"#.utf8)
        try future.write(to: fileURL)

        XCTAssertThrowsError(try store.addWatch(makeWatch())) { error in
            XCTAssertEqual(error as? PageWatchStoreError, .unsupportedVersion(2))
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), future)
    }

    func testStoreRejectsInvalidWatchesAndMissingUpdates() throws {
        let (store, _) = try makeStore()
        XCTAssertThrowsError(try store.addWatch(makeWatch(url: "ftp://example.com/file"))) { error in
            XCTAssertEqual(error as? PageWatchStoreError, .invalidWatch)
        }
        XCTAssertThrowsError(try store.addWatch(makeWatch(title: "   "))) { error in
            XCTAssertEqual(error as? PageWatchStoreError, .invalidWatch)
        }
        XCTAssertThrowsError(try store.updateWatch(makeWatch())) { error in
            XCTAssertEqual(error as? PageWatchStoreError, .missingWatch)
        }
    }

    func testUpdateKeepsCreationDate() throws {
        let (store, _) = try makeStore()
        let watch = makeWatch(createdAt: Date(timeIntervalSinceReferenceDate: 1_000))
        try store.addWatch(watch)

        var edited = watch
        edited.title = "Renamed"
        edited.createdAt = Date(timeIntervalSinceReferenceDate: 9_999)
        try store.updateWatch(edited)
        XCTAssertEqual(try store.watch(id: watch.id)?.title, "Renamed")
        XCTAssertEqual(try store.watch(id: watch.id)?.createdAt, watch.createdAt)
    }

    func testFieldLimitsAndHashFormat() {
        var watch = makeWatch()
        XCTAssertTrue(watch.isValid)

        watch.lastValuePreview = String(repeating: "a", count: PageWatch.maximumPreviewCharacters + 1)
        XCTAssertFalse(watch.isValid)
        watch.lastValuePreview = nil

        watch.mode = .text(selector: String(repeating: "#", count: PageWatch.maximumSelectorCharacters + 1))
        XCTAssertFalse(watch.isValid)
        watch.mode = .text(selector: nil)

        watch.lastValueHash = "ABC"
        XCTAssertFalse(watch.isValid)
        watch.lastValueHash = PageWatchText.fingerprint("x")
        XCTAssertTrue(watch.isValid)
    }

    // MARK: Due dates

    func testIsDueAndNextDueDateForEachInterval() {
        let checked = Date(timeIntervalSinceReferenceDate: 50_000)
        for interval in PageWatchInterval.allCases {
            let watch = makeWatch(interval: interval, lastCheckedAt: checked)
            let due = checked.addingTimeInterval(interval.seconds)
            XCTAssertEqual(watch.nextDueDate, due, "\(interval)")
            XCTAssertFalse(watch.isDue(now: due.addingTimeInterval(-1)), "\(interval)")
            XCTAssertTrue(watch.isDue(now: due), "\(interval)")
        }
        XCTAssertEqual(PageWatchInterval.hourly.seconds, 3_600)
        XCTAssertEqual(PageWatchInterval.every6Hours.seconds, 21_600)
        XCTAssertEqual(PageWatchInterval.daily.seconds, 86_400)
        XCTAssertEqual(PageWatchInterval.weekly.seconds, 604_800)
    }

    func testNeverCheckedWatchIsDueFromCreation() {
        let created = Date(timeIntervalSinceReferenceDate: 1_000)
        let watch = makeWatch(createdAt: created)
        XCTAssertEqual(watch.nextDueDate, created)
        XCTAssertTrue(watch.isDue(now: created))
    }

    func testNextBackgroundRefreshIsAtLeastOneHourAwayAndIgnoresAgentWatches() {
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        XCTAssertNil(PageWatchCoordinator.nextBackgroundRefreshDate(
            for: [makeWatch(mode: .agent(savedTaskID: UUID()))],
            now: now
        ))
        let overdue = makeWatch(createdAt: Date(timeIntervalSinceReferenceDate: 1))
        XCTAssertEqual(
            PageWatchCoordinator.nextBackgroundRefreshDate(for: [overdue], now: now),
            now.addingTimeInterval(PageWatchCoordinator.minimumBackgroundInterval)
        )
        let later = makeWatch(interval: .weekly, lastCheckedAt: now)
        XCTAssertEqual(
            PageWatchCoordinator.nextBackgroundRefreshDate(for: [later], now: now),
            now.addingTimeInterval(PageWatchInterval.weekly.seconds)
        )
    }

    // MARK: Normalization and extraction

    func testNormalizeDropsClockTimesAndCollapsesWhitespace() {
        XCTAssertEqual(
            PageWatchText.normalize("  Updated   12:34 and 9:05:11\n\n Price  $4  "),
            "Updated and Price $4"
        )
        XCTAssertEqual(PageWatchText.normalize("Open 123:45 today"), "Open 123:45 today")
    }

    func testVisibleTextRemovesScriptStyleNoscriptAndComments() {
        let html = """
        <html><head><style>p { color: red }</style><script>var secret = "x";</script></head>
        <body><p>Hello &amp; welcome</p><noscript>enable js</noscript><!-- hidden -->
        <p>Price&nbsp;&#36;5</p></body></html>
        """
        XCTAssertEqual(PageWatchText.visibleText(fromHTML: html), "Hello & welcome Price $5")
    }

    func testEntityDecodingIsSinglePass() {
        XCTAssertEqual(PageWatchText.decodeEntities("&amp;lt;"), "&lt;")
        XCTAssertEqual(PageWatchText.decodeEntities("&#x41;&#66;"), "AB")
    }

    func testFingerprintIsSHA256OfNormalizedText() {
        XCTAssertEqual(
            PageWatchText.fingerprint("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: Change detection

    func testFirstCheckRecordsBaselineThenChangeNotifiesOnce() async throws {
        let harness = try makeHarness()
        let watch = makeWatch()
        try harness.store.addWatch(watch)

        harness.foreground.text = "Price 4"
        let first = try await harness.coordinator.checkWatch(id: watch.id)
        XCTAssertEqual(first, .baseline)
        XCTAssertTrue(harness.notifier.notified.isEmpty)

        harness.foreground.text = "Price 5"
        let second = try await harness.coordinator.checkWatch(id: watch.id)
        XCTAssertEqual(second, .changed)
        XCTAssertEqual(harness.notifier.notified.map { $0.preview }, ["Price 5"])

        harness.foreground.text = "Price 5"
        let third = try await harness.coordinator.checkWatch(id: watch.id)
        XCTAssertEqual(third, .unchanged)
        XCTAssertEqual(harness.notifier.notified.count, 1)
    }

    func testTimestampOnlyChangeDoesNotNotify() async throws {
        let harness = try makeHarness()
        let watch = makeWatch()
        try harness.store.addWatch(watch)

        harness.foreground.text = "Updated 12:34 Price 4"
        _ = try await harness.coordinator.checkWatch(id: watch.id)
        harness.foreground.text = "Updated 12:59:02 Price 4"
        let result = try await harness.coordinator.checkWatch(id: watch.id)
        XCTAssertEqual(result, .unchanged)
        XCTAssertTrue(harness.notifier.notified.isEmpty)
    }

    func testChangeWithNotificationsOffIsRecordedButNotNotified() async throws {
        let harness = try makeHarness()
        let watch = makeWatch(notify: false)
        try harness.store.addWatch(watch)

        harness.foreground.text = "Price 4"
        _ = try await harness.coordinator.checkWatch(id: watch.id)
        harness.foreground.text = "Price 6"
        let result = try await harness.coordinator.checkWatch(id: watch.id)
        XCTAssertEqual(result, .changed)
        XCTAssertTrue(harness.notifier.notified.isEmpty)
        XCTAssertNotNil(try harness.store.watch(id: watch.id)?.lastChangeAt)
    }

    func testFailureRecordsErrorAndKeepsBaseline() async throws {
        let harness = try makeHarness()
        let watch = makeWatch()
        try harness.store.addWatch(watch)

        harness.foreground.text = "Price 4"
        _ = try await harness.coordinator.checkWatch(id: watch.id)
        let baseline = try XCTUnwrap(try harness.store.watch(id: watch.id)?.lastValueHash)

        harness.foreground.error = PageWatchCheckError.emptyPage
        let result = try await harness.coordinator.checkWatch(id: watch.id)
        guard case .failed = result else {
            return XCTFail("Expected a failed check, got \(result)")
        }
        let stored = try XCTUnwrap(try harness.store.watch(id: watch.id))
        XCTAssertNotNil(stored.lastError)
        XCTAssertEqual(stored.lastValueHash, baseline)
        XCTAssertTrue(harness.notifier.notified.isEmpty)
    }

    func testReadingFromAnotherSourceRebaselinesWithoutNotifying() async throws {
        let harness = try makeHarness()
        let watch = makeWatch()
        try harness.store.addWatch(watch)

        harness.foreground.text = "Price 4"
        _ = try await harness.coordinator.checkWatch(id: watch.id)

        // The background read uses a different extraction, so its hash is never compared with the foreground one.
        harness.clock.now = harness.clock.now.addingTimeInterval(PageWatchInterval.daily.seconds + 1)
        harness.background.defaultHTML = "<html><body>Price 9</body></html>"
        let summary = try await harness.coordinator.checkDueWatches(mode: .background)
        XCTAssertEqual(summary.checked, 1)
        XCTAssertTrue(summary.changedTitles.isEmpty)
        XCTAssertTrue(harness.notifier.notified.isEmpty)
        XCTAssertEqual(try harness.store.watch(id: watch.id)?.lastValueSource, .urlSessionText)
    }

    // MARK: Background and foreground scheduling

    func testBackgroundRunSkipsAgentAndSelectorWatchesAndStopsAtFive() async throws {
        let harness = try makeHarness()
        for index in 0..<7 {
            try harness.store.addWatch(makeWatch(title: "Page \(index)", url: "https://example.com/page/\(index)"))
        }
        try harness.store.addWatch(makeWatch(title: "Selector", url: "https://example.com/selector", mode: .text(selector: "#price")))
        try harness.store.addWatch(makeWatch(title: "Agent", url: "https://example.com/agent", mode: .agent(savedTaskID: harness.savedTaskID)))

        let summary = await harness.coordinator.runBackgroundRefresh()
        XCTAssertEqual(summary?.checked, PageWatchCoordinator.backgroundWatchLimit)
        XCTAssertEqual(harness.background.requestedURLs.count, 5)
        XCTAssertFalse(harness.background.requestedURLs.contains { $0.path == "/selector" || $0.path == "/agent" })
        XCTAssertEqual(harness.agent.calls, 0)
        XCTAssertTrue(harness.foreground.selectors.isEmpty)
    }

    func testBackgroundRunStopsWhenItsTimeBudgetIsSpent() async throws {
        let harness = try makeHarness()
        for index in 0..<4 {
            try harness.store.addWatch(makeWatch(title: "Page \(index)", url: "https://example.com/page/\(index)"))
        }
        // Each read takes ten seconds, so a 25 second budget allows three reads.
        let clock = harness.clock
        harness.background.beforeFetch = { clock.now = clock.now.addingTimeInterval(10) }

        _ = await harness.coordinator.runBackgroundRefresh(budget: PageWatchCoordinator.backgroundBudget)
        XCTAssertEqual(harness.background.requestedURLs.count, 3)
    }

    func testBackgroundRunIgnoresWatchesThatAreNotDue() async throws {
        let harness = try makeHarness()
        try harness.store.addWatch(makeWatch(lastCheckedAt: harness.clock.now))
        _ = await harness.coordinator.runBackgroundRefresh()
        XCTAssertTrue(harness.background.requestedURLs.isEmpty)
    }

    func testAgentWatchIsNeverRunInTheBackground() async throws {
        let harness = try makeHarness()
        let watch = makeWatch(mode: .agent(savedTaskID: harness.savedTaskID))
        try harness.store.addWatch(watch)
        let outcome = try await harness.coordinator.checkDueWatches(mode: .background)
        XCTAssertEqual(outcome.checked, 0)
        XCTAssertNil(try harness.store.watch(id: watch.id)?.lastValueHash)

        let checker = PageWatchChecker(
            foreground: harness.foreground,
            background: harness.background,
            agent: harness.agent,
            savedTask: { _ in nil },
            isBlockedOrigin: { _ in false }
        )
        let result = await checker.check(watch, mode: .background)
        guard case .skipped = result else {
            return XCTFail("Expected the agent watch to be skipped, got \(result)")
        }
        XCTAssertEqual(harness.agent.calls, 0)
    }

    func testForegroundActivationIsThrottledToFifteenMinutes() async throws {
        let harness = try makeHarness()
        let idleWithoutAgent = await harness.coordinator.checkOnActivation(isIdle: false)
        XCTAssertNil(idleWithoutAgent)

        let first = await harness.coordinator.checkOnActivation(isIdle: true)
        XCTAssertNotNil(first)
        let immediate = await harness.coordinator.checkOnActivation(isIdle: true)
        XCTAssertNil(immediate)

        harness.clock.now = harness.clock.now.addingTimeInterval(PageWatchCoordinator.activationInterval)
        let later = await harness.coordinator.checkOnActivation(isIdle: true)
        XCTAssertNotNil(later)
    }

    func testBlockedOriginIsRefusedBeforeAnyRead() async throws {
        let harness = try makeHarness()
        harness.origins.blockedHosts = ["example.com"]
        let watch = makeWatch()
        try harness.store.addWatch(watch)

        _ = try await harness.coordinator.checkDueWatches(mode: .background)
        XCTAssertTrue(harness.background.requestedURLs.isEmpty)
        XCTAssertNotNil(try harness.store.watch(id: watch.id)?.lastError)

        let foreground = try await harness.coordinator.checkWatch(id: watch.id)
        guard case .failed = foreground else {
            return XCTFail("Expected the foreground read to be refused, got \(foreground)")
        }
        XCTAssertTrue(harness.foreground.selectors.isEmpty)
    }

    // MARK: Agent watches

    func testAgentWatchHashesSavedTaskOutcomeAndNotifiesOnChange() async throws {
        let harness = try makeHarness()
        let watch = makeWatch(mode: .agent(savedTaskID: harness.savedTaskID))
        try harness.store.addWatch(watch)

        harness.agent.outcome = .finished(makeSnapshot(outcome: "Price 4"))
        let first = try await harness.coordinator.checkWatch(id: watch.id)
        XCTAssertEqual(first, .baseline)

        harness.agent.outcome = .finished(makeSnapshot(outcome: "Price 5"))
        let second = try await harness.coordinator.checkWatch(id: watch.id)
        XCTAssertEqual(second, .changed)
        XCTAssertEqual(harness.notifier.notified.map { $0.preview }, ["Price 5"])
        XCTAssertEqual(harness.agent.calls, 2)
    }

    func testPrivateAgentRunResultIsIgnored() async throws {
        let harness = try makeHarness()
        let watch = makeWatch(mode: .agent(savedTaskID: harness.savedTaskID))
        try harness.store.addWatch(watch)

        harness.agent.outcome = .finished(makeSnapshot(outcome: "Secret", isPrivate: true))
        let result = try await harness.coordinator.checkWatch(id: watch.id)
        guard case .skipped = result else {
            return XCTFail("Expected a private run to be ignored, got \(result)")
        }
        XCTAssertNil(try harness.store.watch(id: watch.id)?.lastValueHash)
        XCTAssertTrue(harness.notifier.notified.isEmpty)
    }

    // MARK: Editing

    func testEditingSelectorResetsBaselineSoItDoesNotNotify() async throws {
        let harness = try makeHarness()
        let watch = makeWatch()
        try harness.store.addWatch(watch)
        harness.foreground.text = "Price 4"
        _ = try await harness.coordinator.checkWatch(id: watch.id)

        try harness.coordinator.editWatch(
            id: watch.id,
            title: "Prices",
            interval: .daily,
            notify: true,
            mode: .text(selector: "#price")
        )
        harness.foreground.text = "Other 9"
        let result = try await harness.coordinator.checkWatch(id: watch.id)
        XCTAssertEqual(result, .baseline)
        XCTAssertTrue(harness.notifier.notified.isEmpty)
    }

    // MARK: Creation rules (used by the sheet and Watch Page)

    func testCreateTextWatchRefusesNonWebAddresses() throws {
        let harness = try makeHarness()
        XCTAssertThrowsError(try harness.coordinator.createTextWatch(
            url: URL(string: "file:///etc/hosts")!,
            title: nil,
            interval: .daily,
            notify: true
        )) { error in
            XCTAssertEqual(error as? PageWatchCheckError, .notWebPage)
        }
        XCTAssertThrowsError(try harness.coordinator.createTextWatch(
            url: URL(string: "javascript:alert(1)")!,
            title: nil,
            interval: .daily,
            notify: true
        ))
        XCTAssertTrue(harness.store.watches.isEmpty)
    }

    func testCreateTextWatchRefusesTwentyFirstWatch() throws {
        let harness = try makeHarness()
        for index in 0..<PageWatch.maximumWatches {
            try harness.store.addWatch(makeWatch(url: "https://example.com/\(index)"))
        }
        XCTAssertThrowsError(try harness.coordinator.createTextWatch(
            url: URL(string: "https://example.com/extra")!,
            title: "Extra",
            interval: .hourly,
            notify: false
        )) { error in
            XCTAssertEqual(error as? PageWatchStoreError, .watchLimitReached)
        }
        XCTAssertEqual(harness.store.watches.count, PageWatch.maximumWatches)
    }

    func testCreateTextWatchUsesHostWhenTitleIsBlank() throws {
        let harness = try makeHarness()
        let watch = try harness.coordinator.createTextWatch(
            url: URL(string: "https://news.example.org/feed")!,
            title: "   ",
            interval: .hourly,
            notify: false
        )
        XCTAssertEqual(watch.title, "news.example.org")
        XCTAssertEqual(watch.interval, .hourly)
        XCTAssertEqual(watch.mode, .text(selector: nil))
    }

    // MARK: Watch URL route

    func testWatchURLAcceptsOneValidUUID() throws {
        let id = UUID()
        let url = try XCTUnwrap(PageWatchURLParser.url(for: id))
        XCTAssertEqual(url.absoluteString, "webmebrowser://watch?id=\(id.uuidString)")
        XCTAssertEqual(try PageWatchURLParser.parse(url), id)
        XCTAssertEqual(try AgentIncomingURLRouter.route(url), .pageWatch(id))
    }

    func testWatchURLRejectsMalformedLinks() throws {
        let id = UUID().uuidString
        let malformed = [
            "webmebrowser://watch",
            "webmebrowser://watch?id=",
            "webmebrowser://watch?id=not-a-uuid",
            "webmebrowser://watch?ID=\(id)",
            "webmebrowser://watch?id=\(id)&id=\(id)",
            "webmebrowser://watch?id=\(id)&extra=1",
            "webmebrowser://watch/extra?id=\(id)",
            "webmebrowser://user@watch?id=\(id)",
            "webmebrowser://watch:8080?id=\(id)",
            "webmebrowser://watch?id=\(id)#fragment"
        ]
        for string in malformed {
            let url = try XCTUnwrap(URL(string: string), string)
            XCTAssertThrowsError(try PageWatchURLParser.parse(url), string)
            XCTAssertThrowsError(try AgentIncomingURLRouter.route(url), string)
        }
    }

    func testExistingRoutesKeepTheirPrecedence() throws {
        let runID = UUID()
        XCTAssertEqual(
            try AgentIncomingURLRouter.route(URL(string: "webmebrowser://run?id=\(runID.uuidString)")!),
            .run(runID)
        )
        XCTAssertEqual(
            try AgentIncomingURLRouter.route(URL(string: "webmebrowser://share?text=hello")!),
            .sharedText("hello")
        )
        XCTAssertEqual(
            try AgentIncomingURLRouter.route(URL(string: "https://example.com/")!),
            .defaultBrowserLink(URL(string: "https://example.com/")!)
        )
        guard case .agentTask(let task) = try AgentIncomingURLRouter.route(URL(string: "webmebrowser://agent?task=Find%20prices")!) else {
            return XCTFail("The agent task route changed.")
        }
        XCTAssertEqual(task.task, "Find prices")
    }

    func testNotificationRouteKeyDoesNotUseTheSharedURLKey() {
        XCTAssertNotEqual(PageWatchNotification.routeKey, "url")
    }
}
