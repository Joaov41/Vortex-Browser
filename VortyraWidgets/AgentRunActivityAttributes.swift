import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

/// The Live Activity for a running browser task.
///
/// This one file is compiled into both the app, which starts, updates and ends the activity, and
/// VortyraWidgets, which draws it. It carries display text only. The app fills it with generic text
/// for private runs, so no page text from a private tab ever reaches the Lock Screen.
nonisolated struct AgentRunActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        nonisolated enum Phase: String, Codable, Hashable, Sendable {
            case working
            case waitingForYou
            case finished
            case failed
            case stopped
        }

        var phase: Phase
        var stepText: String
        var stepCount: Int
        var maximumSteps: Int

        var isEnded: Bool {
            phase == .finished || phase == .failed || phase == .stopped
        }

        /// Between 0 and 1, for the progress bar.
        var fractionComplete: Double {
            if phase == .finished { return 1 }
            guard maximumSteps > 0 else { return 0 }
            return min(1, max(0, Double(stepCount) / Double(maximumSteps)))
        }
    }

    var taskTitle: String
}
#endif
