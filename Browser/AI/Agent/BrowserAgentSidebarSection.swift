//
//  BrowserAgentSidebarSection.swift
//  Vortex
//
//  Agent mode's part of the AI sidebar while a run is in progress: the step
//  log and the approval card for risky actions. When the run ends its answer
//  moves into the normal conversation.
//

import SwiftUI

struct BrowserAgentSidebarSection: View {
    @ObservedObject var agent: BrowserAgentController
    let isDark: Bool
    let fontSize: CGFloat
    @State private var questionDraft = ""

    private var primaryText: Color { isDark ? .white : .black }
    private var secondaryText: Color { isDark ? Color.white.opacity(0.75) : Color.black.opacity(0.6) }
    private var rowBackground: Color { isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agent.steps) { step in
                        stepRow(step)
                            .id(step.id)
                    }
                    if let confirmation = agent.pendingConfirmation {
                        confirmationCard(confirmation)
                            .id(confirmation.id)
                    } else if let question = agent.pendingQuestion {
                        questionCard(question)
                            .id(question.id)
                    } else if agent.isRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Working…")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(secondaryText)
                        }
                        .padding(.horizontal, 6)
                        .id("working")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: agent.steps.count) { _, _ in
                scrollToEnd(proxy)
            }
            .onChange(of: agent.pendingConfirmation) { _, _ in
                scrollToEnd(proxy)
            }
            .onChange(of: agent.pendingQuestion?.id) { _, _ in
                questionDraft = ""
                scrollToEnd(proxy)
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if let confirmation = agent.pendingConfirmation {
                proxy.scrollTo(confirmation.id, anchor: .bottom)
            } else if let question = agent.pendingQuestion {
                proxy.scrollTo(question.id, anchor: .bottom)
            } else if let last = agent.steps.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func stepRow(_ step: BrowserAgentController.Step) -> some View {
        switch step.kind {
        case .task:
            Text(step.text)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(primaryText)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(rowBackground))
                .textSelection(.enabled)
        case .answer:
            Text(step.text)
                .font(.system(size: fontSize))
                .foregroundColor(primaryText)
                .lineSpacing(4)
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .action, .note, .error:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(for: step.kind))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(step.kind == .error ? .red : secondaryText)
                    .frame(width: 16)
                Text(step.text)
                    .font(.caption)
                    .foregroundColor(step.kind == .error ? .red : secondaryText)
                    .lineLimit(step.kind == .action ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
        }
    }

    private func icon(for kind: BrowserAgentController.Step.Kind) -> String {
        switch kind {
        case .action: return "cursorarrow.click"
        case .note: return "text.bubble"
        case .error: return "exclamationmark.triangle"
        case .task, .answer: return "sparkles"
        }
    }

    private func confirmationCard(_ confirmation: BrowserAgentController.Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approve this action?", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(primaryText)
            Text(confirmation.summary)
                .font(.callout)
                .foregroundColor(primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Flagged as: \(confirmation.reason)")
                .font(.caption)
                .foregroundColor(secondaryText)
            HStack(spacing: 10) {
                Button(role: .cancel) {
                    agent.resolveConfirmation(id: confirmation.id, allowed: false)
                } label: {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if confirmation.allowsSiteTrust {
                    Button {
                        agent.resolveConfirmation(id: confirmation.id, allowed: true, alwaysAllow: true)
                    } label: {
                        Text("Always on site")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    agent.resolveConfirmation(id: confirmation.id, allowed: true)
                } label: {
                    Text("Allow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(isDark ? 0.18 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
        )
    }

    private func questionCard(_ question: BrowserAgentController.UserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your input", systemImage: "questionmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(primaryText)
            Text(question.prompt)
                .font(.callout)
                .foregroundColor(primaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Type your answer", text: $questionDraft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit { sendQuestionAnswer(for: question.id) }
            HStack(spacing: 10) {
                Button(role: .cancel) {
                    guard agent.pendingQuestion?.id == question.id else { return }
                    questionDraft = ""
                    agent.resolveUserQuestion(nil, id: question.id)
                } label: {
                    Text("Skip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { sendQuestionAnswer(for: question.id) } label: {
                    Text("Send")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.regular)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(isDark ? 0.18 : 0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
        )
    }

    private func sendQuestionAnswer(for questionID: UUID) {
        guard agent.pendingQuestion?.id == questionID else { return }
        let answer = questionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        questionDraft = ""
        agent.resolveUserQuestion(answer, id: questionID)
    }
}
