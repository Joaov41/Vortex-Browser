import SwiftUI
import WebKit
import UIKit
import Combine

private func browserAISidebarLog(_ message: @autoclosure () -> String) {
    print("🧭 [AISidebar] \(message())")
}

private extension View {
    @ViewBuilder
    func browserAskAIInputSafetyModifiers() -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            self.writingToolsBehavior(.disabled)
        } else {
            self
        }
    }
}
struct AISidebar: View {
    @ObservedObject var aiService: SimpleAIService
    var onSend: (String) -> Void
    var onDismiss: () -> Void
    var contextOptions: [ContextOption]
    @Binding var selectedContextID: UUID?
    var selectionText: String? = nil
    var contextStatusText: String? = nil
    /// Returns true when the parent has dispatched the resolved summary. A
    /// false result preserves the standalone sidebar enqueue behavior.
    var onSummaryExtraction: ((String, SummaryLength, BrowserAgentPageContextBinding?, PageContentExtractor.ExtractedPageContent?) -> Bool)? = nil
    var onContextSelected: ((UUID) -> Void)? = nil
    var onClearConversation: (() -> Void)? = nil
    var onInputFocusChanged: ((Bool) -> Void)? = nil
    var isPinned: Binding<Bool>? = nil
    /// Lets the browser agent open a new tab next to the one it is working in.
    var onAgentOpenTab: BrowserAgentController.TabOpener? = nil
    var onLookupOpenSource: ((BrowserLookupSource) -> Bool)? = nil
    /// Lets the parent clear model-facing page context before the first saved-profile write.
    var onAgentAutofillQuarantine: BrowserAgentController.AutofillQuarantineHandler? = nil
    /// Optional additive adapter. If the starting context is unsupported, legacy tools still run.
    var browserAgentAdapter: BrowserAgentBrowserAdapter? = nil
    /// E2 task-library hooks are window-local; they never use the app-wide handoff queue.
    var agentTaskStoreProvider: (@MainActor @Sendable () throws -> AgentTaskStore)? = nil
    var onAgentTaskLaunch: ((AgentTaskLaunchRequest) -> Void)? = nil
    var pendingAgentTask: PendingAgentTask? = nil
    var onPendingAgentTaskStarted: ((UUID) -> Void)? = nil
    var onPendingAgentTaskDispatchCheck: ((UUID, WKWebView) -> Bool)? = nil
    var onPendingAgentTaskRejected: ((UUID) -> Void)? = nil
    var agentTaskStatusMessage: String? = nil
    var isAgentTaskSidebarVisible: Bool = true
    var browserActionIsBusy: Bool = false
    var onAgentReadinessChanged: ((Bool, Bool, Bool) -> Void)? = nil
    var onAgentRunCompleted: ((BrowserAgentController.CompletionSnapshot, UUID) -> Void)? = nil
    var onAgentNeedsAttention: (() -> Void)? = nil
    /// Set by the window when a `webmebrowser://run?id=` link arrives; opens the library on that run's detail page.
    var agentRunDetailRequest: AgentRunDetailRequest? = nil
    /// Called once a requested run detail has been presented, so the window can clear its request.
    var onAgentRunDetailRequestHandled: (() -> Void)? = nil
    /// Set by the window when a `webmebrowser://watch?id=` link arrives; opens the library on the Watches tab.
    var agentWatchOpenRequest: AgentWatchOpenRequest? = nil
    /// Called once a requested watch has been presented, so the window can clear its request.
    var onAgentWatchOpenRequestHandled: (() -> Void)? = nil

    @State private var input: String = ""
    @AppStorage("customPrompts") private var customPromptsData: String = "[]"
    @State private var customPrompts: [String] = []
    @State private var showCustomPromptEditor = false
    @State private var newCustomPrompt: String = ""
    @FocusState private var isInputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var scaledAssistantReplyFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var scaledSectionLabelFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var scaledInputFontSize: CGFloat = 18
    @State private var areControlsExpanded = true
    @State private var shouldAutoCollapseAfterNextReply = false
    @State private var showFullConversation = false
    @State private var presentedResponseCanvas: AIResponseCanvasPresentation?
    @StateObject private var agent = BrowserAgentController()
    @AppStorage("browserAgentMode") private var isAgentMode = false
    @State private var agentTaskLibraryPresentation: AgentTaskLibraryPresentation?
    @State private var latestAgentCompletion: AgentCompletionUI?
    @State private var savedAgentReplyIDs: Set<UUID> = []
    @State private var attemptedPendingAgentTaskID: UUID?
    @State private var isSidebarVisible = false

    private struct AgentCompletionUI: Identifiable {
        let snapshot: BrowserAgentController.CompletionSnapshot
        let replyID: UUID
        var id: UUID { replyID }
        var saveAssociation: AgentTaskReplySaveAssociation {
            AgentTaskReplySaveAssociation(
                replyID: replyID,
                task: snapshot.task,
                startURL: snapshot.startURL
            )
        }
    }

    /// Route actions through the chosen engine only for the three supported agent backends.
    private var agentModeActive: Bool {
        isAgentMode && agent.canOfferAgent(for: aiService.backend)
    }

    private var mlxAvailable: Bool {
        MLXLocalService.isAvailable()
    }

    private var userSelectableBackends: [AIModelBackend] {
        AIModelBackend.allCases.filter(\.isSelectable)
    }

    private func modelMenuTitle(for backend: AIModelBackend) -> String {
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

    static func canStartInteractiveAction(
        browserActionIsBusy: Bool,
        aiIsProcessing: Bool,
        agentIsRunning: Bool
    ) -> Bool {
        !browserActionIsBusy && !aiIsProcessing && !agentIsRunning
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var primaryText: Color {
        isDark ? Color.white : Color.black
    }

    private var secondaryText: Color {
        isDark ? Color.white.opacity(0.75) : Color.black.opacity(0.6)
    }

    private var isNativeTouchDevice: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone || UIDevice.current.userInterfaceIdiom == .pad
#else
        false
#endif
    }

    private var isPhone: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
#else
        false
#endif
    }

