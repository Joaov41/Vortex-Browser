import Foundation
import Combine

struct SavedAgentTask: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var task: String
    var startURL: URL?
    var createdAt: Date
    var lastRunAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        task: String,
        startURL: URL? = nil,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.task = task
        self.startURL = startURL
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
    }
}

struct AgentRunRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: UUID
    var task: String
    var outcome: String
    var actions: [String]
    var date: Date
    /// The immutable backend captured when this run started, not the current picker value.
    var backend: String
    var preset: String
    var startURL: URL?
    var isPrivate: Bool
    /// Optional detail fields are nil in history written before run details existed.
    var requestID: UUID?
    var startedAt: Date?
    var status: AgentRunStatus?
    var approvals: [AgentRunApproval]?
    var questions: [AgentRunQuestion]?
    var exports: [AgentRunExportRecord]?
    var sources: [AgentRunSourceRecord]?
    var savedTaskID: UUID?
    var duration: TimeInterval?

    init(
        id: UUID = UUID(),
        task: String,
        outcome: String,
        actions: [String],
        date: Date = Date(),
        backend: String,
        preset: String,
        startURL: URL? = nil,
        isPrivate: Bool = false,
        requestID: UUID? = nil,
        startedAt: Date? = nil,
        status: AgentRunStatus? = nil,
        approvals: [AgentRunApproval]? = nil,
        questions: [AgentRunQuestion]? = nil,
        exports: [AgentRunExportRecord]? = nil,
        sources: [AgentRunSourceRecord]? = nil,
        savedTaskID: UUID? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.task = task
        self.outcome = outcome
        self.actions = actions
        self.date = date
        self.backend = backend
        self.preset = preset
        self.startURL = startURL
        self.isPrivate = isPrivate
        self.requestID = requestID
        self.startedAt = startedAt
        self.status = status
        self.approvals = approvals
        self.questions = questions
        self.exports = exports
        self.sources = sources
        self.savedTaskID = savedTaskID
        self.duration = duration
    }
}

enum AgentTaskStoreError: Error, Equatable, LocalizedError {
    case invalidBundleIdentifier
    case invalidTask
    case savedTaskLimitReached
    case invalidRunRecord
    case missingTask
    case privateRun
    case corruptData
    case unsupportedVersion(Int)
    case readFailed
    case writeFailed
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier: return "The app identity cannot be used for task storage."
        case .invalidTask: return "The saved task needs a title and task instructions."
        case .savedTaskLimitReached: return "Vortyra has reached the saved-task limit. Delete a saved task before adding another."
        case .invalidRunRecord: return "The run record is incomplete or too large to save."
        case .missingTask: return "That saved task is no longer available."
        case .privateRun: return "Private runs are not added to automatic history."
        case .corruptData: return "Saved browser tasks could not be read; existing data was left unchanged."
        case .unsupportedVersion: return "Saved browser tasks use an unsupported format; existing data was left unchanged."
        case .readFailed: return "Saved browser tasks could not be read."
        case .writeFailed: return "Saved browser tasks could not be written; existing data was left unchanged."
        case .appGroupUnavailable: return "Shared task storage is unavailable for this app."
        }
    }
}

private struct AgentTaskStoreDocument: Codable {
    static let currentVersion = 1
    var version = currentVersion
    var savedTasks: [SavedAgentTask] = []
    var history: [AgentRunRecord] = []
}

@MainActor
final class AgentTaskStore: ObservableObject {
    static let historyLimit = 50
    static let maximumSavedTasks = 500
    static let maximumDocumentBytes = 32_000_000
    static let maximumTitleCharacters = 160
    static let maximumTitleUTF8Bytes = maximumTitleCharacters * 4
    static let maximumOutcomeCharacters = 40_000
    static let maximumOutcomeUTF8Bytes = maximumOutcomeCharacters * 4
    static let maximumActionCount = 500
    static let maximumActionUTF8Bytes = 8_000
    static let maximumActionsPerRunUTF8Bytes = 128_000
    static let maximumApprovalsPerRun = 50
    static let maximumQuestionsPerRun = 20
    static let maximumExportsPerRun = 20
    static let maximumSourcesPerRun = 50
    static let maximumRunReasonUTF8Bytes = 1_200
    static let maximumRunHostUTF8Bytes = 253
    static let maximumRunQuestionUTF8Bytes = 2_400
    static let maximumRunFilenameUTF8Bytes = 960
    static let maximumRunSourceTitleUTF8Bytes = 960

    @Published private(set) var savedTasks: [SavedAgentTask] = []
    @Published private(set) var history: [AgentRunRecord] = []

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// Loading is explicit so callers can avoid even touching persistent task history for private runs.
    func load() throws {
        let document = try readDocument()
        publish(document)
    }

