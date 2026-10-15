//
//  BrowserAgentController+DataTools.swift
//  Vortex
//
//  Dataset, comparison and export helpers used by the browser agent's data tools.

import Foundation
import WebKit
import Combine
import UIKit

extension BrowserAgentController {
    func selectedDatasets(_ rawValue: Any?, adapter: BrowserAgentBrowserAdapter) throws -> [BrowserAgentDataset] {
        guard let rawIDs = rawValue as? [String], !rawIDs.isEmpty, rawIDs.count <= 8 else {
            throw BrowserToolFailure.invalidArgument("Provide one to eight dataset UUIDs from this run.")
        }
        var seen = Set<UUID>()
        var selected: [BrowserAgentDataset] = []
        for rawID in rawIDs {
            guard let id = UUID(uuidString: rawID), seen.insert(id).inserted,
                  let dataset = datasets[id] else { throw BrowserToolFailure.missingDataset }
            if let sourceTabID = dataset.sourceTabID {
                try adapter.validateSource(tabID: sourceTabID)
            } else if dataset.kind != .fetchedPage || dataset.fetchedText == nil {
                throw BrowserToolFailure.missingDataset
            }
            selected.append(dataset)
        }
        return selected
    }

    func validateCurrentPage(
        _ webView: WKWebView,
        tabID: UUID,
        pageURL: URL?,
        adapter: BrowserAgentBrowserAdapter,
        token: UUID
    ) throws {
        try Task.checkCancellation()
        guard isCurrentRun(token) else { throw CancellationError() }
        guard try adapter.validate(webView: webView) == tabID, webView.url == pageURL else {
            throw BrowserToolFailure.stalePage
        }
    }

    @discardableResult
    func store(_ incoming: [BrowserAgentDataset]) -> [BrowserAgentDataset] {
        let maximumDatasetCount = 12
        let maximumCharacters = 120_000
        var total = datasetOrder.compactMap { datasets[$0] }.reduce(0) { $0 + $1.characterCount }
        var saved: [BrowserAgentDataset] = []
        for rawDataset in incoming {
            // Redact profile echoes before storage limits or JSON serialization
            // can split an encoded value into an unrecoverable prefix.
            let dataset = autofillPrivacy.sanitized(rawDataset)
            guard datasetOrder.count < maximumDatasetCount,
                  total + dataset.characterCount <= maximumCharacters else { continue }
            datasets[dataset.id] = dataset
            datasetOrder.append(dataset.id)
            total += dataset.characterCount
            saved.append(dataset)
        }
        return saved
    }

    func queueExport(
        data: Data,
        filename: String,
        sourceURL: URL?,
        sourceTabID: UUID,
        adapter: BrowserAgentBrowserAdapter
    ) throws -> UUID {
        guard let runIsIncognito = adapter.runIncognitoMode else { throw BrowserAgentBrowserAdapter.AccessError.runNotStarted }
        try adapter.validateSource(tabID: sourceTabID)
        let queued = try adapter.enqueueExportFile(data: data, filename: filename, sourceURL: sourceURL, sourceTabID: sourceTabID, isIncognito: runIsIncognito)
        recordRunExport(fileURL: queued.fileURL)
        return queued.id
    }

    /// Only files this run wrote through the export path are recorded.
    private func recordRunExport(fileURL: URL) {
        guard let context = runContext, !context.isPrivate,
              runExports.count < AgentTaskStore.maximumExportsPerRun else { return }
        let filename = runHistoryText(
            fileURL.lastPathComponent,
            characters: 240,
            utf8Bytes: AgentTaskStore.maximumRunFilenameUTF8Bytes
        )
        runExports.append(AgentRunExport(
            filename: filename,
            kind: AgentRunExportKind(filename: filename),
            fileURL: fileURL
        ))
    }

    func exportOriginTabID(
        for datasets: [BrowserAgentDataset],
        in webView: WKWebView,
        adapter: BrowserAgentBrowserAdapter
    ) throws -> UUID {
        for dataset in datasets {
            if let sourceTabID = dataset.sourceTabID {
                try adapter.validateSource(tabID: sourceTabID)
                return sourceTabID
            }
            guard dataset.kind == .fetchedPage, dataset.fetchedText != nil else {
                throw BrowserToolFailure.missingDataset
            }
        }
        // Fetched content has no browser-tab identity. Use the current in-scope
        // tab only to queue the existing user-facing Files export.
        return try adapter.validate(webView: webView)
    }

    func waitForRestoredTab(
        _ switched: (webView: WKWebView, tabID: UUID, needsRestoreWait: Bool, expectedURL: URL?),
        token: UUID
    ) async -> Bool {
        guard let expectedURL = switched.expectedURL else { return true }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && isCurrentRun(token) {
            if switched.webView.url?.absoluteString == expectedURL.absoluteString,
               !switched.webView.isLoading {
                if let readiness = try? await callJSON(
                    "return JSON.stringify({ready: document.readyState, hasBody: Boolean(document.body), textLength: (document.body && document.body.innerText || '').trim().length});",
                    [:],
                    in: switched.webView,
                    timeout: 1
                ), isCurrentRun(token), readiness["ready"] as? String == "complete",
                   readiness["hasBody"] as? Bool == true {
                    return true
                }
            }
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return false }
        }
        return false
    }

    func callJSONString(_ script: String, in webView: WKWebView) async throws -> String {
        let response = try await callJSON(script, [:], in: webView)
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    func encode(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    func stringArgument(_ value: Any?) -> String { value as? String ?? "" }

    func bounded(_ value: String, to limit: Int) -> String {
        String(value.replacingOccurrences(of: "\u{0000}", with: "").prefix(limit))
    }

    func comparisonFilename(_ title: String, ext: String) -> String {
        let safe = BrowserDownloadManager.sanitizeFilename(title.isEmpty ? "browser-comparison" : title)
        return "\((safe as NSString).deletingPathExtension).\(ext)"
    }
}
