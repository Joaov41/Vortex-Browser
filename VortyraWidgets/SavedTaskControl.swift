import AppIntents
import SwiftUI
import WidgetKit

/// A saved task offered to the Run Saved Task control. Only the id and title are read from the shared store.
struct SavedTaskOption: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved task"
    static let defaultQuery = SavedTaskOptionQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(task: WidgetStore.SavedTask) {
        self.id = task.id.uuidString
        self.title = task.title
    }
}

struct SavedTaskOptionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SavedTaskOption] {
        let wanted = Set(identifiers)
        return WidgetStore.savedTasks()
            .filter { wanted.contains($0.id.uuidString) }
            .map(SavedTaskOption.init(task:))
    }

    func suggestedEntities() async throws -> [SavedTaskOption] {
        WidgetStore.savedTasks().map(SavedTaskOption.init(task:))
    }
}

struct SelectSavedTaskControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Saved Task"
    static let description = IntentDescription("Choose the saved task this control runs in Vortyra.")

    @Parameter(title: "Saved Task")
    var savedTask: SavedTaskOption?
}

/// Runs one chosen saved task. The app queues it through the same path as the Run Saved Browser Task shortcut.
struct RunSavedTaskControl: ControlWidget {
    static let kind = "com.web.me.Browser.control.runSavedTask"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, intent: SelectSavedTaskControlIntent.self) { configuration in
            let chosenID = configuration.savedTask.flatMap { UUID(uuidString: $0.id) }
            let url = chosenID.map(WidgetLinks.savedTask(id:)) ?? WidgetLinks.savedTaskWithoutID
            let title = configuration.savedTask?.title ?? "Choose a task"
            ControlWidgetButton(action: OpenURLIntent(url)) {
                Label(title, systemImage: "arrow.clockwise")
            }
        }
        .displayName("Run Saved Task")
        .description("Run one of your saved browser tasks.")
    }
}
