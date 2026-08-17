import Combine
import XCTest
@testable import Browser

@MainActor
final class BrowserTabGroupMoveTests: XCTestCase {
    func testNewBlankTabsRemainUngroupedUntilExplicitlyMoved() {
        let suiteName = "BrowserTests.TabGroupAssignment.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewModel = BrowserViewModel(userDefaults: defaults)
        let group = viewModel.createTabGroup(title: "Group A")
        viewModel.addTabBlank()
        guard let newTab = viewModel.tabs.last else {
            return XCTFail("Expected a new tab")
        }

        XCTAssertNil(newTab.groupID)
        XCTAssertTrue(viewModel.tabs(matching: "", scope: .group(group.id)).isEmpty)

        viewModel.move(newTab, to: group.id)
        XCTAssertEqual(viewModel.tabs(matching: "", scope: .group(group.id)).map(\.id), [newTab.id])
    }

    func testReplacementAfterClosingFinalGroupedTabIsUngrouped() {
        let suiteName = "BrowserTests.TabGroupReplacement.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewModel = BrowserViewModel(userDefaults: defaults)
        let group = viewModel.createTabGroup(title: "Group A")
        let groupedTab = BrowserTab(
            title: "Grouped",
            url: URL(string: "https://grouped.example")!,
            groupID: group.id
        )
        viewModel.tabs = [groupedTab]
        viewModel.selectedTabID = groupedTab.id

        viewModel.closeTab(groupedTab)

        XCTAssertEqual(viewModel.tabs.count, 1)
        XCTAssertNil(viewModel.tabs[0].groupID)
        XCTAssertTrue(viewModel.tabs(matching: "", scope: .group(group.id)).isEmpty)
    }

    func testMovingVisibleTabOutOfSelectedGroupPublishesFilteredResultsImmediately() {
        let suiteName = "BrowserTests.TabGroupMove.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewModel = BrowserViewModel(userDefaults: defaults)
        let groupA = viewModel.createTabGroup(title: "Group A")
        let groupB = viewModel.createTabGroup(title: "Group B")
        let remainingTab = BrowserTab(title: "Remains", url: URL(string: "https://remains.example")!, groupID: groupA.id)
        let movedTab = BrowserTab(title: "Moves", url: URL(string: "https://moves.example")!, groupID: groupA.id)
        let otherGroupTab = BrowserTab(title: "Other", url: URL(string: "https://other.example")!, groupID: groupB.id)
        viewModel.tabs = [remainingTab, movedTab, otherGroupTab]

        // This models the sidebar's selected group scope. The publisher assertion ensures the
        // result is recomputed because the parent collection changed, not merely because the test
        // queried the model again after the move.
        var selectedGroupResults = viewModel.tabs(matching: "", scope: .group(groupA.id))
        var parentPublished = false
        let observation = viewModel.objectWillChange.sink { _ in
            parentPublished = true
            selectedGroupResults = viewModel.tabs(matching: "", scope: .group(groupA.id))
        }
        defer { observation.cancel() }

        XCTAssertEqual(selectedGroupResults.map(\.id), [remainingTab.id, movedTab.id])
        viewModel.move(movedTab, to: groupB.id)

        XCTAssertTrue(parentPublished)
        XCTAssertEqual(selectedGroupResults.map(\.id), [remainingTab.id])
        XCTAssertEqual(movedTab.groupID, groupB.id)
    }
}
