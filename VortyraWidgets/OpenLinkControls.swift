import AppIntents
import SwiftUI
import WidgetKit

/// Opens a private tab in Vortyra. The app handles `webmebrowser://private-tab`.
struct NewPrivateTabControl: ControlWidget {
    static let kind = "com.web.me.Browser.control.newPrivateTab"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(WidgetLinks.privateTab)) {
                Label("New Private Tab", systemImage: "eye.slash")
            }
        }
        .displayName("New Private Tab")
        .description("Open a private tab in Vortyra.")
    }
}

/// Puts the clipboard text into Vortyra's address field. The app never submits it on its own.
struct SearchClipboardControl: ControlWidget {
    static let kind = "com.web.me.Browser.control.searchClipboard"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(WidgetLinks.searchClipboard)) {
                Label("Search Clipboard", systemImage: "doc.on.clipboard")
            }
        }
        .displayName("Search Clipboard")
        .description("Put the clipboard text into Vortyra's address field.")
    }
}
