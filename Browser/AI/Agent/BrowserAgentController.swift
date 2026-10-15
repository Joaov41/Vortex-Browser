//
//  BrowserAgentController.swift
//  Vortex
//
//  Agent mode: the model completes a task in the user's current tab by
//  calling tools (click, type, scroll, navigate…). Each tool result carries a
//  fresh page snapshot. Actions that could buy, send, post, delete or sign in
//  wait for the user's approval, and sensitive fields are never typed into.
//
//  The agent uses the selected, capability-checked engine while keeping all
//  page actions behind this main-actor controller and the current adapter.
//

import Foundation
import WebKit
import Combine
import UIKit

@MainActor
final class BrowserAgentController: ObservableObject {
    enum Preset: Equatable {
        case standard
        case research
        case automaticApple
        case webLookup
    }

    typealias EngineFactory = @MainActor (AIModelBackend) -> (any BrowserAgentEngine)?
    typealias ScreenshotCapture = @MainActor (WKWebView) async throws -> Data

    struct Step: Identifiable, Equatable {
        enum Kind: Equatable {
            case task
            case note
            case action
            case error
            case answer
        }

        let id = UUID()
        let kind: Kind
        let text: String
    }

    struct Confirmation: Identifiable, Equatable {
        let id: UUID
        let summary: String
        let reason: String
        let allowsSiteTrust: Bool
    }

    struct ConfirmationDecision: Equatable {
        let id: UUID
        let allowed: Bool
        let alwaysAllow: Bool
    }

    struct UserQuestion: Identifiable, Equatable {
        let id = UUID()
        let prompt: String
    }

    struct CompletionSnapshot: Equatable {
        let runID: UUID
        let task: String
        let outcome: String
        let actions: [String]
        let date: Date
        let backend: String
        let preset: String
        let startURL: URL?
        let isPrivate: Bool
        let savedTaskID: UUID?
        var sources: [BrowserLookupSource] = []
        var usedBrowserPath = false
        /// The PendingAgentTask ID that started this run; nil for runs typed in the sidebar.
        var requestID: UUID? = nil
        var startedAt: Date = Date()
        var status: AgentRunStatus = .completed
        var approvals: [AgentRunApproval] = []
        var questions: [AgentRunQuestion] = []
        var exportedFiles: [AgentRunExport] = []

        /// Private runs produce a record that is never stored, so their details stay empty here too.
        var historyRecord: AgentRunRecord {
            let durable = !isPrivate
            return AgentRunRecord(
                id: runID,
                task: task,
                outcome: outcome,
                actions: actions,
                date: date,
                backend: backend,
                preset: preset,
                startURL: startURL,
                isPrivate: isPrivate,
                requestID: requestID,
                startedAt: startedAt,
                status: status,
                approvals: durable ? approvals : [],
                questions: durable ? questions : [],
                exports: durable ? exportedFiles.map { AgentRunExportRecord(filename: $0.filename, kind: $0.kind) } : [],
                sources: durable ? sources.prefix(AgentTaskStore.maximumSourcesPerRun).compactMap { Self.recordSource($0) } : [],
                savedTaskID: savedTaskID,
                duration: max(0, date.timeIntervalSince(startedAt))
            )
        }

        private static func recordSource(_ source: BrowserLookupSource) -> AgentRunSourceRecord? {
            guard !source.isPrivate, AgentTaskURLParser.isAllowedStartURL(source.url) else { return nil }
            return AgentRunSourceRecord(
                title: AgentRunTextLimit.bounded(
                    source.title,
                    characters: 240,
                    utf8Bytes: AgentTaskStore.maximumRunSourceTitleUTF8Bytes
                ),
                url: source.url
            )
        }
    }

    struct RunContext {
        let id: UUID
        let task: String
        let backend: String
        let preset: String
        let startURL: URL?
        let isPrivate: Bool
        let savedTaskID: UUID?
        let requestID: UUID?
        let startedAt: Date
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var isRunning = false
    @Published private(set) var pendingConfirmation: Confirmation?
    @Published private(set) var pendingQuestion: UserQuestion?
    /// Handoffs prepared by the current run's prepare_* tools. The sidebar shows them one at a time after the run ends.
    @Published private(set) var handoffRequests: [AgentHandoffRequest] = []

