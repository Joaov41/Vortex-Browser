import XCTest
import WebKit
@testable import Browser

@MainActor
final class BrowserAppleWebLookupTests: XCTestCase {
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private final class ScriptedLookupEngine: BrowserAgentEngine {
        typealias Body = @MainActor (
            BrowserAgentEngineRequest,
            @escaping BrowserAgentToolExecutor,
            @escaping BrowserAgentNoteHandler
        ) async throws -> String
        let profile: BrowserAgentEngineProfile
        private let body: Body

        init(profile: BrowserAgentEngineProfile? = nil, body: @escaping Body) {
            self.profile = profile ?? .chatGPTPlan(supportsVision: false)
            self.body = body
        }

        func prepare() async throws {}

        func run(
            request: BrowserAgentEngineRequest,
            execute: @escaping BrowserAgentToolExecutor,
            onNote: @escaping BrowserAgentNoteHandler
        ) async throws -> String {
            try await body(request, execute, onNote)
        }
    }


    private final class ContinuationGate<T> {
        private var continuation: CheckedContinuation<T, Never>?
        private var buffered: T?
        private(set) var isAwaiting = false

        func awaitValue() async -> T {
            if let buffered { self.buffered = nil; return buffered }
            return await withCheckedContinuation { cont in
                self.continuation = cont
                self.isAwaiting = true
            }
        }

        func resume(_ value: T) {
            if let continuation {
                self.continuation = nil
                self.isAwaiting = false
                continuation.resume(returning: value)
            } else {
                buffered = value
            }
        }
    }

    private final class LookupHarness {
        var generated: [(instructions: String, body: String, backend: AIModelBackend)] = []
        var fetched: [URL] = []
        var stores: [WKWebsiteDataStore] = []
        var policies: [BrowserAgentBackgroundLoader.FetchURLPolicy?] = []
        var pages: [URL: BrowserAgentBackgroundLoader.Page] = [:]
        var failures: Set<URL> = []
        var fetchOverride: ((URL) -> URL?)? = nil

        func makeLookup(answer: String = "The next Foo Fighters concert is June 5, 2027 in Chicago [1].") -> BrowserAppleWebLookup {
            BrowserAppleWebLookup(
                generate: { [weak self] instructions, body, backend in
                    self?.generated.append((instructions: instructions, body: body, backend: backend))
                    return answer
                },
                fetch: { [weak self] url, store, _, collect, policy in
                    guard let self else { throw CancellationError() }
                    self.fetched.append(url)
                    self.stores.append(store)
                    self.policies.append(policy)
                    if self.failures.contains(url) {
                        throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
                    }
                    guard let page = self.pages[url] else {
                        throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
                    }
                    if let finalURL = self.fetchOverride?(url), finalURL != page.url {
                        var moved = page
                        moved = BrowserAgentBackgroundLoader.Page(
                            title: page.title, url: finalURL, text: page.text,
                            truncated: page.truncated, searchLinks: page.searchLinks
                        )
                        return moved
                    }
                    return page
                }
            )
        }
    }

    private func page(
        _ url: String,
        title: String = "Source",
        text: String = "Readable source text",
        links: [BrowserAgentBackgroundLoader.SearchLink] = []
    ) -> BrowserAgentBackgroundLoader.Page {
        BrowserAgentBackgroundLoader.Page(
            title: title,
            url: URL(string: url)!,
            text: text,
            truncated: false,
            searchLinks: links
        )
    }

    private func link(_ title: String, _ url: String) -> BrowserAgentBackgroundLoader.SearchLink {
        BrowserAgentBackgroundLoader.SearchLink(title: title, url: URL(string: url)!)
    }

    // MARK: Agent-mode send routing

    func testAutomaticLookupRouteOfferedOnlyForAppleBackends() {
        for backend in [AIModelBackend.localApple, .cloudShortcuts] {
            XCTAssertEqual(
                BrowserAppleWebLookup.requestMode(text: "find foo fighters next concert", backend: backend),
                .automatic("find foo fighters next concert")
            )
            XCTAssertEqual(
                BrowserAppleWebLookup.requestMode(text: "/search foo fighters tour", backend: backend),
                .webLookup("foo fighters tour")
            )
            XCTAssertEqual(
                BrowserAppleWebLookup.requestMode(text: "/ask what is this page", backend: backend),
                .legacyRouter
            )
            XCTAssertEqual(
                BrowserAppleWebLookup.requestMode(text: "/do click the button", backend: backend),
                .legacyRouter
            )
        }
        for backend in [AIModelBackend.chatGPTPlan, .webChatGPT, .webGemini, .mlxLocal] {
            XCTAssertNil(BrowserAppleWebLookup.requestMode(text: "find foo fighters next concert", backend: backend))
            XCTAssertNil(BrowserAppleWebLookup.requestMode(text: "/search foo fighters", backend: backend))
        }
        XCTAssertEqual(BrowserAgentRouter.route("/ask what is this"), .chat("what is this"))
        XCTAssertEqual(BrowserAgentRouter.route("/do click save"), .agent("click save"))
    }

    // MARK: Classifier

    func testClassifierMapsValidLabelsAndMalformedOutputToClarify() async throws {
        var labels = ["LOOKUP", "PAGE", "BROWSER", "CLARIFY", "lookup extra", "", "BROWSER LOOKUP", "search"]
        let expected: [BrowserAppleWebLookup.Route] = [.lookup, .page, .browser, .clarify, .clarify, .clarify, .clarify, .clarify]
        var bodies: [String] = []
        var instructionCopies: [String] = []
        var backends: [AIModelBackend] = []
        let lookup = BrowserAppleWebLookup(generate: { instructions, body, backend in
            instructionCopies.append(instructions)
            bodies.append(body)
            backends.append(backend)
            return labels.removeFirst()
        }, fetch: { _, _, _, _, _ in
            throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
        })
        for expectedRoute in expected {
            let route = try await lookup.classify(task: "find the next Foo Fighters concert", backend: .localApple)
            XCTAssertEqual(route, expectedRoute)
        }
        XCTAssertTrue(instructionCopies.allSatisfy { $0 == BrowserAppleWebLookup.routingInstructions })
        XCTAssertTrue(bodies.allSatisfy { $0 == "User request:\nfind the next Foo Fighters concert" })
        XCTAssertTrue(backends.allSatisfy { $0 == .localApple })
    }

