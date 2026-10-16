import XCTest
@testable import Browser

@MainActor
final class AgentTasksTests: XCTestCase {
    private final class FailingQueuePersistence: PendingAgentTaskQueuePersistence {
        var data: Data?
        var failReads = false
        var failWrites = false

        func readData(forKey key: String) throws -> Data? {
            if failReads { throw PendingAgentTaskQueueError.readFailed }
            return data
        }

        func writeData(_ data: Data, forKey key: String) throws {
            if failWrites { throw PendingAgentTaskQueueError.writeFailed }
            self.data = data
        }
    }

    private final class FailingDirectoryFileManager: FileManager {
        override func createDirectory(
            at url: URL,
            withIntermediateDirectories createIntermediates: Bool,
            attributes: [FileAttributeKey: Any]? = nil
        ) throws {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTasksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeQueue(capacity: Int = 8) throws -> (PendingAgentTaskQueue, UserDefaults, String, String) {
        let suite = "AgentTasksTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let key = try AgentTaskStoreLocation.defaultsKey(bundleIdentifier: "com.example.BrowserTests")
        return (PendingAgentTaskQueue(defaults: defaults, storageKey: key, capacity: capacity), defaults, key, suite)
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func taskDocumentData(tasks: [Any], history: [Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["version": 1, "savedTasks": tasks, "history": history],
            options: [.sortedKeys]
        )
    }

    func testSavedTasksAndRunRecordsRoundTripWithoutLosingCapturedRunContext() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tasks.json")
        let store = AgentTaskStore(fileURL: fileURL)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let startURL = try XCTUnwrap(URL(string: "https://example.test/start?q=one"))
        let task = SavedAgentTask(
            title: "Daily report",
            task: "Read the page and summarize the latest report. Keep this exact wording.",
            startURL: startURL,
            createdAt: created
        )
        try store.saveTask(task)
        let record = AgentRunRecord(
            task: task.task,
            outcome: "Complete answer",
            actions: ["Read page title", "Finished"],
            date: created.addingTimeInterval(60),
            backend: AIModelBackend.chatGPTPlan.rawValue,
            preset: "research",
            startURL: startURL,
            isPrivate: false
        )
        try store.appendRun(record)

        let restored = AgentTaskStore(fileURL: fileURL)
        try restored.load()
        XCTAssertEqual(restored.savedTasks, [task])
        XCTAssertEqual(restored.history, [record])
        XCTAssertEqual(try restored.savedTask(id: task.id), task)
    }

    func testTaskEditsAndDeletesPublishOnlyAfterSuccessfulAtomicWrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tasks.json")
        let store = AgentTaskStore(fileURL: fileURL)
        let original = SavedAgentTask(title: "Original", task: "Read the page")
        try store.saveTask(original)

        let edited = SavedAgentTask(
            id: original.id,
            title: "Edited",
            task: "Read and compare the page",
            startURL: URL(string: "https://example.test"),
            createdAt: Date(timeIntervalSince1970: 1),
            lastRunAt: Date(timeIntervalSince1970: 2)
        )
        try store.updateTask(edited)
        XCTAssertEqual(store.savedTasks.first?.title, "Edited")
        XCTAssertEqual(store.savedTasks.first?.createdAt, original.createdAt)

        let failingStore = AgentTaskStore(fileURL: fileURL, fileManager: FailingDirectoryFileManager())
        try failingStore.load()
        let bytesBeforeFailures = try Data(contentsOf: fileURL)
        let savedTasksBeforeFailures = failingStore.savedTasks
        let historyBeforeFailures = failingStore.history

        XCTAssertThrowsError(try failingStore.saveTask(SavedAgentTask(title: "New", task: "Write"))) { error in
            XCTAssertEqual(error as? AgentTaskStoreError, .writeFailed, "A readable document should fail at commit time.")
        }
        XCTAssertThrowsError(try failingStore.updateTask(edited)) { error in
            XCTAssertEqual(error as? AgentTaskStoreError, .writeFailed)
        }
        XCTAssertThrowsError(try failingStore.deleteTask(id: original.id)) { error in
            XCTAssertEqual(error as? AgentTaskStoreError, .writeFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), bytesBeforeFailures)
        XCTAssertEqual(failingStore.savedTasks, savedTasksBeforeFailures)
        XCTAssertEqual(failingStore.history, historyBeforeFailures)

        let missingURL = directory.appendingPathComponent("not-created.json")
        let missingStore = AgentTaskStore(fileURL: missingURL, fileManager: FailingDirectoryFileManager())
        XCTAssertThrowsError(try missingStore.saveTask(SavedAgentTask(title: "No destination", task: "Write"))) { error in
            XCTAssertEqual(error as? AgentTaskStoreError, .writeFailed, "A missing file with a readable parent should fail during commit.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
        XCTAssertTrue(missingStore.savedTasks.isEmpty)
        XCTAssertTrue(missingStore.history.isEmpty)

        try store.deleteTask(id: original.id)
        XCTAssertTrue(store.savedTasks.isEmpty)
    }

    func testCorruptLoadAndMutationLeaveExistingDataAndPublishedStateUntouched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tasks.json")
        let store = AgentTaskStore(fileURL: fileURL)
        let task = SavedAgentTask(title: "Keep", task: "Read this page")
        try store.saveTask(task)
        let publishedBeforeCorruption = store.savedTasks
        let corruptBytes = Data("{ definitely not json".utf8)
        try corruptBytes.write(to: fileURL, options: .atomic)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? AgentTaskStoreError, .corruptData)
        }
        XCTAssertEqual(store.savedTasks, publishedBeforeCorruption)
        XCTAssertThrowsError(try store.saveTask(SavedAgentTask(title: "Replace", task: "Overwrite"))) { error in
            XCTAssertEqual(error as? AgentTaskStoreError, .corruptData)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)
    }

