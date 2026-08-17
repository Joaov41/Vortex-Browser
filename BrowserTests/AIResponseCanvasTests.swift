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
}
