import SwiftUI

/// The AI page in Settings: the few choices most people need up top, with
/// sign-in, agent details and on-device models one level down in Advanced.
struct AISettingsView: View {
    let isChatGPTSignedIn: Bool
    let isGeminiSignedIn: Bool
    let webAIStatusMessage: String?
    @Binding var isLoadingMLXModel: Bool
    @Binding var mlxDownloadProgress: Progress?
    @Binding var mlxLoadError: String?
    let onSignIn: (WebAIProvider) -> Void
    let onSignOut: (WebAIProvider) -> Void
    /// Model id plus destination folder; a nil folder downloads into app storage.
    let onDownloadMLXModel: (String, URL?) -> Void
    let onCancelMLXDownload: () -> Void

    // Same instance and keys as the AI sidebar, so a choice made here shows up there.
    @ObservedObject private var aiService = SimpleAIService.shared
    @AppStorage("browserAgentMode") private var isAgentMode = false
    @AppStorage("aiReadVoiceRepliesAloud") private var readVoiceRepliesAloud = true

    private var mlxAvailable: Bool {
        MLXLocalService.isAvailable()
    }

    private var userSelectableBackends: [AIModelBackend] {
        AIModelBackend.allCases.filter(\.isSelectable)
    }

    /// Matches the titles in the AI sidebar's model menu.
    static func modelMenuTitle(for backend: AIModelBackend) -> String {
        switch backend {
        case .localApple:
            return "Apple Local"
        case .cloudShortcuts:
            return "Private Cloud Compute"
        case .webChatGPT:
            return "ChatGPT (free account)"
        case .webGemini:
            return "Gemini (free account)"
        case .chatGPTPlan:
            return "ChatGPT Plan"
        default:
            return backend.displayName
        }
    }

    /// The model needs a sign-in that hasn't happened yet.
    private var needsSignIn: Bool {
        switch aiService.backend {
        case .webChatGPT:
            return !isChatGPTSignedIn
        case .webGemini:
            return !isGeminiSignedIn
        default:
            return false
        }
    }

