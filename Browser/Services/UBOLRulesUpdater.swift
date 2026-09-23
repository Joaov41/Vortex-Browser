import Combine
import Foundation

/// Network-rules-only updates for the bundled uBlock Origin Lite package.
///
/// Daily: one request to GitHub's releases API to learn whether a newer official release exists.
/// On the user's request: download that release archive, verify it against GitHub's published SHA-256
/// digest, keep only the rule *data* for the rulesets declared by the pinned manifest, validate it, and
/// stage it. Applying is a separate user action handled by `UBlockLiteService`.
@MainActor
final class UBOLRulesUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, downloading, applying
    }

    struct Release: Equatable {
        let tag: String
        let downloadURL: URL
        let sha256: String
        let size: Int
    }

    enum Error: Swift.Error, LocalizedError {
        case badResponse(String), assetMissing(String), digestMissing, digestMismatch, tooLarge(Int), rejectedRelease(String)
        var errorDescription: String? {
            switch self {
            case .badResponse(let detail): "GitHub did not return a usable release: \(detail)."
            case .assetMissing(let tag): "Release \(tag) has no Safari package."
            case .digestMissing: "GitHub published no SHA-256 digest for the package, so it cannot be verified."
            case .digestMismatch: "The downloaded package does not match GitHub's published digest."
            case .tooLarge(let size): "The package is unexpectedly large (\(size) bytes)."
            case .rejectedRelease(let tag): "Release \(tag) was rejected earlier after failing to load."
            }
        }
    }

    static let releasesURL: URL = {
        #if DEBUG
        // `--ubol-releases-url=<url>` points the updater at a synthetic release for pipeline tests.
        if let override = ProcessInfo.processInfo.arguments.lazy.compactMap({ $0.hasPrefix("--ubol-releases-url=") ? URL(string: String($0.dropFirst("--ubol-releases-url=".count))) : nil }).first {
            return override
        }
        #endif
        return URL(string: "https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest")!
    }()
    static var allowsInsecureDownloads: Bool {
        #if DEBUG
        return releasesURL.scheme == "http"
        #else
        return false
        #endif
    }
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let maximumArchiveSize = 40 * 1024 * 1024

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var availableRelease: Release?
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastCheck: Date?

    let store: UBOLPackageStore
    private let session: URLSession

    init(store: UBOLPackageStore) {
        self.store = store
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = ["Accept": "application/vnd.github+json", "User-Agent": "Vortex-Lite-Lab"]
        session = URLSession(configuration: configuration)
        lastCheck = store.loadState()?.lastCheck
    }

    /// Runs the daily availability check when it is due. Network activity is limited to one API request.
    func checkIfDue() async {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        await check()
    }

    func check() async {
        guard phase == .idle else { return }
        phase = .checking
        defer { phase = .idle }
        do {
            let release = try await fetchLatestRelease()
            var state = store.loadState()
            state?.lastCheck = Date()
            lastCheck = state?.lastCheck
            let installed = state?.rulesVersion ?? ""
            if release.tag == installed || release.tag == state?.pendingRulesVersion {
                availableRelease = nil
                statusMessage = release.tag == installed ? "Rules are up to date (\(release.tag))." : "Update \(release.tag) is downloaded and ready to apply."
                state?.availableRelease = nil
            } else if state?.rejectedReleases.contains(release.tag) == true {
                availableRelease = nil
                statusMessage = "Release \(release.tag) was rejected earlier after failing to load."
            } else if Self.isNewer(release.tag, than: installed) {
                availableRelease = release
                statusMessage = "Rules update \(release.tag) is available."
                state?.availableRelease = release.tag
            } else {
                availableRelease = nil
                statusMessage = "Rules are up to date (\(installed))."
            }
            if let state { try store.save(state) }
        } catch {
            statusMessage = "Update check failed: \(error.localizedDescription)"
        }
    }

    /// Downloads, verifies, filters and stages the available release. Does not apply it.
    func downloadAndStage() async {
        guard phase == .idle, let release = availableRelease else { return }
        phase = .downloading
        defer { phase = .idle }
        do {
            if store.loadState()?.rejectedReleases.contains(release.tag) == true { throw Error.rejectedRelease(release.tag) }
            guard release.size <= Self.maximumArchiveSize else { throw Error.tooLarge(release.size) }
            statusMessage = "Downloading \(release.tag)…"
            let (fileURL, response) = try await session.download(from: release.downloadURL)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw Error.badResponse("download status") }
            let size = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
            guard size <= Self.maximumArchiveSize else { throw Error.tooLarge(size) }
            statusMessage = "Verifying \(release.tag)…"
            // Hashing, unzipping and validating tens of megabytes stays off the main actor.
            let store = self.store, tag = release.tag, digest = release.sha256
            let omittedCount: Int? = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                // Nothing in the archive is read before it matches GitHub's digest.
                guard UBOLPackageStore.sha256Hex(data) == digest else { return nil }
                let archive = try ZipArchive(data: data)
                let manifest = try UBOLPackageStore.readManifest(at: store.activeURL)
                let overlay = try UBOLPackageStore.makeOverlay(from: archive, pinnedManifest: manifest, pinnedPackageURL: store.activeURL, version: tag)
                try store.stage(overlay, digest: digest)
                return overlay.omittedRuleIDs.values.reduce(0) { $0 + $1.count }
            }.value
            guard let omitted = omittedCount else { throw Error.digestMismatch }
            availableRelease = nil
            statusMessage = "Update \(release.tag) verified and ready to apply" + (omitted > 0 ? " (\(omitted) WebKit-incompatible rules omitted)." : ".")
        } catch {
            statusMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    func markApplying(_ applying: Bool) { phase = applying ? .applying : .idle }
    func setStatus(_ message: String?) { statusMessage = message }

    private func fetchLatestRelease() async throws -> Release {
        let (data, response) = try await session.data(from: Self.releasesURL)
        guard let http = response as? HTTPURLResponse else { throw Error.badResponse("no HTTP response") }
        guard http.statusCode == 200 else { throw Error.badResponse("status \(http.statusCode)") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, !tag.isEmpty,
              let assets = object["assets"] as? [[String: Any]] else { throw Error.badResponse("missing tag or assets") }
        guard let asset = assets.first(where: { ($0["name"] as? String) == "uBOLite_\(tag).safari.zip" }),
              let urlString = asset["browser_download_url"] as? String, let url = URL(string: urlString), url.scheme == "https" || Self.allowsInsecureDownloads,
              let size = asset["size"] as? Int else { throw Error.assetMissing(tag) }
        guard let digest = asset["digest"] as? String, digest.hasPrefix("sha256:"), digest.count == 71 else { throw Error.digestMissing }
        return Release(tag: tag, downloadURL: url, sha256: String(digest.dropFirst(7)).lowercased(), size: size)
    }

    /// uBOL tags are dotted date-based numbers (e.g. 2026.907.2003); compare numerically per component.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? -1 }
        let installedParts = installed.split(separator: ".").map { Int($0) ?? -1 }
        for index in 0..<max(candidateParts.count, installedParts.count) {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < installedParts.count ? installedParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}
