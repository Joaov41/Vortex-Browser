import Foundation
import UserNotifications

enum PageWatchNotification {
    /// userInfo key holding the `webmebrowser://watch?id=` link. It is deliberately not `url`,
    /// which the existing notification handler opens as a web page.
    static let routeKey = "pageWatchURL"
    /// Posted by the app delegate when a page-watch notification is tapped. Its userInfo["url"] is a URL.
    static let openRequested = Notification.Name("Browser.PageWatchOpenRequested")
    static let identifierPrefix = "pagewatch."
    static let maximumBodyPreviewCharacters = 120
}

@MainActor
protocol PageWatchNotifying {
    /// Asks for permission only when the system has not yet answered.
    func prepareForNotifications() async
    func notifyChanged(_ watch: PageWatch, preview: String) async
}

@MainActor
struct UserNotificationPageWatchNotifier: PageWatchNotifying {
    func prepareForNotifications() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notifyChanged(_ watch: PageWatch, preview: String) async {
        guard let link = PageWatchURLParser.url(for: watch.id)?.absoluteString else { return }
        let content = UNMutableNotificationContent()
        content.title = watch.title
        content.body = "Changed: " + String(preview.prefix(PageWatchNotification.maximumBodyPreviewCharacters))
        content.userInfo = [PageWatchNotification.routeKey: link]
        // A fixed identifier per watch replaces an earlier, unread notification for the same page.
        let request = UNNotificationRequest(
            identifier: PageWatchNotification.identifierPrefix + watch.id.uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
