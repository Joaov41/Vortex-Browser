import Foundation
import WebKit

private func browserAIExtractLog(_ message: @autoclosure () -> String) {}

enum PageContentExtractor {
    struct ExtractedPageContent: Sendable {
        let title: String?
        let body: String
        let redditCommentCount: Int?
        let redditCoverage: RedditCoverageMetadata?

        var formattedForAIContext: String {
            let coveragePrefix = redditCoverage.map { "\($0.contextDescription)\n\n" } ?? ""
            if let title, !title.isEmpty {
                return "Title: \(title)\n\nBody:\n\(coveragePrefix)\(body)"
            }
            return "Body:\n\(coveragePrefix)\(body)"
        }
    }

    private static let redditSummaryTimeout: TimeInterval = 30
    private static let redditFastQueryTimeout: TimeInterval = 20

    private static let articleExtractionScript: String = {
        """
        (function() {
          try {
            function normalize(text) {
              return (text || '').replace(/\\s+/g, ' ').trim();
            }

            var title = normalize(document.title || '');
            var body = '';
            var selectors = [
              'article',
              'main article',
              '[role="main"] article',
              '.post-content',
              '.entry-content',
              '.article-content',
              '.article',
              'main'
            ];

            for (var i = 0; i < selectors.length && !body; i++) {
              var candidate = document.querySelector(selectors[i]);
              if (!candidate) { continue; }
              var candidateText = normalize(candidate.innerText || candidate.textContent || '');
              if (candidateText.length >= 120) {
                body = candidateText;
              }
            }

            if (!body) {
              body = normalize(document.body && (document.body.innerText || document.body.textContent) || '');
            }

            if (!body) { return null; }
            if (body.length > 60000) {
              body = body.slice(0, 60000);
            }
            if (title.length > 300) {
              title = title.slice(0, 300);
            }
            return {
              title: title || null,
              body: body
            };
          } catch (_) {
            return null;
          }
        })();
        """
    }()

    private static let fallbackTextScript = """
        (function() {
          var title = (document.title || '').trim();
          var body = (document.body && (document.body.innerText || document.body.textContent) || '').trim();
          if (!body) { return null; }
          return { title: title || null, body: body };
        })();
    """

    static func extractContent(from webView: WKWebView, url: URL?, preferFast: Bool = false) async -> ExtractedPageContent? {
        browserAIExtractLog("START preferFast=\(preferFast) url=\(url?.absoluteString ?? "nil") reddit=\(url.map(isRedditURL(_:)) ?? false)")
        if let url, isRedditURL(url) {
            do {
                // Reddit QA is only useful if the model sees the thread, not just
                // the post body. Keep comment extraction enabled even on the
                // "fast" path so Ask AI can answer about replies again.
                let redditTimeout = preferFast ? redditFastQueryTimeout : redditSummaryTimeout
                let includeAllComments = true
                var result: RedditContentResult?
                var lastError: Error?
                for attempt in 0..<2 {
                    do {
                        result = try await withTimeout(seconds: redditTimeout) {
                            try await RedditAPI().getContentResult(from: url, includeAllComments: includeAllComments)
                        }
                        lastError = nil
                        break
                    } catch {
                        lastError = error
                        let canRetry = attempt == 0 && RedditExtractionRetryPolicy.shouldRetry(error)
                        browserAIExtractLog(
                            "REDDIT attempt=\(attempt + 1) failed retryable=\(canRetry) error=\(error.localizedDescription)"
                        )
                        guard canRetry else { break }
                    }
                }
                if let lastError, result == nil {
                    throw lastError
                }
                guard let result else { return nil }
                if let extracted = buildExtractedContent(
                    title: nil,
                    body: result.content,
                    redditCommentCount: result.commentCount,
                    redditCoverage: result.coverage
                ) {
                    browserAIExtractLog(
                        "REDDIT success bodyChars=\(extracted.body.count) comments=\(result.coverage.accessibleCommentCount) complete=\(result.coverage.extractionComplete)"
                    )
                    return extracted
                }
            } catch {
                browserAIExtractLog("REDDIT failed error=\(error.localizedDescription)")
            }
        }

        let result = await extractDOMContent(from: webView, preferFast: preferFast)
        browserAIExtractLog("END success=\(result != nil) bodyChars=\(result?.body.count ?? 0)")
        return result
    }

