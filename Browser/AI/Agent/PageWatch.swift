import Foundation

/// How often a page watch becomes due. Pure values only: the widget extension
/// (Phase 8) compiles this file, so it must not reference app-only types.
nonisolated enum PageWatchInterval: String, Codable, CaseIterable, Equatable, Sendable {
    case hourly
    case every6Hours
    case daily
    case weekly

    var seconds: TimeInterval {
        switch self {
        case .hourly: return 3_600
        case .every6Hours: return 6 * 3_600
        case .daily: return 24 * 3_600
        case .weekly: return 7 * 24 * 3_600
        }
    }

    var title: String {
        switch self {
        case .hourly: return "Every hour"
        case .every6Hours: return "Every 6 hours"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }
}

/// What a watch compares between checks. Text watches read a page; agent watches re-run a saved task.
nonisolated enum PageWatchMode: Codable, Equatable, Sendable {
    case text(selector: String?)
    case agent(savedTaskID: UUID)

    var isText: Bool {
        if case .text = self { return true }
        return false
    }

    var selector: String? {
        if case .text(let selector) = self { return selector }
        return nil
    }

    var savedTaskID: UUID? {
        if case .agent(let id) = self { return id }
        return nil
    }
}

/// Where the value that was hashed came from. A watch re-baselines silently when its source changes,
/// so a foreground read and a background read are never compared with each other.
nonisolated enum PageWatchValueSource: String, Codable, Equatable, Sendable {
    case browserText
    case urlSessionText
    case agentRun
}

nonisolated struct PageWatch: Codable, Equatable, Identifiable, Sendable {
    static let maximumWatches = 20
    static let maximumTitleCharacters = 160
    static let maximumURLCharacters = 4_096
    static let maximumSelectorCharacters = 500
    static let maximumPreviewCharacters = 500
    static let maximumErrorCharacters = 500
    static let hashLength = 64

    var id: UUID
    var title: String
    var url: URL
    var mode: PageWatchMode
    var interval: PageWatchInterval
    var notify: Bool
    var createdAt: Date
    var lastCheckedAt: Date?
    var lastValueHash: String?
    var lastValuePreview: String?
    var lastChangeAt: Date?
    var lastError: String?
    /// Optional so documents written before this field existed still decode. Nil means no baseline yet.
    var lastValueSource: PageWatchValueSource?

    init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        mode: PageWatchMode,
        interval: PageWatchInterval,
        notify: Bool = true,
        createdAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        lastValueHash: String? = nil,
        lastValuePreview: String? = nil,
        lastChangeAt: Date? = nil,
        lastError: String? = nil,
        lastValueSource: PageWatchValueSource? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.mode = mode
        self.interval = interval
        self.notify = notify
        self.createdAt = createdAt
        self.lastCheckedAt = lastCheckedAt
        self.lastValueHash = lastValueHash
        self.lastValuePreview = lastValuePreview
        self.lastChangeAt = lastChangeAt
        self.lastError = lastError
        self.lastValueSource = lastValueSource
    }

    /// A watch that has never been checked is due at creation time.
    var nextDueDate: Date {
        lastCheckedAt.map { $0.addingTimeInterval(interval.seconds) } ?? createdAt
    }

    func isDue(now: Date) -> Bool {
        nextDueDate <= now
    }

    /// Background refresh only reads text watches without a selector. A selector is applied in the foreground
    /// loader only, so a background read of the whole page would not match the stored baseline.
    var isBackgroundEligible: Bool {
        mode.isText && mode.selector == nil
    }

    var isValid: Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              title.count <= Self.maximumTitleCharacters,
              title.utf8.count <= Self.maximumTitleCharacters * 4,
              Self.isWebURL(url),
              createdAt.timeIntervalSince1970.isFinite,
              lastCheckedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              lastChangeAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              lastValuePreview.map({ $0.count <= Self.maximumPreviewCharacters }) ?? true,
              lastError.map({ $0.count <= Self.maximumErrorCharacters }) ?? true,
              lastValueHash.map(Self.isHash) ?? true else {
            return false
        }
        switch mode {
        case .text(let selector):
            guard selector.map({ $0.count <= Self.maximumSelectorCharacters }) ?? true else { return false }
        case .agent:
            break
        }
        return true
    }

    /// Only plain HTTP and HTTPS addresses with a host and no embedded credentials.
    static func isWebURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              url.absoluteString.count <= maximumURLCharacters else { return false }
        return true
    }

    /// Trims a CSS selector and treats blank input as no selector.
    static func normalizedSelector(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func isHash(_ value: String) -> Bool {
        value.count == hashLength && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
