import Foundation
import LocalAuthentication
import Security

/// The browser agent's personal autofill data. It intentionally contains no
/// credentials or payment data and is never Codable into an agent request.
struct AutofillProfile: Equatable {
    var givenName = ""
    var middleName = ""
    var familyName = ""
    var email = ""
    var phone = ""
    var addressLine1 = ""
    var addressLine2 = ""
    var city = ""
    var region = ""
    var postalCode = ""
    var country = ""
    var organization = ""

    enum Field: String, CaseIterable, Identifiable {
        case givenName
        case middleName
        case familyName
        case fullName
        case email
        case phone
        case addressLine1
        case addressLine2
        case city
        case region
        case postalCode
        case country
        case organization

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .givenName: "given name"
            case .middleName: "middle name"
            case .familyName: "family name"
            case .fullName: "full name"
            case .email: "email"
            case .phone: "phone"
            case .addressLine1: "address line 1"
            case .addressLine2: "address line 2"
            case .city: "city"
            case .region: "region"
            case .postalCode: "postal code"
            case .country: "country"
            case .organization: "organization"
            }
        }
    }

    func value(for field: Field) -> String {
        switch field {
        case .givenName: givenName
        case .middleName: middleName
        case .familyName: familyName
        case .fullName:
            [givenName, middleName, familyName]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .email: email
        case .phone: phone
        case .addressLine1: addressLine1
        case .addressLine2: addressLine2
        case .city: city
        case .region: region
        case .postalCode: postalCode
        case .country: country
        case .organization: organization
        }
    }

    func values(for fields: Set<Field>) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.compactMap { field in
            let value = value(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : (field.rawValue, value)
        })
    }

    var isEmpty: Bool {
        Field.allCases.allSatisfy { value(for: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

@MainActor
protocol AutofillProfileStore: AnyObject {
    func load() throws -> AutofillProfile?
    func save(_ profile: AutofillProfile) throws
    func delete() throws
}

@MainActor
protocol AutofillProfileAuthenticator: AnyObject {
    func authenticate(reason: String) async -> Bool
}

@MainActor
protocol AutofillKeychainClient: AnyObject {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ query: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

@MainActor
final class SecurityAutofillKeychainClient: AutofillKeychainClient {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class KeychainAutofillProfileStore: AutofillProfileStore {
    static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.vortyra.browser").autofill-profile"
    }
    static let account = "default-profile-v1"

    private let serviceName: String
    private let accountName: String
    private let keychain: AutofillKeychainClient

    init(
        service: String? = nil,
        account: String? = nil,
        keychain: AutofillKeychainClient? = nil
    ) {
        self.serviceName = service ?? Self.service
        self.accountName = account ?? Self.account
        self.keychain = keychain ?? SecurityAutofillKeychainClient()
    }

    func load() throws -> AutofillProfile? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let profile = try? JSONDecoder().decode(AutofillProfilePayload.self, from: data).profile else {
            throw AutofillProfileError.storageUnavailable
        }
        return profile
    }

    func save(_ profile: AutofillProfile) throws {
        let data: Data
        do { data = try JSONEncoder().encode(AutofillProfilePayload(profile: profile)) }
        catch { throw AutofillProfileError.storageUnavailable }

        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]
        let updateStatus = keychain.update(match, attributes: [kSecValueData as String: data])
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw AutofillProfileError.storageUnavailable }

        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard keychain.add(add) == errSecSuccess else {
            throw AutofillProfileError.storageUnavailable
        }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]
        let status = keychain.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AutofillProfileError.storageUnavailable
        }
    }
}

@MainActor
final class LocalAutofillProfileAuthenticator: AutofillProfileAuthenticator {
    private let contextFactory: @MainActor () -> AutofillAuthenticationContext

    init(contextFactory: (@MainActor () -> AutofillAuthenticationContext)? = nil) {
        self.contextFactory = contextFactory ?? { LocalAuthenticationContext() }
    }

