import Foundation
import UIKit
import UniformTypeIdentifiers
import WebKit

@MainActor
extension BrowserIntentExecutor {
    func executePageNavigation(_ command: BrowserIntentCommand) throws -> BrowserIntentOutput {
        switch command {
        case .back:
            let binding = try pageBinding()
            guard binding.webView.canGoBack else {
                throw BrowserIntentError.emptyResult("There is no page to go back to.")
            }
            binding.tab.navigateBack()
            return output("Requested going back in the current tab.")
        case .forward:
            let binding = try pageBinding()
            guard binding.webView.canGoForward else {
                throw BrowserIntentError.emptyResult("There is no page to go forward to.")
            }
            binding.tab.navigateForward()
            return output("Requested going forward in the current tab.")
        case .reload:
            let binding = try pageBinding()
            binding.webView.reload()
            return output("Requested a reload of the current page.")
        case .setDesktop(let enabled):
            let binding = try pageBinding()
            binding.tab.setUserAgentPreference(enabled)
            binding.webView.reload()
            let mode = enabled ? "Desktop" : "Mobile"
            return output("\(mode) site mode requested for this tab.")
        default:
            throw BrowserIntentError.unsupported("Unsupported command.")
        }
    }

    func executePageModeCommand(_ command: BrowserIntentCommand) async throws -> BrowserIntentOutput {
        switch command {
        case .setReader(let enabled):
            return try await setReader(enabled)
        case .translate(let tag):
            return try await translate(tag)
        case .findText(let query):
            return try await findText(query)
        default:
            throw BrowserIntentError.unsupported("Unsupported command.")
        }
    }

    func executePageOutputCommand(
        _ command: BrowserIntentCommand,
        confirm: BrowserIntentConfirmation
    ) async throws -> BrowserIntentOutput {
        switch command {
        case .bookmark(let folderID):
            return try bookmark(folderID: folderID)
        case .readingList:
            return try readingList()
        case .exportPDF:
            return try await exportPDF(confirm: confirm)
        case .copyPageLink:
            return try copyPageLink()
        case .screenshot:
            return try await screenshot(confirm: confirm)
        default:
            throw BrowserIntentError.unsupported("Unsupported command.")
        }
    }

    func setReader(_ enabled: Bool) async throws -> BrowserIntentOutput {
        let binding = try await boundPageWithNonce()
        if binding.tab.isReaderMode == enabled {
            return output(enabled ? "Reader mode is already on." : "Reader mode is already off.")
        }
        let raw = try await evaluatePageScript(binding.webView, ReaderModeService.toggleScript)
        try await revalidate(binding, checkNonce: true)
        guard (raw as? Bool) == enabled else {
            throw BrowserIntentError.emptyResult("The page could not change reader mode.")
        }
        binding.tab.isReaderMode = enabled
        return output(enabled ? "Reader mode is on." : "Reader mode is off.")
    }

