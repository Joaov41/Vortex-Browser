import XCTest
@testable import Browser

@MainActor
final class BrowserIntentsPermitTests: XCTestCase {
    private func makeRuntime() -> BrowserIntentRuntime {
        BrowserIntentRuntime(readinessTimeout: 0.4, executionTimeout: 0.4, pollInterval: 0.01)
    }

    private let approve: BrowserIntentConfirmation = { _ in }

    func testSecondColdRequestRejectsWhileWaitingForWindow() async {
        let runtime = BrowserIntentRuntime(readinessTimeout: 0.3, executionTimeout: 0.5, pollInterval: 0.01)
        let first = Task { @MainActor in
            try await runtime.perform(.newTab, confirm: self.approve)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        do {
            _ = try await runtime.perform(.newTab, confirm: approve)
            XCTFail("Concurrent cold request must be rejected")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .busy)
        }
        _ = await first.result
        XCTAssertFalse(runtime.isBusy)
    }

    func testColdRequestSucceedsAfterRegistration() async throws {
        let runtime = makeRuntime()
        let task = Task { @MainActor in
            try await runtime.perform(.newTab, confirm: self.approve)
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        runtime.register(windowID: UUID(), isActive: true, isReady: { true }, execute: { _, _, _ in
            BrowserIntentOutput(text: "late ok")
        })
        let output = try await task.value
        XCTAssertEqual(output.text, "late ok")
    }

    func testExpiredPermitStaysInvalidDuringLaterRequest() async throws {
        let runtime = makeRuntime()
        var firstValidity: (@MainActor () -> Bool)?
        var secondPermitChecked = false
        var callCount = 0
        runtime.register(windowID: UUID(), isActive: true, isReady: { true }, execute: { _, _, validity in
            callCount += 1
            if callCount == 1 {
                firstValidity = validity
            } else {
                secondPermitChecked = firstValidity?() == false
            }
            return BrowserIntentOutput(text: "ok")
        })
        _ = try await runtime.perform(.newTab, confirm: approve)
        _ = try await runtime.perform(.newTab, confirm: approve)
        XCTAssertTrue(secondPermitChecked)
        XCTAssertEqual(firstValidity?(), false)
        let freshTaskResult = await Task { @MainActor in
            firstValidity?() ?? true
        }.value
        XCTAssertFalse(freshTaskResult)
    }

    func testBackgroundInvalidationKeepsPermitDeadAfterReactivation() async throws {
        let runtime = makeRuntime()
        let windowID = UUID()
        var captured: (@MainActor () -> Bool)?
        var revivedInsideExecute: Bool?
        runtime.register(windowID: windowID, isActive: true, isReady: { true }, execute: { _, _, validity in
            captured = validity
            runtime.setActive(false, windowID: windowID, invalidateRequest: true)
            runtime.setActive(true, windowID: windowID)
            revivedInsideExecute = validity()
            return BrowserIntentOutput(text: "late")
        })
        do {
            _ = try await runtime.perform(.newTab, confirm: approve)
            XCTFail("A background-invalidated request must not succeed")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
        XCTAssertEqual(revivedInsideExecute, false)
        XCTAssertEqual(captured?(), false)
    }

    func testTransientInactiveReactivatesPermit() async throws {
        let runtime = makeRuntime()
        let windowID = UUID()
        var duringInactive: Bool?
        var afterReactivate: Bool?
        runtime.register(windowID: windowID, isActive: true, isReady: { true }, execute: { _, _, validity in
            runtime.setActive(false, windowID: windowID)
            duringInactive = validity()
            runtime.setActive(true, windowID: windowID)
            afterReactivate = validity()
            return BrowserIntentOutput(text: "ok")
        })
        let output = try await runtime.perform(.newTab, confirm: approve)
        XCTAssertEqual(output.text, "ok")
        XCTAssertEqual(duringInactive, false)
        XCTAssertEqual(afterReactivate, true)
    }

    func testUnregisterThenReregisterDoesNotRevivePermit() async throws {
        let runtime = BrowserIntentRuntime(readinessTimeout: 0.4, executionTimeout: 5, pollInterval: 0.01)
        let windowID = UUID()
        var captured: (@MainActor () -> Bool)?
        runtime.register(windowID: windowID, isActive: true, isReady: { true }, execute: { _, _, validity in
            captured = validity
            runtime.unregister(windowID: windowID)
            runtime.register(windowID: windowID, isActive: true, isReady: { true }, execute: { _, _, _ in
                BrowserIntentOutput(text: "new")
            })
            return BrowserIntentOutput(text: "late")
        })
        do {
            _ = try await runtime.perform(.newTab, confirm: approve)
            XCTFail("Unregistered request must not succeed")
        } catch {
            XCTAssertEqual(error as? BrowserIntentError, .stalePage)
        }
        XCTAssertEqual(captured?(), false)
    }
}
