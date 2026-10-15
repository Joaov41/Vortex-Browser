import Foundation
import CoreFoundation
import Combine

struct PendingAgentTask: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var task: String
    var startURL: URL?
    var savedTaskID: UUID?
    var enqueuedAt: Date

    init(
        id: UUID = UUID(),
        task: String,
        startURL: URL? = nil,
        savedTaskID: UUID? = nil,
        enqueuedAt: Date = Date()
    ) {
        self.id = id
        self.task = task
        self.startURL = startURL
        self.savedTaskID = savedTaskID
        self.enqueuedAt = enqueuedAt
    }
}

/// Per-window launch payload shared by saved-task and history replay actions.
/// History replay deliberately carries no saved-task identity.
struct AgentTaskLaunchRequest: Equatable, Sendable {
    let task: String
    let startURL: URL?
    let savedTaskID: UUID?

    init(task: String, startURL: URL? = nil, savedTaskID: UUID? = nil) {
        self.task = task
        self.startURL = startURL
        self.savedTaskID = savedTaskID
    }

    init(savedTask: SavedAgentTask) {
        self.init(task: savedTask.runTaskText, startURL: savedTask.startURL, savedTaskID: savedTask.id)
    }

    init(historyRecord: AgentRunRecord) {
        self.init(task: historyRecord.task, startURL: historyRecord.startURL)
    }
}

enum AgentTaskURLParseError: Error, Equatable, LocalizedError {
    case malformedAgentURL
    case duplicateParameter(String)
    case unknownParameter(String)
    case missingTask
    case invalidTask
    case invalidStartURL

    var errorDescription: String? {
        switch self {
        case .malformedAgentURL: return "The browser-task link is malformed."
        case .duplicateParameter(let name): return "The browser-task link contains more than one \(name) value."
        case .unknownParameter(let name): return "The browser-task link contains an unsupported parameter: \(name)."
        case .missingTask: return "The browser-task link does not include task instructions."
        case .invalidTask: return "The browser-task instructions are empty or too long."
        case .invalidStartURL: return "The starting address must be an HTTP or HTTPS website."
        }
    }
}

enum AgentTaskURLParser {
    static let maximumTaskUTF8Bytes = 20_000
    static let maximumStartURLCharacters = 4_096

    /// Returns nil for every URL outside the exact app handoff route.
    static func parse(_ url: URL) throws -> PendingAgentTask? {
        guard url.scheme?.lowercased() == "webmebrowser",
              url.host?.lowercased() == "agent" else { return nil }
        guard url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AgentTaskURLParseError.malformedAgentURL
        }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard item.name == "task" || item.name == "url" else {
                throw AgentTaskURLParseError.unknownParameter(item.name)
            }
            guard values[item.name] == nil else {
                throw AgentTaskURLParseError.duplicateParameter(item.name)
            }
            guard let value = item.value else { throw AgentTaskURLParseError.malformedAgentURL }
            values[item.name] = value
        }

        guard let task = values["task"] else { throw AgentTaskURLParseError.missingTask }
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.utf8.count <= maximumTaskUTF8Bytes else {
            throw AgentTaskURLParseError.invalidTask
        }

        let startURL: URL?
        if let rawStartURL = values["url"] {
            guard let candidate = URL(string: rawStartURL), isAllowedStartURL(candidate) else {
                throw AgentTaskURLParseError.invalidStartURL
            }
            startURL = candidate
        } else {
            startURL = nil
        }
        return PendingAgentTask(task: task, startURL: startURL)
    }

    static func isAllowedStartURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              url.absoluteString.count <= maximumStartURLCharacters else { return false }
        return true
    }
}

enum AgentRunURLParseError: Error, Equatable, LocalizedError {
    case malformedRunURL

    var errorDescription: String? {
        switch self {
        case .malformedRunURL: return "The browser-task result link is malformed."
        }
    }
}

/// Parses `webmebrowser://run?id=<UUID>`, the link that opens a finished run's detail page.
/// Exactly one `id` query item holding a UUID is accepted. Any other shape is rejected.
enum AgentRunURLParser {
    static let host = "run"
    static let idParameter = "id"
    static let missingRunMessage = "That browser task is no longer in your history."

