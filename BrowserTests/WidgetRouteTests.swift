import XCTest
@testable import Browser

/// Phase 8 routes: the widget and control links `webmebrowser://private-tab`, `webmebrowser://search-clipboard`
/// and `webmebrowser://saved-task?id=<UUID>`, plus checks that the existing routes keep their precedence.
@MainActor
final class WidgetRouteTests: XCTestCase {
    private let taskID = UUID(uuidString: "6F1E2D3C-4B5A-4978-8A6B-0C1D2E3F4A5B")!

    private func url(_ string: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        try XCTUnwrap(URL(string: string), "Invalid test URL \(string)", file: file, line: line)
    }

    private func assertControlRejected(_ string: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let parsed = try url(string, file: file, line: line)
        XCTAssertThrowsError(try AgentControlURLParser.parse(parsed), "Accepted \(string)", file: file, line: line)
        XCTAssertThrowsError(try AgentIncomingURLRouter.route(parsed), "Router accepted \(string)", file: file, line: line)
    }

    // MARK: - Valid forms

    func testPrivateTabAcceptsOnlyTheBareLink() throws {
        let link = try url("webmebrowser://private-tab")
        XCTAssertEqual(try AgentControlURLParser.parse(link), .privateTab)
        XCTAssertEqual(try AgentIncomingURLRouter.route(link), .privateTab)

        let trailingSlash = try url("webmebrowser://private-tab/")
        XCTAssertEqual(try AgentControlURLParser.parse(trailingSlash), .privateTab)
    }

    func testSearchClipboardAcceptsOnlyTheBareLink() throws {
        let link = try url("webmebrowser://search-clipboard")
        XCTAssertEqual(try AgentControlURLParser.parse(link), .searchClipboard)
        XCTAssertEqual(try AgentIncomingURLRouter.route(link), .searchClipboard)
    }

    func testSavedTaskAcceptsExactlyOneUUID() throws {
        let link = try url("webmebrowser://saved-task?id=\(taskID.uuidString)")
        XCTAssertEqual(try AgentControlURLParser.parse(link), .savedTask(taskID))
        XCTAssertEqual(try AgentIncomingURLRouter.route(link), .savedTask(taskID))

        let lowercase = try url("webmebrowser://saved-task?id=\(taskID.uuidString.lowercased())")
        XCTAssertEqual(try AgentControlURLParser.parse(lowercase), .savedTask(taskID))
    }

    func testControlHostsAreMatchedCaseInsensitively() throws {
        XCTAssertEqual(try AgentControlURLParser.parse(try url("webmebrowser://PRIVATE-TAB")), .privateTab)
        XCTAssertEqual(try AgentControlURLParser.parse(try url("WEBMEBROWSER://Search-Clipboard")), .searchClipboard)
    }

    // MARK: - Malformed forms on the control hosts

    func testPrivateTabAndSearchClipboardRejectAnyQuery() throws {
        for string in [
            "webmebrowser://private-tab?",
            "webmebrowser://private-tab?text=hello",
            "webmebrowser://private-tab?id=\(taskID.uuidString)",
            "webmebrowser://search-clipboard?",
            "webmebrowser://search-clipboard?text=hello",
            "webmebrowser://search-clipboard?submit=1"
        ] {
            try assertControlRejected(string)
        }
    }

    func testSavedTaskRejectsMissingDuplicateAndMalformedIDs() throws {
        let missing = try url("webmebrowser://saved-task")
        XCTAssertThrowsError(try AgentControlURLParser.parse(missing)) { error in
            XCTAssertEqual(error as? AgentControlURLParseError, .missingSavedTaskID)
        }
        XCTAssertThrowsError(try AgentIncomingURLRouter.route(missing))

        for string in [
            "webmebrowser://saved-task?",
            "webmebrowser://saved-task?id=",
            "webmebrowser://saved-task?id=not-a-uuid",
            "webmebrowser://saved-task?id=\(taskID.uuidString)X",
            "webmebrowser://saved-task?ID=\(taskID.uuidString)",
            "webmebrowser://saved-task?id=\(taskID.uuidString)&id=\(taskID.uuidString)",
            "webmebrowser://saved-task?id=\(taskID.uuidString)&extra=1",
            "webmebrowser://saved-task?extra=1"
        ] {
            try assertControlRejected(string)
        }
    }

