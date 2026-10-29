import Foundation
import UIKit
import UniformTypeIdentifiers
import WebKit

typealias BrowserIntentAIGenerator = @MainActor (String, String, AIModelBackend) async throws -> String

@MainActor
final class BrowserIntentExecutor {
    struct Callbacks {
        var translatePage: (BrowserTab, String, @escaping @MainActor () -> Bool) async throws -> Void = { _, _, _ in
            throw BrowserIntentError.unsupported("Page translation is not available right now.")
        }
        var translationPageIsCurrent: (BrowserTab, WKWebView, URL) -> @MainActor () -> Bool = { _, webView, url in
            { [weak webView] in
                guard let webView else { return false }
                return webView.url == url
            }
        }
        var openSplit: (UUID, UUID) -> Void = { _, _ in }
        var endSplit: () -> Void = {}
        var sendToWebAI: (
            WebAIProvider, String, String, BrowserTab, BrowserAgentPageContextBinding
        ) -> Bool = { _, _, _, _, _ in false }
        var onTabSelected: (UUID) -> Void = { _ in }
    }

    typealias ScriptEvaluator = @MainActor (WKWebView, String, [String: Any]) async throws -> Any?
    typealias PagePDFExporter = @MainActor (WKWebView) async throws -> Data
    typealias ScreenshotCapturer = @MainActor (WKWebView) async throws -> Data
    typealias DownloadStarter = @MainActor (URL, UUID, @escaping @MainActor () -> Bool) async throws -> Void
    typealias PasteboardWriter = @MainActor (String) -> Void

    let viewModel: BrowserViewModel
    let downloadManager: BrowserDownloadManager
    let privacy: BrowserAgentAutofillPrivacy
    let historyStore: HistoryStore
    let isCurrent: @MainActor @Sendable () -> Bool
    let backendProvider: () -> AIModelBackend
    let aiGenerator: BrowserIntentAIGenerator
    let evaluateScript: ScriptEvaluator
    let evaluatePageScript: @MainActor (WKWebView, String) async throws -> Any?
    let exportPagePDF: PagePDFExporter
    let captureScreenshotData: ScreenshotCapturer
    let startDownload: DownloadStarter
    let writePasteboard: PasteboardWriter
    let callbacks: Callbacks
    let calendar: Calendar

    init(
        viewModel: BrowserViewModel,
        downloadManager: BrowserDownloadManager,
        privacy: BrowserAgentAutofillPrivacy? = nil,
        historyStore: HistoryStore? = nil,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        backendProvider: @escaping @MainActor () -> AIModelBackend,
        aiGenerator: @escaping BrowserIntentAIGenerator = BrowserIntentAIService.generate,
        callbacks: Callbacks? = nil,
        evaluateScript: ScriptEvaluator? = nil,
        evaluatePageScript: (@MainActor (WKWebView, String) async throws -> Any?)? = nil,
        exportPDF: PagePDFExporter? = nil,
        captureScreenshot: ScreenshotCapturer? = nil,
        startDownload: DownloadStarter? = nil,
        writePasteboard: PasteboardWriter? = nil,
        calendar: Calendar = .current
    ) {
        self.viewModel = viewModel
        self.downloadManager = downloadManager
        self.privacy = privacy ?? .shared
        self.historyStore = historyStore ?? .shared
        self.isCurrent = isCurrent
        self.backendProvider = backendProvider
        self.aiGenerator = aiGenerator
        self.callbacks = callbacks ?? Callbacks()
        self.evaluateScript = evaluateScript ?? { webView, script, arguments in
            try await webView.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                contentWorld: BrowserAgentPageScript.world
            )
        }
        self.evaluatePageScript = evaluatePageScript ?? { webView, script in
            try await webView.evaluateJavaScript(script)
        }
        self.exportPagePDF = exportPDF ?? { webView in
            try await BrowserAgentExportService.pagePDF(from: webView)
        }
        self.captureScreenshotData = captureScreenshot ?? { webView in
            try await BrowserAgentScreenshotEncoder.capture(webView)
        }
        self.startDownload = startDownload ?? { url, tabID, current in
            let adapter = BrowserAgentBrowserAdapter(
                viewModel: viewModel,
                downloadManager: downloadManager,
                onTabSelected: { _ in }
            )
            guard let tab = viewModel.tabs.first(where: { $0.id == tabID }),
                  let webView = tab.liveWebView, adapter.beginRun(in: webView) else {
                throw BrowserIntentError.stalePage
            }
            defer { adapter.endRun() }
            _ = try await adapter.startDownload(url: url.absoluteString, sourceTabID: tabID, isCurrent: current)
        }
        self.calendar = calendar
        self.writePasteboard = writePasteboard ?? { text in
            UIPasteboard.general.setItems(
                [[UTType.plainText.identifier: text]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
            )
        }
    }

