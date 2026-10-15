import XCTest
import WebKit
@testable import Browser

@MainActor
final class BrowserAgentPageScriptTests: XCTestCase {
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private static let html = """
    <html><head><meta name="viewport" content="width=device-width"></head><body>
    <form role="search" action="/search"><input id="q" name="q" placeholder="Search products"><button>Search</button></form>
    <form id="buy-search" role="search" action="/search"><input id="buy-search-query" type="search" name="q" aria-label="Product query"></form>
    <button id="buy-search-submit" type="submit" form="buy-search">Buy now</button>
    <form method="post" action="/login">
      <input name="email" aria-label="Email"><input type="password" name="pw" aria-label="Password">
      <button type="submit">Continue</button>
    </form>
    <form id="post-auth" action="/submit"><input type="password" aria-label="Protected password"><button id="post-auth-button" type="submit" aria-label="Post protected">Post</button></form>
    <form id="first-login" method="post" action="/auth">
    <input type="email" name="username" autocomplete="username" aria-label="Account email">
    <button id="first-login-button" type="submit" aria-label="Post first-step">Post</button></form>
    <form id="signin-path" method="post" action="/signin"><input type="email" name="email" autocomplete="username"><button id="signin-path-button" type="submit">Continue</button></form>
    <form id="login-path" method="post" action="/login"><input type="email" name="email"><button id="login-path-button" type="submit">Post</button></form>
    <form id="oauth-path" method="post" action="/oauth/continue"><input type="email" name="email" autocomplete="email"><button id="oauth-path-button" type="submit">Continue</button></form>
    <form id="authorize-path" method="post" action="/authorize"><input type="email" name="email" autocomplete="email"><button id="authorize-path-button" type="submit">Continue</button></form>
    <form id="authentication-path" method="post" action="/authentication/start">
    <input type="email" name="email" autocomplete="email">
    <button id="authentication-path-button" type="submit">Continue</button></form>
    <form id="sso-path" method="post" action="/sso/continue"><input type="email" name="email" autocomplete="email"><button id="sso-path-button" type="submit">Continue</button></form>
    <form id="payment-path" method="post" action="/pay">
    <input name="card_number" autocomplete="cc-number" aria-label="Account entry">
    <button id="payment-path-button" type="submit">Continue</button></form>
    <form id="contact-form" method="post" action="/contact"><input type="email" name="email" aria-label="Contact email"><button id="contact-post-button" type="submit">Post message</button></form>
    <form id="author-form" method="post" action="/contact">
    <input type="email" name="author" autocomplete="email" aria-label="Article author">
    <button id="author-post-button" type="submit">Post article</button></form>
    <button id="order" onclick="window.ordered = true">Place order</button>
    <button id="post-button" onclick="window.posted = true">Post update</button>
    <button id="focus-mutating-post" onfocus="this.textContent='Buy now'" onclick="window.focusMutationClicked = true">Post update</button>
    <form id="focus-mutating-form" method="post" action="/contact" onsubmit="event.preventDefault(); window.focusMutationSubmitted = true">
      <input id="focus-mutating-input" name="message" aria-label="Focus mutation field" onfocus="this.type='password'">
      <button type="submit">Send message</button>
    </form>
    <button id="more" onclick="window.moreClicks = (window.moreClicks || 0) + 1">Show more</button>
    <select id="size" aria-label="Size"><option value="s">Small</option><option value="m">Medium</option></select>
    <input id="disabled-input" aria-label="Disabled field" value="locked" disabled>
    <input id="readonly-input" aria-label="Read-only field" value="locked" readonly>
    <select id="disabled-size" aria-label="Disabled size" disabled><option value="a">A</option><option value="b">B</option></select>
    <input id="updates" type="checkbox" aria-label="Optional updates">
    <input id="selected-radio" type="radio" name="plan" aria-label="Selected plan" checked>
    <input id="unselected-radio" type="radio" name="plan" aria-label="Other plan">
    <input id="delete-checkbox" type="checkbox" aria-label="Delete account">
    <input id="otp" aria-label="Verification code" name="otp" autocomplete="one-time-code" value="654321" data-token="super-secret-token" style="color: rgb(1, 2, 3)">
    <iframe id="payment-frame" title="Embedded payment content"></iframe>
    <a id="token-link" href="https://shop.example/record?access_token=super-secret-token&amp;region=porto">Private URL</a>
    <button id="long-label" aria-label="\(String(repeating: "L", count: 320))">Long label</button>
    <div id="hide-target" role="button" tabindex="0">Hide target</div>
    <div role="dialog" aria-modal="true" id="cookie-dialog">
      <button id="reject-all" onclick="window.rejected = true">Reject all</button>
      <button id="accept-all" onclick="window.accepted = true">Accept</button>
    </div>
    <div class="cookie-overlay"><button id="delete-overlay" onclick="window.overlayDeleted = true">Delete account</button></div>
    <div style="height:3000px"></div>
    <a href="/bottom">Bottom link</a>
    <form id="ddg-search" role="search" action="/search">
      <input id="ddg-query" name="q" aria-label="Site search query">
      <button id="ddg-clear" type="button" aria-label="Clear">×</button>
      <button id="ddg-submit" type="submit">Search</button>
    </form>
    <form id="button-only-search" role="search" action="/search">
      <input id="button-only-query" name="q" aria-label="Button only query">
      <button id="button-only-clear" type="button">×</button>
    </form>
    <form id="cart-form" action="/cart">
      <input id="cart-query" name="item" aria-label="Item name">
      <button id="cart-clear" type="button">Clear</button>
      <button id="cart-submit" type="submit">Buy now</button>
    </form>
    <script>
      window.agentGlobalVisible = () => typeof globalThis.__vxAgent !== 'undefined';
      document.getElementById('q').addEventListener('input', e => { window.lastInput = e.target.value; });
      document.querySelector('form[role=search]').addEventListener('submit', e => { e.preventDefault(); window.searched = document.getElementById('q').value; });
      document.getElementById('buy-search').addEventListener('submit', e => { e.preventDefault(); window.riskySearchSubmitted = true; });
      document.getElementById('ddg-search').addEventListener('submit', e => { e.preventDefault(); window.ddgSubmitter = e.submitter ? e.submitter.id : 'none'; });
      document.getElementById('button-only-search').addEventListener('submit', e => { e.preventDefault(); window.buttonOnlySubmitter = e.submitter ? e.submitter.id : 'none'; });
      document.getElementById('cart-form').addEventListener('submit', e => { e.preventDefault(); window.cartSubmitted = true; });
    </script>
    </body></html>
    """

    private var webView: WKWebView!
    private let waiter = LoadWaiter()