    static let maxSteps = 25
    private static let maxElements = 150
    private static let snapshotTextChars = 2_500
    static let readChunkChars = 8_000
    private static let snapshotMarker = "\n\n<page_snapshot>"
    static var screenshotCaptureSequence: UInt64 = 0

    private var runTask: Task<Void, Never>?
    private var runID = UUID()
    var runContext: RunContext?
    private var runPreset: Preset = .standard
    private var runDeclaredToolNames: Set<String> = []
    private var onComplete: ((String) -> Void)?
    private var onRunCompleted: ((CompletionSnapshot) -> Void)?
    private var onPageQuestion: ((String) -> Void)?
    typealias AutofillQuarantineHandler = @MainActor @Sendable (UUID, WKWebView) -> Void
    var onAutofillQuarantine: AutofillQuarantineHandler?
    /// Opens a tab next to the given web view and returns the new tab's web view.
    typealias TabOpener = (URL, WKWebView) -> WKWebView?
    var openTab: TabOpener?
    var browserAdapter: BrowserAgentBrowserAdapter?
    var datasets: [UUID: BrowserAgentDataset] = [:]
    var datasetOrder: [UUID] = []
    var comparisons: [UUID: BrowserAgentExportService.Comparison] = [:]
    /// The tab the agent is acting in; changes when it opens a new tab.
    var activeWebView: WKWebView?
    private var confirmationContinuation: CheckedContinuation<ConfirmationDecision, Never>?
    let questionGate = BrowserAgentQuestionGate<UserQuestion>()
    var runWebsiteDataStore: WKWebsiteDataStore?
    var runIsPrivate = false
    var readPageKeys: Set<String> = []
    var runProfile: BrowserAgentEngineProfile?
    private var runIsAppleInformationRun = false
    private var runUsedBrowserPath = false
    @Published private(set) var lookupSources: [BrowserLookupSource] = []
    /// Run-scoped history details. Each run resets them; private runs never append.
    var runApprovals: [AgentRunApproval] = []
    var runQuestions: [AgentRunQuestion] = []
    var runExports: [AgentRunExport] = []
    /// Set only for Stop and step-limit endings; other endings are derived from the steps.
    private var runEndStatus: AgentRunStatus?
    private let engineFactory: EngineFactory
    private let appleLookup: BrowserAppleWebLookup
    let screenshotCapture: ScreenshotCapture
    let trustStoreProvider: @MainActor () -> AgentTrustStore?
    let autofillProfileService: AutofillProfileService
    let autofillPrivacy: BrowserAgentAutofillPrivacy

    init(
        engineFactory: EngineFactory? = nil,
        screenshotCapture: ScreenshotCapture? = nil,
        trustStore: AgentTrustStore? = nil,
        trustStoreProvider: (@MainActor () -> AgentTrustStore?)? = nil,
        autofillProfileService: AutofillProfileService? = nil,
        autofillPrivacy: BrowserAgentAutofillPrivacy? = nil,
        appleLookup: BrowserAppleWebLookup? = nil
    ) {
        self.engineFactory = engineFactory ?? { BrowserAgentEngineFactory.make(for: $0) }
        self.appleLookup = appleLookup ?? BrowserAppleWebLookup()
        self.screenshotCapture = screenshotCapture ?? { try await BrowserAgentScreenshotEncoder.capture($0) }
        self.autofillProfileService = autofillProfileService ?? AutofillProfileService.shared
        self.autofillPrivacy = autofillPrivacy ?? BrowserAgentAutofillPrivacy.shared
        if let trustStore {
            self.trustStoreProvider = { trustStore }
        } else if let trustStoreProvider {
            self.trustStoreProvider = trustStoreProvider
        } else {
            // Avoid loading persistent permissions for private runs. The provider
            // is invoked only after an eligible, public-host approval is pending.
            self.trustStoreProvider = { AgentTrustStore.shared }
        }
        questionGate.onPendingPromptChange = { [weak self] question in
            self?.pendingQuestion = question
        }
    }

    func isAvailable(for backend: AIModelBackend) -> Bool {
        BrowserAgentEngineFactory.isAvailable(for: backend)
    }

    func canOfferAgent(for backend: AIModelBackend) -> Bool {
        BrowserAgentEngineSelection.canOfferAgent(for: backend)
    }

