import Foundation

/// Read-only access to the app's saved-task and page-watch files in the shared app group.
///
/// The widget keeps its own small decoders on purpose: it compiles none of the app's sources.
/// Only the fields the widget shows are decoded, unknown keys are ignored, and every reader returns
/// an empty list on any error. Nothing here writes to the app's files.
enum WidgetStore {
    static let appGroupIdentifier = "group.com.browser.app"
    static let fallbackAppBundleIdentifier = "com.web.me.Browser"
    static let widgetBundleSuffix = ".Widgets"
    static let maximumSavedTasks = 50
    static let maximumWatches = 20
    /// Widget processes have a small memory budget. Larger documents are ignored rather than read.
    static let maximumDocumentBytes = 16_000_000

    struct SavedTask: Decodable, Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
    }

    struct Watch: Decodable, Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let lastCheckedAt: Date?
        let lastChangeAt: Date?
    }

    private struct TasksDocument: Decodable {
        let savedTasks: [SavedTask]
    }

    private struct WatchesDocument: Decodable {
        let watches: [Watch]
    }

    /// The app's bundle identifier: the widget's identifier without its trailing ".Widgets".
    static var appBundleIdentifier: String {
        let widgetIdentifier = Bundle.main.bundleIdentifier ?? ""
        guard widgetIdentifier.hasSuffix(widgetBundleSuffix),
              widgetIdentifier.count > widgetBundleSuffix.count else {
            return fallbackAppBundleIdentifier
        }
        return String(widgetIdentifier.dropLast(widgetBundleSuffix.count))
    }

    static func savedTasks() -> [SavedTask] {
        guard let data = readDocument(named: "AgentTasks.\(appBundleIdentifier).json"),
              let document = try? JSONDecoder().decode(TasksDocument.self, from: data) else {
            return []
        }
        return Array(document.savedTasks.prefix(maximumSavedTasks))
    }

    static func savedTask(id: UUID) -> SavedTask? {
        savedTasks().first { $0.id == id }
    }

    static func watches() -> [Watch] {
        guard let data = readDocument(named: "PageWatches.\(appBundleIdentifier).json"),
              let document = try? JSONDecoder().decode(WatchesDocument.self, from: data) else {
            return []
        }
        return Array(document.watches.prefix(maximumWatches))
    }

    private static func readDocument(named fileName: String) -> Data? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        let url = container.appendingPathComponent(fileName, isDirectory: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumDocumentBytes else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}

/// Links the widget and controls open. They match the app's `webmebrowser://` routes exactly.
enum WidgetLinks {
    static let privateTab = URL(string: "webmebrowser://private-tab")!
    static let searchClipboard = URL(string: "webmebrowser://search-clipboard")!
    /// Used by the Run Saved Task control before a task is chosen. The app explains that the control needs a task.
    static let savedTaskWithoutID = URL(string: "webmebrowser://saved-task")!

    static func savedTask(id: UUID) -> URL {
        URL(string: "webmebrowser://saved-task?id=\(id.uuidString)")!
    }

    static func watch(id: UUID) -> URL {
        URL(string: "webmebrowser://watch?id=\(id.uuidString)")!
    }
}
