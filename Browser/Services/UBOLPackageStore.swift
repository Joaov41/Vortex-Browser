import CryptoKit
import Foundation

/// Manages the on-disk uBlock Origin Lite package that WebKit loads.
///
/// Layout under Application Support/UBOLite:
/// - `active/`   the package WebKit loads: the bundled official archive, extracted once per app build,
///               with the WebKit compatibility policy applied and any accepted network-rule update overlaid.
/// - `pending/`  a verified, validated rule-data update waiting for the user to apply it.
/// - `previous/` the rule files replaced by the last apply, for rollback.
/// - `state.json` provenance for all of the above.
///
/// Only rule *data* (JSON) is ever replaced. The extension's JavaScript, manifest and resources stay pinned.
struct UBOLPackageStore {
    struct State: Codable, Equatable {
        var bundleBuild: String
        var packageVersion: String
        var rulesVersion: String
        var appliedRulesVersion: String?
        var previousRulesVersion: String?
        var pendingRulesVersion: String?
        var pendingDigest: String?
        var rejectedReleases: [String] = []
        var omittedRuleIDs: [String: [Int]] = [:]
        var lastCheck: Date?
        var availableRelease: String?
    }

    struct RuleOverlay {
        /// Relative path inside the package (e.g. `rulesets/main/easylist.json`) to validated JSON data.
        var files: [String: Data]
        var version: String
        var omittedRuleIDs: [String: [Int]]
    }

    enum Error: Swift.Error, LocalizedError {
        case bundledPackageMissing, manifestInvalid(String), ruleFileInvalid(String, String), noRuleFiles, versionUnchanged(String), nothingPending
        var errorDescription: String? {
            switch self {
            case .bundledPackageMissing: "The bundled uBlock Origin Lite package is missing."
            case .manifestInvalid(let detail): "The extension manifest is invalid: \(detail)."
            case .ruleFileInvalid(let path, let detail): "Rule file \(path) was rejected: \(detail)."
            case .noRuleFiles: "The release contains no usable rule files."
            case .versionUnchanged(let version): "Rules \(version) are already installed."
            case .nothingPending: "No verified update is waiting."
            }
        }
    }

    /// Rule-data directories inside the package; everything else is code or resources and stays pinned.
    static let ruleDataDirectories = ["rulesets/main", "rulesets/regex", "rulesets/strictblock", "rulesets/urlskip"]
    static let ruleDetailsPath = "rulesets/ruleset-details.json"
    static let knownActionTypes: Set<String> = ["block", "allow", "allowAllRequests", "redirect", "upgradeScheme", "modifyHeaders"]

    let root: URL
    var activeURL: URL { root.appendingPathComponent("active", isDirectory: true) }
    var pendingURL: URL { root.appendingPathComponent("pending", isDirectory: true) }
    var previousURL: URL { root.appendingPathComponent("previous", isDirectory: true) }
    private var stateURL: URL { root.appendingPathComponent("state.json") }

    init(root: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appendingPathComponent("UBOLite", isDirectory: true)
    }

