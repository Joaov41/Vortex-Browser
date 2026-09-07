import Foundation
import CryptoKit
import Darwin

/// Small, explicit cross-site supplement for endpoints not covered by the enabled
/// ABP subset. Some are advertiser tools, not ad payload servers: permit use from
/// their own services and never block a document navigation. Shared with JS so a
/// native cache miss does not silently lose this coverage. No test-site checks.
nonisolated enum SupplementalAdResourceRules {
    struct Entry: Codable, Sendable {
        let host: String
        let firstPartySites: [String]
    }
    static let entries: [Entry] = [
        Entry(host: "ads.google.com", firstPartySites: ["google.com", "youtube.com"]),
        Entry(host: "analyticsengine.s3.amazonaws.com", firstPartySites: ["amazonaws.com", "amazon.com"]),
        Entry(host: "affiliationjs.s3.amazonaws.com", firstPartySites: ["amazonaws.com", "amazon.com"]),
        Entry(host: "advertising-api-eu.amazon.com", firstPartySites: ["amazon.com"]),
        Entry(host: "ads.facebook.com", firstPartySites: ["facebook.com", "facebook.net", "instagram.com"]),
        Entry(host: "ads.reddit.com", firstPartySites: ["reddit.com", "redditmedia.com", "redditstatic.com"]),
        Entry(host: "d.reddit.com", firstPartySites: ["reddit.com", "redditmedia.com", "redditstatic.com"]),
        Entry(host: "ads.pinterest.com", firstPartySites: ["pinterest.com"]),
        Entry(host: "ads-dev.pinterest.com", firstPartySites: ["pinterest.com"]),
        Entry(host: "ads.youtube.com", firstPartySites: ["youtube.com", "google.com"]),
        Entry(host: "ads-api.twitter.com", firstPartySites: ["twitter.com", "x.com", "twimg.com", "t.co"]),
        Entry(host: "advertising.twitter.com", firstPartySites: ["twitter.com", "x.com", "twimg.com", "t.co"])
    ]

    static func entries(forMajorVersion majorVersion: Int) -> [Entry] {
        majorVersion == 27 ? entries : []
    }
}

