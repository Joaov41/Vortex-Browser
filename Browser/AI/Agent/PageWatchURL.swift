import Foundation

enum PageWatchURLParseError: Error, Equatable, LocalizedError {
    case malformedWatchURL

    var errorDescription: String? {
        switch self {
        case .malformedWatchURL: return "The page watch link is malformed."
        }
    }
}

/// Parses `webmebrowser://watch?id=<UUID>`, the link that opens one page watch in the library.
/// Exactly one `id` query item holding a UUID is accepted; any other shape is rejected.
enum PageWatchURLParser {
    static let host = "watch"
    static let idParameter = "id"
    static let missingWatchMessage = "That page watch no longer exists."

    /// Returns nil for every URL whose host is not `watch`. Throws for a `watch` link that is not exactly one valid UUID `id`.
    static func parse(_ url: URL) throws -> UUID? {
        guard url.scheme?.lowercased() == AgentIncomingURLRouter.appScheme,
              url.host?.lowercased() == host else { return nil }
        guard url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              (components.percentEncodedQuery ?? "").components(separatedBy: "&").count == 1,
              let items = components.queryItems,
              items.count == 1,
              items[0].name == idParameter,
              let value = items[0].value,
              let watchID = UUID(uuidString: value) else {
            throw PageWatchURLParseError.malformedWatchURL
        }
        return watchID
    }

    /// The canonical link for a watch. Used as the notification tap target.
    static func url(for watchID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = AgentIncomingURLRouter.appScheme
        components.host = host
        components.queryItems = [URLQueryItem(name: idParameter, value: watchID.uuidString)]
        return components.url
    }
}
