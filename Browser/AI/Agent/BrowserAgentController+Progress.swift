//
//  BrowserAgentController+Progress.swift
//  Vortex
//
//  Reports run progress to surfaces outside the app, such as the Live Activity.
//  Private runs report the step count only: their task and page text stay empty.
//

import Foundation

/// One moment of a run, as shown outside the app. The text fields are empty for private runs.
struct BrowserAgentRunProgress: Equatable {
    let runID: UUID
    let taskTitle: String
    let stepText: String
    /// Tool calls the model has made in this run.
    let stepCount: Int
    let maximumSteps: Int
    let isPrivate: Bool
    let isWaitingForUser: Bool
}

@MainActor
protocol BrowserAgentRunObserver: AnyObject {
    func agentRunDidStart(_ progress: BrowserAgentRunProgress)
    func agentRunDidProgress(_ progress: BrowserAgentRunProgress)
    /// `outcome` is the first line of the result, or empty for private runs.
    func agentRunDidEnd(_ progress: BrowserAgentRunProgress, status: AgentRunStatus, outcome: String)
}

extension BrowserAgentController {
    static let progressTextCharacters = 140

    /// Nil when no run is active.
    var currentRunProgress: BrowserAgentRunProgress? {
        guard isRunning, let context = runContext else { return nil }
        let isPrivate = context.isPrivate || runIsPrivate
        let latestStep = steps.last { $0.kind == .action || $0.kind == .note || $0.kind == .error }?.text ?? ""
        return BrowserAgentRunProgress(
            runID: context.id,
            taskTitle: isPrivate ? "" : Self.progressLine(context.task),
            stepText: isPrivate ? "" : Self.progressLine(latestStep),
            stepCount: runToolCallCount,
            maximumSteps: runProfile?.maxSteps ?? Self.maxSteps,
            isPrivate: isPrivate,
            isWaitingForUser: pendingConfirmation != nil || pendingQuestion != nil
        )
    }

    func reportRunStarted() {
        guard let runObserver, let progress = currentRunProgress else { return }
        runObserver.agentRunDidStart(progress)
    }

    func reportRunProgress() {
        guard let runObserver, let progress = currentRunProgress else { return }
        runObserver.agentRunDidProgress(progress)
    }

    func reportRunEnded(_ progress: BrowserAgentRunProgress?, completion: CompletionSnapshot) {
        guard let runObserver, let progress else { return }
        runObserver.agentRunDidEnd(
            progress,
            status: completion.status,
            outcome: progress.isPrivate ? "" : Self.progressLine(completion.outcome)
        )
    }

    /// The first non-empty line, trimmed and bounded.
    static func progressLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(line.prefix(progressTextCharacters))
    }
}
