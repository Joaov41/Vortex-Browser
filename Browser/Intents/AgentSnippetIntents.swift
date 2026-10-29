import AppIntents
import SwiftUI
import Foundation
import UIKit

/// Text limits and small helpers shared by the snippet view models. Pure, so the limits can be tested.
enum AgentSnippetText {
    static let maximumLines = 12
    static let maximumCharacters = 1_200
    static let maximumSourceDomains = 3
    /// Copy Result copies at most this many characters. Matches `AgentTaskStore.maximumOutcomeCharacters`, which a test checks.
    static let maximumCopyCharacters = 40_000

    /// Trims the text, keeps at most `maximumLines` lines and `maximumCharacters` characters, and marks any cut with an ellipsis.
    static func bounded(_ text: String, emptyText: String) -> (text: String, isTruncated: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (emptyText, false) }

        var lines = trimmed.components(separatedBy: .newlines)
        var isTruncated = false
        if lines.count > maximumLines {
            lines = Array(lines.prefix(maximumLines))
            isTruncated = true
        }
        var bounded = lines.joined(separator: "\n")
        if bounded.count > maximumCharacters {
            bounded = String(bounded.prefix(maximumCharacters))
            isTruncated = true
        }
        if isTruncated {
            bounded = bounded.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return (bounded, isTruncated)
    }

    /// The host without a leading "www.", or nil when the URL is not a plain HTTP(S) address.
    static func domain(for url: URL) -> String? {
        guard AgentTaskURLParser.isAllowedStartURL(url), let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Unique domains in first-seen order, at most `maximumSourceDomains`.
    static func domains(from urls: [URL]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for url in urls {
            guard let domain = domain(for: url), !seen.contains(domain) else { continue }
            seen.insert(domain)
            result.append(domain)
            if result.count == maximumSourceDomains { break }
        }
        return result
    }
}

/// Display values for the finished-run card. The Open button exists only when there is a stored run.
struct AgentRunSnippetModel: Equatable {
    static let emptyOutcomeText = "Vortyra finished without a written answer."
    static let maximumTitleCharacters = 120

    let taskTitle: String
    let statusText: String
    let outcomeText: String
    let isOutcomeTruncated: Bool
    let sourceDomains: [String]
    let runID: UUID?
    /// The full outcome, used only by Copy Result.
    let copyableOutcome: String

    var showsOpenInVortyra: Bool { runID != nil }

    init(taskTitle: String, status: String, outcome: String, sourceDomains: [String], runID: UUID?) {
        let trimmedTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.taskTitle = trimmedTitle.isEmpty
            ? "Browser task"
            : String(trimmedTitle.prefix(Self.maximumTitleCharacters))
        self.statusText = Self.statusText(for: status)
        let bounded = AgentSnippetText.bounded(outcome, emptyText: Self.emptyOutcomeText)
        self.outcomeText = bounded.text
        self.isOutcomeTruncated = bounded.isTruncated
        self.sourceDomains = Array(sourceDomains.prefix(AgentSnippetText.maximumSourceDomains))
        self.runID = runID
        self.copyableOutcome = String(outcome.prefix(AgentSnippetText.maximumCopyCharacters))
    }

    static func statusText(for rawStatus: String) -> String {
        switch rawStatus {
        case AgentRunStatus.completed.rawValue: return "Completed"
        case AgentRunStatus.stopped.rawValue: return "Stopped"
        case AgentRunStatus.failed.rawValue: return "Failed"
        case AgentRunStatus.stepLimit.rawValue: return "Stopped at the step limit"
        case AgentRunResultMapper.stillRunningStatus: return "Still running in Vortyra"
        case AgentRunResultMapper.rejectedStatus: return "Could not start"
        case AgentRunResultMapper.cancelledStatus: return "Waiting stopped"
        default: return "Status not recorded"
        }
    }
}

/// The finished-run card returned with the run-and-wait intents and the last-result intent.
/// It carries display values and the run ID only. File data never enters the snippet.
struct AgentRunResultSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Browser Task Result Card"
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Task")
    var taskTitle: String

    @Parameter(title: "Status")
    var status: String

    @Parameter(title: "Outcome")
    var outcome: String

    /// Newline-separated source domains, at most three.
    @Parameter(title: "Source Domains")
    var sourceDomains: String

    /// The stored run's ID as text. Nil for private, timed-out and rejected runs, which hides Open in Vortyra.
    @Parameter(title: "Run ID")
    var runID: String?

    init() {
        self.init(taskTitle: "", status: AgentRunResultMapper.unknownStatus, outcome: "", sourceDomains: [], runID: nil)
    }

    init(taskTitle: String, status: String, outcome: String, sourceDomains: [String], runID: UUID?) {
        self.taskTitle = taskTitle
        self.status = status
        self.outcome = outcome
        self.sourceDomains = sourceDomains
            .prefix(AgentSnippetText.maximumSourceDomains)
            .joined(separator: "\n")
        self.runID = runID?.uuidString
    }

    init(fields: AgentRunResultFields) {
        self.init(
            taskTitle: fields.taskTitle,
            status: fields.status,
            outcome: fields.outcome,
            sourceDomains: AgentSnippetText.domains(from: fields.sources),
            runID: fields.runID
        )
    }

    var model: AgentRunSnippetModel {
        AgentRunSnippetModel(
            taskTitle: taskTitle,
            status: status,
            outcome: outcome,
            sourceDomains: sourceDomains.split(separator: "\n").map(String.init),
            runID: runID.flatMap { UUID(uuidString: $0) }
        )
    }

    @MainActor
    func perform() async throws -> some ShowsSnippetView {
        .result(view: AgentRunResultSnippetView(model: model))
    }
}

enum AgentRunSnippetError: Error, Equatable, LocalizedError {
    case runUnavailable

    var errorDescription: String? {
        switch self {
        case .runUnavailable: return "That browser task is no longer available."
        }
    }
}

/// Opens the app on a stored run's detail page through `webmebrowser://run?id=`.
struct OpenAgentRunInVortyraIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Browser Task in Vortyra"
    static var isDiscoverable: Bool { false }
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Run ID")
    var runID: String

    init() {
        self.runID = ""
    }

    init(runID: UUID) {
        self.runID = runID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        guard let id = UUID(uuidString: runID), let url = AgentRunURLParser.url(for: id) else {
            throw AgentRunSnippetError.runUnavailable
        }
        return .result(opensIntent: OpenURLIntent(url))
    }
}

/// Copies a run's outcome to the pasteboard. It runs in the background and does not open the app.
struct CopyAgentRunResultIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Browser Task Result"
    static var isDiscoverable: Bool { false }
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Outcome")
    var outcome: String

    init() {
        self.outcome = ""
    }

    init(outcome: String) {
        self.outcome = String(outcome.prefix(AgentSnippetText.maximumCopyCharacters))
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .result(dialog: IntentDialog(stringLiteral: "There is no result text to copy."))
        }
        UIPasteboard.general.string = outcome
        return .result(dialog: IntentDialog(stringLiteral: "Copied the browser task result."))
    }
}