    func testClassifierRejectsEmptyLongAndNonAppleTasksWithoutGenerating() async throws {
        var generateCalls = 0
        let lookup = BrowserAppleWebLookup(generate: { _, _, _ in
            generateCalls += 1
            return "LOOKUP"
        }, fetch: { _, _, _, _, _ in
            throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
        })
        let longTask = String(repeating: "a", count: 241)
        for task in ["", "   ", longTask] {
            let route = try await lookup.classify(task: task, backend: .localApple)
            XCTAssertEqual(route, .clarify)
        }
        for backend in [AIModelBackend.chatGPTPlan, .webChatGPT, .webGemini, .mlxLocal] {
            let route = try await lookup.classify(task: "find the next concert", backend: backend)
            XCTAssertEqual(route, .clarify)
        }
        XCTAssertEqual(generateCalls, 0)
    }

    // MARK: Pipeline

    func testLookupReadsBoundedSourcesAndGeneratesOneAnswer() async throws {
        let harness = LookupHarness()
        let searchURL = URL(string: "https://www.google.com/search?q=foo+fighters")!
        harness.pages[searchURL] = page("https://www.google.com/search?q=foo+fighters", links: [
            link("Tour dates", "https://tour.example/dates"),
            link("News", "https://news.example/foo"),
            link("Checkout link", "https://shop.example/checkout"),
            link("Duplicate", "https://news.example/foo"),
            link("Local", "https://internal.local/foo")
        ])
        let filler = String(repeating: "Navigation menu links and footer boilerplate text. ", count: 40)
        harness.pages[URL(string: "https://tour.example/dates")!] = page(
            "https://tour.example/dates",
            title: "Foo Fighters Tour",
            text: filler + " The Foo Fighters concert in Chicago is on June 5, 2027 at Soldier Field."
        )
        harness.pages[URL(string: "https://news.example/foo")!] = page(
            "https://news.example/foo",
            title: "Foo News",
            text: "Foo Fighters announced an extra Foo Fighters concert date for 2026."
        )
        let lookup = harness.makeLookup()
        let frozen = ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")!
        let originalStore = WKWebsiteDataStore.default()
        let policy: BrowserAgentBackgroundLoader.FetchURLPolicy = { _, _ in true }
        let result = try await lookup.lookup(
            task: "find foo fighters next concert in the us",
            backend: .localApple,
            searchURL: searchURL,
            isPrivate: false,
            urlPolicy: policy,
            now: frozen
        )

        XCTAssertLessThanOrEqual(harness.fetched.count, 6)
        XCTAssertEqual(harness.fetched.first, searchURL)
        XCTAssertEqual(harness.generated.count, 1)
        XCTAssertEqual(harness.generated.first?.backend, .localApple)
        let body = try XCTUnwrap(harness.generated.first?.body)
        XCTAssertTrue(body.contains("Today (UTC): 2026-10-13"))
        XCTAssertTrue(body.contains("Question: find foo fighters next concert in the us"))
        XCTAssertTrue(body.contains("Source excerpts (partial, not full pages):"))
        XCTAssertTrue(body.contains("June 5, 2027"), "Excerpt ranking must keep the later concert date: \(body)")
        XCTAssertLessThanOrEqual(body.utf8.count, 3_000, "Local bodies stay inside the on-device context budget")
        XCTAssertEqual(harness.generated.first?.instructions, BrowserAppleWebLookup.answerInstructions)
        XCTAssertEqual(result.sources.map(\.url), [
            URL(string: "https://tour.example/dates")!,
            URL(string: "https://news.example/foo")!
        ])
        XCTAssertEqual(result.sources.map(\.id), [1, 2])
        XCTAssertEqual(result.sources.map(\.isPrivate), [false, false])
        XCTAssertEqual(result.answer, "The next Foo Fighters concert is June 5, 2027 in Chicago [1].")
        XCTAssertTrue(harness.stores.allSatisfy { $0 !== originalStore && !$0.isPersistent })
    }

    func testLookupSkipsFailedSourcesAndDeduplicatesFinalRedirectURLs() async throws {
        let harness = LookupHarness()
        let searchURL = URL(string: "https://duckduckgo.com/?q=foo")!
        let shared = URL(string: "https://shared.example/article")!
        harness.pages[searchURL] = page("https://duckduckgo.com/?q=foo", links: [
            link("A", "https://a.example/one"),
            link("B", "https://b.example/two"),
            link("C", "https://c.example/three"),
            link("D", "https://d.example/four")
        ])
        harness.pages[URL(string: "https://a.example/one")!] = page("https://a.example/one", title: "A", text: "Alpha text")
        harness.pages[URL(string: "https://b.example/two")!] = page("https://b.example/two", title: "B", text: "Beta text")
        harness.pages[URL(string: "https://c.example/three")!] = page("https://c.example/three", title: "C", text: "Gamma text")
        harness.pages[URL(string: "https://d.example/four")!] = page("https://d.example/four", title: "D", text: "Delta text")
        harness.failures.insert(URL(string: "https://b.example/two")!)
        harness.fetchOverride = { url in
            switch url.absoluteString {
            case "https://a.example/one", "https://c.example/three": return shared
            default: return nil
            }
        }
        let lookup = harness.makeLookup()
        let result = try await lookup.lookup(
            task: "find foo",
            backend: .cloudShortcuts,
            searchURL: searchURL,
            isPrivate: true,
            urlPolicy: nil
        )
        XCTAssertEqual(result.sources.map(\.url), [shared, URL(string: "https://d.example/four")!])
        XCTAssertTrue(result.sources.allSatisfy(\.isPrivate))
        XCTAssertEqual(harness.generated.first?.backend, .cloudShortcuts)
        XCTAssertTrue(
            harness.stores.allSatisfy { !$0.isPersistent },
            "Lookup must never reuse the signed-in store."
        )
    }

    func testLookupWithoutReadableSourcesNeverGeneratesAndReturnsNoCards() async throws {
        let harness = LookupHarness()
        let searchURL = URL(string: "https://www.google.com/search?q=x")!
        harness.pages[searchURL] = page("https://www.google.com/search?q=x", links: [
            link("one", "https://one.example/"),
            link("two", "https://two.example/")
        ])
        harness.failures.formUnion([
            URL(string: "https://one.example/")!,
            URL(string: "https://two.example/")!
        ])
        let emptyLinksLookup = harness.makeLookup()
        var result = try await emptyLinksLookup.lookup(
            task: "find foo", backend: .localApple, searchURL: searchURL,
            isPrivate: false, urlPolicy: nil
        )
        XCTAssertTrue(result.sources.isEmpty)
        XCTAssertEqual(result.answer, BrowserAppleWebLookup.noSearchResultsMessage)
        XCTAssertEqual(harness.generated.count, 0)

        let harness2 = LookupHarness()
        harness2.pages[searchURL] = page("https://www.google.com/search?q=x", links: [])
        let lookup2 = harness2.makeLookup()
        result = try await lookup2.lookup(
            task: "find foo", backend: .localApple, searchURL: searchURL,
            isPrivate: false, urlPolicy: nil
        )
        XCTAssertTrue(result.sources.isEmpty)
        XCTAssertEqual(harness2.generated.count, 0)
    }

