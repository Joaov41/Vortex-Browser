import AppIntents
import Foundation
import WebKit
import XCTest
@testable import Browser

@MainActor
final class BrowserIntentsPageModeTests: BrowserIntentsExecutorTestCase {
    func testBackForwardWithoutHistoryFails() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let (executor, confirm) = makeExecutor(harness)
        do {
            _ = try await executor.execute(.back, confirm: confirm)
            XCTFail("Back without history must throw")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
        let reload = try await executor.execute(.reload, confirm: confirm)
        XCTAssertEqual(reload.text, "Requested a reload of the current page.")
    }

    func testPrivateAndProviderTabsRejectedForPageCommands() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let privateTab = addTab(harness, incognito: true)
        harness.viewModel.selectedTabID = privateTab.id
        let (executor, confirm) = makeExecutor(harness)
        do {
            _ = try await executor.execute(.reload, confirm: confirm)
            XCTFail("Private tab must be rejected")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .noEligiblePage)
        }
        let providerTab = addTab(harness, provider: .chatgpt)
        providerTab.activateWebView().loadHTMLString("<p>x</p>", baseURL: URL(string: "https://chatgpt.com"))
        harness.viewModel.selectedTabID = providerTab.id
        do {
            _ = try await executor.execute(.reload, confirm: confirm)
            XCTFail("Provider tab must be rejected")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .noEligiblePage)
        }
    }

    func testReaderModeIdempotentAndToggle() async throws {
        let harness = try makeHarness()
        let (tab, _) = try await loadPage(harness)
        let (executor, confirm) = makeExecutor(harness)
        let already = try await executor.execute(.setReader(false), confirm: confirm)
        XCTAssertEqual(already.text, "Reader mode is already off.")
        let output = try await executor.execute(.setReader(true), confirm: confirm)
        XCTAssertEqual(output.text, "Reader mode is on.")
        XCTAssertTrue(tab.isReaderMode)
    }

    func testSetDesktopOnlyAffectsBoundTab() async throws {
        let harness = try makeHarness()
        let (tab, _) = try await loadPage(harness)
        let other = addTab(harness, url: "https://other.example")
        harness.viewModel.selectedTabID = tab.id
        let (executor, confirm) = makeExecutor(harness)
        let otherBaseline = other.useDesktopUserAgent
        let output = try await executor.execute(.setDesktop(true), confirm: confirm)
        XCTAssertEqual(output.text, "Desktop site mode requested for this tab.")
        XCTAssertTrue(tab.useDesktopUserAgent)
        XCTAssertEqual(other.useDesktopUserAgent, otherBaseline)
    }

    func testTranslateValidatesTagAndCallsCallback() async throws {
        let harness = try makeHarness()
        let (tab, _) = try await loadPage(harness)
        let (executor, confirm) = makeExecutor(harness)
        do {
            _ = try await executor.execute(.translate("en); DROP TABLE"), confirm: confirm)
            XCTFail("Invalid tag must be rejected")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
        let output = try await executor.execute(.translate("pt-BR"), confirm: confirm)
        XCTAssertEqual(
            output.text,
            "Translation prepared; Vortyra may ask to download a language. Check the page for completion."
        )
        XCTAssertEqual(harness.recorded.translateCalls.count, 1)
        XCTAssertEqual(harness.recorded.translateCalls.first?.0.id, tab.id)
        XCTAssertEqual(harness.recorded.translateCalls.first?.1, "pt-BR")
        XCTAssertEqual(harness.recorded.translatePredicate?(), true)
    }

    func testSiriSearchFindsOnThePageFirstAndSearchesTheWebOnlyWhenMissing() async throws {
        // Reported on device: "search for X in Vortyra" opened a search-engine tab instead of finding X on the page.
        let harness = try makeHarness()
        _ = try await loadPage(harness, html: "<main><p>alpha berry alpha</p></main>")
        let (executor, confirm) = makeExecutor(harness)
        let tabsBefore = harness.viewModel.tabs.count

        let onPage = try await executor.execute(.findOnPageOrSearch("alpha"), confirm: confirm)
        XCTAssertTrue(onPage.text.hasPrefix("Found ") && onPage.text.contains("for alpha"), onPage.text)
        XCTAssertEqual(harness.viewModel.tabs.count, tabsBefore, "Text on the page must not open a search tab.")

        let missing = try await executor.execute(.findOnPageOrSearch("zebra"), confirm: confirm)
        XCTAssertTrue(missing.text.contains("isn't on this page"), missing.text)
        XCTAssertEqual(harness.viewModel.tabs.count, tabsBefore + 1, "Only missing text searches the web.")
        let searchTab = try XCTUnwrap(harness.viewModel.tabs.last)
        XCTAssertTrue(searchTab.currentURL?.absoluteString.contains("zebra") == true, "\(String(describing: searchTab.currentURL))")
    }

    func testFindTextUsesRealPageAndSafeQuery() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(
            harness,
            html: "<main><p>alpha berry alpha</p><p>berry alpha</p></main>"
        )
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.findText("alpha"), confirm: confirm)
        XCTAssertTrue(output.text.contains("Found"))
        XCTAssertTrue(output.text.contains("3"), "Expected 3 visible matches, got: \(output.text)")

        let injected = try await executor.execute(
            .findText("alpha');document.title='pwned';//"),
            confirm: confirm
        )
        XCTAssertFalse(injected.text.contains("Found"), "Injected query must not match or run")
        let injectedCall = harness.recorded.jsCalls.last { $0.0 == BrowserAgentInteractionScript.find }
        XCTAssertEqual(
            injectedCall?.1["query"] as? String,
            "alpha');document.title='pwned';//",
            "The query must reach the page as an argument, not as interpolated script"
        )
    }

    func testBookmarkPreservesExistingFolderWhenUnspecified() async throws {
        let harness = try makeHarness()
        let folder = harness.viewModel.createFavoriteFolder(named: "Research", in: nil)
        let (tab, _) = try await loadPage(harness)
        harness.viewModel.addToFavorites(tab)
        guard let favorite = harness.viewModel.favorites.first else {
            return XCTFail("Bookmark fixture missing")
        }
        harness.viewModel.moveFavorite(favorite, toFolder: folder.id)
        let (executor, confirm) = makeExecutor(harness)
        _ = try await executor.execute(.bookmark(nil), confirm: confirm)
        XCTAssertEqual(harness.viewModel.favorites.count, 1)
        XCTAssertEqual(harness.viewModel.favorites.first?.folderID, folder.id)
    }

    func testReadingListCreatesSingleFolder() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let (executor, confirm) = makeExecutor(harness)
        _ = try await executor.execute(.readingList, confirm: confirm)
        _ = try await executor.execute(.readingList, confirm: confirm)
        let readingLists = harness.viewModel.favoriteFolders.filter {
            $0.title.caseInsensitiveCompare("Reading List") == .orderedSame
        }
        XCTAssertEqual(readingLists.count, 1)
        XCTAssertEqual(harness.viewModel.favorites.first?.folderID, readingLists.first?.id)
    }

    func testHistoryMatchOpensMostRecentEntry() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        harness.history.record(url: try XCTUnwrap(URL(string: "https://old.example/match")), title: "match old")
        try await Task.sleep(nanoseconds: 20_000_000)
        harness.history.record(url: try XCTUnwrap(URL(string: "https://new.example/match")), title: "match new")
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.openHistoryMatch("match"), confirm: confirm)
        let opened = try XCTUnwrap(harness.viewModel.tabs.last)
        XCTAssertEqual(opened.url?.absoluteString, "https://new.example/match")
        XCTAssertTrue(output.text.contains("new.example"))
    }

    func testHistoryMatchDeclineOpensNothing() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        harness.history.record(url: try XCTUnwrap(URL(string: "https://x.example/match")), title: "match")
        let (executor, _) = makeExecutor(harness)
        let tabCount = harness.viewModel.tabs.count
        do {
            _ = try await executor.execute(.openHistoryMatch("match"), confirm: decline)
            XCTFail("Decline must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(harness.viewModel.tabs.count, tabCount)
    }

    func testSearchesOnHalfOpenDateAndEnginePaths() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let (executor, _) = makeExecutor(harness)
        harness.history.record(url: try XCTUnwrap(URL(string: "https://www.google.com/search?q=swift")), title: "swift")
        harness.history.record(url: try XCTUnwrap(URL(string: "https://duckduckgo.com/?q=vortyra")), title: "vortyra")
        harness.history.record(
            url: try XCTUnwrap(URL(string: "https://google.com.evil.net/search?q=fake")),
            title: "fake"
        )
        harness.history.record(url: try XCTUnwrap(URL(string: "https://www.google.com/maps?q=paris")), title: "maps")
        let output = try await executor.execute(.searchesOn(noon), confirm: { _ in })
        XCTAssertTrue(output.text.contains("Searches recorded in regular browsing history"))
        XCTAssertTrue(output.text.contains("swift"))
        XCTAssertTrue(output.text.contains("vortyra"))
        XCTAssertFalse(output.text.contains("fake"))
        XCTAssertFalse(output.text.contains("paris"))
    }

    func testSearchesOnSeededDayBoundaries() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let todayStart = utc.startOfDay(for: Date())
        let dayStart = try XCTUnwrap(utc.date(byAdding: .day, value: -1, to: todayStart))
        let noon = dayStart.addingTimeInterval(43_200)
        let nextStart = dayStart.addingTimeInterval(86_400)
        func entry(_ raw: String, _ visited: Date) throws -> HistoryEntry {
            HistoryEntry(
                id: UUID(),
                url: try XCTUnwrap(URL(string: raw)),
                title: "x",
                visitedAt: visited
            )
        }
        let entries = try [
            entry("https://www.google.com/search?q=at-start", dayStart),
            entry("https://www.google.com/search?q=just-before", dayStart.addingTimeInterval(-1)),
            entry("https://duckduckgo.com/?q=at-noon", noon),
            entry("https://www.google.com/search?q=next-day", nextStart),
            entry("https://user:pw@www.google.com/search?q=cred", noon),
            entry("https://www.google.com/searchx?q=wrongpath", noon),
            entry("https://google.com.evil.net/search?q=fake", noon)
        ]
        let historyDir = harness.scratch.appendingPathComponent("seeded-history", isDirectory: true)
        let folder = historyDir.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: folder.appendingPathComponent("history.json"))
        let store = HistoryStore(directory: historyDir)
        let executor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: store,
            isCurrent: { harness.current.value },
            backendProvider: { .chatGPTPlan },
            calendar: utc
        )
        let output = try await executor.execute(.searchesOn(noon), confirm: { _ in })
        XCTAssertTrue(output.text.contains("Searches recorded in regular browsing history"))
        XCTAssertTrue(output.text.contains("at-start"))
        XCTAssertTrue(output.text.contains("at-noon"))
        XCTAssertFalse(output.text.contains("just-before"))
        XCTAssertFalse(output.text.contains("next-day"))
        XCTAssertFalse(output.text.contains("cred"))
        XCTAssertFalse(output.text.contains("wrongpath"))
        XCTAssertFalse(output.text.contains("fake"))
    }

    func testSearchesOnDeclineReadsNothing() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        harness.history.record(url: try XCTUnwrap(URL(string: "https://www.google.com/search?q=secret")), title: "x")
        let (executor, _) = makeExecutor(harness)
        do {
            _ = try await executor.execute(.searchesOn(Date()), confirm: decline)
            XCTFail("Decline must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