    func savedTask(id: UUID) throws -> SavedAgentTask? {
        try readDocument().savedTasks.first { $0.id == id }
    }

    func saveTask(_ task: SavedAgentTask) throws {
        try validate(task)
        var document = try readDocument()
        if let index = document.savedTasks.firstIndex(where: { $0.id == task.id }) {
            var replacement = task
            replacement.createdAt = document.savedTasks[index].createdAt
            document.savedTasks[index] = replacement
        } else {
            guard document.savedTasks.count < Self.maximumSavedTasks else {
                throw AgentTaskStoreError.savedTaskLimitReached
            }
            document.savedTasks.append(task)
        }
        document.savedTasks.sort { $0.createdAt > $1.createdAt }
        try commit(document)
        NotificationCenter.default.post(name: .savedAgentTasksDidChange, object: nil)
    }

    func updateTask(_ task: SavedAgentTask) throws {
        try validate(task)
        var document = try readDocument()
        guard let index = document.savedTasks.firstIndex(where: { $0.id == task.id }) else {
            throw AgentTaskStoreError.missingTask
        }
        var replacement = task
        replacement.createdAt = document.savedTasks[index].createdAt
        document.savedTasks[index] = replacement
        document.savedTasks.sort { $0.createdAt > $1.createdAt }
        try commit(document)
        NotificationCenter.default.post(name: .savedAgentTasksDidChange, object: nil)
    }

    func deleteTask(id: UUID) throws {
        var document = try readDocument()
        document.savedTasks.removeAll { $0.id == id }
        try commit(document)
        NotificationCenter.default.post(name: .savedAgentTasksDidChange, object: nil)
    }

    func appendRun(_ record: AgentRunRecord) throws {
        guard !record.isPrivate else { throw AgentTaskStoreError.privateRun }
        try validate(record)
        var document = try readDocument()
        guard !document.history.contains(where: { $0.id == record.id }) else {
            throw AgentTaskStoreError.invalidRunRecord
        }
        document.history.insert(record, at: 0)
        document.history = Array(document.history.prefix(Self.historyLimit))
        try commit(document)
    }

    private func validate(_ task: SavedAgentTask) throws {
        guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.title.count <= Self.maximumTitleCharacters,
              task.title.utf8.count <= Self.maximumTitleUTF8Bytes,
              !task.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.task.utf8.count <= AgentTaskURLParser.maximumTaskUTF8Bytes,
              task.createdAt.timeIntervalSince1970.isFinite,
              task.lastRunAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              task.startURL.map(AgentTaskURLParser.isAllowedStartURL) ?? true else {
            throw AgentTaskStoreError.invalidTask
        }
    }

    private func validate(_ record: AgentRunRecord) throws {
        guard !record.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.task.utf8.count <= AgentTaskURLParser.maximumTaskUTF8Bytes,
              record.outcome.count <= Self.maximumOutcomeCharacters,
              record.outcome.utf8.count <= Self.maximumOutcomeUTF8Bytes,
              record.actions.count <= Self.maximumActionCount,
              record.actions.allSatisfy({ $0.utf8.count <= Self.maximumActionUTF8Bytes }),
              record.actions.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumActionsPerRunUTF8Bytes,
              !record.backend.isEmpty,
              record.backend.utf8.count <= 256,
              !record.preset.isEmpty,
              record.preset.utf8.count <= 256,
              record.date.timeIntervalSince1970.isFinite,
              record.startURL.map(AgentTaskURLParser.isAllowedStartURL) ?? true else {
            throw AgentTaskStoreError.invalidRunRecord
        }
        try validateRunDetails(of: record)
    }

    private func validateRunDetails(of record: AgentRunRecord) throws {
        let approvals = record.approvals ?? []
        let questions = record.questions ?? []
        let exports = record.exports ?? []
        let sources = record.sources ?? []
        guard record.startedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              record.duration.map({ $0.isFinite && $0 >= 0 }) ?? true,
              approvals.count <= Self.maximumApprovalsPerRun,
              approvals.allSatisfy({ approval in
                  approval.reason.utf8.count <= Self.maximumRunReasonUTF8Bytes
                      && (approval.host?.utf8.count ?? 0) <= Self.maximumRunHostUTF8Bytes
                      && approval.date.timeIntervalSince1970.isFinite
              }),
              questions.count <= Self.maximumQuestionsPerRun,
              questions.allSatisfy({ question in
                  question.prompt.utf8.count <= Self.maximumRunQuestionUTF8Bytes
                      && question.date.timeIntervalSince1970.isFinite
              }),
              exports.count <= Self.maximumExportsPerRun,
              exports.allSatisfy({ $0.filename.utf8.count <= Self.maximumRunFilenameUTF8Bytes }),
              sources.count <= Self.maximumSourcesPerRun,
              sources.allSatisfy({ source in
                  source.title.utf8.count <= Self.maximumRunSourceTitleUTF8Bytes
                      && AgentTaskURLParser.isAllowedStartURL(source.url)
              }) else {
            throw AgentTaskStoreError.invalidRunRecord
        }
    }

