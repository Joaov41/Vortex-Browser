import FoundationModels
import UIKit
import XCTest
import WebKit
@testable import Browser

@MainActor
final class BrowserAgentFoundationEngineTests: XCTestCase {
    private final class ToolGateProbe {
        var activeCalls = 0
        var maximumConcurrentCalls = 0
        var executedCalls = 0
        var releaseActive: (() -> Void)?
    }

    func testEngineSelectionAndLocalBudgetUseSelectedBackendAndContextSize() {
        XCTAssertEqual(BrowserAgentEngineSelection.kind(for: .localApple, iOSMajorVersion: 26, chatGPTPlanEnabled: true), .appleLocal)
        XCTAssertNil(BrowserAgentEngineSelection.kind(for: .cloudShortcuts, iOSMajorVersion: 26, chatGPTPlanEnabled: true))
        XCTAssertEqual(BrowserAgentEngineSelection.kind(for: .cloudShortcuts, iOSMajorVersion: 27, chatGPTPlanEnabled: true), .privateCloud)
        XCTAssertEqual(BrowserAgentEngineSelection.kind(for: .chatGPTPlan, iOSMajorVersion: 18, chatGPTPlanEnabled: true), .chatGPTPlan)
        XCTAssertNil(BrowserAgentEngineSelection.kind(for: .chatGPTPlan, iOSMajorVersion: 27, chatGPTPlanEnabled: false))
        XCTAssertNil(BrowserAgentEngineSelection.kind(for: .mlxLocal, iOSMajorVersion: 27, chatGPTPlanEnabled: true))
        XCTAssertTrue(BrowserAgentEngineSelection.chatGPTModelSupportsVision("gpt-4o-mini"))
        XCTAssertTrue(BrowserAgentEngineSelection.chatGPTModelSupportsVision("gpt-5.1"))
        for visionModel in ["gpt-5.2", "gpt-5.2-mini", "o3", "o3-pro", "o4-mini", "GPT-4O-MINI"] {
            XCTAssertTrue(
                BrowserAgentEngineSelection.chatGPTModelSupportsVision(visionModel),
                "Expected a recognized ChatGPT vision model family: \(visionModel)"
            )
        }
        for textModel in ["gpt-4", "gpt-4-turbo", "o1", "gpt-3.5-turbo", "unknown-model", "custom-text-model"] {
            XCTAssertFalse(
                BrowserAgentEngineSelection.chatGPTModelSupportsVision(textModel),
                "A non-vision model must remain text-only: \(textModel)"
            )
        }
        for currentModel in ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna"] {
            XCTAssertTrue(BrowserAgentEngineSelection.chatGPTModelSupportsVision(currentModel, inputModalities: ["text", "image"]))
            XCTAssertFalse(BrowserAgentEngineSelection.chatGPTModelSupportsVision(currentModel, inputModalities: ["text"]))
        }
        XCTAssertFalse(BrowserAgentEngineSelection.chatGPTModelSupportsVision("unlisted-custom-model", inputModalities: nil))
        XCTAssertTrue(BrowserAgentEngineSelection.unsupportedMessage(for: .cloudShortcuts, iOSMajorVersion: 26, chatGPTPlanEnabled: true).contains("iOS 27"))

