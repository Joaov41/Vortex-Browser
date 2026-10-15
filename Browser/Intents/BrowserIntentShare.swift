import Foundation
import UniformTypeIdentifiers

enum BrowserShareURLParseError: LocalizedError, Equatable {
    case malformedSearchURL
    case unknownParameter(String)
    case duplicateParameter(String)
    case missingText
    case invalidText

    var errorDescription: String? {
        switch self {
        case .malformedSearchURL:
            return "The Vortyra search link is malformed."
        case .unknownParameter(let name):
            return "The Vortyra search link has an unsupported parameter: \(name)."
        case .duplicateParameter(let name):
            return "The Vortyra search link repeats the parameter: \(name)."
        case .missingText:
            return "The Vortyra search link has no search text."
        case .invalidText:
            return "The Vortyra search link text is empty or too long."
        }
    }
}

enum BrowserIntentShareParser {
    static let scheme = "webmebrowser"
    static let searchHost = "search"
    static let maximumTextUTF8Bytes = 4_096

    static func isValidSearchText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= maximumTextUTF8Bytes
    }

    static func parseSearchText(from url: URL) throws -> String? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard url.host?.lowercased() == searchHost else { return nil }
        guard url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw BrowserShareURLParseError.malformedSearchURL
        }
        var text: String?
        for item in components.queryItems ?? [] {
            guard item.name == "text" else {
                throw BrowserShareURLParseError.unknownParameter(item.name)
            }
            guard text == nil else {
                throw BrowserShareURLParseError.duplicateParameter(item.name)
            }
            guard let value = item.value else {
                throw BrowserShareURLParseError.malformedSearchURL
            }
            text = value
        }
        guard let rawText = text else {
            throw BrowserShareURLParseError.missingText
        }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSearchText(trimmed) else {
            throw BrowserShareURLParseError.invalidText
        }
        return trimmed
    }
}

enum BrowserSharePayload {
    static let sharedURLKey = "sharedURL"
    static let sharedSearchTextKey = "sharedSearchText"

    enum Action: Equatable {
        case search
        case openLink
    }

    static func isExplicitWebURL(_ text: String) -> Bool {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return false }
        return true
    }

    static func actions(for text: String) -> [Action] {
        isExplicitWebURL(text) ? [.openLink, .search] : [.search]
    }

    static func writeSearchText(_ text: String, to defaults: UserDefaults) throws {
        guard BrowserIntentShareParser.isValidSearchText(text) else {
            throw BrowserShareURLParseError.invalidText
        }
        defaults.set(text, forKey: sharedSearchTextKey)
        defaults.removeObject(forKey: sharedURLKey)
        defaults.synchronize()
    }

    static func writeSearchTextIfAllowed(
        _ text: String,
        to defaults: UserDefaults,
        gate: BrowserShareDeliveryGate
    ) throws -> Bool {
        guard gate.acceptsCallbacks else { return false }
        try writeSearchText(text, to: defaults)
        return true
    }

    static func writeSharedURL(_ content: String, to defaults: UserDefaults) {
        defaults.set(content, forKey: sharedURLKey)
        defaults.removeObject(forKey: sharedSearchTextKey)
        defaults.synchronize()
    }
}

enum BrowserShareProviderPicker {
    struct Descriptor: Equatable {
        let index: Int
        let typeIdentifiers: Set<String>

        var isStandaloneText: Bool {
            let textIDs: Set<String> = [UTType.plainText.identifier, UTType.text.identifier]
            return !typeIdentifiers.isDisjoint(with: textIDs)
                && !typeIdentifiers.contains(UTType.url.identifier)
        }
    }

    enum Selection: Equatable {
        case textProvider(Int)
        case urlProvider(Int)
        case legacy(Int, String)
        case none
    }

    static func select(_ descriptors: [Descriptor]) -> Selection {
        for descriptor in descriptors where descriptor.isStandaloneText {
            return .textProvider(descriptor.index)
        }
        for descriptor in descriptors where descriptor.typeIdentifiers.contains(UTType.url.identifier) {
            return .urlProvider(descriptor.index)
        }
        for typeID in [UTType.url.identifier, UTType.plainText.identifier, UTType.text.identifier] {
            for descriptor in descriptors where descriptor.typeIdentifiers.contains(typeID) {
                return .legacy(descriptor.index, typeID)
            }
        }
        return .none
    }
}

final class BrowserShareDeliveryGate {
    private(set) var hasCompleted = false
    private(set) var hasFinishedRequest = false

    var acceptsCallbacks: Bool {
        !hasCompleted && !hasFinishedRequest
    }

    func markCompleted() {
        hasCompleted = true
    }

    func markRequestFinished() {
        hasFinishedRequest = true
    }
}
