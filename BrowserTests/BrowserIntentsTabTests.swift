import AppIntents
import Foundation
import WebKit
import XCTest
@testable import Browser

@MainActor
final class BrowserIntentsTabTests: BrowserIntentsExecutorTestCase {
    func testOpenURLCreatesRegularSelectedTab() async throws {
        let harness = try makeHarness()
        _ = addTab(harness, incognito: true)
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(
            .openURL(try XCTUnwrap(URL(string: "https://apple.com/x?y=1"))),
            confirm: confirm
        )
        XCTAssertEqual(output.text, "Opened the website in a new tab.")
        let newTab = try XCTUnwrap(harness.viewModel.tabs.last)
        XCTAssertFalse(newTab.isIncognito)
        XCTAssertEqual(harness.viewModel.selectedTabID, newTab.id)
        XCTAssertEqual(newTab.url?.absoluteString, "https://apple.com/x?y=1")
    }

    func testOpenURLRejectsUnsafeURLs() async throws {
        let harness = try makeHarness()
        let (executor, confirm) = makeExecutor(harness)
        for raw in ["javascript:alert(1)", "file:///etc/passwd", "https://user:pass@example.com", "data:text/html,x"] {
            do {
                _ = try await executor.execute(.openURL(try XCTUnwrap(URL(string: raw))), confirm: confirm)
                XCTFail("Expected rejection for \(raw)")
            } catch {
                XCTAssertTrue(error is BrowserIntentError)
            }
        }
    }

    func testSearchUsesDefaultEngineAndTreatsDomainAsQuery() async throws {
        let harness = try makeHarness()
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.search("café+tea & biscuits"), confirm: confirm)
        let tab = try XCTUnwrap(harness.viewModel.tabs.last)
        let urlString = try XCTUnwrap(tab.url?.absoluteString)
        XCTAssertTrue(urlString.hasPrefix("https://www.google.com/search?q="))
        XCTAssertTrue(urlString.contains("caf"))
        XCTAssertEqual(output.text, "Searched for café+tea & biscuits in a new tab.")

