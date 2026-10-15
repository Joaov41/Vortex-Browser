import XCTest
@testable import Browser

@MainActor
final class AgentTaskNavigationTests: XCTestCase {
    func testRequestedNavigationIgnoresOldCancellationAndAcceptsItsRedirectedFinish() throws {
        let request = PendingAgentTask(
            task: "Read the page",
            startURL: try XCTUnwrap(URL(string: "http://127.0.0.1:60353/redirect"))
        )
        let tabID = UUID()
        let webView = NSObject()
        let oldNavigation = NSObject()
        let requestedNavigation = NSObject()
        var chain = try AgentTaskNavigationChain(request: request, tabID: tabID, webView: webView)

        XCTAssertTrue(chain.bind(navigation: requestedNavigation))
        XCTAssertEqual(
            chain.receive(.failed, tabID: tabID, webView: webView, navigation: oldNavigation,
                          finalURL: nil, isLoading: false),
            .waiting,
            "A cancelled navigation from the old page must not defeat the bound task load."
        )
        XCTAssertEqual(
            chain.receive(.started, tabID: tabID, webView: webView, navigation: requestedNavigation,
                          finalURL: nil, isLoading: true),
            .waiting
        )
        XCTAssertEqual(
            chain.receive(.committed, tabID: tabID, webView: webView, navigation: requestedNavigation,
                          finalURL: URL(string: "http://127.0.0.1:60353/landing"), isLoading: true),
            .waiting
        )
        XCTAssertEqual(
            chain.receive(.finished, tabID: tabID, webView: webView, navigation: requestedNavigation,
                          finalURL: URL(string: "http://127.0.0.1:60353/landing"), isLoading: false),
            .completed,
            "A redirect within the exact bound WKNavigation remains a valid start."
        )
    }

    func testNewNavigationAndChangedContextRejectThePreparedStart() throws {
        let request = PendingAgentTask(
            task: "Read the page",
            startURL: try XCTUnwrap(URL(string: "https://example.test/start"))
        )
        let tabID = UUID()
        let webView = NSObject()
        let expectedNavigation = NSObject()
        let supersedingNavigation = NSObject()
        var superseded = try AgentTaskNavigationChain(request: request, tabID: tabID, webView: webView)
        XCTAssertTrue(superseded.bind(navigation: expectedNavigation))
        XCTAssertEqual(
            superseded.receive(.started, tabID: tabID, webView: webView, navigation: supersedingNavigation,
                               finalURL: nil, isLoading: true),
            .failed("Another page navigation replaced the requested starting page.")
        )

        var changedTab = try AgentTaskNavigationChain(request: request, tabID: tabID, webView: webView)
        XCTAssertTrue(changedTab.bind(navigation: NSObject()))
        XCTAssertEqual(
            changedTab.receive(.finished, tabID: UUID(), webView: webView, navigation: NSObject(),
                               finalURL: URL(string: "https://example.test/start"), isLoading: false),
            .failed("The browser tab changed before the starting page finished loading.")
        )
    }

    func testPreparedContextRejectsSameURLReplacementTabLoadingOrInactiveDispatch() throws {
        let requestID = UUID()
        let tabID = UUID()
        let webView = NSObject()
        let url = try XCTUnwrap(URL(string: "https://example.test/page"))
        let context = AgentTaskPreparedContext(
            requestID: requestID,
            tabID: tabID,
            webView: webView,
            finalURL: url,
            documentRevision: 4,
            navigation: NSObject()
        )

        func matches(
            requestID: UUID,
            tabID: UUID,
            webView: AnyObject,
            currentURL: URL?,
            revision: Int,
            isLoading: Bool,
            foregroundReady: Bool
        ) -> Bool {
            context.matches(
                requestID: requestID,
                tabID: tabID,
                webView: webView,
                currentURL: currentURL,
                documentRevision: revision,
                isLoading: isLoading,
                isForegroundReady: foregroundReady
            )
        }

        XCTAssertTrue(matches(
            requestID: requestID, tabID: tabID, webView: webView, currentURL: url,
            revision: 4, isLoading: false, foregroundReady: true
        ))
        XCTAssertFalse(matches(
            requestID: requestID, tabID: tabID, webView: NSObject(), currentURL: url,
            revision: 4, isLoading: false, foregroundReady: true
        ), "A replaced WebView cannot reuse a completed load.")
        XCTAssertFalse(matches(
            requestID: requestID, tabID: UUID(), webView: webView, currentURL: url,
            revision: 4, isLoading: false, foregroundReady: true
        ), "A changed tab cannot reuse the prepared context.")
        XCTAssertFalse(matches(
            requestID: requestID, tabID: tabID, webView: webView, currentURL: url,
            revision: 5, isLoading: false, foregroundReady: true
        ), "A same-URL replacement document increments the revision.")
        XCTAssertFalse(matches(
            requestID: requestID, tabID: tabID, webView: webView,
            currentURL: URL(string: "https://example.test/other"),
            revision: 4, isLoading: false, foregroundReady: true
        ))
        XCTAssertFalse(matches(
            requestID: requestID, tabID: tabID, webView: webView, currentURL: url,
            revision: 4, isLoading: true, foregroundReady: true
        ))
        XCTAssertFalse(matches(
            requestID: requestID, tabID: tabID, webView: webView, currentURL: url,
            revision: 4, isLoading: false, foregroundReady: false
        ), "An inactive window cannot dispatch after finish.")
    }

