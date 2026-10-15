import XCTest
import WebKit
@testable import Browser

@MainActor
final class AgentRunRecordTests: XCTestCase {
    /// Runs a fixed script so the controller's run history can be checked without a model.
    private final class ScriptedRunEngine: BrowserAgentEngine {
        typealias Body = @MainActor (
            BrowserAgentEngineRequest,
            @escaping BrowserAgentToolExecutor,
            @escaping BrowserAgentNoteHandler
        ) async throws -> String
        let profile = BrowserAgentEngineProfile.chatGPTPlan(supportsVision: false)
        private let body: Body

        init(body: @escaping Body) {
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

    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private var loaders: [LoadWaiter] = []

    private func temporaryFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRunRecordTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("tasks.json")
    }

    private func loadedWebView(_ html: String) async -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let waiter = LoadWaiter()
        loaders.append(waiter)
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://agent-run-record.fixture/")!)
        }
        webView.navigationDelegate = nil
        return webView
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<800 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func sampleRecord(id: UUID = UUID()) -> AgentRunRecord {
        AgentRunRecord(
            id: id,
            task: "Compare two product pages",
            outcome: "The second page is cheaper.",
            actions: ["Read page title", "Finished"],
            date: Date(timeIntervalSince1970: 1_700_000_300),
            backend: AIModelBackend.localApple.rawValue,
            preset: "research",
            startURL: URL(string: "https://example.test/start"),
            isPrivate: false,
            requestID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .completed,
            approvals: [AgentRunApproval(
                reason: "Click Place order",
                host: "shop.example.test",
                decision: .denied,
                date: Date(timeIntervalSince1970: 1_700_000_100)
            )],
            questions: [AgentRunQuestion(
                prompt: "Which size do you want?",
                answered: true,
                date: Date(timeIntervalSince1970: 1_700_000_050)
            )],
            exports: [AgentRunExportRecord(filename: "comparison.csv", kind: .csv)],
            sources: [AgentRunSourceRecord(title: "Second page", url: URL(string: "https://example.test/b")!)],
            savedTaskID: UUID(),
            duration: 300
        )
    }

    private func documentData(history: [Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["version": 1, "savedTasks": [Any](), "history": history],
            options: [.sortedKeys]
        )
    }

