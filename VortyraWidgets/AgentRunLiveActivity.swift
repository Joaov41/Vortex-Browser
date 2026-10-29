import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island views for a running browser task. The app starts, updates and
/// ends the activity; this extension only draws what the app sends.
struct AgentRunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentRunActivityAttributes.self) { context in
            AgentRunLockScreenView(title: context.attributes.taskTitle, state: context.state)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AgentRunPhaseIcon(phase: context.state.phase)
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AgentRunStepCount(state: context.state)
                        .font(.callout.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.taskTitle)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.stepText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        ProgressView(value: context.state.fractionComplete)
                    }
                }
            } compactLeading: {
                AgentRunPhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                Text("\(context.state.stepCount)")
                    .font(.caption.monospacedDigit())
            } minimal: {
                AgentRunPhaseIcon(phase: context.state.phase)
            }
        }
    }
}

struct AgentRunLockScreenView: View {
    let title: String
    let state: AgentRunActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentRunPhaseIcon(phase: state.phase)
                    .font(.headline)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                AgentRunStepCount(state: state)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(state.stepText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ProgressView(value: state.fractionComplete)
        }
        .padding()
    }
}

struct AgentRunStepCount: View {
    let state: AgentRunActivityAttributes.ContentState

    var body: some View {
        Text("Step \(state.stepCount) of \(state.maximumSteps)")
            .accessibilityLabel("Step \(state.stepCount) of \(state.maximumSteps)")
    }
}

struct AgentRunPhaseIcon: View {
    let phase: AgentRunActivityAttributes.ContentState.Phase

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(tint)
            .accessibilityLabel(label)
    }

    private var symbolName: String {
        switch phase {
        case .working: return "sparkles"
        case .waitingForYou: return "hand.raised.fill"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle.fill"
        }
    }

    private var tint: Color {
        switch phase {
        case .working: return .accentColor
        case .waitingForYou: return .orange
        case .finished: return .green
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var label: String {
        switch phase {
        case .working: return "Working"
        case .waitingForYou: return "Waiting for you"
        case .finished: return "Finished"
        case .failed: return "Couldn't finish"
        case .stopped: return "Stopped"
        }
    }
}
