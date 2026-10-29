import WebKit
import XCTest
@testable import Browser

@MainActor
final class BrowserIntentsBindingTests: BrowserIntentsExecutorTestCase {
    func testUnloadedWebViewRejectsPageCommands() async throws {
        let harness = try makeHarness()
        let tab = addTab(harness, url: "https://example.com/page")
        _ = tab.activateWebView()
        XCTAssertNil(tab.liveWebView?.url)
        let (executor, confirm) = makeExecutor(harness)
        do {
            _ = try await executor.execute(.reload, confirm: confirm)
            XCTFail("Unloaded page must be rejected")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
    }

    func testSelectedTabMutationDuringNonceRejects() async throws {
        let harness = try makeHarness()
        let (loaded, _) = try await loadPage(harness)
        let other = addTab(harness, url: "https://other.example")
        harness.viewModel.selectedTabID = loaded.id
        let executor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: harness.history,
            isCurrent: { harness.current.value },
            backendProvider: { .chatGPTPlan },
            evaluateScript: { _, script, _ in
                if script == BrowserAgentPageScript.documentIdentity {
                    harness.viewModel.selectedTabID = other.id
                    return #"{"nonce":"abc123"}"#
                }
                return #"{"ok":true}"#
            }
        )
        do {
            _ = try await executor.execute(.findText("alpha"), confirm: { _ in })
            XCTFail("Selection change during the nonce read must reject")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
    }

    func testSameURLNonceChangeRejects() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        var nonceReads = 0
        let executor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: harness.history,
            isCurrent: { harness.current.value },
            backendProvider: { .chatGPTPlan },
            evaluateScript: { _, script, _ in
                if script == BrowserAgentPageScript.documentIdentity {
                    nonceReads += 1
                    return #"{"nonce":"n\#(nonceReads)"}"#
                }
                return #"{"ok":true}"#
            },
            exportPDF: { _ in Data("%PDF-fake".utf8) }
        )
        do {
            _ = try await executor.execute(.exportPDF, confirm: { _ in })
            XCTFail("A same-URL reload must reject via nonce")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
        XCTAssertGreaterThanOrEqual(nonceReads, 2)
    }

    func testTranslatePredicateSurvivesExecutorRelease() async throws {
        let harness = try makeHarness()
        let (tab, webView) = try await loadPage(harness)
        var executor: BrowserIntentExecutor? = makeExecutor(harness).0
        let output = try await executor!.execute(.translate("pt"), confirm: { _ in })
        XCTAssertTrue(output.text.hasPrefix("Translation prepared"))
        executor = nil
        XCTAssertEqual(harness.recorded.translatePredicate?(), true)
        webView.reload()
        XCTAssertEqual(harness.recorded.translatePredicate?(), false)
        _ = tab
    }

    func testTranslateNonceChangeAfterCallbackInvalidatesPredicate() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let recorded = harness.recorded
        var nonceReads = 0
        var callbacks = makeCallbacks(recorded: recorded)
        callbacks.translatePage = { _, _, shouldContinue in
            recorded.translatePredicate = shouldContinue
        }
        let executor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: harness.history,
            isCurrent: { harness.current.value },
            backendProvider: { .chatGPTPlan },
            callbacks: callbacks,
            evaluateScript: { _, script, _ in
                if script == BrowserAgentPageScript.documentIdentity {
                    nonceReads += 1
                    return #"{"nonce":"n\#(nonceReads)"}"#
                }
                return #"{"ok":true}"#
            }
        )
        do {
            _ = try await executor.execute(.translate("pt"), confirm: { _ in })
            XCTFail("A nonce change after the translation callback must reject")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(recorded.translatePredicate?(), false)
    }

    func testTranslateCancellationInvalidatesPredicate() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let recorded = harness.recorded
        let entered = expectation(description: "translation callback entered")
        let release = expectation(description: "release translation callback")
        var callbacks = makeCallbacks(recorded: recorded)
        callbacks.translatePage = { _, _, shouldContinue in
            recorded.translatePredicate = shouldContinue
            entered.fulfill()
            await self.fulfillment(of: [release], timeout: 5)
        }
        let executor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: harness.history,
            isCurrent: { harness.current.value },
            backendProvider: { .chatGPTPlan },
            callbacks: callbacks,
            evaluateScript: { _, script, _ in
                script == BrowserAgentPageScript.documentIdentity
                    ? #"{"nonce":"abc123"}"#
                    : #"{"ok":true}"#
            }
        )
        let task = Task { @MainActor in
            try await executor.execute(.translate("pt"), confirm: { _ in })
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        release.fulfill()
        let result = await task.result
        switch result {
        case .success:
            XCTFail("Cancelled translation must not succeed")
        case .failure:
            break
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(recorded.translatePredicate?(), false)
    }
}

