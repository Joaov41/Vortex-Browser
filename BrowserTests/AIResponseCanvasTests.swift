import XCTest
@testable import Browser

final class AIResponseCanvasTests: XCTestCase {
    func testParsesMarkdownTableWithAlignmentAndEscapedPipe() {
        let document = AIResponseDocumentParser.parse(
            """
            # Results

            | Name | Status | Notes |
            | :--- | :----: | ----: |
            | Alpha | Ready | A \\| B |
            | Beta | Waiting | 2 |
            """
        )

        guard case .table(_, let table) = document.blocks.last else {
            return XCTFail("Expected the final block to be a table")
        }
        XCTAssertEqual(table.headers, ["Name", "Status", "Notes"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[0], ["Alpha", "Ready", "A | B"])
        XCTAssertEqual(table.alignments.count, 3)
    }

    func testCodeFenceContainingPipesIsNotParsedAsTable() {
        let document = AIResponseDocumentParser.parse(
            """
            ```swift
            let value = left | right
            | not | a table |
            | --- | ------- |
            ```
            """
        )

        XCTAssertEqual(document.blocks.count, 1)
        guard case .code(_, let language, let text) = document.blocks[0] else {
            return XCTFail("Expected a code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(text.contains("not | a table"))
    }

    func testRichReplyAutomaticallyUsesCanvas() {
        let message = ChatMessage(
            role: .assistant,
            text: """
            | Feature | State |
            | --- | --- |
            | Canvas | Ready |
            """
        )

        let presentation = AIResponseCanvasPresentation(message: message)
        XCTAssertTrue(presentation.shouldAutoPresent)
        XCTAssertEqual(presentation.sidebarSummary, "Table reply")
    }

    func testShortPlainReplyStaysInSidebar() {
        let message = ChatMessage(role: .assistant, text: "A short answer.")
        let presentation = AIResponseCanvasPresentation(message: message)
        XCTAssertFalse(presentation.shouldAutoPresent)
    }

    func testInlineMarkdownRemovesSyntaxWhilePreservingContent() {
        let rendered = AIResponseMarkdown.inline("**Ready** with *Markdown* and `code`.")
        XCTAssertEqual(String(rendered.characters), "Ready with Markdown and code.")
    }

    func testPrivacyHostNormalization() {
        XCTAssertEqual(
            SitePrivacyStore.shared.host(for: URL(string: "https://www.example.com/path")),
            "example.com"
        )
    }

    func testTabGroupsAndSessionRestoreWithoutUsingAppPreferences() {
        let suiteName = "BrowserTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let original = BrowserViewModel(userDefaults: defaults)
        let group = original.createTabGroup(title: "Research")
        guard let tab = original.tabs.first else {
            return XCTFail("Expected an initial tab")
        }
        original.move(tab, to: group.id)
        original.saveSession()

        let restored = BrowserViewModel(userDefaults: defaults)
        XCTAssertEqual(restored.tabGroups, [group])
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs.first?.groupID, group.id)
        XCTAssertEqual(restored.selectedTabID, restored.tabs.first?.id)
    }

    func testDuckDuckGoSelectionControlsNewTabsAndTypedSearches() {
        let suiteName = "BrowserTests.SearchEngine.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let original = BrowserViewModel(userDefaults: defaults)
        original.defaultSearchEngine = .duckDuckGo
        original.addTabBlank()

        XCTAssertEqual(original.tabs.last?.url?.host, "duckduckgo.com")

        guard let searchURL = original.destinationURL(from: "private web search"),
              let components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false) else {
            return XCTFail("Expected a DuckDuckGo search URL")
        }
        XCTAssertEqual(components.host, "duckduckgo.com")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "q" })?.value,
            "private web search"
        )

        let restored = BrowserViewModel(userDefaults: defaults)
        XCTAssertEqual(restored.defaultSearchEngine, .duckDuckGo)
    }

    func testGoogleRemainsTheDefaultSearchRoute() {
        let suiteName = "BrowserTests.GoogleSearch.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewModel = BrowserViewModel(userDefaults: defaults)
        guard let searchURL = viewModel.destinationURL(from: "browser news"),
              let components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false) else {
            return XCTFail("Expected a Google search URL")
        }

        XCTAssertEqual(viewModel.defaultSearchEngine, .google)
        XCTAssertEqual(components.host, "www.google.com")
        XCTAssertEqual(components.path, "/search")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "browser news")
    }

    func testRedditRetryPolicyRetriesOnlyTransientFailures() {
        XCTAssertTrue(RedditExtractionRetryPolicy.shouldRetry(RedditExtractionError.timedOut))
        XCTAssertTrue(RedditExtractionRetryPolicy.shouldRetry(URLError(.networkConnectionLost)))
        XCTAssertTrue(RedditExtractionRetryPolicy.shouldRetry(RedditAPIError.rateLimited(retryAfter: 1)))
        XCTAssertTrue(RedditExtractionRetryPolicy.shouldRetry(RedditAPIError.httpError(statusCode: 503, message: nil)))
        XCTAssertFalse(RedditExtractionRetryPolicy.shouldRetry(RedditAPIError.contentDeleted))
        XCTAssertFalse(RedditExtractionRetryPolicy.shouldRetry(RedditAPIError.privateSubreddit))
        XCTAssertFalse(RedditExtractionRetryPolicy.shouldRetry(RedditAPIError.postNotFound))
    }

    func testRedditReplyDepthMarkerAndStableCommentIdentity() {
        XCTAssertEqual(RedditCommentFormatting.depthMarker(for: 0), "")
        XCTAssertEqual(RedditCommentFormatting.depthMarker(for: 2), "[reply depth 2] ")
        XCTAssertEqual(
            RedditCommentFormatting.stableIdentifier(from: ["name": "t1_first", "id": "first"]),
            "t1_first"
        )
        XCTAssertEqual(
            RedditCommentFormatting.stableIdentifier(from: ["id": "second"]),
            "second"
        )
        XCTAssertNil(RedditCommentFormatting.stableIdentifier(from: ["author": "user"]))
    }

    func testRedditPlannerUsesProviderBudgetsAndKeepsEveryComment() {
        let comments = (0..<7).map { index in
            "u/user\(index): comment-\(index)-\(String(repeating: "x", count: 380))"
        }
        let content = """
        Body:
        Reddit coverage: extracted 7 accessible comments (reported 7; complete extraction)
        📌 A thread

        --- Comments ---
        \(comments.joined(separator: "\n"))
        """

        let localPlan = RedditSummaryPlanner.plan(content: content, backend: .localApple)
        XCTAssertEqual(localPlan.characterBudget, 1_100)
        XCTAssertEqual(localPlan.totalCommentCount, comments.count)
        XCTAssertGreaterThan(localPlan.chunks.count, 1)
        let reconstructed = localPlan.chunks.map(\.text).joined(separator: "\n")
        for comment in comments {
            XCTAssertTrue(reconstructed.contains(comment), "Missing comment: \(comment.prefix(24))")
        }
        XCTAssertEqual(RedditSummaryPlanner.characterBudget(for: .mlxLocal), 8_000)
        XCTAssertEqual(RedditSummaryPlanner.characterBudget(for: .applePCCGateway), 80_000)
        XCTAssertEqual(RedditSummaryPlanner.characterBudget(for: .webChatGPT), 76_000)
    }

    func testRedditReductionGroupsRetainAllPartialSummaries() {
        let partials = (0..<25).map {
            "partial-\($0)-unique-evidence-\(String(repeating: "evidence ", count: 55))"
        }
        let groups = RedditSummaryPlanner.reductionGroups(partials, backend: .localApple)
        XCTAssertGreaterThan(groups.count, 1)
        XCTAssertLessThan(groups.count, partials.count)
        let all = groups.joined().joined(separator: "\n")
        for partial in partials {
            XCTAssertTrue(all.contains(partial), "Missing partial: \(partial)")
        }
        XCTAssertEqual(RedditSummaryPlanner.reductionCharacterBudget(for: .localApple), 8_000)
    }

    func testRedditWebCompactionSamplesFirstMiddleAndFinalComments() {
        let comments = (0..<9).map { index in
            "u/user\(index): evidence-\(index)-\(String(repeating: "detail ", count: 32))"
        }
        let content = """
        Title: A thread

        Body:
        Reddit coverage: extracted 9 accessible comments (reported 9; complete extraction)

        --- Comments ---
        \(comments.joined(separator: "\n"))
        """

        let compacted = RedditSummaryPlanner.webSafeContext(content: content, maxCharacters: 1_200)
        XCTAssertLessThanOrEqual(compacted.count, 1_200)
        XCTAssertTrue(compacted.contains("Reddit coverage: extracted 9 accessible comments"))
        XCTAssertTrue(compacted.contains("evidence-0-"), "First comment was omitted")
        XCTAssertTrue(compacted.contains("evidence-4-"), "Middle comment was omitted")
        XCTAssertTrue(compacted.contains("evidence-8-"), "Final comment was omitted")
        XCTAssertTrue(compacted.contains("web context compacted"))

        let ordinaryText = "An ordinary article with no Reddit markers."
        XCTAssertEqual(
            RedditSummaryPlanner.webSafeContext(content: ordinaryText, maxCharacters: 8),
            ordinaryText,
            "Non-Reddit context must remain untouched by the Reddit helper"
        )
    }

    func testRedditCoverageMetadataReportsPartialExtractionHonestly() {
        let metadata = RedditCoverageMetadata(
            expectedCommentCount: 100,
            accessibleCommentCount: 42,
            discoveredMoreCommentIDs: 58,
            moreRequestsAttempted: 3,
            extractionComplete: false,
            hitSafetyLimit: true,
            hitMoreRequestLimit: false,
            hadFetchFailures: false
        )
        XCTAssertTrue(metadata.statusText.contains("42 accessible comments"))
        XCTAssertTrue(metadata.statusText.contains("of 100 reported"))
        XCTAssertTrue(metadata.statusText.contains("partial"))
        XCTAssertTrue(metadata.contextDescription.contains("partial extraction"))
    }
}
