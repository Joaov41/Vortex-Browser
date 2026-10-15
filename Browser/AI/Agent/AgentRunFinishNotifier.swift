//
//  AgentRunFinishNotifier.swift
//  Vortex
//
//  Posts a local notification when a browser task started from Shortcuts or
//  Siri finishes. Notification permission is asked for the first time such a
//  run starts, never before. Private runs say only "Finished".
//

import Foundation
import UserNotifications

enum AgentRunFinishNotification {
    static let enabledKey = "agent.shortcutNotifications.enabled"
    /// userInfo key holding the finished run's `webmebrowser://run?id=` link. Not `url`, which the
    /// notification handler opens as a web page.
    static let routeKey = "agentRunURL"
    static let identifierPrefix = "agentrun."
    static let maximumBodyCharacters = 160
    static let privateTitle = "Finished"

    /// On unless the user turned it off in Settings.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    struct Content: Equatable {
        let identifier: String
        let title: String
        let body: String
        /// Opens the run's detail page. Nil for private runs, which keep no history.
        let link: URL?
    }

    static func content(for snapshot: BrowserAgentController.CompletionSnapshot) -> Content {
        let identifier = identifierPrefix + snapshot.runID.uuidString
        guard !snapshot.isPrivate else {
            return Content(identifier: identifier, title: privateTitle, body: "", link: nil)
        }
        let firstLine = snapshot.outcome.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return Content(
            identifier: identifier,
            title: AgentRunResultIntentSupport.title(forTask: snapshot.task),
            body: firstLine.isEmpty ? "Finished." : String(firstLine.prefix(maximumBodyCharacters)),
            link: AgentRunURLParser.url(for: snapshot.runID)
        )
    }
}

@MainActor
protocol AgentRunNotificationPosting {
    /// Asks for permission only when the system has not yet answered.
    func prepare() async
    func post(_ content: AgentRunFinishNotification.Content) async
}

@MainActor
struct UserNotificationAgentRunPoster: AgentRunNotificationPosting {
    func prepare() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(_ content: AgentRunFinishNotification.Content) async {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        if let link = content.link {
            notification.userInfo = [AgentRunFinishNotification.routeKey: link.absoluteString]
        }
        let request = UNNotificationRequest(identifier: content.identifier, content: notification, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Remembers which started runs came from Shortcuts or Siri and notifies when one of them finishes.
@MainActor
final class AgentRunFinishNotifier {
    static let shared = AgentRunFinishNotifier()
    static let maximumWatchedRuns = 16

    private let poster: any AgentRunNotificationPosting
    private let isEnabled: @MainActor () -> Bool
    private var watchedRequestIDs: [UUID] = []
    private var hasPrepared = false

    init(
        poster: (any AgentRunNotificationPosting)? = nil,
        isEnabled: @escaping @MainActor () -> Bool = { AgentRunFinishNotification.isEnabled() }
    ) {
        self.poster = poster ?? UserNotificationAgentRunPoster()
        self.isEnabled = isEnabled
    }

    /// A run queued by Shortcuts or Siri started. The first one asks for notification permission.
    @discardableResult
    func runStarted(requestID: UUID) -> Task<Void, Never>? {
        guard isEnabled() else { return nil }
        watchedRequestIDs.removeAll { $0 == requestID }
        watchedRequestIDs.append(requestID)
        if watchedRequestIDs.count > Self.maximumWatchedRuns {
            watchedRequestIDs.removeFirst(watchedRequestIDs.count - Self.maximumWatchedRuns)
        }
        guard !hasPrepared else { return nil }
        hasPrepared = true
        let poster = poster
        return Task { await poster.prepare() }
    }

    /// Posts the notification when `snapshot` ends a run that `runStarted` was told about.
    @discardableResult
    func runFinished(_ snapshot: BrowserAgentController.CompletionSnapshot) -> Task<Void, Never>? {
        guard let requestID = snapshot.requestID,
              let index = watchedRequestIDs.firstIndex(of: requestID) else { return nil }
        watchedRequestIDs.remove(at: index)
        guard isEnabled() else { return nil }
        let content = AgentRunFinishNotification.content(for: snapshot)
        let poster = poster
        return Task { await poster.post(content) }
    }
}
