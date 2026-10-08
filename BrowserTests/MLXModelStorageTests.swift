import XCTest
@testable import Browser

final class MLXModelStorageTests: XCTestCase {
    private var tempRoot: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MLXModelStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        suiteName = "MLXModelStorageTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModelDirectory(_ relativePath: String, files: [String]) throws -> URL {
        let directory = tempRoot.appending(path: relativePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try Data("{}".utf8).write(to: directory.appending(path: file))
        }
        return directory
    }

    func testCompleteModelDirectoryNeedsConfigAndWeights() throws {
        let configOnly = try makeModelDirectory("config-only", files: ["config.json"])
        XCTAssertFalse(MLXModelStorage.isCompleteModelDirectory(configOnly))

        let complete = try makeModelDirectory("complete", files: ["config.json", "model.safetensors"])
        XCTAssertTrue(MLXModelStorage.isCompleteModelDirectory(complete))
    }

    func testShardedModelNeedsEveryShardFromIndex() throws {
        let directory = try makeModelDirectory(
            "sharded",
            files: ["config.json", "model-00001-of-00002.safetensors"]
        )
        let index = #"{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}"#
        try Data(index.utf8).write(to: directory.appending(path: "model.safetensors.index.json"))
        XCTAssertFalse(MLXModelStorage.isCompleteModelDirectory(directory))

        try Data().write(to: directory.appending(path: "model-00002-of-00002.safetensors"))
        XCTAssertTrue(MLXModelStorage.isCompleteModelDirectory(directory))
    }

    func testAppStorageModelIDMapsHubLayoutOnly() {
        let base = MLXModelStorage.appDownloadBase.appending(path: "models")
        XCTAssertEqual(
            MLXModelStorage.appStorageModelID(for: base.appending(path: "mlx-community/gemma-3-1b-it-qat-4bit")),
            "mlx-community/gemma-3-1b-it-qat-4bit"
        )
        XCTAssertNil(MLXModelStorage.appStorageModelID(for: base.appending(path: "org")))
        XCTAssertNil(MLXModelStorage.appStorageModelID(for: tempRoot.appending(path: "org/name")))
    }

    func testExternalIDsAreNeverTreatedAsHubDownloads() {
        XCTAssertTrue(MLXModelStorage.isExternal("external:/tmp/models/org/name"))
        XCTAssertFalse(MLXModelStorage.isExternal("mlx-community/gemma-3-1b-it-qat-4bit"))
        XCTAssertFalse(MLXModelStorage.isDownloaded(modelID: "external:/tmp/models/org/name"))
    }

    func testFolderDownloadResolvesThroughPickedFolderBookmark() throws {
        let modelDirectory = try makeModelDirectory(
            "picked/models/org/name",
            files: ["config.json", "model.safetensors"]
        )
        let picked = tempRoot.appending(path: "picked")
        let bookmark = try picked.bookmarkData(options: .minimalBookmark)

        MLXExternalModelStore.addEntry(
            path: modelDirectory.path,
            bookmark: bookmark,
            relativePath: "models/org/name",
            defaults: defaults
        )

        let resolved = MLXExternalModelStore.resolve(path: modelDirectory.path, defaults: defaults)
        XCTAssertEqual(resolved.model.resolvingSymlinksInPath().path, modelDirectory.resolvingSymlinksInPath().path)
        XCTAssertEqual(resolved.scope?.resolvingSymlinksInPath().path, picked.resolvingSymlinksInPath().path)
        XCTAssertEqual(MLXExternalModelStore.loadEntries(defaults: defaults).map(\.path), [modelDirectory.path])

        MLXExternalModelStore.removeEntry(path: modelDirectory.path, defaults: defaults)
        XCTAssertNil(MLXExternalModelStore.relativePath(for: modelDirectory.path, defaults: defaults))
    }

    func testDirectlyPickedFolderResolvesToItself() throws {
        let modelDirectory = try makeModelDirectory("direct", files: ["config.json", "model.safetensors"])
        let bookmark = try modelDirectory.bookmarkData(options: .minimalBookmark)
        MLXExternalModelStore.addEntry(path: modelDirectory.path, bookmark: bookmark, defaults: defaults)

        let resolved = MLXExternalModelStore.resolve(path: modelDirectory.path, defaults: defaults)
        XCTAssertEqual(resolved.model.resolvingSymlinksInPath().path, modelDirectory.resolvingSymlinksInPath().path)
    }
}
