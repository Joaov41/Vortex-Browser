import Foundation
import UIKit
import UniformTypeIdentifiers
import WebKit

@MainActor
extension BrowserIntentExecutor {
    func executeHistoryCommand(
        _ command: BrowserIntentCommand,
        confirm: BrowserIntentConfirmation
    ) async throws -> BrowserIntentOutput {
        switch command {
        case .openHistoryMatch(let query):
            return try await openHistoryMatch(query, confirm: confirm)
        case .searchesOn(let date):
            return try await searchesOn(date, confirm: confirm)
        default:
            throw BrowserIntentError.unsupported("Unsupported command.")
        }
    }

    func executeAICommand(
        _ command: BrowserIntentCommand,
        confirm: BrowserIntentConfirmation
    ) async throws -> BrowserIntentOutput {
        switch command {
        case .summarize:
            return try await summarize(confirm: confirm)
        case .askLocal(let question):
            return try await askLocal(question)
        case .sendToWebAI(let provider):
            return try await sendToWebAI(provider, confirm: confirm)
        default:
            throw BrowserIntentError.unsupported("Unsupported command.")
        }
    }

    func executeDownloadCommand(
        _ command: BrowserIntentCommand,
        confirm: BrowserIntentConfirmation
    ) async throws -> BrowserIntentOutput {
        switch command {
        case .downloadURL(let url):
            return try await downloadURL(url, confirm: confirm)
        case .downloadVideo:
            return try await downloadVideo(confirm: confirm)
        default:
            throw BrowserIntentError.unsupported("Unsupported command.")
        }
    }

    func openHistoryMatch(_ rawQuery: String, confirm: BrowserIntentConfirmation) async throws -> BrowserIntentOutput {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 240 else {
            throw BrowserIntentError.invalidInput("Provide a history search between 1 and 240 characters.")
        }
        try rejectPrivateContext()
        guard let match = historyStore.entries.first(where: {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(query)
        }) else {
            throw BrowserIntentError.emptyResult("No history page matched \(query).")
        }
        guard AgentTaskURLParser.isAllowedStartURL(match.url) else {
            throw BrowserIntentError.emptyResult("The matching history page cannot be opened by this action.")
        }
        try await confirm("Open the most recent page matching \"\(String(query.prefix(120)))\" from history?")
        try Task.checkCancellation()
        guard isCurrent() else { throw BrowserIntentError.stalePage }
        try rejectPrivateContext()
        return try openRegularTab(url: match.url, text: "Opened \(match.url.host ?? "the page") from history.")
    }

    func searchesOn(_ date: Date, confirm: BrowserIntentConfirmation) async throws -> BrowserIntentOutput {
        try rejectPrivateContext()
        try await confirm("Share recorded web searches for this date with Shortcuts?")
        try Task.checkCancellation()
        guard isCurrent() else { throw BrowserIntentError.stalePage }
        try rejectPrivateContext()
        guard let interval = calendar.dateInterval(of: .day, for: date) else {
            throw BrowserIntentError.invalidInput("Could not resolve that date.")
        }
        var seen = Set<String>()
        var queries: [String] = []
        for entry in historyStore.entries where entry.visitedAt >= interval.start && entry.visitedAt < interval.end {
            guard let query = Self.recordedSearchQuery(in: entry.url),
                  !seen.contains(query.lowercased()) else { continue }
            seen.insert(query.lowercased())
            queries.append(query)
            if queries.count >= 30 { break }
        }
        guard !queries.isEmpty else {
            return output("Searches recorded in regular browsing history\n(no recorded searches on that date)")
        }
        let header = "Searches recorded in regular browsing history"
        return output(([header] + queries).joined(separator: "\n"))
    }

    static func recordedSearchQuery(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased() else { return nil }
        let path = components.path
        let isSearchURL: Bool
        switch host {
        case "google.com", "www.google.com":
            isSearchURL = path == "/search"
        case "duckduckgo.com", "www.duckduckgo.com":
            isSearchURL = path.isEmpty || path == "/"
        default:
            return nil
        }
        guard isSearchURL else { return nil }
        guard let value = components.queryItems?.first(where: { $0.name == "q" })?.value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    func summarize(confirm: BrowserIntentConfirmation) async throws -> BrowserIntentOutput {
        let binding = try await guardedPageDataBinding()
        try await confirm(
            "Send this page's readable text to your selected AI model and return its summary to Shortcuts?"
        )
        try await revalidate(binding, checkNonce: true)
        guard !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        let backend = backendProvider()
        let maxChars = backend == .localApple ? 1_800 : 6_000
        _ = try await callAgentJSON(
            BrowserAgentPageScript.snapshot,
            ["maxElements": 1, "maxText": 1],
            in: binding.webView
        )
        let read = try await callAgentJSON(
            BrowserAgentPageScript.readText,
            ["offset": 0, "maxChars": maxChars, "redactValues": privacy.redactionValues(tabID: binding.tab.id)],
            in: binding.webView
        )
        try await revalidate(binding, checkNonce: true)
        guard !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        let rawText = (read["text"] as? String ?? "")
        let text = privacy.redactPotentiallyTruncated(rawText, wasTruncated: true)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserIntentError.emptyResult("The page has no readable text to summarize.")
        }
        let result = try await aiGenerator(
            BrowserIntentAIService.summaryInstructions,
            BrowserIntentAIService.summaryPromptBody(text: text),
            backend
        )
        try await revalidate(binding, checkNonce: true)
        guard !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        let total = (read["total"] as? NSNumber)?.intValue ?? 0
        let suffix = total > text.utf16.count
            ? "\n\nBased on the first \(text.utf16.count) characters of readable page text."
            : ""
        var summary = output(result + suffix)
        summary.pageTitle = privacy.redactKnownValues(binding.tab.title)
        summary.pageURL = binding.url
        return summary
    }

