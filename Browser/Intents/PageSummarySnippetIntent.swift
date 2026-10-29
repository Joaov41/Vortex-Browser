import AppIntents
import SwiftUI
import Foundation

/// Display values for the page-summary card. The Open Page button appears only for a plain HTTP(S) page address.
struct PageSummarySnippetModel: Equatable {
    static let emptySummaryText = "Vortyra returned no summary."
    static let maximumTitleCharacters = 240
    static let fallbackTitle = "Current page"

    let title: String
    let domain: String?
    let summaryText: String
    let isSummaryTruncated: Bool
    let pageURL: URL?

    init(pageTitle: String?, pageURL: URL?, summary: String) {
        let allowedURL = pageURL.flatMap { AgentTaskURLParser.isAllowedStartURL($0) ? $0 : nil }
        let host = allowedURL.flatMap { AgentSnippetText.domain(for: $0) }
        let trimmedTitle = (pageTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            self.title = host ?? Self.fallbackTitle
        } else {
            self.title = String(trimmedTitle.prefix(Self.maximumTitleCharacters))
        }
        self.domain = host
        self.pageURL = allowedURL
        let bounded = AgentSnippetText.bounded(summary, emptyText: Self.emptySummaryText)
        self.summaryText = bounded.text
        self.isSummaryTruncated = bounded.isTruncated
    }
}

/// The result card for Summarize Current Page. It shows what the summary step already knows: the page title, its domain and the summary.
struct PageSummarySnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Page Summary Card"
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Page Title")
    var pageTitle: String?

    @Parameter(title: "Page Address")
    var pageAddress: URL?

    @Parameter(title: "Summary")
    var summary: String

    init() {
        self.summary = ""
    }

    init(pageTitle: String?, pageURL: URL?, summary: String) {
        self.pageTitle = pageTitle
        self.pageAddress = pageURL
        self.summary = summary
    }

    var model: PageSummarySnippetModel {
        PageSummarySnippetModel(pageTitle: pageTitle, pageURL: pageAddress, summary: summary)
    }

    @MainActor
    func perform() async throws -> some ShowsSnippetView {
        .result(view: PageSummarySnippetView(model: model))
    }
}
