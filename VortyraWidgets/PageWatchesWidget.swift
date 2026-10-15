import SwiftUI
import WidgetKit

struct PageWatchesEntry: TimelineEntry {
    let date: Date
    let watches: [WidgetStore.Watch]
}

struct PageWatchesProvider: TimelineProvider {
    /// The widget reloads at most every 30 minutes, and the app also asks for a reload after watch checks.
    static let refreshInterval: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> PageWatchesEntry {
        PageWatchesEntry(date: Date(), watches: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (PageWatchesEntry) -> Void) {
        completion(PageWatchesEntry(date: Date(), watches: WidgetStore.watches()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PageWatchesEntry>) -> Void) {
        let now = Date()
        let entry = PageWatchesEntry(date: now, watches: WidgetStore.watches())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(Self.refreshInterval))))
    }
}

struct PageWatchesWidget: Widget {
    static let kind = "com.web.me.Browser.widget.pageWatches"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: PageWatchesProvider()) { entry in
            PageWatchesWidgetView(entry: entry)
        }
        .configurationDisplayName("Page Watches")
        .description("See which watched pages changed recently.")
        .supportedFamilies([.systemMedium])
    }
}

struct PageWatchesWidgetView: View {
    static let maximumRows = 4
    /// A watch shows the "Changed" badge when its last change happened within this window.
    static let recentChangeWindow: TimeInterval = 24 * 60 * 60

    let entry: PageWatchesEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Page Watches")
                .font(.headline)
            if entry.watches.isEmpty {
                Text("No page watches yet. Watch a page in Vortyra to see its changes here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.watches.prefix(Self.maximumRows)) { watch in
                    Link(destination: WidgetLinks.watch(id: watch.id)) {
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(watch.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(lastChangeText(for: watch))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if isRecentlyChanged(watch) {
                                Text("Changed")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.tint.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func lastChangeText(for watch: WidgetStore.Watch) -> String {
        guard let changedAt = watch.lastChangeAt else { return "No change yet" }
        return "Changed " + changedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func isRecentlyChanged(_ watch: WidgetStore.Watch) -> Bool {
        guard let changedAt = watch.lastChangeAt else { return false }
        let age = entry.date.timeIntervalSince(changedAt)
        return age >= 0 && age <= Self.recentChangeWindow
    }
}