    func testBadCitationsOrModelURLsProduceUnverifiedAnswerWithCards() async throws {
        let harness = LookupHarness()
        let searchURL = URL(string: "https://www.google.com/search?q=x")!
        harness.pages[searchURL] = page("https://www.google.com/search?q=x", links: [
            link("one", "https://one.example/")
        ])
        harness.pages[URL(string: "https://one.example/")!] = page("https://one.example/", title: "One", text: "Foo text")

        for badAnswer in [
            "Here is a made up link https://evil.example/x [1]",
            "Answer citing beyond the retrieved set [9]",
            "A markdown link [like this](https://evil.example) [1]",
            "",
            "An answer with no citation at all"
        ] {
            let lookup = harness.makeLookup(answer: badAnswer)
            let result = try await lookup.lookup(
                task: "find foo", backend: .localApple, searchURL: searchURL,
                isPrivate: false, urlPolicy: nil
            )
            XCTAssertEqual(result.answer, BrowserAppleWebLookup.unverifiedAnswer, "Rejected answer: \(badAnswer)")
            XCTAssertEqual(result.sources.map(\.url), [URL(string: "https://one.example/")!])
        }
        harness.generated.removeAll()
        let good = harness.makeLookup(answer: "Concise answer [1].")
        let goodResult = try await good.lookup(
            task: "find foo", backend: .localApple, searchURL: searchURL,
            isPrivate: false, urlPolicy: nil
        )
        XCTAssertEqual(goodResult.answer, "Concise answer [1].")
    }

    func testSearchSnippetsAloneNeverSatisfyTheAnswer() async throws {
        let harness = LookupHarness()
        let searchURL = URL(string: "https://www.google.com/search?q=x")!
        harness.pages[searchURL] = page("https://www.google.com/search?q=x", text: "Foo Fighters June 5 2026", links: [
            link("Foo Fighters June 5 2026", "https://snippet.example/show")
        ])
        harness.failures.insert(URL(string: "https://snippet.example/show")!)
        let lookup = harness.makeLookup(answer: "Snippet answer")
        let result = try await lookup.lookup(
            task: "find foo fighters next concert", backend: .localApple, searchURL: searchURL,
            isPrivate: false, urlPolicy: nil
        )
        XCTAssertEqual(result.answer, BrowserAppleWebLookup.noSearchResultsMessage)
        XCTAssertTrue(result.sources.isEmpty)
        XCTAssertEqual(harness.generated.count, 0)
    }

    // MARK: URL policy

    func testPublicLookupURLRejectsUnsafeTargets() {
        XCTAssertTrue(BrowserAppleWebLookup.isPublicLookupURL(URL(string: "https://example.com/article")!))
        XCTAssertTrue(BrowserAppleWebLookup.isPublicLookupURL(URL(string: "http://www.example.com:80/x")!))
        XCTAssertTrue(BrowserAppleWebLookup.isPublicLookupURL(URL(string: "https://www.google.com/search?q=foo")!))

        for urlString in [
            "https://user:pass@example.com/",
            "https://127.0.0.1/x",
            "http://192.168.1.1/",
            "https://[::1]/x",
            "https://2130706433/",
            "http://localhost/path",
            "https://example.local/x",
            "https://example.local./x",
            "https://example.internal/x",
            "https://example.test/x",
            "https://example.onion/x",
            "https://shop.example/checkout",
            "https://shop.example/cart",
            "https://shop.example/account/login",
            "https://example.com:8443/x",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "ftp://example.com/x",
            "https://example"
        ] {
            XCTAssertFalse(
                BrowserAppleWebLookup.isPublicLookupURL(URL(string: urlString)!),
                "\(urlString) must be rejected"
            )
        }
    }

    func testLookupPolicyBlocksProtectedOriginsBeforeFetching() async throws {
        let harness = LookupHarness()
        let searchURL = URL(string: "https://www.google.com/search?q=x")!
        harness.pages[searchURL] = page("https://www.google.com/search?q=x", links: [
            link("protected", "https://filled.example/"),
            link("open", "https://open.example/")
        ])
        harness.pages[URL(string: "https://open.example/")!] = page("https://open.example/", title: "Open", text: "Open text")
        let blocked: Set<String> = ["https://filled.example/"]
        let policy: BrowserAgentBackgroundLoader.FetchURLPolicy = { url, _ in
            !blocked.contains(url.absoluteString)
        }
        let lookup = harness.makeLookup()
        let result = try await lookup.lookup(
            task: "find foo", backend: .localApple, searchURL: searchURL,
            isPrivate: false, urlPolicy: policy
        )
        XCTAssertFalse(harness.fetched.contains(URL(string: "https://filled.example/")!))
        XCTAssertEqual(result.sources.map(\.url), [URL(string: "https://open.example/")!])
        XCTAssertTrue(harness.policies.allSatisfy { $0 != nil })
    }

    // MARK: Excerpt ranking

    func testRelevantExcerptKeepsLaterConcertDateOverBoilerplate() {
        let boilerplate = String(repeating: "Home Tour Music Videos Store Contact Privacy Newsletter signup menu links. ", count: 60)
        let text = boilerplate + " The Foo Fighters concert in Chicago is scheduled for June 5, 2027."
        let excerpt = BrowserAppleWebLookup.relevantExcerpt(
            text: text,
            question: "find foo fighters next concert in the us",
            maximumBytes: 650
        )
        XCTAssertTrue(excerpt.contains("June 5, 2027"), "The dated window must outrank boilerplate: \(excerpt)")
        XCTAssertTrue(excerpt.contains("[…]") || excerpt.count <= 600)
        XCTAssertLessThanOrEqual(excerpt.utf8.count, 650)
    }

    // MARK: Cancellation

