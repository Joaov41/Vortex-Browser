//
//  BrowserAgentController+HandoffTools.swift
//  Vortex
//
//  prepare_calendar_event, prepare_reminder and prepare_email. Each validates its arguments and
//  queues a review request. The sidebar shows the prefilled system sheet after the run finishes.
//  These tools never present UI, never save and never send.
//

import Foundation

extension BrowserAgentController {
    static let handoffTitleLimit = 200
    static let handoffTextLimit = 4_000
    static let maxHandoffRequestsPerRun = 3

    /// Validates a prepare_* call and returns the request it would queue. Pure, so bounds and dates can be tested without a browser.
    /// Email attachments come only from this run's own exports, and never for a private run.
    static func handoffRequestKind(
        tool name: String,
        arguments: [String: Any],
        exports: [AgentRunExport],
        isPrivate: Bool,
        fileSize: (URL) -> Int64? = AgentResultHandoffDraft.readableFileSize
    ) throws -> AgentHandoffRequest.Kind {
        switch name {
        case "prepare_calendar_event":
            let title = try handoffTitle(arguments["title"], label: "title")
            let start = try handoffDate(arguments["start"], label: "start")
            let end = try handoffDate(arguments["end"], label: "end")
            if start == nil, end != nil {
                throw BrowserToolFailure.invalidArgument("Provide start when you provide end, or omit both.")
            }
            if let start, let end, end <= start {
                throw BrowserToolFailure.invalidArgument("end must be after start.")
            }
            let notes = handoffText(arguments["notes"])
            let resolvedEnd = start.map { end ?? $0.addingTimeInterval(AgentResultHandoffDraft.defaultEventDuration) }
            return .calendar(title: title, notes: notes, start: start, end: resolvedEnd)
        case "prepare_reminder":
            let title = try handoffTitle(arguments["title"], label: "title")
            let due = try handoffDate(arguments["due"], label: "due")
            return .reminder(title: title, due: due)
        case "prepare_email":
            let subject = try handoffTitle(arguments["subject"], label: "subject")
            let body = handoffText(arguments["body"])
            guard !body.isEmpty else {
                throw BrowserToolFailure.invalidArgument("Provide body with 1 to \(handoffTextLimit) characters.")
            }
            guard let attachExports = arguments["attachExports"] as? Bool else {
                throw BrowserToolFailure.invalidArgument("Provide attachExports as true or false.")
            }
            let attachments = attachExports && !isPrivate
                ? AgentResultHandoffDraft.attachmentURLs(from: exports, fileSize: fileSize)
                : []
            return .email(subject: subject, body: body, attachments: attachments)
        default:
            throw BrowserToolFailure.invalidArgument("Unknown handoff tool.")
        }
    }

    func prepareHandoff(name: String, arguments: [String: Any], token: UUID) throws -> ToolResult {
        guard isCurrentRun(token) else { throw CancellationError() }
        let kind = try Self.handoffRequestKind(
            tool: name,
            arguments: arguments,
            exports: runExports,
            isPrivate: runContext?.isPrivate ?? runIsPrivate
        )
        guard enqueueHandoffRequest(kind) else {
            throw BrowserToolFailure.invalidArgument(
                "This run has already prepared \(Self.maxHandoffRequestsPerRun) handoffs. Tell the user the rest must be added by hand."
            )
        }
        let (step, result) = Self.handoffMessages(for: kind)
        append(.action, step)
        return .plain(result)
    }

    private static func handoffMessages(for kind: AgentHandoffRequest.Kind) -> (step: String, result: String) {
        let review = "the user will review it after the task finishes."
        switch kind {
        case let .calendar(title, _, _, _):
            return (
                "Prepare a calendar event for review",
                "Prepared a calendar event \"\(title)\" — \(review) Nothing has been saved."
            )
        case let .reminder(title, _):
            return (
                "Prepare a reminder for review",
                "Prepared a reminder \"\(title)\" — \(review) Nothing has been saved."
            )
        case let .email(subject, _, attachments):
            let files = attachments.isEmpty ? "" : " with \(attachments.count) attached file\(attachments.count == 1 ? "" : "s")"
            return (
                "Prepare an email for review",
                "Prepared an email with subject \"\(subject)\"\(files) — \(review) Nothing has been sent."
            )
        case .message, .share:
            return ("Prepare a handoff for review", "Prepared a handoff — \(review)")
        }
    }

    private static func handoffTitle(_ value: Any?, label: String) throws -> String {
        let text = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.count <= handoffTitleLimit,
              text.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw BrowserToolFailure.invalidArgument("Provide \(label) as 1 to \(handoffTitleLimit) characters on one line.")
        }
        return text
    }

    /// Notes and bodies are bounded rather than rejected, so a long answer still produces a handoff.
    private static func handoffText(_ value: Any?) -> String {
        let text = (value as? String ?? "")
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(handoffTextLimit))
    }

    private static func handoffDate(_ value: Any?, label: String) throws -> Date? {
        if value == nil || value is NSNull { return nil }
        let invalid = BrowserToolFailure.invalidArgument(
            "Provide \(label) as an ISO 8601 date and time, such as 2026-11-02T14:00:00+01:00."
        )
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw invalid
        }
        guard let date = isoDate(from: text) else { throw invalid }
        return date
    }

    private static func isoDate(from text: String) -> Date? {
        let withZone = ISO8601DateFormatter()
        withZone.formatOptions = [.withInternetDateTime]
        if let date = withZone.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let local = ISO8601DateFormatter()
        local.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        local.timeZone = .current
        return local.date(from: text)
    }
}
