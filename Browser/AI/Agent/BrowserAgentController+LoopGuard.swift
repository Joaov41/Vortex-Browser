//
//  BrowserAgentController+LoopGuard.swift
//  Vortex
//
//  Checks each tool call against the run's loop detector before it runs. A
//  repeated call gets a warning, then is skipped, and a call that keeps coming
//  back ends the run as failed. ask_user and finish pass straight through.
//

import Foundation
import WebKit

extension BrowserAgentController {
    private static let maximumLoopToolNameCharacters = 40
    private static let scrollPositionScript = "return [Math.round(scrollX), Math.round(scrollY)].join(',');"

    func executeCheckingForLoops(
        name: String,
        argumentsJSON: String,
        in webView: WKWebView,
        token: UUID,
        perform: () async -> BrowserAgentToolOutput
    ) async -> BrowserAgentToolOutput {
        guard !BrowserAgentToolLoopDetector.untrackedToolNames.contains(name) else {
            _ = toolLoopDetector.record(name: name, argumentsJSON: argumentsJSON)
            return await perform()
        }
        let pageState = await loopPageState(of: webView)
        guard isCurrentRun(token) else { return BrowserAgentToolOutput(text: "Cancelled.") }
        let shownName = String(name.prefix(Self.maximumLoopToolNameCharacters))
        switch toolLoopDetector.record(name: name, argumentsJSON: argumentsJSON, pageState: pageState) {
        case .allow:
            return await perform()
        case .warn(let repeats):
            let output = await perform()
            guard isCurrentRun(token) else { return output }
            var text = BrowserAgentToolLoopDetector.warningText(toolName: shownName, repeats: repeats) + output.text
            if let contextSize = runProfile?.localContextSize {
                text = BrowserAgentLocalContext.boundedToolResult(text, contextSize: contextSize)
            }
            return BrowserAgentToolOutput(text: text, imageData: output.imageData)
        case .block(let repeats):
            append(.note, "Skipped a repeated \(BrowserAgentToolLoopDetector.readableName(shownName)) action.")
            return BrowserAgentToolOutput(text: BrowserAgentToolLoopDetector.blockedText(toolName: shownName, repeats: repeats))
        case .stop:
            endRunAsFailed(BrowserAgentToolLoopDetector.stoppedMessage(toolName: shownName), token: token)
            return BrowserAgentToolOutput(text: "Cancelled. The run was stopped because it kept repeating the same action.")
        }
    }

    /// The page's address and scroll position. Scrolling further down a long page changes it, so
    /// that is progress rather than a repeat; scrolling at the bottom does not change it.
    private func loopPageState(of webView: WKWebView) async -> String {
        let address = webView.url?.absoluteString ?? ""
        let position = try? await AsyncTimeout.run(
            seconds: 1,
            timeoutError: { ScriptTimeout() },
            operation: { @MainActor in
                try await webView.callAsyncJavaScript(
                    Self.scrollPositionScript,
                    arguments: [:],
                    in: nil,
                    contentWorld: BrowserAgentPageScript.world
                ) as? String
            }
        )
        return address + " @" + (position ?? "")
    }
}
