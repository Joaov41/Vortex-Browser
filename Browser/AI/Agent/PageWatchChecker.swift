import Foundation
import CryptoKit
import WebKit

/// Text used for page-watch comparison. Clock times are dropped so a page that only shows the time does not
/// look changed on every check.
nonisolated enum PageWatchText {
    static let clockTimePattern = #"\b\d{1,2}:\d{2}(?::\d{2})?\b"#

    /// Trims, drops clock times such as 12:34 or 12:34:56, and collapses whitespace.
    static func normalize(_ text: String) -> String {
        let withoutClockTimes = text.replacingOccurrences(of: clockTimePattern, with: " ", options: .regularExpression)
        return withoutClockTimes.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Removes script, style, noscript and comments, turns tags into spaces, decodes entities and collapses whitespace.
    static func visibleText(fromHTML html: String) -> String {
        var value = html
        let removals = [
            #"<script\b[^>]*>[\s\S]*?</script\s*>"#,
            #"<style\b[^>]*>[\s\S]*?</style\s*>"#,
            #"<noscript\b[^>]*>[\s\S]*?</noscript\s*>"#,
            #"<!--[\s\S]*?-->"#
        ]
        for pattern in removals {
            value = value.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        value = value.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        return normalize(decodeEntities(value))
    }

    /// Decodes named basic entities and numeric references in one pass, so `&amp;lt;` becomes `&lt;`, not `<`.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"),
              let regex = try? NSRegularExpression(pattern: #"&(#[xX][0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]{2,8});"#) else {
            return text
        }
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let token = source.substring(with: match.range(at: 1))
            output += decodedEntity(token) ?? source.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }

    static func fingerprint(_ normalized: String) -> String {
        SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func observation(fromText text: String, source: PageWatchValueSource) -> PageWatchObservation {
        let normalized = normalize(text)
        return PageWatchObservation(
            hash: fingerprint(normalized),
            preview: String(normalized.prefix(PageWatch.maximumPreviewCharacters)),
            source: source
        )
    }

    private static func decodedEntity(_ token: String) -> String? {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        if token.hasPrefix("#x") || token.hasPrefix("#X") {
            guard let value = UInt32(token.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        if token.hasPrefix("#") {
            guard let value = UInt32(token.dropFirst()), let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return named[token.lowercased()]
    }
}

/// One successful read of a watched page or agent outcome, reduced to a hash and a short preview.
nonisolated struct PageWatchObservation: Equatable, Sendable {
    let hash: String
    let preview: String
    let source: PageWatchValueSource
}

/// Pure comparison of an observation with the stored baseline.
enum PageWatchEvaluator {
    struct Update: Equatable {
        let watch: PageWatch
        let didChange: Bool
        let isBaseline: Bool
    }

    /// The first observation, or one from a different source, only records a baseline and never reports a change.
    static func apply(_ observation: PageWatchObservation, to watch: PageWatch, at now: Date) -> Update {
        var updated = watch
        updated.lastCheckedAt = now
        updated.lastError = nil
        let isBaseline = watch.lastValueHash == nil || watch.lastValueSource != observation.source
        if isBaseline {
            updated.lastValueHash = observation.hash
            updated.lastValuePreview = observation.preview
            updated.lastValueSource = observation.source
            return Update(watch: updated, didChange: false, isBaseline: true)
        }
        guard watch.lastValueHash != observation.hash else {
            return Update(watch: updated, didChange: false, isBaseline: false)
        }
        updated.lastValueHash = observation.hash
        updated.lastValuePreview = observation.preview
        updated.lastValueSource = observation.source
        updated.lastChangeAt = now
        return Update(watch: updated, didChange: true, isBaseline: false)
    }

    static func recordFailure(_ message: String, on watch: PageWatch, at now: Date) -> PageWatch {
        var updated = watch
        updated.lastCheckedAt = now
        updated.lastError = String(message.prefix(PageWatch.maximumErrorCharacters))
        return updated
    }
}

enum PageWatchCheckOutcome: Equatable {
    case observed(PageWatchObservation)
    /// Not performed and not recorded, for example an agent watch in a background run.
    case skipped(String)
    case failed(String)
}

enum PageWatchCheckError: LocalizedError, Equatable {
    case notWebPage
    case autofillProtected
    case savedTaskMissing
    case emptyPage

    var errorDescription: String? {
        switch self {
        case .notWebPage: return "Only HTTP and HTTPS pages can be watched."
        case .autofillProtected: return "Background checks are unavailable for a site that received autofill."
        case .savedTaskMissing: return "The saved task for this watch is no longer available."
        case .emptyPage: return "The page had no readable text."
        }
    }
}

/// Reads a page in the foreground with the offscreen browser loader, which also supports a CSS selector.
protocol PageWatchForegroundLoading {
    @MainActor func loadText(url: URL, selector: String?) async throws -> String
}

nonisolated struct PageWatchFetchedPage: Equatable, Sendable {
    let text: String
    let finalURL: URL
}

/// Reads a page in the background with a bounded, cookie-free request.
nonisolated protocol PageWatchBackgroundFetching: Sendable {
    func fetchText(url: URL, timeout: TimeInterval) async throws -> PageWatchFetchedPage
}

/// Queues a saved task through the same path as Run Saved Browser Task and waits for its result.
@MainActor
protocol PageWatchAgentRunning {
    func runSavedTask(_ task: SavedAgentTask, timeout: Duration) async -> AgentRunWaitOutcome
}

@MainActor
struct BrowserPageWatchForegroundLoader: PageWatchForegroundLoading {
    func loadText(url: URL, selector: String?) async throws -> String {
        let privacy = BrowserAgentAutofillPrivacy.shared
        // Non-private tabs use the default store, so the watch reads the same page the user sees in the browser.
        // Private tabs never reach this code.
        let page = try await BrowserAgentBackgroundLoader(timeout: 15).fetch(
            url: url,
            startingDataStore: WKWebsiteDataStore.default(),
            isPrivate: false,
            urlPolicy: { candidate, store in
                !privacy.blocksBackgroundFetch(url: candidate, startingDataStore: store)
            },
            rootSelector: selector
        )
        return page.text
    }
}

nonisolated struct URLSessionPageWatchFetcher: PageWatchBackgroundFetching {
    static let maximumBodyBytes = 2_000_000
    static let maximumTimeout: TimeInterval = 20

    enum FetchError: LocalizedError, Equatable {
        case notHTTP
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .notHTTP: return "The page did not return an HTTP response."
            case .badStatus(let code): return "The page returned HTTP status \(code)."
            }
        }
    }

    func fetchText(url: URL, timeout: TimeInterval) async throws -> PageWatchFetchedPage {
        let seconds = min(max(timeout, 1), Self.maximumTimeout)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: seconds)
        request.httpShouldHandleCookies = false
        request.setValue("text/html,application/xhtml+xml;q=0.9,text/plain;q=0.8", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.badStatus(http.statusCode) }

        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= Self.maximumBodyBytes { break }
        }
        let html = String(decoding: data, as: UTF8.self)
        return PageWatchFetchedPage(
            text: PageWatchText.visibleText(fromHTML: html),
            finalURL: http.url ?? url
        )
    }
}

@MainActor
struct AgentTaskWatchRunner: PageWatchAgentRunning {
    func runSavedTask(_ task: SavedAgentTask, timeout: Duration) async -> AgentRunWaitOutcome {
        let request = PendingAgentTask(task: task.task, startURL: task.startURL, savedTaskID: task.id)
        do {
            try AgentTaskIntentRuntime.enqueue(request)
        } catch {
            return .rejected(error.localizedDescription)
        }
        return await AgentRunCompletionBroker.shared.wait(for: request.id, timeout: timeout)
    }
}

/// Checks one watch. It never writes to the store; the coordinator records the outcome.
@MainActor
final class PageWatchChecker {
    enum Mode: Equatable {
        case foreground
        case background
    }

    static let agentTimeout: Duration = .seconds(300)
    /// Per-request limit for URLSession reads. Background runs may pass a shorter value from their remaining budget.
    static let defaultTimeout: TimeInterval = 20

    private let foreground: PageWatchForegroundLoading
    private let background: PageWatchBackgroundFetching
    private let agent: PageWatchAgentRunning
    private let savedTask: @MainActor (UUID) throws -> SavedAgentTask?
    /// True for origins that received autofill in this session. Background reads are refused for them.
    private let isBlockedOrigin: @MainActor (URL) -> Bool

    /// Defaults are built in the body, which runs on the main actor; tests pass fakes for each seam.
    init(
        foreground: PageWatchForegroundLoading? = nil,
        background: PageWatchBackgroundFetching? = nil,
        agent: PageWatchAgentRunning? = nil,
        savedTask: (@MainActor (UUID) throws -> SavedAgentTask?)? = nil,
        isBlockedOrigin: (@MainActor (URL) -> Bool)? = nil
    ) {
        self.foreground = foreground ?? BrowserPageWatchForegroundLoader()
        self.background = background ?? URLSessionPageWatchFetcher()
        self.agent = agent ?? AgentTaskWatchRunner()
        self.savedTask = savedTask ?? { try AgentTaskIntentRuntime.savedTask(id: $0) }
        self.isBlockedOrigin = isBlockedOrigin ?? { url in
            BrowserAgentAutofillPrivacy.shared.blocksBackgroundFetch(url: url, startingDataStore: WKWebsiteDataStore.default())
        }
    }

    func check(_ watch: PageWatch, mode: Mode, timeout: TimeInterval = 20) async -> PageWatchCheckOutcome {
        guard PageWatch.isWebURL(watch.url) else {
            return .failed(PageWatchCheckError.notWebPage.localizedDescription)
        }
        switch watch.mode {
        case .text(let selector):
            return await checkText(url: watch.url, selector: selector, mode: mode, timeout: timeout)
        case .agent(let savedTaskID):
            guard mode == .foreground else {
                return .skipped("Agent watches run only while Vortyra is open.")
            }
            return await checkAgent(savedTaskID: savedTaskID)
        }
    }

    private func checkText(url: URL, selector: String?, mode: Mode, timeout: TimeInterval) async -> PageWatchCheckOutcome {
        if mode == .background, selector != nil {
            return .skipped("Watches with a CSS selector are checked while Vortyra is open.")
        }
        if isBlockedOrigin(url) {
            return .failed(PageWatchCheckError.autofillProtected.localizedDescription)
        }
        do {
            switch mode {
            case .foreground:
                let text = try await foreground.loadText(url: url, selector: selector)
                return observe(text, source: .browserText)
            case .background:
                let page = try await background.fetchText(url: url, timeout: timeout)
                guard !isBlockedOrigin(page.finalURL) else {
                    return .failed(PageWatchCheckError.autofillProtected.localizedDescription)
                }
                return observe(page.text, source: .urlSessionText)
            }
        } catch is CancellationError {
            return .skipped("Cancelled.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func checkAgent(savedTaskID: UUID) async -> PageWatchCheckOutcome {
        let task: SavedAgentTask?
        do {
            task = try savedTask(savedTaskID)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let task else {
            return .failed(PageWatchCheckError.savedTaskMissing.localizedDescription)
        }
        switch await agent.runSavedTask(task, timeout: Self.agentTimeout) {
        case .finished(let snapshot):
            guard !snapshot.isPrivate else {
                return .skipped("Results from private runs are not used for page watches.")
            }
            return observe(snapshot.outcome, source: .agentRun)
        case .rejected(let message):
            return .failed(message)
        case .timedOut:
            return .failed("The saved task did not finish within 5 minutes.")
        case .cancelled:
            return .skipped("Cancelled.")
        }
    }

    private func observe(_ text: String, source: PageWatchValueSource) -> PageWatchCheckOutcome {
        guard !PageWatchText.normalize(text).isEmpty else {
            return .failed(PageWatchCheckError.emptyPage.localizedDescription)
        }
        return .observed(PageWatchText.observation(fromText: text, source: source))
    }
}
