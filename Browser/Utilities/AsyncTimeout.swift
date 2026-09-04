import Foundation

/// Returns as soon as either the operation or timeout finishes. Unlike a task
/// group race, this does not wait for an uncooperative cancelled child before
/// returning to the caller.
nonisolated enum AsyncTimeout {
    static func run<Value: Sendable>(
        seconds: TimeInterval,
        timeoutError: @escaping @Sendable () -> any Error,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        return try await race(
            timeoutError: {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                    return timeoutError()
                } catch {
                    return CancellationError()
                }
            },
            operation: operation
        )
    }

    /// Races an operation against an asynchronous watchdog. The watchdog can
    /// begin its deadline from a later event without a structured task group
    /// waiting for the losing operation to cooperate with cancellation.
    static func race<Value: Sendable>(
        timeoutError: @escaping @Sendable () async -> any Error,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let race = AsyncTimeoutRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(
                    continuation: continuation,
                    timeoutError: timeoutError,
                    operation: operation
                )
            }
        } onCancel: {
            race.cancel()
        }
    }
}

nonisolated private final class AsyncTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var operationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var isFinished = false

    func start(
        continuation: CheckedContinuation<Value, any Error>,
        timeoutError: @escaping @Sendable () async -> any Error,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        self.continuation = continuation
        operationTask = Task { [weak self] in
            do {
                let value = try await operation()
                self?.resolve(.success(value))
            } catch {
                self?.resolve(.failure(error))
            }
        }
        timerTask = Task { [weak self] in
            let error = await timeoutError()
            self?.resolve(.failure(error))
        }
        lock.unlock()
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<Value, any Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        let operationTask = self.operationTask
        let timerTask = self.timerTask
        self.continuation = nil
        self.operationTask = nil
        self.timerTask = nil
        lock.unlock()

        operationTask?.cancel()
        timerTask?.cancel()
        continuation?.resume(with: result)
    }
}
