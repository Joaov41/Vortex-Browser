// AIAssistantProvider.swift
// Unified protocol for AI features with Apple Intelligence local and cloud (via Shortcuts)

import Foundation
#if os(iOS)
import UIKit
#endif

public struct PageContext: Sendable {
    public let url: String?
    public let title: String?
    public let selection: String?
    public let summary: String?
    
    public init(url: String? = nil, title: String? = nil, selection: String? = nil, summary: String? = nil) {
        self.url = url
        self.title = title
        self.selection = selection
        self.summary = summary
    }
}

public protocol AIAssistantProvider {
    func respond(to prompt: String, context: PageContext?) async throws -> String
}

// Simple selector to choose local vs cloud
public enum AIBackend {
    case appleIntelligenceLocal
    case appleIntelligenceCloudShortcut(name: String) // Shortcut name to invoke
}

public final class AIAgent: @unchecked Sendable {
    private let provider: AIAssistantProvider
    
    public init(backend: AIBackend) {
        switch backend {
        case .appleIntelligenceLocal:
            self.provider = AppleIntelligenceLocalProvider()
        case .appleIntelligenceCloudShortcut(let name):
            self.provider = AppleIntelligenceCloudShortcutProvider(shortcutName: name)
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

// Placeholder implementation. You can replace internals with official Apple Intelligence APIs when available.
public struct AppleIntelligenceLocalProvider: AIAssistantProvider {
    public init() {}
    
    public func respond(to prompt: String, context: PageContext?) async throws -> String {
        // Minimal local behavior for now; replace with Apple Intelligence API calls.
        var contextSnippet = ""
        if let context {
            let url = context.url ?? "unknown"
            let title = context.title ?? "Untitled"
            contextSnippet = " [Page: \(title) - \(url)]"
        }
        // Simulate async local generation
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        return "Local AI (Apple Intelligence) response to: \"\(prompt)\"\(contextSnippet)"
    }
}

// MARK: - Apple Intelligence Cloud via Shortcuts

// Invokes a user-configured Shortcut by name, passing prompt/context via x-callback-url.
// The Shortcut should return text in its clipboard or through a custom URL scheme; we model clipboard approach for simplicity.
public struct AppleIntelligenceCloudShortcutProvider: AIAssistantProvider {
    public enum ShortcutError: Error {
        case cannotInvokeShortcut
        case timedOut
        case failed(String)
    }
    
    private let shortcutName: String
    private let timeoutSeconds: TimeInterval
    
    public init(shortcutName: String, timeoutSeconds: TimeInterval = 20) {
        self.shortcutName = shortcutName
        self.timeoutSeconds = timeoutSeconds
    }
    
    public func respond(to prompt: String, context: PageContext?) async throws -> String {
        // Encode parameters into the shortcut URL
        var params: [String: String] = ["prompt": prompt]
        if let context {
            if let url = context.url { params["url"] = url }
            if let title = context.title { params["title"] = title }
            if let selection = context.selection { params["selection"] = selection }
            if let summary = context.summary { params["summary"] = summary }
        }
        let encodedParams = params
            .compactMap { key, value in
                guard let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        
        let shortcutURLString = "shortcuts://run-shortcut?name=\(shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&\(encodedParams)"
        
        guard let shortcutURL = URL(string: shortcutURLString) else {
            throw ShortcutError.cannotInvokeShortcut
        }
        
        // Attempt to open the Shortcut. On iOS, this will background the app and run the Shortcut.
        // The Shortcut should copy its result to the clipboard, or use x-callback-url back to the app.
        #if os(iOS)
        await openURL(shortcutURL)
        // Poll clipboard for a limited time window to retrieve the result.
        let result = try await pollClipboardForResult(timeout: timeoutSeconds)
        return result
        #else
        throw ShortcutError.failed("Shortcuts integration is iOS-only")
        #endif
    }
    
    #if os(iOS)
    // MARK: - iOS helpers
    private func openURL(_ url: URL) async {
        await MainActor.run {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
    
    private func pollClipboardForResult(timeout: TimeInterval) async throws -> String {
        let start = Date()
        var lastValue = UIPasteboard.general.string ?? ""
        
        // The Shortcut should update the clipboard with the final response.
        while Date().timeIntervalSince(start) < timeout {
            try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            let current = UIPasteboard.general.string ?? ""
            let trimmed = current.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if current != lastValue, !trimmed.isEmpty {
                return current
            }
            lastValue = current
        }
        throw ShortcutError.timedOut
    }
    #endif
}