    func testControlLinksRejectPathUserPortAndFragment() throws {
        for string in [
            "webmebrowser://private-tab/extra",
            "webmebrowser://search-clipboard/extra",
            "webmebrowser://saved-task/extra?id=\(taskID.uuidString)",
            "webmebrowser://user@private-tab",
            "webmebrowser://user@saved-task?id=\(taskID.uuidString)",
            "webmebrowser://private-tab:8080",
            "webmebrowser://saved-task:8080?id=\(taskID.uuidString)",
            "webmebrowser://private-tab#fragment",
            "webmebrowser://saved-task?id=\(taskID.uuidString)#fragment"
        ] {
            try assertControlRejected(string)
        }
    }

    // MARK: - Recognition and precedence

    func testIsControlURLRecognizesMalformedLinksOnlyOnTheThreeHosts() throws {
        XCTAssertTrue(AgentControlURLParser.isControlURL(try url("webmebrowser://private-tab?x=1")))
        XCTAssertTrue(AgentControlURLParser.isControlURL(try url("webmebrowser://saved-task")))
        XCTAssertFalse(AgentControlURLParser.isControlURL(try url("webmebrowser://private")))
        XCTAssertFalse(AgentControlURLParser.isControlURL(try url("webmebrowser://share?text=private-tab")))
        XCTAssertFalse(AgentControlURLParser.isControlURL(try url("https://example.com/private-tab")))
    }

    func testExistingRoutesKeepTheirPrecedenceAndUnrelatedHostsAreUnchanged() throws {
        let runID = UUID()
        XCTAssertEqual(try AgentIncomingURLRouter.route(try url("webmebrowser://run?id=\(runID.uuidString)")), .run(runID))
        XCTAssertEqual(try AgentIncomingURLRouter.route(try url("webmebrowser://watch?id=\(runID.uuidString)")), .pageWatch(runID))
        XCTAssertEqual(
            try AgentIncomingURLRouter.route(try url("webmebrowser://share?text=hello")),
            .sharedText("hello")
        )
        XCTAssertEqual(try AgentIncomingURLRouter.route(try url("webmebrowser://private")), .sharedPayload)
        XCTAssertEqual(
            try AgentIncomingURLRouter.route(try url("https://example.com/saved-task?id=\(taskID.uuidString)")),
            .defaultBrowserLink(try url("https://example.com/saved-task?id=\(taskID.uuidString)"))
        )
        let agentLink = try url("webmebrowser://agent?task=Find%20prices")
        guard case .agentTask = try AgentIncomingURLRouter.route(agentLink) else {
            return XCTFail("The agent route changed")
        }
    }

    // MARK: - Navigation from web pages

    func testWidgetControlLinksAreCancelledForWebPageNavigation() throws {
        XCTAssertTrue(BrowserExternalNavigationPolicy.shouldCancelWidgetControlLink(try url("webmebrowser://private-tab")))
        XCTAssertTrue(BrowserExternalNavigationPolicy.shouldCancelWidgetControlLink(try url("webmebrowser://search-clipboard")))
        XCTAssertTrue(BrowserExternalNavigationPolicy.shouldCancelWidgetControlLink(try url("webmebrowser://saved-task?id=\(taskID.uuidString)")))
        XCTAssertFalse(BrowserExternalNavigationPolicy.shouldCancelWidgetControlLink(try url("webmebrowser://watch?id=\(taskID.uuidString)")))
        XCTAssertFalse(BrowserExternalNavigationPolicy.shouldCancelWidgetControlLink(try url("https://example.com/private-tab")))
        XCTAssertFalse(BrowserExternalNavigationPolicy.shouldCancelWidgetControlLink(nil))
    }

    // MARK: - Saved-task handoff and messages

    func testSavedTaskRequestMatchesRunSavedTaskEnqueueing() throws {
        let startURL = try url("https://example.test/start")
        let task = SavedAgentTask(id: taskID, title: "Daily report", task: "Summarize the report", startURL: startURL)
        let request = AgentControlURLParser.pendingRequest(for: task)
        XCTAssertEqual(request.task, "Summarize the report")
        XCTAssertEqual(request.startURL, startURL)
        XCTAssertEqual(request.savedTaskID, taskID)
    }

    func testUserFacingMessagesForControlFailures() {
        XCTAssertEqual(AgentControlURLParser.missingSavedTaskMessage, "That saved task no longer exists.")
        XCTAssertEqual(AgentControlURLParseError.malformedControlURL.errorDescription, "The Vortyra control link is malformed.")
        XCTAssertFalse(AgentControlURLParseError.missingSavedTaskID.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(AgentControlURLParser.emptyClipboardMessage.isEmpty)
        XCTAssertFalse(AgentControlURLParser.unsearchableClipboardMessage.isEmpty)
    }
}
