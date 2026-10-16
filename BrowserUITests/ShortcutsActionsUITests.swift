import XCTest

/// Drives the Shortcuts app on a real device to run Vortyra's actions the way a user builds them.
final class ShortcutsActionsUITests: XCTestCase {
    private var shortcuts: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        await MainActor.run {
            shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
            shortcuts.launch()
        }
    }

    /// Records the Shortcuts app's controls so the action tests can find them.
    @MainActor func test00ExploreShortcutsApp() {
        Thread.sleep(forTimeInterval: 3)
        attach("shortcuts-home")
        attachText("shortcuts-home-tree", shortcuts.debugDescription)
        let add = shortcuts.buttons.matching(NSPredicate(format: "label IN {'Add', 'New Shortcut', 'Create Shortcut', 'plus'}")).firstMatch
        if add.waitForExistence(timeout: 5) {
            add.tap()
            Thread.sleep(forTimeInterval: 3)
        }
        attach("shortcuts-editor")
        attachText("shortcuts-editor-tree", shortcuts.debugDescription)
        let search = shortcuts.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("Vortyra")
            Thread.sleep(forTimeInterval: 3)
        }
        attach("shortcuts-search-vortyra")
        attachText("shortcuts-search-tree", shortcuts.debugDescription)
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func attachText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