    func testTaskLimitsUseUTF8BytesConsistentlyAcrossStoreAndHandoff() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tasks.json")
        let store = AgentTaskStore(fileURL: fileURL)
        let exactLimitTask = String(repeating: "🌐", count: AgentTaskURLParser.maximumTaskUTF8Bytes / 4)
        XCTAssertEqual(exactLimitTask.utf8.count, AgentTaskURLParser.maximumTaskUTF8Bytes)
        XCTAssertLessThan(exactLimitTask.count, AgentTaskURLParser.maximumTaskUTF8Bytes)

        let saved = SavedAgentTask(title: "Unicode boundary", task: exactLimitTask)
        try store.saveTask(saved)
        let record = AgentRunRecord(
            task: exactLimitTask,
            outcome: "Finished",
            actions: [],
            backend: "chatGPTPlan",
            preset: "standard"
        )
        try store.appendRun(record)

        let (queue, defaults, _, suite) = try makeQueue()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pending = PendingAgentTask(task: exactLimitTask)
        try queue.enqueue(pending)
        XCTAssertEqual(try queue.pendingTasks(), [pending])

        let oversized = exactLimitTask + "🌐"
        XCTAssertEqual(oversized.utf8.count, AgentTaskURLParser.maximumTaskUTF8Bytes + 4)
        XCTAssertThrowsError(try store.saveTask(SavedAgentTask(title: "Too large", task: oversized))) { error in
            XCTAssertEqual(error as? AgentTaskStoreError, .invalidTask)
        }
        XCTAssertThrowsError(try store.appendRun(AgentRunRecord(
            task: oversized,
            outcome: "Finished",
            actions: [],
            backend: "chatGPTPlan",
            preset: "standard"
        ))) { error in
            XCTAssertEqual(error as? AgentTaskStoreError, .invalidRunRecord)
        }
        XCTAssertThrowsError(try queue.enqueue(PendingAgentTask(task: oversized))) { error in
            XCTAssertEqual(error as? PendingAgentTaskQueueError, .invalidTask)
        }

