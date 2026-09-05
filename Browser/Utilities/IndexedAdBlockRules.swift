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
    }

    struct Document: Codable, Sendable {
        var version = schema
        var domains: [String] = []
        var rules: [Rule] = []
        var unsupported = 0
        var supportedCount: Int { domains.count + rules.count }
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(rule)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func parseRule(_ line: String) -> Rule? {
        var rule = Rule()
        var text = line
        if text.hasPrefix("@@") { rule.a = true; rule.f = 0; text.removeFirst(2) }
        // Raw regex filters and procedural/redirect modifiers require a richer engine.
        guard !(text.hasPrefix("/") && text.hasSuffix("/")) else { return nil }
        let parts = text.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        text = String(first)
        guard !(text.hasPrefix("/") && text.hasSuffix("/")) else { return nil }
        if parts.count == 2 {
            for option in parts[1].split(separator: ",", omittingEmptySubsequences: false) {
                let value = String(option)
                if value == "third-party" { rule.f = 1 }
                else if value == "~third-party" { rule.f = 2 }
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
    static func merge(_ documents: [Document]) throws -> Snapshot {
        var domains = Set<String>()
        var seen = Set<Rule>()
        var payload = Payload()
        var scoped = 0, generic = 0, exceptions = 0, omitted = 0
        let maxDomains = documents.map { $0.domains.count }.max() ?? 0
        for index in 0..<maxDomains {
            for document in documents where index < document.domains.count {
                let host = document.domains[index]
                if domains.contains(host) { continue }
                if domains.count < domainLimit { domains.insert(host) } else { omitted += 1 }
            }
        }
        let maxRules = documents.map { $0.rules.count }.max() ?? 0
        for index in 0..<maxRules {
            for document in documents where index < document.rules.count {
                let rule = document.rules[index]
                guard seen.insert(rule).inserted else { continue }
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
        return Snapshot(json: String(decoding: data, as: UTF8.self),
                        identity: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
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
