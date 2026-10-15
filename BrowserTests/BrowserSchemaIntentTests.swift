import AppIntents
import Foundation
import XCTest
@testable import Browser

/// Schema parameter mapping: each schema intent delegates to `BrowserSchemaCommands`, tested with plain values.
@MainActor
final class BrowserSchemaIntentMappingTests: XCTestCase {
    private let pageURL = URL(string: "https://example.com/page")!
    private let tabID = UUID()

    func testCreateTabMapsToNewTabOrOpenURL() throws {
        XCTAssertEqual(try BrowserSchemaCommands.createTab(url: nil, isPrivate: false), [.newTab])
        XCTAssertEqual(try BrowserSchemaCommands.createTab(url: pageURL, isPrivate: false), [.openURL(pageURL)])
    }

    func testCreateTabRefusesPrivateTabs() {
        XCTAssertThrowsError(try BrowserSchemaCommands.createTab(url: nil, isPrivate: true)) { error in
            XCTAssertTrue(error is BrowserIntentError)
        }
    }

    func testLoadURLInTabTargetsTheTab() throws {
        XCTAssertEqual(
            try BrowserSchemaCommands.loadURL(pageURL, inTab: tabID.uuidString),
            [.loadURLInTab(pageURL, tabID)]
        )
    }

    func testFindOnPageSelectsTabThenFinds() throws {
        XCTAssertEqual(
            try BrowserSchemaCommands.findOnPage("alpha", inTab: tabID.uuidString),
            [.switchToTab(tabID), .findText("alpha")]
        )
    }

    func testBookmarkTabSelectsTabThenBookmarks() throws {
        XCTAssertEqual(
            try BrowserSchemaCommands.bookmarkTab(tabID.uuidString),
            [.switchToTab(tabID), .bookmark(nil)]
        )
    }

    func testOpenBookmarkOpensURLOrLoadsIntoTab() throws {
        XCTAssertEqual(try BrowserSchemaCommands.openBookmark(url: pageURL, inTab: nil), [.openURL(pageURL)])
        XCTAssertEqual(
            try BrowserSchemaCommands.openBookmark(url: pageURL, inTab: tabID.uuidString),
            [.loadURLInTab(pageURL, tabID)]
        )
    }

    func testOpenBookmarkRejectsNonWebURLs() {
        let local = URL(string: "file:///etc/passwd")!
        XCTAssertThrowsError(try BrowserSchemaCommands.openBookmark(url: local, inTab: nil))
    }

    func testSwitchTabMapsToSwitchToTab() throws {
        XCTAssertEqual(try BrowserSchemaCommands.switchTab(tabID.uuidString), [.switchToTab(tabID)])
    }

    func testMalformedTabIdentifiersAreRejected() {
        XCTAssertThrowsError(try BrowserSchemaCommands.switchTab("not-a-uuid"))
        XCTAssertThrowsError(try BrowserSchemaCommands.closeTabs([tabID.uuidString, "bad"]))
    }

    func testCloseTabsMapsToCloseTabs() throws {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(
            try BrowserSchemaCommands.closeTabs([first.uuidString, second.uuidString]),
            [.closeTabs([first, second])]
        )
    }

    func testSearchInAppMapsToSearch() {
        XCTAssertEqual(BrowserSchemaCommands.search("caf\u{00e9} tea"), [.search("caf\u{00e9} tea")])
    }

    func testDeleteBookmarksMapsToDeleteBookmarks() throws {
        let first = UUID()
        XCTAssertEqual(
            try BrowserSchemaCommands.deleteBookmarks([first.uuidString]),
            [.deleteBookmarks([first])]
        )
    }

    func testClearHistoryMapsTimeFrames() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            BrowserSchemaCommands.clearHistory(.lastHour, now: now),
            [.clearHistory(now.addingTimeInterval(-3_600))]
        )
        XCTAssertEqual(BrowserSchemaCommands.clearHistory(.allTime, now: now), [.clearHistory(nil)])
    }
}

/// Executor behavior: confirmation gates, regular-tab targeting and the new commands.
@MainActor
final class BrowserSchemaExecutorTests: BrowserIntentsExecutorTestCase {
    private func favorite(_ title: String, _ urlString: String) -> Favorite {
        Favorite(title: title, url: URL(string: urlString)!, dateAdded: Date(), favicon: nil)
    }

