import AppIntents
import Foundation
import WebKit
import XCTest
@testable import Browser

@MainActor
final class BrowserIntentEntityTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "BrowserIntentEntityTests.\(UUID().uuidString)"))
    }

    func testGroupQueryReadsStorageWithoutViewModel() async throws {
        let defaults = try makeDefaults()
        let groups = [
            BrowserTabGroup(title: "Work"),
            BrowserTabGroup(title: "Travel")
        ]
        defaults.set(try JSONEncoder().encode(groups), forKey: BrowserIntentEntityStorage.groupsKey)
        let query = BrowserGroupEntityQuery(defaultsProvider: { defaults })
        let all = try await query.suggestedEntities()
        XCTAssertEqual(all.count, 2)
        let byID = try await query.entities(for: [groups[0].id.uuidString])
        XCTAssertEqual(byID.first?.id, groups[0].id.uuidString)
        XCTAssertEqual(byID.first?.title, "Work")
        let matching = try await query.entities(matching: "trav")
        XCTAssertEqual(matching.map(\.title), ["Travel"])
    }

    func testFolderQueryBuildsHumanPaths() async throws {
        let defaults = try makeDefaults()
        let parent = FavoriteFolder(title: "Research")
        let child = FavoriteFolder(title: "AI", parentID: parent.id)
        defaults.set(try JSONEncoder().encode([parent, child]), forKey: BrowserIntentEntityStorage.foldersKey)
        let query = BrowserFolderEntityQuery(defaultsProvider: { defaults })
        let all = try await query.suggestedEntities()
        XCTAssertEqual(all.count, 2)
        let childEntity = try XCTUnwrap(all.first(where: { $0.id == child.id.uuidString }))
        XCTAssertEqual(childEntity.title, "Research › AI")
        let matching = try await query.entities(matching: "Research")
        XCTAssertTrue(matching.contains(where: { $0.id == child.id.uuidString }))
    }

    func testMissingStorageReturnsEmpty() async throws {
        let defaults = try makeDefaults()
        let groups = try await BrowserGroupEntityQuery(defaultsProvider: { defaults }).suggestedEntities()
        let folders = try await BrowserFolderEntityQuery(defaultsProvider: { defaults }).suggestedEntities()
        XCTAssertTrue(groups.isEmpty)
        XCTAssertTrue(folders.isEmpty)
    }

    func testCorruptStorageThrowsInsteadOfGuessing() async throws {
        let defaults = try makeDefaults()
        defaults.set(Data("not json".utf8), forKey: BrowserIntentEntityStorage.groupsKey)
        defaults.set(Data("not json".utf8), forKey: BrowserIntentEntityStorage.foldersKey)
        do {
            _ = try await BrowserGroupEntityQuery(defaultsProvider: { defaults }).suggestedEntities()
            XCTFail("Corrupt group storage must throw")
        } catch {
            XCTAssertTrue(error is BrowserIntentEntityError)
        }
        do {
            _ = try await BrowserFolderEntityQuery(defaultsProvider: { defaults }).suggestedEntities()
            XCTFail("Corrupt folder storage must throw")
        } catch {
            XCTAssertTrue(error is BrowserIntentEntityError)
        }
    }

    func testOversizedStorageThrows() async throws {
        let defaults = try makeDefaults()
        defaults.set(
            Data(count: BrowserIntentEntityStorage.maximumBytes + 1),
            forKey: BrowserIntentEntityStorage.groupsKey
        )
        do {
            _ = try await BrowserGroupEntityQuery(defaultsProvider: { defaults }).suggestedEntities()
            XCTFail("Oversized storage must throw")
        } catch {
            XCTAssertTrue(error is BrowserIntentEntityError)
        }
    }

    func testEntityCapsAtBound() async throws {
        let defaults = try makeDefaults()
        let groups = (0..<150).map { BrowserTabGroup(title: "Group \($0)") }
        defaults.set(try JSONEncoder().encode(groups), forKey: BrowserIntentEntityStorage.groupsKey)
        let all = try await BrowserGroupEntityQuery(defaultsProvider: { defaults }).suggestedEntities()
        XCTAssertEqual(all.count, BrowserIntentEntityStorage.maximumEntities)
    }

    func testEntityLookupResolvesBeyondSuggestionCap() async throws {
        let defaults = try makeDefaults()
        let groups = (0..<150).map { BrowserTabGroup(title: "Group \($0)") }
        defaults.set(try JSONEncoder().encode(groups), forKey: BrowserIntentEntityStorage.groupsKey)
        let query = BrowserGroupEntityQuery(defaultsProvider: { defaults })
        let target = groups[149]
        let found = try await query.entities(for: [target.id.uuidString])
        XCTAssertEqual(found.first?.id, target.id.uuidString)
        let all = try await query.suggestedEntities()
        XCTAssertEqual(all.count, BrowserIntentEntityStorage.maximumEntities)
        XCTAssertFalse(all.contains(where: { $0.id == target.id.uuidString }))
    }

    func testWebProviderEnumMapsToProviders() {
        XCTAssertEqual(BrowserIntentWebProvider.chatgpt.webAIProvider, .chatgpt)
        XCTAssertEqual(BrowserIntentWebProvider.gemini.webAIProvider, .gemini)
    }
}

