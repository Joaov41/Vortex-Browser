import Foundation
import Security
import XCTest
import WebKit
@testable import Browser

@MainActor
final class AutofillProfileTests: XCTestCase {
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private final class WeakWebsiteDataStoreReference {
        weak var value: WKWebsiteDataStore?

        init(_ value: WKWebsiteDataStore? = nil) {
            self.value = value
        }
    }

    private final class FakeKeychain: AutofillKeychainClient {
        var copyStatus: OSStatus = errSecItemNotFound
        var copiedObject: AnyObject?
        var updateStatus: OSStatus = errSecItemNotFound
        var addStatus: OSStatus = errSecSuccess
        var deleteStatus: OSStatus = errSecSuccess
        var copyQuery: [String: Any]?
        var updateQuery: [String: Any]?
        var updateAttributes: [String: Any]?
        var addQuery: [String: Any]?
        var deleteQuery: [String: Any]?

        func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
            copyQuery = query
            return (copyStatus, copiedObject)
        }

        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            updateQuery = query
            updateAttributes = attributes
            return updateStatus
        }

        func add(_ query: [String: Any]) -> OSStatus {
            addQuery = query
            return addStatus
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            deleteQuery = query
            return deleteStatus
        }
    }

    private final class FakeStore: AutofillProfileStore {
        var profile: AutofillProfile?
        var loadCount = 0
        var saveCount = 0
        var deleteCount = 0

        func load() throws -> AutofillProfile? { loadCount += 1; return profile }
        func save(_ profile: AutofillProfile) throws { saveCount += 1; self.profile = profile }
        func delete() throws { deleteCount += 1; profile = nil }
    }

    private final class FakeAuthenticator: AutofillProfileAuthenticator {
        var allowed = true
        var started = false
        var continuation: CheckedContinuation<Bool, Never>?
        var shouldSuspend = false

        func authenticate(reason: String) async -> Bool {
            started = true
            if shouldSuspend {
                return await withCheckedContinuation { continuation = $0 }
            }
            return allowed
        }

        func resume(_ allowed: Bool = true) {
            continuation?.resume(returning: allowed)
            continuation = nil
        }
    }

    private final class FakeAuthenticationContext: AutofillAuthenticationContext {
        var canEvaluate = true
        var evaluationStarted = false
        var invalidated = false
        var completion: (@Sendable (Bool) -> Void)?

        func canEvaluateDeviceOwnerAuthentication() -> Bool { canEvaluate }

        func evaluateDeviceOwnerAuthentication(localizedReason: String, completion: @escaping @Sendable (Bool) -> Void) {
            evaluationStarted = true
            self.completion = completion
        }

        func invalidate() { invalidated = true }
    }

    func testProfilePayloadStoresExactlyTwelveCanonicalPropertiesAndFullNameIsDerived() throws {
        let profile = AutofillProfile(
            givenName: "Ada", middleName: "Byron", familyName: "Lovelace", email: "ada@example.test",
            phone: "+44 20 0000 0000", addressLine1: "1 St James's Square", addressLine2: "Suite 4",
            city: "London", region: "Greater London", postalCode: "SW1Y 4LB", country: "GB", organization: "Analytical Engine"
        )
        XCTAssertEqual(profile.value(for: .fullName), "Ada Byron Lovelace")
        XCTAssertEqual(profile.values(for: [.fullName, .givenName, .country])["fullName"], "Ada Byron Lovelace")

        let keychain = FakeKeychain()
        keychain.updateStatus = errSecSuccess
        let store = KeychainAutofillProfileStore(service: "test.bundle.autofill-profile", account: "test-profile", keychain: keychain)
        try store.save(profile)
        let data = try XCTUnwrap(keychain.updateAttributes?[kSecValueData as String] as? Data)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), Set([
            "givenName", "middleName", "familyName", "email", "phone", "addressLine1", "addressLine2",
            "city", "region", "postalCode", "country", "organization"
        ]))
        XCTAssertNil(payload["fullName"], "The joined name is derived, not an extra persisted field.")
    }

    func testKeychainUsesNarrowNamespacedQueryAndAddsOnlyWhenMissingWithDeviceOnlyAccessibility() throws {
        let keychain = FakeKeychain()
        let service = "test.bundle.autofill-profile"
        let account = "test-profile"
        let store = KeychainAutofillProfileStore(service: service, account: account, keychain: keychain)
        let profile = AutofillProfile(givenName: "Grace")

        try store.save(profile)
        XCTAssertEqual(keychain.updateQuery?[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(keychain.updateQuery?[kSecAttrService as String] as? String, service)
        XCTAssertEqual(keychain.updateQuery?[kSecAttrAccount as String] as? String, account)
        XCTAssertEqual(Set(keychain.updateQuery?.keys.map { $0 } ?? []), Set([kSecClass as String, kSecAttrService as String, kSecAttrAccount as String]))
        XCTAssertEqual(keychain.addQuery?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(keychain.addQuery?[kSecAttrService as String] as? String, service)
        XCTAssertEqual(keychain.addQuery?[kSecAttrAccount as String] as? String, account)

        let readKeychain = FakeKeychain()
        let encoded = try JSONSerialization.data(withJSONObject: [
            "givenName": "Grace", "middleName": "", "familyName": "", "email": "", "phone": "",
            "addressLine1": "", "addressLine2": "", "city": "", "region": "", "postalCode": "",
            "country": "", "organization": ""
        ])
        readKeychain.copyStatus = errSecSuccess
        readKeychain.copiedObject = encoded as NSData
        let readStore = KeychainAutofillProfileStore(service: service, account: account, keychain: readKeychain)
        XCTAssertEqual(try readStore.load()?.givenName, "Grace")
        XCTAssertEqual(Set(readKeychain.copyQuery?.keys.map { $0 } ?? []), Set([
            kSecClass as String, kSecAttrService as String, kSecAttrAccount as String,
            kSecReturnData as String, kSecMatchLimit as String
        ]))
        XCTAssertEqual(readKeychain.copyQuery?[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)

        try store.delete()
        XCTAssertEqual(Set(keychain.deleteQuery?.keys.map { $0 } ?? []), Set([kSecClass as String, kSecAttrService as String, kSecAttrAccount as String]))
        XCTAssertEqual(keychain.deleteQuery?[kSecAttrService as String] as? String, service)
    }

    func testKeychainUpdateDoesNotAddAndNonNotFoundFailuresFailClosed() throws {
        let updateKeychain = FakeKeychain()
        updateKeychain.updateStatus = errSecSuccess
        let updateStore = KeychainAutofillProfileStore(service: "test", account: "profile", keychain: updateKeychain)
        try updateStore.save(AutofillProfile(email: "a@example.test"))
        XCTAssertNil(updateKeychain.addQuery, "An existing profile is updated in place.")

        let failureKeychain = FakeKeychain()
        failureKeychain.updateStatus = errSecAuthFailed
        let failureStore = KeychainAutofillProfileStore(service: "test", account: "profile", keychain: failureKeychain)
        XCTAssertThrowsError(try failureStore.save(AutofillProfile(email: "a@example.test")))
        XCTAssertNil(failureKeychain.addQuery, "Only errSecItemNotFound permits the insert path.")

        let insertFailure = FakeKeychain()
        insertFailure.updateStatus = errSecItemNotFound
        insertFailure.addStatus = errSecDuplicateItem
        let insertFailureStore = KeychainAutofillProfileStore(service: "test", account: "profile", keychain: insertFailure)
        XCTAssertThrowsError(try insertFailureStore.save(AutofillProfile(email: "a@example.test")))

        let readMissing = FakeKeychain()
        let missingStore = KeychainAutofillProfileStore(service: "test", account: "profile", keychain: readMissing)
        XCTAssertNil(try missingStore.load())

        let corruptRead = FakeKeychain()
        corruptRead.copyStatus = errSecSuccess
        corruptRead.copiedObject = Data("not-json".utf8) as NSData
        let corruptStore = KeychainAutofillProfileStore(service: "test", account: "profile", keychain: corruptRead)
        XCTAssertThrowsError(try corruptStore.load())

        let failedRead = FakeKeychain()
        failedRead.copyStatus = errSecAuthFailed
        let failedReadStore = KeychainAutofillProfileStore(service: "test", account: "profile", keychain: failedRead)
        XCTAssertThrowsError(try failedReadStore.load())

        let failedDelete = FakeKeychain()
        failedDelete.deleteStatus = errSecAuthFailed
        let failedDeleteStore = KeychainAutofillProfileStore(service: "test", account: "profile", keychain: failedDelete)
        XCTAssertThrowsError(try failedDeleteStore.delete())

        let missingDelete = FakeKeychain()
        missingDelete.deleteStatus = errSecItemNotFound
        let missingDeleteStore = KeychainAutofillProfileStore(service: "test", account: "profile", keychain: missingDelete)
        XCTAssertNoThrow(try missingDeleteStore.delete())
    }

    func testAuthenticationFailureAndCancellationNeverReachStore() async throws {
        let store = FakeStore()
        let denied = FakeAuthenticator()
        denied.allowed = false
        let deniedService = AutofillProfileService(store: store, authenticator: denied)
        do {
            try await deniedService.save(AutofillProfile(email: "a@example.test"))
            XCTFail("A denied authentication must fail closed.")
        } catch {
            XCTAssertEqual(error as? AutofillProfileError, .authenticationFailed)
        }
        do {
            _ = try await deniedService.loadForEditing()
            XCTFail("A denied authentication must not reveal the saved profile.")
        } catch {
            XCTAssertEqual(error as? AutofillProfileError, .authenticationFailed)
        }
        do {
            try await deniedService.delete()
            XCTFail("A denied authentication must not delete the saved profile.")
        } catch {
            XCTAssertEqual(error as? AutofillProfileError, .authenticationFailed)
        }
        XCTAssertEqual(store.loadCount, 0)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(store.deleteCount, 0)

        let delayed = FakeAuthenticator()
        delayed.shouldSuspend = true
        let cancelledService = AutofillProfileService(store: store, authenticator: delayed)
        let operation = Task { @MainActor in
            try await cancelledService.save(AutofillProfile(email: "a@example.test"))
        }
        for _ in 0..<100 where !delayed.started { await Task.yield() }
        XCTAssertTrue(delayed.started)
        operation.cancel()
        delayed.resume()
        do {
            try await operation.value
            XCTFail("Cancellation after authentication must prevent the Keychain write.")
        } catch is CancellationError {
            // Expected: cancellation is checked after authentication and before store access.
        }
        XCTAssertEqual(store.saveCount, 0)
    }

    func testLocalAuthenticationCancellationInvalidatesOnlyItsActiveContext() async throws {
        let context = FakeAuthenticationContext()
        let authenticator = LocalAutofillProfileAuthenticator(contextFactory: { context })
        let task = Task { @MainActor in
            await authenticator.authenticate(reason: "Synthetic cancellation fixture")
        }
        for _ in 0..<100 where !context.evaluationStarted { await Task.yield() }
        XCTAssertTrue(context.evaluationStarted, "The test uses an injected context and never presents real authentication UI.")
        task.cancel()
        let authenticationResult = await task.value
        XCTAssertFalse(authenticationResult)
        for _ in 0..<100 where !context.invalidated { await Task.yield() }
        XCTAssertTrue(context.invalidated, "Cancellation must invalidate the per-call biometric/passcode prompt.")
        context.completion?(true)
        XCTAssertFalse(authenticationResult, "A late success callback cannot override the one-shot cancellation result.")
    }

    func testFilledTabQuarantineRedactsNavigationEchoAndRejectsStaleReconciliation() async throws {
        let waiter = NavigationWaiter()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        webView.navigationDelegate = waiter
        let url = try XCTUnwrap(URL(string: "https://profile-privacy.test/account"))
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString("<main>Privacy fixture</main>", baseURL: url)
        }

        let privacy = BrowserAgentAutofillPrivacy()
        let tabID = UUID()
        let firstRun = UUID()
        _ = privacy.quarantineBeforeFill(
            tabID: tabID, webView: webView, runID: firstRun, pageURL: webView.url,
            documentNonce: "document-before-first-fill",
            profileValues: ["fullName": "Ada Lovelace", "email": "ada@example.test"]
        )
        XCTAssertTrue(privacy.isQuarantined(tabID: tabID))
        XCTAssertFalse(privacy.allowsScreenshot(tabID: tabID))
        XCTAssertNil(privacy.modelText("Title: Account", tabID: tabID), "The filled document stays quarantined until a new nonce is verified.")
        let cleanTabID = UUID()
        let crossTabMetadata = try XCTUnwrap(privacy.modelText(
            "History title: Ada Lovelace; URL query=name=Ada%20Lovelace",
            tabID: cleanTabID
        ))
        XCTAssertFalse(crossTabMetadata.contains("Ada Lovelace"), "Clean tabs' combined metadata still redacts a value known from a filled tab.")
        XCTAssertFalse(crossTabMetadata.contains("Ada%20Lovelace"))

        let staleRun = privacy.reconciliation(for: tabID, webView: webView, navigationURL: url)
        let secondRun = UUID()
        _ = privacy.quarantineBeforeFill(
            tabID: tabID, webView: webView, runID: secondRun, pageURL: webView.url,
            documentNonce: "document-after-first-fill",
            profileValues: ["fullName": "Grace Hopper", "email": "grace@example.test"]
        )
        let staleReleased = privacy.releaseAfterVerifiedNavigation(
            try XCTUnwrap(staleRun), tabID: tabID, webView: webView, currentURL: url,
            documentNonce: "document-after-navigation"
        )
        XCTAssertFalse(staleReleased, "A delayed callback from the prior fill cannot release the newer fill's quarantine.")
        XCTAssertNil(privacy.modelText("Page echo", tabID: tabID))

        let currentReconciliation = try XCTUnwrap(privacy.reconciliation(
            for: tabID, webView: webView, navigationURL: url
        ))
        let wrongURL = URL(string: "https://profile-privacy.test/other")!
        XCTAssertFalse(privacy.releaseAfterVerifiedNavigation(
            currentReconciliation, tabID: tabID, webView: webView, currentURL: wrongURL,
            documentNonce: "new-document"
        ), "URL must be rechecked after reading a replacement document nonce.")
        XCTAssertTrue(privacy.releaseAfterVerifiedNavigation(
            currentReconciliation, tabID: tabID, webView: webView, currentURL: url,
            documentNonce: "new-document-same-url"
        ), "A verified new document may have the same URL.")

        let echoed = try XCTUnwrap(privacy.modelText(
            "Title: Grace Hopper; query=grace%40example.test; form=Grace+Hopper",
            tabID: tabID
        ))
        XCTAssertFalse(echoed.localizedCaseInsensitiveContains("Grace Hopper"))
        XCTAssertFalse(echoed.localizedCaseInsensitiveContains("grace%40example.test"))
        XCTAssertFalse(echoed.localizedCaseInsensitiveContains("Grace+Hopper"))
        XCTAssertTrue(echoed.contains("[profile data redacted]"))
        XCTAssertFalse(privacy.allowsScreenshot(tabID: tabID), "A filled WebView stays screenshot restricted after navigation.")

        privacy.retainTabs([])
        XCTAssertFalse(privacy.hasRecord(tabID: tabID), "Closing the source tab drops its in-memory profile redaction record.")
        XCTAssertTrue(privacy.redactKnownValues("A closed-tab history entry echoed Ada Lovelace").contains("[profile data redacted]"),
            "The process-local redaction ledger remains after a tab closes because its title or history may persist.")
    }

    func testPrivacyRegistryReleasesStoppedFillAfterCurrentTabReplacementCommitsNewNonce() async throws {
        let url = try XCTUnwrap(URL(string: "https://profile-privacy.test/replace"))
        let original = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        await load("<main>Original page</main>", in: original, at: url)
        let originalNonce = try await documentNonce(in: original)

        let privacy = BrowserAgentAutofillPrivacy()
        let tabID = UUID()
        _ = privacy.quarantineBeforeFill(
            tabID: tabID,
            webView: original,
            runID: UUID(),
            pageURL: original.url,
            documentNonce: originalNonce,
            profileValues: ["givenName": "Synthetic Given Name", "fullName": "Synthetic Given Name Example"]
        )

        // A hibernated tab may acquire a replacement WKWebView after the agent
        // run has stopped. Ownership plus the committed document nonce, not a
        // controller generation or same URL alone, releases the old record.
        let replacement = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        await load("<main>New document after stop</main>", in: replacement, at: url)
        let replacementNonce = try await documentNonce(in: replacement)
        XCTAssertNotEqual(originalNonce, replacementNonce)
        let currentTabWebView: WKWebView? = replacement
        privacy.reconcileNavigation(
            tabID: tabID,
            webView: replacement,
            navigationURL: url
        ) { currentTabWebView === replacement }
        let released = await waitUntil { !privacy.isQuarantined(tabID: tabID) }
        XCTAssertTrue(released, "The registry should release after it verifies the replacement WebView's new nonce.")
        XCTAssertFalse(privacy.allowsScreenshot(tabID: tabID), "Screenshot blocking remains for the filled tab after navigation.")
        XCTAssertTrue(privacy.redactKnownValues("New page echoed Synthetic Given Name").contains("[profile data redacted]"))

        _ = privacy.quarantineBeforeFill(
            tabID: tabID,
            webView: replacement,
            runID: UUID(),
            pageURL: url,
            documentNonce: replacementNonce,
            profileValues: ["givenName": "Second Synthetic Name"]
        )
        privacy.reconcileNavigation(
            tabID: tabID,
            webView: original,
            navigationURL: url
        ) { currentTabWebView === original }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(privacy.isQuarantined(tabID: tabID), "A delayed callback from the older WebView cannot release a newer fill.")
    }

    func testRedactionRunsBeforeUTF8BoundingSoAProfilePrefixCannotEscape() {
        let privacy = BrowserAgentAutofillPrivacy()
        let tabID = UUID()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        let value = "é" + String(repeating: "ProfileValue", count: 12)
        _ = privacy.quarantineBeforeFill(
            tabID: tabID,
            webView: webView,
            runID: UUID(),
            pageURL: URL(string: "https://profile-privacy.test/"),
            documentNonce: "privacy-redaction-boundary",
            profileValues: ["givenName": value]
        )
        let raw = "Header " + value + " trailing text"
        let clippedRaw = BrowserAgentLocalContext.boundedUTF8(raw, to: 24)
        let safe = privacy.redactThenBound(raw) { BrowserAgentLocalContext.boundedUTF8($0, to: 24) }
        XCTAssertTrue(clippedRaw.contains("éProfile"), "The fixture cap should split a profile value when clipping happens first.")
        XCTAssertFalse(safe.contains("éProfile"), "A UTF-8 cap must not leave a partial configured profile value.")
    }

    func testKnownValueRedactionCoversJSONEscapesAndLowercasePercentEscapes() throws {
        let privacy = BrowserAgentAutofillPrivacy()
        let value = "A+B \"Road\""
        _ = privacy.quarantineBeforeFill(
            tabID: UUID(),
            webView: WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1)),
            runID: UUID(),
            pageURL: URL(string: "https://profile-privacy.test/"),
            documentNonce: "encoded-redaction-fixture",
            profileValues: ["addressLine1": value]
        )
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["title": value]), as: UTF8.self)
        let protectedJSON = privacy.redactThenBound(json) {
            BrowserAgentLocalContext.boundedUTF8($0, to: 256)
        }
        XCTAssertFalse(protectedJSON.contains("A+B"))
        XCTAssertFalse(protectedJSON.contains("\\\"Road\\\""), "JSON string escaping must be included in the new privacy codec.")
        XCTAssertEqual(protectedJSON, "{\"title\":\"[profile data redacted]\"}", "Encoded model output must not retain any fragment of the configured address.")

        let encoded = "A%2bB%20%22Road%22"
        let protectedURL = privacy.redactThenBound("https://example.test/?address=\(encoded)") {
            BrowserAgentLocalContext.boundedUTF8($0, to: 256)
        }
        XCTAssertFalse(protectedURL.contains(encoded), "Lowercase percent hex digits must be redacted before URL clipping.")
        XCTAssertEqual(protectedURL, "https://example.test/?address=[profile data redacted]")
    }

    func testModelEgressRequiresCapturedTabWebViewAndURLAndBlocksFilledPage() {
        let privacy = BrowserAgentAutofillPrivacy()
        let tabID = UUID()
        let url = URL(string: "https://egress.fixture/page#old-fragment")!
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        let binding = BrowserAgentPageContextBinding(tabID: tabID, webView: webView, url: url)
        let samePage = BrowserAgentPageContextBinding(
            tabID: tabID,
            webView: webView,
            url: URL(string: "https://egress.fixture/page#new-fragment")!
        )
        XCTAssertEqual(
            BrowserAgentModelEgress.evaluate("public page text", captured: binding, current: samePage, privacy: privacy),
            .allowed("public page text"),
            "Fragments do not create a different source page binding."
        )

        let replacement = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        let replacementBinding = BrowserAgentPageContextBinding(tabID: tabID, webView: replacement, url: url)
        XCTAssertEqual(
            BrowserAgentModelEgress.evaluate("old extraction", captured: binding, current: replacementBinding, privacy: privacy),
            .blocked,
            "A same-URL WebView replacement cannot dispatch an old extraction."
        )
        let nextURLBinding = BrowserAgentPageContextBinding(
            tabID: tabID,
            webView: webView,
            url: URL(string: "https://egress.fixture/next")!
        )
        XCTAssertEqual(
            BrowserAgentModelEgress.evaluate("old extraction", captured: binding, current: nextURLBinding, privacy: privacy),
            .blocked,
            "Navigation invalidates content captured from the prior URL."
        )

        _ = privacy.quarantineBeforeFill(
            tabID: tabID,
            webView: webView,
            runID: UUID(),
            pageURL: url,
            documentNonce: "egress-private-document",
            profileValues: ["email": "profile-echo@example.test"]
        )
        XCTAssertEqual(
            BrowserAgentModelEgress.evaluate("profile-echo@example.test", captured: binding, current: binding, privacy: privacy),
            .blocked,
            "A filled source stays blocked even when the captured binding still matches exactly."
        )
        let capturedPageOutputs = [
            "read_page callback body",
            "selected text callback",
            "cached extraction",
            "stored source context",
            "delayed extraction completion"
        ]
        for output in capturedPageOutputs {
            XCTAssertEqual(
                BrowserAgentModelEgress.evaluate(output, captured: binding, current: binding, privacy: privacy),
                .blocked,
                "Page-derived dispatch output must remain blocked after fill: \(output)"
            )
        }
        XCTAssertFalse(privacy.allowsScreenshot(tabID: tabID), "A tainted page cannot pass the screenshot dispatch gate.")
        XCTAssertEqual(
            BrowserAgentModelEgress.evaluate("title=profile-echo@example.test", captured: nil, current: nil, privacy: privacy),
            .allowed("title=[profile data redacted]"),
            "Combined metadata without a single source binding still uses the process-local value ledger."
        )
    }

    func testModelEgressFallbackRedactsQueuedContentAcrossWindows() {
        let privacy = BrowserAgentAutofillPrivacy()
        let otherWindowPrivacy = BrowserAgentAutofillPrivacy()
        let queuedBeforeFill = "Summarize the account page containing ada@example.test and Ada Lovelace."
        let installedWindowRedactor: (String) -> String = { text in
            otherWindowPrivacy.redactPotentiallyTruncated(text, wasTruncated: true)
        }
        let noWindowRedactor: ((String) -> String)? = nil

        XCTAssertEqual(
            SimpleAIModelEgress.prepare(
                queuedBeforeFill,
                installedRedactor: noWindowRedactor,
                privacy: privacy
            ),
            queuedBeforeFill,
            "Before a native fill, the shared fallback preserves the existing service payload."
        )

        _ = privacy.quarantineBeforeFill(
            tabID: UUID(),
            webView: WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1)),
            runID: UUID(),
            pageURL: URL(string: "https://egress.fixture/account"),
            documentNonce: "service-egress-fill",
            profileValues: ["email": "ada@example.test", "fullName": "Ada Lovelace"]
        )

        // Model two independently owned window services: the first installed
        // a callback backed by another window's empty ledger; the second has
        // no callback. Both prepare only when dequeued after the shared native
        // ledger learned the filled values.
        let firstWindowPayload = SimpleAIModelEgress.prepare(
            queuedBeforeFill,
            installedRedactor: installedWindowRedactor,
            privacy: privacy
        )
        let secondWindowPayload = SimpleAIModelEgress.prepare(
            queuedBeforeFill,
            installedRedactor: noWindowRedactor,
            privacy: privacy
        )
        for payload in [firstWindowPayload, secondWindowPayload] {
            XCTAssertTrue(payload.contains("[profile data redacted]"))
            XCTAssertFalse(payload.contains("ada@example.test"))
            XCTAssertFalse(payload.contains("Ada Lovelace"))
        }
    }

    func testProtectedFetchOriginDoesNotExtendEphemeralStoreLifetime() throws {
        let privacy = BrowserAgentAutofillPrivacy()
        let tabID = UUID()
        let originURL = try XCTUnwrap(URL(string: "https://ephemeral-origin.fixture/account"))
        let ledgerStore = WeakWebsiteDataStoreReference()
        let controlStore = WeakWebsiteDataStoreReference()
        autoreleasepool {
            let store = WKWebsiteDataStore.nonPersistent()
            ledgerStore.value = store
            let sourceWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            privacy.quarantineBeforeFill(
                tabID: tabID,
                webView: sourceWebView,
                runID: UUID(),
                pageURL: originURL,
                documentNonce: "ephemeral-store-fill",
                profileValues: ["email": "ephemeral@example.test"],
                websiteDataStore: store
            )

            XCTAssertTrue(privacy.blocksBackgroundFetch(url: originURL, startingDataStore: store))
            XCTAssertTrue(ledgerStore.value === store)
            privacy.retainTabs([])
            XCTAssertTrue(
                privacy.blocksBackgroundFetch(url: originURL, startingDataStore: store),
                "Closing the filled tab must preserve origin protection while its exact store is still alive."
            )
            let independentStore = WKWebsiteDataStore.nonPersistent()
            XCTAssertFalse(
                privacy.blocksBackgroundFetch(url: originURL, startingDataStore: independentStore),
                "An independent incognito store must not inherit the first store's origin restriction."
            )
        }

        autoreleasepool {
            let store = WKWebsiteDataStore.nonPersistent()
            controlStore.value = store
            XCTAssertTrue(controlStore.value === store)
        }
        XCTAssertEqual(
            ledgerStore.value == nil,
            controlStore.value == nil,
            "The ledger must not extend store lifetime beyond WebKit's own no-ledger baseline."
        )
        if controlStore.value == nil {
            XCTAssertNil(ledgerStore.value)
        }
        let independentStore = WKWebsiteDataStore.nonPersistent()
        XCTAssertFalse(
            privacy.blocksBackgroundFetch(url: originURL, startingDataStore: independentStore),
            "An independent incognito store must not inherit the first store's origin restriction."
        )
        let replacementStore = WKWebsiteDataStore.nonPersistent()
        XCTAssertFalse(
            privacy.blocksBackgroundFetch(url: originURL, startingDataStore: replacementStore),
            "A later store with a potentially reused object identifier cannot inherit a stale weak record."
        )
    }

    private func documentNonce(in webView: WKWebView) async throws -> String {
        let value = try await webView.callAsyncJavaScript(
            BrowserAgentPageScript.documentIdentity,
            arguments: [:],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let json = try XCTUnwrap(value as? String)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["nonce"] as? String)
    }

    private func load(_ html: String, in webView: WKWebView, at url: URL) async {
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: url)
        }
        webView.navigationDelegate = nil
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