    private var agentModelNames: String {
        userSelectableBackends
            .filter { BrowserAgentEngineSelection.canOfferAgent(for: $0) }
            .map { Self.modelMenuTitle(for: $0) }
            .formatted(.list(type: .or))
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $aiService.backend) {
                    ForEach(userSelectableBackends, id: \.self) { backend in
                        Text(Self.modelMenuTitle(for: backend))
                            .tag(backend)
                            .disabled(backend == .mlxLocal && !mlxAvailable)
                    }
                } label: {
                    Label("Model", systemImage: "switch.2")
                }
            } footer: {
                if needsSignIn {
                    Text("Sign in to \(aiService.backend.displayName) in Advanced below to use it.")
                } else {
                    Text("The AI that answers your questions about pages.")
                }
            }

            Section {
                Toggle(isOn: $isAgentMode) {
                    Label("Let the agent act on pages", systemImage: "cursorarrow.click.2")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The assistant can click, type and move between pages to finish a task for you. It asks before steps that need your OK.")
                    if isAgentMode && !BrowserAgentEngineSelection.canOfferAgent(for: aiService.backend) {
                        Text("Works with \(agentModelNames).")
                    }
                }
            }

            Section {
                Toggle(isOn: $readVoiceRepliesAloud) {
                    Label("Read voice answers aloud", systemImage: "speaker.wave.2")
                }
            } footer: {
                Text("When you ask by voice, the answer is spoken as well as shown.")
            }

            Section {
                NavigationLink {
                    AIAdvancedSettingsView(
                        isChatGPTSignedIn: isChatGPTSignedIn,
                        isGeminiSignedIn: isGeminiSignedIn,
                        webAIStatusMessage: webAIStatusMessage,
                        isLoadingMLXModel: $isLoadingMLXModel,
                        mlxDownloadProgress: $mlxDownloadProgress,
                        mlxLoadError: $mlxLoadError,
                        onSignIn: onSignIn,
                        onSignOut: onSignOut,
                        onDownloadMLXModel: onDownloadMLXModel,
                        onCancelMLXDownload: onCancelMLXDownload
                    )
                } label: {
                    Label("Advanced", systemImage: "gearshape.2")
                }
            } footer: {
                Text("Sign-in, site permissions, autofill, task alerts and on-device models.")
            }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AIAdvancedSettingsView: View {
    let isChatGPTSignedIn: Bool
    let isGeminiSignedIn: Bool
    let webAIStatusMessage: String?
    @Binding var isLoadingMLXModel: Bool
    @Binding var mlxDownloadProgress: Progress?
    @Binding var mlxLoadError: String?
    let onSignIn: (WebAIProvider) -> Void
    let onSignOut: (WebAIProvider) -> Void
    let onDownloadMLXModel: (String, URL?) -> Void
    let onCancelMLXDownload: () -> Void

    @AppStorage(AgentRunLiveActivitySettings.enabledKey) private var agentLiveActivity = true
    @AppStorage(AgentRunFinishNotification.enabledKey) private var agentShortcutNotifications = true

    var body: some View {
        Form {
            accountsSection
            agentSection
            agentTasksSection
            onDeviceSection
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var accountsSection: some View {
        Section {
            webAIAccountRow(for: .chatgpt, isSignedIn: isChatGPTSignedIn)
            webAIAccountRow(for: .gemini, isSignedIn: isGeminiSignedIn)
            if ChatGPTPlanAvailability.isEnabled {
                NavigationLink {
                    ChatGPTPlanSettingsView()
                } label: {
                    Label("ChatGPT Plan", systemImage: "person.badge.key")
                }
            }
        } header: {
            Text("AI Accounts")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in inside Vortyra so the in-app ChatGPT and Gemini assistants reuse your session.")
                if let webAIStatusMessage, !webAIStatusMessage.isEmpty {
                    Text(webAIStatusMessage)
                }
            }
        }
    }

    private var agentSection: some View {
        Section("Agent") {
            NavigationLink {
                AgentSitePermissionsView()
            } label: {
                Label("Agent Site Permissions", systemImage: "hand.raised")
            }
            NavigationLink {
                AutofillProfileSettingsView(service: .shared)
            } label: {
                Label("Autofill Profile", systemImage: "person.text.rectangle")
            }
        }
    }

    private var agentTasksSection: some View {
        Section {
            Toggle(isOn: $agentLiveActivity) {
                Label("Live Activity While Running", systemImage: "sparkles.rectangle.stack")
            }
            Toggle(isOn: $agentShortcutNotifications) {
                Label("Notify When Shortcuts Tasks Finish", systemImage: "bell.badge")
            }
        } header: {
            Text("Browser Tasks")
        } footer: {
            Text("The Live Activity shows a running task's steps on the Lock Screen and in the Dynamic Island. Tasks started from Shortcuts or Siri can notify you when they finish. Private tasks never show page text: their notification says only \"Finished\".")
        }
    }

    private var onDeviceSection: some View {
        Section("On This Device") {
            NavigationLink {
                MLXAdvancedSettingsView(
                    isLoadingModel: $isLoadingMLXModel,
                    downloadProgress: $mlxDownloadProgress,
                    loadError: $mlxLoadError,
                    onDownload: onDownloadMLXModel,
                    onCancelDownload: onCancelMLXDownload
                )
            } label: {
                Label("On-Device Models (MLX)", systemImage: "cpu")
            }
        }
    }

    private func webAIAccountRow(for provider: WebAIProvider, isSignedIn: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Label(
                    isSignedIn ? "Signed in" : "Not signed in",
                    systemImage: isSignedIn ? "checkmark.circle.fill" : "circle.dashed"
                )
                .font(.caption)
                .foregroundStyle(isSignedIn ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
            Spacer()
            if isSignedIn {
                Button("Sign Out", role: .destructive) {
                    onSignOut(provider)
                }
                .accessibilityLabel("Sign out of \(provider.displayName)")
            } else {
                Button("Sign In") {
                    onSignIn(provider)
                }
                .accessibilityLabel("Sign in to \(provider.displayName)")
            }
        }
        .buttonStyle(.borderless)
    }
}
