//
//  BrowserAgentController+Confirmation.swift
//  Vortex
//
//  Approval and question flow for the browser agent: confirmation prompts, one-shot approval binding for risky page actions, Apple purchase scope and the resolve handlers.

import Foundation
import WebKit
import Combine
import UIKit

extension BrowserAgentController {
    func resolveConfirmation(_ allowed: Bool) {
        guard let pendingConfirmation else { return }
        resolveConfirmation(id: pendingConfirmation.id, allowed: allowed)
    }

    func resolveUserQuestion(_ answer: String?) {
        let normalized = answer.map { bounded($0.trimmingCharacters(in: .whitespacesAndNewlines), to: 2_000) }
        questionGate.resolve(normalized?.isEmpty == true ? nil : normalized)
    }

    func resolveUserQuestion(_ answer: String?, id: UUID) {
        guard pendingQuestion?.id == id else { return }
        resolveUserQuestion(answer)
    }

    static func applePurchaseIsOutOfScope(
        backend: AIModelBackend?, task: String, reason: String, target: String
    ) -> Bool {
        guard backend == .localApple || backend == .cloudShortcuts else { return false }
        let purchasePattern = #"\b(?:buy|purchase|pay|checkout|check out|place order|order now|book now|reserve|add to (?:cart|bag|basket))\b"#
        guard (reason + " " + target).range(of: purchasePattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            return false
        }
        let normalized = task.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "’", with: "'")
        let negation = #"\b(?:no|not|never|don't|do not|without)\b"#
        if normalized.range(of: negation, options: .regularExpression) != nil { return true }
        let command = #"^(?:(?:please|pls|can you|could you|would you|will you|help me|i want to|i'd like to)\s+)*(?:buy|purchase|pay|checkout|check out|place (?:an? |the )?order|order|book|reserve)\b"#
        return normalized.range(of: command, options: .regularExpression) == nil
    }

    /// Runs a page action with a native binding to the current run, tab, URL,
    /// document nonce, target ID, and one-shot approval identity. The isolated
    /// page world independently rechecks the same target and form context.
    func performRiskGuarded(
        script: String,
        arguments rawArguments: [String: Any],
        operation: String,
        verb: String,
        in webView: WKWebView,
        token: UUID
    ) async throws -> String {
        let pageURL = webView.url
        let sourceTabID = try browserAdapter?.validate(webView: webView)
        let webViewIdentity = ObjectIdentifier(webView)
        let targetIdentity: String
        if let targetID = Self.intArgument(rawArguments["id"]) {
            targetIdentity = "element:\(targetID)"
        } else {
            targetIdentity = "active-element"
        }
        let expectedDocumentNonce = try await documentNonce(of: webView)
        try await validateRiskBinding(
            webView,
            identity: webViewIdentity,
            tabID: sourceTabID,
            pageURL: pageURL,
            documentNonce: expectedDocumentNonce,
            token: token
        )

        let confirmationID = UUID()
        let confirmationToken = confirmationID.uuidString
        var callArguments = rawArguments
        callArguments["confirmed"] = false
        callArguments["approvalID"] = confirmationToken
        callArguments["expectedDocumentNonce"] = expectedDocumentNonce
        var response = try await callJSON(script, callArguments, in: webView)

        if response["needsConfirmation"] as? Bool == true {
            let contextID = response["contextID"] as? String ?? ""
            guard response["approvalID"] as? String == confirmationToken,
                  contextID == confirmationToken else { throw BrowserToolFailure.stalePage }
            try await validateRiskBinding(
                webView,
                identity: webViewIdentity,
                tabID: sourceTabID,
                pageURL: pageURL,
                documentNonce: expectedDocumentNonce,
                token: token
            )

            let target = response["target"] as? String ?? targetIdentity
            let reason = response["reason"] as? String ?? "action"
            if Self.applePurchaseIsOutOfScope(
                backend: runContext.flatMap { AIModelBackend(rawValue: $0.backend) },
                task: runContext?.task ?? "",
                reason: reason,
                target: target
            ) {
                append(.note, "Skipped a purchase action outside the requested task.")
                return "Purchase not requested. Do not retry. Read another source and answer the current question."
            }
            let protectedContext = response["protectedContext"] as? Bool ?? true
            let host = (browserAdapter == nil || runIsPrivate) ? nil : pageURL?.host.flatMap(AgentTrustStore.canonicalHost)
            let trustEligible = host != nil && AgentTrustStore.isAlwaysAllowEligible(
                reason: reason,
                operation: operation,
                protectedContext: protectedContext,
                isPrivate: runIsPrivate
            )
            let trustStore = trustEligible ? trustStoreProvider() : nil
            let remembered = host.flatMap { host in
                trustStore?.allows(
                    host: host,
                    reason: reason,
                    operation: operation,
                    protectedContext: protectedContext,
                    isPrivate: runIsPrivate
                )
            } ?? false

            let decision: ConfirmationDecision
            if remembered {
                // A standing permission answers this approval without a prompt, so record it as a saved decision.
                recordRunApproval(reason: reason, host: host, decision: .alwaysAllowed)
                decision = ConfirmationDecision(id: confirmationID, allowed: true, alwaysAllow: false)
            } else {
                decision = await requestConfirmationDecision(
                    summary: "\(verb) \(target)",
                    reason: reason,
                    id: confirmationID,
                    allowsSiteTrust: trustEligible
                )
            }
            try Task.checkCancellation()
            guard decision.id == confirmationID, isCurrentRun(token) else { throw CancellationError() }
            guard decision.allowed else {
                append(.note, "You declined: \(verb.lowercased()) \(target).")
                return "The user declined this action (\(reason)). Do not try it again; finish and explain what is left for the user to do."
            }

            try await validateRiskBinding(
                webView,
                identity: webViewIdentity,
                tabID: sourceTabID,
                pageURL: pageURL,
                documentNonce: expectedDocumentNonce,
                token: token
            )
            // Keep the target identity fixed across the confirmation suspension.
            guard targetIdentity == (Self.intArgument(rawArguments["id"]).map { "element:\($0)" } ?? "active-element") else {
                throw BrowserToolFailure.stalePage
            }
            callArguments["confirmed"] = true
            callArguments["confirmationContextID"] = contextID
            response = try await callJSON(script, callArguments, in: webView)
            guard response["ok"] as? Bool == true else { return describe(response, verb: verb) }

            // A navigation/document replacement after the effect may mean the action
            // happened, but it cannot establish a durable site permission.
            try await validateRiskBinding(
                webView,
                identity: webViewIdentity,
                tabID: sourceTabID,
                pageURL: pageURL,
                documentNonce: expectedDocumentNonce,
                token: token
            )
            guard response["approvalContextID"] as? String == contextID else {
                throw BrowserToolFailure.stalePage
            }

            if decision.alwaysAllow, trustEligible, let host, let trustStore {
                _ = trustStore.allow(
                    host: host,
                    reason: reason,
                    operation: operation,
                    protectedContext: protectedContext,
                    isPrivate: runIsPrivate
                )
            }
        } else {
            // Even actions that were initially judged safe must still be tied to
            // the same document. The page script checks its nonce before acting.
            try await validateRiskBinding(
                webView,
                identity: webViewIdentity,
                tabID: sourceTabID,
                pageURL: pageURL,
                documentNonce: expectedDocumentNonce,
                token: token
            )
        }
        return describe(response, verb: verb)
    }

    private func validateRiskBinding(
        _ webView: WKWebView,
        identity: ObjectIdentifier,
        tabID: UUID?,
        pageURL: URL?,
        documentNonce: String,
        token: UUID
    ) async throws {
        guard ObjectIdentifier(webView) == identity,
              activeWebView.map({ $0 === webView }) == true else { throw BrowserToolFailure.stalePage }
        try await validateFreshPage(
            webView,
            tabID: tabID,
            pageURL: pageURL,
            documentNonce: documentNonce,
            token: token
        )
    }

    func documentNonce(of webView: WKWebView) async throws -> String {
        let identity = try await callJSON(BrowserAgentPageScript.documentIdentity, [:], in: webView)
        guard let nonce = identity["nonce"] as? String, !nonce.isEmpty else {
            throw BrowserToolFailure.stalePage
        }
        return nonce
    }

    func restoreScreenshotMask(
        _ expectedNonce: String,
        captureOwner: String,
        maskedElementCount: Int,
        in webView: WKWebView
    ) async throws {
        // This unstructured MainActor task deliberately does not inherit Stop's
        // cancellation, so cleanup can finish after the run has been stopped.
        let cleanup = Task { @MainActor in
            let currentNonce = try await self.documentNonce(of: webView)
            guard currentNonce == expectedNonce else { return }
            let response = try await self.callJSON(
                BrowserAgentPageScript.restoreScreenshotMask,
                ["expectedDocumentNonce": expectedNonce, "captureOwner": captureOwner],
                in: webView,
                timeout: 3
            )
            if response["staleOwner"] as? Bool == true { return }
            guard response["error"] == nil,
                  let restoredCount = Self.intArgument(response["restored"]) else {
                throw BrowserToolFailure.screenshotMaskRestoreFailed("The page did not confirm screenshot-mask restoration.")
            }
            if maskedElementCount > 0, restoredCount == 0 {
                let afterNonce = try await self.documentNonce(of: webView)
                if afterNonce != expectedNonce { return }
                throw BrowserToolFailure.screenshotMaskRestoreFailed("Sensitive page fields remain masked.")
            }
        }
        try await cleanup.value
    }

    func validateFreshPage(
        _ webView: WKWebView,
        tabID: UUID?,
        pageURL: URL?,
        documentNonce: String,
        token: UUID
    ) async throws {
        try Task.checkCancellation()
        guard isCurrentRun(token), webView.url == pageURL else { throw BrowserToolFailure.stalePage }
        if let adapter = browserAdapter, let tabID {
            guard try adapter.validate(webView: webView) == tabID else { throw BrowserToolFailure.stalePage }
        }
        guard try await self.documentNonce(of: webView) == documentNonce else {
            throw BrowserToolFailure.stalePage
        }
    }

    func requestConfirmation(summary: String, reason: String) async -> Bool {
        await requestConfirmationDecision(summary: summary, reason: reason).allowed
    }

}
