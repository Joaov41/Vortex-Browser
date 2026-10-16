import XCTest
import WebKit
@testable import Browser

/// "Extract the dates", then "now create the PDF": the second request must find the first one's data.
@MainActor
final class AgentFollowUpDataTests: XCTestCase {
    @MainActor
    private final class ScriptedEngine: BrowserAgentEngine {
        typealias Body = @MainActor (
            BrowserAgentEngineRequest,
            @escaping BrowserAgentToolExecutor,
            @escaping BrowserAgentNoteHandler
        ) async throws -> String
        let profile: BrowserAgentEngineProfile = .chatGPTPlan(supportsVision: false)
        private let body: Body

        init(body: @escaping Body) { self.body = body }

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

    private struct Harness {
        let scratch: URL
        let defaults: UserDefaults
        let suiteName: String
        let webView: WKWebView
        let adapter: BrowserAgentBrowserAdapter

        func cleanup() {
            adapter.endRun()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    private static let concertPage = """
    <main><h1>Tour dates</h1><table><caption>Concert dates</caption>
    <tr><th>Date</th><th>City</th></tr>
    <tr><td>12 Nov</td><td>Lisbon</td></tr>
    <tr><td>15 Nov</td><td>Porto</td></tr>
    </table></main>
    """

    private func makeHarness(isPrivate: Bool = false) async throws -> Harness {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let suiteName = "AgentFollowUpDataTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let url = try XCTUnwrap(URL(string: "https://tour.fixture/dates"))
        let tab = BrowserTab(title: "Tour dates", url: url, isIncognito: isPrivate)
        let viewModel = BrowserViewModel(
            userDefaults: defaults,
            thumbnailDirectory: scratch.appendingPathComponent("thumbs", isDirectory: true)
        )
        viewModel.tabs = [tab]
        viewModel.selectedTabID = tab.id
        let webView = tab.activateWebView()
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(Self.concertPage, baseURL: url)
        }
        webView.navigationDelegate = nil
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            onTabSelected: { _ in },
            historyStore: HistoryStore(directory: scratch.appendingPathComponent("history", isDirectory: true))
        )
        return Harness(scratch: scratch, defaults: defaults, suiteName: suiteName, webView: webView, adapter: adapter)
    }

    private func datasetID(in text: String) -> String? {
        guard let range = text.range(
            of: #"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"#,
            options: .regularExpression
        ) else { return nil }
        return String(text[range])
    }

