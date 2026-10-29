//
//  BrowserAgentFoundationEngine.swift
//  Vortex
//
//  Apple Foundation Models bridge for the browser agent. The generic Tool
//  wrapper keeps the existing JSON tool catalog and controller executor as the
//  single action boundary.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
import UIKit

enum BrowserAgentFoundationSchemaError: Error, LocalizedError {
    case invalidToolDefinition(String)
    case unsupportedSchema(String)

    var errorDescription: String? {
        switch self {
        case .invalidToolDefinition(let name): return "The \(name) browser tool has an invalid argument schema."
        case .unsupportedSchema(let type): return "The browser agent cannot represent the \(type) tool argument yet."
        }
    }
}

@available(iOS 26.0, *)
enum BrowserAgentFoundationSchemaAdapter {
    static func schema(for definition: [String: Any]) throws -> GenerationSchema {
        guard let name = definition["name"] as? String,
              let parameters = definition["parameters"] as? [String: Any],
              let properties = parameters["properties"] as? [String: Any] else {
            throw BrowserAgentFoundationSchemaError.invalidToolDefinition(definition["name"] as? String ?? "unnamed")
        }
        let required = Set(parameters["required"] as? [String] ?? [])
        let root = try objectSchema(name: "\(name)Arguments", properties: properties, required: required)
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func objectSchema(
        name: String,
        properties: [String: Any],
        required: Set<String>
    ) throws -> DynamicGenerationSchema {
        let dynamicProperties = try properties.keys.sorted().map { key -> DynamicGenerationSchema.Property in
            guard let raw = properties[key] as? [String: Any] else {
                throw BrowserAgentFoundationSchemaError.unsupportedSchema("property \(key)")
            }
            let (schema, needsOptionalFallback) = try valueSchema(raw, name: key)
            return DynamicGenerationSchema.Property(
                name: key,
                description: raw["description"] as? String,
                schema: schema,
                isOptional: !required.contains(key) || needsOptionalFallback
            )
        }
        if #available(iOS 26.4, *) {
            return DynamicGenerationSchema(
                name: name,
                representNilExplicitlyInGeneratedContent: true,
                properties: dynamicProperties
            )
        }
        return DynamicGenerationSchema(name: name, properties: dynamicProperties)
    }

    private static func valueSchema(_ raw: [String: Any], name: String) throws -> (DynamicGenerationSchema, Bool) {
        let types = raw["type"] as? [String] ?? [raw["type"] as? String ?? ""]
        let acceptsNull = types.contains("null")
        guard let type = types.first(where: { $0 != "null" }), !type.isEmpty else {
            if #available(iOS 26.4, *) { return (.null, false) }
            throw BrowserAgentFoundationSchemaError.unsupportedSchema("null")
        }

        let schema: DynamicGenerationSchema
        let legacyOptionalFallback: Bool
        if type == "string", let choices = raw["enum"] as? [String], !choices.isEmpty {
            schema = DynamicGenerationSchema(name: name, anyOf: choices)
            legacyOptionalFallback = false
        } else {
            switch type {
            case "string":
                schema = DynamicGenerationSchema(type: String.self)
                legacyOptionalFallback = false
            case "integer":
                schema = DynamicGenerationSchema(type: Int.self)
                legacyOptionalFallback = false
            case "number":
                schema = DynamicGenerationSchema(type: Double.self)
                legacyOptionalFallback = false
            case "boolean":
                schema = DynamicGenerationSchema(type: Bool.self)
                legacyOptionalFallback = false
            case "array":
                guard let item = raw["items"] as? [String: Any] else {
                    throw BrowserAgentFoundationSchemaError.invalidToolDefinition(name)
                }
                let (itemSchema, _) = try valueSchema(item, name: "\(name)Item")
                schema = DynamicGenerationSchema(arrayOf: itemSchema)
                legacyOptionalFallback = false
            case "object":
                let properties = raw["properties"] as? [String: Any] ?? [:]
                let required = Set(raw["required"] as? [String] ?? [])
                schema = try objectSchema(name: "\(name)Object", properties: properties, required: required)
                legacyOptionalFallback = false
            default:
                throw BrowserAgentFoundationSchemaError.unsupportedSchema(type)
            }
        }

        guard acceptsNull else { return (schema, legacyOptionalFallback) }
        if #available(iOS 26.4, *) {
            return (DynamicGenerationSchema(name: "\(name)Nullable", anyOf: [schema, .null]), false)
        }
        return (schema, true)
    }
}

