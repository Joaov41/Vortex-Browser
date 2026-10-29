import Foundation
import Combine

/// Remembers only narrowly eligible, user-approved browser-agent actions on an exact host.
/// Private runs deliberately neither read nor write these permissions.
@MainActor
final class AgentTrustStore: ObservableObject {
    struct Permission: Codable, Equatable, Identifiable {
        var id: String { host + "|" + reason }
        let host: String
        let reason: String
    }

    static let shared = AgentTrustStore()

    private let defaults: UserDefaults
    private let storageKey: String
    @Published private(set) var permissions: [Permission]

    init(defaults: UserDefaults = .standard, storageKey: String = "browser_agent_site_permissions_v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([Permission].self, from: data) {
            permissions = saved.sorted { ($0.host, $0.reason) < ($1.host, $1.reason) }
        } else {
            permissions = []
        }
    }

    static func canonicalHost(_ rawHost: String) -> String? {
        let candidate = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty, !candidate.hasPrefix("."), !candidate.contains("/") else { return nil }
        let host = candidate.hasSuffix(".") ? String(candidate.dropLast()) : candidate
        guard !host.isEmpty, !host.hasSuffix("."), !host.contains("..") else { return nil }
        // URL's host parser applies the platform's canonical host handling without
        // broadening www or subdomain matches.
        guard let components = URLComponents(string: "https://\(host)"),
              components.host?.lowercased() == host else { return nil }
        return host
    }

    static func normalizedReason(_ rawReason: String) -> String {
        rawReason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    static func isAlwaysAllowEligible(
        reason rawReason: String,
        operation rawOperation: String,
        protectedContext: Bool,
        isPrivate: Bool
    ) -> Bool {
        guard !isPrivate, !protectedContext else { return false }
        let reason = normalizedReason(rawReason)
        let operation = normalizedReason(rawOperation).replacingOccurrences(of: " ", with: "_")
        let blockedOperations: Set<String> = [
            "close_tab", "fill_form", "download", "download_url", "download_link", "downloads",
            "delete", "remove", "purchase", "buy", "pay", "checkout", "order", "transfer"
        ]
        guard !blockedOperations.contains(operation) else { return false }

        let words = Set(reason.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let excludedWords: Set<String> = [
            "buy", "purchase", "pay", "payment", "checkout", "order", "transfer", "delete", "remove",
            "sign-in", "signin", "login", "password", "sensitive", "credential", "download", "close_tab", "fill_form"
        ]
        guard words.isDisjoint(with: excludedWords),
              !reason.contains("sign-in"), !reason.contains("sign in"), !reason.contains("log in") else { return false }

        let eligibleReasons: Set<String> = [
            "post", "publish", "tweet", "reply", "comment", "form submission", "hide page element"
        ]
        return eligibleReasons.contains(reason)
    }

    func allows(
        host rawHost: String,
        reason rawReason: String,
        operation: String,
        protectedContext: Bool,
        isPrivate: Bool
    ) -> Bool {
        guard Self.isAlwaysAllowEligible(
            reason: rawReason,
            operation: operation,
            protectedContext: protectedContext,
            isPrivate: isPrivate
        ), let host = Self.canonicalHost(rawHost) else { return false }
        let reason = Self.normalizedReason(rawReason)
        return permissions.contains { $0.host == host && $0.reason == reason }
    }

    @discardableResult
    func allow(
        host rawHost: String,
        reason rawReason: String,
        operation: String,
        protectedContext: Bool,
        isPrivate: Bool
    ) -> Bool {
        guard Self.isAlwaysAllowEligible(
            reason: rawReason,
            operation: operation,
            protectedContext: protectedContext,
            isPrivate: isPrivate
        ), let host = Self.canonicalHost(rawHost) else { return false }
        let permission = Permission(host: host, reason: Self.normalizedReason(rawReason))
        guard !permissions.contains(permission) else { return true }
        permissions.append(permission)
        permissions.sort { ($0.host, $0.reason) < ($1.host, $1.reason) }
        persist()
        return true
    }

    func revoke(_ permission: Permission) {
        permissions.removeAll { $0 == permission }
        persist()
    }

    func revokeAll() {
        permissions.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(permissions) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
