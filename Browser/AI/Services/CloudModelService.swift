import Foundation
import Combine
import UIKit

enum CloudShortcutCallbackPolicy {
    enum Outcome: Equatable {
        case success(String?)
        case cancelled
        case failure(String?)
    }

    static let scheme = "webmebrowser"
    static let host = "shortcut"

    static func callbackURL(path: String, requestID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/\(path)"
        components.queryItems = [
            URLQueryItem(name: "requestID", value: requestID.uuidString)
        ]
        return components.url
    }

    static func runURL(shortcutName: String, text: String, requestID: UUID) -> URL? {
        guard let successURL = callbackURL(path: "success", requestID: requestID),
              let cancelURL = callbackURL(path: "cancel", requestID: requestID),
              let errorURL = callbackURL(path: "error", requestID: requestID) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: shortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "x-success", value: successURL.absoluteString),
            URLQueryItem(name: "x-cancel", value: cancelURL.absoluteString),
            URLQueryItem(name: "x-error", value: errorURL.absoluteString)
        ]
        return components.url
    }

    static func outcome(from url: URL, expectedRequestID: UUID) -> Outcome? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?
                .first(where: { $0.name == "requestID" })?
                .value == expectedRequestID.uuidString else {
            return nil
        }

        let value: (String) -> String? = { name in
            components.queryItems?
                .first(where: { $0.name == name })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch components.path {
        case "/success":
            return .success(value("result"))
        case "/cancel":
            return .cancelled
        case "/error":
            return .failure(value("errorMessage"))
        default:
            return nil
        }
    }
}

/// Apple Intelligence integration for iOS 26 through the user's Shortcut.
/// The response is returned by Shortcuts' documented x-callback-url result,
/// rather than accepting any clipboard change that happens during the request.
class CloudModelService: NSObject, ObservableObject {
    private var currentRequestID: UUID?
    private var currentRequestCompletion: ((String) -> Void)?
    private var requestTimeoutTimer: Timer?
    private var originalClipboardChangeCount: Int?
    private let requestTimeoutSeconds: TimeInterval = 120
    private var isRequestInProgress = false

    var shortcutName: String = "RSS Reader Cloud Summary"

    @MainActor
    func launchCloudRequest(
        for text: String,
        type: AppleIntelligenceRequestType,
        completion: ((String) -> Void)?
    ) {
        guard !isRequestInProgress else {
            completion?("Cloud AI service is busy processing another request. Please wait.")
            return
        }

        let trimmedShortcut = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedShortcut.isEmpty else {
            completion?("Please enter a Shortcut name before sending a request.")
            return
        }

        let requestID = UUID()
        guard let url = CloudShortcutCallbackPolicy.runURL(
            shortcutName: trimmedShortcut,
            text: text,
            requestID: requestID
        ) else {
            completion?("Cloud AI service could not create the Shortcut URL.")
            return
        }

        isRequestInProgress = true
        currentRequestID = requestID
        currentRequestCompletion = completion
        originalClipboardChangeCount = UIPasteboard.general.changeCount
        NSLog("📱 CloudModelService: Launching request-bound Shortcut callback (%@)", String(describing: type))

        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            Task { @MainActor in
                guard let self, self.currentRequestID == requestID else { return }
                guard success else {
                    self.finish(
                        with: "Could not launch Shortcuts. Check that the app and named Shortcut are installed."
                    )
                    return
                }
                self.startTimeout(for: requestID)
            }
        }
    }

    @MainActor
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard let requestID = currentRequestID,
              let outcome = CloudShortcutCallbackPolicy.outcome(
                from: url,
                expectedRequestID: requestID
              ) else {
            return false
        }

        switch outcome {
        case .success(let result):
            if let result, !result.isEmpty {
                finish(with: result)
            } else if let originalClipboardChangeCount,
                      UIPasteboard.general.changeCount != originalClipboardChangeCount,
                      let clipboardResult = UIPasteboard.general.string?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !clipboardResult.isEmpty {
                // Compatibility for older supplied Shortcuts: inspect the
                // clipboard only after this request's success callback.
                finish(with: clipboardResult)
            } else {
                finish(with: "The Shortcut completed without returning a text result.")
            }
        case .cancelled:
            finish(with: "The Shortcut request was cancelled.")
        case .failure(let message):
            if let message, !message.isEmpty {
                finish(with: "Shortcut failed: \(String(message.prefix(1_000)))")
            } else {
                finish(with: "The Shortcut could not complete the request.")
            }
        }
        return true
    }

    @MainActor
    private func startTimeout(for requestID: UUID) {
        requestTimeoutTimer?.invalidate()
        requestTimeoutTimer = Timer.scheduledTimer(
            timeInterval: requestTimeoutSeconds,
            target: self,
            selector: #selector(handleTimeoutTimer(_:)),
            userInfo: requestID.uuidString,
            repeats: false
        )
    }

    @MainActor
    @objc private func handleTimeoutTimer(_ timer: Timer) {
        guard let requestIDString = timer.userInfo as? String,
              currentRequestID?.uuidString == requestIDString else { return }
        finish(with: "Cloud AI service timed out. Please try again.")
    }

    @MainActor
    private func finish(with output: String) {
        requestTimeoutTimer?.invalidate()
        requestTimeoutTimer = nil
        let completion = currentRequestCompletion
        currentRequestCompletion = nil
        currentRequestID = nil
        originalClipboardChangeCount = nil
        isRequestInProgress = false
        completion?(output)
    }
}