    func status(for backend: AIModelBackend) -> String {
        BrowserAgentEngineFactory.status(for: backend)
    }

    var isAppleInformationRun: Bool {
        isRunning && runIsAppleInformationRun
    }

    // MARK: Control

    /// Runs `task` in `webView`. `conversation` is earlier chat for follow-ups
    /// ("add that one to the cart"). `onComplete` receives the answer with a
    /// short list of the steps taken, once the run ends for any reason.
    func start(
        task: String,
        preset: Preset = .standard,
        conversation: String?,
        in webView: WKWebView,
        openTab: TabOpener?,
        browserAdapter: BrowserAgentBrowserAdapter? = nil,
        backend: AIModelBackend = .chatGPTPlan,
        startingTabIsPrivate: Bool = false,
        savedTaskID: UUID? = nil,
        requestID: UUID? = nil,
        onAutofillQuarantine: AutofillQuarantineHandler? = nil,
        onPageQuestion: ((String) -> Void)? = nil,
        onRunCompleted: ((CompletionSnapshot) -> Void)? = nil,
        onComplete: @escaping (String) -> Void
    ) {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTask = autofillPrivacy.redactPotentiallyTruncated(trimmed, wasTruncated: true)
        let safeConversation = conversation.map { autofillPrivacy.redactPotentiallyTruncated($0, wasTruncated: true) }
        guard !safeTask.isEmpty, !isRunning else { return }
        steps = [Step(kind: .task, text: safeTask)]
        isRunning = true
        let appleInformationPreset = BrowserAppleWebLookup.supportsBackend(backend)
            && (preset == .automaticApple || preset == .webLookup)
        runPreset = appleInformationPreset
            ? preset
            : (preset == .research || BrowserAgentRouter.isResearchIntent(safeTask) ? .research : .standard)
        runIsAppleInformationRun = appleInformationPreset
        runUsedBrowserPath = false
        lookupSources = []
        let id = UUID()
        runID = id
        let dataStore = webView.configuration.websiteDataStore
        let resolvedPrivate = startingTabIsPrivate
            || browserAdapter?.startingTabIsIncognito(for: webView) == true
            || !dataStore.isPersistent
        runContext = RunContext(
            id: id,
            task: safeTask,
            backend: backend.rawValue,
            preset: Self.presetName(for: runPreset),
            startURL: Self.historySafeStartURL(webView.url),
            isPrivate: resolvedPrivate,
            savedTaskID: savedTaskID,
            requestID: requestID,
            startedAt: Date()
        )
        runApprovals = []
        runQuestions = []
        runExports = []
        runEndStatus = nil
        handoffRequests = []
        self.onComplete = onComplete
        self.onRunCompleted = onRunCompleted
        self.onPageQuestion = onPageQuestion
        self.onAutofillQuarantine = onAutofillQuarantine
        self.openTab = openTab
        if let browserAdapter, browserAdapter.beginRun(in: webView) {
            self.browserAdapter = browserAdapter
            runWebsiteDataStore = webView.configuration.websiteDataStore
            runIsPrivate = resolvedPrivate || browserAdapter.runIncognitoMode == true
        } else {
            browserAdapter?.endRun()
            self.browserAdapter = nil
            if browserAdapter == nil {
                runWebsiteDataStore = webView.configuration.websiteDataStore
                runIsPrivate = resolvedPrivate
            } else {
                runWebsiteDataStore = nil
                runIsPrivate = resolvedPrivate
            }
        }
        datasets = [:]
        datasetOrder = []
        comparisons = [:]
        readPageKeys = []
        runDeclaredToolNames = []
        runTask = Task { [weak self, weak webView] in
            guard let self else { return }
            await self.run(task: safeTask, conversation: safeConversation, webView: webView, backend: backend, token: id)
            // A stopped run can end after a newer one has started.
            if self.runID == id {
                self.finishRun(for: id)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        let stoppedRunID = runContext?.id
        runEndStatus = .stopped
        questionGate.cancel()
        runTask?.cancel()
        resolveConfirmation(false)
        append(.note, "Stopped.")
        runID = UUID()
        if let stoppedRunID { finishRun(for: stoppedRunID) }
    }

    private func finishRun(for expectedRunID: UUID) {
        guard let context = runContext, context.id == expectedRunID else { return }
        let completion = completionSnapshot(context: context, steps: steps, date: Date())
        let summary = Self.summary(of: steps)
        let handler = onComplete
        let completionHandler = onRunCompleted
        questionGate.cancel()
        runTask = nil
        isRunning = false
        pendingConfirmation = nil
        openTab = nil
        activeWebView = nil
        browserAdapter?.endRun()
        browserAdapter = nil
        runWebsiteDataStore = nil
        runIsPrivate = false
        datasets = [:]
        datasetOrder = []
        comparisons = [:]
        runProfile = nil
        runPreset = .standard
        runDeclaredToolNames = []
        runIsAppleInformationRun = false
        runUsedBrowserPath = false
        lookupSources = []
        runApprovals = []
        runQuestions = []
        runExports = []
        runEndStatus = nil
        runContext = nil
        onComplete = nil
        onRunCompleted = nil
        onPageQuestion = nil
        onAutofillQuarantine = nil
        steps = []
        handler?(summary)
        completionHandler?(completion)
    }

    private func completionSnapshot(context: RunContext, steps: [Step], date: Date) -> CompletionSnapshot {
        let rawOutcome = steps.last { $0.kind == .answer }?.text
            ?? steps.last { $0.kind == .error }.map { "Couldn't finish: \($0.text)" }
            ?? steps.last { $0.kind == .note }?.text
            ?? "Stopped."
        let outcome = autofillPrivacy.redactPotentiallyTruncated(rawOutcome, wasTruncated: true)
        let actions = steps
            .filter { $0.kind == .action || $0.kind == .note || $0.kind == .error }
            .map { autofillPrivacy.redactPotentiallyTruncated($0.text, wasTruncated: true) }
        let lastTerminal = steps.last { $0.kind == .answer || $0.kind == .error }
        let derivedStatus: AgentRunStatus = lastTerminal?.kind == .error ? .failed : .completed
        let isPrivate = context.isPrivate
        return CompletionSnapshot(
            runID: context.id,
            task: autofillPrivacy.redactPotentiallyTruncated(context.task, wasTruncated: true),
            outcome: outcome,
            actions: actions,
            date: date,
            backend: context.backend,
            preset: context.preset,
            startURL: context.startURL,
            isPrivate: isPrivate,
            savedTaskID: context.savedTaskID,
            sources: lookupSources,
            usedBrowserPath: runUsedBrowserPath,
            requestID: context.requestID,
            startedAt: context.startedAt,
            status: runEndStatus ?? derivedStatus,
            approvals: isPrivate ? [] : runApprovals,
            questions: isPrivate ? [] : runQuestions,
            exportedFiles: isPrivate ? [] : runExports
        )
    }

    /// Bounds run-history text by characters, then by UTF-8 bytes, after redacting profile values.
    func runHistoryText(_ text: String, characters: Int, utf8Bytes: Int) -> String {
        AgentRunTextLimit.bounded(
            autofillPrivacy.redactPotentiallyTruncated(text, wasTruncated: true),
            characters: characters,
            utf8Bytes: utf8Bytes
        )
    }

    /// Records an approval decision. Private runs, and runs that have already ended, record nothing.
    func recordRunApproval(reason: String, host: String?, decision: AgentRunApprovalDecision) {
        guard let context = runContext, !context.isPrivate,
              runApprovals.count < AgentTaskStore.maximumApprovalsPerRun else { return }
        runApprovals.append(AgentRunApproval(
            reason: runHistoryText(
                reason,
                characters: 300,
                utf8Bytes: AgentTaskStore.maximumRunReasonUTF8Bytes
            ),
            host: host.map {
                AgentRunTextLimit.bounded($0, characters: 253, utf8Bytes: AgentTaskStore.maximumRunHostUTF8Bytes)
            },
            decision: decision,
            date: Date()
        ))
    }

    /// Records that the agent asked `prompt`. The answer is never stored; the returned ID is used to mark the question finished.
    func beginRunQuestion(_ prompt: String) -> UUID? {
        guard let context = runContext, !context.isPrivate,
              runQuestions.count < AgentTaskStore.maximumQuestionsPerRun else { return nil }
        let question = AgentRunQuestion(
            prompt: runHistoryText(prompt, characters: 600, utf8Bytes: AgentTaskStore.maximumRunQuestionUTF8Bytes),
            answered: false,
            date: Date()
        )
        runQuestions.append(question)
        return question.id
    }

    func finishRunQuestion(_ id: UUID?, answered: Bool) {
        guard let id, let index = runQuestions.firstIndex(where: { $0.id == id }) else { return }
        runQuestions[index].answered = answered
    }

    /// Queues a prepared handoff for the user. Returns false when this run already has the maximum.
    /// Nothing is presented or sent here; the sidebar shows the request after the run ends.
    @discardableResult
    func enqueueHandoffRequest(_ kind: AgentHandoffRequest.Kind) -> Bool {
        guard handoffRequests.count < Self.maxHandoffRequestsPerRun else { return false }
        handoffRequests.append(AgentHandoffRequest(kind: kind))
        return true
    }

    /// Removes a handoff after the user confirms or cancels it.
    func dismissHandoffRequest(_ id: UUID) {
        handoffRequests.removeAll { $0.id == id }
    }

    private static func presetName(for preset: Preset) -> String {
        switch preset {
        case .research:
            return "research"
        case .webLookup:
            return "lookup"
        case .automaticApple:
            return "automatic"
        case .standard:
            return "standard"
        }
    }

    private static func historySafeStartURL(_ url: URL?) -> URL? {
        guard let url, AgentTaskURLParser.isAllowedStartURL(url) else { return nil }
        return url
    }

    /// The final answer (or error), followed by the actions taken.
    private static func summary(of steps: [Step]) -> String {
        let outcome = steps.last { $0.kind == .answer }?.text
            ?? steps.last { $0.kind == .error }.map { "Couldn't finish: \($0.text)" }
            ?? steps.last { $0.kind == .note }?.text
            ?? "Stopped."
        let actions = steps.filter { $0.kind == .action }.map(\.text)
        guard !actions.isEmpty else { return outcome }
        let shown = actions.prefix(8).joined(separator: " → ")
        let more = actions.count > 8 ? " → +\(actions.count - 8) more" : ""
        return outcome + "\n\nSteps: " + shown + more
    }

    func append(_ kind: Step.Kind, _ text: String) {
        steps.append(Step(kind: kind, text: autofillPrivacy.redactKnownValues(text)))
    }

    // MARK: Loop

    private func run(task: String, conversation: String?, webView: WKWebView?, backend: AIModelBackend, token: UUID) async {
        if runIsAppleInformationRun, await runAppleInformationRoute(task: task, backend: backend, webView: webView, token: token) {
            return
        }
        runUsedBrowserPath = true
        guard let engine = engineFactory(backend) else {
            let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            append(.error, BrowserAgentEngineSelection.unsupportedMessage(
                for: backend,
                iOSMajorVersion: major,
                chatGPTPlanEnabled: ChatGPTPlanAvailability.isEnabled
            ))
            return
        }
        guard let webView else {
            append(.error, "No webpage is open.")
            return
        }
        activeWebView = webView

        do {
            try await engine.prepare()
            try Task.checkCancellation()
            guard isCurrentRun(token) else { return }
            let requestedPreset = runPreset
            let baseProfile = engine.profile
            let profile = requestedPreset == .research && baseProfile.localContextSize == nil
                ? baseProfile.withMaximumSteps(40)
                : baseProfile
            runProfile = profile
            if let contextSize = profile.localContextSize,
               !BrowserAgentLocalContext.taskFits(task, contextSize: contextSize) {
                throw BrowserAgentEngineFailure.contextTooLarge
            }
            let snapshot = try await snapshotText(of: webView, profile: profile)
            let initialPrompt: String
            if let contextSize = profile.localContextSize {
                initialPrompt = BrowserAgentLocalContext.makeInitialPrompt(
                    task: task,
                    conversation: conversation,
                    snapshot: snapshot,
                    snapshotMarker: Self.snapshotMarker,
                    contextSize: contextSize
                )
            } else {
                let earlier = conversation.map {
                    "Earlier in this conversation (for reference):\n\(bounded($0, to: profile.recentConversationCharacters))\n\n"
                } ?? ""
                initialPrompt = earlier + "Task: \(task)" + Self.snapshotMarker + snapshot + "\n</page_snapshot>"
            }
            let tools = Self.toolsForRun(
                task: task,
                browserAdapterAvailable: browserAdapter != nil,
                fetchPageAvailable: runWebsiteDataStore != nil,
                coreOnly: profile.toolPolicy == .coreOnly,
                supportsVision: profile.supportsVision,
                readChunkCharacters: profile.readChunkCharacters
            )
            runDeclaredToolNames = Set(tools.compactMap { $0["name"] as? String })
            var instructions: String
            if profile.localContextSize != nil {
                instructions = Self.localInstructions + (requestedPreset == .research ? "\n\n" + Self.localResearchUnavailableInstructions : "")
            } else if requestedPreset == .research {
                instructions = Self.instructions + "\n\n" + Self.researchInstructions
            } else {
                instructions = Self.instructions
            }
            if backend == .cloudShortcuts {
                instructions += "\n\n" + Self.appleTaskScopeInstructions
            }
            let request = BrowserAgentEngineRequest(
                initialPrompt: initialPrompt,
                tools: tools,
                instructions: instructions,
                profile: profile,
                snapshotMarker: Self.snapshotMarker,
                maximumAnswerCharacters: requestedPreset == .research && profile.localContextSize == nil ? 20_000 : nil
            )
            let executeTool: BrowserAgentToolExecutor = { [weak self, weak webView] name, argumentsJSON in
                guard let self, let initialWebView = webView,
                      self.isCurrentRun(token) else {
                    return BrowserAgentToolOutput(text: "Cancelled.")
                }
                guard self.runDeclaredToolNames.contains(name) else {
                    return BrowserAgentToolOutput(text: "That tool was not included in this run. Use only the tools listed for the current task.")
                }
                let arguments = Self.parseArguments(argumentsJSON)
                return await self.execute(
                    name: name,
                    arguments: arguments,
                    in: self.activeWebView ?? initialWebView,
                    token: token
                )
            }
            let note: BrowserAgentNoteHandler = { [weak self] text in
                guard let self, self.isCurrentRun(token) else { return }
                self.append(.note, text)
            }
            let answer = try await engine.run(request: request, execute: executeTool, onNote: note)
            guard isCurrentRun(token) else { return }
            append(.answer, answer.isEmpty ? "Done." : answer)
        } catch is CancellationError {
            // stop() already logged it.
        } catch {
            if !Task.isCancelled {
                if let failure = error as? BrowserAgentEngineFailure, case .stepLimit(_) = failure {
                    runEndStatus = .stepLimit
                }
                append(.error, error.localizedDescription)
            }
        }
    }

    private func runAppleInformationRoute(task: String, backend: AIModelBackend, webView: WKWebView?, token: UUID) async -> Bool {
        guard isCurrentRun(token) else { return true }
        var route: BrowserAppleWebLookup.Route
        if runPreset == .webLookup {
            route = .lookup
        } else {
            append(.note, "Choosing how to help")
            do {
                route = try await appleLookup.classify(task: task, backend: backend)
            } catch is CancellationError {
                return true
            } catch {
                guard isCurrentRun(token) else { return true }
                append(.note, "Couldn't classify the request. Use /search, /ask or /do to choose a mode.")
                return true
            }
        }
        return await handleAppleInformationRoute(route, task: task, backend: backend, webView: webView, token: token)
    }

    private func handleAppleInformationRoute(
        _ route: BrowserAppleWebLookup.Route,
        task: String,
        backend: AIModelBackend,
        webView: WKWebView?,
        token: UUID
    ) async -> Bool {
        guard isCurrentRun(token) else { return true }
        switch route {
        case .lookup:
            do {
                guard let adapter = browserAdapter, let startingStore = runWebsiteDataStore,
                      let webView else {
                    append(.note, "Public lookup needs an open browser tab. Use /ask to ask directly.")
                    return true
                }
                _ = try adapter.validate(webView: webView)
                let searchURL = try adapter.searchURL(query: task)
                let urlPolicy: BrowserAgentBackgroundLoader.FetchURLPolicy = { [weak self] candidate, _ in
                    guard let self else { return false }
                    return BrowserAppleWebLookup.isPublicLookupURL(candidate)
                        && !self.autofillPrivacy.blocksBackgroundFetch(
                            url: candidate,
                            startingDataStore: startingStore
                        )
                }
                let result = try await appleLookup.lookup(
                    task: task,
                    backend: backend,
                    searchURL: searchURL,
                    isPrivate: runContext?.isPrivate ?? runIsPrivate,
                    urlPolicy: urlPolicy
                ) { [weak self] label in
                    guard let self, self.isCurrentRun(token) else { return }
                    self.append(.note, label)
                }
                guard isCurrentRun(token) else { return true }
                lookupSources = result.sources
                append(.answer, result.answer)
            } catch is CancellationError {
                return true
            } catch {
                guard isCurrentRun(token) else { return true }
                append(.error, error.localizedDescription)
            }
            return true
        case .page:
            guard let callback = onPageQuestion else {
                append(.note, "Use /ask to ask about the current page.")
                return true
            }
            onComplete = nil
            onRunCompleted = nil
            finishRun(for: token)
            callback(task)
            return true
        case .browser:
            runPreset = BrowserAgentRouter.isResearchIntent(task) ? .research : .standard
            return false
        case .clarify:
            let clarifyPrompt = "Search the public web, read the current page, or operate the browser? Reply search, page, or browser."
            let questionID = beginRunQuestion(clarifyPrompt)
            let reply = await questionGate.ask(UserQuestion(prompt: clarifyPrompt))
            finishRunQuestion(questionID, answered: reply != nil)
            guard isCurrentRun(token) else { return true }
            switch reply?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "search":
                return await handleAppleInformationRoute(.lookup, task: task, backend: backend, webView: webView, token: token)
            case "page":
                return await handleAppleInformationRoute(.page, task: task, backend: backend, webView: webView, token: token)
            case "browser":
                runPreset = BrowserAgentRouter.isResearchIntent(task) ? .research : .standard
                return false
            default:
                append(.note, "No action taken. Use /search, /ask or /do to choose a mode.")
                return true
            }
        }
    }

    private static func parseArguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    // MARK: Tools

    private func execute(name: String, arguments: [String: Any], in webView: WKWebView, token: UUID) async -> BrowserAgentToolOutput {
        guard isCurrentRun(token) else { return BrowserAgentToolOutput(text: "Cancelled.") }
        let urlBefore = webView.url
        do {
            var result: ToolResult
            do {
                result = try await runTool(name: name, arguments: arguments, in: webView, token: token)
            } catch let error where !(error is CancellationError)
                && ["click", "type_text", "press_key", "set_checked", "dismiss_overlays"].contains(name)
                && (webView.isLoading || webView.url != urlBefore) {
                // A click that navigates can tear down the page before the
                // script's reply arrives; the action itself went through.
                if name == "click" {
                    append(.action, "Click (page is loading)")
                } else if name == "type_text" {
                    append(.action, "Type (page is loading)")
                } else {
                    append(.action, "Perform \(name.replacingOccurrences(of: "_", with: " ")) (page is loading)")
                }
                result = .withSnapshot("Done; the page started loading something new.")
            }
            guard isCurrentRun(token) else { return BrowserAgentToolOutput(text: "Cancelled.") }
            switch result {
            case .plain(let text):
                return BrowserAgentToolOutput(text: autofillPrivacy.redactThenBound(text, using: localBoundedToolText))
            case .withImage(let text, let imageData):
                return BrowserAgentToolOutput(text: autofillPrivacy.redactThenBound(text, using: localBoundedToolText), imageData: imageData)
            case .withSnapshot(let text):
                // open_tab switches the agent to the new tab's web view.
                let target = activeWebView ?? webView
                await waitForPageToSettle(target)
                guard isCurrentRun(token) else { return BrowserAgentToolOutput(text: "Cancelled.") }
                var resultsBlock = ""
                if name == "web_search", runProfile?.localContextSize != nil {
                    resultsBlock = await localSearchResultsBlock(in: target)
                }
                let snapshot = try await snapshotText(
                    of: target,
                    forToolOutput: true,
                    reservedBytes: resultsBlock.isEmpty ? 0 : resultsBlock.utf8.count + 1
                )
                guard isCurrentRun(token) else { return BrowserAgentToolOutput(text: "Cancelled.") }
                if !resultsBlock.isEmpty {
                    let confirmed = await localSearchResultsBlock(in: target)
                    if confirmed != resultsBlock { resultsBlock = "" }
                }
                guard isCurrentRun(token) else { return BrowserAgentToolOutput(text: "Cancelled.") }
                let prefix: String
                if runProfile?.localContextSize != nil {
                    prefix = autofillPrivacy.redactThenBound(text) {
                        BrowserAgentLocalContext.boundedUTF8($0, to: 96)
                    }
                } else {
                    prefix = autofillPrivacy.redactKnownValues(text)
                }
                var snapshotBody = snapshot
                if !resultsBlock.isEmpty {
                    if let heading = snapshot.range(of: "Interactive elements (") {
                        snapshotBody = String(snapshot[..<heading.lowerBound])
                            + resultsBlock + "\n" + snapshot[heading.lowerBound...]
                    } else {
                        snapshotBody = resultsBlock + "\n" + snapshot
                    }
                }
                return BrowserAgentToolOutput(text: autofillPrivacy.redactKnownValues(prefix + Self.snapshotMarker + snapshotBody + "\n</page_snapshot>"))
            }
        } catch is CancellationError {
            return BrowserAgentToolOutput(text: "Cancelled.")
        } catch {
            let safeError = autofillPrivacy.redactThenBound(error.localizedDescription, using: localBoundedToolText)
            if isCurrentRun(token) { append(.error, safeError) }
            return BrowserAgentToolOutput(text: "Error: \(safeError)")
        }
    }

    func isCurrentRun(_ token: UUID) -> Bool {
        isRunning && runID == token && !Task.isCancelled
    }

    private func localBoundedToolText(_ text: String) -> String {
        guard let contextSize = runProfile?.localContextSize else { return text }
        return BrowserAgentLocalContext.boundedToolResult(text, contextSize: contextSize)
    }

    private func localSearchResultsBlock(in webView: WKWebView) async -> String {
        guard let response = try? await callJSON(
            BrowserAgentPageScript.searchResults,
            ["maxResults": 5],
            in: webView
        ), let items = response["results"] as? [[String: Any]] else { return "" }
        let results = items.compactMap { item -> (id: Int, title: String, url: String)? in
            guard let id = Self.intArgument(item["id"]),
                  let title = item["title"] as? String,
                  let url = item["url"] as? String else { return nil }
            return (id, title, url)
        }
        return autofillPrivacy.redactKnownValues(
            BrowserAgentLocalContext.searchResultsBlock(results, maximumBytes: 420)
        )
    }

    /// Native page translation may outlive a successful agent finish, but Stop and a newer run
    /// replace this generation and invalidate any work that still belongs to the old request.
    func isCurrentRunGeneration(_ token: UUID) -> Bool {
        runID == token
    }

    func resolveConfirmation(id: UUID, allowed: Bool, alwaysAllow: Bool = false) {
        guard let pending = pendingConfirmation, pending.id == id else { return }
        pendingConfirmation = nil
        confirmationContinuation?.resume(returning: ConfirmationDecision(
            id: id,
            allowed: allowed,
            alwaysAllow: allowed && alwaysAllow
        ))
        confirmationContinuation = nil
    }

    func requestConfirmationDecision(
        summary: String,
        reason: String,
        id: UUID = UUID(),
        allowsSiteTrust: Bool = false
    ) async -> ConfirmationDecision {
        let owningRunID = runContext?.id
        let decision: ConfirmationDecision = await withCheckedContinuation { continuation in
            if let previous = pendingConfirmation {
                confirmationContinuation?.resume(returning: ConfirmationDecision(id: previous.id, allowed: false, alwaysAllow: false))
            }
            confirmationContinuation = continuation
            pendingConfirmation = Confirmation(id: id, summary: summary, reason: reason, allowsSiteTrust: allowsSiteTrust)
        }
        // A late resume after Stop, or after a newer run started, must not write into that run's history.
        if let owningRunID, runContext?.id == owningRunID {
            let host = activeWebView?.url?.host.flatMap(AgentTrustStore.canonicalHost)
            let recorded: AgentRunApprovalDecision = decision.allowed
                ? (decision.alwaysAllow ? .alwaysAllowed : .allowed)
                : .denied
            recordRunApproval(reason: reason, host: host, decision: recorded)
        }
        return decision
    }

    enum ToolResult {
        /// Sent back as-is (errors, page text).
        case plain(String)
        /// Followed by a fresh page snapshot once the page settles.
        case withSnapshot(String)
        /// A screenshot result carries pixels separately so only vision engines receive them.
        case withImage(String, Data)
    }
}

struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
