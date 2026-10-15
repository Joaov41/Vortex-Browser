import AppIntents
import Foundation
import WebKit
import XCTest
@testable import Browser

@MainActor
final class BrowserIntentsExportAITests: BrowserIntentsExecutorTestCase {
    func testExportPDFReturnsPreparedData() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.exportPDF, confirm: confirm)
        XCTAssertEqual(output.filename, "Webpage.pdf")
        XCTAssertEqual(output.fileData, Data("%PDF-fake".utf8))
        XCTAssertEqual(harness.recorded.pdfCalls, 1)
    }

    func testExportPDFDeclineSkipsCapture() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let (executor, _) = makeExecutor(harness)
        do {
            _ = try await executor.execute(.exportPDF, confirm: decline)
            XCTFail("Decline must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(harness.recorded.pdfCalls, 0)
    }

    func testScreenshotRequiresApprovalAndAllowedPage() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.screenshot, confirm: confirm)
        XCTAssertEqual(output.filename, "Webpage.jpg")
        XCTAssertEqual(harness.recorded.screenshotCalls, 1)
    }

    func testCopyPageLinkWritesPasteboard() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness, baseURL: "https://example.com/page?token=secret&id=5")
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.copyPageLink, confirm: confirm)
        let copied = try XCTUnwrap(harness.recorded.pasteboardText)
        XCTAssertTrue(copied.contains("https://example.com/page"))
        XCTAssertFalse(copied.contains("secret"))
        XCTAssertEqual(copied, output.text)
    }

    func testSummarizeSendsCleanedTextToSelectedBackend() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.summarize, confirm: confirm)
        XCTAssertEqual(harness.recorded.aiCalls.count, 1)
        let call = try XCTUnwrap(harness.recorded.aiCalls.first)
        XCTAssertEqual(call.backend, .chatGPTPlan)
        XCTAssertEqual(call.instructions, BrowserIntentAIService.summaryInstructions)
        XCTAssertTrue(call.body.contains("<page_text>"))
        XCTAssertTrue(call.body.contains("hello world"))
        XCTAssertTrue(output.text.contains("AI result text"))
        XCTAssertTrue(output.text.contains("Based on the first"))
    }

    func testSummarizeGeneratorErrorPropagates() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let (executor, confirm) = makeExecutor(harness)
        harness.recorded.aiResult = .failure(BrowserIntentError.unsupported("backend down"))
        do {
            _ = try await executor.execute(.summarize, confirm: confirm)
            XCTFail("Generator failure must propagate")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .unsupported("backend down"))
        }
    }

    func testExportPDFRealServiceProducesPDFData() async throws {
        let harness = try makeHarness()
        let (_, webView) = try await loadPage(
            harness,
            html: "<html><body><h1>Report</h1><p>Content</p></body></html>"
        )
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let executor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: harness.history,
            isCurrent: { harness.current.value },
            backendProvider: { .chatGPTPlan },
            evaluateScript: { _, script, _ in
                script == BrowserAgentPageScript.documentIdentity
                    ? #"{"nonce":"abc123"}"#
                    : #"{"ok":true}"#
            }
        )
        let output = try await executor.execute(.exportPDF, confirm: { _ in })
        let data = try XCTUnwrap(output.fileData)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)), "Expected real PDF bytes")
        XCTAssertLessThanOrEqual(data.count, 12 * 1024 * 1024)
    }

    func testPrivateAndProviderTabsRejectedForDataExports() async throws {
        let harness = try makeHarness()
        let privateTab = addTab(harness, incognito: true)
        harness.viewModel.selectedTabID = privateTab.id
        let (executor, confirm) = makeExecutor(harness)
        let commands: [BrowserIntentCommand] = [
            .exportPDF, .screenshot, .copyPageLink, .summarize,
            .sendToWebAI(.chatgpt), .downloadVideo, .bookmark(nil)
        ]
        for command in commands {
            do {
                _ = try await executor.execute(command, confirm: confirm)
                XCTFail("Private tab must reject \(command)")
            } catch {
                XCTAssertTrue(error is BrowserIntentError)
            }
        }
        let providerTab = addTab(harness, provider: .gemini)
        harness.viewModel.selectedTabID = providerTab.id
        for command in commands {
            do {
                _ = try await executor.execute(command, confirm: confirm)
                XCTFail("Provider tab must reject \(command)")
            } catch {
                XCTAssertTrue(error is BrowserIntentError)
            }
        }
        XCTAssertEqual(harness.recorded.pdfCalls, 0)
        XCTAssertEqual(harness.recorded.screenshotCalls, 0)
    }

    func testAskLocalUsesLocalBackendWithoutPageContext() async throws {
        let harness = try makeHarness()
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.askLocal("What is Swift?"), confirm: confirm)
        let call = try XCTUnwrap(harness.recorded.aiCalls.first)
        XCTAssertEqual(call.backend, .localApple)
        XCTAssertEqual(call.instructions, BrowserIntentAIService.localQuestionInstructions)
        XCTAssertEqual(call.body, "What is Swift?")
        XCTAssertEqual(output.text, "AI result text")
    }

    func testSendToWebAIConfirmsBeforeCallback() async throws {
        let harness = try makeHarness()
        let (tab, webView) = try await loadPage(harness)
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.sendToWebAI(.chatgpt), confirm: confirm)
        let call = try XCTUnwrap(harness.recorded.sendWebAICalls.first)
        XCTAssertEqual(call.provider, .chatgpt)
        XCTAssertEqual(call.userPrompt, "Summarize this page excerpt.")
        XCTAssertTrue(call.composedPrompt.contains("<page_text>"))
        XCTAssertEqual(call.sourceTab.id, tab.id)
        XCTAssertEqual(call.binding.tabID, tab.id)
        XCTAssertEqual(call.binding.webViewIdentity, ObjectIdentifier(webView))
        XCTAssertTrue(output.text.contains("Sent the page excerpt to ChatGPT"))
    }

    func testSendToWebAIDeclineSkipsCallback() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let (executor, _) = makeExecutor(harness)
        do {
            _ = try await executor.execute(.sendToWebAI(.gemini), confirm: decline)
            XCTFail("Decline must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(harness.recorded.sendWebAICalls.isEmpty)
    }
}

