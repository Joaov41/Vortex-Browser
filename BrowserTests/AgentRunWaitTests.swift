import XCTest
@testable import Browser

@MainActor
final class AgentRunWaitTests: XCTestCase {
    /// Returns at once, so a wait with no result times out without any real delay.
    private let immediateSleep: (Duration) async throws -> Void = { _ in }
    /// Holds the timer until the wait resumes and cancels it.
    private let parkedSleep: (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

    private final class TestClock {
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    private final class AccessRecorder {
        var sizeCalls = 0
        var readCalls = 0
    }

    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    private func makeBroker(sleep: @escaping (Duration) async throws -> Void) -> AgentRunCompletionBroker {
        AgentRunCompletionBroker(now: { Date(timeIntervalSinceReferenceDate: 800_000_000) }, sleep: sleep)
    }

    /// Yields until the waits have registered, without any real-time delay.
    private func waitUntilWaiting(_ broker: AgentRunCompletionBroker, count: Int = 1) async {
        var turns = 0
        while broker.activeWaiterCount < count, turns < 10_000 {
            await Task.yield()
            turns += 1
        }
        XCTAssertEqual(broker.activeWaiterCount, count, "The expected waits did not register.")
    }

    private func makeSnapshot(
        requestID: UUID? = UUID(),
        isPrivate: Bool = false,
        outcome: String = "Found three results.",
        status: AgentRunStatus = .completed,
        sources: [BrowserLookupSource] = [],
        exports: [AgentRunExport] = []
    ) -> BrowserAgentController.CompletionSnapshot {
        BrowserAgentController.CompletionSnapshot(
            runID: UUID(),
            task: "Find three results",
            outcome: outcome,
            actions: [],
            date: Date(timeIntervalSinceReferenceDate: 2_000),
            backend: "test",
            preset: "standard",
            startURL: nil,
            isPrivate: isPrivate,
            savedTaskID: nil,
            sources: sources,
            requestID: requestID,
            startedAt: Date(timeIntervalSinceReferenceDate: 1_900),
            status: status,
            exportedFiles: exports
        )
    }

    private func export(_ index: Int, kind: AgentRunExportKind = .csv) -> AgentRunExport {
        AgentRunExport(
            filename: "export-\(index).\(kind == .pdf ? "pdf" : "csv")",
            kind: kind,
            fileURL: URL(fileURLWithPath: "/fixtures/export-\(index).\(kind == .pdf ? "pdf" : "csv")")
        )
    }

    /// File access backed by a size table. Reads return a small payload, so no real file is needed.
    private func fakeAccess(
        sizes: [URL: Int],
        unreadable: Set<URL> = [],
        recorder: AccessRecorder = AccessRecorder()
    ) -> AgentRunFileAccess {
        AgentRunFileAccess(
            size: { url in
                recorder.sizeCalls += 1
                if unreadable.contains(url) { throw CocoaError(.fileReadNoSuchFile) }
                return sizes[url] ?? 0
            },
            read: { url in
                recorder.readCalls += 1
                return Data("fixture \(url.lastPathComponent)".utf8)
            }
        )
    }

    // MARK: - Broker

    func testCompletionBeforeWaitIsDeliveredToLaterWait() async {
        let broker = makeBroker(sleep: parkedSleep)
        let id = UUID()
        let snapshot = makeSnapshot(requestID: id, outcome: "Early answer.")

        broker.complete(snapshot)
        XCTAssertEqual(broker.retainedResultCount, 1)

        let outcome = await broker.wait(for: id, timeout: .seconds(180))
        XCTAssertEqual(outcome, .finished(snapshot))
        XCTAssertEqual(broker.retainedResultCount, 0)
        XCTAssertEqual(broker.activeWaiterCount, 0)
    }

    func testRetainedResultIsHandedOverOnlyOnce() async {
        let broker = makeBroker(sleep: immediateSleep)
        let id = UUID()
        let snapshot = makeSnapshot(requestID: id)

        broker.complete(snapshot)
        let first = await broker.wait(for: id, timeout: .seconds(180))
        let second = await broker.wait(for: id, timeout: .seconds(180))

        XCTAssertEqual(first, .finished(snapshot))
        XCTAssertEqual(second, .timedOut)
        XCTAssertEqual(broker.retainedResultCount, 0)
    }

    func testCompletionAfterWaitResumesWaiter() async {
        let broker = makeBroker(sleep: parkedSleep)
        let id = UUID()
        let snapshot = makeSnapshot(requestID: id)

        let waiting = Task { await broker.wait(for: id, timeout: .seconds(180)) }
        await waitUntilWaiting(broker)
        broker.complete(snapshot)

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .finished(snapshot))
        XCTAssertEqual(broker.activeWaiterCount, 0)
        XCTAssertEqual(broker.retainedResultCount, 0, "A result that resumed a waiter must not also be kept.")
    }

    func testTimeoutResumesWaiterAndLeavesNothingBehind() async {
        let broker = makeBroker(sleep: immediateSleep)

        let outcome = await broker.wait(for: UUID(), timeout: .seconds(180))

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(broker.activeWaiterCount, 0)
    }

    func testRejectionResumesWaiter() async {
        let broker = makeBroker(sleep: parkedSleep)
        let id = UUID()

        let waiting = Task { await broker.wait(for: id, timeout: .seconds(180)) }
        await waitUntilWaiting(broker)
        broker.reject(requestID: id, message: "The page changed.")

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .rejected("The page changed."))
        XCTAssertEqual(broker.activeWaiterCount, 0)
    }