    private func jsonObject(_ record: AgentRunRecord) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    }

    // MARK: Persistence

    func testOldHistoryDocumentDecodesWithEveryRunDetailEmpty() throws {
        // Shape copied from a history row written before run details existed.
        let legacyRow: [String: Any] = [
            "id": "6F1C4A2B-1D7E-4C55-9E7A-3B2D1F0A9C11",
            "task": "Read the current page",
            "outcome": "Finished",
            "actions": ["Read page title"],
            "date": 700_000_000,
            "backend": "chatGPTPlan",
            "preset": "standard",
            "isPrivate": false
        ]
        let fileURL = try temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try documentData(history: [legacyRow]).write(to: fileURL)

        let store = AgentTaskStore(fileURL: fileURL)
        try store.load()

        let record = try XCTUnwrap(store.history.first)
        XCTAssertEqual(record.task, "Read the current page")
        XCTAssertNil(record.requestID)
        XCTAssertNil(record.startedAt)
        XCTAssertNil(record.status)
        XCTAssertNil(record.approvals)
        XCTAssertNil(record.questions)
        XCTAssertNil(record.exports)
        XCTAssertNil(record.sources)
        XCTAssertNil(record.savedTaskID)
        XCTAssertNil(record.duration)
        XCTAssertNil(record.plainTextLog.range(of: "Approvals:"), "Legacy runs must not invent approval sections.")
    }

    func testUnfamiliarStatusDecisionAndExportKindDecodeWithoutFailing() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(AgentRunStatus.self, from: Data(#""paused""#.utf8)), .unknown)
        XCTAssertEqual(try decoder.decode(AgentRunStatus.self, from: Data(#""stepLimit""#.utf8)), .stepLimit)
        XCTAssertEqual(try decoder.decode(AgentRunApprovalDecision.self, from: Data(#""askLater""#.utf8)), .unknown)
        XCTAssertEqual(try decoder.decode(AgentRunApprovalDecision.self, from: Data(#""denied""#.utf8)), .denied)
        XCTAssertEqual(try decoder.decode(AgentRunExportKind.self, from: Data(#""xlsx""#.utf8)), .other)
        XCTAssertEqual(try decoder.decode(AgentRunExportKind.self, from: Data(#""csv""#.utf8)), .csv)
    }

    func testRunDetailsRoundTripAndNeverPersistExportLocations() throws {
        let fileURL = try temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let record = sampleRecord()
        let store = AgentTaskStore(fileURL: fileURL)
        try store.appendRun(record)

        let restored = AgentTaskStore(fileURL: fileURL)
        try restored.load()
        XCTAssertEqual(restored.history, [record])

        let bytes = try Data(contentsOf: fileURL)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(text.contains("comparison.csv"))
        XCTAssertFalse(text.contains("file://"), "Export file locations must never be written to history.")
        XCTAssertFalse(text.contains("fileURL"))
    }

    func testOversizedRunDetailArraysAndFieldsAreRejectedOnWriteAndRead() throws {
        let fileURL = try temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AgentTaskStore(fileURL: fileURL)
        let approval = AgentRunApproval(reason: "Download", host: nil, decision: .allowed, date: Date())
        let question = AgentRunQuestion(prompt: "Which?", answered: false, date: Date())
        let export = AgentRunExportRecord(filename: "a.pdf", kind: .pdf)
        let source = AgentRunSourceRecord(title: "Source", url: URL(string: "https://example.test/")!)

        var tooManyApprovals = sampleRecord()
        tooManyApprovals.approvals = Array(repeating: approval, count: AgentTaskStore.maximumApprovalsPerRun + 1)
        var tooManyQuestions = sampleRecord()
        tooManyQuestions.questions = Array(repeating: question, count: AgentTaskStore.maximumQuestionsPerRun + 1)
        var tooManyExports = sampleRecord()
        tooManyExports.exports = Array(repeating: export, count: AgentTaskStore.maximumExportsPerRun + 1)
        var tooManySources = sampleRecord()
        tooManySources.sources = Array(repeating: source, count: AgentTaskStore.maximumSourcesPerRun + 1)
        var oversizedQuestion = sampleRecord()
        oversizedQuestion.questions = [AgentRunQuestion(
            prompt: String(repeating: "🌐", count: (AgentTaskStore.maximumRunQuestionUTF8Bytes / 4) + 1),
            answered: false,
            date: Date()
        )]
        var unsafeSource = sampleRecord()
        unsafeSource.sources = [AgentRunSourceRecord(title: "Local", url: URL(string: "file:///etc/passwd")!)]

        for (description, record) in [
            ("approvals over limit", tooManyApprovals),
            ("questions over limit", tooManyQuestions),
            ("exports over limit", tooManyExports),
            ("sources over limit", tooManySources),
            ("oversized question", oversizedQuestion),
            ("non-web source", unsafeSource)
        ] {
            XCTAssertThrowsError(try store.appendRun(record), description) { error in
                XCTAssertEqual(error as? AgentTaskStoreError, .invalidRunRecord, description)
            }
        }
        XCTAssertTrue(store.history.isEmpty)

        // Documents on disk get the same limits: a bad row makes the whole document unreadable and leaves bytes alone.
        var badRow = try jsonObject(sampleRecord())
        badRow["approvals"] = try jsonObject(tooManyApprovals)["approvals"]
        let badBytes = try documentData(history: [badRow])
        try badBytes.write(to: fileURL, options: .atomic)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? AgentTaskStoreError, .corruptData)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), badBytes)
    }

    // MARK: Snapshot and controller

    func testRequestIDAppearsInSnapshotAndHistoryOnlyWhenGiven() async throws {
        let engine = ScriptedRunEngine { _, _, _ in "Finished." }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        let webView = await loadedWebView("<main>Request fixture</main>")
        let requestID = UUID()
        var snapshots: [BrowserAgentController.CompletionSnapshot] = []

        controller.start(
            task: "Read the page",
            conversation: nil,
            in: webView,
            openTab: nil,
            requestID: requestID,
            onRunCompleted: { snapshots.append($0) },
            onComplete: { _ in }
        )
        let finished = await waitUntil { !controller.isRunning && snapshots.count == 1 }
        XCTAssertTrue(finished)
        let withRequest = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(withRequest.requestID, requestID)
        XCTAssertEqual(withRequest.historyRecord.requestID, requestID)
        XCTAssertEqual(withRequest.status, .completed)
        XCTAssertLessThanOrEqual(withRequest.startedAt, withRequest.date)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(withRequest.historyRecord.duration), 0)
        XCTAssertEqual(withRequest.historyRecord.status, .completed)

        controller.start(
            task: "Read the page again",
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { snapshots.append($0) },
            onComplete: { _ in }
        )
        let secondFinished = await waitUntil { !controller.isRunning && snapshots.count == 2 }
        XCTAssertTrue(secondFinished)
        XCTAssertNil(snapshots[1].requestID, "Sidebar-typed runs carry no request ID.")
        XCTAssertNil(snapshots[1].historyRecord.requestID)
    }

    func testStoppedRunRecordsStoppedStatus() async throws {
        let engine = ScriptedRunEngine { _, _, _ in
            for _ in 0..<2_000 {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            return "Late answer."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        let webView = await loadedWebView("<main>Stop fixture</main>")
        var snapshot: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "Wait for a long time",
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { snapshot = $0 },
            onComplete: { _ in }
        )
        let running = await waitUntil { controller.isRunning }
        XCTAssertTrue(running)
        controller.stop()
        XCTAssertEqual(snapshot?.status, .stopped)
        XCTAssertEqual(snapshot?.historyRecord.status, .stopped)
    }

    func testStepLimitAndFailureEndingsAreRecordedDistinctly() async throws {
        let webView = await loadedWebView("<main>Ending fixture</main>")

        for (task, failure, expected) in [
            ("Hit the limit", BrowserAgentEngineFailure.stepLimit(25), AgentRunStatus.stepLimit),
            ("Engine unavailable", BrowserAgentEngineFailure.unavailable("The model is offline."), AgentRunStatus.failed)
        ] {
            let engine = ScriptedRunEngine { _, _, _ in throw failure }
            let controller = BrowserAgentController(engineFactory: { _ in engine })
            var snapshot: BrowserAgentController.CompletionSnapshot?
            controller.start(
                task: task,
                conversation: nil,
                in: webView,
                openTab: nil,
                onRunCompleted: { snapshot = $0 },
                onComplete: { _ in }
            )
            let finished = await waitUntil { snapshot != nil }
            XCTAssertTrue(finished, task)
            XCTAssertEqual(snapshot?.status, expected, task)
            controller.stop()
        }
    }

    func testPrivateRunsRecordNoApprovalsQuestionsOrExports() async throws {
        let engine = ScriptedRunEngine { _, execute, _ in
            _ = await execute("ask_user", #"{"question":"Which account should I use?"}"#)
            return "Done in private."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        let webView = await loadedWebView("<main>Private fixture</main>")
        var snapshot: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "Ask me something privately",
            conversation: nil,
            in: webView,
            openTab: nil,
            startingTabIsPrivate: true,
            onRunCompleted: { snapshot = $0 },
            onComplete: { _ in }
        )
        let asked = await waitUntil { controller.pendingQuestion != nil }
        XCTAssertTrue(asked)
        controller.resolveUserQuestion("Personal account 42")
        let finished = await waitUntil { snapshot != nil }
        XCTAssertTrue(finished)

        let value = try XCTUnwrap(snapshot)
        XCTAssertTrue(value.isPrivate)
        XCTAssertTrue(value.questions.isEmpty)
        XCTAssertTrue(value.approvals.isEmpty)
        XCTAssertTrue(value.exportedFiles.isEmpty)
        XCTAssertTrue(value.historyRecord.questions?.isEmpty ?? true)
        XCTAssertTrue(value.historyRecord.exports?.isEmpty ?? true)

        let fileURL = try temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AgentTaskStore(fileURL: fileURL)
        let didRecord = try AgentTaskHistoryRecorder.record(value.historyRecord, isPrivate: value.isPrivate) { store }
        XCTAssertFalse(didRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testQuestionAnswerTextIsNeverStoredButPromptIs() async throws {
        let answer = "SECRET-ANSWER-4417"
        let prompt = "Which shipping address should I use?"
        let engine = ScriptedRunEngine { _, execute, _ in
            let output = await execute("ask_user", #"{"question":"Which shipping address should I use?"}"#)
            XCTAssertTrue(output.text.contains(answer), "The model still receives the answer for this run.")
            return "Noted."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        let webView = await loadedWebView("<main>Question fixture</main>")
        var snapshot: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "Choose an address",
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { snapshot = $0 },
            onComplete: { _ in }
        )
        let asked = await waitUntil { controller.pendingQuestion?.prompt == prompt }
        XCTAssertTrue(asked)
        controller.resolveUserQuestion(answer)
        let finished = await waitUntil { snapshot != nil }
        XCTAssertTrue(finished)

        let value = try XCTUnwrap(snapshot)
        let question = try XCTUnwrap(value.questions.first)
        XCTAssertEqual(value.questions.count, 1)
        XCTAssertEqual(question.prompt, prompt)
        XCTAssertTrue(question.answered)

        let encoded = try JSONEncoder().encode(value.historyRecord)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains(answer), "Question answers must never be stored in run history.")
        XCTAssertTrue(text.contains(prompt))
        XCTAssertFalse(value.historyRecord.plainTextLog.contains(answer))
    }

    func testApprovalDecisionIsRecordedInTheRunSnapshot() async throws {
        let webView = await loadedWebView("<button onclick=\"window.deleted=true\">Delete account</button>")
        let snapshotValue = try await webView.callAsyncJavaScript(
            BrowserAgentPageScript.snapshot,
            arguments: ["maxElements": 150, "maxText": 2_500],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        ) as? String
        let snapshotData = try XCTUnwrap(snapshotValue?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshotData) as? [String: Any])
        let line = try XCTUnwrap((object["elements"] as? String ?? "").components(separatedBy: "\n").first { $0.contains("Delete account") })
        let start = try XCTUnwrap(line.firstIndex(of: "["))
        let end = try XCTUnwrap(line.firstIndex(of: "]"))
        let id = try XCTUnwrap(Int(line[line.index(after: start)..<end]))
        let engine = ScriptedRunEngine { _, execute, _ in
            let argumentsData = try JSONSerialization.data(withJSONObject: ["id": id])
            let arguments = try XCTUnwrap(String(data: argumentsData, encoding: .utf8))
            return (await execute("click", arguments)).text
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var snapshot: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "Click the delete button",
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { snapshot = $0 },
            onComplete: { _ in }
        )
        let asked = await waitUntil { controller.pendingConfirmation != nil }
        XCTAssertTrue(asked)
        controller.resolveConfirmation(false)
        let finished = await waitUntil { snapshot != nil }
        XCTAssertTrue(finished)

        let value = try XCTUnwrap(snapshot)
        let approval = try XCTUnwrap(value.approvals.first)
        XCTAssertEqual(value.approvals.count, 1)
        XCTAssertEqual(approval.decision, .denied)
        XCTAssertFalse(approval.reason.isEmpty)
        let afterDenial = try await webView.callAsyncJavaScript("return window.deleted === true;", arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertNotEqual(afterDenial, true, "Recording the decision must not change the approval gate.")
    }
}
