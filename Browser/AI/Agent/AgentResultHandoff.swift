//
//  AgentResultHandoff.swift
//  Vortex
//
//  Builds the text, date and files for handing a finished agent result to Calendar, Reminders,
//  Mail, Messages or the share sheet. Pure value types: no UI, no EventKit, no MessageUI.
//  Nothing here sends or saves anything; the user confirms in the system sheet.
//

import Foundation

/// What one handoff will carry. Private runs never carry page sources or files.
struct AgentResultHandoffDraft: Equatable {
    static let titleLimit = 80
    static let bodyLimit = 4_000
    static let sourceLimit = 10
    static let attachmentLimit = 5
    static let attachmentByteLimit: Int64 = 25 * 1_024 * 1_024
    static let defaultEventDuration: TimeInterval = 3_600
    static let dateScanLimit = 4_000

    let title: String
    let body: String
    let dateRange: DateInterval?
    let attachments: [URL]

    init(title: String, body: String, dateRange: DateInterval?, attachments: [URL]) {
        self.title = title
        self.body = body
        self.dateRange = dateRange
        self.attachments = attachments
    }

    /// A finished run. Private runs keep the outcome only; their exports and sources are dropped.
    init(
        snapshot: BrowserAgentController.CompletionSnapshot,
        fileSize: (URL) -> Int64? = AgentResultHandoffDraft.readableFileSize
    ) {
        let sourceURLs = snapshot.isPrivate ? [] : snapshot.sources.map(\.url)
        self.init(
            title: Self.title(forTask: snapshot.task),
            body: Self.body(outcome: snapshot.outcome, sourceURLs: sourceURLs),
            dateRange: Self.detectDateRange(in: snapshot.outcome),
            attachments: snapshot.isPrivate ? [] : Self.attachmentURLs(from: snapshot.exportedFiles, fileSize: fileSize)
        )
    }

    /// A stored run record. Records keep names of exports, never their locations, so there are no attachments.
    init(record: AgentRunRecord) {
        let sourceURLs = record.isPrivate ? [] : (record.sources ?? []).map(\.url)
        self.init(
            title: Self.title(forTask: record.task),
            body: Self.body(outcome: record.outcome, sourceURLs: sourceURLs),
            dateRange: Self.detectDateRange(in: record.outcome),
            attachments: []
        )
    }

    /// The Kind a manual action row button presents for this draft.
    func request(for action: AgentHandoffAction) -> AgentHandoffRequest.Kind {
        switch action {
        case .calendar:
            return .calendar(title: title, notes: body, start: dateRange?.start, end: dateRange?.end)
        case .reminder:
            return .reminder(title: title, due: dateRange?.start)
        case .email:
            return .email(subject: title, body: body, attachments: attachments)
        case .message:
            return .message(body: body)
        case .share:
            return .share(text: "\(title)\n\n\(body)", files: attachments)
        }
    }

    /// The first `NSDataDetector` date in the outcome. A detected duration is kept; otherwise one hour.
    static func detectDateRange(in text: String) -> DateInterval? {
        let scanned = String(text.prefix(dateScanLimit))
        guard !scanned.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(scanned.startIndex..<scanned.endIndex, in: scanned)
        guard let match = detector.firstMatch(in: scanned, options: [], range: range),
              let start = match.date else {
            return nil
        }
        let duration = match.duration > 0 ? match.duration : defaultEventDuration
        return DateInterval(start: start, duration: duration)
    }

    /// The task's first line, bounded to 80 characters.
    static func title(forTask task: String) -> String {
        let firstLine = task.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = firstLine.isEmpty ? "Browser task result" : firstLine
        return String(text.prefix(titleLimit))
    }

    /// The outcome, then a "Sources:" list of URLs. The sources are kept even when the outcome is long.
    static func body(outcome: String, sourceURLs: [URL]) -> String {
        let trimmed = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = trimmed.isEmpty ? "No answer was recorded." : trimmed
        let urls = Array(sourceURLs.prefix(sourceLimit))
        guard !urls.isEmpty else { return String(answer.prefix(bodyLimit)) }
        let sourceBlock = "Sources:\n" + urls.map { "- \($0.absoluteString)" }.joined(separator: "\n")
        let answerLimit = max(0, bodyLimit - sourceBlock.count - 2)
        let combined = String(answer.prefix(answerLimit)) + "\n\n" + sourceBlock
        return String(combined.prefix(bodyLimit))
    }

    /// Run exports that are readable files within the size limit, at most five, in export order.
    static func attachmentURLs(from exports: [AgentRunExport], fileSize: (URL) -> Int64?) -> [URL] {
        var urls: [URL] = []
        for export in exports where urls.count < attachmentLimit {
            guard let url = export.fileURL,
                  url.isFileURL,
                  let size = fileSize(url),
                  size <= attachmentByteLimit else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    /// The size of a readable regular file, or nil when the file is missing, unreadable or not a regular file.
    static func readableFileSize(_ url: URL) -> Int64? {
        let path = url.path
        guard FileManager.default.isReadableFile(atPath: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        return size
    }
}

/// The actions under a finished agent reply.
enum AgentHandoffAction: CaseIterable, Identifiable, Equatable {
    case calendar
    case reminder
    case email
    case message
    case share

    var id: Self { self }

    var title: String {
        switch self {
        case .calendar: return "Add to Calendar"
        case .reminder: return "Add Reminder"
        case .email: return "Email"
        case .message: return "Message"
        case .share: return "Share"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: return "calendar.badge.plus"
        case .reminder: return "checklist"
        case .email: return "envelope"
        case .message: return "message"
        case .share: return "square.and.arrow.up"
        }
    }

    var accessibilityKey: String {
        switch self {
        case .calendar: return "calendar"
        case .reminder: return "reminder"
        case .email: return "email"
        case .message: return "message"
        case .share: return "share"
        }
    }
}

/// A prepared handoff waiting for the user. Presented as a system sheet; the user confirms or cancels.
struct AgentHandoffRequest: Identifiable, Equatable {
    enum Kind: Equatable {
        case calendar(title: String, notes: String, start: Date?, end: Date?)
        case reminder(title: String, due: Date?)
        case email(subject: String, body: String, attachments: [URL])
        case message(body: String)
        case share(text: String, files: [URL])
    }

    let id: UUID
    let kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}
