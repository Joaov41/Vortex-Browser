import Combine
import CryptoKit
import Foundation
import WebKit

/// Parses the HaGeZi Pro domain list and turns it into WebKit content rule lists.
///
/// Layout under Application Support/ExtraBlocklist:
/// - `list.txt`   the downloaded list, when newer than the copy bundled with the app.
/// - `state.json` last check, available version and the compiled rule-list identifiers.
///
/// Nonisolated so parsing and rule generation run off the main actor.
nonisolated struct ExtraBlocklistStore: Sendable {
    struct State: Codable, Equatable, Sendable {
        var lastCheck: Date?
        var availableVersion: String?
        /// Content identity and rule-list identifiers of the lists last compiled into `WKContentRuleListStore`.
        var compiledIdentity: String?
        var compiledIdentifiers: [String] = []
    }

    struct Blocklist: Sendable {
        let version: String
        let domains: [String]
    }

    enum Error: Swift.Error, LocalizedError {
        case notHaGeZi, missingVersion, tooFewDomains(Int), tooLarge(Int), compileFailed
        var errorDescription: String? {
            switch self {
            case .notHaGeZi: "The file is not a HaGeZi blocklist."
            case .missingVersion: "The blocklist has no version header."
            case .tooFewDomains(let count): "The blocklist has only \(count) domains."
            case .tooLarge(let size): "The blocklist is unexpectedly large (\(size) bytes)."
            case .compileFailed: "WebKit could not compile the blocklist."
            }
        }
    }

    static let downloadURL = URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt")!
    static let maximumSize = 20 * 1024 * 1024
    static let minimumDomains = 50_000
    /// WebKit refuses a single list above 150,000 rules; smaller lists also compile with less peak memory.
    static let rulesPerList = 50_000
    /// Bump when the generated rules change shape so installs recompile.
    static let ruleFormatVersion = 1

    let root: URL
    var listURL: URL { root.appendingPathComponent("list.txt") }
    private var stateURL: URL { root.appendingPathComponent("state.json") }

    init(root: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appendingPathComponent("ExtraBlocklist", isDirectory: true)
    }

    func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL), let state = try? Self.decoder.decode(State.self, from: data) else { return State() }
        return state
    }

    func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    /// The newer of the downloaded and bundled lists.
    func loadActiveList(bundled: URL?) throws -> Blocklist {
        let downloaded = (try? Data(contentsOf: listURL)).flatMap { try? Self.parse($0) }
        let packaged = try bundled.map { try Self.parse(try Data(contentsOf: $0)) }
        switch (downloaded, packaged) {
        case let (downloaded?, packaged?): return Self.isNewer(downloaded.version, than: packaged.version) ? downloaded : packaged
        case let (downloaded?, nil): return downloaded
        case let (nil, packaged?): return packaged
        case (nil, nil): throw Error.notHaGeZi
        }
    }

    func install(_ data: Data) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: listURL, options: .atomic)
    }

    // MARK: Parsing

    /// Reads the version header from the first bytes of a list.
    static func version(in header: Data) -> String? {
        let text = String(decoding: header.prefix(4096), as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("! Version:") {
            let value = line.dropFirst("! Version:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Accepts only plain `||domain^` entries; any other syntax is ignored.
    static func parse(_ data: Data) throws -> Blocklist {
        guard data.count <= maximumSize else { throw Error.tooLarge(data.count) }
        let header = String(decoding: data.prefix(1024), as: UTF8.self)
        guard header.contains("! Title: HaGeZi") else { throw Error.notHaGeZi }
        guard let version = version(in: data) else { throw Error.missingVersion }
        var domains: [String] = []
        domains.reserveCapacity(250_000)
        data.withUnsafeBytes { buffer in
            var start = 0
            let bytes = buffer.bindMemory(to: UInt8.self)
            for index in 0...bytes.count {
                guard index == bytes.count || bytes[index] == 0x0A else { continue }
                var end = index
                if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                // "||" + at least "a.b" + "^"
                if end - start > 6, bytes[start] == 0x7C, bytes[start + 1] == 0x7C, bytes[end - 1] == 0x5E {
                    var valid = true, dots = 0
                    for position in (start + 2)..<(end - 1) {
                        let byte = bytes[position]
                        switch byte {
                        case 0x61...0x7A, 0x30...0x39, 0x2D: continue
                        case 0x2E: dots += 1
                        default: valid = false
                        }
                        if !valid { break }
                    }
                    if valid, dots > 0 {
                        domains.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[(start + 2)..<(end - 1)]), as: UTF8.self))
                    }
                }
                start = index + 1
            }
        }
        guard domains.count >= minimumDomains else { throw Error.tooFewDomains(domains.count) }
        return Blocklist(version: version, domains: domains)
    }

    /// HaGeZi versions are dotted numbers (e.g. 2026.0923.1517.16); compare numerically per component.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? -1 }
        let rhs = installed.split(separator: ".").map { Int($0) ?? -1 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0, b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: Hosts left to uBlock Origin Lite

    /// Hosts that uBOL's default rulesets deliberately answer with a harmless replacement (redirect) or allow,
    /// on every site. The extra list leaves them, and their subdomains, to uBOL for site compatibility.
    static func hostsLeftToUBOL(rulesets: [Data]) -> Set<String> {
        var hosts = Set<String>()
        for data in rulesets {
            guard let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for rule in rules {
                guard let action = rule["action"] as? [String: Any], let type = action["type"] as? String,
                      type == "redirect" || type == "allow" || type == "allowAllRequests",
                      let condition = rule["condition"] as? [String: Any], condition["initiatorDomains"] == nil else { continue }
                if let domains = condition["requestDomains"] as? [String] { hosts.formUnion(domains) }
                if let filter = condition["urlFilter"] as? String, let host = hostOnlyFilter(filter) { hosts.insert(host) }
            }
        }
        return hosts
    }

    /// `||host^`, `||host/` or `||host` with nothing after it.
    private static func hostOnlyFilter(_ filter: String) -> String? {
        guard filter.hasPrefix("||") else { return nil }
        var host = filter.dropFirst(2)
        if host.hasSuffix("^") || host.hasSuffix("/") { host = host.dropLast() }
        guard host.contains("."), host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return String(host).lowercased()
    }

    // MARK: Rule generation

    struct RuleLists: Sendable {
        let json: [String]
        let blockedDomains: Int
        let leftToUBOL: Int
    }

    /// One block rule per domain, in lists of at most `rulesPerList`. Every list ends with exceptions for hosts
    /// left to uBOL under a listed parent, and for top-level page loads: a page the user opens is never blocked,
    /// only what it loads.
    static func makeRuleLists(_ list: Blocklist, leaving ubolHosts: Set<String>) -> RuleLists {
        func coveredByUBOL(_ domain: String) -> Bool {
            var candidate = Substring(domain)
            while true {
                if ubolHosts.contains(String(candidate)) { return true }
                guard let dot = candidate.firstIndex(of: ".") else { return false }
                candidate = candidate[candidate.index(after: dot)...]
                if !candidate.contains(".") { return false }
            }
        }
        let blocked = list.domains.filter { !coveredByUBOL($0) }
        let listed = Set(blocked)
        // uBOL hosts below a blocked parent (e.g. a redirect for one subdomain) need an explicit exception.
        let exceptions = ubolHosts.filter { host in
            var candidate = Substring(host)
            while let dot = candidate.firstIndex(of: ".") {
                candidate = candidate[candidate.index(after: dot)...]
                if !candidate.contains(".") { return false }
                if listed.contains(String(candidate)) { return true }
            }
            return false
        }.sorted()
        var tail = exceptions.map { #"{"trigger":{"url-filter":""# + hostPattern($0) + #""},"action":{"type":"ignore-previous-rules"}}"# }
        tail.append(#"{"trigger":{"url-filter":".*","resource-type":["document"],"load-context":["top-frame"]},"action":{"type":"ignore-previous-rules"}}"#)
        let chunk = rulesPerList - tail.count
        var json: [String] = []
        var index = 0
        while index < blocked.count {
            let slice = blocked[index..<min(index + chunk, blocked.count)]
            let rules = slice.map { #"{"trigger":{"url-filter":""# + hostPattern($0) + #""},"action":{"type":"block"}}"# } + tail
            json.append("[" + rules.joined(separator: ",") + "]")
            index += chunk
        }
        return RuleLists(json: json, blockedDomains: blocked.count, leftToUBOL: list.domains.count - blocked.count)
    }

    /// Matches the host or any subdomain, for any scheme, with a port or path boundary; JSON-escaped.
    static func hostPattern(_ host: String) -> String {
        #"^[^:]+://+([^/:]+\\.)?"# + host.replacingOccurrences(of: ".", with: #"\\."#) + "[:/]"
    }

    static func identity(listVersion: String, ubolRulesVersion: String) -> String {
        let digest = SHA256.hash(data: Data("\(listVersion)|\(ubolRulesVersion)|\(ruleFormatVersion)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// HaGeZi Pro as native WebKit rules alongside uBlock Origin Lite, for ad, tracker and malware domains uBOL's
/// lists do not cover. Active only while Lite is the selected engine, and removed from pages on sites where
/// Lite's filtering is turned off.
@MainActor
final class ExtraBlocklistService: ObservableObject {
    enum Phase: Equatable { case idle, building, checking, updating }

    static let shared = ExtraBlocklistService()
    static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let enabledKey = "extraBlocklist.enabled"
    private static let blockedDomainsKey = "extraBlocklist.blockedDomains"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            reapplyAll()
        }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var version: String?
    @Published private(set) var blockedDomains = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var availableVersion: String?
    @Published private(set) var lastCheck: Date?

    let store = ExtraBlocklistStore()
    private var ruleLists: [WKContentRuleList] = []
    /// Web views whose lists are attached, and every web view seen at a main-frame navigation.
    private let attachedViews = NSHashTable<WKWebView>.weakObjects()
    private let knownViews = NSMapTable<WKWebView, NSURL>.weakToStrongObjects()
    private var preparation: Task<Void, Never>?
    private let session: URLSession

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = ["User-Agent": "Vortex-Browser"]
        session = URLSession(configuration: configuration)
        let state = store.loadState()
        lastCheck = state.lastCheck
        availableVersion = state.availableVersion
    }

    private var bundledListURL: URL? { Bundle.main.url(forResource: "hagezi-pro", withExtension: "txt") }

    /// Loads the compiled lists, building them in the background when the list or uBOL's rules changed.
    func prepare() async {
        if let preparation { await preparation.value; return }
        let task = Task { @MainActor in
            await self.loadOrBuild()
            self.preparation = nil
        }
        preparation = task
        await task.value
        Task { await checkIfDue() }
    }

    private func loadOrBuild() async {
        let store = self.store, bundled = bundledListURL
        do {
            let list = try await Task.detached(priority: .utility) { try store.loadActiveList(bundled: bundled) }.value
            try await build(list)
        } catch {
            statusMessage = "HaGeZi Pro could not be prepared: \(error.localizedDescription)"
        }
    }

    /// Uses the cached compiled lists for `list` when they match, otherwise generates and compiles new ones.
    /// Throws without touching the active lists.
    private func build(_ list: ExtraBlocklistStore.Blocklist) async throws {
        let lite = UBlockLiteService.shared
        let identity = ExtraBlocklistStore.identity(listVersion: list.version, ubolRulesVersion: lite.rulesVersion)
        var state = store.loadState()
        if state.compiledIdentity == identity, let cached = await lookUp(state.compiledIdentifiers) {
            install(cached, version: list.version, blockedDomains: UserDefaults.standard.integer(forKey: Self.blockedDomainsKey))
            return
        }
        let previousPhase = phase
        phase = .building
        defer { phase = previousPhase }
        statusMessage = "Preparing HaGeZi Pro \(list.version)…"
        let source = lite.defaultRulesetSource()
        let generated = await Task.detached(priority: .utility) {
            let rulesets = (source.flatMap { try? UBOLPackageStore.defaultEnabledRulesetData(from: $0) }) ?? []
            return ExtraBlocklistStore.makeRuleLists(list, leaving: ExtraBlocklistStore.hostsLeftToUBOL(rulesets: rulesets))
        }.value
        let identifiers = generated.json.indices.map { "vortex.extra-blocklist.\(identity).\($0)" }
        var compiled: [WKContentRuleList] = []
        do {
            for (identifier, json) in zip(identifiers, generated.json) {
                guard let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
                    throw ExtraBlocklistStore.Error.compileFailed
                }
                compiled.append(ruleList)
            }
        } catch {
            for identifier in identifiers { try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) }
            throw error
        }
        let previous = state.compiledIdentifiers
        state.compiledIdentity = identity
        state.compiledIdentifiers = identifiers
        try store.save(state)
        UserDefaults.standard.set(generated.blockedDomains, forKey: Self.blockedDomainsKey)
        install(compiled, version: list.version, blockedDomains: generated.blockedDomains)
        for identifier in previous where !identifiers.contains(identifier) {
            try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier)
        }
    }

    private func lookUp(_ identifiers: [String]) async -> [WKContentRuleList]? {
        guard !identifiers.isEmpty else { return nil }
        var lists: [WKContentRuleList] = []
        for identifier in identifiers {
            guard let list = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: identifier) else { return nil }
            lists.append(list)
        }
        return lists
    }

    /// Swaps in newly compiled lists on every page that currently has the old ones.
    private func install(_ lists: [WKContentRuleList], version: String, blockedDomains: Int) {
        for webView in attachedViews.allObjects {
            for list in ruleLists { webView.configuration.userContentController.remove(list) }
        }
        attachedViews.removeAllObjects()
        ruleLists = lists
        self.version = version
        self.blockedDomains = blockedDomains
        statusMessage = nil
        reapplyAll()
    }

    // MARK: Attachment

    /// Called before every main-frame navigation. `noFilteringHosts` are the sites where Lite is turned off.
    func apply(to webView: WKWebView, url: URL?, noFilteringHosts: Set<String>) {
        knownViews.setObject((url ?? URL(string: "about:blank")!) as NSURL, forKey: webView)
        let wanted = isEnabled && UBlockLiteService.shared.engine == .ublockLite && !ruleLists.isEmpty
            && !Self.isExcluded(url?.host, by: noFilteringHosts)
        setAttached(wanted, to: webView)
    }

    /// Re-evaluates every known page, after the switch, the engine or the lists change.
    func reapplyAll() {
        guard let views = knownViews.keyEnumerator().allObjects as? [WKWebView] else { return }
        for webView in views {
            apply(to: webView, url: knownViews.object(forKey: webView) as URL?,
                  noFilteringHosts: UBlockLiteService.shared.cachedNoFilteringHosts(for: webView))
        }
    }

    private func setAttached(_ attached: Bool, to webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if attached, !attachedViews.contains(webView) {
            for list in ruleLists { controller.add(list) }
            attachedViews.add(webView)
        } else if !attached, attachedViews.contains(webView) {
            for list in ruleLists { controller.remove(list) }
            attachedViews.remove(webView)
        }
    }

    /// Matches uBOL's lookup: a site is off when its host or any parent domain is listed, or `all-urls` is.
    static func isExcluded(_ host: String?, by noFilteringHosts: Set<String>) -> Bool {
        if noFilteringHosts.contains("all-urls") { return true }
        guard var candidate = host?.lowercased(), !candidate.isEmpty else { return false }
        while true {
            if noFilteringHosts.contains(candidate) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { return false }
            candidate = String(candidate[candidate.index(after: dot)...])
        }
    }

    // MARK: Updates

    /// Daily: one small ranged request for the list header, to learn whether a newer version exists.
    func checkIfDue() async {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        await check()
    }

    func check() async {
        guard phase == .idle else { return }
        phase = .checking
        defer { phase = .idle }
        do {
            var request = URLRequest(url: ExtraBlocklistStore.downloadURL)
            request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode),
                  let latest = ExtraBlocklistStore.version(in: data) else { throw ExtraBlocklistStore.Error.missingVersion }
            var state = store.loadState()
            state.lastCheck = Date()
            lastCheck = state.lastCheck
            if let version, !ExtraBlocklistStore.isNewer(latest, than: version) {
                state.availableVersion = nil
                statusMessage = "HaGeZi Pro is up to date (\(version))."
            } else {
                state.availableVersion = latest
                statusMessage = "HaGeZi Pro \(latest) is available."
            }
            availableVersion = state.availableVersion
            try store.save(state)
        } catch {
            statusMessage = "Blocklist check failed: \(error.localizedDescription)"
        }
    }

    /// Downloads, validates and compiles the latest list. It replaces the saved list only after it compiled, so
    /// the current lists stay active, now and after a relaunch, if any step fails.
    func downloadAndApply() async {
        guard phase == .idle else { return }
        phase = .updating
        defer { phase = .idle }
        do {
            statusMessage = "Downloading HaGeZi Pro…"
            let (fileURL, response) = try await session.download(from: ExtraBlocklistStore.downloadURL)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ExtraBlocklistStore.Error.missingVersion }
            let (data, list) = try await Task.detached(priority: .userInitiated) { () throws -> (Data, ExtraBlocklistStore.Blocklist) in
                let data = try Data(contentsOf: fileURL)
                return (data, try ExtraBlocklistStore.parse(data))
            }.value
            try await build(list)
            let store = self.store
            try await Task.detached(priority: .utility) { try store.install(data) }.value
            var state = store.loadState()
            state.availableVersion = nil
            try store.save(state)
            availableVersion = nil
            statusMessage = "HaGeZi Pro \(list.version) is active."
        } catch {
            statusMessage = "Blocklist update failed: \(error.localizedDescription) The current list stays active."
        }
    }
}
