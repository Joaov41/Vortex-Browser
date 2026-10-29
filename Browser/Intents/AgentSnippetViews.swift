import AppIntents
import SwiftUI

/// The finished-run card. Text uses Dynamic Type styles and no fixed heights, so large text grows instead of clipping.
struct AgentRunResultSnippetView: View {
    let model: AgentRunSnippetModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.taskTitle)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(model.outcomeText)
                .font(.body)
                .lineLimit(AgentSnippetText.maximumLines)
                .fixedSize(horizontal: false, vertical: true)

            if !model.sourceDomains.isEmpty {
                Label(model.sourceDomains.joined(separator: ", "), systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            if let runID = model.runID {
                Button(intent: OpenAgentRunInVortyraIntent(runID: runID)) {
                    Label("Open in Vortyra", systemImage: "arrow.up.forward.app")
                }
            }
            Button(intent: CopyAgentRunResultIntent(outcome: model.copyableOutcome)) {
                Label("Copy Result", systemImage: "doc.on.doc")
            }
        }
        .buttonStyle(.bordered)
    }
}

/// The page-summary card with an Open Page button that uses the existing open-URL intent.
struct PageSummarySnippetView: View {
    let model: PageSummarySnippetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let domain = model.domain {
                    Label(domain, systemImage: "globe")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(model.summaryText)
                .font(.body)
                .lineLimit(AgentSnippetText.maximumLines)
                .fixedSize(horizontal: false, vertical: true)

            if let pageURL = model.pageURL {
                Button(intent: openPageIntent(for: pageURL)) {
                    Label("Open Page", systemImage: "safari")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openPageIntent(for url: URL) -> OpenBrowserURLIntent {
        let intent = OpenBrowserURLIntent()
        intent.url = url
        return intent
    }
}
