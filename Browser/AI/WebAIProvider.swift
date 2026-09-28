import Foundation
import WebKit

enum WebAIProvider: String, CaseIterable {
    case chatgpt
    case gemini

    var displayName: String {
        switch self {
        case .chatgpt:
            return "ChatGPT"
        case .gemini:
            return "Gemini"
        }
    }

    var url: URL {
        switch self {
        case .chatgpt:
            return URL(string: "https://chatgpt.com")!
        case .gemini:
            return URL(string: "https://gemini.google.com/app")!
        }
    }

    var hostMatches: [String] {
        switch self {
        case .chatgpt:
            return ["chatgpt.com", "chat.openai.com"]
        case .gemini:
            return ["gemini.google.com"]
        }
    }

    var sessionHostMatches: [String] {
        switch self {
        case .chatgpt:
            return ["chatgpt.com", "openai.com"]
        case .gemini:
            return ["gemini.google.com", "google.com"]
        }
    }

    func matches(_ url: URL?) -> Bool {
        HostMatchingPolicy.matches(url?.host, any: hostMatches)
    }

    func allowsSessionNavigation(_ url: URL?) -> Bool {
        matchesSessionHost(url?.host)
    }

    func matchesSessionHost(_ host: String?) -> Bool {
        HostMatchingPolicy.matches(host, any: sessionHostMatches)
    }

    /// Fixed identifier for this provider's persistent website data store.
    /// Changing it discards every existing sign-in for the provider.
    var sessionStoreIdentifier: UUID {
        switch self {
        case .chatgpt:
            return UUID(uuidString: "5C1B3F0E-7A61-4C1E-9F2D-2B7C6A1D0E01")!
        case .gemini:
            return UUID(uuidString: "5C1B3F0E-7A61-4C1E-9F2D-2B7C6A1D0E02")!
        }
    }
}

/// Each web AI provider keeps its sign-in in its own persistent store, isolated
/// from normal browsing. Gemini's session cookies live on `.google.com`, so with a
/// shared store signing out of Gemini would also sign the user out of Google in
/// regular tabs.
@MainActor
enum WebAISessionStore {
    private static var stores: [WebAIProvider: WKWebsiteDataStore] = [:]

    static func dataStore(for provider: WebAIProvider) -> WKWebsiteDataStore {
        if let store = stores[provider] {
            return store
        }
        let store = WKWebsiteDataStore(forIdentifier: provider.sessionStoreIdentifier)
        stores[provider] = store
        return store
    }

    /// Removes everything the provider's chat page stored. Normal tabs are unaffected.
    static func signOut(of provider: WebAIProvider) async {
        await dataStore(for: provider).removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
    }
}

enum WebAIMessagePolicy {
    static func allows(provider: WebAIProvider, url: URL?, isMainFrame: Bool) -> Bool {
        guard isMainFrame, let url else { return false }
        return provider.matches(url)
    }
}