    static var bundleBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? Self.decoder.decode(State.self, from: data)
    }

    func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    /// Ensures `active/` holds this app build's bundled package (with the compatibility policy applied)
    /// and reapplies an accepted rules overlay if one was installed by a previous build of the same package.
    func prepareActivePackage(bundledArchive: URL, packageVersion: String) throws -> State {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if let state = loadState(), state.bundleBuild == Self.bundleBuild, state.packageVersion == packageVersion,
           fileManager.fileExists(atPath: activeURL.appendingPathComponent("manifest.json").path) {
            return state
        }
        let archive = try ZipArchive(url: bundledArchive)
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try archive.extract(to: staging)
        let manifest = try Self.readManifest(at: staging)
        var omitted: [String: [Int]] = [:]
        for (id, path) in manifest.rulesets {
            let url = staging.appendingPathComponent(path)
            let filtered = try Self.applyCompatibilityPolicy(to: try Data(contentsOf: url), path: path)
            if !filtered.omittedRuleIDs.isEmpty { omitted[id] = filtered.omittedRuleIDs }
            try filtered.data.write(to: url, options: .atomic)
        }
        let previousState = loadState()
        // A rules overlay accepted by an earlier build stays valid only for the same upstream package.
        if let previousState, previousState.packageVersion == packageVersion, previousState.appliedRulesVersion != nil,
           fileManager.fileExists(atPath: activeURL.path) {
            for directory in Self.ruleDataDirectories + [Self.ruleDetailsPath] {
                let source = activeURL.appendingPathComponent(directory)
                let destination = staging.appendingPathComponent(directory)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
            }
        }
        try? fileManager.removeItem(at: activeURL)
        try fileManager.moveItem(at: staging, to: activeURL)
        var state = State(bundleBuild: Self.bundleBuild, packageVersion: packageVersion, rulesVersion: packageVersion)
        if let previousState, previousState.packageVersion == packageVersion {
            state.rulesVersion = previousState.rulesVersion
            state.appliedRulesVersion = previousState.appliedRulesVersion
            state.pendingRulesVersion = previousState.pendingRulesVersion
            state.pendingDigest = previousState.pendingDigest
            state.rejectedReleases = previousState.rejectedReleases
            state.lastCheck = previousState.lastCheck
            state.availableRelease = previousState.availableRelease
            state.omittedRuleIDs = previousState.omittedRuleIDs
        } else {
            try? fileManager.removeItem(at: pendingURL)
            try? fileManager.removeItem(at: previousURL)
        }
        if state.appliedRulesVersion == nil { state.omittedRuleIDs = omitted }
        try save(state)
        return state
    }

    // MARK: Manifest

    struct Manifest {
        let version: String
        /// ruleset id → manifest path without leading slash.
        let rulesets: [String: String]
    }

    static func readManifest(at packageURL: URL) throws -> Manifest {
        let data = try Data(contentsOf: packageURL.appendingPathComponent("manifest.json"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String,
              let dnr = object["declarative_net_request"] as? [String: Any],
              let resources = dnr["rule_resources"] as? [[String: Any]] else { throw Error.manifestInvalid("missing declarative_net_request") }
        var rulesets: [String: String] = [:]
        for resource in resources {
            guard let id = resource["id"] as? String, let path = resource["path"] as? String else { throw Error.manifestInvalid("rule resource entry") }
            rulesets[id] = path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
        return Manifest(version: version, rulesets: rulesets)
    }

    // MARK: WebKit compatibility policy

    struct FilteredRules {
        let data: Data
        let omittedRuleIDs: [Int]
    }

    /// WebKit converts `excludedRequestDomains` into `ignore-following-rules` triggers keyed only by the excluded
    /// domain, losing the original URL filter (see _WKWebExtensionDeclarativeNetRequestRule.mm). For a rule that
    /// applies on every page that suppresses unrelated blocking for any request containing those domain strings
    /// (root cause of the tracker-script bypass, upstream rule 5154). Rules limited to specific initiator sites
    /// only affect those sites and are kept. Block rules with `excludedRequestDomains` and no `initiatorDomains`
    /// are omitted; the JSON is otherwise rewritten unchanged in content.
    static func applyCompatibilityPolicy(to data: Data, path: String) throws -> FilteredRules {
        guard let rules = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Error.ruleFileInvalid(path, "not an array of rules")
        }
        var kept: [[String: Any]] = []
        var omitted: [Int] = []
        kept.reserveCapacity(rules.count)
        for rule in rules {
            if let action = rule["action"] as? [String: Any], action["type"] as? String == "block",
               let condition = rule["condition"] as? [String: Any],
               condition["excludedRequestDomains"] != nil, condition["initiatorDomains"] == nil {
                omitted.append(rule["id"] as? Int ?? -1)
                continue
            }
            kept.append(rule)
        }
        let output = try JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys])
        return FilteredRules(data: output, omittedRuleIDs: omitted)
    }

    // MARK: Rule-data validation

    /// Accepts only the rule data of rulesets declared by the pinned manifest and checks each file's shape.
    static func makeOverlay(from archive: ZipArchive, pinnedManifest: Manifest, version: String) throws -> RuleOverlay {
        var files: [String: Data] = [:]
        var omitted: [String: [Int]] = [:]
        let pinnedIDs = Set(pinnedManifest.rulesets.keys)
        for entry in archive.entries where !entry.isDirectory {
            guard let directory = ruleDataDirectories.first(where: { entry.path.hasPrefix($0 + "/") }) else { continue }
            let fileName = String(entry.path.dropFirst(directory.count + 1))
            guard fileName.hasSuffix(".json"), !fileName.contains("/") else { continue }
            let id = String(fileName.dropLast(5))
            guard pinnedIDs.contains(id) else { continue }
            let data = try archive.contents(of: entry)
            if directory == "rulesets/main" || directory == "rulesets/regex" || directory == "rulesets/strictblock" {
                try validateDeclarativeRules(data, path: entry.path)
                let filtered = try applyCompatibilityPolicy(to: data, path: entry.path)
                if !filtered.omittedRuleIDs.isEmpty { omitted[id] = filtered.omittedRuleIDs }
                files[entry.path] = filtered.data
            } else {
                try validateURLSkipRules(data, path: entry.path)
                files[entry.path] = data
            }
        }
        if let details = archive.entry(named: ruleDetailsPath) {
            let data = try archive.contents(of: details)
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], list.allSatisfy({ $0["id"] is String }) else {
                throw Error.ruleFileInvalid(ruleDetailsPath, "not a list of ruleset descriptions")
            }
            files[ruleDetailsPath] = data
        }
        // Every static ruleset in the pinned manifest must be present so WebKit never loads a mixed set.
        for (id, path) in pinnedManifest.rulesets where files[path] == nil {
            throw Error.ruleFileInvalid(path, "static ruleset \(id) missing from the release")
        }
        guard !files.isEmpty else { throw Error.noRuleFiles }
        return RuleOverlay(files: files, version: version, omittedRuleIDs: omitted)
    }

    static func validateDeclarativeRules(_ data: Data, path: String) throws {
        guard let rules = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Error.ruleFileInvalid(path, "not an array of rules")
        }
        var ids = Set<Int>()
        for rule in rules {
            guard let id = rule["id"] as? Int, id > 0, ids.insert(id).inserted else { throw Error.ruleFileInvalid(path, "duplicate or invalid rule id") }
            guard let action = rule["action"] as? [String: Any], let type = action["type"] as? String, knownActionTypes.contains(type) else {
                throw Error.ruleFileInvalid(path, "unknown action in rule \(id)")
            }
            guard let condition = rule["condition"] as? [String: Any], !condition.isEmpty else { throw Error.ruleFileInvalid(path, "missing condition in rule \(id)") }
            if let priority = rule["priority"], !(priority is Int) { throw Error.ruleFileInvalid(path, "invalid priority in rule \(id)") }
            if let redirect = action["redirect"] as? [String: Any], let extensionPath = redirect["extensionPath"] as? String, extensionPath.contains("..") {
                throw Error.ruleFileInvalid(path, "unsafe redirect in rule \(id)")
            }
        }
    }

    static func validateURLSkipRules(_ data: Data, path: String) throws {
        guard let rules = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rules.allSatisfy({ $0["re"] is String && $0["steps"] is [String] }) else {
            throw Error.ruleFileInvalid(path, "not a list of urlskip rules")
        }
    }

    // MARK: Pending / apply / rollback

    func stage(_ overlay: RuleOverlay, digest: String) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: pendingURL)
        for (path, data) in overlay.files {
            let url = pendingURL.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        var state = loadState() ?? State(bundleBuild: Self.bundleBuild, packageVersion: overlay.version, rulesVersion: overlay.version)
        state.pendingRulesVersion = overlay.version
        state.pendingDigest = digest
        state.omittedRuleIDs = overlay.omittedRuleIDs
        try save(state)
    }

    /// Moves the pending rule files into the active package, keeping the replaced files for rollback.
    func applyPending() throws -> State {
        let fileManager = FileManager.default
        guard var state = loadState(), let version = state.pendingRulesVersion, fileManager.fileExists(atPath: pendingURL.path) else {
            throw Error.nothingPending
        }
        try? fileManager.removeItem(at: previousURL)
        for directory in Self.ruleDataDirectories + [Self.ruleDetailsPath] {
            let source = pendingURL.appendingPathComponent(directory)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = activeURL.appendingPathComponent(directory)
            let backup = previousURL.appendingPathComponent(directory)
            try fileManager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) { try fileManager.moveItem(at: target, to: backup) }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: target)
        }
        try? fileManager.removeItem(at: pendingURL)
        state.previousRulesVersion = state.rulesVersion
        state.rulesVersion = version
        state.appliedRulesVersion = version
        state.pendingRulesVersion = nil
        state.pendingDigest = nil
        try save(state)
        return state
    }

    /// Restores the rule files replaced by the last apply and marks that release as rejected.
    func rollback(rejecting version: String) throws -> State {
        let fileManager = FileManager.default
        guard var state = loadState() else { throw Error.nothingPending }
        if fileManager.fileExists(atPath: previousURL.path) {
            for directory in Self.ruleDataDirectories + [Self.ruleDetailsPath] {
                let backup = previousURL.appendingPathComponent(directory)
                guard fileManager.fileExists(atPath: backup.path) else { continue }
                let target = activeURL.appendingPathComponent(directory)
                try? fileManager.removeItem(at: target)
                try fileManager.moveItem(at: backup, to: target)
            }
            try? fileManager.removeItem(at: previousURL)
        }
        if !state.rejectedReleases.contains(version) { state.rejectedReleases.append(version) }
        if state.appliedRulesVersion == version {
            state.rulesVersion = state.previousRulesVersion ?? state.packageVersion
            state.appliedRulesVersion = state.rulesVersion == state.packageVersion ? nil : state.rulesVersion
            state.previousRulesVersion = nil
        }
        try save(state)
        return state
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
