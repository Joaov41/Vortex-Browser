import AppIntents
import Foundation
import WebKit
import XCTest
@testable import Browser

@MainActor
final class BrowserIntentsRuntimeTests: XCTestCase {
    private func makeRuntime() -> BrowserIntentRuntime {
        BrowserIntentRuntime(readinessTimeout: 0.4, executionTimeout: 0.6, pollInterval: 0.01)
    }

    private let approve: BrowserIntentConfirmation = { _ in }

    func testNoRegisteredEndpointFails() async {
        let runtime = makeRuntime()
        do {
            _ = try await runtime.perform(.newTab, confirm: approve)
            XCTFail("Expected an error without a registered endpoint")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .noWindow)
        }
        XCTAssertFalse(runtime.isBusy)
    }

    func testInactiveEndpointFails() async {
        let runtime = makeRuntime()
        runtime.register(windowID: UUID(), isActive: false, isReady: { true }, execute: { _, _, _ in
            XCTFail("Inactive endpoint must not execute")
            return BrowserIntentOutput(text: "bad")
        })
        do {
            _ = try await runtime.perform(.newTab, confirm: approve)
            XCTFail("Expected an error with an inactive endpoint")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .windowNotReady)
        }
    }

    func testMultipleActiveWindowsRejectImmediately() async {
        let runtime = makeRuntime()
        runtime.register(windowID: UUID(), isActive: true, isReady: { true }, execute: { _, _, _ in
            BrowserIntentOutput(text: "one")
        })
        runtime.register(windowID: UUID(), isActive: true, isReady: { true }, execute: { _, _, _ in
            BrowserIntentOutput(text: "two")
        })
        do {
            _ = try await runtime.perform(.newTab, confirm: approve)
            XCTFail("Expected multiwindow rejection")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .multipleWindows)
        }
    }

    func testRegisteredEndpointExecutesAndReleasesBusy() async throws {
        let runtime = makeRuntime()
        var busyObserved = false
        runtime.register(windowID: UUID(), isActive: true, isReady: { true }, execute: { _, _, _ in
            busyObserved = runtime.isBusy
            return BrowserIntentOutput(text: "done")
        })
        let output = try await runtime.perform(.newTab, confirm: approve)
        XCTAssertEqual(output.text, "done")
        XCTAssertTrue(busyObserved)
        XCTAssertFalse(runtime.isBusy)
    }

    func testBusyRequestRejectsImmediately() async throws {
        let runtime = BrowserIntentRuntime(readinessTimeout: 0.4, executionTimeout: 5, pollInterval: 0.01)
        let entered = expectation(description: "first request started")
        let release = expectation(description: "release first request")
        runtime.register(windowID: UUID(), isActive: true, isReady: { true }, execute: { _, _, _ in
            entered.fulfill()
            await self.fulfillment(of: [release], timeout: 5)
            return BrowserIntentOutput(text: "slow")
        })
        let task = Task { @MainActor in
            try await runtime.perform(.newTab, confirm: self.approve)
        }
        await fulfillment(of: [entered], timeout: 5)
        do {
            _ = try await runtime.perform(.newTab, confirm: approve)
            XCTFail("Expected busy rejection")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .busy)
        }
        release.fulfill()
        _ = try? await task.value
    }

    func testCancellationWhileWaitingLeavesNoBusyState() async {
        let runtime = BrowserIntentRuntime(readinessTimeout: 5, executionTimeout: 5, pollInterval: 0.01)
        runtime.register(windowID: UUID(), isActive: true, isReady: { false }, execute: { _, _, _ in
            XCTFail("Unready endpoint must not execute")
            return BrowserIntentOutput(text: "bad")
        })
        let task = Task { @MainActor in
            try await runtime.perform(.newTab, confirm: self.approve)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.result
        switch result {
        case .success:
            XCTFail("Cancelled request must not succeed")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError || (error as? BrowserIntentError) == .windowNotReady)
        }
        XCTAssertFalse(runtime.isBusy)
    }

    func testUnregisterInvalidatesCurrentRequest() async throws {
        let runtime = BrowserIntentRuntime(readinessTimeout: 0.4, executionTimeout: 5, pollInterval: 0.01)
        let windowID = UUID()
        var captured: (@MainActor () -> Bool)?
        runtime.register(windowID: windowID, isActive: true, isReady: { true }, execute: { _, _, validity in
            captured = validity
            runtime.unregister(windowID: windowID)
            XCTAssertFalse(validity())
            return BrowserIntentOutput(text: "late")
        })
        do {
            _ = try await runtime.perform(.newTab, confirm: approve)
            XCTFail("An unregistered request must not return success")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
        XCTAssertFalse(runtime.isBusy)
        XCTAssertEqual(captured?(), false)
    }

    func testExecutionTimeoutInvalidatesRequest() async {
        let runtime = BrowserIntentRuntime(readinessTimeout: 0.4, executionTimeout: 0.1, pollInterval: 0.01)
        runtime.register(windowID: UUID(), isActive: true, isReady: { true }, execute: { _, _, _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return BrowserIntentOutput(text: "late")
        })
        do {
            _ = try await runtime.perform(.newTab, confirm: approve)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .timedOut)
        }
        XCTAssertFalse(runtime.isBusy)
    }

}

