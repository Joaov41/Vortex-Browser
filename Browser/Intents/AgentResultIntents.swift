import AppIntents
import Foundation
import UniformTypeIdentifiers

/// The result an agent run hands back to Shortcuts. It is transient: the system keeps it for one shortcut run.
struct AgentRunResultEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Browser task result"

    let id: UUID
    @Property(title: "Outcome")
    var outcome: String
    @Property(title: "Status")
    var status: String
    @Property(title: "Task")
    var taskTitle: String
    @Property(title: "Finished")
    var finishedAt: Date
    @Property(title: "Sources")
    var sources: [URL]
    @Property(title: "Files")
    var files: [IntentFile]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(taskTitle)", subtitle: "\(status)")
    }

    /// Required by `TransientAppEntity`. The app itself always uses `init(id:fields:)`.
    init() {
        self.init(fields: AgentRunResultFields(
            outcome: "",
            status: AgentRunResultMapper.unknownStatus,
            taskTitle: "",
            finishedAt: Date(),
            sources: [],
            files: [],
            fileNotes: []
        ))
    }

    init(id: UUID = UUID(), fields: AgentRunResultFields) {
        self.id = id
        self.outcome = fields.outcome
        self.status = fields.status
        self.taskTitle = fields.taskTitle
        self.finishedAt = fields.finishedAt
        self.sources = fields.sources
        self.files = fields.files.map(\.intentFile)
    }
}

/// Field values for `AgentRunResultEntity`, kept as plain values so the mapping can be tested.
struct AgentRunResultFields: Equatable {
    var outcome: String
    var status: String
    var taskTitle: String
    var finishedAt: Date
    var sources: [URL]
    var files: [AgentRunResultFile]
    /// Plain sentences about skipped files, shown in the dialog.
    var fileNotes: [String]
    /// The stored run's ID, set only for non-private finished runs. Used by the snippet's Open button; not part of the entity.
    var runID: UUID? = nil
}

struct AgentRunResultFile: Equatable {
    let filename: String
    let kind: AgentRunExportKind
    let data: Data

    var intentFile: IntentFile {
        IntentFile(data: data, filename: filename, type: kind.contentType)
    }
}

/// Reads exported files. The live value checks the size before reading; tests inject an in-memory fake.
struct AgentRunFileAccess {
    var size: (URL) throws -> Int
    var read: (URL) throws -> Data

    static let live = AgentRunFileAccess(
        size: { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw CocoaError(.fileReadUnknown)
            }
            return size.intValue
        },
        read: { url in try Data(contentsOf: url) }
    )
}

/// Turns a wait outcome or a stored run record into entity fields. Pure apart from the injected file reader.
enum AgentRunResultMapper {
    static let maximumFiles = 5
    static let maximumFileBytes = 25_000_000

    static let privateRunOutcome = "This task ran in a private tab, so its result isn't shared with Shortcuts."
    static let stillRunningOutcome = "The task is still running in Vortyra."
    static let cancelledOutcome = "Waiting stopped before the task finished. The task keeps running in Vortyra."

    static let completedStatus = "completed"
    static let stillRunningStatus = "stillRunning"
    static let rejectedStatus = "rejected"
    static let cancelledStatus = "cancelled"
    static let unknownStatus = "unknown"

    static func fields(
        for outcome: AgentRunWaitOutcome,
        taskTitle: String,
        now: Date,
        files: AgentRunFileAccess = .live
    ) -> AgentRunResultFields {
        switch outcome {
        case .finished(let snapshot):
            guard !snapshot.isPrivate else {
                return AgentRunResultFields(
                    outcome: privateRunOutcome,
                    status: completedStatus,
                    taskTitle: taskTitle,
                    finishedAt: snapshot.date,
                    sources: [],
                    files: [],
                    fileNotes: []
                )
            }
            let sources = snapshot.sources
                .filter { !$0.isPrivate && AgentTaskURLParser.isAllowedStartURL($0.url) }
                .map(\.url)
            let collected = collectFiles(snapshot.exportedFiles, access: files)
            return AgentRunResultFields(
                outcome: snapshot.outcome,
                status: snapshot.status.rawValue,
                taskTitle: taskTitle,
                finishedAt: snapshot.date,
                sources: sources,
                files: collected.files,
                fileNotes: collected.notes,
                runID: snapshot.runID
            )
        case .rejected(let message):
            return AgentRunResultFields(
                outcome: message,
                status: rejectedStatus,
                taskTitle: taskTitle,
                finishedAt: now,
                sources: [],
                files: [],
                fileNotes: []
            )
        case .timedOut:
            return AgentRunResultFields(
                outcome: stillRunningOutcome,
                status: stillRunningStatus,
                taskTitle: taskTitle,
                finishedAt: now,
                sources: [],
                files: [],
                fileNotes: []
            )
        case .cancelled:
            return AgentRunResultFields(
                outcome: cancelledOutcome,
                status: cancelledStatus,
                taskTitle: taskTitle,
                finishedAt: now,
                sources: [],
                files: [],
                fileNotes: []
            )
        }
    }