    private var isIPadInputFocused: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad && isInputFocused
#else
        false
#endif
    }

    private var assistantReplyFontSize: CGFloat {
        isNativeTouchDevice ? scaledAssistantReplyFontSize : 14
    }

    private var conversationLineSpacing: CGFloat {
        isNativeTouchDevice ? 5 : 4
    }

    private var sectionLabelFontSize: CGFloat {
        isNativeTouchDevice ? scaledSectionLabelFontSize : 12
    }

    private var inputFontSize: CGFloat {
        isNativeTouchDevice ? scaledInputFontSize : 14
    }

    private var rowBackground: Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    private var rowEmphasisBackground: Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    private var iconBackground: Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.1)
    }

    private var backendLabel: String {
        if aiService.backend == .mlxLocal && !mlxAvailable {
            return "\(aiService.backend.displayName) (Unavailable)"
        }
        return aiService.backend.displayName
    }

    private var hasConversationContent: Bool {
        hasCompletedAssistantReply || agent.isRunning
    }

    private var hasCompletedAssistantReply: Bool {
        aiService.messages.contains {
            $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var effectiveControlsExpanded: Bool {
        if isIPadInputFocused {
            return false
        }
        if !hasConversationContent {
            return true
        }
        return areControlsExpanded
    }

    private var canToggleControlsVisibility: Bool {
        hasConversationContent && !aiService.isProcessing
    }

    private let panelCornerRadius: CGFloat = 22

    struct ContextOption: Identifiable {
        let id: UUID
        let title: String
        let subtitle: String?
        let webView: WKWebView?
        let isPrivate: Bool
    }

    private var currentContext: ContextOption? {
        if let selected = selectedContextID,
           let match = contextOptions.first(where: { $0.id == selected }) {
            return match
        }
        return contextOptions.first
    }

    private var currentWebView: WKWebView? {
        currentContext?.webView
    }

    private var currentPageContextBinding: BrowserAgentPageContextBinding? {
        guard let context = currentContext,
              let webView = context.webView,
              let url = webView.url else { return nil }
        return BrowserAgentPageContextBinding(tabID: context.id, webView: webView, url: url)
    }

    private var contextOptionIDs: [UUID] {
        contextOptions.map(\.id)
    }

    private var trimmedSelectionText: String? {
        let trimmed = selectionText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var trimmedContextStatusText: String? {
        let trimmed = contextStatusText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        VStack(spacing: 12) {
            headerRow
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
            if let contextStatus = trimmedContextStatusText {
                contextStatusRow(contextStatus)
            }
            if effectiveControlsExpanded {
                controlsSection
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
            }
            if effectiveControlsExpanded {
                Divider()
                    .background(Color.white.opacity(isDark ? 0.15 : 0.2))
            }

            if agent.isRunning {
                BrowserAgentSidebarSection(
                    agent: agent,
                    isDark: isDark,
                    fontSize: assistantReplyFontSize
                )
            } else {
                messagesSection
            }

            Divider()
                .background(Color.white.opacity(isDark ? 0.15 : 0.2))

            inputRow
                .layoutPriority(1)
        }
        .padding(12)
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .glassEffectCompat(
            in: RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous),
            material: .ultraThinMaterial,
            strokeOpacity: isDark ? 0.2 : 0.35,
            isInteractive: false
        )
        .shadow(
            color: Color.black.opacity(isDark ? 0.35 : 0.2),
            radius: 12,
            x: 0,
            y: 6
        )
        .onAppear {
            isSidebarVisible = true
            syncContextSelection()
            loadCustomPrompts()
            publishAgentReadiness(isReady: true)
            startPendingAgentTaskIfPossible()
        }
        .onDisappear {
            isSidebarVisible = false
            publishAgentReadiness(isReady: false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                publishAgentReadiness(isReady: true)
                startPendingAgentTaskIfPossible()
            } else {
                publishAgentReadiness(isReady: false)
            }
        }
        .onChange(of: isAgentTaskSidebarVisible) { _, isVisible in
            publishAgentReadiness(isReady: isVisible)
            if isVisible { startPendingAgentTaskIfPossible() }
            if !isVisible { isInputFocused = false }
        }
        .onChange(of: agent.isRunning) { _, _ in
            publishAgentReadiness(isReady: true)
            startPendingAgentTaskIfPossible()
        }
        .onChange(of: agent.pendingConfirmation?.id) { _, id in
            if id != nil, !isAgentTaskSidebarVisible { onAgentNeedsAttention?() }
        }
        .onChange(of: agent.pendingQuestion?.id) { _, id in
            if id != nil, !isAgentTaskSidebarVisible { onAgentNeedsAttention?() }
        }
        .onChange(of: aiService.isProcessing) { _, _ in
            publishAgentReadiness(isReady: true)
            startPendingAgentTaskIfPossible()
        }
        .onChange(of: aiService.backend) { _, _ in
            cancelAppleInformationRunIfNeeded()
            publishAgentReadiness(isReady: true)
            startPendingAgentTaskIfPossible()
        }
        .onChange(of: currentContext?.isPrivate) { _, _ in
            cancelAppleInformationRunIfNeeded()
        }
        .onChange(of: pendingAgentTask?.id) { _, _ in
            attemptedPendingAgentTaskID = nil
            publishAgentReadiness(isReady: true)
            startPendingAgentTaskIfPossible()
        }
        .onChange(of: contextOptionIDs) { _, _ in
            syncContextSelection()
        }
        .onChange(of: customPrompts) { _, _ in
            persistCustomPrompts()
        }
        .onChange(of: isInputFocused) { _, focused in
            onInputFocusChanged?(focused)
        }
        .onChange(of: aiService.messages) { _, _ in
            if shouldAutoCollapseAfterNextReply && !aiService.isProcessing && hasCompletedAssistantReply {
                areControlsExpanded = false
                shouldAutoCollapseAfterNextReply = false
            }
        }
        .sheet(isPresented: $showFullConversation) {
            AISidebarConversationArchiveSheet(
                messages: aiService.archiveMessages,
                isDark: isDark,
                assistantReplyFontSize: assistantReplyFontSize,
                conversationLineSpacing: conversationLineSpacing,
                onOpenLookupSource: openLookupSource
            )
        }
        .sheet(item: $agentTaskLibraryPresentation) { presentation in
            if let agentTaskStoreProvider {
                let storeProvider: @MainActor @Sendable () throws -> AgentTaskStore = {
                    try agentTaskStoreProvider()
                }
                AgentTaskLibrarySheet(
                    storeProvider: storeProvider,
                    initialDraft: presentation.initialDraft,
                    onRun: { request in onAgentTaskLaunch?(request) },
                    onSavedReply: { id in savedAgentReplyIDs.insert(id) },
                    initialRunID: presentation.initialRunID,
                    initialWatchID: presentation.initialWatchID
                )
            }
        }
        .onAppear {
            presentRequestedRunDetail()
            presentRequestedWatch()
        }
        .onChange(of: agentRunDetailRequest) { _, _ in
            presentRequestedRunDetail()
        }
        .onChange(of: agentWatchOpenRequest) { _, _ in
            presentRequestedWatch()
        }
        .fullScreenCover(item: $presentedResponseCanvas) { presentation in
            AIResponseCanvas(presentation: presentation, onOpenSource: openLookupSource)
        }
        .onReceive(aiService.$isProcessing.removeDuplicates()) { isProcessing in
            if isProcessing {
                shouldAutoCollapseAfterNextReply = true
            } else if shouldAutoCollapseAfterNextReply && hasCompletedAssistantReply {
                areControlsExpanded = false
                shouldAutoCollapseAfterNextReply = false
            }
        }
    }

    /// Presents the library on a requested run's detail page. Runs on appear as well as on change,
    /// because the sidebar is only mounted while the panel is shown.
    private func presentRequestedRunDetail() {
        guard let request = agentRunDetailRequest else { return }
        if agentTaskStoreProvider != nil {
            agentTaskLibraryPresentation = .run(request)
        }
        onAgentRunDetailRequestHandled?()
    }

    /// Presents the library on the Watches tab for a requested watch, the same way as a requested run.
    private func presentRequestedWatch() {
        guard let request = agentWatchOpenRequest else { return }
        if agentTaskStoreProvider != nil {
            agentTaskLibraryPresentation = .watch(request)
        }
        onAgentWatchOpenRequestHandled?()
    }

    private var headerRow: some View {
        rowContainer(background: rowEmphasisBackground) {
            HStack(spacing: 10) {
                iconContainer {
                    Image(systemName: "sparkles")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(primaryText)
                }
                Text(backendLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(rowBackground)
                    )
                Spacer()
                if canToggleControlsVisibility {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            areControlsExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: effectiveControlsExpanded ? "rectangle.compress.vertical" : "slider.horizontal.3")
                            .font(.caption.weight(.bold))
                            .foregroundColor(secondaryText)
                            .padding(6)
                            .background(
                                Circle().fill(iconBackground)
                            )
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .accessibilityLabel(effectiveControlsExpanded ? "Collapse controls" : "Expand controls")
                }
                if !aiService.messages.isEmpty {
                    Button {
                        showFullConversation = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption.weight(.bold))
                            .foregroundColor(secondaryText)
                            .padding(6)
                            .background(
                                Circle().fill(iconBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("View full conversation")
                }
                if agentTaskStoreProvider != nil {
                    Button {
                        agentTaskLibraryPresentation = .browse(UUID())
                    } label: {
                        Image(systemName: "checklist")
                            .font(.caption.weight(.bold))
                            .foregroundColor(secondaryText)
                            .padding(6)
                            .background(Circle().fill(iconBackground))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Saved agent tasks and history")
                }
                if let isPinned {
                    Button {
                        isPinned.wrappedValue.toggle()
                    } label: {
                        Image(systemName: isPinned.wrappedValue ? "pin.fill" : "pin")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isPinned.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(secondaryText))
                            .padding(6)
                            .background(
                                Circle().fill(iconBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(isPinned.wrappedValue ? "Unpin AI sidebar" : "Pin AI sidebar")
                    .accessibilityHint("When pinned, tapping the page keeps the sidebar open")
                }
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundColor(secondaryText)
                        .padding(6)
                        .background(
                            Circle().fill(iconBackground)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Close AI assistant")
            }
        }
    }

    private var controlsSection: some View {
        VStack(spacing: 12) {
            modelRow
            if agent.canOfferAgent(for: aiService.backend) {
                agentModeRow
            }
            if contextOptions.count > 1 {
                contextPickerRow
            }
            selectionSection
            summarizeRow
            customPromptsSection
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func contextStatusRow(_ text: String) -> some View {
        rowContainer {
            HStack(spacing: 10) {
                iconContainer {
                    Image(systemName: "text.bubble")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(primaryText)
                }
                Text(text)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var backendRow: some View {
        rowContainer {
            if isPhone {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        iconContainer {
                            Image(systemName: "switch.2")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(primaryText)
                        }
                        Text("Model")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(primaryText)
                    }
                    Menu {
                        ForEach(userSelectableBackends, id: \.self) { backend in
                            Button {
                                aiService.backend = backend
                            } label: {
                                HStack {
                                    Text(modelMenuTitle(for: backend))
                                    if aiService.backend == backend {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .disabled(backend == .mlxLocal && !mlxAvailable)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(modelMenuTitle(for: aiService.backend))
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .allowsTightening(true)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundColor(primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Model")
                    .accessibilityValue(modelMenuTitle(for: aiService.backend))
                    .disabled(agent.isRunning)
                }
            } else {
                HStack(spacing: 10) {
                    iconContainer {
                        Image(systemName: "switch.2")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(primaryText)
                    }
                    Text("Model")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(primaryText)
                    Spacer()
                    Picker("Model", selection: $aiService.backend) {
                        ForEach(userSelectableBackends, id: \.self) { backend in
                            Text(modelMenuTitle(for: backend))
                                .tag(backend)
                                .disabled(backend == .mlxLocal && !mlxAvailable)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(agent.isRunning)
                }
            }
        }
    }

    private var modelRow: some View {
        backendRow
    }

    private var agentModeRow: some View {
        rowContainer {
            Toggle(isOn: $isAgentMode) {
                HStack(spacing: 10) {
                    iconContainer {
                        Image(systemName: "cursorarrow.click.2")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(primaryText)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agent mode")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(primaryText)
                        Text(agent.status(for: aiService.backend))
                            .font(.caption2)
                            .foregroundColor(secondaryText)
                    }
                }
            }
            .disabled(agent.isRunning)
        }
    }

    private var summarizeRow: some View {
        Menu {
            Button {
                guard !browserActionIsBusy else { return }
                if aiService.backend.isWebProvider {
                    sendSidebarPrompt(
                        "Provide a brief 2-paragraph summary of the following text. First paragraph: main topic. Second paragraph: key points. Be concise:",
                        hideFromVisibleConversation: true
                    )
                    return
                }
                Task {
                    if let selection = trimmedSelectionText {
                        let binding = currentPageContextBinding
                        await MainActor.run {
                            aiService.prepareForNewContext(currentWebView?.url)
                        }
                        let handled = onSummaryExtraction?(selection, .short, binding, nil) ?? false
                        if !handled { aiService.enqueueSummary(selection, length: .short) }
                        return
                    }
                    guard let webView = currentWebView else {
                        await MainActor.run {
                            aiService.appendAssistantMessage("No webpage loaded")
                        }
                        return
                    }

                    await MainActor.run {
                        aiService.prepareForNewContext(webView.url)
                    }
                    let binding = currentPageContextBinding
                    let extractedContent = await PageContentExtractor.extractContent(from: webView, url: webView.url)
                    if let extractedContent {
                        let content = extractedContent.formattedForAIContext
                        print("📄 Extracted content length: \(content.count) characters")
                        let handled = await MainActor.run {
                            onSummaryExtraction?(content, .short, binding, extractedContent) ?? false
                        }
                        if !handled {
                            aiService.enqueueSummary(content, length: .short)
                        }
                    } else {
                        await MainActor.run {
                            aiService.appendAssistantMessage("Could not extract page content. Please try again.")
                        }
                    }
                }
            } label: {
                Label("Short Summary", systemImage: "text.badge.minus")
                Text("2 paragraphs max")
            }

            Button {
                guard !browserActionIsBusy else { return }
                if aiService.backend.isWebProvider {
                    sendSidebarPrompt(
                        "Summarize the following text clearly, highlighting key themes and points. Provide a detailed analysis:",
                        hideFromVisibleConversation: true
                    )
                    return
                }
                Task {
                    if let selection = trimmedSelectionText {
                        let binding = currentPageContextBinding
                        await MainActor.run {
                            aiService.prepareForNewContext(currentWebView?.url)
                        }
                        let handled = onSummaryExtraction?(selection, .long, binding, nil) ?? false
                        if !handled { aiService.enqueueSummary(selection, length: .long) }
                        return
                    }
                    guard let webView = currentWebView else {
                        await MainActor.run {
                            aiService.appendAssistantMessage("No webpage loaded")
                        }
                        return
                    }

                    await MainActor.run {
                        aiService.prepareForNewContext(webView.url)
                    }
                    let binding = currentPageContextBinding
                    let extractedContent = await PageContentExtractor.extractContent(from: webView, url: webView.url)
                    if let extractedContent {
                        let content = extractedContent.formattedForAIContext
                        print("📄 Extracted content length: \(content.count) characters")
                        let handled = await MainActor.run {
                            onSummaryExtraction?(content, .long, binding, extractedContent) ?? false
                        }
                        if !handled {
                            aiService.enqueueSummary(content, length: .long)
                        }
                    } else {
                        await MainActor.run {
                            aiService.appendAssistantMessage("Could not extract page content. Please try again.")
                        }
                    }
                }
            } label: {
                Label("Long Summary", systemImage: "text.badge.plus")
                Text("Detailed analysis")
            }
        } label: {
            rowContainer(background: rowEmphasisBackground) {
                HStack(spacing: 10) {
                    iconContainer {
                        Image(systemName: "doc.text")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(primaryText)
                    }
                    Text("Summarize")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(primaryText)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(secondaryText)
                }
            }
        }
        .disabled(aiService.isProcessing || browserActionIsBusy)
    }

    @ViewBuilder
    private var selectionSection: some View {
        if let selection = trimmedSelectionText {
            rowContainer(background: rowEmphasisBackground) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        iconContainer {
                            Image(systemName: "text.quote")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(primaryText)
                        }
                        Text("Selected text")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(primaryText)
                        Spacer()
                    }
                    Text(selection)
                        .font(.caption)
                        .foregroundColor(secondaryText)
                        .lineLimit(6)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }


    private var customPromptsSection: some View {
        ZStack {
            Menu {
                if customPrompts.isEmpty {
                    Button("No custom prompts yet") {}
                        .disabled(true)
                } else {
                    ForEach(customPrompts.indices, id: \.self) { index in
                        let prompt = customPrompts[index]
                        Button {
                            guard !aiService.isProcessing else { return }
                            sendSidebarPrompt(prompt, hideFromVisibleConversation: true)
                        } label: {
                            Text(prompt)
                        }
                    }
                }
                Divider()
                Button {
                    showCustomPromptEditor = true
                } label: {
                    Label("Add Custom Prompt", systemImage: "plus")
                }
            } label: {
                rowContainer(background: rowEmphasisBackground) {
                    HStack(spacing: 10) {
                        iconContainer {
                            Image(systemName: "text.badge.plus")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(primaryText)
                        }
                        Text("Custom Prompts")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(primaryText)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(secondaryText)
                    }
                    .padding(.trailing, 28)
                }
            }
            .disabled(aiService.isProcessing || browserActionIsBusy)
            HStack {
                Spacer()
                Button {
                    showCustomPromptEditor = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(secondaryText)
                        .padding(6)
                        .background(
                            Circle().fill(iconBackground)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .disabled(aiService.isProcessing)
                .accessibilityLabel("Add custom prompt")
            }
            .padding(.trailing, 8)
        }
        .sheet(isPresented: $showCustomPromptEditor) {
            customPromptEditor
        }
    }

    private var customPromptEditor: some View {
        NavigationView {
            VStack(spacing: 12) {
                TextEditor(text: $newCustomPrompt)
                    .font(.subheadline)
                    .foregroundColor(primaryText)
                    .frame(minHeight: 140)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(rowBackground)
                    )
                Spacer()
            }
            .padding(16)
            .navigationTitle("Custom Prompt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        newCustomPrompt = ""
                        showCustomPromptEditor = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addCustomPrompt()
                    }
                    .disabled(trimmedCustomPrompt.isEmpty)
                }
            }
        }
    }

    private var trimmedCustomPrompt: String {
        newCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var contextPickerRow: some View {
        Menu {
            ForEach(contextOptions) { option in
                Button {
                    selectedContextID = option.id
                    onContextSelected?(option.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title)
                        if let subtitle = option.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundColor(secondaryText)
                        }
                    }
                }
            }
        } label: {
            rowContainer(background: rowEmphasisBackground) {
                HStack(spacing: 10) {
                    iconContainer {
                        Image(systemName: "square.on.square")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(primaryText)
                    }
                    Text("Tabs")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(primaryText)
                    Spacer()
                    if let current = currentContext {
                        Text(current.title)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(secondaryText)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(secondaryText)
                }
            }
        }
    }

    private var messagesSection: some View {
        VStack(spacing: 8) {
            if let agentTaskStatusMessage {
                rowContainer {
                    Label(agentTaskStatusMessage, systemImage: "clock")
                        .font(.caption.weight(.medium))
                        .foregroundColor(secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("agentTaskWaitingStatus")
                }
            }
            AISidebarMessagesSection(
                messages: displayedMessages,
                isProcessing: aiService.isProcessing,
                queuedCount: aiService.queuedCount,
                streamState: aiService.streamState,
                isDark: isDark,
                assistantReplyFontSize: assistantReplyFontSize,
                conversationLineSpacing: conversationLineSpacing,
                sectionLabelFontSize: sectionLabelFontSize,
                trimmedSelectionText: trimmedSelectionText,
                showsEmptyPrompt: !agentModeActive,
                onClearConversation: {
                    cancelAppleInformationRunIfNeeded()
                    onClearConversation?() ?? aiService.reset()
                },
                saveAgentReplyID: agentTaskReplyEligible?.replyID,
                savedAgentReplyIDs: savedAgentReplyIDs,
                onSaveAgentReply: { replyID in
                    guard let completion = agentTaskReplyEligible,
                          completion.replyID == replyID else { return }
                    beginSaveAgentTask(completion, displayedReplyID: replyID)
                },
                showsSlowRedditProcessingNotice: aiService.isSlowRedditProcessingNoticeVisible,
                onOpenResponseCanvas: { presentation in
                    presentedResponseCanvas = presentation
                },
                onOpenLookupSource: openLookupSource
            )

        }
    }

    private var agentTaskReplyEligible: AgentCompletionUI? {
        guard let completion = latestAgentCompletion,
              !completion.snapshot.isPrivate,
              completion.snapshot.sources.isEmpty,
              completion.snapshot.preset != "lookup",
              completion.snapshot.preset != "automatic" || completion.snapshot.usedBrowserPath,
              agentTaskStoreProvider != nil,
              aiService.messages.contains(where: { $0.id == completion.replyID && $0.role == .assistant }) else { return nil }
        return completion
    }

    private func beginSaveAgentTask(_ completion: AgentCompletionUI, displayedReplyID: UUID) {
        guard let draft = completion.saveAssociation.draft(for: displayedReplyID) else { return }
        agentTaskLibraryPresentation = .save(draft)
    }

    private var displayedMessages: [ChatMessage] {
        let maxVisibleMessages = 10
        let sidebarMessages = aiService.messages.filter(\.showsInSidebar)
        let visible: [ChatMessage]
        if sidebarMessages.count <= maxVisibleMessages {
            visible = sidebarMessages
        } else {
            visible = Array(sidebarMessages.suffix(maxVisibleMessages))
        }
        let totalChars = visible.reduce(0) { $0 + $1.text.count }
        let hiddenCount = aiService.messages.count - sidebarMessages.count
        browserAISidebarLog("displayedMessages totalStored=\(aiService.messages.count) hidden=\(hiddenCount) visible=\(visible.count) totalChars=\(totalChars)")
        return visible
    }

    private var inputRow: some View {
        VStack(spacing: 6) {
            if browserActionIsBusy {
                Text("Finishing a Siri or Shortcuts action\u{2026}")
                    .font(.caption)
                    .foregroundColor(secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            inputRowContent
        }
    }

    private var inputRowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.footnote.weight(.semibold))
                .foregroundColor(primaryText)
                .frame(width: 30, height: 30)
                .glassEffectCompat(
                    in: Circle(),
                    material: .ultraThinMaterial,
                    strokeOpacity: isDark ? 0.16 : 0.3,
                    isInteractive: false
                )

            TextField(agentModeActive ? "Ask, or tell it what to do…" : "Ask anything...", text: $input)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.asciiCapable)
                .font(.system(size: inputFontSize))
                .foregroundColor(primaryText)
                .browserAskAIInputSafetyModifiers()
                .focused($isInputFocused)
                .onSubmit { send() }
                .disabled(aiService.isProcessing || agent.isRunning || browserActionIsBusy)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .glassEffectCompat(
                    in: Capsule(),
                    material: .ultraThinMaterial,
                    strokeOpacity: isDark ? 0.16 : 0.35
                )

            if agent.isRunning {
                Button {
                    agent.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(primaryText)
                        .frame(width: 44, height: 44)
                        .glassEffectCompat(
                            in: Circle(),
                            material: .ultraThinMaterial,
                            strokeOpacity: isDark ? 0.16 : 0.3
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop agent")
            } else if !input.isEmpty {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(primaryText)
                        .frame(width: 44, height: 44)
                        .glassEffectCompat(
                            in: Circle(),
                            material: .ultraThinMaterial,
                            strokeOpacity: isDark ? 0.16 : 0.3
                        )
                }
                .buttonStyle(.plain)
                .disabled(aiService.isProcessing || browserActionIsBusy)
                .accessibilityLabel("Send message")
            }
        }
        .glassEffectContainerCompat(spacing: 10)
    }

    private func rowContainer<Content: View>(
        background: Color? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                shape.fill(background ?? rowBackground)
            )
            .overlay(
                shape.strokeBorder(Color.white.opacity(isDark ? 0.1 : 0.3), lineWidth: 0.6)
            )
    }

    private func iconContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconBackground)
            content()
        }
        .frame(width: 26, height: 26)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: sectionLabelFontSize, weight: .semibold))
            .foregroundColor(secondaryText)
            .padding(.leading, 6)
    }


    private func addCustomPrompt() {
        let trimmed = trimmedCustomPrompt
        guard !trimmed.isEmpty else { return }
        customPrompts.append(trimmed)
        newCustomPrompt = ""
        showCustomPromptEditor = false
    }

    private func removeCustomPrompt(at index: Int) {
        guard customPrompts.indices.contains(index) else { return }
        customPrompts.remove(at: index)
    }

    private func loadCustomPrompts() {
        guard let data = customPromptsData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            customPrompts = []
            return
        }
        customPrompts = decoded
    }

    private func persistCustomPrompts() {
        guard let data = try? JSONEncoder().encode(customPrompts),
              let json = String(data: data, encoding: .utf8) else { return }
        customPromptsData = json
    }

    private func syncContextSelection() {
        guard !contextOptions.isEmpty else {
            selectedContextID = nil
            return
        }
        if let selected = selectedContextID,
           contextOptions.contains(where: { $0.id == selected }) {
            return
        }
        selectedContextID = contextOptions.first?.id
    }

    private func sendSidebarPrompt(_ prompt: String, hideFromVisibleConversation: Bool = false) {
        guard !browserActionIsBusy else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if hideFromVisibleConversation {
            aiService.markNextUserPromptHiddenInSidebar()
        }
        onSend(trimmed)
    }

    private func send() {
        guard !browserActionIsBusy else { return }
        guard !aiService.isProcessing else {
            browserAISidebarLog("send blocked isProcessing=true queued=\(aiService.queuedCount) storedMessages=\(aiService.messages.count)")
            return
        }
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if agentModeActive {
            if let mode = BrowserAppleWebLookup.requestMode(text: text, backend: aiService.backend) {
                switch mode {
                case .webLookup(let task):
                    startAgent(task: task, preset: .webLookup)
                    return
                case .automatic(let task):
                    startAgent(task: task, preset: .automaticApple)
                    return
                case .legacyRouter:
                    break
                }
            }
            switch BrowserAgentRouter.route(text) {
            case .agent(let task):
                startAgent(task: task)
                return
            case .research(let task):
                startAgent(task: task, preset: .research)
                return
            case .chat(let question):
                text = question
            }
        }
        browserAISidebarLog("send start chars=\(text.count) storedMessages=\(aiService.messages.count) displayedMessages=\(displayedMessages.count) backend=\(aiService.backend.rawValue)")
        input = ""
        Task { @MainActor in
            onSend(text)
        }
    }

    private func publishAgentReadiness(isReady: Bool) {
        let visible = isReady
            && isSidebarVisible
            && isAgentTaskSidebarVisible
            && scenePhase == .active
        onAgentReadinessChanged?(
            visible,
            agent.isRunning || aiService.isProcessing,
            agent.canOfferAgent(for: aiService.backend)
        )
    }

    private func startPendingAgentTaskIfPossible() {
        guard !browserActionIsBusy,
              let request = pendingAgentTask,
              attemptedPendingAgentTaskID != request.id,
              scenePhase == .active,
              isSidebarVisible,
              isAgentTaskSidebarVisible,
              !agent.isRunning,
              !aiService.isProcessing,
              agent.canOfferAgent(for: aiService.backend),
              let webView = currentWebView,
              !webView.isLoading else { return }
        guard onPendingAgentTaskDispatchCheck?(request.id, webView) == true else {
            attemptedPendingAgentTaskID = request.id
            onPendingAgentTaskRejected?(request.id)
            return
        }
        guard startAgent(task: request.task, savedTaskID: request.savedTaskID, requestID: request.id) else { return }
        attemptedPendingAgentTaskID = request.id
        onPendingAgentTaskStarted?(request.id)
    }

    @discardableResult
    private func startAgent(
        task: String,
        preset: BrowserAgentController.Preset = .standard,
        savedTaskID: UUID? = nil,
        requestID: UUID? = nil
    ) -> Bool {
        guard !browserActionIsBusy,
              !agent.isRunning, !aiService.isProcessing,
              agent.canOfferAgent(for: aiService.backend) else { return false }
        guard let webView = currentWebView else {
            aiService.appendAssistantMessage("No webpage loaded")
            return false
        }
        input = ""
        isInputFocused = false
        withAnimation(.easeOut(duration: 0.2)) {
            areControlsExpanded = false
        }
        let safeTask = BrowserAgentAutofillPrivacy.shared.redactPotentiallyTruncated(task, wasTruncated: true)
        let service = aiService
        var capturedSummary: String?
        let quarantineHandler: BrowserAgentController.AutofillQuarantineHandler? = {
            guard let parentHandler = onAgentAutofillQuarantine else { return nil }
            let relay: BrowserAgentController.AutofillQuarantineHandler = { tabID, webView in
                parentHandler(tabID, webView)
            }
            return relay
        }()
        agent.start(
            task: safeTask,
            preset: preset,
            conversation: recentConversation.map { BrowserAgentAutofillPrivacy.shared.redactPotentiallyTruncated($0, wasTruncated: true) },
            in: webView,
            openTab: onAgentOpenTab,
            browserAdapter: browserAgentAdapter,
            backend: aiService.backend,
            startingTabIsPrivate: currentContext?.isPrivate ?? false,
            savedTaskID: savedTaskID,
            requestID: requestID,
            onAutofillQuarantine: quarantineHandler,
            onPageQuestion: { [onSend] question in
                onSend(question)
            },
            onRunCompleted: { snapshot in
                guard let summary = capturedSummary else { return }
                let replyID = service.appendAgentExchange(
                    task: safeTask,
                    answer: BrowserAgentAutofillPrivacy.shared.redactPotentiallyTruncated(summary, wasTruncated: true),
                    sources: snapshot.sources
                )
                latestAgentCompletion = AgentCompletionUI(snapshot: snapshot, replyID: replyID)
                onAgentRunCompleted?(snapshot, replyID)
                publishAgentReadiness(isReady: true)
            }
        ) { summary in
            capturedSummary = summary
        }
        return true
    }

    static func lookupSourceOpenEligible(
        _ source: BrowserLookupSource,
        contextIsPrivate: Bool,
        webViewDataStoreIsPersistent: Bool
    ) -> Bool {
        guard source.isPrivate == contextIsPrivate else { return false }
        guard webViewDataStoreIsPersistent != contextIsPrivate else { return false }
        return BrowserAppleWebLookup.isPublicLookupURL(source.url)
    }

    private func openLookupSource(_ source: BrowserLookupSource) {
        guard !agent.isRunning,
              !browserActionIsBusy,
              !aiService.isProcessing,
              onLookupOpenSource?(source) == true else {
            aiService.appendAssistantMessage("That source can't be opened from this tab anymore. Return to a matching browser tab and try again.")
            return
        }
    }

    private func cancelAppleInformationRunIfNeeded() {
        if agent.isAppleInformationRun {
            agent.stop()
        }
    }

    /// The last few visible turns, so the agent can follow up on them.
    private var recentConversation: String? {
        let turns = aiService.messages
            .filter(\.showsInSidebar)
            .suffix(6)
            .map { message -> String in
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let clipped = text.count > 600 ? String(text.prefix(600)) + "…" : text
                return (message.role == .user ? "User: " : "Assistant: ") + clipped
            }
        return turns.isEmpty ? nil : turns.joined(separator: "\n")
    }
}

private struct AISidebarMessagesSection: View {
    let messages: [ChatMessage]
    let isProcessing: Bool
    let queuedCount: Int
    @ObservedObject var streamState: AIStreamState
    let isDark: Bool
    let assistantReplyFontSize: CGFloat
    let conversationLineSpacing: CGFloat
    let sectionLabelFontSize: CGFloat
    let trimmedSelectionText: String?
    let showsEmptyPrompt: Bool
    let onClearConversation: () -> Void
    let saveAgentReplyID: UUID?
    let savedAgentReplyIDs: Set<UUID>
    let onSaveAgentReply: (UUID) -> Void
    let showsSlowRedditProcessingNotice: Bool
    let onOpenResponseCanvas: (AIResponseCanvasPresentation) -> Void
    var onOpenLookupSource: ((BrowserLookupSource) -> Void)? = nil

    @State private var renderedStreamingResponse: String = ""
    @State private var pendingStreamingResponse: String = ""
    @State private var renderedThroughputState: AIThroughputState? = nil
    @State private var pendingThroughputState: AIThroughputState? = nil
    @State private var renderTask: Task<Void, Never>? = nil

    private let renderFlushNanoseconds: UInt64 = 150_000_000

    private var primaryText: Color {
        isDark ? Color.white : Color.black
    }

    private var secondaryText: Color {
        isDark ? Color.white.opacity(0.75) : Color.black.opacity(0.6)
    }

    private var rowBackground: Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    private var iconBackground: Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.1)
    }

    private var activeThroughput: AIThroughputState? {
        guard let throughput = renderedThroughputState else { return nil }
        guard throughput.backend == .localApple || throughput.backend == .mlxLocal else { return nil }
        return throughput
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionHeader("Conversation", systemImage: "bubble.left.and.bubble.right")
                    Spacer()
                    if !messages.isEmpty || !renderedStreamingResponse.isEmpty || !pendingStreamingResponse.isEmpty {
                        Button(action: onClearConversation) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(secondaryText)
                        }
                        .accessibilityLabel("Clear conversation")
                        .buttonStyle(.plain)
                        .frame(width: 44, height: 44)
                    }
                }

                AISidebarConversationHistoryView(
                    messages: messages,
                    isDark: isDark,
                    assistantReplyFontSize: assistantReplyFontSize,
                    conversationLineSpacing: conversationLineSpacing,
                    onOpenResponseCanvas: onOpenResponseCanvas,
                    saveAgentReplyID: saveAgentReplyID,
                    savedAgentReplyIDs: savedAgentReplyIDs,
                    onSaveAgentReply: onSaveAgentReply,
                    onOpenLookupSource: onOpenLookupSource
                )
                .equatable()

                if !renderedStreamingResponse.isEmpty {
                    streamingAssistantBubble(renderedStreamingResponse)
                }

                if let throughput = activeThroughput,
                   !showsSlowRedditProcessingNotice || throughput.tokens > 0 {
                    rowContainer {
                        Text(throughputInlineText(throughput))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(secondaryText)
                    }
                }

                if isProcessing && showsSlowRedditProcessingNotice {
                    rowContainer {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(SimpleAIService.slowRedditProcessingNotice)
                                .foregroundColor(secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if isProcessing && pendingStreamingResponse.isEmpty && !showsSlowRedditProcessingNotice {
                    rowContainer {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Answering...")
                                .foregroundColor(secondaryText)
                        }
                    }
                }

                if queuedCount > 0 {
                    rowContainer {
                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                                .foregroundColor(secondaryText)
                            Text("Queued: \(queuedCount)")
                                .foregroundColor(secondaryText)
                        }
                    }
                }

                if showsEmptyPrompt && messages.isEmpty && !isProcessing {
                    Text(trimmedSelectionText == nil ? "Ask about this page..." : "Ask about this selection...")
                        .foregroundColor(secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transaction { transaction in
            transaction.animation = nil
        }
        .onAppear {
            syncImmediately()
        }
        .onChange(of: isProcessing) { _, processing in
            if !processing {
                syncImmediately()
            }
        }
        .onReceive(streamState.$textVersion) { _ in
            handleStreamingResponseChange(streamState.text)
        }
        .onReceive(streamState.$throughput) { newValue in
            handleThroughputStateChange(newValue)
        }
        .onDisappear {
            renderTask?.cancel()
            renderTask = nil
        }
    }

    private func rowContainer<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                shape.fill(rowBackground)
            )
            .overlay(
                shape.strokeBorder(Color.white.opacity(isDark ? 0.1 : 0.3), lineWidth: 0.6)
            )
    }

    private func iconContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconBackground)
            content()
        }
        .frame(width: 26, height: 26)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: sectionLabelFontSize, weight: .semibold))
            .foregroundColor(secondaryText)
            .padding(.leading, 6)
    }

    private func handleStreamingResponseChange(_ newValue: String) {
        pendingStreamingResponse = newValue

        if newValue.isEmpty {
            renderTask?.cancel()
            renderTask = nil
            renderedStreamingResponse = ""
            return
        }

        scheduleRenderIfNeeded()
    }

    private func handleThroughputStateChange(_ newValue: AIThroughputState?) {
        pendingThroughputState = newValue
        if newValue == nil {
            renderedThroughputState = nil
            return
        }
        scheduleRenderIfNeeded()
    }

    private func syncImmediately() {
        renderTask?.cancel()
        renderTask = nil
        pendingStreamingResponse = streamState.text
        renderedStreamingResponse = pendingStreamingResponse
        pendingThroughputState = streamState.throughput
        renderedThroughputState = pendingThroughputState
    }

    private func scheduleRenderIfNeeded() {
        guard renderTask == nil else { return }
        renderTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: renderFlushNanoseconds)
            guard !Task.isCancelled else { return }
            renderTask = nil
            renderedStreamingResponse = pendingStreamingResponse
            renderedThroughputState = pendingThroughputState
        }
    }

    private func streamingAssistantBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            iconContainer {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(primaryText)
            }
            Text(AIResponseMarkdown.inline(text))
                .font(.system(size: assistantReplyFontSize))
                .lineSpacing(conversationLineSpacing)
                .foregroundColor(primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowBackground)
        )
    }

    private func throughputInlineText(_ throughput: AIThroughputState) -> String {
        let label = throughput.backend.throughputLabel
        if throughput.tokens <= 0 {
            return "\(label) generating..."
        }
        if throughput.backend == .mlxLocal && throughput.isFinal {
            return "[MLX] Generated \(throughput.tokens) tokens in \(String(format: "%.1f", throughput.elapsed))s (\(String(format: "%.1f", throughput.tokensPerSecond)) tok/s)"
        }
        if throughput.isFinal {
            return "\(label) avg \(String(format: "%.1f", throughput.tokensPerSecond)) tok/s • \(throughput.tokens) tok"
        }
        return "\(label) \(String(format: "%.1f", throughput.tokensPerSecond)) tok/s • \(throughput.tokens) tok"
    }
}