    private struct Declined: Error {}

    func testDeleteBookmarksRequiresConfirmation() async throws {
        let harness = try makeHarness()
        let (executor, _) = makeExecutor(harness)
        let saved = favorite("Keep me", "https://example.com/keep")
        let target = favorite("Remove me", "https://example.com/remove")
        harness.viewModel.favorites = [saved, target]

        do {
            _ = try await executor.execute(.deleteBookmarks([target.id]), confirm: { _ in throw Declined() })
            XCTFail("Declining should stop the delete")
        } catch {
            XCTAssertTrue(error is Declined)
        }
        XCTAssertEqual(harness.viewModel.favorites.map(\.id), [saved.id, target.id])
    }

    func testDeleteBookmarksRemovesOnlyApprovedTargets() async throws {
        let harness = try makeHarness()
        let (executor, _) = makeExecutor(harness)
        let saved = favorite("Keep me", "https://example.com/keep")
        let target = favorite("Remove me", "https://example.com/remove")
        harness.viewModel.favorites = [saved, target]
        let log = SchemaTestLog()

        let output = try await executor.execute(
            .deleteBookmarks([target.id, UUID()]),
            confirm: { message in log.messages.append(message) }
        )

        XCTAssertEqual(log.messages.count, 1)
        XCTAssertEqual(harness.viewModel.favorites.map(\.id), [saved.id])
        XCTAssertEqual(output.text, "Deleted 1 bookmark from Favorites.")
    }

