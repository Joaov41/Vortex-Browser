import XCTest
import WebKit
@testable import Browser

/// Result handoffs: draft building, attachment selection, the prepare_* tools and the sidebar queue.
/// Nothing here touches Calendar, Reminders, Mail, Messages or the network.
@MainActor
final class ResultHandoffTests: XCTestCase {
    @MainActor
    private final class HandoffScriptedEngine: BrowserAgentEngine {
        typealias Body = @MainActor (
            BrowserAgentEngineRequest,
            @escaping BrowserAgentToolExecutor,
            @escaping BrowserAgentNoteHandler
        ) async throws -> String
        let profile: BrowserAgentEngineProfile
        private let body: Body

        init(body: @escaping Body) {
            self.profile = .chatGPTPlan(supportsVision: false)
            self.body = body
        }

        func prepare() async throws {}

        func run(
            request: BrowserAgentEngineRequest,
            execute: @escaping BrowserAgentToolExecutor,
            onNote: @escaping BrowserAgentNoteHandler
        ) async throws -> String {
            try await body(request, execute, onNote)
        }
    }

    private final class HandoffLoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private let fixtureDirectory = URL(fileURLWithPath: "/fixtures/handoff")

    // MARK: Fixtures

    private func makeSnapshot(
        task: String = "Find the clinic opening hours",
        outcome: String = "The clinic is open on 2026-11-02 at 09:00.",
        isPrivate: Bool = false,
        sources: [BrowserLookupSource] = [],
        exports: [AgentRunExport] = []
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
            sources: sources,
            requestID: nil,
            startedAt: Date(timeIntervalSinceReferenceDate: 1_900),
            status: .completed,
            exportedFiles: exports
        )
    }

    private func source(_ index: Int) -> BrowserLookupSource {
        BrowserLookupSource(
            id: index,
            title: "Source \(index)",
            url: URL(string: "https://example.com/\(index == 1 ? "a" : "b")")!,
            isPrivate: false
        )
    }

    private func export(_ name: String, url: URL? = nil) -> AgentRunExport {
        AgentRunExport(
            filename: name,
            kind: AgentRunExportKind(filename: name),
            fileURL: url ?? fixtureDirectory.appendingPathComponent(name)
        )
    }

    private func iso(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    private func arguments(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    private func toolNames(_ definitions: [[String: Any]]) -> Set<String> {
        Set(definitions.compactMap { $0["name"] as? String })
    }

    private func loadedWebView(_ html: String) async -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let waiter = HandoffLoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://handoff.fixture/")!)
        }
        webView.navigationDelegate = nil
        return webView
    }

    // MARK: Date detection

    func testDetectsTheFirstDateInTheOutcome() throws {
        let range = try XCTUnwrap(AgentResultHandoffDraft.detectDateRange(in: "Your visit is on November 2, 2026 at 3:00 PM."))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: range.start)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 11)
        XCTAssertEqual(parts.day, 2)
        XCTAssertEqual(parts.hour, 15)
        XCTAssertEqual(range.duration, AgentResultHandoffDraft.defaultEventDuration, "A date without a duration gets one hour.")
    }

    func testOutcomeWithoutADateHasNoDateRange() {
        XCTAssertNil(AgentResultHandoffDraft.detectDateRange(in: "Three products matched the search."))
        XCTAssertNil(AgentResultHandoffDraft.detectDateRange(in: ""))
    }

    func testADetectedDurationIsKept() throws {
        let range = try XCTUnwrap(AgentResultHandoffDraft.detectDateRange(in: "The workshop runs from 10:00 to 11:30 on November 2, 2026."))
        XCTAssertEqual(range.duration, 5_400, "A stated range of 90 minutes must keep its duration.")
    }

    // MARK: Title and body

    func testTitleIsTheFirstLineOfTheTaskTrimmed() {
        let draft = AgentResultHandoffDraft(snapshot: makeSnapshot(task: "  Find the cheapest flight\nto Lisbon in May  "))
        XCTAssertEqual(draft.title, "Find the cheapest flight")
    }

    func testTitleIsBoundedToEightyCharacters() {
        let task = "Find the cheapest flight to Lisbon in May and compare three airlines with prices in euros today"
        let title = AgentResultHandoffDraft.title(forTask: task)
        XCTAssertEqual(title.count, AgentResultHandoffDraft.titleLimit)
        XCTAssertEqual(title, String(task.prefix(80)))
    }

    func testEmptyTaskGetsAFallbackTitle() {
        XCTAssertEqual(AgentResultHandoffDraft.title(forTask: "   \n  "), "Browser task result")
    }

    func testBodyIsOutcomeFollowedByTheSourceList() {
        let body = AgentResultHandoffDraft.body(
            outcome: "  The clinic opens at 9.  ",
            sourceURLs: [URL(string: "https://example.com/a")!, URL(string: "https://example.com/b")!]
        )
        XCTAssertEqual(body, "The clinic opens at 9.\n\nSources:\n- https://example.com/a\n- https://example.com/b")
    }

    func testBodyWithoutSourcesIsTheOutcomeOnly() {
        XCTAssertEqual(AgentResultHandoffDraft.body(outcome: "Done.", sourceURLs: []), "Done.")
        XCTAssertEqual(AgentResultHandoffDraft.body(outcome: " ", sourceURLs: []), "No answer was recorded.")
    }

    func testBodyKeepsTheSourcesWhenTheOutcomeIsLong() {
        let body = AgentResultHandoffDraft.body(
            outcome: String(repeating: "x", count: 10_000),
            sourceURLs: [URL(string: "https://example.com/a")!, URL(string: "https://example.com/b")!]
        )
        XCTAssertLessThanOrEqual(body.count, AgentResultHandoffDraft.bodyLimit)
        XCTAssertTrue(body.contains("- https://example.com/a"))
        XCTAssertTrue(body.hasSuffix("- https://example.com/b"))
    }

    func testBodyListsAtMostTenSources() {
        let urls = (1...12).map { URL(string: "https://example.com/\($0)")! }
        let body = AgentResultHandoffDraft.body(outcome: "Done.", sourceURLs: urls)
        XCTAssertTrue(body.contains("- https://example.com/10"))
        XCTAssertFalse(body.contains("- https://example.com/11"))
    }

    // MARK: Private runs

    func testPrivateRunDraftHasOutcomeOnlyWithNoSourcesOrAttachments() {
        let snapshot = makeSnapshot(
            isPrivate: true,
            sources: [source(1)],
            exports: [export("report.csv")]
        )
        let draft = AgentResultHandoffDraft(snapshot: snapshot, fileSize: { _ in 100 })
        XCTAssertEqual(draft.body, "The clinic is open on 2026-11-02 at 09:00.")
        XCTAssertFalse(draft.body.contains("Sources:"))
        XCTAssertTrue(draft.attachments.isEmpty)
        XCTAssertNotNil(draft.dateRange, "The date comes from the outcome, which is allowed for private runs.")
    }

    func testPublicRunDraftIncludesSourcesAndReadableExports() {
        let csv = export("report.csv")
        let snapshot = makeSnapshot(sources: [source(1), source(2)], exports: [csv])
        let draft = AgentResultHandoffDraft(snapshot: snapshot, fileSize: { _ in 2_048 })
        XCTAssertTrue(draft.body.contains("Sources:\n- https://example.com/a\n- https://example.com/b"))
        XCTAssertEqual(draft.attachments, [csv.fileURL!])
    }

    func testRecordDraftHasSourcesButNoAttachments() {
        let record = AgentRunRecord(
            task: "Find the clinic opening hours",
            outcome: "Open at 9.",
            actions: [],
            backend: "test",
            preset: "standard",
            exports: [AgentRunExportRecord(filename: "report.csv", kind: .csv)],
            sources: [AgentRunSourceRecord(title: "Clinic", url: URL(string: "https://example.com/clinic")!)]
        )
        let draft = AgentResultHandoffDraft(record: record)
        XCTAssertTrue(draft.body.contains("- https://example.com/clinic"))
        XCTAssertTrue(draft.attachments.isEmpty, "Records keep export names only, never file locations.")
    }

    func testPrivateRecordDraftHasNoSources() {
        let record = AgentRunRecord(
            task: "Private task",
            outcome: "Only the outcome.",
            actions: [],
            backend: "test",
            preset: "standard",
            isPrivate: true,
            sources: [AgentRunSourceRecord(title: "Clinic", url: URL(string: "https://example.com/clinic")!)]
        )
        XCTAssertEqual(AgentResultHandoffDraft(record: record).body, "Only the outcome.")
    }

    // MARK: Attachments

    func testAttachmentsKeepOnlyReadableFilesWithinTheSizeLimit() {
        let sizes: [String: Int64] = [
            "small.csv": 1_000,
            "big.pdf": AgentResultHandoffDraft.attachmentByteLimit + 1,
            "exact.pdf": AgentResultHandoffDraft.attachmentByteLimit
        ]
        let exports = [
            export("small.csv"),
            export("big.pdf"),
            export("missing.csv"),
            export("exact.pdf"),
            AgentRunExport(filename: "no-location.csv", kind: .csv, fileURL: nil),
            AgentRunExport(filename: "remote.csv", kind: .csv, fileURL: URL(string: "https://example.com/remote.csv")!)
        ]
        let urls = AgentResultHandoffDraft.attachmentURLs(from: exports) { url in
            sizes[url.lastPathComponent]
        }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["small.csv", "exact.pdf"])
    }

    func testAttachmentsAreCappedAtFive() {
        let exports = (1...8).map { export("file-\($0).csv") }
        let urls = AgentResultHandoffDraft.attachmentURLs(from: exports) { _ in 10 }
        XCTAssertEqual(urls.count, AgentResultHandoffDraft.attachmentLimit)
        XCTAssertEqual(urls.last?.lastPathComponent, "file-5.csv")
    }

    // MARK: Requests for the user

    func testRequestsPrefillCalendarMailMessageAndShare() {
        let draft = AgentResultHandoffDraft(
            title: "Clinic hours",
            body: "Open at 9.",
            dateRange: DateInterval(start: iso("2026-11-02T09:00:00+01:00"), duration: 3_600),
            attachments: [fixtureDirectory.appendingPathComponent("report.csv")]
        )
        XCTAssertEqual(
            draft.request(for: .calendar),
            .calendar(title: "Clinic hours", notes: "Open at 9.", start: iso("2026-11-02T09:00:00+01:00"), end: iso("2026-11-02T10:00:00+01:00"))
        )
        XCTAssertEqual(draft.request(for: .reminder), .reminder(title: "Clinic hours", due: iso("2026-11-02T09:00:00+01:00")))
        XCTAssertEqual(draft.request(for: .message), .message(body: "Open at 9."))
        XCTAssertEqual(draft.request(for: .email), .email(subject: "Clinic hours", body: "Open at 9.", attachments: draft.attachments))
        XCTAssertEqual(draft.request(for: .share), .share(text: "Clinic hours\n\nOpen at 9.", files: draft.attachments))
    }

    func testRequestsWithoutADateLeaveDatesEmpty() {
        let draft = AgentResultHandoffDraft(title: "Hours", body: "Open.", dateRange: nil, attachments: [])
        XCTAssertEqual(draft.request(for: .calendar), .calendar(title: "Hours", notes: "Open.", start: nil, end: nil))
        XCTAssertEqual(draft.request(for: .reminder), .reminder(title: "Hours", due: nil))
    }

    // MARK: prepare_* argument validation

    func testCalendarArgumentsDefaultTheEndAndKeepTheNotes() throws {
        let kind = try BrowserAgentController.handoffRequestKind(
            tool: "prepare_calendar_event",
            arguments: arguments(#"{"title":"Dentist","start":"2026-11-02T14:00:00+01:00","notes":"Bring the form"}"#),
            exports: [],
            isPrivate: false
        )
        XCTAssertEqual(
            kind,
            .calendar(
                title: "Dentist",
                notes: "Bring the form",
                start: iso("2026-11-02T14:00:00+01:00"),
                end: iso("2026-11-02T15:00:00+01:00")
            )
        )
    }

    func testCalendarArgumentsWithNullOptionalsHaveNoDates() throws {
        let kind = try BrowserAgentController.handoffRequestKind(
            tool: "prepare_calendar_event",
            arguments: ["title": "Dentist", "start": NSNull(), "end": NSNull(), "notes": NSNull()],
            exports: [],
            isPrivate: false
        )
        XCTAssertEqual(kind, .calendar(title: "Dentist", notes: "", start: nil, end: nil))
    }

    func testCalendarRejectsInvalidDates() {
        XCTAssertThrowsError(try handoff("prepare_calendar_event", #"{"title":"A","start":"next Tuesday"}"#))
        XCTAssertThrowsError(try handoff("prepare_calendar_event", #"{"title":"A","start":"2026-11-02T14:00:00+01:00","end":"2026-11-02T13:00:00+01:00"}"#))
        XCTAssertThrowsError(try handoff("prepare_calendar_event", #"{"title":"A","end":"2026-11-02T13:00:00+01:00"}"#), "An end without a start is invalid.")
    }

    func testTitlesAreRequiredSingleLineAndAtMost200Characters() {
        XCTAssertThrowsError(try handoff("prepare_reminder", #"{"title":"   "}"#))
        XCTAssertThrowsError(try handoff("prepare_reminder", #"{"title":"Line one\nLine two"}"#))
        let longTitle = String(repeating: "t", count: 201)
        XCTAssertThrowsError(try handoff("prepare_reminder", #"{"title":"\#(longTitle)"}"#))
        let exactTitle = String(repeating: "t", count: 200)
        XCTAssertNoThrow(try handoff("prepare_reminder", #"{"title":"\#(exactTitle)"}"#))
    }

    func testNotesAndBodiesAreBoundedNotRejected() throws {
        let long = String(repeating: "n", count: 5_000)
        let request = try handoff("prepare_calendar_event", #"{"title":"A","notes":"\#(long)"}"#)
        guard case let .calendar(_, notes, _, _) = request else { return XCTFail("Expected a calendar request.") }
        XCTAssertEqual(notes.count, AgentResultHandoffDraft.bodyLimit)
    }

    func testReminderDueDateIsOptionalAndValidated() throws {
        XCTAssertEqual(
            try handoff("prepare_reminder", #"{"title":"Renew passport","due":"2026-11-02T09:00:00+01:00"}"#),
            .reminder(title: "Renew passport", due: iso("2026-11-02T09:00:00+01:00"))
        )
        XCTAssertEqual(try handoff("prepare_reminder", #"{"title":"Renew passport"}"#), .reminder(title: "Renew passport", due: nil))
        XCTAssertThrowsError(try handoff("prepare_reminder", #"{"title":"Renew passport","due":"soon"}"#))
    }

    func testEmailRequiresSubjectBodyAndAttachExports() throws {
        XCTAssertThrowsError(try handoff("prepare_email", #"{"subject":"Hours","body":"","attachExports":false}"#))
        XCTAssertThrowsError(try handoff("prepare_email", #"{"subject":"Hours","body":"Open."}"#), "attachExports is required.")
        XCTAssertThrowsError(try handoff("prepare_email", #"{"subject":"","body":"Open.","attachExports":false}"#))
    }

    func testEmailAttachesOnlyTheRunsReadableExportsWhenAsked() throws {
        let exports = [export("report.csv")]
        let attached = try BrowserAgentController.handoffRequestKind(
            tool: "prepare_email",
            arguments: ["subject": "Hours", "body": "Open.", "attachExports": true],
            exports: exports,
            isPrivate: false,
            fileSize: { _ in 10 }
        )
        XCTAssertEqual(attached, .email(subject: "Hours", body: "Open.", attachments: [exports[0].fileURL!]))

        let notAsked = try BrowserAgentController.handoffRequestKind(
            tool: "prepare_email",
            arguments: ["subject": "Hours", "body": "Open.", "attachExports": false],
            exports: exports,
            isPrivate: false,
            fileSize: { _ in 10 }
        )
        XCTAssertEqual(notAsked, .email(subject: "Hours", body: "Open.", attachments: []))
    }

    func testPrivateRunsNeverAttachExports() throws {
        let kind = try BrowserAgentController.handoffRequestKind(
            tool: "prepare_email",
            arguments: ["subject": "Hours", "body": "Open.", "attachExports": true],
            exports: [export("report.csv")],
            isPrivate: true,
            fileSize: { _ in 10 }
        )
        XCTAssertEqual(kind, .email(subject: "Hours", body: "Open.", attachments: []))
    }

    func testUnknownHandoffToolIsRejected() {
        XCTAssertThrowsError(try handoff("prepare_message", #"{"body":"Hi"}"#))
    }

    private func handoff(_ tool: String, _ json: String) throws -> AgentHandoffRequest.Kind {
        try BrowserAgentController.handoffRequestKind(tool: tool, arguments: arguments(json), exports: [], isPrivate: false)
    }

    // MARK: Catalog and offering

    func testHandoffToolsAreOfferedOnlyWithHandoffCues() throws {
        let handoff: Set<String> = BrowserAgentController.handoffToolNames
        XCTAssertTrue(toolNames(BrowserAgentController.tools).isSuperset(of: handoff))
        XCTAssertTrue(handoff.isDisjoint(with: BrowserAgentController.coreToolNames), "Handoff tools are not core tools.")

        let cues = [
            "Add a calendar event for the clinic visit", "Schedule a meeting with Ana", "Book an appointment",
            "Remind me to renew it", "Set a reminder for Friday", "Email the summary to me", "Send an e-mail with the table",
            "Mail the report", "Message the results to Sam", "Text me the link", "Send to Ana the hours"
        ]
        for task in cues {
            let names = try toolNames(BrowserAgentController.toolsForRun(task: task, browserAdapterAvailable: true))
            XCTAssertTrue(handoff.isSubset(of: names), "\(task) should offer every handoff tool.")
        }

        let plain = try toolNames(BrowserAgentController.toolsForRun(task: "Click the blue button", browserAdapterAvailable: true))
        XCTAssertTrue(handoff.isDisjoint(with: plain), "A task without handoff cues must not offer handoff tools.")
    }

    func testHandoffToolsAreNeverOfferedForTheCoreOnlyPolicy() throws {
        let names = try toolNames(
            BrowserAgentController.toolsForRun(
                task: "Remind me to call the clinic and email the hours",
                browserAdapterAvailable: true,
                coreOnly: true
            )
        )
        XCTAssertTrue(BrowserAgentController.handoffToolNames.isDisjoint(with: names))
    }

    func testHandoffBundleIsSelectedByCuesAndNotByOtherBundles() {
        XCTAssertTrue(BrowserAgentController.selectedBundles(forTask: "Remind me tomorrow", browserAdapterAvailable: false).contains(.handoff))
        XCTAssertFalse(BrowserAgentController.selectedBundles(forTask: "Read the page", browserAdapterAvailable: true).contains(.handoff))
    }

    func testThreeHandoffSchemasDescribeTheirArguments() throws {
        let definitions = BrowserAgentController.tools.filter { BrowserAgentController.handoffToolNames.contains($0["name"] as? String ?? "") }
        XCTAssertEqual(definitions.count, 3)
        let required = Dictionary(uniqueKeysWithValues: definitions.map { definition -> (String, [String]) in
            let parameters = definition["parameters"] as? [String: Any] ?? [:]
            return (definition["name"] as? String ?? "", parameters["required"] as? [String] ?? [])
        })
        XCTAssertEqual(required["prepare_calendar_event"], ["title", "start", "end", "notes"])
        XCTAssertEqual(required["prepare_reminder"], ["title", "due"])
        XCTAssertEqual(required["prepare_email"], ["subject", "body", "attachExports"])
    }

    @available(iOS 26.0, *)
    func testFoundationSchemaAdapterAcceptsTheThreeHandoffTools() throws {
        for definition in BrowserAgentController.tools where BrowserAgentController.handoffToolNames.contains(definition["name"] as? String ?? "") {
            XCTAssertNoThrow(try BrowserAgentFoundationSchemaAdapter.schema(for: definition))
        }
    }

    // MARK: Runs queue requests and never act

    func testPreparedHandoffsAreQueuedAfterTheRunAndNothingIsSent() async throws {
        let engine = HandoffScriptedEngine { _, execute, _ in
            let reminder = await execute("prepare_reminder", #"{"title":"Call the clinic","due":"2026-11-02T09:00:00+01:00"}"#)
            XCTAssertTrue(reminder.text.contains("the user will review it after the task finishes"))
            _ = await execute("prepare_email", #"{"subject":"Clinic hours","body":"Open at 9.","attachExports":true}"#)
            return "Prepared the reminder and the email."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        let webView = await loadedWebView("<main>Clinic hours</main>")
        var snapshot: BrowserAgentController.CompletionSnapshot?

        controller.start(
            task: "Find the clinic hours and remind me to call",
            preset: .standard,
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { snapshot = $0 },
            onComplete: { _ in }
        )
        for _ in 0..<2_000 where snapshot == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(snapshot)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.pendingConfirmation, "Preparing a handoff must not ask for an approval.")
        XCTAssertEqual(controller.handoffRequests.count, 2)
        XCTAssertEqual(controller.handoffRequests.first?.kind, .reminder(title: "Call the clinic", due: iso("2026-11-02T09:00:00+01:00")))
        XCTAssertEqual(controller.handoffRequests.last?.kind, .email(subject: "Clinic hours", body: "Open at 9.", attachments: []))

        let first = try XCTUnwrap(controller.handoffRequests.first)
        controller.dismissHandoffRequest(first.id)
        XCTAssertEqual(controller.handoffRequests.count, 1, "Dismissing shows the next request in order.")
    }

    func testPrivateRunStillQueuesButNeverAttachesFiles() async throws {
        let engine = HandoffScriptedEngine { _, execute, _ in
            _ = await execute("prepare_email", #"{"subject":"Hours","body":"Open.","attachExports":true}"#)
            return "Prepared."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        let webView = await loadedWebView("<main>Private hours</main>")
        var snapshot: BrowserAgentController.CompletionSnapshot?

        controller.start(
            task: "Email the hours to me",
            preset: .standard,
            conversation: nil,
            in: webView,
            openTab: nil,
            startingTabIsPrivate: true,
            onRunCompleted: { snapshot = $0 },
            onComplete: { _ in }
        )
        for _ in 0..<2_000 where snapshot == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(snapshot?.isPrivate, true)
        XCTAssertEqual(controller.handoffRequests.map(\.kind), [.email(subject: "Hours", body: "Open.", attachments: [])])
    }

    func testHandoffQueueHasARunLimit() async throws {
        let engine = HandoffScriptedEngine { _, execute, _ in
            var outputs: [String] = []
            for index in 1...(BrowserAgentController.maxHandoffRequestsPerRun + 1) {
                let output = await execute("prepare_reminder", #"{"title":"Task \#(index)"}"#)
                outputs.append(output.text)
            }
            return outputs.last ?? ""
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        let webView = await loadedWebView("<main>Limit</main>")
        var snapshot: BrowserAgentController.CompletionSnapshot?

        controller.start(
            task: "Remind me about each item",
            preset: .standard,
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { snapshot = $0 },
            onComplete: { _ in }
        )
        for _ in 0..<2_000 where snapshot == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(controller.handoffRequests.count, BrowserAgentController.maxHandoffRequestsPerRun)
        XCTAssertTrue(snapshot?.outcome.contains("already prepared") ?? false)
    }
}
