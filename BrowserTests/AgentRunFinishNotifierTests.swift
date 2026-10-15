import XCTest
@testable import Browser

@MainActor
final class AgentRunFinishNotifierTests: XCTestCase {
    @MainActor
    private final class FakePoster: AgentRunNotificationPosting {
        var prepareCount = 0
        var posted: [AgentRunFinishNotification.Content] = []

        func prepare() async { prepareCount += 1 }
        func post(_ content: AgentRunFinishNotification.Content) async { posted.append(content) }
    }

    @MainActor
    private final class Switch {
        var isOn = false
    }

    private func snapshot(
        requestID: UUID?,
        task: String = "Find three results\nRecorded step 1",
        outcome: String = "\n  Found three results.  \nSecond line",
        isPrivate: Bool = false,
        status: AgentRunStatus = .completed
    ) -> BrowserAgentController.CompletionSnapshot {
        BrowserAgentController.CompletionSnapshot(
            runID: UUID(),
            task: task,
            outcome: outcome,
            actions: [],
            date: Date(timeIntervalSinceReferenceDate: 2_000),
            backend: "test",
            preset: "standard",
            startURL: nil,
            isPrivate: isPrivate,
            savedTaskID: nil,
            requestID: requestID,
            startedAt: Date(timeIntervalSinceReferenceDate: 1_900),
            status: status
        )
    }

    // MARK: Requests

    func testShortcutFlagSurvivesTheSharedQueueAndOldQueuesStillDecode() throws {
        let suiteName = "AgentRunFinishNotifierTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = PendingAgentTaskQueue(defaults: defaults, storageKey: "queue")
        let fromShortcut = PendingAgentTask(task: "Read the page", notifiesWhenFinished: true)
        let fromLink = PendingAgentTask(task: "Read the title")
        try queue.enqueue(fromShortcut)
        try queue.enqueue(fromLink)
        let first = try XCTUnwrap(queue.consumeNextIfReady(isForeground: true, hasBrowserView: true, aiBusy: false, agentBusy: false, startupBusy: false))
        let second = try XCTUnwrap(queue.consumeNextIfReady(isForeground: true, hasBrowserView: true, aiBusy: false, agentBusy: false, startupBusy: false))
        XCTAssertEqual(first.id, fromShortcut.id)
        XCTAssertEqual(first.notifiesWhenFinished, true)
        XCTAssertNil(second.notifiesWhenFinished)

        let encoded = try JSONEncoder().encode(fromLink)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("notifiesWhenFinished"), "Other sources store nothing new.")

        let id = UUID()
        let older = Data(#"{"id":"\#(id.uuidString)","task":"Read","enqueuedAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(PendingAgentTask.self, from: older)
        XCTAssertEqual(decoded.id, id)
        XCTAssertNil(decoded.notifiesWhenFinished, "Queues written before this change still decode.")
    }

    func testSavedTaskRequestsNotifyOnlyWhenAsked() {
        let saved = SavedAgentTask(title: "Morning news", task: "Read the headlines")
        XCTAssertNil(AgentTaskIntentRuntime.pendingRequest(for: saved).notifiesWhenFinished)
        let request = AgentTaskIntentRuntime.pendingRequest(for: saved, notifiesWhenFinished: true)
        XCTAssertEqual(request.notifiesWhenFinished, true)
        XCTAssertEqual(request.savedTaskID, saved.id)
        XCTAssertNil(AgentControlURLParser.pendingRequest(for: saved).notifiesWhenFinished, "Control Center runs do not notify.")
    }

    // MARK: Notifier

    func testFirstShortcutRunAsksForPermissionAndItsFinishPostsTitleAndFirstLine() async throws {
        let poster = FakePoster()
        let notifier = AgentRunFinishNotifier(poster: poster, isEnabled: { true })
        let requestID = UUID()

        XCTAssertEqual(poster.prepareCount, 0, "Nothing is asked before a Shortcuts run starts.")
        await notifier.runStarted(requestID: requestID)?.value
        XCTAssertEqual(poster.prepareCount, 1)
        XCTAssertNil(notifier.runStarted(requestID: UUID()), "Permission is asked once per launch.")
        XCTAssertEqual(poster.prepareCount, 1)

        let finished = snapshot(requestID: requestID)
        await notifier.runFinished(finished)?.value
        let content = try XCTUnwrap(poster.posted.first)
        XCTAssertEqual(poster.posted.count, 1)
        XCTAssertEqual(content.title, "Find three results")
        XCTAssertEqual(content.body, "Found three results.")
        XCTAssertEqual(content.identifier, "agentrun." + finished.runID.uuidString)
        XCTAssertEqual(content.link, AgentRunURLParser.url(for: finished.runID))

        XCTAssertNil(notifier.runFinished(snapshot(requestID: requestID)), "A request notifies once.")
        XCTAssertEqual(poster.posted.count, 1)
    }