    /// Returns nil for every URL whose host is not `run`. Throws for a `run` link that is not exactly one valid UUID `id`.
    static func parse(_ url: URL) throws -> UUID? {
        guard url.scheme?.lowercased() == AgentIncomingURLRouter.appScheme,
              url.host?.lowercased() == host else { return nil }
        guard url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              (components.percentEncodedQuery ?? "").components(separatedBy: "&").count == 1,
              let items = components.queryItems,
              items.count == 1,
              items[0].name == idParameter,
              let value = items[0].value,
              let runID = UUID(uuidString: value) else {
            throw AgentRunURLParseError.malformedRunURL
        }
        return runID
    }

    /// The canonical link for a run. Used by the snippet's Open button.
    static func url(for runID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = AgentIncomingURLRouter.appScheme
        components.host = host
        components.queryItems = [URLQueryItem(name: idParameter, value: runID.uuidString)]
        return components.url
    }
}

enum AgentControlURLParseError: Error, Equatable, LocalizedError {
    case malformedControlURL
    case missingSavedTaskID

    var errorDescription: String? {
        switch self {
        case .malformedControlURL: return "The Vortyra control link is malformed."
        case .missingSavedTaskID: return "This control has no saved task. Edit the control and choose one."
        }
    }
}

/// Parses the links that Home Screen widgets and Control Center controls open:
/// `webmebrowser://private-tab` and `webmebrowser://search-clipboard` (no query), and
/// `webmebrowser://saved-task?id=<UUID>` (exactly one UUID `id`). Any other shape on these hosts is rejected.
enum AgentControlURLParser {
    enum Action: Equatable, Sendable {
        case privateTab
        case searchClipboard
        case savedTask(UUID)
    }

    static let privateTabHost = "private-tab"
    static let searchClipboardHost = "search-clipboard"
    static let savedTaskHost = "saved-task"
    static let idParameter = "id"
    static let missingSavedTaskMessage = "That saved task no longer exists."
    static let emptyClipboardMessage = "The clipboard has no text to search."
    static let unsearchableClipboardMessage = "The clipboard text is too long to search."

    /// True for every URL on one of the three control hosts, well formed or not.
    static func isControlURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == AgentIncomingURLRouter.appScheme,
              let host = url.host?.lowercased() else { return false }
        return host == privateTabHost || host == searchClipboardHost || host == savedTaskHost
    }

    /// Returns nil for every URL outside the three control hosts. Throws for a control link with any other shape.
    static func parse(_ url: URL) throws -> Action? {
        guard isControlURL(url), let host = url.host?.lowercased() else { return nil }
        guard url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil else {
            throw AgentControlURLParseError.malformedControlURL
        }

        switch host {
        case privateTabHost:
            guard components.percentEncodedQuery == nil else { throw AgentControlURLParseError.malformedControlURL }
            return .privateTab
        case searchClipboardHost:
            guard components.percentEncodedQuery == nil else { throw AgentControlURLParseError.malformedControlURL }
            return .searchClipboard
        default:
            guard components.percentEncodedQuery != nil else { throw AgentControlURLParseError.missingSavedTaskID }
            guard (components.percentEncodedQuery ?? "").components(separatedBy: "&").count == 1,
                  let items = components.queryItems,
                  items.count == 1,
                  items[0].name == idParameter,
                  let value = items[0].value,
                  let taskID = UUID(uuidString: value) else {
                throw AgentControlURLParseError.malformedControlURL
            }
            return .savedTask(taskID)
        }
    }

    /// The queued request for a saved task. It matches what Run Saved Browser Task enqueues.
    static func pendingRequest(for task: SavedAgentTask) -> PendingAgentTask {
        PendingAgentTask(task: task.runTaskText, startURL: task.startURL, savedTaskID: task.id)
    }
}

/// A pure decision seam that preserves the app's existing URL-dispatch precedence.
/// ContentView handles `.agentTask` and `.run` in its own URL handler; these cases are the testable decision for each URL.
enum AgentIncomingURLRoute: Equatable {
    case bookmarkFile(URL)
    case defaultBrowserLink(URL)
    case cloudShortcut(URL)
    case agentTask(PendingAgentTask)
    case run(UUID)
    case pageWatch(UUID)
    case privateTab
    case searchClipboard
    case savedTask(UUID)
    case sharedText(String)
    case sharedPayload
    case unhandled
}

enum AgentIncomingURLRouter {
    static let appScheme = "webmebrowser"

