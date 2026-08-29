import Foundation
import XCTest
@testable import Browser

@MainActor
final class BrowserDownloadTests: XCTestCase {
    func testOrdinaryNavigationRemainsAllowed() {
        XCTAssertEqual(
            BrowserDownloadPolicy.navigationActionDecision(
                shouldPerformDownload: false,
                scheme: "https",
                isIncognito: false
            ),
            .allow
        )
        XCTAssertEqual(
            BrowserDownloadPolicy.navigationResponseDecision(
                canShowMIMEType: true,
                contentDisposition: nil,
                scheme: "https",
                isIncognito: false
            ),
            .allow
        )
    }

    func testShouldPerformDownloadSelectsDownloadBeforeNavigationHandling() {
        XCTAssertEqual(
            BrowserDownloadPolicy.navigationActionDecision(
                shouldPerformDownload: true,
                scheme: "https",
                isIncognito: false
            ),
            .download
        )
    }

    func testAttachmentResponseIsCaseInsensitiveAndSupportsParameters() {
        let headers: [AnyHashable: Any] = [
            "cOnTeNt-DiSpOsItIoN": " AtTaChMeNt ; filename=\"report.pdf\""
        ]
        let value = BrowserDownloadPolicy.contentDispositionHeader(from: headers)

        XCTAssertEqual(value, " AtTaChMeNt ; filename=\"report.pdf\"")
        XCTAssertTrue(BrowserDownloadPolicy.contentDispositionIndicatesAttachment(value))
        XCTAssertEqual(
            BrowserDownloadPolicy.navigationResponseDecision(
                canShowMIMEType: true,
                contentDisposition: value,
                scheme: "https",
                isIncognito: false
            ),
            .download
        )
    }

    func testUnsupportedMIMETypeSelectsDownload() {
        XCTAssertEqual(
            BrowserDownloadPolicy.navigationResponseDecision(
                canShowMIMEType: false,
                contentDisposition: nil,
                scheme: "https",
                isIncognito: false
            ),
            .download
        )
    }

    func testDisplayableHTMLImageAndPDFRemainNormalWithoutAttachment() {
        for mimeType in ["text/html", "image/png", "application/pdf"] {
            XCTAssertEqual(
                BrowserDownloadPolicy.navigationResponseDecision(
                    canShowMIMEType: true,
                    contentDisposition: nil,
                    scheme: "https",
                    isIncognito: false
                ),
                .allow,
                "Expected displayable \(mimeType) response to remain normal navigation"
            )
        }
    }

    func testIncognitoAllowsOnlyHTTPHTTPSAndBlobActualDownloads() {
        for scheme in ["http", "https", "HTTP", "blob"] {
            XCTAssertEqual(
                BrowserDownloadPolicy.navigationActionDecision(
                    shouldPerformDownload: true,
                    scheme: scheme,
                    isIncognito: true
                ),
                .download
            )
            XCTAssertEqual(
                BrowserDownloadPolicy.navigationResponseDecision(
                    canShowMIMEType: false,
                    contentDisposition: nil,
                    scheme: scheme,
                    isIncognito: true
                ),
                .download
            )
        }

        for scheme in ["data", "file", "custom", "app", ""] {
            XCTAssertEqual(
                BrowserDownloadPolicy.navigationActionDecision(
                    shouldPerformDownload: true,
                    scheme: scheme,
                    isIncognito: true
                ),
                .cancel
            )
            XCTAssertEqual(
                BrowserDownloadPolicy.navigationResponseDecision(
                    canShowMIMEType: false,
                    contentDisposition: "attachment; filename=file.bin",
                    scheme: scheme,
                    isIncognito: true
                ),
                .cancel
            )
        }
    }