    func execute(
        _ command: BrowserIntentCommand,
        confirm: BrowserIntentConfirmation
    ) async throws -> BrowserIntentOutput {
        try Task.checkCancellation()
        guard isCurrent() else { throw BrowserIntentError.stalePage }
        await waitForSelectedPageToFinishLoading()
        switch command {
        case .openURL, .search:
            return try executeOpenCommand(command)
        case .findOnPageOrSearch(let query):
            return try await findOnPageOrSearch(query)
        case .newTab, .newPrivateTab, .reopenClosedTab, .closeCurrentTab, .closeGroup,
             .switchGroup, .switchToTab, .moveToGroup, .openSplit, .endSplit:
            return try await executeTabCommand(command, confirm: confirm)
        case .back, .forward, .reload, .setDesktop:
            return try executePageNavigation(command)
        case .setReader, .translate, .findText:
            return try await executePageModeCommand(command)
        case .bookmark, .readingList, .exportPDF, .copyPageLink, .screenshot:
            return try await executePageOutputCommand(command, confirm: confirm)
        case .openHistoryMatch, .searchesOn:
            return try await executeHistoryCommand(command, confirm: confirm)
        case .summarize, .askLocal, .sendToWebAI:
            return try await executeAICommand(command, confirm: confirm)
        case .downloadURL, .downloadVideo:
            return try await executeDownloadCommand(command, confirm: confirm)
        case .loadURLInTab, .closeTabs, .deleteBookmarks, .clearHistory, .renameBookmark:
            return try await executeSchemaCommand(command, confirm: confirm)
        }
    }

