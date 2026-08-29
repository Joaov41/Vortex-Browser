import Foundation
import Combine
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

private func browserAIServiceLog(_ message: @autoclosure () -> String) {
    print("🧠 [AIService] \(message())")
}

private func appleLocalFollowUpLog(_ message: @autoclosure () -> String) {
    print("🍎 [LocalFollowUp] \(message())")
}

private enum BrowserAIKeychain {
    private static let service = "Browser.ApplePCCGateway"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func setString(_ value: String, for account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        guard !trimmed.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(trimmed.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}

private struct PCCGatewayConfiguration {
    let host: String
    let port: Int
    let token: String
    let model: String

    var normalizedToken: String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("bearer ") {
            return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    func endpoint(path: String) -> URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return nil }

        if trimmedHost.lowercased().hasPrefix("http://") || trimmedHost.lowercased().hasPrefix("https://") {
            guard var components = URLComponents(string: trimmedHost) else { return nil }
            if components.port == nil {
                components.port = port
            }
            components.path = path
            return components.url
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmedHost
        components.port = port
        components.path = path
        return components.url
    }
}

private enum PCCGatewayError: LocalizedError {
    case unavailableOnCurrentOS
    case invalidConfiguration(String)
    case httpStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailableOnCurrentOS:
            return "Apple PCC Gateway requires iOS 27 or later in this build."
        case .invalidConfiguration(let message):
            return message
        case .httpStatus(let status, let message):
            return "Apple PCC Gateway error \(status): \(message)"
        case .emptyResponse:
            return "Apple PCC Gateway returned an empty response."
        }
    }
}

private struct PCCGatewayChatMessage: Codable {
    let role: String
    let content: String
}

private struct PCCGatewayChatRequest: Encodable {
    let model: String
    let messages: [PCCGatewayChatMessage]
    let stream: Bool
}

private struct PCCGatewayChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message?
        let text: String?
    }

    let choices: [Choice]
}

private final class PCCGatewayClient {
    private let configuration: PCCGatewayConfiguration

    init(configuration: PCCGatewayConfiguration) {
        self.configuration = configuration
    }

    func healthSummary() async throws -> String {
        let data = try await send(path: "/health", method: "GET", body: nil)
        guard !data.isEmpty else { return "Connected to Apple PCC Gateway." }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let status = object["status"] as? String ?? "ok"
            let model = object["model"] as? String ?? configuration.model
            if let available = object["model_available"] as? Bool {
                return "Apple PCC Gateway \(status). Model \(model): \(available ? "available" : "unavailable")."
            }
            return "Apple PCC Gateway \(status). Model \(model)."
        }
        return String(data: data, encoding: .utf8) ?? "Connected to Apple PCC Gateway."
    }

    func complete(prompt: String) async throws -> String {
        let requestBody = PCCGatewayChatRequest(
            model: configuration.model,
            messages: [PCCGatewayChatMessage(role: "user", content: prompt)],
            stream: false
        )
        let body = try JSONEncoder().encode(requestBody)
        let data = try await send(path: "/v1/chat/completions", method: "POST", body: body)
        let decoded = try JSONDecoder().decode(PCCGatewayChatResponse.self, from: data)
        let text = decoded.choices.compactMap { $0.message?.content ?? $0.text }.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            throw PCCGatewayError.emptyResponse
        }
        return text
    }

    private func send(path: String, method: String, body: Data?) async throws -> Data {
        guard !configuration.normalizedToken.isEmpty else {
            throw PCCGatewayError.invalidConfiguration("Enter the Apple PCC Gateway token from the Mac start script.")
        }
        guard let url = configuration.endpoint(path: path) else {
            throw PCCGatewayError.invalidConfiguration("Enter a valid Apple PCC Gateway host or IP address.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 300
        request.setValue("Bearer \(configuration.normalizedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PCCGatewayError.invalidConfiguration("Apple PCC Gateway returned a non-HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw PCCGatewayError.httpStatus(http.statusCode, Self.errorMessage(from: data))
        }
        return data
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String {
                return message
            }
            if let status = object["status"] as? String {
                return status
            }
        }
        return String(data: data, encoding: .utf8) ?? "Unknown gateway error."
    }
}

#if canImport(FoundationModels)
private enum AppleLocalStreamEvent: Sendable {
    case availabilityCheckStarted(Date)
    case availabilityCheckFinished(Date, status: String)
    case sessionAcquireStarted(Date)
    case standbyReady(Date)
    case sessionAcquireFinished(Date, usedStandby: Bool, coldStart: Bool, warmupTimeoutFallback: Bool)
    case started(Date)
    case firstSnapshot(Date)
}

private enum AppleLocalStandbyState: Sendable {
    case idle
    case warming
    case ready
}

private actor AppleLocalGenerationService {
    static let shared = AppleLocalGenerationService()

    private var activeSession: LanguageModelSession?
    private var standbySession: LanguageModelSession?
    private var standbyState: AppleLocalStandbyState = .idle
    private var standbyWarmTask: Task<Void, Never>?
    private var lastStandbyWarmupError: String?
    private var isGenerating = false
    private var realRequestPending = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    // Persistent session held alive between requests.
    // Apple's FoundationModels framework runs ~1.5s of token-container cleanup
    // on the main thread when a LanguageModelSession is DEALLOCATED.  By keeping
    // one strong reference alive here we prevent that deallocation — and the
    // resulting main-thread stall (spinning beach ball) — from occurring between
    // consecutive requests.  The session is only released on an explicit reset.
    private var persistentSession: LanguageModelSession? = nil
    // Timestamp used only when we must create a brand-new session (after an
    // explicit reset).  The recovery gap gives the previous session's cleanup
    // time to finish before the new one starts.
    private var lastSessionReleasedAt: Date? = nil
    private var lastIsolatedGenerationCompletedAt: Date? = nil
    private let sessionRecoveryGapSeconds: TimeInterval = 1.5
    private let streamChunkFlushInterval: TimeInterval = 0.05
    private let streamChunkFlushCharacterCount = 160
    private let streamDeliveryFlushInterval: TimeInterval = 0.08
    private let streamDeliveryFlushCharacterCount = 320
    // Do not block user requests on standby warm-up; if standby is not ready,
    // immediately fall back to a fresh session for responsiveness.
    private let standbyAcquireWaitNanoseconds: UInt64 = 0
    private let defaultMaximumResponseTokens = 320
    private let sessionInstructions = """
    Return only the requested answer.
    Do not repeat the prompt or these instructions.
    If a format is requested, follow it strictly.
    """

    @available(iOS 18.2, macOS 15.2, *)
    private func makeSession() -> LanguageModelSession {
        // Use a fresh session per request to prevent hidden multi-turn history
        // accumulation from slowing first-token latency on subsequent queries.
        LanguageModelSession(instructions: sessionInstructions)
    }

    private func waitUntilIdle() async {
        // Fast path: nothing generating
        if !isGenerating {
            await waitForSessionFinalization()
            return
        }
        // Slow path: suspend until signalIdle() is called
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
        await waitForSessionFinalization()
    }

    /// Brief bounded wait for session.isResponding to clear after isGenerating
    /// becomes false.  The session finalizes within a few ms; cap at 50ms to
    /// avoid any permanent hang.
    private func waitForSessionFinalization() async {
        if #available(iOS 26.0, macOS 26.0, *) {
            var attempts = 0
            while let activeSession, activeSession.isResponding, attempts < 10 {
                try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
                attempts += 1
            }
        }
    }

    private func signalIdle() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func markRealRequestPending() {
        realRequestPending = true
    }

    @available(iOS 18.2, macOS 15.2, *)
    private func availabilityStatus() -> String {
        if let lastStandbyWarmupError, standbyState == .idle {
            return "unavailable:\(lastStandbyWarmupError)"
        }
        switch standbyState {
        case .ready:
            return "ready_standby"
        case .warming:
            return "warming_standby"
        case .idle:
            return "cold_start"
        }
    }

    private func availabilityErrorMessage(from status: String) -> String? {
        let normalized = status.lowercased()
        guard normalized.contains("unavailable") || normalized.contains("notready") else { return nil }
        let definitiveUnavailabilityMarkers = [
            "disabled",
            "unsupported",
            "not supported",
            "not eligible",
            "not available on this device"
        ]
        guard definitiveUnavailabilityMarkers.contains(where: { normalized.contains($0) }) else {
            return nil
        }
        if normalized.contains("appleintelligence") || normalized.contains("disabled") {
            return "Apple Intelligence appears disabled. Enable Apple Intelligence in Settings and try again."
        }
        return "Apple local model is not currently available (\(status))."
    }

    @available(iOS 18.2, macOS 15.2, *)
    private func clearStandbySessionState() {
        standbyWarmTask?.cancel()
        standbyWarmTask = nil
        standbySession = nil
        standbyState = .idle
        lastStandbyWarmupError = nil
    }

    @available(iOS 18.2, macOS 15.2, *)
    private func startStandbyWarmup() {
        guard standbyState == .idle else { return }
        standbyState = .warming
        standbyWarmTask = Task(priority: .utility) { [self] in
            await runStandbyWarmup()
        }
    }

    @available(iOS 18.2, macOS 15.2, *)
    private func runStandbyWarmup() async {
        defer {
            standbyWarmTask = nil
            if standbyState == .warming && standbySession == nil {
                standbyState = .idle
            }
        }
        if Task.isCancelled {
            standbySession = nil
            standbyState = .idle
            return
        }

        let session = makeSession()
        do {
            lastStandbyWarmupError = nil
            let warmupPrompt = "Reply with exactly: OK"
            if #available(iOS 26.0, macOS 26.0, *) {
                let options = GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: 1
                )
                _ = try await session.respond(to: warmupPrompt, options: options).content
            } else {
                _ = try await session.respond(to: warmupPrompt).content
            }
            if Task.isCancelled {
                standbySession = nil
                standbyState = .idle
                return
            }
            standbySession = session
            standbyState = .ready
            lastStandbyWarmupError = nil
        } catch {
            standbySession = nil
            standbyState = .idle
            if !(error is CancellationError) {
                lastStandbyWarmupError = error.localizedDescription
            }
            print("⚠️ [Apple Local] Standby warm-up failed: \(error.localizedDescription)")
        }
    }

    @available(iOS 18.2, macOS 15.2, *)
    private func waitForStandbyReady(timeoutNanoseconds: UInt64) async -> Bool {
        if standbyState == .ready, standbySession != nil {
            return true
        }
        if standbyState == .idle {
            startStandbyWarmup()
        }
        guard timeoutNanoseconds > 0 else {
            return standbyState == .ready && standbySession != nil
        }
        let startedAt = Date()
        let timeoutSeconds = Double(timeoutNanoseconds) / 1_000_000_000
        while standbyState == .warming {
            if Date().timeIntervalSince(startedAt) >= timeoutSeconds {
                return false
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return standbyState == .ready && standbySession != nil
    }

    @available(iOS 18.2, macOS 15.2, *)
    private func acquireSessionForRequest() async -> (
        session: LanguageModelSession,
        usedStandby: Bool,
        coldStart: Bool,
        warmupTimeoutFallback: Bool
    ) {
        if standbyState == .ready, let standbySession {
            self.standbySession = nil
            standbyState = .idle
            return (session: standbySession, usedStandby: true, coldStart: false, warmupTimeoutFallback: false)
        }

        var warmupTimeoutFallback = false
        if standbyState == .warming {
            let standbyReady = await waitForStandbyReady(timeoutNanoseconds: standbyAcquireWaitNanoseconds)
            if standbyReady, standbyState == .ready, let standbySession {
                self.standbySession = nil
                standbyState = .idle
                return (session: standbySession, usedStandby: true, coldStart: false, warmupTimeoutFallback: false)
            }
            // Cancel the in-progress warmup so its session.respond() call
            // does not compete with the real request for the on-device model.
            clearStandbySessionState()
            warmupTimeoutFallback = true
        }

        return (
            session: makeSession(),
            usedStandby: false,
            coldStart: true,
            warmupTimeoutFallback: warmupTimeoutFallback
        )
    }

    func prepareStandbySessionIfNeeded() async -> Bool {
        guard #available(iOS 18.2, macOS 15.2, *) else { return false }
        if standbyState == .ready, standbySession != nil {
            return true
        }
        startStandbyWarmup()
        return standbyState == .ready && standbySession != nil
    }

    @available(iOS 18.2, macOS 15.2, *)
    private func normalizedPrompt(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("User question:") {
            return trimmed
        }
        return """
        User question:
        \(trimmed)
        """
    }

    func respond(to prompt: String, maxOutputTokens: Int? = nil) async throws -> String {
        guard #available(iOS 18.2, macOS 15.2, *) else {
            throw NSError(
                domain: "SimpleAIService.AppleLocal",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Apple local model requires iOS 18.2+ or macOS 15.2+."]
            )
        }
        let normalized = normalizedPrompt(prompt)
        guard !normalized.isEmpty else { return "" }
        realRequestPending = false
        let configuredMax = maxOutputTokens ?? defaultMaximumResponseTokens
        let effectiveMax = max(1, min(configuredMax, defaultMaximumResponseTokens))
        appleLocalFollowUpLog("service.respond start persistentSession=\(persistentSession != nil) promptChars=\(normalized.count) maxTokens=\(effectiveMax)")

        let availability = availabilityStatus()
        if let message = availabilityErrorMessage(from: availability) {
            throw NSError(
                domain: "SimpleAIService.AppleLocal",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        await waitUntilIdle()
        // Reuse the persistent session if available.  Keeping one strong
        // reference alive prevents Apple's FoundationModels framework from
        // deallocating the session between requests — deallocation triggers
        // ~1.5s of token-container cleanup on the main thread which causes a
        // spinning beach ball.  Only create a new session when none exists
        // (first ever call, or after an explicit reset).
        if persistentSession == nil {
            appleLocalFollowUpLog("service.respond creating fresh persistent session")
            // A prior session was recently released — wait for its cleanup to
            // finish before creating a new one.
            if let released = lastSessionReleasedAt {
                let elapsed = -released.timeIntervalSinceNow
                if elapsed < sessionRecoveryGapSeconds {
                    let remainingNs = UInt64((sessionRecoveryGapSeconds - elapsed) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: remainingNs)
                }
            }
            let acquisition = await acquireSessionForRequest()
            persistentSession = acquisition.session
        }
        let session = persistentSession!
        activeSession = session
        isGenerating = true
        defer {
            activeSession = nil
            isGenerating = false
            // Do NOT release persistentSession — keeping it alive prevents the
            // framework cleanup from running on the main thread between requests.
            signalIdle()
        }
        if #available(iOS 26.0, macOS 26.0, *) {
            let options = GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: effectiveMax
            )
            return try await session.respond(to: normalized, options: options).content
        } else {
            return try await session.respond(to: normalized).content
        }
    }

    func streamResponse(
        to prompt: String,
        maxOutputTokens: Int,
        isolatesSession: Bool = false,
        onChunk: @Sendable @escaping (String) async -> Void,
        shouldContinue: (@Sendable () async -> Bool)? = nil,
        onStreamEvent: (@Sendable (AppleLocalStreamEvent) async -> Void)? = nil
    ) async throws -> String {
        guard #available(iOS 18.2, macOS 15.2, *) else {
            throw NSError(
                domain: "SimpleAIService.AppleLocal",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Apple local model requires iOS 18.2+ or macOS 15.2+."]
            )
        }
        let normalized = normalizedPrompt(prompt)
        guard !normalized.isEmpty else { return "" }
        realRequestPending = false
        if let onStreamEvent {
            Task { await onStreamEvent(.availabilityCheckStarted(Date())) }
        }
        let availability = availabilityStatus()
        if let onStreamEvent {
            Task { await onStreamEvent(.availabilityCheckFinished(Date(), status: availability)) }
        }
        if let message = availabilityErrorMessage(from: availability) {
            throw NSError(
                domain: "SimpleAIService.AppleLocal",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        await waitUntilIdle()
        if let onStreamEvent {
            Task { await onStreamEvent(.sessionAcquireStarted(Date())) }
        }
        let acquisition: (
            session: LanguageModelSession,
            usedStandby: Bool,
            coldStart: Bool,
            warmupTimeoutFallback: Bool
        )
        if isolatesSession {
            // Reddit map/reduction passes are independent jobs. Never reuse a
            // stateful transcript across them, because each prompt/response is
            // retained by LanguageModelSession and eventually exhausts or
            // slows the local model context.
            clearStandbySessionState()
            if let completed = lastIsolatedGenerationCompletedAt {
                let elapsed = -completed.timeIntervalSinceNow
                if elapsed < sessionRecoveryGapSeconds {
                    let remainingNs = UInt64((sessionRecoveryGapSeconds - elapsed) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: remainingNs)
                }
            }
            acquisition = (
                session: makeSession(),
                usedStandby: false,
                coldStart: true,
                warmupTimeoutFallback: false
            )
        } else {
            acquisition = await acquireSessionForRequest()
        }
        if acquisition.usedStandby, let onStreamEvent {
            Task { await onStreamEvent(.standbyReady(Date())) }
        }
        if let onStreamEvent {
            Task {
                await onStreamEvent(
                    .sessionAcquireFinished(
                        Date(),
                        usedStandby: acquisition.usedStandby,
                        coldStart: acquisition.coldStart,
                        warmupTimeoutFallback: acquisition.warmupTimeoutFallback
                    )
                )
            }
        }
        let session = acquisition.session
        activeSession = session
        isGenerating = true
        defer {
            activeSession = nil
            isGenerating = false
            if isolatesSession {
                lastIsolatedGenerationCompletedAt = Date()
            }
            signalIdle()
            // Do NOT start standby warmup here — a queued request may start
            // immediately and the warmup's session.respond() would race it
            // for the on-device model, causing the real request to freeze.
        }

        if #available(iOS 26.0, macOS 26.0, *) {
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: maxOutputTokens)
            var fullText = ""
            var bufferedDelta = ""
            var lastFlushTime = Date.distantPast
            var chunkContinuation: AsyncStream<String>.Continuation?
            let chunkStream = AsyncStream<String> { continuation in
                chunkContinuation = continuation
            }
            let deliveryTask = Task {
                var deliveryBuffer = ""
                var lastDeliveryTime = Date.distantPast
                for await chunk in chunkStream {
                    if Task.isCancelled { break }
                    deliveryBuffer += chunk
                    let now = Date()
                    if deliveryBuffer.count >= streamDeliveryFlushCharacterCount
                        || now.timeIntervalSince(lastDeliveryTime) >= streamDeliveryFlushInterval {
                        if let shouldContinue, !(await shouldContinue()) {
                            break
                        }
                        let flushed = deliveryBuffer
                        deliveryBuffer = ""
                        lastDeliveryTime = now
                        await onChunk(flushed)
                    }
                }
                if !deliveryBuffer.isEmpty {
                    if let shouldContinue, !(await shouldContinue()) {
                        return
                    }
                    await onChunk(deliveryBuffer)
                }
            }
            defer {
                chunkContinuation?.finish()
                deliveryTask.cancel()
            }
            if let onStreamEvent {
                Task { await onStreamEvent(.started(Date())) }
            }
            let stream = session.streamResponse(to: normalized, options: options)
            var emittedFirstSnapshot = false
            for try await snapshot in stream {
                if !emittedFirstSnapshot {
                    emittedFirstSnapshot = true
                    if let onStreamEvent {
                        Task { await onStreamEvent(.firstSnapshot(Date())) }
                    }
                }
                let content = snapshot.content
                let delta: String
                if content.hasPrefix(fullText) {
                    delta = String(content.dropFirst(fullText.count))
                } else {
                    delta = content
                }
                if !delta.isEmpty {
                    bufferedDelta += delta
                    let now = Date()
                    if bufferedDelta.count >= streamChunkFlushCharacterCount
                        || now.timeIntervalSince(lastFlushTime) >= streamChunkFlushInterval {
                        let flushed = bufferedDelta
                        bufferedDelta = ""
                        lastFlushTime = now
                        chunkContinuation?.yield(flushed)
                    }
                }
                fullText = content
            }
            if !bufferedDelta.isEmpty {
                chunkContinuation?.yield(bufferedDelta)
            }
            return fullText
        } else {
            let response = try await session.respond(to: normalized).content
            if !response.isEmpty {
                await onChunk(response)
            }
            return response
        }
    }

    func warmUpIfNeeded() async -> Bool {
        guard #available(iOS 18.2, macOS 15.2, *) else { return false }
        if standbyState == .ready, standbySession != nil { return true }
        startStandbyWarmup()
        return await waitForStandbyReady(timeoutNanoseconds: standbyAcquireWaitNanoseconds)
    }

    func resetConversation() {
        activeSession = nil
        isGenerating = false
        realRequestPending = false
        if #available(iOS 18.2, macOS 15.2, *) {
            // Do NOT release persistentSession here — keeping it alive prevents
            // Apple's FoundationModels framework from running its ~1.5s
            // token-container cleanup on the main thread between requests
            // (which causes a spinning beach ball).  Only the explicit reset()
            // path (user-initiated clear or timeout recovery) should release it.
            clearStandbySessionState()
        }
        signalIdle()
    }

    func reset() {
        appleLocalFollowUpLog("service.reset start persistentSession=\(persistentSession != nil)")
        activeSession = nil
        isGenerating = false
        realRequestPending = false
        if #available(iOS 18.2, macOS 15.2, *) {
            if persistentSession != nil {
                persistentSession = nil
                lastSessionReleasedAt = Date()
            }
            clearStandbySessionState()
        }
        signalIdle()
        appleLocalFollowUpLog("service.reset end")
    }
}