@MainActor
final class BrowserIntentsPrivacyGuardTests: BrowserIntentsExecutorTestCase {
    func testMidCaptureQuarantineRejectsScreenshot() async throws {
        let harness = try makeHarness()
        let (tab, webView) = try await loadPage(harness)
        let executor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: harness.history,
            isCurrent: { harness.current.value },
            backendProvider: { .chatGPTPlan },
            evaluateScript: { _, script, _ in
                script == BrowserAgentPageScript.documentIdentity
                    ? #"{"nonce":"abc123"}"#
                    : #"{"ok":true}"#
            },
            captureScreenshot: { _ in
                _ = harness.privacy.quarantineBeforeFill(
                    tabID: tab.id,
                    webView: webView,
                    runID: UUID(),
                    pageURL: webView.url,
                    documentNonce: "fixture-nonce",
                    profileValues: ["given_name": "SecretName"]
                )
                return Data("jpeg".utf8)
            }
        )
        do {
            _ = try await executor.execute(.screenshot, confirm: { _ in })
            XCTFail("A fill during capture must reject the result")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .privacyProtected)
        }
    }

    func testAskLocalCancelledGeneratorReturnsNoSuccess() async throws {
        let harness = try makeHarness()
        let entered = expectation(description: "generator started")
        let release = expectation(description: "release generator")
        let executor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: harness.history,
            isCurrent: { harness.current.value },
            backendProvider: { .localApple },
            aiGenerator: { _, _, _ in
                entered.fulfill()
                await self.fulfillment(of: [release], timeout: 5)
                return "late answer"
            }
        )
        let task = Task { @MainActor in
            try await executor.execute(.askLocal("q"), confirm: { _ in })
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        release.fulfill()
        let result = await task.result
        switch result {
        case .success:
            XCTFail("A cancelled request must not succeed")
        case .failure(let error):
            XCTAssertTrue(
                error is CancellationError || (error as? BrowserIntentError) == .stalePage
            )
        }
    }
}

