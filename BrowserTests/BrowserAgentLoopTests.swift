import CryptoKit
import Network
import PDFKit
import XCTest
import WebKit
@testable import Browser

private nonisolated final class BrowserAgentHTTPFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BrowserAgentHTTPFixture")
    private var listener: NWListener?
    private var port: UInt16 = 0

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        queue.sync { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = BrowserAgentFixtureResumeOnce()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, port > 0 else {
                        listener.cancel()
                        if once.claim() { continuation.resume(throwing: URLError(.cannotCreateFile)) }
                        return
                    }
                    self?.port = port
                    if once.claim() { continuation.resume(returning: port) }
                case .failed(let error):
                    listener.cancel()
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: URLError(.cancelled)) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        let listenerToCancel = queue.sync { () -> NWListener? in
            defer { listener = nil }
            return listener
        }
        listenerToCancel?.cancel()
    }

    static func url(port: UInt16, path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    static func url(host: String, port: UInt16, path: String) -> URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound), on: connection)
            } else if isComplete || error != nil || buffer.count > 32_768 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let requestLine = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1].split(separator: "?", maxSplits: 1).first ?? "") : ""
        switch path {
        case "/redirect":
            send(status: "302 Found", headers: ["Location": "http://127.0.0.1:\(port)/page"], body: "", on: connection)
        case "/redirect-to-protected":
            send(status: "302 Found", headers: ["Location": "http://127.0.0.1:\(port)/page"], body: "", on: connection)
        case "/attachment":
            send(
                status: "200 OK",
                headers: ["Content-Type": "text/html; charset=utf-8", "Content-Disposition": "attachment; filename=fixture.html"],
                body: "<main>attachment sentinel</main>",
                on: connection
            )
        case "/empty":
            send(
                status: "200 OK",
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: "<!doctype html><html><head><title>Empty</title></head><body><main>  </main></body></html>",
                on: connection
            )
        case "/page":
            let html = """
            <!doctype html><html><head><title>Loopback source</title></head><body>
            <main><h1>Local HTTP content</h1><p>Readable loopback fixture</p></main>
            <iframe src="file:///etc/passwd"></iframe>
            <script>window.open('/popup')</script>
            </body></html>
            """
            send(status: "200 OK", headers: ["Content-Type": "text/html; charset=utf-8"], body: html, on: connection)
        default:
            send(status: "404 Not Found", headers: ["Content-Type": "text/plain; charset=utf-8"], body: "Not found", on: connection)
        }
    }

    private func send(status: String, headers: [String: String], body: String, on connection: NWConnection) {
        let extraHeaders = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        let response = "HTTP/1.1 \(status)\r\n\(extraHeaders)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private nonisolated final class BrowserAgentFixtureResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return false }
        resolved = true
        return true
    }
}

@MainActor
final class BrowserAgentLoopTests: XCTestCase {
    @MainActor
    private final class ScriptedEngine: BrowserAgentEngine {
        typealias Body = @MainActor (
            BrowserAgentEngineRequest,
            @escaping BrowserAgentToolExecutor,
            @escaping BrowserAgentNoteHandler
        ) async throws -> String
        let profile: BrowserAgentEngineProfile
        private let body: Body

        init(
            profile: BrowserAgentEngineProfile? = nil,
            body: @escaping Body
        ) {
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

    @MainActor
    private final class SourceMessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
    }

    @MainActor
    private final class LoopProfileStore: AutofillProfileStore {
        var profile: AutofillProfile?
        var loadCount = 0
        var saveCount = 0
        var deleteCount = 0
        func load() throws -> AutofillProfile? { loadCount += 1; return profile }
        func save(_ profile: AutofillProfile) throws { saveCount += 1; self.profile = profile }
        func delete() throws { deleteCount += 1; profile = nil }
    }

    private final class LoopToolOutput {
        var value = ""
    }

    @MainActor
    private struct AutofillApprovalHarness {
        let scratch: URL
        let defaults: UserDefaults
        let suiteName: String
        let tab: BrowserTab
        let webView: WKWebView
        let adapter: BrowserAgentBrowserAdapter
        let store: LoopProfileStore
        let authenticator: LoopAuthenticator
        let privacy: BrowserAgentAutofillPrivacy
        let controller: BrowserAgentController
        let output: LoopToolOutput

        func cleanup() {
            controller.stop()
            adapter.endRun()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    private func makeAutofillApprovalHarness(path: String) async throws -> AutofillApprovalHarness {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let suiteName = "BrowserAgentLoop.autofill-approval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let url = try XCTUnwrap(URL(string: "https://autofill-approval.fixture/\(path)"))
        let tab = BrowserTab(title: "Contact", url: url)
        let viewModel = BrowserViewModel(
            userDefaults: defaults,
            thumbnailDirectory: scratch.appendingPathComponent("thumbs", isDirectory: true)
        )
        viewModel.tabs = [tab]
        viewModel.selectedTabID = tab.id
        let webView = tab.activateWebView()
        await loadHTML(
            #"<script>window.inputEvents=0;window.submitEvents=0;</script>"#
                + #"<form id="contact" method="post" action="/contact"><label for="name">Given name</label>"#
                + #"<input id="name" name="given_name" autocomplete="given-name" oninput="window.inputEvents++">"#
                + #"<button type="submit">Save</button></form>"#
                + #"<script>document.getElementById("contact").addEventListener("submit",function(event){"#
                + #"event.preventDefault();window.submitEvents++});</script>"#,
            into: webView,
            baseURL: url
        )
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            onTabSelected: { _ in },
            historyStore: HistoryStore(directory: scratch.appendingPathComponent("history", isDirectory: true))
        )
        let store = LoopProfileStore()
        store.profile = AutofillProfile(givenName: "Synthetic Approval Name")
        let authenticator = LoopAuthenticator()
        let privacy = BrowserAgentAutofillPrivacy()
        let output = LoopToolOutput()
        let engine = ScriptedEngine { _, execute, _ in
            output.value = (await execute("fill_form", "{}")).text
            return "Autofill approval fixture finished."
        }
        let controller = BrowserAgentController(
            engineFactory: { _ in engine },
            autofillProfileService: AutofillProfileService(store: store, authenticator: authenticator),
            autofillPrivacy: privacy
        )
        controller.start(
            task: "Fill my contact form from the saved profile",
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter
        ) { _ in }
        return AutofillApprovalHarness(
            scratch: scratch,
            defaults: defaults,
            suiteName: suiteName,
            tab: tab,
            webView: webView,
            adapter: adapter,
            store: store,
            authenticator: authenticator,
            privacy: privacy,
            controller: controller,
            output: output
        )
    }

    @MainActor
    private final class LoopAuthenticator: AutofillProfileAuthenticator {
        var shouldSuspend = false
        var allowed = true
        var started = false
        var continuation: CheckedContinuation<Bool, Never>?

        func authenticate(reason: String) async -> Bool {
            started = true
            guard shouldSuspend else { return allowed }
            return await withCheckedContinuation { continuation = $0 }
        }

        func resume(_ result: Bool) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    func testToolBundlesKeepSimpleActionsSmallAndGateAdapterTools() throws {
        let allNames = try toolNames(BrowserAgentController.tools)
        XCTAssertTrue(allNames.contains("ask_user"))
        XCTAssertTrue(allNames.contains("fetch_page"))

        let clickTools = BrowserAgentController.toolsForRun(task: "Click the blue button", browserAdapterAvailable: true)
        let clickNames = try toolNames(clickTools)
        XCTAssertTrue(["click", "type_text", "read_page", "ask_user", "finish"].allSatisfy(clickNames.contains))
        XCTAssertLessThan(clickTools.count, allNames.count, "A simple page action should omit the optional data and research bundles.")
        XCTAssertTrue(["translate_page", "hover_element", "scroll_container", "find_page_text", "hide_element"].allSatisfy(clickNames.contains))
        XCTAssertFalse(clickNames.contains("extract_html_tables"))
        XCTAssertFalse(clickNames.contains("fetch_page"))
        let stableButtonNames = try toolNames(BrowserAgentController.toolsForRun(task: "Click the stable button", browserAdapterAvailable: true))
        XCTAssertFalse(stableButtonNames.contains("extract_html_tables"), "Data cues must match words, not substrings such as 'stable'.")

        let previouslySupportedActions = [
            ("Translate page to French", "translate_page"),
            ("Move over the menu", "hover_element"),
            ("Scroll this panel", "scroll_container"),
            ("Find the phrase on this page", "find_page_text"),
            ("Hide this banner", "hide_element")
        ]
        for (task, expectedTool) in previouslySupportedActions {
            let names = try toolNames(BrowserAgentController.toolsForRun(task: task, browserAdapterAvailable: true))
            XCTAssertTrue(names.contains(expectedTool), "\(task) must retain its existing browser tool.")
        }

        let tabTools = BrowserAgentController.toolsForRun(task: "Close the old tab", browserAdapterAvailable: true)
        let tabNames = try toolNames(tabTools)
        XCTAssertTrue(tabNames.contains("close_tab"))
        XCTAssertTrue(tabNames.contains("list_tabs"))
        XCTAssertFalse(tabNames.contains("extract_html_tables"))

        let comparePages = BrowserAgentController.toolsForRun(task: "Compare these two pages", browserAdapterAvailable: true)
        let compareNames = try toolNames(comparePages)
        XCTAssertTrue(compareNames.contains("switch_tab"))
        XCTAssertTrue(compareNames.contains("extract_html_tables"))

        let unavailable = BrowserAgentController.toolsForRun(task: "Close the old tab", browserAdapterAvailable: false)
        XCTAssertTrue(BrowserAgentController.browserToolNames.isDisjoint(with: try toolNames(unavailable)))
        XCTAssertTrue(try toolNames(unavailable).contains("click"))
    }

    func testDataAndResearchBundlesIncludeOnlyTheirRequestedTools() throws {
        let dataTools = BrowserAgentController.toolsForRun(task: "Extract the tables and export CSV", browserAdapterAvailable: true)
        let dataNames = try toolNames(dataTools)
        XCTAssertTrue(["extract_links", "extract_html_tables", "export_dataset_csv", "compose_comparison"].allSatisfy(dataNames.contains))
        XCTAssertTrue(dataNames.contains("list_tabs"), "The browser bundle remains available whenever the adapter is present.")
        XCTAssertFalse(dataNames.contains("fetch_page"))
        XCTAssertTrue(
            dataNames.contains("web_search"),
            "web_search is a browser tool and stays available whenever the adapter is present."
        )

        let linkData = BrowserAgentController.toolsForRun(task: "Show me all links from this page", browserAdapterAvailable: true)
        XCTAssertTrue(try toolNames(linkData).contains("extract_links"))

        let tableData = BrowserAgentController.toolsForRun(task: "Read every table on this page", browserAdapterAvailable: true)
        XCTAssertTrue(try toolNames(tableData).contains("extract_html_tables"))

        let research = BrowserAgentController.toolsForRun(task: "Research this and fetch a source online", browserAdapterAvailable: true)
        let researchNames = try toolNames(research)
        XCTAssertTrue(researchNames.contains("fetch_page"))
        XCTAssertTrue(researchNames.contains("web_search"))
        XCTAssertFalse(researchNames.contains("extract_html_tables"))

        let webSearchNames = try toolNames(BrowserAgentController.toolsForRun(task: "Search the web for current product reviews", browserAdapterAvailable: true))
        XCTAssertTrue(webSearchNames.contains("fetch_page"))
        XCTAssertTrue(webSearchNames.contains("web_search"))

        let pageSearchNames = try toolNames(BrowserAgentController.toolsForRun(task: "Search this page for reviews", browserAdapterAvailable: true))
        XCTAssertFalse(pageSearchNames.contains("fetch_page"))
        XCTAssertTrue(
            pageSearchNames.contains("web_search"),
            "Page-local search cues still keep the always-available browser web_search tool."
        )

        for task in [
            "Look up the current price online",
            "Find current coverage on the web",
            "Fetch the page at https://example.com"
        ] {
            let names = try toolNames(BrowserAgentController.toolsForRun(task: task, browserAdapterAvailable: true))
            XCTAssertTrue(names.contains("fetch_page"), "\(task) should include fetch_page.")
            XCTAssertTrue(names.contains("web_search"), "\(task) should include web_search.")
            XCTAssertFalse(names.contains("extract_html_tables"))
        }

        let researchAndData = BrowserAgentController.toolsForRun(
            task: "Research these sources online and save a comparison CSV",
            browserAdapterAvailable: true
        )
        let researchAndDataNames = try toolNames(researchAndData)
        XCTAssertTrue(
            ["web_search", "fetch_page", "extract_html_tables", "compose_comparison", "export_comparison_csv"].allSatisfy(researchAndDataNames.contains),
            "A research task that requests an export must receive both the research and data bundles."
        )

        let researchWithoutAdapter = BrowserAgentController.toolsForRun(task: "Research this and fetch a source online", browserAdapterAvailable: false)
        let researchWithoutAdapterNames = try toolNames(researchWithoutAdapter)
        XCTAssertTrue(researchWithoutAdapterNames.contains("fetch_page"))
        XCTAssertFalse(researchWithoutAdapterNames.contains("web_search"))

        let fetchUnavailable = BrowserAgentController.toolsForRun(
            task: "Research this online",
            browserAdapterAvailable: true,
            fetchPageAvailable: false
        )
        let fetchUnavailableNames = try toolNames(fetchUnavailable)
        XCTAssertFalse(fetchUnavailableNames.contains("fetch_page"))
        XCTAssertTrue(fetchUnavailableNames.contains("web_search"))

        let flightNames = try toolNames(BrowserAgentController.toolsForRun(
            task: "Find me cheap flights to Lisbon",
            browserAdapterAvailable: true
        ))
        XCTAssertTrue(flightNames.contains("web_search"), "web_search must be offered for any adapter-backed run.")

        let localSearchNames = BrowserAgentController.localCoreToolNames(
            forTask: "search for cheap flights",
            supportsVision: false
        )
        XCTAssertTrue(
            localSearchNames.contains("web_search"),
            "The local engine's core tools must expose web_search for search intents."
        )

        let coreOnlyNames = try toolNames(BrowserAgentController.toolsForRun(
            task: "search for cheap flights",
            browserAdapterAvailable: true,
            coreOnly: true
        ))
        XCTAssertTrue(
            coreOnlyNames.contains("web_search"),
            "web_search must survive the coreOnly path when the adapter is present."
        )

        let coreOnlyNoAdapterNames = try toolNames(BrowserAgentController.toolsForRun(
            task: "search for cheap flights",
            browserAdapterAvailable: false,
            coreOnly: true
        ))
        XCTAssertFalse(
            coreOnlyNoAdapterNames.contains("web_search"),
            "web_search remains unavailable without a browser adapter."
        )
    }

    func testEngineProfilesBoundToolBundlesAndExposeScreenshotOnlyWithVision() throws {
        let local = BrowserAgentController.toolsForRun(
            task: "Research and extract links",
            browserAdapterAvailable: true,
            coreOnly: true,
            supportsVision: false,
            readChunkCharacters: 1_200
        )
        let localNames = try toolNames(local)
        XCTAssertFalse(localNames.contains("list_tabs"))
        XCTAssertFalse(localNames.contains("extract_links"))
        XCTAssertFalse(localNames.contains("fetch_page"))
        XCTAssertFalse(localNames.contains("screenshot"))
        let readPage = try XCTUnwrap(local.first { $0["name"] as? String == "read_page" })
        XCTAssertTrue((readPage["description"] as? String)?.contains("1200 characters") == true)

        let visionTools = BrowserAgentController.toolsForRun(
            task: "Describe what is visible",
            browserAdapterAvailable: true,
            supportsVision: true
        )
        XCTAssertTrue(try toolNames(visionTools).contains("screenshot"))
        let textOnlyTools = BrowserAgentController.toolsForRun(
            task: "Describe what is visible",
            browserAdapterAvailable: true,
            supportsVision: false
        )
        XCTAssertFalse(try toolNames(textOnlyTools).contains("screenshot"))
    }

