//
//  BrowserAgentScreenshot.swift
//  Vortex
//
//  Bounded screenshot capture used only by a vision-capable agent engine.
//

import Foundation
import UIKit
import WebKit

enum BrowserAgentScreenshotError: Error, LocalizedError, Equatable {
    case captureFailed
    case timedOut
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .captureFailed: return "The current page could not be captured."
        case .timedOut: return "The page screenshot timed out."
        case .encodingFailed: return "The page screenshot could not be reduced to the safe image limit."
        }
    }
}

private nonisolated final class BrowserAgentScreenshotCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage, any Error>?
    private var result: Result<UIImage, any Error>?

    func install(_ continuation: CheckedContinuation<UIImage, any Error>) {
        lock.lock()
        let result = self.result
        if case nil = result { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with: result) }
    }

    func resolve(_ result: Result<UIImage, any Error>) {
        lock.lock()
        guard case nil = self.result else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

enum BrowserAgentScreenshotEncoder {
    typealias Snapshotter = @MainActor (
        WKWebView,
        WKSnapshotConfiguration,
        @escaping @MainActor @Sendable (UIImage?, (any Error)?) -> Void
    ) -> Void

    static let maximumDimension = 1_024
    static let maximumBytes = 512_000

    static func encode(
        _ image: CGImage,
        maximumDimension: Int = maximumDimension,
        maximumBytes: Int = maximumBytes
    ) -> Data? {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > 0, maximumDimension > 0, maximumBytes > 0 else { return nil }
        var scale = min(1, CGFloat(maximumDimension) / CGFloat(longestEdge))

        for _ in 0..<24 {
            let size = CGSize(
                width: max(1, (CGFloat(image.width) * scale).rounded(.down)),
                height: max(1, (CGFloat(image.height) * scale).rounded(.down))
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let resized = renderer.image { context in
                context.cgContext.interpolationQuality = .medium
                UIImage(cgImage: image, scale: 1, orientation: .up).draw(in: CGRect(origin: .zero, size: size))
            }
            for quality in [0.62, 0.48, 0.34] {
                guard let data = resized.jpegData(compressionQuality: quality) else { continue }
                if data.count <= maximumBytes { return data }
            }
            if size.width <= 1, size.height <= 1 { break }
            scale *= 0.75
        }
        return nil
    }

    @MainActor
    static func capture(
        _ webView: WKWebView,
        timeout: TimeInterval = 8,
        snapshotter: Snapshotter? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: webView.bounds.size)
        configuration.afterScreenUpdates = true
        let completion = BrowserAgentScreenshotCompletion()
        let takeSnapshot: Snapshotter
        if let snapshotter {
            takeSnapshot = snapshotter
        } else {
            takeSnapshot = { view, configuration, handler in
                view.takeSnapshot(with: configuration, completionHandler: handler)
            }
        }
        let image: UIImage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                guard !Task.isCancelled else {
                    completion.resolve(.failure(CancellationError()))
                    return
                }
                takeSnapshot(webView, configuration) { image, error in
                    if let image {
                        completion.resolve(.success(image))
                    } else {
                        completion.resolve(.failure(error ?? BrowserAgentScreenshotError.captureFailed))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, timeout)) {
                    completion.resolve(.failure(BrowserAgentScreenshotError.timedOut))
                }
            }
        } onCancel: {
            completion.resolve(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        guard let cgImage = image.cgImage,
              let jpeg = encode(cgImage) else {
            throw BrowserAgentScreenshotError.encodingFailed
        }
        return jpeg
    }
}
