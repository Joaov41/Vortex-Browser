import Foundation
import Combine

enum PageWatchStoreError: Error, Equatable, LocalizedError {
    case invalidWatch
    case watchLimitReached
    case missingWatch
    case corruptData
    case unsupportedVersion(Int)
    case readFailed
    case writeFailed
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidWatch: return "The page watch needs a title and a web address (HTTP or HTTPS)."
        case .watchLimitReached: return "Vortyra can watch up to \(PageWatch.maximumWatches) pages. Delete a page watch before adding another."
        case .missingWatch: return "That page watch no longer exists."
        case .corruptData: return "Page watches could not be read; existing data was left unchanged."
        case .unsupportedVersion: return "Page watches use an unsupported format; existing data was left unchanged."
        case .readFailed: return "Page watches could not be read."
        case .writeFailed: return "Page watches could not be written; existing data was left unchanged."
        case .appGroupUnavailable: return "Shared storage is unavailable for page watches."
        }
    }
}

private struct PageWatchStoreDocument: Codable {
    static let currentVersion = 1
    var version = currentVersion
    var watches: [PageWatch] = []
}

/// Persists page watches in the app group container, next to the saved-task store.
/// Every write reads and validates the current document first, so unreadable data is never overwritten.
@MainActor
final class PageWatchStore: ObservableObject {
    static let maximumDocumentBytes = 2_000_000

    @Published private(set) var watches: [PageWatch] = []

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws {
        let document = try readDocument()
        publish(document)
    }

    func watch(id: UUID) throws -> PageWatch? {
        try readDocument().watches.first { $0.id == id }
    }

    /// Adds a new watch. Fails when the store already holds the maximum number of watches.
    func addWatch(_ watch: PageWatch) throws {
        guard watch.isValid else { throw PageWatchStoreError.invalidWatch }
        var document = try readDocument()
        guard !document.watches.contains(where: { $0.id == watch.id }) else {
            throw PageWatchStoreError.invalidWatch
        }
        guard document.watches.count < PageWatch.maximumWatches else {
            throw PageWatchStoreError.watchLimitReached
        }
        document.watches.append(watch)
        document.watches.sort { $0.createdAt < $1.createdAt }
        try commit(document)
    }

    /// Replaces an existing watch. The creation date is kept from the stored watch.
    func updateWatch(_ watch: PageWatch) throws {
        guard watch.isValid else { throw PageWatchStoreError.invalidWatch }
        var document = try readDocument()
        guard let index = document.watches.firstIndex(where: { $0.id == watch.id }) else {
            throw PageWatchStoreError.missingWatch
        }
        var replacement = watch
        replacement.createdAt = document.watches[index].createdAt
        document.watches[index] = replacement
        try commit(document)
    }

    func deleteWatch(id: UUID) throws {
        var document = try readDocument()
        document.watches.removeAll { $0.id == id }
        try commit(document)
    }

    private func readDocument() throws -> PageWatchStoreDocument {
        let data: Data
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            if let size = attributes[.size] as? NSNumber,
               size.intValue > Self.maximumDocumentBytes {
                throw PageWatchStoreError.corruptData
            }
            data = try Data(contentsOf: fileURL)
        } catch {
            if let storeError = error as? PageWatchStoreError { throw storeError }
            if let cocoaError = error as? CocoaError, cocoaError.code == .fileReadNoSuchFile {
                return PageWatchStoreDocument()
            }
            throw PageWatchStoreError.readFailed
        }
        guard data.count <= Self.maximumDocumentBytes else {
            throw PageWatchStoreError.corruptData
        }
        let document: PageWatchStoreDocument
        do {
            document = try JSONDecoder().decode(PageWatchStoreDocument.self, from: data)
        } catch {
            throw PageWatchStoreError.corruptData
        }
        guard document.version == PageWatchStoreDocument.currentVersion else {
            throw PageWatchStoreError.unsupportedVersion(document.version)
        }
        do {
            try validate(document)
        } catch {
            throw PageWatchStoreError.corruptData
        }
        return document
    }

    private func validate(_ document: PageWatchStoreDocument) throws {
        guard document.watches.count <= PageWatch.maximumWatches,
              Set(document.watches.map(\.id)).count == document.watches.count,
              document.watches.allSatisfy(\.isValid) else {
            throw PageWatchStoreError.corruptData
        }
    }

    private func commit(_ document: PageWatchStoreDocument) throws {
        do {
            let parent = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            guard data.count <= Self.maximumDocumentBytes else {
                throw PageWatchStoreError.writeFailed
            }
            try data.write(to: fileURL, options: .atomic)
        } catch let error as PageWatchStoreError {
            throw error
        } catch {
            throw PageWatchStoreError.writeFailed
        }
        publish(document)
    }

    private func publish(_ document: PageWatchStoreDocument) {
        watches = document.watches.sorted { $0.createdAt < $1.createdAt }
    }
}

enum PageWatchStoreLocation {
    /// Same app group as the saved-task store, so the widget extension can read watches later.
    static let appGroupIdentifier = "group.com.browser.app"

    static func fileName(bundleIdentifier: String) throws -> String {
        guard isSafeBundleIdentifier(bundleIdentifier) else {
            throw PageWatchStoreError.appGroupUnavailable
        }
        return "PageWatches.\(bundleIdentifier).json"
    }

    static func fileURL(containerURL: URL, bundleIdentifier: String) throws -> URL {
        containerURL.appendingPathComponent(try fileName(bundleIdentifier: bundleIdentifier), isDirectory: false)
    }

    static func isSafeBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                return (65...90).contains(value) || (97...122).contains(value)
                    || (48...57).contains(value) || value == 45
            }
        }
    }

    @MainActor
    static func makeDefaultStore(
        bundleIdentifier: String? = nil,
        fileManager: FileManager = .default
    ) throws -> PageWatchStore {
        guard let bundleIdentifier = bundleIdentifier ?? Bundle.main.bundleIdentifier,
              let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw PageWatchStoreError.appGroupUnavailable
        }
        return PageWatchStore(fileURL: try fileURL(containerURL: container, bundleIdentifier: bundleIdentifier), fileManager: fileManager)
    }
}
