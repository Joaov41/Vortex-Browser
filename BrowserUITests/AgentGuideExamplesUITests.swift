import XCTest

/// Runs the agent guide's example requests on a real device with the user's own ChatGPT Plan sign-in.
/// Each example opens its starting page from the address bar and is typed into the AI panel, as a user would. Approvals are always declined and questions skipped, so the
/// agent never buys, sends, posts, deletes or saves anything. Screenshots and the screen's text are
/// attached to the result bundle for review.
final class AgentGuideExamplesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        await MainActor.run {
            app = XCUIApplication()
            app.launchArguments = ["-VortyraUITestKeepAwake"]
            app.launch()
        }
    }

    // MARK: Examples from "What to ask"

    @MainActor func test01ExtractThenFollowUpPDF() {
        queue("Extract the concert dates on this page", url: "https://en.wikipedia.org/wiki/Everything_or_Nothing_at_All_Tour")
        finishRun(named: "01a-extract")
        followUp("Now create the PDF")
        finishRun(named: "01b-follow-up-pdf")
    }

    @MainActor func test02SearchHeadphones() {
        queue("Find the search box, search for \"wireless headphones\" and tell me the top 3 results with prices.", url: "https://www.ebay.com")
        finishRun(named: "02-search-headphones")
    }

    @MainActor func test03FillContactForm() {
        queue("Fill this contact form with my details and ask for a quote on 20 pallets.", url: "https://httpbin.org/forms/post")
        finishRun(named: "03-fill-form")
    }

    @MainActor func test04CookieBannerAndReviews() {
        queue("Close the cookie banner and scroll to the reviews.", url: "https://www.imdb.com/title/tt0111161/")
        finishRun(named: "04-cookie-reviews")
    }

    @MainActor func test05CarrierTracking() {
        queue("Go to my carrier's tracking page, enter MSCU1234567 and tell me the ETA.", url: "https://www.msc.com/en/track-a-shipment")
        finishRun(named: "05-tracking")
    }

    @MainActor func test06ExtractTableCSV() {
        queue("Extract the table of ships on this page and export it as CSV.", url: "https://en.wikipedia.org/wiki/List_of_largest_container_ships")
        finishRun(named: "06-table-csv")
    }

    @MainActor func test07CollectPDFLinks() {
        queue("Collect every PDF link on this page.", url: "https://www.irs.gov/forms-instructions")
        finishRun(named: "07-pdf-links")
    }

    @MainActor func test08CompareLaptopsPDF() {
        queue("Compare the price and battery life of the MacBook Air 13, Dell XPS 13 and Lenovo ThinkPad X1 Carbon and make a PDF report.", url: "https://www.google.com")
        finishRun(named: "08-compare-laptops", timeout: 480)
    }

    @MainActor func test09TabGroup() {
        queue("Open two more tabs about Lisbon hotels, then put all my tabs about Lisbon hotels into a tab group called Trip.", url: "https://www.booking.com/city/pt/lisbon.html")
        finishRun(named: "09-tab-group")
    }

    @MainActor func test10BookmarkInFolder() {
        queue("Bookmark this page in my Recipes folder.", url: "https://www.bbcgoodfood.com/recipes/pasta-carbonara")
        finishRun(named: "10-bookmark")
    }

    @MainActor func test11SideBySide() {
        queue("Open the English and Portuguese versions side by side.", url: "https://www.visitportugal.com/en")
        finishRun(named: "11-side-by-side")
    }

    @MainActor func test12TranslateAndReader() {
        queue("Translate this page and turn on reader mode.", url: "https://www.publico.pt")
        finishRun(named: "12-translate-reader")
    }

    @MainActor func test13Research() {
        queue("Research the best e-bikes under €2000.", url: "https://www.google.com")
        finishRun(named: "13-research", timeout: 600)
    }

    @MainActor func test14CalendarHandoff() {
        queue("Find the next Benfica home match and add it to my calendar.", url: "https://www.slbenfica.pt/en-us")
        finishRun(named: "14-calendar")
    }

    // MARK: Commands (/do, /ask, /search)

    @MainActor func test30DoCommand() {
        openPage("https://www.rtings.com/headphones/reviews/best/by-type/wireless")
        sendToAgent("/do add the cheapest option to the comparison table")
        finishRun(named: "30-do-command")
    }

    @MainActor func test31AskCommand() {
        openPage("https://www.apple.com/legal/internet-services/itunes/us/terms.html")
        sendChat("/ask what does this contract say about cancellation?")
        attach("31-ask-command-result", screenshot: true)
        XCTAssertFalse(app.buttons["Stop agent"].exists, "/ask must answer as chat, without starting the agent.")
    }

    @MainActor func test32SearchCommand() {
        openPage("https://www.google.com")
        sendChat("/search when is the next Benfica home game?")
        attach("32-search-command-result", screenshot: true)
    }

    // MARK: Research and other apps

    @MainActor func test33ResearchInTabsPDF() {
        openPage("https://www.google.com")
        sendToAgent("Research noise-cancelling headphones in tabs and export a PDF report.")
        finishRun(named: "33-research-tabs-pdf", timeout: 600)
    }

    @MainActor func test34CompareReturnPolicies() {
        openPage("https://www.google.com")
        sendToAgent("Compare the return policies of three phone shops across websites.")
        finishRun(named: "34-return-policies", timeout: 600)
    }

    @MainActor func test35TableCSVEmail() {
        queue("Extract the container table, export it as CSV and email it to me.", url: "https://en.wikipedia.org/wiki/List_of_largest_container_ships")
        finishRun(named: "35-csv-email")
    }

    @MainActor func test36PassportReminder() {
        queue("Find when the passport office opens tomorrow and remind me.", url: "https://www.google.com")
        finishRun(named: "36-passport-reminder")
    }

    @MainActor func test37CompareThreeOpenLaptops() {
        openPage("https://www.apple.com/macbook-air/specs/")
        openInNewTab("https://www.dell.com/en-us/shop/dell-laptops/xps-13-laptop/spd/xps-13-9350-laptop")
        openInNewTab("https://www.lenovo.com/us/en/p/laptops/thinkpad/thinkpadx1/thinkpad-x1-carbon-gen-13-14-inch-intel/len101t0111")
        sendToAgent("Compare the price and battery life of these three laptops and make a PDF report.")
        finishRun(named: "37-three-laptops-pdf", timeout: 480)
    }

    // MARK: Saved tasks, history, teach mode, page watches

    @MainActor func test38SaveRunAndHistory() {
        queue("Find the page title and tell me", url: "https://en.wikipedia.org/wiki/Lisbon")
        finishRun(named: "38a-run")
        tapIfPresent(app.buttons["Save Run as Task"], "38b-save-run")
        tapIfPresent(app.buttons["Save Task"], "38c-save-editor")
        tapIfPresent(app.buttons["Saved agent tasks and history"], "38d-library")
        attach("38d-library-tasks", screenshot: true)
        tapIfPresent(app.buttons["History"], "38e-history")
        let firstRun = app.cells.firstMatch
        tapIfPresent(firstRun, "38f-run-detail")
        attach("38f-run-detail", screenshot: true)
        tapIfPresent(app.buttons["Run Again"], "38g-run-again")
        if app.buttons["Stop agent"].waitForExistence(timeout: 30) { finishRun(named: "38g-run-again") }
    }

    @MainActor func test39TeachMode() {
        openPage("https://en.wikipedia.org/wiki/Lisbon")
        showAISidebarIfNeeded()
        tapIfPresent(app.buttons["Saved agent tasks and history"], "39a-library")
        tapIfPresent(app.buttons["Record a New Task"], "39b-record")
        attach("39b-recording", screenshot: true)
        let link = app.links.matching(NSPredicate(format: "label CONTAINS[c] 'Portugal'")).firstMatch
        tapIfPresent(link, "39c-tap-link")
        Thread.sleep(forTimeInterval: 4)
        tapIfPresent(app.buttons["Stop"], "39d-stop")
        attach("39d-save-recorded", screenshot: true)
        tapIfPresent(app.buttons["Save Task"], "39e-saved")
        attach("39e-saved", screenshot: true)
    }

    @MainActor func test40PageWatch() {
        openPage("https://en.wikipedia.org/wiki/Special:Random")
        tapIfPresent(app.buttons["Page options"], "40a-menu")
        attach("40a-menu", screenshot: true)
        tapIfPresent(app.buttons["Watch This Page…"], "40b-watch-sheet")
        attach("40b-watch-sheet", screenshot: true)
        tapIfPresent(app.buttons["Watch Page"], "40c-saved")
        showAISidebarIfNeeded()
        tapIfPresent(app.buttons["Saved agent tasks and history"], "40d-library")
        tapIfPresent(app.buttons["Watches"], "40e-watches")
        attach("40e-watches", screenshot: true)
    }

    // MARK: Siri

    /// "Search for X in Vortyra" should find X on the page on screen (find bar), not open a web search.
    @MainActor func test20SiriSearchFindsOnPage() {
        openPage("https://en.wikipedia.org/wiki/Lisbon")
        attach("siri-before", screenshot: true)
        XCUIDevice.shared.siriService.activate(voiceRecognitionText: "Search for tram in Vortyra")
        Thread.sleep(forTimeInterval: 15)
        attach("siri-search-on-page", screenshot: true)
        app.activate()
        Thread.sleep(forTimeInterval: 3)
        attach("siri-search-on-page-app", screenshot: true)
    }

    // MARK: Driving the app

    /// Opens the starting page from the address bar, then sends the request to the agent with /do.
    @MainActor private func queue(_ task: String, url: String) {
        openPage(url)
        sendToAgent("/do " + task)
        attach("start", screenshot: true)
    }

    @MainActor private func openPage(_ url: String) {
        let address = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'connection' OR label == 'Focus Address Bar'")).firstMatch
        guard address.waitForExistence(timeout: 20) else {
            attach("no-address-bar", screenshot: true)
            return XCTFail("The address bar was not found.")
        }
        address.tap()
        let field = app.textFields.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        guard field.waitForExistence(timeout: 5) else {
            attach("no-address-field", screenshot: true)
            return XCTFail("The address field did not take the keyboard.")
        }
        // The field opens with the current address in it; clear it so the new address replaces it.
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        field.typeText(url + "\n")
        Thread.sleep(forTimeInterval: 8)
        attach("page-loaded", screenshot: true)
    }

    /// Sends a message that should be answered as chat; waits for the reply to arrive.
    @MainActor private func sendChat(_ text: String) {
        showAISidebarIfNeeded()
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Ask'")).firstMatch
        guard field.waitForExistence(timeout: 20) else { return XCTFail("The AI panel's input field was not found.") }
        for _ in 0..<5 where !(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false) {
            field.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        field.typeText(text)
        app.buttons["Send message"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 45)
    }

    @MainActor private func openInNewTab(_ url: String) {
        let visibleNewTab = app.buttons.matching(identifier: "New Tab").allElementsBoundByIndex.first { $0.isHittable }
        tapIfPresent(visibleNewTab ?? app.buttons["New Tab"].firstMatch, "new-tab")
        let field = app.textFields.matching(NSPredicate(format: "hasKeyboardFocus == true OR placeholderValue == 'Search or enter address'")).firstMatch
        if field.waitForExistence(timeout: 5) {
            if !(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false) { field.tap() }
            field.typeText(url + "\n")
            Thread.sleep(forTimeInterval: 8)
        } else {
            openPage(url)
        }
        attach("new-tab-loaded", screenshot: true)
    }

    /// Taps the element if it shows up; otherwise records a screenshot and a failure, and carries on.
    @MainActor private func tapIfPresent(_ element: XCUIElement, _ name: String) {
        if element.waitForExistence(timeout: 10), element.isHittable {
            element.tap()
            Thread.sleep(forTimeInterval: 2)
        } else {
            attach("missing-\(name)", screenshot: true)
            XCTFail("\(name): element not found")
        }
    }

    @MainActor private func sendToAgent(_ text: String) {
        showAISidebarIfNeeded()
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Ask'")).firstMatch
        guard field.waitForExistence(timeout: 20) else {
            attach("no-input-field", screenshot: true)
            return XCTFail("The AI panel's input field was not found.")
        }
        // A finished reply can still be animating in; tap until the field really has the keyboard.
        for _ in 0..<5 where !(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false) {
            field.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        field.typeText(text)
        app.buttons["Send message"].firstMatch.tap()
        let started = app.buttons["Stop agent"].waitForExistence(timeout: 60)
        XCTAssertTrue(started, "\"\(text)\" did not start the agent.")
    }

    /// Types a follow-up into the AI panel and sends it.
    @MainActor private func followUp(_ text: String) {
        sendToAgent(text)
        attach("follow-up-start", screenshot: true)
    }

    /// Waits for the run to end, declining every approval and skipping every question, then records the result.
    @MainActor private func finishRun(named name: String, timeout: TimeInterval = 300) {
        let deadline = Date().addingTimeInterval(timeout)
        var approvals = 0
        var questions = 0
        while app.buttons["Stop agent"].exists, Date() < deadline {
            if app.buttons["Decline"].exists {
                approvals += 1
                attach("\(name)-approval-\(approvals)", screenshot: true)
                app.buttons["Decline"].firstMatch.tap()
            } else if app.buttons["Skip"].exists, app.buttons["Send"].exists {
                questions += 1
                attach("\(name)-question-\(questions)", screenshot: true)
                app.buttons["Skip"].firstMatch.tap()
            }
            Thread.sleep(forTimeInterval: 2)
        }
        let ended = !app.buttons["Stop agent"].exists
        if !ended {
            attach("\(name)-timeout", screenshot: true)
            app.buttons["Stop agent"].firstMatch.tap()
        }
        Thread.sleep(forTimeInterval: 2)
        attach("\(name)-result", screenshot: true)
        // Screenshots only: dumping the screen's text failed on large or changing pages and stopped the runner.
        XCTAssertTrue(ended, "\(name) was still running after \(Int(timeout)) seconds.")
    }

    /// Opens the AI panel unless it is already open. The app opens it by itself for queued tasks,
    /// so give it a moment and only tap a button that is still there.
    @MainActor private func showAISidebarIfNeeded() {
        if app.buttons["Hide AI sidebar"].waitForExistence(timeout: 4) { return }
        let show = app.buttons["Show AI sidebar"]
        if show.exists, show.isHittable { show.tap() }
    }

    @MainActor private func attach(_ name: String, screenshot: Bool) {
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
