import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

enum BrowserDownloadPolicyDecision: Equatable {
    case allow
    case download
    case cancel
}

/// Pure policy decisions used by the WebKit delegate and unit tests.
enum BrowserDownloadPolicy {
    static func navigationActionDecision(
        shouldPerformDownload: Bool,
        scheme: String?,
        isIncognito: Bool
    ) -> BrowserDownloadPolicyDecision {
        guard shouldPerformDownload else { return .allow }
        if isIncognito && !allowsIncognitoDownloadScheme(scheme) {
            return .cancel
        }
        return .download
    }

    static func navigationResponseDecision(
        canShowMIMEType: Bool,
        contentDisposition: String?,
        scheme: String?,
        isIncognito: Bool
    ) -> BrowserDownloadPolicyDecision {
        let isAttachment = contentDispositionIndicatesAttachment(contentDisposition)
        guard isAttachment || !canShowMIMEType else { return .allow }
        if isIncognito && !allowsIncognitoDownloadScheme(scheme) {
            return .cancel
        }
        return .download
    }

    static func contentDispositionIndicatesAttachment(_ value: String?) -> Bool {
        guard let value else { return false }
        let token = value
            .split(separator: ";", omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return token == "attachment"
    }

    static func contentDispositionHeader(from response: URLResponse) -> String? {
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        return contentDispositionHeader(from: httpResponse.allHeaderFields)
    }

    static func contentDispositionHeader(from headers: [AnyHashable: Any]) -> String? {
        for (key, value) in headers {
            let keyString: String
            if let stringKey = key as? String {
                keyString = stringKey
            } else if let stringKey = key as? NSString {
                keyString = stringKey as String
            } else {
                continue
            }
            guard keyString.caseInsensitiveCompare("Content-Disposition") == .orderedSame else {
                continue
            }
            if let stringValue = value as? String {
                return stringValue
            }
            if let stringValue = value as? NSString {
                return stringValue as String
            }
            return String(describing: value)
        }
        return nil
    }

    static func allowsIncognitoDownloadScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "blob"
    }
}

enum BrowserDownloadState: Equatable {
    case downloading
    case exportPending
    case completed
    case failed
    case cancelled
}

struct BrowserDownloadItem: Identifiable, Equatable {
    let id: UUID
    var filename: String
    let sourceURL: URL?
    let isIncognito: Bool
    var state: BrowserDownloadState
    var progress: Double
    var temporaryFileURL: URL?
    var failureMessage: String?
}

struct BrowserDownloadExport: Identifiable, Equatable {
    let id: UUID
    let fileURL: URL
    let filename: String
}

@MainActor
final class BrowserDownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    private final class ActiveSessionReference {
        weak var manager: BrowserDownloadManager?
        let sessionPath: String

