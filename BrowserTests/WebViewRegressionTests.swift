import XCTest
import WebKit
@testable import Browser

@MainActor
final class WebViewRegressionTests: XCTestCase {
    func testManagedScriptsStayBoundedAndPreserveOtherFeatures() {
        let controller = WKUserContentController()
        let passwordScript = WKUserScript(source: "window.passwordTest = true;", injectionTime: .atDocumentStart,
                                          forMainFrameOnly: true)
        controller.addUserScript(passwordScript)
        ManagedUserScript.install(source: "first", identifier: "ad-block", in: controller)
        let fontScript = WKUserScript(source: "window.fontTest = true;", injectionTime: .atDocumentEnd,
                                      forMainFrameOnly: false)
        controller.addUserScript(fontScript)
        for index in 0..<50 {
            ManagedUserScript.install(source: "config\(index)", identifier: "ad-block", in: controller)
        }
        XCTAssertEqual(controller.userScripts.count, 3)
        XCTAssertTrue(controller.userScripts[0] === passwordScript)
        XCTAssertTrue(controller.userScripts[2] === fontScript)
        XCTAssertTrue(controller.userScripts[1].source.hasSuffix("config49"))
        XCTAssertFalse(ManagedUserScript.install(source: "config49", identifier: "ad-block", in: controller))
    }

    func testCookieCompatibilityDoesNotEnableUntestedOSOrSDK() {
        XCTAssertTrue(NativeCookieRuleCompatibility.supports(majorVersion: 26, osBuild: "old", sdkBuild: nil))
        XCTAssertTrue(NativeCookieRuleCompatibility.supports(
            majorVersion: 27, osBuild: "24A5430a", sdkBuild: "24A5380g"
        ))
        XCTAssertFalse(NativeCookieRuleCompatibility.supports(
            majorVersion: 27, osBuild: "earlier-beta", sdkBuild: "24A5380g"
        ))
        XCTAssertFalse(NativeCookieRuleCompatibility.supports(
            majorVersion: 27, osBuild: "24A5430a", sdkBuild: "untested-sdk"
        ))
        XCTAssertFalse(NativeCookieRuleCompatibility.supports(
            majorVersion: 28, osBuild: "24A5430a", sdkBuild: "24A5380g"
        ))
    }

    func testDarkOverrideIsInstalledBeforeFirstNavigationAndDoesNotAccumulate() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let service = DarkModeService()
        service.configureWebView(webView, enabled: true, hasOverride: true)
        XCTAssertEqual(configuration.userContentController.userScripts.count, 1)
        XCTAssertTrue(configuration.userContentController.userScripts[0].source.contains("const enabled = true;"))
        service.disableDarkMode(for: webView)
        XCTAssertEqual(configuration.userContentController.userScripts.count, 1)
        XCTAssertTrue(configuration.userContentController.userScripts[0].source.contains("const enabled = false;"))
    }
}
