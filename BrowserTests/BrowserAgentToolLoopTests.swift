import XCTest
import WebKit
@testable import Browser

@MainActor
final class BrowserAgentToolLoopTests: XCTestCase {
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

    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private static let counterPage = #"<main><button id="count" onclick="window.clickCount=(window.clickCount||0)+1">Count</button></main>"#

    // MARK: Detector

    func testDetectorWarnsAtThreeBlocksAtFiveAndStopsAtEight() {
        var detector = BrowserAgentToolLoopDetector()
        let verdicts = (0..<8).map { _ in detector.record(name: "click", argumentsJSON: #"{"id":4}"#) }
        XCTAssertEqual(verdicts, [
            .allow, .allow,
            .warn(repeats: 3), .warn(repeats: 4),
            .block(repeats: 5), .block(repeats: 6), .block(repeats: 7),
            .stop(total: 8)
        ])
    }

    func testDetectorTreatsEquivalentArgumentsAsTheSameCall() {
        var detector = BrowserAgentToolLoopDetector()
        XCTAssertEqual(detector.record(name: "type_text", argumentsJSON: #"{"id":3,"text":" hi "}"#), .allow)
        XCTAssertEqual(detector.record(name: "type_text", argumentsJSON: #"{ "text": "hi", "id": 3 }"#), .allow)
        XCTAssertEqual(
            detector.record(name: "type_text", argumentsJSON: #"{"text":"hi","id":3,"submit":null}"#),
            .warn(repeats: 3),
            "Key order, surrounding spaces and null values do not make a call different."
        )

        var empty = BrowserAgentToolLoopDetector()
        XCTAssertEqual(empty.record(name: "go_back", argumentsJSON: ""), .allow)
        XCTAssertEqual(empty.record(name: "go_back", argumentsJSON: "{}"), .allow)
        XCTAssertEqual(empty.record(name: "go_back", argumentsJSON: "  { } "), .warn(repeats: 3))
    }

    func testDifferentArgumentsToolsOrPagesBreakTheStreakButStillCountTowardTheRunTotal() throws {
        var detector = BrowserAgentToolLoopDetector()
        XCTAssertEqual(detector.record(name: "click", argumentsJSON: #"{"id":1}"#), .allow)
        XCTAssertEqual(detector.record(name: "click", argumentsJSON: #"{"id":1}"#), .allow)
        XCTAssertEqual(detector.record(name: "click", argumentsJSON: #"{"id":2}"#), .allow)
        XCTAssertEqual(detector.record(name: "scroll", argumentsJSON: #"{"id":1}"#), .allow)

        let first = "https://one.example/article @0,0"
        let second = "https://two.example/article @0,0"
        var pages = BrowserAgentToolLoopDetector()
        for page in [first, second, first, second, first, second] {
            XCTAssertEqual(
                pages.record(name: "read_page", argumentsJSON: "{}", pageState: page),
                .allow,
                "Reading different pages is not a repeat."
            )
        }

        var scrolling = BrowserAgentToolLoopDetector()
        for offset in stride(from: 0, through: 6_000, by: 600) {
            XCTAssertEqual(
                scrolling.record(name: "scroll", argumentsJSON: #"{"direction":"down"}"#, pageState: "https://long.example/ @0,\(offset)"),
                .allow,
                "Scrolling further down is progress."
            )
        }
        XCTAssertEqual(scrolling.record(name: "scroll", argumentsJSON: #"{"direction":"down"}"#, pageState: "https://long.example/ @0,6000"), .allow)
        XCTAssertEqual(
            scrolling.record(name: "scroll", argumentsJSON: #"{"direction":"down"}"#, pageState: "https://long.example/ @0,6000"),
            .warn(repeats: 3),
            "Scrolling at the bottom of the page is a repeat."
        )

        var alternating = BrowserAgentToolLoopDetector()
        var verdicts: [BrowserAgentToolLoopDetector.Verdict] = []
        for index in 0..<15 {
            verdicts.append(alternating.record(name: "click", argumentsJSON: index.isMultiple(of: 2) ? #"{"id":1}"# : #"{"id":2}"#))
        }
        XCTAssertEqual(Array(verdicts.prefix(14)), Array(repeating: .allow, count: 14))
        XCTAssertEqual(verdicts.last, .stop(total: 8), "Eight of the same call anywhere in a run stop it, even when never consecutive.")
    }

    func testAskUserAndFinishAreNeverCountedAndAQuestionEndsTheStreak() {
        var detector = BrowserAgentToolLoopDetector()
        for _ in 0..<12 {
            XCTAssertEqual(detector.record(name: "finish", argumentsJSON: #"{"answer":"Done"}"#), .allow)
            XCTAssertEqual(detector.record(name: "ask_user", argumentsJSON: #"{"question":"Which one?"}"#), .allow)
        }

        var streak = BrowserAgentToolLoopDetector()
        XCTAssertEqual(streak.record(name: "click", argumentsJSON: #"{"id":9}"#), .allow)
        XCTAssertEqual(streak.record(name: "click", argumentsJSON: #"{"id":9}"#), .allow)
        XCTAssertEqual(streak.record(name: "ask_user", argumentsJSON: #"{"question":"Try again?"}"#), .allow)
        XCTAssertEqual(streak.record(name: "click", argumentsJSON: #"{"id":9}"#), .allow, "The user's answer starts a new streak.")
    }

    // MARK: Controller

    func testRepeatedClickIsWarnedThenSkippedWithoutRunning() async throws {
        let webView = await loadedWebView(Self.counterPage)
        let id = try await elementID(containing: "Count", in: webView)
        var outputs: [String] = []
        let engine = ScriptedEngine { _, execute, _ in
            for _ in 0..<6 {
                outputs.append((await execute("click", #"{"id":\#(id)}"#)).text)
            }
            return "Counted."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var completion: BrowserAgentController.CompletionSnapshot?
        var summary = ""
        controller.start(
            task: "Press the count button",
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { completion = $0 }
        ) { summary = $0 }

        let completed = await waitUntil { !controller.isRunning && completion != nil }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        XCTAssertEqual(outputs.count, 6)
        for output in outputs.prefix(2) {
            XCTAssertFalse(output.contains("Repeated call"), output)
            XCTAssertTrue(output.contains("<page_snapshot>"), output)
        }
        for output in outputs[2...3] {
            XCTAssertTrue(output.hasPrefix("Repeated call: this exact click call"), output)
            XCTAssertTrue(output.contains("<page_snapshot>"), "A warned call still runs and returns its result: \(output)")
        }
        for output in outputs[4...5] {
            XCTAssertTrue(output.hasPrefix("Blocked:"), output)
            XCTAssertFalse(output.contains("<page_snapshot>"), output)
        }
        let count = try await webView.callAsyncJavaScript("return window.clickCount || 0;", arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(count, 4, "The fifth and sixth identical clicks must not reach the page.")
        let snapshot = try XCTUnwrap(completion)
        XCTAssertEqual(snapshot.status, .completed)
        XCTAssertEqual(snapshot.outcome, "Counted.")
        XCTAssertTrue(snapshot.actions.contains("Skipped a repeated click action."), "\(snapshot.actions)")
    }

    func testScrollingDownALongPageIsNotARepeatUntilTheBottom() async throws {
        let webView = await loadedWebView(#"<main style="height:6000px">Long page</main>"#)
        var outputs: [String] = []
        let engine = ScriptedEngine { _, execute, _ in
            for _ in 0..<14 {
                outputs.append((await execute("scroll", #"{"direction":"down"}"#)).text)
            }
            return "Scrolled to the end."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var completion: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "Scroll to the end of the page",
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { completion = $0 }
        ) { _ in }

        let completed = await waitUntil(iterations: 2_000) { !controller.isRunning && completion != nil }
        XCTAssertTrue(completed, "outputs=\(outputs)")
        XCTAssertEqual(outputs.count, 14)
        let bottom = try XCTUnwrap(
            outputs.firstIndex { $0.contains("Reached the bottom of the page.") },
            "6000 px at about 675 px a scroll reaches the bottom within 14 scrolls: \(outputs.map { $0.prefix(60) })"
        )
        XCTAssertGreaterThanOrEqual(bottom, 6, "The fixture must need several scrolls before the bottom.")
        for output in outputs[...bottom] {
            XCTAssertFalse(output.contains("Repeated call"), "Scrolls that move the page are progress: \(output.prefix(120))")
            XCTAssertFalse(output.hasPrefix("Blocked"), String(output.prefix(120)))
        }
        // The scroll that reached the bottom moved the page. From then on the position stays put,
        // so the third scroll at the bottom is warned about and the fifth is skipped.
        XCTAssertFalse(outputs[bottom + 2].contains("Repeated call"), String(outputs[bottom + 2].prefix(120)))
        XCTAssertTrue(outputs[bottom + 3].hasPrefix("Repeated call"), String(outputs[bottom + 3].prefix(120)))
        XCTAssertTrue(outputs[bottom + 5].hasPrefix("Blocked:"), String(outputs[bottom + 5].prefix(120)))
        XCTAssertEqual(completion?.status, .completed)
    }

    func testEighthRepeatStopsTheRunAsFailed() async throws {
        let webView = await loadedWebView(Self.counterPage)
        let id = try await elementID(containing: "Count", in: webView)
        var outputs: [String] = []
        let engine = ScriptedEngine { _, execute, _ in
            for _ in 0..<10 {
                outputs.append((await execute("click", #"{"id":\#(id)}"#)).text)
            }
            return "This answer must not be accepted."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var completion: BrowserAgentController.CompletionSnapshot?
        var summary = ""
        controller.start(
            task: "Press the count button",
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { completion = $0 }
        ) { summary = $0 }

        let completed = await waitUntil { !controller.isRunning && completion != nil }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        XCTAssertEqual(outputs.count, 10)
        XCTAssertTrue(outputs[7].hasPrefix("Cancelled."), outputs[7])
        XCTAssertEqual(Array(outputs[8...]), ["Cancelled.", "Cancelled."], "Nothing runs after the loop stop.")
        let snapshot = try XCTUnwrap(completion)
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertTrue(snapshot.outcome.contains("kept repeating the same click action"), snapshot.outcome)
        XCTAssertFalse(summary.contains("This answer must not be accepted."), summary)
        XCTAssertTrue(summary.contains("kept repeating the same click action"), summary)
        let count = try await webView.callAsyncJavaScript("return window.clickCount || 0;", arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(count, 4)
    }

    func testChatGPTEngineLoopEndsAsFailedBeforeTheStepLimit() async throws {
        let webView = await loadedWebView(Self.counterPage)
        let id = try await elementID(containing: "Count", in: webView)
        var turns = 0
        let engine = ChatGPTPlanAgentEngine(profile: .chatGPTPlan(supportsVision: false)) { _, _, _ in
            turns += 1
            return ChatGPTAgentTurn(calls: [
                ChatGPTAgentFunctionCall(callID: "call-\(turns)", name: "click", arguments: #"{"id":\#(id)}"#)
            ])
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var completion: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "Press the count button",
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { completion = $0 }
        ) { _ in }

        let completed = await waitUntil { !controller.isRunning && completion != nil }
        XCTAssertTrue(completed, "steps=\(controller.steps.map(\.text))")
        let snapshot = try XCTUnwrap(completion)
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertTrue(snapshot.outcome.contains("kept repeating"), snapshot.outcome)
        XCTAssertEqual(turns, 8, "The run ends on the eighth identical call, well inside the 25-step limit.")
    }

    func testDistinctCallsStillStopAtTheTwentyFiveStepLimit() async throws {
        XCTAssertEqual(BrowserAgentController.maxSteps, 25)
        XCTAssertEqual(BrowserAgentEngineProfile.chatGPTPlan(supportsVision: false).maxSteps, 25)
        let webView = await loadedWebView("<main><p>\(String(repeating: "Long article text. ", count: 400))</p></main>")
        var turns = 0
        let engine = ChatGPTPlanAgentEngine(profile: .chatGPTPlan(supportsVision: false)) { _, _, _ in
            turns += 1
            return ChatGPTAgentTurn(calls: [
                ChatGPTAgentFunctionCall(callID: "call-\(turns)", name: "read_page", arguments: #"{"offset":\#(turns * 10)}"#)
            ])
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var completion: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "Read the article",
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { completion = $0 }
        ) { _ in }

        let completed = await waitUntil(iterations: 2_000) { !controller.isRunning && completion != nil }
        XCTAssertTrue(completed, "steps=\(controller.steps.map(\.text))")
        let snapshot = try XCTUnwrap(completion)
        XCTAssertEqual(snapshot.status, .stepLimit)
        XCTAssertEqual(turns, 25)
        XCTAssertFalse(snapshot.actions.contains { $0.contains("Skipped a repeated") }, "\(snapshot.actions)")
    }

    func testAskUserIsNeverWarnedOrBlocked() async throws {
        let webView = await loadedWebView("<main>Question fixture</main>")
        var outputs: [String] = []
        let engine = ScriptedEngine { _, execute, _ in
            for _ in 0..<9 {
                outputs.append((await execute("ask_user", #"{"question":"Which color?"}"#)).text)
            }
            return "Asked nine times."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var completion: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "Choose a color",
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { completion = $0 }
        ) { _ in }

        for index in 0..<9 {
            let shown = await waitUntil { controller.pendingQuestion?.prompt == "Which color?" && outputs.count == index }
            XCTAssertTrue(shown, "question \(index); outputs=\(outputs)")
            controller.resolveUserQuestion("Blue \(index)")
        }
        let completed = await waitUntil { !controller.isRunning && completion != nil }
        XCTAssertTrue(completed, "outputs=\(outputs)")
        XCTAssertEqual(outputs.count, 9)
        for (index, output) in outputs.enumerated() {
            XCTAssertTrue(output.contains("Blue \(index)"), output)
            XCTAssertFalse(output.contains("Repeated call"), output)
            XCTAssertFalse(output.contains("Blocked"), output)
        }
        XCTAssertEqual(completion?.status, .completed)
        XCTAssertEqual(completion?.outcome, "Asked nine times.")
    }

    func testFinishPassedToTheExecutorIsNeverWarnedBlockedOrStopped() async throws {
        let webView = await loadedWebView("<main>Finish fixture</main>")
        var outputs: [String] = []
        let engine = ScriptedEngine { _, execute, _ in
            for _ in 0..<9 {
                outputs.append((await execute("finish", #"{"answer":"Done"}"#)).text)
            }
            return "Finished."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var completion: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "Read the page title",
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { completion = $0 }
        ) { _ in }

        let completed = await waitUntil { !controller.isRunning && completion != nil }
        XCTAssertTrue(completed, "outputs=\(outputs)")
        XCTAssertEqual(outputs.count, 9)
        for output in outputs {
            XCTAssertFalse(output.contains("Repeated call"), output)
            XCTAssertFalse(output.hasPrefix("Blocked"), output)
            XCTAssertFalse(output.hasPrefix("Cancelled"), output)
        }
        XCTAssertEqual(completion?.status, .completed)
        XCTAssertEqual(completion?.outcome, "Finished.")
    }

    func testANewRunStartsWithAFreshDetector() async throws {
        let webView = await loadedWebView(Self.counterPage)
        let id = try await elementID(containing: "Count", in: webView)
        var outputs: [String] = []
        let engine = ScriptedEngine { _, execute, _ in
            for _ in 0..<2 {
                outputs.append((await execute("click", #"{"id":\#(id)}"#)).text)
            }
            return "Clicked twice."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        for run in 0..<2 {
            var summary = ""
            controller.start(task: "Press the count button", conversation: nil, in: webView, openTab: nil) { summary = $0 }
            let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
            XCTAssertTrue(completed, "run \(run); summary=\(summary)")
        }
        XCTAssertEqual(outputs.count, 4)
        XCTAssertFalse(outputs.contains { $0.contains("Repeated call") }, "Repeats are counted per run: \(outputs)")
    }

    // MARK: Helpers

    private func loadedWebView(_ html: String) async -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://agent-loop.fixture/")!)
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