    override func setUp() async throws {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(Self.html, baseURL: URL(string: "https://shop.example/"))
        }
    }

    private func agent(_ script: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let value = try await webView.callAsyncJavaScript(
            script, arguments: arguments, in: nil, contentWorld: BrowserAgentPageScript.world
        )
        let data = try XCTUnwrap((value as? String)?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func page(_ expression: String) async throws -> Any? {
        try await webView.callAsyncJavaScript("return \(expression);", arguments: [:], in: nil, contentWorld: .page)
    }

    private func snapshotLines() async throws -> [String] {
        let snapshot = try await agent(BrowserAgentPageScript.snapshot, ["maxElements": 150, "maxText": 500])
        return (snapshot["elements"] as? String ?? "").components(separatedBy: "\n")
    }

    private func documentNonce() async throws -> String {
        let identity = try await agent(BrowserAgentPageScript.documentIdentity)
        return try XCTUnwrap(identity["nonce"] as? String)
    }

    private func reloadSameURLDocument() async {
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(Self.html, baseURL: URL(string: "https://shop.example/"))
        }
    }

    private func replaceWithDedicatedFixture(_ html: String) async {
        let fixture = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let fixtureWaiter = LoadWaiter()
        fixture.navigationDelegate = fixtureWaiter
        await withCheckedContinuation { continuation in
            fixtureWaiter.continuation = continuation
            fixture.loadHTMLString(html, baseURL: URL(string: "https://autofill.fixture/"))
        }
        fixture.navigationDelegate = nil
        webView = fixture
    }

    private func id(of label: String, in lines: [String]) throws -> Int {
        let line = try XCTUnwrap(lines.first { $0.contains("\"\(label)\"") }, "no element labelled \(label)")
        let digits = line.dropFirst().prefix { $0.isNumber }
        return try XCTUnwrap(Int(digits))
    }

    private func domElementID(_ elementID: String) async throws -> Int {
        let value = try await webView.callAsyncJavaScript(
            "return globalThis.__vxAgent.idFor(document.getElementById(elementID));",
            arguments: ["elementID": elementID],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        return try XCTUnwrap((value as? NSNumber)?.intValue, elementID)
    }

    func testSnapshotListsElementsAndHidesAgentFromPage() async throws {
        let lines = try await snapshotLines()
        XCTAssertTrue(lines.contains { $0.contains("textbox \"Search products\"") })
        XCTAssertTrue(lines.contains { $0.contains("\"Password\" (sensitive") })
        XCTAssertTrue(lines.contains { $0.contains("select \"Size\"") && $0.contains("Medium") })
        XCTAssertTrue(lines.contains { $0.contains("\"Bottom link\"") && $0.contains("(offscreen)") })
        let visibleToPage = try await page("window.agentGlobalVisible()") as? Bool
        XCTAssertEqual(visibleToPage, false)
    }

    func testSearchTypesAndSubmitsWithoutApproval() async throws {
        let lines = try await snapshotLines()
        let result = try await agent(BrowserAgentPageScript.type, [
            "id": try id(of: "Search products", in: lines), "text": "running shoes", "submit": true, "confirmed": false
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        let lastInput = try await page("window.lastInput") as? String
        let searched = try await page("window.searched") as? String
        XCTAssertEqual(lastInput, "running shoes")
        XCTAssertEqual(searched, "running shoes")
    }

    func testRiskyClickNeedsApprovalFirst() async throws {
        let lines = try await snapshotLines()
        let orderID = try id(of: "Place order", in: lines)
        let approvalID = UUID().uuidString
        let nonce = try await documentNonce()
        let first = try await agent(BrowserAgentPageScript.click, [
            "id": orderID, "confirmed": false, "approvalID": approvalID, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(first["needsConfirmation"] as? Bool, true)
        let orderedBefore = try await page("window.ordered === true") as? Bool
        XCTAssertEqual(orderedBefore, false)

        let second = try await agent(BrowserAgentPageScript.click, [
            "id": orderID, "confirmed": true, "approvalID": approvalID,
            "confirmationContextID": first["contextID"] as? String ?? "", "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(second["ok"] as? Bool, true)
        let orderedAfter = try await page("window.ordered === true") as? Bool
        XCTAssertEqual(orderedAfter, true)
    }

    func testOrdinaryClickRunsImmediately() async throws {
        let lines = try await snapshotLines()
        let result = try await agent(BrowserAgentPageScript.click, ["id": try id(of: "Show more", in: lines), "confirmed": false])
        XCTAssertEqual(result["ok"] as? Bool, true)
        let clicks = try await page("String(window.moreClicks)") as? String
        XCTAssertEqual(clicks, "1")
    }

    func testSignInSubmitNeedsApprovalAndPasswordIsBlocked() async throws {
        let lines = try await snapshotLines()
        let continueResult = try await agent(BrowserAgentPageScript.click, ["id": try id(of: "Continue", in: lines), "confirmed": false])
        XCTAssertEqual(continueResult["reason"] as? String, "sign-in form")

        let passwordID = try XCTUnwrap(lines.first { $0.contains("\"Password\"") }.flatMap { Int($0.dropFirst().prefix { $0.isNumber }) })
        let typed = try await agent(BrowserAgentPageScript.type, ["id": passwordID, "text": "hunter2", "submit": false, "confirmed": true])
        XCTAssertNotNil(typed["blocked"])
        let value = try await page("document.querySelector('input[type=password]').value") as? String
        XCTAssertEqual(value, "")
    }

    func testPostInsideProtectedFormIsNotEligibleForRemembering() async throws {
        let lines = try await snapshotLines()
        let result = try await agent(BrowserAgentPageScript.click, [
            "id": try id(of: "Post protected", in: lines), "confirmed": false,
            "approvalID": UUID().uuidString, "expectedDocumentNonce": try await documentNonce()
        ])
        XCTAssertEqual(result["needsConfirmation"] as? Bool, true)
        XCTAssertEqual(result["reason"] as? String, "post")
        XCTAssertEqual(result["protectedContext"] as? Bool, true)
        XCTAssertEqual(result["trustEligible"] as? Bool, false)
    }

    func testPasswordlessFirstStepSignInIsProtectedButContactFormIsNot() async throws {
        let lines = try await snapshotLines()
        let nonce = try await documentNonce()
        for elementID in [
            "first-login-button", "signin-path-button", "login-path-button", "oauth-path-button",
            "authorize-path-button", "authentication-path-button", "sso-path-button", "payment-path-button"
        ] {
            let targetID = try await domElementID(elementID)
            let auth = try await agent(BrowserAgentPageScript.click, [
                "id": targetID, "confirmed": false,
                "approvalID": UUID().uuidString, "expectedDocumentNonce": nonce
            ])
            XCTAssertEqual(auth["needsConfirmation"] as? Bool, true, elementID)
            XCTAssertEqual(auth["protectedContext"] as? Bool, true, elementID)
            XCTAssertEqual(auth["trustEligible"] as? Bool, false, elementID)
            XCTAssertFalse(AgentTrustStore.isAlwaysAllowEligible(
                reason: auth["reason"] as? String ?? "",
                operation: "click",
                protectedContext: auth["protectedContext"] as? Bool ?? false,
                isPrivate: false
            ), elementID)
        }

        let contact = try await agent(BrowserAgentPageScript.click, [
            "id": try id(of: "Post message", in: lines), "confirmed": false,
            "approvalID": UUID().uuidString, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(contact["needsConfirmation"] as? Bool, true)
        XCTAssertEqual(contact["reason"] as? String, "post")
        XCTAssertEqual(contact["protectedContext"] as? Bool, false)
        XCTAssertEqual(contact["trustEligible"] as? Bool, true)

        let authorID = try await domElementID("author-post-button")
        let author = try await agent(BrowserAgentPageScript.click, [
            "id": authorID, "confirmed": false, "approvalID": UUID().uuidString, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(author["needsConfirmation"] as? Bool, true)
        XCTAssertEqual(author["reason"] as? String, "post")
        XCTAssertEqual(author["protectedContext"] as? Bool, false, "An ordinary author field must not be treated as an auth hint.")
        XCTAssertEqual(author["trustEligible"] as? Bool, true)
    }

    func testFormContextMutationFromContactToSignInInvalidatesApproval() async throws {
        let lines = try await snapshotLines()
        let elementID = try id(of: "Post message", in: lines)
        let approvalID = UUID().uuidString
        let nonce = try await documentNonce()
        let first = try await agent(BrowserAgentPageScript.click, [
            "id": elementID, "confirmed": false, "approvalID": approvalID, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(first["protectedContext"] as? Bool, false)

        _ = try await page("document.getElementById('contact-form').action = '/login'")
        let replay = try await agent(BrowserAgentPageScript.click, [
            "id": elementID, "confirmed": true, "approvalID": approvalID,
            "confirmationContextID": first["contextID"] as? String ?? "", "expectedDocumentNonce": nonce
        ])
        XCTAssertNotNil(replay["error"])
        let posted = try await page("window.posted === true") as? Bool
        XCTAssertNotEqual(posted, true)
    }

    func testSameDOMTargetMutationInvalidatesPendingApproval() async throws {
        let lines = try await snapshotLines()
        let elementID = try id(of: "Post update", in: lines)
        let approvalID = UUID().uuidString
        let nonce = try await documentNonce()
        let first = try await agent(BrowserAgentPageScript.click, [
            "id": elementID, "confirmed": false, "approvalID": approvalID, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(first["reason"] as? String, "post")

        _ = try await page("document.getElementById('post-button').textContent = 'Buy now'")
        let replay = try await agent(BrowserAgentPageScript.click, [
            "id": elementID, "confirmed": true, "approvalID": approvalID,
            "confirmationContextID": first["contextID"] as? String ?? "", "expectedDocumentNonce": nonce
        ])
        XCTAssertNotNil(replay["error"])
        XCTAssertFalse(replay["error"] as? String == nil)
        let posted = try await page("window.posted === true") as? Bool
        XCTAssertNotEqual(posted, true)
    }

    func testFocusHandlersCannotEscalateApprovedClickOrTextEntry() async throws {
        let lines = try await snapshotLines()
        let nonce = try await documentNonce()
        let buttonID = try await domElementID("focus-mutating-post")
        let clickApprovalID = UUID().uuidString
        let pendingClick = try await agent(BrowserAgentPageScript.click, [
            "id": buttonID, "confirmed": false,
            "approvalID": clickApprovalID, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(pendingClick["needsConfirmation"] as? Bool, true)
        let click = try await agent(BrowserAgentPageScript.click, [
            "id": buttonID, "confirmed": true,
            "approvalID": clickApprovalID,
            "confirmationContextID": pendingClick["contextID"] as? String ?? "",
            "expectedDocumentNonce": nonce
        ])
        XCTAssertNotNil(click["error"])
        let clickEffect = try await page("window.focusMutationClicked === true") as? Bool
        XCTAssertNotEqual(clickEffect, true)

        let inputID = try id(of: "Focus mutation field", in: lines)
        let typeApprovalID = UUID().uuidString
        let pendingType = try await agent(BrowserAgentPageScript.type, [
            "id": inputID, "text": "message must not be written", "submit": true, "confirmed": false,
            "approvalID": typeApprovalID, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(pendingType["needsConfirmation"] as? Bool, true)
        let typed = try await agent(BrowserAgentPageScript.type, [
            "id": inputID, "text": "message must not be written", "submit": true, "confirmed": true,
            "approvalID": typeApprovalID,
            "confirmationContextID": pendingType["contextID"] as? String ?? "",
            "expectedDocumentNonce": nonce
        ])
        XCTAssertNotNil(typed["error"])
        let fieldValue = try await page("document.getElementById('focus-mutating-input').value") as? String
        let submitted = try await page("window.focusMutationSubmitted === true") as? Bool
        XCTAssertEqual(fieldValue, "")
        XCTAssertNotEqual(submitted, true)
    }

    func testSelectOptionByText() async throws {
        let lines = try await snapshotLines()
        let result = try await agent(BrowserAgentPageScript.select, ["id": try id(of: "Size", in: lines), "option": "medium"])
        XCTAssertEqual(result["ok"] as? Bool, true)
        let value = try await page("document.getElementById('size').value") as? String
        XCTAssertEqual(value, "m")
    }

    func testStaleIdReportsError() async throws {
        do {
            _ = try await agent(BrowserAgentPageScript.click, ["id": 9_999, "confirmed": false])
            XCTFail("expected an error for an unknown id")
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
            XCTAssertTrue(message.contains("no longer on the page"), message)
        }
    }

    func testPressKeyPerformsRealFocusTextSearchAndSelectEffects() async throws {
        let lines = try await snapshotLines()
        let nonce = try await documentNonce()
        let queryID = try id(of: "Search products", in: lines)

        let tab = try await agent(BrowserAgentPageScript.pressKey, [
            "key": "Tab", "id": queryID, "confirmed": false, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(tab["ok"] as? Bool, true)
        let focusedText = try await page("document.activeElement.textContent.trim()") as? String
        XCTAssertEqual(focusedText, "Search")

        _ = try await page("document.getElementById('q').value = 'shoes'")
        _ = try await page("document.getElementById('q').setSelectionRange(5, 5)")
        let backspace = try await agent(BrowserAgentPageScript.pressKey, [
            "key": "Backspace", "id": queryID, "confirmed": false, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(backspace["ok"] as? Bool, true)
        let afterBackspace = try await page("document.getElementById('q').value") as? String
        XCTAssertEqual(afterBackspace, "shoe")

        let enter = try await agent(BrowserAgentPageScript.pressKey, [
            "key": "Enter", "id": queryID, "confirmed": false, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(enter["ok"] as? Bool, true)
        let searched = try await page("window.searched") as? String
        XCTAssertEqual(searched, "shoe")

        _ = try await page("document.getElementById('size').focus()")
        let selectID = try id(of: "Size", in: lines)
        let arrow = try await agent(BrowserAgentPageScript.pressKey, [
            "key": "ArrowDown", "id": selectID, "confirmed": false, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(arrow["ok"] as? Bool, true)
        let selectedSize = try await page("document.getElementById('size').value") as? String
        XCTAssertEqual(selectedSize, "m")
    }

    func testPressKeyDoesNotMutateDisabledOrReadOnlyControls() async throws {
        let lines = try await snapshotLines()
        let nonce = try await documentNonce()

        let disabledID = try id(of: "Disabled field", in: lines)
        let disabled = try await agent(BrowserAgentPageScript.pressKey, [
            "key": "Backspace", "id": disabledID, "confirmed": true, "expectedDocumentNonce": nonce
        ])
        XCTAssertNotNil(disabled["error"])

        let readonlyID = try id(of: "Read-only field", in: lines)
        let readonly = try await agent(BrowserAgentPageScript.pressKey, [
            "key": "Backspace", "id": readonlyID, "confirmed": true, "expectedDocumentNonce": nonce
        ])
        XCTAssertNotNil(readonly["error"])

        let disabledSelectID = try id(of: "Disabled size", in: lines)
        let disabledSelect = try await agent(BrowserAgentPageScript.pressKey, [
            "key": "ArrowDown", "id": disabledSelectID, "confirmed": true, "expectedDocumentNonce": nonce
        ])
        XCTAssertNotNil(disabledSelect["error"])
        let disabledValue = try await page("document.getElementById('disabled-input').value") as? String
        let readonlyValue = try await page("document.getElementById('readonly-input').value") as? String
        let disabledSelection = try await page("document.getElementById('disabled-size').value") as? String
        XCTAssertEqual(disabledValue, "locked")
        XCTAssertEqual(readonlyValue, "locked")
        XCTAssertEqual(disabledSelection, "a")
    }

    func testAutofillUsesAssociatedLabelsNamePartsAndCountryCodeWithoutReturningLabelsOrValues() async throws {
        await replaceWithDedicatedFixture("""
        <!doctype html><html><body>
          <form id="profile-form" method="post" action="/profile">
            <label for="profile-full">Full name</label><input id="profile-full" autocomplete="name">
            <label for="profile-first">First Name</label><input id="profile-first">
            <span id="profile-middle-label">Middle Name</span><input id="profile-middle" aria-labelledby="profile-middle-label">
            <label for="profile-family">Family Name</label><input id="profile-family">
            <label for="opaque-country">Country</label><select id="opaque-country" autocomplete="country"><option value="">Choose a country</option><option value="PT">Portugal</option></select>
            <label for="opaque-country-name">Country Name</label><input id="opaque-country-name">
            <label for="opaque-company">Company Name</label><input id="opaque-company">
          </form>
          <form id="protected-form"></form>
          <label for="external-email">External email</label><input id="external-email" form="protected-form" autocomplete="email">
          <input id="external-password" form="protected-form" type="password" name="password">
        </body></html>
        """)
        let nonce = try await documentNonce()
        let previewID = UUID().uuidString
        let preview = try await agent(BrowserAgentPageScript.previewAutofill, [
            "previewID": previewID,
            "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(preview["documentNonce"] as? String, nonce)
        let fields = try XCTUnwrap(preview["fields"] as? [[String: Any]])
        let actual = Dictionary(uniqueKeysWithValues: fields.compactMap { field -> (String, String)? in
            guard let id = field["id"] as? NSNumber, let key = field["key"] as? String else { return nil }
            return (String(id.intValue), key)
        })
        let fullNameID = String(try await domElementID("profile-full"))
        let firstNameID = String(try await domElementID("profile-first"))
        let middleNameID = String(try await domElementID("profile-middle"))
        let familyNameID = String(try await domElementID("profile-family"))
        let countryID = String(try await domElementID("opaque-country"))
        let countryNameID = String(try await domElementID("opaque-country-name"))
        let companyNameID = String(try await domElementID("opaque-company"))
        let externalEmailID = String(try await domElementID("external-email"))
        XCTAssertEqual(actual[fullNameID], "fullName")
        XCTAssertEqual(actual[firstNameID], "givenName")
        XCTAssertEqual(actual[middleNameID], "middleName")
        XCTAssertEqual(actual[familyNameID], "familyName")
        XCTAssertEqual(actual[countryID], "country", "autocomplete=country works even when the control has an opaque id.")
        XCTAssertEqual(actual[countryNameID], "country", "A country-name label stays a country field, not a full-name field.")
        XCTAssertEqual(actual[companyNameID], "organization", "A company-name label stays an organization field.")
        XCTAssertFalse(actual.keys.contains(externalEmailID), "A password associated from outside the form still protects every form field.")
        XCTAssertEqual(Set(fields.first?.keys.map { $0 } ?? []), Set(["id", "key"]))
        let previewData = try JSONSerialization.data(withJSONObject: preview)
        XCTAssertFalse(previewData.contains(Data("Full name".utf8)), "Labels never leave the page-world preview.")

        let fill = try await agent(BrowserAgentPageScript.fillAutofillPreview, [
            "previewID": previewID,
            "expectedDocumentNonce": nonce,
            "profileValues": [
                "fullName": "Ada Byron Lovelace", "givenName": "Ada", "middleName": "Byron",
                "familyName": "Lovelace", "country": "Portugal"
            ]
        ])
        XCTAssertEqual(fill["ok"] as? Bool, true)
        let filledKeys = Set(fill["filledKeys"] as? [String] ?? [])
        XCTAssertTrue(["fullName", "givenName", "middleName", "familyName", "country"].allSatisfy(filledKeys.contains))
        XCTAssertFalse((try JSONSerialization.data(withJSONObject: fill)).contains(Data("Ada Byron Lovelace".utf8)), "Tool output contains canonical field names only.")
        let filledFullName = try await page("document.getElementById('profile-full').value") as? String
        let filledFirstName = try await page("document.getElementById('profile-first').value") as? String
        let filledMiddleName = try await page("document.getElementById('profile-middle').value") as? String
        let filledFamilyName = try await page("document.getElementById('profile-family').value") as? String
        let filledCountry = try await page("document.getElementById('opaque-country').value") as? String
        XCTAssertEqual(filledFullName, "Ada Byron Lovelace")
        XCTAssertEqual(filledFirstName, "Ada")
        XCTAssertEqual(filledMiddleName, "Byron")
        XCTAssertEqual(filledFamilyName, "Lovelace")
        XCTAssertEqual(filledCountry, "PT", "A localized country name maps to the option's country code.")
    }

    func testAutofillRejectsFocusEscalationAndDisabledCountryOptgroup() async throws {
        await replaceWithDedicatedFixture("""
        <!doctype html><html><body><form>
          <label for="focus-fill-email">Contact email</label>
          <input id="focus-fill-email" name="email" autocomplete="email" onfocus="this.type='password'">
        </form></body></html>
        """)
        let nonce = try await documentNonce()
        let previewID = UUID().uuidString
        _ = try await agent(BrowserAgentPageScript.previewAutofill, ["previewID": previewID, "expectedDocumentNonce": nonce])
        let result = try await agent(BrowserAgentPageScript.fillAutofillPreview, [
            "previewID": previewID,
            "expectedDocumentNonce": nonce,
            "profileValues": ["email": "ada@example.test", "country": "Portugal"]
        ])
        XCTAssertNotNil(result["error"] as? String, "A focus handler that changes an email field into a password must abort before writing.")
        let escalatedValue = try await page("document.getElementById('focus-fill-email').value") as? String
        XCTAssertEqual(escalatedValue, "")

        await replaceWithDedicatedFixture("""
        <!doctype html><html><body>
          <label for="disabled-country">Country</label>
          <select id="disabled-country" autocomplete="country"><optgroup label="Unavailable" disabled><option value="PT">Portugal</option></optgroup></select>
        </body></html>
        """)
        let countryNonce = try await documentNonce()
        let initialCountryValue = try await page("document.getElementById('disabled-country').value") as? String
        let countryPreviewID = UUID().uuidString
        _ = try await agent(BrowserAgentPageScript.previewAutofill, ["previewID": countryPreviewID, "expectedDocumentNonce": countryNonce])
        let country = try await agent(BrowserAgentPageScript.fillAutofillPreview, [
            "previewID": countryPreviewID,
            "expectedDocumentNonce": countryNonce,
            "profileValues": ["country": "Portugal"]
        ])
        XCTAssertNotEqual(country["ok"] as? Bool, true)
        let disabledCountryValue = try await page("document.getElementById('disabled-country').value") as? String
        XCTAssertEqual(disabledCountryValue, initialCountryValue, "A disabled option group must remain unchanged even when the browser selected its initial value.")
        XCTAssertTrue((country["skippedKeys"] as? [String] ?? []).contains("country"))
    }

    func testAutofillPreviewRejectsAccessibleLabelMutationWithSameCanonicalField() async throws {
        await replaceWithDedicatedFixture("""
        <!doctype html><html><body>
          <label id="mutable-email-label" for="mutable-email">Contact email label</label>
          <input id="mutable-email" autocomplete="email">
        </body></html>
        """)
        let nonce = try await documentNonce()
        let previewID = UUID().uuidString
        let preview = try await agent(BrowserAgentPageScript.previewAutofill, [
            "previewID": previewID,
            "expectedDocumentNonce": nonce
        ])
        let fields = try XCTUnwrap(preview["fields"] as? [[String: Any]])
        let emailID = String(try await domElementID("mutable-email"))
        XCTAssertTrue(fields.contains { ($0["id"] as? NSNumber)?.stringValue == emailID && ($0["key"] as? String) == "email" })

        _ = try await page("document.getElementById('mutable-email-label').textContent = 'Purchase account' ")
        let validation = try await agent(BrowserAgentPageScript.validateAutofillPreview, [
            "previewID": previewID,
            "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(validation["valid"] as? Bool, false, "A label can change while autocomplete still maps to email, so the approval binding must fail.")

        let result = try await agent(BrowserAgentPageScript.fillAutofillPreview, [
            "previewID": previewID,
            "expectedDocumentNonce": nonce,
            "profileValues": ["email": "ada@example.test"]
        ])
        XCTAssertNotNil(result["error"] as? String)
        let value = try await page("document.getElementById('mutable-email').value") as? String
        XCTAssertEqual(value, "")
    }

    func testAutofillSkipsHiddenCSRFTokenButFillsOrdinaryContactPostFields() async throws {
        await replaceWithDedicatedFixture("""
        <!doctype html><html><body>
          <form id="csrf-contact-form" method="post" action="/contact">
            <input id="csrf-hidden-token" type="hidden" name="csrf_token" value="fixture-csrf-token">
            <label for="csrf-contact-email">Contact email</label>
            <input id="csrf-contact-email" type="email" name="contact_email" autocomplete="email">
            <button type="submit">Send message</button>
          </form>
          <script>document.getElementById('csrf-contact-form').addEventListener('submit', event => { event.preventDefault(); window.csrfContactSubmitted = true; });</script>
        </body></html>
        """)
        let nonce = try await documentNonce()
        let previewID = UUID().uuidString
        let preview = try await agent(BrowserAgentPageScript.previewAutofill, [
            "previewID": previewID,
            "expectedDocumentNonce": nonce
        ])
        let fields = try XCTUnwrap(preview["fields"] as? [[String: Any]])
        let emailID = String(try await domElementID("csrf-contact-email"))
        let tokenID = String(try await domElementID("csrf-hidden-token"))
        XCTAssertTrue(fields.contains { ($0["id"] as? NSNumber)?.stringValue == emailID && ($0["key"] as? String) == "email" },
            "A recognizable hidden CSRF token must not make an ordinary contact form unfillable.")
        XCTAssertFalse(fields.contains { ($0["id"] as? NSNumber)?.stringValue == tokenID }, "Hidden tokens are never autofill candidates.")

        let result = try await agent(BrowserAgentPageScript.fillAutofillPreview, [
            "previewID": previewID,
            "expectedDocumentNonce": nonce,
            "profileValues": ["email": "ada@example.test"]
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        let emailValue = try await page("document.getElementById('csrf-contact-email').value") as? String
        let tokenValue = try await page("document.getElementById('csrf-hidden-token').value") as? String
        let submitted = try await page("window.csrfContactSubmitted === true") as? Bool
        XCTAssertEqual(emailValue, "ada@example.test")
        XCTAssertEqual(tokenValue, "fixture-csrf-token")
        XCTAssertNotEqual(submitted, true, "Filling must not submit the form.")
    }

    func testEnterChecksRiskySubmitterEvenInsideSearchForm() async throws {
        let lines = try await snapshotLines()
        let result = try await agent(BrowserAgentPageScript.pressKey, [
            "key": "Enter",
            "id": try id(of: "Product query", in: lines),
            "confirmed": false,
            "approvalID": UUID().uuidString,
            "expectedDocumentNonce": try await documentNonce()
        ])
        XCTAssertEqual(result["needsConfirmation"] as? Bool, true)
        XCTAssertEqual(result["reason"] as? String, "buy")
        let didSubmit = try await page("window.riskySearchSubmitted === true") as? Bool
        XCTAssertNotEqual(didSubmit, true)
    }

    func testTypeSubmitSkipsNonSubmitButtonAndUsesRealSubmitter() async throws {
        let lines = try await snapshotLines()
        let result = try await agent(BrowserAgentPageScript.type, [
            "id": try id(of: "Site search query", in: lines), "text": "vortyra", "submit": true, "confirmed": false
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertNil(result["error"])
        let submitter = try await page("window.ddgSubmitter") as? String
        XCTAssertEqual(submitter, "ddg-submit")
        let typed = try await page("document.getElementById('ddg-query').value") as? String
        XCTAssertEqual(typed, "vortyra")
    }

    func testEnterSkipsNonSubmitButtonAndUsesRealSubmitter() async throws {
        let lines = try await snapshotLines()
        let result = try await agent(BrowserAgentPageScript.pressKey, [
            "key": "Enter", "id": try id(of: "Site search query", in: lines), "confirmed": false
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertNil(result["error"])
        let submitter = try await page("window.ddgSubmitter") as? String
        XCTAssertEqual(submitter, "ddg-submit")
    }

    func testFormWithOnlyNonSubmitButtonSubmitsWithoutSubmitter() async throws {
        let lines = try await snapshotLines()
        let fieldID = try id(of: "Button only query", in: lines)

        let enter = try await agent(BrowserAgentPageScript.pressKey, [
            "key": "Enter", "id": fieldID, "confirmed": false
        ])
        XCTAssertEqual(enter["ok"] as? Bool, true)
        XCTAssertNil(enter["error"])
        let enterSubmitter = try await page("window.buttonOnlySubmitter") as? String
        XCTAssertEqual(enterSubmitter, "none")

        let typed = try await agent(BrowserAgentPageScript.type, [
            "id": fieldID, "text": "vortyra", "submit": true, "confirmed": false
        ])
        XCTAssertEqual(typed["ok"] as? Bool, true)
        XCTAssertNil(typed["error"])
        let typeSubmitter = try await page("window.buttonOnlySubmitter") as? String
        XCTAssertEqual(typeSubmitter, "none")
    }

    func testSubmitRiskJudgedFromRealSubmitterNotEarlierButton() async throws {
        let lines = try await snapshotLines()
        let result = try await agent(BrowserAgentPageScript.type, [
            "id": try id(of: "Item name", in: lines), "text": "vortyra", "submit": true,
            "confirmed": false, "approvalID": UUID().uuidString,
            "expectedDocumentNonce": try await documentNonce()
        ])
        XCTAssertEqual(result["needsConfirmation"] as? Bool, true)
        XCTAssertEqual(result["reason"] as? String, "buy")
        let submitted = try await page("window.cartSubmitted === true") as? Bool
        XCTAssertNotEqual(submitted, true)
    }

    func testScreenshotMaskHidesSensitiveControlsAndFramesThenRestoresInlineStyles() async throws {
        let nonce = try await documentNonce()
        let captureOwner = UUID().uuidString
        let originalColor = try await page("document.getElementById('otp').style.color") as? String
        let mask = try await agent(BrowserAgentPageScript.maskSensitiveForScreenshot, [
            "expectedDocumentNonce": nonce,
            "captureOwner": captureOwner,
            "captureSequence": 1
        ])
        XCTAssertNil(mask["error"])
        XCTAssertGreaterThan(mask["masked"] as? Int ?? 0, 0)
        let passwordVisibility = try await page("getComputedStyle(document.querySelector('input[type=password]')).visibility") as? String
        let otpVisibility = try await page("getComputedStyle(document.getElementById('otp')).visibility") as? String
        let frameVisibility = try await page("getComputedStyle(document.getElementById('payment-frame')).visibility") as? String
        XCTAssertEqual(passwordVisibility, "hidden")
        XCTAssertEqual(otpVisibility, "hidden")
        XCTAssertEqual(frameVisibility, "hidden")

        let restored = try await agent(BrowserAgentPageScript.restoreScreenshotMask, [
            "expectedDocumentNonce": nonce,
            "captureOwner": captureOwner,
            "captureSequence": 1
        ])
        XCTAssertGreaterThan(restored["restored"] as? Int ?? 0, 0)
        let restoredPasswordVisibility = try await page("getComputedStyle(document.querySelector('input[type=password]')).visibility") as? String
        let restoredOTPVisibility = try await page("getComputedStyle(document.getElementById('otp')).visibility") as? String
        let restoredColor = try await page("document.getElementById('otp').style.color") as? String
        XCTAssertEqual(restoredPasswordVisibility, "visible")
        XCTAssertEqual(restoredOTPVisibility, "visible")
        XCTAssertEqual(restoredColor, originalColor)
    }

    func testStaleScreenshotCleanupCannotRestoreANewerCaptureMask() async throws {
        let nonce = try await documentNonce()
        let oldOwner = UUID().uuidString
        let currentOwner = UUID().uuidString
        let oldMask = try await agent(BrowserAgentPageScript.maskSensitiveForScreenshot, [
            "expectedDocumentNonce": nonce,
            "captureOwner": oldOwner,
            "captureSequence": 1
        ])
        XCTAssertNil(oldMask["error"])
        XCTAssertGreaterThan(oldMask["masked"] as? Int ?? 0, 0)

        let currentMask = try await agent(BrowserAgentPageScript.maskSensitiveForScreenshot, [
            "expectedDocumentNonce": nonce,
            "captureOwner": currentOwner,
            "captureSequence": 2
        ])
        XCTAssertEqual(currentMask["ownershipTransferred"] as? Bool, true)

        let lateOldMask = try await agent(BrowserAgentPageScript.maskSensitiveForScreenshot, [
            "expectedDocumentNonce": nonce,
            "captureOwner": oldOwner,
            "captureSequence": 1
        ])
        XCTAssertEqual(lateOldMask["staleOwner"] as? Bool, true)

        let staleCleanup = try await agent(BrowserAgentPageScript.restoreScreenshotMask, [
            "expectedDocumentNonce": nonce,
            "captureOwner": oldOwner
        ])
        XCTAssertEqual(staleCleanup["staleOwner"] as? Bool, true)
        let stillMasked = try await page("getComputedStyle(document.querySelector('input[type=password]')).visibility") as? String
        XCTAssertEqual(stillMasked, "hidden")

        let cleanup = try await agent(BrowserAgentPageScript.restoreScreenshotMask, [
            "expectedDocumentNonce": nonce,
            "captureOwner": currentOwner
        ])
        XCTAssertGreaterThan(cleanup["restored"] as? Int ?? 0, 0)
        let restored = try await page("getComputedStyle(document.querySelector('input[type=password]')).visibility") as? String
        XCTAssertEqual(restored, "visible")
    }

    func testNewScreenshotMaskAddsLateSensitiveControlsWithoutLosingOriginalStyles() async throws {
        let nonce = try await documentNonce()
        let originalOwner = UUID().uuidString
        let newerOwner = UUID().uuidString
        let originalColor = try await page("document.getElementById('otp').style.color") as? String
        let originalOTPVisibility = try await page("document.getElementById('otp').style.getPropertyValue('visibility')") as? String
        let originalOTPPriority = try await page("document.getElementById('otp').style.getPropertyPriority('visibility')") as? String
        let originalMask = try await agent(BrowserAgentPageScript.maskSensitiveForScreenshot, [
            "expectedDocumentNonce": nonce,
            "captureOwner": originalOwner,
            "captureSequence": 1
        ])
        XCTAssertNil(originalMask["error"])

        let siteChangedMaskedControl = try await page("""
        (() => {
          const otp = document.getElementById('otp');
          otp.style.setProperty('visibility', 'visible', 'important');
          return true;
        })()
        """) as? Bool
        XCTAssertEqual(siteChangedMaskedControl, true)

        let inserted = try await page("""
        (() => {
          const input = document.createElement('input');
          input.type = 'password'; input.id = 'late-password';
          input.style.setProperty('visibility', 'collapse', 'important');
          document.body.appendChild(input);
          const frame = document.createElement('iframe');
          frame.id = 'late-frame';
          frame.style.setProperty('visibility', 'visible', 'important');
          document.body.appendChild(frame);
          return true;
        })()
        """) as? Bool
        XCTAssertEqual(inserted, true)

        let newerMask = try await agent(BrowserAgentPageScript.maskSensitiveForScreenshot, [
            "expectedDocumentNonce": nonce,
            "captureOwner": newerOwner,
            "captureSequence": 2
        ])
        XCTAssertNil(newerMask["error"])
        XCTAssertEqual(newerMask["ownershipTransferred"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(newerMask["added"] as? Int ?? 0, 2)
        let hiddenNewPassword = try await page("getComputedStyle(document.getElementById('late-password')).visibility") as? String
        let hiddenNewFrame = try await page("getComputedStyle(document.getElementById('late-frame')).visibility") as? String
        let hiddenPreviouslyMaskedOTP = try await page("getComputedStyle(document.getElementById('otp')).visibility") as? String
        XCTAssertEqual(hiddenNewPassword, "hidden")
        XCTAssertEqual(hiddenNewFrame, "hidden")
        XCTAssertEqual(hiddenPreviouslyMaskedOTP, "hidden", "Ownership transfer must re-mask sensitive controls sites changed after the first capture.")

        let staleRestore = try await agent(BrowserAgentPageScript.restoreScreenshotMask, [
            "expectedDocumentNonce": nonce,
            "captureOwner": originalOwner
        ])
        XCTAssertEqual(staleRestore["staleOwner"] as? Bool, true)
        let stillHidden = try await page("getComputedStyle(document.getElementById('late-password')).visibility") as? String
        XCTAssertEqual(stillHidden, "hidden")

        let restored = try await agent(BrowserAgentPageScript.restoreScreenshotMask, [
            "expectedDocumentNonce": nonce,
            "captureOwner": newerOwner
        ])
        XCTAssertGreaterThan(restored["restored"] as? Int ?? 0, 0)
        let passwordVisibility = try await page("getComputedStyle(document.querySelector('input[type=password]')).visibility") as? String
        let otpVisibility = try await page("getComputedStyle(document.getElementById('otp')).visibility") as? String
        let latePasswordVisibility = try await page("document.getElementById('late-password').style.getPropertyValue('visibility')") as? String
        let latePasswordPriority = try await page("document.getElementById('late-password').style.getPropertyPriority('visibility')") as? String
        let lateFrameVisibility = try await page("document.getElementById('late-frame').style.getPropertyValue('visibility')") as? String
        let lateFramePriority = try await page("document.getElementById('late-frame').style.getPropertyPriority('visibility')") as? String
        let restoredOTPInlineVisibility = try await page("document.getElementById('otp').style.getPropertyValue('visibility')") as? String
        let restoredOTPPriority = try await page("document.getElementById('otp').style.getPropertyPriority('visibility')") as? String
        let restoredColor = try await page("document.getElementById('otp').style.color") as? String
        XCTAssertEqual(passwordVisibility, "visible")
        XCTAssertEqual(otpVisibility, "visible")
        XCTAssertEqual(latePasswordVisibility, "collapse")
        XCTAssertEqual(latePasswordPriority, "important")
        XCTAssertEqual(lateFrameVisibility, "visible")
        XCTAssertEqual(lateFramePriority, "important")
        XCTAssertEqual(restoredOTPInlineVisibility, originalOTPVisibility)
        XCTAssertEqual(restoredOTPPriority, originalOTPPriority)
        XCTAssertEqual(restoredColor, originalColor)
    }

    func testSetCheckedIsIdempotentAndRadioUncheckIsRejected() async throws {
        let lines = try await snapshotLines()
        let nonce = try await documentNonce()
        let checkboxID = try id(of: "Optional updates", in: lines)
        let unchanged = try await agent(BrowserAgentPageScript.setChecked, [
            "id": checkboxID, "checked": false, "confirmed": false, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(unchanged["ok"] as? Bool, true)
        XCTAssertEqual(unchanged["changed"] as? Bool, false)

        let checked = try await agent(BrowserAgentPageScript.setChecked, [
            "id": checkboxID, "checked": true, "confirmed": false, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(checked["checked"] as? Bool, true)
        let isChecked = try await page("document.getElementById('updates').checked") as? Bool
        XCTAssertEqual(isChecked, true)

        let selectedRadioID = try id(of: "Selected plan", in: lines)
        let rejectUncheck = try await agent(BrowserAgentPageScript.setChecked, [
            "id": selectedRadioID, "checked": false, "confirmed": false, "expectedDocumentNonce": nonce
        ])
        XCTAssertNotNil(rejectUncheck["error"])
        let selectedRadioIsChecked = try await page("document.getElementById('selected-radio').checked") as? Bool
        XCTAssertEqual(selectedRadioIsChecked, true)

        let otherRadioID = try id(of: "Other plan", in: lines)
        let alreadyUnchecked = try await agent(BrowserAgentPageScript.setChecked, [
            "id": otherRadioID, "checked": false, "confirmed": false, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(alreadyUnchecked["ok"] as? Bool, true)
        XCTAssertEqual(alreadyUnchecked["changed"] as? Bool, false)
    }

    func testConfirmationReplayRejectsSameURLReplacementDocument() async throws {
        let lines = try await snapshotLines()
        let originalURL = webView.url
        let nonce = try await documentNonce()
        let elementID = try id(of: "Delete account", in: lines)
        let first = try await agent(BrowserAgentPageScript.setChecked, [
            "id": elementID, "checked": true, "confirmed": false, "approvalID": UUID().uuidString, "expectedDocumentNonce": nonce
        ])
        XCTAssertEqual(first["needsConfirmation"] as? Bool, true)
        let initialChecked = try await page("document.getElementById('delete-checkbox').checked") as? Bool
        XCTAssertEqual(initialChecked, false)

        await reloadSameURLDocument()
        XCTAssertEqual(webView.url, originalURL)
        let newNonce = try await documentNonce()
        XCTAssertNotEqual(newNonce, nonce)
        let replacementLines = try await snapshotLines()
        let replacementID = try id(of: "Delete account", in: replacementLines)
        XCTAssertEqual(replacementID, elementID, "The replacement document may reuse the old numeric element ID.")
        let replay = try await agent(BrowserAgentPageScript.setChecked, [
            "id": replacementID, "checked": true, "confirmed": true,
            "approvalID": first["approvalID"] as? String ?? "", "confirmationContextID": first["contextID"] as? String ?? "",
            "expectedDocumentNonce": nonce
        ])
        XCTAssertNotNil(replay["error"])
        let replayChecked = try await page("document.getElementById('delete-checkbox').checked") as? Bool
        XCTAssertEqual(replayChecked, false)

        let staleKey = try await agent(BrowserAgentPageScript.pressKey, [
            "key": "Space", "id": replacementID, "confirmed": true, "expectedDocumentNonce": nonce
        ])
        XCTAssertNotNil(staleKey["error"])
        let keyReplayChecked = try await page("document.getElementById('delete-checkbox').checked") as? Bool
        XCTAssertEqual(keyReplayChecked, false)

        let staleHide = try await agent(BrowserAgentInteractionScript.hideElement, [
            "id": try id(of: "Hide target", in: replacementLines), "expectedDocumentNonce": nonce
        ])
        XCTAssertNotNil(staleHide["error"])
    }

    func testInspectRedactsSensitiveAttributesAndSanitizesHref() async throws {
        let lines = try await snapshotLines()
        let otp = try await agent(BrowserAgentPageScript.inspect, ["id": try id(of: "Verification code", in: lines)])
        XCTAssertEqual(otp["value"] as? String, "[redacted]")
        XCTAssertEqual(otp["label"] as? String, "Sensitive field")
        let attributes = try XCTUnwrap(otp["attributes"] as? [[String: Any]])
        XCTAssertTrue(attributes.contains { $0["name"] as? String == "data-token" && $0["value"] as? String == "[redacted]" })
        XCTAssertFalse(String(describing: otp).contains("654321"))
        XCTAssertFalse(String(describing: otp).contains("super-secret-token"))

        let authorField = try await agent(BrowserAgentPageScript.inspect, ["id": try id(of: "Article author", in: lines)])
        XCTAssertEqual(authorField["sensitive"] as? Bool, false)
        XCTAssertEqual(authorField["label"] as? String, "Article author")
        let authorInspection = BrowserAgentController.redactedInspection(authorField)
        let authorAttributes = try XCTUnwrap(authorInspection["attributes"] as? [[String: Any]])
        XCTAssertTrue(authorAttributes.contains { $0["name"] as? String == "aria-label" && $0["value"] as? String == "Article author" })
        let authInspection = BrowserAgentController.redactedInspection(["attributes": [
            ["name": "data-auth-token", "value": "oauth-secret"],
            ["name": "aria-label", "value": "Authorization code"]
        ]])
        let authAttributes = try XCTUnwrap(authInspection["attributes"] as? [[String: Any]])
        XCTAssertTrue(authAttributes.allSatisfy { $0["value"] as? String == "[redacted]" })

        let link = try await agent(BrowserAgentPageScript.inspect, ["id": try id(of: "Private URL", in: lines)])
        let href = try XCTUnwrap(link["href"] as? String)
        XCTAssertFalse(href.contains("super-secret-token"))
        XCTAssertTrue(href.contains("region=porto"))

        let snapshotLabel = String(repeating: "L", count: 79) + "…"
        let longLabel = try await agent(BrowserAgentPageScript.inspect, ["id": try id(of: snapshotLabel, in: lines)])
        XCTAssertEqual((longLabel["label"] as? String)?.count, 320)
    }

    func testDismissOverlaysOnlyUsesSafeRejectControlAndHideUsesStableSelector() async throws {
        _ = try await snapshotLines()
        let overlays = try await agent(BrowserAgentInteractionScript.dismissOverlays)
        XCTAssertEqual(overlays["count"] as? Int, 1)
        let didReject = try await page("window.rejected === true") as? Bool
        let didAccept = try await page("window.accepted === true") as? Bool
        let didDelete = try await page("window.overlayDeleted === true") as? Bool
        XCTAssertEqual(didReject, true)
        XCTAssertNotEqual(didAccept, true)
        XCTAssertNotEqual(didDelete, true)

        let lines = try await snapshotLines()
        let selector = try await agent(BrowserAgentInteractionScript.hideElement, [
            "id": try id(of: "Hide target", in: lines),
            "expectedDocumentNonce": try await documentNonce()
        ])
        XCTAssertNotNil(selector["selector"] as? String)
        XCTAssertNil(selector["error"])

        let sensitive = try await agent(BrowserAgentInteractionScript.hideElement, [
            "id": try id(of: "Verification code", in: lines),
            "expectedDocumentNonce": try await documentNonce()
        ])
        XCTAssertNotNil(sensitive["error"])
    }

    func testRedactValuesReplaceProfileEchoesBeforeAnyClipInEveryWorldOutput() async throws {
        let longAriaLabel = String(repeating: "x", count: 75) + "Johnathan Example"
        await replaceWithDedicatedFixture("""
        <!doctype html><html><head><title>Hello Johnathan Example</title></head><body>
          <input id="n" aria-label="Full name" value="Johnathan Example">
          <p>Hello Johnathan Example</p>
          <button id="clip" aria-label="\(longAriaLabel)">Clip target</button>
          <button id="cont" type="button" onclick="window.clicked=true">Continue</button>
        </body></html>
        """)
        let redactValues = ["Johnathan Example"]
        let snapshot = try await agent(BrowserAgentPageScript.snapshot, [
            "maxElements": 150,
            "maxText": 2_500,
            "redactValues": redactValues
        ])
        let elements = snapshot["elements"] as? String ?? ""
        let visibleText = snapshot["text"] as? String ?? ""
        let title = snapshot["title"] as? String ?? ""
        XCTAssertTrue(elements.contains("value=\"[redacted]\""), "Input values must be redacted: \(elements)")
        XCTAssertTrue(visibleText.contains("[redacted]"), "Visible page text must be redacted: \(visibleText)")
        XCTAssertTrue(title.contains("[redacted]"), "The document title must be redacted: \(title)")
        for output in [elements, visibleText, title] {
            XCTAssertFalse(output.contains("Johnathan Example"), output)
            XCTAssertFalse(output.contains("John"), "No four-character-or-longer value prefix may leak: \(output)")
        }
        let clipLine = try XCTUnwrap(
            elements.components(separatedBy: "\n").first { $0.contains("Clip") || $0.contains("xxxx") }
        )
        XCTAssertFalse(clipLine.contains("John"), "A clipped label must not leak a value prefix: \(clipLine)")

        let read = try await agent(BrowserAgentPageScript.readText, [
            "offset": 0,
            "maxChars": 4_000,
            "redactValues": redactValues
        ])
        let pageText = read["text"] as? String ?? ""
        XCTAssertTrue(pageText.contains("[redacted]"))
        XCTAssertFalse(pageText.contains("John"), pageText)

        let inputInspect = try await agent(BrowserAgentPageScript.inspect, [
            "id": try await domElementID("n"),
            "redactValues": redactValues
        ])
        XCTAssertEqual(inputInspect["value"] as? String, "[redacted]")
        XCTAssertFalse((inputInspect["label"] as? String ?? "").contains("John"))

        let clickID = try await domElementID("cont")
        let click = try await agent(BrowserAgentPageScript.click, [
            "id": clickID,
            "confirmed": false,
            "approvalID": UUID().uuidString,
            "expectedDocumentNonce": try await documentNonce(),
            "redactValues": redactValues
        ])
        let clickTarget = click["target"] as? String ?? ""
        XCTAssertTrue(clickTarget.contains("Continue"), clickTarget)
        XCTAssertFalse(clickTarget.contains("John"), clickTarget)
        let clipClick = try await agent(BrowserAgentPageScript.click, [
            "id": try await domElementID("clip"),
            "confirmed": false,
            "approvalID": UUID().uuidString,
            "expectedDocumentNonce": try await documentNonce(),
            "redactValues": redactValues
        ])
        XCTAssertFalse(
            (clipClick["target"] as? String ?? "").contains("John"),
            "A clipped click target must not leak a value prefix: \(clipClick["target"] ?? "")"
        )
    }

    private static let searchResultsFixture = """
    <!doctype html><html><body>
      <header>
        <a id="nav-home" href="https://duckduckgo.com/">DuckDuckGo home</a>
        <nav><a href="https://duckduckgo.com/settings">Settings</a></nav>
        <div aria-hidden="true"><h2><a href="https://promo.example/ad">Promo</a></h2></div>
      </header>
      <article><h2><a data-testid="result-title-a" href="https://foofighters.com/tour-dates">Foo Fighters Tour Dates</a></h2></article>
      <a href="https://www.livenation.com/artist/foo"><h3>Foo Fighters - Live Nation</h3></a>
      <li class="b_algo"><h2><a href="https://www.ticketmaster.com/foo">Ticketmaster</a></h2></li>
      <a href="https://foofighters.com/tour-dates"><h3>Duplicate tour link</h3></a>
      <a href="#section"><h3>Hash only</h3></a>
      <p><a href="https://example.com/plain">Plain body link</a></p>
      <p><a data-testid="result-title-a" href="https://www.songkick.com/foo">Songkick</a></p>
      <script>
        document.querySelectorAll('a').forEach(a => a.addEventListener('click', e => {
          e.preventDefault();
          window.clickedHref = a.href;
        }));
      </script>
    </body></html>
    """

    func testSearchResultsReturnsHeadingAnchorsDedupedInDocumentOrderAndClickable() async throws {
        await replaceWithDedicatedFixture(Self.searchResultsFixture)
        let response = try await agent(BrowserAgentPageScript.searchResults, ["maxResults": 5])
        let results = try XCTUnwrap(response["results"] as? [[String: Any]])
        XCTAssertEqual(results.compactMap { $0["url"] as? String }, [
            "foofighters.com/tour-dates",
            "www.livenation.com/artist/foo",
            "www.ticketmaster.com/foo",
            "www.songkick.com/foo"
        ])
        XCTAssertEqual(results.first?["title"] as? String, "Foo Fighters Tour Dates")
        XCTAssertEqual(results[1]["title"] as? String, "Foo Fighters - Live Nation")
        XCTAssertEqual(results[2]["title"] as? String, "Ticketmaster")
        let firstID = try XCTUnwrap(results.first?["id"] as? Int)
        let click = try await agent(BrowserAgentPageScript.click, ["id": firstID, "confirmed": false])
        XCTAssertEqual(click["ok"] as? Bool, true)
        let clickedHref = try await page("window.clickedHref") as? String
        XCTAssertEqual(clickedHref, "https://foofighters.com/tour-dates", "A returned id must click the result anchor itself.")
    }

    func testSearchResultsHonorsMaximumCount() async throws {
        await replaceWithDedicatedFixture(Self.searchResultsFixture)
        let response = try await agent(BrowserAgentPageScript.searchResults, ["maxResults": 2])
        let results = try XCTUnwrap(response["results"] as? [[String: Any]])
        XCTAssertEqual(results.compactMap { $0["url"] as? String }, [
            "foofighters.com/tour-dates",
            "www.livenation.com/artist/foo"
        ])
    }

    func testSearchResultsReRegistratesIDsAfterSnapshotReset() async throws {
        await replaceWithDedicatedFixture(Self.searchResultsFixture)
        let response = try await agent(BrowserAgentPageScript.searchResults, ["maxResults": 5])
        let results = try XCTUnwrap(response["results"] as? [[String: Any]])
        let firstID = try XCTUnwrap(results.first?["id"] as? Int)
        _ = try await agent(BrowserAgentPageScript.snapshot, ["maxElements": 1, "maxText": 500])
        do {
            _ = try await agent(BrowserAgentPageScript.click, ["id": firstID, "confirmed": false])
            XCTFail("A snapshot must evict result ids it did not register.")
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
            XCTAssertTrue(message.contains("no longer on the page"), message)
        }
        _ = try await agent(BrowserAgentPageScript.searchResults, ["maxResults": 5])
        let click = try await agent(BrowserAgentPageScript.click, ["id": firstID, "confirmed": false])
        XCTAssertEqual(click["ok"] as? Bool, true)
        let clickedHref = try await page("window.clickedHref") as? String
        XCTAssertEqual(clickedHref, "https://foofighters.com/tour-dates")
    }
}