final class BrowserIntentSidebarGateTests: XCTestCase {
    func testInteractiveActionPolicy() {
        XCTAssertTrue(AISidebar.canStartInteractiveAction(
            browserActionIsBusy: false,
            aiIsProcessing: false,
            agentIsRunning: false
        ))
        XCTAssertFalse(AISidebar.canStartInteractiveAction(
            browserActionIsBusy: true,
            aiIsProcessing: false,
            agentIsRunning: false
        ))
        XCTAssertFalse(AISidebar.canStartInteractiveAction(
            browserActionIsBusy: false,
            aiIsProcessing: true,
            agentIsRunning: false
        ))
        XCTAssertFalse(AISidebar.canStartInteractiveAction(
            browserActionIsBusy: false,
            aiIsProcessing: false,
            agentIsRunning: true
        ))
    }
}

@MainActor
struct IntentAICall {
    let instructions: String
    let body: String
    let backend: AIModelBackend
}

struct SentWebAIRequest {
    let provider: WebAIProvider
    let userPrompt: String
    let composedPrompt: String
    let sourceTab: BrowserTab
    let binding: BrowserAgentPageContextBinding
}

struct IntentExecutorHarness {
    let scratch: URL
    let viewModel: BrowserViewModel
    let downloadManager: BrowserDownloadManager
    let privacy: BrowserAgentAutofillPrivacy
    let history: HistoryStore
    let current: IntentFlag
    var recorded = IntentRecorded()
}

final class IntentFlag {
    var value = true
}

final class IntentLoadWaiter: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }
}

final class IntentRecorded {
    var downloads: [URL] = []
    var pasteboardText: String?
    var translateCalls: [(BrowserTab, String)] = []
    var aiCalls: [IntentAICall] = []
    var splitCalls: [(UUID, UUID)] = []
    var endSplitCalls = 0
    var sendWebAICalls: [SentWebAIRequest] = []
    var jsCalls: [(String, [String: Any])] = []
    var pdfCalls = 0
    var screenshotCalls = 0
    var sendWebAIResult = true
    var videoScriptResult = "[]"
    var aiResult: Result<String, Error> = .success("AI result text")
    var translatePredicate: (@MainActor () -> Bool)?
}

