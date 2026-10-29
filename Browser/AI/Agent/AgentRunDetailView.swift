import SwiftUI

/// Shows what one finished agent run did. Opened from a history row in AgentTaskLibrarySheet.
struct AgentRunDetailView: View {
    let record: AgentRunRecord
    let onRunAgain: () -> Void
    let onSaveAsTask: () -> Void
    @State private var handoffRequest: AgentHandoffRequest?

    var body: some View {
        List {
            Section("Task") {
                Text(record.task)
                    .textSelection(.enabled)
                if let startURL = record.startURL {
                    Label(startURL.host ?? startURL.absoluteString, systemImage: "globe")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Run") {
                LabeledContent("Status", value: record.status?.title ?? "Not recorded")
                LabeledContent("Started") {
                    Text((record.startedAt ?? record.date).formatted(date: .abbreviated, time: .shortened))
                }
                if let durationText = record.durationText {
                    LabeledContent("Duration", value: durationText)
                }
                LabeledContent("Backend", value: AIModelBackend(rawValue: record.backend)?.displayName ?? record.backend)
            }

            Section("Outcome") {
                Text(record.outcome)
                    .textSelection(.enabled)
            }

            Section("Hand Off") {
                AgentResultHandoffRow { action in
                    handoffRequest = AgentHandoffRequest(kind: AgentResultHandoffDraft(record: record).request(for: action))
                }
            }

            Section("Actions") {
                if record.actions.isEmpty {
                    Text("No actions recorded.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(record.actions.enumerated()), id: \.offset) { index, action in
                    Label {
                        Text(action)
                    } icon: {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Approvals") {
                if let approvals = record.approvals {
                    if approvals.isEmpty {
                        Text("No approvals were needed.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(approvals.enumerated()), id: \.offset) { _, approval in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(approval.reason)
                            HStack {
                                if let host = approval.host {
                                    Text(host)
                                    Text("·")
                                }
                                Text(approval.decision.title)
                                Spacer()
                                Text(approval.date, style: .time)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Approvals were not recorded for this run.")
                        .foregroundStyle(.secondary)
                }
            }

            if let questions = record.questions, !questions.isEmpty {
                Section("Questions") {
                    ForEach(questions) { question in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(question.prompt)
                            Text(question.answered ? "Answered" : "Skipped or stopped")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let sources = record.sources, !sources.isEmpty {
                Section("Sources") {
                    ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                        Link(destination: source.url) {
                            Label(source.title, systemImage: "link")
                                .lineLimit(2)
                        }
                    }
                }
            }

            if let exports = record.exports, !exports.isEmpty {
                Section("Files") {
                    ForEach(Array(exports.enumerated()), id: \.offset) { _, export in
                        Label(export.filename, systemImage: export.kind == .pdf ? "doc.richtext" : "tablecells")
                            .lineLimit(2)
                    }
                }
            }

            Section {
                Button {
                    onRunAgain()
                } label: {
                    Label("Run Again", systemImage: "arrow.clockwise")
                }
                Button {
                    onSaveAsTask()
                } label: {
                    Label("Save as Task", systemImage: "square.and.pencil")
                }
            }
        }
        .listStyle(.insetGrouped)
        .agentHandoffSheet($handoffRequest)
        .navigationTitle("Run Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: record.plainTextLog) {
                    Label("Share Log", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Share Log")
            }
        }
    }
}