    /// Stored runs keep only file names, so their files are always empty.
    static func fields(for record: AgentRunRecord, taskTitle: String) -> AgentRunResultFields {
        guard !record.isPrivate else {
            return AgentRunResultFields(
                outcome: privateRunOutcome,
                status: completedStatus,
                taskTitle: taskTitle,
                finishedAt: record.date,
                sources: [],
                files: [],
                fileNotes: []
            )
        }
        return AgentRunResultFields(
            outcome: record.outcome,
            status: record.status?.rawValue ?? unknownStatus,
            taskTitle: taskTitle,
            finishedAt: record.date,
            sources: (record.sources ?? []).map(\.url),
            files: [],
            fileNotes: [],
            runID: record.id
        )
    }

    /// Attaches at most `maximumFiles` files. Files that are too large or unreadable are skipped and do not use a slot.
    static func collectFiles(
        _ exports: [AgentRunExport],
        access: AgentRunFileAccess
    ) -> (files: [AgentRunResultFile], notes: [String]) {
        var files: [AgentRunResultFile] = []
        var notes: [String] = []
        var omittedForLimit = 0
        for export in exports {
            guard files.count < maximumFiles else {
                omittedForLimit += 1
                continue
            }
            guard let url = export.fileURL, url.isFileURL else {
                notes.append("\(export.filename) could not be read and was not attached.")
                continue
            }
            do {
                let size = try access.size(url)
                guard size <= maximumFileBytes else {
                    notes.append("\(export.filename) is larger than 25 MB and was not attached.")
                    continue
                }
                let data = try access.read(url)
                guard data.count <= maximumFileBytes else {
                    notes.append("\(export.filename) is larger than 25 MB and was not attached.")
                    continue
                }
                files.append(AgentRunResultFile(filename: export.filename, kind: export.kind, data: data))
            } catch {
                notes.append("\(export.filename) could not be read and was not attached.")
            }
        }
        if omittedForLimit > 0 {
            notes.append("\(omittedForLimit) more file(s) were not attached because the limit is \(maximumFiles).")
        }
        return (files, notes)
    }
}

enum AgentRunResultIntentSupport {
    static let defaultTimeoutSeconds = 180
    static let minimumTimeoutSeconds = 15
    static let maximumTimeoutSeconds = 900
    static let dialogOutcomeCharacters = 300
    static let taskTitleCharacters = 80

    static func clampedTimeoutSeconds(_ seconds: Int) -> Int {
        min(max(seconds, minimumTimeoutSeconds), maximumTimeoutSeconds)
    }

    static func waitTimeout(seconds: Int) -> Duration {
        .seconds(clampedTimeoutSeconds(seconds))
    }

    static func title(forTask task: String) -> String {
        let firstLine = task.split(whereSeparator: \.isNewline).first.map { String($0) } ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Browser task" }
        return String(trimmed.prefix(taskTitleCharacters))
    }

    /// The first 300 characters of the outcome, then one sentence per skipped file.
    static func dialogText(outcome: String, fileNotes: [String]) -> String {
        let trimmed = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = trimmed.isEmpty
            ? "Vortyra finished without a written answer."
            : String(trimmed.prefix(dialogOutcomeCharacters))
        for note in fileNotes {
            text += " " + note
        }
        return text
    }

    static func makeResult(
        for outcome: AgentRunWaitOutcome,
        taskTitle: String,
        now: Date = Date(),
        files: AgentRunFileAccess = .live
    ) -> (entity: AgentRunResultEntity, dialog: String, snippet: AgentRunResultSnippetIntent) {
        let fields = AgentRunResultMapper.fields(for: outcome, taskTitle: taskTitle, now: now, files: files)
        return (
            AgentRunResultEntity(fields: fields),
            dialogText(outcome: fields.outcome, fileNotes: fields.fileNotes),
            AgentRunResultSnippetIntent(fields: fields)
        )
    }
}

enum AgentResultIntentError: Error, Equatable, LocalizedError {
    case noFinishedRun

    var errorDescription: String? {
        switch self {
        case .noFinishedRun:
            return "Vortyra has no finished browser task yet. Run a browser task first."
        }
    }
}