    func testRejectionBeforeWaitIsDelivered() async {
        let broker = makeBroker(sleep: parkedSleep)
        let id = UUID()

        broker.reject(requestID: id, message: "Refused before start.")
        let outcome = await broker.wait(for: id, timeout: .seconds(180))

        XCTAssertEqual(outcome, .rejected("Refused before start."))
        XCTAssertEqual(broker.retainedResultCount, 0)
    }

    func testCancellingTheWaitResumesWithCancelled() async {
        let broker = makeBroker(sleep: parkedSleep)
        let id = UUID()

        let waiting = Task { await broker.wait(for: id, timeout: .seconds(180)) }
        await waitUntilWaiting(broker)
        waiting.cancel()

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(broker.activeWaiterCount, 0)
    }

    func testConcurrentWaitsForDifferentIDsEachReceiveTheirOwnResult() async {
        let broker = makeBroker(sleep: parkedSleep)
        let firstID = UUID()
        let secondID = UUID()
        let first = makeSnapshot(requestID: firstID, outcome: "First run.")
        let second = makeSnapshot(requestID: secondID, outcome: "Second run.")

        let firstWait = Task { await broker.wait(for: firstID, timeout: .seconds(180)) }
        let secondWait = Task { await broker.wait(for: secondID, timeout: .seconds(180)) }
        await waitUntilWaiting(broker, count: 2)

        broker.complete(second)
        XCTAssertEqual(broker.activeWaiterCount, 1)
        broker.complete(first)

        let firstOutcome = await firstWait.value
        let secondOutcome = await secondWait.value
        XCTAssertEqual(firstOutcome, .finished(first))
        XCTAssertEqual(secondOutcome, .finished(second))
        XCTAssertEqual(broker.activeWaiterCount, 0)
    }

