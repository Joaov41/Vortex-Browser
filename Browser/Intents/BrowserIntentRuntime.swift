import Combine
import Foundation

enum BrowserIntentCommand: Sendable, Equatable {
    case openURL(URL)
    case search(String)
    case newTab
    case newPrivateTab
    case reopenClosedTab
    case closeCurrentTab
    case closeGroup(UUID)
    case switchGroup(UUID)
    case switchToTab(UUID)
    case moveToGroup(UUID)
    case back
    case forward
    case reload
    case setReader(Bool)
    case translate(String)
    case setDesktop(Bool)
    case findText(String)
    case bookmark(UUID?)
    case readingList
    case exportPDF
    case copyPageLink
    case screenshot
    case openHistoryMatch(String)
    case searchesOn(Date)
    case openSplit(URL, URL)
    case endSplit
    case summarize
    case askLocal(String)
    case sendToWebAI(BrowserIntentWebProvider)
    case downloadURL(URL)
    case downloadVideo
    case loadURLInTab(URL, UUID)
    case closeTabs([UUID])
    case deleteBookmarks([UUID])
    case clearHistory(Date?)
    case renameBookmark(UUID, String)
}

struct BrowserIntentOutput: Sendable {
    let text: String
    var fileData: Data?
    var filename: String?
    /// Set only by the summary command, for its result card. Other commands leave both nil.
    var pageTitle: String? = nil
    var pageURL: URL? = nil
    /// Set by the schema tab-creating commands so the schema intent can return the tab it made.
    var resultTabID: UUID? = nil
    /// Set by the bookmark command so the schema intent can return the saved bookmark.
    var savedBookmark: BrowserIntentSavedBookmark? = nil
}

struct BrowserIntentSavedBookmark: Sendable, Equatable {
    let id: UUID
    let title: String
    let url: URL
}

typealias BrowserIntentConfirmation = @MainActor @Sendable (String) async throws -> Void

enum BrowserIntentError: LocalizedError, Equatable {
    case noWindow
    case windowNotReady
    case multipleWindows
    case busy
    case timedOut
    case declined
    case noEligiblePage
    case pageNotLoaded
    case pageStillLoading
    case stalePage
    case invalidInput(String)
    case emptyResult(String)
    case privacyProtected
    case unknownGroup
    case lastAccessibleTab
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .noWindow:
            return "Vortyra is not open. Launch it and try again."
        case .windowNotReady:
            return "Vortyra did not become ready in time. Bring it to the foreground and try again."
        case .multipleWindows:
            return "Choose one Vortyra window and try again."
        case .busy:
            return "Vortyra is already running a browser action. Try again when it finishes."
        case .timedOut:
            return "The browser action took too long and was stopped."
        case .declined:
            return "The action was declined."
        case .noEligiblePage:
            return "The current Vortyra tab is not a regular HTTP(S) page this action can use."
        case .pageNotLoaded:
            return "The current page is not loaded yet. Open it in Vortyra first."
        case .pageStillLoading:
            return "Wait for the current page to finish loading and try again."
        case .stalePage:
            return "The page changed before the action could finish. Run it again."
        case .invalidInput(let message):
            return message
        case .emptyResult(let message):
            return message
        case .privacyProtected:
            return "This page is protected because a form was filled on it. Page data stays in Vortyra."
        case .unknownGroup:
            return "That tab group is no longer available."
        case .lastAccessibleTab:
            return "Vortyra will not close its last regular tab."
        case .unsupported(let message):
            return message
        }
    }
}

@MainActor
final class BrowserIntentRuntime: ObservableObject {
    static let shared = BrowserIntentRuntime()

    typealias ReadinessCheck = @MainActor () -> Bool
    typealias ValidityCheck = @MainActor @Sendable () -> Bool
    typealias CommandExecutor = @MainActor (
        BrowserIntentCommand,
        BrowserIntentConfirmation,
        @escaping ValidityCheck
    ) async throws -> BrowserIntentOutput

    private struct Endpoint {
        let windowID: UUID
        let registrationID: UUID
        var isActive: Bool
        let isReady: ReadinessCheck
        let execute: CommandExecutor
    }

    @Published private(set) var isBusy = false

    typealias TabSnapshot = @MainActor () -> [BrowserTab]

    private var endpoints: [UUID: Endpoint] = [:]
    /// Each window's current tabs, read by Spotlight tab entities. Kept apart from `endpoints`.
    private var tabSnapshots: [UUID: TabSnapshot] = [:]
    private var activeEndpointID: UUID?
    private var activeToken: UUID?
    private var activeRegistrationID: UUID?
    private var reservedToken: UUID?
    private var busyToken: UUID?
    private let readinessTimeout: TimeInterval
    private let executionTimeout: TimeInterval
    private let pollNanoseconds: UInt64