    func testStartedRequestAcknowledgementRemovesNoURLHeadExactlyOnce() {
        let first = PendingAgentTask(task: "Read current page")
        let second = PendingAgentTask(task: "Read the next page")
        var pending = [first, second]
        var staged: PendingAgentTask? = first
        var isBusy = false

        let firstAcknowledged = AgentTaskWindowQueuePolicy.acknowledgeStarted(
            requestID: first.id, pending: &pending, staged: &staged, isBusy: &isBusy
        )
        XCTAssertTrue(firstAcknowledged)
        XCTAssertEqual(pending, [second])
        XCTAssertNil(staged)
        XCTAssertTrue(isBusy)
        let staleAcknowledgement = AgentTaskWindowQueuePolicy.acknowledgeStarted(
            requestID: first.id, pending: &pending, staged: &staged, isBusy: &isBusy
        )
        XCTAssertFalse(staleAcknowledgement, "A stale duplicate acknowledgement cannot remove the next task.")

        isBusy = false
        staged = pending.first
        let secondAcknowledged = AgentTaskWindowQueuePolicy.acknowledgeStarted(
            requestID: second.id, pending: &pending, staged: &staged, isBusy: &isBusy
        )
        XCTAssertTrue(secondAcknowledged)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertNil(staged)
    }

    func testDeferredRestorationLoadCannotReplaceChangedOrTaskOwnedNavigation() throws {
        let original = try XCTUnwrap(URL(string: "https://example.test/restored"))
        XCTAssertTrue(AgentTaskWebViewLoadPolicy.shouldStartRestorationLoad(
            requestedURL: original,
            currentTabURL: original,
            isLoading: false,
            agentOwnsLoad: false
        ))
        XCTAssertFalse(AgentTaskWebViewLoadPolicy.shouldStartRestorationLoad(
            requestedURL: original,
            currentTabURL: original,
            isLoading: false,
            agentOwnsLoad: true
        ))
        XCTAssertFalse(AgentTaskWebViewLoadPolicy.shouldStartRestorationLoad(
            requestedURL: original,
            currentTabURL: URL(string: "https://example.test/new-task"),
            isLoading: false,
            agentOwnsLoad: false
        ))
        XCTAssertFalse(AgentTaskWebViewLoadPolicy.shouldStartRestorationLoad(
            requestedURL: original,
            currentTabURL: original,
            isLoading: true,
            agentOwnsLoad: false
        ))
    }

    func testCancelledInitialAgentNavigationHasNoBrowserSideEffects() throws {
        let suiteName = "BrowserTests.AgentTaskNavigation.InitialCancel.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated browser preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewModel = BrowserViewModel(userDefaults: defaults)
        guard let selectedTab = viewModel.tabs.first else {
            return XCTFail("Expected the initial browser tab")
        }
        let targetURL = try XCTUnwrap(URL(string: "https://task-start.example/article"))
        let targetTab = BrowserTab(title: "Existing page", url: URL(string: "https://existing.example/page"))
        viewModel.tabs.append(targetTab)
        viewModel.updateProtectedTabIDs([selectedTab.id])
        let webView = targetTab.activateWebView()
        XCTAssertTrue(viewModel.evictionCandidateIDs().contains(targetTab.id))
        viewModel.saveSession()
        let sessionBefore = defaults.data(forKey: "browser_session_v1")
        let candidatesBefore = viewModel.evictionCandidateIDs()

        var navigationStarted = false
        var failures: [String] = []
        viewModel.navigateForAgentTask(
            to: targetURL,
            in: targetTab,
            shouldProceed: { false },
            onNavigationStarted: { _, _, _ in navigationStarted = true },
            onFailure: { failures.append($0) }
        )

        XCTAssertEqual(targetTab.url, URL(string: "https://existing.example/page"))
        XCTAssertEqual(targetTab.address, "https://existing.example/page")
        XCTAssertTrue(targetTab.liveWebView === webView)
        XCTAssertNil(webView.url, "The cancelled request must not start a WebKit load.")
        XCTAssertFalse(webView.isLoading)
        XCTAssertFalse(navigationStarted)
        XCTAssertEqual(failures, ["The browser changed before the requested starting page could load."])
        XCTAssertEqual(viewModel.evictionCandidateIDs(), candidatesBefore,
                       "Cancellation must not alter the tab's protected/unprotected status.")
        XCTAssertEqual(defaults.data(forKey: "browser_session_v1"), sessionBefore,
                       "Cancellation must not persist the requested URL or other session metadata.")
    }

    func testRealCloudShortcutCallbackRouteKeepsExistingURLPrecedence() throws {
        let requestID = UUID()
        let callback = try XCTUnwrap(CloudShortcutCallbackPolicy.callbackURL(path: "success", requestID: requestID))
        let cloudOutcome = CloudShortcutCallbackPolicy.outcome(from: callback, expectedRequestID: requestID)
        XCTAssertEqual(cloudOutcome, .success(nil))
        let existingCloudHandlerAcceptedCallback = cloudOutcome != nil
        let routedCallback = try AgentIncomingURLRouter.route(
            callback,
            cloudShortcutWasHandled: existingCloudHandlerAcceptedCallback
        )
        XCTAssertEqual(routedCallback, .cloudShortcut(callback))
        let webURL = try XCTUnwrap(URL(string: "https://example.test/"))
        let routedWebURL = try AgentIncomingURLRouter.route(webURL, cloudShortcutWasHandled: true)
        XCTAssertEqual(routedWebURL, .defaultBrowserLink(webURL))
    }
}
