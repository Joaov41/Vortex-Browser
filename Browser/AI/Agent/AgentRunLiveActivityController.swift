//
//  AgentRunLiveActivityController.swift
//  Vortex
//
//  Shows a running browser task on the Lock Screen and in the Dynamic Island.
//  The activity starts with the run, follows its steps and ends when the run
//  finishes or stops. Private runs show generic text and the step count only,
//  and their activity is removed as soon as the run ends.
//

import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

enum AgentRunLiveActivitySettings {
    static let enabledKey = "agent.liveActivity.enabled"

    /// On unless the user turned it off in Settings.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// What the app's agent controllers report to: the Live Activity where the system supports one.
    @MainActor
    static var appObserver: (any BrowserAgentRunObserver)? {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        return AgentRunLiveActivityController.shared
        #else
        return nil
        #endif
    }

    /// Ends Live Activities that an earlier launch left behind when it quit during a run.
    @MainActor
    static func endActivitiesFromEarlierLaunches() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        AgentRunLiveActivityController.shared.endActivitiesFromEarlierLaunches()
        #endif
    }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
/// What the activity shows for a run. Kept apart from ActivityKit so it can be tested.
enum AgentRunLiveActivityContent {
    typealias State = AgentRunActivityAttributes.ContentState

    static let privateTitle = "Private browsing task"
    static let fallbackTitle = "Browser task"

    static func title(for progress: BrowserAgentRunProgress) -> String {
        if progress.isPrivate { return privateTitle }
        return progress.taskTitle.isEmpty ? fallbackTitle : progress.taskTitle
    }

    static func state(for progress: BrowserAgentRunProgress) -> State {
        let phase: State.Phase = progress.isWaitingForUser ? .waitingForYou : .working
        let text: String
        if progress.isWaitingForUser {
            text = "Waiting for you in Vortyra"
        } else if progress.isPrivate || progress.stepText.isEmpty {
            text = "Working…"
        } else {
            text = progress.stepText
        }
        return State(phase: phase, stepText: text, stepCount: progress.stepCount, maximumSteps: progress.maximumSteps)
    }

    static func finalState(for progress: BrowserAgentRunProgress, status: AgentRunStatus, outcome: String) -> State {
        let phase: State.Phase
        let generic: String
        switch status {
        case .completed, .unknown:
            phase = .finished
            generic = "Finished"
        case .failed, .stepLimit:
            phase = .failed
            generic = "Couldn't finish"
        case .stopped:
            phase = .stopped
            generic = "Stopped"
        }
        let text = progress.isPrivate || outcome.isEmpty ? generic : outcome
        return State(phase: phase, stepText: text, stepCount: progress.stepCount, maximumSteps: progress.maximumSteps)
    }
}

@MainActor
final class AgentRunLiveActivityController: BrowserAgentRunObserver {
    static let shared = AgentRunLiveActivityController()
    /// Steps can come quickly; the activity is updated at most this often.
    static let updateInterval: Duration = .milliseconds(750)
    /// A finished run stays on the Lock Screen this long. Private runs are removed at once.
    static let endedDismissalDelay: TimeInterval = 15 * 60

    private let isEnabled: @MainActor () -> Bool
    private let areActivitiesAllowed: @MainActor () -> Bool
    private var activities: [UUID: Activity<AgentRunActivityAttributes>] = [:]
    private var latestStates: [UUID: AgentRunActivityAttributes.ContentState] = [:]
    private var sentStates: [UUID: AgentRunActivityAttributes.ContentState] = [:]
    private var updateTasks: [UUID: Task<Void, Never>] = [:]

    init(
        isEnabled: @escaping @MainActor () -> Bool = { AgentRunLiveActivitySettings.isEnabled() },
        areActivitiesAllowed: @escaping @MainActor () -> Bool = { ActivityAuthorizationInfo().areActivitiesEnabled }
    ) {
        self.isEnabled = isEnabled
        self.areActivitiesAllowed = areActivitiesAllowed
    }

    var activeRunCount: Int {
        activities.count
    }

    func agentRunDidStart(_ progress: BrowserAgentRunProgress) {
        guard activities[progress.runID] == nil, isEnabled(), areActivitiesAllowed() else { return }
        let state = AgentRunLiveActivityContent.state(for: progress)
        do {
            let activity = try Activity.request(
                attributes: AgentRunActivityAttributes(taskTitle: AgentRunLiveActivityContent.title(for: progress)),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            activities[progress.runID] = activity
            sentStates[progress.runID] = state
        } catch {
            // The system can refuse an activity; the run carries on without one.
        }
    }

    func agentRunDidProgress(_ progress: BrowserAgentRunProgress) {
        let runID = progress.runID
        guard activities[runID] != nil else { return }
        guard isEnabled() else {
            endActivity(for: runID, finalState: nil, dismissImmediately: true)
            return
        }
        let state = AgentRunLiveActivityContent.state(for: progress)
        latestStates[runID] = state
        guard state != sentStates[runID], updateTasks[runID] == nil else { return }
        updateTasks[runID] = Task { [weak self] in
            try? await Task.sleep(for: Self.updateInterval)
            guard !Task.isCancelled else { return }
            await self?.sendLatestState(for: runID)
        }
    }

    func agentRunDidEnd(_ progress: BrowserAgentRunProgress, status: AgentRunStatus, outcome: String) {
        guard activities[progress.runID] != nil else { return }
        endActivity(
            for: progress.runID,
            finalState: AgentRunLiveActivityContent.finalState(for: progress, status: status, outcome: outcome),
            dismissImmediately: progress.isPrivate
        )
    }

    /// Ends activities left behind by an earlier launch that quit during a run.
    func endActivitiesFromEarlierLaunches() {
        let current = Set(activities.values.map(\.id))
        for activity in Activity<AgentRunActivityAttributes>.activities where !current.contains(activity.id) {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func sendLatestState(for runID: UUID) async {
        updateTasks[runID] = nil
        guard let activity = activities[runID],
              let state = latestStates[runID],
              state != sentStates[runID] else { return }
        sentStates[runID] = state
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    private func endActivity(
        for runID: UUID,
        finalState: AgentRunActivityAttributes.ContentState?,
        dismissImmediately: Bool
    ) {
        updateTasks.removeValue(forKey: runID)?.cancel()
        latestStates[runID] = nil
        sentStates[runID] = nil
        guard let activity = activities.removeValue(forKey: runID) else { return }
        let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = dismissImmediately
            ? .immediate
            : .after(Date().addingTimeInterval(Self.endedDismissalDelay))
        Task { await activity.end(content, dismissalPolicy: policy) }
    }
}
#endif