@MainActor
final class BrowserIntentsCloseApprovalTests: BrowserIntentsExecutorTestCase {
    func testCloseTabModeFlipDuringApprovalRejects() async throws {
        let harness = try makeHarness()
        let first = addTab(harness, url: "https://one.example")
        _ = addTab(harness, url: "https://two.example")
        harness.viewModel.selectedTabID = first.id
        let (executor, _) = makeExecutor(harness)
        let mutate: BrowserIntentConfirmation = { _ in
            first.isIncognito = true
        }
        do {
            _ = try await executor.execute(.closeCurrentTab, confirm: mutate)
            XCTFail("A private-mode flip must reject the close")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
        XCTAssertEqual(harness.viewModel.tabs.count, 2)
    }

    func testCloseTabNavigationDuringApprovalRejects() async throws {
        let harness = try makeHarness()
        let (tab, webView) = try await loadPage(harness)
        _ = addTab(harness, url: "https://two.example")
        harness.viewModel.selectedTabID = tab.id
        let (executor, _) = makeExecutor(harness)
        let navigate: BrowserIntentConfirmation = { _ in
            webView.load(URLRequest(url: URL(string: "https://moved.example")!))
        }
        do {
            _ = try await executor.execute(.closeCurrentTab, confirm: navigate)
            XCTFail("Navigation during approval must reject the close")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
        XCTAssertEqual(harness.viewModel.tabs.count, 2)
    }

    func testCloseGroupMemberChangeRejectsAll() async throws {
        let harness = try makeHarness()
        let group = harness.viewModel.createTabGroup(title: "Work")
        let memberA = addTab(harness, url: "https://a.example", groupID: group.id)
        _ = addTab(harness, url: "https://b.example", groupID: group.id)
        _ = addTab(harness, url: "https://outside.example")
        let (executor, _) = makeExecutor(harness)
        let mutate: BrowserIntentConfirmation = { _ in
            memberA.groupID = nil
        }
        do {
            _ = try await executor.execute(.closeGroup(group.id), confirm: mutate)
            XCTFail("A membership change must reject the close")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
        XCTAssertEqual(harness.viewModel.tabs.count, 3)
    }

    func testCloseGroupMemberModeFlipRejectsAll() async throws {
        let harness = try makeHarness()
        let group = harness.viewModel.createTabGroup(title: "Work")
        _ = addTab(harness, url: "https://a.example", groupID: group.id)
        let memberB = addTab(harness, url: "https://b.example", groupID: group.id)
        _ = addTab(harness, url: "https://outside.example")
        let (executor, _) = makeExecutor(harness)
        let mutate: BrowserIntentConfirmation = { _ in
            memberB.webAIProvider = .gemini
        }
        do {
            _ = try await executor.execute(.closeGroup(group.id), confirm: mutate)
            XCTFail("A provider-mode flip must reject the close")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
        XCTAssertEqual(harness.viewModel.tabs.count, 3)
        XCTAssertEqual(harness.viewModel.tabs.filter { $0.groupID == group.id }.count, 2)
    }

    private func loadPage(
        in webView: AIWebView,
        baseURL: String
    ) async {
        let waiter = IntentLoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString("<html><body>p</body></html>", baseURL: URL(string: baseURL))
        }
    }

    func testCloseGroupMutationDuringFinalMemberNonceRejectsAll() async throws {
        let harness = try makeHarness()
        let group = harness.viewModel.createTabGroup(title: "Work")
        let memberA = addTab(harness, url: "https://a.example", groupID: group.id)
        let memberB = addTab(harness, url: "https://b.example", groupID: group.id)
        _ = addTab(harness, url: "https://outside.example")
        let webViewB = memberB.activateWebView()
        await loadPage(in: webViewB, baseURL: "https://b.example")
        let executor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: harness.history,
            isCurrent: { harness.current.value },
            backendProvider: { .chatGPTPlan },
            evaluateScript: { webView, script, _ in
                if script == BrowserAgentPageScript.documentIdentity {
                    if webView === webViewB {
                        memberA.groupID = nil
                    }
                    return #"{"nonce":"abc123"}"#
                }
                return #"{"ok":true}"#
            }
        )
        do {
            _ = try await executor.execute(.closeGroup(group.id), confirm: { _ in })
            XCTFail("A membership change during the last nonce read must reject")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
        XCTAssertEqual(harness.viewModel.tabs.count, 3)
        XCTAssertNotNil(harness.viewModel.tabGroups.first(where: { $0.id == group.id }))
    }

    func testCloseGroupDeletionDuringFinalMemberNonceRejectsAll() async throws {
        let harness = try makeHarness()
        let group = harness.viewModel.createTabGroup(title: "Work")
        _ = addTab(harness, url: "https://a.example", groupID: group.id)
        let memberB = addTab(harness, url: "https://b.example", groupID: group.id)
        _ = addTab(harness, url: "https://outside.example")
        let webViewB = memberB.activateWebView()
        await loadPage(in: webViewB, baseURL: "https://b.example")
        let executor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: harness.history,
            isCurrent: { harness.current.value },
            backendProvider: { .chatGPTPlan },
            evaluateScript: { webView, script, _ in
                if script == BrowserAgentPageScript.documentIdentity {
                    if webView === webViewB {
                        harness.viewModel.deleteTabGroup(group)
                    }
                    return #"{"nonce":"abc123"}"#
                }
                return #"{"ok":true}"#
            }
        )
        do {
            _ = try await executor.execute(.closeGroup(group.id), confirm: { _ in })
            XCTFail("Deleting the group during the last nonce read must reject")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
        XCTAssertEqual(harness.viewModel.tabs.count, 3)
    }

}