    func askLocal(_ rawQuestion: String) async throws -> BrowserIntentOutput {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.utf8.count <= 4_096 else {
            throw BrowserIntentError.invalidInput("Provide a question between 1 and 4096 UTF-8 bytes.")
        }
        let safeQuestion = privacy.redactKnownValues(question)
        let result = try await aiGenerator(
            BrowserIntentAIService.localQuestionInstructions,
            safeQuestion,
            .localApple
        )
        try Task.checkCancellation()
        guard isCurrent() else { throw BrowserIntentError.stalePage }
        return output(result)
    }

    func sendToWebAI(
        _ provider: BrowserIntentWebProvider,
        confirm: BrowserIntentConfirmation
    ) async throws -> BrowserIntentOutput {
        let binding = try await guardedPageDataBinding()
        let webProvider = provider.webAIProvider
        try await confirm("Send this page's readable text to \(webProvider.displayName) on the web?")
        try await revalidate(binding, checkNonce: true)
        guard !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        _ = try await callAgentJSON(
            BrowserAgentPageScript.snapshot,
            ["maxElements": 1, "maxText": 1],
            in: binding.webView
        )
        let read = try await callAgentJSON(
            BrowserAgentPageScript.readText,
            ["offset": 0, "maxChars": 6_000, "redactValues": privacy.redactionValues(tabID: binding.tab.id)],
            in: binding.webView
        )
        try await revalidate(binding, checkNonce: true)
        guard !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        let rawText = (read["text"] as? String ?? "")
        let text = privacy.redactPotentiallyTruncated(rawText, wasTruncated: true)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserIntentError.emptyResult("The page has no readable text to send.")
        }
        let composedPrompt = BrowserIntentAIService.summaryInstructions
            + "\n\n" + BrowserIntentAIService.summaryPromptBody(text: text)
        let sent = callbacks.sendToWebAI(
            webProvider,
            "Summarize this page excerpt.",
            composedPrompt,
            binding.tab,
            binding.contextBinding
        )
        guard sent else {
            throw BrowserIntentError.emptyResult("Vortyra could not start the \(webProvider.displayName) request.")
        }
        return output("Sent the page excerpt to \(webProvider.displayName); view its response in Vortyra.")
    }

    func downloadURL(_ url: URL, confirm: BrowserIntentConfirmation) async throws -> BrowserIntentOutput {
        guard AgentTaskURLParser.isAllowedStartURL(url) else {
            throw BrowserIntentError.invalidInput("Provide a valid http or https address to download.")
        }
        let binding = try await boundPageWithNonce()
        let displayURL = String(url.absoluteString.prefix(240))
        try await confirm("Download \(displayURL) in Vortyra?")
        try await revalidate(binding, checkNonce: true)
        try await startDownload(url, binding.tab.id, makePageBoundValidity(binding))
        try await revalidate(binding)
        return output("Download started in Vortyra; finish saving it in the browser.")
    }

    func downloadVideo(confirm: BrowserIntentConfirmation) async throws -> BrowserIntentOutput {
        let binding = try await guardedPageDataBinding()
        let raw = try await evaluateScript(binding.webView, Self.videoSourcesScript, [:])
        try await revalidate(binding, checkNonce: true)
        guard !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        guard let string = raw as? String,
              let data = string.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            throw BrowserIntentError.emptyResult("Could not inspect the page for video sources.")
        }
        let candidates = Set(list.prefix(20).compactMap { candidate -> URL? in
            guard let url = URL(string: candidate),
                  AgentTaskURLParser.isAllowedStartURL(url) else { return nil }
            let path = url.pathExtension.lowercased()
            guard path != "m3u8", path != "mpd" else { return nil }
            return url
        })
        guard candidates.count == 1, let videoURL = candidates.first else {
            throw BrowserIntentError.emptyResult(
                candidates.isEmpty
                    ? "No direct video file was found on the page. Choose a video URL manually."
                    : "More than one video source was found. Choose a video URL manually."
            )
        }
        let displayURL = String(videoURL.absoluteString.prefix(240))
        try await confirm("Download the video from \(displayURL) in Vortyra?")
        try await revalidate(binding, checkNonce: true)
        guard !privacy.withholdsPageData(tabID: binding.tab.id) else {
            throw BrowserIntentError.privacyProtected
        }
        try await startDownload(videoURL, binding.tab.id, makePageBoundValidity(binding))
        try await revalidate(binding)
        return output("Download started in Vortyra; finish saving it in the browser.")
    }

    private static let videoSourcesScript = #"""
    return (function() {
      const out = [];
      const videos = document.querySelectorAll('video');
      for (const video of videos) {
        if (out.length >= 20) break;
        if (video.mediaKeys) continue;
        const push = value => {
          if (typeof value !== 'string' || value.length === 0 || out.length >= 20) return;
          try {
            const resolved = new URL(value, document.baseURI).href;
            if (!out.includes(resolved)) out.push(resolved);
          } catch (error) {}
        };
        push(video.currentSrc);
        push(video.getAttribute('src'));
        for (const source of video.querySelectorAll('source')) push(source.getAttribute('src'));
      }
      return JSON.stringify(out);
    })();
    """#
}