    func testLookupCancellationDuringFetchAndGeneratePropagates() async throws {
        let cancelFetch = BrowserAppleWebLookup(
            generate: { _, _, _ in "unused" },
            fetch: { _, _, _, _, _ in throw CancellationError() }
        )
        do {
            _ = try await cancelFetch.lookup(
                task: "find foo", backend: .localApple,
                searchURL: URL(string: "https://www.google.com/search?q=x")!,
                isPrivate: false, urlPolicy: nil
            )
            XCTFail("Cancellation during the search fetch must propagate.")
        } catch is CancellationError {}

        let harness = LookupHarness()
        let searchURL = URL(string: "https://www.google.com/search?q=x")!
        harness.pages[searchURL] = page("https://www.google.com/search?q=x", links: [
            link("one", "https://one.example/")
        ])
        harness.pages[URL(string: "https://one.example/")!] = page("https://one.example/", title: "One", text: "Text")
        let cancelGenerate = BrowserAppleWebLookup(
            generate: { _, _, _ in throw CancellationError() },
            fetch: { [weak harness] url, store, isPrivate, collect, policy in
                guard let harness else { throw CancellationError() }
                harness.fetched.append(url)
                guard let page = harness.pages[url] else {
                    throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
                }
                _ = store; _ = isPrivate; _ = collect; _ = policy
                return page
            }
        )
        do {
            _ = try await cancelGenerate.lookup(
                task: "find foo", backend: .localApple, searchURL: searchURL,
                isPrivate: false, urlPolicy: nil
            )
            XCTFail("Cancellation during answer generation must propagate.")
        } catch is CancellationError {}
    }

    // MARK: Message/presentation plumbing

    func testChatMessageSourcesSurviveAppendArchiveAndReset() {
        let service = SimpleAIService.shared
        service.reset()
        defer { service.reset() }
        let sources = [
            BrowserLookupSource(id: 1, title: "Tour", url: URL(string: "https://tour.example/")!, isPrivate: false)
        ]
        let replyID = service.appendAgentExchange(task: "find foo", answer: "Answer [1].", sources: sources)
        let assistant = service.messages.first { $0.id == replyID }
        XCTAssertEqual(assistant?.sources, sources)
        XCTAssertEqual(service.archiveMessages.first { $0.id == replyID }?.sources, sources)
        XCTAssertTrue(service.messages.first { $0.role == .user }?.sources.isEmpty == true)
        service.reset()
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertTrue(service.archiveMessages.isEmpty)
    }

    func testDefaultChatMessageAndCanvasPresentationSources() {
        let plain = ChatMessage(role: .assistant, text: "hello")
        XCTAssertTrue(plain.sources.isEmpty)
        let sourced = ChatMessage(
            role: .assistant, text: "Answer [1].",
            sources: [BrowserLookupSource(id: 1, title: "T", url: URL(string: "https://t.example/")!, isPrivate: true)]
        )
        let presentation = AIResponseCanvasPresentation(message: sourced)
        XCTAssertEqual(presentation.sources, sourced.sources)
        XCTAssertTrue(AIResponseCanvasPresentation(message: plain).sources.isEmpty)
    }

    func testLookupSourceOpenEligibilityRequiresMatchingPrivacyAndSafeURL() {
        let publicSource = BrowserLookupSource(id: 1, title: "T", url: URL(string: "https://example.com/a")!, isPrivate: false)
        let privateSource = BrowserLookupSource(id: 2, title: "P", url: URL(string: "https://example.com/p")!, isPrivate: true)
        let unsafeSource = BrowserLookupSource(id: 3, title: "U", url: URL(string: "https://example.com/checkout")!, isPrivate: false)

        XCTAssertTrue(AISidebar.lookupSourceOpenEligible(publicSource, contextIsPrivate: false, webViewDataStoreIsPersistent: true))
        XCTAssertTrue(AISidebar.lookupSourceOpenEligible(privateSource, contextIsPrivate: true, webViewDataStoreIsPersistent: false))
        XCTAssertFalse(AISidebar.lookupSourceOpenEligible(privateSource, contextIsPrivate: false, webViewDataStoreIsPersistent: true))
        XCTAssertFalse(AISidebar.lookupSourceOpenEligible(publicSource, contextIsPrivate: true, webViewDataStoreIsPersistent: false))
        XCTAssertFalse(AISidebar.lookupSourceOpenEligible(publicSource, contextIsPrivate: false, webViewDataStoreIsPersistent: false))
        XCTAssertFalse(AISidebar.lookupSourceOpenEligible(unsafeSource, contextIsPrivate: false, webViewDataStoreIsPersistent: true))
    }

    // MARK: WK search-links extraction

    func testSearchLinksScriptExtractsGoogleAndDDGResultsWithoutNavigation() async throws {
        let googleHTML = """
        <html><body><main>
        <p>Results</p>
        <a href="/url?q=https%3A%2F%2Fone.example%2Fshow&sa=U"><h3>Google One</h3></a>
        <a href="https://two.example/direct"><h3>Google Two</h3></a>
        <a href="https://two.example/direct"><h3>Duplicate Two</h3></a>
        <a href="/search?q=other"><h3>More results nav</h3></a>
        <div data-text-ad><a href="https://paid.example/ad"><h3>Sponsored</h3></a></div>
        <a href="https://hidden.example/x" style="display:none"><h3>Hidden</h3></a>
        <a href="javascript:void(0)"><h3>JS link</h3></a>
        <a href="https://noheading.example/x">No heading here</a>
        </main></body></html>
        """
        var store = WKWebsiteDataStore.nonPersistent()
        var loader = BrowserAgentBackgroundLoader(
            timeout: 5,
            requestLoader: { webView, request in
                _ = webView.loadHTMLString(googleHTML, baseURL: request.url)
            },
            pagePreparation: { _, _ in }
        )
        var pageResult = try await loader.fetch(
            url: URL(string: "https://www.google.com/search?q=foo")!,
            startingDataStore: store,
            isPrivate: false,
            collectSearchResults: true
        )
        XCTAssertEqual(pageResult.searchLinks.map(\.url), [
            URL(string: "https://one.example/show")!,
            URL(string: "https://two.example/direct")!
        ])
        XCTAssertEqual(pageResult.searchLinks.first?.title, "Google One")

        let ddgHTML = """
        <html><body><main>
        <p>Results</p>
        <a class="result__a" href="/l/?uddg=https%3A%2F%2Fddg1.example%2Fshow">DDG One</a>
        <a data-testid="result-title-a" href="https://ddg2.example/show">DDG Two</a>
        <a href="/settings"><h3>Settings</h3></a>
        <div class="result--ad"><a href="https://ad.example/x"><h3>Ad</h3></a></div>
        <div aria-hidden="true"><a href="https://sr.example/x"><h3>SR hidden</h3></a></div>
        </main></body></html>
        """
        store = WKWebsiteDataStore.nonPersistent()
        loader = BrowserAgentBackgroundLoader(
            timeout: 5,
            requestLoader: { webView, request in
                _ = webView.loadHTMLString(ddgHTML, baseURL: request.url)
            },
            pagePreparation: { _, _ in }
        )
        pageResult = try await loader.fetch(
            url: URL(string: "https://duckduckgo.com/?q=foo")!,
            startingDataStore: store,
            isPrivate: false,
            collectSearchResults: true
        )
        XCTAssertEqual(pageResult.searchLinks.map(\.url), [
            URL(string: "https://ddg1.example/show")!,
            URL(string: "https://ddg2.example/show")!
        ])
        XCTAssertEqual(pageResult.searchLinks.first?.title, "DDG One")
    }