private struct AISidebarConversationArchiveSheet: View {
    let messages: [ChatMessage]
    let isDark: Bool
    let assistantReplyFontSize: CGFloat
    let conversationLineSpacing: CGFloat
    var onOpenLookupSource: ((BrowserLookupSource) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var presentedResponseCanvas: AIResponseCanvasPresentation?

    private var sourceOpener: ((BrowserLookupSource) -> Void)? {
        guard onOpenLookupSource != nil else { return nil }
        return { source in openSource(source) }
    }

    private func openSource(_ source: BrowserLookupSource) {
        dismiss()
        DispatchQueue.main.async {
            onOpenLookupSource?(source)
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    AISidebarConversationHistoryView(
                        messages: messages,
                        isDark: isDark,
                        assistantReplyFontSize: assistantReplyFontSize,
                        conversationLineSpacing: conversationLineSpacing,
                        onOpenResponseCanvas: { presentation in
                            presentedResponseCanvas = presentation
                        },
                        onOpenLookupSource: sourceOpener
                    )
                }
                .padding(16)
            }
            .background(isDark ? Color.black : Color(UIColor.systemBackground))
            .navigationTitle("Full Conversation")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .fullScreenCover(item: $presentedResponseCanvas) { presentation in
            AIResponseCanvas(presentation: presentation, onOpenSource: sourceOpener)
        }
    }
}

