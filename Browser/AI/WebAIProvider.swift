import Foundation

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
}

enum WebAIMessagePolicy {
    static func allows(provider: WebAIProvider, url: URL?, isMainFrame: Bool) -> Bool {
        guard isMainFrame, let url else { return false }
        return provider.matches(url)
    }
}