    func testDefaultFetchPathLeavesSearchLinksEmptyAndUnchanged() async throws {
        let html = """
        <html><body><main><p>Plain readable fixture text.</p>
        <a href="https://one.example/show"><h3>Not collected</h3></a>
        </main></body></html>
        """
        let loader = BrowserAgentBackgroundLoader(
            timeout: 5,
            requestLoader: { webView, request in
                _ = webView.loadHTMLString(html, baseURL: request.url)
            },
            pagePreparation: { _, _ in }
        )
        let page = try await loader.fetch(
            url: URL(string: "https://fixture.example/read")!,
            startingDataStore: .nonPersistent(),
            isPrivate: false
        )
        XCTAssertTrue(page.searchLinks.isEmpty)
        XCTAssertTrue(page.text.contains("Plain readable fixture text."))
    }

    // MARK: Controller integration

    private func makeAdapterHarness() async throws -> (BrowserAgentBrowserAdapter, WKWebView, BrowserViewModel, URL) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let suiteName = "BrowserAppleLookup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let url = try XCTUnwrap(URL(string: "https://lookup-start.fixture/"))
        let tab = BrowserTab(title: "Start", url: url)
        let viewModel = BrowserViewModel(
            userDefaults: defaults,
            thumbnailDirectory: scratch.appendingPathComponent("thumbs", isDirectory: true)
        )
        viewModel.tabs = [tab]
        viewModel.selectedTabID = tab.id
        let webView = tab.activateWebView()
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString("<main>Lookup start page fixture text.</main>", baseURL: url)
        }
        webView.navigationDelegate = nil
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            onTabSelected: { _ in },
            historyStore: HistoryStore(directory: scratch.appendingPathComponent("history", isDirectory: true))
        )
        return (adapter, webView, viewModel, url)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<600 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func waitForRunEnd(_ controller: BrowserAgentController) async -> Bool {
        await waitUntil { !controller.isRunning }
    }

    private func decodedSearchQuery(_ url: URL?) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name.caseInsensitiveCompare("q") == .orderedSame }?.value
    }

    private struct AutomaticLookupOutcome {
        var searchRequestURL: URL?
        var fetched: [URL] = []
        var generated: [(instructions: String, body: String, backend: AIModelBackend)] = []
        var snapshot: BrowserAgentController.CompletionSnapshot?
        var summary: String?
        var engineInvoked = false
        var runEnded = false
    }

    private func runAutomaticLookupCase(task: String) async throws -> AutomaticLookupOutcome {
        var outcome = AutomaticLookupOutcome()
        let harness = LookupHarness()
        harness.pages[URL(string: "https://one.example/")!] = page(
            "https://one.example/", title: "One", text: "Foo text")
        let lookupService = BrowserAppleWebLookup(
            generate: { instructions, body, backend in
                outcome.generated.append((instructions: instructions, body: body, backend: backend))
                return instructions == BrowserAppleWebLookup.routingInstructions
                    ? "LOOKUP" : "Verified answer [1]."
            },
            fetch: { [weak harness] url, store, isPrivate, collect, policy in
                guard let harness else { throw CancellationError() }
                outcome.fetched.append(url)
                _ = store; _ = isPrivate; _ = policy
                if collect {
                    guard outcome.searchRequestURL == nil else {
                        throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
                    }
                    outcome.searchRequestURL = url
                    return self.page(
                        url.absoluteString,
                        title: "Search",
                        text: "Search results text.",
                        links: [self.link("One", "https://one.example/")]
                    )
                }
                guard let page = harness.pages[url] else {
                    throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
                }
                return page
            }
        )
        let controller = BrowserAgentController(
            engineFactory: { _ in
                outcome.engineInvoked = true
                return ScriptedLookupEngine { _, _, _ in "engine answer" }
            },
            appleLookup: lookupService
        )
        let (adapter, webView, _, _) = try await makeAdapterHarness()
        controller.start(
            task: task,
            preset: .automaticApple,
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter,
            backend: .localApple,
            onPageQuestion: { _ in },
            onRunCompleted: { outcome.snapshot = $0 },
            onComplete: { outcome.summary = $0 }
        )
        outcome.runEnded = await waitForRunEnd(controller)
        adapter.endRun()
        return outcome
    }

    func testControllerLookupAnswersWithSourcesWithoutInvokingEngine() async throws {
        for task in ["find foo", "when is the next foo fighters concert"] {
            let outcome = try await runAutomaticLookupCase(task: task)
            XCTAssertTrue(outcome.runEnded)
            XCTAssertFalse(outcome.engineInvoked, "Lookup must never create an agent engine")
            XCTAssertEqual(outcome.generated.count, 2, "One classify call plus one answer call")
            XCTAssertEqual(outcome.snapshot?.preset, "automatic")
            XCTAssertEqual(outcome.snapshot?.sources.map(\.url), [URL(string: "https://one.example/")!])
            XCTAssertFalse(outcome.snapshot?.usedBrowserPath ?? true)
            XCTAssertEqual(outcome.snapshot?.outcome, "Verified answer [1].")
            XCTAssertTrue(outcome.summary?.hasPrefix("Verified answer [1].") == true)
            XCTAssertEqual(
                decodedSearchQuery(outcome.searchRequestURL), task,
                "The fetched search request must carry the user's task as its decoded query"
            )
        }
    }

    func testControllerBrowserRouteFallsThroughToScriptedEngine() async throws {
        var capturedRequest: BrowserAgentEngineRequest?
        let engine = ScriptedLookupEngine(profile: .local(contextSize: 4_096, supportsVision: false)) { request, _, _ in
            capturedRequest = request
            return "Browser action finished."
        }
        let lookupService = BrowserAppleWebLookup(
            generate: { instructions, _, _ in
                instructions == BrowserAppleWebLookup.routingInstructions ? "BROWSER" : "unused"
            },
            fetch: { _, _, _, _, _ in throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable }
        )
        let controller = BrowserAgentController(
            engineFactory: { _ in engine },
            appleLookup: lookupService
        )
        let (adapter, webView, _, _) = try await makeAdapterHarness()
        var snapshot: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "click the save button",
            preset: .automaticApple,
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter,
            backend: .localApple,
            onRunCompleted: { snapshot = $0 },
            onComplete: { _ in }
        )
        let runEnded = await waitForRunEnd(controller)
        XCTAssertTrue(runEnded)
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.instructions, BrowserAgentController.localInstructions)
        XCTAssertEqual(snapshot?.preset, "automatic")
        XCTAssertTrue(snapshot?.usedBrowserPath ?? false)
        XCTAssertTrue(snapshot?.sources.isEmpty ?? false)
        adapter.endRun()
    }

    func testControllerPageRouteForwardsOnceWithoutFakeCompletion() async throws {
        let lookupService = BrowserAppleWebLookup(
            generate: { instructions, _, _ in
                instructions == BrowserAppleWebLookup.routingInstructions ? "PAGE" : "unused"
            },
            fetch: { _, _, _, _, _ in throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable }
        )
        var engineInvoked = false
        let controller = BrowserAgentController(
            engineFactory: { _ in
                engineInvoked = true
                return ScriptedLookupEngine { _, _, _ in "unused" }
            },
            appleLookup: lookupService
        )
        let (adapter, webView, _, _) = try await makeAdapterHarness()
        var forwarded: [String] = []
        var completionFired = false
        var snapshotFired = false
        controller.start(
            task: "summarize this article",
            preset: .automaticApple,
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter,
            backend: .localApple,
            onPageQuestion: { forwarded.append($0) },
            onRunCompleted: { _ in snapshotFired = true },
            onComplete: { _ in completionFired = true }
        )
        let runEnded = await waitForRunEnd(controller)
        XCTAssertTrue(runEnded)
        XCTAssertEqual(forwarded, ["summarize this article"])
        XCTAssertFalse(completionFired, "A PAGE handoff must not record a fake agent exchange")
        XCTAssertFalse(snapshotFired)
        XCTAssertFalse(engineInvoked)
        adapter.endRun()
    }

    func testChatGPTAutomaticPresetKeepsLegacyInstructionsAndRouting() async throws {
        var capturedRequest: BrowserAgentEngineRequest?
        let engine = ScriptedLookupEngine { request, _, _ in
            capturedRequest = request
            return "ChatGPT answer."
        }
        let lookupService = BrowserAppleWebLookup(
            generate: { _, _, _ in
                XCTFail("ChatGPT must never reach the Apple lookup classifier")
                return "CLARIFY"
            },
            fetch: { _, _, _, _, _ in throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable }
        )
        let controller = BrowserAgentController(
            engineFactory: { _ in engine },
            appleLookup: lookupService
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString("<main>ChatGPT fixture page text.</main>", baseURL: URL(string: "https://chatgpt.fixture/"))
        }
        webView.navigationDelegate = nil
        var snapshot: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "find foo fighters next concert",
            preset: .automaticApple,
            conversation: nil,
            in: webView,
            openTab: nil,
            backend: .chatGPTPlan,
            onRunCompleted: { snapshot = $0 },
            onComplete: { _ in }
        )
        let runEnded = await waitForRunEnd(controller)
        XCTAssertTrue(runEnded)
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.instructions, BrowserAgentController.instructions)
        XCTAssertFalse(request.instructions.contains(BrowserAppleWebLookup.routingInstructions))
        XCTAssertEqual(snapshot?.preset, "standard")
        XCTAssertTrue(snapshot?.usedBrowserPath ?? false)
    }

    func testLookupRejectsEmptyOrLongQuestionAtEntry() async throws {
        let harness = LookupHarness()
        for task in ["   \n", String(repeating: "x", count: 241)] {
            do {
                _ = try await harness.makeLookup().lookup(
                    task: task,
                    backend: .localApple,
                    searchURL: URL(string: "https://www.google.com/search?q=x")!,
                    isPrivate: false,
                    urlPolicy: nil
                )
                XCTFail("An invalid task must fail before any fetch.")
            } catch let error as BrowserAppleWebLookup.LookupError {
                XCTAssertEqual(error, .invalidQuestion)
            }
        }
        XCTAssertTrue(harness.fetched.isEmpty)
    }

    func testEffectivePolicyRejectsUnsafeFetchTargetsWithNilCallerPolicy() async throws {
        let harness = LookupHarness()
        let searchURL = URL(string: "https://www.google.com/search?q=x")!
        harness.pages[searchURL] = page("https://www.google.com/search?q=x", links: [
            link("ip", "http://127.0.0.1/a"),
            link("checkout", "https://shop.example/checkout"),
            link("trailing", "https://example.local./x"),
            link("open", "https://open.example/")
        ])
        harness.pages[URL(string: "https://open.example/")!] = page(
            "https://open.example/", title: "Open", text: "Open text")
        var probeResults: [Bool] = []
        let lookup = BrowserAppleWebLookup(
            generate: { [weak harness] i, b, be in
                harness?.generated.append((instructions: i, body: b, backend: be))
                return "Answer [1]."
            },
            fetch: { [weak harness] url, store, isPrivate, collect, policy in
                guard let harness else { throw CancellationError() }
                harness.fetched.append(url)
                for probe in ["http://127.0.0.1/probe", "https://shop.example/checkout", "https://example.local./x"] {
                    probeResults.append(policy?(URL(string: probe)!, store) ?? true)
                }
                _ = isPrivate; _ = collect
                guard let page = harness.pages[url] else {
                    throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
                }
                return page
            }
        )
        let result = try await lookup.lookup(
            task: "find foo", backend: .localApple, searchURL: searchURL,
            isPrivate: false, urlPolicy: nil
        )
        XCTAssertFalse(probeResults.contains(true))
        XCTAssertEqual(harness.fetched, [searchURL, URL(string: "https://open.example/")!])
        XCTAssertEqual(result.sources.map(\.url), [URL(string: "https://open.example/")!])
    }

    func testSearchPageFinalRedirectIsPolicyChecked() async throws {
        let searchURL = URL(string: "https://www.google.com/search?q=x")!
        let moved = BrowserAgentBackgroundLoader.Page(
            title: "Search",
            url: URL(string: "https://shop.example/checkout")!,
            text: "results",
            truncated: false,
            searchLinks: [link("open", "https://open.example/")]
        )
        var generateCalled = false
        let lookup = BrowserAppleWebLookup(
            generate: { _, _, _ in
                generateCalled = true
                return "Answer [1]."
            },
            fetch: { url, _, _, _, _ in
                guard url == searchURL else {
                    throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
                }
                return moved
            }
        )
        do {
            _ = try await lookup.lookup(
                task: "find foo", backend: .localApple, searchURL: searchURL,
                isPrivate: false, urlPolicy: nil
            )
            XCTFail("A search page landing on a blocked destination must fail.")
        } catch {
            XCTAssertFalse(generateCalled)
        }
    }

    func testEmptySourceTextProducesNoCardsOrGeneration() async throws {
        let harness = LookupHarness()
        let searchURL = URL(string: "https://www.google.com/search?q=x")!
        harness.pages[searchURL] = page("https://www.google.com/search?q=x", links: [
            link("empty", "https://empty.example/")
        ])
        harness.pages[URL(string: "https://empty.example/")!] = page(
            "https://empty.example/", title: "Empty", text: "  \n\t  ")
        let result = try await harness.makeLookup().lookup(
            task: "find foo", backend: .localApple, searchURL: searchURL,
            isPrivate: false, urlPolicy: nil
        )
        XCTAssertEqual(result.answer, BrowserAppleWebLookup.noSearchResultsMessage)
        XCTAssertTrue(result.sources.isEmpty)
        XCTAssertTrue(harness.generated.isEmpty)
    }

    func testFragmentVariantsDeduplicateIntoOneSource() async throws {
        let harness = LookupHarness()
        let searchURL = URL(string: "https://www.google.com/search?q=x")!
        harness.pages[searchURL] = page("https://www.google.com/search?q=x", links: [
            link("a1", "https://dup.example/page#top"),
            link("a2", "https://dup.example/page#bottom"),
            link("a3", "https://dup.example/page")
        ])
        harness.pages[URL(string: "https://dup.example/page")!] = page(
            "https://dup.example/page", title: "Dup", text: "Foo text")
        let result = try await harness.makeLookup().lookup(
            task: "find foo", backend: .localApple, searchURL: searchURL,
            isPrivate: false, urlPolicy: nil
        )
        XCTAssertEqual(harness.fetched, [searchURL, URL(string: "https://dup.example/page")!])
        XCTAssertEqual(result.sources.map(\.url), [URL(string: "https://dup.example/page")!])
    }

    func testRelevantExcerptKeepsHighRelevanceNonASCIIWindowWithinBudget() {
        let boiler = String(repeating: "menu navigation links footer ", count: 30)
        let dense = String(repeating: "\u{6771}", count: 300)
        let text = boiler + dense + "foo fighters concert tokyo dome"
        let excerpt = BrowserAppleWebLookup.relevantExcerpt(
            text: text,
            question: "find foo fighters concert",
            maximumBytes: 650
        )
        XCTAssertTrue(excerpt.contains("foo"))
        XCTAssertLessThanOrEqual(excerpt.utf8.count, 650)
    }

    func testRelevantExcerptReturnsEmptyForZeroLimit() {
        XCTAssertEqual(
            BrowserAppleWebLookup.relevantExcerpt(text: "foo fighters concert", question: "find foo", maximumBytes: 0),
            ""
        )
        XCTAssertEqual(
            BrowserAppleWebLookup.relevantExcerpt(text: "foo", question: "find foo", maximumBytes: -1),
            ""
        )
    }

    private struct ClarifyOutcome {
        var snapshot: BrowserAgentController.CompletionSnapshot?
        var summary: String?
        var engineInvoked = false
        var forwarded: String?
        var fetchCount = 0
        var runEnded = false
        var answerGenerate = false
    }

    private func runClarifyCase(reply: String?) async throws -> ClarifyOutcome {
        var outcome = ClarifyOutcome()
        let harness = LookupHarness()
        harness.pages[URL(string: "https://one.example/")!] = page(
            "https://one.example/", title: "One", text: "Foo text")
        let lookupService = BrowserAppleWebLookup(
            generate: { instructions, _, _ in
                if instructions == BrowserAppleWebLookup.routingInstructions { return "CLARIFY" }
                outcome.answerGenerate = true
                return "Answer [1]."
            },
            fetch: { [weak harness] url, store, isPrivate, collect, policy in
                outcome.fetchCount += 1
                guard let harness else { throw CancellationError() }
                _ = store; _ = isPrivate; _ = policy
                if collect {
                    return self.page(
                        url.absoluteString,
                        title: "Search",
                        text: "Search text.",
                        links: [self.link("One", "https://one.example/")]
                    )
                }
                guard let page = harness.pages[url] else {
                    throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
                }
                return page
            }
        )
        let controller = BrowserAgentController(
            engineFactory: { _ in
                outcome.engineInvoked = true
                return ScriptedLookupEngine { _, _, _ in "engine answer" }
            },
            appleLookup: lookupService
        )
        let (adapter, webView, _, _) = try await makeAdapterHarness()
        controller.start(
            task: "ambiguous",
            preset: .automaticApple,
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter,
            backend: .localApple,
            onPageQuestion: { outcome.forwarded = $0 },
            onRunCompleted: { outcome.snapshot = $0 },
            onComplete: { outcome.summary = $0 }
        )
        let asked = await waitUntil { controller.pendingQuestion != nil }
        XCTAssertTrue(asked)
        controller.resolveUserQuestion(reply)
        outcome.runEnded = await waitForRunEnd(controller)
        adapter.endRun()
        return outcome
    }

    func testClarifyRouteAnswersSelectSearchPageOrBrowser() async throws {
        let search = try await runClarifyCase(reply: "search")
        XCTAssertTrue(search.runEnded)
        XCTAssertFalse(search.engineInvoked)
        XCTAssertNil(search.forwarded)
        XCTAssertEqual(search.snapshot?.sources.map(\.url), [URL(string: "https://one.example/")!])
        XCTAssertEqual(search.snapshot?.outcome, "Answer [1].")

        let page = try await runClarifyCase(reply: "page")
        XCTAssertTrue(page.runEnded)
        XCTAssertFalse(page.engineInvoked)
        XCTAssertEqual(page.forwarded, "ambiguous")
        XCTAssertNil(page.snapshot)
        XCTAssertEqual(page.fetchCount, 0)

        let browser = try await runClarifyCase(reply: "browser")
        XCTAssertTrue(browser.runEnded)
        XCTAssertTrue(browser.engineInvoked)
        XCTAssertNil(browser.forwarded)
        XCTAssertEqual(browser.snapshot?.outcome, "engine answer")
        XCTAssertEqual(browser.fetchCount, 0)
    }

    func testClarifyUnrecognizedReplyTakesNoAction() async throws {
        let outcome = try await runClarifyCase(reply: "maybe later")
        XCTAssertTrue(outcome.runEnded)
        XCTAssertFalse(outcome.engineInvoked)
        XCTAssertNil(outcome.forwarded)
        XCTAssertEqual(outcome.fetchCount, 0)
        XCTAssertFalse(outcome.answerGenerate)
        XCTAssertEqual(
            outcome.snapshot?.outcome,
            "No action taken. Use /search, /ask or /do to choose a mode."
        )
    }

    func testControllerStopDuringClassifySuppressesLateResult() async throws {
        let gate = ContinuationGate<String>()
        var engineInvoked = false
        var pageForwarded = false
        var fetchCount = 0
        let lookupService = BrowserAppleWebLookup(
            generate: { instructions, _, _ in
                guard instructions == BrowserAppleWebLookup.routingInstructions else {
                    return "unused"
                }
                return await gate.awaitValue()
            },
            fetch: { _, _, _, _, _ in
                fetchCount += 1
                throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
            }
        )
        let controller = BrowserAgentController(
            engineFactory: { _ in
                engineInvoked = true
                return ScriptedLookupEngine { _, _, _ in "engine answer" }
            },
            appleLookup: lookupService
        )
        let (adapter, webView, _, _) = try await makeAdapterHarness()
        var snapshot: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "find foo",
            preset: .automaticApple,
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter,
            backend: .localApple,
            onPageQuestion: { _ in pageForwarded = true },
            onRunCompleted: { snapshot = $0 },
            onComplete: { _ in }
        )
        let suspended = await waitUntil { gate.isAwaiting }
        XCTAssertTrue(suspended)
        controller.stop()
        XCTAssertFalse(controller.isRunning)
        gate.resume("LOOKUP")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(engineInvoked)
        XCTAssertFalse(pageForwarded)
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(snapshot?.sources ?? [], [])
        XCTAssertEqual(snapshot?.outcome, "Stopped.")
    }

    func testControllerStopDuringAnswerGenerateAttachesNoSourceCards() async throws {
        let gate = ContinuationGate<String>()
        let harness = LookupHarness()
        harness.pages[URL(string: "https://one.example/")!] = page(
            "https://one.example/", title: "One", text: "Foo text")
        let lookupService = BrowserAppleWebLookup(
            generate: { instructions, _, _ in
                if instructions == BrowserAppleWebLookup.routingInstructions { return "LOOKUP" }
                return await gate.awaitValue()
            },
            fetch: { [weak harness] url, store, isPrivate, collect, policy in
                guard let harness else { throw CancellationError() }
                _ = store; _ = isPrivate; _ = policy
                if collect {
                    return self.page(
                        url.absoluteString,
                        title: "Search",
                        text: "Search text.",
                        links: [self.link("One", "https://one.example/")]
                    )
                }
                guard let page = harness.pages[url] else {
                    throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
                }
                return page
            }
        )
        let controller = BrowserAgentController(
            engineFactory: { _ in ScriptedLookupEngine { _, _, _ in "engine answer" } },
            appleLookup: lookupService
        )
        let (adapter, webView, _, _) = try await makeAdapterHarness()
        var snapshot: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "find foo",
            preset: .automaticApple,
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter,
            backend: .localApple,
            onPageQuestion: { _ in },
            onRunCompleted: { snapshot = $0 },
            onComplete: { _ in }
        )
        let suspended = await waitUntil { gate.isAwaiting }
        XCTAssertTrue(suspended)
        controller.stop()
        XCTAssertFalse(controller.isRunning)
        gate.resume("Verified answer [1].")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(snapshot?.sources ?? [], [])
        XCTAssertEqual(snapshot?.outcome, "Stopped.")
    }

    func testControllerReplacementSuppressesOldLookupResult() async throws {
        let gateA = ContinuationGate<String>()
        var fetchACount = 0
        var pageForwarded = false
        let serviceA = BrowserAppleWebLookup(
            generate: { instructions, _, _ in
                guard instructions == BrowserAppleWebLookup.routingInstructions else {
                    return "A answer"
                }
                return await gateA.awaitValue()
            },
            fetch: { _, _, _, _, _ in
                fetchACount += 1
                throw BrowserAgentBackgroundLoader.LoadError.pageUnavailable
            }
        )
        var engineRuns = 0
        let controller = BrowserAgentController(
            engineFactory: { _ in
                ScriptedLookupEngine { _, _, _ in
                    engineRuns += 1
                    return "B engine answer"
                }
            },
            appleLookup: serviceA
        )
        let (adapter, webView, _, _) = try await makeAdapterHarness()
        var snapshotB: BrowserAgentController.CompletionSnapshot?
        controller.start(
            task: "first task",
            preset: .automaticApple,
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter,
            backend: .localApple,
            onPageQuestion: { _ in pageForwarded = true },
            onRunCompleted: { _ in },
            onComplete: { _ in }
        )
        let suspended = await waitUntil { gateA.isAwaiting }
        XCTAssertTrue(suspended)
        controller.stop()
        controller.start(
            task: "second task",
            preset: .standard,
            conversation: nil,
            in: webView,
            openTab: nil,
            browserAdapter: adapter,
            backend: .localApple,
            onPageQuestion: { _ in pageForwarded = true },
            onRunCompleted: { snapshotB = $0 },
            onComplete: { _ in }
        )
        gateA.resume("LOOKUP")
        let runEnded = await waitForRunEnd(controller)
        XCTAssertTrue(runEnded)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fetchACount, 0)
        XCTAssertFalse(pageForwarded)
        XCTAssertEqual(engineRuns, 1)
        XCTAssertEqual(snapshotB?.outcome, "B engine answer")
        XCTAssertTrue(snapshotB?.sources.isEmpty ?? true)
    }
}
