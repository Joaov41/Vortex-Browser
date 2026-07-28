# MLX & Local Model Implementation Reference

This document describes the complete MLX and Apple local model implementation used in the Browser project. Use it as a reference when porting these features to another codebase (e.g., a summarization app).

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Key Files](#key-files)
3. [MLXLocalService — Full API](#mlxlocalservice--full-api)
4. [MLXLocalSettings — Configuration](#mlxlocalsettings--configuration)
5. [Apple Local Model (FoundationModels)](#apple-local-model-foundationmodels)
6. [External Model Store](#external-model-store)
7. [Backend Enum & Throughput Tracking](#backend-enum--throughput-tracking)
8. [GPU Memory Management](#gpu-memory-management)
9. [Timeout Wrapper](#timeout-wrapper)
10. [Prompt Building for Summarization](#prompt-building-for-summarization)
11. [Summarization Flow — Step by Step](#summarization-flow--step-by-step)
12. [Q&A / Chat Flow — Step by Step](#qa--chat-flow--step-by-step)
13. [Critical Fixes to Apply in Your Codebase](#critical-fixes-to-apply-in-your-codebase)
14. [Constants Reference](#constants-reference)
15. [Platform Guard Pattern](#platform-guard-pattern)

---

## Architecture Overview

```
User Request
    │
    ▼
AIModelBackend (enum)
    ├── .mlxLocal     → MLXLocalService (actor)
    │       └── ModelContainer (cached, keyed by model ID or URL)
    │               └── MLXLMCommon.generate() → token stream
    │
    ├── .localApple   → AppleLocalGenerationService (actor)
    │       └── LanguageModelSession (persistent, FoundationModels framework)
    │               └── session.streamResponse() → snapshot stream
    │
    └── .cloudShortcuts → CloudModelService
            └── Shortcuts URL scheme → clipboard polling
```

**Key design decisions:**
- `MLXLocalService` is a Swift `actor` — all state mutations are serialised automatically.
- Model containers are cached in a dictionary so reloading from disk only happens once per model ID.
- A **recovery gap** (0.8 s for MLX, 1.5 s for Apple Local) is enforced after GPU/session cleanup to prevent Metal main-thread stalls (spinning beach ball).
- The Apple Local `LanguageModelSession` is kept alive in `persistentSession` between requests to avoid the ~1.5 s deallocation cost on the main thread.

---

## Key Files

| File | Role |
|------|------|
| `Browser/AI/Services/MLXLocalService.swift` | Core MLX actor — model loading, caching, generation |
| `Browser/AI/Services/MLXExternalModelStore.swift` | UserDefaults persistence for user-selected local model folders |
| `Browser/AI/Services/CloudModelService.swift` | Shortcuts-based cloud backend |
| `Browser/AI/Services/AIAssistantProvider.swift` | Protocol + Apple Local / Cloud placeholder providers |
| `Browser/AI/Models/SummaryProvider.swift` | `SummaryProvider` enum (Gemini / Apple Local / Apple Cloud) |
| `Browser/AI/SimpleAIService.swift` | Orchestrator: routes requests to backends, manages streaming, throughput |
| `Browser/AI/ManageMLXModelsView.swift` | SwiftUI model management UI |

---

## MLXLocalService — Full API

```swift
#if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)

actor MLXLocalService {
    static let shared = MLXLocalService()

    // MARK: - Availability

    static func isAvailable() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Model Loading

    /// Preload a Hugging Face model ID.
    func preloadModel(modelID: String, progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws

    /// Preload either a HF model ID or an "external:" path.
    func preloadConfiguredModel(modelID: String, progressHandler: ...) async throws

    /// Load + run a tiny generation pass to prime caches.
    func warmUpConfiguredModel(modelID: String, maxContextTokens: Int?, progressHandler: ...) async throws

    // MARK: - Generation

    /// Generate text (returns full string only).
    func generateText(prompt: String, systemPrompt: String? = nil, modelID: String,
                      maxOutputTokens: Int, maxContextTokens: Int?,
                      progressHandler: ..., onToken: (@Sendable (String) async -> Void)?) async throws -> String

    /// Generate text + return token count and elapsed time.
    func generateTextWithMetrics(prompt: String, systemPrompt: String? = nil, modelID: String,
                                 maxOutputTokens: Int, maxContextTokens: Int?,
                                 progressHandler: ...,
                                 onToken: (@Sendable (String) async -> Void)?) async throws -> MLXGenerationMetrics

    /// Same as above but load model from a local directory URL.
    func generateText(prompt: String, systemPrompt: String? = nil, modelDirectory: URL,
                      maxOutputTokens: Int, maxContextTokens: Int?,
                      onToken: ...) async throws -> String

    func generateTextWithMetrics(prompt: String, systemPrompt: String? = nil, modelDirectory: URL,
                                 maxOutputTokens: Int, maxContextTokens: Int?,
                                 onToken: ...) async throws -> MLXGenerationMetrics

    // MARK: - Cache / Memory

    func clearTransientCache()          // GPU.clearCache() — call after generation
    func resetModelState(modelID: String) // Evict from modelCache + GPU.clearCache()
    func unloadModel(modelID: String)
    func unloadAllModels()

    // MARK: - Directory Models

    func preloadModelFromDirectory(_ directory: URL) async throws
    func unloadModelFromDirectory(_ directory: URL)

    // MARK: - Download

    func downloadModelToLocation(modelID: String, location: URL, progressHandler: ...) async throws
}
#endif
```

### MLXGenerationMetrics

```swift
struct MLXGenerationMetrics: Sendable {
    let text: String
    let tokenCount: Int
    let elapsed: TimeInterval
    var tokensPerSecond: Double { elapsed > 0 ? Double(tokenCount) / elapsed : 0 }
}
```

---

## MLXLocalSettings — Configuration

```swift
struct MLXLocalSettings {
    // UserDefaults keys
    static let modelIDKey           = "mlxModelID"
    static let maxOutputTokensKey   = "mlxMaxOutputTokens"
    static let maxContextTokensKey  = "mlxMaxContextTokens"

    // Defaults / caps
    static let defaultModelID            = "mlx-community/gemma-3-1b-it-qat-4bit"
    static let defaultMaxOutputTokens    = 256
    static let defaultMaxContextTokens   = 0       // 0 = auto
    static let autoContextTokenFallback  = 4_096
    static let maxOutputTokenHardCap     = 512
    static let maxContextTokenHardCap    = 8_192

    let modelID: String
    let maxOutputTokens: Int
    let maxContextTokens: Int   // 0 means "auto"

    static func load(from defaults: UserDefaults = .standard) -> MLXLocalSettings
}
```

### Prompt truncation helper

```swift
// Approximate token estimation: ~4 chars per token.
// Always call this before passing a prompt to generateText.
func truncatePromptToFitContext(_ prompt: String) -> String {
    let effectiveMax = maxContextTokens > 0 ? maxContextTokens : Self.autoContextTokenFallback
    let overheadTokens = 100
    let available = max(0, effectiveMax - maxOutputTokens - overheadTokens)
    let maxChars = available * 4
    guard prompt.count > maxChars else { return prompt }
    return String(prompt.prefix(maxChars))
        + "\n\n[Content truncated to fit local model context. Answer using what is provided above.]"
}
```

### Token output capping helpers (from SimpleAIService)

```swift
// Hard cap for summarization output
private func cappedMLXOutputTokens(_ configured: Int) -> Int {
    min(max(1, configured), mlxMaxOutputTokenHardCap)  // hard cap = 512
}

// For Q&A: concise answers capped at 96 tokens, detailed at 192
private func cappedMLXQueryOutputTokens(_ configured: Int, question: String) -> Int {
    let base = cappedMLXOutputTokens(configured)
    if shouldUseConciseAnswer(for: question) { return min(base, 96) }
    return min(base, 192)
}

// Context tokens: 0 → fallback (4096), else min(configured, 8192)
private func cappedMLXContextTokens(_ configured: Int) -> Int? {
    let resolved = configured > 0 ? configured : mlxAutoContextTokenFallback
    return min(resolved, mlxMaxContextTokenHardCap)
}
```

---

## Apple Local Model (FoundationModels)

### Key patterns

```swift
#if canImport(FoundationModels)
import FoundationModels
#endif

private actor AppleLocalGenerationService {
    static let shared = AppleLocalGenerationService()

    // CRITICAL: Persist session between requests.
    // Deallocating a LanguageModelSession triggers ~1.5s main-thread cleanup.
    // Keep one strong reference alive to prevent beach balls between requests.
    private var persistentSession: LanguageModelSession? = nil
    private var lastSessionReleasedAt: Date? = nil
    private let sessionRecoveryGapSeconds: TimeInterval = 1.5

    // Session instructions — keep brief
    private let sessionInstructions = """
    Return only the requested answer.
    Do not repeat the prompt or these instructions.
    If a format is requested, follow it strictly.
    """

    @available(iOS 18.2, macOS 15.2, *)
    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: sessionInstructions)
    }
}
```

### Session acquisition (persistent session pattern)

```swift
func respond(to prompt: String, maxOutputTokens: Int? = nil) async throws -> String {
    guard #available(iOS 18.2, macOS 15.2, *) else { throw /* version error */ }

    // Reuse persistent session — avoids deallocation cost
    if persistentSession == nil {
        // Wait for recovery gap if a session was just released
        if let released = lastSessionReleasedAt {
            let elapsed = -released.timeIntervalSinceNow
            if elapsed < sessionRecoveryGapSeconds {
                let remaining = UInt64((sessionRecoveryGapSeconds - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: remaining)
            }
        }
        persistentSession = makeSession()
    }

    let session = persistentSession!
    isGenerating = true
    defer {
        isGenerating = false
        // Do NOT nil out persistentSession here — that triggers deallocation
        signalIdle()
    }

    if #available(iOS 26.0, macOS 26.0, *) {
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: effectiveMax)
        return try await session.respond(to: prompt, options: options).content
    } else {
        return try await session.respond(to: prompt).content
    }
}
```

### Streaming with snapshot delta computation

Apple Local's `streamResponse` yields cumulative snapshots, not deltas. Compute delta manually:

```swift
var fullText = ""
let stream = session.streamResponse(to: prompt, options: options)
for try await snapshot in stream {
    let content = snapshot.content
    let delta: String
    if content.hasPrefix(fullText) {
        delta = String(content.dropFirst(fullText.count))
    } else {
        delta = content   // fallback: emit full content if prefix check fails
    }
    if !delta.isEmpty {
        await onChunk(delta)
    }
    fullText = content
}
```

### Standby session warm-up

Pre-warm a session in the background between requests to reduce first-token latency:

```swift
// Start warming immediately after a request completes
func startStandbyWarmup() {
    guard standbyState == .idle else { return }
    standbyState = .warming
    standbyWarmTask = Task(priority: .utility) {
        let session = makeSession()
        _ = try? await session.respond(to: "Reply with exactly: OK").content
        standbySession = session
        standbyState = .ready
    }
}

// Acquire for real request: prefer standby, fall back to cold start
func acquireSessionForRequest() async -> LanguageModelSession {
    if standbyState == .ready, let s = standbySession {
        standbySession = nil
        standbyState = .idle
        return s
    }
    // Cancel in-progress warmup so it doesn't compete with real request
    standbyWarmTask?.cancel()
    standbyState = .idle
    return makeSession()
}
```

**Warning:** Do NOT start standby warmup immediately after a request completes. A queued follow-up request may start immediately and the warmup's `session.respond()` would race with it for the on-device model, causing the real request to freeze.

---

## External Model Store

Manages user-selected local model folders via `UserDefaults` and security-scoped bookmarks.

```swift
struct MLXExternalModelStore {
    static let selectedBookmarkKey = "MLXExternalModelBookmark"
    static let selectedPathKey     = "MLXExternalModelPath"
    static let bookmarksKey        = "MLXExternalModelBookmarks"
    static let pathsKey            = "MLXExternalModelPaths"

    struct Entry: Identifiable, Hashable {
        let id: String
        let path: String
        let name: String
    }

    // Only entries with a valid config.json are returned
    static func loadEntries(defaults: UserDefaults = .standard) -> [Entry]

    // Register a new folder (path + optional security-scoped bookmark data)
    static func addEntry(path: String, bookmark: Data?, defaults: UserDefaults = .standard)

    static func removeEntry(path: String, defaults: UserDefaults = .standard)
    static func selectedPath(defaults: UserDefaults = .standard) -> String?
    static func setSelected(path: String?, bookmark: Data?, defaults: UserDefaults = .standard)
    static func clearSelection(defaults: UserDefaults = .standard)
}
```

### Creating a bookmark (iOS file picker)

```swift
// In your file importer callback:
let bookmarkData = try url.bookmarkData(
    options: [],               // iOS
    // options: .withSecurityScope, // macOS
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)
MLXExternalModelStore.addEntry(path: url.path, bookmark: bookmarkData)
```

### Resolving a bookmark

```swift
var isStale = false
let url = try URL(
    resolvingBookmarkData: bookmarkData,
    options: [],               // iOS
    // options: .withSecurityScope, // macOS
    relativeTo: nil,
    bookmarkDataIsStale: &isStale
)
if isStale { /* prompt user to re-select the folder */ }
```

### Model ID convention for external models

External models use the prefix `"external:"` in the model ID string:

```
"external:/path/to/model-folder"
```

`MLXLocalService` detects this prefix and routes to `loadModelFromDirectory()` instead of the Hugging Face hub.

---

## Backend Enum & Throughput Tracking

```swift
enum AIModelBackend: String, CaseIterable {
    case localApple      // Apple Intelligence (FoundationModels)
    case cloudShortcuts  // Shortcuts-based cloud
    case mlxLocal        // MLX on-device
    case webChatGPT
    case webGemini
}

struct AIThroughputState {
    let sessionID: UUID
    let backend: AIModelBackend
    let tokens: Int
    let elapsed: TimeInterval
    let tokensPerSecond: Double
    let isFinal: Bool
}
```

---

## GPU Memory Management

### Configure once at startup

```swift
// Call this before the first generation — configures the Metal GPU cache limit.
// 512 MB lets WebKit rendering and MLX inference coexist without OOM pressure.
GPU.set(cacheLimit: 512 * 1024 * 1024)
```

### After each generation

```swift
// Clear ONLY transient GPU compute cache (intermediate activations).
// Do NOT call resetModelState — that evicts the model weights from modelCache,
// forcing a full disk reload next time (which stalls Metal on the main thread).
await MLXLocalService.shared.clearTransientCache()
```

### After long-context inference (e.g., summaries)

Accumulated KV-cache can cause memory pressure. After summarization:
- Call `clearTransientCache()` — safe; keeps model weights in cache.
- Do NOT call `resetModelState()` unless you are explicitly freeing the model.

### Recovery gap

After `GPU.clearCache()` + model reload, Metal may need time to settle. The service enforces a 0.8 s gap between consecutive generations:

```swift
private var lastGenerationCompletedAt: Date?
private let generationRecoveryGapSeconds: TimeInterval = 0.8

// At the start of generateWithContainer():
if let completed = lastGenerationCompletedAt {
    let elapsed = -completed.timeIntervalSinceNow
    if elapsed < generationRecoveryGapSeconds {
        let remaining = UInt64((generationRecoveryGapSeconds - elapsed) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: remaining)
    }
}
```

---

## Timeout Wrapper

Wrap all MLX generation calls with a timeout to prevent the UI from hanging if inference stalls:

```swift
private struct MLXTimeoutError: Error {}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let operationTask = Task.detached(priority: .userInitiated) {
        try await operation()
    }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            do {
                return try await operationTask.value
            } catch is CancellationError {
                throw MLXTimeoutError()
            } catch {
                throw error
            }
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            operationTask.cancel()
            throw MLXTimeoutError()
        }
        guard let result = try await group.next() else {
            operationTask.cancel()
            throw MLXTimeoutError()
        }
        group.cancelAll()
        operationTask.cancel()
        return result
    }
}
```

**Usage:**

```swift
let metrics = try await withTimeout(seconds: mlxGenerationTimeoutSeconds) {
    try await MLXLocalService.shared.generateTextWithMetrics(
        prompt: preparedPrompt,
        modelID: settings.modelID,
        maxOutputTokens: maxOutputTokens,
        maxContextTokens: maxContextTokens,
        onToken: { chunk in /* stream chunk */ }
    )
}
// On catch: if error is MLXTimeoutError → show "MLX timed out. Please try again."
```

---

## Prompt Building for Summarization

### Content condensing

Limit input size before building the prompt to stay within model context:

```swift
private let mlxInputCharacterLimit = 12_000  // tune to your model's context window

static func condense(_ text: String, maxChars: Int) -> String {
    guard text.count > maxChars else { return text }
    return String(text.prefix(maxChars))
}
```

### Summarization prompts

```swift
// Short summary (2-paragraph)
let prompt = """
Provide a brief 2-paragraph summary of the following text. \
First paragraph: main topic. Second paragraph: key points. Be concise:

\(condensedContent)
"""

// Long/detailed summary
let prompt = """
Summarize the following text clearly, highlighting key themes and points. \
Provide a detailed analysis:

\(condensedContent)
"""
```

### Prompt optimization for MLX (normalisation + wrapping)

```swift
private let mlxPromptPrefix = ""   // add model-specific prefix if needed
private let mlxPromptSuffix = ""   // add model-specific suffix if needed
private let mlxPromptCharacterLimit = 10_000

private func optimizedPromptForMLX(_ prompt: String) -> String {
    // 1. Normalize whitespace
    var normalized = prompt
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // 2. Truncate with smart prefix+suffix preservation
    if normalized.count > mlxPromptCharacterLimit {
        let prefixCount = Int(Double(mlxPromptCharacterLimit) * 0.72)
        let suffixCount = max(0, mlxPromptCharacterLimit - prefixCount - 80)
        let prefix = String(normalized.prefix(prefixCount))
        let suffix = String(normalized.suffix(suffixCount))
        normalized = "\(prefix)\n\n[...truncated for local model context...]\n\n\(suffix)"
    }

    return mlxPromptPrefix + normalized + mlxPromptSuffix
}
```

### Complete summarization call

```swift
let settings = MLXLocalSettings.load()
let condensed = condense(pageContent, maxChars: mlxInputCharacterLimit)
let rawPrompt = buildSummaryPrompt(condensed, length: summaryLength)
let preparedPrompt = settings.truncatePromptToFitContext(optimizedPromptForMLX(rawPrompt))
let maxOutputTokens = cappedMLXOutputTokens(settings.maxOutputTokens)
let maxContextTokens = cappedMLXContextTokens(settings.maxContextTokens)

let metrics = try await withTimeout(seconds: 90) {
    try await MLXLocalService.shared.generateTextWithMetrics(
        prompt: preparedPrompt,
        modelID: settings.modelID,
        maxOutputTokens: maxOutputTokens,
        maxContextTokens: maxContextTokens,
        onToken: { chunk in
            // deliver streaming chunk to UI
        }
    )
}

// After generation: free transient GPU cache
await MLXLocalService.shared.clearTransientCache()

// Use the result
let summaryText = metrics.text
```

---

## Q&A / Chat Flow — Step by Step

### System prompt (keep lightweight for Gemma models)

```swift
private func buildMLXSystemPrompt(context: String?, conversationContext: String?) -> String {
    "You answer questions about a webpage. Use ONLY the provided text. If the answer is not in the text, say you cannot find it."
}
```

### User prompt with context

```swift
private func buildMLXUserPrompt(question: String, concise: Bool, context: String?, conversationContext: String?) -> String {
    var parts: [String] = []

    // Include recent conversation (max 2000 chars)
    if let conv = conversationContext, !conv.isEmpty {
        parts.append("Previous conversation:\n\(String(conv.prefix(2_000)))")
    }

    // Include page context (max mlxQueryContextCharacterLimit chars)
    if let ctx = context, !ctx.isEmpty {
        parts.append("Text from webpage:\n\(String(ctx.prefix(mlxQueryContextCharacterLimit)))")
    }

    // Question
    if concise {
        parts.append("Based on the text above, answer in one sentence.\n\nQuestion: \(question)")
    } else {
        parts.append("Based on the text above, answer the following question.\n\nQuestion: \(question)")
    }

    return parts.joined(separator: "\n\n")
}
```

### Q&A call with system prompt

```swift
let settings = MLXLocalSettings.load()
let systemPrompt = buildMLXSystemPrompt(context: condensed, conversationContext: conversationContext)
let userPrompt = buildMLXUserPrompt(question: query, concise: concise, context: condensed, conversationContext: conversationContext)
let maxOutputTokens = cappedMLXQueryOutputTokens(settings.maxOutputTokens, question: query)
let maxContextTokens = cappedMLXContextTokens(settings.maxContextTokens)

let metrics = try await withTimeout(seconds: 60) {
    try await MLXLocalService.shared.generateTextWithMetrics(
        prompt: userPrompt,
        systemPrompt: systemPrompt,
        modelID: settings.modelID,
        maxOutputTokens: maxOutputTokens,
        maxContextTokens: maxContextTokens,
        onToken: { chunk in /* stream */ }
    )
}
await MLXLocalService.shared.clearTransientCache()
```

---

## Critical Fixes to Apply in Your Codebase

These are the bugs and performance issues discovered in the Browser project that must be applied to any other codebase using these models:

### Fix 1: Always use `clearTransientCache()` after generation — never `resetModelState()`

```swift
// ❌ WRONG — evicts model weights, forces disk reload (Metal beach ball)
await MLXLocalService.shared.resetModelState(modelID: settings.modelID)

// ✅ CORRECT — clears only transient GPU activations
await MLXLocalService.shared.clearTransientCache()
```

`resetModelState()` should only be called when you explicitly want to free the model from memory (e.g., app backgrounding, user manually clearing the model).

### Fix 2: Enforce the generation recovery gap

If you skip the 0.8 s recovery gap between back-to-back MLX generations, you risk a Metal synchronization stall on the main thread. Ensure `MLXLocalService` always checks `lastGenerationCompletedAt` at the start of `generateWithContainer()`.

### Fix 3: Keep Apple Local `LanguageModelSession` alive between requests

```swift
// ❌ WRONG — creates and destroys session on every request
func respond(to prompt: String) async throws -> String {
    let session = LanguageModelSession(instructions: instructions)
    defer { /* session gets deallocated → 1.5s main thread stall */ }
    return try await session.respond(to: prompt).content
}

// ✅ CORRECT — hold persistentSession alive; only nil it on explicit reset
private var persistentSession: LanguageModelSession? = nil
```

### Fix 4: Wrap all MLX calls in the timeout wrapper

Without a timeout, a stalled generation will block the UI forever. Always use `withTimeout(seconds:)`.

### Fix 5: Normalize the Apple Local prompt

Wrap user prompts with `"User question:\n"` prefix to prevent hidden multi-turn history accumulation from slowing first-token latency:

```swift
private func normalizedPrompt(_ prompt: String) -> String {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("User question:") { return trimmed }
    return "User question:\n\(trimmed)"
}
```

### Fix 6: Do NOT start standby warm-up immediately after request completion

```swift
// ❌ WRONG — standby respond() races with next real request
defer {
    isGenerating = false
    startStandbyWarmup() // ← dangerous here
}

// ✅ CORRECT — only start warmup when no queued request is pending
// Start warmup only from an idle state, not from within defer blocks
```

### Fix 7: Use `@Sendable` on all token callbacks

```swift
// ❌ WRONG — compiler warning / potential data race
onToken: { chunk in self.handleChunk(chunk) }

// ✅ CORRECT
onToken: { @Sendable [weak self] chunk in
    guard let self else { return }
    Task { await self.handleChunk(chunk) }
}
```

### Fix 8: Use output sanitization

MLX models often emit stop tokens in the text. Strip them:

```swift
private func sanitizeModelOutput(_ text: String) -> String {
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
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

This is already called inside `MLXLocalService.generateWithContainer()`, so it applies automatically to all output from `generateText` / `generateTextWithMetrics`.

---

## Constants Reference

```swift
// MLX limits (from SimpleAIService)
let mlxInputCharacterLimit      = 12_000   // max chars fed to MLX before generating prompt
let mlxPromptCharacterLimit     = 10_000   // max chars in the final built prompt
let mlxQueryContextCharacterLimit = 8_000  // max chars of page context in Q&A prompts
let mlxMaxOutputTokenHardCap    = 512      // from MLXLocalSettings
let mlxMaxContextTokenHardCap   = 8_192   // from MLXLocalSettings
let mlxAutoContextTokenFallback = 4_096   // when maxContextTokens = 0
let mlxGenerationTimeoutSeconds: TimeInterval = 90  // summary timeout
let mlxQueryTimeoutSeconds: TimeInterval      = 60  // Q&A timeout

// Apple Local limits
let appleLocalPromptCharacterLimit = 8_000
let appleLocalMaxOutputTokens      = 320    // defaultMaximumResponseTokens

// Recovery gaps
let mlxGenerationRecoveryGap: TimeInterval    = 0.8   // seconds
let appleLocalSessionRecoveryGap: TimeInterval = 1.5   // seconds
```

---

## Platform Guard Pattern

MLX is only available on arm64 (Apple Silicon / A-series) and requires the MLX Swift packages. Use compile-time guards everywhere:

```swift
#if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
// Full implementation
actor MLXLocalService {
    static func isAvailable() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
    // ... full implementation
}
#else
// Stub — same public interface, all methods throw "MLX unavailable"
actor MLXLocalService {
    static let shared = MLXLocalService()
    static func isAvailable() -> Bool { false }
    func generateText(/* ... */) async throws -> String {
        throw NSError(domain: "MLXLocalService", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."])
    }
    // ... matching stubs for every public method
}
#endif
```

Always check `MLXLocalService.isAvailable()` at runtime before routing to the MLX backend:

```swift
guard MLXLocalService.isAvailable() else {
    completeRequest(with: "MLX Local is not available on this device/build.")
    return
}
```

For Apple Local (FoundationModels):

```swift
#if canImport(FoundationModels)
import FoundationModels
#endif

// At call site:
guard #available(iOS 18.2, macOS 15.2, *) else {
    throw NSError(domain: "SimpleAIService.AppleLocal", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Apple local model requires iOS 18.2+ or macOS 15.2+."])
}
```

---

## HubApi Configuration

```swift
// macOS: share the ~/.cache/huggingface/hub directory with Python / mlx-lm tools
#if os(macOS)
private let sharedHub = HubApi(
    downloadBase: URL.homeDirectory.appending(path: ".cache/huggingface/hub")
)
#else
// iOS: sandboxed — use app's Caches directory
private let sharedHub = HubApi(
    downloadBase: URL.cachesDirectory.appending(path: "huggingface")
)
#endif
```

Pass `sharedHub` to `LLMModelFactory.shared.loadContainer(hub:configuration:progressHandler:)` for all HF model IDs.

---

## Recommended Default Model

```
mlx-community/gemma-3-1b-it-qat-4bit
```

- 1B parameters, 4-bit quantized — fits in ~1 GB RAM
- Fast on A-series (iPhone 15+, all M-series Macs)
- Handles summarization and short Q&A well
- `temperature: 0.2`, `topP: 0.95` are good defaults for deterministic factual tasks

For longer/more detailed summaries, consider:
```
mlx-community/Qwen2.5-3B-Instruct-4bit
mlx-community/Llama-3.2-3B-Instruct-4bit
```