private extension AgentRunExportKind {
    var contentType: UTType? {
        switch self {
        case .csv: return .commaSeparatedText
        case .pdf: return .pdf
        case .other: return nil
        }
    }
}

struct RunAgentTaskAndWaitIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Browser Task and Get Result"
    static let description = IntentDescription(
        "Queue a browser task in Vortyra, wait for it to finish, and return its result and exported files. If the wait times out, the task keeps running in Vortyra."
    )
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Task", description: "What Vortyra should do in the browser")
    var task: String

    @Parameter(title: "Starting Website")
    var startURL: URL?

    @Parameter(
        title: "Timeout (seconds)",
        description: "How long to wait for the result, from 15 to 900 seconds.",
        default: 180,
        inclusiveRange: (15, 900)
    )
    var timeoutSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Run browser task \(\.$task) and get the result")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AgentRunResultEntity> & ProvidesDialog & ShowsSnippetIntent {
        let request = try await MainActor.run { () throws -> PendingAgentTask in
            guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.utf8.count <= AgentTaskURLParser.maximumTaskUTF8Bytes,
                  startURL.map(AgentTaskURLParser.isAllowedStartURL) ?? true else {
                throw PendingAgentTaskQueueError.invalidTask
            }
            let request = PendingAgentTask(task: task, startURL: startURL, notifiesWhenFinished: true)
            try AgentTaskIntentRuntime.enqueue(request)
            return request
        }
        let outcome = await AgentRunCompletionBroker.shared.wait(
            for: request.id,
            timeout: AgentRunResultIntentSupport.waitTimeout(seconds: timeoutSeconds)
        )
        let result = AgentRunResultIntentSupport.makeResult(
            for: outcome,
            taskTitle: AgentRunResultIntentSupport.title(forTask: task)
        )
        return .result(value: result.entity, dialog: IntentDialog(stringLiteral: result.dialog), snippetIntent: result.snippet)
    }
}

struct RunSavedAgentTaskAndWaitIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Saved Browser Task and Get Result"
    static let description = IntentDescription(
        "Run one of your saved browser tasks in Vortyra, wait for it to finish, and return its result and exported files. If the wait times out, the task keeps running in Vortyra."
    )
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Saved Task")
    var savedTask: AgentTaskEntity

    @Parameter(
        title: "Timeout (seconds)",
        description: "How long to wait for the result, from 15 to 900 seconds.",
        default: 180,
        inclusiveRange: (15, 900)
    )
    var timeoutSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Run saved task \(\.$savedTask) and get the result")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AgentRunResultEntity> & ProvidesDialog & ShowsSnippetIntent {
        let queued = try await MainActor.run { () throws -> (request: PendingAgentTask, title: String) in
            guard let id = UUID(uuidString: savedTask.id),
                  let saved = try AgentTaskIntentRuntime.savedTask(id: id) else {
                throw AgentTaskStoreError.missingTask
            }
            let request = AgentTaskIntentRuntime.pendingRequest(for: saved, notifiesWhenFinished: true)
            try AgentTaskIntentRuntime.enqueue(request)
            return (request, saved.title)
        }
        let outcome = await AgentRunCompletionBroker.shared.wait(
            for: queued.request.id,
            timeout: AgentRunResultIntentSupport.waitTimeout(seconds: timeoutSeconds)
        )
        let result = AgentRunResultIntentSupport.makeResult(for: outcome, taskTitle: queued.title)
        return .result(value: result.entity, dialog: IntentDialog(stringLiteral: result.dialog), snippetIntent: result.snippet)
    }
}

struct GetLastAgentRunResultIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Browser Task Result"
    static let description = IntentDescription(
        "Return the outcome of the most recent finished browser task. Runs in private tabs are never kept. Exported files are not stored, so this result has no files."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AgentRunResultEntity> & ProvidesDialog & ShowsSnippetIntent {
        let fields = try await MainActor.run { () throws -> AgentRunResultFields in
            let store = try AgentTaskIntentRuntime.makeStore()
            try store.load()
            guard let record = store.history.first(where: { !$0.isPrivate }) else {
                throw AgentResultIntentError.noFinishedRun
            }
            let savedTitle = record.savedTaskID.flatMap { id in
                store.savedTasks.first { $0.id == id }?.title
            }
            return AgentRunResultMapper.fields(
                for: record,
                taskTitle: savedTitle ?? AgentRunResultIntentSupport.title(forTask: record.task)
            )
        }
        return .result(
            value: AgentRunResultEntity(fields: fields),
            dialog: IntentDialog(stringLiteral: AgentRunResultIntentSupport.dialogText(outcome: fields.outcome, fileNotes: [])),
            snippetIntent: AgentRunResultSnippetIntent(fields: fields)
        )
    }
}
