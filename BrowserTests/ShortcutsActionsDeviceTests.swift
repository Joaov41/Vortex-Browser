import AppIntents
import UIKit
import XCTest
@testable import Browser

/// Runs every Vortyra Shortcuts action's own `perform()` inside the real app on a connected device,
/// in an order where each action finds the page and tabs it needs. It does not use the Shortcuts app,
/// so nothing is added to the Shortcuts library.
///
/// Safety: Close Tabs, Close Tabs in Group, Delete Bookmarks and Clear History are never carried out;
/// only their confirmation step is checked, and declined. Save Page to Reading List is skipped because
/// it writes to Safari's Reading List. Tabs, bookmarks and the page watch the test creates are removed
/// at the end. Skipped in the simulator.
@MainActor
final class ShortcutsActionsDeviceTests: XCTestCase {
    private struct Outcome {
        let name: String
        let result: String
    }

    private var outcomes: [Outcome] = []
    private let lisbon = URL(string: "https://en.wikipedia.org/wiki/Lisbon#vortyra-test")!
    private let porto = URL(string: "https://en.wikipedia.org/wiki/Porto")!

    override func setUp() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Runs on a real device with the user's sign-ins.")
        #endif
        try await Task.sleep(for: .seconds(4))
    }

    func testEveryShortcutsActionInTheRealApp() async throws {
        let tabsBefore = Set(try await BrowserSchemaTabQuery().suggestedEntities().map(\.id))
        let bookmarksBefore = Set(try await BrowserSchemaBookmarkQuery().suggestedEntities().map(\.id))
        let watchesBefore = Set(((try? PageWatchCoordinator.shared.watches()) ?? []).map(\.id))

        // Open and navigate
        await run("Open URL in Vortyra") { let i = OpenBrowserURLIntent(); i.url = self.lisbon; _ = try await i.perform() }
        try await settle(6)
        await run("Find Text on Page") { let i = FindBrowserTextIntent(); i.query = "tram"; _ = try await i.perform() }
        await run("Search in Vortyra (find on page first)") { let i = SearchBrowserIntent(); i.query = "Alfama"; i.webOnly = false; _ = try await i.perform() }
        await run("Copy Page Title and URL") {
            _ = try await CopyBrowserLinkIntent().perform()
            let copied = UIPasteboard.general.string ?? ""
            guard copied.contains("wikipedia.org/wiki/Lisbon") else { throw Check.failed("clipboard has \(copied.prefix(80))") }
        }
        await command("Capture Page Screenshot", .screenshot)
        await command("Export Page as PDF", .exportPDF)
        await run("Bookmark Current Page") { _ = try await BookmarkBrowserPageIntent().perform() }
        skip("Save Page to Reading List", "writes to Safari's Reading List, which the test cannot undo")
        await command("Summarize Current Page", .summarize)
        try await settle(20)
        await run("Ask On-Device AI") { let i = AskBrowserLocalIntent(); i.question = "In one sentence, what is this page about?"; _ = try await i.perform() }
        await command("Send Page to Web AI", .sendToWebAI(.chatgpt))
        try await settle(20)
        await run("Set Reader Mode (on)") { let i = SetBrowserReaderIntent(); i.enabled = true; _ = try await i.perform() }
        await run("Set Reader Mode (off)") { let i = SetBrowserReaderIntent(); i.enabled = false; _ = try await i.perform() }
        await run("Set Desktop Site Mode (on)") { let i = SetBrowserDesktopIntent(); i.enabled = true; _ = try await i.perform() }
        try await settle(4)
        await run("Set Desktop Site Mode (off)") { let i = SetBrowserDesktopIntent(); i.enabled = false; _ = try await i.perform() }
        try await settle(4)
        await run("Translate Vortyra Page") { let i = TranslateBrowserPageIntent(); i.language = "Portuguese"; _ = try await i.perform() }
        try await settle(4)
        await run("Reload Vortyra Page") { _ = try await ReloadBrowserPageIntent().perform() }
        try await settle(5)
        await run("Load URL in Vortyra Tab") {
            let current = try await self.currentTabEntity()
            let i = LoadURLInBrowserTabSchemaIntent(); i.url = self.porto; i.tab = current; _ = try await i.perform()
        }
        try await settle(6)
        await run("Go Back in Vortyra") { _ = try await BrowserBackIntent().perform() }
        try await settle(4)
        await run("Go Forward in Vortyra") { _ = try await BrowserForwardIntent().perform() }
        try await settle(4)

        // Tabs
        await run("New Vortyra Tab") { _ = try await NewBrowserTabIntent().perform() }
        try await settle(2)
        await run("Create Tab in Vortyra") { let i = CreateBrowserTabSchemaIntent(); i.url = self.lisbon; i.isPrivate = false; _ = try await i.perform() }
        try await settle(6)
        await run("Find Text on Vortyra Page") {
            let current = try await self.currentTabEntity()
            let i = FindOnBrowserPageSchemaIntent(); i.searchPhrase = "Tagus"; i.tab = current; _ = try await i.perform()
        }
        await run("Bookmark Vortyra Tab") {
            let current = try await self.currentTabEntity()
            let i = BookmarkBrowserTabSchemaIntent(); i.tab = current; i.name = "Vortyra test bookmark #vortyra-test"; _ = try await i.perform()
        }
        await run("Switch to Tab in Vortyra") {
            let tabs = try await BrowserSchemaTabQuery().suggestedEntities()
            guard let other = tabs.dropFirst().first else { throw Check.failed("only one tab open") }
            let i = SwitchToBrowserTabSchemaIntent(); i.target = other; _ = try await i.perform()
        }
        await run("Switch to Vortyra Tab") {
            guard let tab = try await OpenTabEntityQuery().suggestedEntities().dropFirst().first else { throw Check.failed("no other tab") }
            let i = SwitchToVortyraTabIntent(); i.target = tab; _ = try await i.perform()
        }
        await run("Open Websites Side by Side") { let i = OpenBrowserSplitIntent(); i.firstURL = self.lisbon; i.secondURL = self.porto; _ = try await i.perform() }
        try await settle(6)
        await run("End Split View") { _ = try await EndBrowserSplitIntent().perform() }
        try await settle(2)
        await command("Close Current Vortyra Tab", .closeCurrentTab)
        try await settle(2)
        await run("Reopen Last Closed Tab") { _ = try await ReopenBrowserTabIntent().perform() }
        try await settle(4)
        await run("New Private Vortyra Tab") { _ = try await NewPrivateBrowserTabIntent().perform() }
        try await settle(2)
        // Leave the private tab for a regular one: Shortcuts actions only act on regular tabs.
        await run("Switch back to a regular tab") {
            guard let tab = try await BrowserSchemaTabQuery().suggestedEntities().first else { throw Check.failed("no regular tab") }
            let i = SwitchToBrowserTabSchemaIntent(); i.target = tab; _ = try await i.perform()
        }
        if #available(iOS 27.0, *) {
            await run("Search Web in Vortyra") { let i = SearchBrowserInAppSchemaIntent(); i.criteria = StringSearchCriteria(term: "zzqx trams Lisbon"); _ = try await i.perform() }
        } else {
            skip("Search Web in Vortyra", "needs iOS 27")
        }
        try await settle(5)
        await run("Search Clipboard in Vortyra") {
            UIPasteboard.general.string = "Lisbon tram 28 route"
            _ = try await SearchClipboardBrowserIntent().perform()
        }
        try await settle(5)

        // Groups
        if let group = try await BrowserGroupEntityQuery().suggestedEntities().first {
            await run("Move Tab to Group") { let i = MoveBrowserTabIntent(); i.group = group; _ = try await i.perform() }
            await run("Switch to Tab Group") { let i = SwitchBrowserGroupIntent(); i.group = group; _ = try await i.perform() }
        } else {
            skip("Move Tab to Group", "no tab group exists")
            skip("Switch to Tab Group", "no tab group exists")
        }

        // Bookmarks and history
        await run("Open Bookmark in Vortyra") {
            guard let bookmark = try await BookmarkEntityQuery().suggestedEntities().first else { throw Check.failed("no bookmarks") }
            let i = OpenBookmarkInVortyraIntent(); i.target = bookmark; _ = try await i.perform()
        }
        try await settle(4)
        await run("Open Bookmark in Vortyra Tab") {
            guard let bookmark = try await BrowserSchemaBookmarkQuery().suggestedEntities().first else { throw Check.failed("no bookmarks") }
            let i = OpenBrowserBookmarkSchemaIntent(); i.target = bookmark; i.tab = try await self.currentTabEntity(); _ = try await i.perform()
        }
        try await settle(4)
        await command("Open Last Matching History Page", .openHistoryMatch("Lisbon"))
        try await settle(4)
        await run("Open History Page in Vortyra") {
            guard let entry = try await HistoryEntityQuery().suggestedEntities().first else { throw Check.failed("no history entities (Spotlight history may be off)") }
            let i = OpenHistoryEntryInVortyraIntent(); i.target = entry; _ = try await i.perform()
        }
        try await settle(4)
        await command("Get Recorded Web Searches", .searchesOn(Date()))

        // Downloads
        await command("Download URL in Vortyra", .downloadURL(URL(string: "https://www.w3.org/TR/PNG/iso_8859-1.txt")!))
        await run("Download Direct Page Video", expectFailureOn: "no direct video on a Wikipedia page") { _ = try await DownloadBrowserVideoIntent().perform() }

        // Page watches
        await run("Watch Page") {
            let i = WatchPageIntent(); i.pageAddress = self.porto; i.watchTitle = "Vortyra test watch"; i.interval = .daily; _ = try await i.perform()
        }
        await run("Check Watched Pages") { _ = try await CheckWatchedPagesIntent().perform() }

        // Result cards and agent tasks
        await run("Browser Task Result Card") {
            let i = AgentRunResultSnippetIntent(); i.taskTitle = "Test"; i.status = "Completed"; i.outcome = "Done."; i.sourceDomains = ""; _ = try await i.perform()
        }
        await run("Page Summary Card") { let i = PageSummarySnippetIntent(); i.summary = "A test summary."; i.pageTitle = "Lisbon"; i.pageAddress = self.lisbon; _ = try await i.perform() }
        await run("Copy Browser Task Result") { let i = CopyAgentRunResultIntent(); i.outcome = "Vortyra test result"; _ = try await i.perform() }
        await run("Get Last Browser Task Result") { _ = try await GetLastAgentRunResultIntent().perform() }
        await run("Open Browser Task in Vortyra") {
            guard let record = try? AgentTaskStoreLocation.makeDefaultStore(bundleIdentifier: Bundle.main.bundleIdentifier), (try? record.load()) != nil,
                  let last = record.history.first else { throw Check.failed("no run history") }
            let i = OpenAgentRunInVortyraIntent(); i.runID = last.id.uuidString; _ = try await i.perform()
        }
        try await settle(3)
        await run("Run Browser Task") {
            let i = RunAgentTaskIntent(); i.task = "Read the page title and tell me"; i.startURL = self.lisbon; _ = try await i.perform()
        }
        try await settle(45)
        await run("Run Browser Task and Get Result") {
            let i = RunAgentTaskAndWaitIntent(); i.task = "Read the page title and tell me"; i.startURL = self.porto; i.timeoutSeconds = 150; _ = try await i.perform()
        }
        if let saved = try await AgentTaskEntityQuery().suggestedEntities().first {
            await run("Run Saved Browser Task and Get Result") { let i = RunSavedAgentTaskAndWaitIntent(); i.savedTask = saved; i.timeoutSeconds = 150; _ = try await i.perform() }
            await run("Run Saved Browser Task") { let i = RunSavedAgentTaskIntent(); i.savedTask = saved; _ = try await i.perform() }
            try await settle(45)
            await run("Open Saved Browser Task") { let i = OpenSavedAgentTaskIntent(); i.target = saved; _ = try await i.perform() }
            try await settle(45)
        } else {
            for name in ["Run Saved Browser Task and Get Result", "Run Saved Browser Task", "Open Saved Browser Task"] { skip(name, "no saved task") }
        }
        await run("Research a Topic") {
            let i = ResearchTopicIntent(); i.topic = "Lisbon tram 28 history"; i.openSourcesInTabs = false; i.makePDF = false; i.timeoutSeconds = 300; _ = try await i.perform()
        }

        // Destructive actions: only the confirmation step, declined.
        await confirmOnly("Close Tabs in Vortyra") {
            let ids = try await BrowserSchemaTabQuery().suggestedEntities().compactMap { UUID(uuidString: $0.id) }
            return .closeTabs(Array(ids.prefix(1)))
        }
        await confirmOnly("Delete Vortyra Bookmarks") {
            let ids = try await BrowserSchemaBookmarkQuery().suggestedEntities().compactMap { UUID(uuidString: $0.id) }
            return .deleteBookmarks(Array(ids.prefix(1)))
        }
        await confirmOnly("Clear Vortyra History") { .clearHistory(Date().addingTimeInterval(-3600)) }
        if let group = try await BrowserGroupEntityQuery().suggestedEntities().first, let id = UUID(uuidString: group.id) {
            await confirmOnly("Close Tabs in Group") { .closeGroup(id) }
        } else {
            skip("Close Tabs in Group", "no tab group exists")
        }

        // Clean up what this test created.
        // Only bookmarks this test made: their address or name carries #vortyra-test.
        let newBookmarks = try await BrowserSchemaBookmarkQuery().entities(matching: "vortyra-test")
            .filter { !bookmarksBefore.contains($0.id) && ($0.url.absoluteString.contains("vortyra-test") || $0.name.contains("vortyra-test")) }
            .compactMap { UUID(uuidString: $0.id) }
        if !newBookmarks.isEmpty {
            _ = try? await BrowserIntentRuntime.shared.perform(.deleteBookmarks(newBookmarks)) { _ in }
        }
        let newTabs = try await BrowserSchemaTabQuery().suggestedEntities()
            .filter { !tabsBefore.contains($0.id) }.compactMap { UUID(uuidString: $0.id) }
        if !newTabs.isEmpty {
            _ = try? await BrowserIntentRuntime.shared.perform(.closeTabs(newTabs)) { _ in }
        }
        if let store = try? PageWatchStoreLocation.makeDefaultStore() {
            try? store.load()
            for watch in store.watches where !watchesBefore.contains(watch.id) && watch.title == "Vortyra test watch" {
                try? store.deleteWatch(id: watch.id)
            }
        }
        // Read only: list bookmarks earlier test runs may have left, for the person to review.
        var leftovers: [String] = []
        for term in ["Vortyra test", "Lisbon", "carbonara"] {
            for bookmark in (try? await BrowserSchemaBookmarkQuery().entities(matching: term)) ?? [] {
                leftovers.append("\(bookmark.name) — \(bookmark.url.absoluteString)")
            }
        }
        print("LEFTOVER-BOOKMARKS\n" + Set(leftovers).sorted().joined(separator: "\n") + "\nEND-LEFTOVERS")
        record("Cleanup", "removed \(newBookmarks.count) test bookmarks, \(newTabs.count) test tabs and the test page watch")

        let report = outcomes.map { "\($0.result.hasPrefix("ok") ? "✅" : $0.result.hasPrefix("skipped") ? "⏭️" : "❌") \($0.name): \($0.result)" }
            .joined(separator: "\n")
        print("SHORTCUTS-ACTIONS-REPORT\n" + report + "\nEND-REPORT")
        let attachment = XCTAttachment(string: report)
        attachment.name = "shortcuts-actions-report"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Helpers

    private enum Check: Error, CustomStringConvertible {
        case failed(String)
        var description: String { if case .failed(let message) = self { return message }; return "" }
    }

    private func run(_ name: String, expectFailureOn reason: String? = nil, _ body: () async throws -> Void) async {
        do {
            try await body()
            record(name, "ok")
        } catch {
            if let reason {
                record(name, "ok (expected refusal: \(reason)) — \(error.localizedDescription)")
            } else {
                record(name, "FAILED — \(error.localizedDescription) [\(error)]")
            }
        }
        try? await Task.sleep(for: .seconds(1))
    }

    /// Runs an action's command through the app's runtime, the path Shortcuts reaches after it hands over,
    /// for actions whose results (files and cards) only work inside the Shortcuts runtime.
    private func command(_ name: String, _ command: BrowserIntentCommand) async {
        do {
            let output = try await BrowserIntentRuntime.shared.perform(command) { _ in }
            let file = output.fileData.map { " + file \(output.filename ?? "") (\($0.count) bytes)" } ?? ""
            record(name, "ok — \(output.text.prefix(120))\(file)")
        } catch {
            record(name, "FAILED — \(error.localizedDescription) [\(error)]")
        }
        try? await Task.sleep(for: .seconds(1))
    }

    /// Runs a destructive command through the app's runtime and declines its confirmation.
    private func confirmOnly(_ name: String, _ makeCommand: () async throws -> BrowserIntentCommand) async {
        var asked = ""
        do {
            let command = try await makeCommand()
            _ = try await BrowserIntentRuntime.shared.perform(command) { message in
                asked = message
                throw CancellationError()
            }
            record(name, asked.isEmpty ? "FAILED — ran without asking first" : "FAILED — continued after a declined confirmation")
        } catch {
            record(name, asked.isEmpty ? "FAILED — \(error.localizedDescription)" : "ok (asked first: \"\(asked.prefix(90))\", declined, nothing changed)")
        }
    }

    private func skip(_ name: String, _ reason: String) {
        record(name, "skipped — \(reason)")
    }

    private func record(_ name: String, _ result: String) {
        outcomes.append(Outcome(name: name, result: result))
        print("ACTION \(name): \(result)")
    }

    private func settle(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private func currentTabEntity() async throws -> BrowserSchemaTabEntity {
        guard let tab = try await BrowserSchemaTabQuery().suggestedEntities().first else { throw Check.failed("no open tab") }
        return tab
    }
}
