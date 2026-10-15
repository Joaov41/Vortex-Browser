import AppIntents
import Foundation

@MainActor
enum AgentTaskShortcutMetadata {
    static func refresh() {
        BrowserAgentShortcuts.updateAppShortcutParameters()
    }
}

@MainActor
enum AgentTaskIntentRuntime {
    static func makeQueue() throws -> PendingAgentTaskQueue {
        guard let defaults = UserDefaults(suiteName: AgentTaskStoreLocation.appGroupIdentifier),
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw AgentTaskStoreError.appGroupUnavailable
        }
        let key = try AgentTaskStoreLocation.defaultsKey(bundleIdentifier: bundleIdentifier)
        return PendingAgentTaskQueue(defaults: defaults, storageKey: key)
    }

    static func makeStore() throws -> AgentTaskStore {
        try AgentTaskStoreLocation.makeDefaultStore()
    }

    static func enqueue(_ request: PendingAgentTask) throws {
        let coordinator = AgentTaskHandoffCoordinator(queue: try makeQueue())
        try coordinator.enqueue(request)
    }

    static func savedTask(id: UUID) throws -> SavedAgentTask? {
        let store = try makeStore()
        try store.load()
        return try store.savedTask(id: id)
    }

    /// The queued request for a saved task. Its text includes any recorded steps.
    /// Shortcuts and Siri runs pass `notifiesWhenFinished` so the app posts a notification when they finish.
    static func pendingRequest(for task: SavedAgentTask, notifiesWhenFinished: Bool = false) -> PendingAgentTask {
        PendingAgentTask(
            task: task.runTaskText,
            startURL: task.startURL,
            savedTaskID: task.id,
            notifiesWhenFinished: notifiesWhenFinished ? true : nil
        )
    }

    /// Queues a saved task. Shared by Run Saved Browser Task and Open Saved Browser Task.
    static func queueSavedTask(_ entity: AgentTaskEntity, notifiesWhenFinished: Bool = false) throws -> String {
        guard let id = UUID(uuidString: entity.id),
              let task = try savedTask(id: id) else {
            throw AgentTaskStoreError.missingTask
        }
        try enqueue(pendingRequest(for: task, notifiesWhenFinished: notifiesWhenFinished))
        return task.title
    }
}

/// The entity intentionally exposes display metadata only; task text and start URLs stay in the app store.
struct AgentTaskEntity: AppEntity, IndexedEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved browser task"
    static let defaultQuery = AgentTaskEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(task: SavedAgentTask) {
        self.init(id: task.id.uuidString, title: task.title)
    }
}

struct AgentTaskEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AgentTaskEntity] {
        try await MainActor.run {
            let store = try AgentTaskIntentRuntime.makeStore()
            try store.load()
            let requested = Set(identifiers)
            return store.savedTasks
                .filter { requested.contains($0.id.uuidString) }
                .map { AgentTaskEntity(task: $0) }
        }
    }

    func suggestedEntities() async throws -> [AgentTaskEntity] {
        try await MainActor.run {
            let store = try AgentTaskIntentRuntime.makeStore()
            try store.load()
            return store.savedTasks.prefix(30).map { AgentTaskEntity(task: $0) }
        }
    }
}

struct RunAgentTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Browser Task"
    static let description = IntentDescription(
        "Queue a browser task and bring Vortyra to the foreground. The app performs the task after it is ready."
    )
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Task", description: "What Vortyra should do in the browser")
    var task: String

    @Parameter(title: "Starting Website")
    var startURL: URL?

    static var parameterSummary: some ParameterSummary {
        Summary("Run browser task \(\.$task)")
    }

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.utf8.count <= AgentTaskURLParser.maximumTaskUTF8Bytes,
                  startURL.map(AgentTaskURLParser.isAllowedStartURL) ?? true else {
                throw PendingAgentTaskQueueError.invalidTask
            }
            let request = PendingAgentTask(task: task, startURL: startURL, notifiesWhenFinished: true)
            try AgentTaskIntentRuntime.enqueue(request)
        }
        return .result(dialog: "Queued the browser task. Vortyra will continue when it is ready.")
    }
}

struct RunSavedAgentTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Saved Browser Task"
    static let description = IntentDescription("Queue one of your saved browser tasks in Vortyra.")
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Saved Task")
    var savedTask: AgentTaskEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run saved task \(\.$savedTask)")
    }

    func perform() async throws -> some IntentResult {
        let queuedTitle = try await MainActor.run { () throws -> String in
            try AgentTaskIntentRuntime.queueSavedTask(savedTask, notifiesWhenFinished: true)
        }
        return .result(dialog: "Queued \(queuedTitle). Vortyra will continue when it is ready.")
    }
}

struct BrowserAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunAgentTaskIntent(),
            phrases: [
                "Run a browser task with \(.applicationName)",
                "Ask \(.applicationName) to work on a webpage"
            ],
            shortTitle: "Run browser task",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: RunSavedAgentTaskIntent(),
            phrases: [
                "Run \(\.$savedTask) with \(.applicationName)",
                "Start \(\.$savedTask) in \(.applicationName)"
            ],
            shortTitle: "Run saved task",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: SearchBrowserIntent(),
            phrases: [
                "Search with \(.applicationName)"
            ],
            shortTitle: "Search in Vortyra",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: SearchClipboardBrowserIntent(),
            phrases: [
                "Search my clipboard with \(.applicationName)"
            ],
            shortTitle: "Search clipboard",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: OpenBrowserURLIntent(),
            phrases: [
                "Open a website with \(.applicationName)"
            ],
            shortTitle: "Open website",
            systemImageName: "globe"
        )
        AppShortcut(
            intent: NewPrivateBrowserTabIntent(),
            phrases: [
                "Open a private tab in \(.applicationName)"
            ],
            shortTitle: "Private tab",
            systemImageName: "eye.slash"
        )
        AppShortcut(
            intent: SetBrowserReaderIntent(),
            phrases: [
                "Read this page with \(.applicationName)"
            ],
            shortTitle: "Reader mode",
            systemImageName: "doc.plaintext"
        )
        AppShortcut(
            intent: TranslateBrowserPageIntent(),
            phrases: [
                "Translate this page with \(.applicationName)"
            ],
            shortTitle: "Translate page",
            systemImageName: "character.bubble"
        )
        AppShortcut(
            intent: SummarizeBrowserPageIntent(),
            phrases: [
                "Summarize this page with \(.applicationName)"
            ],
            shortTitle: "Summarize page",
            systemImageName: "text.quote"
        )
        AppShortcut(
            intent: AskBrowserLocalIntent(),
            phrases: [
                "Ask on-device AI in \(.applicationName)"
            ],
            shortTitle: "On-device AI",
            systemImageName: "apple.intelligence"
        )
    }
}
