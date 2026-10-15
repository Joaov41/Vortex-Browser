import Foundation
import WebKit

enum AgentTaskNavigationEventKind: Equatable, Sendable {
    case started
    case committed
    case finished
    case failed
}

enum AgentTaskNavigationResolution: Equatable {
    case waiting
    case completed
    case failed(String)
}

/// Tracks only the navigation chain started for one task request. It accepts
/// server redirects carried by that same WKNavigation and rejects any new
/// navigation chain or changed browser context.
struct AgentTaskNavigationChain {
    let requestID: UUID
    let tabID: UUID
    let webViewID: ObjectIdentifier
    let requestedURL: URL
    private(set) var navigationID: ObjectIdentifier?
    private(set) var resolution: AgentTaskNavigationResolution = .waiting

    init(request: PendingAgentTask, tabID: UUID, webView: AnyObject) throws {
        guard let url = request.startURL, AgentTaskURLParser.isAllowedStartURL(url) else {
            throw AgentTaskURLParseError.invalidStartURL
        }
        self.requestID = request.id
        self.tabID = tabID
        self.webViewID = ObjectIdentifier(webView)
        self.requestedURL = url
    }

    mutating func bind(navigation: AnyObject) -> Bool {
        guard resolution == .waiting, navigationID == nil else { return false }
        navigationID = ObjectIdentifier(navigation)
        return true
    }

    @discardableResult
    mutating func receive(
        _ event: AgentTaskNavigationEventKind,
        tabID: UUID,
        webView: AnyObject,
        navigation: AnyObject,
        finalURL: URL?,
        isLoading: Bool
    ) -> AgentTaskNavigationResolution {
        guard resolution == .waiting else { return resolution }
        guard tabID == self.tabID, ObjectIdentifier(webView) == webViewID else {
            resolution = .failed("The browser tab changed before the starting page finished loading.")
            return resolution
        }
        let observedNavigationID = ObjectIdentifier(navigation)
        guard let expected = navigationID else {
            // The load callback binds the exact WKNavigation before WebKit's
            // delegate callbacks are delivered. Ignore unrelated old events.
            return resolution
        }
        guard observedNavigationID == expected else {
            // The requested load may cancel the previous page's WKNavigation.
            // Old terminal callbacks are unrelated and must not defeat the new
            // chain; a new started chain is an actual superseding navigation.
            if event == .started {
                resolution = .failed("Another page navigation replaced the requested starting page.")
            }
            return resolution
        }

        switch event {
        case .started:
            return resolution
        case .committed:
            return resolution
        case .failed:
            resolution = .failed("The requested starting page could not be loaded.")
        case .finished:
            guard !isLoading,
                  let finalURL,
                  AgentTaskURLParser.isAllowedStartURL(finalURL) else {
                resolution = .failed("The starting page did not finish at a valid website address.")
                return resolution
            }
            resolution = .completed
        }
        return resolution
    }

    mutating func fail(_ message: String) -> AgentTaskNavigationResolution {
        guard resolution == .waiting else { return resolution }
        resolution = .failed(message)
        return resolution
    }

    var isPending: Bool { resolution == .waiting }
}

@MainActor
final class AgentTaskNavigationAttempt {
    let request: PendingAgentTask
    private(set) var chain: AgentTaskNavigationChain
    private(set) var resolution: AgentTaskNavigationResolution = .waiting
    private(set) var expectedNavigation: WKNavigation?
    private(set) var hasRequestedNavigation = false
    weak var tab: BrowserTab?
    weak var webView: WKWebView?
    var hasBoundNavigation: Bool { expectedNavigation != nil }

    init(request: PendingAgentTask, tab: BrowserTab, webView: WKWebView) throws {
        self.request = request
        self.tab = tab
        self.webView = webView
        self.chain = try AgentTaskNavigationChain(request: request, tabID: tab.id, webView: webView)
    }

