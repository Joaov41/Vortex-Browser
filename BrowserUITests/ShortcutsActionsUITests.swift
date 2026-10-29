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

    /// Second look: the classic editor behind Edit, its action search, one harmless action and Run.
    @MainActor func test01ExploreEditorAndRun() {
        Thread.sleep(forTimeInterval: 3)
        let add = shortcuts.buttons.matching(NSPredicate(format: "label IN {'Add', 'New Shortcut', 'Create Shortcut', 'plus'}")).firstMatch
        if add.waitForExistence(timeout: 5) { add.tap(); Thread.sleep(forTimeInterval: 3) }
        let edit = shortcuts.buttons["Edit"].firstMatch
        if edit.waitForExistence(timeout: 5) { edit.tap(); Thread.sleep(forTimeInterval: 3) }
        attach("editor-after-edit")
        attachText("editor-after-edit-tree", shortcuts.debugDescription)
        let actionSearch = shortcuts.searchFields.allElementsBoundByIndex.last ?? shortcuts.searchFields.firstMatch
        if actionSearch.waitForExistence(timeout: 5) {
            actionSearch.tap()
            actionSearch.typeText("Copy Page Title")
            Thread.sleep(forTimeInterval: 3)
        }
        attach("action-search")
        attachText("action-search-tree", shortcuts.debugDescription)
        let result = shortcuts.cells.containing(NSPredicate(format: "label CONTAINS[c] 'Copy Page Title'")).firstMatch
        if result.waitForExistence(timeout: 5) {
            result.tap()
            Thread.sleep(forTimeInterval: 2)
        } else {
            let anyText = shortcuts.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Copy Page Title'")).firstMatch
            if anyText.exists { anyText.tap(); Thread.sleep(forTimeInterval: 2) }
        }
        attach("action-added")
        attachText("action-added-tree", shortcuts.debugDescription)
        let run = shortcuts.buttons.matching(NSPredicate(format: "label IN {'Run', 'Play', 'Run Shortcut'}")).firstMatch
        if run.waitForExistence(timeout: 5) { run.tap(); Thread.sleep(forTimeInterval: 8) }
        attach("after-run")
        attachText("after-run-tree", XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)
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