    func authenticate(reason: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        let context = contextFactory()
        guard context.canEvaluateDeviceOwnerAuthentication() else { return false }
        let completion = AutofillAuthenticationCompletion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.install(continuation)
                guard !Task.isCancelled else {
                    context.invalidate()
                    completion.finish(false)
                    return
                }
                context.evaluateDeviceOwnerAuthentication(localizedReason: reason) { success in
                    completion.finish(success)
                }
            }
        } onCancel: {
            completion.finish(false)
            Task { @MainActor in context.invalidate() }
        }
    }
}

@MainActor
protocol AutofillAuthenticationContext: AnyObject {
    func canEvaluateDeviceOwnerAuthentication() -> Bool
    func evaluateDeviceOwnerAuthentication(localizedReason: String, completion: @escaping @Sendable (Bool) -> Void)
    func invalidate()
}

@MainActor
private final class LocalAuthenticationContext: AutofillAuthenticationContext {
    private let context = LAContext()

    func canEvaluateDeviceOwnerAuthentication() -> Bool {
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func evaluateDeviceOwnerAuthentication(localizedReason: String, completion: @escaping @Sendable (Bool) -> Void) {
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: localizedReason) { success, _ in
            completion(success)
        }
    }

    func invalidate() {
        context.invalidate()
    }
}

private nonisolated final class AutofillAuthenticationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(returning: false)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ success: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: success)
    }
}

@MainActor
final class AutofillProfileService {
    static let shared = AutofillProfileService(
        store: KeychainAutofillProfileStore(),
        authenticator: LocalAutofillProfileAuthenticator()
    )

    private let store: AutofillProfileStore
    private let authenticator: AutofillProfileAuthenticator

    init(store: AutofillProfileStore, authenticator: AutofillProfileAuthenticator) {
        self.store = store
        self.authenticator = authenticator
    }

    func loadForEditing() async throws -> AutofillProfile {
        try await authenticate()
        try Task.checkCancellation()
        return try store.load() ?? AutofillProfile()
    }

    func loadForAgentFill() async throws -> AutofillProfile {
        try await authenticate()
        try Task.checkCancellation()
        guard let profile = try store.load(), !profile.isEmpty else {
            throw AutofillProfileError.profileNotConfigured
        }
        return profile
    }

    func save(_ profile: AutofillProfile) async throws {
        try await authenticate()
        try Task.checkCancellation()
        try store.save(profile)
    }

    func delete() async throws {
        try await authenticate()
        try Task.checkCancellation()
        try store.delete()
    }

    private func authenticate() async throws {
        let authenticated = await authenticator.authenticate(reason: "Authenticate to access your autofill profile")
        try Task.checkCancellation()
        guard authenticated else {
            throw AutofillProfileError.authenticationFailed
        }
    }
}

enum AutofillProfileError: LocalizedError, Equatable {
    case authenticationFailed
    case profileNotConfigured
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .authenticationFailed: "Authentication did not succeed. Your profile remains protected."
        case .profileNotConfigured: "Set up an autofill profile in Settings before filling a form."
        case .storageUnavailable: "The autofill profile could not be read or saved securely."
        }
    }
}

private struct AutofillProfilePayload: Codable {
    let givenName: String
    let middleName: String
    let familyName: String
    let email: String
    let phone: String
    let addressLine1: String
    let addressLine2: String
    let city: String
    let region: String
    let postalCode: String
    let country: String
    let organization: String

    init(profile: AutofillProfile) {
        givenName = profile.givenName
        middleName = profile.middleName
        familyName = profile.familyName
        email = profile.email
        phone = profile.phone
        addressLine1 = profile.addressLine1
        addressLine2 = profile.addressLine2
        city = profile.city
        region = profile.region
        postalCode = profile.postalCode
        country = profile.country
        organization = profile.organization
    }

    var profile: AutofillProfile {
        AutofillProfile(
            givenName: givenName, middleName: middleName, familyName: familyName,
            email: email, phone: phone, addressLine1: addressLine1, addressLine2: addressLine2,
            city: city, region: region, postalCode: postalCode, country: country, organization: organization
        )
    }
}
