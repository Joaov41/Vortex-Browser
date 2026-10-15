import AppIntents
import Foundation
import UIKit

extension AppIntent {
    func browserIntentConfirmation(message: String) async throws {
        try await requestConfirmation(
            conditions: [],
            actionName: .continue,
            dialog: IntentDialog(stringLiteral: message)
        )
    }

    func performBrowserIntent(
        _ command: BrowserIntentCommand
    ) async throws -> some IntentResult & ReturnsValue<String> {
        let output = try await BrowserIntentRuntime.shared.perform(command) { message in
            try await browserIntentConfirmation(message: message)
        }
        return .result(value: output.text, dialog: IntentDialog(stringLiteral: output.text))
    }
}

struct OpenBrowserURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Open URL in Vortyra"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "URL")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$url) in Vortyra")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.openURL(url))
    }
}

struct SearchBrowserIntent: AppIntent {
    static let title: LocalizedStringResource = "Search in Vortyra"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Search Text")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search Vortyra for \(\.$query)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.search(query))
    }
}

struct SearchClipboardBrowserIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Clipboard in Vortyra"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    static var parameterSummary: some ParameterSummary {
        Summary("Search Vortyra for the clipboard text")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let clipboard = await MainActor.run { UIPasteboard.general.string }
        guard let text = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw BrowserIntentError.invalidInput("The clipboard has no text to search for.")
        }
        return try await performBrowserIntent(.search(text))
    }
}

struct NewBrowserTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Vortyra Tab"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.newTab)
    }
}

struct NewPrivateBrowserTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Private Vortyra Tab"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.newPrivateTab)
    }
}

struct ReopenBrowserTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Reopen Last Closed Tab"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.reopenClosedTab)
    }
}

struct CloseBrowserTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Current Vortyra Tab"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.closeCurrentTab)
    }
}

struct CloseBrowserGroupIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Tabs in Group"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Group")
    var group: BrowserGroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Close tabs in \(\.$group)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let id = UUID(uuidString: group.id) else { throw BrowserIntentError.unknownGroup }
        return try await performBrowserIntent(.closeGroup(id))
    }
}

struct SwitchBrowserGroupIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch to Tab Group"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Group")
    var group: BrowserGroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch to \(\.$group)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let id = UUID(uuidString: group.id) else { throw BrowserIntentError.unknownGroup }
        return try await performBrowserIntent(.switchGroup(id))
    }
}

struct MoveBrowserTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Move Tab to Group"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Group")
    var group: BrowserGroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Move the current tab to \(\.$group)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let id = UUID(uuidString: group.id) else { throw BrowserIntentError.unknownGroup }
        return try await performBrowserIntent(.moveToGroup(id))
    }
}

struct BrowserBackIntent: AppIntent {
    static let title: LocalizedStringResource = "Go Back in Vortyra"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.back)
    }
}

struct BrowserForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Go Forward in Vortyra"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.forward)
    }
}

struct ReloadBrowserPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Reload Vortyra Page"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.reload)
    }
}

struct SetBrowserReaderIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Reader Mode"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Enabled")
    var enabled: Bool?

    static var parameterSummary: some ParameterSummary {
        Summary("Set reader mode to \(\.$enabled)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.setReader(enabled ?? true))
    }
}

struct TranslateBrowserPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Translate Vortyra Page"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Language")
    var language: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Translate the page to \(\.$language)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.translate(language ?? "en"))
    }
}

struct SetBrowserDesktopIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Desktop Site Mode"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Enabled")
    var enabled: Bool?

    static var parameterSummary: some ParameterSummary {
        Summary("Set desktop site mode to \(\.$enabled)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.setDesktop(enabled ?? true))
    }
}

struct OpenBrowserSplitIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Websites Side by Side"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "First URL")
    var firstURL: URL

    @Parameter(title: "Second URL")
    var secondURL: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$firstURL) and \(\.$secondURL) side by side")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.openSplit(firstURL, secondURL))
    }
}

struct EndBrowserSplitIntent: AppIntent {
    static let title: LocalizedStringResource = "End Split View"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.endSplit)
    }
}