    /// Shortcuts run actions back to back, so the page from the previous action is often still loading.
    /// Give it up to `timeout` seconds to finish instead of refusing at once; the page checks still run after.
    func waitForSelectedPageToFinishLoading(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled,
              let selectedID = viewModel.selectedTabID,
              let tab = viewModel.tabs.first(where: { $0.id == selectedID }),
              tab.liveWebView?.isLoading == true {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func executeOpenCommand(_ command: BrowserIntentCommand) throws -> BrowserIntentOutput {
        switch command {
        case .openURL(let url):
            return try openRegularTab(url: url, text: "Opened the website in a new tab.")
        case .search(let rawQuery):
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query.utf8.count <= 4_096 else {
                throw BrowserIntentError.invalidInput("Provide search text between 1 and 4096 UTF-8 bytes.")
            }
            guard let url = viewModel.defaultSearchEngine.searchURL(for: query) else {
                throw BrowserIntentError.invalidInput("The default search engine could not build a search URL.")
            }
            return try openGeneratedSearchTab(url: url, text: "Searched for \(query) in a new tab.")
        default:
            throw BrowserIntentError.unsupported("Unsupported command.")
        }
    }

    static let maximumOutputCharacters = 20_000
    static let maximumGeneratedSearchURLCharacters = 3 * 4_096 + 256

    func output(_ text: String, fileData: Data? = nil, filename: String? = nil) -> BrowserIntentOutput {
        let redacted = privacy.redactKnownValues(text)
        let bounded = redacted.count > Self.maximumOutputCharacters
            ? String(redacted.prefix(Self.maximumOutputCharacters))
            : redacted
        return BrowserIntentOutput(text: bounded, fileData: fileData, filename: filename)
    }

    func regularTabs() -> [BrowserTab] {
        viewModel.tabs.filter { !$0.isIncognito && $0.webAIProvider == nil }
    }

    func openRegularTab(url: URL, text: String) throws -> BrowserIntentOutput {
        guard AgentTaskURLParser.isAllowedStartURL(url) else {
            throw BrowserIntentError.invalidInput("Provide a valid http or https address without credentials.")
        }
        let tab = BrowserTab(
            title: url.host ?? "New Tab",
            url: url,
            isIncognito: false
        )
        viewModel.tabs.append(tab)
        viewModel.selectTab(tab)
        viewModel.navigate(to: url, in: tab)
        callbacks.onTabSelected(tab.id)
        var result = output(text)
        result.resultTabID = tab.id
        return result
    }

    func openGeneratedSearchTab(url: URL, text: String) throws -> BrowserIntentOutput {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              url.absoluteString.count <= Self.maximumGeneratedSearchURLCharacters else {
            throw BrowserIntentError.invalidInput("The default search engine could not build a search URL.")
        }
        let tab = BrowserTab(
            title: url.host ?? "New Tab",
            url: url,
            isIncognito: false
        )
        viewModel.tabs.append(tab)
        viewModel.selectTab(tab)
        viewModel.navigate(to: url, in: tab)
        callbacks.onTabSelected(tab.id)
        return output(text)
    }

    struct PageBinding {
        let tab: BrowserTab
        let webView: WKWebView
        let url: URL
        let contextBinding: BrowserAgentPageContextBinding
        var nonce: String?
    }

    func boundPageWithNonce() async throws -> PageBinding {
        var binding = try pageBinding()
        binding.nonce = try await documentNonce(of: binding.webView)
        try validateBinding(binding)
        return binding
    }

    func pageBinding() throws -> PageBinding {
        try Task.checkCancellation()
        guard isCurrent() else { throw BrowserIntentError.stalePage }
        guard let selectedID = viewModel.selectedTabID,
              let tab = viewModel.tabs.first(where: { $0.id == selectedID }),
              !tab.isIncognito,
              tab.webAIProvider == nil else {
            throw BrowserIntentError.noEligiblePage
        }
        guard let webView = tab.liveWebView else { throw BrowserIntentError.pageNotLoaded }
        guard let url = webView.url,
              AgentTaskURLParser.isAllowedStartURL(url) else {
            throw BrowserIntentError.noEligiblePage
        }
        guard !webView.isLoading else { throw BrowserIntentError.pageStillLoading }
        return PageBinding(
            tab: tab,
            webView: webView,
            url: url,
            contextBinding: BrowserAgentPageContextBinding(tabID: tab.id, webView: webView, url: url)
        )
    }

    func validateBinding(_ binding: PageBinding) throws {
        try Task.checkCancellation()
        guard isCurrent(),
              viewModel.selectedTabID == binding.tab.id,
              viewModel.tabs.first(where: { $0.id == binding.tab.id }) === binding.tab,
              binding.tab.liveWebView === binding.webView,
              !binding.tab.isIncognito,
              binding.tab.webAIProvider == nil,
              binding.webView.url == binding.url,
              !binding.webView.isLoading else {
            throw BrowserIntentError.stalePage
        }
    }

    func revalidate(_ binding: PageBinding, checkNonce: Bool = false) async throws {
        try validateBinding(binding)
        if checkNonce {
            guard let expected = binding.nonce else { throw BrowserIntentError.stalePage }
            let current = try await documentNonce(of: binding.webView)
            guard current == expected else { throw BrowserIntentError.stalePage }
            try validateBinding(binding)
        }
    }

}
