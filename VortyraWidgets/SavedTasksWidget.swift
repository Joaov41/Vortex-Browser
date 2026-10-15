import SwiftUI
import WidgetKit

struct SavedTasksEntry: TimelineEntry {
    let date: Date
    let tasks: [WidgetStore.SavedTask]
}

struct SavedTasksProvider: TimelineProvider {
    /// The widget reloads at most every 30 minutes, and the app also asks for a reload after task changes.
    static let refreshInterval: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> SavedTasksEntry {
        SavedTasksEntry(date: Date(), tasks: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (SavedTasksEntry) -> Void) {
        completion(SavedTasksEntry(date: Date(), tasks: WidgetStore.savedTasks()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SavedTasksEntry>) -> Void) {
        let now = Date()
        let entry = SavedTasksEntry(date: now, tasks: WidgetStore.savedTasks())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(Self.refreshInterval))))
    }
}

struct SavedTasksWidget: Widget {
    static let kind = "com.web.me.Browser.widget.savedTasks"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SavedTasksProvider()) { entry in
            SavedTasksWidgetView(entry: entry)
        }
        .configurationDisplayName("Saved Tasks")
        .description("Run your saved browser tasks from the Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SavedTasksWidgetView: View {
    static let maximumRows = 4

    let entry: SavedTasksEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved Tasks")
                .font(.headline)
            if entry.tasks.isEmpty {
                Text("No saved tasks yet. Save a task in Vortyra to see it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.tasks.prefix(Self.maximumRows)) { task in
                    Link(destination: WidgetLinks.savedTask(id: task.id)) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.tint)
                            Text(task.title)
                                .lineLimit(1)
                        }
                        .font(.callout)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
