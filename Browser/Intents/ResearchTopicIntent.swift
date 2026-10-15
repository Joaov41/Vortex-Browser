import AppIntents
import Foundation

enum ResearchTopicError: Error, Equatable, LocalizedError {
    case emptyTopic

    var errorDescription: String? {
        switch self {
        case .emptyTopic:
            return "Provide a topic to research."
        }
    }
}

/// Builds the browser task text for ResearchTopicIntent. Pure so the wording, bounds and flags can be tested.
enum ResearchTopicTaskBuilder {
    static let topicCharacters = 200
    /// Matches the groupTitle limit of open_sources_in_group, so the named group always fits the tool.
    static let groupNameCharacters = 60

    /// One line, whitespace and control characters collapsed to single spaces, at most 200 characters.
    static func normalizedTopic(_ raw: String) -> String {
        let words = raw
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
            .filter { !$0.isEmpty }
        return String(words.joined(separator: " ").prefix(topicCharacters))
            .trimmingCharacters(in: .whitespaces)
    }

    /// The research preset is chosen by the leading "Research" word, so the text always starts with it.
    static func taskText(topic rawTopic: String, openSourcesInTabs: Bool, makePDF: Bool) throws -> String {
        let topic = normalizedTopic(rawTopic)
        guard !topic.isEmpty else { throw ResearchTopicError.emptyTopic }
        var sentence = "Compare the most relevant sources"
        if openSourcesInTabs {
            let groupName = String(topic.prefix(groupNameCharacters)).trimmingCharacters(in: .whitespaces)
            sentence += ", open them in a tab group named \(groupName)"
        }
        if makePDF {
            sentence += ", and export a PDF report"
        }
        return "Research \(topic). \(sentence)."
    }
}

struct ResearchTopicIntent: AppIntent {
    static let title: LocalizedStringResource = "Research a Topic"
    static let description = IntentDescription(
        "Research a topic in Vortyra. Optionally open the chosen sources in a tab group and export a PDF report. Waits for the result and returns its text and exported files. If the wait times out, the task keeps running in Vortyra."
    )
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Topic", description: "What to research, up to 200 characters")
    var topic: String

    @Parameter(title: "Open Sources in Tabs", description: "Open the chosen sources in a tab group named after the topic", default: true)
    var openSourcesInTabs: Bool

    @Parameter(title: "Make PDF Report", description: "Export the findings as a PDF report", default: true)
    var makePDF: Bool

    @Parameter(
        title: "Timeout (seconds)",
        description: "How long to wait for the result, from 15 to 900 seconds.",
        default: 300,
        inclusiveRange: (15, 900)
    )
    var timeoutSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Research \(\.$topic) and get the result")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AgentRunResultEntity> & ProvidesDialog & ShowsSnippetIntent {
        let queued = try await MainActor.run { () throws -> (request: PendingAgentTask, title: String) in
            let text = try ResearchTopicTaskBuilder.taskText(
                topic: topic,
                openSourcesInTabs: openSourcesInTabs,
                makePDF: makePDF
            )
            let request = PendingAgentTask(task: text)
            try AgentTaskIntentRuntime.enqueue(request)
            let title = AgentRunResultIntentSupport.title(forTask: "Research \(ResearchTopicTaskBuilder.normalizedTopic(topic))")
            return (request, title)
        }
        let outcome = await AgentRunCompletionBroker.shared.wait(
            for: queued.request.id,
            timeout: AgentRunResultIntentSupport.waitTimeout(seconds: timeoutSeconds)
        )
        let result = AgentRunResultIntentSupport.makeResult(for: outcome, taskTitle: queued.title)
        return .result(value: result.entity, dialog: IntentDialog(stringLiteral: result.dialog), snippetIntent: result.snippet)
    }
}
