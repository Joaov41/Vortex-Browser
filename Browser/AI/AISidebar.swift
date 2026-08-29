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
    var onSummaryExtraction: ((PageContentExtractor.ExtractedPageContent, SummaryLength) -> Bool)? = nil
    var onContextSelected: ((UUID) -> Void)? = nil
    var onClearConversation: (() -> Void)? = nil

    @State private var input: String = ""
    @AppStorage("customPrompts") private var customPromptsData: String = "[]"
    @State private var customPrompts: [String] = []
    @State private var showCustomPromptEditor = false
    @State private var newCustomPrompt: String = ""
    @FocusState private var isInputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var scaledAssistantReplyFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var scaledSectionLabelFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var scaledInputFontSize: CGFloat = 18
    @State private var areControlsExpanded = true
    @State private var shouldAutoCollapseAfterNextReply = false
    @State private var showFullConversation = false
    @State private var presentedResponseCanvas: AIResponseCanvasPresentation?
    @State private var automaticallyPresentedCanvasReplyIDs: Set<UUID> = []

    private var mlxAvailable: Bool {
        MLXLocalService.isAvailable()
    }

    private var userSelectableBackends: [AIModelBackend] {
        AIModelBackend.allCases.filter { $0 != .applePCCGateway }
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
        default:
            return backend.displayName
        }
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

    private var hasCompletedAssistantReply: Bool {
        aiService.messages.contains {
            $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var effectiveControlsExpanded: Bool {
        if !hasCompletedAssistantReply {
            return true
        }
        return areControlsExpanded
    }

    private var canToggleControlsVisibility: Bool {
        hasCompletedAssistantReply && !aiService.isProcessing
    }

    private let panelCornerRadius: CGFloat = 22

    struct ContextOption: Identifiable {
        let id: UUID
        let title: String
        let subtitle: String?
        let webView: WKWebView?
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
            if let contextStatus = trimmedContextStatusText {
                contextStatusRow(contextStatus)
            }
            if effectiveControlsExpanded {
                controlsSection
            }
            if effectiveControlsExpanded {
                Divider()
                    .background(Color.white.opacity(isDark ? 0.15 : 0.2))
            }

            messagesSection

            Divider()
                .background(Color.white.opacity(isDark ? 0.15 : 0.2))

            inputRow
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
            if aiService.backend == .applePCCGateway {
                aiService.backend = .localApple
            }
            syncContextSelection()
            loadCustomPrompts()
        }
        .onChange(of: contextOptionIDs) { _ in
            syncContextSelection()
        }
        .onChange(of: customPrompts) { _ in
            persistCustomPrompts()
        }
        .onChange(of: aiService.messages) { messages in
            if shouldAutoCollapseAfterNextReply && !aiService.isProcessing && hasCompletedAssistantReply {
                areControlsExpanded = false
                shouldAutoCollapseAfterNextReply = false
            }
            presentLatestRichReplyIfNeeded(in: messages)
        }
        .sheet(isPresented: $showFullConversation) {
            AISidebarConversationArchiveSheet(
                messages: aiService.archiveMessages,
                isDark: isDark,
                assistantReplyFontSize: assistantReplyFontSize,
                conversationLineSpacing: conversationLineSpacing
            )
        }
        .fullScreenCover(item: $presentedResponseCanvas) { presentation in
            AIResponseCanvas(presentation: presentation)
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

    private var headerRow: some View {
        rowContainer(background: rowEmphasisBackground) {
            HStack(spacing: 10) {
                iconContainer {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(primaryText)
                }
                Text(backendLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(secondaryText)
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
                            .font(.system(size: 12, weight: .bold))
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
                            .font(.system(size: 12, weight: .bold))
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
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(secondaryText)
                        .padding(6)
                        .background(
                            Circle().fill(iconBackground)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .accessibilityLabel(aiService.isProcessing ? "Cancel AI task and close" : "Close AI assistant")
            }
        }
    }

    private var controlsSection: some View {
        VStack(spacing: 12) {
            modelRow
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(primaryText)
                }
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
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
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(primaryText)
                        }
                        Text("Model")
                            .font(.system(size: 14, weight: .semibold))
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
                            .disabled(
                                (backend == .mlxLocal && !mlxAvailable)
                                    || !backend.isAvailableInCurrentEnvironment
                            )
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(modelMenuTitle(for: aiService.backend))
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .allowsTightening(true)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Model")
                    .accessibilityValue(modelMenuTitle(for: aiService.backend))
                }
            } else {
                HStack(spacing: 10) {
                    iconContainer {
                        Image(systemName: "switch.2")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(primaryText)
                    }
                    Text("Model")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(primaryText)
                    Spacer()
                    Picker("Model", selection: $aiService.backend) {
                        ForEach(userSelectableBackends, id: \.self) { backend in
                            Text(modelMenuTitle(for: backend))
                                .tag(backend)
                                .disabled(
                                    (backend == .mlxLocal && !mlxAvailable)
                                        || !backend.isAvailableInCurrentEnvironment
                                )
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var modelRow: some View {
        backendRow
    }

    private var shortcutRow: some View {
        rowContainer {
            HStack(spacing: 10) {
                iconContainer {
                    Image(systemName: "shortcuts")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(primaryText)
                }
                TextField("Shortcut name", text: Binding(get: { aiService.shortcutName }, set: { aiService.shortcutName = $0 }))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .foregroundColor(primaryText)

                Image(systemName: "questionmark.circle")
                    .foregroundColor(secondaryText)
                    .help("Configure an iOS Shortcut that returns text in the clipboard.")
            }
        }
    }

    private var summarizeRow: some View {
        Menu {
            Button {
                if aiService.backend.isWebProvider {
                    sendSidebarPrompt(
                        "Provide a brief 2-paragraph summary of the following text. First paragraph: main topic. Second paragraph: key points. Be concise:",
                        hideFromVisibleConversation: true
                    )
                    return
                }
                Task {
                    if let selection = trimmedSelectionText {
                        await MainActor.run {
                            aiService.prepareForNewContext(currentWebView?.url)
                        }
                        aiService.enqueueSummary(selection, length: .short)
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
                    let extractedContent = await PageContentExtractor.extractContent(from: webView, url: webView.url)
                    if let extractedContent {
                        let content = extractedContent.formattedForAIContext
                        print("📄 Extracted content length: \(content.count) characters")
                        let handled = await MainActor.run {
                            onSummaryExtraction?(extractedContent, .short) ?? false
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
                if aiService.backend.isWebProvider {
                    sendSidebarPrompt(
                        "Summarize the following text clearly, highlighting key themes and points. Provide a detailed analysis:",
                        hideFromVisibleConversation: true
                    )
                    return
                }
                Task {
                    if let selection = trimmedSelectionText {
                        await MainActor.run {
                            aiService.prepareForNewContext(currentWebView?.url)
                        }
                        aiService.enqueueSummary(selection, length: .long)
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
                    let extractedContent = await PageContentExtractor.extractContent(from: webView, url: webView.url)
                    if let extractedContent {
                        let content = extractedContent.formattedForAIContext
                        print("📄 Extracted content length: \(content.count) characters")
                        let handled = await MainActor.run {
                            onSummaryExtraction?(extractedContent, .long) ?? false
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(primaryText)
                    }
                    Text("Summarize")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(primaryText)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(secondaryText)
                }
            }
        }
        .disabled(aiService.isProcessing)
    }

    @ViewBuilder
    private var selectionSection: some View {
        if let selection = trimmedSelectionText {
            rowContainer(background: rowEmphasisBackground) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        iconContainer {
                            Image(systemName: "text.quote")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(primaryText)
                        }
                        Text("Selected text")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(primaryText)
                        Spacer()
                    }
                    Text(selection)
                        .font(.system(size: 12))
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
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(primaryText)
                        }
                        Text("Custom Prompts")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(primaryText)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(secondaryText)
                    }
                    .padding(.trailing, 28)
                }
            }
            .disabled(aiService.isProcessing)
            HStack {
                Spacer()
                Button {
                    showCustomPromptEditor = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 14))
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(primaryText)
                    }
                    Text("Tabs")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(primaryText)
                    Spacer()
                    if let current = currentContext {
                        Text(current.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(secondaryText)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(secondaryText)
                }
            }
        }
    }

    private var messagesSection: some View {
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
            onClearConversation: {
                onClearConversation?() ?? aiService.reset()
            },
            showsSlowRedditProcessingNotice: aiService.isSlowRedditProcessingNoticeVisible,
            onOpenResponseCanvas: { presentation in
                presentedResponseCanvas = presentation
            }
        )
    }

    private func presentLatestRichReplyIfNeeded(in messages: [ChatMessage]) {
        guard let latestReply = messages.last,
              latestReply.role == .assistant,
              !automaticallyPresentedCanvasReplyIDs.contains(latestReply.id) else {
            return
        }
        let presentation = AIResponseCanvasPresentation(message: latestReply)
        guard presentation.shouldAutoPresent else { return }
        automaticallyPresentedCanvasReplyIDs.insert(latestReply.id)
        presentedResponseCanvas = presentation
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
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(primaryText)
                .frame(width: 30, height: 30)
                .glassEffectCompat(
                    in: Circle(),
                    material: .ultraThinMaterial,
                    strokeOpacity: isDark ? 0.16 : 0.3,
                    isInteractive: false
                )

            TextField("Ask Vortex...", text: $input)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.asciiCapable)
                .font(.system(size: inputFontSize))
                .foregroundColor(primaryText)
                .browserAskAIInputSafetyModifiers()
                .focused($isInputFocused)
                .onSubmit { send() }
                .disabled(aiService.isProcessing)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .glassEffectCompat(
                    in: Capsule(),
                    material: .ultraThinMaterial,
                    strokeOpacity: isDark ? 0.16 : 0.35
                )

            if !input.isEmpty {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(primaryText)
                        .frame(width: 44, height: 44)
                        .glassEffectCompat(
                            in: Circle(),
                            material: .ultraThinMaterial,
                            strokeOpacity: isDark ? 0.16 : 0.3
                        )
                }
                .buttonStyle(.plain)
                .disabled(aiService.isProcessing)
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
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if hideFromVisibleConversation {
            aiService.markNextUserPromptHiddenInSidebar()
        }
        onSend(trimmed)
    }

    private func send() {
        guard !aiService.isProcessing else {
            browserAISidebarLog("send blocked isProcessing=true queued=\(aiService.queuedCount) storedMessages=\(aiService.messages.count)")
            return
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        browserAISidebarLog("send start chars=\(text.count) storedMessages=\(aiService.messages.count) displayedMessages=\(displayedMessages.count) backend=\(aiService.backend.rawValue)")
        input = ""
        Task { @MainActor in
            onSend(text)
        }
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
    let onClearConversation: () -> Void
    let showsSlowRedditProcessingNotice: Bool
    let onOpenResponseCanvas: (AIResponseCanvasPresentation) -> Void

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
        guard throughput.backend == .localApple || throughput.backend == .mlxLocal || throughput.backend == .applePCCGateway else { return nil }
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
                    onOpenResponseCanvas: onOpenResponseCanvas
                )
                .equatable()

                if !renderedStreamingResponse.isEmpty {
                    streamingAssistantBubble(renderedStreamingResponse)
                }

                if let throughput = activeThroughput,
                   !showsSlowRedditProcessingNotice || throughput.tokens > 0 {
                    rowContainer {
                        Text(throughputInlineText(throughput))
                            .font(.system(size: 12, weight: .semibold))
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
                            Text("Generating response...")
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

                if messages.isEmpty && !isProcessing {
                    Text(trimmedSelectionText == nil ? "Ask AI about this page..." : "Ask AI about this selection...")
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
        .onChange(of: isProcessing) { processing in
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
                    .font(.system(size: 12, weight: .semibold))
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
    @Environment(\.dismiss) private var dismiss
    @State private var presentedResponseCanvas: AIResponseCanvasPresentation?

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
                        }
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
            AIResponseCanvas(presentation: presentation)
        }
    }
}

private struct AISidebarConversationHistoryView: View, Equatable {
    let messages: [ChatMessage]
    let isDark: Bool
    let assistantReplyFontSize: CGFloat
    let conversationLineSpacing: CGFloat
    let onOpenResponseCanvas: (AIResponseCanvasPresentation) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.isDark == rhs.isDark,
              lhs.assistantReplyFontSize == rhs.assistantReplyFontSize,
              lhs.conversationLineSpacing == rhs.conversationLineSpacing else {
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(primaryText)
                }
                if msg.role == .user {
                    Text(verbatim: msg.text)
                        .font(.system(size: 14))
                        .foregroundColor(primaryText)
                } else {
                    let responseCanvas = AIResponseCanvasPresentation(message: msg)
                    VStack(alignment: .leading, spacing: 9) {
                        if responseCanvas.shouldAutoPresent {
                            Text(responseCanvas.sidebarSummary)
                                .font(.system(size: assistantReplyFontSize, weight: .semibold))
                                .foregroundColor(primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            AIResponseSidebarMarkdownView(
                                text: assistantDisplayText(for: msg),
                                fontSize: assistantReplyFontSize,
                                lineSpacing: conversationLineSpacing,
                                color: primaryText
                            )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            onOpenResponseCanvas(responseCanvas)
                        } label: {
                            Label("Open Full Reply", systemImage: "rectangle.expand.diagonal")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .browserResponseCanvasButtonStyle()
                        .accessibilityHint("Opens this model reply in the full-screen canvas")
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
