import XCTest
import WebKit
@testable import Browser

@MainActor
final class AgentRunLiveActivityTests: XCTestCase {
    @MainActor
    private final class ScriptedEngine: BrowserAgentEngine {
        typealias Body = @MainActor (
            BrowserAgentEngineRequest,
            @escaping BrowserAgentToolExecutor,
            @escaping BrowserAgentNoteHandler
        ) async throws -> String
        let profile: BrowserAgentEngineProfile
        private let body: Body

        init(profile: BrowserAgentEngineProfile? = nil, body: @escaping Body) {
            self.profile = profile ?? .chatGPTPlan(supportsVision: false)
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

    @MainActor
    private final class RecordingObserver: BrowserAgentRunObserver {
        var started: [BrowserAgentRunProgress] = []
        var progress: [BrowserAgentRunProgress] = []
        var ended: [(progress: BrowserAgentRunProgress, status: AgentRunStatus, outcome: String)] = []

        func agentRunDidStart(_ progress: BrowserAgentRunProgress) { started.append(progress) }
        func agentRunDidProgress(_ progress: BrowserAgentRunProgress) { self.progress.append(progress) }
        func agentRunDidEnd(_ progress: BrowserAgentRunProgress, status: AgentRunStatus, outcome: String) {
            ended.append((progress, status, outcome))
        }
    }

    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private static let page = #"<main><h1>Secret page heading</h1><button onclick="window.clickCount=(window.clickCount||0)+1">Secret button</button></main>"#

    // MARK: Controller progress

    func testPublicRunReportsTaskStepsCountAndOutcome() async throws {
        let webView = await loadedWebView(Self.page)
        let id = try await elementID(containing: "Secret button", in: webView)
        let engine = ScriptedEngine { _, execute, _ in
            _ = await execute("click", #"{"id":\#(id)}"#)
            _ = await execute("scroll", #"{"direction":"down"}"#)
            return "Pressed the button.\nMore detail on a second line."
        }
        let observer = RecordingObserver()
        let controller = BrowserAgentController(engineFactory: { _ in engine }, runObserver: observer)
        defer { controller.stop() }
        var summary = ""
        controller.start(task: "Press the button\nwith recorded steps", conversation: nil, in: webView, openTab: nil) { summary = $0 }

        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary)")
        let start = try XCTUnwrap(observer.started.first)
        XCTAssertEqual(observer.started.count, 1)
        XCTAssertEqual(start.taskTitle, "Press the button", "The title is the task's first line.")
        XCTAssertEqual(start.stepCount, 0)
        XCTAssertEqual(start.maximumSteps, 25)
        XCTAssertFalse(start.isPrivate)
        XCTAssertEqual(observer.progress.map(\.stepCount).max(), 2)
        XCTAssertTrue(observer.progress.allSatisfy { $0.runID == start.runID })
        XCTAssertTrue(observer.progress.contains { $0.stepText == "Scroll down" }, "\(observer.progress.map(\.stepText))")
        let end = try XCTUnwrap(observer.ended.first)
        XCTAssertEqual(observer.ended.count, 1)
        XCTAssertEqual(end.status, .completed)
        XCTAssertEqual(end.outcome, "Pressed the button.", "Only the first line of the result is shown.")
        XCTAssertEqual(end.progress.stepCount, 2)
    }

    func testPrivateRunReportsNoTaskOrPageText() async throws {
        let webView = await loadedWebView(Self.page)
        let id = try await elementID(containing: "Secret button", in: webView)
        let engine = ScriptedEngine { _, execute, onNote in
            onNote("Found the Secret page heading")
            _ = await execute("click", #"{"id":\#(id)}"#)
            return "Secret answer"
        }
        let observer = RecordingObserver()
        let controller = BrowserAgentController(engineFactory: { _ in engine }, runObserver: observer)
        defer { controller.stop() }
        var summary = ""
        controller.start(
            task: "Press the secret button",
            conversation: nil,
            in: webView,
            openTab: nil,
            startingTabIsPrivate: true
        ) { summary = $0 }

        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary)")
        let everything = observer.started + observer.progress + observer.ended.map(\.progress)
        XCTAssertFalse(everything.isEmpty)
        for progress in everything {
            XCTAssertTrue(progress.isPrivate)
            XCTAssertEqual(progress.taskTitle, "")
            XCTAssertEqual(progress.stepText, "")
        }
        XCTAssertEqual(observer.progress.map(\.stepCount).max(), 1, "Private runs still report the step count.")
        XCTAssertEqual(observer.ended.first?.outcome, "")
        XCTAssertEqual(observer.ended.first?.status, .completed)
    }

    func testWaitingForAnAnswerIsReportedAndStopEndsAsStopped() async throws {
        let webView = await loadedWebView(Self.page)
        let engine = ScriptedEngine { _, execute, _ in
            _ = await execute("ask_user", #"{"question":"Which one?"}"#)
            return "Should not finish."
        }
        let observer = RecordingObserver()
        let controller = BrowserAgentController(engineFactory: { _ in engine }, runObserver: observer)
        defer { controller.stop() }
        controller.start(task: "Ask me something", conversation: nil, in: webView, openTab: nil) { _ in }

        let waiting = await waitUntil { observer.progress.last?.isWaitingForUser == true }
        XCTAssertTrue(waiting, "\(observer.progress)")
        controller.stop()
        XCTAssertEqual(observer.ended.count, 1)
        XCTAssertEqual(observer.ended.first?.status, .stopped)
        XCTAssertEqual(observer.ended.first?.outcome, "Stopped.")
    }

    func testRepeatedCallStopEndsTheActivityAsFailed() async throws {
        let webView = await loadedWebView(Self.page)
        let engine = ScriptedEngine { _, execute, _ in
            for _ in 0..<8 {
                _ = await execute("wait", #"{"seconds":0}"#)
            }
            return "Should not finish."
        }
        let observer = RecordingObserver()
        let controller = BrowserAgentController(engineFactory: { _ in engine }, runObserver: observer)
        defer { controller.stop() }
        controller.start(task: "Wait for the page", conversation: nil, in: webView, openTab: nil) { _ in }

        let ended = await waitUntil(iterations: 2_000) { !observer.ended.isEmpty }
        XCTAssertTrue(ended, "\(observer.progress.map(\.stepText))")
        XCTAssertEqual(observer.ended.first?.status, .failed)
        XCTAssertTrue(observer.ended.first?.outcome.contains("kept repeating") == true, observer.ended.first?.outcome ?? "")
    }

    // MARK: Activity content

    func testContentHidesPrivateTextAndNamesEachPhase() {
        let runID = UUID()
        let privateProgress = BrowserAgentRunProgress(
            runID: runID,
            taskTitle: "Leaked title",
            stepText: "Leaked page text",
            stepCount: 3,
            maximumSteps: 25,
            isPrivate: true,
            isWaitingForUser: false
        )
        XCTAssertEqual(AgentRunLiveActivityContent.title(for: privateProgress), "Private browsing task")
        let privateState = AgentRunLiveActivityContent.state(for: privateProgress)
        XCTAssertEqual(privateState.phase, .working)
        XCTAssertEqual(privateState.stepText, "Working…")
        XCTAssertEqual(privateState.stepCount, 3)
        for status in [AgentRunStatus.completed, .failed, .stepLimit, .stopped, .unknown] {
            let final = AgentRunLiveActivityContent.finalState(for: privateProgress, status: status, outcome: "Leaked outcome")
            XCTAssertFalse(final.stepText.contains("Leaked"), "\(status): \(final.stepText)")
        }

        let publicProgress = BrowserAgentRunProgress(
            runID: runID,
            taskTitle: "Find a flight",
            stepText: "Click \"Search\"",
            stepCount: 5,
            maximumSteps: 40,
            isPrivate: false,
            isWaitingForUser: false
        )
        XCTAssertEqual(AgentRunLiveActivityContent.title(for: publicProgress), "Find a flight")
        let working = AgentRunLiveActivityContent.state(for: publicProgress)
        XCTAssertEqual(working.stepText, "Click \"Search\"")
        XCTAssertEqual(working.fractionComplete, 5.0 / 40.0, accuracy: 0.0001)

        let waiting = BrowserAgentRunProgress(
            runID: runID, taskTitle: "Find a flight", stepText: "Click \"Buy\"", stepCount: 6,
            maximumSteps: 40, isPrivate: false, isWaitingForUser: true
        )
        XCTAssertEqual(AgentRunLiveActivityContent.state(for: waiting).phase, .waitingForYou)
        XCTAssertEqual(AgentRunLiveActivityContent.state(for: waiting).stepText, "Waiting for you in Vortyra")

        let finished = AgentRunLiveActivityContent.finalState(for: publicProgress, status: .completed, outcome: "Cheapest is $120")
        XCTAssertEqual(finished.phase, .finished)
        XCTAssertEqual(finished.stepText, "Cheapest is $120")
        XCTAssertEqual(finished.fractionComplete, 1)
        XCTAssertEqual(AgentRunLiveActivityContent.finalState(for: publicProgress, status: .stepLimit, outcome: "").phase, .failed)
        XCTAssertEqual(AgentRunLiveActivityContent.finalState(for: publicProgress, status: .stepLimit, outcome: "").stepText, "Couldn't finish")
        XCTAssertEqual(AgentRunLiveActivityContent.finalState(for: publicProgress, status: .stopped, outcome: "").phase, .stopped)

        let untitled = BrowserAgentRunProgress(
            runID: runID, taskTitle: "", stepText: "", stepCount: 0,
            maximumSteps: 25, isPrivate: false, isWaitingForUser: false
        )
        XCTAssertEqual(AgentRunLiveActivityContent.title(for: untitled), "Browser task")
    }

    func testSettingDefaultsOnAndTurningItOffStartsNoActivity() throws {
        let suiteName = "AgentRunLiveActivityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(AgentRunLiveActivitySettings.isEnabled(defaults: defaults))
        defaults.set(false, forKey: AgentRunLiveActivitySettings.enabledKey)
        XCTAssertFalse(AgentRunLiveActivitySettings.isEnabled(defaults: defaults))

        let progress = BrowserAgentRunProgress(
            runID: UUID(), taskTitle: "Task", stepText: "", stepCount: 0,
            maximumSteps: 25, isPrivate: false, isWaitingForUser: false
        )
        let switchedOff = AgentRunLiveActivityController(isEnabled: { false }, areActivitiesAllowed: { true })
        switchedOff.agentRunDidStart(progress)
        XCTAssertEqual(switchedOff.activeRunCount, 0)
        let notAllowed = AgentRunLiveActivityController(isEnabled: { true }, areActivitiesAllowed: { false })
        notAllowed.agentRunDidStart(progress)
        XCTAssertEqual(notAllowed.activeRunCount, 0)
        // Progress and end for a run without an activity are ignored.
        notAllowed.agentRunDidProgress(progress)
        notAllowed.agentRunDidEnd(progress, status: .completed, outcome: "Done")
        XCTAssertEqual(notAllowed.activeRunCount, 0)
    }

    func testProgressLineUsesTheFirstNonEmptyLine() {
        XCTAssertEqual(BrowserAgentController.progressLine("\n  \nFirst line \nSecond"), "First line")
        XCTAssertEqual(BrowserAgentController.progressLine(String(repeating: "x", count: 500)).count, 140)
        XCTAssertEqual(BrowserAgentController.progressLine(""), "")
    }

    // MARK: Helpers

    private func loadedWebView(_ html: String) async -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://live-activity.fixture/")!)
        }
        webView.navigationDelegate = nil
        return webView
    }

    private func elementID(containing label: String, in webView: WKWebView) async throws -> Int {
        let value = try await webView.callAsyncJavaScript(
            BrowserAgentPageScript.snapshot,
            arguments: ["maxElements": 150, "maxText": 2_500],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        ) as? String
        let data = try XCTUnwrap(value?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lines = (object["elements"] as? String ?? "").components(separatedBy: "\n")
        let line = try XCTUnwrap(lines.first { $0.contains(label) })
        let start = try XCTUnwrap(line.firstIndex(of: "["))
        let end = try XCTUnwrap(line.firstIndex(of: "]"))
        return try XCTUnwrap(Int(line[line.index(after: start)..<end]))
    }

    private func waitUntil(iterations: Int = 800, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<iterations {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
