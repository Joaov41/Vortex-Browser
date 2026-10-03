//
//  ChatGPTPlanSettingsView.swift
//  Vortex
//
//  Settings → ChatGPT Plan: account, model, reasoning effort and Fast/Normal for
//  the "ChatGPT Plan" model. Shown only in builds installed from Xcode.
//

import SwiftUI

struct ChatGPTPlanSettingsView: View {
    @ObservedObject private var plan = ChatGPTPlanService.shared
    @State private var isCheckingConnection = false
    @State private var connectionStatus: String?
    @State private var customModel = ""

    var body: some View {
        Form {
            Section {
                accountRows
            } header: {
                Text("Account")
            } footer: {
                Text("Runs AI requests on your own ChatGPT Plus or Pro plan. OpenAI allows this for personal apps run locally, so it only appears in builds installed from Xcode.")
            }

            if plan.status == .connected {
                Section {
                    modelRows
                } header: {
                    Text("Model")
                } footer: {
                    if plan.reasoningSupport == .unknown || plan.fastSupport == .unknown {
                        Text("Check Connection confirms which of these options your plan accepts. Options it rejects are hidden.")
                    }
                }

                Section {
                    checkConnectionRow
                }
            }

            if let lastError = plan.lastError {
                Section {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("ChatGPT Plan")
        .task {
            // New models roll out often; reload the account's list each time this opens.
            if plan.status == .connected, !plan.isLoadingModels {
                await plan.refreshModels()
            }
        }
    }

    @ViewBuilder
    private var accountRows: some View {
        switch plan.status {
        case .connected:
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.accountLabel.map { "Signed in as \($0)" } ?? "Signed in")
                Label(
                    plan.planUsageGranted ? "Using ChatGPT plan" : "Plan usage not granted",
                    systemImage: plan.planUsageGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(plan.planUsageGranted ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
            }
            Link("Manage usage", destination: ChatGPTPlanService.manageUsageURL)
            Button("Disconnect", role: .destructive) {
                connectionStatus = nil
                Task { await plan.disconnect() }
            }
        case .connecting:
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for ChatGPT sign-in…")
                    .foregroundStyle(.secondary)
            }
        case .disconnected, .reauthRequired:
            if plan.status == .reauthRequired {
                Text("Your ChatGPT connection expired. Sign in again to keep using your plan.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button {
                Task { await plan.signIn() }
            } label: {
                Label("Sign in with ChatGPT", systemImage: "person.badge.key")
            }
        }
    }

    @ViewBuilder
    private var modelRows: some View {
        HStack {
            if plan.models.isEmpty && customModelSlugs.isEmpty {
                Text(plan.isLoadingModels ? "Loading models…" : "No models loaded")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: Binding(
                    get: { plan.effectiveModel },
                    set: { plan.selectModel($0) }
                )) {
                    ForEach(plan.models) { model in
                        Text(model.displayName).tag(model.slug)
                    }
                    ForEach(customModelSlugs, id: \.self) { slug in
                        Text(slug).tag(slug)
                    }
                }
                .pickerStyle(.menu)
            }

            Button {
                Task { await plan.refreshModels() }
            } label: {
                if plan.isLoadingModels {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(plan.isLoadingModels)
            .accessibilityLabel("Reload models")
        }

        HStack {
            TextField("Other model by name, e.g. gpt-6.1-sol", text: $customModel)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .onSubmit(useCustomModel)
            Button("Use", action: useCustomModel)
                .buttonStyle(.borderless)
                .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        if plan.reasoningSupport != .unsupported {
            Picker("Reasoning", selection: $plan.reasoningEffort) {
                Text(plan.defaultReasoningEffort(forModel: plan.effectiveModel).map { "Default (\(Self.effortLabel($0)))" } ?? "Default")
                    .tag("")
                ForEach(plan.reasoningEfforts(forModel: plan.effectiveModel), id: \.self) { effort in
                    Text(Self.effortLabel(effort)).tag(effort)
                }
            }
            .pickerStyle(.menu)
        }

        if plan.fastSupport != .unsupported, let fastTier = plan.fastTier(forModel: plan.effectiveModel) {
            Picker("Speed", selection: $plan.fastMode) {
                Text("Normal").tag(false)
                Text("Fast").tag(true)
            }
            .pickerStyle(.segmented)

            if plan.fastIgnoredModels.contains(plan.effectiveModel) {
                Text("OpenAI accepts Fast for this model but reports running it at normal speed. Codex shows the same report (openai/codex#30413), so Fast may have no effect here yet.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if plan.fastMode {
                Text(fastTier.description.map { "Fast: \($0)." } ?? "Fast uses priority processing and can use your plan allowance faster.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var checkConnectionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isCheckingConnection = true
                connectionStatus = nil
                Task {
                    connectionStatus = await plan.checkConnection()
                    isCheckingConnection = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isCheckingConnection {
                        ProgressView()
                    }
                    Text("Check Connection")
                }
            }
            .disabled(isCheckingConnection)

            if let connectionStatus {
                Text(connectionStatus)
                    .font(.footnote)
                    .foregroundStyle(connectionStatus.hasPrefix("Connected") ? .green : .red)
            }
        }
    }

    /// Typed-in models that the catalog does not list, plus the current one.
    private var customModelSlugs: [String] {
        var slugs = plan.customModels.filter { slug in !plan.models.contains { $0.slug == slug } }
        let current = plan.selectedModel
        if !current.isEmpty, !plan.models.contains(where: { $0.slug == current }), !slugs.contains(current) {
            slugs.append(current)
        }
        return slugs
    }

    private func useCustomModel() {
        let slug = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return }
        plan.rememberCustomModel(slug)
        plan.selectModel(slug)
        customModel = ""
        connectionStatus = nil
    }

    private static func effortLabel(_ effort: String) -> String {
        switch effort.lowercased() {
        case "xhigh": return "Extra high"
        case "max": return "Max"
        default: return effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}
