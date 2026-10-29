//
//  AgentTaskRecorderBanner.swift
//  Vortex
//
//  The visible "Recording — Stop" banner shown while teach mode is active.
//

import SwiftUI

struct AgentTaskRecordingBanner: View {
    @ObservedObject var recorder: AgentTaskRecorder
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text("Recording —")
                .font(.subheadline.weight(.semibold))
            Button("Stop", action: onStop)
                .font(.subheadline.weight(.semibold))
                .accessibilityHint("Ends the recording and opens the save editor")
            Spacer(minLength: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(radius: BrowserDesign.Shadow.controlRadius, y: 4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording a browser task")
    }

    private var statusText: String {
        if recorder.limitReached { return "Step limit reached" }
        return recorder.stepCount == 1 ? "1 step" : "\(recorder.stepCount) steps"
    }
}