    /// Runs the extract request, then the follow-up, and returns what the follow-up saw.
    private func runExtractThenFollowUp(
        harness: Harness,
        followUpConversation: String?,
        startingTabIsPrivate: Bool = false
    ) async throws -> (extracted: String, followUpPrompt: String, followUpTools: Set<String>, exportOutput: String) {
        var extractedOutput = ""
        var followUpPrompt = ""
        var followUpTools: Set<String> = []
        var exportOutput = ""
        var runIndex = 0
        let extractEngine = ScriptedEngine { _, execute, _ in
            extractedOutput = (await execute("extract_html_tables", "{}")).text
            return "Found 2 concert dates."
        }
        let followUpEngine = ScriptedEngine { request, execute, _ in
            followUpPrompt = request.initialPrompt
            followUpTools = Set(request.tools.compactMap { $0["name"] as? String })
            let id = self.datasetID(in: request.initialPrompt.components(separatedBy: "<page_snapshot>").first ?? "") ?? UUID().uuidString
            exportOutput = (await execute("export_dataset_pdf", #"{"dataset_ids":["\#(id)"]}"#)).text
            return "Created the PDF."
        }
        let controller = BrowserAgentController(engineFactory: { _ in
            defer { runIndex += 1 }
            return runIndex == 0 ? extractEngine : followUpEngine
        })
        defer { controller.stop() }

        var first = ""
        controller.start(
            task: "Extract the concert dates",
            conversation: nil,
            in: harness.webView,
            openTab: nil,
            browserAdapter: harness.adapter,
            startingTabIsPrivate: startingTabIsPrivate
        ) { first = $0 }
        let firstDone = await waitUntil { !controller.isRunning && !first.isEmpty }
        XCTAssertTrue(firstDone, "first=\(first)")

        var second = ""
        controller.start(
            task: "Now create the PDF",
            conversation: followUpConversation,
            in: harness.webView,
            openTab: nil,
            browserAdapter: harness.adapter,
            startingTabIsPrivate: startingTabIsPrivate
        ) { second = $0 }
        let secondDone = await waitUntil { !controller.isRunning && !second.isEmpty }
        XCTAssertTrue(secondDone, "second=\(second)")
        return (extractedOutput, followUpPrompt, followUpTools, exportOutput)
    }

    func testFollowUpCanExportDataTheEarlierRequestExtracted() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let result = try await runExtractThenFollowUp(
            harness: harness,
            followUpConversation: "User: Extract the concert dates\nAssistant: Found 2 concert dates."
        )
        let extractedID = try XCTUnwrap(datasetID(in: result.extracted), result.extracted)
        XCTAssertTrue(result.followUpPrompt.contains("<previous_request_data>"), result.followUpPrompt)
        XCTAssertTrue(result.followUpPrompt.contains(extractedID), "The follow-up must be told the earlier dataset ID.")
        XCTAssertTrue(result.followUpTools.contains("export_dataset_pdf"), "Export tools must be offered: \(result.followUpTools.sorted())")
        XCTAssertTrue(result.exportOutput.hasPrefix("Export "), "The PDF export must succeed: \(result.exportOutput)")
    }

    func testFollowUpCanExportAWrittenAnswerAsPDF() async throws {
        // On device the first run listed the dates in its answer instead of extracting the table.
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        var followUpPrompt = ""
        var exportOutput = ""
        var runIndex = 0
        let answerEngine = ScriptedEngine { _, _, _ in
            "The page lists these concert dates:\n- 12 Nov — Lisbon\n- 15 Nov — Porto"
        }
        let followUpEngine = ScriptedEngine { request, execute, _ in
            followUpPrompt = request.initialPrompt
            let id = self.datasetID(in: request.initialPrompt.components(separatedBy: "<page_snapshot>").first ?? "") ?? UUID().uuidString
            exportOutput = (await execute("export_dataset_pdf", #"{"dataset_ids":["\#(id)"]}"#)).text
            return "Created the PDF."
        }
        let controller = BrowserAgentController(engineFactory: { _ in
            defer { runIndex += 1 }
            return runIndex == 0 ? answerEngine : followUpEngine
        })
        defer { controller.stop() }
        var first = ""
        controller.start(task: "Extract the concert dates on this page", conversation: nil, in: harness.webView, openTab: nil, browserAdapter: harness.adapter) { first = $0 }
        _ = await waitUntil { !controller.isRunning && !first.isEmpty }
        var second = ""
        controller.start(
            task: "Now create the PDF",
            conversation: "User: Extract the concert dates on this page\nAssistant: \(first)",
            in: harness.webView,
            openTab: nil,
            browserAdapter: harness.adapter
        ) { second = $0 }
        _ = await waitUntil { !controller.isRunning && !second.isEmpty }
        XCTAssertTrue(followUpPrompt.contains("your previous answer as text"), followUpPrompt)
        XCTAssertTrue(exportOutput.hasPrefix("Export "), "The written answer must be exportable: \(exportOutput)")
    }

    func testANewChatStartsWithoutTheEarlierData() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let result = try await runExtractThenFollowUp(harness: harness, followUpConversation: nil)
        XCTAssertFalse(result.followUpPrompt.contains("<previous_request_data>"))
        XCTAssertFalse(result.exportOutput.hasPrefix("Export "), result.exportOutput)
    }

    func testPrivateRunsNeitherKeepNorReceiveData() async throws {
        let harness = try await makeHarness(isPrivate: true)
        defer { harness.cleanup() }
        let result = try await runExtractThenFollowUp(
            harness: harness,
            followUpConversation: "User: Extract the concert dates\nAssistant: Found 2 concert dates.",
            startingTabIsPrivate: true
        )
        XCTAssertFalse(result.followUpPrompt.contains("<previous_request_data>"), "Private data never carries over.")
        XCTAssertFalse(result.exportOutput.hasPrefix("Export "), result.exportOutput)
    }

    func testKeptDataExpiresAndIsUsedOnce() throws {
        let controller = BrowserAgentController()
        let store = WKWebsiteDataStore.default()
        let dataset = BrowserAgentDataset(
            id: UUID(), kind: .links, title: "Links", pageTitle: "Page", sourceURL: "https://a.fixture/",
            sourceTabID: UUID(), capturedAt: "now", wasTruncated: false, truncationReasons: [],
            links: [], tables: [], fetchedText: nil
        )
        controller.datasets = [dataset.id: dataset]
        controller.datasetOrder = [dataset.id]
        let kept = Date(timeIntervalSinceReferenceDate: 1_000)
        controller.keepRunDataForFollowUp(isPrivate: false, dataStore: store, now: kept)
        controller.datasets = [:]
        controller.datasetOrder = []

        controller.restoreKeptRunData(
            hasEarlierConversation: true, isPrivate: false, dataStore: store,
            now: kept.addingTimeInterval(BrowserAgentController.keptRunDataLifetime + 1)
        )
        XCTAssertTrue(controller.datasetOrder.isEmpty, "Data older than 30 minutes is dropped.")
        XCTAssertNil(controller.keptRunData)

        controller.datasets = [dataset.id: dataset]
        controller.datasetOrder = [dataset.id]
        controller.keepRunDataForFollowUp(isPrivate: false, dataStore: store, now: kept)
        controller.datasets = [:]
        controller.datasetOrder = []
        controller.restoreKeptRunData(hasEarlierConversation: true, isPrivate: false, dataStore: WKWebsiteDataStore.nonPersistent(), now: kept)
        XCTAssertTrue(controller.datasetOrder.isEmpty, "A different data store never receives the data.")
        XCTAssertNil(controller.keptRunData, "Kept data is offered once.")
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