    init(
        readinessTimeout: TimeInterval = 10,
        executionTimeout: TimeInterval = 90,
        pollInterval: TimeInterval = 0.1
    ) {
        self.readinessTimeout = readinessTimeout
        self.executionTimeout = executionTimeout
        self.pollNanoseconds = UInt64(max(0.005, pollInterval) * 1_000_000_000)
    }

    func register(
        windowID: UUID,
        isActive: Bool,
        isReady: @escaping ReadinessCheck,
        execute: @escaping CommandExecutor
    ) {
        endpoints[windowID] = Endpoint(
            windowID: windowID,
            registrationID: UUID(),
            isActive: isActive,
            isReady: isReady,
            execute: execute
        )
    }

    func setActive(_ isActive: Bool, windowID: UUID, invalidateRequest: Bool = false) {
        endpoints[windowID]?.isActive = isActive
        if invalidateRequest, activeEndpointID == windowID {
            activeToken = nil
            activeEndpointID = nil
            activeRegistrationID = nil
        }
    }

    func registerTabSnapshot(windowID: UUID, tabs: @escaping TabSnapshot) {
        tabSnapshots[windowID] = tabs
    }

    /// Tabs of the one active window. Returns nothing when no window or several windows are active.
    func liveTabs() -> [BrowserTab] {
        let active = endpoints.values.filter(\.isActive)
        guard active.count == 1, let windowID = active.first?.windowID else { return [] }
        return tabSnapshots[windowID]?() ?? []
    }

    func unregister(windowID: UUID) {
        endpoints.removeValue(forKey: windowID)
        tabSnapshots.removeValue(forKey: windowID)
        if activeEndpointID == windowID {
            activeToken = nil
            activeEndpointID = nil
            activeRegistrationID = nil
        }
    }

    func isWindowRegisteredAndActive(windowID: UUID) -> Bool {
        endpoints[windowID]?.isActive == true
    }

    func perform(
        _ command: BrowserIntentCommand,
        confirm: @escaping BrowserIntentConfirmation
    ) async throws -> BrowserIntentOutput {
        try Task.checkCancellation()
        guard reservedToken == nil, !isBusy else { throw BrowserIntentError.busy }
        let token = UUID()
        reservedToken = token
        defer { releasePermit(ownedBy: token) }
        let endpoint = try await waitForEndpoint()
        try Task.checkCancellation()
        guard let live = endpoints[endpoint.windowID],
              live.registrationID == endpoint.registrationID,
              live.isActive,
              live.isReady() else {
            throw BrowserIntentError.windowNotReady
        }
        let windowID = endpoint.windowID
        let registrationID = endpoint.registrationID
        activeToken = token
        activeEndpointID = windowID
        activeRegistrationID = registrationID
        busyToken = token
        isBusy = true
        let isCurrent = makeRequestValidity(
            token: token,
            windowID: windowID,
            registrationID: registrationID
        )
        let output = try await AsyncTimeout.run(
            seconds: executionTimeout,
            timeoutError: { BrowserIntentError.timedOut },
            operation: { @MainActor in
                guard isCurrent() else { throw BrowserIntentError.stalePage }
                return try await endpoint.execute(command, confirm, isCurrent)
            }
        )
        try Task.checkCancellation()
        guard activeToken == token,
              let finished = endpoints[windowID],
              finished.registrationID == registrationID,
              finished.isActive else {
            throw BrowserIntentError.stalePage
        }
        return output
    }

    private func releasePermit(ownedBy token: UUID) {
        if activeToken == token {
            activeToken = nil
            activeEndpointID = nil
            activeRegistrationID = nil
        }
        if reservedToken == token {
            reservedToken = nil
        }
        if busyToken == token {
            busyToken = nil
            isBusy = false
        }
    }

    private func makeRequestValidity(
        token: UUID,
        windowID: UUID,
        registrationID: UUID
    ) -> ValidityCheck {
        { [weak self] in
            guard let self,
                  self.activeToken == token,
                  let endpoint = self.endpoints[windowID],
                  endpoint.registrationID == registrationID,
                  endpoint.isActive,
                  !Task.isCancelled else { return false }
            return endpoint.isReady()
        }
    }

    private func waitForEndpoint() async throws -> Endpoint {
        let deadline = Date().addingTimeInterval(readinessTimeout)
        while true {
            try Task.checkCancellation()
            let activeEndpoints = endpoints.values.filter(\.isActive)
            if activeEndpoints.count > 1 { throw BrowserIntentError.multipleWindows }
            if let endpoint = activeEndpoints.first, endpoint.isReady() {
                return endpoint
            }
            guard Date() < deadline else {
                throw endpoints.isEmpty ? BrowserIntentError.noWindow : BrowserIntentError.windowNotReady
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }
}