enum BrowserAgentFoundationReadiness {
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static func localSessionUsesLegacyAPI(isSimulator: Bool) -> Bool {
        isSimulator
    }

    static func privateCloudSimulatorUnavailableMessage(isSimulator: Bool) -> String? {
        isSimulator ? "Private Cloud Compute agent mode requires a supported iOS 27 device." : nil
    }

    static func localContextUnavailableMessage(contextSize: Int) -> String? {
        contextSize > 0 ? nil : "Apple Local isn't ready for agent mode yet. Try again when its on-device model context is available."
    }

    static func appleImageAttachmentsSupported(reportedVisionCapability: Bool) -> Bool {
        !isSimulator && reportedVisionCapability
    }

    static func toolCallingFailure(engine: String, supportsToolCalling: Bool) -> BrowserAgentEngineFailure? {
        supportsToolCalling ? nil : .capability("\(engine) is available, but agent tool calling is not supported right now.")
    }

    static func privateCloudQuotaFailure(isLimitReached: Bool, resetDate: Date?) -> BrowserAgentEngineFailure? {
        isLimitReached ? .quotaReached(resetDate) : nil
    }

    static func shouldOfferAgent(isAvailable: Bool, supportsToolCalling: Bool?) -> Bool {
        isAvailable && (supportsToolCalling ?? true)
    }

    static func privateCloudQuotaNote(isApproachingLimit: Bool) -> String? {
        isApproachingLimit ? "Private Cloud Compute is nearing its current usage limit." : nil
    }

    static func rateLimitFailure(engine: String, resetDate: Date?) -> BrowserAgentEngineFailure {
        .rateLimited(engine: engine, resetDate: resetDate)
    }

    static func localContextFailure(
        promptTokens: Int,
        instructionTokens: Int,
        toolTokens: Int,
        contextSize: Int
    ) -> BrowserAgentEngineFailure? {
        BrowserAgentLocalContext.hasRoomForInitialContext(
            promptTokens: promptTokens,
            instructionTokens: instructionTokens,
            toolTokens: toolTokens,
            contextSize: contextSize
        ) ? nil : .contextTooLarge
    }

    @available(iOS 27.0, *)
    static func privateCloudIsApproachingLimit(_ status: PrivateCloudComputeLanguageModel.QuotaUsage.Status) -> Bool {
        if case .belowLimit(let detail) = status { return detail.isApproachingLimit }
        return false
    }
}

@available(iOS 26.0, *)
struct FoundationAgentTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = Prompt

    let name: String
    let description: String
    let parameters: GenerationSchema
    let coordinator: BrowserAgentFoundationToolCoordinator
    let supportsVision: Bool

    init(definition: [String: Any], coordinator: BrowserAgentFoundationToolCoordinator, supportsVision: Bool) throws {
        guard let name = definition["name"] as? String,
              let description = definition["description"] as? String else {
            throw BrowserAgentFoundationSchemaError.invalidToolDefinition("unnamed")
        }
        self.name = name
        self.description = description
        parameters = try BrowserAgentFoundationSchemaAdapter.schema(for: definition)
        self.coordinator = coordinator
        self.supportsVision = supportsVision
    }

    @concurrent
    func call(arguments: GeneratedContent) async throws -> Prompt {
        let result = try await coordinator.invoke(name: name, argumentsJSON: arguments.jsonString)
        return await BrowserAgentFoundationPromptBuilder.toolOutput(
            text: result.text,
            imageData: result.imageData,
            supportsVision: supportsVision
        ).prompt
    }
}

