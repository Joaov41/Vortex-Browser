import BackgroundTasks
import Foundation

/// BGAppRefreshTask wiring for page watches. `register()` must run before the app finishes launching.
nonisolated enum PageWatchBackgroundScheduler {
    static let identifier = "com.web.me.Browser.pagewatch"

    /// Called from `application(_:didFinishLaunchingWithOptions:)`.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            runRefresh(refresh)
        }
    }

    /// Runs one refresh and always completes the task. The expiration handler cancels the checks in progress.
    static func runRefresh(_ refresh: BGAppRefreshTask) {
        let work = Task { @MainActor in
            let summary = await PageWatchCoordinator.shared.runBackgroundRefresh()
            PageWatchBackgroundScheduler.refreshSchedule()
            refresh.setTaskCompleted(success: summary != nil && !Task.isCancelled)
        }
        refresh.expirationHandler = {
            work.cancel()
        }
    }

    /// Re-derives the next refresh from the stored watches. Called at launch, on backgrounding and after every change.
    @MainActor
    static func refreshSchedule() {
        schedule(earliest: try? PageWatchCoordinator.shared.nextBackgroundRefreshDate())
    }

    /// Replaces any pending request. With no due text watch there is nothing to schedule.
    @MainActor
    static func schedule(earliest: Date?) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard let earliest else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliest
        // A failed submit (for example in the simulator) is harmless: the next launch, background or save reschedules.
        try? BGTaskScheduler.shared.submit(request)
    }
}
