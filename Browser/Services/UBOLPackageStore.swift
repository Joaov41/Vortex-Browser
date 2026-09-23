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
/// Nonisolated so extraction, validation and file moves can run off the main actor.
nonisolated struct UBOLPackageStore: Sendable {
    struct State: Codable, Equatable, Sendable {
        var bundleBuild: String
        var packageVersion: String
        /// `compatibilityPolicyVersion` the active package was filtered with; nil for packages prepared before it existed.
        var policyVersion: Int?
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

    struct RuleOverlay: Sendable {
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
    /// Directories holding declarative rules: the static rulesets (`main`) and the regex and strict-block rules
    /// uBOL registers as dynamic rules. WebKit converts all of them the same way, so all get the compatibility policy.
    static let declarativeRuleDirectories = ["rulesets/main", "rulesets/regex", "rulesets/strictblock"]
    static let ruleDetailsPath = "rulesets/ruleset-details.json"
    static let knownActionTypes: Set<String> = ["block", "allow", "allowAllRequests", "redirect", "upgradeScheme", "modifyHeaders"]
    /// Bump when `applyCompatibilityPolicy` changes so existing installs re-filter their active package.
    static let compatibilityPolicyVersion = 3

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
           state.policyVersion == Self.compatibilityPolicyVersion,
           fileManager.fileExists(atPath: activeURL.appendingPathComponent("manifest.json").path) {
            return state
        }
        let archive = try ZipArchive(url: bundledArchive)
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try archive.extract(to: staging)
        // Reject an archive without a valid manifest before it replaces the active package.
        _ = try Self.readManifest(at: staging)
        let previousState = loadState()
        // A rules overlay accepted by an earlier build stays valid only for the same upstream package.
        let carriesOverlay = previousState.map { $0.packageVersion == packageVersion && $0.appliedRulesVersion != nil } == true
            && fileManager.fileExists(atPath: activeURL.path)
        if carriesOverlay {
            for directory in Self.ruleDataDirectories + [Self.ruleDetailsPath] {
                let source = activeURL.appendingPathComponent(directory)
                let destination = staging.appendingPathComponent(directory)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
            }
        }
        // Filter after the overlay copy so an accepted update is re-filtered by the current policy too.
        var omitted: [String: [Int]] = [:]
        for directory in Self.declarativeRuleDirectories {
            let folder = staging.appendingPathComponent(directory, isDirectory: true)
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasSuffix(".json") {
                let url = folder.appendingPathComponent(name)
                let filtered = try Self.applyCompatibilityPolicy(to: try Data(contentsOf: url), path: "\(directory)/\(name)")
                if !filtered.omittedRuleIDs.isEmpty { omitted[Self.omissionKey(directory: directory, id: String(name.dropLast(5)))] = filtered.omittedRuleIDs }
                try filtered.data.write(to: url, options: .atomic)
            }
        }
        try? fileManager.removeItem(at: activeURL)
        try fileManager.moveItem(at: staging, to: activeURL)
        var state = State(bundleBuild: Self.bundleBuild, packageVersion: packageVersion, policyVersion: Self.compatibilityPolicyVersion, rulesVersion: packageVersion)
        if let previousState, previousState.packageVersion == packageVersion {
            state.rulesVersion = previousState.rulesVersion
            state.appliedRulesVersion = previousState.appliedRulesVersion
            state.pendingRulesVersion = previousState.pendingRulesVersion
            state.pendingDigest = previousState.pendingDigest
            state.rejectedReleases = previousState.rejectedReleases
            state.lastCheck = previousState.lastCheck
            state.availableRelease = previousState.availableRelease
        } else {
            try? fileManager.removeItem(at: pendingURL)
            try? fileManager.removeItem(at: previousURL)
        }
        // Rules the overlay's own filtering already removed are no longer present to count again.
        if carriesOverlay, let previousState {
            state.omittedRuleIDs = previousState.omittedRuleIDs.merging(omitted) { Array(Set($0 + $1)).sorted() }
        } else {
            state.omittedRuleIDs = omitted
        }
        try save(state)
        return state
    }

    // MARK: Manifest

    struct Manifest: Sendable {
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

    enum RulesetSource: Sendable {
        case directory(URL), archive(URL)
    }

    /// Rule data of the static rulesets the manifest enables by default.
    static func defaultEnabledRulesetData(from source: RulesetSource) throws -> [Data] {
        switch source {
        case .directory(let url):
            return try enabledRulesetPaths(manifest: Data(contentsOf: url.appendingPathComponent("manifest.json")))
                .map { try Data(contentsOf: url.appendingPathComponent($0)) }
        case .archive(let url):
            let archive = try ZipArchive(url: url)
            guard let manifest = archive.entry(named: "manifest.json") else { throw Error.manifestInvalid("missing manifest.json") }
            return try enabledRulesetPaths(manifest: archive.contents(of: manifest)).compactMap { path in
                try archive.entry(named: path).map { try archive.contents(of: $0) }
            }
        }
    }

    private static func enabledRulesetPaths(manifest data: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dnr = object["declarative_net_request"] as? [String: Any],
              let resources = dnr["rule_resources"] as? [[String: Any]] else { throw Error.manifestInvalid("missing declarative_net_request") }
        return resources.compactMap { resource in
            guard resource["enabled"] as? Bool == true, let path = resource["path"] as? String else { return nil }
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
    }

    // MARK: WebKit compatibility policy

    struct FilteredRules: Sendable {
        let data: Data
        let omittedRuleIDs: [Int]
    }

    /// WebKit converts `excludedRequestDomains` into `ignore-following-rules` triggers keyed only by the excluded
    /// domain, losing the original URL filter (see _WKWebExtensionDeclarativeNetRequestRule.mm). For a rule that
    /// applies on every page that suppresses unrelated blocking for any request containing those domain strings
    /// (root cause of the tracker-script bypass, upstream rule 5154). Rules limited to specific initiator sites
    /// only affect those sites and are kept. Block and redirect rules with `excludedRequestDomains` and no
    /// `initiatorDomains` are omitted (a redirect is a block with a substitute response and is converted the same
    /// way); the JSON is otherwise rewritten unchanged in content.
    static func applyCompatibilityPolicy(to data: Data, path: String) throws -> FilteredRules {
        guard let rules = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Error.ruleFileInvalid(path, "not an array of rules")
        }
        var kept: [[String: Any]] = []
        var omitted: [Int] = []
        kept.reserveCapacity(rules.count)
        for rule in rules {
            if let action = rule["action"] as? [String: Any], let type = action["type"] as? String, type == "block" || type == "redirect",
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

    /// Key for `State.omittedRuleIDs`: the ruleset id for static rules, prefixed by folder for regex and strict-block
    /// rules, which reuse the same ruleset ids.
    static func omissionKey(directory: String, id: String) -> String {
        directory == "rulesets/main" ? id : "\(directory.dropFirst("rulesets/".count))/\(id)"
    }

    // MARK: Rule-data validation

    /// Accepts only the rule data of rulesets declared by the pinned manifest and checks each file's shape.
    /// Redirect targets must already exist in `pinnedPackageURL`, because only rule data is updated.
    static func makeOverlay(from archive: ZipArchive, pinnedManifest: Manifest, pinnedPackageURL: URL, version: String) throws -> RuleOverlay {
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
            if declarativeRuleDirectories.contains(directory) {
                try validateDeclarativeRules(data, path: entry.path, packageURL: pinnedPackageURL)
                let filtered = try applyCompatibilityPolicy(to: data, path: entry.path)
                if !filtered.omittedRuleIDs.isEmpty { omitted[omissionKey(directory: directory, id: id)] = filtered.omittedRuleIDs }
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

    static func validateDeclarativeRules(_ data: Data, path: String, packageURL: URL) throws {
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
            if let redirect = action["redirect"] as? [String: Any], let extensionPath = redirect["extensionPath"] as? String {
                guard !extensionPath.contains("..") else { throw Error.ruleFileInvalid(path, "unsafe redirect in rule \(id)") }
                let resource = packageURL.appendingPathComponent(String(extensionPath.drop { $0 == "/" }))
                guard FileManager.default.fileExists(atPath: resource.path) else {
                    throw Error.ruleFileInvalid(path, "rule \(id) redirects to \(extensionPath), which the pinned package does not contain")
                }
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
    /// All or nothing: if any move or the state write fails, the moves already made are undone, the update
    /// stays pending, and the error is rethrown.
    func applyPending() throws -> State {
        let fileManager = FileManager.default
        guard var state = loadState(), let version = state.pendingRulesVersion, fileManager.fileExists(atPath: pendingURL.path) else {
            throw Error.nothingPending
        }
        try? fileManager.removeItem(at: previousURL)
        var moved: [String] = []
        do {
            for directory in Self.ruleDataDirectories + [Self.ruleDetailsPath] {
                let source = pendingURL.appendingPathComponent(directory)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let target = activeURL.appendingPathComponent(directory)
                let backup = previousURL.appendingPathComponent(directory)
                try fileManager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: target.path) { try fileManager.moveItem(at: target, to: backup) }
                do {
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: source, to: target)
                } catch {
                    if fileManager.fileExists(atPath: backup.path), !fileManager.fileExists(atPath: target.path) {
                        try? fileManager.moveItem(at: backup, to: target)
                    }
                    throw error
                }
                moved.append(directory)
            }
            var applied = state
            applied.previousRulesVersion = state.rulesVersion
            applied.rulesVersion = version
            applied.appliedRulesVersion = version
            applied.pendingRulesVersion = nil
            applied.pendingDigest = nil
            try save(applied)
            state = applied
        } catch {
            for directory in moved.reversed() {
                let source = pendingURL.appendingPathComponent(directory)
                let target = activeURL.appendingPathComponent(directory)
                let backup = previousURL.appendingPathComponent(directory)
                try? fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.moveItem(at: target, to: source)
                if fileManager.fileExists(atPath: backup.path) { try? fileManager.moveItem(at: backup, to: target) }
            }
            try? fileManager.removeItem(at: previousURL)
            throw error
        }
        try? fileManager.removeItem(at: pendingURL)
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