@MainActor
class BrowserIntentsExecutorTestCase: XCTestCase {
    func makeHarness() throws -> IntentExecutorHarness {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let suite = "BrowserIntentsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let viewModel = BrowserViewModel(
            userDefaults: defaults,
            thumbnailDirectory: scratch.appendingPathComponent("thumbs", isDirectory: true)
        )
        viewModel.tabs = []
        return IntentExecutorHarness(
            scratch: scratch,
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            privacy: BrowserAgentAutofillPrivacy(),
            history: HistoryStore(directory: scratch.appendingPathComponent("history", isDirectory: true)),
            current: IntentFlag()
        )
    }

    func makeExecutor(
        _ harness: IntentExecutorHarness,
        approve confirm: BrowserIntentConfirmation? = nil
    ) -> (BrowserIntentExecutor, BrowserIntentConfirmation) {
        let recorded = harness.recorded
        let executor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: harness.history,
            isCurrent: { harness.current.value },
            backendProvider: { .chatGPTPlan },
            aiGenerator: { instructions, body, backend in
                recorded.aiCalls.append(IntentAICall(instructions: instructions, body: body, backend: backend))
                switch recorded.aiResult {
                case .success(let text): return text
                case .failure(let error): throw error
                }
            },
            callbacks: makeCallbacks(recorded: recorded),
            evaluateScript: { _, script, arguments in
                recorded.jsCalls.append((script, arguments))
                switch script {
                case BrowserAgentPageScript.documentIdentity:
                    return #"{"nonce":"abc123"}"#
                case BrowserAgentPageScript.snapshot:
                    return #"{"ok":true}"#
                case BrowserAgentPageScript.readText:
                    return #"{"total":123,"offset":0,"text":"hello world"}"#
                default:
                    let found = (arguments["query"] as? String) == "alpha"
                    return #"{"found":"# + "\(found)" + #","count":3,"highlighted":true}"#
                }
            },
            evaluatePageScript: { _, _ in true },
            exportPDF: { _ in
                recorded.pdfCalls += 1
                return Data("%PDF-fake".utf8)
            },
            captureScreenshot: { _ in
                recorded.screenshotCalls += 1
                return Data("jpeg-fake".utf8)
            },
            startDownload: { url, _, _ in
                recorded.downloads.append(url)
            },
            writePasteboard: { text in
                recorded.pasteboardText = text
            }
        )
        return (executor, confirm ?? { _ in })
    }

    func makeCallbacks(recorded: IntentRecorded) -> BrowserIntentExecutor.Callbacks {
        var callbacks = BrowserIntentExecutor.Callbacks()
        callbacks.translatePage = { tab, tag, shouldContinue in
            recorded.translateCalls.append((tab, tag))
            recorded.translatePredicate = shouldContinue
        }
        callbacks.openSplit = { primary, secondary in recorded.splitCalls.append((primary, secondary)) }
        callbacks.endSplit = { recorded.endSplitCalls += 1 }
        callbacks.sendToWebAI = { provider, user, composed, tab, binding in
            recorded.sendWebAICalls.append(
                SentWebAIRequest(
                    provider: provider,
                    userPrompt: user,
                    composedPrompt: composed,
                    sourceTab: tab,
                    binding: binding
                )
            )
            return recorded.sendWebAIResult
        }
        return callbacks
    }

    let decline: BrowserIntentConfirmation = { _ in throw CancellationError() }

    @discardableResult
    func addTab(
        _ harness: IntentExecutorHarness,
        url: String = "https://example.com/page",
        incognito: Bool = false,
        provider: WebAIProvider? = nil,
        groupID: UUID? = nil
    ) -> BrowserTab {
        let tab = BrowserTab(title: "Tab", url: URL(string: url), isIncognito: incognito, groupID: groupID)
        tab.webAIProvider = provider
        harness.viewModel.tabs.append(tab)
        harness.viewModel.selectedTabID = tab.id
        return tab
    }

    func loadPage(
        _ harness: IntentExecutorHarness,
        html: String = "<main>Hello readable content</main>",
        baseURL: String = "https://example.com/page"
    ) async throws -> (BrowserTab, AIWebView) {
        let tab = addTab(harness, url: baseURL)
        let webView = tab.activateWebView()
        let waiter = IntentLoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: baseURL))
        }
        return (tab, webView)
    }
}
