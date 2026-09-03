import XCTest
import WebKit
@testable import Browser

final class AIResponseCanvasTests: XCTestCase {
    func testAIPanelIncidentalDismissalIsBlockedOnlyWhileProcessing() {
        XCTAssertTrue(
            AIPanelDismissalPolicy.allowsDismissal(
                isProcessing: false,
                isExplicitCancellation: false
            )
        )
        XCTAssertFalse(
            AIPanelDismissalPolicy.allowsDismissal(
                isProcessing: true,
                isExplicitCancellation: false
            )
        )
        XCTAssertTrue(
            AIPanelDismissalPolicy.allowsDismissal(
                isProcessing: true,
                isExplicitCancellation: true
            )
        )
    }

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

    func testRedditReplyNeverAutomaticallyUsesCanvas() {
        let message = ChatMessage(
            role: .assistant,
            text: """
            Reddit summary coverage: summarized 46 accessible comments across 12 parts.

            | Theme | Consensus |
            | --- | --- |
            | Reliability | The comments contain a long, richly formatted synthesis. |
            """ + String(repeating: " Additional Reddit detail.", count: 80)
        )

        let presentation = AIResponseCanvasPresentation(message: message)
        XCTAssertTrue(presentation.isRedditReply)
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

    func testIPhoneCancelsOnlyXAppDeepLinks() {
        XCTAssertTrue(
            BrowserExternalNavigationPolicy.shouldCancelXAppDeepLink(
                URL(string: "x://timeline"),
                idiom: .phone
            )
        )
        XCTAssertTrue(
            BrowserExternalNavigationPolicy.shouldCancelXAppDeepLink(
                URL(string: "twitter://user?screen_name=example"),
                idiom: .phone
            )
        )
        XCTAssertFalse(
            BrowserExternalNavigationPolicy.shouldCancelXAppDeepLink(
                URL(string: "https://x.com/example"),
                idiom: .phone
            )
        )
        XCTAssertFalse(
            BrowserExternalNavigationPolicy.shouldCancelXAppDeepLink(
                URL(string: "mailto:test@example.com"),
                idiom: .phone
            )
        )
        XCTAssertFalse(
            BrowserExternalNavigationPolicy.shouldCancelXAppDeepLink(
                URL(string: "twitter://timeline"),
                idiom: .pad
            )
        )
    }

    func testIPhoneForcesLinkActivatedXHTTPSNavigationIntoWebView() {
        XCTAssertTrue(
            BrowserExternalNavigationPolicy.shouldForceXHTTPSNavigationInWebView(
                URL(string: "https://x.com/?lang=pt"),
                idiom: .phone,
                navigationType: .linkActivated
            )
        )
        XCTAssertTrue(
            BrowserExternalNavigationPolicy.shouldForceXHTTPSNavigationInWebView(
                URL(string: "https://mobile.twitter.com/example"),
                idiom: .phone,
                navigationType: .linkActivated
            )
        )
        XCTAssertFalse(
            BrowserExternalNavigationPolicy.shouldForceXHTTPSNavigationInWebView(
                URL(string: "https://x.com/?lang=pt"),
                idiom: .phone,
                navigationType: .other
            )
        )
        XCTAssertFalse(
            BrowserExternalNavigationPolicy.shouldForceXHTTPSNavigationInWebView(
                URL(string: "https://x.com/?lang=pt"),
                idiom: .pad,
                navigationType: .linkActivated
            )
        )
        XCTAssertFalse(
            BrowserExternalNavigationPolicy.shouldForceXHTTPSNavigationInWebView(
                URL(string: "https://x.com.example.com/"),
                idiom: .phone,
                navigationType: .linkActivated
            )
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

    func testProtectedSiteTopContentInsetsAreDeviceAndHostScoped() {
        XCTAssertEqual(
            BrowserSiteViewportPolicy.topContentInset(
                for: URL(string: "https://www.reddit.com/r/AppleWatch/comments/example"),
                idiom: .pad
            ),
            12
        )
        XCTAssertEqual(
            BrowserSiteViewportPolicy.topContentInset(
                for: URL(string: "https://old.reddit.com/r/AppleWatch"),
                idiom: .pad
            ),
            12
        )
        XCTAssertEqual(
            BrowserSiteViewportPolicy.topContentInset(
                for: URL(string: "https://www.reddit.com/r/AppleWatch"),
                idiom: .phone
            ),
            24
        )
        XCTAssertEqual(
            BrowserSiteViewportPolicy.topContentInset(
                for: URL(string: "https://x.com/home"),
                idiom: .pad
            ),
            12
        )
        XCTAssertEqual(
            BrowserSiteViewportPolicy.topContentInset(
                for: URL(string: "https://x.com/home"),
                idiom: .phone
            ),
            24
        )
        XCTAssertEqual(
            BrowserSiteViewportPolicy.topContentInset(
                for: URL(string: "https://mobile.twitter.com/home"),
                idiom: .phone
            ),
            24
        )
        XCTAssertEqual(
            BrowserSiteViewportPolicy.topContentInset(
                for: URL(string: "https://example.com"),
                idiom: .pad
            ),
            0
        )
        XCTAssertEqual(
            BrowserSiteViewportPolicy.topContentInset(
                for: URL(string: "https://notreddit.com/r/AppleWatch"),
                idiom: .phone
            ),
            0
        )
        XCTAssertEqual(
            BrowserSiteViewportPolicy.topContentInset(
                for: URL(string: "https://x.com.evil.example/home"),
                idiom: .phone
            ),
            0
        )
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

    func testRedditPlannerUsesAppleLocalSevenThousandTokenWindow() {
        let comments = (0..<50).map { index in
            "u/user\(index): comment-\(index)-evidence"
        }
        let content = """
        Body:
        Reddit coverage: extracted 50 accessible comments (reported 50; complete extraction)
        📌 A thread

        --- Comments ---
        \(comments.joined(separator: "\n"))
        """

        let localPlan = RedditSummaryPlanner.plan(content: content, backend: .localApple)
        XCTAssertEqual(localPlan.characterBudget, 18_750)
        XCTAssertEqual(RedditSummaryPlanner.reductionCharacterBudget(for: .localApple), 18_750)
        XCTAssertEqual(localPlan.totalCommentCount, comments.count)
        XCTAssertEqual(localPlan.chunks.count, 1)
        XCTAssertTrue(RedditSummaryPlanner.shouldUseSingleGeneration(plan: localPlan, backend: .localApple))
        XCTAssertFalse(RedditSummaryPlanner.shouldUseSingleGeneration(plan: localPlan, backend: .mlxLocal))
        XCTAssertFalse(
            RedditSummaryPlanner.requiresAppleLocalMultiPassPreflight(
                content: content,
                backend: .localApple
            )
        )
        XCTAssertFalse(
            RedditSummaryPlanner.requiresAppleLocalMultiPassPreflight(
                content: content,
                backend: .mlxLocal
            )
        )
        XCTAssertFalse(
            RedditSummaryPlanner.requiresAppleLocalMultiPassPreflight(
                content: "An ordinary article without Reddit comment records.",
                backend: .localApple
            )
        )
        let reconstructed = localPlan.chunks.map(\.text).joined(separator: "\n")
        for comment in comments {
            XCTAssertTrue(reconstructed.contains(comment), "Missing comment: \(comment.prefix(24))")
        }
    }

    func testRedditPlannerKeepsProviderBudgetsAndAllOversizedCommentRecords() {
        let oversizedComments = (0..<4).map { index in
            "u/oversized\(index): unique-marker-\(index) \(String(repeating: "evidence-\(index) ", count: 1_000))"
        }
        let content = """
        Body:
        Reddit coverage: extracted 4 accessible comments (reported 4; complete extraction)

        --- Comments ---
        \(oversizedComments.joined(separator: "\n"))
        """

        let localPlan = RedditSummaryPlanner.plan(content: content, backend: .localApple)
        XCTAssertGreaterThan(localPlan.chunks.count, 1)
        XCTAssertFalse(RedditSummaryPlanner.shouldUseSingleGeneration(plan: localPlan, backend: .localApple))
        XCTAssertTrue(
            RedditSummaryPlanner.requiresAppleLocalMultiPassPreflight(
                content: content,
                backend: .localApple
            )
        )
        XCTAssertFalse(
            RedditSummaryPlanner.requiresAppleLocalMultiPassPreflight(
                content: content,
                backend: .mlxLocal
            )
        )
        XCTAssertEqual(localPlan.totalCommentCount, oversizedComments.count)
        let reconstructed = localPlan.chunks.map(\.text).joined(separator: "\n")
        for index in oversizedComments.indices {
            XCTAssertTrue(reconstructed.contains("unique-marker-\(index)"), "Missing comment marker: \(index)")
        }

        XCTAssertEqual(RedditSummaryPlanner.characterBudget(for: .localApple), 18_750)
        XCTAssertEqual(RedditSummaryPlanner.characterBudget(for: .mlxLocal), 8_000)
        XCTAssertEqual(RedditSummaryPlanner.characterBudget(for: .applePCCGateway), 80_000)
        XCTAssertEqual(RedditSummaryPlanner.characterBudget(for: .webChatGPT), 76_000)
        XCTAssertEqual(RedditSummaryPlanner.characterBudget(for: .webGemini), 76_000)
        XCTAssertEqual(RedditSummaryPlanner.characterBudget(for: .cloudShortcuts), 60_000)
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
        XCTAssertEqual(RedditSummaryPlanner.reductionCharacterBudget(for: .localApple), 18_750)
    }

    func testAppleLocalPreflightCatchesDenseLargeRedditThreadBeforeGeneration() {
        let comments = (0..<159).map { index in
            "👤 u/u\(index): ok [1 points]"
        }
        let content = """
        Body:
        Reddit coverage: extracted 159 accessible comments (reported 159; complete extraction)
        📌 A busy Reddit thread

        --- Comments ---
        \(comments.joined(separator: "\n"))
        """

        let plan = RedditSummaryPlanner.plan(content: content, backend: .localApple)

        XCTAssertEqual(plan.totalCommentCount, 159)
        XCTAssertLessThan(content.count, RedditSummaryPlanner.appleLocalRedditSourceCharacterBudget)
        XCTAssertGreaterThan(plan.chunkCount, 1)
        XCTAssertTrue(
            RedditSummaryPlanner.requiresAppleLocalMultiPassPreflight(
                content: content,
                backend: .localApple
            )
        )
        XCTAssertFalse(RedditSummaryPlanner.shouldUseSingleGeneration(plan: plan, backend: .localApple))
    }

    func testSlowRedditProcessingNoticeIsProviderAndContextScoped() {
        XCTAssertTrue(
            SimpleAIService.shouldShowSlowRedditProcessingNotice(
                isRedditContext: true,
                backend: .localApple
            )
        )
        XCTAssertTrue(
            SimpleAIService.shouldShowSlowRedditProcessingNotice(
                isRedditContext: true,
                backend: .mlxLocal
            )
        )

        for backend in [
            AIModelBackend.cloudShortcuts,
            .applePCCGateway,
            .webChatGPT,
            .webGemini
        ] {
            XCTAssertFalse(
                SimpleAIService.shouldShowSlowRedditProcessingNotice(
                    isRedditContext: true,
                    backend: backend
                )
            )
        }
        XCTAssertFalse(
            SimpleAIService.shouldShowSlowRedditProcessingNotice(
                isRedditContext: false,
                backend: .localApple
            )
        )
        XCTAssertFalse(
            SimpleAIService.shouldShowSlowRedditProcessingNotice(
                isRedditContext: false,
                backend: .mlxLocal
            )
        )
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

    func testPasswordBridgeUsesNormalizedWebKitOriginHost() {
        XCTAssertEqual(
            PasswordBridgePolicy.normalizedCredentialHost(" Example.COM. "),
            "example.com"
        )
        XCTAssertEqual(
            PasswordBridgePolicy.normalizedCredentialHost("login.example.com"),
            "login.example.com"
        )
        XCTAssertNil(PasswordBridgePolicy.normalizedCredentialHost(nil))
        XCTAssertNil(PasswordBridgePolicy.normalizedCredentialHost(" ... "))
    }

    func testWebAIBridgeAcceptsOnlyProviderMainFrames() {
        XCTAssertTrue(
            WebAIMessagePolicy.allows(
                provider: .chatgpt,
                url: URL(string: "https://chatgpt.com/c/123"),
                isMainFrame: true
            )
        )
        XCTAssertTrue(
            WebAIMessagePolicy.allows(
                provider: .gemini,
                url: URL(string: "https://gemini.google.com/app"),
                isMainFrame: true
            )
        )
        XCTAssertFalse(
            WebAIMessagePolicy.allows(
                provider: .chatgpt,
                url: URL(string: "https://chatgpt.com.evil.example/"),
                isMainFrame: true
            )
        )
        XCTAssertFalse(
            WebAIMessagePolicy.allows(
                provider: .chatgpt,
                url: URL(string: "https://auth.openai.com/"),
                isMainFrame: true
            )
        )
        XCTAssertFalse(
            WebAIMessagePolicy.allows(
                provider: .gemini,
                url: URL(string: "https://gemini.google.com/app"),
                isMainFrame: false
            )
        )
        XCTAssertTrue(
            WebAIProvider.chatgpt.allowsSessionNavigation(
                URL(string: "https://auth.openai.com/login")
            )
        )
        XCTAssertTrue(
            WebAIProvider.gemini.allowsSessionNavigation(
                URL(string: "https://accounts.google.com/ServiceLogin")
            )
        )
        XCTAssertFalse(
            WebAIProvider.chatgpt.allowsSessionNavigation(
                URL(string: "https://openai.com.evil.example/")
            )
        )
    }

    func testIncognitoTabsNeverRequestRemoteFavicons() {
        let pageURL = URL(string: "https://example.com/private")
        XCTAssertNil(
            BrowserFaviconPolicy.remoteFaviconURL(for: pageURL, isIncognito: true)
        )

        guard let faviconURL = BrowserFaviconPolicy.remoteFaviconURL(
            for: pageURL,
            isIncognito: false
        ) else {
            return XCTFail("Expected a favicon URL for a normal tab")
        }
        XCTAssertEqual(faviconURL.host, "www.google.com")
        XCTAssertEqual(
            URLComponents(url: faviconURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "domain" })?
                .value,
            "example.com"
        )
    }

    func testMoreCommentsRetryCountIsBounded() {
        XCTAssertEqual(
            RedditMoreCommentsRetryPolicy.nextRetryCount(current: 0, maximum: 5),
            1
        )
        XCTAssertEqual(
            RedditMoreCommentsRetryPolicy.nextRetryCount(current: 4, maximum: 5),
            5
        )
        XCTAssertNil(
            RedditMoreCommentsRetryPolicy.nextRetryCount(current: 5, maximum: 5)
        )
    }
}