@available(iOS 26.0, *)
@MainActor
struct BrowserAgentFoundationPromptBuilder {
    struct ToolOutput {
        let prompt: Prompt
        let includesImageAttachment: Bool
    }

    static func toolOutput(text: String, imageData: Data?, supportsVision: Bool = false) -> ToolOutput {
        if #available(iOS 27.0, *),
           BrowserAgentFoundationReadiness.appleImageAttachmentsSupported(reportedVisionCapability: supportsVision),
           let data = imageData,
           let image = UIImage(data: data)?.cgImage {
            return ToolOutput(
                prompt: Prompt {
                    text
                    Attachment<ImageAttachmentContent>(image)
                },
                includesImageAttachment: true
            )
        }
        return ToolOutput(prompt: Prompt(text), includesImageAttachment: false)
    }
}

@available(iOS 26.0, *)
actor BrowserAgentFoundationToolCoordinator {
    private let maximumCalls: Int
    private let maximumAnswerCharacters: Int
    private let rejectOversizedFinish: Bool
    private let executor: BrowserAgentToolExecutor
    private var active = false
    private var activeInvocationID: UUID?
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var callCount = 0
    private var isClosed = false
    private var limitReached = false
    private var finishAnswer: String?

    init(
        maximumCalls: Int,
        maximumAnswerCharacters: Int = 2_000,
        rejectOversizedFinish: Bool = false,
        executor: @escaping BrowserAgentToolExecutor
    ) {
        self.maximumCalls = max(1, maximumCalls)
        self.maximumAnswerCharacters = max(1, maximumAnswerCharacters)
        self.rejectOversizedFinish = rejectOversizedFinish
        self.executor = executor
    }

    func invoke(name: String, argumentsJSON: String) async throws -> BrowserAgentToolOutput {
        let invocationID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let acquired = await acquire(invocationID)
            guard acquired else {
                if limitReached { throw BrowserAgentEngineFailure.stepLimit(maximumCalls) }
                try Task.checkCancellation()
                return BrowserAgentToolOutput(text: "This agent run has finished. No page action was taken.")
            }
            defer { release(invocationID) }
            try Task.checkCancellation()
            guard !isClosed else {
                if limitReached { throw BrowserAgentEngineFailure.stepLimit(maximumCalls) }
                return BrowserAgentToolOutput(text: "This agent run has finished. No page action was taken.")
            }
            guard callCount < maximumCalls else {
                limitReached = true
                close()
                throw BrowserAgentEngineFailure.stepLimit(maximumCalls)
            }
            callCount += 1
            if name == "finish" {
                let answer = Self.answer(from: argumentsJSON)
                if rejectOversizedFinish, answer.count > maximumAnswerCharacters {
                    return BrowserAgentToolOutput(text: BrowserAgentEngineFailure.answerTooLongFeedback(maximumAnswerCharacters))
                }
                finishAnswer = String(answer.prefix(maximumAnswerCharacters))
                close()
                return BrowserAgentToolOutput(text: "The task is finished.")
            }
            let output = await executor(name, argumentsJSON)
            try Task.checkCancellation()
            return output
        } onCancel: {
            Task { await self.cancelInvocation(invocationID) }
        }
    }

    func close() {
        isClosed = true
        let pending = Array(waiters.values)
        waiters.removeAll()
        waiterOrder.removeAll()
        for continuation in pending { continuation.resume(returning: false) }
    }

    func answer() -> String? { finishAnswer }

    func reachedCallLimit() -> Bool { limitReached }

    func queuedInvocationCount() -> Int { waiters.count }

    private func acquire(_ invocationID: UUID) async -> Bool {
        if isClosed { return false }
        if !active {
            active = true
            activeInvocationID = invocationID
            return true
        }
        return await withCheckedContinuation { continuation in
            if isClosed {
                continuation.resume(returning: false)
            } else {
                waiterOrder.append(invocationID)
                waiters[invocationID] = continuation
            }
        }
    }

    private func release(_ invocationID: UUID) {
        guard activeInvocationID == invocationID else { return }
        if isClosed {
            active = false
            activeInvocationID = nil
        } else {
            while !waiterOrder.isEmpty {
                let nextID = waiterOrder.removeFirst()
                guard let next = waiters.removeValue(forKey: nextID) else { continue }
                activeInvocationID = nextID
                next.resume(returning: true)
                return
            }
            active = false
            activeInvocationID = nil
        }
    }

    private func cancelInvocation(_ invocationID: UUID) {
        if let continuation = waiters.removeValue(forKey: invocationID) {
            waiterOrder.removeAll { $0 == invocationID }
            continuation.resume(returning: false)
        }
        if activeInvocationID == invocationID {
            close()
        }
    }

    private static func answer(from json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["answer"] as? String else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@available(iOS 26.0, *)
@MainActor
final class FoundationModelsAgentEngine: BrowserAgentEngine {
    enum Backend {
        case local
        case privateCloud
    }

    let backend: Backend
    private(set) var profile = BrowserAgentEngineProfile.local(contextSize: 4_096, supportsVision: false)
    private var localModel: SystemLanguageModel?
    private var cloudModelStorage: Any?
    @available(iOS 27.0, *)
    private var cloudModel: PrivateCloudComputeLanguageModel? {
        get { cloudModelStorage as? PrivateCloudComputeLanguageModel }
        set { cloudModelStorage = newValue }
    }

    init(backend: Backend) {
        self.backend = backend
    }

    func prepare() async throws {
        switch backend {
        case .local:
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                throw BrowserAgentEngineFailure.unavailable(Self.statusMessage(for: model.availability))
            }
            let contextSize = model.contextSize
            if let message = BrowserAgentFoundationReadiness.localContextUnavailableMessage(contextSize: contextSize) {
                throw BrowserAgentEngineFailure.unavailable(message)
            }
            var vision = false
            if #available(iOS 27.0, *) {
                if let failure = BrowserAgentFoundationReadiness.toolCallingFailure(
                    engine: "Apple Local",
                    supportsToolCalling: model.capabilities.contains(.toolCalling)
                ) {
                    throw failure
                }
                vision = BrowserAgentFoundationReadiness.appleImageAttachmentsSupported(
                    reportedVisionCapability: model.capabilities.contains(.vision)
                )
            }
            localModel = model
            profile = .local(contextSize: contextSize, supportsVision: vision)

        case .privateCloud:
            if let message = BrowserAgentFoundationReadiness.privateCloudSimulatorUnavailableMessage(
                isSimulator: BrowserAgentFoundationReadiness.isSimulator
            ) {
                throw BrowserAgentEngineFailure.unavailable(message)
            }
            guard #available(iOS 27.0, *) else {
                throw BrowserAgentEngineFailure.unavailable("Private Cloud Compute agent mode needs iOS 27 or later.")
            }
            let model = PrivateCloudComputeLanguageModel()
            guard model.isAvailable else {
                throw BrowserAgentEngineFailure.unavailable(Self.statusMessage(for: model.availability))
            }
            let quota = model.quotaUsage
            if let failure = BrowserAgentFoundationReadiness.privateCloudQuotaFailure(
                isLimitReached: quota.isLimitReached,
                resetDate: quota.resetDate
            ) {
                throw failure
            }
            if let failure = BrowserAgentFoundationReadiness.toolCallingFailure(
                engine: "Private Cloud Compute",
                supportsToolCalling: model.capabilities.contains(.toolCalling)
            ) {
                throw failure
            }
            let contextSize = try await model.contextSize
            cloudModel = model
            profile = .privateCloud(
                contextSize: contextSize,
                supportsVision: BrowserAgentFoundationReadiness.appleImageAttachmentsSupported(
                    reportedVisionCapability: model.capabilities.contains(.vision)
                )
            )
        }
    }

    func run(
        request: BrowserAgentEngineRequest,
        execute: @escaping BrowserAgentToolExecutor,
        onNote: @escaping BrowserAgentNoteHandler
    ) async throws -> String {
        if case .privateCloud = backend,
           let message = BrowserAgentFoundationReadiness.privateCloudSimulatorUnavailableMessage(
               isSimulator: BrowserAgentFoundationReadiness.isSimulator
           ) {
            throw BrowserAgentEngineFailure.unavailable(message)
        }
        let coordinator = BrowserAgentFoundationToolCoordinator(
            maximumCalls: request.profile.maxSteps,
            maximumAnswerCharacters: request.maximumAnswerCharacters ?? 2_000,
            rejectOversizedFinish: request.maximumAnswerCharacters != nil,
            executor: execute
        )
        let tools = try request.tools.map {
            try FoundationAgentTool(
                definition: $0,
                coordinator: coordinator,
                supportsVision: request.profile.supportsVision
            )
        }
        do {
            let responseText: String
            if #available(iOS 27.0, *), case .privateCloud = backend, let cloudModel {
                let quota = cloudModel.quotaUsage
                if let failure = BrowserAgentFoundationReadiness.privateCloudQuotaFailure(
                    isLimitReached: quota.isLimitReached,
                    resetDate: quota.resetDate
                ) {
                    throw failure
                }
                if Self.isApproachingLimit(quota.status),
                   let note = BrowserAgentFoundationReadiness.privateCloudQuotaNote(isApproachingLimit: true) {
                    onNote(note)
                }
            }
            switch backend {
            case .local:
                guard let localModel else {
                    throw BrowserAgentEngineFailure.unavailable("Apple Local is not ready for agent requests.")
                }
                if #available(iOS 26.4, *) {
                    try await Self.validateLocalContext(
                        model: localModel,
                        request: request,
                        tools: tools
                    )
                }
                if BrowserAgentFoundationReadiness.localSessionUsesLegacyAPI(
                    isSimulator: BrowserAgentFoundationReadiness.isSimulator
                ) {
                    let session = LanguageModelSession(model: localModel, tools: tools, instructions: request.instructions)
                    responseText = try await session.respond(to: request.initialPrompt).content
                } else if #available(iOS 27.0, *) {
                    let session = Self.session27(
                        model: localModel,
                        instructions: request.instructions,
                        tools: tools,
                        snapshotLimit: 1,
                        outputLimit: 1
                    )
                    responseText = try await session.respond(to: Prompt(request.initialPrompt)).content
                } else {
                    let session = LanguageModelSession(model: localModel, tools: tools, instructions: request.instructions)
                    responseText = try await session.respond(to: request.initialPrompt).content
                }
            case .privateCloud:
                guard #available(iOS 27.0, *), let cloudModel else {
                    throw BrowserAgentEngineFailure.unavailable("Private Cloud Compute agent mode needs iOS 27 or later.")
                }
                let session = Self.session27(
                    model: cloudModel,
                    instructions: request.instructions,
                    tools: tools,
                    snapshotLimit: 2,
                    outputLimit: nil
                )
                responseText = try await session.respond(to: Prompt(request.initialPrompt)).content
            }
            await coordinator.close()
            if await coordinator.reachedCallLimit() {
                throw BrowserAgentEngineFailure.stepLimit(request.profile.maxSteps)
            }
            if #available(iOS 27.0, *), case .privateCloud = backend, let cloudModel {
                let quota = cloudModel.quotaUsage
                if quota.isLimitReached {
                    onNote(BrowserAgentEngineFailure.quotaReached(quota.resetDate).localizedDescription)
                } else if Self.isApproachingLimit(quota.status),
                          let note = BrowserAgentFoundationReadiness.privateCloudQuotaNote(isApproachingLimit: true) {
                    onNote(note)
                }
            }
            let answer = await coordinator.answer()
            if let answer, !answer.isEmpty { return answer }
            if let limit = request.maximumAnswerCharacters, responseText.count > limit {
                throw BrowserAgentEngineFailure.answerTooLong(limit)
            }
            return Self.bound(responseText.trimmingCharacters(in: .whitespacesAndNewlines), to: request.maximumAnswerCharacters)
        } catch {
            await coordinator.close()
            if await coordinator.reachedCallLimit() {
                throw BrowserAgentEngineFailure.stepLimit(request.profile.maxSteps)
            }
            if #available(iOS 27.0, *), let modelError = error as? LanguageModelError {
                switch modelError {
                case .contextSizeExceeded:
                    throw BrowserAgentEngineFailure.contextTooLarge
                case .rateLimited(let detail):
                    let engine: String
                    switch backend {
                    case .local: engine = "Apple Local"
                    case .privateCloud: engine = "Private Cloud Compute"
                    }
                    throw BrowserAgentFoundationReadiness.rateLimitFailure(engine: engine, resetDate: detail.resetDate)
                default:
                    break
                }
            }
            if #available(iOS 27.0, *), let cloudError = error as? PrivateCloudComputeLanguageModel.Error {
                if case .quotaLimitReached(let detail) = cloudError {
                    throw BrowserAgentEngineFailure.quotaReached(detail.resetDate)
                }
            }
            throw error
        }
    }

    private static func bound(_ answer: String, to maximumCharacters: Int?) -> String {
        guard let maximumCharacters, answer.count > maximumCharacters else { return answer }
        return String(answer.prefix(maximumCharacters))
    }

    @available(iOS 27.0, *)
    private static func session27(
        model: any LanguageModel,
        instructions: String,
        tools: [any Tool],
        snapshotLimit: Int,
        outputLimit: Int?
    ) -> LanguageModelSession {
        let profile = LanguageModelSession.Profile {
            Instructions(instructions)
            tools
        }
        .model(model)
        .historyTransform { entries in
            BrowserAgentFoundationHistoryRetention.retainRecentSnapshotsAndLatestImage(
                entries,
                snapshotLimit: snapshotLimit,
                outputLimit: outputLimit
            )
        }
        return LanguageModelSession(profile: profile)
    }

    @available(iOS 26.4, *)
    private static func validateLocalContext(
        model: SystemLanguageModel,
        request: BrowserAgentEngineRequest,
        tools: [FoundationAgentTool]
    ) async throws {
        let promptTokens = try await model.tokenCount(for: Prompt(request.initialPrompt))
        let instructionTokens = try await model.tokenCount(for: Instructions(request.instructions))
        let toolTokens: [any Tool] = tools.map { $0 as any Tool }
        let toolTokenCount = try await model.tokenCount(for: toolTokens)
        if let failure = BrowserAgentFoundationReadiness.localContextFailure(
            promptTokens: promptTokens,
            instructionTokens: instructionTokens,
            toolTokens: toolTokenCount,
            contextSize: model.contextSize
        ) {
            throw failure
        }
    }

    @available(iOS 27.0, *)
    private static func isApproachingLimit(_ status: PrivateCloudComputeLanguageModel.QuotaUsage.Status) -> Bool {
        BrowserAgentFoundationReadiness.privateCloudIsApproachingLimit(status)
    }

    @available(iOS 26.0, *)
    static func statusMessage(for availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available: return "Apple Local is ready."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence to use Apple Local agent mode."
        case .unavailable(.modelNotReady): return "Apple Local is still preparing its on-device model. Try again when it is ready."
        case .unavailable(.deviceNotEligible): return "This device does not support Apple Local agent mode."
        @unknown default: return "Apple Local is unavailable on this device."
        }
    }

    @available(iOS 27.0, *)
    static func statusMessage(for availability: PrivateCloudComputeLanguageModel.Availability) -> String {
        switch availability {
        case .available: return "Private Cloud Compute is ready."
        case .unavailable(.deviceNotEligible): return "This device does not support Private Cloud Compute agent mode."
        case .unavailable(.systemNotReady): return "Private Cloud Compute is not ready right now. Try again later."
        @unknown default: return "Private Cloud Compute is unavailable right now."
        }
    }
}

