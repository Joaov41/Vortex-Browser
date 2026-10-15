import Foundation

/// Holds one visible question while an agent run waits for the user.
/// All terminal paths resolve the same continuation at most once.
@MainActor
final class BrowserAgentQuestionGate<Prompt> {
    private(set) var pendingPrompt: Prompt?
    private(set) var pendingRequestID: UUID?
    var onPendingPromptChange: (@MainActor (Prompt?) -> Void)?

    private var continuation: CheckedContinuation<String?, Never>?

    func ask(_ prompt: Prompt) async -> String? {
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                if self.continuation != nil {
                    resolve(nil)
                }
                self.continuation = continuation
                pendingRequestID = requestID
                pendingPrompt = prompt
                onPendingPromptChange?(prompt)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID: requestID)
            }
        }
    }

    func resolve(_ answer: String?) {
        guard let continuation else { return }
        self.continuation = nil
        pendingRequestID = nil
        pendingPrompt = nil
        onPendingPromptChange?(nil)
        continuation.resume(returning: answer)
    }

    /// Ignores a cancellation queued by an older question after a replacement is visible.
    func cancel(requestID: UUID) {
        guard pendingRequestID == requestID else { return }
        resolve(nil)
    }

    func cancel() {
        resolve(nil)
    }
}