private struct AISidebarConversationHistoryView: View, Equatable {
    let messages: [ChatMessage]
    let isDark: Bool
    let assistantReplyFontSize: CGFloat
    let conversationLineSpacing: CGFloat
    let onOpenResponseCanvas: (AIResponseCanvasPresentation) -> Void
    var saveAgentReplyID: UUID? = nil
    var savedAgentReplyIDs: Set<UUID> = []
    var onSaveAgentReply: ((UUID) -> Void)? = nil
    var onOpenLookupSource: ((BrowserLookupSource) -> Void)? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.isDark == rhs.isDark,
              lhs.assistantReplyFontSize == rhs.assistantReplyFontSize,
              lhs.conversationLineSpacing == rhs.conversationLineSpacing,
              lhs.saveAgentReplyID == rhs.saveAgentReplyID,
              lhs.savedAgentReplyIDs == rhs.savedAgentReplyIDs else {
            return false
        }
        guard lhs.messages.count == rhs.messages.count else { return false }
        for index in lhs.messages.indices {
            if lhs.messages[index].id != rhs.messages[index].id {
                return false
            }
        }
        return true
    }

    private var primaryText: Color {
        isDark ? Color.white : Color.black
    }

    private var rowBackground: Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    private var rowEmphasisBackground: Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    private var iconBackground: Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.1)
    }

    private func assistantDisplayText(for message: ChatMessage) -> String {
        message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ForEach(messages) { msg in
            HStack(alignment: .top, spacing: 10) {
                iconContainer {
                    Image(systemName: msg.role == .user ? "person.fill" : "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(primaryText)
                }
                if msg.role == .user {
                    Text(verbatim: msg.text)
                        .font(.subheadline)
                        .foregroundColor(primaryText)
                } else {
                    let responseCanvas = AIResponseCanvasPresentation(message: msg)
                    VStack(alignment: .leading, spacing: 9) {
                        AIResponseSidebarMarkdownView(
                            text: assistantDisplayText(for: msg),
                            fontSize: assistantReplyFontSize,
                            lineSpacing: conversationLineSpacing,
                            color: primaryText
                        )
                            .fixedSize(horizontal: false, vertical: true)
                        AIResponseSourceCards(sources: msg.sources, onOpenSource: onOpenLookupSource)
                        Button {
                            onOpenResponseCanvas(responseCanvas)
                        } label: {
                            Label("Open Full Reply", systemImage: "rectangle.expand.diagonal")
                                .font(.footnote.weight(.semibold))
                        }
                        .browserResponseCanvasButtonStyle()
                        .accessibilityHint("Opens this model reply in the full-screen canvas")
                        if saveAgentReplyID == msg.id {
                            Button {
                                onSaveAgentReply?(msg.id)
                            } label: {
                                Label(
                                    savedAgentReplyIDs.contains(msg.id) ? "Saved as Task" : "Save Run as Task",
                                    systemImage: savedAgentReplyIDs.contains(msg.id) ? "checkmark.circle.fill" : "bookmark"
                                )
                                .font(.footnote.weight(.semibold))
                            }
                            .browserResponseCanvasButtonStyle()
                            .disabled(savedAgentReplyIDs.contains(msg.id))
                            .accessibilityIdentifier("saveAgentRunAsTask")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(msg.role == .user ? rowEmphasisBackground : rowBackground)
            )
        }
    }

    private func iconContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconBackground)
            content()
        }
        .frame(width: 26, height: 26)
    }
}