/// A bounded companion to the full JavaScript index, not the legacy native converter.
nonisolated enum NativeAdResourceRules {
    static let domainLimit = 20_000
    static let patternLimit = 2_000
    static let byteLimit = 8_000_000
    static let identifier = "vortex-native-resources-v1"
    static let essentialHosts = ["microsoft.com", "microsoftonline.com", "office.com", "office365.com", "live.com", "outlook.com", "apple.com", "icloud.com", "chatgpt.com", "chat.openai.com", "openai.com", "gemini.google.com", "bard.google.com"]
    static let socialGroups = [["x.com", "twitter.com", "twimg.com", "t.co"], ["reddit.com", "redditmedia.com", "redditstatic.com"]]
    static let resourceTypes = ["script", "image", "style-sheet", "font", "media", "raw"]

    struct Snapshot: Sendable {
        let json: String
        let identity: String
        let blocks: Int
        let omitted: Int
    }
    enum BuildError: Error { case unsupportedException, safetyBudget }

    // Enable only after the isolated full-ruleset probe passes on this pair.
    static func supports(majorVersion: Int, osBuild: String, sdkBuild: String?) -> Bool {
        majorVersion == 27 && osBuild == "24A5430a" && sdkBuild == "24A5380g"
    }
    static var isSupported: Bool {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return false }
        return supports(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                        osBuild: String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? "",
                        sdkBuild: Bundle.main.object(forInfoDictionaryKey: "DTSDKBuild") as? String)
    }

    static func hostPattern(_ host: String, allowingUserInfo: Bool = false) -> String {
        // Keep wildcard userinfo out of the large block set: authenticated URLs may
        // fall through to JS, but allows must still cover their actual destination.
        "^https?://" + (allowingUserInfo ? "([^/?#]*@)?" : "")
            + "([^/:?#@]+\\.)?" + NSRegularExpression.escapedPattern(for: host) + "(:[0-9]+)?/"
    }

    /// WebKit rejects disjunctions, including the JavaScript separator's `|$`.
    /// Expand a terminal separator into two rules; skip other unsupported shapes.
    static func patterns(_ input: String) -> [String]? {
        guard input.utf8.count <= 2_048, input.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let value = input.replacingOccurrences(of: "^(?:https?|wss?)://", with: "^https?://")
        let separator = "([^a-zA-Z0-9_.%-]|$)"
        let result: [String]
        if value.hasSuffix(separator) {
            let head = String(value.dropLast(separator.count))
            result = [head + "[^a-zA-Z0-9_.%-]", head + "$"]
        } else { result = [value] }
        guard result.allSatisfy({ !$0.contains("|") && !$0.contains("(?") }) else { return nil }
        return result
    }

    /// Preserve a request exception's URL, not just its host. An interior ABP
    /// separator cannot take its end-of-string branch when a literal follows it.
    static func exceptionFilters(_ rule: IndexedAdBlockRules.Rule) -> [String]? {
        if rule.p.isEmpty { return [hostPattern(rule.h, allowingUserInfo: true)] }
        let separator = "([^a-zA-Z0-9_.%-]|$)"
        var value = rule.p
        while let range = value.range(of: separator), range.upperBound != value.endIndex {
            let tail = String(value[range.upperBound...])
            let required = tail.replacingOccurrences(of: separator, with: "")
                .replacingOccurrences(of: ".*", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "$"))
            // Nullable suffixes need a richer expansion. Keep the existing safe
            // host fallback for this uncommon shape, with all other conditions.
            guard !required.isEmpty else { return nil }
            value.replaceSubrange(range, with: "[^a-zA-Z0-9_.%-]")
        }
        return patterns(value)
    }

    static func exceptionRules(_ rule: IndexedAdBlockRules.Rule) throws -> [[String: Any]] {
        // The JS matcher evaluates document exceptions with thirdParty=false.
        if rule.d && rule.f == 1 { return [] }
        let filters: [String]
        if let exact = exceptionFilters(rule) { filters = exact }
        else if !rule.h.isEmpty { filters = [hostPattern(rule.h, allowingUserInfo: true)] }
        else { throw BuildError.unsupportedException }

        var included = rule.i
        let excluded = rule.x
        func within(_ host: String, _ domain: String) -> Bool {
            host == domain || host.hasSuffix("." + domain)
        }
        if !rule.d, rule.f == 2, !rule.h.isEmpty {
            // JS uses the final two labels for same-site, not WebKit's stricter
            // first-party load type. Preserve that allowance across subdomains.
            let site = rule.h.split(separator: ".").suffix(2).joined(separator: ".")
            if included.isEmpty { included = [site] }
            else {
                included = included.compactMap { within($0, site) ? $0 : (within(site, $0) ? site : nil) }
                if included.isEmpty { return [] }
            }
        }
        let scopeFilters = included.map { hostPattern($0, allowingUserInfo: true) }
        let exclusions = excluded.map { hostPattern($0, allowingUserInfo: true) }
        // This WebKit build permits only one source-URL condition per trigger,
        // including across top/frame keys. Fall back to JS rather than discard a
        // condition and silently widen an exception.
        guard scopeFilters.isEmpty || exclusions.isEmpty else { throw BuildError.unsupportedException }
        guard !rule.d || (scopeFilters.isEmpty && exclusions.isEmpty) else { throw BuildError.unsupportedException }
        let masks: [(Int, [String])] = [(1,["raw","fetch"]), (2,["script"]), (4,["image"]),
            (8,["style-sheet"]), (16,["font"]), (32,["media"]), (64,["websocket"]),
            (128,["ping"]), (256,["document"]), (512,["other"])]
        let types = masks.filter { (rule.t == 0 || rule.t & $0.0 != 0) && rule.n & $0.0 == 0 }.flatMap(\.1)
        if types.isEmpty { return [] }
        var result: [[String: Any]] = []
        for filter in filters {
            var trigger: [String: Any] = ["url-filter": rule.d ? ".*" : filter,
                "load-context": ["top-frame"], "url-filter-is-case-sensitive": rule.c]
            if rule.t != 0 || rule.n != 0 { trigger["resource-type"] = types }
            if !rule.d && rule.f == 1 { trigger["load-type"] = ["third-party"] }
            // For hostless first-party exceptions we cannot derive a source site;
            // retain the URL/type/domain conditions and conservatively allow both parties.
            if rule.d {
                trigger["if-top-url"] = [filter]
            } else {
                if !scopeFilters.isEmpty { trigger["if-top-url"] = scopeFilters }
                if !exclusions.isEmpty { trigger["unless-top-url"] = exclusions }
            }
            result.append(["trigger": trigger, "action": ["type": "ignore-previous-rules"]])
        }
        return result
    }

    static func make(indexJSON: String, preferredHosts: [String]) throws -> Snapshot {
        let payload = try JSONDecoder().decode(IndexedAdBlockRules.Payload.self, from: Data(indexJSON.utf8))
        var rules: [[String: Any]] = []
        var domains = Set<String>()
        let available = payload.domains.split(separator: "\n").map(String.init)
        let availableSet = Set(available)
        // Prioritize common, already-indexed destinations. Never manufacture a block
        // solely because a test expects one, or revive a disabled downloaded list.
        for host in preferredHosts where availableSet.contains(host) && domains.count < domainLimit { domains.insert(host) }
        // Deterministic sampling distributes the bounded native budget across the index.
        let capacity = domainLimit - domains.count
        let remaining = available.filter { !domains.contains($0) }
        if capacity > 0 {
            let count = min(capacity, remaining.count)
            for i in 0..<count { domains.insert(remaining[i * remaining.count / count]) }
        }
        // Keep the original sample stable. Reserve only the small supplement's
        // slots, evicting non-priority domains from the native layer (not JS).
        // Seeding the sampler with the supplement would reshuffle most of it.
        let supplement = SupplementalAdResourceRules.entries
        let indexedCapacity = domainLimit - supplement.count
        guard indexedCapacity >= 0 else { throw BuildError.safetyBudget }
        if domains.count > indexedCapacity {
            let preferred = Set(preferredHosts)
            let removable = domains.sorted {
                if preferred.contains($0) != preferred.contains($1) { return !preferred.contains($0) }
                return $0 > $1
            }
            for host in removable.prefix(domains.count - indexedCapacity) { domains.remove(host) }
        }
        for host in domains.sorted() {
            rules.append(["trigger": ["url-filter": hostPattern(host), "load-type": ["third-party"], "load-context": ["top-frame"], "resource-type": resourceTypes], "action": ["type": "block"]])
        }
        let all = payload.hosts.keys.sorted().flatMap { payload.hosts[$0] ?? [] } + payload.generic
        var omitted = available.count - domains.count
        var patternCount = 0
        let maskTypes = [(1,"raw"), (2,"script"), (4,"image"), (8,"style-sheet"), (16,"font"), (32,"media")]
        for rule in all where !rule.a {
            if !rule.h.isEmpty, !rule.p.isEmpty {
                let hostPathPrefix = "^(?:https?|wss?)://([^/:]+\\.)?" + NSRegularExpression.escapedPattern(for: rule.h + "/")
                // A slash after the host cannot be confused with a username followed by @.
                guard rule.p.lowercased().hasPrefix(hostPathPrefix.lowercased()) else { omitted += 1; continue }
            }
            // Frame vs top-page domain scoping differs; leave those blocks to JS.
            guard rule.i.isEmpty, rule.x.isEmpty,
                  let filters = rule.p.isEmpty ? [hostPattern(rule.h)] : patterns(rule.p),
                  patternCount + filters.count <= patternLimit else { omitted += 1; continue }
            let types = maskTypes.filter { (rule.t == 0 || rule.t & $0.0 != 0) && rule.n & $0.0 == 0 }.map(\.1)
            guard !types.isEmpty else { omitted += 1; continue }
            for filter in filters {
                var trigger: [String: Any] = ["url-filter": filter, "resource-type": types, "load-context": ["top-frame"], "url-filter-is-case-sensitive": rule.c]
                if rule.f != 0 { trigger["load-type"] = [rule.f == 1 ? "third-party" : "first-party"] }
                rules.append(["trigger": trigger, "action": ["type": "block"]])
                patternCount += 1
            }
        }
        for entry in supplement {
            rules.append(["trigger": ["url-filter": hostPattern(entry.host),
                "load-type": ["third-party"], "load-context": ["top-frame"],
                "resource-type": resourceTypes + ["fetch"],
                "unless-top-url": entry.firstPartySites.map { hostPattern($0, allowingUserInfo: true) }],
                "action": ["type": "block"]])
        }
        let blocks = rules.count
        // Keep exception paths, resource types and source-site conditions. A narrow
        // exception must not cancel every native block beneath its destination host.
        for rule in all.filter(\.a) + payload.documentExceptions {
            rules.append(contentsOf: try exceptionRules(rule))
        }
        for host in essentialHosts {
            rules.append(["trigger": ["url-filter": hostPattern(host, allowingUserInfo: true)], "action": ["type": "ignore-previous-rules"]])
        }
        for group in socialGroups {
            for host in group {
                rules.append(["trigger": ["url-filter": hostPattern(host, allowingUserInfo: true), "if-top-url": group.map { hostPattern($0, allowingUserInfo: true) }], "action": ["type": "ignore-previous-rules"]])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        guard data.count <= byteLimit, rules.count <= 30_000 else { throw BuildError.safetyBudget }
        return Snapshot(json: String(decoding: data, as: UTF8.self),
                        identity: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                        blocks: blocks, omitted: omitted)
    }
}
