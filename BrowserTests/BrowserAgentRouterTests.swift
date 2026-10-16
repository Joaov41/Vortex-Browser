import XCTest
@testable import Browser

final class BrowserAgentRouterTests: XCTestCase {
    private func isAgent(_ text: String) -> Bool {
        switch BrowserAgentRouter.route(text) {
        case .agent, .research: return true
        case .chat: return false
        }
    }

    func testActionsGoToAgent() {
        let actions = [
            "Click the sign up button",
            "open the first result",
            "Add the blue one to the cart",
            "search this site for running shoes",
            "can you book a table for two at 8pm",
            "Could you please scroll down and find the reviews",
            "help me fill out this form",
            "I’d like to sort by price",
            "go back",
            "Fetch the page at https://example.com",
            "Search the web for current product reviews",
            "Look up the current price online",
            "Find current coverage on the web",
            "Translate page to French",
            "Move over the menu",
            "Scroll this panel",
            "Find the phrase on this page",
            "Hide this banner",
            "Use the desktop site",
            "Request desktop site",
            "Split this page with https://example.com",
            "Take a screenshot of this page",
            "Capture the current page screenshot",
            "ok, add that one to the cart",
            "Show me the cheapest flight",
            "Log in"
        ]
        for text in actions {
            XCTAssertTrue(isAgent(text), text)
        }
    }

    func testDataAndFileRequestsGoToTheAgent() {
        // Seen on device: both went to chat, which answered "I can't create or attach a PDF".
        for text in [
            "Extract the concert dates on this page",
            "Now create the PDF",
            "now make a PDF of that",
            "Export it as CSV",
            "Save the results as a spreadsheet",
            "Scrape the prices",
            "Gather the opening hours",
            "Turn it into a PDF report"
        ] {
            XCTAssertEqual(BrowserAgentRouter.route(text), .agent(text), text)
        }
        let laptops = "Compare the price and battery life of these three laptops and make a PDF report."
        XCTAssertEqual(BrowserAgentRouter.route(laptops), .agent(laptops))
        guard case .agent(let search) = BrowserAgentRouter.route("/search when is the next Benfica home game?") else {
            return XCTFail("/search must reach the agent when the model has no quick lookup.")
        }
        XCTAssertTrue(search.hasPrefix("Search the web for: when is the next Benfica home game?"), search)
        for text in ["What is a PDF?", "Can you explain this report?", "Why does the file not open?", "How do I compare prices and make a PDF?"] {
            XCTAssertEqual(BrowserAgentRouter.route(text), .chat(text), text)
        }
    }

    func testOrdinaryPageAndResearchQuestionsStayOnChat() {
        let questions = [
            "What does this page say about product reviews?",
            "Can you explain the current price?",
            "Would searching the web help here?"
        ]
        for text in questions {
            XCTAssertEqual(BrowserAgentRouter.route(text), .chat(text), text)
        }
    }

    func testExplicitWebResearchUsesResearchPresetWhileOpenPageComparisonsKeepTheirRoute() {
        for request in [
            "Research current electric vehicle prices",
            "Find sources online for recent reviews",
            "Compare these laptop prices across websites",
            "Compare product sources online"
        ] {
            XCTAssertEqual(BrowserAgentRouter.route(request), .research(request), request)
            XCTAssertTrue(BrowserAgentRouter.isResearchIntent(request), request)
        }

        for request in [
            "Search the web for recent reviews",
            "Search online for a recipe",
            "Look up current coverage online",
            "Find current coverage on the web"
        ] {
            XCTAssertEqual(BrowserAgentRouter.route(request), .agent(request), request)
            XCTAssertFalse(BrowserAgentRouter.isResearchIntent(request), request)
        }

        for request in [
            "Compare these two pages",
            "Compare the tables on this page",
            "Compare these datasets"
        ] {
            XCTAssertEqual(BrowserAgentRouter.route(request), .agent(request), request)
            XCTAssertFalse(BrowserAgentRouter.isResearchIntent(request), request)
        }

        XCTAssertEqual(BrowserAgentRouter.route("/ask Research current prices"), .chat("Research current prices"))
        XCTAssertEqual(BrowserAgentRouter.route("/do Research current prices"), .agent("Research current prices"))
        XCTAssertTrue(BrowserAgentRouter.isResearchIntent("/do Research current prices"))
    }

    func testQuestionsGoToChat() {
        let questions = [
            "What is this article about?",
            "summarize this page",
            "Is this product waterproof?",
            "can you tell me who wrote this",
            "How much does the pro plan cost?",
            "Explain the second paragraph",
            "translate this to Portuguese",
            "settings for privacy — what do they mean?",
            "the price of the blue one",
            "Should we split this page?",
            "Why should I use the desktop site?",
            "What is a screenshot?"
        ]
        for text in questions {
            XCTAssertFalse(isAgent(text), text)
        }
    }

    func testPrefixesForceRoute() {
        XCTAssertEqual(BrowserAgentRouter.route("/do what's on sale"), .agent("what's on sale"))
        XCTAssertEqual(BrowserAgentRouter.route("/ask click here means what?"), .chat("click here means what?"))
        XCTAssertEqual(BrowserAgentRouter.route("/download the pdf"), .chat("/download the pdf"))
    }
}
