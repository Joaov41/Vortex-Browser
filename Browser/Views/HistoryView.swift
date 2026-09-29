import SwiftUI

/// Browsing history grouped by day, with recently closed tabs on top.
struct HistoryView: View {
    @ObservedObject var viewModel: BrowserViewModel
    let onOpen: (URL) -> Void

    @ObservedObject private var history = HistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showClearOptions = false

    private static let recentlyClosedPreviewCount = 5

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty && !viewModel.recentlyClosedTabs.isEmpty {
                    recentlyClosedSection
                }
                ForEach(daySections) { section in
                    Section(section.title) {
                        ForEach(section.entries) { entry in
                            Button {
                                onOpen(entry.url)
                                dismiss()
                            } label: {
                                HistoryRow(title: entry.title, url: entry.url) {
                                    Text(entry.visitedAt, format: .dateTime.hour().minute())
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    history.remove([entry.id])
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if daySections.isEmpty && (!searchText.isEmpty || viewModel.recentlyClosedTabs.isEmpty) {
                    if searchText.isEmpty {
                        ContentUnavailableView(
                            "No History",
                            systemImage: "clock",
                            description: Text("Pages you visit appear here. Private tabs are never recorded.")
                        )
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search History")
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear") { showClearOptions = true }
                        .disabled(history.entries.isEmpty && viewModel.recentlyClosedTabs.isEmpty)
                }
            }
            .confirmationDialog("Clear History", isPresented: $showClearOptions, titleVisibility: .visible) {
                Button("Last Hour", role: .destructive) {
                    history.clear(since: Date().addingTimeInterval(-3600))
                }
                Button("Today", role: .destructive) {
                    history.clear(since: Calendar.current.startOfDay(for: Date()))
                }
                Button("All History", role: .destructive) {
                    history.clear(since: nil)
                    viewModel.clearRecentlyClosed()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("History is stored only on this device.")
            }
        }
    }

    private var recentlyClosedSection: some View {
        Section {
            ForEach(viewModel.recentlyClosedTabs.prefix(Self.recentlyClosedPreviewCount)) { record in
                recentlyClosedButton(record)
            }
            if viewModel.recentlyClosedTabs.count > Self.recentlyClosedPreviewCount {
                NavigationLink("Show All (\(viewModel.recentlyClosedTabs.count))") {
                    List(viewModel.recentlyClosedTabs) { record in
                        recentlyClosedButton(record)
                    }
                    .navigationTitle("Recently Closed")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        } header: {
            Text("Recently Closed")
        }
    }

    private func recentlyClosedButton(_ record: RecentlyClosedTab) -> some View {
        Button {
            viewModel.reopenRecentlyClosed(record)
            dismiss()
        } label: {
            HistoryRow(title: record.title, url: record.url) {
                Text(record.closedAt, style: .relative)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Reopens this tab")
    }

    private struct DaySection: Identifiable {
        let id: Date
        let title: String
        let entries: [HistoryEntry]
    }

    private var daySections: [DaySection] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = needle.isEmpty ? history.entries : history.entries.filter {
            $0.title.lowercased().contains(needle) || $0.url.absoluteString.lowercased().contains(needle)
        }
        let calendar = Calendar.current
        var sections: [DaySection] = []
        var currentDay: Date?
        var bucket: [HistoryEntry] = []
        func flush() {
            guard let day = currentDay, !bucket.isEmpty else { return }
            sections.append(DaySection(id: day, title: Self.title(for: day, calendar: calendar), entries: bucket))
        }
        // Entries are newest first, so each day's visits are contiguous.
        for entry in matching {
            let day = calendar.startOfDay(for: entry.visitedAt)
            if day != currentDay {
                flush()
                currentDay = day
                bucket = []
            }
            bucket.append(entry)
        }
        flush()
        return sections
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// Site initial, title and domain, with a trailing detail (time or "5 min ago").
private struct HistoryRow<Detail: View>: View {
    let title: String
    let url: URL
    @ViewBuilder let detail: () -> Detail

    private var domain: String {
        guard var host = url.host else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(String(domain.prefix(1)).uppercased())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? domain : title)
                    .font(.body)
                    .lineLimit(1)
                Text(domain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            detail()
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