@available(iOS 27.0, *)
enum BrowserAgentFoundationHistoryRetention {
    static func retainRecentSnapshotsAndLatestImage(
        _ entries: [Transcript.Entry],
        snapshotMarker: String = "<page_snapshot>",
        snapshotLimit: Int = 2,
        outputLimit: Int? = nil
    ) -> [Transcript.Entry] {
        var remainingSnapshots = max(0, snapshotLimit)
        var remainingOutputs = outputLimit.map { max(0, $0) }
        var retainedImage = false
        return entries.reversed().map { entry in
            guard case .toolOutput(let output) = entry else { return entry }
            let retainOutputText = remainingOutputs.map { $0 > 0 } ?? true
            if retainOutputText, let remaining = remainingOutputs { remainingOutputs = remaining - 1 }
            let segments = output.segments.reversed().map { segment -> Transcript.Segment in
                switch segment {
                case .text(let text):
                    guard retainOutputText else {
                        if remainingSnapshots > 0,
                           let markerRange = text.content.range(of: snapshotMarker) {
                            remainingSnapshots -= 1
                            return .text(Transcript.TextSegment(
                                id: text.id,
                                content: "[Earlier tool result removed to fit the Local context.]\n"
                                    + String(text.content[markerRange.lowerBound...])
                            ))
                        }
                        return .text(Transcript.TextSegment(id: text.id, content: "[Earlier tool result removed to fit the Local context.]"))
                    }
                    guard let markerRange = text.content.range(of: snapshotMarker) else { return segment }
                    if remainingSnapshots > 0 {
                        remainingSnapshots -= 1
                        return segment
                    }
                    let compact = String(text.content[..<markerRange.lowerBound]) + "\n[older page snapshot removed]"
                    return .text(Transcript.TextSegment(id: text.id, content: compact))
                case .attachment(let attachment):
                    guard case .image = attachment.content else { return segment }
                    if retainedImage { return .text(Transcript.TextSegment(id: attachment.id, content: "[Earlier screenshot removed.]")) }
                    retainedImage = true
                    return segment
                case .structure:
                    return segment
                @unknown default:
                    return segment
                }
            }.reversed()
            return .toolOutput(Transcript.ToolOutput(id: output.id, toolName: output.toolName, segments: Array(segments)))
        }.reversed()
    }
}

