// AIAssistantProvider.swift
// Compatibility protocol for the Apple Intelligence local fallback.

import Foundation

public struct PageContext: Sendable {
    public let url: String?
    public let title: String?
    public let selection: String?
    public let summary: String?

    public init(
        url: String? = nil,
        title: String? = nil,
        selection: String? = nil,
        summary: String? = nil
    ) {
        self.url = url
        self.title = title
        self.selection = selection
        self.summary = summary
    }
}

public protocol AIAssistantProvider {
    func respond(to prompt: String, context: PageContext?) async throws -> String
}

// Compatibility selector retained for older local-generation call sites.
public enum AIBackend {
    case appleIntelligenceLocal
}

public final class AIAgent: @unchecked Sendable {
    private let provider: AIAssistantProvider

    public init(backend: AIBackend) {
        switch backend {
        case .appleIntelligenceLocal:
            self.provider = AppleIntelligenceLocalProvider()
        }
    }

    public func ask(_ prompt: String, context: PageContext? = nil) async -> String {
        do {
            return try await provider.respond(to: prompt, context: context)
        } catch {
            return "AI error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Apple Intelligence Local

// This provider is compiled only as a compatibility fallback when the direct
// Foundation Models implementation is unavailable. It must never fabricate an
// AI response that could be mistaken for model output.
public struct AppleIntelligenceLocalProvider: AIAssistantProvider {
    public init() {}

    public func respond(to _: String, context _: PageContext?) async throws -> String {
        throw NSError(
            domain: "Browser.AppleIntelligenceLocal",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Apple Intelligence local generation is unavailable in this build."
            ]
        )
    }
}
