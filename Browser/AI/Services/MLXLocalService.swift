import Foundation

// MARK: - MLX Local Settings

struct MLXLocalSettings {
    static let modelIDKey = "mlxModelID"
    static let maxOutputTokensKey = "mlxMaxOutputTokens"
    static let maxContextTokensKey = "mlxMaxContextTokens"

    static let defaultModelID = "mlx-community/gemma-3-1b-it-qat-4bit"
    static let defaultMaxOutputTokens = 256
    static let defaultMaxContextTokens = 0
    static let autoContextTokenFallback = 4_096
    static let maxOutputTokenHardCap = 512
    static let maxContextTokenHardCap = 8_192

    let modelID: String
    let maxOutputTokens: Int
    let maxContextTokens: Int

    static func load(from defaults: UserDefaults = .standard) -> MLXLocalSettings {
        let rawModelID = defaults.string(forKey: modelIDKey) ?? ""
        let trimmedModelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = trimmedModelID.isEmpty ? defaultModelID : trimmedModelID

        let maxOutputTokens: Int = {
            guard defaults.object(forKey: maxOutputTokensKey) != nil else {
                return defaultMaxOutputTokens
            }
            let configured = defaults.integer(forKey: maxOutputTokensKey)
            return min(max(1, configured), maxOutputTokenHardCap)
        }()

        let maxContextTokens: Int = {
            guard defaults.object(forKey: maxContextTokensKey) != nil else {
                return defaultMaxContextTokens
            }
            let value = defaults.integer(forKey: maxContextTokensKey)
            guard value > 0 else { return 0 }
            return min(value, maxContextTokenHardCap)
        }()

        return MLXLocalSettings(
            modelID: modelID,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens
        )
    }

    func truncatePromptToFitContext(_ prompt: String) -> String {
        let effectiveMaxContextTokens = maxContextTokens > 0 ? maxContextTokens : Self.autoContextTokenFallback
        // Rough heuristic: ~4 chars per token for English text.
        let overheadTokens = 100
        let availableTokens = max(0, effectiveMaxContextTokens - maxOutputTokens - overheadTokens)
        guard availableTokens > 0 else {
            return String(prompt.prefix(4_000))
        }

        let maxPromptChars = availableTokens * 4
        guard prompt.count > maxPromptChars else { return prompt }

        return String(prompt.prefix(maxPromptChars))
            + "\n\n[Content truncated to fit local model context. Answer using what is provided above.]"
    }
}

struct MLXGenerationMetrics: Sendable {
    let text: String
    let tokenCount: Int
    let elapsed: TimeInterval

    var tokensPerSecond: Double {
        elapsed > 0 ? Double(tokenCount) / elapsed : 0
    }
}

#if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
import MLX
import MLXLLM
import MLXLMCommon
import Hub
#if canImport(MLXVLM)
import MLXVLM
#endif

