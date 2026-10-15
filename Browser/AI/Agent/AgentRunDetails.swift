//
//  AgentRunDetails.swift
//  Vortex
//
//  Details kept for a finished agent run: how it ended, the approvals it asked
//  for, the questions it asked (prompts only), the files it exported and its
//  sources. Export file locations and question answers are never persisted.
//

import Foundation

enum AgentRunStatus: String, Codable, Equatable, Sendable {
    case completed
    case stopped
    case failed
    case stepLimit
    /// A status written by a newer version of the app. Decoding never fails on it,
    /// so one unfamiliar record cannot make the whole history unreadable.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentRunStatus(rawValue: raw) ?? .unknown
    }

    var title: String {
        switch self {
        case .completed: return "Completed"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        case .stepLimit: return "Step limit reached"
        case .unknown: return "Unknown"
        }
    }
}

enum AgentRunApprovalDecision: String, Codable, Equatable, Sendable {
    case allowed
    case denied
    case alwaysAllowed
    /// A decision written by a newer version of the app; see `AgentRunStatus.unknown`.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentRunApprovalDecision(rawValue: raw) ?? .unknown
    }

    var title: String {
        switch self {
        case .allowed: return "Allowed once"
        case .denied: return "Declined"
        case .alwaysAllowed: return "Allowed by saved permission"
        case .unknown: return "Unknown"
        }
    }
}

struct AgentRunApproval: Codable, Equatable, Hashable, Sendable {
    var reason: String
    var host: String?
    var decision: AgentRunApprovalDecision
    var date: Date
}

/// A question the agent asked. The user's answer is deliberately not represented.
struct AgentRunQuestion: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: UUID
    var prompt: String
    var answered: Bool
    var date: Date

    init(id: UUID = UUID(), prompt: String, answered: Bool, date: Date) {
        self.id = id
        self.prompt = prompt
        self.answered = answered
        self.date = date
    }
}

enum AgentRunExportKind: String, Codable, Equatable, Sendable {
    case csv
    case pdf
    case other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentRunExportKind(rawValue: raw) ?? .other
    }

    init(filename: String) {
        switch (filename as NSString).pathExtension.lowercased() {
        case "csv": self = .csv
        case "pdf": self = .pdf
        default: self = .other
        }
    }
}

/// A file this run exported. The file URL stays in memory for the completed-run handoff only.
struct AgentRunExport: Equatable, Sendable {
    var filename: String
    var kind: AgentRunExportKind
    var fileURL: URL?
}

/// The persisted form of an export: its name and kind, never its location.
struct AgentRunExportRecord: Codable, Equatable, Hashable, Sendable {
    var filename: String
    var kind: AgentRunExportKind
}

struct AgentRunSourceRecord: Codable, Equatable, Hashable, Sendable {
    var title: String
    var url: URL
}

enum AgentRunTextLimit {
    /// Bounds text by Character count first, then by UTF-8 bytes so validation never rejects a stored record.
    static func bounded(_ text: String, characters: Int, utf8Bytes: Int) -> String {
        var result = String(text.replacingOccurrences(of: "\u{0000}", with: "").prefix(characters))
        while result.utf8.count > utf8Bytes {
            result.removeLast()
        }
        return result
    }
}

extension AgentRunRecord {
    /// Plain text for the Share Log action. It contains only what the record stores.
    var plainTextLog: String {
        var lines: [String] = []
        lines.append("Vortyra agent run")
        lines.append("Task: \(task)")
        lines.append("Status: \(status?.title ?? "Not recorded")")
        lines.append("Started: \((startedAt ?? date).formatted(date: .abbreviated, time: .shortened))")
        if let durationText {
            lines.append("Duration: \(durationText)")
        }
        lines.append("Backend: \(AIModelBackend(rawValue: backend)?.displayName ?? backend)")
        if let startURL {
            lines.append("Start URL: \(startURL.absoluteString)")
        }
        lines.append("")
        lines.append("Outcome:")
        lines.append(outcome)
        lines.append("")
        lines.append("Actions:")
        if actions.isEmpty {
            lines.append("None recorded.")
        } else {
            lines.append(contentsOf: actions.enumerated().map { "\($0.offset + 1). \($0.element)" })
        }
        if let approvals {
            lines.append("")
            lines.append("Approvals:")
            if approvals.isEmpty {
                lines.append("None.")
            }
            for approval in approvals {
                let host = approval.host.map { " (\($0))" } ?? ""
                lines.append("- \(approval.reason)\(host): \(approval.decision.title)")
            }
        }
        if let questions {
            lines.append("")
            lines.append("Questions:")
            if questions.isEmpty {
                lines.append("None.")
            }
            for question in questions {
                lines.append("- \(question.prompt) (\(question.answered ? "answered" : "not answered"))")
            }
        }
        if let sources, !sources.isEmpty {
            lines.append("")
            lines.append("Sources:")
            lines.append(contentsOf: sources.map { "- \($0.title): \($0.url.absoluteString)" })
        }
        if let exports, !exports.isEmpty {
            lines.append("")
            lines.append("Files:")
            lines.append(contentsOf: exports.map { "- \($0.filename)" })
        }
        return lines.joined(separator: "\n")
    }

    /// Human-readable duration, or nil when the run did not record one.
    var durationText: String? {
        guard let duration else { return nil }
        return Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}