    func testFilenameSanitizationRemovesTraversalAndControlCharacters() {
        let sanitized = BrowserDownloadManager.sanitizeFilename("../../private/\u{0000}report\n.pdf")
        XCTAssertEqual(sanitized, "report.pdf")
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertFalse(sanitized.contains("\\"))
        XCTAssertFalse(sanitized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        XCTAssertEqual(BrowserDownloadManager.sanitizeFilename("."), "download")
        XCTAssertEqual(BrowserDownloadManager.sanitizeFilename(".."), "download")
        XCTAssertEqual(BrowserDownloadManager.sanitizeFilename(nil), "download")
    }

    func testFilenameLengthCapPreservesExtension() {
        let longName = String(repeating: "a", count: 400) + ".pdf"
        let sanitized = BrowserDownloadManager.sanitizeFilename(longName)

        XCTAssertLessThanOrEqual(sanitized.count, 180)
        XCTAssertTrue(sanitized.hasSuffix(".pdf"))
    }

    func testDuplicateDestinationNeverOverwritesAndKeepsExtension() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        let manager = BrowserDownloadManager(temporaryDirectory: fixture.baseURL)

        let first = manager.uniqueDestinationURL(for: "report.pdf")
        try Data([1]).write(to: first)
        let second = manager.uniqueDestinationURL(for: "report.pdf")
        try Data([2]).write(to: second)
        let third = manager.uniqueDestinationURL(for: "report.pdf")

        XCTAssertEqual(first.lastPathComponent, "report.pdf")
        XCTAssertEqual(second.lastPathComponent, "report (2).pdf")
        XCTAssertEqual(third.lastPathComponent, "report (3).pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: third.path))
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
    }

    func testReservedDestinationsAvoidCollisionBeforeEitherFileExists() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        let manager = BrowserDownloadManager(temporaryDirectory: fixture.baseURL)

        let first = manager.uniqueDestinationURL(for: "report.pdf")
        let second = manager.uniqueDestinationURL(for: "report.pdf")

        XCTAssertEqual(first.lastPathComponent, "report.pdf")
        XCTAssertEqual(second.lastPathComponent, "report (2).pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testCompletedExportQueuePreservesOrderingAndCleansTemporaryFiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        let manager = BrowserDownloadManager(temporaryDirectory: fixture.baseURL)
        let firstURL = manager.sessionDirectoryURL.appendingPathComponent("first.txt")
        let secondURL = manager.sessionDirectoryURL.appendingPathComponent("second.txt")
        try Data([1]).write(to: firstURL)
        try Data([2]).write(to: secondURL)

        let firstID = try XCTUnwrap(
            manager.enqueueCompletedFile(at: firstURL, suggestedFilename: "first.txt")
        )
        let secondID = try XCTUnwrap(
            manager.enqueueCompletedFile(at: secondURL, suggestedFilename: "second.txt")
        )

        XCTAssertEqual(manager.presentedExport?.id, firstID)
        manager.finishExport(id: firstID, exported: true)
        XCTAssertEqual(manager.presentedExport?.id, secondID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))

        manager.finishExport(id: secondID, exported: false)
        XCTAssertNil(manager.presentedExport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertEqual(manager.items.first(where: { $0.id == firstID })?.state, .completed)
        XCTAssertEqual(manager.items.first(where: { $0.id == secondID })?.state, .cancelled)
    }

    func testInitializationCleansOnlyAbandonedDedicatedDownloadDirectories() throws {
        let fixtureBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDownloadCleanup.\(UUID().uuidString)", isDirectory: true)
        let root = fixtureBase.appendingPathComponent(BrowserDownloadManager.downloadRootComponent, isDirectory: true)
        let abandoned = root.appendingPathComponent("old-session", isDirectory: true)
        let outside = fixtureBase.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data([7]).write(to: abandoned.appendingPathComponent("stale.bin"))
        try Data([8]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: fixtureBase) }

        let manager = BrowserDownloadManager(temporaryDirectory: fixtureBase)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.sessionDirectoryURL.path))
    }

    func testSecondManagerPreservesFirstManagersActiveSessionDirectory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        let firstManager = BrowserDownloadManager(temporaryDirectory: fixture.baseURL)
        let inProgressFile = firstManager.sessionDirectoryURL.appendingPathComponent("in-progress.bin")
        try Data([9]).write(to: inProgressFile)

        let secondManager = BrowserDownloadManager(temporaryDirectory: fixture.baseURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstManager.sessionDirectoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inProgressFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondManager.sessionDirectoryURL.path))
        XCTAssertNotEqual(
            firstManager.sessionDirectoryURL.standardizedFileURL,
            secondManager.sessionDirectoryURL.standardizedFileURL
        )
    }

    private func makeFixture() throws -> (baseURL: URL, managerRootURL: URL) {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDownloadFixture.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let rootURL = baseURL.appendingPathComponent(BrowserDownloadManager.downloadRootComponent, isDirectory: true)
        return (baseURL, rootURL)
    }
}