final class BrowserIntentMetadataTests: XCTestCase {
    private func assertIntentMetadata<Intent: AppIntent>(
        _ type: Intent.Type,
        _ expectedTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            String(describing: Intent.title).contains(expectedTitle),
            "\(type) title must contain \(expectedTitle); got \(String(describing: Intent.title))",
            file: file,
            line: line
        )
        XCTAssertTrue(
            Intent.supportedModes.contains(.foreground),
            "\(type) must run in the foreground",
            file: file,
            line: line
        )
        XCTAssertEqual(Intent.authenticationPolicy, .requiresLocalDeviceAuthentication, file: file, line: line)
    }

    func testAllThirtyOneNativeIntentsPresent() {
        assertIntentMetadata(OpenBrowserURLIntent.self, "Open URL in Vortyra")
        assertIntentMetadata(SearchBrowserIntent.self, "Search in Vortyra")
        assertIntentMetadata(SearchClipboardBrowserIntent.self, "Search Clipboard in Vortyra")
        assertIntentMetadata(NewBrowserTabIntent.self, "New Vortyra Tab")
        assertIntentMetadata(NewPrivateBrowserTabIntent.self, "New Private Vortyra Tab")
        assertIntentMetadata(ReopenBrowserTabIntent.self, "Reopen Last Closed Tab")
        assertIntentMetadata(CloseBrowserTabIntent.self, "Close Current Vortyra Tab")
        assertIntentMetadata(CloseBrowserGroupIntent.self, "Close Tabs in Group")
        assertIntentMetadata(SwitchBrowserGroupIntent.self, "Switch to Tab Group")
        assertIntentMetadata(MoveBrowserTabIntent.self, "Move Tab to Group")
        assertIntentMetadata(BrowserBackIntent.self, "Go Back in Vortyra")
        assertIntentMetadata(BrowserForwardIntent.self, "Go Forward in Vortyra")
        assertIntentMetadata(ReloadBrowserPageIntent.self, "Reload Vortyra Page")
        assertIntentMetadata(SetBrowserReaderIntent.self, "Set Reader Mode")
        assertIntentMetadata(TranslateBrowserPageIntent.self, "Translate Vortyra Page")
        assertIntentMetadata(SetBrowserDesktopIntent.self, "Set Desktop Site Mode")
        assertIntentMetadata(FindBrowserTextIntent.self, "Find Text on Page")
        assertIntentMetadata(BookmarkBrowserPageIntent.self, "Bookmark Current Page")
        assertIntentMetadata(SaveBrowserReadingListIntent.self, "Save Page to Reading List")
        assertIntentMetadata(ExportBrowserPDFIntent.self, "Export Page as PDF")
        assertIntentMetadata(CopyBrowserLinkIntent.self, "Copy Page Title and URL")
        assertIntentMetadata(CaptureBrowserPageIntent.self, "Capture Page Screenshot")
        assertIntentMetadata(OpenBrowserHistoryIntent.self, "Open Last Matching History Page")
        assertIntentMetadata(BrowserSearchHistoryIntent.self, "Get Recorded Web Searches")
        assertIntentMetadata(OpenBrowserSplitIntent.self, "Open Websites Side by Side")
        assertIntentMetadata(EndBrowserSplitIntent.self, "End Split View")
        assertIntentMetadata(SummarizeBrowserPageIntent.self, "Summarize Current Page")
        assertIntentMetadata(AskBrowserLocalIntent.self, "Ask On-Device AI")
        assertIntentMetadata(SendBrowserPageToAIIntent.self, "Send Page to Web AI")
        assertIntentMetadata(DownloadBrowserURLIntent.self, "Download URL in Vortyra")
        assertIntentMetadata(DownloadBrowserVideoIntent.self, "Download Direct Page Video")
    }

    func testExistingAgentIntentsRemain() {
        XCTAssertTrue(String(describing: RunAgentTaskIntent.title).contains("Run Browser Task"))
        XCTAssertTrue(String(describing: RunSavedAgentTaskIntent.title).contains("Run Saved Browser Task"))
        XCTAssertTrue(RunAgentTaskIntent.supportedModes.contains(.foreground))
        XCTAssertTrue(RunSavedAgentTaskIntent.supportedModes.contains(.foreground))
    }

    func testShortcutProviderHasTenEntries() {
        XCTAssertEqual(BrowserAgentShortcuts.appShortcuts.count, 10)
    }
}