    func translate(_ rawTag: String) async throws -> BrowserIntentOutput {
        let tag = Self.languageTag(for: rawTag)
        guard tag.range(of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil,
              Locale.Language(identifier: tag).languageCode != nil else {
            throw BrowserIntentError.invalidInput("Use a valid language tag such as pt or pt-BR.")
        }
        let binding = try await boundPageWithNonce()
        let cancelled = BrowserIntentCancelFlag()
        let tab = binding.tab
        let webView = binding.webView
        let url = binding.url
        let windowPredicate = callbacks.translationPageIsCurrent(tab, webView, url)
        let predicate: @MainActor () -> Bool = { [weak viewModel = viewModel, weak tab, weak webView] in
            guard let viewModel, let tab, let webView, !cancelled.value else { return false }
            return windowPredicate()
                && viewModel.tabs.first(where: { $0.id == tab.id }) === tab
                && tab.liveWebView === webView
                && webView.url == url
                && !webView.isLoading
        }
        do {
            try await withTaskCancellationHandler {
                try await callbacks.translatePage(tab, tag, predicate)
            } onCancel: {
                Task { @MainActor in cancelled.value = true }
            }
            try await revalidate(binding, checkNonce: true)
        } catch {
            cancelled.value = true
            throw error
        }
        return output("Translation prepared; Vortyra may ask to download a language. Check the page for completion.")
    }

    func findText(_ rawQuery: String) async throws -> BrowserIntentOutput {
        try await findTextCountingMatches(rawQuery).output
    }

    /// Accepts a language tag ("pt", "pt-BR") or a language name in English or the device language
    /// ("Portuguese", "português"), which is what people type into Shortcuts. Anything else is returned
    /// unchanged for the tag check to reject.
    nonisolated static func languageTag(for raw: String, locale: Locale = .current) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) == nil else {
            return trimmed
        }
        let wanted = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let english = Locale(identifier: "en")
        for code in Locale.LanguageCode.isoLanguageCodes where code.identifier.count == 2 {
            for naming in [english, locale, Locale(identifier: code.identifier)] {
                guard let name = naming.localizedString(forLanguageCode: code.identifier) else { continue }
                if name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == wanted {
                    return code.identifier
                }
            }
        }
        return trimmed
    }

    /// Finds `rawQuery` on the page on screen and opens the find bar on the matches. Only when the text
    /// isn't on the page, or no web page is open, does it run a web search in a new tab, and it says why.
    func findOnPageOrSearch(_ rawQuery: String) async throws -> BrowserIntentOutput {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason: String
        do {
            let found = try await findTextCountingMatches(query)
            if found.matches > 0 { return found.output }
            reason = "\(query) isn't on this page, so I searched the web for it."
        } catch BrowserIntentError.invalidInput(let message) {
            throw BrowserIntentError.invalidInput(message)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            reason = "No web page was open to search, so I searched the web for \(query)."
        }
        _ = try await execute(.search(query), confirm: { _ in })
        return output(reason)
    }

    private func findTextCountingMatches(_ rawQuery: String) async throws -> (matches: Int, output: BrowserIntentOutput) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 240 else {
            throw BrowserIntentError.invalidInput("Provide search text between 1 and 240 characters.")
        }
        let binding = try await boundPageWithNonce()
        _ = try await callAgentJSON(
            BrowserAgentPageScript.snapshot,
            ["maxElements": 1, "maxText": 1],
            in: binding.webView
        )
        try await revalidate(binding, checkNonce: true)
        let result = try await callAgentJSON(
            BrowserAgentInteractionScript.find,
            ["query": query, "redactValues": privacy.redactionValues(tabID: binding.tab.id)],
            in: binding.webView
        )
        try await revalidate(binding, checkNonce: true)
        if let error = result["error"] as? String {
            throw BrowserIntentError.emptyResult(error)
        }
        let count = (result["count"] as? NSNumber)?.intValue ?? 0
        guard result["found"] as? Bool == true, count > 0 else {
            return (0, output("No matches for \(query) on the page."))
        }
        // Prefer the system find bar: it highlights every match and lets the user step through them.
        if let interaction = binding.webView.findInteraction {
            _ = try? await callAgentJSON(BrowserAgentInteractionScript.clearHighlights, [:], in: binding.webView)
            interaction.searchText = query
            interaction.presentFindNavigator(showingReplace: false)
            return (count, output("Found \(count) match\(count == 1 ? "" : "es") for \(query). Use the arrows in the find bar to move between them."))
        }
        let highlighted = result["highlighted"] as? Bool == true
        let suffix = highlighted ? " and highlighted them" : ""
        return (count, output("Found \(count) match\(count == 1 ? "" : "es") for \(query)\(suffix)."))
    }

    func bookmark(folderID: UUID?) throws -> BrowserIntentOutput {
        let binding = try pageBinding()
        guard !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        let existingFolder = viewModel.favorites.first(where: { $0.url == binding.url })?.folderID
        let adapter = makeAdapter()
        guard adapter.beginRun(in: binding.webView) else { throw BrowserIntentError.stalePage }
        defer { adapter.endRun() }
        let favoriteID = try adapter.addBookmark(forTabID: binding.tab.id.uuidString, folderID: folderID ?? existingFolder)
        try adapter.validateSource(tabID: binding.tab.id)
        var result = output("Saved the page to Favorites.")
        if let favoriteID, let favorite = viewModel.favorites.first(where: { $0.id == favoriteID }) {
            result.savedBookmark = BrowserIntentSavedBookmark(id: favorite.id, title: favorite.title, url: favorite.url)
        }
        return result
    }

    func readingList() throws -> BrowserIntentOutput {
        let binding = try pageBinding()
        guard !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        let folder = viewModel.favoriteFolders.first {
            $0.parentID == nil && $0.title.caseInsensitiveCompare("Reading List") == .orderedSame
        } ?? viewModel.createFavoriteFolder(named: "Reading List", in: nil)
        let adapter = makeAdapter()
        guard adapter.beginRun(in: binding.webView) else { throw BrowserIntentError.stalePage }
        defer { adapter.endRun() }
        _ = try adapter.addBookmark(forTabID: binding.tab.id.uuidString, folderID: folder.id)
        try adapter.validateSource(tabID: binding.tab.id)
        return output("Saved the page to Reading List.")
    }

    func guardedPageDataBinding() async throws -> PageBinding {
        let binding = try await boundPageWithNonce()
        guard !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        return binding
    }

    func exportPDF(confirm: BrowserIntentConfirmation) async throws -> BrowserIntentOutput {
        let binding = try await guardedPageDataBinding()
        try await confirm("Export the current page to Shortcuts? It may contain personal information.")
        try await revalidate(binding, checkNonce: true)
        guard privacy.allowsScreenshot(tabID: binding.tab.id, webView: binding.webView),
              !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        let data = try await exportPagePDF(binding.webView)
        try await revalidate(binding, checkNonce: true)
        guard privacy.allowsScreenshot(tabID: binding.tab.id, webView: binding.webView),
              !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        return output(
            "Prepared the page PDF. Add Save File in Shortcuts to keep it.",
            fileData: data,
            filename: "Webpage.pdf"
        )
    }

    func screenshot(confirm: BrowserIntentConfirmation) async throws -> BrowserIntentOutput {
        let binding = try await guardedPageDataBinding()
        guard privacy.allowsScreenshot(tabID: binding.tab.id, webView: binding.webView) else {
            throw BrowserIntentError.privacyProtected
        }
        try await confirm("Capture the current page as an image for Shortcuts? It may contain personal information.")
        try await revalidate(binding, checkNonce: true)
        guard privacy.allowsScreenshot(tabID: binding.tab.id, webView: binding.webView),
              !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        let data = try await captureScreenshotData(binding.webView)
        try await revalidate(binding, checkNonce: true)
        guard privacy.allowsScreenshot(tabID: binding.tab.id, webView: binding.webView),
              !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        return output(
            "Prepared the page image. Add Save File or Save to Photo Album in Shortcuts to keep it.",
            fileData: data,
            filename: "Webpage.jpg"
        )
    }

    func copyPageLink() throws -> BrowserIntentOutput {
        let binding = try pageBinding()
        guard !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        guard let safeURL = BrowserAgentExtractionParser.safeSourceURL(binding.url) else {
            throw BrowserIntentError.noEligiblePage
        }
        let title = privacy.redactKnownValues(binding.webView.title ?? binding.tab.title)
        let boundedTitle = String(title.prefix(160))
        let text = "\(boundedTitle)\n\(safeURL.absoluteString)"
        let safeText = privacy.redactKnownValues(text)
        writePasteboard(safeText)
        return output(safeText)
    }
}

