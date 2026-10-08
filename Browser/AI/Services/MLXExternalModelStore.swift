import Foundation

struct MLXExternalModelStore {
    static let selectedBookmarkKey = "MLXExternalModelBookmark"
    static let selectedPathKey = "MLXExternalModelPath"
    static let bookmarksKey = "MLXExternalModelBookmarks"
    static let pathsKey = "MLXExternalModelPaths"
    /// Model path -> path of the model folder relative to the bookmarked folder.
    /// Set when a model is downloaded into a user-picked folder: the bookmark then
    /// covers the picked folder (which carries the security scope) rather than
    /// the model subfolder inside it.
    static let relativePathsKey = "MLXExternalModelRelativePaths"

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
            // Folders outside the sandbox (iCloud Drive, external drives) are only
            // readable through their security-scoped bookmark.
            let resolved = resolve(path: trimmed, defaults: defaults)
            let didAccess = resolved.scope?.startAccessingSecurityScopedResource() ?? false
            let hasConfig = FileManager.default.fileExists(
                atPath: resolved.model.appendingPathComponent("config.json").path
            )
            if didAccess { resolved.scope?.stopAccessingSecurityScopedResource() }
            guard hasConfig else { continue }
            entries.append(Entry(id: trimmed, path: trimmed, name: URL(fileURLWithPath: trimmed).lastPathComponent))
            seen.insert(trimmed)
        }

        return entries
    }

    static func addEntry(
        path: String,
        bookmark: Data?,
        relativePath: String? = nil,
        defaults: UserDefaults = .standard
    ) {
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

            var relativePaths = defaults.dictionary(forKey: relativePathsKey) as? [String: String] ?? [:]
            if let relativePath, !relativePath.isEmpty {
                relativePaths[trimmed] = relativePath
            } else {
                relativePaths.removeValue(forKey: trimmed)
            }
            defaults.set(relativePaths, forKey: relativePathsKey)
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

        var relativePaths = defaults.dictionary(forKey: relativePathsKey) as? [String: String] ?? [:]
        relativePaths.removeValue(forKey: trimmed)
        defaults.set(relativePaths, forKey: relativePathsKey)

        if defaults.string(forKey: selectedPathKey) == trimmed {
            clearSelection(defaults: defaults)
        }
    }

    static func bookmark(for path: String, defaults: UserDefaults = .standard) -> Data? {
        let bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        return bookmarks[path]
    }

    static func relativePath(for path: String, defaults: UserDefaults = .standard) -> String? {
        let relativePaths = defaults.dictionary(forKey: relativePathsKey) as? [String: String] ?? [:]
        return relativePaths[path]
    }

    /// Resolves a saved model path to the folder to load (`model`) and the URL whose
    /// security scope must be held while reading it (`scope`, nil when no bookmark).
    static func resolve(path: String, defaults: UserDefaults = .standard) -> (model: URL, scope: URL?) {
        let fallback = URL(fileURLWithPath: path)
        let bookmarkData = bookmark(for: path, defaults: defaults)
            ?? (selectedPath(defaults: defaults) == path ? defaults.data(forKey: selectedBookmarkKey) : nil)
        guard let bookmarkData else { return (fallback, nil) }

        var isStale = false
        #if os(iOS)
        let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #else
        let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #endif
        guard let scopeURL = resolvedURL else { return (fallback, nil) }

        if let relative = relativePath(for: path, defaults: defaults), !relative.isEmpty {
            return (scopeURL.appending(path: relative), scopeURL)
        }
        return (scopeURL, scopeURL)
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

/// Where Hugging Face model ids are stored when they are downloaded into the app
/// (mirrors the `HubApi` download base used by `MLXLocalService`).
enum MLXModelStorage {
    /// The only files MLX needs to load a model; everything else in a repo
    /// (GGUF/PyTorch copies, images, READMEs) is skipped.
    static let modelFileGlobs = ["*.safetensors", "*.json", "*.jinja"]

    static var appDownloadBase: URL {
        #if os(macOS)
        return URL.homeDirectory.appending(path: ".cache/huggingface/hub")
        #else
        return URL.cachesDirectory.appending(path: "huggingface")
        #endif
    }

    static func isExternal(_ modelID: String) -> Bool {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("external:")
    }

    static func appStorageURL(for modelID: String) -> URL {
        appDownloadBase.appending(path: "models").appending(path: modelID)
    }

    /// True when every weight file of a Hugging Face model id is already in app storage.
    static func isDownloaded(modelID: String) -> Bool {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !isExternal(id) else { return false }
        return isCompleteModelDirectory(appStorageURL(for: id))
    }

    /// A folder is loadable when it has config.json and all of its safetensors weights
    /// (including every shard listed in a sharded model's index).
    static func isCompleteModelDirectory(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appending(path: "config.json").path) else { return false }

        let indexURL = directory.appending(path: "model.safetensors.index.json")
        if let data = try? Data(contentsOf: indexURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let weightMap = json["weight_map"] as? [String: String] {
            return Set(weightMap.values).allSatisfy { fm.fileExists(atPath: directory.appending(path: $0).path) }
        }

        let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// Maps a folder inside app storage back to its Hugging Face id ("org/name"),
    /// so it can be selected by id instead of by an absolute sandbox path that may
    /// change when the app is updated.
    static func appStorageModelID(for directory: URL) -> String? {
        let base = appDownloadBase.appending(path: "models").resolvingSymlinksInPath().pathComponents
        let components = directory.resolvingSymlinksInPath().pathComponents
        guard components.count == base.count + 2, Array(components.prefix(base.count)) == base else {
            return nil
        }
        return components.suffix(2).joined(separator: "/")
    }
}