        init(manager: BrowserDownloadManager, sessionPath: String) {
            self.manager = manager
            self.sessionPath = sessionPath
        }
    }

    private final class LiveDownload {
        let id: UUID
        let download: WKDownload
        let sourceURL: URL?
        let isIncognito: Bool
        var destinationURL: URL?
        var suggestedFilename: String?
        var progressObservation: NSKeyValueObservation?
        var cancellationRequested = false

        init(id: UUID, download: WKDownload, sourceURL: URL?, isIncognito: Bool) {
            self.id = id
            self.download = download
            self.sourceURL = sourceURL
            self.isIncognito = isIncognito
        }
    }

    static let downloadRootComponent = "VortexDownloads"

    @Published private(set) var items: [BrowserDownloadItem] = []
    /// The one export currently presented by the root view. Setting this to nil is also safe when
    /// SwiftUI dismisses a sheet binding before the picker delegate reports cancellation.
    @Published var presentedExport: BrowserDownloadExport?

    let downloadRootURL: URL
    let sessionDirectoryURL: URL

    private let fileManager: FileManager
    private var liveDownloads: [ObjectIdentifier: LiveDownload] = [:]
    private var exportQueue: [UUID] = []
    private var reservedDestinationPaths: Set<String> = []
    private static var activeSessionReferences: [String: [ActiveSessionReference]] = [:]

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let baseTemporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        let root = baseTemporaryDirectory
            .appendingPathComponent(Self.downloadRootComponent, isDirectory: true)
        downloadRootURL = root
        sessionDirectoryURL = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        super.init()

        prepareSessionDirectory()
        registerActiveSessionDirectory()
    }

    var activeItems: [BrowserDownloadItem] {
        items.filter { $0.state == .downloading }
    }

    var failedItems: [BrowserDownloadItem] {
        items.filter { $0.state == .failed }
    }

    var hasVisibleStatus: Bool {
        !activeItems.isEmpty || !failedItems.isEmpty
    }

    func register(
        _ download: WKDownload,
        sourceURL: URL?,
        isIncognito: Bool
    ) {
        let key = ObjectIdentifier(download)
        if let existing = liveDownloads[key] {
            existing.download.delegate = self
            return
        }

        let itemID = UUID()
        let liveDownload = LiveDownload(
            id: itemID,
            download: download,
            sourceURL: sourceURL,
            isIncognito: isIncognito
        )
        liveDownloads[key] = liveDownload
        // WKDownload's delegate is weak. Keep this assignment here as a second guard in addition
        // to the immediate assignment in each WKNavigationDelegate didBecome callback.
        download.delegate = self

        items.append(
            BrowserDownloadItem(
                id: itemID,
                filename: "Download",
                sourceURL: sourceURL,
                isIncognito: isIncognito,
                state: .downloading,
                progress: 0,
                temporaryFileURL: nil,
                failureMessage: nil
            )
        )

        let progress = download.progress
        liveDownload.progressObservation = progress.observe(
            \.fractionCompleted,
            options: [.initial, .new]
        ) { [weak self, weak download] progress, _ in
            guard let self, let download else { return }
            Task { @MainActor in
                self.updateProgress(for: download, value: progress.fractionCompleted)
            }
        }
    }

    func cancelDownload(id: UUID) {
        guard let (key, liveDownload) = liveDownloads.first(where: { $0.value.id == id }) else {
            return
        }
        guard !liveDownload.cancellationRequested else { return }

        liveDownload.cancellationRequested = true
        updateItem(id: id) { item in
            item.state = .cancelled
            item.progress = 0
        }

        liveDownload.download.cancel { [weak self, weak download = liveDownload.download] _ in
            Task { @MainActor in
                guard let self else { return }
                self.finalizeCancellation(for: key, download: download)
            }
        }
    }

    func dismiss(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].state == .failed || items[index].state == .cancelled else { return }
        removeTemporaryFile(at: items[index].temporaryFileURL)
        exportQueue.removeAll { $0 == id }
        items.remove(at: index)
    }

    func finishExport(id: UUID, exported: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].state == .exportPending else { return }

        let temporaryURL = items[index].temporaryFileURL
        removeTemporaryFile(at: temporaryURL)
        items[index].temporaryFileURL = nil
        items[index].state = exported ? .completed : .cancelled
        if !exported {
            items[index].failureMessage = "Export cancelled"
        }
        exportQueue.removeAll { $0 == id }
        if presentedExport?.id == id {
            presentedExport = nil
        }
        advanceExportQueue()
    }

    /// Records a completed file in the manager and queues its native Files export. This is also
    /// useful for deterministic queue tests without constructing a WKDownload instance.
    @discardableResult
    func enqueueCompletedFile(
        at fileURL: URL,
        suggestedFilename: String? = nil,
        sourceURL: URL? = nil,
        isIncognito: Bool = false,
        id: UUID = UUID()
    ) -> UUID? {
        guard fileManager.fileExists(atPath: fileURL.path), isInsideDownloadRoot(fileURL) else {
            return nil
        }
        let filename = Self.sanitizeFilename(suggestedFilename ?? fileURL.lastPathComponent)
        items.append(
            BrowserDownloadItem(
                id: id,
                filename: filename,
                sourceURL: sourceURL,
                isIncognito: isIncognito,
                state: .exportPending,
                progress: 1,
                temporaryFileURL: fileURL,
                failureMessage: nil
            )
        )
        exportQueue.append(id)
        advanceExportQueue()
        return id
    }

    static func sanitizeFilename(_ suggestedFilename: String?) -> String {
        let raw = suggestedFilename ?? ""
        let lastPathComponent = raw
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? raw

        let filteredScalars = lastPathComponent.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
        var filename = String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while filename.hasPrefix(".") && filename != "." && filename != ".." {
            // Leading dots are safe as filename characters, but remove repeated traversal-like
            // prefixes so a suggested name such as "../../report.pdf" cannot remain ambiguous.
            filename.removeFirst()
        }
        if filename.isEmpty || filename == "." || filename == ".." {
            filename = "download"
        }

        let maxLength = 180
        if filename.count > maxLength {
            let ext = (filename as NSString).pathExtension
            if !ext.isEmpty {
                let extensionLength = min(ext.count, maxLength - 2)
                let boundedExtension = String(ext.prefix(extensionLength))
                let suffix = ".\(boundedExtension)"
                let prefixLength = max(1, maxLength - suffix.count)
                filename = String(filename.prefix(prefixLength)) + suffix
            } else {
                filename = String(filename.prefix(maxLength))
            }
        }
        return filename
    }

    func uniqueDestinationURL(for suggestedFilename: String) -> URL {
        reserveUniqueDestinationURL(for: suggestedFilename)
    }

    private func reserveUniqueDestinationURL(for suggestedFilename: String) -> URL {
        let safeFilename = Self.sanitizeFilename(suggestedFilename)
        let name = (safeFilename as NSString).deletingPathExtension
        let ext = (safeFilename as NSString).pathExtension

        func candidate(_ index: Int) -> URL {
            let stem = index == 1 ? name : "\(name) (\(index))"
            let filename = ext.isEmpty ? stem : "\(stem).\(ext)"
            return sessionDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        }

        var index = 1
        var destination = candidate(index)
        while fileManager.fileExists(atPath: destination.path) || isDestinationReserved(destination) {
            index += 1
            destination = candidate(index)
        }
        reservedDestinationPaths.insert(normalizedPath(for: destination))
        return destination
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let key = ObjectIdentifier(download)
        guard let liveDownload = liveDownloads[key] else {
            completionHandler(nil)
            return
        }

        if let previousDestination = liveDownload.destinationURL {
            releaseDestinationReservation(for: previousDestination)
        }
        let destinationURL = reserveUniqueDestinationURL(for: suggestedFilename)
        liveDownload.suggestedFilename = Self.sanitizeFilename(suggestedFilename)
        liveDownload.destinationURL = destinationURL
        updateItem(id: liveDownload.id) { item in
            item.temporaryFileURL = destinationURL
            item.failureMessage = nil
            item.state = .downloading
            item.progress = max(0, min(1, download.progress.fractionCompleted))
            item.filename = destinationURL.lastPathComponent
        }
        completionHandler(destinationURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let liveDownload = liveDownloads[key] else { return }

        if liveDownload.cancellationRequested {
            finalizeCancellation(for: key, download: download)
            return
        }

        liveDownload.progressObservation?.invalidate()
        liveDownload.progressObservation = nil
        download.delegate = nil
        releaseDestinationReservation(for: liveDownload.destinationURL)
        liveDownloads.removeValue(forKey: key)

        guard let destinationURL = liveDownload.destinationURL,
              fileManager.fileExists(atPath: destinationURL.path) else {
            markFailure(
                id: liveDownload.id,
                message: "The download completed without a file."
            )
            return
        }

        updateItem(id: liveDownload.id) { item in
            item.state = .exportPending
            item.progress = 1
            item.temporaryFileURL = destinationURL
            item.failureMessage = nil
            item.filename = destinationURL.lastPathComponent
        }
        exportQueue.append(liveDownload.id)
        advanceExportQueue()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard let liveDownload = liveDownloads[key] else { return }

        if liveDownload.cancellationRequested {
            finalizeCancellation(for: key, download: download)
            return
        }

        liveDownload.progressObservation?.invalidate()
        liveDownload.progressObservation = nil
        download.delegate = nil
        liveDownloads.removeValue(forKey: key)
        releaseDestinationReservation(for: liveDownload.destinationURL)
        removeTemporaryFile(at: liveDownload.destinationURL)
        markFailure(id: liveDownload.id, message: error.localizedDescription)
    }

    // MARK: - Internals

    private func prepareSessionDirectory() {
        // Only enumerate and remove direct children beneath the dedicated root. No caller-supplied
        // URL is ever removed, and the current session directory is created only after cleanup.
        try? fileManager.createDirectory(at: downloadRootURL, withIntermediateDirectories: true)
        let activeSessionPaths = Self.activeSessionPaths(for: downloadRootURL)
        if let entries = try? fileManager.contentsOfDirectory(
            at: downloadRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.standardizedFileURL != sessionDirectoryURL.standardizedFileURL {
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      isDirectChildOfDownloadRoot(entry),
                      !activeSessionPaths.contains(normalizedPath(for: entry)) else {
                    continue
                }
                try? fileManager.removeItem(at: entry)
            }
        }
        try? fileManager.createDirectory(at: sessionDirectoryURL, withIntermediateDirectories: true)
    }

    private func registerActiveSessionDirectory() {
        let rootPath = normalizedPath(for: downloadRootURL)
        let sessionPath = normalizedPath(for: sessionDirectoryURL)
        let liveReferences = Self.activeSessionReferences[rootPath, default: []]
            .filter { $0.manager != nil }
        Self.activeSessionReferences[rootPath] = liveReferences + [
            ActiveSessionReference(manager: self, sessionPath: sessionPath)
        ]
    }

    private static func activeSessionPaths(for rootURL: URL) -> Set<String> {
        let rootPath = rootURL.standardizedFileURL.path
        let liveReferences = activeSessionReferences[rootPath, default: []]
            .filter { $0.manager != nil }
        activeSessionReferences[rootPath] = liveReferences
        return Set(liveReferences.map(\.sessionPath))
    }

    private func isDirectChildOfDownloadRoot(_ url: URL) -> Bool {
        let rootPath = downloadRootURL.standardizedFileURL.path
        let entryPath = url.standardizedFileURL.path
        guard entryPath.hasPrefix(rootPath + "/") else { return false }
        return entryPath.dropFirst(rootPath.count + 1).contains("/") == false
    }

    private func isInsideDownloadRoot(_ url: URL) -> Bool {
        let rootPath = downloadRootURL.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private func normalizedPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func isDestinationReserved(_ url: URL) -> Bool {
        reservedDestinationPaths.contains(normalizedPath(for: url))
    }

    private func releaseDestinationReservation(for url: URL?) {
        guard let url else { return }
        reservedDestinationPaths.remove(normalizedPath(for: url))
    }

    private func removeTemporaryFile(at url: URL?) {
        guard let url, isInsideDownloadRoot(url) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func updateProgress(for download: WKDownload, value: Double) {
        guard let liveDownload = liveDownloads[ObjectIdentifier(download)] else { return }
        guard let index = items.firstIndex(where: { $0.id == liveDownload.id }) else { return }
        items[index].progress = max(0, min(1, value))
    }

    private func updateItem(id: UUID, _ update: (inout BrowserDownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        update(&items[index])
    }

    private func markFailure(id: UUID, message: String) {
        updateItem(id: id) { item in
            item.state = .failed
            item.failureMessage = message
            item.progress = 0
            item.temporaryFileURL = nil
        }
    }

    private func finalizeCancellation(for key: ObjectIdentifier, download: WKDownload?) {
        guard let liveDownload = liveDownloads[key] else { return }
        if let download, liveDownload.download !== download {
            return
        }
        liveDownload.progressObservation?.invalidate()
        liveDownload.progressObservation = nil
        liveDownload.download.delegate = nil
        releaseDestinationReservation(for: liveDownload.destinationURL)
        removeTemporaryFile(at: liveDownload.destinationURL)
        liveDownloads.removeValue(forKey: key)
        updateItem(id: liveDownload.id) { item in
            item.state = .cancelled
            item.progress = 0
            item.temporaryFileURL = nil
        }
    }

    private func advanceExportQueue() {
        guard presentedExport == nil else { return }
        while let nextID = exportQueue.first {
            exportQueue.removeFirst()
            guard let item = items.first(where: { $0.id == nextID }),
                  item.state == .exportPending,
                  let fileURL = item.temporaryFileURL,
                  fileManager.fileExists(atPath: fileURL.path) else {
                continue
            }
            presentedExport = BrowserDownloadExport(
                id: item.id,
                fileURL: fileURL,
                filename: item.filename
            )
            return
        }
    }
}

struct BrowserDocumentExportPicker: UIViewControllerRepresentable {
    let fileURL: URL
    let onComplete: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onComplete = onComplete
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onComplete: (Bool) -> Void
        private var didComplete = false

        init(onComplete: @escaping (Bool) -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            complete(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            complete(false)
        }

        private func complete(_ exported: Bool) {
            guard !didComplete else { return }
            didComplete = true
            onComplete(exported)
        }
    }
}

struct BrowserDocumentExportSheet: View {
    let fileURL: URL
    let onComplete: (Bool) -> Void

    var body: some View {
        BrowserDocumentExportPicker(fileURL: fileURL, onComplete: onComplete)
            .ignoresSafeArea()
            .onDisappear {
                // Covers swipe-down/system dismissal paths where UIDocumentPickerDelegate does not
                // receive documentPickerWasCancelled before the SwiftUI sheet disappears.
                onComplete(false)
            }
    }
}

struct BrowserDownloadStatusOverlay: View {
    @ObservedObject var manager: BrowserDownloadManager

    private var primaryItem: BrowserDownloadItem? {
        manager.failedItems.first ?? manager.activeItems.first
    }

    var body: some View {
        if let item = primaryItem {
            HStack(spacing: 10) {
                if item.state == .downloading {
                    ProgressView(value: item.progress, total: 1)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .accessibilityLabel("Download progress")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.state == .downloading ? "Downloading" : "Download failed")
                        .font(.caption.weight(.semibold))
                    Text(item.filename)
                        .font(.caption2)
                        .lineLimit(1)
                    if item.state == .downloading {
                        Text("\(Int(item.progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let failureMessage = item.failureMessage {
                        Text(failureMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 2)

                if item.state == .downloading {
                    Button {
                        manager.cancelDownload(id: item.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel download")
                } else {
                    Button {
                        manager.dismiss(id: item.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss download failure")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 280)
            .glassEffectCompat(
                in: Capsule(),
                material: .ultraThinMaterial,
                strokeOpacity: 0.2
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 84)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }
}
