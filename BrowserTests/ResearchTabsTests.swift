import Foundation
import WebKit
import XCTest
@testable import Browser

/// Research-in-tabs: the open_sources_in_group tool and the Research a Topic task builder.
/// Uses the adapter and the scripted engine seams from BrowserAgentLoopTests. No test needs the network;
/// the source hosts use the reserved .invalid domain.
@MainActor
final class ResearchTabsTests: XCTestCase {
    @MainActor
    private final class ToolCallEngine: BrowserAgentEngine {
        let profile = BrowserAgentEngineProfile.chatGPTPlan(supportsVision: false)
        private let arguments: String
        var output = ""

        init(arguments: String) {
            self.arguments = arguments
        }

        func prepare() async throws {}

        func run(
            request: BrowserAgentEngineRequest,
            execute: @escaping BrowserAgentToolExecutor,
            onNote: @escaping BrowserAgentNoteHandler
        ) async throws -> String {
            output = (await execute("open_sources_in_group", arguments)).text
            return "Sources handled."
        }
    }

    private struct OpenSourcesRun {
        let output: String
        let finished: Bool
        let viewModel: BrowserViewModel
        let source: BrowserTab
        let selectedTabIDs: [UUID]
        let confirmationRequested: Bool
    }

    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            continuation?.resume()
            continuation = nil
        }
    }

    private let validSources = ["https://sources.invalid/a", "https://sources.invalid/b"]

    // MARK: Argument validation

    func testSourceGroupTitleIsTrimmedAndBoundedToSixtyCharacters() throws {
        XCTAssertEqual(try parseSourceGroup(title: "  Lisbon  ").groupTitle, "Lisbon")
        XCTAssertEqual(try parseSourceGroup(title: String(repeating: "a", count: 60)).groupTitle.count, 60)
        XCTAssertThrowsError(try parseSourceGroup(title: ""))
        XCTAssertThrowsError(try parseSourceGroup(title: "   "))
        XCTAssertThrowsError(try parseSourceGroup(title: String(repeating: "a", count: 61)))
        XCTAssertThrowsError(try parseSourceGroup(title: "Two\nlines"), "Titles must stay on one line.")
    }

    func testSourceURLsAreRequiredAndCappedAtEight() throws {
        XCTAssertThrowsError(try parseSourceGroup(urls: []), "Zero URLs must be refused.")
        XCTAssertThrowsError(try parseSourceGroup(urls: (1...9).map { "https://sources.invalid/\($0)" }), "Nine URLs must be refused.")
        XCTAssertEqual(try parseSourceGroup(urls: (1...8).map { "https://sources.invalid/\($0)" }).urls.count, 8)
        XCTAssertThrowsError(try BrowserAgentController.SourceGroupRequest.parse(["groupTitle": "Lisbon"]), "urls is required.")
    }

    func testSourceURLsMustBeHTTPWithoutCredentials() throws {
        let invalid = [
            "javascript:alert(1)",
            "file:///etc/hosts",
            "ftp://sources.invalid/a",
            "sources.invalid/a",
            "https://user:secret@sources.invalid/a",
            "https://user@sources.invalid/a",
            "https:///no-host",
            "   "
        ]
        for url in invalid {
            XCTAssertThrowsError(try parseSourceGroup(urls: [url]), "\(url) must be refused.")
        }
        XCTAssertThrowsError(try parseSourceGroup(urls: [42]), "Entries must be strings.")
        XCTAssertThrowsError(
            try parseSourceGroup(urls: ["https://sources.invalid/a", "file:///etc/hosts"]),
            "One invalid URL rejects the whole call."
        )
        XCTAssertEqual(
            try parseSourceGroup(urls: ["  https://sources.invalid/a  "]).urls.map(\.absoluteString),
            ["https://sources.invalid/a"]
        )
    }

    func testRepeatedSourceURLsOpenOnce() throws {
        let request = try parseSourceGroup(urls: ["https://sources.invalid/a", "https://sources.invalid/a", "https://sources.invalid/b"])
        XCTAssertEqual(request.urls.map(\.absoluteString), ["https://sources.invalid/a", "https://sources.invalid/b"])
    }

    // MARK: Tool catalog

    func testOpenSourcesInGroupIsOfferedOnlyWithTheResearchBundle() throws {
        let name = "open_sources_in_group"
        XCTAssertTrue(BrowserAgentController.researchToolNames.contains(name))
        XCTAssertFalse(BrowserAgentController.browserToolNames.contains(name))
        XCTAssertFalse(BrowserAgentController.browserBundleToolNames.contains(name))
        XCTAssertFalse(BrowserAgentController.dataToolNames.contains(name))
        XCTAssertFalse(BrowserAgentController.coreToolNames.contains(name))

        let research = try toolNames(BrowserAgentController.toolsForRun(task: "Research Lisbon coffee shops", browserAdapterAvailable: true))
        XCTAssertTrue(research.contains(name))

        let openSources = try toolNames(BrowserAgentController.toolsForRun(
            task: "Research these sources online and open them in tabs",
            browserAdapterAvailable: true
        ))
        XCTAssertTrue(openSources.contains(name))

        let data = try toolNames(BrowserAgentController.toolsForRun(task: "Extract the tables and export CSV", browserAdapterAvailable: true))
        XCTAssertFalse(data.contains(name))

        let clicks = try toolNames(BrowserAgentController.toolsForRun(task: "Click the blue button", browserAdapterAvailable: true))
        XCTAssertFalse(clicks.contains(name))

        let withoutAdapter = try toolNames(BrowserAgentController.toolsForRun(task: "Research Lisbon coffee shops", browserAdapterAvailable: false))
        XCTAssertFalse(withoutAdapter.contains(name), "Tab groups need the browser adapter.")

        let coreOnly = try toolNames(BrowserAgentController.toolsForRun(
            task: "Research Lisbon coffee shops",
            browserAdapterAvailable: true,
            coreOnly: true
        ))
        XCTAssertFalse(coreOnly.contains(name), "On-device core-only runs never receive research tools.")
    }

    func testOpenSourcesInGroupSchemaRequiresGroupTitleAndURLs() throws {
        let definition = try XCTUnwrap(BrowserAgentController.tools.first { $0["name"] as? String == "open_sources_in_group" })
        let parameters = try XCTUnwrap(definition["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["groupTitle", "urls"])
        XCTAssertEqual(Set(try XCTUnwrap(parameters["required"] as? [String])), ["groupTitle", "urls"])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)

        let title = try XCTUnwrap(properties["groupTitle"] as? [String: Any])
        XCTAssertEqual(title["type"] as? String, "string")

        let urls = try XCTUnwrap(properties["urls"] as? [String: Any])
        XCTAssertEqual(urls["type"] as? String, "array")
        XCTAssertEqual(urls["minItems"] as? Int, 1)
        XCTAssertEqual(urls["maxItems"] as? Int, 8)
        XCTAssertEqual((urls["items"] as? [String: Any])?["type"] as? String, "string")
    }

    func testFoundationEngineSchemaAcceptsTheSourceGroupTool() throws {
        let definition = try XCTUnwrap(BrowserAgentController.tools.first { $0["name"] as? String == "open_sources_in_group" })
        XCTAssertNoThrow(try BrowserAgentFoundationSchemaAdapter.schema(for: definition))
    }

    func testResearchInstructionsTellTheModelWhenToOpenSources() {
        XCTAssertTrue(BrowserAgentController.researchInstructions.contains("open_sources_in_group"))
    }

    // MARK: Running the tool

    func testSourcesOpenAsBackgroundTabsInAnExistingGroupWithTheSameTitle() async throws {
        var existingGroupID: UUID?
        let run = try await runOpenSourcesTool(
            arguments: sourceArgumentsJSON(title: "Lisbon", urls: validSources),
            prepare: { viewModel in
                existingGroupID = viewModel.createTabGroup(title: "Lisbon").id
                viewModel.createTabGroup(title: "Lisbon trip")
            }
        )

        XCTAssertTrue(run.finished, run.output)
        XCTAssertTrue(run.output.contains("Opened 2 source tabs"), run.output)
        let groupID = try XCTUnwrap(existingGroupID)
        XCTAssertEqual(run.viewModel.tabGroups.count, 2, "The exact title must reuse the existing group.")

        let opened = run.viewModel.tabs.filter { $0.id != run.source.id }
        XCTAssertEqual(opened.count, 2)
        XCTAssertTrue(opened.allSatisfy { $0.groupID == groupID })
        XCTAssertFalse(opened.contains { $0.isIncognito })
        XCTAssertEqual(opened.compactMap { $0.url?.absoluteString }, validSources)

        XCTAssertEqual(run.viewModel.selectedTabID, run.source.id, "The agent's tab must stay selected.")
        XCTAssertTrue(run.selectedTabIDs.isEmpty, "Background tabs must never be selected through the adapter.")
        XCTAssertFalse(run.confirmationRequested, "Opening pages needs no approval.")
    }

    func testSourcesCreateANewGroupWhenTheTitleDiffersInCase() async throws {
        let run = try await runOpenSourcesTool(
            arguments: sourceArgumentsJSON(title: "lisbon", urls: ["https://sources.invalid/a"]),
            prepare: { viewModel in
                viewModel.createTabGroup(title: "Lisbon")
            }
        )

        XCTAssertTrue(run.finished, run.output)
        XCTAssertEqual(run.viewModel.tabGroups.map(\.title), ["Lisbon", "lisbon"], "Only an exact title is reused.")
        let newGroup = try XCTUnwrap(run.viewModel.tabGroups.first { $0.title == "lisbon" })
        let opened = run.viewModel.tabs.first { $0.id != run.source.id }
        XCTAssertEqual(opened?.groupID, newGroup.id)
        XCTAssertEqual(run.viewModel.selectedTabID, run.source.id)
    }

    func testPrivateRunsRefuseSourceTabsWithoutCreatingGroupsOrTabs() async throws {
        let run = try await runOpenSourcesTool(
            arguments: sourceArgumentsJSON(title: "Lisbon", urls: validSources),
            isPrivate: true
        )

        XCTAssertTrue(run.finished, run.output)
        XCTAssertTrue(run.output.hasPrefix("Error:"), run.output)
        XCTAssertTrue(run.output.contains("private browsing"), run.output)
        XCTAssertEqual(run.viewModel.tabs.count, 1, "A refused private run must not open tabs.")
        XCTAssertTrue(run.viewModel.tabGroups.isEmpty, "A refused private run must not create a group.")
    }

    func testAdapterRefusesGroupsAndBackgroundTabsForPrivateRuns() throws {
        let suite = "ResearchTabs.adapter.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: scratch)
        }
        let viewModel = BrowserViewModel(userDefaults: defaults, thumbnailDirectory: scratch.appendingPathComponent("thumbs", isDirectory: true))
        let privateTab = BrowserTab(title: "Private", url: URL(string: "https://private.example/"), isIncognito: true)
        viewModel.tabs = [privateTab]
        viewModel.selectedTabID = privateTab.id
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            onTabSelected: { _ in }
        )

        XCTAssertTrue(adapter.beginRun(in: privateTab.activateWebView()))
        XCTAssertThrowsError(try adapter.sourceGroup(title: "Lisbon"))
        XCTAssertThrowsError(try adapter.openBackgroundTab(url: URL(string: "https://sources.invalid/a")!, groupID: UUID()))
        XCTAssertEqual(viewModel.tabs.count, 1)
        XCTAssertTrue(viewModel.tabGroups.isEmpty)
    }

    // MARK: Research a Topic task text

    func testTaskTextCoversEveryFlagCombination() throws {
        let topic = "Lisbon coffee shops"
        XCTAssertEqual(
            try ResearchTopicTaskBuilder.taskText(topic: topic, openSourcesInTabs: false, makePDF: false),
            "Research Lisbon coffee shops. Compare the most relevant sources."
        )
        XCTAssertEqual(
            try ResearchTopicTaskBuilder.taskText(topic: topic, openSourcesInTabs: true, makePDF: false),
            "Research Lisbon coffee shops. Compare the most relevant sources, open them in a tab group named Lisbon coffee shops."
        )
        XCTAssertEqual(
            try ResearchTopicTaskBuilder.taskText(topic: topic, openSourcesInTabs: false, makePDF: true),
            "Research Lisbon coffee shops. Compare the most relevant sources, and export a PDF report."
        )
        XCTAssertEqual(
            try ResearchTopicTaskBuilder.taskText(topic: topic, openSourcesInTabs: true, makePDF: true),
            "Research Lisbon coffee shops. Compare the most relevant sources, open them in a tab group named Lisbon coffee shops, and export a PDF report."
        )
    }

    func testTopicNewlinesAndControlCharactersBecomeSpaces() throws {
        let text = try ResearchTopicTaskBuilder.taskText(
            topic: "Line one\nLine two\r\n\tLine three\u{0}",
            openSourcesInTabs: true,
            makePDF: false
        )
        XCTAssertEqual(
            text,
            "Research Line one Line two Line three. Compare the most relevant sources, open them in a tab group named Line one Line two Line three."
        )
        XCTAssertFalse(text.contains("\n"))
        XCTAssertFalse(text.contains("\r"))
    }

    func testTopicIsBoundedAndTheGroupNameStaysWithinTheToolLimit() throws {
        let long = String(repeating: "abcde ", count: 60)
        let topic = ResearchTopicTaskBuilder.normalizedTopic(long)
        XCTAssertEqual(topic.count, 200)

        let groupName = String(topic.prefix(60)).trimmingCharacters(in: .whitespaces)
        XCTAssertLessThanOrEqual(groupName.count, 60)
        let text = try ResearchTopicTaskBuilder.taskText(topic: long, openSourcesInTabs: true, makePDF: true)
        XCTAssertEqual(
            text,
            "Research \(topic). Compare the most relevant sources, open them in a tab group named \(groupName), and export a PDF report."
        )
    }

    func testEmptyTopicIsRejected() {
        for raw in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(try ResearchTopicTaskBuilder.taskText(topic: raw, openSourcesInTabs: true, makePDF: true), "'\(raw)' must be refused.")
        }
    }

    // MARK: Helpers

    private func parseSourceGroup(
        title: String = "Lisbon",
        urls: [Any] = ["https://sources.invalid/a"]
    ) throws -> BrowserAgentController.SourceGroupRequest {
        try BrowserAgentController.SourceGroupRequest.parse(["groupTitle": title, "urls": urls])
    }

    private func sourceArgumentsJSON(title: String, urls: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["groupTitle": title, "urls": urls]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func toolNames(_ tools: [[String: Any]]) throws -> Set<String> {
        Set(try tools.map { try XCTUnwrap($0["name"] as? String) })
    }

    private func runOpenSourcesTool(
        arguments: String,
        isPrivate: Bool = false,
        prepare: (BrowserViewModel) -> Void = { _ in }
    ) async throws -> OpenSourcesRun {
        let suite = "ResearchTabs.run.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: scratch)
        }

        let viewModel = BrowserViewModel(
            userDefaults: defaults,
            thumbnailDirectory: scratch.appendingPathComponent("thumbs", isDirectory: true)
        )
        let source = BrowserTab(
            title: "Research source",
            url: URL(string: "https://research-tabs.fixture/source"),
            isIncognito: isPrivate
        )
        viewModel.tabs = [source]
        viewModel.selectedTabID = source.id
        prepare(viewModel)
        let webView = source.activateWebView()
        await loadHTML("<main>Research tab fixture</main>", into: webView, baseURL: URL(string: "https://research-tabs.fixture/")!)

        var selectedTabIDs: [UUID] = []
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            onTabSelected: { selectedTabIDs.append($0) }
        )
        let engine = ToolCallEngine(arguments: arguments)
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var summary = ""
        controller.start(
            task: "Research Lisbon coffee shops and open the sources in tabs",
            preset: .research,
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter
        ) { summary = $0 }
        let finished = await waitUntil { !controller.isRunning && !summary.isEmpty }
        return OpenSourcesRun(
            output: engine.output,
            finished: finished,
            viewModel: viewModel,
            source: source,
            selectedTabIDs: selectedTabIDs,
            confirmationRequested: controller.pendingConfirmation != nil
        )
    }

    private func loadHTML(_ html: String, into webView: WKWebView, baseURL: URL) async {
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        webView.navigationDelegate = nil
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<800 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