    static func route(_ url: URL, cloudShortcutWasHandled: Bool = false) throws -> AgentIncomingURLRoute {
        if url.isFileURL { return .bookmarkFile(url) }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return .defaultBrowserLink(url)
        }
        if cloudShortcutWasHandled { return .cloudShortcut(url) }
        guard url.scheme?.lowercased() == appScheme else { return .unhandled }
        if let task = try AgentTaskURLParser.parse(url) {
            return .agentTask(task)
        }
        if let runID = try AgentRunURLParser.parse(url) {
            return .run(runID)
        }
        if let watchID = try PageWatchURLParser.parse(url) {
            return .pageWatch(watchID)
        }
        if let control = try AgentControlURLParser.parse(url) {
            switch control {
            case .privateTab: return .privateTab
            case .searchClipboard: return .searchClipboard
            case .savedTask(let id): return .savedTask(id)
            }
        }
        let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "text" })?.value
        if let text, !text.isEmpty { return .sharedText(text) }
        return .sharedPayload
    }
}

enum PendingAgentTaskQueueError: Error, Equatable, LocalizedError {
    case invalidTask
    case queueFull(limit: Int)
    case duplicateRequest
    case corruptQueue
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidTask: return "The browser task could not be queued because its instructions are empty or too long."
        case .queueFull(let limit): return "The browser already has \(limit) pending tasks. Open Vortyra and try again when one finishes."
        case .duplicateRequest: return "That browser task is already pending."
        case .corruptQueue: return "Pending browser tasks could not be read; existing requests were left unchanged."
        case .readFailed: return "Vortyra could not confirm its pending-task queue. Check the app before retrying."
        case .writeFailed: return "Vortyra could not confirm that the task was queued. Check the app before retrying."
        }
    }
}

@MainActor
protocol PendingAgentTaskQueuePersistence {
    func readData(forKey key: String) throws -> Data?
    func writeData(_ data: Data, forKey key: String) throws
}

@MainActor
struct UserDefaultsAgentTaskQueuePersistence: PendingAgentTaskQueuePersistence {
    let defaults: UserDefaults
    private let synchronizeDefaults: @MainActor () -> Bool

    init(
        defaults: UserDefaults,
        synchronizeDefaults: (@MainActor () -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.synchronizeDefaults = synchronizeDefaults ?? { defaults.synchronize() }
    }

    func readData(forKey key: String) throws -> Data? {
        return defaults.data(forKey: key)
    }

    func writeData(_ data: Data, forKey key: String) throws {
        let previous = try readData(forKey: key)
        defaults.set(data, forKey: key)
        guard synchronizeDefaults(), defaults.data(forKey: key) == data else {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            _ = synchronizeDefaults()
            throw PendingAgentTaskQueueError.writeFailed
        }
    }
}

private struct PendingAgentTaskQueueDocument: Codable {
    static let currentVersion = 1
    var version = currentVersion
    var pending: [PendingAgentTask] = []
    var consumedIDs: [UUID] = []
}

@MainActor
final class PendingAgentTaskQueue {
    static let maximumPendingTasks = 8
    static let consumedIDLimit = 256
    static let maximumEncodedQueueBytes = 1_000_000

    private let persistence: any PendingAgentTaskQueuePersistence
    private let storageKey: String
    private let capacity: Int

    init(
        defaults: UserDefaults,
        storageKey: String,
        capacity: Int = 8
    ) {
        self.persistence = UserDefaultsAgentTaskQueuePersistence(defaults: defaults)
        self.storageKey = storageKey
        self.capacity = min(Self.maximumPendingTasks, max(1, capacity))
    }

    init(
        persistence: any PendingAgentTaskQueuePersistence,
        storageKey: String,
        capacity: Int = 8
    ) {
        self.persistence = persistence
        self.storageKey = storageKey
        self.capacity = min(Self.maximumPendingTasks, max(1, capacity))
    }

    func pendingTasks() throws -> [PendingAgentTask] {
        try readDocument().pending
    }

    func consumeNextIfReady(
        isForeground: Bool,
        hasBrowserView: Bool,
        aiBusy: Bool,
        agentBusy: Bool,
        startupBusy: Bool
    ) throws -> PendingAgentTask? {
        guard isForeground, hasBrowserView, !aiBusy, !agentBusy, !startupBusy else { return nil }
        return try consumeNext()
    }

    func enqueue(_ task: PendingAgentTask) throws {
        guard !task.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.task.utf8.count <= AgentTaskURLParser.maximumTaskUTF8Bytes,
              task.startURL.map(AgentTaskURLParser.isAllowedStartURL) ?? true else {
            throw PendingAgentTaskQueueError.invalidTask
        }
        var document = try readDocument()
        guard !document.pending.contains(where: { $0.id == task.id }),
              !document.consumedIDs.contains(task.id) else {
            throw PendingAgentTaskQueueError.duplicateRequest
        }
        guard document.pending.count < capacity else { throw PendingAgentTaskQueueError.queueFull(limit: capacity) }
        document.pending.append(task)
        try writeDocument(document)
    }

