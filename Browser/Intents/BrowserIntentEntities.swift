import AppIntents
import Foundation

enum BrowserIntentEntityError: LocalizedError {
    case malformedStorage
    case oversizedStorage

    var errorDescription: String? {
        switch self {
        case .malformedStorage:
            return "The stored browser data could not be read."
        case .oversizedStorage:
            return "The stored browser data is larger than this action supports."
        }
    }
}

enum BrowserIntentEntityStorage {
    static let groupsKey = "browser_tab_groups_v1"
    static let foldersKey = "browser_favorite_folders_v1"
    static let maximumBytes = 1_000_000
    static let maximumEntities = 100

    static func groups(from defaults: UserDefaults) throws -> [BrowserTabGroup] {
        guard let data = defaults.data(forKey: groupsKey) else { return [] }
        guard data.count <= maximumBytes else { throw BrowserIntentEntityError.oversizedStorage }
        guard let decoded = try? JSONDecoder().decode([BrowserTabGroup].self, from: data) else {
            throw BrowserIntentEntityError.malformedStorage
        }
        return decoded
    }

    static func folders(from defaults: UserDefaults) throws -> [FavoriteFolder] {
        guard let data = defaults.data(forKey: foldersKey) else { return [] }
        guard data.count <= maximumBytes else { throw BrowserIntentEntityError.oversizedStorage }
        guard let decoded = try? JSONDecoder().decode([FavoriteFolder].self, from: data) else {
            throw BrowserIntentEntityError.malformedStorage
        }
        return decoded
    }

    static func folderPaths(from defaults: UserDefaults) throws -> [UUID: String] {
        let folders = try folders(from: defaults)
        var paths: [UUID: String] = [:]
        var titleByID: [UUID: FavoriteFolder] = [:]
        for folder in folders { titleByID[folder.id] = folder }
        for folder in folders {
            var parts = [folder.title]
            var visited: Set<UUID> = [folder.id]
            var parent = folder.parentID.flatMap { titleByID[$0] }
            while let current = parent, !visited.contains(current.id), parts.count < 10 {
                parts.insert(current.title, at: 0)
                visited.insert(current.id)
                parent = current.parentID.flatMap { titleByID[$0] }
            }
            paths[folder.id] = parts.joined(separator: " › ")
        }
        return paths
    }
}

struct BrowserGroupEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tab Group"
    static let defaultQuery = BrowserGroupEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct BrowserFolderEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Favorites Folder"
    static let defaultQuery = BrowserFolderEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct BrowserGroupEntityQuery: EntityStringQuery {
    private let defaultsProvider: @Sendable () -> UserDefaults

    init() {
        self.init(defaultsProvider: { .standard })
    }

    init(defaultsProvider: @escaping @Sendable () -> UserDefaults) {
        self.defaultsProvider = defaultsProvider
    }

    func entities(for identifiers: [String]) async throws -> [BrowserGroupEntity] {
        let groups = try BrowserIntentEntityStorage.groups(from: defaultsProvider())
        let requested = Set(identifiers)
        return groups.filter { requested.contains($0.id.uuidString) }
            .prefix(BrowserIntentEntityStorage.maximumEntities)
            .map { BrowserGroupEntity(id: $0.id.uuidString, title: String($0.title.prefix(320))) }
    }

    func suggestedEntities() async throws -> [BrowserGroupEntity] {
        try BrowserIntentEntityStorage.groups(from: defaultsProvider())
            .prefix(BrowserIntentEntityStorage.maximumEntities)
            .map { BrowserGroupEntity(id: $0.id.uuidString, title: String($0.title.prefix(320))) }
    }

    func entities(matching string: String) async throws -> [BrowserGroupEntity] {
        try BrowserIntentEntityStorage.groups(from: defaultsProvider())
            .filter { $0.title.localizedCaseInsensitiveContains(string) }
            .prefix(BrowserIntentEntityStorage.maximumEntities)
            .map { BrowserGroupEntity(id: $0.id.uuidString, title: String($0.title.prefix(320))) }
    }
}

struct BrowserFolderEntityQuery: EntityStringQuery {
    private let defaultsProvider: @Sendable () -> UserDefaults

    init() {
        self.init(defaultsProvider: { .standard })
    }

    init(defaultsProvider: @escaping @Sendable () -> UserDefaults) {
        self.defaultsProvider = defaultsProvider
    }

    func entities(for identifiers: [String]) async throws -> [BrowserFolderEntity] {
        let folders = try BrowserIntentEntityStorage.folders(from: defaultsProvider())
        let paths = try BrowserIntentEntityStorage.folderPaths(from: defaultsProvider())
        let requested = Set(identifiers)
        return folders.filter { requested.contains($0.id.uuidString) }
            .prefix(BrowserIntentEntityStorage.maximumEntities)
            .map { BrowserFolderEntity(id: $0.id.uuidString, title: String((paths[$0.id] ?? $0.title).prefix(320))) }
    }

    func suggestedEntities() async throws -> [BrowserFolderEntity] {
        let folders = try BrowserIntentEntityStorage.folders(from: defaultsProvider())
        let paths = try BrowserIntentEntityStorage.folderPaths(from: defaultsProvider())
        return folders
            .prefix(BrowserIntentEntityStorage.maximumEntities)
            .map { BrowserFolderEntity(id: $0.id.uuidString, title: String((paths[$0.id] ?? $0.title).prefix(320))) }
    }

    func entities(matching string: String) async throws -> [BrowserFolderEntity] {
        let folders = try BrowserIntentEntityStorage.folders(from: defaultsProvider())
        let paths = try BrowserIntentEntityStorage.folderPaths(from: defaultsProvider())
        return folders
            .filter {
                $0.title.localizedCaseInsensitiveContains(string)
                    || (paths[$0.id]?.localizedCaseInsensitiveContains(string) ?? false)
            }
            .prefix(BrowserIntentEntityStorage.maximumEntities)
            .map { BrowserFolderEntity(id: $0.id.uuidString, title: String((paths[$0.id] ?? $0.title).prefix(320))) }
    }
}

enum BrowserIntentWebProvider: String, AppEnum {
    case chatgpt
    case gemini

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Web AI"

    static let caseDisplayRepresentations: [BrowserIntentWebProvider: DisplayRepresentation] = [
        .chatgpt: "ChatGPT",
        .gemini: "Gemini"
    ]

    var webAIProvider: WebAIProvider {
        switch self {
        case .chatgpt: return .chatgpt
        case .gemini: return .gemini
        }
    }
}