    func testCompletionWithoutRequestIDIsIgnored() async {
        let broker = makeBroker(sleep: parkedSleep)
        let id = UUID()

        let waiting = Task { await broker.wait(for: id, timeout: .seconds(180)) }
        await waitUntilWaiting(broker)

        broker.complete(makeSnapshot(requestID: nil))
        XCTAssertEqual(broker.retainedResultCount, 0)
        XCTAssertEqual(broker.activeWaiterCount, 1, "A sidebar run must not resume a waiting intent.")

        broker.reject(requestID: id, message: "Done waiting.")
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .rejected("Done waiting."))
    }

    func testRetainedResultsAreCappedAtSixteenAndEvictOldestFirst() async {
        let broker = makeBroker(sleep: immediateSleep)
        let ids = (0..<(AgentRunCompletionBroker.maximumRetainedResults + 1)).map { _ in UUID() }

        for id in ids {
            broker.reject(requestID: id, message: "Refused.")
        }
        XCTAssertEqual(broker.retainedResultCount, AgentRunCompletionBroker.maximumRetainedResults)

        let evicted = await broker.wait(for: ids[0], timeout: .seconds(180))
        XCTAssertEqual(evicted, .timedOut)

        let kept = await broker.wait(for: ids[ids.count - 1], timeout: .seconds(180))
        XCTAssertEqual(kept, .rejected("Refused."))
    }

    func testRetainedResultIsKeptUntilTheRetentionWindowEnds() async {
        let clock = TestClock()
        let broker = AgentRunCompletionBroker(now: { clock.date }, sleep: immediateSleep)
        let id = UUID()
        let snapshot = makeSnapshot(requestID: id)

        broker.complete(snapshot)
        clock.date.addTimeInterval(AgentRunCompletionBroker.retentionSeconds - 1)
        XCTAssertEqual(broker.retainedResultCount, 1)

        clock.date.addTimeInterval(1)
        XCTAssertEqual(broker.retainedResultCount, 0)
        let outcome = await broker.wait(for: id, timeout: .seconds(180))
        XCTAssertEqual(outcome, .timedOut)
    }

    // MARK: - Result mapper

    func testPrivateRunIsRedactedAndNeverTouchesFiles() {
        let recorder = AccessRecorder()
        let source = BrowserLookupSource(id: 1, title: "Public", url: URL(string: "https://example.com/a")!, isPrivate: false)
        let snapshot = makeSnapshot(
            isPrivate: true,
            outcome: "The account balance is 4,210.",
            sources: [source],
            exports: [export(1)]
        )

        let fields = AgentRunResultMapper.fields(
            for: .finished(snapshot),
            taskTitle: "Check balance",
            now: now,
            files: fakeAccess(sizes: [export(1).fileURL!: 10], recorder: recorder)
        )

        XCTAssertEqual(fields.outcome, AgentRunResultMapper.privateRunOutcome)
        XCTAssertFalse(fields.outcome.contains("4,210"))
        XCTAssertEqual(fields.status, "completed")
        XCTAssertTrue(fields.sources.isEmpty)
        XCTAssertTrue(fields.files.isEmpty)
        XCTAssertEqual(recorder.sizeCalls, 0)
        XCTAssertEqual(recorder.readCalls, 0)
    }

    func testTimedOutWaitReportsStillRunning() {
        let fields = AgentRunResultMapper.fields(
            for: .timedOut,
            taskTitle: "Watch prices",
            now: now,
            files: fakeAccess(sizes: [:])
        )

        XCTAssertEqual(fields.outcome, "The task is still running in Vortyra.")
        XCTAssertEqual(fields.status, "stillRunning")
        XCTAssertEqual(fields.finishedAt, now)
        XCTAssertTrue(fields.files.isEmpty)
    }

    func testRejectionCarriesTheUserFacingMessage() {
        let fields = AgentRunResultMapper.fields(
            for: .rejected("The browser page changed before the task could start."),
            taskTitle: "Watch prices",
            now: now,
            files: fakeAccess(sizes: [:])
        )

        XCTAssertEqual(fields.status, "rejected")
        XCTAssertEqual(fields.outcome, "The browser page changed before the task could start.")
        XCTAssertEqual(fields.finishedAt, now)
    }

    func testStoppedRunKeepsItsStatusAndWhateverOutcomeExists() {
        let snapshot = makeSnapshot(outcome: "Stopped after two pages.", status: .stopped)

        let fields = AgentRunResultMapper.fields(
            for: .finished(snapshot),
            taskTitle: "Survey",
            now: now,
            files: fakeAccess(sizes: [:])
        )

        XCTAssertEqual(fields.status, "stopped")
        XCTAssertEqual(fields.outcome, "Stopped after two pages.")
        XCTAssertEqual(fields.finishedAt, snapshot.date)
    }

    func testCancelledWaitReportsCancelledStatus() {
        let fields = AgentRunResultMapper.fields(
            for: .cancelled,
            taskTitle: "Survey",
            now: now,
            files: fakeAccess(sizes: [:])
        )

        XCTAssertEqual(fields.status, "cancelled")
        XCTAssertEqual(fields.outcome, AgentRunResultMapper.cancelledOutcome)
    }

    func testSourcesKeepOnlyPublicWebAddresses() {
        let sources = [
            BrowserLookupSource(id: 1, title: "Public", url: URL(string: "https://example.com/a")!, isPrivate: false),
            BrowserLookupSource(id: 2, title: "Private tab", url: URL(string: "https://example.com/b")!, isPrivate: true),
            BrowserLookupSource(id: 3, title: "Local file", url: URL(string: "file:///fixtures/c.html")!, isPrivate: false)
        ]

        let fields = AgentRunResultMapper.fields(
            for: .finished(makeSnapshot(sources: sources)),
            taskTitle: "Survey",
            now: now,
            files: fakeAccess(sizes: [:])
        )

        XCTAssertEqual(fields.sources, [URL(string: "https://example.com/a")!])
    }

    func testAtMostFiveFilesAreAttachedAndTheRestAreNoted() {
        let exports = (1...6).map { export($0) }
        let sizes = Dictionary(uniqueKeysWithValues: exports.map { ($0.fileURL!, 1_000) })

        let fields = AgentRunResultMapper.fields(
            for: .finished(makeSnapshot(exports: exports)),
            taskTitle: "Export",
            now: now,
            files: fakeAccess(sizes: sizes)
        )

        XCTAssertEqual(fields.files.map(\.filename), (1...5).map { "export-\($0).csv" })
        XCTAssertEqual(fields.fileNotes, ["1 more file(s) were not attached because the limit is 5."])
    }

    func testFileOverTwentyFiveMegabytesIsSkippedAndDoesNotUseASlot() {
        let oversized = export(1, kind: .pdf)
        let exports = [oversized] + (2...6).map { export($0) }
        var sizes = Dictionary(uniqueKeysWithValues: exports.map { ($0.fileURL!, 1_000) })
        sizes[oversized.fileURL!] = 25_000_001

        let fields = AgentRunResultMapper.fields(
            for: .finished(makeSnapshot(exports: exports)),
            taskTitle: "Export",
            now: now,
            files: fakeAccess(sizes: sizes)
        )

        XCTAssertEqual(fields.files.map(\.filename), (2...6).map { "export-\($0).csv" })
        XCTAssertEqual(fields.fileNotes, ["export-1.pdf is larger than 25 MB and was not attached."])
    }

    func testFileExactlyAtTheLimitIsAttached() {
        let exact = export(1, kind: .pdf)
        let fields = AgentRunResultMapper.fields(
            for: .finished(makeSnapshot(exports: [exact])),
            taskTitle: "Export",
            now: now,
            files: fakeAccess(sizes: [exact.fileURL!: 25_000_000])
        )

        XCTAssertEqual(fields.files.map(\.filename), ["export-1.pdf"])
        XCTAssertEqual(fields.files.first?.kind, .pdf)
        XCTAssertTrue(fields.fileNotes.isEmpty)
    }

    func testUnreadableOrUnlocatedFilesAreSkippedAndNoted() {
        let missing = export(1)
        let present = export(2)
        let unlocated = AgentRunExport(filename: "unlocated.csv", kind: .csv, fileURL: nil)

        let fields = AgentRunResultMapper.fields(
            for: .finished(makeSnapshot(exports: [missing, unlocated, present])),
            taskTitle: "Export",
            now: now,
            files: fakeAccess(sizes: [present.fileURL!: 100], unreadable: [missing.fileURL!])
        )

        XCTAssertEqual(fields.files.map(\.filename), ["export-2.csv"])
        XCTAssertEqual(fields.fileNotes, [
            "export-1.csv could not be read and was not attached.",
            "unlocated.csv could not be read and was not attached."
        ])
    }

    func testStoredRunRecordHasNoFilesAndUnknownStatusWhenMissing() {
        let record = AgentRunRecord(
            task: "Compare laptops",
            outcome: "Two laptops are cheaper.",
            actions: [],
            date: now,
            backend: "test",
            preset: "standard",
            status: .stepLimit,
            exports: [AgentRunExportRecord(filename: "laptops.csv", kind: .csv)],
            sources: [AgentRunSourceRecord(title: "Shop", url: URL(string: "https://example.com/shop")!)]
        )

        let fields = AgentRunResultMapper.fields(for: record, taskTitle: "Compare laptops")

        XCTAssertEqual(fields.status, "stepLimit")
        XCTAssertEqual(fields.outcome, "Two laptops are cheaper.")
        XCTAssertEqual(fields.sources, [URL(string: "https://example.com/shop")!])
        XCTAssertTrue(fields.files.isEmpty)

        let legacy = AgentRunRecord(task: "Old run", outcome: "Done", actions: [], date: now, backend: "test", preset: "standard")
        XCTAssertEqual(AgentRunResultMapper.fields(for: legacy, taskTitle: "Old run").status, "unknown")
    }

    func testEntityCarriesPrivateRedactionThroughMakeResult() {
        let result = AgentRunResultIntentSupport.makeResult(
            for: .finished(makeSnapshot(isPrivate: true, outcome: "Secret text.")),
            taskTitle: "Private task",
            now: now,
            files: fakeAccess(sizes: [:])
        )

        XCTAssertEqual(result.entity.outcome, AgentRunResultMapper.privateRunOutcome)
        XCTAssertEqual(result.entity.status, "completed")
        XCTAssertTrue(result.entity.files.isEmpty)
        XCTAssertEqual(result.dialog, AgentRunResultMapper.privateRunOutcome)
    }

    // MARK: - Intent helpers

    func testDialogKeepsOnlyTheFirstThreeHundredCharacters() {
        let long = String(repeating: "a", count: 350)
        XCTAssertEqual(AgentRunResultIntentSupport.dialogText(outcome: long, fileNotes: []).count, 300)
        XCTAssertEqual(
            AgentRunResultIntentSupport.dialogText(outcome: "Done", fileNotes: ["big.pdf is larger than 25 MB and was not attached."]),
            "Done big.pdf is larger than 25 MB and was not attached."
        )
    }

    func testTimeoutIsClampedToFifteenThroughNineHundredSeconds() {
        XCTAssertEqual(AgentRunResultIntentSupport.clampedTimeoutSeconds(5), 15)
        XCTAssertEqual(AgentRunResultIntentSupport.clampedTimeoutSeconds(180), 180)
        XCTAssertEqual(AgentRunResultIntentSupport.clampedTimeoutSeconds(5_000), 900)
    }

    func testTaskTitleUsesTheFirstLineAndHasFallback() {
        XCTAssertEqual(AgentRunResultIntentSupport.title(forTask: "  Find prices \nsecond line"), "Find prices")
        XCTAssertEqual(AgentRunResultIntentSupport.title(forTask: "   \n  "), "Browser task")
    }
}