actor MLXLocalService {
    static let shared = MLXLocalService()

    static func isAvailable() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private var modelCache: [String: ModelContainer] = [:]
    private var inFlightLoads: [String: Task<ModelContainer, Error>] = [:]
    private var hasConfiguredMemory = false
    // Timestamp of the most-recently-completed generation.
    // GPU.clearCache() + model-reload can trigger brief Metal synchronization
    // on the main thread; a short recovery gap before the next generation
    // prevents that from overlapping with a new inference pass (beach ball).
    private var lastGenerationCompletedAt: Date? = nil
    private let generationRecoveryGapSeconds: TimeInterval = 0.8
    private let modelBookmarkKey = "MLXExternalModelBookmark"
    private let modelPathKey = "MLXExternalModelPath"
    private static let eosMarkers = [
        "<end_of_turn>",
        "</s>",
        "<|end_of_text|>",
        "<|endoftext|>",
        "<|eot_id|>",
        "<|end|>",
        "<|im_end|>",
    ]
    private static let turnMarkers = [
        "<start_of_turn>",
        "<|im_start|>",
    ]

    /// HubApi configured to use the appropriate cache location per platform.
    /// - macOS: Uses ~/.cache/huggingface/hub (shared with Python, mlx-lm, etc.)
    /// - iOS: Uses app's Caches directory (sandboxed, no sharing possible)
    #if os(macOS)
    private let sharedHub = HubApi(
        downloadBase: URL.homeDirectory.appending(path: ".cache/huggingface/hub")
    )
    #else
    private let sharedHub = HubApi(
        downloadBase: URL.cachesDirectory.appending(path: "huggingface")
    )
    #endif

    private func configureMemoryIfNeeded() {
        guard !hasConfiguredMemory else { return }
        // Keep MLX cache bounded so WebKit rendering and local inference can coexist.
        GPU.set(cacheLimit: 512 * 1024 * 1024)
        hasConfiguredMemory = true
    }

    func preloadModel(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        _ = try await loadModel(modelID: modelID, progressHandler: progressHandler)
    }

    /// Preload a configured model id, supporting both Hugging Face ids and `external:` paths.
    func preloadConfiguredModel(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        configureMemoryIfNeeded()
        let trimmedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw NSError(
                domain: "MLXLocalService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing Hugging Face model id."]
            )
        }
        if trimmedID.lowercased().hasPrefix("external:") {
            let modelURL = try resolveExternalModelURL(for: trimmedID)
            _ = try await loadModelFromDirectory(modelURL)
        } else {
            _ = try await loadModel(modelID: trimmedID, progressHandler: progressHandler)
        }
    }

    /// Warm up a configured model by loading it and running a tiny generation pass.
    /// This primes model/runtime caches so first user-visible token latency is lower.
    func warmUpConfiguredModel(
        modelID: String,
        maxContextTokens: Int?,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        configureMemoryIfNeeded()
        let trimmedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw NSError(
                domain: "MLXLocalService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing Hugging Face model id."]
            )
        }

        let container: ModelContainer
        if trimmedID.lowercased().hasPrefix("external:") {
            let modelURL = try resolveExternalModelURL(for: trimmedID)
            container = try await loadModelFromDirectory(modelURL)
        } else {
            container = try await loadModel(modelID: trimmedID, progressHandler: progressHandler)
        }

        _ = try await generateWithContainer(
            container,
            prompt: "Reply with exactly: OK",
            maxOutputTokens: 12,
            maxContextTokens: maxContextTokens,
            onToken: nil
        )
    }

    func clearTransientCache() {
        GPU.clearCache()
    }

    /// Drop the cached model container so the next generation starts with a
    /// fresh KV-cache, then clear the GPU compute cache.  This prevents
    /// accumulated KV-cache memory pressure from stalling follow-up
    /// generations after long contexts (e.g. summaries).
    func resetModelState(modelID: String) {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.lowercased().hasPrefix("external:") {
            // External models are keyed by their resolved URL string.
            // Clearing all cached containers is the safest approach.
            modelCache.removeAll()
        } else if !id.isEmpty {
            modelCache[id] = nil
        }
        GPU.clearCache()
    }

    func unloadModel(modelID: String) {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let task = inFlightLoads[id] {
            task.cancel()
            inFlightLoads[id] = nil
        }
        modelCache[id] = nil
        GPU.clearCache()
    }

    func unloadAllModels() {
        for (_, task) in inFlightLoads {
            task.cancel()
        }
        inFlightLoads.removeAll()
        modelCache.removeAll()
        GPU.clearCache()
    }

    func generateText(
        prompt: String,
        systemPrompt: String? = nil,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in },
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        let metrics = try await generateTextWithMetrics(
            prompt: prompt,
            systemPrompt: systemPrompt,
            modelID: modelID,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            progressHandler: progressHandler,
            onToken: onToken
        )
        return metrics.text
    }

    func generateTextWithMetrics(
        prompt: String,
        systemPrompt: String? = nil,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in },
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> MLXGenerationMetrics {
        configureMemoryIfNeeded()
        let trimmedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let container: ModelContainer
        if trimmedID.lowercased().hasPrefix("external:") {
            let modelURL = try resolveExternalModelURL(for: trimmedID)
            container = try await loadModelFromDirectory(modelURL)
        } else {
            container = try await loadModel(modelID: trimmedID, progressHandler: progressHandler)
        }

        return try await generateWithContainer(
            container,
            prompt: prompt,
            systemPrompt: systemPrompt,
            modelIdentifierHint: trimmedID,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: onToken
        )
    }

    /// Generate text using a model loaded from a local directory.
    /// Use this when loading models from user-selected folders (e.g., via Files app on iOS).
    func generateText(
        prompt: String,
        systemPrompt: String? = nil,
        modelDirectory: URL,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        let metrics = try await generateTextWithMetrics(
            prompt: prompt,
            systemPrompt: systemPrompt,
            modelDirectory: modelDirectory,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: onToken
        )
        return metrics.text
    }

    func generateTextWithMetrics(
        prompt: String,
        systemPrompt: String? = nil,
        modelDirectory: URL,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> MLXGenerationMetrics {
        configureMemoryIfNeeded()
        let container = try await loadModelFromDirectory(modelDirectory)
        return try await generateWithContainer(
            container,
            prompt: prompt,
            systemPrompt: systemPrompt,
            modelIdentifierHint: modelDirectory.lastPathComponent,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens,
            onToken: onToken
        )
    }

    private func generateWithContainer(
        _ container: ModelContainer,
        prompt: String,
        systemPrompt: String? = nil,
        modelIdentifierHint: String? = nil,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> MLXGenerationMetrics {
        // Adaptive recovery gap: after GPU.clearCache() + model reload, Metal
        // may need a moment to settle before a new inference pass begins.
        // Overlapping these causes brief main-thread stalls (spinning beach ball).
        if let completed = lastGenerationCompletedAt {
            let elapsed = -completed.timeIntervalSinceNow
            if elapsed < generationRecoveryGapSeconds {
                let remainingNs = UInt64((generationRecoveryGapSeconds - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: remainingNs)
            }
        }
        let startTime = Date()
        let resolvedSystemPrompt = systemPrompt ?? "You are a helpful assistant."
        let disableThinking = shouldDisableThinking(for: modelIdentifierHint)
        let userPrompt = disableThinking ? ensureNoThinkDirective(in: prompt) : prompt
        let chat: [Chat.Message] = [
            .system(resolvedSystemPrompt),
            .user(userPrompt),
        ]
        let userInput: UserInput
        if disableThinking {
            let additionalContext: [String: any Sendable] = ["enable_thinking": false]
            userInput = UserInput(chat: chat, additionalContext: additionalContext)
        } else {
            userInput = UserInput(chat: chat)
        }
        print("⏱️ [MLX] Starting generation (maxTokens: \(maxOutputTokens))")

        let generationResult = try await container.perform { context in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(
                maxTokens: maxOutputTokens,
                maxKVSize: maxContextTokens,
                temperature: 0.2,
                topP: 0.95
            )
            let stream = try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)

            var output = ""
            var tokenCount = 0
            var consecutiveNilChunks = 0
            for await token in stream {
                if Task.isCancelled { throw CancellationError() }
                if let chunk = token.chunk {
                    consecutiveNilChunks = 0
                    output += chunk
                    tokenCount += 1
                    if let onToken {
                        await onToken(chunk)
                    }
                    if Self.eosMarkers.contains(where: { chunk.contains($0) }) {
                        break
                    }
                    if tokenCount % 8 == 0 {
                        if Self.eosMarkers.contains(where: { output.contains($0) }) {
                            break
                        }
                        if tokenCount > 1, Self.turnMarkers.contains(where: { output.contains($0) }) {
                            break
                        }
                    }
                } else {
                    consecutiveNilChunks += 1
                    if consecutiveNilChunks >= 3 && tokenCount > 0 {
                        break
                    }
                }
            }

            return (output: output, tokenCount: tokenCount)
        }

        let output = generationResult.output
        let tokenCount = generationResult.tokenCount
        let elapsed = Date().timeIntervalSince(startTime)
        let tokensPerSecond = elapsed > 0 ? Double(tokenCount) / elapsed : 0
        print("✅ [MLX] Generated \(tokenCount) tokens in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", tokensPerSecond)) tok/s)")

        let cleanedText = sanitizeModelOutput(output)
        lastGenerationCompletedAt = Date()
        return MLXGenerationMetrics(
            text: cleanedText,
            tokenCount: tokenCount,
            elapsed: elapsed
        )
    }

    private func sanitizeModelOutput(_ text: String) -> String {
        var cleaned = text
        for marker in Self.eosMarkers + Self.turnMarkers {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "")
        }
        let roleLeakRangeEnd = cleaned.index(cleaned.startIndex, offsetBy: min(7, cleaned.count))
        cleaned = cleaned.replacingOccurrences(
            of: "model\n",
            with: "",
            options: [],
            range: cleaned.startIndex..<roleLeakRangeEnd
        )

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadModel(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        configureMemoryIfNeeded()

        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw NSError(
                domain: "MLXLocalService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing Hugging Face model id."]
            )
        }

        if let cached = modelCache[id] {
            return cached
        }

        if let task = inFlightLoads[id] {
            return try await task.value
        }

        let task = Task<ModelContainer, Error> {
            try await loadContainerFromModelID(
                id,
                hub: sharedHub,
                progressHandler: progressHandler
            )
        }

        inFlightLoads[id] = task
        do {
            let container = try await task.value
            modelCache[id] = container
            inFlightLoads[id] = nil
            return container
        } catch {
            inFlightLoads[id] = nil
            throw error
        }
    }

    /// Load a model from a local directory (e.g., user-selected via Files app).
    /// Handles security-scoped resource access for iOS sandboxing.
    private func loadModelFromDirectory(_ directory: URL) async throws -> ModelContainer {
        configureMemoryIfNeeded()

        let cacheKey = directory.absoluteString
        if let cached = modelCache[cacheKey] {
            print("🚀 [MLX] Using cached model")
            return cached
        }
        print("⏳ [MLX] Loading model from disk...")

        if let task = inFlightLoads[cacheKey] {
            return try await task.value
        }

        let task = Task<ModelContainer, Error> {
            // Handle security-scoped resources (required for iOS file picker URLs)
            let didStartAccessing = directory.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    directory.stopAccessingSecurityScopedResource()
                }
            }

            // Verify the directory contains required model files
            let configPath = directory.appending(path: "config.json")
            guard FileManager.default.fileExists(atPath: configPath.path) else {
                throw NSError(
                    domain: "MLXLocalService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid model directory: missing config.json"]
                )
            }

            return try await loadContainerFromDirectory(
                directory,
                progressHandler: { _ in }
            )
        }

        inFlightLoads[cacheKey] = task
        do {
            let container = try await task.value
            modelCache[cacheKey] = container
            inFlightLoads[cacheKey] = nil
            return container
        } catch {
            inFlightLoads[cacheKey] = nil
            throw error
        }
    }

    /// Preload a model from a local directory for faster first inference.
    func preloadModelFromDirectory(_ directory: URL) async throws {
        _ = try await loadModelFromDirectory(directory)
    }

    /// Unload a model that was loaded from a local directory.
    func unloadModelFromDirectory(_ directory: URL) {
        let cacheKey = directory.absoluteString
        if let task = inFlightLoads[cacheKey] {
            task.cancel()
            inFlightLoads[cacheKey] = nil
        }
        modelCache[cacheKey] = nil
        GPU.clearCache()
    }

    /// Download a model to a custom location (e.g., iCloud Drive for sharing).
    func downloadModelToLocation(
        modelID: String,
        location: URL,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw NSError(
                domain: "MLXLocalService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing Hugging Face model id."]
            )
        }

        // Create a HubApi with the custom download location
        let customHub = HubApi(downloadBase: location)
        // Download files only (no model instantiation) to avoid OOM during large model transfers.
        _ = try await customHub.snapshot(from: id, matching: "*", progressHandler: progressHandler)
    }

    private func ensureNoThinkDirective(in prompt: String) -> String {
        guard !promptHasNoThinkDirective(prompt) else { return prompt }
        return "/no_think\n\(prompt)"
    }

    private func promptHasNoThinkDirective(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("/no_think")
    }

    private func shouldDisableThinking(for modelIdentifier: String?) -> Bool {
        guard let modelIdentifier else { return false }
        let normalized = modelIdentifier.lowercased()
        return normalized.contains("qwen")
    }

    private func loadContainerFromModelID(
        _ modelID: String,
        hub: HubApi,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        do {
            let configuration = LLMModelFactory.shared.configuration(id: modelID)
            return try await LLMModelFactory.shared.loadContainer(
                hub: hub,
                configuration: configuration,
                progressHandler: progressHandler
            )
        } catch {
            guard shouldFallbackToVLM(error) else { throw error }
            #if canImport(MLXVLM)
            let configuration = VLMModelFactory.shared.configuration(id: modelID)
            return try await VLMModelFactory.shared.loadContainer(
                hub: hub,
                configuration: configuration,
                progressHandler: progressHandler
            )
            #else
            throw error
            #endif
        }
    }

    private func loadContainerFromDirectory(
        _ directory: URL,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        let configuration = ModelConfiguration(directory: directory)
        do {
            return try await LLMModelFactory.shared.loadContainer(
                configuration: configuration,
                progressHandler: progressHandler
            )
        } catch {
            guard shouldFallbackToVLM(error) else { throw error }
            #if canImport(MLXVLM)
            return try await VLMModelFactory.shared.loadContainer(
                configuration: configuration,
                progressHandler: progressHandler
            )
            #else
            throw error
            #endif
        }
    }

    private func shouldFallbackToVLM(_ error: Error) -> Bool {
        if let factoryError = error as? ModelFactoryError {
            if case .unsupportedModelType = factoryError {
                return true
            }
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("unsupported model type")
    }

    private func resolveExternalModelURL(for modelID: String) throws -> URL {
        if let bookmarkData = UserDefaults.standard.data(forKey: modelBookmarkKey) {
            var isStale = false
            #if os(iOS)
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #else
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #endif

            if isStale {
                throw NSError(
                    domain: "MLXLocalService",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Model bookmark is stale. Please re-select the model folder in Manage Models."]
                )
            }
            return url
        }

        let prefix = "external:"
        if modelID.lowercased().hasPrefix(prefix) {
            let rawPath = String(modelID.dropFirst(prefix.count))
            if !rawPath.isEmpty {
                return URL(fileURLWithPath: rawPath)
            }
        }

        if let modelPath = UserDefaults.standard.string(forKey: modelPathKey), !modelPath.isEmpty {
            return URL(fileURLWithPath: modelPath)
        }

        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No model selected. Please select a model in Manage Models."]
        )
    }
}
#else
actor MLXLocalService {
    static let shared = MLXLocalService()

    static func isAvailable() -> Bool { false }

    func preloadModel(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func preloadConfiguredModel(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func warmUpConfiguredModel(
        modelID: String,
        maxContextTokens: Int?,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func clearTransientCache() {
        // no-op
    }

    func resetModelState(modelID: String) {
        // no-op
    }

    func unloadModel(modelID: String) {
        // no-op
    }

    func unloadAllModels() {
        // no-op
    }

    func generateText(
        prompt: String,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in },
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func generateTextWithMetrics(
        prompt: String,
        systemPrompt: String? = nil,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in },
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> MLXGenerationMetrics {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func generateText(
        prompt: String,
        modelDirectory: URL,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func generateTextWithMetrics(
        prompt: String,
        systemPrompt: String? = nil,
        modelDirectory: URL,
        maxOutputTokens: Int,
        maxContextTokens: Int?,
        onToken: (@Sendable (String) async -> Void)? = nil
    ) async throws -> MLXGenerationMetrics {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func preloadModelFromDirectory(_ directory: URL) async throws {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }

    func unloadModelFromDirectory(_ directory: URL) {
        // no-op
    }

    func downloadModelToLocation(
        modelID: String,
        location: URL,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        throw NSError(
            domain: "MLXLocalService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."]
        )
    }
}
#endif
