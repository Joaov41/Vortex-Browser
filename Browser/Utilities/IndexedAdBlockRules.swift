import Foundation
import CryptoKit

/// A deliberately bounded ABP subset. Unsupported options are rejected, never treated as URL text.
/// Domain-only rules remain third-party, preserving Vortex's existing first-party safety policy.
nonisolated enum IndexedAdBlockRules {
    static let schema = 1
    static let domainLimit = 100_000
    static let scopedLimit = 12_000
    static let genericLimit = 1_000
    static let exceptionLimit = 5_000
    static let cacheByteLimit = 12_000_000

    /// The JavaScript/native index normally preserves the legacy party policy.
    /// iOS 27 has a separately validated correction for URL/path- and
    /// source-scoped rules whose party modifier was implicit. Host-only rules
    /// intentionally remain third-party-only in both policies.
    enum Policy: String, Sendable {
        case legacy
        case ios27Scripts
    }

    struct Rule: Codable, Hashable, Sendable {
        var h = "" // destination host, empty for unscoped patterns
        var p = "" // regex, empty for host-only rules
        var i: [String] = [] // included document domains
        var x: [String] = [] // excluded document domains
        var t = 0 // included resource mask (zero means all)
        var n = 0 // excluded resource mask
        var f = 1 // 1 third-party, 2 first-party, 0 either
        var a = false // exception
        var c = false // case sensitive
        var d = false // document exception
        // Whether third-party/first-party was explicitly present in the source.
        // This is persisted so iOS 27 can correct only implicit scoped rules.
        // A missing value from a pre-provenance cache decodes as true below,
        // preserving its old semantics until that list is refreshed.
        var q = false
        // True only for an explicitly URL/path-shaped source rule. This keeps
        // iOS 27's party correction away from arbitrary generic substrings.
        var u = false
        // Bounded raw regex rules are enabled only in the validated iOS 27 policy.
        var r = false

        init(h: String = "", p: String = "", i: [String] = [], x: [String] = [],
             t: Int = 0, n: Int = 0, f: Int = 1, a: Bool = false,
             c: Bool = false, d: Bool = false, q: Bool = false, u: Bool = false) {
            self.h = h
            self.p = p
            self.i = i
            self.x = x
            self.t = t
            self.n = n
            self.f = f
            self.a = a
            self.c = c
            self.d = d
            self.q = q
            self.u = u
        }

        private enum CodingKeys: String, CodingKey {
            case h, p, i, x, t, n, f, a, c, d, q, u, r
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            h = try values.decode(String.self, forKey: .h)
            p = try values.decode(String.self, forKey: .p)
            i = try values.decode([String].self, forKey: .i)
            x = try values.decode([String].self, forKey: .x)
            t = try values.decode(Int.self, forKey: .t)
            n = try values.decode(Int.self, forKey: .n)
            f = try values.decode(Int.self, forKey: .f)
            a = try values.decode(Bool.self, forKey: .a)
            c = try values.decode(Bool.self, forKey: .c)
            d = try values.decode(Bool.self, forKey: .d)
            // Old v1 documents had no provenance. Treat their existing party
            // value as intentional rather than widening an offline snapshot.
            q = try values.decodeIfPresent(Bool.self, forKey: .q) ?? true
            u = try values.decodeIfPresent(Bool.self, forKey: .u) ?? false
            r = try values.decodeIfPresent(Bool.self, forKey: .r) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(h, forKey: .h)
            try values.encode(p, forKey: .p)
            try values.encode(i, forKey: .i)
            try values.encode(x, forKey: .x)
            try values.encode(t, forKey: .t)
            try values.encode(n, forKey: .n)
            try values.encode(f, forKey: .f)
            try values.encode(a, forKey: .a)
            try values.encode(c, forKey: .c)
            try values.encode(d, forKey: .d)
            try values.encode(q, forKey: .q)
            try values.encode(u, forKey: .u)
            if r { try values.encode(true, forKey: .r) }
        }
    }

    struct Document: Codable, Sendable {
        var version = schema
        var domains: [String] = []
        var rules: [Rule] = []
        var unsupported = 0
        // New documents carry an explicit provenance marker. Missing metadata
        // identifies a v1 offline cache that should be refreshed opportunistically.
        var format = 3
        var supportedCount: Int { domains.count + rules.count }
        var needsProvenanceRefresh: Bool { format < 3 }

        init(version: Int = schema, domains: [String] = [], rules: [Rule] = [],
             unsupported: Int = 0, format: Int = 3) {
            self.version = version
            self.domains = domains
            self.rules = rules
            self.unsupported = unsupported
            self.format = format
        }

        private enum CodingKeys: String, CodingKey {
            case version, domains, rules, unsupported, format
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            domains = try values.decode([String].self, forKey: .domains)
            rules = try values.decode([Rule].self, forKey: .rules)
            unsupported = try values.decode(Int.self, forKey: .unsupported)
            format = try values.decodeIfPresent(Int.self, forKey: .format) ?? 1
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(version, forKey: .version)
            try values.encode(domains, forKey: .domains)
            try values.encode(rules, forKey: .rules)
            try values.encode(unsupported, forKey: .unsupported)
            try values.encode(format, forKey: .format)
        }
    }

    struct Payload: Codable, Sendable {
        var domains = "" // sorted newline-delimited string: no 100k JS objects or regexes
        var hosts: [String: [Rule]] = [:]
        var generic: [Rule] = []
        var documentExceptions: [Rule] = []
    }

    struct Snapshot: Sendable {
        var json = "{}"
        var identity = "empty"
        var domains = 0
        var patterns = 0
        var omitted = 0
    }

    static func parse(_ content: String) -> Document {
        var result = Document()
        var domains = Set<String>()
        var rules = Set<Rule>()
        for raw in content.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { continue }
            // Cosmetic rules are handled independently by the existing CSS parser.
            guard !line.contains("#") else { continue }
            guard line.utf8.count <= 2_048, let rule = parseRule(line) else {
                result.unsupported += 1
                continue
            }
            if !rule.a, rule.p.isEmpty, rule.f == 1, rule.t == 0, rule.n == 0,
               rule.i.isEmpty, rule.x.isEmpty {
                domains.insert(rule.h)
            } else {
                rules.insert(rule)
            }
        }
        result.domains = domains.sorted()
        // Stable file order for rules; prevents nondeterministic truncation/configuration reloads.
        result.rules = rules.map { (ruleKey($0), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        return result
    }

    private static func ruleKey(_ rule: Rule) -> String {
        var normalized = rule
        // Provenance is policy metadata, not filter semantics. Ignoring it for
        // ordering keeps iOS 26's parser/index order stable and prevents a
        // duplicate line from consuming extra budget merely because one copy
        // has an explicit modifier marker.
        normalized.q = false
        normalized.u = false
        normalized.r = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(normalized)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func parseRule(_ line: String) -> Rule? {
        var rule = Rule()
        var text = line
        if text.hasPrefix("@@") { rule.a = true; rule.f = 0; text.removeFirst(2) }
        // A regex may contain a `$` end anchor. Its options begin only after
        // the closing slash, not at the first dollar in the expression.
        var rawRegex: String?
        let parts: [Substring]
        if text.hasPrefix("/"), let closing = text.dropFirst().lastIndex(of: "/"),
           closing == text.index(before: text.endIndex) || text[text.index(after: closing)] == "$" {
            let body = String(text[text.index(after: text.startIndex)..<closing])
            guard let normalized = boundedRegex(body) else { return nil }
            rawRegex = normalized
            let suffix = text[text.index(after: closing)...]
            parts = suffix.isEmpty ? [text[...]] : [text[...], suffix.dropFirst()]
        } else {
            parts = text.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        }
        guard let first = parts.first, !first.isEmpty else { return nil }
        text = String(first)
        let sourceText = text
        if sourceText.hasPrefix("||") {
            let tail = sourceText.dropFirst(2)
            rule.u = tail.contains("/")
        } else if sourceText.hasPrefix("|") {
            let value = String(sourceText.dropFirst())
            if let scheme = value.range(of: "://"),
               let slash = value[scheme.upperBound...].firstIndex(of: "/") {
                rule.u = value[slash...].count > 1
            }
        } else if sourceText.hasPrefix("/") {
            // A leading slash is an explicit path-shaped ABP filter, not a
            // generic token such as `ads.js`; wildcard-only `/*` is too broad.
            let path = sourceText.dropFirst()
            rule.u = !path.isEmpty && path.first != "*"
        }
        if parts.count == 2 {
            for option in parts[1].split(separator: ",", omittingEmptySubsequences: false) {
                let value = String(option)
                if value == "third-party" { rule.f = 1; rule.q = true }
                else if value == "~third-party" { rule.f = 2; rule.q = true }
                else if value == "match-case" { rule.c = true }
                else if value.hasPrefix("domain=") {
                    for entry in value.dropFirst(7).split(separator: "|") {
                        let excluded = entry.hasPrefix("~")
                        let host = String(excluded ? entry.dropFirst() : entry[...]).lowercased()
                        guard validHost(host) else { return nil }
                        if excluded { rule.x.append(host) } else { rule.i.append(host) }
                    }
                    guard !rule.i.isEmpty || !rule.x.isEmpty else { return nil }
                } else if value == "document", rule.a {
                    rule.d = true
                } else {
                    let negated = value.hasPrefix("~")
                    let name = negated ? String(value.dropFirst()) : value
                    let masks = ["xmlhttprequest": 1, "script": 2, "image": 4, "stylesheet": 8,
                                 "font": 16, "media": 32, "websocket": 64, "ping": 128,
                                 "subdocument": 256, "other": 512]
                    guard let mask = masks[name] else { return nil }
                    if negated { rule.n |= mask } else { rule.t |= mask }
                }
            }
        }
        rule.i.sort(); rule.x.sort()
        if let rawRegex {
            rule.p = rawRegex
            rule.r = true
            // Accepted expressions are explicitly anchored URLs or slash paths.
            rule.u = true
            return rule
        }
        if text.hasPrefix("||") {
            let tail = String(text.dropFirst(2))
            let host = String(tail.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
            guard validHost(host.lowercased()) else { return nil }
            let remainder = String(tail.dropFirst(host.count))
            // A wildcard within a hostname is not a host boundary; skip rather than broaden.
            guard remainder.isEmpty || remainder.hasPrefix("^") || remainder.hasPrefix("/") else { return nil }
            rule.h = host.lowercased()
            if remainder.isEmpty || remainder == "^" { return rule }
        }
        rule.p = regex(text)
        guard (try? NSRegularExpression(pattern: rule.p)) != nil else { return nil }
        return rule
    }

    /// Apply the iOS 27 scoped-script correction before the shared payload is
    /// merged. This is intentionally used by both JavaScript and native paths,
    /// so they cannot disagree about an implicit party modifier. Broad,
    /// unscoped host-only rules keep the legacy third-party safety behavior.
    static func applying(_ policy: Policy, to document: Document) -> Document {
        var result = document
        guard policy == .ios27Scripts else {
            result.rules.removeAll { $0.r }
            return result
        }
        result.rules = document.rules.map { original in
            var rule = original
            guard !rule.a, rule.f == 1, !rule.q else { return rule }
            // An exclusion-only scope is not a positive first-party constraint:
            // promoting it would apply a generic rule to every other site.
            let hasPositiveSourceScope = !rule.i.isEmpty
            let hasHostPath = !rule.h.isEmpty && !rule.p.isEmpty
            // A path/host anchor or explicit source scope is sufficiently
            // constrained to apply to first-party requests. Arbitrary generic
            // substring rules remain third-party-only, especially for scripts.
            guard hasPositiveSourceScope || hasHostPath || rule.u else { return rule }
            rule.f = 0
            return rule
        }
        return result
    }

    /// Small shared ICU/JavaScript/WebKit subset. No wildcard repetition,
    /// groups, alternation, backreferences or lookarounds. Bounded repetition
    /// is expanded into atoms/optionals because WebKit's grammar is narrower.
    /// This avoids accepting arbitrary backtracking programs from filter lists.
    static func boundedRegex(_ source: String) -> String? {
        guard source.utf8.count <= 512, source.unicodeScalars.allSatisfy(\.isASCII),
              source.hasPrefix(#"^https?:\/\/"#) || source.hasPrefix(#"\/"#) else { return nil }
        let chars = Array(source)
        var index = 0, output = "", variableAtoms = 0, optionalAtoms = 0
        while index < chars.count {
            let char = chars[index]
            if char == "^" && index == 0 { output += "^"; index += 1; continue }
            if char == "$" && index == chars.count - 1 { output += "$"; index += 1; continue }
            var atom = ""
            if char == "\\" {
                index += 1
                guard index < chars.count, #"/.?+*()[]{}^$|\-"#.contains(chars[index]) else { return nil }
                atom = chars[index] == "/" ? "/" : "\\" + String(chars[index])
                index += 1
            } else if char == "[" {
                let start = index
                index += 1
                let bodyStart = index
                while index < chars.count && chars[index] != "]" {
                    let c = chars[index]
                    guard c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_") else { return nil }
                    index += 1
                }
                guard index > bodyStart, index < chars.count else { return nil }
                atom = String(chars[start...index]); index += 1
            } else {
                guard char.isASCII && (char.isLetter || char.isNumber || ":/_=@%&,-".contains(char)) else { return nil }
                atom = String(char); index += 1
            }
            var minimum = 1, maximum = 1
            if index < chars.count && chars[index] == "?" {
                minimum = 0; maximum = 1; index += 1
            } else if index < chars.count && chars[index] == "{" {
                index += 1
                let start = index
                while index < chars.count && chars[index] != "}" { index += 1 }
                guard index < chars.count else { return nil }
                let values = String(chars[start..<index]).split(separator: ",", omittingEmptySubsequences: false)
                guard (1...2).contains(values.count),
                      values.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
                      let low = Int(values[0]), let high = Int(values.last!),
                      low >= 1, high >= low, high <= 64 else { return nil }
                minimum = low; maximum = high; index += 1
            }
            if maximum != minimum { variableAtoms += 1 }
            optionalAtoms += maximum - minimum
            // Limit optional branches as well as output size.
            guard variableAtoms <= 2, optionalAtoms <= 8 else { return nil }
            output += String(repeating: atom, count: minimum)
            output += String(repeating: atom + "?", count: maximum - minimum)
            guard output.utf8.count <= 1_024 else { return nil }
        }
        guard (try? NSRegularExpression(pattern: output)) != nil else { return nil }
        return output
    }

    private static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && host.contains(".")
            && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                    && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
    }

    private static func regex(_ text: String) -> String {
        var value = text
        var prefix = ""
        if value.hasPrefix("||") {
            value.removeFirst(2)
            prefix = "^(?:https?|wss?)://([^/:]+\\.)?"
        } else if value.hasPrefix("|") {
            value.removeFirst()
            prefix = "^"
        }
        let end = value.hasSuffix("|")
        if end { value.removeLast() }
        let escaped = NSRegularExpression.escapedPattern(for: value)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\^", with: "([^a-zA-Z0-9_.%-]|$)")
        return prefix + escaped + (end ? "$" : "")
    }

    /// Round-robin merge prevents an earlier enabled list starving subsequent lists.
    static func merge(_ documents: [Document], policy: Policy = .legacy) throws -> Snapshot {
        var domains = Set<String>()
        var seen = Set<Rule>()
        var payload = Payload()
        var scoped = 0, generic = 0, exceptions = 0, omitted = 0
        let preparedDocuments = documents.map { applying(policy, to: $0) }
        let maxDomains = preparedDocuments.map { $0.domains.count }.max() ?? 0
        for index in 0..<maxDomains {
            for document in preparedDocuments where index < document.domains.count {
                let host = document.domains[index]
                if domains.contains(host) { continue }
                if domains.count < domainLimit { domains.insert(host) } else { omitted += 1 }
            }
        }
        let maxRules = preparedDocuments.map { $0.rules.count }.max() ?? 0
        for index in 0..<maxRules {
            for document in preparedDocuments where index < document.rules.count {
                let rule = document.rules[index]
                var semanticRule = rule
                semanticRule.q = false
                semanticRule.u = false
                semanticRule.r = false
                guard seen.insert(semanticRule).inserted else { continue }
                if rule.a {
                    // Never install a partial exception set: keep the prior snapshot instead.
                    guard exceptions < exceptionLimit else { throw IndexError.tooManyExceptions }
                    exceptions += 1
                } else if rule.h.isEmpty {
                    guard generic < genericLimit else { omitted += 1; continue }
                    generic += 1
                } else {
                    guard scoped < scopedLimit else { omitted += 1; continue }
                    scoped += 1
                }
                if rule.d { payload.documentExceptions.append(rule) }
                else if rule.h.isEmpty { payload.generic.append(rule) }
                else { payload.hosts[rule.h, default: []].append(rule) }
            }
        }
        payload.domains = domains.sorted().joined(separator: "\n")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= cacheByteLimit else { throw IndexError.tooLarge }
        let identityInput = Data(("indexed-\(schema)-\(policy.rawValue):").utf8) + data
        return Snapshot(json: String(decoding: data, as: UTF8.self),
                        identity: SHA256.hash(data: identityInput).map { String(format: "%02x", $0) }.joined(),
                        domains: domains.count, patterns: scoped + generic + exceptions, omitted: omitted)
    }

    enum IndexError: Error { case tooLarge, tooManyExceptions, invalidDownload }

    static func cacheURL(directory: URL, listURL: String) -> URL {
        let digest = SHA256.hash(data: Data(listURL.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("indexed_v\(schema)_\(digest).json")
    }

    static func load(directory: URL, listURL: String) -> Document? {
        let url = cacheURL(directory: directory, listURL: listURL)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= cacheByteLimit,
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == schema else { return nil }
        return document
    }

    static func store(_ document: Document, directory: URL, listURL: String) throws {
        let data = try JSONEncoder().encode(document)
        guard data.count <= cacheByteLimit else { throw IndexError.tooLarge }
        try data.write(to: cacheURL(directory: directory, listURL: listURL), options: .atomic)
    }
}