private actor ApplePrivateCloudGenerationService {
    static let shared = ApplePrivateCloudGenerationService()

    @available(iOS 27.0, *)
    func respond(to prompt: String) async throws -> String {
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable else {
            throw NSError(
                domain: "SimpleAIService.AppleCloud",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Apple Private Cloud Compute is unavailable: \(model.availability)"
                ]
            )
        }

        let session = LanguageModelSession(model: model)
        let response = try await session.respond(
            to: prompt,
            contextOptions: ContextOptions(reasoningLevel: .moderate)
        )
        let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw NSError(
                domain: "SimpleAIService.AppleCloud",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Apple Private Cloud Compute returned an empty response."]
            )
        }
        return content
    }
}

#endif

enum AIModelBackend: String, CaseIterable {
    case localApple
    case cloudShortcuts
    case applePCCGateway
    case mlxLocal
    case webChatGPT
    case webGemini

    var isAvailableInCurrentEnvironment: Bool {
        switch self {
        case .applePCCGateway:
            #if DEBUG
            return true
            #else
            if #available(iOS 27.0, *) {
                return true
            }
            // TestFlight uses a sandbox receipt. Treat missing/unknown receipts
            // as pre-release too, so an iOS 26 distribution cannot fail open.
            return Bundle.main.appStoreReceiptURL?.lastPathComponent == "receipt"
            #endif
        default:
            return true
        }
    }

    var displayName: String {
        switch self {
        case .localApple:
            return "Local"
        case .cloudShortcuts:
            return "Cloud"
        case .applePCCGateway:
            return "Apple PCC Gateway"
        case .mlxLocal:
            return "MLX"
        case .webChatGPT:
            return "ChatGPT"
        case .webGemini:
            return "Gemini"
        }
    }

    var throughputLabel: String {
        switch self {
        case .localApple:
            return "Apple Local"
        case .applePCCGateway:
            return "Apple PCC"
        case .mlxLocal:
            return "MLX"
        default:
            return displayName
        }
    }

    var isWebProvider: Bool {
        switch self {
        case .webChatGPT, .webGemini:
            return true
        default:
            return false
        }
    }
}

struct AIThroughputState: Equatable {
    let sessionID: UUID
    let backend: AIModelBackend
    let tokens: Int
    let elapsed: TimeInterval
    let tokensPerSecond: Double
    let isFinal: Bool
}

@MainActor
final class AIStreamState: ObservableObject {
    private(set) var text: String = ""
    @Published private(set) var textVersion: UInt64 = 0
    @Published var throughput: AIThroughputState? = nil

    func resetText() {
        text = ""
        textVersion &+= 1
    }

    func appendText(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        text += chunk
        textVersion &+= 1
    }
}

private final class AIThroughputCounter {
    struct Snapshot {
        let tokens: Int
        let elapsed: TimeInterval
        let tokensPerSecond: Double
    }

    private let startedAt: Date
    private var tokenUnits: Int = 0
    private var lastPublishedUnits: Int = 0
    private var lastPublishedAt: Date

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.lastPublishedAt = startedAt
    }

    var tokens: Int { tokenUnits }

    func record(units: Int, now: Date) -> Snapshot? {
        guard units > 0 else { return nil }
        tokenUnits += units
        let unitsDelta = tokenUnits - lastPublishedUnits
        let timeDelta = now.timeIntervalSince(lastPublishedAt)
        let shouldPublish = lastPublishedUnits == 0 || unitsDelta >= 8 || timeDelta >= 0.25
        guard shouldPublish else { return nil }

        lastPublishedUnits = tokenUnits
        lastPublishedAt = now
        return snapshot(at: now)
    }

    func add(units: Int) {
        guard units > 0 else { return }
        tokenUnits += units
    }

    func finalSnapshot(now: Date) -> Snapshot {
        snapshot(at: now)
    }

    private func snapshot(at now: Date) -> Snapshot {
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let tps = elapsed > 0 ? Double(tokenUnits) / elapsed : 0
        return Snapshot(tokens: tokenUnits, elapsed: elapsed, tokensPerSecond: tps)
    }
}

private actor StreamChunkAccumulator {
    private let minimumCharacters: Int
    private let minimumInterval: TimeInterval
    private let deliver: @Sendable (String) async -> Void
    private var buffer = ""
    private var lastFlushTime = Date.distantPast

    init(
        minimumCharacters: Int,
        minimumInterval: TimeInterval,
        deliver: @escaping @Sendable (String) async -> Void
    ) {
        self.minimumCharacters = max(1, minimumCharacters)
        self.minimumInterval = minimumInterval
        self.deliver = deliver
    }

    func append(_ chunk: String) async {
        guard !chunk.isEmpty else { return }
        buffer += chunk
        let now = Date()
        if buffer.count >= minimumCharacters || now.timeIntervalSince(lastFlushTime) >= minimumInterval {
            let flushed = buffer
            buffer = ""
            lastFlushTime = now
            await deliver(flushed)
        }
    }

    func finish() async {
        guard !buffer.isEmpty else { return }
        let flushed = buffer
        buffer = ""
        lastFlushTime = Date()
        await deliver(flushed)
    }
}

class SimpleAIService: ObservableObject {
    static let shared = SimpleAIService()

    private struct QueuedRequest {
        let payload: AIRequest
        let enqueuedAt: Date
    }

    private struct AppleLocalDiagnostics {
        let requestID: UUID
        let enqueuedAt: Date
        var availabilityCheckStartedAt: Date?
        var availabilityCheckCompletedAt: Date?
        var availabilityStatus: String?
        var sessionAcquireStartedAt: Date?
        var sessionAcquireCompletedAt: Date?
        var standbyReadyAt: Date?
        var usedStandby: Bool = false
        var coldStart: Bool = false
        var warmupTimeoutFallback: Bool = false
        var modelStreamStartedAt: Date?
        var firstModelSnapshotAt: Date?
        var firstUIChunkAt: Date?
        var firstSnapshotTimeoutTriggered: Bool = false
        var retryAttempted: Bool = false
        var retrySucceeded: Bool = false
        var retryFirstSnapshotMs: Double?
        var completedAt: Date?
        var queueUnblockedAt: Date?
    }

    private struct AppleLocalFirstSnapshotTimeoutError: Error {}

    private actor AppleLocalFirstSnapshotTracker {
        private var firstSnapshotAt: Date?
        private var streamStartedAt: Date?

        func markIfNeeded(_ date: Date) {
            if firstSnapshotAt == nil {
                firstSnapshotAt = date
            }
        }

        func markStreamStartedIfNeeded(_ date: Date) {
            if streamStartedAt == nil {
                streamStartedAt = date
            }
        }

        func hasFirstSnapshot() -> Bool {
            firstSnapshotAt != nil
        }

        func streamStartDate() -> Date? {
            streamStartedAt
        }

        func elapsedMilliseconds(since startDate: Date) -> Double? {
            guard let firstSnapshotAt else { return nil }
            return max(0, firstSnapshotAt.timeIntervalSince(startDate) * 1000)
        }
    }

    static let slowRedditProcessingNotice = "This can take a while depending on the size of the comments."