@MainActor
extension BrowserIntentExecutor {
    func documentNonce(of webView: WKWebView) async throws -> String {
        let raw = try await evaluateScript(webView, BrowserAgentPageScript.documentIdentity, [:])
        guard let string = raw as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nonce = object["nonce"] as? String, !nonce.isEmpty else {
            throw BrowserIntentError.stalePage
        }
        return nonce
    }

    func callAgentJSON(
        _ script: String,
        _ arguments: [String: Any],
        in webView: WKWebView
    ) async throws -> [String: Any] {
        let raw = try await evaluateScript(webView, script, arguments)
        guard let string = raw as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserIntentError.emptyResult("The page did not return a readable result.")
        }
        return object
    }

    func makePageBoundValidity(_ binding: PageBinding) -> @MainActor () -> Bool {
        { [weak tab = binding.tab, weak webView = binding.webView] in
            guard let tab, let webView else { return false }
            guard self.isCurrent() else { return false }
            return self.viewModel.tabs.first(where: { $0.id == tab.id }) === tab
                && tab.liveWebView === webView
                && !tab.isIncognito
                && tab.webAIProvider == nil
                && webView.url == binding.url
                && !webView.isLoading
        }
    }

    func makeAdapter() -> BrowserAgentBrowserAdapter {
        BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: downloadManager,
            onTabSelected: callbacks.onTabSelected
        )
    }
}

@MainActor
private final class BrowserIntentCancelFlag {
    var value = false
}
