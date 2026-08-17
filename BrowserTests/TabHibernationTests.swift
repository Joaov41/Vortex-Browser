import XCTest
@testable import Browser

@MainActor
final class TabHibernationTests: XCTestCase {
    func testBrowserTabStartsMetadataOnly() {
        let tab = BrowserTab(
            title: "Saved page",
            url: URL(string: "https://example.com")!
        )

        XCTAssertNil(tab.liveWebView)
        XCTAssertTrue(tab.isHibernated)
        XCTAssertFalse(tab.showsHibernationIndicator)
        XCTAssertEqual(tab.currentURL?.absoluteString, "https://example.com")
    }

    func testSessionSearchAndSaveDoNotWakeTabs() {
        let suiteName = "BrowserTests.Hibernation.(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewModel = BrowserViewModel(userDefaults: defaults)
        guard let tab = viewModel.tabs.first else {
            return XCTFail("Expected an initial tab")
        }

        _ = viewModel.tabs(matching: "google", scope: .all)
        viewModel.saveSession()

        XCTAssertNil(tab.liveWebView)
        XCTAssertEqual(viewModel.liveTabCount, 0)
        XCTAssertEqual(viewModel.hibernatedTabCount, 1)
    }

    func testEvictionCandidatesAreLRUAndExcludeSelectedIncognitoAIAndMediaTabs() {
        let suiteName = "BrowserTests.Hibernation.Exclusions.(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewModel = BrowserViewModel(userDefaults: defaults)
        guard let selected = viewModel.tabs.first else {
            return XCTFail("Expected an initial tab")
        }
        let normal = BrowserTab(title: "Normal", url: URL(string: "https://normal.example")!)
        let incognito = BrowserTab(title: "Private", url: URL(string: "https://private.example")!, isIncognito: true)
        let ai = BrowserTab(title: "AI", url: URL(string: "https://chatgpt.com")!)
        let media = BrowserTab(title: "Playing", url: URL(string: "https://media.example")!)
        let newer = BrowserTab(title: "Newer", url: URL(string: "https://newer.example")!)
        ai.webAIProvider = .chatgpt
        viewModel.tabs.append(contentsOf: [normal, incognito, ai, media, newer])
        viewModel.updateProtectedTabIDs([selected.id])

        _ = selected.activateWebView()
        _ = normal.activateWebView()
        _ = incognito.activateWebView()
        _ = ai.activateWebView()
        _ = media.activateWebView()
        _ = newer.activateWebView()
        normal.touch(at: Date(timeIntervalSince1970: 100))
        newer.touch(at: Date(timeIntervalSince1970: 200))
        media.recordMediaPlaybackState(true)

        XCTAssertEqual(viewModel.evictionCandidateIDs(), [normal.id, newer.id])
    }

    func testRecreatedTabUsesSavedURLAndRemainsMetadataOnlyUntilActivation() {
        let tab = BrowserTab(
            title: "Restored",
            url: URL(string: "https://example.com/article")!
        )
        XCTAssertEqual(tab.address, "https://example.com/article")
        XCTAssertNil(tab.liveWebView)

        _ = tab.activateWebView()
        XCTAssertNotNil(tab.liveWebView)
        XCTAssertFalse(tab.isHibernated)
    }

    func testRestoringOneHundredTabsDoesNotCreateWebViews() {
        let suiteName = "BrowserTests.Hibernation.LargeRestore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var writer: BrowserViewModel? = BrowserViewModel(userDefaults: defaults)
        writer?.tabs = (0..<100).map { index in
            BrowserTab(title: "Tab \(index)", url: URL(string: "https://example.com/\(index)")!)
        }
        writer?.selectedTabID = writer?.tabs.last?.id
        writer?.saveSession()
        writer = nil

        let restored = BrowserViewModel(userDefaults: defaults)
        XCTAssertEqual(restored.tabs.count, 100)
        XCTAssertEqual(restored.liveTabCount, 0)
        XCTAssertTrue(restored.tabs.allSatisfy { $0.isHibernated && $0.liveWebView == nil })
        XCTAssertTrue(restored.tabs.allSatisfy(\.showsHibernationIndicator))
    }

    func testSavedScrollPositionSurvivesReactivation() {
        let tab = BrowserTab(title: "Article", url: URL(string: "https://example.com/article")!)
        tab.recordScrollPosition(640)

        _ = tab.activateWebView()

        XCTAssertEqual(tab.savedScrollPosition, 640)
    }

    func testSleepingIndicatorAppearsOnlyAfterHibernationAndClearsWhenReactivated() async {
        let tab = BrowserTab(title: "Article", url: URL(string: "https://example.com/article")!)
        XCTAssertFalse(tab.showsHibernationIndicator)

        _ = tab.activateWebView()
        XCTAssertFalse(tab.showsHibernationIndicator)

        let didHibernate = await tab.hibernate()
        XCTAssertTrue(didHibernate)
        XCTAssertTrue(tab.showsHibernationIndicator)

        _ = tab.activateWebView()
        XCTAssertFalse(tab.showsHibernationIndicator)
    }
}