    func testLocalLookupTasksGainSearchAndPageActionTools() throws {
        func localNames(for task: String) throws -> Set<String> {
            try toolNames(BrowserAgentController.toolsForRun(
                task: task,
                browserAdapterAvailable: true,
                coreOnly: true,
                supportsVision: false,
                readChunkCharacters: 1_200
            ))
        }

        let findNames = try localNames(for: "find foo fighters next concert in the ua")
        XCTAssertTrue(
            ["web_search", "read_page", "click", "go_back"].allSatisfy(findNames.contains),
            "Lookup tasks must carry search plus the tools to open and read results: \(findNames)"
        )

        let searchNames = try localNames(for: "search for the next foo fighters coincert in the us")
        XCTAssertTrue(
            ["web_search", "read_page", "click", "go_back", "type_text"].allSatisfy(searchNames.contains),
            "A search-and-type task must keep typing plus result-navigation tools: \(searchNames)"
        )

        let whenNames = try localNames(for: "when is the next Foo Fighters concert in the US")
        XCTAssertTrue(
            ["web_search", "read_page", "click"].allSatisfy(whenNames.contains),
            "Question-form lookup tasks must reach the search toolkit: \(whenNames)"
        )

        let googleNames = try localNames(for: "google cheap flights")
        XCTAssertTrue(
            ["web_search", "read_page", "click", "go_back"].allSatisfy(googleNames.contains),
            "Engine-named lookups must keep result-navigation tools: \(googleNames)"
        )

        let clickNames = try localNames(for: "click the login button")
        XCTAssertFalse(clickNames.contains("web_search"), "Non-lookup tasks must not gain web_search: \(clickNames)")
    }

    func testNonLocalToolSetsUnchangedForLookupTasks() throws {
        let base: Set<String> = [
            "add_bookmark", "ask_user", "cancel_download", "clear_page_highlights", "click", "close_tab",
            "copy_to_clipboard", "create_bookmark_folder", "create_tab_group", "dismiss_overlays",
            "download_link", "download_url", "file_upload_status", "fill_form", "find_page_text", "finish",
            "go_back", "go_forward", "hide_element", "hover_element", "inspect", "list_bookmarks",
            "list_downloads", "list_extended_page_controls", "list_tab_groups", "list_tabs",
            "move_bookmark_to_folder", "move_tab_to_group", "navigate", "open_in_split", "open_tab",
            "page_translation_status", "press_key", "read_page", "reload", "remove_bookmark",
            "rename_tab_group", "request_file_upload", "scroll", "scroll_container",
            "scroll_element_into_view", "search_history", "select_option", "set_checked",
            "set_desktop_mode", "set_reader_mode", "set_slider_value", "show_original_page", "switch_tab",
            "synthetic_drag_drop", "translate_page", "type_text", "wait", "web_search"
        ]
        var withFetchPage = base
        // Research-bundle tools. open_sources_in_group joined this bundle in Phase 9.
        withFetchPage.formUnion(["fetch_page", "open_sources_in_group"])

        let recordedSets: [String: Set<String>] = [
            "find foo fighters next concert in the ua": base,
            "search for the next foo fighters coincert in the us": withFetchPage,
            "when is the next Foo Fighters concert in the US": base,
            "google cheap flights": base,
            "click the login button": base
        ]
        for (task, expected) in recordedSets {
            let names = try toolNames(BrowserAgentController.toolsForRun(
                task: task, browserAdapterAvailable: true
            ))
            XCTAssertEqual(names, expected, "Non-Local tool set changed for task: \(task)")
        }
    }

    func testLocalTaskAwareCoreSelectionKeepsRequestedActionsAndSmallTitleSet() throws {
        let localProfile = BrowserAgentEngineProfile.local(contextSize: 4_096, supportsVision: false)
        XCTAssertEqual(localProfile.toolPolicy, .coreOnly)
        XCTAssertEqual(localProfile.maxSteps, 20, "Local runs keep a bounded 20-step ceiling.")

        let titleNames = try toolNames(BrowserAgentController.toolsForRun(
            task: "Read the page title and finish",
            browserAdapterAvailable: true,
            coreOnly: true
        ))
        XCTAssertEqual(titleNames, ["read_page", "ask_user", "finish"])

        let requestedActions: [(String, String)] = [
            ("Click the button", "click"),
            ("Type a name in the field", "type_text"),
            ("Choose an option in the dropdown", "select_option"),
            ("Check the newsletter checkbox", "set_checked"),
            ("Scroll down", "scroll"),
            ("Visit https://example.invalid", "navigate"),
            ("Open a new tab", "open_tab"),
            ("Go back to the previous page", "go_back"),
            ("Go forward to the next page", "go_forward"),
            ("Reload the page", "reload"),
            ("Press Enter", "press_key"),
            ("Inspect the button attributes", "inspect"),
            ("Dismiss the cookie banner", "dismiss_overlays"),
            ("Copy this to the clipboard", "copy_to_clipboard"),
            ("Wait until the page loads", "wait")
        ]
        for (task, expectedTool) in requestedActions {
            let names = try toolNames(BrowserAgentController.toolsForRun(
                task: task,
                browserAdapterAvailable: true,
                coreOnly: true
            ))
            XCTAssertTrue(names.contains(expectedTool), "Local must retain \(expectedTool) when task requests it: \(task)")
            XCTAssertTrue(names.contains("ask_user"))
            XCTAssertTrue(names.contains("finish"))
        }

        let mixedIntentTasks: [(String, Set<String>)] = [
            ("Read the title then click the blue button", ["read_page", "click"]),
            ("Read the current title, type it into the search box, and reload", ["read_page", "type_text", "reload"])
        ]
        for (task, expectedTools) in mixedIntentTasks {
            let names = try toolNames(BrowserAgentController.toolsForRun(
                task: task,
                browserAdapterAvailable: true,
                coreOnly: true
            ))
            XCTAssertTrue(expectedTools.isSubset(of: names), "Local must retain every requested action for mixed task: \(task)")
        }

        let visualNames = try toolNames(BrowserAgentController.toolsForRun(
            task: "Describe the visual layout",
            browserAdapterAvailable: true,
            coreOnly: true,
            supportsVision: true
        ))
        XCTAssertTrue(visualNames.contains("screenshot"))
        let noVisionNames = try toolNames(BrowserAgentController.toolsForRun(
            task: "Describe the visual layout",
            browserAdapterAvailable: true,
            coreOnly: true,
            supportsVision: false
        ))
        XCTAssertFalse(noVisionNames.contains("screenshot"))
    }

    func testInjectedEngineCompletesWithSelectedBackendAndRunProfile() async throws {
        var capturedRequest: BrowserAgentEngineRequest?
        let profile = BrowserAgentEngineProfile.local(contextSize: 4_096, supportsVision: false)
        let engine = ScriptedEngine(profile: profile) { request, _, _ in
            capturedRequest = request
            return "Task completed by Local."
        }
        let controller = BrowserAgentController(engineFactory: { backend in
            XCTAssertEqual(backend, .localApple)
            return engine
        })
        defer { controller.stop() }
        let webView = await loadedWebView("<main>Engine fixture</main>")
        var summary = ""
        controller.start(
            task: "Summarize this page",
            conversation: String(repeating: "Earlier conversation. ", count: 200),
            in: webView,
            openTab: nil,
            backend: .localApple
        ) { summary = $0 }

        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        XCTAssertTrue(summary.contains("Task completed by Local."))
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.profile, profile)
        XCTAssertTrue(request.initialPrompt.count < 3_000, "Local recent conversation must be bounded before it enters the model context.")
        let names = try toolNames(request.tools)
        XCTAssertTrue(names.contains("click"))
        XCTAssertFalse(names.contains("list_tabs"))
        XCTAssertFalse(names.contains("fetch_page"))
    }