    static func extractText(from webView: WKWebView, url: URL?, preferFast: Bool = false) async -> String? {
        await extractContent(from: webView, url: url, preferFast: preferFast)?.formattedForAIContext
    }

    static func isRedditURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("reddit.com")
    }

    private static func extractDOMContent(from webView: WKWebView, preferFast: Bool) async -> ExtractedPageContent? {
        let timeout = preferFast ? 2.0 : 4.0
        do {
            browserAIExtractLog("DOM article START timeout=\(timeout)s")
            let extracted = try await withTimeout(seconds: timeout) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async {
                        webView.evaluateJavaScript(articleExtractionScript) { result, _ in
                            continuation.resume(returning: result)
                        }
                    }
                }
            }
            if let extractedContent = makeExtractedContent(from: extracted) {
                browserAIExtractLog("DOM article SUCCESS bodyChars=\(extractedContent.body.count)")
                return extractedContent
            }

            browserAIExtractLog("DOM article EMPTY, trying fallback")
            let fallback = try await withTimeout(seconds: timeout) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async {
                        webView.evaluateJavaScript(fallbackTextScript) { result, _ in
                            continuation.resume(returning: result)
                        }
                    }
                }
            }
            let fallbackResult = makeExtractedContent(from: fallback)
            browserAIExtractLog("DOM fallback success=\(fallbackResult != nil) bodyChars=\(fallbackResult?.body.count ?? 0)")
            return fallbackResult
        } catch {
            browserAIExtractLog("DOM failed error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func makeExtractedContent(from value: Any?) -> ExtractedPageContent? {
        if let dictionary = value as? [String: Any] {
            let title = dictionary["title"] as? String
            let body = dictionary["body"] as? String
            return buildExtractedContent(title: title, body: body)
        }
        if let body = value as? String {
            return buildExtractedContent(title: nil, body: body)
        }
        return nil
    }

    private static func buildExtractedContent(
        title: String?,
        body: String?,
        redditCommentCount: Int? = nil,
        redditCoverage: RedditCoverageMetadata? = nil
    ) -> ExtractedPageContent? {
        let sanitizedTitle = sanitizeExtractedText(title ?? "")
        let sanitizedBody = redditCoverage == nil && redditCommentCount == nil
            ? sanitizeExtractedText(body ?? "")
            : sanitizeRedditText(body ?? "")
        guard !sanitizedBody.isEmpty else { return nil }

        let cappedTitle: String? = {
            guard !sanitizedTitle.isEmpty else { return nil }
            if sanitizedTitle.count <= 300 { return sanitizedTitle }
            return String(sanitizedTitle.prefix(300))
        }()
        let cappedBody: String = {
            if redditCoverage != nil || redditCommentCount != nil {
                return sanitizedBody
            }
            if sanitizedBody.count <= 60_000 { return sanitizedBody }
            return String(sanitizedBody.prefix(60_000))
        }()

        return ExtractedPageContent(
            title: cappedTitle,
            body: cappedBody,
            redditCommentCount: redditCommentCount,
            redditCoverage: redditCoverage
        )
    }

    private static func sanitizeExtractedText(_ text: String) -> String {
        let withoutScripts = text.replacingOccurrences(
            of: #"(?is)<(script|style)[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        let withoutTags = withoutScripts.replacingOccurrences(
            of: #"(?is)</?[a-zA-Z][^>]*>"#,
            with: " ",
            options: .regularExpression
        )
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        return decoded
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reddit comment records are newline-delimited by RedditAPI. Preserve
    /// those boundaries while still removing markup and excess spaces so the
    /// summarizer can account for every comment independently.
    private static func sanitizeRedditText(_ text: String) -> String {
        let withoutScripts = text.replacingOccurrences(
            of: #"(?is)<(script|style)[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        let withoutTags = withoutScripts.replacingOccurrences(
            of: #"(?is)</?[a-zA-Z][^>]*>"#,
            with: " ",
            options: .regularExpression
        )
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        return decoded
            .components(separatedBy: .newlines)
            .map { line in
                line.components(separatedBy: CharacterSet.whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func withTimeout<T>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RedditExtractionError.timedOut
            }

            guard let first = try await group.next() else {
                throw RedditExtractionError.timedOut
            }
            group.cancelAll()
            return first
        }
    }
}
