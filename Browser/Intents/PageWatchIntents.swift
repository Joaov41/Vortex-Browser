import AppIntents
import Foundation

extension PageWatchInterval: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Page watch interval"
    static let caseDisplayRepresentations: [PageWatchInterval: DisplayRepresentation] = [
        .hourly: "Every hour",
        .every6Hours: "Every 6 hours",
        .daily: "Daily",
        .weekly: "Weekly"
    ]
}

/// Checks every due watch now. Schedule it with a Shortcuts time-of-day automation to check on your own timing.
struct CheckWatchedPagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Watched Pages"
    static let description = IntentDescription(
        "Check your watched pages that are due now and report which ones changed."
    )
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let message = try await PageWatchCoordinator.shared.checkDueWatchesMessage()
        return .result(value: message)
    }
}

/// Creates a text watch for a web page. Private tabs and non-web addresses are refused.
struct WatchPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Watch Page"
    static let description = IntentDescription(
        "Watch a web page on a schedule and get a notification when its text changes."
    )
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Page Address", description: "The HTTP or HTTPS address to watch")
    var pageAddress: URL

    @Parameter(title: "Title", description: "An optional name for the watch")
    var watchTitle: String?

    @Parameter(title: "Check Every", default: .daily)
    var interval: PageWatchInterval

    static var parameterSummary: some ParameterSummary {
        Summary("Watch \(\.$pageAddress) \(\.$interval)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = try await MainActor.run { () throws -> String in
            try PageWatchCoordinator.shared.createTextWatch(
                url: pageAddress,
                title: watchTitle,
                interval: interval,
                notify: true
            ).title
        }
        await PageWatchCoordinator.shared.prepareNotifications(for: true)
        return .result(dialog: "Watching \(title). Vortyra will tell you when its text changes.")
    }
}