    func testPrivateRunNotificationSaysOnlyFinished() async throws {
        let poster = FakePoster()
        let notifier = AgentRunFinishNotifier(poster: poster, isEnabled: { true })
        let requestID = UUID()
        notifier.runStarted(requestID: requestID)
        await notifier.runFinished(snapshot(
            requestID: requestID,
            task: "Check my private account",
            outcome: "Your balance is 1,234",
            isPrivate: true
        ))?.value
        let content = try XCTUnwrap(poster.posted.first)
        XCTAssertEqual(content.title, "Finished")
        XCTAssertEqual(content.body, "")
        XCTAssertNil(content.link, "Private runs keep no history to open.")
    }

    func testSidebarAndUnknownRunsDoNotNotify() {
        let poster = FakePoster()
        let notifier = AgentRunFinishNotifier(poster: poster, isEnabled: { true })
        notifier.runStarted(requestID: UUID())
        XCTAssertNil(notifier.runFinished(snapshot(requestID: nil)), "Runs typed in the sidebar have no request ID.")
        XCTAssertNil(notifier.runFinished(snapshot(requestID: UUID())), "Runs queued from links or controls were never started as Shortcuts runs.")
        XCTAssertTrue(poster.posted.isEmpty)
    }

    func testSwitchedOffAsksNothingAndPostsNothing() async throws {
        let poster = FakePoster()
        let setting = Switch()
        let notifier = AgentRunFinishNotifier(poster: poster, isEnabled: { setting.isOn })
        let requestID = UUID()
        XCTAssertNil(notifier.runStarted(requestID: requestID))
        XCTAssertNil(notifier.runFinished(snapshot(requestID: requestID)))
        XCTAssertEqual(poster.prepareCount, 0)
        XCTAssertTrue(poster.posted.isEmpty)

        setting.isOn = true
        let laterID = UUID()
        await notifier.runStarted(requestID: laterID)?.value
        setting.isOn = false
        XCTAssertNil(notifier.runFinished(snapshot(requestID: laterID)), "Turning the switch off before the finish posts nothing.")
        XCTAssertTrue(poster.posted.isEmpty)

        let suiteName = "AgentRunFinishNotifierTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(AgentRunFinishNotification.isEnabled(defaults: defaults), "The switch is on by default.")
        defaults.set(false, forKey: AgentRunFinishNotification.enabledKey)
        XCTAssertFalse(AgentRunFinishNotification.isEnabled(defaults: defaults))
    }

    func testContentBoundsTheBodyAndHandlesEmptyResults() {
        let long = AgentRunFinishNotification.content(for: snapshot(requestID: UUID(), outcome: String(repeating: "a", count: 500)))
        XCTAssertEqual(long.body.count, AgentRunFinishNotification.maximumBodyCharacters)
        let empty = AgentRunFinishNotification.content(for: snapshot(requestID: UUID(), task: "  ", outcome: "  \n "))
        XCTAssertEqual(empty.title, "Browser task")
        XCTAssertEqual(empty.body, "Finished.")
        let failed = AgentRunFinishNotification.content(for: snapshot(
            requestID: UUID(),
            outcome: "Couldn't finish: Stopped because the agent kept repeating the same click action without making progress.",
            status: .failed
        ))
        XCTAssertTrue(failed.body.hasPrefix("Couldn't finish:"), failed.body)
    }

    func testWatchedRunsAreBounded() async {
        let poster = FakePoster()
        let notifier = AgentRunFinishNotifier(poster: poster, isEnabled: { true })
        let first = UUID()
        notifier.runStarted(requestID: first)
        for _ in 0..<AgentRunFinishNotifier.maximumWatchedRuns {
            notifier.runStarted(requestID: UUID())
        }
        XCTAssertNil(notifier.runFinished(snapshot(requestID: first)), "The oldest watched run is dropped past the limit.")
    }
}
