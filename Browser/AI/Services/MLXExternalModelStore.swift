import Foundation

struct MLXExternalModelStore {
    static let selectedBookmarkKey = "MLXExternalModelBookmark"
    static let selectedPathKey = "MLXExternalModelPath"
    static let bookmarksKey = "MLXExternalModelBookmarks"
    static let pathsKey = "MLXExternalModelPaths"

    struct Entry: Identifiable, Hashable {
        let id: String
        let path: String
        let name: String
    }

    static func loadEntries(defaults: UserDefaults = .standard) -> [Entry] {
        var paths = defaults.stringArray(forKey: pathsKey) ?? []
        let legacyPath = defaults.string(forKey: selectedPathKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let legacyPath, !legacyPath.isEmpty, !paths.contains(legacyPath) {
            paths.insert(legacyPath, at: 0)
            defaults.set(paths, forKey: pathsKey)
        }

        var bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        if let legacyBookmark = defaults.data(forKey: selectedBookmarkKey),
           let legacyPath, !legacyPath.isEmpty,
           bookmarks[legacyPath] == nil {
            bookmarks[legacyPath] = legacyBookmark
            defaults.set(bookmarks, forKey: bookmarksKey)
        }

        var seen = Set<String>()
        var entries: [Entry] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            let url = URL(fileURLWithPath: trimmed)
            let configPath = url.appendingPathComponent("config.json")
            guard FileManager.default.fileExists(atPath: configPath.path) else { continue }
            entries.append(Entry(id: trimmed, path: trimmed, name: url.lastPathComponent))
            seen.insert(trimmed)
        }

        return entries
    }

    static func addEntry(path: String, bookmark: Data?, defaults: UserDefaults = .standard) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var paths = defaults.stringArray(forKey: pathsKey) ?? []
        if !paths.contains(trimmed) {
            paths.append(trimmed)
            defaults.set(paths, forKey: pathsKey)
        }

        if let bookmark {
            var bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
            bookmarks[trimmed] = bookmark
            defaults.set(bookmarks, forKey: bookmarksKey)
        }
    }

    static func removeEntry(path: String, defaults: UserDefaults = .standard) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var paths = defaults.stringArray(forKey: pathsKey) ?? []
        paths.removeAll { $0 == trimmed }
        defaults.set(paths, forKey: pathsKey)

        var bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: trimmed)
        defaults.set(bookmarks, forKey: bookmarksKey)

        if defaults.string(forKey: selectedPathKey) == trimmed {
            clearSelection(defaults: defaults)
        }
    }

    static func bookmark(for path: String, defaults: UserDefaults = .standard) -> Data? {
        let bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        return bookmarks[path]
    }

    static func selectedPath(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: selectedPathKey)
    }

    static func setSelected(path: String?, bookmark: Data?, defaults: UserDefaults = .standard) {
        if let path, !path.isEmpty {
            defaults.set(path, forKey: selectedPathKey)
        } else {
            defaults.removeObject(forKey: selectedPathKey)
        }

        if let bookmark {
            defaults.set(bookmark, forKey: selectedBookmarkKey)
        } else {
            defaults.removeObject(forKey: selectedBookmarkKey)
        }
    }

    static func clearSelection(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: selectedPathKey)
        defaults.removeObject(forKey: selectedBookmarkKey)
    }
}
