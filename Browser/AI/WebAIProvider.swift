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

    func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return hostMatches.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    }
}