@MainActor
final class BrowserIntentsDownloadSplitTests: BrowserIntentsExecutorTestCase {
    func testDownloadURLConfirmsThenStarts() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let (executor, confirm) = makeExecutor(harness)
        let target = try XCTUnwrap(URL(string: "https://files.example/report.zip"))
        let output = try await executor.execute(.downloadURL(target), confirm: confirm)
        XCTAssertEqual(harness.recorded.downloads, [target])
        XCTAssertTrue(output.text.contains("Download started"))
    }

    func testDownloadDeclineStartsNothing() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let (executor, _) = makeExecutor(harness)
        let target = try XCTUnwrap(URL(string: "https://files.example/report.zip"))
        do {
            _ = try await executor.execute(.downloadURL(target), confirm: decline)
            XCTFail("Decline must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(harness.recorded.downloads.isEmpty)
    }

    func testDownloadRejectsBlobAndUnsafeURLs() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let (executor, confirm) = makeExecutor(harness)
        for raw in ["blob:https://example.com/abc", "javascript:alert(1)", "file:///x"] {
            do {
                _ = try await executor.execute(.downloadURL(try XCTUnwrap(URL(string: raw))), confirm: confirm)
                XCTFail("Unsafe URL must be rejected: \(raw)")
            } catch {
                XCTAssertTrue(error is BrowserIntentError)
            }
        }
        XCTAssertTrue(harness.recorded.downloads.isEmpty)
    }

    func testDownloadVideoAmbiguityAndSuccess() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(harness)
        let recorded = harness.recorded
        recorded.videoScriptResult = #"["https://cdn.example/a.mp4","https://cdn.example/b.mp4"]"#
        let (executor, confirm) = makeExecutor(harness)
        let customExecutor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: harness.history,
            isCurrent: { harness.current.value },
            backendProvider: { .chatGPTPlan },
            evaluateScript: { _, script, _ in
                if script == BrowserAgentPageScript.documentIdentity {
                    return #"{"nonce":"abc123"}"#
                }
                return recorded.videoScriptResult
            },
            startDownload: { url, _, _ in recorded.downloads.append(url) }
        )
        do {
            _ = try await customExecutor.execute(.downloadVideo, confirm: confirm)
            XCTFail("Ambiguous video must throw")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
        XCTAssertTrue(recorded.downloads.isEmpty)

        recorded.videoScriptResult = #"["https://cdn.example/a.mp4","blob:https://example.com/x","#
            + "\"https://cdn.example/stream.m3u8\"]"
        let output = try await customExecutor.execute(.downloadVideo, confirm: confirm)
        XCTAssertEqual(recorded.downloads, [URL(string: "https://cdn.example/a.mp4")!])
        XCTAssertTrue(output.text.contains("Download started"))

        recorded.videoScriptResult = #"[]"#
        do {
            _ = try await customExecutor.execute(.downloadVideo, confirm: confirm)
            XCTFail("Missing video must throw")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
        _ = executor
    }

    func testOpenSplitCreatesPairAndCallback() async throws {
        let harness = try makeHarness()
        _ = addTab(harness)
        let (executor, confirm) = makeExecutor(harness)
        let first = try XCTUnwrap(URL(string: "https://a.example"))
        let second = try XCTUnwrap(URL(string: "https://b.example"))
        let output = try await executor.execute(.openSplit(first, second), confirm: confirm)
        XCTAssertEqual(output.text, "Opened both websites side by side.")
        let call = try XCTUnwrap(harness.recorded.splitCalls.first)
        let pair = harness.viewModel.splitPair(containing: call.0)
        XCTAssertEqual(pair?.secondaryID, call.1)
        XCTAssertEqual(harness.viewModel.selectedTabID, call.0)
    }

    func testOpenSplitValidatesBothURLsBeforeMutating() async throws {
        let harness = try makeHarness()
        _ = addTab(harness)
        let (executor, confirm) = makeExecutor(harness)
        let tabCount = harness.viewModel.tabs.count
        do {
            _ = try await executor.execute(
                .openSplit(
                    try XCTUnwrap(URL(string: "javascript:bad")),
                    try XCTUnwrap(URL(string: "https://b.example"))
                ),
                confirm: confirm
            )
            XCTFail("Invalid URL must be rejected")
        } catch {
            XCTAssertTrue(error is BrowserIntentError)
        }
        XCTAssertEqual(harness.viewModel.tabs.count, tabCount)
        XCTAssertTrue(harness.recorded.splitCalls.isEmpty)
    }

    func testEndSplitKeepsBothTabs() async throws {
        let harness = try makeHarness()
        let first = addTab(harness, url: "https://a.example")
        let second = addTab(harness, url: "https://b.example")
        harness.viewModel.setSplitPair(primaryID: first.id, secondaryID: second.id, isHorizontal: false)
        harness.viewModel.selectedTabID = first.id
        let (executor, confirm) = makeExecutor(harness)
        let output = try await executor.execute(.endSplit, confirm: confirm)
        XCTAssertEqual(output.text, "Ended split view; both tabs stay open.")
        XCTAssertNil(harness.viewModel.splitPair(containing: first.id))
        XCTAssertEqual(harness.recorded.endSplitCalls, 1)
        XCTAssertEqual(harness.viewModel.tabs.count, 2)
    }

    func testFilledPageBlocksExports() async throws {
        let harness = try makeHarness()
        let (tab, webView) = try await loadPage(harness)
        harness.privacy.quarantineBeforeFill(
            tabID: tab.id,
            webView: webView,
            runID: UUID(),
            pageURL: webView.url,
            documentNonce: "fixture-nonce",
            profileValues: ["given_name": "SecretName"]
        )
        let (executor, confirm) = makeExecutor(harness)
        do {
            _ = try await executor.execute(.exportPDF, confirm: confirm)
            XCTFail("Filled page must block PDF export")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .privacyProtected)
        }
        XCTAssertEqual(harness.recorded.pdfCalls, 0)
        do {
            _ = try await executor.execute(.summarize, confirm: confirm)
            XCTFail("Filled page must block summarize")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .privacyProtected)
        }
        XCTAssertTrue(harness.recorded.aiCalls.isEmpty)
    }
}
