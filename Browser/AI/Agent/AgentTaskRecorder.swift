//
//  AgentTaskRecorder.swift
//  Vortex
//
//  Teach mode. Records the user's actions on one regular tab so they can be saved
//  as a task. The page script is installed only while recording and is removed on
//  stop. Recorded values are limited to plain text, search and select inputs that
//  the agent's sensitive-field detector does not flag. Nothing here is persisted
//  until the user saves the task.
//

import Foundation
import WebKit
import Combine

enum AgentTaskRecorderError: LocalizedError, Equatable {
    case privateTab
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .privateTab: return "Task recording is not available in private tabs."
        case .alreadyRecording: return "A task is already being recorded. Stop it before starting another."
        }
    }
}

@MainActor
final class AgentTaskRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var stepCount = 0
    @Published private(set) var limitReached = false

    private(set) var recordedTabID: UUID?
    private weak var webView: WKWebView?
    private var handler: AgentTaskRecorderMessageHandler?
    private var installedScript: WKUserScript?
    private(set) var steps: [RecordedStep] = []
    private var startURL: URL?
    private var pageTitle: String?
    private var documentNonce: String?
    private var documentURL: URL?
    /// Set by a step whose click or submit navigates. The next page load then belongs to that step.
    private var lastStepCausedNavigation = false

    /// Starts recording on a live page. Refuses private tabs and a second recording.
    func start(tabID: UUID, webView: WKWebView, isPrivate: Bool) async throws {
        guard !isRecording else { throw AgentTaskRecorderError.alreadyRecording }
        guard !isPrivate else { throw AgentTaskRecorderError.privateTab }

        let controller = webView.configuration.userContentController
        let handler = AgentTaskRecorderMessageHandler(recorder: self)
        controller.removeScriptMessageHandler(
            forName: AgentTaskRecorderScript.messageHandlerName,
            contentWorld: AgentTaskRecorderScript.world
        )
        controller.add(
            handler,
            contentWorld: AgentTaskRecorderScript.world,
            name: AgentTaskRecorderScript.messageHandlerName
        )
        let script = WKUserScript(
            source: AgentTaskRecorderScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: AgentTaskRecorderScript.world
        )
        controller.addUserScript(script)

        self.handler = handler
        installedScript = script
        self.webView = webView
        recordedTabID = tabID
        steps = []
        stepCount = 0
        limitReached = false
        startURL = Self.sanitizedURL(webView.url?.absoluteString)
        pageTitle = nil
        documentNonce = nil
        documentURL = nil
        lastStepCausedNavigation = false
        isRecording = true

        // Covers the page that is already open. Later pages get the script from the user-script list.
        _ = try? await webView.evaluateJavaScript(
            AgentTaskRecorderScript.source,
            in: nil,
            contentWorld: AgentTaskRecorderScript.world
        )
    }

    /// Ends the recording, removes the page script and message handler, and returns what was captured.
    @discardableResult
    func stop() -> AgentTaskRecording? {
        guard isRecording else { return nil }
        let recording = AgentTaskRecording(
            steps: steps,
            startURL: startURL,
            pageTitle: pageTitle,
            limitReached: limitReached
        )
        if let webView {
            Task {
                _ = try? await webView.evaluateJavaScript(
                    AgentTaskRecorderScript.teardownSource,
                    in: nil,
                    contentWorld: AgentTaskRecorderScript.world
                )
            }
            let controller = webView.configuration.userContentController
            controller.removeScriptMessageHandler(
                forName: AgentTaskRecorderScript.messageHandlerName,
                contentWorld: AgentTaskRecorderScript.world
            )
            if let installedScript {
                // Keep every other script. Only this recorder's script object is dropped.
                ManagedUserScript.replaceAppScripts(
                    controller.userScripts.filter { $0 !== installedScript },
                    in: controller
                )
            }
        }
        reset()
        return recording
    }

    /// Stops an active recording when the user moves to a private tab. Returns true when it stopped.
    @discardableResult
    func selectedTabDidChange(toPrivate isPrivate: Bool) -> Bool {
        guard isRecording, isPrivate else { return false }
        stop()
        return true
    }

    /// Entry point for messages from the page script. Testable without a live page.
    func handle(_ body: Any) {
        guard isRecording, let payload = body as? [String: Any],
              let type = payload["type"] as? String else { return }
        switch type {
        case "ready":
            handleReady(payload)
        case "step":
            if let raw = payload["step"] as? [String: Any] {
                record(raw)
            }
        default:
            return
        }
    }

    /// Only http and https addresses are kept. Query strings and fragments are dropped,
    /// because they often carry tokens or search terms that should not be stored.
    static func sanitizedURL(_ raw: String?) -> URL? {
        guard let raw, var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        guard let url = components.url, AgentTaskURLParser.isAllowedStartURL(url) else { return nil }
        return url
    }

    private func handleReady(_ payload: [String: Any]) {
        if pageTitle == nil, let title = payload["title"] as? String {
            let cleaned = Self.collapsed(title)
            if !cleaned.isEmpty { pageTitle = String(cleaned.prefix(160)) }
        }
        guard let nonce = payload["nonce"] as? String, nonce != documentNonce else { return }
        let url = Self.sanitizedURL(payload["url"] as? String)
        let isFirstDocument = documentNonce == nil
        documentNonce = nonce
        if isFirstDocument {
            documentURL = url
            if startURL == nil { startURL = url }
            return
        }

        let causedByStep = lastStepCausedNavigation
        lastStepCausedNavigation = false
        let previousURL = documentURL
        documentURL = url
        // A link or submit that navigated is already a step. Only typed or other page loads add a navigate step.
        guard !causedByStep, let url, url != previousURL else { return }
        append(RecordedStep(
            kind: .navigate,
            label: "",
            role: "",
            selectorHint: "",
            url: url,
            value: nil,
            needsUserInput: false
        ))
    }

    private func record(_ raw: [String: Any]) {
        guard let kindName = raw["kind"] as? String,
              let kind = RecordedStep.Kind(rawValue: kindName),
              kind != .navigate,
              let url = Self.sanitizedURL(raw["url"] as? String) else { return }

        let navigates = (raw["navigates"] as? Bool) ?? false
        lastStepCausedNavigation = navigates
        guard steps.count < AgentTaskRecipeLimits.maximumSteps else {
            limitReached = true
            return
        }

        var value = (raw["value"] as? String).map {
            String($0.prefix(AgentTaskRecipeLimits.maximumValueCharacters))
        }
        var needsUserInput = (raw["needsUserInput"] as? Bool) ?? false
        if kind == .click || kind == .submit {
            value = nil
            needsUserInput = false
        }
        if needsUserInput {
            value = nil
        }
        if kind == .input || kind == .select {
            // A value that echoes a profile value filled earlier in this session is treated as sensitive.
            if let known = value, BrowserAgentAutofillPrivacy.shared.redactKnownValues(known) != known {
                value = nil
            }
            if value == nil { needsUserInput = true }
            if value?.isEmpty == true { return }
        }

        append(RecordedStep(
            kind: kind,
            label: String(Self.collapsed(raw["label"] as? String ?? "").prefix(AgentTaskRecipeLimits.maximumLabelCharacters)),
            role: String(Self.collapsed(raw["role"] as? String ?? "").prefix(AgentTaskRecipeLimits.maximumRoleCharacters)),
            selectorHint: String(Self.collapsed(raw["selectorHint"] as? String ?? "").prefix(AgentTaskRecipeLimits.maximumSelectorHintCharacters)),
            url: url,
            value: value,
            needsUserInput: needsUserInput
        ))
    }

    private func append(_ step: RecordedStep) {
        guard AgentTaskRecipe.isValid(step), steps.count < AgentTaskRecipeLimits.maximumSteps else { return }
        steps.append(step)
        stepCount = steps.count
    }

    private func reset() {
        isRecording = false
        recordedTabID = nil
        webView = nil
        handler = nil
        installedScript = nil
        steps = []
        stepCount = 0
        limitReached = false
        startURL = nil
        pageTitle = nil
        documentNonce = nil
        documentURL = nil
        lastStepCausedNavigation = false
    }

    private static func collapsed(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Forwards page-script messages to the recorder. Only the recorder's own content world can reach it.
@MainActor
final class AgentTaskRecorderMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var recorder: AgentTaskRecorder?

    init(recorder: AgentTaskRecorder) {
        self.recorder = recorder
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == AgentTaskRecorderScript.messageHandlerName,
              message.frameInfo.isMainFrame else { return }
        recorder?.handle(message.body)
    }
}