        _ = try await executor.execute(.search("example.com"), confirm: confirm)
        let searchTab = try XCTUnwrap(harness.viewModel.tabs.last)
        XCTAssertTrue(try XCTUnwrap(searchTab.url?.absoluteString).contains("search?q="))
    }

    func testSearchAcceptsMultibyteQueryAtByteBound() async throws {
        let harness = try makeHarness()
        let (executor, confirm) = makeExecutor(harness)
        let query = String(repeating: "\u{00e9}", count: 2_048)
        XCTAssertEqual(query.utf8.count, 4_096)
        _ = try await executor.execute(.search(query), confirm: confirm)
        let tab = try XCTUnwrap(harness.viewModel.tabs.last)
        let url = try XCTUnwrap(tab.url)
        XCTAssertGreaterThan(url.absoluteString.count, 4_096)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "q" })?.value,
            query
        )
    }

    func testNewTabIsRegularEvenWhenPrivateSelected() async throws {
        let harness = try makeHarness()
        _ = addTab(harness, incognito: true)
        let (executor, confirm) = makeExecutor(harness)
        _ = try await executor.execute(.newTab, confirm: confirm)
        let tab = try XCTUnwrap(harness.viewModel.tabs.last)
        XCTAssertFalse(tab.isIncognito)
        XCTAssertEqual(harness.viewModel.selectedTabID, tab.id)
    }

    func testNewPrivateTabCreatesPrivateTab() async throws {
        let harness = try makeHarness()
        _ = addTab(harness)
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.newPrivateTab, confirm: confirm)
        let tab = try XCTUnwrap(harness.viewModel.tabs.last)
        XCTAssertTrue(tab.isIncognito)
        XCTAssertEqual(harness.viewModel.selectedTabID, tab.id)
        XCTAssertFalse(output.text.contains("example.com"))
    }

    func testReopenClosedTabRequiresRecord() async throws {
        let harness = try makeHarness()
        let (executor, confirm) = makeExecutor(harness)
        do {
            _ = try await executor.execute(.reopenClosedTab, confirm: confirm)
            XCTFail("Expected empty history error")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
        harness.viewModel.recentlyClosedTabs = [
            RecentlyClosedTab(
                id: UUID(),
                title: "Closed",
                url: try XCTUnwrap(URL(string: "https://closed.example")),
                groupID: nil,
                closedAt: Date()
            )
        ]
        let output = try await executor.execute(.reopenClosedTab, confirm: confirm)
        XCTAssertEqual(output.text, "Reopened the last closed tab.")
        XCTAssertTrue(harness.viewModel.recentlyClosedTabs.isEmpty)
    }

    func testCloseTabDeclineHasNoEffect() async throws {
        let harness = try makeHarness()
        let first = addTab(harness, url: "https://one.example")
        _ = addTab(harness, url: "https://two.example")
        harness.viewModel.selectedTabID = first.id
        let (executor, _) = makeExecutor(harness)
        do {
            _ = try await executor.execute(.closeCurrentTab, confirm: decline)
            XCTFail("Decline must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(harness.viewModel.tabs.count, 2)
        XCTAssertEqual(harness.viewModel.selectedTabID, first.id)
    }

    func testCloseCurrentTabConfirmedCloses() async throws {
        let harness = try makeHarness()
        let first = addTab(harness, url: "https://one.example")
        let second = addTab(harness, url: "https://two.example")
        harness.viewModel.selectedTabID = first.id
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.closeCurrentTab, confirm: confirm)
        XCTAssertEqual(output.text, "Closed the current tab.")
        XCTAssertEqual(harness.viewModel.tabs.count, 1)
        XCTAssertEqual(harness.viewModel.tabs.first?.id, second.id)
    }

    func testCloseLastRegularTabRefused() async throws {
        let harness = try makeHarness()
        _ = addTab(harness)
        _ = addTab(harness, incognito: true)
        harness.viewModel.selectedTabID = harness.viewModel.tabs.first?.id
        let (executor, confirm) = makeExecutor(harness)
        do {
            _ = try await executor.execute(.closeCurrentTab, confirm: confirm)
            XCTFail("Last regular tab close must be refused")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .lastAccessibleTab)
        }
        XCTAssertEqual(harness.viewModel.tabs.count, 2)
    }

    func testCloseTabMembershipChangeDuringApprovalRejects() async throws {
        let harness = try makeHarness()
        let first = addTab(harness, url: "https://one.example")
        _ = addTab(harness, url: "https://two.example")
        harness.viewModel.selectedTabID = first.id
        let (executor, _) = makeExecutor(harness)
        let mutateDuringConfirm: BrowserIntentConfirmation = { _ in
            first.groupID = UUID()
            harness.viewModel.selectedTabID = harness.viewModel.tabs.last?.id
        }
        do {
            _ = try await executor.execute(.closeCurrentTab, confirm: mutateDuringConfirm)
            XCTFail("Membership change must reject the close")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
        XCTAssertEqual(harness.viewModel.tabs.count, 2)
    }

    func testCloseGroupClosesOnlyEligibleMembers() async throws {
        let harness = try makeHarness()
        let group = harness.viewModel.createTabGroup(title: "Work")
        let memberA = addTab(harness, url: "https://a.example", groupID: group.id)
        let memberB = addTab(harness, url: "https://b.example", groupID: group.id)
        let privateMember = addTab(harness, url: "https://p.example", incognito: true, groupID: group.id)
        let outside = addTab(harness, url: "https://outside.example")
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.closeGroup(group.id), confirm: confirm)
        XCTAssertEqual(output.text, "Closed 2 tabs in the group.")
        let remainingIDs = Set(harness.viewModel.tabs.map(\.id))
        XCTAssertFalse(remainingIDs.contains(memberA.id))
        XCTAssertFalse(remainingIDs.contains(memberB.id))
        XCTAssertTrue(remainingIDs.contains(privateMember.id))
        XCTAssertTrue(remainingIDs.contains(outside.id))
        XCTAssertNotNil(harness.viewModel.tabGroups.first(where: { $0.id == group.id }))
    }

    func testCloseGroupDeclineLeavesEverything() async throws {
        let harness = try makeHarness()
        let group = harness.viewModel.createTabGroup(title: "Work")
        _ = addTab(harness, url: "https://a.example", groupID: group.id)
        _ = addTab(harness, url: "https://outside.example")
        let (executor, _) = makeExecutor(harness)
        do {
            _ = try await executor.execute(.closeGroup(group.id), confirm: decline)
            XCTFail("Decline must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(harness.viewModel.tabs.count, 2)
    }

    func testSwitchAndMoveGroup() async throws {
        let harness = try makeHarness()
        let group = harness.viewModel.createTabGroup(title: "Work")
        let member = addTab(harness, url: "https://a.example", groupID: group.id)
        let outside = addTab(harness, url: "https://outside.example")
        harness.viewModel.selectedTabID = outside.id
        let (executor, confirm) = makeExecutor(harness)
        _ = try await executor.execute(.switchGroup(group.id), confirm: confirm)
        XCTAssertEqual(harness.viewModel.selectedTabID, member.id)

        let emptyGroup = harness.viewModel.createTabGroup(title: "Empty")
        let empty = try await executor.execute(.switchGroup(emptyGroup.id), confirm: confirm)
        XCTAssertEqual(empty.text, "This group has no regular tabs.")

        harness.viewModel.selectedTabID = outside.id
        _ = try await executor.execute(.moveToGroup(group.id), confirm: confirm)
        XCTAssertEqual(outside.groupID, group.id)

        do {
            _ = try await executor.execute(.switchGroup(UUID()), confirm: confirm)
            XCTFail("Unknown group must throw")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .unknownGroup)
        }
    }
}
