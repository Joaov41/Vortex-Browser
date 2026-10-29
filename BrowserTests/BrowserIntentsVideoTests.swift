import XCTest
@testable import Browser

@MainActor
final class BrowserIntentsVideoTests: BrowserIntentsExecutorTestCase {
    func testDownloadVideoRealScriptResolvesRelativeSource() async throws {
        let harness = try makeHarness()
        _ = try await loadPage(
            harness,
            html: #"<html><body><video src="/clip.mp4"></video></body></html>"#,
            baseURL: "https://example.com/page"
        )
        let recorded = harness.recorded
        let executor = BrowserIntentExecutor(
            viewModel: harness.viewModel,
            downloadManager: harness.downloadManager,
            privacy: harness.privacy,
            historyStore: harness.history,
            isCurrent: { harness.current.value },
            backendProvider: { .chatGPTPlan },
            startDownload: { url, _, _ in
                recorded.downloads.append(url)
            }
        )
        let output = try await executor.execute(.downloadVideo, confirm: { _ in })
        XCTAssertEqual(
            recorded.downloads,
            [URL(string: "https://example.com/clip.mp4")!]
        )
        XCTAssertTrue(output.text.contains("Download started"))
    }

    func testDownloadVideoRealScriptAmbiguityDrmBlob() async throws {
        for (html, seedScript) in [
            (#"<html><body><video src="/a.mp4"></video><video src="/b.mp4"></video></body></html>"#, nil),
            (
                #"<html><body><video src="/a.mp4"></video></body></html>"#,
                "Object.defineProperty(document.querySelector('video'),"
                    + "'mediaKeys',{get:function(){return {};}}); return true;"
            ),
            (#"<html><body><video src="blob:https://example.com/x"></video></body></html>"#, nil)
        ] {
            let harness = try makeHarness()
            let (_, webView) = try await loadPage(harness, html: html)
            if let seedScript {
                _ = try await webView.callAsyncJavaScript(
                    seedScript,
                    arguments: [:],
                    in: nil,
                    in: BrowserAgentPageScript.world
                )
            }
            let recorded = harness.recorded
            let executor = BrowserIntentExecutor(
                viewModel: harness.viewModel,
                downloadManager: harness.downloadManager,
                privacy: harness.privacy,
                historyStore: harness.history,
                isCurrent: { harness.current.value },
                backendProvider: { .chatGPTPlan },
                startDownload: { url, _, _ in
                    recorded.downloads.append(url)
                }
            )
            do {
                _ = try await executor.execute(.downloadVideo, confirm: { _ in })
                XCTFail("Unsafe or ambiguous video must throw: \(html)")
            } catch {
                XCTAssertTrue(error is BrowserIntentError)
            }
            XCTAssertTrue(recorded.downloads.isEmpty)
        }
    }
}