    @Published var isProcessing = false
    /// Captured when an app-backend Reddit request starts. The notice must not
    /// follow a picker change while that request is still running.
    @Published private(set) var activeRedditRequestBackend: AIModelBackend? = nil
    @Published private(set) var activeRequestIsReddit = false
    @Published var messages: [ChatMessage] = []
    @Published var archiveMessages: [ChatMessage] = []
    @Published var queuedCount: Int = 0
    @Published var backend: AIModelBackend = .cloudShortcuts {
        didSet {
            UserDefaults.standard.set(backend.rawValue, forKey: "selectedAIBackend")
        }
    }
    @Published var shortcutName: String = "RSS Reader Cloud Summary"
    @Published var pccGatewayHost: String = UserDefaults.standard.string(forKey: "pccGatewayHost") ?? "127.0.0.1" {
        didSet {
            UserDefaults.standard.set(pccGatewayHost.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "pccGatewayHost")
        }
    }
    @Published var pccGatewayPort: Int = {
        let saved = UserDefaults.standard.integer(forKey: "pccGatewayPort")
        return saved > 0 ? saved : 1977
    }() {
        didSet {
            UserDefaults.standard.set(pccGatewayPort, forKey: "pccGatewayPort")
        }
    }
    @Published var pccGatewayModel: String = UserDefaults.standard.string(forKey: "pccGatewayModel") ?? "pcc" {
        didSet {
            let trimmed = pccGatewayModel.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? "pcc" : trimmed, forKey: "pccGatewayModel")
        }
    }
    @Published var pccGatewayToken: String = "" {
        didSet {
            BrowserAIKeychain.setString(pccGatewayToken, for: "token")
        }
    }
    let streamState = AIStreamState()

    static func shouldShowSlowRedditProcessingNotice(
        isRedditContext: Bool,
        backend: AIModelBackend?
    ) -> Bool {
        guard isRedditContext else { return false }
        return backend == .localApple || backend == .mlxLocal
    }

    var isSlowRedditProcessingNoticeVisible: Bool {
        isProcessing && Self.shouldShowSlowRedditProcessingNotice(
            isRedditContext: activeRequestIsReddit,
            backend: activeRedditRequestBackend
        )
    }

    private let cloudService = CloudModelService()
    private var lastContextURL: String? = nil
    private var sourcePageContext: String? = nil
    private var requestQueue: [QueuedRequest] = []
    private var activeRequestID: UUID? = nil
    private var activeMessageChannel: MessageChannel = .appBackend
    private var requestTimeoutTask: Task<Void, Never>? = nil
    private var latestThroughputSessionID: UUID? = nil
    private var activeAppleLocalStreamSessionID: UUID? = nil
    private var appleLocalDiagnosticsByRequestID: [UUID: AppleLocalDiagnostics] = [:]
    private var shouldResetAppleLocalAfterSummaryWhenIdle = false
    private var pendingAppleLocalPostSummaryFollowUp = false
    private var pendingNextUserSidebarVisibility: [Bool] = []
    private var mlxWarmupTask: Task<Void, Never>? = nil
    private var warmingUpMLXModelID: String? = nil
    private var warmedUpMLXModelID: String? = nil
    private var appleWarmupTask: Task<Void, Never>? = nil
    private var warmedUpAppleLocal = false
    private let requestTimeoutNanoseconds: UInt64 = 90_000_000_000
    private let pccGatewayRequestTimeoutNanoseconds: UInt64 = 300_000_000_000
    // A full Reddit map/reduce pass can legitimately require many small local
    // generations. Keep the app cancellable while allowing that pass to finish
    // instead of firing the ordinary single-request watchdog after 90 seconds.
    private let redditProcessingTimeoutNanoseconds: UInt64 = 1_800_000_000_000
    private let maxRetainedMessagesForWebProviders = 2
    private let maxRetainedMessagesForAppBackends = 4
    private let appleLocalQueryContextCharacterLimit = 1_200
    private let appleLocalSummaryContextCharacterLimit = 1_800
    private let appleLocalShortSummaryContextCharacterLimit = 1_350
    private let appleLocalPromptCharacterLimit = 12_000
    private let mlxInputCharacterLimit = 12_000
    private let mlxQueryContextCharacterLimit = 6_000
    private let mlxPromptCharacterLimit = 12_000
    // PCC is documented as a 32K-token context window. This character cap is a
    // conservative approximation (~24K tokens for English text) that leaves room
    // for instructions and the generated answer inside the model window.
    private let pccGatewayInputCharacterLimit = 96_000
    private let pccGatewayFollowUpContextCharacterLimit = 10_000
    private let appleLocalMaxOutputTokens = 320
    private let appleLocalConciseMaxOutputTokens = 224
    private let appleLocalRetryBodyCharacterLimit = 2_400
    private let appleLocalShortRetryBodyCharacterLimit = 1_800
    private let appleLocalRetryMaxOutputTokens = 160
    private let appleLocalFirstSnapshotSoftWarningNanoseconds: UInt64 = 3_000_000_000
    private let appleLocalFirstSnapshotHardTimeoutNanoseconds: UInt64 = 8_000_000_000
    private let appleLocalRedditFirstSnapshotSoftWarningNanoseconds: UInt64 = 8_000_000_000
    private let appleLocalRedditFirstSnapshotHardTimeoutNanoseconds: UInt64 = 30_000_000_000
    private static let inlineContextMinChars = 800
    private static let inlineContextMinNewlines = 4
    private static let inlineContextMinParagraphs = 2
    private let mlxMaxOutputTokenHardCap = 512
    private let mlxMaxContextTokenHardCap = 8_192
    private let mlxAutoContextTokenFallback = 4_096
    private let mlxFollowUpContextCharacterLimit = 3_200
    private let mlxGenerationTimeoutSeconds: TimeInterval = 45

    private enum MessageChannel {
        case appBackend
        case webProvider
    }

    private enum AIRequest {
        case query(prompt: String, pageContent: String?)
        case summary(content: String, length: SummaryLength)

        var debugLabel: String {
            switch self {
            case .query: return "query"
            case .summary: return "summary"
            }
        }
    }

    private init() {
        if let savedBackend = UserDefaults.standard.string(forKey: "selectedAIBackend"),
           let restored = AIModelBackend(rawValue: savedBackend) {
            if restored.isAvailableInCurrentEnvironment {
                self.backend = restored
            } else {
                self.backend = .localApple
                UserDefaults.standard.set(AIModelBackend.localApple.rawValue, forKey: "selectedAIBackend")
            }
        }
        self.pccGatewayToken = BrowserAIKeychain.string(for: "token") ?? ""
    }

    var hasSourcePageContext: Bool {
        guard let sourcePageContext else { return false }
        return !sourcePageContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var sourcePageContextText: String? {
        guard let sourcePageContext else { return nil }
        let trimmed = sourcePageContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : sourcePageContext
    }

    func testPCCGatewayConnection() async throws -> String {
        try await makePCCGatewayClient().healthSummary()
    }

    private func makePCCGatewayClient() throws -> PCCGatewayClient {
        guard AIModelBackend.applePCCGateway.isAvailableInCurrentEnvironment else {
            throw PCCGatewayError.unavailableOnCurrentOS
        }
        let host = pccGatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = pccGatewayModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = PCCGatewayConfiguration(
            host: host.isEmpty ? "127.0.0.1" : host,
            port: pccGatewayPort > 0 ? pccGatewayPort : 1977,
            token: pccGatewayToken,
            model: model.isEmpty ? "pcc" : model
        )
        return PCCGatewayClient(configuration: config)
    }

    private func runPrivateCloudComputeIfAvailable(prompt: String) async throws -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            print("☁️ [Apple Cloud] Using Apple Private Cloud Compute (prompt: \(prompt.count) chars)")
            return try await ApplePrivateCloudGenerationService.shared.respond(to: prompt)
        }
        #endif
        return nil
    }

    func enqueueQuery(_ query: String, pageContent: String? = nil) {
        browserAIServiceLog("enqueueQuery backend=\(backend.rawValue) queryChars=\(query.count) pageContentChars=\(pageContent?.count ?? 0)")
        Task { @MainActor in
            self.enqueue(.query(prompt: query, pageContent: pageContent))
        }
    }

    func enqueueSummary(_ content: String, length: SummaryLength = .long) {
        let lengthLabel = length == .short ? "short" : "long"
        browserAIServiceLog("enqueueSummary backend=\(backend.rawValue) length=\(lengthLabel) contentChars=\(content.count)")
        Task { @MainActor in
            self.enqueue(.summary(content: content, length: length))
        }
    }

    @MainActor
    @discardableResult
    func beginExternalWebRequest(userMessage: String) -> UUID? {
        guard !isProcessing else {
            browserAIServiceLog("beginExternalWebRequest blocked isProcessing=true queued=\(queuedCount)")
            return nil
        }

        browserAIServiceLog("beginExternalWebRequest userChars=\(userMessage.count) storedMessages=\(messages.count)")
        trimRetainedMessages(for: .webProvider)
        let requestID = UUID()
        activeMessageChannel = .webProvider
        activeRedditRequestBackend = nil
        activeRequestIsReddit = false
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        activeRequestID = requestID
        activeAppleLocalStreamSessionID = nil
        latestThroughputSessionID = nil
        streamState.throughput = nil
        isProcessing = true
        streamState.resetText()
        let message = resolvedSidebarVisibility(for: .init(role: .user, text: userMessage))
        appendArchiveMessage(message)
        replaceMessagesForWebRequest(message)

        requestTimeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.requestTimeoutNanoseconds)
            await MainActor.run {
                guard self.isRequestActive(requestID) else { return }
                self.streamState.resetText()
                self.appendRetainedMessage(.init(role: .assistant, text: "Request timed out. Please try again."), channel: .webProvider)
                self.finishRequest()
            }
        }

        return requestID
    }

    @MainActor
    func completeExternalWebRequest(with text: String, requestID: UUID) {
        completeRequest(with: text, requestID: requestID)
    }

    @MainActor
    func failExternalWebRequest(message: String, requestID: UUID) {
        guard isRequestActive(requestID) else { return }
        streamState.resetText()
        appendRetainedMessage(.init(role: .assistant, text: message), channel: .webProvider)
        finishRequest()
    }

    @MainActor
    func warmUpMLXIfNeeded() {
        guard backend == .mlxLocal else { return }
        guard !isProcessing else { return }
        let settings = MLXLocalSettings.load()
        let modelID = settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return }

        if warmedUpMLXModelID == modelID {
            return
        }
        if mlxWarmupTask != nil {
            if warmingUpMLXModelID == modelID {
                return
            }
            mlxWarmupTask?.cancel()
            mlxWarmupTask = nil
        }

        warmingUpMLXModelID = modelID
        mlxWarmupTask = Task(priority: .utility) { [weak self] in
            let cappedContextTokens = self?.cappedMLXContextTokens(settings.maxContextTokens)
            let warmed = await Self.preloadMLXModel(modelID: modelID, maxContextTokens: cappedContextTokens)
            await MainActor.run {
                guard let self else { return }
                if self.warmingUpMLXModelID == modelID {
                    self.warmingUpMLXModelID = nil
                    self.mlxWarmupTask = nil
                    if warmed {
                        self.warmedUpMLXModelID = modelID
                    }
                }
            }
        }
    }

    static func preloadMLXModel(modelID: String? = nil, maxContextTokens: Int? = nil) async -> Bool {
        guard MLXLocalService.isAvailable() else { return false }
        let loadedSettings = MLXLocalSettings.load()
        let configured = modelID ?? loadedSettings.modelID
        let contextTokens = maxContextTokens ?? loadedSettings.maxContextTokens
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        do {
            try await MLXLocalService.shared.warmUpConfiguredModel(
                modelID: trimmed,
                maxContextTokens: contextTokens
            )
            print("✅ [MLX] Model warmed up")
            return true
        } catch {
            print("⚠️ [MLX] Warm-up failed: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    func warmUpAppleLocalIfNeeded(force _: Bool = false) {
        // Old local mode: do not prewarm or keep standby sessions.
        appleWarmupTask?.cancel()
        appleWarmupTask = nil
        warmedUpAppleLocal = false
    }

    @MainActor
    private func enqueue(_ request: AIRequest) {
        browserAIServiceLog("enqueue request=\(request.debugLabel) isProcessing=\(isProcessing) queueCount=\(requestQueue.count)")
        let enqueuedAt = Date()
        if isProcessing {
            requestQueue.append(QueuedRequest(payload: request, enqueuedAt: enqueuedAt))
            queuedCount = requestQueue.count
            browserAIServiceLog("queued request=\(request.debugLabel) newQueueCount=\(queuedCount)")
            return
        }
        execute(request, enqueuedAt: enqueuedAt)
    }

    @MainActor
    private func execute(_ request: AIRequest, enqueuedAt: Date) {
        activeMessageChannel = .appBackend
        browserAIServiceLog("execute start request=\(request.debugLabel) backend=\(backend.rawValue) storedMessages=\(messages.count) queue=\(requestQueue.count)")
        isProcessing = true
        streamState.resetText()
        streamState.throughput = nil
        if backend != .localApple {
            appleWarmupTask?.cancel()
            appleWarmupTask = nil
        }
        let requestID = UUID()
        activeRequestID = requestID
        let selectedBackend = backend
        let isRedditRequest: Bool = {
            switch request {
            case .summary(let content, _):
                return RedditSummaryPlanner.isRedditContext(content)
            case .query(_, let pageContent):
                return pageContent.map(RedditSummaryPlanner.isRedditContext) ?? false
            }
        }()
        activeRequestIsReddit = isRedditRequest
        activeRedditRequestBackend = isRedditRequest ? selectedBackend : nil
        if backend == .localApple {
            beginAppleLocalDiagnostics(requestID: requestID, enqueuedAt: enqueuedAt)
        }

        requestTimeoutTask?.cancel()
        requestTimeoutTask = Task { [weak self] in
            guard let self else { return }
            let isRedditRequest: Bool = {
                switch request {
                case .summary(let content, _):
                    return RedditSummaryPlanner.isRedditContext(content)
                case .query(_, let pageContent):
                    return pageContent.map(RedditSummaryPlanner.isRedditContext) ?? false
                }
            }()
            let timeoutNanoseconds: UInt64
            if isRedditRequest {
                timeoutNanoseconds = self.redditProcessingTimeoutNanoseconds
            } else if selectedBackend == .applePCCGateway {
                timeoutNanoseconds = self.pccGatewayRequestTimeoutNanoseconds
            } else {
                timeoutNanoseconds = self.requestTimeoutNanoseconds
            }
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            await MainActor.run {
                guard self.isRequestActive(requestID) else { return }
                browserAIServiceLog("requestTimeout fired requestID=\(requestID.uuidString.prefix(8)) backend=\(selectedBackend.rawValue)")
                self.streamState.resetText()
                self.appendRetainedMessage(.init(role: .assistant, text: "Request timed out. Please try again."), channel: .appBackend)
                self.clearThroughputIfSessionMatches(sessionID: requestID)
                self.markAppleLocalCompleted(requestID: requestID, at: Date())
                self.finishRequest()
            }
        }

        browserAIServiceLog("execute request=\(request.debugLabel) backend=\(selectedBackend.rawValue) requestID=\(requestID.uuidString.prefix(8)) queuedRemaining=\(requestQueue.count)")
        print("🔵 [execute] Starting \(request.debugLabel) on \(selectedBackend.rawValue), requestID: \(requestID.uuidString.prefix(8))")
        switch request {
        case .query(let prompt, let pageContent):
            let providedPageContent: String? = {
                guard let pageContent else { return nil }
                let trimmed = pageContent.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : pageContent
            }()
            let resolvedPageContent: String?
            let recentConversation: String?
            if selectedBackend == .localApple {
                let isPostSummaryFollowUp = pendingAppleLocalPostSummaryFollowUp
                pendingAppleLocalPostSummaryFollowUp = false
                if let providedPageContent {
                    let trimmedProvided = providedPageContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedProvided.isEmpty {
                        let shouldPromote = sourcePageContext == nil || Self.shouldPromoteToSourceContext(trimmedProvided)
                        if shouldPromote {
                            sourcePageContext = RedditSummaryPlanner.isRedditContext(trimmedProvided)
                                ? trimmedProvided
                                : Self.truncatePreservingStructure(
                                    trimmedProvided,
                                    maxChars: appleLocalSummaryContextCharacterLimit
                                )
                        }
                    }
                }
                // Local follow-ups can reuse source context from the prior summary/query
                // to avoid another heavy WebView extraction pass.
                resolvedPageContent = providedPageContent ?? sourcePageContext
                appleLocalFollowUpLog(
                    "execute.query postSummaryFollowUp=\(isPostSummaryFollowUp) providedPageContentChars=\(providedPageContent?.count ?? 0) sourcePageContextChars=\(sourcePageContext?.count ?? 0) resolvedChars=\(resolvedPageContent?.count ?? 0)"
                )
                recentConversation = nil
            } else {
                let shouldPromoteProvidedContext =
                    sourcePageContext == nil || (providedPageContent.map(Self.shouldPromoteToSourceContext) ?? false)
                if shouldPromoteProvidedContext, let providedPageContent {
                    if RedditSummaryPlanner.isRedditContext(providedPageContent) {
                        sourcePageContext = providedPageContent
                    } else {
                        let contextCap = selectedBackend == .applePCCGateway
                            ? pccGatewayInputCharacterLimit
                            : mlxInputCharacterLimit
                        sourcePageContext = Self.truncatePreservingStructure(providedPageContent, maxChars: contextCap)
                    }
                }
                resolvedPageContent = {
                    guard let providedPageContent else { return sourcePageContext }
                    if shouldPromoteProvidedContext {
                        return providedPageContent
                    }
                    return sourcePageContext ?? providedPageContent
                }()
                recentConversation = nil
            }
            let showsUserPromptInSidebar = consumeNextUserPromptSidebarVisibility(defaultValue: true)
            let treatsPromptAsInstruction = !showsUserPromptInSidebar
            browserAIServiceLog("execute query promptChars=\(prompt.count) providedPageContentChars=\(providedPageContent?.count ?? 0) resolvedPageContentChars=\(resolvedPageContent?.count ?? 0) sourcePageContextChars=\(sourcePageContext?.count ?? 0) treatsPromptAsInstruction=\(treatsPromptAsInstruction)")
            appendRetainedMessage(.init(role: .user, text: prompt, showsInSidebar: showsUserPromptInSidebar), channel: .appBackend)
            Task(priority: .userInitiated) { [weak self] in
                guard let self else {
                    print("🔴 [query] self is nil in Task!")
                    return
                }
                browserAIServiceLog("runQuery task START requestID=\(requestID.uuidString.prefix(8)) backend=\(selectedBackend.rawValue)")
                print("🔵 [query] Task body entered, about to call runQuery")
                await self.runQuery(
                    prompt,
                    pageContent: resolvedPageContent,
                    conversationContext: recentConversation,
                    backend: selectedBackend,
                    treatsPromptAsInstruction: treatsPromptAsInstruction,
                    requestID: requestID
                )
                browserAIServiceLog("runQuery task END requestID=\(requestID.uuidString.prefix(8)) backend=\(selectedBackend.rawValue)")
                print("🔵 [query] runQuery returned")
            }
        case .summary(let content, let length):
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedContent.isEmpty,
               sourcePageContext == nil || Self.shouldPromoteToSourceContext(trimmedContent) {
                if RedditSummaryPlanner.isRedditContext(trimmedContent) {
                    // Keep the complete structured Reddit context for the map
                    // pass and for later follow-up questions.
                    sourcePageContext = trimmedContent
                } else {
                    let contextCap: Int
                    switch selectedBackend {
                    case .localApple:
                        contextCap = length == .short
                            ? appleLocalShortSummaryContextCharacterLimit
                            : appleLocalSummaryContextCharacterLimit
                    case .applePCCGateway:
                        contextCap = pccGatewayInputCharacterLimit
                    default:
                        contextCap = mlxInputCharacterLimit
                    }
                    // Preserve newline structure so follow-up queries can still
                    // parse "Title:" / "Body:" markers from the stored context.
                    sourcePageContext = Self.truncatePreservingStructure(content, maxChars: contextCap)
                }
            }
            if selectedBackend == .localApple {
                appleLocalFollowUpLog(
                    "execute.summary length=\(length == .short ? "short" : "long") contentChars=\(content.count) storedSourceContextChars=\(sourcePageContext?.count ?? 0)"
                )
            }
            let displayMessage = length == .short ? "Generate a short summary (2 paragraphs)" : "Generate a detailed summary"
            browserAIServiceLog("execute summary inputChars=\(content.count) storedSourcePageContextChars=\(sourcePageContext?.count ?? 0)")
            appendRetainedMessage(.init(role: .user, text: displayMessage), channel: .appBackend)
            Task(priority: .userInitiated) { [weak self] in
                browserAIServiceLog("runSummary task START requestID=\(requestID.uuidString.prefix(8)) backend=\(selectedBackend.rawValue)")
                await self?.runSummary(content, length: length, backend: selectedBackend, requestID: requestID)
                browserAIServiceLog("runSummary task END requestID=\(requestID.uuidString.prefix(8)) backend=\(selectedBackend.rawValue)")
            }
        }
    }

    @MainActor
    private func finishRequest() {
        let finishedRequestID = activeRequestID
        browserAIServiceLog("finishRequest enter activeChannel=\(activeMessageChannel == .webProvider ? "web" : "app") storedMessages=\(messages.count) queue=\(requestQueue.count)")
        if let finishedRequestID {
            browserAIServiceLog("finishRequest requestID=\(finishedRequestID.uuidString.prefix(8)) queueBefore=\(requestQueue.count)")
        } else {
            browserAIServiceLog("finishRequest requestID=nil queueBefore=\(requestQueue.count)")
        }
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        activeRequestID = nil
        activeAppleLocalStreamSessionID = nil
        isProcessing = false
        activeRedditRequestBackend = nil
        activeRequestIsReddit = false
        if !requestQueue.isEmpty {
            let next = requestQueue.removeFirst()
            queuedCount = requestQueue.count
            browserAIServiceLog("dequeue next=\(next.payload.debugLabel) queueAfter=\(queuedCount)")
            if let finishedRequestID {
                markAppleLocalQueueUnblocked(requestID: finishedRequestID, at: Date())
                logAndClearAppleLocalDiagnostics(requestID: finishedRequestID, nextRequestWillStart: true)
            }
            execute(next.payload, enqueuedAt: next.enqueuedAt)
        } else {
            queuedCount = 0
            browserAIServiceLog("finishRequest queue drained")
            let shouldResetAppleLocalSession = backend == .localApple && shouldResetAppleLocalAfterSummaryWhenIdle
            shouldResetAppleLocalAfterSummaryWhenIdle = false
            if let finishedRequestID {
                markAppleLocalQueueUnblocked(requestID: finishedRequestID, at: Date())
                logAndClearAppleLocalDiagnostics(requestID: finishedRequestID, nextRequestWillStart: false)
            }
            if shouldResetAppleLocalSession {
                appleLocalFollowUpLog("finishRequest queue drained -> scheduling post-summary reset")
                #if canImport(FoundationModels)
                Task {
                    appleLocalFollowUpLog("post-summary reset task start")
                    await AppleLocalGenerationService.shared.reset()
                    appleLocalFollowUpLog("post-summary reset task end")
                }
                #endif
            }
            // No standby warmup here — each Apple Local request calls
            // reset() + creates a fresh session to avoid any racing.
        }
    }

    private func runQuery(
        _ query: String,
        pageContent: String? = nil,
        conversationContext: String? = nil,
        backend: AIModelBackend,
        treatsPromptAsInstruction: Bool = false,
        requestID: UUID
    ) async {
        print("🔍 processQuery called with:")
        print("   Query: \(query)")
        print("   PageContent length: \(pageContent?.count ?? 0)")

        let sourceContext = pageContent ?? ""

        do {
            if RedditSummaryPlanner.isRedditContext(sourceContext),
               !backend.isWebProvider {
                let counter = AIThroughputCounter()
                await MainActor.run {
                    self.beginThroughputSession(sessionID: requestID, backend: backend)
                }
                let responseText = try await runRedditQuery(
                    query: query,
                    content: sourceContext,
                    length: shouldUseConciseAnswer(for: query) ? .short : .long,
                    backend: backend,
                    requestID: requestID,
                    counter: counter
                )
                await MainActor.run {
                    self.completeRequest(with: responseText, requestID: requestID)
                }
                await finishThroughputSessionIfNeeded(
                    requestID: requestID,
                    backend: backend,
                    counter: counter,
                    fallbackText: responseText
                )
                if backend == .mlxLocal {
                    await MLXLocalService.shared.clearTransientCache()
                }
                return
            }
            switch backend {
            case .cloudShortcuts:
                let condensed = Self.condense(sourceContext, maxChars: 6000)
                print("   Cloud - Condensed content length: \(condensed.count)")
                let concise = shouldUseConciseAnswer(for: query)
                let composed = buildQueryTaskBody(
                    question: query,
                    pageContext: condensed,
                    concise: concise,
                    conversationContext: conversationContext
                )

                if let responseText = try await runPrivateCloudComputeIfAvailable(prompt: composed) {
                    let counter = AIThroughputCounter()
                    await MainActor.run {
                        self.beginThroughputSession(sessionID: requestID, backend: .cloudShortcuts)
                        self.completeRequest(with: responseText, requestID: requestID)
                    }
                    await finishThroughputSessionIfNeeded(
                        requestID: requestID,
                        backend: .cloudShortcuts,
                        counter: counter,
                        fallbackText: responseText
                    )
                    return
                }

                cloudService.shortcutName = shortcutName

                await MainActor.run {
                    self.cloudService.launchCloudRequest(for: composed, type: .summary) { [weak self] output in
                        Task { @MainActor in
                            guard let self, self.isRequestActive(requestID) else { return }
                            self.completeRequest(with: output, requestID: requestID)
                        }
                    }
                }
                return

            case .applePCCGateway:
                let hasConversationContext = !(conversationContext?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let contextLimit = hasConversationContext ? pccGatewayFollowUpContextCharacterLimit : pccGatewayInputCharacterLimit
                let condensed = Self.truncatePreservingStructure(sourceContext, maxChars: contextLimit)
                print("   Apple PCC Gateway - Condensed content length: \(condensed.count)")
                let prompt: String
                if treatsPromptAsInstruction {
                    prompt = buildInstructionTaskBody(
                        instruction: query,
                        pageContext: condensed,
                        conversationContext: conversationContext
                    )
                } else {
                    prompt = buildQueryTaskBody(
                        question: query,
                        pageContext: condensed,
                        concise: false,
                        conversationContext: conversationContext
                    )
                }
                let counter = AIThroughputCounter()
                await MainActor.run {
                    self.beginThroughputSession(sessionID: requestID, backend: .applePCCGateway)
                }
                let responseText = try await makePCCGatewayClient().complete(prompt: prompt)
                await MainActor.run {
                    self.completeRequest(with: responseText, requestID: requestID)
                }
                await finishThroughputSessionIfNeeded(
                    requestID: requestID,
                    backend: .applePCCGateway,
                    counter: counter,
                    fallbackText: responseText
                )

            case .localApple:
                appleLocalFollowUpLog("runQuery local start requestID=\(requestID.uuidString.prefix(8)) queryChars=\(query.count) pageContentChars=\(pageContent?.count ?? 0)")
                let inlineContext = Self.parseInlineContext(from: query)
                var effectiveQuestion = query
                var effectiveSource = sourceContext

                if let inlineContext {
                    effectiveSource = inlineContext.context
                    let trimmedInline = inlineContext.context.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedInline.isEmpty {
                        let storedContext = Self.truncatePreservingStructure(
                            trimmedInline,
                            maxChars: appleLocalSummaryContextCharacterLimit
                        )
                        await MainActor.run {
                            self.sourcePageContext = storedContext
                        }
                    }

                    if let inlineQuestion = inlineContext.question, !inlineQuestion.isEmpty {
                        effectiveQuestion = inlineQuestion
                        print("   Local FoundationModels - Using pasted context length: \(inlineContext.context.count)")
                    } else {
                        await MainActor.run {
                            self.completeRequest(
                                with: "Pasted text saved as context. Ask a question about it.",
                                requestID: requestID
                            )
                        }
                        return
                    }
                }

                let trimmedSource = effectiveSource.trimmingCharacters(in: .whitespacesAndNewlines)
                let condensed = trimmedSource.isEmpty
                    ? ""
                    : Self.buildAppleLocalTitleBodyContext(
                        from: effectiveSource,
                        maxBodyChars: appleLocalQueryContextCharacterLimit
                    )
                print("   Local FoundationModels - Condensed content length: \(condensed.count)")
                let concise = shouldUseConciseAnswer(for: effectiveQuestion)
                // Build a prompt that starts with "User question:" so that
                // AppleLocalGenerationService.normalizedPrompt() returns it unchanged
                // (no double-wrapping). The previous buildQueryTaskBody approach embedded
                // "User question:" near the end, causing the actor to wrap the whole thing
                // in another "User question:" — making Apple Intelligence stall consistently
                // after a prior summary.
                let queryBody: String = {
                    let q = normalizePrompt(effectiveQuestion)
                    let instruction = concise
                        ? "Answer in one short sentence using only the context below. If the answer is not present, say so."
                        : "Answer using only the context below. If the answer is not present, say so."
                    if condensed.isEmpty {
                        return "User question: \(q)\n\n\(instruction)"
                    }
                    return "User question: \(q)\n\n\(instruction)\n\nContext:\n\(condensed)"
                }()
                let preparedPrompt = optimizedPromptForAppleLocal(queryBody)
                let maxOutputTokens = cappedAppleLocalQueryOutputTokens(question: effectiveQuestion)
                let retryContext = trimmedSource.isEmpty
                    ? ""
                    : Self.buildAppleLocalTitleBodyContext(
                        from: effectiveSource,
                        maxBodyChars: appleLocalRetryBodyCharacterLimit
                    )
                let retryPrompt = optimizedPromptForAppleLocal(
                    buildAppleLocalRetryQueryPrompt(question: effectiveQuestion, context: retryContext)
                )
                let counter = AIThroughputCounter()

                #if canImport(FoundationModels)
                if #available(iOS 18.2, macOS 15.2, *) {
                    await MainActor.run {
                        self.beginThroughputSession(sessionID: requestID, backend: .localApple)
                    }
                    print("🍎 [Apple Local Query] Starting direct request (prompt: \(preparedPrompt.count) chars)")
                    appleLocalFollowUpLog("runQuery local preparedPromptChars=\(preparedPrompt.count) retryPromptChars=\(retryPrompt.count)")
                    let responseText = try await runAppleLocalDirectWithRetry(
                        primaryPrompt: preparedPrompt,
                        primaryMaxOutputTokens: maxOutputTokens,
                        retryPrompt: retryPrompt,
                        requestID: requestID,
                        counter: counter
                    )
                    print("🍎 [Apple Local Query] Completed: \(responseText.count) chars")
                    await MainActor.run {
                        self.completeRequest(with: responseText, requestID: requestID)
                    }
                    await finishThroughputSessionIfNeeded(
                        requestID: requestID,
                        backend: .localApple,
                        counter: counter,
                        fallbackText: responseText
                    )
                } else {
                    await MainActor.run {
                        self.completeRequest(
                            with: "Apple local model requires iOS 18.2+ or macOS 15.2+.",
                            requestID: requestID
                        )
                    }
                }
                #else
                let ctx = PageContext(url: nil, title: nil, selection: nil, summary: condensed)
                let agent = AIAgent(backend: .appleIntelligenceLocal)
                let text = await agent.ask(effectiveQuestion, context: ctx)
                await MainActor.run {
                    self.completeRequest(with: text, requestID: requestID)
                }
                #endif

            case .mlxLocal:
                guard MLXLocalService.isAvailable() else {
                    await MainActor.run {
                        self.completeRequest(with: "MLX Local is not available on this device/build.", requestID: requestID)
                    }
                    return
                }

                let hasConversationContext = !(conversationContext?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let contextLimit = hasConversationContext ? mlxFollowUpContextCharacterLimit : mlxQueryContextCharacterLimit
                let condensed = Self.condense(sourceContext, maxChars: contextLimit)
                print("   MLX Local - Condensed content length: \(condensed.count)")

                let settings = MLXLocalSettings.load()
                let mlxSystemPrompt = buildMLXSystemPrompt(context: condensed, conversationContext: conversationContext)
                let concise = shouldUseConciseAnswer(for: query)
                let mlxUserPrompt = buildMLXUserPrompt(question: query, concise: concise, context: condensed, conversationContext: conversationContext)
                print("   MLX Local - System prompt length: \(mlxSystemPrompt.count), User prompt length: \(mlxUserPrompt.count)")
                let maxOutputTokens = cappedMLXQueryOutputTokens(settings.maxOutputTokens, question: query)
                let maxContextTokens = cappedMLXContextTokens(settings.maxContextTokens)
                let counter = AIThroughputCounter()
                let streamAccumulator = StreamChunkAccumulator(
                    minimumCharacters: 320,
                    minimumInterval: 0.12
                ) { [weak self] flushed in
                    guard let self else { return }
                    await self.handleStreamChunk(
                        flushed,
                        requestID: requestID,
                        backend: .mlxLocal,
                        counter: counter
                    )
                }
                await MainActor.run {
                    self.beginThroughputSession(sessionID: requestID, backend: .mlxLocal)
                }

                let metrics = try await withTimeout(seconds: mlxGenerationTimeoutSeconds) {
                    try await MLXLocalService.shared.generateTextWithMetrics(
                        prompt: mlxUserPrompt,
                        systemPrompt: mlxSystemPrompt,
                        modelID: settings.modelID,
                        maxOutputTokens: maxOutputTokens,
                        maxContextTokens: maxContextTokens,
                        onToken: { chunk in
                            await streamAccumulator.append(chunk)
                        }
                    )
                }
                await streamAccumulator.finish()
                await finishThroughputSession(
                    requestID: requestID,
                    backend: .mlxLocal,
                    tokens: metrics.tokenCount,
                    elapsed: metrics.elapsed
                )
                await MainActor.run {
                    self.completeRequest(with: metrics.text, requestID: requestID)
                }

            case .webChatGPT, .webGemini:
                await MainActor.run {
                    self.completeRequest(with: "Use the \(backend.displayName) pane to send prompts.", requestID: requestID)
                }
            }
        } catch {
            if backend == .mlxLocal {
                let settings = MLXLocalSettings.load()
                await MLXLocalService.shared.resetModelState(modelID: settings.modelID)
            }
            await MainActor.run {
                let message: String
                if backend == .mlxLocal, error is MLXTimeoutError {
                    message = "MLX timed out. Please try again."
                } else {
                    message = "Error: \(error.localizedDescription)"
                }
                self.completeRequest(with: message, requestID: requestID)
                self.clearThroughputIfSessionMatches(sessionID: requestID)
            }
        }
    }

    private static func condense(_ text: String, maxChars: Int) -> String {
        guard !text.isEmpty else { return "" }
        let collapsed = text
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.prefix(maxChars))
    }

    /// Truncate text while preserving newline structure (needed so downstream
    /// parsers like ``parseTitleAndBody`` can still find "Title:" / "Body:"
    /// markers).  Collapses runs of 3+ newlines and long whitespace runs but
    /// keeps single/double newlines intact.
    private static func truncatePreservingStructure(_ text: String, maxChars: Int) -> String {
        guard !text.isEmpty else { return "" }
        // Collapse runs of 3+ newlines to double-newline.
        var cleaned = text.replacingOccurrences(
            of: #"\n{3,}"#, with: "\n\n", options: .regularExpression
        )
        // Collapse runs of spaces/tabs (but not newlines) to a single space.
        cleaned = cleaned.replacingOccurrences(
            of: #"[^\S\n]{2,}"#, with: " ", options: .regularExpression
        )
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars { return trimmed }
        return String(trimmed.prefix(maxChars))
    }

    private static func sanitizeModelContext(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let withoutScripts = text.replacingOccurrences(
            of: #"(?is)<(script|style)[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        let withoutTags = withoutScripts.replacingOccurrences(
            of: #"(?is)</?[a-zA-Z][^>]*>"#,
            with: " ",
            options: .regularExpression
        )
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return decoded
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func parseTitleAndBody(from text: String) -> (title: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, "") }
        let hasExplicitFormat =
            trimmed.range(of: #"(?is)^\s*Title:"#, options: .regularExpression) != nil
            || trimmed.range(of: #"(?is)^\s*Body:"#, options: .regularExpression) != nil
        guard hasExplicitFormat else {
            return (nil, trimmed)
        }
        let bodyMarkers = ["\n\nBody:", "\nBody:", "Body:"]
        guard let marker = bodyMarkers.compactMap({ marker in
            trimmed.range(of: marker, options: [.caseInsensitive])
        }).first else {
            return (nil, trimmed)
        }

        let head = String(trimmed[..<marker.lowerBound])
        let tail = String(trimmed[marker.upperBound...])
        let title: String? = {
            guard let titleRange = head.range(of: "Title:", options: [.caseInsensitive]) else { return nil }
            let value = String(head[titleRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }()

        return (title, tail)
    }

    private static func buildAppleLocalTitleBodyContext(from text: String, maxBodyChars: Int) -> String {
        let parsed = parseTitleAndBody(from: text)
        let sanitizedTitle = sanitizeModelContext(parsed.title ?? "")
        var sanitizedBody = sanitizeModelContext(parsed.body)
        if sanitizedBody.isEmpty {
            sanitizedBody = sanitizeModelContext(text)
        }
        let condensedBody = condense(sanitizedBody, maxChars: maxBodyChars)

        if !sanitizedTitle.isEmpty {
            return "Title: \(sanitizedTitle)\n\nBody:\n\(condensedBody)"
        }
        return "Body:\n\(condensedBody)"
    }

    private static func shouldPromoteToSourceContext(_ text: String) -> Bool {
        let normalized = condense(text, maxChars: max(1, text.count))
        guard !normalized.isEmpty else { return false }
        if normalized.count >= 480 { return true }
        let wordCount = normalized.split(separator: " ").count
        return wordCount >= 90
    }

    private enum RedditGenerationPhase {
        case map
        case reduction
        case final
    }

    private func runRedditSummary(
        content: String,
        length: SummaryLength,
        backend: AIModelBackend,
        requestID: UUID,
        counter: AIThroughputCounter
    ) async throws -> String {
        let plan = RedditSummaryPlanner.plan(content: content, backend: backend)
        guard !plan.chunks.isEmpty else {
            throw NSError(
                domain: "SimpleAIService.Reddit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Reddit thread did not contain any summarizable content."]
            )
        }
        print(
            "🧵 [Reddit Summary] backend=\(backend.rawValue) chunks=\(plan.chunkCount) comments=\(plan.totalCommentCount) budget=\(plan.characterBudget)"
        )

        if RedditSummaryPlanner.shouldUseSingleGeneration(plan: plan, backend: backend) {
            let prompt = buildRedditDirectSummaryPrompt(
                chunk: plan.chunks[0],
                requestedLength: length
            )
            let synthesis = try await generateRedditResponse(
                prompt: prompt,
                backend: backend,
                length: length,
                phase: .final,
                requestID: requestID,
                counter: counter
            )
            let trimmed = synthesis.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw NSError(
                    domain: "SimpleAIService.Reddit",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The selected model returned an empty Reddit summary."]
                )
            }
            let coverageLine = "Reddit summary coverage: summarized \(plan.totalCommentCount) accessible comments across \(plan.chunkCount) parts."
            let partialNotice = content.contains("(partial extraction)")
                ? " Extraction was partial; the source did not expose every accessible comment."
                : ""
            return "\(coverageLine)\(partialNotice)\n\n\(trimmed)"
        }

        var partials: [String] = []
        partials.reserveCapacity(plan.chunks.count)
        for chunk in plan.chunks {
            try Task.checkCancellation()
            let prompt = buildRedditMapPrompt(
                chunk: chunk,
                totalChunks: plan.chunkCount,
                requestedLength: length
            )
            let partial = try await generateRedditResponse(
                prompt: prompt,
                backend: backend,
                length: length,
                phase: .map,
                requestID: requestID,
                counter: counter
            )
            let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw NSError(
                    domain: "SimpleAIService.Reddit",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The selected model returned an empty Reddit partial summary."]
                )
            }
            partials.append(trimmed)
        }

        let finalInstruction = buildRedditFinalSummaryPrompt(length: length)
        let synthesis = try await reduceRedditPartials(
            partials,
            backend: backend,
            length: length,
            finalInstruction: finalInstruction,
            requestID: requestID,
            counter: counter
        )
        let coverageLine = "Reddit summary coverage: summarized \(plan.totalCommentCount) accessible comments across \(plan.chunkCount) parts."
        let partialNotice = content.contains("(partial extraction)")
            ? " Extraction was partial; the source did not expose every accessible comment."
            : ""
        return "\(coverageLine)\(partialNotice)\n\n\(synthesis)"
    }

    private func runRedditQuery(
        query: String,
        content: String,
        length: SummaryLength,
        backend: AIModelBackend,
        requestID: UUID,
        counter: AIThroughputCounter
    ) async throws -> String {
        let plan = RedditSummaryPlanner.plan(content: content, backend: backend)
        guard !plan.chunks.isEmpty else {
            throw NSError(
                domain: "SimpleAIService.Reddit",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Reddit thread did not contain any searchable content."]
            )
        }
        print(
            "🧵 [Reddit Query] backend=\(backend.rawValue) chunks=\(plan.chunkCount) comments=\(plan.totalCommentCount) budget=\(plan.characterBudget)"
        )

        if RedditSummaryPlanner.shouldUseSingleGeneration(plan: plan, backend: backend) {
            let prompt = buildRedditDirectQueryPrompt(
                question: query,
                chunk: plan.chunks[0],
                requestedLength: length
            )
            let answer = try await generateRedditResponse(
                prompt: prompt,
                backend: backend,
                length: length,
                phase: .final,
                requestID: requestID,
                counter: counter
            )
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "I couldn't find an answer in the accessible Reddit comments."
            }
            let coverageLine = "Reddit query coverage: checked \(plan.totalCommentCount) accessible comments across \(plan.chunkCount) parts."
            let partialNotice = content.contains("(partial extraction)")
                ? " The source extraction was partial."
                : ""
            return "\(coverageLine)\(partialNotice)\n\n\(trimmed)"
        }

        var partials: [String] = []
        partials.reserveCapacity(plan.chunks.count)
        for chunk in plan.chunks {
            try Task.checkCancellation()
            let prompt = buildRedditMapQueryPrompt(
                question: query,
                chunk: chunk,
                totalChunks: plan.chunkCount
            )
            let partial = try await generateRedditResponse(
                prompt: prompt,
                backend: backend,
                length: length,
                phase: .map,
                requestID: requestID,
                counter: counter
            )
            let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            partials.append(trimmed)
        }
        guard !partials.isEmpty else {
            return "I couldn't find an answer in the accessible Reddit comments."
        }

        let finalInstruction = buildRedditFinalQueryPrompt(question: query, length: length)
        let synthesis = try await reduceRedditPartials(
            partials,
            backend: backend,
            length: length,
            finalInstruction: finalInstruction,
            requestID: requestID,
            counter: counter
        )
        let coverageLine = "Reddit query coverage: checked \(plan.totalCommentCount) accessible comments across \(plan.chunkCount) parts."
        let partialNotice = content.contains("(partial extraction)")
            ? " The source extraction was partial."
            : ""
        return "\(coverageLine)\(partialNotice)\n\n\(synthesis)"
    }

    private func reduceRedditPartials(
        _ partials: [String],
        backend: AIModelBackend,
        length: SummaryLength,
        finalInstruction: String,
        requestID: UUID,
        counter: AIThroughputCounter
    ) async throws -> String {
        var current = partials
        var pass = 0
        while current.count > 1 {
            try Task.checkCancellation()
            pass += 1
            let groups = RedditSummaryPlanner.reductionGroups(current, backend: backend)
            guard !groups.isEmpty else { break }
            var reduced: [String] = []
            reduced.reserveCapacity(groups.count)
            for group in groups {
                try Task.checkCancellation()
                let prompt = buildRedditReductionPrompt(
                    partials: group.joined(separator: "\n\n"),
                    pass: pass,
                    requestedLength: length
                )
                let result = try await generateRedditResponse(
                    prompt: prompt,
                    backend: backend,
                    length: length,
                    phase: .reduction,
                    requestID: requestID,
                    counter: counter
                )
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { reduced.append(trimmed) }
            }
            guard !reduced.isEmpty else { break }
            // A provider that returns an unusually long partial can make every
            // reduction record exceed its budget. Preserve all generated parts
            // as the honest fallback instead of silently dropping a suffix.
            if reduced.count >= current.count {
                return reduced.joined(separator: "\n\n")
            }
            current = reduced
        }

        let source = current.joined(separator: "\n\n")
        let finalPrompt = "\(finalInstruction)\n\nPartial synthesis:\n\(source)"
        return try await generateRedditResponse(
            prompt: finalPrompt,
            backend: backend,
            length: length,
            phase: .final,
            requestID: requestID,
            counter: counter
        )
    }

    private func generateRedditResponse(
        prompt: String,
        backend: AIModelBackend,
        length: SummaryLength,
        phase: RedditGenerationPhase,
        requestID: UUID,
        counter: AIThroughputCounter
    ) async throws -> String {
        try Task.checkCancellation()
        switch backend {
        case .localApple:
            let outputTokens: Int = {
                switch phase {
                case .final:
                    return cappedAppleLocalSummaryOutputTokens(length: length)
                default:
                    return min(appleLocalRetryMaxOutputTokens, 160)
                }
            }()
            #if canImport(FoundationModels)
            guard #available(iOS 18.2, macOS 15.2, *) else {
                throw NSError(
                    domain: "SimpleAIService.Reddit",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Apple local model requires iOS 18.2+ or macOS 15.2+."]
                )
            }
            let preparedPrompt = optimizedRedditPromptForAppleLocal(prompt)
            let retryPrompt = optimizedRedditPromptForAppleLocal(
                "Use only the supplied Reddit material. Return a compact, faithful synthesis.\n\n\(prompt)"
            )
            return try await runAppleLocalRedditStreamWithRetry(
                primaryPrompt: preparedPrompt,
                primaryMaxOutputTokens: outputTokens,
                retryPrompt: retryPrompt,
                requestID: requestID,
                counter: counter
            )
            #else
            let context = PageContext(url: nil, title: nil, selection: nil, summary: prompt)
            let agent = AIAgent(backend: .appleIntelligenceLocal)
            return await agent.ask(prompt, context: context)
            #endif

        case .mlxLocal:
            guard MLXLocalService.isAvailable() else {
                throw NSError(
                    domain: "SimpleAIService.Reddit",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "MLX Local is not available on this device/build."]
                )
            }
            let settings = MLXLocalSettings.load()
            let preparedPrompt = settings.truncatePromptToFitContext(optimizedPromptForMLX(prompt))
            let configuredOutput = cappedMLXOutputTokens(settings.maxOutputTokens)
            let outputTokens = phase == .final ? configuredOutput : min(configuredOutput, 256)
            let metrics = try await withTimeout(seconds: mlxGenerationTimeoutSeconds) {
                try await MLXLocalService.shared.generateTextWithMetrics(
                    prompt: preparedPrompt,
                    modelID: settings.modelID,
                    maxOutputTokens: outputTokens,
                    maxContextTokens: self.cappedMLXContextTokens(settings.maxContextTokens),
                    onToken: nil
                )
            }
            counter.add(units: metrics.tokenCount)
            return metrics.text

        case .applePCCGateway:
            return try await makePCCGatewayClient().complete(prompt: prompt)

        case .cloudShortcuts:
            if let response = try await runPrivateCloudComputeIfAvailable(prompt: prompt) {
                return response
            }
            return try await runCloudShortcutResponse(prompt: prompt)

        case .webChatGPT, .webGemini:
            throw NSError(
                domain: "SimpleAIService.Reddit",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Web Reddit summaries are handled by the provider session."]
            )
        }
    }

    private func runCloudShortcutResponse(prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.cloudService.shortcutName = self.shortcutName
                self.cloudService.launchCloudRequest(for: prompt, type: .summary) { output in
                    continuation.resume(returning: output)
                }
            }
        }
    }

    private func buildRedditDirectSummaryPrompt(
        chunk: RedditSummaryChunk,
        requestedLength: SummaryLength
    ) -> String {
        let instruction = requestedLength == .short
            ? "Write a short but complete Reddit thread summary in at most two concise paragraphs. State the main topic and outcome, then the most important supporting points and notable disagreement."
            : "Write a detailed but clear summary of the Reddit thread. Cover the main topic, recurring themes, evidence, important high-scored or minority perspectives, and disagreements."
        return """
        \(instruction)
        The Reddit material below is the complete accessible thread for this request, not a partial synthesis. Use only this material. Do not invent details or claim certainty the source does not support.

        Reddit material:
        \(chunk.text)
        """
    }

    private func buildRedditDirectQueryPrompt(
        question: String,
        chunk: RedditSummaryChunk,
        requestedLength: SummaryLength
    ) -> String {
        let style = requestedLength == .short
            ? "Answer briefly in one or two concise paragraphs."
            : "Answer clearly and in detail, distinguishing consensus from disagreement."
        return """
        Answer the user's Reddit question using only the complete accessible Reddit thread below. \(style) If the evidence is insufficient, say so. This is the complete thread for this request, not a partial synthesis. Do not invent details or infer from missing comments.

        User question:
        \(question)

        Reddit material:
        \(chunk.text)
        """
    }

    private func buildRedditMapPrompt(
        chunk: RedditSummaryChunk,
        totalChunks: Int,
        requestedLength: SummaryLength
    ) -> String {
        let detail = requestedLength == .short
            ? "Capture every distinct important point in a compact set of notes; the final answer will be short."
            : "Capture themes, evidence, disagreements, minority views, and useful high-scored insights."
        return """
        Summarize this part of a Reddit thread for a later synthesis. This is part \(chunk.index + 1) of \(totalChunks) and contains \(chunk.commentCount) comment records.
        \(detail)
        Do not invent facts or claim this part represents comments it does not contain. Keep concrete names, claims, and disagreements. Return only faithful notes.

        Reddit material:
        \(chunk.text)
        """
    }

    private func buildRedditMapQueryPrompt(
        question: String,
        chunk: RedditSummaryChunk,
        totalChunks: Int
    ) -> String {
        """
        Find evidence relevant to the user's question in this part of a Reddit thread. This is part \(chunk.index + 1) of \(totalChunks).
        List relevant claims, disagreements, and supporting details faithfully. If this part has no relevant evidence, say exactly: No relevant evidence in this part. Do not infer from missing parts.

        User question:
        \(question)

        Reddit material:
        \(chunk.text)
        """
    }

    private func buildRedditReductionPrompt(
        partials: String,
        pass: Int,
        requestedLength: SummaryLength
    ) -> String {
        let detail = requestedLength == .short
            ? "Keep the synthesis compact while retaining every distinct important point."
            : "Retain distinct themes, disagreements, minority opinions, and concrete supporting details."
        return """
        Combine these partial Reddit notes in reduction pass \(pass) into one faithful synthesis.
        \(detail)
        Do not add facts, erase disagreement, or mention internal passes. Every supplied partial must influence the result.

        \(partials)
        """
    }

    private func buildRedditFinalSummaryPrompt(length: SummaryLength) -> String {
        if length == .short {
            return """
            Write a short but complete Reddit thread summary in at most two concise paragraphs. State the main topic and outcome, then the most important supporting points and notable disagreement. Use only the partial synthesis below.
            """
        }
        return """
        Write a detailed but clear summary of the Reddit thread from the partial synthesis below. Cover the main topic, recurring themes, evidence, important high-scored or minority perspectives, and disagreements. Do not invent details or claim certainty the source does not support.
        """
    }

    private func buildRedditFinalQueryPrompt(question: String, length: SummaryLength) -> String {
        let style = length == .short
            ? "Answer briefly in one or two concise paragraphs."
            : "Answer clearly and in detail, distinguishing consensus from disagreement."
        return """
        Answer the user's Reddit question using only the partial synthesis below. \(style) If the evidence is insufficient, say so. Do not mention internal synthesis passes.

        User question:
        \(question)
        """
    }

    private func runSummary(
        _ content: String,
        length: SummaryLength = .long,
        backend: AIModelBackend,
        requestID: UUID
    ) async {
        do {
            if RedditSummaryPlanner.isRedditContext(content),
               !backend.isWebProvider {
                let counter = AIThroughputCounter()
                await MainActor.run {
                    self.beginThroughputSession(sessionID: requestID, backend: backend)
                }
                let responseText = try await runRedditSummary(
                    content: content,
                    length: length,
                    backend: backend,
                    requestID: requestID,
                    counter: counter
                )
                await MainActor.run {
                    if backend == .localApple {
                        self.shouldResetAppleLocalAfterSummaryWhenIdle = true
                        self.pendingAppleLocalPostSummaryFollowUp = true
                    }
                    self.completeRequest(with: responseText, requestID: requestID)
                }
                await finishThroughputSessionIfNeeded(
                    requestID: requestID,
                    backend: backend,
                    counter: counter,
                    fallbackText: responseText
                )
                if backend == .mlxLocal {
                    await MLXLocalService.shared.clearTransientCache()
                }
                return
            }
            switch backend {
            case .cloudShortcuts:
                let prompt: String
                if length == .short {
                    prompt = "Provide a brief 2-paragraph summary of the following text. First paragraph: main topic. Second paragraph: key points. Be concise:\n\n" + content
                } else {
                    prompt = "Summarize the following text clearly, highlighting key themes and points. Provide a detailed analysis:\n\n" + content
                }

                if let responseText = try await runPrivateCloudComputeIfAvailable(prompt: prompt) {
                    let counter = AIThroughputCounter()
                    await MainActor.run {
                        self.beginThroughputSession(sessionID: requestID, backend: .cloudShortcuts)
                        self.completeRequest(with: responseText, requestID: requestID)
                    }
                    await finishThroughputSessionIfNeeded(
                        requestID: requestID,
                        backend: .cloudShortcuts,
                        counter: counter,
                        fallbackText: responseText
                    )
                    return
                }

                cloudService.shortcutName = shortcutName

                await MainActor.run {
                    self.cloudService.launchCloudRequest(for: prompt, type: .summary) { [weak self] output in
                        Task { @MainActor in
                            guard let self, self.isRequestActive(requestID) else { return }
                            self.completeRequest(with: output, requestID: requestID)
                        }
                    }
                }

            case .applePCCGateway:
                let condensedContent = Self.truncatePreservingStructure(content, maxChars: pccGatewayInputCharacterLimit)
                print("Condensed content for Apple PCC Gateway: \(condensedContent.count) chars (original: \(content.count))")

                let prompt: String
                if length == .short {
                    prompt = """
                    Summarize the following article in 2 short but complete paragraphs.
                    Paragraph 1: state the main topic, outcome, or announcement.
                    Paragraph 2: include the most important supporting details, people/companies involved, and any notable implications if present.
                    Keep it concise, but do not make it overly brief or vague.

                    \(condensedContent)
                    """
                } else {
                    prompt = "Summarize the following text clearly, highlighting key themes and points. Provide a detailed analysis:\n\n" + condensedContent
                }

                let counter = AIThroughputCounter()
                await MainActor.run {
                    self.beginThroughputSession(sessionID: requestID, backend: .applePCCGateway)
                }
                let responseText = try await makePCCGatewayClient().complete(prompt: prompt)
                await MainActor.run {
                    self.completeRequest(with: responseText, requestID: requestID)
                }
                await finishThroughputSessionIfNeeded(
                    requestID: requestID,
                    backend: .applePCCGateway,
                    counter: counter,
                    fallbackText: responseText
                )

            case .localApple:
                let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                let summaryContextLimit = length == .short
                    ? appleLocalShortSummaryContextCharacterLimit
                    : appleLocalSummaryContextCharacterLimit
                let condensedContent = trimmedContent.isEmpty
                    ? ""
                    : Self.buildAppleLocalTitleBodyContext(
                        from: content,
                        maxBodyChars: summaryContextLimit
                    )
                print("📄 Condensed content for local model: \(condensedContent.count) chars (original: \(content.count))")
                appleLocalFollowUpLog("runSummary local start length=\(length == .short ? "short" : "long") condensedChars=\(condensedContent.count)")

                let prompt: String
                if length == .short {
                    prompt = """
                    Summarize the following article in 2 short but complete paragraphs.
                    Paragraph 1: state the main topic, outcome, or announcement.
                    Paragraph 2: include the most important supporting details, people/companies involved, and any notable implications if present.
                    Keep it concise, but do not make it overly brief or vague.

                    \(condensedContent)
                    """
                } else {
                    prompt = "Summarize the following text clearly, highlighting key themes and points. Provide a detailed analysis:\n\n" + condensedContent
                }
                let preparedPrompt = optimizedPromptForAppleLocal(prompt)
                let maxOutputTokens = cappedAppleLocalSummaryOutputTokens(length: length)
                let retryContextLimit = length == .short
                    ? appleLocalShortRetryBodyCharacterLimit
                    : appleLocalRetryBodyCharacterLimit
                let retryContext = trimmedContent.isEmpty
                    ? ""
                    : Self.buildAppleLocalTitleBodyContext(
                        from: content,
                        maxBodyChars: retryContextLimit
                    )
                let retryPrompt = optimizedPromptForAppleLocal(
                    buildAppleLocalRetrySummaryPrompt(context: retryContext)
                )
                let counter = AIThroughputCounter()

                #if canImport(FoundationModels)
                if #available(iOS 18.2, macOS 15.2, *) {
                    await MainActor.run {
                        self.beginThroughputSession(sessionID: requestID, backend: .localApple)
                    }
                    print("🍎 [Apple Local Summary] Starting direct request (prompt: \(preparedPrompt.count) chars)")
                    appleLocalFollowUpLog("runSummary local preparedPromptChars=\(preparedPrompt.count) retryPromptChars=\(retryPrompt.count)")
                    let responseText = try await runAppleLocalDirectWithRetry(
                        primaryPrompt: preparedPrompt,
                        primaryMaxOutputTokens: maxOutputTokens,
                        retryPrompt: retryPrompt,
                        requestID: requestID,
                        counter: counter
                    )
                    print("🍎 [Apple Local Summary] Completed: \(responseText.count) chars")
                    await MainActor.run {
                        self.shouldResetAppleLocalAfterSummaryWhenIdle = true
                        self.pendingAppleLocalPostSummaryFollowUp = true
                        self.completeRequest(with: responseText, requestID: requestID)
                    }
                    appleLocalFollowUpLog("runSummary local complete -> flagged post-summary follow-up reset")
                    await finishThroughputSessionIfNeeded(
                        requestID: requestID,
                        backend: .localApple,
                        counter: counter,
                        fallbackText: responseText
                    )
                } else {
                    await MainActor.run {
                        self.completeRequest(
                            with: "Apple local model requires iOS 18.2+ or macOS 15.2+.",
                            requestID: requestID
                        )
                    }
                }
                #else
                let ctx = PageContext(url: nil, title: nil, selection: nil, summary: condensedContent)
                let agent = AIAgent(backend: .appleIntelligenceLocal)
                let text = await agent.ask(prompt, context: ctx)
                await MainActor.run {
                    self.completeRequest(with: text, requestID: requestID)
                }
                #endif

            case .mlxLocal:
                guard MLXLocalService.isAvailable() else {
                    await MainActor.run {
                        self.completeRequest(with: "MLX Local is not available on this device/build.", requestID: requestID)
                    }
                    return
                }

                let condensedContent = Self.condense(content, maxChars: mlxInputCharacterLimit)
                print("Condensed content for MLX local: \(condensedContent.count) chars (original: \(content.count))")

                let prompt: String
                if length == .short {
                    prompt = "Provide a brief 2-paragraph summary of the following text. First paragraph: main topic. Second paragraph: key points. Be concise:\n\n" + condensedContent
                } else {
                    prompt = "Summarize the following text clearly, highlighting key themes and points. Provide a detailed analysis:\n\n" + condensedContent
                }

                let settings = MLXLocalSettings.load()
                let preparedPrompt = settings.truncatePromptToFitContext(optimizedPromptForMLX(prompt))
                let maxOutputTokens = cappedMLXOutputTokens(settings.maxOutputTokens)
                let maxContextTokens = cappedMLXContextTokens(settings.maxContextTokens)
                let counter = AIThroughputCounter()
                let streamAccumulator = StreamChunkAccumulator(
                    minimumCharacters: 320,
                    minimumInterval: 0.12
                ) { [weak self] flushed in
                    guard let self else { return }
                    await self.handleStreamChunk(
                        flushed,
                        requestID: requestID,
                        backend: .mlxLocal,
                        counter: counter
                    )
                }
                await MainActor.run {
                    self.beginThroughputSession(sessionID: requestID, backend: .mlxLocal)
                }

                let metrics = try await withTimeout(seconds: mlxGenerationTimeoutSeconds) {
                    try await MLXLocalService.shared.generateTextWithMetrics(
                        prompt: preparedPrompt,
                        modelID: settings.modelID,
                        maxOutputTokens: maxOutputTokens,
                        maxContextTokens: maxContextTokens,
                        onToken: { chunk in
                            await streamAccumulator.append(chunk)
                        }
                    )
                }
                await streamAccumulator.finish()
                await finishThroughputSession(
                    requestID: requestID,
                    backend: .mlxLocal,
                    tokens: metrics.tokenCount,
                    elapsed: metrics.elapsed
                )
                // Clear GPU compute cache to free transient memory from the
                // summary generation.  Do NOT call resetModelState here — that
                // evicts the model from modelCache, forcing a full disk reload
                // on the next query which triggers Metal main-thread sync
                // (beach ball).  The model weights are unchanged; each
                // generation already builds fresh chat messages so prior
                // KV-cache state is irrelevant.
                await MLXLocalService.shared.clearTransientCache()
                await MainActor.run {
                    self.completeRequest(with: metrics.text, requestID: requestID)
                }

            case .webChatGPT, .webGemini:
                await MainActor.run {
                    self.completeRequest(with: "Summaries are available for Local, Cloud, Apple PCC Gateway, or MLX.", requestID: requestID)
                }
            }
        } catch {
            if backend == .mlxLocal {
                await MLXLocalService.shared.clearTransientCache()
            }
            await MainActor.run {
                let message: String
                if backend == .mlxLocal, error is MLXTimeoutError {
                    message = "MLX timed out. Please try again."
                } else {
                    message = "Error: \(error.localizedDescription)"
                }
                self.completeRequest(with: message, requestID: requestID)
                self.clearThroughputIfSessionMatches(sessionID: requestID)
            }
        }
    }

    private func emitTextInChunks(
        _ text: String,
        requestID: UUID,
        backend: AIModelBackend,
        counter: AIThroughputCounter,
        chunkSize: Int,
        delayNanoseconds: UInt64
    ) async {
        guard !text.isEmpty else { return }
        let size = max(1, chunkSize)

        var index = text.startIndex
        while index < text.endIndex {
            let nextIndex = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[index..<nextIndex])
            index = nextIndex

            await handleStreamChunk(chunk, requestID: requestID, backend: backend, counter: counter)

            if index < text.endIndex && delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
    }

    private func handleStreamChunk(
        _ chunk: String,
        requestID: UUID,
        backend: AIModelBackend,
        counter: AIThroughputCounter,
        tokenUnits: Int? = nil
    ) async {
        let units = tokenUnits ?? Self.estimatedUnits(for: chunk, backend: backend)
        let now = Date()
        let snapshot = counter.record(units: units, now: now)

        await MainActor.run {
            guard self.isRequestActive(requestID) else { return }

            if let snapshot {
                self.updateThroughputSession(
                    sessionID: requestID,
                    backend: backend,
                    tokens: snapshot.tokens,
                    elapsed: snapshot.elapsed,
                    tokensPerSecond: snapshot.tokensPerSecond
                )
            }

            if self.streamState.text.isEmpty {
                browserAIServiceLog("firstOutput requestID=\(requestID.uuidString.prefix(8)) backend=\(backend.rawValue) chunkChars=\(chunk.count)")
            }
            if backend == .localApple {
                self.markAppleLocalFirstUIChunkIfNeeded(requestID: requestID, at: now)
            }
            self.appendStreamChunk(chunk)
        }
    }

    private struct AppleLocalStreamAttemptResult {
        let text: String
        let firstSnapshotMs: Double?
    }

    private enum AppleLocalDirectTimeoutError: Error {
        case timedOut
    }

    private func runAppleLocalDirectWithRetry(
        primaryPrompt: String,
        primaryMaxOutputTokens: Int,
        retryPrompt: String,
        requestID: UUID,
        counter: AIThroughputCounter
    ) async throws -> String {
        do {
            let attempt = try await runAppleLocalDirectAttempt(
                prompt: primaryPrompt,
                maxOutputTokens: primaryMaxOutputTokens,
                requestID: requestID,
                counter: counter
            )
            return attempt.text
        } catch is AppleLocalFirstSnapshotTimeoutError {
            await MainActor.run {
                self.markAppleLocalRetryAttempted(requestID: requestID)
                guard self.isRequestActive(requestID) else { return }
                self.streamState.resetText()
            }
            do {
                let retryAttempt = try await runAppleLocalDirectAttempt(
                    prompt: retryPrompt,
                    maxOutputTokens: appleLocalRetryMaxOutputTokens,
                    requestID: requestID,
                    counter: counter
                )
                await MainActor.run {
                    self.markAppleLocalRetrySucceeded(
                        requestID: requestID,
                        retryFirstSnapshotMs: retryAttempt.firstSnapshotMs
                    )
                }
                return retryAttempt.text
            } catch is AppleLocalFirstSnapshotTimeoutError {
                throw NSError(
                    domain: "SimpleAIService.AppleLocal",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Apple local runtime stalled on this Mac; try system restart/model redownload/use MLX fallback."
                    ]
                )
            }
        }
    }

    private func runAppleLocalDirectAttempt(
        prompt: String,
        maxOutputTokens: Int,
        requestID: UUID,
        counter: AIThroughputCounter
    ) async throws -> AppleLocalStreamAttemptResult {
        let startedAt = Date()
        let rid = String(requestID.uuidString.prefix(8))
        print("🍎 [Apple Local][\(rid)] directAttempt START (timeout: \(Double(appleLocalFirstSnapshotHardTimeoutNanoseconds) / 1_000_000_000)s, prompt: \(prompt.count) chars, maxTokens: \(maxOutputTokens))")
        await MainActor.run {
            self.markAppleLocalModelStreamStarted(requestID: requestID, at: startedAt)
        }
        print("🍎 [Apple Local][\(rid)] marked stream started, entering timeout wrapper")
        let timeoutSeconds = Double(appleLocalFirstSnapshotHardTimeoutNanoseconds) / 1_000_000_000
        do {
            let text = try await withAppleLocalTimeout(seconds: timeoutSeconds) {
                print("🍎 [Apple Local][\(rid)] inside timeout: creating LanguageModelSession")
                let result = try await Self.generateAppleLocalDirectResponse(
                    prompt: prompt,
                    maxOutputTokens: maxOutputTokens
                )
                print("🍎 [Apple Local][\(rid)] inside timeout: session.respond completed (\(result.count) chars)")
                return result
            }
            let finishedAt = Date()
            await MainActor.run {
                self.markAppleLocalFirstSnapshot(requestID: requestID, at: finishedAt)
                self.markAppleLocalFirstUIChunkIfNeeded(requestID: requestID, at: finishedAt)
            }
            counter.add(units: Self.approximateAppleTokenCount(from: text))
            return AppleLocalStreamAttemptResult(
                text: text,
                firstSnapshotMs: max(0, finishedAt.timeIntervalSince(startedAt) * 1000)
            )
        } catch is AppleLocalDirectTimeoutError {
            print("🍎 [Apple Local][\(rid)] ⏰ TIMEOUT fired after \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s")
            await MainActor.run {
                self.markAppleLocalFirstSnapshotTimeout(requestID: requestID, at: Date())
            }
            #if canImport(FoundationModels)
            await AppleLocalGenerationService.shared.reset()
            #endif
            throw AppleLocalFirstSnapshotTimeoutError()
        }
    }

    private static func generateAppleLocalDirectResponse(
        prompt: String,
        maxOutputTokens: Int
    ) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 18.2, macOS 15.2, *) else {
            throw NSError(
                domain: "SimpleAIService.AppleLocal",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Apple local model requires iOS 18.2+ or macOS 15.2+."]
            )
        }
        // Check cancellation before starting the potentially long session call.
        try Task.checkCancellation()
        print("🍎 [Apple Local][Direct] Calling AppleLocalGenerationService.respond (maxTokens: \(maxOutputTokens))")
        let result = try await AppleLocalGenerationService.shared.respond(
            to: prompt,
            maxOutputTokens: maxOutputTokens
        )
        print("🍎 [Apple Local][Direct] respond returned (\(result.count) chars)")
        // Check cancellation after — the caller may have timed out while we
        // were blocked inside session.respond().
        try Task.checkCancellation()
        return result
        #else
        return ""
        #endif
    }

    private func withAppleLocalTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // Race the operation against a sleep timer.  When the timer wins we
        // cancel the (possibly non-responsive) operation task and throw
        // immediately — we do NOT await operationTask.value so a hung
        // session.respond() cannot block the caller.
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AppleLocalDirectTimeoutError.timedOut
            }
            guard let result = try await group.next() else {
                throw AppleLocalDirectTimeoutError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    private func runAppleLocalRedditStreamWithRetry(
        primaryPrompt: String,
        primaryMaxOutputTokens: Int,
        retryPrompt: String,
        requestID: UUID,
        counter: AIThroughputCounter
    ) async throws -> String {
        do {
            let attempt = try await runAppleLocalRedditStreamAttempt(
                prompt: primaryPrompt,
                maxOutputTokens: primaryMaxOutputTokens,
                requestID: requestID,
                counter: counter
            )
            return attempt.text
        } catch is AppleLocalFirstSnapshotTimeoutError {
            await MainActor.run {
                self.markAppleLocalRetryAttempted(requestID: requestID)
                guard self.isRequestActive(requestID) else { return }
                self.streamState.resetText()
            }
            do {
                let retryAttempt = try await runAppleLocalRedditStreamAttempt(
                    prompt: retryPrompt,
                    maxOutputTokens: appleLocalRetryMaxOutputTokens,
                    requestID: requestID,
                    counter: counter
                )
                await MainActor.run {
                    self.markAppleLocalRetrySucceeded(
                        requestID: requestID,
                        retryFirstSnapshotMs: retryAttempt.firstSnapshotMs
                    )
                }
                return retryAttempt.text
            } catch is AppleLocalFirstSnapshotTimeoutError {
                throw NSError(
                    domain: "SimpleAIService.AppleLocal",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Apple Local did not begin this Reddit pass after two attempts. Please try the summary again."
                    ]
                )
            }
        }
    }

    private func runAppleLocalRedditStreamAttempt(
        prompt: String,
        maxOutputTokens: Int,
        requestID: UUID,
        counter: AIThroughputCounter
    ) async throws -> AppleLocalStreamAttemptResult {
        let firstSnapshotTracker = AppleLocalFirstSnapshotTracker()
        let attemptStartedAt = Date()

        let softWarningSeconds = Double(appleLocalRedditFirstSnapshotSoftWarningNanoseconds) / 1_000_000_000
        let hardTimeoutSeconds = Double(appleLocalRedditFirstSnapshotHardTimeoutNanoseconds) / 1_000_000_000

        do {
            let finalText = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await AppleLocalGenerationService.shared.streamResponse(
                        to: prompt,
                        maxOutputTokens: maxOutputTokens,
                        isolatesSession: true,
                        onChunk: { _ in },
                        shouldContinue: nil,
                        onStreamEvent: { [weak self] event in
                            guard let self else { return }
                            if case .started(let at) = event {
                                await firstSnapshotTracker.markStreamStartedIfNeeded(at)
                            }
                            if case .firstSnapshot(let at) = event {
                                await firstSnapshotTracker.markIfNeeded(at)
                            }
                            self.handleAppleLocalStreamEvent(event, requestID: requestID)
                        }
                    )
                }
                group.addTask {
                    let startedAt = Date()
                    var warned = false
                    while true {
                        try Task.checkCancellation()
                        let elapsed = Date().timeIntervalSince(startedAt)
                        let hasFirstSnapshot = await firstSnapshotTracker.hasFirstSnapshot()
                        guard let streamStartDate = await firstSnapshotTracker.streamStartDate() else {
                            // First-snapshot watchdog starts once streaming has actually started.
                            try await Task.sleep(nanoseconds: 100_000_000)
                            continue
                        }
                        let streamElapsed = Date().timeIntervalSince(streamStartDate)
                        if !warned && streamElapsed >= softWarningSeconds {
                            warned = true
                            if !hasFirstSnapshot {
                                let id = String(requestID.uuidString.prefix(8))
                                print("⚠️ [Apple Local][Diag \(id)] first snapshot pending > \(Int(softWarningSeconds))s")
                            }
                        }
                        if streamElapsed >= hardTimeoutSeconds && !hasFirstSnapshot {
                            throw AppleLocalFirstSnapshotTimeoutError()
                        }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                defer { group.cancelAll() }
                guard let firstCompleted = try await group.next() else {
                    throw AppleLocalFirstSnapshotTimeoutError()
                }
                return firstCompleted
            }
            counter.add(units: Self.approximateAppleTokenCount(from: finalText))
            return AppleLocalStreamAttemptResult(
                text: finalText,
                firstSnapshotMs: await firstSnapshotTracker.elapsedMilliseconds(
                    since: (await firstSnapshotTracker.streamStartDate()) ?? attemptStartedAt
                )
            )
        } catch {
            if error is AppleLocalFirstSnapshotTimeoutError {
                await MainActor.run {
                    self.markAppleLocalFirstSnapshotTimeout(requestID: requestID, at: Date())
                }
            }
            throw error
        }
    }

    private func handleAppleLocalStreamEvent(_ event: AppleLocalStreamEvent, requestID: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch event {
            case .availabilityCheckStarted(let at):
                self.markAppleLocalAvailabilityCheckStarted(requestID: requestID, at: at)
            case .availabilityCheckFinished(let at, let status):
                self.markAppleLocalAvailabilityCheckFinished(requestID: requestID, at: at, status: status)
            case .sessionAcquireStarted(let at):
                self.markAppleLocalSessionAcquireStarted(requestID: requestID, at: at)
            case .standbyReady(let at):
                self.markAppleLocalStandbyReady(requestID: requestID, at: at)
            case .sessionAcquireFinished(let at, let usedStandby, let coldStart, let warmupTimeoutFallback):
                self.markAppleLocalSessionAcquireFinished(
                    requestID: requestID,
                    at: at,
                    usedStandby: usedStandby,
                    coldStart: coldStart,
                    warmupTimeoutFallback: warmupTimeoutFallback
                )
            case .started(let at):
                self.markAppleLocalModelStreamStarted(requestID: requestID, at: at)
            case .firstSnapshot(let at):
                self.markAppleLocalFirstSnapshot(requestID: requestID, at: at)
            }
        }
    }

    /// Foundation-model-specific chunk handler dispatches UI updates to MainActor
    /// without blocking the stream delivery loop.
    private func handleAppleLocalChunk(
        _ chunk: String,
        requestID: UUID,
        streamSessionID: UUID,
        counter: AIThroughputCounter
    ) {
        let units = Self.approximateAppleTokenCount(from: chunk)
        let now = Date()
        let snapshot = counter.record(units: units, now: now)

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isAppleLocalStreamSessionActive(requestID: requestID, streamSessionID: streamSessionID) else { return }
            self.markAppleLocalFirstUIChunkIfNeeded(requestID: requestID, at: now)
            self.appendStreamChunk(chunk)
            if let snapshot {
                self.updateThroughputSession(
                    sessionID: requestID,
                    backend: .localApple,
                    tokens: snapshot.tokens,
                    elapsed: snapshot.elapsed,
                    tokensPerSecond: snapshot.tokensPerSecond
                )
            }
        }
    }

    private func finishThroughputSessionIfNeeded(
        requestID: UUID,
        backend: AIModelBackend,
        counter: AIThroughputCounter,
        fallbackText: String
    ) async {
        if counter.tokens == 0 {
            counter.add(units: Self.estimatedUnits(for: fallbackText, backend: backend))
        }
        let fallbackUnits = Self.estimatedUnits(for: fallbackText, backend: backend)
        if fallbackUnits > counter.tokens {
            counter.add(units: fallbackUnits - counter.tokens)
        }
        let final = counter.finalSnapshot(now: Date())
        if backend == .localApple {
            print(
                "📊 [Apple Local] Estimated throughput: \(String(format: "%.1f", final.tokensPerSecond)) tok/s (\(final.tokens) est. tok; chars/4 approximation)"
            )
        }
        await MainActor.run {
            self.finishThroughputSession(
                sessionID: requestID,
                backend: backend,
                tokens: final.tokens,
                elapsed: final.elapsed,
                tokensPerSecond: final.tokensPerSecond
            )
        }
    }

    private func finishThroughputSession(
        requestID: UUID,
        backend: AIModelBackend,
        tokens: Int,
        elapsed: TimeInterval
    ) async {
        let safeElapsed = max(0, elapsed)
        let tokensPerSecond = safeElapsed > 0 ? Double(tokens) / safeElapsed : 0
        await MainActor.run {
            self.finishThroughputSession(
                sessionID: requestID,
                backend: backend,
                tokens: tokens,
                elapsed: safeElapsed,
                tokensPerSecond: tokensPerSecond
            )
        }
    }

    private static func approximateTokenCount(from text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, trimmed.split(whereSeparator: \.isWhitespace).count)
    }

    private static func approximateAppleTokenCount(from text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        // Apple local doesn't expose token callbacks here. Use a BPE-ish approximation
        // so throughput is on a similar scale to MLX token counts.
        let chars = trimmed.count
        return max(1, Int((Double(chars) / 4.0).rounded()))
    }

    private static func approximateMLXTokenCount(from text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        // Use a BPE-ish approximation when MLX token callbacks are disabled.
        let chars = trimmed.count
        return max(1, Int((Double(chars) / 4.0).rounded()))
    }

    private static func estimatedUnits(for text: String, backend: AIModelBackend) -> Int {
        switch backend {
        case .localApple:
            return approximateAppleTokenCount(from: text)
        case .mlxLocal:
            return approximateMLXTokenCount(from: text)
        default:
            return approximateTokenCount(from: text)
        }
    }

    private let mlxPromptPrefix = """
    Follow the task below exactly.
    - Return only the requested answer.
    - Do not repeat the prompt or these instructions.
    - If a format is requested, follow it strictly.

    === TASK ===
    """

    private let mlxPromptSuffix = """

    === END TASK ===

    Start your answer now.
    """

    private func normalizePrompt(_ prompt: String) -> String {
        prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct InlineContextParseResult {
        let context: String
        let question: String?
    }

    static func hasInlineContextCandidate(_ query: String) -> Bool {
        parseInlineContext(from: query) != nil
    }

    private static func parseInlineContext(from query: String) -> InlineContextParseResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let range = findInlineQuestionDelimiter(in: trimmed) {
            let context = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let question = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !context.isEmpty {
                return InlineContextParseResult(context: context, question: question.isEmpty ? nil : question)
            }
        }

        guard trimmed.count >= inlineContextMinChars else { return nil }
        let newlineCount = trimmed.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        let paragraphCount = trimmed
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        guard newlineCount >= inlineContextMinNewlines || paragraphCount >= inlineContextMinParagraphs else {
            return nil
        }

        return InlineContextParseResult(context: trimmed, question: nil)
    }

    private static func findInlineQuestionDelimiter(in text: String) -> Range<String.Index>? {
        if let range = text.range(of: "\nquestion:", options: [.caseInsensitive, .backwards]) {
            return range
        }
        if let range = text.range(of: "\nq:", options: [.caseInsensitive, .backwards]) {
            return range
        }
        return nil
    }

    private func buildQueryTaskBody(
        question: String,
        pageContext: String?,
        concise: Bool = false,
        conversationContext: String? = nil
    ) -> String {
        var sections: [String] = []
        if concise {
            sections.append("""
            Answer rules:
            - Answer directly in one short sentence.
            - Use facts from page context and conversation turns to resolve references.
            - Use only the provided context; do not use outside knowledge.
            - Do not explain the user's intent.
            - Do not mention conversation, context, notes, or reasoning.
            - If missing facts, reply: I can't find that in the current page context.
            """)
        } else {
            sections.append("""
            Answer rules:
            - Answer directly with concrete facts.
            - Use facts from page context and conversation turns to resolve references.
            - Use only the provided context; do not use outside knowledge.
            - Do not explain the user's intent.
            - Do not mention conversation, context, notes, or reasoning.
            - If missing facts, reply: I can't find that in the current page context.
            """)
        }

        let normalizedContext = normalizePrompt(pageContext ?? "")
        if !normalizedContext.isEmpty {
            sections.append("Context from current webpage:\n\(normalizedContext)")
        }

        let normalizedConversation = normalizePrompt(conversationContext ?? "")
        if !normalizedConversation.isEmpty {
            sections.append("Conversation turns (for reference resolution only):\n\(normalizedConversation)")
        }

        sections.append("User question:\n\(normalizePrompt(question))")
        return sections.joined(separator: "\n\n")
    }

    private func buildInstructionTaskBody(
        instruction: String,
        pageContext: String?,
        conversationContext: String? = nil
    ) -> String {
        var sections: [String] = []
        sections.append("""
        Task rules:
        - Follow the user instruction exactly, including requested length, structure, tone, and format.
        - Use the current page context as the source material.
        - Do not force a one-sentence answer unless the user explicitly asks for one.
        - Do not mention these rules, the context block, or internal reasoning.
        - If the requested information is not present in the context, say that it is not available in the current page context.
        """)

        let normalizedContext = normalizePrompt(pageContext ?? "")
        if !normalizedContext.isEmpty {
            sections.append("Context from current webpage:\n\(normalizedContext)")
        }

        let normalizedConversation = normalizePrompt(conversationContext ?? "")
        if !normalizedConversation.isEmpty {
            sections.append("Conversation turns, only if needed for references:\n\(normalizedConversation)")
        }

        sections.append("User instruction:\n\(normalizePrompt(instruction))")
        return sections.joined(separator: "\n\n")
    }

    private func buildAppleLocalRetryQueryPrompt(question: String, context: String) -> String {
        """
        Answer in one short sentence.
        Use only the context below.
        If missing facts, reply exactly: I can't find that in the current page context.

        \(normalizePrompt(context))

        User question:
        \(normalizePrompt(question))
        """
    }

    private func buildAppleLocalRetrySummaryPrompt(context: String) -> String {
        """
        Summarize in 2 short but complete paragraphs.
        Use only the context below.
        Cover the main topic first, then the most important supporting details and implications.
        Keep it concise, but do not make it overly brief or vague.

        \(normalizePrompt(context))
        """
    }

    private func optimizedPromptForMLX(_ prompt: String) -> String {
        var normalized = normalizePrompt(prompt)
        guard !normalized.isEmpty else { return normalized }

        if normalized.count > mlxPromptCharacterLimit {
            let prefixCount = Int(Double(mlxPromptCharacterLimit) * 0.72)
            let suffixCount = max(0, mlxPromptCharacterLimit - prefixCount - 80)
            let prefix = String(normalized.prefix(prefixCount))
            let suffix = String(normalized.suffix(suffixCount))
            normalized = "\(prefix)\n\n[...truncated for local model context...]\n\n\(suffix)"
        }

        return mlxPromptPrefix + normalized + mlxPromptSuffix
    }

    private struct MLXTimeoutError: Error {}

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MLXTimeoutError()
            }
            guard let result = try await group.next() else {
                throw MLXTimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    private func buildMLXTaskBody(
        question: String,
        context: String?,
        concise: Bool,
        conversationContext: String?,
        settings: MLXLocalSettings
    ) -> String {
        let normalizedQuestion = normalizePrompt(question)
        let questionHeader = "User question:\n"
        let queryRules: String
        if concise {
            queryRules = """
            Answer rules:
            - Answer directly in one short sentence.
            - Use facts from page context and conversation turns to resolve references.
            - Use only the provided context; do not use outside knowledge.
            - Do not explain the user's intent.
            - Do not mention conversation, context, notes, or reasoning.
            - If missing facts, reply: I can't find that in the current page context.
            """
        } else {
            queryRules = """
            Answer rules:
            - Answer directly with concrete facts.
            - Use facts from page context and conversation turns to resolve references.
            - Use only the provided context; do not use outside knowledge.
            - Do not explain the user's intent.
            - Do not mention conversation, context, notes, or reasoning.
            - If missing facts, reply: I can't find that in the current page context.
            """
        }
        let baseQuestion = queryRules + "\n\n" + questionHeader + normalizedQuestion
        let contextHeader = "Context from current webpage:\n"
        let conversationHeader = "Conversation turns (for reference resolution only):\n"
        let separator = "\n\n"
        let truncationNote = "\n\n[Context truncated to fit the local model.]"

        let maxPromptChars: Int = {
            guard settings.maxContextTokens > 0 else { return mlxPromptCharacterLimit }
            let overheadTokens = 100
            let availableTokens = max(0, settings.maxContextTokens - settings.maxOutputTokens - overheadTokens)
            return max(1, availableTokens * 4)
        }()

        let wrapperOverhead = mlxPromptPrefix.count + mlxPromptSuffix.count
        let maxTaskChars = max(0, maxPromptChars - wrapperOverhead)

        if maxTaskChars <= baseQuestion.count {
            return String(baseQuestion.prefix(maxTaskChars))
        }

        let normalizedContext = normalizePrompt(context ?? "")
        let normalizedConversation = normalizePrompt(conversationContext ?? "")
        if normalizedContext.isEmpty && normalizedConversation.isEmpty {
            return baseQuestion
        }

        var remainingBudget = maxTaskChars - baseQuestion.count
        guard remainingBudget > 0 else { return baseQuestion }

        var sections: [String] = []

        if !normalizedConversation.isEmpty {
            let conversationBudget = max(0, min(remainingBudget - separator.count, 2_000))
            if conversationBudget > 0 {
                let conversationBody = normalizedConversation.count <= conversationBudget
                    ? normalizedConversation
                    : String(normalizedConversation.prefix(conversationBudget))
                let conversationSection = conversationHeader + conversationBody
                sections.append(conversationSection)
                remainingBudget -= (conversationSection.count + separator.count)
            }
        }

        if !normalizedContext.isEmpty && remainingBudget > 0 {
            let contextBudget = max(0, remainingBudget - contextHeader.count - separator.count)
            if contextBudget > 0 {
                let contextBody: String
                if normalizedContext.count <= contextBudget {
                    contextBody = normalizedContext
                } else {
                    let truncationBudget = max(0, contextBudget - truncationNote.count)
                    if truncationBudget > 0 {
                        contextBody = String(normalizedContext.prefix(truncationBudget)) + truncationNote
                    } else {
                        contextBody = String(normalizedContext.prefix(contextBudget))
                    }
                }
                sections.append(contextHeader + contextBody)
            }
        }

        if sections.isEmpty { return baseQuestion }
        return sections.joined(separator: separator) + separator + baseQuestion
    }

    @MainActor
    // MARK: - MLX Context-Aware Prompt Building

    /// Short system prompt for MLX Q&A — keeps the system role lightweight
    /// so the Gemma chat template doesn't choke on a huge system message.
    private func buildMLXSystemPrompt(context: String?, conversationContext: String?) -> String {
        "You answer questions about a webpage. Use ONLY the provided text. If the answer is not in the text, say you cannot find it."
    }

    /// Builds a simple user prompt that mirrors the summarize format (which works).
    /// Context is placed directly before the question in the user message.
    private func buildMLXUserPrompt(question: String, concise: Bool, context: String?, conversationContext: String?) -> String {
        let normalizedQuestion = normalizePrompt(question)
        let normalizedContext = normalizePrompt(context ?? "")
        let normalizedConversation = normalizePrompt(conversationContext ?? "")

        var parts: [String] = []

        if !normalizedConversation.isEmpty {
            let trimmedConversation = String(normalizedConversation.prefix(2_000))
            parts.append("Previous conversation:\n\(trimmedConversation)")
        }

        if !normalizedContext.isEmpty {
            let trimmedContext = String(normalizedContext.prefix(mlxQueryContextCharacterLimit))
            parts.append("Text from webpage:\n\(trimmedContext)")
        }

        if concise {
            parts.append("Based on the text above, answer in one sentence.\n\nQuestion: \(normalizedQuestion)")
        } else {
            parts.append("Based on the text above, answer the following question.\n\nQuestion: \(normalizedQuestion)")
        }

        return parts.joined(separator: "\n\n")
    }

    private func recentConversationContext(
        excludingCurrentPrompt prompt: String,
        maxMessages: Int = 2,
        maxCharsPerMessage: Int = 220
    ) -> String? {
        let normalizedPrompt = normalizePrompt(prompt)
        var collected: [ChatMessage] = []

        for message in messages.reversed() {
            guard message.role == .user else { continue }
            if collected.count >= maxMessages {
                break
            }
            if collected.isEmpty,
               message.role == .user,
               normalizePrompt(message.text) == normalizedPrompt {
                continue
            }
            collected.append(message)
        }

        let ordered = collected.reversed()
        guard !ordered.isEmpty else { return nil }

        let lines: [String] = ordered.map { message in
            var text = normalizePrompt(message.text)
            if text.count > maxCharsPerMessage {
                text = String(text.prefix(maxCharsPerMessage)) + "..."
            }
            return "Previous user turn:\n\(text)"
        }

        return lines.joined(separator: "\n\n")
    }

    private func shouldUseConciseAnswer(for prompt: String) -> Bool {
        let normalized = normalizePrompt(prompt).lowercased()
        guard !normalized.isEmpty else { return true }
        let explicitShortPhrases = [
            "tl;dr",
            "tldr",
            "short answer",
            "one sentence",
            "in one sentence",
            "in a sentence",
            "briefly",
            "brief",
            "quick answer"
        ]
        if explicitShortPhrases.contains(where: { normalized.contains($0) }) {
            return true
        }

        let explicitDetailPhrases = [
            "summarize",
            "summarise",
            "summary",
            "overview",
            "recap",
            "key points",
            "takeaways",
            "highlights",
            "details",
            "explain",
            "analysis",
            "analyze",
            "break down",
            "walk me through",
            "in depth",
            "deep dive",
            "detailed",
            "comprehensive",
            "full"
        ]
        if explicitDetailPhrases.contains(where: { normalized.contains($0) }) {
            return false
        }

        if normalized.count <= 60 {
            if normalized.hasPrefix("name ")
                || normalized.hasPrefix("what is ")
                || normalized.hasPrefix("who is ")
                || normalized.hasPrefix("what's ")
                || normalized.hasPrefix("who's ") {
                return true
            }
        }
        return false
    }

    /// Reddit map/reduce chunks have their own larger prompt ceiling. Keep the
    /// ordinary Apple Local optimizer below unchanged so article, selected
    /// text, and non-Reddit requests retain their 12K-character behavior.
    private func optimizedRedditPromptForAppleLocal(_ prompt: String) -> String {
        var normalized = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return normalized }

        let characterLimit = RedditSummaryPlanner.appleLocalRedditPromptCharacterBudget
        if normalized.count > characterLimit {
            let prefixCount = Int(Double(characterLimit) * 0.72)
            let suffixCount = max(0, characterLimit - prefixCount - 80)
            let prefix = String(normalized.prefix(prefixCount))
            let suffix = String(normalized.suffix(suffixCount))
            normalized = "\(prefix)\n\n[...truncated for local Reddit model context...]\n\n\(suffix)"
        }

        return normalized
    }

    private func optimizedPromptForAppleLocal(_ prompt: String) -> String {
        var normalized = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return normalized }

        if normalized.count > appleLocalPromptCharacterLimit {
            let prefixCount = Int(Double(appleLocalPromptCharacterLimit) * 0.72)
            let suffixCount = max(0, appleLocalPromptCharacterLimit - prefixCount - 80)
            let prefix = String(normalized.prefix(prefixCount))
            let suffix = String(normalized.suffix(suffixCount))
            normalized = "\(prefix)\n\n[...truncated for local model context...]\n\n\(suffix)"
        }

        return normalized
    }

    private func cappedMLXOutputTokens(_ configured: Int) -> Int {
        min(max(1, configured), mlxMaxOutputTokenHardCap)
    }

    private func cappedMLXQueryOutputTokens(_ configured: Int, question: String) -> Int {
        let base = cappedMLXOutputTokens(configured)
        if shouldUseConciseAnswer(for: question) {
            return min(base, 96)
        }
        return min(base, 192)
    }

    private func cappedMLXContextTokens(_ configured: Int) -> Int? {
        let resolved = configured > 0 ? configured : mlxAutoContextTokenFallback
        return min(resolved, mlxMaxContextTokenHardCap)
    }

    private func cappedAppleLocalQueryOutputTokens(question: String) -> Int {
        let base = max(1, appleLocalMaxOutputTokens)
        if shouldUseConciseAnswer(for: question) {
            return min(base, appleLocalConciseMaxOutputTokens)
        }
        return base
    }

    private func cappedAppleLocalSummaryOutputTokens(length: SummaryLength) -> Int {
        let base = max(1, appleLocalMaxOutputTokens)
        if length == .short {
            return min(base, appleLocalConciseMaxOutputTokens)
        }
        return base
    }

    @MainActor
    private func beginAppleLocalStreamSession(requestID: UUID) -> UUID {
        guard isRequestActive(requestID) else { return UUID() }
        let streamSessionID = UUID()
        activeAppleLocalStreamSessionID = streamSessionID
        return streamSessionID
    }

    @MainActor
    private func isAppleLocalStreamSessionActive(requestID: UUID, streamSessionID: UUID) -> Bool {
        isRequestActive(requestID) && activeAppleLocalStreamSessionID == streamSessionID
    }

    @MainActor
    private func beginAppleLocalDiagnostics(requestID: UUID, enqueuedAt: Date) {
        appleLocalDiagnosticsByRequestID[requestID] = AppleLocalDiagnostics(
            requestID: requestID,
            enqueuedAt: enqueuedAt
        )
    }

    @MainActor
    private func markAppleLocalAvailabilityCheckStarted(requestID: UUID, at date: Date) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID],
              diagnostics.availabilityCheckStartedAt == nil else { return }
        diagnostics.availabilityCheckStartedAt = date
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func markAppleLocalAvailabilityCheckFinished(requestID: UUID, at date: Date, status: String) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID] else { return }
        diagnostics.availabilityCheckCompletedAt = date
        diagnostics.availabilityStatus = status
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func markAppleLocalSessionAcquireStarted(requestID: UUID, at date: Date) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID],
              diagnostics.sessionAcquireStartedAt == nil else { return }
        diagnostics.sessionAcquireStartedAt = date
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func markAppleLocalStandbyReady(requestID: UUID, at date: Date) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID],
              diagnostics.standbyReadyAt == nil else { return }
        diagnostics.standbyReadyAt = date
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func markAppleLocalSessionAcquireFinished(
        requestID: UUID,
        at date: Date,
        usedStandby: Bool,
        coldStart: Bool,
        warmupTimeoutFallback: Bool
    ) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID] else { return }
        diagnostics.sessionAcquireCompletedAt = date
        diagnostics.usedStandby = usedStandby
        diagnostics.coldStart = coldStart
        diagnostics.warmupTimeoutFallback = warmupTimeoutFallback
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func markAppleLocalModelStreamStarted(requestID: UUID, at date: Date) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID],
              diagnostics.modelStreamStartedAt == nil else { return }
        diagnostics.modelStreamStartedAt = date
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func markAppleLocalFirstSnapshot(requestID: UUID, at date: Date) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID],
              diagnostics.firstModelSnapshotAt == nil else { return }
        diagnostics.firstModelSnapshotAt = date
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func markAppleLocalFirstUIChunkIfNeeded(requestID: UUID, at date: Date) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID],
              diagnostics.firstUIChunkAt == nil else { return }
        diagnostics.firstUIChunkAt = date
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func markAppleLocalFirstSnapshotTimeout(requestID: UUID, at _: Date) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID] else { return }
        diagnostics.firstSnapshotTimeoutTriggered = true
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func markAppleLocalRetryAttempted(requestID: UUID) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID] else { return }
        diagnostics.retryAttempted = true
        diagnostics.retrySucceeded = false
        diagnostics.retryFirstSnapshotMs = nil
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func markAppleLocalRetrySucceeded(requestID: UUID, retryFirstSnapshotMs: Double?) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID] else { return }
        diagnostics.retrySucceeded = true
        diagnostics.retryFirstSnapshotMs = retryFirstSnapshotMs
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func markAppleLocalCompleted(requestID: UUID, at date: Date) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID] else { return }
        if diagnostics.completedAt == nil {
            diagnostics.completedAt = date
        }
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func markAppleLocalQueueUnblocked(requestID: UUID, at date: Date) {
        guard var diagnostics = appleLocalDiagnosticsByRequestID[requestID] else { return }
        diagnostics.queueUnblockedAt = date
        appleLocalDiagnosticsByRequestID[requestID] = diagnostics
    }

    @MainActor
    private func logAndClearAppleLocalDiagnostics(requestID: UUID, nextRequestWillStart: Bool) {
        guard let diagnostics = appleLocalDiagnosticsByRequestID.removeValue(forKey: requestID) else { return }

        func ms(_ from: Date, _ to: Date?) -> String {
            guard let to else { return "n/a" }
            return String(format: "%.0fms", max(0, to.timeIntervalSince(from) * 1000))
        }

        let prefix = String(requestID.uuidString.prefix(8))
        let total = ms(diagnostics.enqueuedAt, diagnostics.completedAt)
        let enqueueToAvailabilityStart = ms(diagnostics.enqueuedAt, diagnostics.availabilityCheckStartedAt)
        let enqueueToAvailabilityDone = ms(diagnostics.enqueuedAt, diagnostics.availabilityCheckCompletedAt)
        let enqueueToAcquireStart = ms(diagnostics.enqueuedAt, diagnostics.sessionAcquireStartedAt)
        let enqueueToAcquireDone = ms(diagnostics.enqueuedAt, diagnostics.sessionAcquireCompletedAt)
        let enqueueToStandbyReady = ms(diagnostics.enqueuedAt, diagnostics.standbyReadyAt)
        let enqueueToStream = ms(diagnostics.enqueuedAt, diagnostics.modelStreamStartedAt)
        let enqueueToFirstSnapshot = ms(diagnostics.enqueuedAt, diagnostics.firstModelSnapshotAt)
        let enqueueToFirstUI = ms(diagnostics.enqueuedAt, diagnostics.firstUIChunkAt)
        let availabilityToAcquire: String = {
            guard let availabilityCompletedAt = diagnostics.availabilityCheckCompletedAt else { return "n/a" }
            return ms(availabilityCompletedAt, diagnostics.sessionAcquireStartedAt)
        }()
        let acquireToStream: String = {
            guard let sessionAcquireCompletedAt = diagnostics.sessionAcquireCompletedAt else { return "n/a" }
            return ms(sessionAcquireCompletedAt, diagnostics.modelStreamStartedAt)
        }()
        let modelToUI: String = {
            guard let firstModelSnapshotAt = diagnostics.firstModelSnapshotAt else { return "n/a" }
            return ms(firstModelSnapshotAt, diagnostics.firstUIChunkAt)
        }()
        let completeToQueueAdvance: String = {
            guard let completedAt = diagnostics.completedAt else { return "n/a" }
            return ms(completedAt, diagnostics.queueUnblockedAt)
        }()
        let retryFirstSnapshot: String = {
            guard let retryFirstSnapshotMs = diagnostics.retryFirstSnapshotMs else { return "n/a" }
            return String(format: "%.0fms", retryFirstSnapshotMs)
        }()

        print("""
        ⏱️ [Apple Local][Diag \(prefix)] total=\(total) availabilityStatus=\(diagnostics.availabilityStatus ?? "n/a") usedStandby=\(diagnostics.usedStandby) coldStart=\(diagnostics.coldStart) warmupTimeoutFallback=\(diagnostics.warmupTimeoutFallback) firstSnapshotTimeoutTriggered=\(diagnostics.firstSnapshotTimeoutTriggered) retryAttempted=\(diagnostics.retryAttempted) retrySucceeded=\(diagnostics.retrySucceeded) retryFirstSnapshot=\(retryFirstSnapshot) enqueue→availabilityStart=\(enqueueToAvailabilityStart) enqueue→availabilityDone=\(enqueueToAvailabilityDone) availability→acquire=\(availabilityToAcquire) enqueue→acquireStart=\(enqueueToAcquireStart) enqueue→acquireDone=\(enqueueToAcquireDone) enqueue→standbyReady=\(enqueueToStandbyReady) acquire→stream=\(acquireToStream) enqueue→stream=\(enqueueToStream) enqueue→firstSnapshot=\(enqueueToFirstSnapshot) enqueue→firstUI=\(enqueueToFirstUI) model→UI=\(modelToUI) complete→queueAdvance=\(completeToQueueAdvance) nextQueuedStarts=\(nextRequestWillStart)
        """)
    }

    @MainActor
    func appendAssistantMessage(_ text: String) {
        streamState.resetText()
        let sanitized = Self.sanitizeAssistantText(text)
        appendRetainedMessage(.init(role: .assistant, text: sanitized), channel: .appBackend)
    }

    @MainActor
    private func completeRequest(with text: String, requestID: UUID) {
        guard isRequestActive(requestID) else { return }
        if appleLocalDiagnosticsByRequestID[requestID] != nil {
            markAppleLocalCompleted(requestID: requestID, at: Date())
        }
        let sanitized = Self.sanitizeAssistantText(text)
        browserAIServiceLog("completeRequest requestID=\(requestID.uuidString.prefix(8)) textChars=\(sanitized.count)")
        streamState.resetText()
        appendRetainedMessage(.init(role: .assistant, text: sanitized), channel: activeMessageChannel)
        finishRequest()
    }

    private static func sanitizeAssistantChunk(_ text: String) -> String {
        let controlMarkers = [
            "<end_of_turn>",
            "</s>",
            "<|end_of_text|>",
            "<|eot_id|>",
            "<|im_end|>",
        ]

        var cleaned = text
        for marker in controlMarkers {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "")
        }
        return cleaned
    }

    private static func sanitizeAssistantText(_ text: String) -> String {
        sanitizeAssistantChunk(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func isRequestActive(_ requestID: UUID) -> Bool {
        isProcessing && activeRequestID == requestID
    }

    @MainActor
    private func beginThroughputSession(sessionID: UUID, backend: AIModelBackend) {
        latestThroughputSessionID = sessionID
        streamState.throughput = AIThroughputState(
            sessionID: sessionID,
            backend: backend,
            tokens: 0,
            elapsed: 0,
            tokensPerSecond: 0,
            isFinal: false
        )
    }

    @MainActor
    private func updateThroughputSession(
        sessionID: UUID,
        backend: AIModelBackend,
        tokens: Int,
        elapsed: TimeInterval,
        tokensPerSecond: Double
    ) {
        guard latestThroughputSessionID == sessionID else { return }
        streamState.throughput = AIThroughputState(
            sessionID: sessionID,
            backend: backend,
            tokens: tokens,
            elapsed: elapsed,
            tokensPerSecond: tokensPerSecond,
            isFinal: false
        )
    }

    @MainActor
    private func finishThroughputSession(
        sessionID: UUID,
        backend: AIModelBackend,
        tokens: Int,
        elapsed: TimeInterval,
        tokensPerSecond: Double
    ) {
        guard latestThroughputSessionID == sessionID else { return }
        streamState.throughput = AIThroughputState(
            sessionID: sessionID,
            backend: backend,
            tokens: tokens,
            elapsed: elapsed,
            tokensPerSecond: tokensPerSecond,
            isFinal: true
        )
    }

    @MainActor
    private func clearThroughputIfSessionMatches(sessionID: UUID) {
        guard latestThroughputSessionID == sessionID else { return }
        streamState.throughput = nil
        latestThroughputSessionID = nil
    }

    @MainActor
    private func appendRetainedMessage(_ message: ChatMessage, channel: MessageChannel) {
        let resolvedMessage = resolvedSidebarVisibility(for: message)
        appendArchiveMessage(resolvedMessage)
        messages.append(resolvedMessage)
        browserAIServiceLog("append message role=\(message.role == .user ? "user" : "assistant") chars=\(message.text.count) channel=\(channel == .webProvider ? "web" : "app") compactStoredBeforeTrim=\(messages.count) archiveStored=\(archiveMessages.count)")
        trimRetainedMessages(for: channel)
    }

    @MainActor
    private func replaceMessagesForWebRequest(_ message: ChatMessage) {
        messages = [message]
        browserAIServiceLog("replaceMessagesForWebRequest userChars=\(message.text.count) archiveStored=\(archiveMessages.count)")
        trimRetainedMessages(for: .webProvider)
    }

    @MainActor
    private func trimRetainedMessages(for channel: MessageChannel) {
        let limit = channel == .webProvider ? maxRetainedMessagesForWebProviders : maxRetainedMessagesForAppBackends
        guard messages.count > limit else { return }
        let before = messages.count
        messages = Array(messages.suffix(limit))
        browserAIServiceLog("trimRetainedMessages channel=\(channel == .webProvider ? "web" : "app") before=\(before) after=\(messages.count)")
    }

    @MainActor
    private func appendArchiveMessage(_ message: ChatMessage) {
        archiveMessages.append(message)
    }

    @MainActor
    func markNextUserPromptHiddenInSidebar() {
        pendingNextUserSidebarVisibility.append(false)
    }

    @MainActor
    private func consumeNextUserPromptSidebarVisibility(defaultValue: Bool) -> Bool {
        guard !pendingNextUserSidebarVisibility.isEmpty else { return defaultValue }
        return pendingNextUserSidebarVisibility.removeFirst()
    }

    @MainActor
    private func resolvedSidebarVisibility(for message: ChatMessage) -> ChatMessage {
        guard message.role == .user else { return message }
        let showsInSidebar = consumeNextUserPromptSidebarVisibility(defaultValue: message.showsInSidebar)
        if showsInSidebar == message.showsInSidebar {
            return message
        }
        return ChatMessage(id: message.id, role: message.role, text: message.text, showsInSidebar: showsInSidebar)
    }

    @MainActor
    func reset() {
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        mlxWarmupTask?.cancel()
        mlxWarmupTask = nil
        appleWarmupTask?.cancel()
        appleWarmupTask = nil
        warmingUpMLXModelID = nil
        warmedUpMLXModelID = nil
        warmedUpAppleLocal = false
        activeRequestID = nil
        activeAppleLocalStreamSessionID = nil
        activeRedditRequestBackend = nil
        activeRequestIsReddit = false
        appleLocalDiagnosticsByRequestID.removeAll()
        latestThroughputSessionID = nil
        streamState.throughput = nil
        isProcessing = false
        streamState.resetText()
        messages.removeAll()
        archiveMessages.removeAll()
        pendingNextUserSidebarVisibility.removeAll()
        requestQueue.removeAll()
        queuedCount = 0
        sourcePageContext = nil
        shouldResetAppleLocalAfterSummaryWhenIdle = false
        pendingAppleLocalPostSummaryFollowUp = false
        if backend == .mlxLocal {
            Task { await cleanupMLXResources() }
        }
        #if canImport(FoundationModels)
        Task { await AppleLocalGenerationService.shared.reset() }
        #endif
    }

    private func cleanupMLXResources() async {
        await MainActor.run {
            mlxWarmupTask?.cancel()
            mlxWarmupTask = nil
            warmingUpMLXModelID = nil
        }
        await MLXLocalService.shared.unloadAllModels()
        await MLXLocalService.shared.clearTransientCache()
    }

    @MainActor
    func prepareForNewContext(_ url: URL?) {
        let next = Self.normalizedContextKey(url)
        if lastContextURL != next {
            browserAIServiceLog("prepareForNewContext reset old=\(lastContextURL ?? "nil") new=\(next)")
            lastContextURL = next
            sourcePageContext = nil
            shouldResetAppleLocalAfterSummaryWhenIdle = false
            pendingAppleLocalPostSummaryFollowUp = false
            activeAppleLocalStreamSessionID = nil
            activeRedditRequestBackend = nil
            activeRequestIsReddit = false
            appleLocalDiagnosticsByRequestID.removeAll()
            streamState.resetText()
            streamState.throughput = nil
            messages.removeAll()
            archiveMessages.removeAll()
            pendingNextUserSidebarVisibility.removeAll()
            requestQueue.removeAll()
            queuedCount = 0
            #if canImport(FoundationModels)
            if backend == .localApple {
                Task {
                    await AppleLocalGenerationService.shared.resetConversation()
                }
            }
            #endif
        } else {
            browserAIServiceLog("prepareForNewContext reuse key=\(next)")
        }
    }

    @MainActor
    private func appendStreamChunk(_ chunk: String) {
        let cleaned = Self.sanitizeAssistantChunk(chunk)
        guard !cleaned.isEmpty else { return }
        streamState.appendText(cleaned)
    }

    private static func normalizedContextKey(_ url: URL?) -> String {
        guard let url else { return "" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        components.query = nil
        return components.url?.absoluteString ?? url.absoluteString
    }
}

// MARK: - Chat message model
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id: UUID
    let role: Role
    let text: String
    let showsInSidebar: Bool

    init(id: UUID = UUID(), role: Role, text: String, showsInSidebar: Bool = true) {
        self.id = id
        self.role = role
        self.text = text
        self.showsInSidebar = showsInSidebar
    }
}
