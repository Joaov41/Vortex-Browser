import Combine
import Foundation

struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let url: URL
    var title: String
    var visitedAt: Date
}

/// Pages visited in regular tabs, stored only on this device. Private tabs and the
/// in-app AI provider pages are never recorded (the caller filters them).
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let maxEntries = 5000
    static let maxAge: TimeInterval = 90 * 24 * 60 * 60
    /// A revisit of the page just recorded within this window updates that entry
    /// (reloads, late titles) instead of adding a duplicate.
    private static let revisitMergeWindow: TimeInterval = 30 * 60

    /// Newest first.
    @Published private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("history.json")
        load()
    }

    func record(url: URL, title: String?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayTitle = trimmedTitle.isEmpty ? (url.host ?? url.absoluteString) : trimmedTitle
        let now = Date()
        if let latest = entries.first, latest.url == url,
           now.timeIntervalSince(latest.visitedAt) < Self.revisitMergeWindow {
            entries[0].title = displayTitle
            entries[0].visitedAt = now
        } else {
            entries.insert(HistoryEntry(id: UUID(), url: url, title: displayTitle, visitedAt: now), at: 0)
        }
        prune(now: now)
        scheduleSave()
    }

    func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    /// Clears visits made since `date`, or everything when `date` is nil.
    func clear(since date: Date?) {
        if let date {
            entries.removeAll { $0.visitedAt >= date }
        } else {
            entries.removeAll()
        }
        scheduleSave()
    }

    /// Address-bar matches, one per URL. A domain that starts with the query ranks
    /// above a URL or title that merely contains it; frequent and recent visits rank
    /// higher within each.
    func suggestions(for query: String, limit: Int = 5) -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let now = Date()
        var ranked: [URL: (entry: HistoryEntry, score: Double)] = [:]
        for entry in entries {
            let recency = 1 / (1 + now.timeIntervalSince(entry.visitedAt) / 86_400)
            if let existing = ranked[entry.url] {
                ranked[entry.url] = (existing.entry, existing.score + 0.5 + recency)
                continue
            }
            var host = (entry.url.host ?? "").lowercased()
            if host.hasPrefix("www.") { host.removeFirst(4) }
            let match: Double
            if host.hasPrefix(needle) {
                match = 3
            } else if entry.url.absoluteString.lowercased().contains(needle) {
                match = 2
            } else if entry.title.lowercased().contains(needle) {
                match = 1
            } else {
                continue
            }
            ranked[entry.url] = (entry, match * 10 + recency)
        }
        return ranked.values
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.entry)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
        prune(now: Date())
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.maxAge)
        if let last = entries.last, last.visitedAt < cutoff {
            entries.removeAll { $0.visitedAt < cutoff }
        }
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    /// Coalesces bursts of visits into one write; encoding stays on the main actor,
    /// only the file write runs in the background.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled,
                  let data = try? JSONEncoder().encode(self.entries) else { return }
            let destination = self.fileURL
            await Task.detached(priority: .utility) {
                try? data.write(to: destination, options: [.atomic, .completeFileProtection])
            }.value
        }
    }
}