    func isCurrent(in viewModel: BrowserViewModel, selectedContextID: UUID?) -> Bool {
        guard resolution == .waiting,
              let tab, let webView,
              selectedContextID == tab.id,
              viewModel.selectedTabID == tab.id,
              viewModel.tabs.contains(where: { $0 === tab }),
              tab.liveWebView === webView else { return false }
        return true
    }

    @discardableResult
    func bind(webView: WKWebView, navigation: WKNavigation) -> Bool {
        guard let tab, tab.liveWebView === webView,
              chain.bind(navigation: navigation) else { return false }
        expectedNavigation = navigation
        return true
    }

    func markNavigationRequested() -> Bool {
        guard resolution == .waiting, !hasRequestedNavigation else { return false }
        hasRequestedNavigation = true
        return true
    }

    @discardableResult
    func receive(
        _ event: AgentTaskNavigationEventKind,
        tab: BrowserTab,
        webView: WKWebView,
        navigation: WKNavigation,
        finalURL: URL?,
        isLoading: Bool
    ) -> AgentTaskNavigationResolution {
        resolution = chain.receive(
            event,
            tabID: tab.id,
            webView: webView,
            navigation: navigation,
            finalURL: finalURL,
            isLoading: isLoading
        )
        return resolution
    }

    @discardableResult
    func fail(_ message: String) -> AgentTaskNavigationResolution {
        resolution = chain.fail(message)
        return resolution
    }
}

/// Immutable evidence captured after a task's exact starting document is ready.
/// The sidebar revalidates it synchronously immediately before starting the
/// model loop, so a same-URL replacement, tab switch, or new document cannot
/// inherit the completed navigation's approval to start.
struct AgentTaskPreparedContext: Equatable {
    let requestID: UUID
    let tabID: UUID
    let webViewID: ObjectIdentifier
    let finalURL: String
    let documentRevision: Int
    let navigationID: ObjectIdentifier?

    init(
        requestID: UUID,
        tabID: UUID,
        webView: AnyObject,
        finalURL: URL,
        documentRevision: Int,
        navigation: AnyObject? = nil,
        navigationID: ObjectIdentifier? = nil
    ) {
        self.requestID = requestID
        self.tabID = tabID
        self.webViewID = ObjectIdentifier(webView)
        self.finalURL = finalURL.absoluteString
        self.documentRevision = documentRevision
        self.navigationID = navigationID ?? navigation.map(ObjectIdentifier.init)
    }

    func matches(
        requestID: UUID,
        tabID: UUID,
        webView: AnyObject,
        currentURL: URL?,
        documentRevision: Int,
        isLoading: Bool,
        isForegroundReady: Bool
    ) -> Bool {
        guard isForegroundReady,
              self.requestID == requestID,
              self.tabID == tabID,
              webViewID == ObjectIdentifier(webView),
              self.documentRevision == documentRevision,
              !isLoading,
              let currentURL,
              AgentTaskURLParser.isAllowedStartURL(currentURL) else { return false }
        return currentURL.absoluteString == finalURL
    }
}

enum AgentTaskWindowQueuePolicy {
    /// A request may remain at the head while a no-startURL task waits for a
    /// usable current page. Remove it only after the model run has passed its
    /// final prepared-context check and synchronously started.
    @discardableResult
    static func acknowledgeStarted(
        requestID: UUID,
        pending: inout [PendingAgentTask],
        staged: inout PendingAgentTask?,
        isBusy: inout Bool
    ) -> Bool {
        guard staged?.id == requestID else { return false }
        pending.removeAll { $0.id == requestID }
        staged = nil
        isBusy = true
        return true
    }
}

enum AgentTaskWebViewLoadPolicy {
    static func shouldStartRestorationLoad(
        requestedURL: URL,
        currentTabURL: URL?,
        isLoading: Bool,
        agentOwnsLoad: Bool
    ) -> Bool {
        !agentOwnsLoad && !isLoading && currentTabURL == requestedURL
    }
}