    /// The head is removed and synchronously persisted before return, so repeat observers cannot consume it twice.
    func consumeNext() throws -> PendingAgentTask? {
        var document = try readDocument()
        guard let first = document.pending.first else { return nil }
        document.pending.removeFirst()
        document.consumedIDs.append(first.id)
        document.consumedIDs = Array(document.consumedIDs.suffix(Self.consumedIDLimit))
        try writeDocument(document)
        return first
    }

    private func readDocument() throws -> PendingAgentTaskQueueDocument {
        guard let data = try persistence.readData(forKey: storageKey) else {
            return PendingAgentTaskQueueDocument()
        }
        guard data.count <= Self.maximumEncodedQueueBytes else {
            throw PendingAgentTaskQueueError.corruptQueue
        }
        let document: PendingAgentTaskQueueDocument
        do {
            document = try JSONDecoder().decode(PendingAgentTaskQueueDocument.self, from: data)
        } catch {
            throw PendingAgentTaskQueueError.corruptQueue
        }
        guard document.version == PendingAgentTaskQueueDocument.currentVersion,
              document.pending.count <= capacity,
              document.consumedIDs.count <= Self.consumedIDLimit,
              Set(document.pending.map(\.id)).count == document.pending.count,
              Set(document.consumedIDs).count == document.consumedIDs.count,
              Set(document.pending.map(\.id)).isDisjoint(with: Set(document.consumedIDs)),
              document.pending.allSatisfy(isSemanticallyValid) else {
            throw PendingAgentTaskQueueError.corruptQueue
        }
        return document
    }

    private func isSemanticallyValid(_ task: PendingAgentTask) -> Bool {
        !task.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && task.task.utf8.count <= AgentTaskURLParser.maximumTaskUTF8Bytes
            && (task.startURL.map(AgentTaskURLParser.isAllowedStartURL) ?? true)
    }

    private func writeDocument(_ document: PendingAgentTaskQueueDocument) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            guard data.count <= Self.maximumEncodedQueueBytes else {
                throw PendingAgentTaskQueueError.writeFailed
            }
            try persistence.writeData(data, forKey: storageKey)
        } catch let error as PendingAgentTaskQueueError {
            throw error
        } catch {
            throw PendingAgentTaskQueueError.writeFailed
        }
    }
}

@MainActor
final class AgentTaskHandoffCoordinator {
    private let queue: PendingAgentTaskQueue
    private let notify: @MainActor () -> Void

    init(queue: PendingAgentTaskQueue, notify: (@MainActor () -> Void)? = nil) {
        self.queue = queue
        self.notify = notify ?? { AgentTaskHandoffNotification.post() }
    }

    func enqueue(_ task: PendingAgentTask) throws {
        try queue.enqueue(task)
        notify()
    }
}

enum AgentTaskHandoffNotification {
    static let darwinName = "com.browser.agentTask.pending" as CFString
    static let localName = Notification.Name("Browser.AgentTaskPending")

    static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: darwinName),
            nil,
            nil,
            true
        )
        NotificationCenter.default.post(name: localName, object: nil)
    }
}

/// Window-local listener for the separate agent queue channel. The existing
/// shared-URL observer remains untouched so share-extension delivery keeps its
/// established key and precedence.
@MainActor
final class AgentTaskDarwinNotificationObserver: ObservableObject {
    private static let notificationName = AgentTaskHandoffNotification.darwinName

    let notifications = PassthroughSubject<Void, Never>()
    private var localObserver: NSObjectProtocol?

    func startObserving() {
        stopObserving()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let instance = Unmanaged<AgentTaskDarwinNotificationObserver>
                .fromOpaque(observer)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                instance.notifications.send()
            }
        }
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            callback,
            Self.notificationName,
            nil,
            .deliverImmediately
        )
        localObserver = NotificationCenter.default.addObserver(
            forName: AgentTaskHandoffNotification.localName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.notifications.send() }
        }
    }

    func stopObserving() {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
        if let localObserver {
            NotificationCenter.default.removeObserver(localObserver)
            self.localObserver = nil
        }
    }

    isolated deinit {
        stopObserving()
    }
}