    func testLocalRequestCompactsAdversarialLabelsTaskAndConversationWithinContextBudget() async throws {
        let longLabel = String(repeating: "界", count: 180)
        let controls = (0..<40).map { index in
            "<button aria-label=\"control-\(index)-\(longLabel)\">Open</button>"
        }.joined()
        let webView = await loadedWebView("<main>\(controls)</main>")
        let profile = BrowserAgentEngineProfile.local(contextSize: 4_096, supportsVision: false)
        var capturedRequest: BrowserAgentEngineRequest?
        let engine = ScriptedEngine(profile: profile) { request, _, _ in
            capturedRequest = request
            return "Local context stayed bounded."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var summary = ""
        let taskLimit = BrowserAgentLocalContext.taskByteLimit(contextSize: profile.contextSize ?? 4_096)
        let finalConstraint = "Final constraint: never submit."
        let acceptedTask = String(repeating: "x", count: taskLimit - finalConstraint.utf8.count) + finalConstraint
        XCTAssertTrue(BrowserAgentLocalContext.taskFits(acceptedTask, contextSize: profile.contextSize ?? 4_096))
        let adversarialConversation = String(repeating: "🧵 Earlier discussion. ", count: 500)
        controller.start(
            task: acceptedTask,
            conversation: adversarialConversation,
            in: webView,
            openTab: nil,
            backend: .localApple
        ) { summary = $0 }

        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertLessThanOrEqual(
            request.initialPrompt.utf8.count,
            BrowserAgentLocalContext.initialPromptByteLimit(contextSize: profile.contextSize ?? 4_096)
        )
        XCTAssertLessThan(request.instructions.utf8.count, 1_200)
        XCTAssertTrue(request.instructions.contains("Never type passwords"))
        XCTAssertTrue(request.instructions.contains("Purchases, sending, posting, deleting"))
        XCTAssertTrue(request.instructions.contains("need user approval"))
        XCTAssertFalse(request.instructions.contains("extract_html_tables"))
        XCTAssertFalse(request.instructions.contains("fetch_page"))
        XCTAssertTrue(request.initialPrompt.contains("Task: \(acceptedTask)"), "The accepted task, including its final constraint, must remain exact.")
        XCTAssertTrue(acceptedTask.hasSuffix(finalConstraint))

        let snapshot = try XCTUnwrap(request.initialPrompt.components(separatedBy: "</page_snapshot>").first)
        let elementSection = snapshot.components(separatedBy: "Visible text (start):").first ?? ""
        let represented = elementSection.components(separatedBy: "\n").filter {
            $0.range(of: #"^\[\d+\] "#, options: .regularExpression) != nil
        }
        XCTAssertFalse(represented.isEmpty, "At least one complete page-control line should survive compaction.")
        for line in represented {
            XCTAssertNotNil(line.range(of: #"^\[\d+\] "#, options: .regularExpression), line)
            XCTAssertTrue(
                line.hasSuffix("\"") || line.hasSuffix("\" (offscreen)"),
                "A retained element must be a whole line, never a truncated ID or label: \(line)"
            )
        }
    }

    func testOversizedLocalTaskIsRejectedBeforeEngineOrPageActions() async throws {
        let profile = BrowserAgentEngineProfile.local(contextSize: 4_096, supportsVision: false)
        var engineInvoked = false
        let engine = ScriptedEngine(profile: profile) { _, execute, _ in
            engineInvoked = true
            _ = await execute("click", #"{"id":1}"#)
            return "Unexpected execution."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        let webView = await loadedWebView("<button onclick=\"window.clicked=true\">Dangerous action</button>")
        let oversizedTask = String(repeating: "🧪", count: BrowserAgentLocalContext.taskByteLimit(contextSize: 4_096))
            + "X"
        XCTAssertFalse(BrowserAgentLocalContext.taskFits(oversizedTask, contextSize: 4_096))
        var summary = ""
        controller.start(task: oversizedTask, conversation: nil, in: webView, openTab: nil, backend: .localApple) {
            summary = $0
        }

        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        XCTAssertFalse(engineInvoked, "The engine must not receive a task that was silently truncated.")
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("shorter task"))
        let clicked = try await webView.callAsyncJavaScript(
            "return window.clicked === true;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? Bool
        XCTAssertNotEqual(clicked, true)
    }

    func testLocalNextStepSnapshotKeepsLaterShortControlAfterLongHeadersAndLabels() async throws {
        let longControls = (0..<3).map { index in
            let longLabel = "Long control \(index) " + String(repeating: "界", count: 72)
            return "<button aria-label=\"\(longLabel)\">Long control</button>"
        }.joined()
        let longTitle = String(repeating: "A long browser title ", count: 24)
        let html = """
        <!doctype html><html><head><title>\(longTitle)</title></head><body>
        <main>\(longControls)
        <button id="short-target" onclick="window.actionCount=(window.actionCount||0)+1">Short actionable target</button>
        </main></body></html>
        """
        let longPath = String(repeating: "long-url-segment/", count: 38)
        let baseURL = try XCTUnwrap(URL(string: "https://agent-loop.fixture/\(longPath)"))
        let webView = await loadedWebView(html, baseURL: baseURL)
        XCTAssertGreaterThan(webView.url?.absoluteString.utf8.count ?? 0, 512)
        let targetID = try await elementID(containing: "Short actionable target", in: webView)
        let profile = BrowserAgentEngineProfile.local(contextSize: 4_096, supportsVision: false)
        var nextStepResult = ""
        let engine = ScriptedEngine(profile: profile) { _, execute, _ in
            nextStepResult = (await execute("click", #"{"id":\#(targetID)}"#)).text
            return "Clicked the short target."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var summary = ""
        controller.start(task: "Click the short actionable target", conversation: nil, in: webView, openTab: nil, backend: .localApple) {
            summary = $0
        }

        let completed = await waitUntilAsync { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        XCTAssertLessThanOrEqual(
            nextStepResult.utf8.count,
            BrowserAgentLocalContext.toolResultByteLimit(contextSize: profile.contextSize ?? 4_096)
        )
        XCTAssertTrue(
            nextStepResult.contains("[\(targetID)] button \"Short actionable target\""),
            "A too-long early control line must not prevent a later usable ID from appearing in the fresh snapshot."
        )
        XCTAssertFalse(nextStepResult.contains("Long control 2"), "The oversized early control must be skipped whole.")
        let actionCount = try await webView.callAsyncJavaScript(
            "return window.actionCount || 0;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? Int
        XCTAssertEqual(actionCount, 1, "The retained ID must still refer to the intended control.")
    }

    func testInjectedEngineCanAskUserAndContinueAfterAnswer() async throws {
        var questionOutput = ""
        let engine = ScriptedEngine { _, execute, _ in
            let output = await execute("ask_user", #"{"question":"Which color should I choose?"}"#)
            questionOutput = output.text
            return "Received your preference."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        let webView = await loadedWebView("<main>Question fixture</main>")
        var summary = ""
        controller.start(task: "Choose a color", conversation: nil, in: webView, openTab: nil) { summary = $0 }

        let questionVisible = await waitUntil { controller.pendingQuestion?.prompt == "Which color should I choose?" }
        XCTAssertTrue(questionVisible, "pendingQuestion=\(String(describing: controller.pendingQuestion)); summary=\(summary); steps=\(controller.steps.map(\.text))")
        controller.resolveUserQuestion("Blue")
        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        XCTAssertTrue(questionOutput.contains("Blue"))
        XCTAssertTrue(summary.contains("Received your preference."))
    }

    func testStaleDisplayedQuestionIDCannotResolveNewerPendingQuestion() async throws {
        var firstOutput = ""
        var secondOutput = ""
        let engine = ScriptedEngine { _, execute, _ in
            firstOutput = (await execute("ask_user", #"{"question":"First question?"}"#)).text
            secondOutput = (await execute("ask_user", #"{"question":"Second question?"}"#)).text
            return "Questions answered."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        let webView = await loadedWebView("<main>Question ID fixture</main>")
        var summary = ""
        controller.start(task: "Ask two clarifying questions", conversation: nil, in: webView, openTab: nil) {
            summary = $0
        }

        let firstShown = await waitUntil { controller.pendingQuestion?.prompt == "First question?" }
        XCTAssertTrue(firstShown, "pendingQuestion=\(String(describing: controller.pendingQuestion)); steps=\(controller.steps.map(\.text))")
        let oldQuestionID = try XCTUnwrap(controller.pendingQuestion?.id)
        controller.resolveUserQuestion("first answer", id: oldQuestionID)

        let secondShown = await waitUntil { controller.pendingQuestion?.prompt == "Second question?" }
        XCTAssertTrue(secondShown, "pendingQuestion=\(String(describing: controller.pendingQuestion)); steps=\(controller.steps.map(\.text))")
        let newQuestionID = try XCTUnwrap(controller.pendingQuestion?.id)
        XCTAssertNotEqual(oldQuestionID, newQuestionID)
        controller.resolveUserQuestion("stale answer", id: oldQuestionID)
        XCTAssertEqual(controller.pendingQuestion?.id, newQuestionID, "The Send/Skip callbacks from an older card cannot clear the current card.")
        controller.resolveUserQuestion("second answer", id: newQuestionID)

        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        XCTAssertTrue(firstOutput.contains("first answer"))
        XCTAssertTrue(secondOutput.contains("second answer"))
        XCTAssertFalse(secondOutput.contains("stale answer"))
    }

    func testStopDuringSuspendedAutofillAuthenticationCannotPolluteNewRun() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suiteName = "BrowserAgentLoop.autofill-stop.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let url = try XCTUnwrap(URL(string: "https://autofill-stop.fixture/contact"))
        let tab = BrowserTab(title: "Contact", url: url)
        let viewModel = BrowserViewModel(userDefaults: defaults, thumbnailDirectory: scratch.appendingPathComponent("thumbs", isDirectory: true))
        viewModel.tabs = [tab]
        viewModel.selectedTabID = tab.id
        let webView = tab.activateWebView()
        await loadHTML("<label for=\"name\">Given name</label><input id=\"name\" autocomplete=\"given-name\">", into: webView, baseURL: url)
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            onTabSelected: { _ in },
            historyStore: HistoryStore(directory: scratch.appendingPathComponent("history", isDirectory: true))
        )
        let store = LoopProfileStore()
        store.profile = AutofillProfile(givenName: "Synthetic Stop Name")
        let auth = LoopAuthenticator()
        auth.shouldSuspend = true
        let service = AutofillProfileService(store: store, authenticator: auth)

        var oldToolOutput = ""
        let oldEngine = ScriptedEngine { _, execute, _ in
            oldToolOutput = (await execute("fill_form", "{}")).text
            return "The old run should not resume."
        }
        let newEngine = ScriptedEngine { _, _, _ in "Replacement run completed." }
        var engineIndex = 0
        let controller = BrowserAgentController(
            engineFactory: { _ in defer { engineIndex += 1 }; return engineIndex == 0 ? oldEngine : newEngine },
            autofillProfileService: service,
            autofillPrivacy: BrowserAgentAutofillPrivacy()
        )
        defer {
            controller.stop()
            auth.resume(false)
            adapter.endRun()
        }

        controller.start(task: "Fill my contact profile", conversation: nil, in: webView, openTab: nil, browserAdapter: adapter) { _ in }
        let approvalVisible = await waitUntil { controller.pendingConfirmation != nil }
        XCTAssertTrue(approvalVisible, "steps=\(controller.steps.map(\.text))")
        let approval = try XCTUnwrap(controller.pendingConfirmation)
        controller.resolveConfirmation(id: approval.id, allowed: true)
        let authenticationWaiting = await waitUntil { auth.started && auth.continuation != nil }
        XCTAssertTrue(authenticationWaiting, "The fake authenticator should suspend before any store read.")

        controller.stop()
        var newSummary = ""
        controller.start(task: "Read the page title", conversation: nil, in: webView, openTab: nil, browserAdapter: adapter) {
            newSummary = $0
        }
        let newRunCompleted = await waitUntil { !controller.isRunning && newSummary.contains("Replacement run completed.") }
        XCTAssertTrue(newRunCompleted, "summary=\(newSummary); steps=\(controller.steps.map(\.text))")
        XCTAssertNil(controller.pendingConfirmation)
        XCTAssertEqual(controller.steps, [], "The completed newer run's steps were drained normally.")

        auth.resume(false)
        let oldRunUnblocked = await waitUntil { !oldToolOutput.isEmpty }
        XCTAssertTrue(oldRunUnblocked, "The cancelled old tool should settle when its injected auth callback returns.")
        XCTAssertEqual(store.loadCount, 0, "A late denial/success callback after Stop must not read Keychain or the fake profile store.")
        XCTAssertTrue(newSummary.contains("Replacement run completed."))
        XCTAssertNil(controller.pendingConfirmation)
        let fieldValue = try await webView.callAsyncJavaScript("return document.getElementById('name').value;", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(fieldValue, "")
    }

    func testFillApprovalDeclineAndStopNeverReadProfileOrMutatePage() async throws {
        for stopInsteadOfDecline in [false, true] {
            let harness = try await makeAutofillApprovalHarness(path: stopInsteadOfDecline ? "stop-pending" : "decline")
            defer { harness.cleanup() }

            let approvalVisible = await waitUntil { harness.controller.pendingConfirmation != nil }
            XCTAssertTrue(
                approvalVisible,
                "stop=\(stopInsteadOfDecline); steps=\(harness.controller.steps.map(\.text))"
            )
            let approval = try XCTUnwrap(harness.controller.pendingConfirmation)
            XCTAssertFalse(approval.allowsSiteTrust, "Autofill approval must always be one-shot.")

            if stopInsteadOfDecline {
                harness.controller.stop()
            } else {
                harness.controller.resolveConfirmation(id: approval.id, allowed: false)
            }

            let settled = await waitUntil { !harness.controller.isRunning && !harness.output.value.isEmpty }
            XCTAssertTrue(settled, "stop=\(stopInsteadOfDecline); output=\(harness.output.value)")
            if stopInsteadOfDecline {
                XCTAssertEqual(harness.output.value, "Cancelled.")
            } else {
                XCTAssertTrue(harness.output.value.localizedCaseInsensitiveContains("declined"), harness.output.value)
            }
            XCTAssertFalse(harness.authenticator.started, "Decline/Stop while approval is pending must not authenticate.")
            XCTAssertEqual(harness.store.loadCount, 0, "Decline/Stop must not read the profile store.")
            XCTAssertEqual(harness.store.saveCount, 0)
            XCTAssertEqual(harness.store.deleteCount, 0)
            XCTAssertFalse(harness.privacy.isQuarantined(tabID: harness.tab.id, webView: harness.webView))

            let pageState = try await harness.webView.callAsyncJavaScript(
                #"return [document.getElementById('name').value,window.inputEvents,window.submitEvents].join('|');"#,
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? String
            XCTAssertEqual(pageState, "|0|0", "A declined or stopped approval must not write or submit the form.")
        }
    }

    func testFillApprovalRejectsSameDocumentAndSameURLDocumentReplacement() async throws {
        for replaceDocument in [false, true] {
            let harness = try await makeAutofillApprovalHarness(path: replaceDocument ? "same-url-replacement" : "same-document-replacement")
            defer { harness.cleanup() }

            let approvalVisible = await waitUntil { harness.controller.pendingConfirmation != nil }
            XCTAssertTrue(
                approvalVisible,
                "replaceDocument=\(replaceDocument); steps=\(harness.controller.steps.map(\.text))"
            )
            let approval = try XCTUnwrap(harness.controller.pendingConfirmation)
            let originalNonce = try await agentDocumentNonce(in: harness.webView)

            if replaceDocument {
                let originalURL = try XCTUnwrap(harness.webView.url)
                await loadHTML(
                    #"<script>window.inputEvents=0;window.submitEvents=0;</script>"#
                    + #"<form id="contact" method="post" action="/contact"><label for="name">Given name</label>"#
                    + #"<input id="name" name="given_name" autocomplete="given-name" oninput="window.inputEvents++">"#
                    + #"<button type="submit">Save</button></form>"#
                    + #"<script>document.getElementById("contact").addEventListener("submit",function(event){"#
                    + #"event.preventDefault();window.submitEvents++});</script>"#,
                    into: harness.webView,
                    baseURL: originalURL
                )
                XCTAssertEqual(harness.webView.url, originalURL, "The stale-page check must reject a replacement even when the URL is unchanged.")
                let replacementNonce = try await agentDocumentNonce(in: harness.webView)
                XCTAssertNotEqual(replacementNonce, originalNonce)
            } else {
                let replacementResult = try await harness.webView.callAsyncJavaScript(
                    #"const original=document.getElementById('name');window.originalField=original;original.replaceWith(original.cloneNode(true));return true;"#,
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                ) as? Bool
                XCTAssertEqual(replacementResult, true)
                let currentNonce = try await agentDocumentNonce(in: harness.webView)
                XCTAssertEqual(currentNonce, originalNonce, "The element replacement keeps the same document nonce.")
            }

            harness.controller.resolveConfirmation(id: approval.id, allowed: true)
            let settled = await waitUntil { !harness.controller.isRunning && !harness.output.value.isEmpty }
            XCTAssertTrue(settled, "replaceDocument=\(replaceDocument); output=\(harness.output.value); steps=\(harness.controller.steps.map(\.text))")
            XCTAssertTrue(
                harness.output.value.localizedCaseInsensitiveContains("changed") || harness.output.value.localizedCaseInsensitiveContains("stale"),
                harness.output.value
            )
            XCTAssertFalse(harness.authenticator.started, "A stale approval must be rejected before authentication.")
            XCTAssertEqual(harness.store.loadCount, 0, "A stale approval must not read the profile store.")
            XCTAssertEqual(harness.store.saveCount, 0)
            XCTAssertEqual(harness.store.deleteCount, 0)
            XCTAssertFalse(harness.privacy.isQuarantined(tabID: harness.tab.id, webView: harness.webView))

            let pageState = try await harness.webView.callAsyncJavaScript(
                replaceDocument
                    ? #"return [document.getElementById('name').value,window.inputEvents,window.submitEvents].join('|');"#
                    : #"return [document.getElementById('name').value,window.originalField.value,window.inputEvents,window.submitEvents].join('|');"#,
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? String
            XCTAssertEqual(pageState, replaceDocument ? "|0|0" : "||0|0", "Neither old nor replacement controls may be mutated after stale approval.")
        }
    }

    func testFilledTabEchoIsRedactedFromCleanTabAndHistoryAgentResults() async throws {
        let suiteName = "BrowserAgentLoop.autofill-metadata.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let privateName = String(repeating: "ProfileEcho", count: 18)
        let encodedName = privateName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? privateName
        let filledURL = try XCTUnwrap(URL(string: "https://profile-echo.fixture/contact?name=\(encodedName)"))
        let cleanURL = try XCTUnwrap(URL(string: "https://clean.fixture/page"))
        let filledTab = BrowserTab(title: privateName, url: filledURL)
        let cleanTab = BrowserTab(title: "Clean tab", url: cleanURL)
        let viewModel = BrowserViewModel(userDefaults: defaults, thumbnailDirectory: scratch.appendingPathComponent("thumbs", isDirectory: true))
        viewModel.tabs = [filledTab, cleanTab]
        viewModel.selectedTabID = filledTab.id
        let filledWebView = filledTab.activateWebView()
        await loadHTML(
            #"<label for="name">First name</label>"#
                + #"<input id="name" autocomplete="given-name" "#
                + #"oninput="document.getElementById('echo').textContent=this.value">"#
                + #"<p id="echo"></p>"#,
            into: filledWebView,
            baseURL: filledURL
        )
        let cleanWebView = cleanTab.activateWebView()
        await loadHTML("<main>Clean page</main>", into: cleanWebView, baseURL: cleanURL)

        let history = HistoryStore(directory: scratch.appendingPathComponent("history", isDirectory: true))
        var historyURLComponents = URLComponents(string: "https://history.fixture/profile")!
        historyURLComponents.queryItems = [
            URLQueryItem(name: "name", value: privateName),
            URLQueryItem(name: "tail", value: String(repeating: "x", count: 420))
        ]
        let historyURL = try XCTUnwrap(historyURLComponents.url)
        history.record(url: historyURL, title: privateName)
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            onTabSelected: { _ in },
            historyStore: history
        )
        let store = LoopProfileStore()
        store.profile = AutofillProfile(givenName: privateName)
        let service = AutofillProfileService(store: store, authenticator: LoopAuthenticator())
        let privacy = BrowserAgentAutofillPrivacy()
        var fillOutput = ""
        var listOutput = ""
        var historyOutput = ""
        var pageOutputs: [String] = []
        var screenshotCaptureCount = 0
        let engine = ScriptedEngine(profile: .chatGPTPlan(supportsVision: true)) { _, execute, _ in
            fillOutput = (await execute("fill_form", "{}")).text
            for name in ["read_page", "inspect", "extract_links", "screenshot"] {
                pageOutputs.append((await execute(name, "{}")).text)
            }
            _ = await execute("switch_tab", try self.argumentsJSON(["tab_id": cleanTab.id.uuidString]))
            listOutput = (await execute("list_tabs", "{}")).text
            historyOutput = (await execute("search_history", try self.argumentsJSON(["query": "history.fixture"]))).text
            return "Finished checking scoped metadata."
        }
        let controller = BrowserAgentController(
            engineFactory: { _ in engine },
            screenshotCapture: { _ in
                screenshotCaptureCount += 1
                return Data()
            },
            autofillProfileService: service,
            autofillPrivacy: privacy
        )
        defer {
            controller.stop()
            adapter.endRun()
        }
        var summary = ""
        controller.start(
            task: "Fill the contact form, then read the page, inspect it, capture a screenshot, "
                + "extract links, and check tabs and history",
            conversation: nil,
            in: filledWebView,
            openTab: nil,
            browserAdapter: adapter
        ) {
            summary = $0
        }
        let approvalVisible = await waitUntil { controller.pendingConfirmation != nil }
        XCTAssertTrue(approvalVisible, "steps=\(controller.steps.map(\.text))")
        let approval = try XCTUnwrap(controller.pendingConfirmation)
        controller.resolveConfirmation(id: approval.id, allowed: true)
        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); fill=\(fillOutput); list=\(listOutput); history=\(historyOutput)")
        XCTAssertTrue(fillOutput.contains("Filled 1"), fillOutput)
        XCTAssertEqual(pageOutputs.count, 4)
        XCTAssertTrue(
            pageOutputs[0].contains("[redacted]"),
            "A profile value echoed into page text must be redacted: \(pageOutputs[0])"
        )
        XCTAssertEqual(pageOutputs[3], "Screenshots are disabled in a tab that received autofill.")
        XCTAssertEqual(screenshotCaptureCount, 0, "A filled page must never reach the screenshot capture seam.")
        for output in pageOutputs {
            XCTAssertFalse(
                output.contains(privateName),
                "Filled-tab page output must never contain a profile value: \(output)"
            )
            XCTAssertFalse(
                output.contains(String(privateName.prefix(120))),
                "A clipped profile echo must not leak a long prefix: \(output)"
            )
        }
        XCTAssertTrue(listOutput.contains(cleanTab.id.uuidString))
        XCTAssertTrue(historyOutput.contains("history.fixture"))
        for output in [listOutput, historyOutput] {
            XCTAssertFalse(output.contains(privateName), "Full profile echoes must be redacted: \(output)")
            XCTAssertFalse(output.contains(String(privateName.prefix(120))), "Values must be redacted before title/URL bounds: \(output)")
            XCTAssertTrue(output.contains("[profile data redacted]"), "The redaction marker should remain visible in: \(output)")
        }
    }

    func testFilledTabStaysUsableWhileRedactingProfileValues() async throws {
        let suiteName = "BrowserAgentLoop.autofill-usable.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let url = try XCTUnwrap(URL(string: "https://filled-usable.fixture/contact"))
        let tab = BrowserTab(title: "Contact", url: url)
        let viewModel = BrowserViewModel(userDefaults: defaults, thumbnailDirectory: scratch.appendingPathComponent("thumbs", isDirectory: true))
        viewModel.tabs = [tab]
        viewModel.selectedTabID = tab.id
        let webView = tab.activateWebView()
        await loadHTML(
            #"<label for="name">First name</label><input id="name" autocomplete="given-name" "#
                + #"oninput="document.getElementById('echo').textContent=this.value">"#
                + #"<p id="echo"></p>"#
                + #"<button id="cont" type="button" onclick="window.continued=true">Continue</button>"#,
            into: webView,
            baseURL: url
        )
        let continueID = try await elementID(containing: "Continue", in: webView)
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            onTabSelected: { _ in },
            historyStore: HistoryStore(directory: scratch.appendingPathComponent("history", isDirectory: true))
        )
        let store = LoopProfileStore()
        store.profile = AutofillProfile(givenName: "Synthetic Usable Name")
        let privacy = BrowserAgentAutofillPrivacy()
        var clickOutput = ""
        var screenshotOutput = ""
        var fetchOutput = ""
        var screenshotCaptureCount = 0
        let engine = ScriptedEngine(profile: .chatGPTPlan(supportsVision: true)) { _, execute, _ in
            _ = await execute("fill_form", "{}")
            clickOutput = (await execute("click", #"{"id":\#(continueID)}"#)).text
            screenshotOutput = (await execute("screenshot", "{}")).text
            fetchOutput = (await execute(
                "fetch_page",
                try self.argumentsJSON(["url": "https://filled-usable.fixture/again"])
            )).text
            return "Finished the usable-tab check."
        }
        let controller = BrowserAgentController(
            engineFactory: { _ in engine },
            screenshotCapture: { _ in
                screenshotCaptureCount += 1
                return Data()
            },
            autofillProfileService: AutofillProfileService(store: store, authenticator: LoopAuthenticator()),
            autofillPrivacy: privacy
        )
        defer {
            controller.stop()
            adapter.endRun()
        }
        var summary = ""
        controller.start(
            task: "Fill the form, continue, then fetch the follow-up page",
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter
        ) { summary = $0 }

        let approvalVisible = await waitUntil { controller.pendingConfirmation != nil }
        XCTAssertTrue(approvalVisible, "steps=\(controller.steps.map(\.text))")
        let approval = try XCTUnwrap(controller.pendingConfirmation)
        controller.resolveConfirmation(id: approval.id, allowed: true)
        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); click=\(clickOutput); steps=\(controller.steps.map(\.text))")

        let continued = try await webView.callAsyncJavaScript(
            "return window.continued === true;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? Bool
        XCTAssertEqual(continued, true, "A normal button click must still execute in a filled tab.")
        XCTAssertTrue(
            clickOutput.contains("<page_snapshot>"),
            "The click must return a fresh snapshot, not a block message: \(clickOutput)"
        )
        XCTAssertTrue(
            clickOutput.contains("[redacted]"),
            "Filled values must be redacted inside the page snapshot: \(clickOutput)"
        )
        XCTAssertFalse(clickOutput.contains("Synthetic Usable Name"), clickOutput)
        XCTAssertFalse(
            clickOutput.contains("Synthetic Usable"),
            "No four-character-or-longer prefix of the value may leak: \(clickOutput)"
        )

        XCTAssertEqual(screenshotOutput, "Screenshots are disabled in a tab that received autofill.")
        XCTAssertEqual(screenshotCaptureCount, 0, "A filled tab must never reach the screenshot capture seam.")
        XCTAssertTrue(fetchOutput.contains("unavailable for a site that received autofill"), fetchOutput)
        for output in [clickOutput, screenshotOutput, fetchOutput] {
            XCTAssertFalse(output.contains("Synthetic Usable Name"), output)
        }
    }

    func testHideElementHonoursSavedSiteTrustOnTheExactHost() async throws {
        let suiteName = "BrowserAgentLoop.hide-trust.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let url = try XCTUnwrap(URL(string: "https://hide-trust-\(UUID().uuidString.lowercased()).fixture/article"))
        let tab = BrowserTab(title: "Article", url: url)
        let viewModel = BrowserViewModel(userDefaults: defaults, thumbnailDirectory: scratch.appendingPathComponent("thumbs", isDirectory: true))
        viewModel.tabs = [tab]
        viewModel.selectedTabID = tab.id
        let webView = tab.activateWebView()
        await loadHTML(
            #"<div id="tile-a" role="button" tabindex="0" style="width:140px;height:48px">Tile alpha</div>"#
                + #"<div id="tile-b" role="button" tabindex="0" style="width:140px;height:48px">Tile beta</div>"#,
            into: webView,
            baseURL: url
        )
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            onTabSelected: { _ in },
            historyStore: HistoryStore(directory: scratch.appendingPathComponent("history", isDirectory: true))
        )
        let firstID = try await elementID(containing: "Tile alpha", in: webView)
        let secondID = try await elementID(containing: "Tile beta", in: webView)
        let trustStore = AgentTrustStore(defaults: defaults, storageKey: "permissions")
        var firstOutput = ""
        var secondOutput = ""
        let engine = ScriptedEngine { _, execute, _ in
            firstOutput = (await execute("hide_element", #"{"id":\#(firstID)}"#)).text
            secondOutput = (await execute("hide_element", #"{"id":\#(secondID)}"#)).text
            return "Finished hiding."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine }, trustStore: trustStore)
        defer {
            controller.stop()
            adapter.endRun()
        }
        var summary = ""
        var completion: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "Hide the sponsored sections",
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter,
            onRunCompleted: { completion = $0 }
        ) { summary = $0 }

        let approvalVisible = await waitUntil { controller.pendingConfirmation != nil }
        XCTAssertTrue(approvalVisible, "steps=\(controller.steps.map(\.text))")
        let firstApproval = try XCTUnwrap(controller.pendingConfirmation)
        XCTAssertTrue(firstApproval.allowsSiteTrust, "hide_element must offer site trust on an eligible host.")
        controller.resolveConfirmation(id: firstApproval.id, allowed: true, alwaysAllow: true)

        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(
            completed,
            "summary=\(summary); first=\(firstOutput); second=\(secondOutput); steps=\(controller.steps.map(\.text))"
        )
        XCTAssertNil(
            controller.pendingConfirmation,
            "The second hide_element on the same host must be remembered without a new card."
        )
        XCTAssertTrue(firstOutput.contains("Saved and hid"), firstOutput)
        XCTAssertTrue(secondOutput.contains("Saved and hid"), secondOutput)
        XCTAssertTrue(
            completion?.actions.contains { $0.contains("Allowed by your saved permission") } == true,
            "actions=\(completion?.actions ?? [])"
        )
    }

    func testStopCancelsQuestionAndRejectsLaterToolActionsFromOldEngine() async throws {
        var lateToolOutput = ""
        let engine = ScriptedEngine { _, execute, _ in
            _ = await execute("ask_user", #"{"question":"Continue?"}"#)
            lateToolOutput = (await execute("click", #"{"id":1}"#)).text
            return "Unexpected completion."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        let webView = await loadedWebView("<button onclick=\"window.clicked=true\">Delete account</button>")
        controller.start(task: "Wait then click", conversation: nil, in: webView, openTab: nil) { _ in }

        let questionVisible = await waitUntil { controller.pendingQuestion != nil }
        XCTAssertTrue(questionVisible, "pendingQuestion=\(String(describing: controller.pendingQuestion)); steps=\(controller.steps.map(\.text))")
        controller.stop()
        let oldEngineReturned = await waitUntil { !lateToolOutput.isEmpty }
        XCTAssertTrue(oldEngineReturned, "lateToolOutput=\(lateToolOutput); steps=\(controller.steps.map(\.text))")
        XCTAssertEqual(lateToolOutput, "Cancelled.")
        let clicked = try await webView.callAsyncJavaScript("return window.clicked === true;", arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertNotEqual(clicked, true)
    }

    func testCompletedControllerRunRejectsAnyLaterToolAction() async throws {
        var savedExecutor: BrowserAgentToolExecutor?
        let engine = ScriptedEngine { _, execute, _ in
            savedExecutor = execute
            return "Completed without page changes."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        let webView = await loadedWebView("<button onclick=\"window.clicked=true\">Click me</button>")
        var summary = ""
        controller.start(task: "Read the page", conversation: nil, in: webView, openTab: nil) { summary = $0 }
        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")

        let executor = try XCTUnwrap(savedExecutor)
        let lateOutput = await executor("click", #"{"id":1}"#)
        XCTAssertEqual(lateOutput.text, "Cancelled.")
        let clicked = try await webView.callAsyncJavaScript("return window.clicked === true;", arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertNotEqual(clicked, true)
    }

    func testOldRunCallbackCannotActAfterANewRunStarts() async throws {
        var runNumber = 0
        var oldExecutor: BrowserAgentToolExecutor?
        var newRunStarted = false
        var releaseNewRun: CheckedContinuation<Void, Never>?
        let oldEngine = ScriptedEngine { _, execute, _ in
            oldExecutor = execute
            return "Old run finished."
        }
        let newEngine = ScriptedEngine { _, _, _ in
            newRunStarted = true
            await withCheckedContinuation { releaseNewRun = $0 }
            return "New run finished."
        }
        let controller = BrowserAgentController(engineFactory: { _ in
            runNumber += 1
            return runNumber == 1 ? oldEngine : newEngine
        })
        defer {
            controller.stop()
            releaseNewRun?.resume()
            releaseNewRun = nil
        }
        let webView = await loadedWebView("<button onclick=\"window.clicked=true\">Click me</button>")
        var oldSummary = ""
        controller.start(task: "First task", conversation: nil, in: webView, openTab: nil) { oldSummary = $0 }
        let firstFinished = await waitUntil { !controller.isRunning && !oldSummary.isEmpty }
        XCTAssertTrue(firstFinished, "summary=\(oldSummary); steps=\(controller.steps.map(\.text))")

        var newSummary = ""
        controller.start(task: "Second task", conversation: nil, in: webView, openTab: nil) { newSummary = $0 }
        let secondStarted = await waitUntil { newRunStarted && controller.isRunning }
        guard secondStarted else {
            return XCTFail("The replacement run should remain active while the stale callback is checked. started=\(newRunStarted), summary=\(newSummary), steps=\(controller.steps.map(\.text))")
        }
        let executor = try XCTUnwrap(oldExecutor)
        let staleOutput = await executor("click", #"{"id":1}"#)
        XCTAssertEqual(staleOutput.text, "Cancelled.")
        let clicked = try await webView.callAsyncJavaScript("return window.clicked === true;", arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertNotEqual(clicked, true)
        releaseNewRun?.resume()
        releaseNewRun = nil
        let secondFinished = await waitUntil { !controller.isRunning && !newSummary.isEmpty }
        XCTAssertTrue(secondFinished, "summary=\(newSummary); steps=\(controller.steps.map(\.text))")
    }

    func testRunCompletionSnapshotCapturesStartingContextAndFullActionLogBeforeCleanup() async throws {
        let engine = ScriptedEngine { _, execute, _ in
            for _ in 0..<12 {
                _ = await execute("scroll", #"{"direction":"down"}"#)
            }
            return "Finished with the requested summary."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        // Tall enough that each of the 12 scrolls moves the page, so none is a repeated call.
        let webView = await loadedWebView(#"<main style="height:20000px">Completion snapshot fixture</main>"#)
        let startingURL = webView.url
        let savedTaskID = UUID()
        var callbackOrder: [String] = []
        var legacyReply = ""
        var snapshot: BrowserAgentController.CompletionSnapshot?

        controller.start(
            task: "Scroll down the page and summarize the results",
            preset: .research,
            conversation: nil,
            in: webView,
            openTab: nil,
            backend: .localApple,
            startingTabIsPrivate: true,
            savedTaskID: savedTaskID,
            onRunCompleted: { value in
                callbackOrder.append("snapshot")
                snapshot = value
            },
            onComplete: { summary in
                callbackOrder.append("reply")
                legacyReply = summary
            }
        )

        var completed = false
        for _ in 0..<2_000 { // This fixture performs 12 sequential WebKit actions; leave the ordinary 8-second helper unchanged.
            if !controller.isRunning && snapshot != nil {
                completed = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        completed = completed || (!controller.isRunning && snapshot != nil)
        XCTAssertTrue(completed, "steps=\(controller.steps.map(\.text)); reply=\(legacyReply)")
        let value = try XCTUnwrap(snapshot)
        XCTAssertEqual(callbackOrder, ["reply", "snapshot"], "The legacy callback must create the exact reply before the immutable completion is delivered.")
        XCTAssertEqual(value.task, "Scroll down the page and summarize the results")
        XCTAssertEqual(value.backend, AIModelBackend.localApple.rawValue)
        XCTAssertEqual(value.preset, "research")
        XCTAssertEqual(value.startURL, startingURL)
        XCTAssertTrue(value.isPrivate, "Private history must be derived from the starting tab before cleanup.")
        XCTAssertEqual(value.savedTaskID, savedTaskID)
        XCTAssertTrue(value.outcome.contains("Finished with the requested summary."))
        XCTAssertEqual(value.actions, Array(repeating: "Scroll down", count: 12), "History keeps the full run action log even though the chat summary is abbreviated.")
        XCTAssertTrue(legacyReply.contains("+4 more"), "The user-facing exchange should preserve its existing short action summary.")
        XCTAssertEqual(value.historyRecord.id, value.runID)
        XCTAssertEqual(value.historyRecord.actions, value.actions)
        XCTAssertTrue(controller.steps.isEmpty, "The snapshot must remain complete after transient run state is cleared.")
    }

    func testCompletionPrivacyUsesTheActualPrivateStartingTabWhenAdapterCannotBegin() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suite = "BrowserAgentLoop.private-completion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let url = try XCTUnwrap(URL(string: "https://private-provider.fixture/"))
        let tab = BrowserTab(title: "Private provider", url: url, isIncognito: false)
        let viewModel = BrowserViewModel(
            userDefaults: defaults,
            thumbnailDirectory: scratch.appendingPathComponent("thumbs", isDirectory: true)
        )
        viewModel.tabs = [tab]
        viewModel.selectedTabID = tab.id
        let webView = tab.activateWebView()
        XCTAssertTrue(webView.configuration.websiteDataStore.isPersistent, "This fixture intentionally pairs private tab metadata with a persistent WebKit store.")
        tab.isIncognito = true
        tab.webAIProvider = .chatgpt // the adapter must decline to manage provider tabs
        await loadHTML("<main>Private completion fixture</main>", into: webView, baseURL: url)
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            onTabSelected: { _ in },
            historyStore: HistoryStore(directory: scratch.appendingPathComponent("history", isDirectory: true))
        )
        XCTAssertEqual(adapter.startingTabIsIncognito(for: webView), true, "The real tab metadata should remain readable even when beginRun will refuse this provider tab.")
        XCTAssertFalse(adapter.beginRun(in: webView), "Provider tabs are outside the browser adapter's action scope.")

        let engine = ScriptedEngine { _, _, _ in "Private task completed." }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop(); adapter.endRun() }
        var completion: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "Read the private provider page",
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter,
            onRunCompleted: { completion = $0 },
            onComplete: { _ in }
        )
        let completed = await waitUntil { completion != nil && !controller.isRunning }
        XCTAssertTrue(completed, "steps=\(controller.steps.map(\.text))")
        let value = try XCTUnwrap(completion)
        XCTAssertTrue(value.isPrivate, "Adapter startup failure must not turn the actual private tab into regular history.")
        var providerCalls = 0
        let recorded = try AgentTaskHistoryRecorder.record(value.historyRecord, isPrivate: value.isPrivate) {
            providerCalls += 1
            throw AgentTaskStoreError.appGroupUnavailable
        }
        XCTAssertFalse(recorded)
        XCTAssertEqual(providerCalls, 0, "The captured private flag must prevent even constructing/loading the history store.")
    }

    func testStoppedAndSupersededRunsProduceOnlyTheirOwnImmutableCompletion() async throws {
        var oldRunStarted = false
        var releaseOldRun: CheckedContinuation<String, Never>?
        let oldEngine = ScriptedEngine { _, _, onNote in
            oldRunStarted = true
            onNote("Old run's completed action")
            return await withCheckedContinuation { releaseOldRun = $0 }
        }
        let replacementEngine = ScriptedEngine { _, _, onNote in
            onNote("New run's action")
            return "New run completed."
        }
        var engineIndex = 0
        let controller = BrowserAgentController(engineFactory: { _ in
            defer { engineIndex += 1 }
            return engineIndex == 0 ? oldEngine : replacementEngine
        })
        defer {
            controller.stop()
            releaseOldRun?.resume(returning: "Stale old answer")
            releaseOldRun = nil
        }
        let webView = await loadedWebView("<main>Stopped snapshot fixture</main>")
        var completions: [BrowserAgentController.CompletionSnapshot] = []
        var replies: [String] = []
        controller.start(
            task: "First task to stop",
            conversation: nil,
            in: webView,
            openTab: nil,
            savedTaskID: UUID(),
            onRunCompleted: { completions.append($0) },
            onComplete: { replies.append($0) }
        )
        let oldStarted = await waitUntil { oldRunStarted }
        XCTAssertTrue(oldStarted)
        controller.stop()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].task, "First task to stop")
        XCTAssertEqual(completions[0].outcome, "Stopped.")
        XCTAssertTrue(completions[0].actions.contains("Old run's completed action"))
        XCTAssertEqual(replies.count, 1)

        controller.start(
            task: "Second replacement task",
            conversation: nil,
            in: webView,
            openTab: nil,
            onRunCompleted: { completions.append($0) },
            onComplete: { replies.append($0) }
        )
        let replacementCompleted = await waitUntil { completions.count == 2 && !controller.isRunning }
        XCTAssertTrue(replacementCompleted, "completions=\(completions.map(\.task)); replies=\(replies)")
        let replacementRunID = completions[1].runID
        releaseOldRun?.resume(returning: "Stale old answer")
        releaseOldRun = nil
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(completions.count, 2, "The late old engine return must not create a completion for or mutate the replacement run.")
        XCTAssertEqual(completions[0].task, "First task to stop")
        XCTAssertEqual(completions[1].task, "Second replacement task")
        XCTAssertNotEqual(completions[0].runID, replacementRunID)
        XCTAssertEqual(completions[1].runID, replacementRunID)
        XCTAssertTrue(completions[1].actions.contains("New run's action"))
        XCTAssertFalse(completions[1].outcome.contains("Stale old answer"))
        XCTAssertFalse(replies.last?.contains("Stale old answer") ?? false)
    }

    func testStopWhileApprovalIsPendingCancelsTheRiskyAction() async throws {
        let webView = await loadedWebView("<button onclick=\"window.deleted=true\">Delete account</button>")
        let elementID = try await elementID(containing: "Delete account", in: webView)
        var toolOutput = ""
        let engine = ScriptedEngine { _, execute, _ in
            let arguments = try JSONSerialization.data(withJSONObject: ["id": elementID])
            toolOutput = (await execute("click", try XCTUnwrap(String(data: arguments, encoding: .utf8)))).text
            return "Stopped action result."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        controller.start(task: "Click delete", conversation: nil, in: webView, openTab: nil) { _ in }
        let approvalVisible = await waitUntil { controller.pendingConfirmation != nil }
        XCTAssertTrue(approvalVisible, "pendingConfirmation=\(String(describing: controller.pendingConfirmation)); steps=\(controller.steps.map(\.text))")
        controller.stop()
        let cancelled = await waitUntil { toolOutput == "Cancelled." }
        XCTAssertTrue(cancelled, "toolOutput=\(toolOutput); steps=\(controller.steps.map(\.text))")
        let deleted = try await webView.callAsyncJavaScript("return window.deleted === true;", arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertNotEqual(deleted, true)
    }

    func testIncognitoApprovalNeverInvokesSiteTrustStoreProvider() async throws {
        let suite = "BrowserAgentLoop.private-trust.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let viewModel = BrowserViewModel(userDefaults: defaults, thumbnailDirectory: scratch)
        let pageURL = try XCTUnwrap(URL(string: "https://private-agent.fixture/post"))
        let privateTab = BrowserTab(title: "Private", url: pageURL, isIncognito: true)
        viewModel.tabs = [privateTab]
        viewModel.selectedTabID = privateTab.id
        let webView = privateTab.activateWebView()
        await loadHTML(
            #"<form method="post" action="/contact"><button id="post-button">Post update</button></form>"#,
            into: webView,
            baseURL: pageURL
        )
        let elementID = try await elementID(containing: "Post update", in: webView)
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            onTabSelected: { _ in },
            historyStore: HistoryStore(directory: scratch.appendingPathComponent("history", isDirectory: true))
        )

        var providerCalls = 0
        var completion = ""
        let engine = ScriptedEngine { _, execute, _ in
            (await execute("click", #"{"id":\#(elementID)}"#)).text
        }
        let controller = BrowserAgentController(
            engineFactory: { _ in engine },
            trustStoreProvider: {
                providerCalls += 1
                return AgentTrustStore(defaults: defaults, storageKey: "permissions")
            }
        )
        defer {
            controller.stop()
            adapter.endRun()
        }
        controller.start(
            task: "Click Post update",
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter
        ) { completion = $0 }

        let approvalVisible = await waitUntil { controller.pendingConfirmation != nil }
        XCTAssertTrue(approvalVisible, "pendingConfirmation=\(String(describing: controller.pendingConfirmation)); steps=\(controller.steps.map(\.text))")
        XCTAssertEqual(adapter.runIncognitoMode, true)
        let confirmation = try XCTUnwrap(controller.pendingConfirmation)
        XCTAssertFalse(confirmation.allowsSiteTrust)
        XCTAssertEqual(providerCalls, 0, "Private approvals must not load persisted permissions.")
        controller.resolveConfirmation(id: confirmation.id, allowed: false)
        let completed = await waitUntil { !controller.isRunning && !completion.isEmpty }
        XCTAssertTrue(completed, "completion=\(completion); steps=\(controller.steps.map(\.text))")
        XCTAssertEqual(providerCalls, 0, "Private runs must not read or write site permissions.")
    }

    func testStaleConfirmationIDCannotResolveReplacementApproval() async throws {
        let webView = await loadedWebView("""
        <button id="first" onclick="window.firstDeleted=true">Delete first</button>
        <button id="second" onclick="window.secondDeleted=true">Delete second</button>
        """)
        let firstID = try await elementID(containing: "Delete first", in: webView)
        let secondID = try await elementID(containing: "Delete second", in: webView)
        var firstOutput = ""
        var secondOutput = ""
        let engine = ScriptedEngine { _, execute, _ in
            firstOutput = (await execute("click", #"{"id":\#(firstID)}"#)).text
            secondOutput = (await execute("click", #"{"id":\#(secondID)}"#)).text
            return "Checked both approval decisions."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var summary = ""
        controller.start(task: "Delete the two old items", conversation: nil, in: webView, openTab: nil) { summary = $0 }

        let firstVisible = await waitUntil { controller.pendingConfirmation != nil }
        XCTAssertTrue(firstVisible, "pendingConfirmation=\(String(describing: controller.pendingConfirmation)); steps=\(controller.steps.map(\.text))")
        let firstConfirmation = try XCTUnwrap(controller.pendingConfirmation)
        controller.resolveConfirmation(id: firstConfirmation.id, allowed: false)

        let replacementVisible = await waitUntil {
            controller.pendingConfirmation != nil && controller.pendingConfirmation?.id != firstConfirmation.id
        }
        XCTAssertTrue(replacementVisible, "The second risky action should create its own approval card. output=\(firstOutput), second=\(secondOutput)")
        let secondConfirmation = try XCTUnwrap(controller.pendingConfirmation)
        controller.resolveConfirmation(id: firstConfirmation.id, allowed: true, alwaysAllow: true)
        XCTAssertEqual(controller.pendingConfirmation?.id, secondConfirmation.id, "A stale card callback must not resolve the current approval.")

        let effectsBeforeCurrentDecision = try await webView.callAsyncJavaScript(
            "return JSON.stringify([window.firstDeleted === true, window.secondDeleted === true]);",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        XCTAssertEqual(effectsBeforeCurrentDecision, "[false,false]")
        controller.resolveConfirmation(id: secondConfirmation.id, allowed: false)
        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); first=\(firstOutput); second=\(secondOutput)")
        let finalEffects = try await webView.callAsyncJavaScript(
            "return JSON.stringify([window.firstDeleted === true, window.secondDeleted === true]);",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        XCTAssertEqual(finalEffects, "[false,false]")
    }

    func testPendingApprovalCannotSurviveSameURLDocumentReplacement() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://agent-loop.fixture/account"))
        let webView = await loadedWebView("<button id=\"delete\" onclick=\"window.deleted=true\">Delete account</button>", baseURL: baseURL)
        let elementID = try await elementID(containing: "Delete account", in: webView)
        var toolOutput = ""
        let engine = ScriptedEngine { _, execute, _ in
            toolOutput = (await execute("click", #"{"id":\#(elementID)}"#)).text
            return "Finished reviewing the approval."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var summary = ""
        controller.start(task: "Delete the account", conversation: nil, in: webView, openTab: nil) { summary = $0 }

        let approvalVisible = await waitUntil { controller.pendingConfirmation != nil }
        XCTAssertTrue(approvalVisible, "pendingConfirmation=\(String(describing: controller.pendingConfirmation)); steps=\(controller.steps.map(\.text))")
        let confirmation = try XCTUnwrap(controller.pendingConfirmation)
        let oldIdentity = try await webView.callAsyncJavaScript(
            BrowserAgentPageScript.documentIdentity, arguments: [:], in: nil, contentWorld: BrowserAgentPageScript.world
        ) as? String
        await loadHTML(
            "<button id=\"delete\" onclick=\"window.deleted=true\">Delete account</button>",
            into: webView,
            baseURL: baseURL
        )
        let newIdentity = try await webView.callAsyncJavaScript(
            BrowserAgentPageScript.documentIdentity, arguments: [:], in: nil, contentWorld: BrowserAgentPageScript.world
        ) as? String
        XCTAssertNotEqual(oldIdentity, newIdentity)
        XCTAssertEqual(webView.url, baseURL)

        controller.resolveConfirmation(id: confirmation.id, allowed: true)
        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); toolOutput=\(toolOutput); steps=\(controller.steps.map(\.text))")
        XCTAssertTrue(toolOutput.localizedCaseInsensitiveContains("stale") || toolOutput.localizedCaseInsensitiveContains("changed"), toolOutput)
        let deleted = try await webView.callAsyncJavaScript("return window.deleted === true;", arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertNotEqual(deleted, true)
    }

    func testScreenshotMaskIsRestoredWhenCaptureFails() async throws {
        let webView = await loadedWebView("<input type=\"password\" value=\"private-value\" id=\"secret\">")
        let engine = ScriptedEngine(profile: .chatGPTPlan(supportsVision: true)) { _, execute, _ in
            let result = await execute("screenshot", "{}")
            return result.text
        }
        let controller = BrowserAgentController(
            engineFactory: { _ in engine },
            screenshotCapture: { _ in throw BrowserAgentScreenshotError.captureFailed }
        )
        defer { controller.stop() }
        var summary = ""
        controller.start(task: "Describe the page", conversation: nil, in: webView, openTab: nil) { summary = $0 }
        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        let visibility = try await pageVisibility(of: webView)
        XCTAssertEqual(visibility, "visible")
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("could not be captured"))
    }

    func testStoppingDuringScreenshotCaptureStillRestoresSensitiveFields() async throws {
        let webView = await loadedWebView("<input type=\"password\" value=\"private-value\" id=\"secret\">")
        var captureStarted = false
        let engine = ScriptedEngine(profile: .chatGPTPlan(supportsVision: true)) { _, execute, _ in
            (await execute("screenshot", "{}")).text
        }
        let controller = BrowserAgentController(
            engineFactory: { _ in engine },
            screenshotCapture: { _ in
                captureStarted = true
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return Data()
            }
        )
        defer { controller.stop() }
        controller.start(task: "Describe the page", conversation: nil, in: webView, openTab: nil) { _ in }
        let started = await waitUntil { captureStarted }
        guard started else {
            controller.stop()
            return XCTFail("The screenshot capture seam should be reached before Stop. captureStarted=\(captureStarted); steps=\(controller.steps.map(\.text))")
        }
        let masked = try await pageVisibility(of: webView)
        XCTAssertEqual(masked, "hidden")
        controller.stop()
        let restored = await waitUntilAsync {
            (try? await self.pageVisibility(of: webView)) == "visible"
        }
        XCTAssertTrue(restored, "Stop must not cancel the bounded screenshot cleanup task.")
    }

    func testLateStoppedScreenshotCleanupCannotLogIntoOrUnmaskANewerRun() async throws {
        let webView = await loadedWebView("<input type=\"password\" value=\"private-value\" id=\"secret\">")
        let profile = BrowserAgentEngineProfile.chatGPTPlan(supportsVision: true)
        var oldToolOutput = ""
        let oldEngine = ScriptedEngine(profile: profile) { _, execute, _ in
            oldToolOutput = (await execute("screenshot", "{}")).text
            return "Old run returned."
        }
        let newEngine = ScriptedEngine(profile: profile) { _, execute, _ in
            let output = await execute("screenshot", "{}")
            XCTAssertTrue(output.text.contains("Captured a bounded JPEG"))
            return "New run completed."
        }
        var engineCount = 0
        var captureCount = 0
        var firstCaptureStarted = false
        var resumeOldCapture: (() -> Void)?
        let controller = BrowserAgentController(
            engineFactory: { _ in
                defer { engineCount += 1 }
                return engineCount == 0 ? oldEngine : newEngine
            },
            screenshotCapture: { _ in
                captureCount += 1
                if captureCount == 1 {
                    firstCaptureStarted = true
                    return await withCheckedContinuation { continuation in
                        resumeOldCapture = { continuation.resume(returning: Data("old capture".utf8)) }
                    }
                }
                return Data("new capture".utf8)
            }
        )
        defer {
            controller.stop()
            resumeOldCapture?()
            resumeOldCapture = nil
        }

        controller.start(task: "Describe the first capture", conversation: nil, in: webView, openTab: nil) { _ in }
        let oldCaptureWaiting = await waitUntil { firstCaptureStarted }
        XCTAssertTrue(oldCaptureWaiting, "captureCount=\(captureCount); steps=\(controller.steps.map(\.text))")
        let oldMaskVisibility = try await pageVisibility(of: webView)
        XCTAssertEqual(oldMaskVisibility, "hidden")

        controller.stop()
        var newSummary = ""
        controller.start(task: "Describe the replacement capture", conversation: nil, in: webView, openTab: nil) { newSummary = $0 }
        let newRunCompleted = await waitUntil { !controller.isRunning && newSummary.contains("New run completed.") }
        XCTAssertTrue(newRunCompleted, "summary=\(newSummary); steps=\(controller.steps.map(\.text))")
        XCTAssertEqual(captureCount, 2)
        let newMaskVisibility = try await pageVisibility(of: webView)
        XCTAssertEqual(newMaskVisibility, "visible")

        resumeOldCapture?()
        resumeOldCapture = nil
        let oldRunReleased = await waitUntil { !oldToolOutput.isEmpty }
        XCTAssertTrue(oldRunReleased, "oldToolOutput=\(oldToolOutput); steps=\(controller.steps.map(\.text))")
        await Task.yield()
        XCTAssertTrue(controller.steps.isEmpty, "Late screenshot cleanup from a stopped run must not append into a replacement run.")
        let finalVisibility = try await pageVisibility(of: webView)
        XCTAssertEqual(finalVisibility, "visible")
    }

    func testInjectedEngineCannotRunRiskyClickUntilUserApproves() async throws {
        let webView = await loadedWebView("<button onclick=\"window.deleted=true\">Delete account</button>")
        let snapshotValue = try await webView.callAsyncJavaScript(
            BrowserAgentPageScript.snapshot,
            arguments: ["maxElements": 150, "maxText": 2_500],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        ) as? String
        let snapshot = try XCTUnwrap(snapshotValue?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot) as? [String: Any])
        let elementLines = (object["elements"] as? String ?? "").components(separatedBy: "\n")
        let targetLine = try XCTUnwrap(elementLines.first { $0.contains("Delete account") })
        let start = try XCTUnwrap(targetLine.firstIndex(of: "["))
        let end = try XCTUnwrap(targetLine.firstIndex(of: "]"))
        let id = try XCTUnwrap(Int(targetLine[targetLine.index(after: start)..<end]))
        let engine = ScriptedEngine { _, execute, _ in
            let argumentsData = try JSONSerialization.data(withJSONObject: ["id": id])
            let arguments = try XCTUnwrap(String(data: argumentsData, encoding: .utf8))
            return (await execute("click", arguments)).text
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var summary = ""
        controller.start(task: "Click the delete button", conversation: nil, in: webView, openTab: nil) { summary = $0 }

        let confirmationVisible = await waitUntil { controller.pendingConfirmation != nil }
        XCTAssertTrue(confirmationVisible, "pendingConfirmation=\(String(describing: controller.pendingConfirmation)); summary=\(summary); steps=\(controller.steps.map(\.text))")
        let beforeApproval = try await webView.callAsyncJavaScript("return window.deleted === true;", arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(beforeApproval, false)
        controller.resolveConfirmation(false)
        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("declined"))
        let afterDenial = try await webView.callAsyncJavaScript("return window.deleted === true;", arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertNotEqual(afterDenial, true)
    }

    func testApplePurchaseScopeRequiresExplicitCurrentTask() throws {
        let informationalTasks = [
            "find foo fighters next concert in the us",
            "when is the next Foo Fighters concert in the US",
            "where can I buy tickets?",
            "find ticket prices",
            "Find the button labelled Buy tickets",
            "Do not buy tickets",
            "Please buy tickets but do not pay",
            "find the date then buy tickets",
            "Please do not reserve anything",
            "Never purchase tickets"
        ]
        let explicitTasks = [
            "Buy two Foo Fighters tickets",
            "Please buy tickets",
            "Can you reserve two tickets",
            "I want to purchase two tickets"
        ]
        let buyTarget = #"link "Buy tickets""#
        for backend in [AIModelBackend.localApple, .cloudShortcuts] {
            for task in informationalTasks {
                XCTAssertTrue(
                    BrowserAgentController.applePurchaseIsOutOfScope(
                        backend: backend, task: task, reason: "buy", target: buyTarget
                    ),
                    "\(backend) should block a buy click for task: \(task)"
                )
            }
            for task in explicitTasks {
                XCTAssertFalse(
                    BrowserAgentController.applePurchaseIsOutOfScope(
                        backend: backend, task: task, reason: "buy", target: buyTarget
                    ),
                    "\(backend) should keep the approval flow for task: \(task)"
                )
            }
            XCTAssertFalse(BrowserAgentController.applePurchaseIsOutOfScope(
                backend: backend, task: informationalTasks[0], reason: "action", target: #"link "Event details""#
            ))
            XCTAssertTrue(BrowserAgentController.applePurchaseIsOutOfScope(
                backend: backend, task: informationalTasks[0], reason: "confirm", target: "Checkout"
            ))
            for reason in ["buy", "purchase", "pay", "checkout", "check out", "place order", "order now", "book now", "reserve"] {
                XCTAssertTrue(
                    BrowserAgentController.applePurchaseIsOutOfScope(
                        backend: backend, task: informationalTasks[0], reason: reason, target: #"link "Tickets""#
                    ),
                    "\(backend) should block reason \(reason) on an informational task"
                )
            }
            XCTAssertTrue(BrowserAgentController.applePurchaseIsOutOfScope(
                backend: backend, task: informationalTasks[0], reason: "action", target: #"button "Add to cart""#
            ))
        }
        let nonAppleBackends: [AIModelBackend?] = [.chatGPTPlan, .webChatGPT, nil]
        for backend in nonAppleBackends {
            for task in informationalTasks + explicitTasks {
                XCTAssertFalse(
                    BrowserAgentController.applePurchaseIsOutOfScope(
                        backend: backend, task: task, reason: "buy", target: buyTarget
                    ),
                    "\(String(describing: backend)) must never take the Apple-only block for task: \(task)"
                )
            }
        }
    }

    func testAppleLookupBlocksPurchaseClicksWithoutApprovalOrMutation() async throws {
        let backends: [(AIModelBackend, BrowserAgentEngineProfile)] = [
            (.localApple, .local(contextSize: 4_096, supportsVision: false)),
            (.cloudShortcuts, .privateCloud(contextSize: 4_096, supportsVision: false))
        ]
        for (backend, profile) in backends {
            let webView = await loadedWebView(
                #"<main><p>Foo Fighters tour dates</p><button onclick="window.bought=true">Buy tickets</button></main>"#
            )
            let id = try await elementID(containing: "Buy tickets", in: webView)
            var outputs: [String] = []
            let engine = ScriptedEngine(profile: profile) { _, execute, _ in
                let arguments = try self.argumentsJSON(["id": id])
                outputs.append((await execute("click", arguments)).text)
                outputs.append((await execute("click", arguments)).text)
                return "Finished looking."
            }
            let controller = BrowserAgentController(engineFactory: { _ in engine })
            var summary = ""
            controller.start(
                task: "find foo fighters next concert in the us",
                conversation: nil, in: webView, openTab: nil, backend: backend
            ) { summary = $0 }

            let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
            XCTAssertTrue(completed, "\(backend): summary=\(summary); steps=\(controller.steps.map(\.text))")
            XCTAssertNil(controller.pendingConfirmation, "\(backend) must not ask for approval on an out-of-scope purchase")
            XCTAssertEqual(outputs.count, 2)
            XCTAssertTrue(
                outputs.allSatisfy { $0.contains("Purchase not requested") },
                "\(backend): outputs=\(outputs)"
            )
            let bought = try await webView.callAsyncJavaScript(
                "return window.bought === true;", arguments: [:], in: nil, contentWorld: .page
            ) as? Bool
            XCTAssertNotEqual(bought, true, "\(backend) must never run the confirmed purchase script")
            controller.stop()
        }
    }

    func testAppleExplicitPurchaseStillRequiresApproval() async throws {
        let backends: [(AIModelBackend, BrowserAgentEngineProfile)] = [
            (.localApple, .local(contextSize: 4_096, supportsVision: false)),
            (.cloudShortcuts, .privateCloud(contextSize: 4_096, supportsVision: false))
        ]
        for (backend, profile) in backends {
            let webView = await loadedWebView(
                #"<main><p>Foo Fighters tour dates</p><button onclick="window.bought=true">Buy tickets</button></main>"#
            )
            let id = try await elementID(containing: "Buy tickets", in: webView)
            let engine = ScriptedEngine(profile: profile) { _, execute, _ in
                let arguments = try self.argumentsJSON(["id": id])
                return (await execute("click", arguments)).text
            }
            let controller = BrowserAgentController(engineFactory: { _ in engine })
            var summary = ""
            controller.start(
                task: "Buy two Foo Fighters tickets",
                conversation: nil, in: webView, openTab: nil, backend: backend
            ) { summary = $0 }

            let confirmationVisible = await waitUntil { controller.pendingConfirmation != nil }
            XCTAssertTrue(
                confirmationVisible,
                "\(backend): an explicit purchase task must still ask for approval; steps=\(controller.steps.map(\.text))"
            )
            let beforeApproval = try await webView.callAsyncJavaScript(
                "return window.bought === true;", arguments: [:], in: nil, contentWorld: .page
            ) as? Bool
            XCTAssertNotEqual(beforeApproval, true, "\(backend) must not mutate before approval")
            controller.resolveConfirmation(false)
            let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
            XCTAssertTrue(completed, "\(backend): summary=\(summary); steps=\(controller.steps.map(\.text))")
            XCTAssertTrue(summary.localizedCaseInsensitiveContains("declined"), "\(backend): \(summary)")
            let afterDenial = try await webView.callAsyncJavaScript(
                "return window.bought === true;", arguments: [:], in: nil, contentWorld: .page
            ) as? Bool
            XCTAssertNotEqual(afterDenial, true, "\(backend)")
            controller.stop()
        }
    }

    func testChatGPTLookupPurchaseKeepsExistingApprovalFlow() async throws {
        let webView = await loadedWebView(
            #"<main><p>Foo Fighters tour dates</p><button onclick="window.bought=true">Buy tickets</button></main>"#
        )
        let id = try await elementID(containing: "Buy tickets", in: webView)
        let engine = ScriptedEngine { _, execute, _ in
            let arguments = try self.argumentsJSON(["id": id])
            return (await execute("click", arguments)).text
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var summary = ""
        controller.start(
            task: "find foo fighters next concert in the us",
            conversation: nil, in: webView, openTab: nil, backend: .chatGPTPlan
        ) { summary = $0 }

        let confirmationVisible = await waitUntil { controller.pendingConfirmation != nil }
        XCTAssertTrue(
            confirmationVisible,
            "ChatGPT must keep its approval flow instead of the Apple-only block; steps=\(controller.steps.map(\.text))"
        )
        let beforeApproval = try await webView.callAsyncJavaScript(
            "return window.bought === true;", arguments: [:], in: nil, contentWorld: .page
        ) as? Bool
        XCTAssertNotEqual(beforeApproval, true)
        controller.resolveConfirmation(false)
        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("declined"), "summary=\(summary)")
        let afterDenial = try await webView.callAsyncJavaScript(
            "return window.bought === true;", arguments: [:], in: nil, contentWorld: .page
        ) as? Bool
        XCTAssertNotEqual(afterDenial, true)
    }

    func testAppleTaskInstructionsAreIsolatedFromChatGPT() async throws {
        XCTAssertEqual(BrowserAgentController.instructions.utf8.count, 4_463)
        XCTAssertEqual(
            SHA256.hash(data: Data(BrowserAgentController.instructions.utf8))
                .map { String(format: "%02x", $0) }.joined(),
            "1f66d1d1e80e5ca19643ebdbfd6a3fc0400fd54cb6e735d6118a842bf81a698d"
        )
        let scope = BrowserAgentController.appleTaskScopeInstructions

        let local = try await captureRequest(
            backend: .localApple,
            profile: .local(contextSize: 4_096, supportsVision: false)
        )
        XCTAssertTrue(local.instructions.contains(scope))
        XCTAssertLessThan(local.instructions.utf8.count, 1_200)
        XCTAssertTrue(local.instructions.contains("Never type passwords"))
        XCTAssertTrue(local.instructions.contains("need user approval"))

        let cloudStandard = try await captureRequest(
            backend: .cloudShortcuts,
            profile: .privateCloud(contextSize: 4_096, supportsVision: false)
        )
        XCTAssertEqual(
            cloudStandard.instructions,
            BrowserAgentController.instructions + "\n\n" + scope
        )

        let cloudResearch = try await captureRequest(
            backend: .cloudShortcuts,
            preset: .research,
            profile: .privateCloud(contextSize: 4_096, supportsVision: false)
        )
        XCTAssertEqual(
            cloudResearch.instructions,
            BrowserAgentController.instructions + "\n\n"
                + BrowserAgentController.researchInstructions + "\n\n" + scope
        )

        let chatGPTStandard = try await captureRequest(backend: .chatGPTPlan, profile: .chatGPTPlan(supportsVision: false))
        XCTAssertEqual(chatGPTStandard.instructions, BrowserAgentController.instructions)
        XCTAssertFalse(chatGPTStandard.instructions.contains(scope))

        let chatGPTResearch = try await captureRequest(
            backend: .chatGPTPlan, preset: .research, profile: .chatGPTPlan(supportsVision: false)
        )
        XCTAssertEqual(
            chatGPTResearch.instructions,
            BrowserAgentController.instructions + "\n\n" + BrowserAgentController.researchInstructions
        )
        XCTAssertFalse(chatGPTResearch.instructions.contains(scope))
    }

    private func captureRequest(
        backend: AIModelBackend,
        preset: BrowserAgentController.Preset = .standard,
        profile: BrowserAgentEngineProfile
    ) async throws -> BrowserAgentEngineRequest {
        var captured: BrowserAgentEngineRequest?
        let engine = ScriptedEngine(profile: profile) { request, _, _ in
            captured = request
            return "Captured."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        let webView = await loadedWebView("<main>Instructions fixture</main>")
        var summary = ""
        controller.start(
            task: "find foo fighters next concert in the us",
            preset: preset,
            conversation: nil,
            in: webView,
            openTab: nil,
            backend: backend
        ) { summary = $0 }
        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "\(backend): summary=\(summary); steps=\(controller.steps.map(\.text))")
        let request = try XCTUnwrap(captured)
        let expectedProfile = preset == .research && profile.localContextSize == nil
            ? profile.withMaximumSteps(40)
            : profile
        XCTAssertEqual(request.profile, expectedProfile, "\(backend) profile changed")
        return request
    }

    func testQuestionGateReturnsSendAndSkipOnce() async {
        let gate = BrowserAgentQuestionGate<String>()
        let answerTask = Task { @MainActor in await gate.ask("Which option should I use?") }
        let answerPromptVisible = await waitForPendingPrompt(gate)
        XCTAssertTrue(answerPromptVisible)
        XCTAssertEqual(gate.pendingPrompt, "Which option should I use?")
        gate.resolve("Use the second option")
        gate.resolve("ignored duplicate")
        let answer = await answerTask.value
        XCTAssertEqual(answer, "Use the second option")
        XCTAssertNil(gate.pendingPrompt)

        let skipTask = Task { @MainActor in await gate.ask("Should I continue?") }
        let skipPromptVisible = await waitForPendingPrompt(gate)
        XCTAssertTrue(skipPromptVisible)
        gate.resolve(nil)
        gate.cancel()
        let skippedAnswer = await skipTask.value
        XCTAssertNil(skippedAnswer)
        XCTAssertNil(gate.pendingPrompt)
    }

    func testQuestionGateCancellationResolvesPendingContinuation() async {
        let gate = BrowserAgentQuestionGate<String>()
        let task = Task { @MainActor in await gate.ask("Need a detail") }
        let promptVisible = await waitForPendingPrompt(gate)
        XCTAssertTrue(promptVisible)
        task.cancel()
        let cancelledAnswer = await task.value
        XCTAssertNil(cancelledAnswer)
        XCTAssertNil(gate.pendingPrompt)
    }

    func testQuestionGateStaleCancellationCannotClearReplacementQuestion() async {
        let gate = BrowserAgentQuestionGate<String>()
        let oldTask = Task { @MainActor in await gate.ask("Old question") }
        let oldPromptVisible = await waitUntil { gate.pendingPrompt == "Old question" }
        XCTAssertTrue(oldPromptVisible)
        guard let oldRequestID = gate.pendingRequestID else {
            XCTFail("The old question should have an active request ID.")
            return
        }

        let newTask = Task { @MainActor in await gate.ask("Replacement question") }
        let replacementPromptVisible = await waitUntil { gate.pendingPrompt == "Replacement question" }
        XCTAssertTrue(replacementPromptVisible)
        guard let newRequestID = gate.pendingRequestID else {
            XCTFail("The replacement question should have an active request ID.")
            return
        }
        XCTAssertNotEqual(oldRequestID, newRequestID)

        gate.cancel(requestID: oldRequestID)
        XCTAssertEqual(gate.pendingPrompt, "Replacement question")
        gate.resolve("Answer for replacement")
        let oldAnswer = await oldTask.value
        let newAnswer = await newTask.value
        XCTAssertNil(oldAnswer, "Replacing a question resolves its old continuation once.")
        XCTAssertEqual(newAnswer, "Answer for replacement")
    }

    func testBackgroundLoaderUsesExactDataStoreFreshControllerAndPrivateScript() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let sourceConfiguration = WKWebViewConfiguration()
        sourceConfiguration.websiteDataStore = store
        let sourceHandler = SourceMessageHandler()
        sourceConfiguration.userContentController.add(sourceHandler, name: "webProviderPrompt")
        let source = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: sourceConfiguration)
        let waiter = LoadWaiter()
        source.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            source.loadHTMLString("<main>Source tab stays here</main>", baseURL: URL(string: "https://source.fixture/"))
        }
        let originalURL = source.url
        let originalText = try await source.callAsyncJavaScript("return document.body.innerText;", arguments: [:], in: nil, contentWorld: .page) as? String
        let loader = BrowserAgentBackgroundLoader(pagePreparation: { _, _ in })
        let background = loader.makeWebView(
            websiteDataStore: store,
            isPrivate: true,
            initialURL: URL(string: "https://fixture.example/")
        )

        XCTAssertTrue(background.configuration.websiteDataStore === store)
        XCTAssertFalse(background.configuration.userContentController === source.configuration.userContentController)
        XCTAssertTrue(background.configuration.userContentController.userScripts.contains { $0.source.contains("Incognito Mode") })
        let backgroundWaiter = LoadWaiter()
        background.navigationDelegate = backgroundWaiter
        await withCheckedContinuation { continuation in
            backgroundWaiter.continuation = continuation
            background.loadHTMLString("<main>Isolated background document</main>", baseURL: URL(string: "https://background.fixture/"))
        }
        let providerHandlerPresent = try await background.callAsyncJavaScript(
            "return typeof window.webkit.messageHandlers.webProviderPrompt !== 'undefined';",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? Bool
        XCTAssertEqual(providerHandlerPresent, false)
        XCTAssertEqual(source.url, originalURL)
        let unchangedSourceText = try await source.callAsyncJavaScript("return document.body.innerText;", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(unchangedSourceText, originalText, "The source web view must remain untouched by an offscreen fetch.")
        background.navigationDelegate = nil
        background.uiDelegate = nil
    }

    func testBackgroundLoaderReadsSyntheticPageWithTextCapAndSafeSourceURL() async throws {
        let longText = String(repeating: "Visible fixture text. ", count: 600)
        let html = """
        <html><head><title>Fixture source</title><style>.hidden { display:none }</style></head>
        <body><main>\(longText)</main><div class="hidden">hidden sentinel</div>
        <input type="password" value="do-not-expose">
        <textarea autocomplete="current-password">hidden text area secret</textarea>
        <form id="write" method="post" action="/change"></form>
        <script>document.getElementById('write').requestSubmit();</script></body></html>
        """
        var requestMethod: String?
        let loader = BrowserAgentBackgroundLoader(
            timeout: 5,
            requestLoader: { webView, request in
                requestMethod = request.httpMethod
                _ = webView.loadHTMLString(html, baseURL: request.url)
            },
            pagePreparation: { _, _ in }
        )
        let secretURL = try XCTUnwrap(URL(string: "https://fixture.example/read?access_token=secret-value"))
        let page = try await loader.fetch(
            url: secretURL,
            startingDataStore: .nonPersistent(),
            isPrivate: true
        )

        XCTAssertEqual(page.title, "Fixture source")
        XCTAssertLessThanOrEqual(page.text.count, BrowserAgentBackgroundLoader.maximumTextCharacters)
        XCTAssertTrue(page.truncated)
        XCTAssertFalse(page.text.contains("hidden sentinel"))
        XCTAssertFalse(page.text.contains("do-not-expose"))
        XCTAssertFalse(page.text.contains("hidden text area secret"))
        XCTAssertEqual(requestMethod, "GET")
        XCTAssertFalse(page.url.absoluteString.contains("secret-value"))
        XCTAssertEqual(URLComponents(url: page.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "[redacted]")
    }

    func testBackgroundLoaderFetchesLocalHTTPRedirectAndBlocksAttachmentAndEmptyPage() async throws {
        let fixture = BrowserAgentHTTPFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let loader = BrowserAgentBackgroundLoader(timeout: 5, pagePreparation: { _, _ in })
        let store = WKWebsiteDataStore.nonPersistent()

        let redirected = try await loader.fetch(
            url: BrowserAgentHTTPFixture.url(port: port, path: "/redirect"),
            startingDataStore: store,
            isPrivate: true
        )
        XCTAssertEqual(redirected.url.path, "/page")
        XCTAssertEqual(redirected.title, "Loopback source")
        XCTAssertTrue(redirected.text.contains("Local HTTP content"))
        XCTAssertTrue(redirected.text.contains("Readable loopback fixture"))

        do {
            _ = try await loader.fetch(
                url: BrowserAgentHTTPFixture.url(port: port, path: "/attachment"),
                startingDataStore: store,
                isPrivate: true
            )
            XCTFail("A displayable response marked as an attachment must be blocked.")
        } catch {
            XCTAssertEqual(error as? BrowserAgentBackgroundLoader.LoadError, .downloadBlocked)
        }

        do {
            _ = try await loader.fetch(
                url: BrowserAgentHTTPFixture.url(port: port, path: "/empty"),
                startingDataStore: store,
                isPrivate: true
            )
            XCTFail("A page with no readable text must fail as unavailable.")
        } catch {
            XCTAssertEqual(error as? BrowserAgentBackgroundLoader.LoadError, .pageUnavailable)
        }
    }

    func testBackgroundFetchQuarantineIsScopedToFilledOriginAndExactWebsiteDataStore() async throws {
        let fixture = BrowserAgentHTTPFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }

        let dataStore = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let filledWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let privacy = BrowserAgentAutofillPrivacy()
        privacy.quarantineBeforeFill(
            tabID: UUID(),
            webView: filledWebView,
            runID: UUID(),
            pageURL: BrowserAgentHTTPFixture.url(port: port, path: "/page"),
            documentNonce: "synthetic-fill-document",
            profileValues: ["email": "agent-private@example.test"],
            websiteDataStore: dataStore
        )
        let policy: BrowserAgentBackgroundLoader.FetchURLPolicy = { url, store in
            !privacy.blocksBackgroundFetch(url: url, startingDataStore: store)
        }
        let loader = BrowserAgentBackgroundLoader(timeout: 5, pagePreparation: { _, _ in })

        let unrelatedHostPage = try await loader.fetch(
            url: BrowserAgentHTTPFixture.url(host: "localhost", port: port, path: "/page"),
            startingDataStore: dataStore,
            isPrivate: true,
            urlPolicy: policy
        )
        XCTAssertEqual(unrelatedHostPage.title, "Loopback source")
        XCTAssertTrue(unrelatedHostPage.text.contains("Readable loopback fixture"))

        do {
            _ = try await loader.fetch(
                url: BrowserAgentHTTPFixture.url(port: port, path: "/page"),
                startingDataStore: dataStore,
                isPrivate: true,
                urlPolicy: policy
            )
            XCTFail("The filled origin must be denied before its response body is read.")
        } catch {
            XCTAssertEqual(error as? BrowserAgentBackgroundLoader.LoadError, .autofillProtectedOrigin)
        }

        do {
            _ = try await loader.fetch(
                url: BrowserAgentHTTPFixture.url(host: "localhost", port: port, path: "/redirect-to-protected"),
                startingDataStore: dataStore,
                isPrivate: true,
                urlPolicy: policy
            )
            XCTFail("A redirect into the filled origin must be denied before extraction.")
        } catch {
            XCTAssertEqual(error as? BrowserAgentBackgroundLoader.LoadError, .autofillProtectedOrigin)
        }

        let otherDataStorePage = try await loader.fetch(
            url: BrowserAgentHTTPFixture.url(port: port, path: "/page"),
            startingDataStore: .nonPersistent(),
            isPrivate: true,
            urlPolicy: policy
        )
        XCTAssertEqual(otherDataStorePage.title, "Loopback source", "An unrelated website data store does not inherit the fill origin quarantine.")
    }

    func testFetchedPageCanComposeAndExportBesideAValidatedLiveTable() async throws {
        let fixture = BrowserAgentHTTPFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let suite = "BrowserAgentLoop.fetched-export.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let liveURL = try XCTUnwrap(URL(string: "https://live-catalog.fixture/products?region=porto"))
        let liveTab = BrowserTab(title: "Live catalog", url: liveURL, isIncognito: true)
        let viewModel = BrowserViewModel(userDefaults: defaults, thumbnailDirectory: scratch)
        viewModel.tabs = [liveTab]
        viewModel.selectedTabID = liveTab.id
        let webView = liveTab.activateWebView()
        await loadHTML("""
        <!doctype html><html><head><title>Live catalog</title></head><body>
          <table><caption>Current price list</caption><thead><tr><th>Product</th><th>Price</th></tr></thead>
          <tbody><tr><td>Widget</td><td>€24.50</td></tr></tbody></table>
        </body></html>
        """, into: webView, baseURL: liveURL)
        let downloadManager = BrowserDownloadManager(temporaryDirectory: scratch)
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: downloadManager,
            onTabSelected: { _ in },
            historyStore: HistoryStore(directory: scratch.appendingPathComponent("history", isDirectory: true))
        )

        var capturedRequest: BrowserAgentEngineRequest?
        var fetchedDataset: BrowserAgentDataset?
        var liveDataset: BrowserAgentDataset?
        var csvExportOutput = ""
        var pdfExportOutput = ""
        let engine = ScriptedEngine { request, execute, _ in
            capturedRequest = request
            let fetchArguments = try self.argumentsJSON([
                "url": BrowserAgentHTTPFixture.url(port: port, path: "/page").absoluteString
            ])
            let fetchedOutput = await execute("fetch_page", fetchArguments)
            XCTAssertFalse(fetchedOutput.text.hasPrefix("Error:"), fetchedOutput.text)
            fetchedDataset = try self.datasetFromToolOutput(fetchedOutput.text)
            XCTAssertEqual(fetchedDataset?.kind, .fetchedPage)
            XCTAssertNil(fetchedDataset?.sourceTabID)
            XCTAssertTrue(
                fetchedDataset?.fetchedText?.contains("Local HTTP content") == true,
                "The fetched dataset should retain the source body text before comparison composition."
            )

            let tableOutput = await execute("extract_html_tables", "{}")
            XCTAssertFalse(tableOutput.text.hasPrefix("Error:"), tableOutput.text)
            liveDataset = try self.datasetFromToolOutput(tableOutput.text)
            XCTAssertEqual(liveDataset?.kind, .htmlTable)
            XCTAssertEqual(liveDataset?.sourceTabID, liveTab.id)

            let comparisonArguments = try self.argumentsJSON([
                "dataset_ids": [try XCTUnwrap(fetchedDataset?.id.uuidString), try XCTUnwrap(liveDataset?.id.uuidString)],
                "title": "Loopback and live comparison",
                "summary": "The fetched source and live catalog were checked together.",
                "rows": [["label": "Product evidence", "values": ["Readable loopback fixture", "€24.50"]]]
            ])
            let comparisonOutput = await execute("compose_comparison", comparisonArguments)
            XCTAssertFalse(comparisonOutput.text.hasPrefix("Error:"), comparisonOutput.text)
            let comparisonID = try self.uuidAfter("Created model-authored comparison ", in: comparisonOutput.text)
            csvExportOutput = (await execute("export_comparison_csv", try self.argumentsJSON(["comparison_id": comparisonID]))).text
            pdfExportOutput = (await execute("export_comparison_pdf", try self.argumentsJSON(["comparison_id": comparisonID]))).text
            return "Fetched evidence was compared with the live table and queued for export."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer {
            controller.stop()
            adapter.endRun()
        }
        var summary = ""
        controller.start(
            task: "Research the fetched source and save a comparison CSV and PDF",
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter
        ) { summary = $0 }

        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        XCTAssertTrue(summary.contains("Fetched evidence was compared"))
        XCTAssertNotNil(fetchedDataset)
        XCTAssertNotNil(liveDataset)
        let request = try XCTUnwrap(capturedRequest)
        let names = try toolNames(request.tools)
        XCTAssertTrue(["fetch_page", "extract_html_tables", "compose_comparison", "export_comparison_csv", "export_comparison_pdf"].allSatisfy(names.contains))
        XCTAssertEqual(request.profile.maxSteps, 40, "The non-Local research preset uses its bounded 40-step profile.")
        XCTAssertEqual(request.maximumAnswerCharacters, 20_000)
        XCTAssertTrue(request.instructions.contains("3–5 distinct, relevant sources"))
        XCTAssertTrue(request.instructions.contains("complete bounded answer, including the Sources list"))
        XCTAssertTrue(csvExportOutput.contains("ready to save"), csvExportOutput)
        XCTAssertTrue(pdfExportOutput.contains("ready to save"), pdfExportOutput)
        XCTAssertEqual(downloadManager.items.count, 2)
        for item in downloadManager.items {
            let fileURL = try XCTUnwrap(item.temporaryFileURL)
            let data = try Data(contentsOf: fileURL)
            if item.filename.hasSuffix(".csv") {
                let csv = try XCTUnwrap(String(data: data, encoding: .utf8))
                XCTAssertTrue(csv.contains("127.0.0.1:\(port)/page"))
                XCTAssertTrue(csv.contains("Loopback source"), "The comparison export should retain the fetched source title.")
                XCTAssertTrue(csv.contains("Live catalog"), "The comparison export should retain the live source title.")
                XCTAssertTrue(csv.contains("Readable loopback fixture"))
                XCTAssertTrue(csv.contains("live-catalog.fixture"))
                XCTAssertTrue(csv.contains("€24.50"))
            } else {
                let document = try XCTUnwrap(PDFDocument(data: data))
                let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
                XCTAssertTrue(text.contains("127.0.0.1:\(port)/page"))
                XCTAssertTrue(text.contains("Loopback source"), "The comparison PDF should retain the fetched source title.")
                XCTAssertTrue(text.contains("Live catalog"), "The comparison PDF should retain the live source title.")
                XCTAssertTrue(text.contains("Readable loopback fixture"))
                XCTAssertTrue(text.contains("live-catalog.fixture"))
                XCTAssertTrue(text.contains("€24.50"))
            }
        }
    }

    func testBackgroundLoaderTimesOutAndCleansUpAnUnfinishedLoad() async {
        let loader = BrowserAgentBackgroundLoader(timeout: 0.05, requestLoader: { _, _ in }, pagePreparation: { _, _ in })
        do {
            _ = try await loader.fetch(
                url: URL(string: "https://timeout.fixture/")!,
                startingDataStore: .nonPersistent(),
                isPrivate: true
            )
            XCTFail("An unfinished load must time out.")
        } catch {
            XCTAssertEqual(error as? BrowserAgentBackgroundLoader.LoadError, .timedOut)
        }
    }

    func testBackgroundLoaderAlreadyCancelledNeverStartsRequest() async {
        var requestStarted = false
        let loader = BrowserAgentBackgroundLoader(
            timeout: 5,
            requestLoader: { _, _ in requestStarted = true },
            pagePreparation: { _, _ in }
        )
        let loadTask = Task { @MainActor in
            try await loader.fetch(
                url: URL(string: "https://cancelled.fixture/")!,
                startingDataStore: .nonPersistent(),
                isPrivate: true
            )
        }
        loadTask.cancel()
        do {
            _ = try await loadTask.value
            XCTFail("An already-cancelled read must not start.")
        } catch is CancellationError {
            XCTAssertFalse(requestStarted)
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func testBackgroundLoaderCancellationAndNavigationFailureResolveOnce() async throws {
        var requestStarted = false
        var loadingView: WKWebView?
        let loader = BrowserAgentBackgroundLoader(
            timeout: 5,
            requestLoader: { webView, _ in
                requestStarted = true
                loadingView = webView
            },
            pagePreparation: { _, _ in }
        )
        let loadTask = Task { @MainActor in
            try await loader.fetch(
                url: URL(string: "https://failure.fixture/")!,
                startingDataStore: .nonPersistent(),
                isPrivate: true
            )
        }
        let failureRequestStarted = await waitUntil { requestStarted }
        XCTAssertTrue(failureRequestStarted)
        let webView = try XCTUnwrap(loadingView)
        loader.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
        loader.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.timedOut))
        do {
            _ = try await loadTask.value
            XCTFail("A failed navigation must fail the read.")
        } catch {
            XCTAssertEqual(error as? BrowserAgentBackgroundLoader.LoadError, .pageUnavailable)
        }

        var cancelledRequestStarted = false
        let cancelledLoader = BrowserAgentBackgroundLoader(
            timeout: 5,
            requestLoader: { _, _ in cancelledRequestStarted = true },
            pagePreparation: { _, _ in }
        )
        let cancelledTask = Task { @MainActor in
            try await cancelledLoader.fetch(
                url: URL(string: "https://cancel.fixture/")!,
                startingDataStore: .nonPersistent(),
                isPrivate: true
            )
        }
        let cancellationIsPending = await waitUntil { cancelledRequestStarted }
        XCTAssertTrue(cancellationIsPending)
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("Cancellation must resolve a pending read.")
        } catch is CancellationError {
            // Expected; the timeout task is cancelled by the same once-only cleanup path.
        }
    }

    func testBackgroundLoaderStaleCancellationAndCallbacksCannotFinishReplacementLoad() async throws {
        var requestViews: [WKWebView] = []
        let loader = BrowserAgentBackgroundLoader(
            timeout: 5,
            requestLoader: { webView, request in
                requestViews.append(webView)
                if requestViews.count == 2 {
                    _ = webView.loadHTMLString("<main>Replacement load succeeded.</main>", baseURL: request.url)
                }
            },
            pagePreparation: { _, _ in }
        )
        let firstTask = Task { @MainActor in
            try await loader.fetch(
                url: URL(string: "https://old.fixture/")!,
                startingDataStore: .nonPersistent(),
                isPrivate: true
            )
        }
        let firstStarted = await waitUntil { requestViews.count == 1 }
        XCTAssertTrue(firstStarted)
        let oldView = try XCTUnwrap(requestViews.first)
        let oldGeneration = try XCTUnwrap(loader.activeGeneration)
        loader.cancelLoad(generation: oldGeneration, webView: oldView)
        do {
            _ = try await firstTask.value
            XCTFail("The old load should be cancelled before replacement.")
        } catch is CancellationError {
            // Expected.
        }

        let secondTask = Task { @MainActor in
            try await loader.fetch(
                url: URL(string: "https://replacement.fixture/")!,
                startingDataStore: .nonPersistent(),
                isPrivate: true
            )
        }
        let replacementStarted = await waitUntil { requestViews.count == 2 }
        XCTAssertTrue(replacementStarted)
        let replacementView = try XCTUnwrap(requestViews.last)
        let replacementGeneration = try XCTUnwrap(loader.activeGeneration)
        XCTAssertFalse(oldView === replacementView)
        XCTAssertNotEqual(oldGeneration, replacementGeneration)

        loader.cancelLoad(generation: oldGeneration, webView: oldView)
        loader.webView(oldView, didFailProvisionalNavigation: nil, withError: URLError(.timedOut))
        loader.webView(oldView, didFinish: nil)
        XCTAssertEqual(loader.activeGeneration, replacementGeneration)

        let replacementPage = try await secondTask.value
        XCTAssertTrue(replacementPage.text.contains("Replacement load succeeded."))
        XCTAssertNil(loader.activeGeneration)
    }

    func testBackgroundLoaderRejectsUnsafeNavigationRedirectAndDownloads() {
        let https = URL(string: "https://fixture.example/redirect")
        let file = URL(fileURLWithPath: "/tmp/not-a-web-page")
        let unsafeSubframeURLs = [
            file,
            URL(string: "javascript:alert(1)"),
            URL(string: "mailto:reader@example.com"),
            URL(string: "about:blank")
        ].compactMap { $0 }
        XCTAssertTrue(BrowserAgentBackgroundLoader.allowsNavigation(
            url: https, isMainFrame: true, hasTargetFrame: true, isDownload: false, method: "GET"
        ))
        XCTAssertTrue(BrowserAgentBackgroundLoader.allowsNavigation(
            url: https, isMainFrame: false, hasTargetFrame: true, isDownload: false, method: "GET"
        ))
        XCTAssertFalse(BrowserAgentBackgroundLoader.allowsNavigation(
            url: file, isMainFrame: true, hasTargetFrame: true, isDownload: false, method: "GET"
        ))
        XCTAssertFalse(BrowserAgentBackgroundLoader.allowsNavigation(
            url: file, isMainFrame: false, hasTargetFrame: true, isDownload: false, method: "GET"
        ))
        XCTAssertFalse(BrowserAgentBackgroundLoader.allowsNavigation(
            url: https, isMainFrame: true, hasTargetFrame: true, isDownload: false, method: "POST"
        ))
        XCTAssertFalse(BrowserAgentBackgroundLoader.allowsNavigation(
            url: https, isMainFrame: true, hasTargetFrame: false, isDownload: false, method: "GET"
        ))
        XCTAssertFalse(BrowserAgentBackgroundLoader.allowsNavigation(
            url: https, isMainFrame: true, hasTargetFrame: true, isDownload: true, method: "GET"
        ))
        XCTAssertFalse(BrowserAgentBackgroundLoader.allowsNavigation(
            url: https, isMainFrame: false, hasTargetFrame: true, isDownload: false, method: "POST"
        ))
        XCTAssertTrue(BrowserAgentBackgroundLoader.allowsResponse(url: https, isMainFrame: true, canShowMIMEType: true))
        XCTAssertTrue(BrowserAgentBackgroundLoader.allowsResponse(url: https, isMainFrame: false, canShowMIMEType: true))
        XCTAssertFalse(BrowserAgentBackgroundLoader.allowsResponse(url: file, isMainFrame: true, canShowMIMEType: true))
        XCTAssertFalse(BrowserAgentBackgroundLoader.allowsResponse(url: file, isMainFrame: false, canShowMIMEType: true))
        XCTAssertFalse(BrowserAgentBackgroundLoader.allowsResponse(url: https, isMainFrame: false, canShowMIMEType: false))
        for unsafeURL in unsafeSubframeURLs {
            XCTAssertFalse(BrowserAgentBackgroundLoader.allowsNavigation(
                url: unsafeURL, isMainFrame: false, hasTargetFrame: true, isDownload: false, method: "GET"
            ), "Unsafe child-frame navigation must be rejected: \(unsafeURL)")
            XCTAssertFalse(BrowserAgentBackgroundLoader.allowsResponse(
                url: unsafeURL, isMainFrame: false, canShowMIMEType: true
            ), "Unsafe child-frame responses must be rejected: \(unsafeURL)")
        }
        XCTAssertFalse(BrowserAgentBackgroundLoader.allowsResponse(
            url: https,
            isMainFrame: true,
            canShowMIMEType: true,
            contentDisposition: "attachment; filename=fixture.html"
        ))
        XCTAssertFalse(BrowserAgentBackgroundLoader.shouldFailForBlockedNavigation(isMainFrame: false))
        XCTAssertTrue(BrowserAgentBackgroundLoader.shouldFailForBlockedNavigation(isMainFrame: true))
    }

    private func toolNames(_ tools: [[String: Any]]) throws -> Set<String> {
        Set(try tools.map { try XCTUnwrap($0["name"] as? String) })
    }

    private func datasetFromToolOutput(_ output: String) throws -> BrowserAgentDataset {
        let start = try XCTUnwrap(output.range(of: "<untrusted_browser_data>\n"))
        let end = try XCTUnwrap(output.range(of: "\n</untrusted_browser_data>", range: start.upperBound..<output.endIndex))
        let json = String(output[start.upperBound..<end.lowerBound])
        return try JSONDecoder().decode(BrowserAgentDataset.self, from: Data(json.utf8))
    }

    private func argumentsJSON(_ arguments: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func uuidAfter(_ prefix: String, in text: String) throws -> String {
        let range = try XCTUnwrap(text.range(of: prefix))
        let value = text[range.upperBound...].prefix { !$0.isWhitespace }
        return try XCTUnwrap(UUID(uuidString: String(value))).uuidString
    }

    private func waitForPendingPrompt(_ gate: BrowserAgentQuestionGate<String>) async -> Bool {
        await waitUntil { gate.pendingPrompt != nil }
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

    private func pageVisibility(of webView: WKWebView) async throws -> String? {
        try await webView.callAsyncJavaScript(
            "return getComputedStyle(document.getElementById('secret')).visibility;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
    }

    private func agentDocumentNonce(in webView: WKWebView) async throws -> String {
        let raw = try await webView.callAsyncJavaScript(
            BrowserAgentPageScript.documentIdentity,
            arguments: [:],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let json = try XCTUnwrap(raw as? String)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["nonce"] as? String)
    }

    func testLocalRepeatedReadPageReturnsGuardTextWithFreshSnapshot() async throws {
        let webView = await loadedWebView("<main><p>Concert article text.</p></main>")
        let profile = BrowserAgentEngineProfile.local(contextSize: 4_096, supportsVision: false)
        var outputs: [String] = []
        let engine = ScriptedEngine(profile: profile) { _, execute, _ in
            outputs.append((await execute("read_page", #"{"offset":0}"#)).text)
            outputs.append((await execute("read_page", #"{"offset":0}"#)).text)
            return "Read twice."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var summary = ""
        controller.start(task: "Read the article", conversation: nil, in: webView, openTab: nil, backend: .localApple) {
            summary = $0
        }

        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        XCTAssertEqual(outputs.count, 2)
        XCTAssertTrue(outputs[0].contains("<page_text"), "The first read must return page text: \(outputs)")
        XCTAssertFalse(outputs[1].contains("<page_text"), "The repeated read must not re-run the page script: \(outputs[1])")
        XCTAssertTrue(outputs[1].contains("Already read."), outputs[1])
        XCTAssertTrue(outputs[1].contains("<page_snapshot>"), "The guard must return a fresh snapshot with current IDs: \(outputs[1])")
        XCTAssertTrue(outputs[1].contains("Interactive elements"), outputs[1])
    }

    func testNonLocalRepeatedReadPageReturnsPageTextBothTimes() async throws {
        let webView = await loadedWebView("<main><p>Concert article text.</p></main>")
        var outputs: [String] = []
        let engine = ScriptedEngine { _, execute, _ in
            outputs.append((await execute("read_page", #"{"offset":0}"#)).text)
            outputs.append((await execute("read_page", #"{"offset":0}"#)).text)
            return "Read twice."
        }
        let controller = BrowserAgentController(engineFactory: { _ in engine })
        defer { controller.stop() }
        var summary = ""
        controller.start(task: "Read the article", conversation: nil, in: webView, openTab: nil) {
            summary = $0
        }

        let completed = await waitUntil { !controller.isRunning && !summary.isEmpty }
        XCTAssertTrue(completed, "summary=\(summary); steps=\(controller.steps.map(\.text))")
        XCTAssertEqual(outputs.count, 2)
        XCTAssertTrue(outputs[0].contains("<page_text"), outputs[0])
        XCTAssertTrue(outputs[1].contains("<page_text"), "Non-Local repeated reads must keep returning page text: \(outputs[1])")
    }

    func testLocalSearchResultsBlockHonorsByteLimitWithWholeLines() {
        let results = [
            (id: 12, title: "Foo Fighters Tour Dates", url: "foofighters.com/tour-dates"),
            (id: 13, title: "Foo Fighters - Live Nation", url: "www.livenation.com/artist/foo"),
            (id: 14, title: "Ticketmaster", url: "www.ticketmaster.com/foo")
        ]
        XCTAssertEqual(BrowserAgentLocalContext.searchResultsBlock([], maximumBytes: 420), "")
        XCTAssertEqual(BrowserAgentLocalContext.searchResultsBlock(results, maximumBytes: 0), "")
        let full = BrowserAgentLocalContext.searchResultsBlock(results, maximumBytes: 420)
        XCTAssertEqual(full.components(separatedBy: "\n"), [
            "Top results (click by id):",
            "[12] link \"Foo Fighters Tour Dates\" → foofighters.com/tour-dates",
            "[13] link \"Foo Fighters - Live Nation\" → www.livenation.com/artist/foo",
            "[14] link \"Ticketmaster\" → www.ticketmaster.com/foo"
        ])
        let headerBytes = "Top results (click by id):".utf8.count
        let firstLineBytes = "\n[12] link \"Foo Fighters Tour Dates\" → foofighters.com/tour-dates".utf8.count
        let tight = BrowserAgentLocalContext.searchResultsBlock(results, maximumBytes: headerBytes + firstLineBytes)
        XCTAssertEqual(tight, "Top results (click by id):\n[12] link \"Foo Fighters Tour Dates\" → foofighters.com/tour-dates")
        XCTAssertLessThanOrEqual(tight.utf8.count, headerBytes + firstLineBytes)
        XCTAssertEqual(BrowserAgentLocalContext.searchResultsBlock(results, maximumBytes: headerBytes + 5), "")
    }

    func testLocalWebSearchOutputCompositionStaysWithinToolResultLimit() {
        let contextSize = 4_096
        let results = [
            (id: 12, title: "Foo Fighters Tour Dates", url: "foofighters.com/tour-dates"),
            (id: 13, title: "Foo Fighters - Live Nation", url: "www.livenation.com/artist/foo"),
            (id: 14, title: "Ticketmaster", url: "www.ticketmaster.com/foo"),
            (id: 15, title: "Songkick", url: "www.songkick.com/foo"),
            (id: 16, title: "Bandsintown", url: "www.bandsintown.com/foo")
        ]
        let block = BrowserAgentLocalContext.searchResultsBlock(results, maximumBytes: 420)
        XCTAssertFalse(block.isEmpty)
        XCTAssertLessThanOrEqual(block.utf8.count, 420)
        let snapshotBudget = BrowserAgentLocalContext.snapshotByteLimit(contextSize: contextSize, forToolOutput: true)
        let snapshotBytes = max(0, snapshotBudget - (block.utf8.count + 1))
        let markerBytes = "\n\n<page_snapshot>".utf8.count
        let closingBytes = "\n</page_snapshot>".utf8.count
        let worstOutputBytes = 96 + markerBytes + block.utf8.count + 1 + snapshotBytes + closingBytes
        XCTAssertLessThanOrEqual(
            worstOutputBytes,
            BrowserAgentLocalContext.toolResultByteLimit(contextSize: contextSize)
        )
    }

    private func loadedWebView(_ html: String) async -> WKWebView {
        await loadedWebView(html, baseURL: URL(string: "https://agent-loop.fixture/")!)
    }

    private func loadedWebView(_ html: String, baseURL: URL) async -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        await loadHTML(html, into: webView, baseURL: baseURL)
        webView.navigationDelegate = nil
        return webView
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

    private func waitUntilAsync(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<800 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}
