import XCTest
@testable import Browser

final class ChatGPTPlanAvailabilityTests: XCTestCase {
    func testDistributionSignedTestFlightEnablesChatGPTWithoutDevelopmentProfile() {
        let receipt = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/test/StoreKit/sandboxReceipt")
        XCTAssertTrue(ChatGPTPlanAvailability.supportsIOSInstall(allowsDebugging: false, receiptURL: receipt))
    }

    func testPublicAppStoreInstallKeepsExistingRestriction() {
        XCTAssertFalse(ChatGPTPlanAvailability.supportsIOSInstall(
            allowsDebugging: false, receiptURL: URL(fileURLWithPath: "/StoreKit/receipt")
        ))
    }

    func testDevelopmentInstallStillWorksWithoutReceipt() {
        XCTAssertTrue(ChatGPTPlanAvailability.supportsIOSInstall(allowsDebugging: true, receiptURL: nil))
    }

    func testUnknownDistributionInstallDoesNotEnableChatGPT() {
        XCTAssertFalse(ChatGPTPlanAvailability.supportsIOSInstall(allowsDebugging: false, receiptURL: nil))
    }
}
