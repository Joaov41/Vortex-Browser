import UIKit
import XCTest
@testable import Browser

@MainActor
final class AgentSnippetTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    // MARK: - Helpers

    private func makeSnapshot(
        runID: UUID = UUID(),
        isPrivate: Bool = false,
        outcome: String = "Found three results.",
        status: AgentRunStatus = .completed,
        sources: [BrowserLookupSource] = []
    ) -> BrowserAgentController.CompletionSnapshot {
        BrowserAgentController.CompletionSnapshot(
            runID: runID,
            task: "Find three results",
            outcome: outcome,
            actions: [],
            date: Date(timeIntervalSinceReferenceDate: 2_000),
            backend: "test",
            preset: "standard",
            startURL: nil,
            isPrivate: isPrivate,
            savedTaskID: nil,
            sources: sources,
            requestID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 1_900),
            status: status,
            exportedFiles: []
        )
    }

    private func parsedURL(_ string: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        try XCTUnwrap(URL(string: string), "Test URL did not parse: \(string)", file: file, line: line)
    }

    private func assertRunLinkRejected(_ string: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try parsedURL(string, file: file, line: line)
        XCTAssertThrowsError(try AgentRunURLParser.parse(url), "Accepted \(string)", file: file, line: line) { error in
            XCTAssertEqual(error as? AgentRunURLParseError, .malformedRunURL, file: file, line: line)
        }
        XCTAssertThrowsError(try AgentIncomingURLRouter.route(url), "Router accepted \(string)", file: file, line: line)
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    // MARK: - Run route grammar

    func testRunRouteAcceptsOneValidUUID() throws {
        let runID = UUID()
        let built = try XCTUnwrap(AgentRunURLParser.url(for: runID))
        XCTAssertEqual(built.absoluteString, "webmebrowser://run?id=\(runID.uuidString)")
        XCTAssertEqual(try AgentRunURLParser.parse(built), runID)
        XCTAssertEqual(try AgentIncomingURLRouter.route(built), .run(runID))

        let lowercase = try parsedURL("webmebrowser://run?id=\(runID.uuidString.lowercased())")
        XCTAssertEqual(try AgentRunURLParser.parse(lowercase), runID)
    }

    func testRunRouteRejectsAMissingID() throws {
        try assertRunLinkRejected("webmebrowser://run")
        try assertRunLinkRejected("webmebrowser://run?")
        try assertRunLinkRejected("webmebrowser://run?id=")
        try assertRunLinkRejected("webmebrowser://run?runID=\(UUID().uuidString)")
    }

    func testRunRouteRejectsTwoIDs() throws {
        let first = UUID().uuidString
        let second = UUID().uuidString
        try assertRunLinkRejected("webmebrowser://run?id=\(first)&id=\(second)")
        try assertRunLinkRejected("webmebrowser://run?id=\(first)&id=\(first)")
    }

    func testRunRouteRejectsExtraParameters() throws {
        let runID = UUID().uuidString
        try assertRunLinkRejected("webmebrowser://run?id=\(runID)&text=hello")
        try assertRunLinkRejected("webmebrowser://run?text=hello&id=\(runID)")
        try assertRunLinkRejected("webmebrowser://run?id=\(runID)&")
    }

    func testRunRouteRejectsNonUUIDValues() throws {
        try assertRunLinkRejected("webmebrowser://run?id=not-a-uuid")
        try assertRunLinkRejected("webmebrowser://run?id=1234")
        try assertRunLinkRejected("webmebrowser://run?id=\(UUID().uuidString)x")
        try assertRunLinkRejected("webmebrowser://run?id=%20\(UUID().uuidString)")
    }

    func testRunRouteRejectsUserPortFragmentAndPath() throws {
        let runID = UUID().uuidString
        try assertRunLinkRejected("webmebrowser://user@run?id=\(runID)")
        try assertRunLinkRejected("webmebrowser://user:secret@run?id=\(runID)")
        try assertRunLinkRejected("webmebrowser://run:8443?id=\(runID)")
        try assertRunLinkRejected("webmebrowser://run?id=\(runID)#detail")
        try assertRunLinkRejected("webmebrowser://run/extra?id=\(runID)")
    }

    func testRouteForOtherHostsIsUnchangedAndNeverRunRoute() throws {
        let runID = UUID().uuidString
        let file = URL(fileURLWithPath: "/tmp/bookmarks.html")
        XCTAssertEqual(try AgentIncomingURLRouter.route(file, cloudShortcutWasHandled: true), .bookmarkFile(file))

        let web = try parsedURL("https://example.test/?id=\(runID)")
        XCTAssertEqual(try AgentIncomingURLRouter.route(web), .defaultBrowserLink(web))

        let cloud = try parsedURL("webmebrowser://shortcut/success?requestID=\(runID)")
        XCTAssertEqual(try AgentIncomingURLRouter.route(cloud, cloudShortcutWasHandled: true), .cloudShortcut(cloud))
        XCTAssertEqual(try AgentIncomingURLRouter.route(cloud), .sharedPayload)

        let agent = try parsedURL("webmebrowser://agent?task=read%20the%20page")
        guard case .agentTask(let pending) = try AgentIncomingURLRouter.route(agent) else {
            return XCTFail("The agent route must keep its precedence.")
        }
        XCTAssertEqual(pending.task, "read the page")

        let shared = try parsedURL("webmebrowser://share?text=hello%2Bworld")
        XCTAssertEqual(try AgentIncomingURLRouter.route(shared), .sharedText("hello+world"))
        let payload = try parsedURL("webmebrowser://share")
        XCTAssertEqual(try AgentIncomingURLRouter.route(payload), .sharedPayload)

        // A host that only looks like "run" is an ordinary unknown webmebrowser link.
        let lookalike = try parsedURL("webmebrowser://runner?id=\(runID)")
        XCTAssertEqual(try AgentIncomingURLRouter.route(lookalike), .sharedPayload)
        XCTAssertNil(try AgentRunURLParser.parse(lookalike))
        XCTAssertNil(try AgentRunURLParser.parse(shared))
        XCTAssertNil(try AgentRunURLParser.parse(agent))
    }

    // MARK: - Result card text limits

    func testOutcomeIsLimitedToTwelveLines() {
        let text = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let model = AgentRunSnippetModel(taskTitle: "T", status: "completed", outcome: text, sourceDomains: [], runID: nil)

        XCTAssertTrue(model.isOutcomeTruncated)
        let shown = lines(model.outcomeText)
        XCTAssertEqual(shown.count, AgentSnippetText.maximumLines)
        XCTAssertEqual(shown.first, "line 1")
        XCTAssertTrue(model.outcomeText.hasSuffix("…"))
    }

    func testOutcomeWithExactlyTwelveLinesIsNotTruncated() {
        let text = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let model = AgentRunSnippetModel(taskTitle: "T", status: "completed", outcome: text, sourceDomains: [], runID: nil)

        XCTAssertFalse(model.isOutcomeTruncated)
        XCTAssertEqual(model.outcomeText, text)
    }

    func testOutcomeIsLimitedToTwelveHundredCharacters() {
        let long = String(repeating: "a", count: 2_000)
        let model = AgentRunSnippetModel(taskTitle: "T", status: "completed", outcome: long, sourceDomains: [], runID: nil)

        XCTAssertTrue(model.isOutcomeTruncated)
        XCTAssertEqual(model.outcomeText.count, AgentSnippetText.maximumCharacters + 1)
        XCTAssertTrue(model.outcomeText.hasSuffix("…"))
        XCTAssertEqual(model.copyableOutcome, long, "Copy Result keeps the full outcome, not the card's shortened text.")
    }

    func testShortAndEmptyOutcomesAreShownPlainly() {
        let short = AgentRunSnippetModel(taskTitle: "T", status: "completed", outcome: "  Done.  ", sourceDomains: [], runID: nil)
        XCTAssertEqual(short.outcomeText, "Done.")
        XCTAssertFalse(short.isOutcomeTruncated)

        let empty = AgentRunSnippetModel(taskTitle: "T", status: "completed", outcome: " \n ", sourceDomains: [], runID: nil)
        XCTAssertEqual(empty.outcomeText, AgentRunSnippetModel.emptyOutcomeText)
        XCTAssertFalse(empty.isOutcomeTruncated)
    }

    func testTaskTitleFallsBackWhenBlankAndIsBounded() {
        let blank = AgentRunSnippetModel(taskTitle: "   ", status: "completed", outcome: "x", sourceDomains: [], runID: nil)
        XCTAssertEqual(blank.taskTitle, "Browser task")

        let long = AgentRunSnippetModel(
            taskTitle: String(repeating: "t", count: 300),
            status: "completed",
            outcome: "x",
            sourceDomains: [],
            runID: nil
        )
        XCTAssertEqual(long.taskTitle.count, AgentRunSnippetModel.maximumTitleCharacters)
    }

    func testCopyLimitMatchesTheStoredOutcomeLimit() {
        XCTAssertEqual(AgentSnippetText.maximumCopyCharacters, AgentTaskStore.maximumOutcomeCharacters)
    }

    // MARK: - Source domains

    func testSourceDomainsAreUniqueWithoutWWWAndAtMostThree() throws {
        let urls = [
            try parsedURL("https://www.example.com/a"),
            try parsedURL("https://example.com/b"),
            try parsedURL("https://news.test/x"),
            try parsedURL("https://shop.test/y"),
            try parsedURL("https://blog.test/z"),
        ]
        XCTAssertEqual(AgentSnippetText.domains(from: urls), ["example.com", "news.test", "shop.test"])
    }

    func testSourceDomainsSkipNonWebAddresses() throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/export.csv"),
            try parsedURL("webmebrowser://agent?task=x"),
            try parsedURL("ftp://files.test/readme"),
            try parsedURL("https://kept.test/page"),
        ]
        XCTAssertEqual(AgentSnippetText.domains(from: urls), ["kept.test"])
    }

    func testSnippetModelReceivesDomainsFromFields() throws {
        let fields = AgentRunResultFields(
            outcome: "Done",
            status: "completed",
            taskTitle: "Compare",
            finishedAt: now,
            sources: [try parsedURL("https://www.one.test/a"), try parsedURL("https://two.test/b")],
            files: [],
            fileNotes: []
        )
        XCTAssertEqual(AgentRunResultSnippetIntent(fields: fields).model.sourceDomains, ["one.test", "two.test"])
    }

    // MARK: - Status labels

    func testStatusLabelsAreHumanReadable() {
        XCTAssertEqual(AgentRunSnippetModel.statusText(for: "completed"), "Completed")
        XCTAssertEqual(AgentRunSnippetModel.statusText(for: "stopped"), "Stopped")
        XCTAssertEqual(AgentRunSnippetModel.statusText(for: "failed"), "Failed")
        XCTAssertEqual(AgentRunSnippetModel.statusText(for: "stepLimit"), "Stopped at the step limit")
        XCTAssertEqual(AgentRunSnippetModel.statusText(for: "stillRunning"), "Still running in Vortyra")
        XCTAssertEqual(AgentRunSnippetModel.statusText(for: "rejected"), "Could not start")
        XCTAssertEqual(AgentRunSnippetModel.statusText(for: "cancelled"), "Waiting stopped")
        XCTAssertEqual(AgentRunSnippetModel.statusText(for: "unknown"), "Status not recorded")
        XCTAssertEqual(AgentRunSnippetModel.statusText(for: "something-new"), "Status not recorded")
    }

    // MARK: - Open in Vortyra gating

    func testOpenButtonIsShownOnlyWhenThereIsAStoredRun() {
        let stored = AgentRunSnippetModel(taskTitle: "T", status: "completed", outcome: "x", sourceDomains: [], runID: UUID())
        XCTAssertTrue(stored.showsOpenInVortyra)

        let unstored = AgentRunSnippetModel(taskTitle: "T", status: "completed", outcome: "x", sourceDomains: [], runID: nil)
        XCTAssertFalse(unstored.showsOpenInVortyra)
    }

    func testFinishedNonPrivateRunCarriesItsRunIDToTheSnippet() {
        let snapshot = makeSnapshot()
        let result = AgentRunResultIntentSupport.makeResult(for: .finished(snapshot), taskTitle: "Find", now: now)
        XCTAssertEqual(result.snippet.model.runID, snapshot.runID)
        XCTAssertTrue(result.snippet.model.showsOpenInVortyra)
        XCTAssertEqual(result.snippet.model.copyableOutcome, snapshot.outcome)
    }

    func testPrivateRunsHaveNoOpenButton() {
        let snapshot = makeSnapshot(isPrivate: true, outcome: "Secret text.")
        let result = AgentRunResultIntentSupport.makeResult(for: .finished(snapshot), taskTitle: "Private", now: now)
        XCTAssertNil(result.snippet.runID)
        XCTAssertFalse(result.snippet.model.showsOpenInVortyra)
        XCTAssertEqual(result.snippet.model.outcomeText, AgentRunResultMapper.privateRunOutcome)
        XCTAssertEqual(result.snippet.model.sourceDomains, [])
    }

    func testTimeoutRejectionAndCancellationHaveNoOpenButton() {
        let timedOut = AgentRunResultIntentSupport.makeResult(for: .timedOut, taskTitle: "Slow", now: now)
        XCTAssertFalse(timedOut.snippet.model.showsOpenInVortyra)
        XCTAssertEqual(timedOut.snippet.model.statusText, "Still running in Vortyra")

        let rejected = AgentRunResultIntentSupport.makeResult(for: .rejected("Page changed."), taskTitle: "Refused", now: now)
        XCTAssertFalse(rejected.snippet.model.showsOpenInVortyra)
        XCTAssertEqual(rejected.snippet.model.statusText, "Could not start")

        let cancelled = AgentRunResultIntentSupport.makeResult(for: .cancelled, taskTitle: "Stopped", now: now)
        XCTAssertFalse(cancelled.snippet.model.showsOpenInVortyra)
    }

    func testStoredHistoryRecordCarriesItsIDAndPrivateRecordDoesNot() {
        let stored = AgentRunRecord(task: "Saved", outcome: "Done", actions: [], date: now, backend: "test", preset: "standard")
        let storedFields = AgentRunResultMapper.fields(for: stored, taskTitle: "Saved")
        XCTAssertEqual(storedFields.runID, stored.id)
        XCTAssertTrue(AgentRunResultSnippetIntent(fields: storedFields).model.showsOpenInVortyra)

        var privateRecord = stored
        privateRecord.isPrivate = true
        let privateFields = AgentRunResultMapper.fields(for: privateRecord, taskTitle: "Private")
        XCTAssertNil(privateFields.runID)
        XCTAssertFalse(AgentRunResultSnippetIntent(fields: privateFields).model.showsOpenInVortyra)
    }

    func testSnippetCarriesRunIDAndAtMostThreeDomains() {
        let runID = UUID()
        let intent = AgentRunResultSnippetIntent(
            taskTitle: "T", status: "completed", outcome: "x", sourceDomains: ["a.test", "b.test", "c.test", "d.test"], runID: runID
        )
        XCTAssertEqual(intent.model.runID, runID)
        XCTAssertEqual(intent.model.sourceDomains, ["a.test", "b.test", "c.test"], "The snippet carries at most three domains.")

        let none = AgentRunResultSnippetIntent(taskTitle: "T", status: "completed", outcome: "x", sourceDomains: [], runID: nil)
        XCTAssertNil(none.runID)
        XCTAssertNil(none.model.runID)
    }

    func testSnippetIntentsAreNotDiscoverable() {
        XCTAssertFalse(AgentRunResultSnippetIntent.isDiscoverable)
        XCTAssertFalse(OpenAgentRunInVortyraIntent.isDiscoverable)
        XCTAssertFalse(CopyAgentRunResultIntent.isDiscoverable)
        XCTAssertFalse(PageSummarySnippetIntent.isDiscoverable)
    }

    func testOpenIntentRejectsAnInvalidRunID() async {
        var intent = OpenAgentRunInVortyraIntent()
        intent.runID = "not-a-uuid"
        do {
            _ = try await intent.perform()
            XCTFail("An invalid run ID must not open anything.")
        } catch {
            XCTAssertEqual(error as? AgentRunSnippetError, .runUnavailable)
        }
    }

    func testCopyIntentPutsTheOutcomeOnThePasteboardWithoutOpeningTheApp() async throws {
        UIPasteboard.general.string = "before"
        _ = try await CopyAgentRunResultIntent(outcome: "Copied outcome text.").perform()
        XCTAssertEqual(UIPasteboard.general.string, "Copied outcome text.")

        _ = try await CopyAgentRunResultIntent(outcome: "   ").perform()
        XCTAssertEqual(UIPasteboard.general.string, "Copied outcome text.", "An empty outcome must not replace the pasteboard.")
    }

    // MARK: - Page summary card

    func testPageSummaryShowsTitleDomainAndOpenPageForAWebPage() throws {
        let model = PageSummarySnippetModel(
            pageTitle: "  Example Article  ",
            pageURL: try parsedURL("https://www.example.org/article?x=1"),
            summary: "A short summary."
        )
        XCTAssertEqual(model.title, "Example Article")
        XCTAssertEqual(model.domain, "example.org")
        XCTAssertEqual(model.summaryText, "A short summary.")
        XCTAssertFalse(model.isSummaryTruncated)
        XCTAssertNotNil(model.pageURL)
    }

    func testPageSummaryFallsBackToTheDomainWhenTheTitleIsBlank() throws {
        let model = PageSummarySnippetModel(pageTitle: " ", pageURL: try parsedURL("https://news.test/a"), summary: "x")
        XCTAssertEqual(model.title, "news.test")
    }

    func testPageSummaryWithoutAPageAddressHasNoOpenButtonOrInventedDomain() {
        let model = PageSummarySnippetModel(pageTitle: "Only a title", pageURL: nil, summary: "x")
        XCTAssertEqual(model.title, "Only a title")
        XCTAssertNil(model.domain)
        XCTAssertNil(model.pageURL)

        let untitled = PageSummarySnippetModel(pageTitle: nil, pageURL: nil, summary: "x")
        XCTAssertEqual(untitled.title, PageSummarySnippetModel.fallbackTitle)
    }

    func testPageSummaryRefusesNonWebAddresses() throws {
        let model = PageSummarySnippetModel(pageTitle: "Local", pageURL: URL(fileURLWithPath: "/tmp/page.html"), summary: "x")
        XCTAssertNil(model.pageURL)
        XCTAssertNil(model.domain)
        XCTAssertEqual(model.title, "Local")
    }

    func testPageSummaryLimitsTitleAndSummary() throws {
        let url = try parsedURL("https://example.test/")
        let longTitle = String(repeating: "t", count: 400)
        let manyLines = (1...30).map { "row \($0)" }.joined(separator: "\n")
        let model = PageSummarySnippetModel(pageTitle: longTitle, pageURL: url, summary: manyLines)

        XCTAssertEqual(model.title.count, PageSummarySnippetModel.maximumTitleCharacters)
        XCTAssertTrue(model.isSummaryTruncated)
        XCTAssertEqual(lines(model.summaryText).count, AgentSnippetText.maximumLines)
    }

    func testPageSummaryUsesTheEmptyFallbackForAnEmptySummary() {
        let model = PageSummarySnippetModel(pageTitle: "T", pageURL: nil, summary: "  ")
        XCTAssertEqual(model.summaryText, PageSummarySnippetModel.emptySummaryText)
    }
}
