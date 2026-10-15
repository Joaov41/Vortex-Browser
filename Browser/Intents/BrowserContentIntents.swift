import AppIntents
import Foundation
import UniformTypeIdentifiers

struct FindBrowserTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Text on Page"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Search Text")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$query) on the page")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.findText(query))
    }
}

struct BookmarkBrowserPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Bookmark Current Page"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Folder")
    var folder: BrowserFolderEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Bookmark the current page")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if let folder, UUID(uuidString: folder.id) == nil {
            throw BrowserIntentError.invalidInput("That Favorites folder is no longer available.")
        }
        return try await performBrowserIntent(.bookmark(folder.flatMap { UUID(uuidString: $0.id) }))
    }
}

struct SaveBrowserReadingListIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Page to Reading List"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.readingList)
    }
}

struct ExportBrowserPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Page as PDF"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let output = try await BrowserIntentRuntime.shared.perform(.exportPDF) { message in
            try await browserIntentConfirmation(message: message)
        }
        guard let data = output.fileData else {
            throw BrowserIntentError.emptyResult("The page PDF was not prepared.")
        }
        let file = IntentFile(data: data, filename: output.filename ?? "Webpage.pdf", type: .pdf)
        return .result(
            value: file,
            dialog: "Prepared the PDF. Add Save File in Shortcuts to keep it."
        )
    }
}

struct CopyBrowserLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Page Title and URL"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.copyPageLink)
    }
}

struct CaptureBrowserPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Page Screenshot"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let output = try await BrowserIntentRuntime.shared.perform(.screenshot) { message in
            try await browserIntentConfirmation(message: message)
        }
        guard let data = output.fileData else {
            throw BrowserIntentError.emptyResult("The page image was not prepared.")
        }
        let file = IntentFile(data: data, filename: output.filename ?? "Webpage.jpg", type: .jpeg)
        return .result(
            value: file,
            dialog: "Prepared the page file. Add Save File or Save to Photo Album in Shortcuts to keep it."
        )
    }
}

struct OpenBrowserHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Last Matching History Page"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Search Text")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Open the last page matching \(\.$query)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.openHistoryMatch(query))
    }
}

struct BrowserSearchHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recorded Web Searches"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Date")
    var date: Date

    static var parameterSummary: some ParameterSummary {
        Summary("Get recorded web searches on \(\.$date)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.searchesOn(date))
    }
}

struct SummarizeBrowserPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Current Page"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.summarize)
    }
}

struct AskBrowserLocalIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask On-Device AI"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Question")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask on-device AI \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.askLocal(question))
    }
}

struct SendBrowserPageToAIIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Page to Web AI"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Provider")
    var provider: BrowserIntentWebProvider

    static var parameterSummary: some ParameterSummary {
        Summary("Send the page to \(\.$provider)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.sendToWebAI(provider))
    }
}

struct DownloadBrowserURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Download URL in Vortyra"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "URL")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$url) in Vortyra")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.downloadURL(url))
    }
}

struct DownloadBrowserVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Download Direct Page Video"
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await performBrowserIntent(.downloadVideo)
    }
}