    private func readDocument() throws -> AgentTaskStoreDocument {
        let data: Data
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            if let size = attributes[.size] as? NSNumber,
               size.intValue > Self.maximumDocumentBytes {
                throw AgentTaskStoreError.corruptData
            }
            data = try Data(contentsOf: fileURL)
        } catch {
            if let storeError = error as? AgentTaskStoreError { throw storeError }
            if let cocoaError = error as? CocoaError, cocoaError.code == .fileReadNoSuchFile {
                return AgentTaskStoreDocument()
            }
            throw AgentTaskStoreError.readFailed
        }
        guard data.count <= Self.maximumDocumentBytes else {
            throw AgentTaskStoreError.corruptData
        }
        let document: AgentTaskStoreDocument
        do {
            document = try JSONDecoder().decode(AgentTaskStoreDocument.self, from: data)
        } catch {
            throw AgentTaskStoreError.corruptData
        }
        guard document.version == AgentTaskStoreDocument.currentVersion else {
            throw AgentTaskStoreError.unsupportedVersion(document.version)
        }
        do {
            try validate(document)
        } catch {
            throw AgentTaskStoreError.corruptData
        }
        return document
    }

    private func validate(_ document: AgentTaskStoreDocument) throws {
        guard document.savedTasks.count <= Self.maximumSavedTasks,
              document.history.count <= Self.historyLimit,
              Set(document.savedTasks.map(\.id)).count == document.savedTasks.count,
              Set(document.history.map(\.id)).count == document.history.count else {
            throw AgentTaskStoreError.corruptData
        }
        for task in document.savedTasks { try validate(task) }
        for record in document.history {
            guard !record.isPrivate else { throw AgentTaskStoreError.corruptData }
            try validate(record)
        }
    }

    private func commit(_ document: AgentTaskStoreDocument) throws {
        do {
            let parent = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            guard data.count <= Self.maximumDocumentBytes else {
                throw AgentTaskStoreError.writeFailed
            }
            try data.write(to: fileURL, options: .atomic)
        } catch let error as AgentTaskStoreError {
            throw error
        } catch {
            throw AgentTaskStoreError.writeFailed
        }
        publish(document)
    }

    private func publish(_ document: AgentTaskStoreDocument) {
        savedTasks = document.savedTasks.sorted { $0.createdAt > $1.createdAt }
        history = Array(document.history.prefix(Self.historyLimit))
    }
}

enum AgentTaskStoreLocation {
    static let appGroupIdentifier = "group.com.browser.app"

    static func fileName(bundleIdentifier: String) throws -> String {
        guard isSafeBundleIdentifier(bundleIdentifier) else {
            throw AgentTaskStoreError.invalidBundleIdentifier
        }
        return "AgentTasks.\(bundleIdentifier).json"
    }

    static func defaultsKey(bundleIdentifier: String) throws -> String {
        guard isSafeBundleIdentifier(bundleIdentifier) else {
            throw AgentTaskStoreError.invalidBundleIdentifier
        }
        return "Browser.Agent.PendingTasks.\(bundleIdentifier)"
    }

    static func fileURL(containerURL: URL, bundleIdentifier: String) throws -> URL {
        containerURL.appendingPathComponent(try fileName(bundleIdentifier: bundleIdentifier), isDirectory: false)
    }

    static func isSafeBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                return (65...90).contains(value) || (97...122).contains(value)
                    || (48...57).contains(value) || value == 45
            }
        }
    }

    @MainActor
    static func makeDefaultStore(
        bundleIdentifier: String? = nil,
        fileManager: FileManager = .default
    ) throws -> AgentTaskStore {
        guard let bundleIdentifier = bundleIdentifier ?? Bundle.main.bundleIdentifier,
              let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw AgentTaskStoreError.appGroupUnavailable
        }
        return AgentTaskStore(fileURL: try fileURL(containerURL: container, bundleIdentifier: bundleIdentifier), fileManager: fileManager)
    }
}

/// A lazy recorder used by run completion. The provider is never touched for private runs.
@MainActor
enum AgentTaskHistoryRecorder {
    @discardableResult
    static func record(
        _ record: AgentRunRecord,
        isPrivate: Bool,
        storeProvider: () throws -> AgentTaskStore
    ) throws -> Bool {
        guard !isPrivate, !record.isPrivate else { return false }
        try storeProvider().appendRun(record)
        return true
    }
}