@MainActor
enum BrowserAgentEngineFactory {
    static func make(for backend: AIModelBackend) -> (any BrowserAgentEngine)? {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard let kind = BrowserAgentEngineSelection.kind(
            for: backend,
            iOSMajorVersion: major,
            chatGPTPlanEnabled: ChatGPTPlanAvailability.isEnabled
        ) else { return nil }
        switch kind {
        case .chatGPTPlan:
            return ChatGPTPlanAgentEngine()
        case .appleLocal:
            if #available(iOS 26.0, *) { return FoundationModelsAgentEngine(backend: .local) }
            return nil
        case .privateCloud:
            if #available(iOS 27.0, *) { return FoundationModelsAgentEngine(backend: .privateCloud) }
            return nil
        }
    }

    static func isAvailable(for backend: AIModelBackend) -> Bool {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard BrowserAgentEngineSelection.kind(
            for: backend,
            iOSMajorVersion: major,
            chatGPTPlanEnabled: ChatGPTPlanAvailability.isEnabled
        ) != nil else { return false }
        switch backend {
        case .chatGPTPlan:
            return true
        case .localApple:
            if #available(iOS 26.0, *) {
                let model = SystemLanguageModel.default
                guard model.isAvailable,
                      BrowserAgentFoundationReadiness.localContextUnavailableMessage(contextSize: model.contextSize) == nil else {
                    return false
                }
                if #available(iOS 27.0, *) {
                    return BrowserAgentFoundationReadiness.shouldOfferAgent(
                        isAvailable: true,
                        supportsToolCalling: model.capabilities.contains(.toolCalling)
                    )
                }
                return true
            }
            return false
        case .cloudShortcuts:
            guard BrowserAgentFoundationReadiness.privateCloudSimulatorUnavailableMessage(
                isSimulator: BrowserAgentFoundationReadiness.isSimulator
            ) == nil else { return false }
            if #available(iOS 27.0, *) {
                let model = PrivateCloudComputeLanguageModel()
                return BrowserAgentFoundationReadiness.shouldOfferAgent(
                    isAvailable: model.isAvailable && !model.quotaUsage.isLimitReached,
                    supportsToolCalling: model.capabilities.contains(.toolCalling)
                )
            }
            return false
        case .mlxLocal, .webChatGPT, .webGemini:
            return false
        }
    }

    static func status(for backend: AIModelBackend) -> String {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard let kind = BrowserAgentEngineSelection.kind(
            for: backend,
            iOSMajorVersion: major,
            chatGPTPlanEnabled: ChatGPTPlanAvailability.isEnabled
        ) else {
            return BrowserAgentEngineSelection.unsupportedMessage(
                for: backend,
                iOSMajorVersion: major,
                chatGPTPlanEnabled: ChatGPTPlanAvailability.isEnabled
            )
        }
        switch kind {
        case .chatGPTPlan: return "Acts on pages · ChatGPT Plan"
        case .appleLocal:
            if #available(iOS 26.0, *) {
                let model = SystemLanguageModel.default
                guard model.isAvailable else { return FoundationModelsAgentEngine.statusMessage(for: model.availability) }
                if let message = BrowserAgentFoundationReadiness.localContextUnavailableMessage(contextSize: model.contextSize) {
                    return message
                }
                if #available(iOS 27.0, *), !model.capabilities.contains(.toolCalling) {
                    return BrowserAgentFoundationReadiness.toolCallingFailure(engine: "Apple Local", supportsToolCalling: false)?.localizedDescription
                        ?? "Apple Local agent tool calling is unavailable."
                }
                return "Acts on pages · On-device Apple Intelligence"
            }
            return "Apple Local agent mode needs iOS 26 or later."
        case .privateCloud:
            if let message = BrowserAgentFoundationReadiness.privateCloudSimulatorUnavailableMessage(
                isSimulator: BrowserAgentFoundationReadiness.isSimulator
            ) {
                return message
            }
            if #available(iOS 27.0, *) {
                let model = PrivateCloudComputeLanguageModel()
                if !model.isAvailable { return FoundationModelsAgentEngine.statusMessage(for: model.availability) }
                if model.quotaUsage.isLimitReached { return BrowserAgentEngineFailure.quotaReached(model.quotaUsage.resetDate).localizedDescription }
                if !model.capabilities.contains(.toolCalling) {
                    return BrowserAgentFoundationReadiness.toolCallingFailure(engine: "Private Cloud Compute", supportsToolCalling: false)?.localizedDescription
                        ?? "Private Cloud Compute agent tool calling is unavailable."
                }
                if BrowserAgentFoundationReadiness.privateCloudIsApproachingLimit(model.quotaUsage.status) {
                    return "Acts on pages · Private Cloud Compute · quota nearing limit"
                }
                return "Acts on pages · Private Cloud Compute"
            }
            return "Private Cloud Compute agent mode needs iOS 27 or later."
        }
    }
}

#else
enum BrowserAgentFoundationSchemaError: Error {}
#endif