    func testDeleteBookmarksWithNoKnownTargetsAsksNothing() async throws {
        let harness = try makeHarness()
        let (executor, _) = makeExecutor(harness)
        let log = SchemaTestLog()
        do {
            _ = try await executor.execute(.deleteBookmarks([UUID()]), confirm: { _ in log.count += 1 })
            XCTFail("Unknown bookmarks should fail")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
        XCTAssertEqual(log.count, 0)
    }

    func testClearHistoryRequiresConfirmation() async throws {
        let harness = try makeHarness()
        let (executor, _) = makeExecutor(harness)
        harness.history.record(url: URL(string: "https://example.com/a")!, title: "A")

        do {
            _ = try await executor.execute(.clearHistory(nil), confirm: { _ in throw Declined() })
            XCTFail("Declining should keep history")
        } catch {
            XCTAssertTrue(error is Declined)
        }
        XCTAssertEqual(harness.history.entries.count, 1)
    }

    func testClearHistoryClearsAndNotifiesSpotlightReconciliation() async throws {
        let harness = try makeHarness()
        let (executor, _) = makeExecutor(harness)
        harness.history.record(url: URL(string: "https://example.com/a")!, title: "A")
        harness.history.record(url: URL(string: "https://example.com/b")!, title: "B")
        XCTAssertEqual(harness.history.entries.count, 2)

        let log = SchemaTestLog()
        let token = NotificationCenter.default.addObserver(
            forName: .browserHistoryDidChange,
            object: nil,
            queue: nil
        ) { _ in log.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try await executor.execute(.clearHistory(nil), confirm: { _ in })

        XCTAssertTrue(harness.history.entries.isEmpty)
        XCTAssertGreaterThan(log.count, 0, "Clearing history must post the change the Spotlight indexer listens for")
    }

    func testClosedTabsRequireConfirmationAndOnlyRegularTabsAreTargets() async throws {
        let harness = try makeHarness()
        let (executor, _) = makeExecutor(harness)
        let keep = addTab(harness, url: "https://example.com/keep")
        let close = addTab(harness, url: "https://example.com/close")
        let privateTab = addTab(harness, url: "https://example.com/private", incognito: true)

        do {
            _ = try await executor.execute(.closeTabs([close.id]), confirm: { _ in throw Declined() })
            XCTFail("Declining should keep the tab open")
        } catch {
            XCTAssertTrue(error is Declined)
        }
        XCTAssertTrue(harness.viewModel.tabs.contains { $0.id == close.id })

        _ = try await executor.execute(.closeTabs([close.id, privateTab.id]), confirm: { _ in })

        XCTAssertFalse(harness.viewModel.tabs.contains { $0.id == close.id })
        XCTAssertTrue(harness.viewModel.tabs.contains { $0.id == keep.id })
        XCTAssertTrue(harness.viewModel.tabs.contains { $0.id == privateTab.id }, "Private tabs are never close targets")
    }

    func testCloseTabsOnlyPrivateTargetsFailWithoutAsking() async throws {
        let harness = try makeHarness()
        let (executor, _) = makeExecutor(harness)
        _ = addTab(harness, url: "https://example.com/keep")
        let privateTab = addTab(harness, url: "https://example.com/private", incognito: true)
        let log = SchemaTestLog()
        do {
            _ = try await executor.execute(.closeTabs([privateTab.id]), confirm: { _ in log.count += 1 })
            XCTFail("A private tab is not a close target")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
        XCTAssertEqual(log.count, 0)
        XCTAssertTrue(harness.viewModel.tabs.contains { $0.id == privateTab.id })
    }

    func testCloseTabsNeverClosesTheLastRegularTab() async throws {
        let harness = try makeHarness()
        let (executor, _) = makeExecutor(harness)
        let only = addTab(harness, url: "https://example.com/only")
        do {
            _ = try await executor.execute(.closeTabs([only.id]), confirm: { _ in })
            XCTFail("The last regular tab must stay open")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .lastAccessibleTab)
        }
    }

    func testSwitchToPrivateTabIsRefused() async throws {
        let harness = try makeHarness()
        let (executor, confirm) = makeExecutor(harness)
        let regular = addTab(harness, url: "https://example.com/regular")
        let privateTab = addTab(harness, url: "https://example.com/private", incognito: true)
        harness.viewModel.selectedTabID = regular.id

        do {
            _ = try await executor.execute(.switchToTab(privateTab.id), confirm: confirm)
            XCTFail("Private tabs are not switch targets")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
        XCTAssertEqual(harness.viewModel.selectedTabID, regular.id)
    }

    func testLoadURLInTabNavigatesRegularTabOnly() async throws {
        let harness = try makeHarness()
        let (executor, confirm) = makeExecutor(harness)
        let regular = addTab(harness, url: "https://example.com/regular")
        let privateTab = addTab(harness, url: "https://example.com/private", incognito: true)
        let destination = URL(string: "https://apple.com/loaded")!

        _ = try await executor.execute(.loadURLInTab(destination, regular.id), confirm: confirm)
        XCTAssertEqual(regular.url?.absoluteString, destination.absoluteString)

        do {
            _ = try await executor.execute(.loadURLInTab(destination, privateTab.id), confirm: confirm)
            XCTFail("Private tabs are never load targets")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
        XCTAssertNotEqual(privateTab.url?.absoluteString, destination.absoluteString)
    }

    func testLoadURLInTabRejectsUnsafeURLs() async throws {
        let harness = try makeHarness()
        let (executor, confirm) = makeExecutor(harness)
        let regular = addTab(harness, url: "https://example.com/regular")
        do {
            _ = try await executor.execute(
                .loadURLInTab(URL(string: "javascript:alert(1)")!, regular.id),
                confirm: confirm
            )
            XCTFail("Unsafe URLs must be refused")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
    }

    func testNewTabReportsTheCreatedTab() async throws {
        let harness = try makeHarness()
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.newTab, confirm: confirm)
        XCTAssertEqual(output.resultTabID, harness.viewModel.selectedTabID)
        XCTAssertNotNil(output.resultTabID)
    }

    func testRenameBookmarkUpdatesTitleAndRejectsEmptyNames() async throws {
        let harness = try makeHarness()
        let (executor, confirm) = makeExecutor(harness)
        let target = favorite("Old", "https://example.com/old")
        harness.viewModel.favorites = [target]

        do {
            _ = try await executor.execute(.renameBookmark(target.id, "   "), confirm: confirm)
            XCTFail("An empty name must be refused")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
        XCTAssertEqual(harness.viewModel.favorites.first?.title, "Old")

        _ = try await executor.execute(.renameBookmark(target.id, "  New name "), confirm: confirm)
        XCTAssertEqual(harness.viewModel.favorites.first?.title, "New name")
    }
}

/// Counts confirmation prompts and notifications seen by a test.
final class SchemaTestLog {
    var messages: [String] = []
    var count = 0
}
