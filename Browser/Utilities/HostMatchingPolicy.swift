import Foundation

nonisolated enum HostMatchingPolicy {
    static func matches(_ rawHost: String?, any domains: [String]) -> Bool {
        guard let host = normalized(rawHost) else { return false }
        return domains.contains { rawDomain in
            guard let domain = normalized(rawDomain) else { return false }
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }
}
