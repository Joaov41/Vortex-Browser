import XCTest
@testable import Browser

@MainActor
final class AgentTrustStoreTests: XCTestCase {
    private func makeStore() throws -> (AgentTrustStore, UserDefaults, String) {
        let suite = "AgentTrustStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let key = "permissions"
        return (AgentTrustStore(defaults: defaults, storageKey: key), defaults, key)
    }

    func testRememberedPermissionMatchesOnlyCanonicalExactHostAndReason() throws {
        let (store, _, _) = try makeStore()
        XCTAssertTrue(store.allow(host: "Example.COM.", reason: " Post ", operation: "click", protectedContext: false, isPrivate: false))

        XCTAssertTrue(store.allows(host: "example.com", reason: "post", operation: "click", protectedContext: false, isPrivate: false))
        XCTAssertFalse(store.allows(host: "www.example.com", reason: "post", operation: "click", protectedContext: false, isPrivate: false))
        XCTAssertFalse(store.allows(host: "shop.example.com", reason: "post", operation: "click", protectedContext: false, isPrivate: false))
        XCTAssertFalse(store.allows(host: "example.com", reason: "publish", operation: "click", protectedContext: false, isPrivate: false))
    }

    func testProtectedAndHighImpactContextsCannotBeRemembered() throws {
        let (store, _, _) = try makeStore()
        for reason in ["sign-in form", "form with sensitive fields", "buy", "purchase", "payment", "checkout", "delete", "remove", "transfer", "downloads"] {
            XCTAssertFalse(store.allow(host: "example.com", reason: reason, operation: "click", protectedContext: false, isPrivate: false), reason)
        }
        XCTAssertFalse(store.allow(host: "example.com", reason: "post", operation: "click", protectedContext: true, isPrivate: false))
        XCTAssertFalse(store.allow(host: "example.com", reason: "post", operation: "fill_form", protectedContext: false, isPrivate: false))
        XCTAssertFalse(store.allow(host: "example.com", reason: "post", operation: "close_tab", protectedContext: false, isPrivate: false))
        XCTAssertTrue(store.permissions.isEmpty)
    }

    func testHideElementSiteTrustStaysExactHostAndPrivacyScoped() throws {
        let (store, _, _) = try makeStore()
        XCTAssertTrue(AgentTrustStore.isAlwaysAllowEligible(
            reason: "hide page element",
            operation: "hide_element",
            protectedContext: false,
            isPrivate: false
        ))
        XCTAssertFalse(AgentTrustStore.isAlwaysAllowEligible(
            reason: "hide page element",
            operation: "hide_element",
            protectedContext: true,
            isPrivate: false
        ))
        XCTAssertFalse(AgentTrustStore.isAlwaysAllowEligible(
            reason: "hide page element",
            operation: "hide_element",
            protectedContext: false,
            isPrivate: true
        ))
        for operation in ["close_tab", "fill_form", "download_url", "download_link", "purchase", "delete"] {
            XCTAssertFalse(AgentTrustStore.isAlwaysAllowEligible(
                reason: "hide page element",
                operation: operation,
                protectedContext: false,
                isPrivate: false
            ), operation)
        }

        XCTAssertTrue(store.allow(
            host: "Example.COM.",
            reason: "hide page element",
            operation: "hide_element",
            protectedContext: false,
            isPrivate: false
        ))
        XCTAssertTrue(store.allows(
            host: "example.com",
            reason: "hide page element",
            operation: "hide_element",
            protectedContext: false,
            isPrivate: false
        ))
        for lookalike in ["www.example.com", "example.com.evil.test", "notexample.com", "example2.com"] {
            XCTAssertFalse(store.allows(
                host: lookalike,
                reason: "hide page element",
                operation: "hide_element",
                protectedContext: false,
                isPrivate: false
            ), lookalike)
        }
        XCTAssertFalse(store.allows(
            host: "example.com",
            reason: "hide page element",
            operation: "hide_element",
            protectedContext: false,
            isPrivate: true
        ), "Private runs never read remembered permissions.")
    }

    func testPrivateModeNeverReadsOrWritesRememberedPermissionsAndRevokePersists() throws {
        let (store, defaults, key) = try makeStore()
        XCTAssertTrue(store.allow(host: "example.com", reason: "post", operation: "click", protectedContext: false, isPrivate: false))
        let beforePrivateCheck = defaults.data(forKey: key)

        XCTAssertFalse(store.allows(host: "example.com", reason: "post", operation: "click", protectedContext: false, isPrivate: true))
        XCTAssertFalse(store.allow(host: "private.example", reason: "post", operation: "click", protectedContext: false, isPrivate: true))
        XCTAssertEqual(defaults.data(forKey: key), beforePrivateCheck)

        let permission = try XCTUnwrap(store.permissions.first)
        store.revoke(permission)
        XCTAssertFalse(store.allows(host: "example.com", reason: "post", operation: "click", protectedContext: false, isPrivate: false))
        XCTAssertTrue(AgentTrustStore(defaults: defaults, storageKey: key).permissions.isEmpty)
    }
}