        let local = BrowserAgentEngineProfile.local(contextSize: 4_096, supportsVision: false)
        XCTAssertEqual(local.toolPolicy, .coreOnly)
        XCTAssertEqual(local.maxElements, 60)
        XCTAssertEqual(local.snapshotTextCharacters, 1_200)
        XCTAssertEqual(local.readChunkCharacters, 1_200)
        XCTAssertEqual(local.maxSteps, 20)
        XCTAssertEqual(local.contextSize, 4_096)
        XCTAssertFalse(local.supportsVision)
        XCTAssertEqual(BrowserAgentEngineProfile.local(contextSize: 8_192, supportsVision: true).maxSteps, 20)
        XCTAssertEqual(BrowserAgentEngineProfile.local(contextSize: 2_048, supportsVision: false).maxSteps, 10)
        XCTAssertEqual(BrowserAgentEngineProfile.local(contextSize: 0, supportsVision: false).maxSteps, 4)
        XCTAssertEqual(BrowserAgentEngineProfile.chatGPTPlan(supportsVision: false).maxSteps, 25)
        XCTAssertEqual(BrowserAgentEngineProfile.privateCloud(contextSize: 4_096, supportsVision: false).maxSteps, 25)
        XCTAssertLessThanOrEqual(
            BrowserAgentLocalContext.initialPromptByteLimit(contextSize: 4_096),
            4_096 / 2
        )
        XCTAssertTrue(BrowserAgentLocalContext.hasRoomForInitialContext(
            promptTokens: 300,
            instructionTokens: 300,
            toolTokens: 300,
            contextSize: 4_096
        ))
        XCTAssertTrue(BrowserAgentFoundationReadiness.localContextFailure(
            promptTokens: 2_000,
            instructionTokens: 1_000,
            toolTokens: 1_000,
            contextSize: 4_096
        )?.localizedDescription.localizedCaseInsensitiveContains("context") == true)
        let largeToolResult = BrowserAgentLocalContext.boundedToolResult(
            String(repeating: "界", count: 2_000),
            contextSize: 4_096
        )
        XCTAssertLessThanOrEqual(largeToolResult.utf8.count, BrowserAgentLocalContext.toolResultByteLimit(contextSize: 4_096))
        XCTAssertTrue(largeToolResult.hasSuffix("[tool result trimmed for the Local context]"))
    }

    func testChatGPTModelImageMetadataDecodesAndOldCatalogCacheRemainsCompatible() throws {
        let oldCache = Data(#"{"slug":"account-specific","displayName":"Account model","reasoningEfforts":[],"defaultReasoningEffort":null}"#.utf8)
        let oldModel = try JSONDecoder().decode(ChatGPTPlanModel.self, from: oldCache)
        XCTAssertNil(oldModel.inputModalities)
        XCTAssertNil(oldModel.supportsImageInput)
        XCTAssertFalse(BrowserAgentEngineSelection.chatGPTModelSupportsVision(oldModel.slug, inputModalities: oldModel.inputModalities))

        let current = ChatGPTPlanModel(
            slug: "gpt-6.1-sol",
            displayName: "GPT-6.1 Sol",
            inputModalities: ["text", "image"],
            reasoningEfforts: ["low", "high"],
            defaultReasoningEffort: "high"
        )
        let decoded = try JSONDecoder().decode(ChatGPTPlanModel.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(decoded.inputModalities, ["text", "image"])
        XCTAssertEqual(decoded.supportsImageInput, true)
        XCTAssertTrue(BrowserAgentEngineSelection.chatGPTModelSupportsVision(decoded.slug, inputModalities: decoded.inputModalities))

        let parsed = try ChatGPTPlanService.parseModelCatalog([
            "models": [
                ["visibility": "list", "slug": "gpt-6.1-sol", "display_name": "GPT-6.1 Sol", "input_modalities": ["text", "image"], "priority": 1],
                ["visibility": "list", "slug": "gpt-6-luna", "display_name": "GPT-6 Luna", "input_modalities": ["text"], "priority": 2],
                ["visibility": "hidden", "slug": "not-listed", "input_modalities": ["text", "image"]]
            ]
        ])
        XCTAssertEqual(parsed.map(\.slug), ["gpt-6.1-sol", "gpt-6-luna"])
        let imageModel = try XCTUnwrap(parsed.first)
        let textOnlyModel = try XCTUnwrap(parsed.dropFirst().first)
        XCTAssertEqual(imageModel.inputModalities, ["text", "image"])
        XCTAssertTrue(BrowserAgentEngineSelection.chatGPTModelSupportsVision(imageModel.slug, inputModalities: imageModel.inputModalities))
        XCTAssertFalse(BrowserAgentEngineSelection.chatGPTModelSupportsVision(textOnlyModel.slug, inputModalities: textOnlyModel.inputModalities))
        XCTAssertFalse(BrowserAgentEngineSelection.chatGPTModelSupportsVision("gpt-4o", inputModalities: ["text"]))
    }

    @available(iOS 26.4, *)
    func testNativeTokenizerAcceptsCompactLocalTitleClickAndTypeRequestsWithinOutputReserve() async throws {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw XCTSkip("Apple Local is unavailable, so the native tokenizer cannot measure this request.")
        }

        let contextSize = model.contextSize
        guard contextSize > 0 else {
            throw XCTSkip("Apple Local reports no usable context size in this runtime, so native token measurement is unavailable.")
        }
        let profile = BrowserAgentEngineProfile.local(contextSize: contextSize, supportsVision: false)
        let controls = (3...18).map { "[\($0)] link \"Section \($0)\"" }.joined(separator: "\n")
        let visibleContent = String(repeating: "Example article sentence with ordinary page text. ", count: 45)
        let snapshot = """
        URL: https://example.invalid/
        Title: Example page
        Scroll: 0 of 0px
        Interactive elements (18 of 18, on-screen first):
        [1] button "Blue button"
        [2] textbox "Search"
        \(controls)
        Visible text (start):
        \(visibleContent)
        """
        let reserve = BrowserAgentLocalContext.outputTokenReserve(contextSize: contextSize)
        let available = BrowserAgentLocalContext.availableInputTokens(contextSize: contextSize)
        let requests: [(task: String, expectedTool: String)] = [
            ("Read the page title and finish.", "read_page"),
            ("Click the blue button.", "click"),
            ("Type hello into the search box.", "type_text")
        ]

        for (index, item) in requests.enumerated() {
            let definitions = BrowserAgentController.toolsForRun(
                task: item.task,
                browserAdapterAvailable: true,
                coreOnly: true,
                supportsVision: false,
                readChunkCharacters: profile.readChunkCharacters
            )
            XCTAssertTrue(definitions.contains { $0["name"] as? String == item.expectedTool })
            let request = BrowserAgentEngineRequest(
                initialPrompt: BrowserAgentLocalContext.makeInitialPrompt(
                    task: item.task,
                    conversation: nil,
                    snapshot: snapshot,
                    snapshotMarker: "\n\n<page_snapshot>",
                    contextSize: contextSize
                ),
                tools: definitions,
                instructions: BrowserAgentController.localInstructions,
                profile: profile,
                snapshotMarker: "\n\n<page_snapshot>"
            )
            XCTAssertTrue(request.initialPrompt.contains("Task: \(item.task)"), "Accepted Local tasks must remain exact.")

            let coordinator = BrowserAgentFoundationToolCoordinator(maximumCalls: profile.maxSteps) { _, _ in
                BrowserAgentToolOutput(text: "")
            }
            let tools: [any Tool]
            do {
                tools = try definitions.map {
                    try FoundationAgentTool(definition: $0, coordinator: coordinator, supportsVision: false)
                }
            } catch {
                XCTFail("Local tool schema construction failed for case=\(index + 1): context=\(contextSize) outputReserve=\(reserve) errorType=\(String(reflecting: type(of: error)))")
                return
            }

            let promptTokens: Int
            let instructionTokens: Int
            let toolTokens: Int
            do {
                promptTokens = try await model.tokenCount(for: Prompt(request.initialPrompt))
                instructionTokens = try await model.tokenCount(for: Instructions(request.instructions))
                toolTokens = try await model.tokenCount(for: tools)
            } catch {
                if model.isAvailable {
                    XCTFail("Native tokenizer failed for case=\(index + 1) before budget assertion: context=\(contextSize) outputReserve=\(reserve) errorType=\(String(reflecting: type(of: error)))")
                    return
                }
                throw XCTSkip("Apple Local became unavailable while tokenizing case=\(index + 1).")
            }

            let total = promptTokens + instructionTokens + toolTokens
            print(
                "Local native-tokenizer counts: case=\(index + 1) context=\(contextSize) outputReserve=\(reserve) "
                    + "availableInput=\(available) prompt=\(promptTokens) instructions=\(instructionTokens) "
                    + "tools=\(toolTokens) total=\(total)"
            )
            XCTAssertNil(
                BrowserAgentFoundationReadiness.localContextFailure(
                    promptTokens: promptTokens,
                    instructionTokens: instructionTokens,
                    toolTokens: toolTokens,
                    contextSize: contextSize
                ),
                "Compact Local request exceeds its token budget: case=\(index + 1) context=\(contextSize) "
                    + "outputReserve=\(reserve) availableInput=\(available) prompt=\(promptTokens) "
                    + "instructions=\(instructionTokens) tools=\(toolTokens) total=\(total)"
            )
        }
    }

    func testFoundationCapabilityAndCloudQuotaFailuresAreExplicit() {
        XCTAssertTrue(BrowserAgentFoundationReadiness.localSessionUsesLegacyAPI(isSimulator: true))
        XCTAssertFalse(BrowserAgentFoundationReadiness.localSessionUsesLegacyAPI(isSimulator: false))
        XCTAssertEqual(
            BrowserAgentFoundationReadiness.privateCloudSimulatorUnavailableMessage(isSimulator: true),
            "Private Cloud Compute agent mode requires a supported iOS 27 device."
        )
        XCTAssertNil(BrowserAgentFoundationReadiness.privateCloudSimulatorUnavailableMessage(isSimulator: false))
        XCTAssertFalse(BrowserAgentFoundationReadiness.appleImageAttachmentsSupported(reportedVisionCapability: false))
        XCTAssertEqual(
            BrowserAgentFoundationReadiness.localContextUnavailableMessage(contextSize: 0),
            "Apple Local isn't ready for agent mode yet. Try again when its on-device model context is available."
        )
        XCTAssertNil(BrowserAgentFoundationReadiness.localContextUnavailableMessage(contextSize: 4_096))
        #if targetEnvironment(simulator)
        XCTAssertFalse(BrowserAgentFoundationReadiness.appleImageAttachmentsSupported(reportedVisionCapability: true))
        #else
        XCTAssertTrue(BrowserAgentFoundationReadiness.appleImageAttachmentsSupported(reportedVisionCapability: true))
        #endif
        XCTAssertNil(BrowserAgentFoundationReadiness.toolCallingFailure(engine: "Apple Local", supportsToolCalling: true))
        XCTAssertTrue(BrowserAgentFoundationReadiness.toolCallingFailure(engine: "Apple Local", supportsToolCalling: false)?.localizedDescription.contains("tool calling") == true)
        XCTAssertTrue(BrowserAgentFoundationReadiness.shouldOfferAgent(isAvailable: true, supportsToolCalling: true))
        XCTAssertFalse(BrowserAgentFoundationReadiness.shouldOfferAgent(isAvailable: true, supportsToolCalling: false))
        XCTAssertTrue(BrowserAgentFoundationReadiness.shouldOfferAgent(isAvailable: true, supportsToolCalling: nil), "iOS 26 model capability data is not exposed before iOS 27.")
        XCTAssertFalse(BrowserAgentFoundationReadiness.shouldOfferAgent(isAvailable: false, supportsToolCalling: true))
        XCTAssertNil(BrowserAgentFoundationReadiness.privateCloudQuotaFailure(isLimitReached: false, resetDate: nil))
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(BrowserAgentFoundationReadiness.privateCloudQuotaFailure(isLimitReached: true, resetDate: reset)?.localizedDescription.contains("quota is exhausted") == true)
        XCTAssertNotNil(BrowserAgentFoundationReadiness.privateCloudQuotaNote(isApproachingLimit: true))
        XCTAssertNil(BrowserAgentFoundationReadiness.privateCloudQuotaNote(isApproachingLimit: false))
        let rateLimited = BrowserAgentFoundationReadiness.rateLimitFailure(engine: "Apple Local", resetDate: reset).localizedDescription
        XCTAssertTrue(rateLimited.contains("Apple Local"))
        XCTAssertTrue(rateLimited.localizedCaseInsensitiveContains("rate limited"))
        XCTAssertFalse(rateLimited.contains("Private Cloud Compute"))
    }

    func testPrivateCloudSimulatorReadinessFailsClearlyBeforeModelAccess() throws {
        #if targetEnvironment(simulator)
        XCTAssertFalse(BrowserAgentEngineFactory.isAvailable(for: .cloudShortcuts))
        XCTAssertEqual(
            BrowserAgentEngineFactory.status(for: .cloudShortcuts),
            "Private Cloud Compute agent mode requires a supported iOS 27 device."
        )
        #else
        throw XCTSkip("This readiness regression is specific to Simulator runtimes.")
        #endif
    }

    @available(iOS 26.0, *)
    func testLocalSimulatorWithZeroContextIsUnavailableAndShowsReadinessStatus() throws {
        #if targetEnvironment(simulator)
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw XCTSkip("Apple Local is unavailable in this Simulator runtime.")
        }
        guard model.contextSize == 0 else {
            throw XCTSkip("This Simulator reports a positive Apple Local context size.")
        }
        XCTAssertFalse(BrowserAgentEngineFactory.isAvailable(for: .localApple))
        XCTAssertEqual(
            BrowserAgentEngineFactory.status(for: .localApple),
            "Apple Local isn't ready for agent mode yet. Try again when its on-device model context is available."
        )
        #else
        throw XCTSkip("This readiness regression is specific to Simulator runtimes with zero Local context.")
        #endif
    }

    @available(iOS 26.0, *)
    func testFoundationToolGateSerializesConcurrentCallsAndStopsAfterFinish() async throws {
        let probe = ToolGateProbe()
        let coordinator = BrowserAgentFoundationToolCoordinator(maximumCalls: 3) { _, _ in
            probe.activeCalls += 1
            probe.executedCalls += 1
            probe.maximumConcurrentCalls = max(probe.maximumConcurrentCalls, probe.activeCalls)
            try? await Task.sleep(nanoseconds: 10_000_000)
            probe.activeCalls -= 1
            return BrowserAgentToolOutput(text: "serialized")
        }
        async let first = try coordinator.invoke(name: "read_page", argumentsJSON: "{}")
        async let second = try coordinator.invoke(name: "read_page", argumentsJSON: "{}")
        let outputs = try await (first, second)
        XCTAssertEqual(outputs.0.text, "serialized")
        XCTAssertEqual(outputs.1.text, "serialized")
        XCTAssertEqual(probe.maximumConcurrentCalls, 1)
        XCTAssertEqual(probe.executedCalls, 2)

        let afterFinishProbe = ToolGateProbe()
        let afterFinish = BrowserAgentFoundationToolCoordinator(maximumCalls: 3) { _, _ in
            afterFinishProbe.executedCalls += 1
            return BrowserAgentToolOutput(text: "action")
        }
        _ = try await afterFinish.invoke(name: "click", argumentsJSON: "{}")
        let finish = try await afterFinish.invoke(name: "finish", argumentsJSON: #"{"answer":"Finished."}"#)
        let staleAction = try await afterFinish.invoke(name: "click", argumentsJSON: "{}")
        let finishAnswer = await afterFinish.answer()
        XCTAssertEqual(finish.text, "The task is finished.")
        XCTAssertEqual(finishAnswer, "Finished.")
        XCTAssertEqual(staleAction.text, "This agent run has finished. No page action was taken.")
        XCTAssertEqual(afterFinishProbe.executedCalls, 1)
    }

    @available(iOS 26.0, *)
    func testFoundationResearchFinishRetriesOversizedAnswerWithoutClippingSources() async throws {
        let limit = 20_000
        let sources = "\n\nSources:\n- [Source A](https://a.example/research)\n- [Source B](https://b.example/report)\n- [Source C](https://c.example/data)"
        let oversized = String(repeating: "Evidence body. ", count: 1_400) + sources
        let accepted = "The three sources report the same bounded finding." + sources
        XCTAssertGreaterThan(oversized.count, limit)

        func arguments(_ answer: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["answer": answer])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }

        let coordinator = BrowserAgentFoundationToolCoordinator(
            maximumCalls: 4,
            maximumAnswerCharacters: limit,
            rejectOversizedFinish: true
        ) { _, _ in
            XCTFail("Finishing an answer must not execute a page action.")
            return BrowserAgentToolOutput(text: "unexpected action")
        }
        let rejected = try await coordinator.invoke(name: "finish", argumentsJSON: arguments(oversized))
        XCTAssertTrue(rejected.text.contains("complete Sources list"))
        let answerAfterRejection = await coordinator.answer()
        XCTAssertNil(answerAfterRejection, "An oversized answer must not be accepted in truncated form.")

        let acceptedFinish = try await coordinator.invoke(name: "finish", argumentsJSON: arguments(accepted))
        let finalAnswer = await coordinator.answer()
        XCTAssertEqual(acceptedFinish.text, "The task is finished.")
        XCTAssertEqual(finalAnswer, accepted)
        XCTAssertTrue(finalAnswer?.hasSuffix(sources) == true, "The complete source list must remain at the end.")
    }

    @available(iOS 26.0, *)
    func testFoundationToolGateEnforcesCallLimitAndDoesNotRunQueuedCancelledActions() async throws {
        let limitedProbe = ToolGateProbe()
        let limited = BrowserAgentFoundationToolCoordinator(maximumCalls: 1) { _, _ in
            limitedProbe.executedCalls += 1
            return BrowserAgentToolOutput(text: "one action")
        }
        _ = try await limited.invoke(name: "click", argumentsJSON: "{}")
        do {
            _ = try await limited.invoke(name: "click", argumentsJSON: "{}")
            XCTFail("Exceeding the configured call limit must fail the engine turn.")
        } catch let error as BrowserAgentEngineFailure {
            XCTAssertTrue(error.localizedDescription.contains("1 tool steps"))
        }
        let reachedLimit = await limited.reachedCallLimit()
        XCTAssertTrue(reachedLimit)
        XCTAssertEqual(limitedProbe.executedCalls, 1)
        do {
            _ = try await limited.invoke(name: "click", argumentsJSON: "{}")
            XCTFail("The exhausted coordinator should remain terminal.")
        } catch is BrowserAgentEngineFailure {
            // Expected; the closed run cannot take another action.
        }
        XCTAssertEqual(limitedProbe.executedCalls, 1, "Calls after the limit must remain closed.")

        let queuedProbe = ToolGateProbe()
        let coordinator = BrowserAgentFoundationToolCoordinator(maximumCalls: 5) { _, _ in
            queuedProbe.executedCalls += 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queuedProbe.releaseActive = { continuation.resume() }
            }
            return BrowserAgentToolOutput(text: "released")
        }
        let active = Task { try await coordinator.invoke(name: "read_page", argumentsJSON: "{}") }
        let activeStarted = await waitUntil { queuedProbe.releaseActive != nil }
        XCTAssertTrue(activeStarted)
        let queued = Task { try await coordinator.invoke(name: "click", argumentsJSON: "{}") }
        var queuedCount = 0
        for _ in 0..<100 {
            queuedCount = await coordinator.queuedInvocationCount()
            if queuedCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(queuedCount, 1)
        queued.cancel()
        let cancelledQueuedResult = await queued.result
        guard case .failure(let queuedError) = cancelledQueuedResult else {
            return XCTFail("Cancelled queued work should finish with CancellationError.")
        }
        XCTAssertTrue(queuedError is CancellationError)
        let remainingQueuedCount = await coordinator.queuedInvocationCount()
        XCTAssertEqual(remainingQueuedCount, 0)
        let closedQueued = Task { try await coordinator.invoke(name: "click", argumentsJSON: "{}") }
        var closeQueueCount = 0
        for _ in 0..<100 {
            closeQueueCount = await coordinator.queuedInvocationCount()
            if closeQueueCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(closeQueueCount, 1)
        await coordinator.close()
        queuedProbe.releaseActive?()
        _ = try await active.value
        let closedOutput = try await closedQueued.value
        XCTAssertEqual(closedOutput.text, "This agent run has finished. No page action was taken.")
        XCTAssertEqual(queuedProbe.executedCalls, 1)
    }

    @available(iOS 26.0, *)
    func testFoundationSchemaAdapterConvertsEveryAgentToolDefinition() throws {
        for definition in BrowserAgentController.tools {
            XCTAssertNoThrow(
                try BrowserAgentFoundationSchemaAdapter.schema(for: definition),
                "Schema conversion failed for \(definition["name"] as? String ?? "unnamed")."
            )
        }
    }

    @available(iOS 26.0, *)
    func testFoundationSchemaAndGeneratedContentRoundTripNullableNestedAndEnumArguments() throws {
        let definition: [String: Any] = [
            "name": "schema_round_trip",
            "parameters": [
                "type": "object",
                "properties": [
                    "nullable_query": ["type": ["string", "null"]],
                    "mode": ["type": "string", "enum": ["exact", "fuzzy"]],
                    "records": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "integer"],
                                "note": ["type": ["string", "null"]]
                            ],
                            "required": ["id", "note"]
                        ]
                    ]
                ],
                "required": ["nullable_query", "mode", "records"]
            ]
        ]
        let schema = try BrowserAgentFoundationSchemaAdapter.schema(for: definition)
        let encodedSchema = try JSONEncoder().encode(schema)
        let schemaJSON = try XCTUnwrap(String(data: encodedSchema, encoding: .utf8))
        let decodedSchema = try JSONDecoder().decode(GenerationSchema.self, from: encodedSchema)
        XCTAssertEqual(decodedSchema.debugDescription, schema.debugDescription)
        let schemaObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedSchema) as? [String: Any])
        for expected in ["nullable_query", "mode", "records", "note", "exact", "fuzzy"] {
            XCTAssertTrue(schemaJSON.contains(expected), "The generated schema should retain \(expected).")
        }
        if #available(iOS 26.4, *) {
            func namedObject(_ name: String, in value: Any) -> [String: Any]? {
                if let object = value as? [String: Any] {
                    if object["name"] as? String == name { return object }
                    if let keyedProperty = object[name] as? [String: Any] { return keyedProperty }
                    for child in object.values {
                        if let match = namedObject(name, in: child) { return match }
                    }
                } else if let array = value as? [Any] {
                    for child in array {
                        if let match = namedObject(name, in: child) { return match }
                    }
                }
                return nil
            }
            func hasRequiredProperty(_ name: String, in value: Any) -> Bool {
                if let object = value as? [String: Any] {
                    if (object["required"] as? [String])?.contains(name) == true { return true }
                    return object.values.contains { hasRequiredProperty(name, in: $0) }
                }
                if let array = value as? [Any] {
                    return array.contains { hasRequiredProperty(name, in: $0) }
                }
                return false
            }
            func encoded(_ value: Any) throws -> String {
                let data = try JSONSerialization.data(withJSONObject: value)
                return try XCTUnwrap(String(data: data, encoding: .utf8))
            }
            func resolveJSONPointer(_ reference: String, in root: Any) -> Any? {
                guard reference.hasPrefix("#/") else { return nil }
                var current = root
                for component in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
                    let key = component.replacingOccurrences(of: "~1", with: "/")
                        .replacingOccurrences(of: "~0", with: "~")
                    if let object = current as? [String: Any], let value = object[key] {
                        current = value
                    } else if let array = current as? [Any], let index = Int(key), array.indices.contains(index) {
                        current = array[index]
                    } else {
                        return nil
                    }
                }
                return current
            }
            func acceptsNull(_ value: Any, root: Any, followedReferences: Set<String> = []) -> Bool {
                guard let object = value as? [String: Any] else { return false }
                if let reference = object["$ref"] as? String {
                    guard !followedReferences.contains(reference),
                          var target = resolveJSONPointer(reference, in: root) as? [String: Any] else { return false }
                    var siblings = object
                    siblings.removeValue(forKey: "$ref")
                    target.merge(siblings) { _, sibling in sibling }
                    return acceptsNull(
                        target,
                        root: root,
                        followedReferences: followedReferences.union([reference])
                    )
                }
                var foundConstraint = false
                if let type = object["type"] as? String {
                    foundConstraint = true
                    guard type == "null" else { return false }
                } else if let types = object["type"] as? [String] {
                    foundConstraint = true
                    guard types.contains("null") else { return false }
                }
                if let allowedValues = object["enum"] as? [Any] {
                    foundConstraint = true
                    guard allowedValues.contains(where: { $0 is NSNull }) else { return false }
                }
                if let constant = object["const"] {
                    foundConstraint = true
                    guard constant is NSNull else { return false }
                }
                if let alternatives = object["anyOf"] as? [Any] {
                    foundConstraint = true
                    guard alternatives.contains(where: {
                        acceptsNull($0, root: root, followedReferences: followedReferences)
                    }) else { return false }
                }
                if let alternatives = object["oneOf"] as? [Any] {
                    foundConstraint = true
                    let acceptingAlternatives = alternatives.filter {
                        acceptsNull($0, root: root, followedReferences: followedReferences)
                    }
                    guard acceptingAlternatives.count == 1 else { return false }
                }
                if let requiredComponents = object["allOf"] as? [Any] {
                    foundConstraint = true
                    guard requiredComponents.allSatisfy({
                        acceptsNull($0, root: root, followedReferences: followedReferences)
                    }) else { return false }
                }
                return foundConstraint
            }

            for requiredName in ["nullable_query", "mode", "records", "id", "note"] {
                XCTAssertTrue(
                    hasRequiredProperty(requiredName, in: schemaObject),
                    "A required value must remain required even when its schema accepts null: \(requiredName)."
                )
            }
            let querySchema = try XCTUnwrap(namedObject("nullable_query", in: schemaObject))
            XCTAssertTrue(
                acceptsNull(querySchema, root: schemaObject),
                "The required query schema must accept explicit null after resolving references. Encoded schema: \(schemaJSON)"
            )
            let noteSchema = try XCTUnwrap(namedObject("note", in: schemaObject))
            let encodedNoteSchema = try encoded(noteSchema)
            XCTAssertTrue(
                acceptsNull(noteSchema, root: schemaObject),
                "The required nested note schema must accept explicit null after resolving references. Property: \(encodedNoteSchema); encoded schema: \(schemaJSON)"
            )
        }

        let argumentJSON = #"{"nullable_query":null,"mode":"exact","records":[{"id":7,"note":null},{"id":8,"note":"keep this"}]}"#
        let generated = try GeneratedContent(json: argumentJSON)
        let generatedRoundTrip = try GeneratedContent(json: generated.jsonString)
        let normalized = try JSONSerialization.jsonObject(with: XCTUnwrap(generatedRoundTrip.jsonString.data(using: .utf8))) as? [String: Any]
        XCTAssertTrue(normalized?["nullable_query"] is NSNull)
        XCTAssertEqual(normalized?["mode"] as? String, "exact")
        let records = try XCTUnwrap(normalized?["records"] as? [[String: Any]])
        XCTAssertTrue(records.first?["note"] is NSNull)
        XCTAssertEqual(records.last?["note"] as? String, "keep this")
    }

    func testChatGPTEngineSendsOnlyTheNewestScreenshotAsInputImage() async throws {
        let profile = BrowserAgentEngineProfile.chatGPTPlan(supportsVision: true)
        let firstImage = Data("first-jpeg".utf8)
        let secondImage = Data("second-jpeg".utf8)
        var inputsByTurn: [[[String: Any]]] = []
        var turnNumber = 0
        let engine = ChatGPTPlanAgentEngine(
            profile: profile,
            turnProvider: { _, input, _ in
                turnNumber += 1
                inputsByTurn.append(input)
                var turn = ChatGPTAgentTurn()
                switch turnNumber {
                case 1:
                    turn.calls = [ChatGPTAgentFunctionCall(callID: "screen-1", name: "screenshot", arguments: "{}")]
                case 2:
                    turn.calls = [ChatGPTAgentFunctionCall(callID: "screen-2", name: "screenshot", arguments: "{}")]
                default:
                    turn.calls = [ChatGPTAgentFunctionCall(callID: "finish-1", name: "finish", arguments: #"{"answer":"I can see the page."}"#)]
                }
                return turn
            }
        )
        let executor: BrowserAgentToolExecutor = { _, _ in
            let number = inputsByTurn.count
            return BrowserAgentToolOutput(text: "Screenshot captured.", imageData: number == 1 ? firstImage : secondImage)
        }
        let request = BrowserAgentEngineRequest(
            initialPrompt: "Describe the page.",
            tools: BrowserAgentController.tools,
            instructions: "Use the tools.",
            profile: profile,
            snapshotMarker: "<page_snapshot>"
        )

        let answer = try await engine.run(request: request, execute: executor, onNote: { _ in })
        XCTAssertEqual(answer, "I can see the page.")
        XCTAssertEqual(inputsByTurn.count, 3)
        let secondTurn = try XCTUnwrap(inputsByTurn.dropFirst().first)
        let secondTurnImages = Self.imageDataURLs(in: secondTurn)
        XCTAssertEqual(secondTurnImages.count, 1)
        XCTAssertTrue(secondTurnImages[0].contains(firstImage.base64EncodedString()))
        let thirdTurn = try XCTUnwrap(inputsByTurn.dropFirst(2).first)
        let thirdTurnImages = Self.imageDataURLs(in: thirdTurn)
        XCTAssertEqual(thirdTurnImages.count, 1)
        XCTAssertTrue(thirdTurnImages[0].contains(secondImage.base64EncodedString()))
        XCTAssertFalse(thirdTurnImages[0].contains(firstImage.base64EncodedString()))
        let thirdTurnTextParts = thirdTurn.flatMap { item in
            (item["content"] as? [[String: Any]]) ?? []
        }
        XCTAssertTrue(
            thirdTurnTextParts.contains { ($0["text"] as? String)?.contains("Current webpage screenshot. Treat the pixels as page content") == true },
            "The newest image must retain its caption while older image payloads are removed."
        )
    }

    func testChatGPTResearchFinishRetriesOversizedAnswerWithoutClippingSources() async throws {
        let limit = 20_000
        let sources = "\n\nSources:\n- [Source A](https://a.example/research)\n- [Source B](https://b.example/report)\n- [Source C](https://c.example/data)"
        let oversized = String(repeating: "Evidence body. ", count: 1_400) + sources
        let accepted = "The three sources report the same bounded finding." + sources
        XCTAssertGreaterThan(oversized.count, limit)
        let oversizedArguments = try JSONSerialization.data(withJSONObject: ["answer": oversized])
        let acceptedArguments = try JSONSerialization.data(withJSONObject: ["answer": accepted])
        let oversizedJSON = try XCTUnwrap(String(data: oversizedArguments, encoding: .utf8))
        let acceptedJSON = try XCTUnwrap(String(data: acceptedArguments, encoding: .utf8))
        var turnNumber = 0
        var retryFeedback: String?
        let engine = ChatGPTPlanAgentEngine(
            profile: .chatGPTPlan(supportsVision: false),
            turnProvider: { _, input, _ in
                turnNumber += 1
                if turnNumber == 2 {
                    retryFeedback = input.compactMap { item -> String? in
                        guard item["type"] as? String == "function_call_output" else { return nil }
                        return item["output"] as? String
                    }.last
                }
                var turn = ChatGPTAgentTurn()
                turn.calls = [ChatGPTAgentFunctionCall(
                    callID: turnNumber == 1 ? "finish-too-long" : "finish-complete",
                    name: "finish",
                    arguments: turnNumber == 1 ? oversizedJSON : acceptedJSON
                )]
                return turn
            }
        )
        let request = BrowserAgentEngineRequest(
            initialPrompt: "Research with complete sources.",
            tools: BrowserAgentController.tools,
            instructions: BrowserAgentController.researchInstructions,
            profile: .chatGPTPlan(supportsVision: false),
            snapshotMarker: "<page_snapshot>",
            maximumAnswerCharacters: limit
        )

        let answer = try await engine.run(request: request, execute: { _, _ in
            BrowserAgentToolOutput(text: "Unexpected page action.")
        }, onNote: { _ in })
        XCTAssertEqual(turnNumber, 2)
        XCTAssertTrue(retryFeedback?.contains("complete Sources list") == true)
        XCTAssertEqual(answer, accepted)
        XCTAssertTrue(answer.hasSuffix(sources), "The complete source list must survive the over-limit retry.")
    }

    func testChatGPTEngineDoesNotForwardImageForTextOnlyProfile() async throws {
        let profile = BrowserAgentEngineProfile.chatGPTPlan(supportsVision: false)
        var imageCountAfterScreenshot = -1
        var turnNumber = 0
        let engine = ChatGPTPlanAgentEngine(
            profile: profile,
            turnProvider: { _, input, _ in
                turnNumber += 1
                if turnNumber == 2 { imageCountAfterScreenshot = Self.imageDataURLs(in: input).count }
                var turn = ChatGPTAgentTurn()
                turn.calls = [ChatGPTAgentFunctionCall(
                    callID: "call-\(turnNumber)",
                    name: turnNumber == 1 ? "screenshot" : "finish",
                    arguments: turnNumber == 1 ? "{}" : #"{"answer":"Done."}"#
                )]
                return turn
            }
        )
        let request = BrowserAgentEngineRequest(
            initialPrompt: "Text-only run.",
            tools: BrowserAgentController.tools,
            instructions: "Use the tools.",
            profile: profile,
            snapshotMarker: "<page_snapshot>"
        )
        _ = try await engine.run(
            request: request,
            execute: { _, _ in BrowserAgentToolOutput(text: "Screenshot.", imageData: Data("not-forwarded".utf8)) },
            onNote: { _ in }
        )
        XCTAssertEqual(imageCountAfterScreenshot, 0)
    }

    @available(iOS 27.0, *)
    func testTypedTranscriptRetentionKeepsPairsAndOnlyNewestSnapshotAndImage() throws {
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.cgImage)
        let callArguments = try GeneratedContent(json: #"{"id":1}"#)
        let call = Transcript.ToolCall(id: "call-1", toolName: "read_page", arguments: callArguments)
        let pair = Transcript.ToolCalls(id: "calls-1", [call])
        let oldScreenshot = Transcript.AttachmentSegment(id: "image-old", content: .image(Transcript.ImageAttachment(image)))
        let newScreenshot = Transcript.AttachmentSegment(id: "image-new", content: .image(Transcript.ImageAttachment(image)))
        let original: [Transcript.Entry] = [
            .toolCalls(pair),
            .toolOutput(Transcript.ToolOutput(id: "output-old", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-old", content: "older text\n<page_snapshot>snapshot one"))
            ])),
            .toolOutput(Transcript.ToolOutput(id: "output-image-old", toolName: "screenshot", segments: [
                .text(Transcript.TextSegment(id: "text-image-old", content: "Old screenshot.")), .attachment(oldScreenshot)
            ])),
            .toolOutput(Transcript.ToolOutput(id: "output-new", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-new", content: "newer text\n<page_snapshot>snapshot two"))
            ])),
            .toolOutput(Transcript.ToolOutput(id: "output-image-new", toolName: "screenshot", segments: [
                .text(Transcript.TextSegment(id: "text-image-new", content: "Current screenshot.")), .attachment(newScreenshot)
            ]))
        ]

        let retained = BrowserAgentFoundationHistoryRetention.retainRecentSnapshotsAndLatestImage(
            original,
            snapshotLimit: 1
        )
        XCTAssertEqual(retained.map(\.id), original.map(\.id), "Transcript call/output entry identity and pairing must remain intact.")
        guard case .toolCalls(let retainedPair) = try XCTUnwrap(retained.first) else {
            return XCTFail("Tool call entries should remain paired with their outputs.")
        }
        XCTAssertEqual(retainedPair.id, pair.id)
        XCTAssertEqual(retainedPair.first?.id, call.id)

        let outputs = retained.compactMap { entry -> Transcript.ToolOutput? in
            guard case .toolOutput(let output) = entry else { return nil }
            return output
        }
        XCTAssertEqual(outputs.first?.id, "output-old")
        let oldSnapshotText = outputs.first?.segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }.joined(separator: " ")
        XCTAssertTrue(oldSnapshotText?.contains("older page snapshot removed") == true)
        let imageSegments = outputs.flatMap(\.segments).compactMap { segment -> String? in
            guard case .attachment(let attachment) = segment else { return nil }
            return attachment.id
        }
        XCTAssertEqual(imageSegments, ["image-new"])
    }

    @available(iOS 27.0, *)
    func testLocalTranscriptRetentionKeepsOnlyRecentToolTextAndPreservesEntryIdentity() throws {
        let original: [Transcript.Entry] = (1...5).map { index in
            .toolOutput(Transcript.ToolOutput(
                id: "output-\(index)",
                toolName: "read_page",
                segments: [.text(Transcript.TextSegment(id: "text-\(index)", content: "result-\(index)"))]
            ))
        }
        let retained = BrowserAgentFoundationHistoryRetention.retainRecentSnapshotsAndLatestImage(
            original,
            outputLimit: 2
        )
        XCTAssertEqual(retained.map(\.id), original.map(\.id))
        let texts = retained.compactMap { entry -> String? in
            guard case .toolOutput(let output) = entry,
                  let segment = output.segments.first,
                  case .text(let text) = segment else { return nil }
            return text.content
        }
        XCTAssertEqual(texts.count, 5)
        XCTAssertTrue(texts[0].contains("Earlier tool result removed"))
        XCTAssertTrue(texts[1].contains("Earlier tool result removed"))
        XCTAssertTrue(texts[2].contains("Earlier tool result removed"))
        XCTAssertEqual(texts[3], "result-4")
        XCTAssertEqual(texts[4], "result-5")
    }

    @available(iOS 27.0, *)
    func testLocalRetentionKeepsNewestSnapshotInsideDroppedToolOutput() throws {
        let original: [Transcript.Entry] = [
            .toolOutput(Transcript.ToolOutput(id: "output-a", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-a", content: "action A\n<page_snapshot>snapshot one"))
            ])),
            .toolOutput(Transcript.ToolOutput(id: "output-read", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-read", content: "fresh read text"))
            ]))
        ]
        let retained = BrowserAgentFoundationHistoryRetention.retainRecentSnapshotsAndLatestImage(
            original,
            snapshotLimit: 1,
            outputLimit: 1
        )
        XCTAssertEqual(retained.map(\.id), original.map(\.id))
        let texts = retained.compactMap { entry -> String? in
            guard case .toolOutput(let output) = entry,
                  let segment = output.segments.first,
                  case .text(let text) = segment else { return nil }
            return text.content
        }
        XCTAssertEqual(texts, [
            "[Earlier tool result removed to fit the Local context.]\n<page_snapshot>snapshot one",
            "fresh read text"
        ])
        guard case .toolOutput(let firstOutput) = retained.first,
              case .text(let firstText) = firstOutput.segments.first else {
            return XCTFail("Entry and segment identity must be preserved.")
        }
        XCTAssertEqual(firstOutput.id, "output-a")
        XCTAssertEqual(firstText.id, "text-a")
    }

    @available(iOS 27.0, *)
    func testLocalRetentionKeepsOnlyNewestSnapshotAmongDroppedToolOutputs() throws {
        let original: [Transcript.Entry] = [
            .toolOutput(Transcript.ToolOutput(id: "output-a", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-a", content: "action A\n<page_snapshot>snapshot one"))
            ])),
            .toolOutput(Transcript.ToolOutput(id: "output-b", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-b", content: "action B\n<page_snapshot>snapshot two"))
            ])),
            .toolOutput(Transcript.ToolOutput(id: "output-read", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-read", content: "fresh read text"))
            ]))
        ]
        let retained = BrowserAgentFoundationHistoryRetention.retainRecentSnapshotsAndLatestImage(
            original,
            snapshotLimit: 1,
            outputLimit: 1
        )
        let texts = retained.compactMap { entry -> String? in
            guard case .toolOutput(let output) = entry,
                  let segment = output.segments.first,
                  case .text(let text) = segment else { return nil }
            return text.content
        }
        XCTAssertEqual(texts, [
            "[Earlier tool result removed to fit the Local context.]",
            "[Earlier tool result removed to fit the Local context.]\n<page_snapshot>snapshot two",
            "fresh read text"
        ])
    }

    @available(iOS 27.0, *)
    func testLocalRetentionLeavesNewestOutputWholeAndDropsOlderSnapshotWhenLimitSpent() throws {
        let original: [Transcript.Entry] = [
            .toolOutput(Transcript.ToolOutput(id: "output-a", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-a", content: "action A\n<page_snapshot>snapshot one"))
            ])),
            .toolOutput(Transcript.ToolOutput(id: "output-b", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-b", content: "action B\n<page_snapshot>snapshot two"))
            ]))
        ]
        let retained = BrowserAgentFoundationHistoryRetention.retainRecentSnapshotsAndLatestImage(
            original,
            snapshotLimit: 1,
            outputLimit: 1
        )
        let texts = retained.compactMap { entry -> String? in
            guard case .toolOutput(let output) = entry,
                  let segment = output.segments.first,
                  case .text(let text) = segment else { return nil }
            return text.content
        }
        XCTAssertEqual(texts, [
            "[Earlier tool result removed to fit the Local context.]",
            "action B\n<page_snapshot>snapshot two"
        ])
    }

    @available(iOS 27.0, *)
    func testCloudRetentionWithoutOutputLimitIsUnchanged() throws {
        let original: [Transcript.Entry] = [
            .toolOutput(Transcript.ToolOutput(id: "output-1", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-1", content: "action A\n<page_snapshot>snapshot one"))
            ])),
            .toolOutput(Transcript.ToolOutput(id: "output-2", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-2", content: "plain read output"))
            ])),
            .toolOutput(Transcript.ToolOutput(id: "output-3", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-3", content: "action C\n<page_snapshot>snapshot three"))
            ])),
            .toolOutput(Transcript.ToolOutput(id: "output-4", toolName: "read_page", segments: [
                .text(Transcript.TextSegment(id: "text-4", content: "action D\n<page_snapshot>snapshot four"))
            ]))
        ]
        let retained = BrowserAgentFoundationHistoryRetention.retainRecentSnapshotsAndLatestImage(
            original,
            snapshotLimit: 2,
            outputLimit: nil
        )
        XCTAssertEqual(retained.map(\.id), original.map(\.id))
        let texts = retained.compactMap { entry -> String? in
            guard case .toolOutput(let output) = entry,
                  let segment = output.segments.first,
                  case .text(let text) = segment else { return nil }
            return text.content
        }
        XCTAssertEqual(texts, [
            "action A\n\n[older page snapshot removed]",
            "plain read output",
            "action C\n<page_snapshot>snapshot three",
            "action D\n<page_snapshot>snapshot four"
        ])
    }

    func testScreenshotJPEGIsDimensionAndByteBounded() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2_048, height: 1_024), format: format).image { context in
            for row in 0..<32 {
                let value = CGFloat(row) / 31
                UIColor(red: value, green: 1 - value, blue: (value * 7).truncatingRemainder(dividingBy: 1), alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: CGFloat(row) * 32, width: 2_048, height: 32))
            }
        }
        let jpeg = try XCTUnwrap(BrowserAgentScreenshotEncoder.encode(try XCTUnwrap(source.cgImage), maximumBytes: 64_000))
        XCTAssertLessThanOrEqual(jpeg.count, 64_000)
        let decoded = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), BrowserAgentScreenshotEncoder.maximumDimension)
    }

    func testScreenshotEncoderPreservesTopBottomAndDownscalesSourcesOverFiveThousandPixels() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 24), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 12, width: 12, height: 12))
        }
        let sourceCG = try XCTUnwrap(source.cgImage)
        let encoded = try XCTUnwrap(BrowserAgentScreenshotEncoder.encode(sourceCG))
        let decodedCG = try XCTUnwrap(UIImage(data: encoded)?.cgImage)
        let sourceTop = try pixel(in: sourceCG, pixelX: sourceCG.width / 2, pixelY: 1)
        let sourceBottom = try pixel(in: sourceCG, pixelX: sourceCG.width / 2, pixelY: sourceCG.height - 2)
        let outputTop = try pixel(in: decodedCG, pixelX: decodedCG.width / 2, pixelY: 1)
        let outputBottom = try pixel(in: decodedCG, pixelX: decodedCG.width / 2, pixelY: decodedCG.height - 2)
        XCTAssertGreaterThan(colorDistance(sourceTop, sourceBottom), 100)
        XCTAssertLessThan(colorDistance(sourceTop, outputTop), 100)
        XCTAssertLessThan(colorDistance(sourceBottom, outputBottom), 100)

        let largeContext = try XCTUnwrap(CGContext(
            data: nil,
            width: 6_000,
            height: 2_000,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        largeContext.setFillColor(UIColor.systemTeal.cgColor)
        largeContext.fill(CGRect(x: 0, y: 0, width: 6_000, height: 2_000))
        let largeCG = try XCTUnwrap(largeContext.makeImage())
        let largeJPEG = try XCTUnwrap(BrowserAgentScreenshotEncoder.encode(largeCG))
        let largeOutput = try XCTUnwrap(UIImage(data: largeJPEG)?.cgImage)
        XCTAssertLessThanOrEqual(max(largeOutput.width, largeOutput.height), BrowserAgentScreenshotEncoder.maximumDimension)
    }

    func testScreenshotCaptureTimesOutAndCancellationResolvesLateSnapshotCallbackOnce() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        do {
            _ = try await BrowserAgentScreenshotEncoder.capture(webView, timeout: 0.02, snapshotter: { _, _, _ in })
            XCTFail("A snapshotter that never replies must hit the capture timeout.")
        } catch let error as BrowserAgentScreenshotError {
            XCTAssertEqual(error, .timedOut)
        }

        var captureStarted = false
        var lateCompletion: (@MainActor @Sendable (UIImage?, (any Error)?) -> Void)?
        let task = Task { @MainActor in
            try await BrowserAgentScreenshotEncoder.capture(webView, timeout: 0.2, snapshotter: { _, _, completion in
                captureStarted = true
                lateCompletion = completion
            })
        }
        let started = await waitUntil { captureStarted }
        XCTAssertTrue(started)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation should release the pending snapshot continuation.")
        } catch is CancellationError {
            // Expected.
        }
        let lateImage = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        lateCompletion?(lateImage, nil)
    }

    @available(iOS 27.0, *)
    func testAppleVisionToolOutputPromptCarriesImageAttachment() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The current FoundationModels Simulator runtime lacks the weak-imported image attachment implementation; verify this path on a vision-capable Apple device.")
        #else
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw XCTSkip("Apple Foundation Models is unavailable in this runtime; image attachment construction requires a supported Apple model.")
        }
        guard model.capabilities.contains(.vision) else {
            throw XCTSkip("This runtime's Apple model does not advertise vision; testing image attachment construction is unsupported here.")
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let output = BrowserAgentFoundationPromptBuilder.toolOutput(text: "Masked screenshot.", imageData: jpeg, supportsVision: true)
        XCTAssertTrue(output.includesImageAttachment)
        #endif
    }

    @available(iOS 27.0, *)
    func testAppleVisionPromptDefensivelyUsesTextFallbackOnSimulatorEvenWhenProfileClaimsVision() throws {
        #if targetEnvironment(simulator)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let output = BrowserAgentFoundationPromptBuilder.toolOutput(
            text: "Masked screenshot.",
            imageData: jpeg,
            supportsVision: true
        )
        XCTAssertFalse(output.includesImageAttachment, "Apple image attachments must safely fall back on Simulator even if a stale profile says vision is supported.")
        #else
        throw XCTSkip("This defensive fallback regression applies only to Simulator runtimes.")
        #endif
    }

    @available(iOS 26.0, *)
    func testAppleVisionToolOutputUsesTextFallbackWithoutVisionSupport() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let textOnlyOutput = BrowserAgentFoundationPromptBuilder.toolOutput(text: "Screenshot.", imageData: jpeg, supportsVision: false)
        XCTAssertFalse(textOnlyOutput.includesImageAttachment)

        let unreadableImage = BrowserAgentFoundationPromptBuilder.toolOutput(text: "Screenshot unavailable.", imageData: Data("not an image".utf8))
        XCTAssertFalse(unreadableImage.includesImageAttachment)
    }

    private static func imageDataURLs(in input: [[String: Any]]) -> [String] {
        input.flatMap { item -> [String] in
            guard let content = item["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { part in
                guard part["type"] as? String == "input_image" else { return nil }
                return part["image_url"] as? String
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<800 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func pixel(in image: CGImage, pixelX: Int, pixelY: Int) throws -> [UInt8] {
        let provider = try XCTUnwrap(image.dataProvider)
        let data = try XCTUnwrap(provider.data) as Data
        let bytesPerPixel = image.bitsPerPixel / 8
        let offset = pixelY * image.bytesPerRow + pixelX * bytesPerPixel
        guard bytesPerPixel >= 3, offset >= 0, offset + 2 < data.count else {
            throw NSError(domain: "BrowserAgentScreenshotTest", code: 1)
        }
        return Array(data[offset..<(offset + 3)])
    }

    private func colorDistance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        zip(lhs, rhs).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    }
}
