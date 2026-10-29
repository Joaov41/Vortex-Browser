//
//  AgentRunCompletionBroker.swift
//  Vortex
//
//  Hands finished agent runs (and requests rejected before they started) to
//  App Intents that are waiting for a result. Results that arrive before anyone
//  waits are kept briefly so a fast run is not missed.
//

import Foundation

/// How a wait for one queued agent request ended.
enum AgentRunWaitOutcome: Equatable {
    case finished(BrowserAgentController.CompletionSnapshot)
    case rejected(String)
    case timedOut
    case cancelled
}

@MainActor
final class AgentRunCompletionBroker {
    static let shared = AgentRunCompletionBroker()

    /// How long a completion or rejection waits for its intent to ask for it.
    static let retentionSeconds: TimeInterval = 10 * 60
    static let maximumRetainedResults = 16

    private enum Resolution {
        case finished(BrowserAgentController.CompletionSnapshot)
        case rejected(String)

        var outcome: AgentRunWaitOutcome {
            switch self {
            case .finished(let snapshot): return .finished(snapshot)
            case .rejected(let message): return .rejected(message)
            }
        }
    }

    private struct RetainedResult {
        let resolution: Resolution
        let storedAt: Date
    }

    private struct Waiter {
        let requestID: UUID
        let continuation: CheckedContinuation<AgentRunWaitOutcome, Never>
        let timer: Task<Void, Never>?
    }

    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    /// Keyed by a per-wait token so one request ID can have several waiters.
    private var waiters: [UUID: Waiter] = [:]
    private var retained: [UUID: RetainedResult] = [:]
    /// Request IDs of `retained`, oldest first, for eviction.
    private var retainedOrder: [UUID] = []

    /// Tests pass a fixed clock and a sleep that returns at once or waits until cancelled.
    init(
        now: @escaping () -> Date = { Date() },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// Waits for the run that request `requestID` starts. Returns at once if its result is already retained.
    func wait(for requestID: UUID, timeout: Duration) async -> AgentRunWaitOutcome {
        pruneExpiredResults()
        if let result = takeRetained(requestID) {
            return result.resolution.outcome
        }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AgentRunWaitOutcome, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                let timer = Task { @MainActor [weak self, sleep] in
                    try? await sleep(timeout)
                    guard !Task.isCancelled, let self else { return }
                    self.resumeWaiter(token, with: .timedOut)
                }
                waiters[token] = Waiter(requestID: requestID, continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeWaiter(token, with: .cancelled)
            }
        }
    }

    /// Delivers a finished run. Snapshots without a request ID come from sidebar runs and are ignored.
    func complete(_ snapshot: BrowserAgentController.CompletionSnapshot) {
        guard let requestID = snapshot.requestID else { return }
        deliver(.finished(snapshot), for: requestID)
    }

    /// Delivers a request that was refused before its run started.
    func reject(requestID: UUID, message: String) {
        deliver(.rejected(message), for: requestID)
    }

    /// Number of waits that have not resumed yet.
    var activeWaiterCount: Int {
        waiters.count
    }

    /// Number of early results waiting for a wait.
    var retainedResultCount: Int {
        pruneExpiredResults()
        return retained.count
    }

    private func deliver(_ resolution: Resolution, for requestID: UUID) {
        pruneExpiredResults()
        let tokens = waiters.filter { $0.value.requestID == requestID }.map(\.key)
        guard !tokens.isEmpty else {
            retain(resolution, for: requestID)
            return
        }
        for token in tokens {
            resumeWaiter(token, with: resolution.outcome)
        }
    }

    /// Removes the waiter before resuming it, so each continuation resumes exactly once.
    private func resumeWaiter(_ token: UUID, with outcome: AgentRunWaitOutcome) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        waiter.timer?.cancel()
        waiter.continuation.resume(returning: outcome)
    }

    private func retain(_ resolution: Resolution, for requestID: UUID) {
        retained[requestID] = RetainedResult(resolution: resolution, storedAt: now())
        retainedOrder.removeAll { $0 == requestID }
        retainedOrder.append(requestID)
        while retainedOrder.count > Self.maximumRetainedResults {
            let evicted = retainedOrder.removeFirst()
            retained.removeValue(forKey: evicted)
        }
    }

    private func takeRetained(_ requestID: UUID) -> RetainedResult? {
        guard let result = retained.removeValue(forKey: requestID) else { return nil }
        retainedOrder.removeAll { $0 == requestID }
        return result
    }

    private func pruneExpiredResults() {
        let current = now()
        let expired = Set(retained.compactMap { requestID, result in
            current.timeIntervalSince(result.storedAt) >= Self.retentionSeconds ? requestID : nil
        })
        guard !expired.isEmpty else { return }
        for requestID in expired {
            retained.removeValue(forKey: requestID)
        }
        retainedOrder.removeAll { expired.contains($0) }
    }
}