        let restored = AgentTaskStore(fileURL: fileURL)
        try restored.load()
        XCTAssertEqual(restored.savedTasks.first?.task, exactLimitTask)
        XCTAssertEqual(restored.history.first?.task, exactLimitTask)
    }

    func testStoreRejectsSemanticallyInvalidDocumentsWithoutChangingBytesOrPublishedState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tasks.json")
        let store = AgentTaskStore(fileURL: fileURL)
        let task = SavedAgentTask(title: "Kept task", task: "Read the existing page")
        let record = AgentRunRecord(
            task: "Kept history",
            outcome: "Complete",
            actions: ["Read page"],
            backend: "chatGPTPlan",
            preset: "standard"
        )
        try store.saveTask(task)
        try store.appendRun(record)
        let publishedTasks = store.savedTasks
        let publishedHistory = store.history

        let taskObject = try XCTUnwrap(try jsonObject(task) as? [String: Any])
        let recordObject = try XCTUnwrap(try jsonObject(record) as? [String: Any])
        let oneOverLimitTask = String(repeating: "🌐", count: (AgentTaskURLParser.maximumTaskUTF8Bytes / 4) + 1)
        var duplicateTask = taskObject
        duplicateTask["title"] = "Duplicate ID"
        var oversizedTask = taskObject
        oversizedTask["task"] = oneOverLimitTask
        var invalidURLTask = taskObject
        invalidURLTask["startURL"] = "file:///etc/passwd"
        var privateRecord = recordObject
        privateRecord["isPrivate"] = true
        var oversizedActionsRecord = recordObject
        oversizedActionsRecord["actions"] = [String(repeating: "A", count: AgentTaskStore.maximumActionUTF8Bytes + 1)]
        var duplicateRecord = recordObject
        duplicateRecord["outcome"] = "Duplicate ID"

        let validTasks = [try jsonObject(task)]
        let validHistory = [try jsonObject(record)]
        let tooManyHistory = (0...AgentTaskStore.historyLimit).map { index -> Any in
            var row = recordObject
            row["id"] = UUID().uuidString
            row["task"] = "History row \(index)"
            return row
        }
        let tooManyTasks = (0...AgentTaskStore.maximumSavedTasks).map { index -> Any in
            var row = taskObject
            row["id"] = UUID().uuidString
            row["title"] = "Saved row \(index)"
            return row
        }
        let invalidDocuments: [(String, Data)] = [
            ("duplicate saved task IDs", try taskDocumentData(tasks: [taskObject, duplicateTask], history: validHistory)),
            ("oversized UTF-8 task", try taskDocumentData(tasks: [oversizedTask], history: validHistory)),
            ("non-web start URL", try taskDocumentData(tasks: [invalidURLTask], history: validHistory)),
            ("private history row", try taskDocumentData(tasks: validTasks, history: [privateRecord])),
            ("duplicate history IDs", try taskDocumentData(tasks: validTasks, history: [recordObject, duplicateRecord])),
            ("oversized action", try taskDocumentData(tasks: validTasks, history: [oversizedActionsRecord])),
            ("history over limit", try taskDocumentData(tasks: validTasks, history: tooManyHistory)),
            ("saved tasks over limit", try taskDocumentData(tasks: tooManyTasks, history: validHistory))
        ]

        for (description, bytes) in invalidDocuments {
            try bytes.write(to: fileURL, options: .atomic)
            XCTAssertThrowsError(try store.load(), description) { error in
                XCTAssertEqual(error as? AgentTaskStoreError, .corruptData, description)
            }
            XCTAssertThrowsError(try store.deleteTask(id: task.id), description) { error in
                XCTAssertEqual(error as? AgentTaskStoreError, .corruptData, description)
            }
            XCTAssertEqual(store.savedTasks, publishedTasks, description)
            XCTAssertEqual(store.history, publishedHistory, description)
            XCTAssertEqual(try Data(contentsOf: fileURL), bytes, description)
        }
    }

    func testHistoryKeepsOnlyNewestFiftyRecords() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentTaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        for index in 0..<55 {
            try store.appendRun(AgentRunRecord(
                task: "Task \(index)",
                outcome: "Outcome \(index)",
                actions: ["Action \(index)"],
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                backend: "chatGPTPlan",
                preset: "standard"
            ))
        }
        XCTAssertEqual(store.history.count, 50)
        XCTAssertEqual(store.history.first?.task, "Task 54")
        XCTAssertEqual(store.history.last?.task, "Task 5")
        let restored = AgentTaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        try restored.load()
        XCTAssertEqual(restored.history.count, 50)
    }

    func testPrivateHistoryDoesNotAskForOrConstructTheStore() throws {
        let record = AgentRunRecord(
            task: "Private task",
            outcome: "Finished",
            actions: ["Read a page"],
            backend: "chatGPTPlan",
            preset: "standard",
            isPrivate: true
        )
        var providerCalls = 0
        let didRecord = try AgentTaskHistoryRecorder.record(record, isPrivate: true) {
            providerCalls += 1
            throw AgentTaskStoreError.appGroupUnavailable
        }
        XCTAssertFalse(didRecord)
        XCTAssertEqual(providerCalls, 0)

        let ordinaryRecord = AgentRunRecord(
            task: "Ordinary task",
            outcome: "Finished",
            actions: [],
            backend: "localApple",
            preset: "standard",
            isPrivate: false
        )
        XCTAssertThrowsError(try AgentTaskHistoryRecorder.record(ordinaryRecord, isPrivate: false) {
            providerCalls += 1
            throw AgentTaskStoreError.appGroupUnavailable
        })
        XCTAssertEqual(providerCalls, 1)
    }

    func testBundleIdentityNamespacesTaskFilesAndPendingDefaults() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let mainFile = try AgentTaskStoreLocation.fileURL(containerURL: container, bundleIdentifier: "com.web.me.Browser")
        let testFile = try AgentTaskStoreLocation.fileURL(containerURL: container, bundleIdentifier: "com.web.me.BrowserTests")
        let mainKey = try AgentTaskStoreLocation.defaultsKey(bundleIdentifier: "com.web.me.Browser")
        let testKey = try AgentTaskStoreLocation.defaultsKey(bundleIdentifier: "com.web.me.BrowserTests")

        XCTAssertNotEqual(mainFile.lastPathComponent, testFile.lastPathComponent)
        XCTAssertNotEqual(mainKey, testKey)
        XCTAssertThrowsError(try AgentTaskStoreLocation.fileName(bundleIdentifier: "../shared"))
    }

    func testAgentURLParserPreservesUnicodePlusAmpersandAndStartingURL() throws {
        let task = "Compare C++ & café prices — 東京 🌐"
        var components = URLComponents()
        components.scheme = "webmebrowser"
        components.host = "agent"
        components.queryItems = [
            URLQueryItem(name: "task", value: task),
            URLQueryItem(name: "url", value: "https://example.test/search?q=c%2B%2B&sort=price")
        ]
        let url = try XCTUnwrap(components.url)

        let parsed = try XCTUnwrap(AgentTaskURLParser.parse(url))
        XCTAssertEqual(parsed.task, task)
        XCTAssertEqual(parsed.startURL?.absoluteString, "https://example.test/search?q=c%2B%2B&sort=price")
    }

    func testAgentURLParserRejectsDuplicateMalformedAndNonHTTPParameters() throws {
        for query in [
            "task=one&task=two",
            "task=one&url=javascript%3Aalert%281%29",
            "task=%20%20",
            "task=one&extra=value",
            "task=one&url=",
            "task=one&url=https%3A%2F%2Fuser%3Apass%40example.test"
        ] {
            let url = try XCTUnwrap(URL(string: "webmebrowser://agent?\(query)"))
            XCTAssertThrowsError(try AgentTaskURLParser.parse(url), query)
        }
        let duplicateStart = try XCTUnwrap(URL(string: "webmebrowser://agent?task=one&url=https%3A%2F%2Fa.test&url=https%3A%2F%2Fb.test"))
        XCTAssertThrowsError(try AgentTaskURLParser.parse(duplicateStart))
        let unexpectedAgentPort = try XCTUnwrap(URL(string: "webmebrowser://agent:123?task=one"))
        XCTAssertThrowsError(try AgentTaskURLParser.parse(unexpectedAgentPort))
        let tooLong = String(repeating: "x", count: AgentTaskURLParser.maximumTaskUTF8Bytes + 1)
        var components = URLComponents()
        components.scheme = "webmebrowser"
        components.host = "agent"
        components.queryItems = [URLQueryItem(name: "task", value: tooLong)]
        XCTAssertThrowsError(try AgentTaskURLParser.parse(try XCTUnwrap(components.url)))
    }

    func testAgentURLParserIgnoresOtherRoutesAndIncomingURLPrecedenceStaysStable() throws {
        let file = URL(fileURLWithPath: "/tmp/bookmarks.html")
        XCTAssertEqual(try AgentIncomingURLRouter.route(file, cloudShortcutWasHandled: true), .bookmarkFile(file))

        let web = try XCTUnwrap(URL(string: "https://example.test/"))
        XCTAssertEqual(try AgentIncomingURLRouter.route(web, cloudShortcutWasHandled: true), .defaultBrowserLink(web))

        let cloud = try XCTUnwrap(URL(string: "webmebrowser://shortcut/success?requestID=abc"))
        XCTAssertEqual(try AgentIncomingURLRouter.route(cloud, cloudShortcutWasHandled: true), .cloudShortcut(cloud))
        XCTAssertEqual(try AgentIncomingURLRouter.route(cloud), .sharedPayload)

        let agentTaskURL = try XCTUnwrap(URL(string: "webmebrowser://agent?task=read%20the%20page"))
        guard case .agentTask(let pending) = try AgentIncomingURLRouter.route(agentTaskURL) else {
            return XCTFail("Agent route should be handled after the Cloud callback check.")
        }
        XCTAssertEqual(pending.task, "read the page")

        let sharedText = try XCTUnwrap(URL(string: "webmebrowser://share?text=hello%2Bworld"))
        XCTAssertEqual(try AgentIncomingURLRouter.route(sharedText), .sharedText("hello+world"))
        let sharedPayload = try XCTUnwrap(URL(string: "webmebrowser://share"))
        XCTAssertEqual(try AgentIncomingURLRouter.route(sharedPayload), .sharedPayload)
        XCTAssertNil(try AgentTaskURLParser.parse(sharedText))
        XCTAssertNil(try AgentTaskURLParser.parse(cloud))
    }

    func testPendingQueueConsumesFIFOExactlyOnceAndNotifiesOnlyAfterCommit() throws {
        let (queue, defaults, key, suite) = try makeQueue()
        defer { defaults.removePersistentDomain(forName: suite) }
        var notifications = 0
        let coordinator = AgentTaskHandoffCoordinator(queue: queue) { notifications += 1 }
        let first = PendingAgentTask(task: "First")
        let second = PendingAgentTask(task: "Second")
        try coordinator.enqueue(first)
        try coordinator.enqueue(second)
        XCTAssertEqual(notifications, 2)

        let otherObserver = PendingAgentTaskQueue(defaults: defaults, storageKey: key)
        XCTAssertEqual(try queue.consumeNext(), first)
        XCTAssertEqual(try otherObserver.consumeNext(), second)
        XCTAssertNil(try queue.consumeNext())
        XCTAssertEqual(notifications, 2)
    }

    func testUserDefaultsQueueReadsDoNotDependOnSuccessfulSynchronization() throws {
        let suite = "AgentTasksTests.ReadWithoutSync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = try AgentTaskStoreLocation.defaultsKey(bundleIdentifier: "com.example.BrowserTests")
        var synchronizationCalls = 0
        let persistence = UserDefaultsAgentTaskQueuePersistence(defaults: defaults) {
            synchronizationCalls += 1
            return false
        }
        let queue = PendingAgentTaskQueue(persistence: persistence, storageKey: key)

        XCTAssertEqual(try queue.pendingTasks(), [], "An empty queue is a valid read even if a flush would fail.")
        XCTAssertEqual(synchronizationCalls, 0)

        let writer = PendingAgentTaskQueue(defaults: defaults, storageKey: key)
        let request = PendingAgentTask(task: "Existing cross-process request")
        try writer.enqueue(request)

        XCTAssertEqual(try queue.pendingTasks(), [request])
        XCTAssertEqual(synchronizationCalls, 0, "Reading existing App Group bytes must not ask UserDefaults to flush writes.")
    }

    func testInjectedQueueReadFailurePropagatesWithoutChangingStoredQueue() throws {
        let persistence = FailingQueuePersistence()
        let queue = PendingAgentTaskQueue(persistence: persistence, storageKey: "read-failure")
        let request = PendingAgentTask(task: "Keep this queued")
        try queue.enqueue(request)
        let originalBytes = persistence.data
        persistence.failReads = true

        XCTAssertThrowsError(try queue.pendingTasks()) { error in
            XCTAssertEqual(error as? PendingAgentTaskQueueError, .readFailed)
        }
        XCTAssertThrowsError(try queue.consumeNext()) { error in
            XCTAssertEqual(error as? PendingAgentTaskQueueError, .readFailed)
        }
        XCTAssertEqual(persistence.data, originalBytes)
        persistence.failReads = false
        XCTAssertEqual(try queue.pendingTasks(), [request])
    }

    func testUserDefaultsWriteSucceedsWhenSynchronizeReportsFalseButTheValueReadsBack() throws {
        // On device, synchronize() returned false for the app-group defaults although the value was stored,
        // so every webmebrowser://agent link and Shortcuts request failed with "could not confirm".
        let suite = "AgentTasksTests.FalseSyncWrite.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = try AgentTaskStoreLocation.defaultsKey(bundleIdentifier: "com.example.BrowserTests")
        var synchronizationCalls = 0
        let persistence = UserDefaultsAgentTaskQueuePersistence(defaults: defaults) {
            synchronizationCalls += 1
            return false
        }
        let queue = PendingAgentTaskQueue(persistence: persistence, storageKey: key)
        var notifications = 0
        let coordinator = AgentTaskHandoffCoordinator(queue: queue) { notifications += 1 }
        let first = PendingAgentTask(task: "First request")
        let second = PendingAgentTask(task: "Second request")
        try coordinator.enqueue(first)
        try coordinator.enqueue(second)
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(try queue.pendingTasks(), [first, second])
        XCTAssertGreaterThan(synchronizationCalls, 0, "Writes still ask UserDefaults to flush.")

        XCTAssertEqual(try queue.consumeNext(), first)
        XCTAssertEqual(try queue.pendingTasks(), [second])
    }

    func testQueueHandoffIsVisibleToSeparateDefaultsClientAndConsumedIDsCannotReplay() throws {
        let suite = "AgentTasksTests.SharedSuite.\(UUID().uuidString)"
        let producerDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let consumerDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { producerDefaults.removePersistentDomain(forName: suite) }
        let key = try AgentTaskStoreLocation.defaultsKey(bundleIdentifier: "com.example.BrowserTests")
        let producer = PendingAgentTaskQueue(defaults: producerDefaults, storageKey: key)
        let consumer = PendingAgentTaskQueue(defaults: consumerDefaults, storageKey: key)
        var notificationCount = 0
        let coordinator = AgentTaskHandoffCoordinator(queue: producer) { notificationCount += 1 }
        let request = PendingAgentTask(id: UUID(), task: "Open the pricing page")

        try coordinator.enqueue(request)
        XCTAssertEqual(try consumer.pendingTasks(), [request])
        XCTAssertEqual(try consumer.consumeNext(), request)
        XCTAssertNil(try producer.consumeNext(), "A duplicate notification must find no second copy to consume.")
        XCTAssertThrowsError(try producer.enqueue(request)) { error in
            XCTAssertEqual(error as? PendingAgentTaskQueueError, .duplicateRequest)
        }
        XCTAssertEqual(notificationCount, 1, "A rejected replay must not emit another notification.")
    }

    func testPendingQueueReportsCapacityWithoutDroppingOrOverwritingRequests() throws {
        let (queue, defaults, _, suite) = try makeQueue(capacity: 3)
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = (0..<3).map { PendingAgentTask(task: "Task \($0)") }
        for request in original { try queue.enqueue(request) }
        let before = try queue.pendingTasks()
        XCTAssertThrowsError(try queue.enqueue(PendingAgentTask(task: "Overflow"))) { error in
            XCTAssertEqual(error as? PendingAgentTaskQueueError, .queueFull(limit: 3))
        }
        XCTAssertEqual(try queue.pendingTasks(), before)
        XCTAssertEqual(before, original)
    }

    func testCorruptPendingQueueIsNotOverwrittenByNewHandoff() throws {
        let (queue, defaults, key, suite) = try makeQueue()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("not-json".utf8)
        defaults.set(original, forKey: key)
        XCTAssertThrowsError(try queue.enqueue(PendingAgentTask(task: "Keep old data"))) { error in
            XCTAssertEqual(error as? PendingAgentTaskQueueError, .corruptQueue)
        }
        XCTAssertEqual(defaults.data(forKey: key), original)
    }

    func testDecodedQueueSemanticsRejectInvalidTasksBadURLsDuplicateIDsAndOverCapacity() throws {
        let (queue, defaults, key, suite) = try makeQueue(capacity: 2)
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID().uuidString
        let anotherID = UUID().uuidString
        let valid: [String: Any] = ["id": id, "task": "Read", "enqueuedAt": 0]
        let invalidStates: [[String: Any]] = [
            ["version": 1, "pending": [["id": id, "task": "  ", "enqueuedAt": 0]], "consumedIDs": []],
            ["version": 1, "pending": [["id": id, "task": "Read", "startURL": "file:///etc/passwd", "enqueuedAt": 0]], "consumedIDs": []],
            ["version": 1, "pending": [valid, valid], "consumedIDs": []],
            ["version": 1, "pending": [valid, ["id": anotherID, "task": "Second", "enqueuedAt": 0], ["id": UUID().uuidString, "task": "Third", "enqueuedAt": 0]], "consumedIDs": []]
        ]

        for state in invalidStates {
            let bytes = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            defaults.set(bytes, forKey: key)
            XCTAssertThrowsError(try queue.pendingTasks()) { error in
                XCTAssertEqual(error as? PendingAgentTaskQueueError, .corruptQueue)
            }
            XCTAssertThrowsError(try queue.enqueue(PendingAgentTask(task: "Do not overwrite"))) { error in
                XCTAssertEqual(error as? PendingAgentTaskQueueError, .corruptQueue)
            }
            XCTAssertEqual(defaults.data(forKey: key), bytes)
        }
    }

    func testQueueWriteFailureLeavesStoredAndPendingRequestsUnchanged() throws {
        let persistence = FailingQueuePersistence()
        let queue = PendingAgentTaskQueue(persistence: persistence, storageKey: "test")
        let existing = PendingAgentTask(task: "Existing request")
        try queue.enqueue(existing)
        let bytesBeforeFailure = persistence.data
        persistence.failWrites = true

        XCTAssertThrowsError(try queue.enqueue(PendingAgentTask(task: "New request"))) { error in
            XCTAssertEqual(error as? PendingAgentTaskQueueError, .writeFailed)
        }
        XCTAssertEqual(persistence.data, bytesBeforeFailure)
        persistence.failWrites = false
        XCTAssertEqual(try queue.pendingTasks(), [existing])
    }

    func testConsumeWriteFailureKeepsQueueHeadForRetry() throws {
        let persistence = FailingQueuePersistence()
        let queue = PendingAgentTaskQueue(persistence: persistence, storageKey: "consume-test")
        let first = PendingAgentTask(task: "First foreground request")
        let second = PendingAgentTask(task: "Second foreground request")
        try queue.enqueue(first)
        try queue.enqueue(second)
        let bytesBeforeFailure = try XCTUnwrap(persistence.data)
        persistence.failWrites = true

        XCTAssertThrowsError(try queue.consumeNextIfReady(
            isForeground: true,
            hasBrowserView: true,
            aiBusy: false,
            agentBusy: false,
            startupBusy: false
        )) { error in
            XCTAssertEqual(error as? PendingAgentTaskQueueError, .writeFailed)
        }
        XCTAssertEqual(persistence.data, bytesBeforeFailure)
        persistence.failWrites = false
        XCTAssertEqual(try queue.pendingTasks(), [first, second])
        XCTAssertEqual(try queue.consumeNextIfReady(
            isForeground: true,
            hasBrowserView: true,
            aiBusy: false,
            agentBusy: false,
            startupBusy: false
        ), first)
        XCTAssertEqual(try queue.pendingTasks(), [second])
    }

    func testQueueDoesNotConsumeUntilForegroundBrowserAndAllWorkAreReady() throws {
        let (queue, defaults, _, suite) = try makeQueue()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PendingAgentTask(task: "First")
        let second = PendingAgentTask(task: "Second")
        try queue.enqueue(first)
        try queue.enqueue(second)

        let blockedStates: [(String, Bool, Bool, Bool, Bool, Bool)] = [
            ("inactive scene", false, true, false, false, false),
            ("missing browser view", true, false, false, false, false),
            ("AI request busy", true, true, true, false, false),
            ("agent busy", true, true, false, true, false),
            ("startup navigation busy", true, true, false, false, true)
        ]
        for (label, foreground, hasBrowser, aiBusy, agentBusy, startupBusy) in blockedStates {
            XCTAssertNil(try queue.consumeNextIfReady(
                isForeground: foreground,
                hasBrowserView: hasBrowser,
                aiBusy: aiBusy,
                agentBusy: agentBusy,
                startupBusy: startupBusy
            ), label)
            XCTAssertEqual(try queue.pendingTasks(), [first, second], "\(label) must leave FIFO requests queued.")
        }

        XCTAssertEqual(try queue.consumeNextIfReady(
            isForeground: true,
            hasBrowserView: true,
            aiBusy: false,
            agentBusy: false,
            startupBusy: false
        ), first)
        XCTAssertEqual(try queue.consumeNextIfReady(
            isForeground: true,
            hasBrowserView: true,
            aiBusy: false,
            agentBusy: false,
            startupBusy: false
        ), second)
        XCTAssertNil(try queue.consumeNextIfReady(
            isForeground: true,
            hasBrowserView: true,
            aiBusy: false,
            agentBusy: false,
            startupBusy: false
        ))
    }

    func testDuplicateQueueRequestCannotBeConsumedTwice() throws {
        let (queue, defaults, _, suite) = try makeQueue()
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = PendingAgentTask(id: UUID(), task: "One request")
        try queue.enqueue(request)
        XCTAssertThrowsError(try queue.enqueue(request)) { error in
            XCTAssertEqual(error as? PendingAgentTaskQueueError, .duplicateRequest)
        }
        XCTAssertEqual(try queue.consumeNext(), request)
        XCTAssertNil(try queue.consumeNext())
    }

    func testIntentsDeclareForegroundOnlyAndEntityContainsDisplayMetadata() {
        XCTAssertEqual(RunAgentTaskIntent.supportedModes, .foreground)
        XCTAssertEqual(RunSavedAgentTaskIntent.supportedModes, .foreground)
        let entity = AgentTaskEntity(id: UUID().uuidString, title: "Daily price check")
        XCTAssertFalse(entity.id.isEmpty)
        XCTAssertEqual(entity.title, "Daily price check")
    }

    func testHistoryReplayDoesNotPretendItsRunRecordIsASavedTask() throws {
        let record = AgentRunRecord(
            task: "Replay this finished run",
            outcome: "Previously completed",
            actions: ["Read page"],
            backend: AIModelBackend.chatGPTPlan.rawValue,
            preset: "research",
            startURL: try XCTUnwrap(URL(string: "https://example.test/replay"))
        )
        let request = AgentTaskLaunchRequest(historyRecord: record)
        XCTAssertEqual(request.task, record.task)
        XCTAssertEqual(request.startURL, record.startURL)
        XCTAssertNil(request.savedTaskID, "History replay must not update lastRunAt on a fabricated saved-task ID.")
    }

    func testSaveDraftRemainsBoundToItsExactAssistantReplyID() throws {
        let replyID = UUID()
        let startURL = try XCTUnwrap(URL(string: "https://example.test/report"))
        let association = AgentTaskReplySaveAssociation(
            replyID: replyID,
            task: "Read this exact completed run",
            startURL: startURL
        )

        let draft = try XCTUnwrap(association.draft(for: replyID))
        XCTAssertEqual(draft.replyID, replyID)
        XCTAssertEqual(draft.task, association.task)
        XCTAssertEqual(draft.startURL, startURL)
        XCTAssertNil(association.draft(for: UUID()), "A stale row callback cannot save a different reply's task.")
    }

    func testSavePresentationCarriesItsDraftAtomically() throws {
        let replyID = UUID()
        let draft = AgentTaskSaveDraft(
            replyID: replyID,
            task: "Read this exact completed run",
            startURL: URL(string: "https://example.test/report")
        )

        let savePresentation = AgentTaskLibraryPresentation.save(draft)
        XCTAssertEqual(savePresentation.id, draft.id)
        XCTAssertEqual(savePresentation.initialDraft?.replyID, replyID)
        XCTAssertEqual(savePresentation.initialDraft?.task, draft.task)
        XCTAssertEqual(savePresentation.initialDraft?.startURL, draft.startURL)

        let browsePresentation = AgentTaskLibraryPresentation.browse(UUID())
        XCTAssertNil(browsePresentation.initialDraft)
    }
}
