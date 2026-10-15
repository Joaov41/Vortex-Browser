import SwiftUI
import Combine
import Translation
import WebKit
import SafariServices
import UIKit
import UserNotifications
import UniformTypeIdentifiers

nonisolated private func browserAIFlowLog(_ message: @autoclosure () -> String) {
    print("🌐 [AIFlow] \(message())")
}

nonisolated private func browserAIWebLog(_ message: @autoclosure () -> String) {
    print("🕸️ [AIWeb] \(message())")
}

nonisolated private func browserURLForLog(_ url: URL?) -> String {
    guard let url else { return "nil" }
    let scheme = url.scheme?.lowercased() ?? "unknown"
    let host = url.host?.lowercased() ?? "no-host"
    return "\(scheme)://\(host)"
}

/// Pages start a little below the status bar and the blurred band under it, so a site's
/// top row can be tapped when it loads; scrolling still slides content up under the
/// status bar. Began as a Reddit/X fix and applies to every web page.
enum BrowserSiteViewportPolicy {
    static let iPadTopContentInset: CGFloat = 12
    static let iPhoneTopContentInset: CGFloat = 24

    static func topContentInset(for url: URL?, idiom: UIUserInterfaceIdiom) -> CGFloat {
        guard let scheme = url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url?.host?.isEmpty == false else {
            return 0
        }

        switch idiom {
        case .pad:
            return iPadTopContentInset
        case .phone:
            return iPhoneTopContentInset
        default:
            return 0
        }
    }
}

enum BrowserExternalNavigationPolicy {
    private static func isXWebHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "x.com" || host.hasSuffix(".x.com")
            || host == "twitter.com" || host.hasSuffix(".twitter.com")
    }

    static func shouldForceXHTTPSNavigationInWebView(
        _ url: URL?,
        navigationType: WKNavigationType
    ) -> Bool {
        guard navigationType == .linkActivated,
              let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return isXWebHost(url.host)
    }

    static func shouldCancelXAppDeepLink(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "x" || scheme == "twitter"
    }

    /// Widget and control links are for the system only. A web page that navigates to one is ignored.
    static func shouldCancelWidgetControlLink(_ url: URL?) -> Bool {
        guard let url else { return false }
        return AgentControlURLParser.isControlURL(url)
    }
}

enum AIPanelDismissalPolicy {
    static func allowsDismissal(isProcessing: Bool, isExplicitCancellation: Bool) -> Bool {
        isExplicitCancellation || !isProcessing
    }
}

enum AIConversationContextPolicy {
    static func preservesConversation(previousContextWasPrivate: Bool, nextContextIsPrivate: Bool) -> Bool {
        !previousContextWasPrivate && !nextContextIsPrivate
    }
}

// MARK: - Darwin Notification Observer (for Share Extension IPC)
@MainActor
final class DarwinNotificationObserver: ObservableObject {
    static let notificationName = "com.browser.sharedURL" as CFString
    static let appGroupID = "group.com.browser.app"  // Update with your actual App Group ID

    let notifications = PassthroughSubject<Void, Never>()

    func startObserving() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()

        // Remove any existing observer
        stopObserving()

        // Create callback
        let callback: CFNotificationCallback = { center, observer, name, object, userInfo in
            print("DEBUG: Darwin notification received!")
            if let observer = observer {
                let observerInstance = Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    print("DEBUG: Calling onNotificationReceived callback")
                    observerInstance.notifications.send()
                }
            }
        }

        // Add observer
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            callback,
            Self.notificationName,
            nil,
            .deliverImmediately
        )
        print("DEBUG: Darwin observer started for: \(Self.notificationName)")
    }

    func stopObserving() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }

    isolated deinit {
        stopObserving()
    }
}

// MARK: - Glass TextField Component
struct GlassTextField: View {
    @ObservedObject var tab: BrowserTab
    var placeholder: String = "Search or enter address"
    var onSubmit: (() -> Void)?
    var showClearButton: Bool = true
    var trailingAccessory: AnyView? = nil
    var onClear: (() -> Void)? = nil
    var frosted: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.isIncognito ? "eye.slash" : "magnifyingglass")
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityLabel(tab.isIncognito ? "Private tab" : "")
            
            TextField(placeholder, text: $tab.address)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .onSubmit { onSubmit?() }
            
            if let trailingAccessory {
                trailingAccessory
            }

            if showClearButton && !tab.address.isEmpty {
                Button {
                    tab.address = ""
                    onClear?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .ios26PhoneButtonHitTargetCompat()
                .accessibilityLabel("Clear text")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .toolbarBackdrop(in: Capsule(), frosted: frosted)
        .shadow(radius: 8, y: 3)
    }
}

private extension View {
    func browserToolbarControl() -> some View {
        frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    func ios26ButtonHitTargetCompat() -> some View {
        if #available(iOS 27.0, *) {
            self
        } else {
            self
                .frame(width: 44, height: 44)
                .contentShape(.interaction, Rectangle())
        }
    }

    @ViewBuilder
    func ios26PhoneButtonHitTargetCompat() -> some View {
        if #available(iOS 27.0, *) {
            self
        } else if UIDevice.current.userInterfaceIdiom == .phone {
            self
                .frame(width: 44, height: 44)
                .contentShape(.interaction, Rectangle())
        } else {
            self
        }
    }
}

final class AIWebView: WKWebView {
    var onAskAI: (() -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let command = UICommand(
            title: "Ask about this",
            action: #selector(askAI(_:))
        )
        let menu = UIMenu(
            title: "",
            options: .displayInline,
            children: [command]
        )
        builder.insertChild(menu, atEndOfMenu: .standardEdit)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(askAI(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func askAI(_ sender: Any?) {
        onAskAI?()
    }
}

/// What the page's scrolling and taps mean for the floating bottom toolbar.
enum ToolbarScrollEvent {
    case scrollBegan
    case scrollEnded(atTop: Bool)
    /// A tap on the page or a new page: show the toolbar and keep it showing.
    case pin
}

/// WebKit temporarily reparents the web view for element fullscreen. SwiftUI must own a stable
/// container instead of resizing that web view while it belongs to the fullscreen controller.
final class BrowserWebViewContainer: UIView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        backgroundColor = webView.backgroundColor
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
    }

    required init?(coder: NSCoder) { nil }

    /// Height of the floating browser controls above the bottom safe area while they're
    /// showing. The web view treats it as obscured, so pages lay out fixed bottom bars
    /// (cookie banners, cart buttons, chat inputs) above the controls, not underneath.
    var bottomChromeHeight: CGFloat = 0 {
        didSet {
            guard abs(oldValue - bottomChromeHeight) > 0.5 else { return }
            applyBottomChromeInset()
        }
    }

    /// Distance from the screen's bottom edge that the minimized address strip covers
    /// while the full controls are away. Page bars stay above it rather than under it.
    var bottomStripHeight: CGFloat = 0 {
        didSet {
            guard abs(oldValue - bottomStripHeight) > 0.5 else { return }
            applyBottomChromeInset()
        }
    }

    /// Scroll room kept below the page so its end can clear the controls. Unlike the
    /// obscured height it stays put while the controls hide during scrolling, so the
    /// page doesn't jump.
    var bottomScrollInset: CGFloat = 0 {
        didSet {
            guard abs(oldValue - bottomScrollInset) > 0.5 else { return }
            applyBottomChromeInset()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyBottomChromeInset()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        applyBottomChromeInset()
    }

    private func applyBottomChromeInset() {
        // Element fullscreen reparents the web view; leave its insets alone until it returns.
        guard webView.superview === self, window != nil else { return }
        let scrollView = webView.scrollView
        let adjusted = scrollView.adjustedContentInset
        let content = scrollView.contentInset
        let bottomObscured: CGFloat
        if bottomChromeHeight > 0 {
            bottomObscured = safeAreaInsets.bottom + bottomChromeHeight
        } else {
            // Controls scrolled away: keep page bars clear of the home indicator and
            // the minimized address strip.
            bottomObscured = bottomScrollInset > 0 ? max(safeAreaInsets.bottom, bottomStripHeight) : 0
        }

        // Setting obscured insets replaces WebKit's own safe-area handling, so pass the
        // status bar / notch edges explicitly along with the bottom controls. Fixed and
        // sticky page bars then sit below the status bar, where they can be tapped, and
        // above the bottom controls.
        let obscured = UIEdgeInsets(
            top: max(safeAreaInsets.top, adjusted.top - content.top),
            left: max(safeAreaInsets.left, adjusted.left - content.left),
            bottom: bottomObscured,
            right: max(safeAreaInsets.right, adjusted.right - content.right)
        )
        if webView.obscuredContentInsets != obscured {
            webView.obscuredContentInsets = obscured
        }

        // Let the end of the page scroll clear of the controls.
        let systemBottom = adjusted.bottom - content.bottom
        let reserved = bottomScrollInset > 0 ? safeAreaInsets.bottom + bottomScrollInset : 0
        let desired = max(0, reserved - systemBottom)
        guard abs(content.bottom - desired) > 0.5 else { return }
        scrollView.contentInset.bottom = desired
        scrollView.verticalScrollIndicatorInsets.bottom = desired
    }
}

private struct BrowserWebAIRequest: Identifiable, Equatable {
    let id = UUID()
    let provider: WebAIProvider
    let title: String
    let prompt: String
    let shouldAutoCapture: Bool
    let shouldStartMinimized: Bool
    let sourceBinding: BrowserAgentPageContextBinding?
}

@MainActor
private final class BrowserWebAISessionManager {
    static let shared = BrowserWebAISessionManager()

    private var webViews: [WebAIProvider: WKWebView] = [:]

    private init() {}

    func webView(
        for provider: WebAIProvider,
        coordinator: WKNavigationDelegate & WKScriptMessageHandler,
        handlerName: String,
        bootstrapScript: String,
        forceReload: Bool = true
    ) -> WKWebView {
        if let existing = webViews[provider] {
            configure(existing, coordinator: coordinator, handlerName: handlerName, bootstrapScript: bootstrapScript)
            if forceReload || existing.url == nil {
                existing.load(URLRequest(url: provider.url))
            } else {
                existing.evaluateJavaScript(bootstrapScript, completionHandler: nil)
            }
            return existing
        }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = WebAISessionStore.dataStore(for: provider)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        configure(webView, coordinator: coordinator, handlerName: handlerName, bootstrapScript: bootstrapScript)
        webView.load(URLRequest(url: provider.url))
        webViews[provider] = webView
        return webView
    }

    func reconfigure(
        _ webView: WKWebView,
        coordinator: WKNavigationDelegate & WKScriptMessageHandler,
        handlerName: String,
        bootstrapScript: String
    ) {
        configure(webView, coordinator: coordinator, handlerName: handlerName, bootstrapScript: bootstrapScript)
    }

    func resetSession(for provider: WebAIProvider, completion: @escaping (String) -> Void) {
        if let webView = webViews.removeValue(forKey: provider) {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }

        // Only the provider's own store is cleared, so regular tabs stay signed in
        // (for Gemini, that means the rest of Google).
        Task {
            await WebAISessionStore.signOut(of: provider)
            completion("Signed out of \(provider.displayName).")
        }
    }

    func isLoggedIn(to provider: WebAIProvider, completion: @escaping (Bool) -> Void) {
        WebAISessionStore.dataStore(for: provider).httpCookieStore.getAllCookies { [weak self] cookies in
            let hasAuthenticatedCookie = cookies.contains { cookie in
                let domain = cookie.domain.lowercased()
                let name = cookie.name.lowercased()

                switch provider {
                case .chatgpt:
                    let isChatGPTDomain = provider.matchesSessionHost(domain)
                    let isSessionCookie = name.contains("session-token") || name.contains("auth-session")
                    return isChatGPTDomain && isSessionCookie
                case .gemini:
                    let isGoogleDomain = provider.matchesSessionHost(domain)
                    let authenticatedCookieNames: Set<String> = [
                        "sid", "hsid", "ssid", "apisid", "sapisid",
                        "__secure-1psid", "__secure-3psid"
                    ]
                    return isGoogleDomain && authenticatedCookieNames.contains(name)
                }
            }

            if hasAuthenticatedCookie {
                completion(true)
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    completion(false)
                    return
                }
                self.isLoggedInFromLoadedPage(to: provider, completion: completion)
            }
        }
    }

    private func isLoggedInFromLoadedPage(
        to provider: WebAIProvider,
        completion: @escaping (Bool) -> Void
    ) {
        guard let webView = webViews[provider],
              let host = webView.url?.host?.lowercased() else {
            completion(false)
            return
        }

        let script: String
        switch provider {
        case .chatgpt:
            guard provider.allowsSessionNavigation(webView.url) else {
                completion(false)
                return
            }
            script = """
            try {
                const response = await fetch('/api/auth/session', {
                    credentials: 'include',
                    cache: 'no-store'
                });
                if (response.ok) {
                    const session = await response.json();
                    if (session && (session.user || session.accessToken || session.expires)) {
                        return true;
                    }
                }
            } catch (_) {}

            const accountControl = document.querySelector(
                '[data-testid*="profile" i], button[aria-label*="profile" i], button[aria-label*="account" i]'
            );
            const loginControl = document.querySelector(
                'a[href*="/auth/login"], button[data-testid*="login" i]'
            );
            return Boolean(accountControl) && !loginControl;
            """
        case .gemini:
            guard host == "gemini.google.com" || host.hasSuffix(".google.com") else {
                completion(false)
                return
            }
            script = """
            const accountControl = document.querySelector(
                'a[aria-label*="Google Account" i], button[aria-label*="Google Account" i]'
            );
            const signInControl = document.querySelector(
                'a[href*="accounts.google.com/ServiceLogin"], a[aria-label*="Sign in" i]'
            );
            return Boolean(accountControl) && !signInControl;
            """
        }

        Task {
            do {
                let value = try await webView.callAsyncJavaScript(
                    script,
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                )
                completion((value as? NSNumber)?.boolValue ?? false)
            } catch {
                completion(false)
            }
        }
    }

    func releaseAllWebViews() {
        for (_, webView) in webViews {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeAllUserScripts()
        }
        webViews.removeAll()
    }

    private func configure(
        _ webView: WKWebView,
        coordinator: WKNavigationDelegate & WKScriptMessageHandler,
        handlerName: String,
        bootstrapScript: String
    ) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: handlerName)
        controller.removeAllUserScripts()
        controller.add(coordinator, name: handlerName)
        controller.addUserScript(
            WKUserScript(
                source: bootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        webView.navigationDelegate = coordinator
    }

}

private struct BrowserWebAIRepresentable: UIViewRepresentable {
    static let scriptMessageHandlerName = "browserWebAICapture"

    let request: BrowserWebAIRequest
    @Binding var isLoading: Bool
    @Binding var didInject: Bool
    @Binding var fallbackMessage: String?
    let onResponseCaptured: (String) -> Void
    let onCaptureFailed: (String) -> Void
    let canTransmitPageContext: (BrowserAgentPageContextBinding?) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        BrowserWebAISessionManager.shared.webView(
            for: request.provider,
            coordinator: context.coordinator,
            handlerName: Self.scriptMessageHandlerName,
            bootstrapScript: Coordinator.buildCaptureBootstrapScript(handlerName: Self.scriptMessageHandlerName),
            forceReload: false
        )
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(parent: self, webView: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var parent: BrowserWebAIRepresentable
        private var currentRequestID: UUID?
        private var injectionAttempts = 0
        private let maxAttempts = 10
        private var captureFinished = false
        private var hasPreparedCurrentRequest = false
        private var hasInjectedCurrentRequest = false
        private var expectedChunks: [String: Int] = [:]
        private var chunkBuffers: [String: [Int: String]] = [:]

        init(parent: BrowserWebAIRepresentable) {
            self.parent = parent
            self.currentRequestID = nil
        }

        func update(parent: BrowserWebAIRepresentable, webView: WKWebView) {
            let requestChanged = currentRequestID != parent.request.id
            self.parent = parent

            if requestChanged {
                currentRequestID = parent.request.id
                injectionAttempts = 0
                captureFinished = false
                hasPreparedCurrentRequest = false
                hasInjectedCurrentRequest = false
                expectedChunks.removeAll()
                chunkBuffers.removeAll()

                DispatchQueue.main.async {
                    self.parent.isLoading = true
                    self.parent.didInject = false
                    self.parent.fallbackMessage = nil
                }
            }

            guard !hasPreparedCurrentRequest else { return }
            hasPreparedCurrentRequest = true

            browserAIWebLog("update request=\(parent.request.id.uuidString.prefix(8)) provider=\(parent.request.provider.displayName) changed=\(requestChanged) origin=\(browserURLForLog(webView.url)) loading=\(webView.isLoading)")

            BrowserWebAISessionManager.shared.reconfigure(
                webView,
                coordinator: self,
                handlerName: BrowserWebAIRepresentable.scriptMessageHandlerName,
                bootstrapScript: Self.buildCaptureBootstrapScript(handlerName: BrowserWebAIRepresentable.scriptMessageHandlerName)
            )

            if isProviderPageLoading(in: webView, for: parent.request.provider) {
                browserAIWebLog("update waiting existing load request=\(parent.request.id.uuidString.prefix(8))")
                return
            }

            if canReuseCurrentPage(in: webView, for: parent.request.provider) {
                browserAIWebLog("update reusing current page request=\(parent.request.id.uuidString.prefix(8))")
                webView.evaluateJavaScript(Self.buildCaptureBootstrapScript(handlerName: BrowserWebAIRepresentable.scriptMessageHandlerName), completionHandler: nil)
                DispatchQueue.main.async {
                    self.parent.isLoading = false
                }
                armCaptureSession(in: webView)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.injectPrompt(into: webView)
                }
            } else {
                browserAIWebLog("update loading provider home request=\(parent.request.id.uuidString.prefix(8)) provider=\(parent.request.provider.displayName)")
                webView.load(URLRequest(url: parent.request.provider.url))
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            injectionAttempts = 0
            captureFinished = false
            hasInjectedCurrentRequest = false
            expectedChunks.removeAll()
            chunkBuffers.removeAll()
            browserAIWebLog("didStart request=\(parent.request.id.uuidString.prefix(8)) origin=\(browserURLForLog(webView.url))")
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.didInject = false
                self.parent.fallbackMessage = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browserAIWebLog("didFinish request=\(parent.request.id.uuidString.prefix(8)) origin=\(browserURLForLog(webView.url))")
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            guard parent.request.provider.matches(webView.url) else {
                browserAIWebLog("didFinish awaiting provider origin request=\(parent.request.id.uuidString.prefix(8))")
                return
            }
            armCaptureSession(in: webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.injectPrompt(into: webView)
            }
        }

        private func injectPrompt(into webView: WKWebView) {
            guard parent.request.provider.matches(webView.url) else {
                browserAIWebLog("inject skipped non-provider origin request=\(parent.request.id.uuidString.prefix(8))")
                return
            }
            if parent.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                browserAIWebLog("inject skipped empty prompt request=\(parent.request.id.uuidString.prefix(8))")
                hasInjectedCurrentRequest = true
                DispatchQueue.main.async {
                    self.parent.didInject = true
                    self.parent.fallbackMessage = nil
                }
                return
            }

            guard parent.canTransmitPageContext(parent.request.sourceBinding) else {
                hasInjectedCurrentRequest = true
                let message = "Page-derived content from a tab that received autofill stays out of agent context. Switch to an unfilled tab to continue."
                DispatchQueue.main.async {
                    self.parent.isLoading = false
                    self.parent.didInject = true
                    self.parent.fallbackMessage = message
                    self.parent.onCaptureFailed(message)
                }
                return
            }

            guard !hasInjectedCurrentRequest else {
                browserAIWebLog("inject skipped alreadyInjected request=\(parent.request.id.uuidString.prefix(8))")
                return
            }
            guard injectionAttempts < maxAttempts else {
                browserAIWebLog("inject failed maxAttempts request=\(parent.request.id.uuidString.prefix(8))")
                DispatchQueue.main.async {
                    self.parent.fallbackMessage = "Auto-send could not find the message box."
                }
                return
            }

            injectionAttempts += 1
            browserAIWebLog("inject attempt=\(injectionAttempts) request=\(parent.request.id.uuidString.prefix(8))")
            webView.evaluateJavaScript(buildInjectionScript()) { [weak self] result, _ in
                guard let self else { return }
                if let status = result as? String, status == "success" {
                    self.hasInjectedCurrentRequest = true
                    browserAIWebLog("inject success request=\(self.parent.request.id.uuidString.prefix(8))")
                    DispatchQueue.main.async {
                        self.parent.didInject = true
                        self.parent.fallbackMessage = nil
                    }
                    return
                }

                browserAIWebLog("inject retry request=\(self.parent.request.id.uuidString.prefix(8)) status=\((result as? String) ?? "nil")")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.injectPrompt(into: webView)
                }
            }
        }

        private func finishWithCaptureFailure() {
            captureFinished = true
            let message = "Automatic response capture timed out for \(parent.request.provider.displayName)."
            browserAIWebLog("capture failure request=\(parent.request.id.uuidString.prefix(8)) reason=timeout")
            DispatchQueue.main.async {
                self.parent.fallbackMessage = message
                self.parent.onCaptureFailed(message)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == BrowserWebAIRepresentable.scriptMessageHandlerName,
                  WebAIMessagePolicy.allows(
                    provider: parent.request.provider,
                    url: message.frameInfo.request.url ?? message.webView?.url,
                    isMainFrame: message.frameInfo.isMainFrame
                  ),
                  let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String,
                  let requestID = payload["requestId"] as? String,
                  requestID == parent.request.id.uuidString else {
                return
            }

            switch type {
            case "finalBegin":
                browserAIWebLog("bridge finalBegin request=\(requestID.prefix(8)) chunks=\(payload["totalChunks"] as? Int ?? 0)")
                expectedChunks[requestID] = payload["totalChunks"] as? Int ?? 0
                chunkBuffers[requestID] = [:]

            case "finalChunk":
                let index = payload["index"] as? Int ?? 0
                let text = payload["text"] as? String ?? ""
                if index == 0 {
                    browserAIWebLog("bridge firstChunk request=\(requestID.prefix(8)) chars=\(text.count)")
                }
                var buffer = chunkBuffers[requestID] ?? [:]
                buffer[index] = text
                chunkBuffers[requestID] = buffer

            case "finalEnd":
                guard let expected = expectedChunks[requestID],
                      let buffer = chunkBuffers[requestID],
                      buffer.count == expected else {
                    finishWithCaptureFailure()
                    return
                }

                let fullText = (0..<expected).compactMap { buffer[$0] }.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                expectedChunks[requestID] = nil
                chunkBuffers[requestID] = nil

                guard !fullText.isEmpty else {
                    finishWithCaptureFailure()
                    return
                }

                captureFinished = true
                browserAIWebLog("bridge finalEnd request=\(requestID.prefix(8)) textChars=\(fullText.count)")
                DispatchQueue.main.async {
                    self.parent.fallbackMessage = nil
                    self.parent.onResponseCaptured(fullText)
                }

            case "failed":
                let reason = (payload["message"] as? String) ?? "Automatic response capture timed out for \(parent.request.provider.displayName)."
                captureFinished = true
                browserAIWebLog("bridge failed request=\(requestID.prefix(8)) reason=\(reason)")
                DispatchQueue.main.async {
                    self.parent.fallbackMessage = reason
                    self.parent.onCaptureFailed(reason)
                }

            default:
                break
            }
        }

        private func armCaptureSession(in webView: WKWebView) {
            guard parent.request.shouldAutoCapture,
                  parent.request.provider.matches(webView.url) else { return }
            captureFinished = false
            expectedChunks.removeAll()
            chunkBuffers.removeAll()
            browserAIWebLog("armCapture request=\(parent.request.id.uuidString.prefix(8)) provider=\(parent.request.provider.displayName)")
            webView.evaluateJavaScript(buildArmCaptureScript(), completionHandler: nil)
        }

        private func canReuseCurrentPage(in webView: WKWebView, for provider: WebAIProvider) -> Bool {
            guard !webView.isLoading else { return false }
            return provider.matches(webView.url)
        }

        private func isProviderPageLoading(in webView: WKWebView, for provider: WebAIProvider) -> Bool {
            guard webView.isLoading else { return false }
            return provider.allowsSessionNavigation(webView.url)
        }

        private func buildArmCaptureScript() -> String {
            let requestID = parent.request.id.uuidString
            return """
            (function() {
                if (!window.__webAICapture || typeof window.__webAICapture.start !== "function") return "missing";
                window.__webAICapture.start({
                    requestId: "\(requestID)",
                    provider: "\(parent.request.provider.rawValue)",
                    settleMs: 1800,
                    minLength: 120,
                    maxWaitMs: 180000
                });
                return "armed";
            })();
            """
        }

        static func buildCaptureBootstrapScript(handlerName: String) -> String {
            """
            (function () {
              if (window.__webAICaptureInstalled) return;
              window.__webAICaptureInstalled = true;

              const HANDLER = "\(handlerName)";

              function post(payload) {
                try {
                  window.webkit.messageHandlers[HANDLER].postMessage(payload);
                } catch (_) {}
              }

              function normalize(value) {
                return (value || "")
                  .replace(/\\u00a0/g, " ")
                  .replace(/[ \\t]+\\n/g, "\\n")
                  .replace(/\\n{3,}/g, "\\n\\n")
                  .replace(/[ \\t]{2,}/g, " ")
                  .trim();
              }

              function uniqueNodes(nodes) {
                return Array.from(new Set(nodes.filter(Boolean)));
              }

              function cleanText(node) {
                if (!node) return "";
                return normalize(node.innerText || node.textContent || "");
              }

              function geminiResponseContainer(node) {
                if (!node) return null;
                return node.closest("response-container") || node.closest(".response-container") || node;
              }

              function assistantContainers(provider) {
                if (provider === "chatgpt") {
                  const assistantNodes = Array.from(document.querySelectorAll("[data-message-author-role='assistant']"));
                  const containers = assistantNodes.map(node =>
                    node.closest("article") || node.closest("[data-testid*='conversation-turn']") || node.parentElement || node
                  );
                  return uniqueNodes(containers);
                }

                if (provider === "gemini") {
                  const primary = Array.from(document.querySelectorAll("response-container"));
                  if (primary.length) {
                    return uniqueNodes(primary);
                  }

                  const fallbackSelectors = [
                    ".response-container-content",
                    ".presented-response-container",
                    ".model-response-text",
                    "[class*='model-response']"
                  ];
                  const mapped = fallbackSelectors.flatMap(selector =>
                    Array.from(document.querySelectorAll(selector)).map(node => geminiResponseContainer(node))
                  );
                  return uniqueNodes(mapped);
                }

                const selectors = [
                  "message-content",
                  "model-response",
                  ".model-response-text",
                  "[class*='model-response']",
                  "[data-test-id='response-content']",
                  "main .response-content",
                  "main .markdown",
                  "main article",
                  "main [role='article']",
                  "main [class*='message']",
                  "main [class*='response']"
                ];
                return uniqueNodes(selectors.flatMap(selector => Array.from(document.querySelectorAll(selector))));
              }

              function latestContainer(provider) {
                const nodes = assistantContainers(provider);
                if (!nodes.length) return null;
                return nodes[nodes.length - 1];
              }

              function latestTextBearingContainer(provider) {
                const nodes = assistantContainers(provider);
                for (let i = nodes.length - 1; i >= 0; i -= 1) {
                  if (cleanText(nodes[i])) {
                    return nodes[i];
                  }
                }
                return null;
              }

              function isStreaming(provider) {
                if (provider === "chatgpt") {
                  return Boolean(
                    document.querySelector("button[aria-label*='Stop']") ||
                    document.querySelector("button[data-testid*='stop']") ||
                    document.querySelector("[aria-busy='true']")
                  );
                }

                if (provider === "gemini") {
                  return Boolean(
                    document.querySelector("button[aria-label*='Stop response']") ||
                    document.querySelector("button[aria-label*='Stop']") ||
                    document.querySelector(".send-button.stop") ||
                    document.querySelector("[aria-busy='true']") ||
                    document.querySelector("[data-state='streaming']")
                  );
                }

                return Boolean(
                  document.querySelector("[aria-busy='true']") ||
                  document.querySelector("[data-state='streaming']")
                );
              }

              window.__webAICapture = {
                state: null,
                observer: null,
                timer: null,
                scanScheduled: false,
                scanInFlight: false,
                lastScanAt: 0,
                minScanInterval: 250,

                stop() {
                  if (this.observer) {
                    this.observer.disconnect();
                    this.observer = null;
                  }
                  if (this.timer) {
                    clearInterval(this.timer);
                    this.timer = null;
                  }
                  this.scanScheduled = false;
                  this.scanInFlight = false;
                  this.lastScanAt = 0;
                  this.state = null;
                },

                start(opts) {
                  this.stop();

                  const baselineNode = latestTextBearingContainer(opts.provider);
                  const baselineNodes = assistantContainers(opts.provider);
                  this.state = {
                    requestId: opts.requestId,
                    provider: opts.provider,
                    baselineCount: baselineNodes.length,
                    baselineText: cleanText(baselineNode),
                    lastText: "",
                    lastChangeAt: Date.now(),
                    startedAt: Date.now(),
                    progressAt: 0,
                    settleMs: opts.settleMs || 1800,
                    minLength: opts.minLength || 120,
                    maxWaitMs: opts.maxWaitMs || 180000,
                    delivered: false
                  };

                  const root = document.querySelector("main") || document.body;
                  this.observer = new MutationObserver(() => this.requestScan());
                  this.observer.observe(root, {
                    subtree: true,
                    childList: true,
                    characterData: true
                  });

                  this.timer = setInterval(() => this.requestScan(), 1200);
                  this.requestScan();
                },

                currentTarget() {
                  const s = this.state;
                  if (!s) return null;

                  const containers = assistantContainers(s.provider);
                  const latest = latestContainer(s.provider);
                  const latestText = cleanText(latest);

                  if (containers.length > s.baselineCount) {
                    if (!latest || !latestText) return null;
                    return { node: latest, text: latestText };
                  }

                  const latestTextBearing = latestTextBearingContainer(s.provider);
                  if (!latestTextBearing) return null;
                  const latestTextBearingText = cleanText(latestTextBearing);

                  if (latestTextBearingText && latestTextBearingText !== s.baselineText) {
                    return { node: latestTextBearing, text: latestTextBearingText };
                  }

                  return null;
                },

                requestScan() {
                  if (this.scanScheduled || this.scanInFlight) return;
                  const now = Date.now();
                  const waitMs = Math.max(0, this.minScanInterval - (now - this.lastScanAt));
                  this.scanScheduled = true;
                  setTimeout(() => {
                    this.scanScheduled = false;
                    this.scan();
                  }, waitMs);
                },

                scan() {
                  const s = this.state;
                  if (!s || s.delivered) return;
                  if (this.scanInFlight) return;
                  this.scanInFlight = true;
                  this.lastScanAt = Date.now();

                  const target = this.currentTarget();
                  const text = target ? target.text : "";
                  const now = Date.now();
                  const streaming = isStreaming(s.provider);

                  if (text && text !== s.lastText) {
                    s.lastText = text;
                    s.lastChangeAt = now;
                  }

                  const stable = !!s.lastText && (now - s.lastChangeAt) >= s.settleMs;
                  const hasEnoughContent = s.lastText.length >= s.minLength || /\\n\\n/.test(s.lastText);

                  if (hasEnoughContent && !streaming && stable) {
                    this.deliver("stable_complete", s.lastText);
                    this.scanInFlight = false;
                    return;
                  }

                  if ((now - s.startedAt) > s.maxWaitMs) {
                    if (s.lastText) {
                      this.deliver("timeout_partial", s.lastText);
                    } else {
                      this.fail("Automatic response capture timed out.");
                    }
                    this.scanInFlight = false;
                    return;
                  }
                  this.scanInFlight = false;
                },

                deliver(reason, text) {
                  const s = this.state;
                  if (!s || s.delivered) return;

                  s.delivered = true;
                  if (this.observer) this.observer.disconnect();
                  if (this.timer) clearInterval(this.timer);

                  const chunkSize = 12000;
                  const totalChunks = Math.max(1, Math.ceil(text.length / chunkSize));

                  post({
                    type: "finalBegin",
                    requestId: s.requestId,
                    reason: reason,
                    totalChunks: totalChunks,
                    totalLength: text.length
                  });

                  for (let i = 0; i < totalChunks; i += 1) {
                    post({
                      type: "finalChunk",
                      requestId: s.requestId,
                      index: i,
                      text: text.slice(i * chunkSize, (i + 1) * chunkSize)
                    });
                  }

                  post({
                    type: "finalEnd",
                    requestId: s.requestId
                  });
                },

                fail(message) {
                  const s = this.state;
                  if (!s || s.delivered) return;
                  s.delivered = true;
                  if (this.observer) this.observer.disconnect();
                  if (this.timer) clearInterval(this.timer);
                  post({
                    type: "failed",
                    requestId: s.requestId,
                    message: message
                  });
                }
              };
            })();
            """
        }

        private func buildInjectionScript() -> String {
            let escapedText = parent.request.prompt
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

            let provider = parent.request.provider.rawValue
            let requestID = parent.request.id.uuidString
            let shouldAutoCapture = parent.request.shouldAutoCapture ? "true" : "false"

            return """
            (function() {
                const text = "\(escapedText)";
                const provider = "\(provider)";
                const requestId = "\(requestID)";
                const shouldAutoCapture = \(shouldAutoCapture);

                function pickFirst(list) {
                    for (let i = 0; i < list.length; i += 1) {
                        if (list[i]) return list[i];
                    }
                    return null;
                }

                function findInput() {
                    if (provider === "chatgpt") {
                        return pickFirst([
                            document.getElementById("prompt-textarea"),
                            document.querySelector(".ProseMirror[contenteditable='true']"),
                            document.querySelector("[data-testid='composer-input'] [contenteditable='true']"),
                            document.querySelector("div[contenteditable='true'][data-placeholder]"),
                            document.querySelector("textarea"),
                            document.querySelector("[contenteditable='true']")
                        ]);
                    }

                    if (provider === "gemini") {
                        return pickFirst([
                            document.querySelector("rich-textarea .ql-editor[contenteditable='true']"),
                            document.querySelector("rich-textarea [contenteditable='true']"),
                            document.querySelector("textarea"),
                            document.querySelector("[contenteditable='true']")
                        ]);
                    }

                    return pickFirst([
                        document.querySelector("textarea"),
                        document.querySelector("[contenteditable='true']")
                    ]);
                }

                function setValue(el, value) {
                    if (!el) return false;
                    el.focus();

                    if (provider === "gemini") {
                        const geminiHost = el.closest("rich-textarea") || document.querySelector("rich-textarea");
                        const geminiQuill = geminiHost && geminiHost.__quill ? geminiHost.__quill : (el.parentElement && el.parentElement.__quill ? el.parentElement.__quill : null);
                        if (geminiQuill && typeof geminiQuill.setText === "function") {
                            geminiQuill.setText(value, "user");
                            if (typeof geminiQuill.setSelection === "function" && typeof geminiQuill.getLength === "function") {
                                geminiQuill.setSelection(Math.max(0, geminiQuill.getLength() - 1), 0, "silent");
                            }
                            if (typeof geminiQuill.focus === "function") {
                                geminiQuill.focus();
                            }
                            if (typeof geminiQuill.update === "function") {
                                geminiQuill.update("user");
                            }
                            return true;
                        }
                    }

                    const isProseMirror = el.classList.contains("ProseMirror") || el.querySelector("p") !== null;
                    if (isProseMirror) {
                        let p = el.querySelector("p");
                        if (!p) {
                            p = document.createElement("p");
                            el.innerHTML = "";
                            el.appendChild(p);
                        }
                        p.textContent = value;
                        el.dispatchEvent(new InputEvent("input", {
                            bubbles: true,
                            cancelable: true,
                            inputType: "insertText",
                            data: value
                        }));
                        return true;
                    }

                    if (el.tagName === "TEXTAREA" || el.tagName === "INPUT") {
                        try {
                            const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                            const nativeSetter = Object.getOwnPropertyDescriptor(proto, "value").set;
                            nativeSetter.call(el, value);
                            if (el.setSelectionRange) el.setSelectionRange(value.length, value.length);
                        } catch (error) {
                            el.value = value;
                        }
                        el.dispatchEvent(new Event("input", { bubbles: true }));
                        el.dispatchEvent(new Event("change", { bubbles: true }));
                        return true;
                    }

                    if (el.getAttribute("contenteditable") === "true") {
                        const p = document.createElement("p");
                        p.textContent = value;
                        el.innerHTML = "";
                        el.appendChild(p);
                        el.dispatchEvent(new InputEvent("input", {
                            bubbles: true,
                            cancelable: true,
                            inputType: "insertText",
                            data: value
                        }));
                        return true;
                    }

                    return false;
                }

                function dispatchEnter(el) {
                    if (!el) return;
                    el.focus();

                    const eventInit = {
                        key: "Enter",
                        code: "Enter",
                        keyCode: 13,
                        which: 13,
                        bubbles: true,
                        cancelable: true
                    };

                    ["keydown", "keypress", "keyup"].forEach(type => {
                        el.dispatchEvent(new KeyboardEvent(type, eventInit));
                    });

                    const form = el.closest("form");
                    if (form && typeof form.requestSubmit === "function") {
                        form.requestSubmit();
                    }
                }

                function nudgeGeminiComposer(el) {
                    if (provider !== "gemini" || !el) return;
                    dispatchEnter(el);
                }

                function geminiDraftText(el) {
                    if (provider !== "gemini") return "";
                    const host = (el && el.closest && el.closest("rich-textarea")) || document.querySelector("rich-textarea");
                    const quill = host && host.__quill ? host.__quill : null;
                    if (quill && typeof quill.getText === "function") {
                        return (quill.getText() || "").trim();
                    }
                    if (el && typeof el.innerText === "string") {
                        return el.innerText.trim();
                    }
                    return "";
                }

                function dispatchPress(el) {
                    if (!el) return false;
                    const base = { bubbles: true, cancelable: true, composed: true, view: window };
                    try { el.focus(); } catch (error) {}
                    try {
                        el.dispatchEvent(new PointerEvent("pointerdown", Object.assign({
                            pointerId: 1,
                            pointerType: "mouse",
                            isPrimary: true,
                            button: 0,
                            buttons: 1,
                            clientX: 1,
                            clientY: 1
                        }, base)));
                    } catch (error) {}
                    ["mousedown", "pointerup", "mouseup", "click"].forEach(type => {
                        const init = Object.assign({
                            button: 0,
                            buttons: type === "mousedown" ? 1 : 0,
                            clientX: 1,
                            clientY: 1
                        }, base);
                        try {
                            if (type.startsWith("pointer")) {
                                el.dispatchEvent(new PointerEvent(type, Object.assign({
                                    pointerId: 1,
                                    pointerType: "mouse",
                                    isPrimary: true
                                }, init)));
                            } else {
                                el.dispatchEvent(new MouseEvent(type, init));
                            }
                        } catch (error) {}
                    });
                    if (typeof el.click === "function") {
                        try {
                            el.click();
                            return true;
                        } catch (error) {}
                    }
                    return true;
                }

                function triggerGeminiSend(button, input) {
                    if (provider !== "gemini" || !button) return false;
                    if (!geminiDraftText(input)) return false;
                    const wrapper = button.parentElement;
                    let triggered = false;
                    if (wrapper) triggered = dispatchPress(wrapper) || triggered;
                    triggered = dispatchPress(button) || triggered;
                    return triggered;
                }

                function blurComposer(el) {
                    try {
                        if (el && typeof el.blur === "function") {
                            el.blur();
                        }
                        if (document.activeElement && typeof document.activeElement.blur === "function") {
                            document.activeElement.blur();
                        }
                        if (document.body && typeof document.body.focus === "function") {
                            document.body.focus();
                        }
                    } catch (error) {
                    }
                }

                function findSendButton() {
                    if (provider === "chatgpt") {
                        return pickFirst([
                            document.querySelector("button[data-testid='send-button']"),
                            document.querySelector("button[data-testid='composer-send-button']"),
                            document.querySelector("button[aria-label='Send prompt']"),
                            document.querySelector("button[aria-label='Send message']"),
                            document.querySelector("button[aria-label='Send']"),
                            document.querySelector("form button[type='submit']"),
                            document.querySelector("button[type='submit']")
                        ]);
                    }

                    return pickFirst([
                        document.querySelector("button[aria-label='Send message']"),
                        document.querySelector("button[aria-label='Send']"),
                        document.querySelector("button[type='submit']"),
                        document.querySelector("div[role='button'][aria-label*='Send']")
                    ]);
                }

                function findNewChatButton() {
                    if (provider !== "chatgpt") return null;
                    return pickFirst([
                        document.querySelector("a[href='/']"),
                        document.querySelector("a[href='/?model=auto']"),
                        document.querySelector("nav a[href='/']"),
                        document.querySelector("button[aria-label='New chat']"),
                        document.querySelector("a[aria-label='New chat']")
                    ]);
                }

                function assistantTurnCount() {
                    if (provider === "chatgpt") {
                        return document.querySelectorAll("[data-message-author-role='assistant']").length;
                    }
                    if (provider === "gemini") {
                        const primary = document.querySelectorAll("response-container");
                        if (primary.length) {
                            return primary.length;
                        }
                        const fallbackSelectors = [
                            ".response-container-content",
                            ".presented-response-container",
                            ".model-response-text",
                            "[class*='model-response']"
                        ];
                        const mapped = fallbackSelectors.flatMap(selector =>
                            Array.from(document.querySelectorAll(selector)).map(node =>
                                node.closest("response-container") || node.closest(".response-container") || node
                            )
                        );
                        return Array.from(new Set(mapped.filter(Boolean))).length;
                    }
                    return document.querySelectorAll("message-content, model-response, [class*='model-response']").length;
                }

                function sendPrompt() {
                    const input = findInput();
                    if (!input) return "retry";

                    if (provider === "chatgpt" && shouldAutoCapture && assistantTurnCount() > 0) {
                        if (window.__codexWebAILastNewChatRequestId !== requestId) {
                            window.__codexWebAILastNewChatRequestId = requestId;
                            const newChatButton = findNewChatButton();
                            if (newChatButton) {
                                newChatButton.click();
                                return "retry";
                            }
                        }
                    }

                    if (!setValue(input, text)) return "retry";

                    if (provider === "gemini") {
                        nudgeGeminiComposer(input);
                    }

                    const attemptSend = function(tries) {
                        const button = findSendButton();
                        const ariaDisabled = button && button.getAttribute ? button.getAttribute("aria-disabled") : null;
                        const isDisabled = button && (button.disabled || ariaDisabled === "true");
                        if (provider === "gemini" && triggerGeminiSend(button, input)) {
                            setTimeout(function() { blurComposer(input); }, 50);
                            return;
                        }
                        if (button && !isDisabled) {
                            button.click();
                            setTimeout(function() { blurComposer(input); }, 50);
                            return;
                        }
                        if (provider === "gemini" && tries > 0) {
                            nudgeGeminiComposer(input);
                        }
                        if (tries <= 0) {
                            dispatchEnter(input);
                            setTimeout(function() { blurComposer(input); }, 50);
                            return;
                        }
                        setTimeout(function() { attemptSend(tries - 1); }, 250);
                    };

                    const initialDelay = provider === "chatgpt" ? 800 : 500;
                    setTimeout(function() { attemptSend(40); }, initialDelay);
                    return "success";
                }

                return sendPrompt();
            })();
            """
        }
    }
}

struct ContentView: View {
    private let shareAppURLScheme = "webmebrowser"

    private struct TabRowView<RowContent: View>: View {
        @ObservedObject var tab: BrowserTab
        /// Part of the view's inputs so cards redraw when previews are shown or hidden.
        var showsPreview = true
        let content: (BrowserTab) -> RowContent

        var body: some View {
            content(tab)
        }
    }

    // MARK: - State
    @StateObject private var vm = BrowserViewModel()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var omniboxFocused: Bool
    @FocusState private var tabSearchFocused: Bool
    @AppStorage("sidebarFavoritesCollapsed") private var favoritesCollapsed = false
    /// Tab cards show their page preview unless the user collapses them to title rows.
    @AppStorage("sidebarTabPreviewsCollapsed") private var tabPreviewsCollapsed = false
    @State private var isHoldingNewTab = false
    @State private var tabGroupNamePrompt: TabGroupNamePrompt?
    @State private var tabGroupNameText = ""
    @State private var newTabHoldProgress: CGFloat = 0
    @State private var newTabHoldTimers: [DispatchWorkItem] = []
    @State private var newTabHoldFired = false
    @ScaledMetric(relativeTo: .caption) private var scaledSidebarSectionFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var scaledSidebarTitleFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var scaledSidebarSubtitleFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var scaledSidebarIconFontSize: CGFloat = 15
    @State private var tabSearchText = ""
    @State private var favoritesSheet: FavoritesSheetRequest?
    @State private var bookmarkImportMessage: String?
    @State private var favoritePendingRename: Favorite?
    @State private var favoriteRenameText = ""
    @State private var selectedTabScope: BrowserTabScope = .all
    @State private var showHistory = false
    @State private var showTabGroupManager = false
    @State private var showAIPanel = false
    @State private var isAISidebarInputFocused = false
    @State private var iPadKeyboardOverlap: CGFloat = 0
    @State private var aiHasUnreadResponse = false
    @State private var aiQuery: String = ""
    @StateObject private var aiService = SimpleAIService.shared
    @State private var splitMode: SplitMode? = nil
    @State private var splitPrimaryID: UUID?
    @State private var splitSecondaryID: UUID?
    @State private var splitSecondaryExternalTab: BrowserTab?
    @State private var lastInteractedSplitTabID: UUID?
    @State private var showWebProviderSheet = false
    @State private var aiContextTabID: UUID?
    @State private var aiContextWasPrivate = false
    @State private var lastSelectedTabID: UUID?
    @State private var isSidebarCollapsed: Bool = false
    @State private var sidebarDrag: CGFloat = 0
    private var leftSidebarBaseWidth: CGFloat {
        if isMacRuntimeForIPadBuild { return 460 }
        if isNativeIPadDevice { return 380 }
        return 320
    }
    private var aiSidebarBaseWidth: CGFloat {
        if isMacRuntimeForIPadBuild { return 448 }
        if isNativeIPadDevice { return 380 }
        return 320
    }
    private let sidebarCornerRadius: CGFloat = 22
    private let splitSpacing: CGFloat = 10
    @State private var splitVerticalRatio: CGFloat = 0.5
    @State private var splitHorizontalRatio: CGFloat = 0.5
    @State private var splitDragAxis: SplitAxis? = nil
    @State private var activeSplitDropZone: SplitDropZone?
    @State private var draggedSidebarTabID: UUID?
    @State private var sidebarTabDragLocation: CGPoint?
    private enum PhoneSecondaryPanel: Equatable {
        case none
        case tabs
        case ai
    }
    @State private var phoneSecondaryPanel: PhoneSecondaryPanel = .none
    @State private var phonePanelDragOffset: CGFloat = 0
    @State private var phonePanelHiddenForTabDrag = false
    @State private var phoneAIPanelExpanded = false
    @State private var splitDropContentRect: CGRect = .zero
    private let splitDragCoordinateSpace = "browserSplitDragSpace"
    private let splitMinRatio: CGFloat = 0.25
    private let splitMaxRatio: CGFloat = 0.75
    private let splitDividerHandleLength: CGFloat = 80
    private let splitDividerHandleThickness: CGFloat = 4
    private let splitDividerHitSize: CGFloat = 16
    @State private var isToolbarCollapsed: Bool = true
    /// Like Safari: the bottom toolbar steps away while the page scrolls and comes
    /// back as a small address strip when it stops. Tapping the strip or the page,
    /// a new page or the top of the page brings the full toolbar back.
    private enum ToolbarScrollState {
        /// Full toolbar showing and staying; page bars sit above it.
        case pinned
        /// Nothing showing while the page moves.
        case hidden
        /// Page at rest away from the top: only the address strip shows.
        case minimized
    }

    @State private var toolbarScrollState: ToolbarScrollState = .pinned

    private var isToolbarScrolledAway: Bool {
        toolbarScrollState != .pinned
    }

    /// Height of the minimized address strip and its gap above the screen's bottom edge.
    private let minimizedStripHeight: CGFloat = 32
    private let minimizedStripBottomGap: CGFloat = 8

    /// What the strip covers from the screen's bottom edge whenever the full toolbar is
    /// away, kept through scrolling as well so page bars don't bounce on every scroll.
    private var activeTabBottomStripHeight: CGFloat {
        isChromeHidden || toolbarScrollState == .pinned ? 0 : minimizedStripHeight + minimizedStripBottomGap
    }
    /// Width of the browser's content area; on iPad it changes with Split View and
    /// Stage Manager window sizes.
    @State private var layoutWidth: CGFloat = 0
    /// Full-screen browsing: the bottom controls and status bar step aside for the page.
    @State private var isChromeHidden: Bool = false
    /// Bumped when page-menu state changes outside SwiftUI (zoom, hidden items, translation).
    @State private var pageMenuRevision: Int = 0
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var pendingTranslation: PendingPageTranslation?
    @State private var pageTranslationAgentOwners: [UUID: UUID] = [:]
    @State private var pageTranslationAgentStates: [UUID: String] = [:]
    /// The tab whose per-site protection panel is open.
    @State private var sitePrivacyTabID: UUID?
    /// The tab whose page is in "tap items to hide" mode.
    @State private var distractionPickerTabID: UUID?
    @State private var pageStatusMessage: String?
    @State private var pageStatusClearTask: Task<Void, Never>?
    /// True while page text sits behind the bottom toolbar; the toolbar frosts then.
    @State private var toolbarOverText: Bool = false
    private let toolbarPillHeight: CGFloat = 44
    // New service states
    @StateObject private var adBlockService = AdBlockService.shared
    @StateObject private var passwordManager = PasswordManager.shared
    @StateObject private var incognitoMode = IncognitoMode.shared
    @StateObject private var darkModeService = DarkModeService.shared
    @StateObject private var fontSizeService = FontSizeService.shared
    @StateObject private var thirdPartyCookieBlocker = ThirdPartyCookieBlocker.shared
    @StateObject private var downloadManager = BrowserDownloadManager()
    @State private var showFontSizeSettings = false
    @State private var showSettingsMenu = false
    @AppStorage("pinTabSidebar") private var pinTabSidebar = false
    @AppStorage("pinAISidebar") private var pinAISidebar = false
    @State private var showFilterListSettings = false
    @AppStorage("requestDesktopSite") private var requestDesktopSite: Bool = false
    @State private var pendingAISelection: AISelection?
    @State private var pendingAIReplacement: AIReplacement?
    @State private var aiSelectionContext: AISelectionContext?
    @State private var pendingWebProviderPrompt: String?
    @State private var pendingWebProviderProvider: WebAIProvider?
    @State private var pendingWebProviderTargetID: UUID?
    @State private var pendingWebProviderContextOverride: String?
    @State private var pendingRedditPreflight: PendingRedditPreflightTask?
    @State private var lastPrimaryURLString: String?
    @State private var webProviderContextTabID: UUID?
    @State private var webProviderContextURLString: String?
    @State private var aiPageContentCache: [UUID: AICachedPageContent] = [:]
    @State private var pendingAIQueryTask: Task<Void, Never>?
    @State private var pendingAIQueryToken = UUID()
    @State private var activeWebAIRequest: BrowserWebAIRequest?
    @State private var activeWebAIServiceRequestID: UUID?
    @State private var isWebAIOverlayExpanded = false
    @State private var isWebAIOverlayMinimized = false
    @State private var webAIIsLoading = true
    @State private var webAIDidInject = false
    @State private var webAIFallbackMessage: String?
    @State private var webAISettingsStatusMessage: String?
    @State private var isChatGPTLoggedIn = false
    @State private var isGeminiLoggedIn = false
    @State private var pendingWebAILoginProvider: WebAIProvider?
    // MLX Local settings
    @AppStorage("mlxModelID") private var mlxModelID: String = MLXLocalSettings.defaultModelID
    @AppStorage("mlxMaxOutputTokens") private var mlxMaxOutputTokens: Int = MLXLocalSettings.defaultMaxOutputTokens
    @AppStorage("mlxMaxContextTokens") private var mlxMaxContextTokens: Int = MLXLocalSettings.defaultMaxContextTokens
    @State private var isLoadingMLXModel: Bool = false
    @State private var mlxDownloadProgress: Progress? = nil
    @State private var mlxLoadError: String? = nil
    @State private var mlxWarmupTask: Task<Void, Never>? = nil
    @State private var mlxDownloadTask: Task<Void, Never>? = nil
    private let webProviderContextMaxChars = 80000
    private var redditWebProviderContextMaxChars: Int {
        min(
            webProviderContextMaxChars,
            RedditSummaryPlanner.characterBudget(for: .webChatGPT)
        )
    }

    private struct AICachedPageContent {
        let urlKey: String
        let binding: BrowserAgentPageContextBinding
        let content: PageContentExtractor.ExtractedPageContent
    }

    // Share Extension handling
    @StateObject private var darwinObserver = DarwinNotificationObserver()
    @StateObject private var agentTaskObserver = AgentTaskDarwinNotificationObserver()
    @State private var sharedURLRetryCount = 0
    @State private var isAgentSidebarReady = false
    @State private var isAgentSidebarBusy = false
    @State private var isAgentBackendSupported = false
    @State private var windowAgentTaskQueue: [PendingAgentTask] = []
    @State private var stagedAgentTask: PendingAgentTask?
    @State private var stagedAgentTaskContext: AgentTaskPreparedContext?
    @State private var agentTaskStartup: AgentTaskNavigationAttempt?
    @State private var agentTaskStartupTimeout: Task<Void, Never>?
    @State private var agentTaskStartupGeneration = UUID()
    @State private var agentTaskDocumentRevisions: [ObjectIdentifier: Int] = [:]
    @State private var agentTaskLastFinishedNavigationIDs: [ObjectIdentifier: ObjectIdentifier] = [:]
    @State private var agentTaskReadyWebViews: Set<ObjectIdentifier> = []
    @State private var agentTaskQueueStatusMessage: String?
    @State private var agentRunDetailRequest: AgentRunDetailRequest?
    @State private var agentWatchOpenRequest: AgentWatchOpenRequest?
    @State private var pageWatchDraft: PageWatchDraft?
    @State private var lastAgentBackendStatusShown: String?
    @StateObject private var browserIntentRuntime = BrowserIntentRuntime.shared
    @State private var browserIntentWindowID = UUID()
    @Environment(\.scenePhase) private var scenePhase

    private var isMacRuntimeForIPadBuild: Bool {
#if targetEnvironment(macCatalyst)
        return true
#elseif os(iOS)
        if #available(iOS 14.0, *) {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                return true
            }
            return UIDevice.current.userInterfaceIdiom == .mac
        }
        return false
#else
        return false
#endif
    }

    private var agentTaskSidebarForegroundReady: Bool {
        scenePhase == .active
            && showAIPanel
            && isAgentSidebarReady
            && (!isPhone || (phoneSecondaryPanel == .ai && !phonePanelHiddenForTabDrag))
    }

    private var isNativeIPadDevice: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad && !isMacRuntimeForIPadBuild
#else
        false
#endif
    }

    private func activeKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                $0.activationState == .foregroundActive
                    || $0.activationState == .foregroundInactive
            }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private func keyboardAnimationDuration(from notification: Notification) -> Double {
        guard let value = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber else {
            return 0.25
        }
        let duration = value.doubleValue
        return duration > 0 ? duration : 0.25
    }

    private func updateIPadKeyboardOverlap(from notification: Notification) {
        guard isNativeIPadDevice,
              showAIPanel,
              let window = activeKeyWindow(),
              let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
            return
        }

        let keyboardFrameInWindow = window.screen.coordinateSpace.convert(
            frameValue.cgRectValue,
            to: window.coordinateSpace
        )
        let overlap = max(0, window.bounds.intersection(keyboardFrameInWindow).height)
        let duration = keyboardAnimationDuration(from: notification)

        withAnimation(.easeInOut(duration: duration)) {
            iPadKeyboardOverlap = overlap
        }
    }

    private func resetIPadKeyboardOverlap(from notification: Notification) {
        guard isNativeIPadDevice else { return }
        let duration = keyboardAnimationDuration(from: notification)
        withAnimation(.easeInOut(duration: duration)) {
            iPadKeyboardOverlap = 0
        }
    }

    private var currentSidebarWidth: CGFloat {
        if isSidebarCollapsed {
            return max(0, min(leftSidebarBaseWidth, sidebarDrag))
        } else {
            return max(0, min(leftSidebarBaseWidth, leftSidebarBaseWidth + sidebarDrag))
        }
    }

    /// How far in from each edge the open iPad side panels reach (the wider side wins,
    /// so the bottom toolbar stays centered).
    private var toolbarPanelInset: CGFloat {
        guard !isPhone else { return 0 }
        let panelInset: CGFloat = 24
        let gap: CGFloat = 8
        let leading = currentSidebarWidth > 1 ? panelInset + currentSidebarWidth + gap : 0
        let trailing = showAIPanel ? panelInset + aiSidebarBaseWidth + gap : 0
        return max(leading, trailing)
    }

    /// Wide iPad windows: the toolbar narrows into the gap between the side panels.
    private var toolbarFitsBetweenPanels: Bool {
        let minimumBarWidth: CGFloat = 340
        return toolbarPanelInset > 0 && layoutWidth - toolbarPanelInset * 2 >= minimumBarWidth
    }

    private var toolbarSideInset: CGFloat {
        toolbarFitsBetweenPanels ? toolbarPanelInset : 0
    }

    /// Narrower iPad windows (half-screen Split View): the gap is too small for the
    /// toolbar, so it keeps its full size and the side panels end above it instead.
    private var sidePanelsClearToolbar: Bool {
        toolbarPanelInset > 0 && !toolbarFitsBetweenPanels
    }

    private var isSidebarDark: Bool {
        colorScheme == .dark || darkModeService.isDarkMode
    }

    /// The device's own light/dark setting. Settings panels follow this rather than
    /// "Dark Web Pages", which only darkens websites and made the panels dark on
    /// light pages.
    private var systemColorScheme: ColorScheme {
        let style = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.traitCollection.userInterfaceStyle }
            .first ?? .unspecified
        return style == .dark ? .dark : .light
    }

    private var isNativeTouchDevice: Bool {
#if os(iOS)
        !isMacRuntimeForIPadBuild
#else
        false
#endif
    }

    private var sidebarSectionFontSize: CGFloat {
        isNativeTouchDevice ? scaledSidebarSectionFontSize : 12
    }

    private var sidebarTitleFontSize: CGFloat {
        isNativeTouchDevice ? scaledSidebarTitleFontSize : 14
    }

    private var sidebarSubtitleFontSize: CGFloat {
        isNativeTouchDevice ? scaledSidebarSubtitleFontSize : 12
    }

    private var sidebarIconFontSize: CGFloat {
        isNativeTouchDevice ? scaledSidebarIconFontSize : 14
    }

    private var sidebarPrimaryText: Color {
        isSidebarDark ? Color.white : Color.black
    }

    private var sidebarSecondaryText: Color {
        isSidebarDark ? Color.white.opacity(0.8) : Color.black.opacity(0.6)
    }

    private var sidebarToggleForeground: Color {
        isSidebarDark ? Color.white.opacity(0.85) : Color.black.opacity(0.65)
    }

    private var sidebarRowBackground: Color {
        isSidebarDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }


    private var sidebarRowSelectedBackground: Color {
        isSidebarDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
    }

    private var sidebarIconBackground: Color {
        isSidebarDark ? Color.white.opacity(0.12) : Color.black.opacity(0.1)
    }

    private var sidebarBackground: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            LinearGradient(
                colors: isSidebarDark
                    ? [Color.white.opacity(0.18), Color.white.opacity(0.04)]
                    : [Color.white.opacity(0.6), Color(UIColor.systemGray6).opacity(0.9)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(isSidebarDark ? 0.15 : 0.35)
        }
    }

    private var sidebarToggleButton: some View {
        Button {
            if isPhone {
                togglePhoneSecondaryPanel(.tabs)
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    isSidebarCollapsed.toggle()
                    sidebarDrag = 0
                }
            }
        } label: {
            Image(systemName: isPhone
                ? (phoneSecondaryPanel == .tabs ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                : (isSidebarCollapsed ? "chevron.right" : "chevron.left"))
                .font(.footnote.weight(.semibold))
                .foregroundColor(sidebarToggleForeground)
                .padding(.horizontal, 12)
                .frame(height: toolbarPillHeight)
                .toolbarBackdrop(in: Capsule(), frosted: toolbarOverText)
                .shadow(
                    color: Color.black.opacity(isSidebarDark ? 0.35 : 0.2),
                    radius: 8,
                    x: 0,
                    y: 4
                )
                .contentShape(.interaction, Capsule())
        }
        .buttonStyle(.plain)
        .ios26ButtonHitTargetCompat()
        .accessibilityLabel(isPhone
            ? (phoneSecondaryPanel == .tabs ? "Hide tabs" : "Show tabs")
            : (isSidebarCollapsed ? "Show sidebar" : "Hide sidebar"))
    }

    private var aiSidebarToggleButton: some View {
        Button {
            if isPhone {
                togglePhoneSecondaryPanel(.ai)
            } else if showAIPanel {
                dismissAIPanel()
            } else {
                syncAIContextSelection(forceVisibleTab: true)
                prepareAIContext()
                withAnimation(.easeOut(duration: 0.2)) {
                    showAIPanel = true
                }
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.footnote.weight(.semibold))
                .foregroundColor(isSidebarDark ? .white.opacity(0.85) : .primary)
                .padding(.horizontal, 12)
                .frame(height: toolbarPillHeight)
                .toolbarBackdrop(in: Capsule(), frosted: toolbarOverText)
                .shadow(
                    color: Color.black.opacity(isSidebarDark ? 0.35 : 0.2),
                    radius: 8,
                    x: 0,
                    y: 4
                )
                .contentShape(.interaction, Capsule())
        }
        .buttonStyle(.plain)
        .ios26ButtonHitTargetCompat()
        .accessibilityLabel(isPhone
            ? (phoneSecondaryPanel == .ai ? "Hide AI assistant" : "Show AI assistant")
            : (showAIPanel ? "Hide AI sidebar" : "Show AI sidebar"))
    }

    private var exitSplitViewButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                endSplitPair()
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: splitMode == .horizontal ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.red)
                    .offset(x: 5, y: -5)
            }
            .foregroundColor(isSidebarDark ? .white.opacity(0.85) : .primary)
            .padding(.horizontal, 12)
            .frame(height: toolbarPillHeight)
            .toolbarBackdrop(in: Capsule(), frosted: toolbarOverText)
            .shadow(
                color: Color.black.opacity(isSidebarDark ? 0.35 : 0.2),
                radius: 8,
                x: 0,
                y: 4
            )
        }
        .buttonStyle(.plain)
        .ios26PhoneButtonHitTargetCompat()
        .accessibilityLabel("Exit split view")
        .accessibilityHint("Keeps both tabs open")
    }

    private func expandToolbar(focusOmnibox: Bool) {
        withAnimation(.easeOut(duration: 0.15)) {
            isToolbarCollapsed = false
        }
        if focusOmnibox {
            omniboxFocused = true
        }
    }

    /// Frosts the bottom toolbar only while page text sits behind it. Samples
    /// points across the toolbar's area and asks WebKit whether a glyph is there.
    /// Runs when the toolbar reappears (scroll end), after loads and on tab switch;
    /// the toolbar is hidden while scrolling, so it never needs to track frames.
    private func refreshToolbarBackdrop() {
        guard splitMode == nil,
              let idx = vm.selectedIndex,
              !vm.tabs[idx].isBlank,
              let webView = vm.tabs[idx].liveWebView else {
            toolbarOverText = false
            return
        }
        let size = webView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let bottomInset = webView.window?.safeAreaInsets.bottom ?? 0
        let centerY = size.height - bottomInset - 24 - toolbarPillHeight / 2
        let halfWidth = min(260, size.width / 2 - 16)
        let xs = stride(from: -1.0, through: 1.0, by: 1.0 / 3).map { size.width / 2 + halfWidth * $0 }
        let script = """
        const k = window.innerWidth / width;
        function textAt(x, y) {
            const caret = document.caretRangeFromPoint(x, y);
            const node = caret && caret.startContainer;
            if (!node || node.nodeType !== Node.TEXT_NODE || !node.textContent.trim()) return false;
            const offset = Math.min(caret.startOffset, node.length - 1);
            if (offset < 0) return false;
            const glyph = document.createRange();
            glyph.setStart(node, offset);
            glyph.setEnd(node, offset + 1);
            const box = glyph.getBoundingClientRect();
            return x >= box.left - 4 && x <= box.right + 4 && y >= box.top - 4 && y <= box.bottom + 4;
        }
        let hits = 0;
        for (const x of xs) {
            for (const dy of [-12, 0, 12]) {
                if (textAt(x * k, (y + dy) * k)) hits++;
            }
        }
        return hits;
        """
        let tabID = vm.tabs[idx].id
        webView.callAsyncJavaScript(
            script,
            arguments: ["xs": xs, "y": centerY, "width": size.width],
            in: nil,
            in: .defaultClient
        ) { result in
            guard vm.selectedTabID == tabID else { return }
            let hits = ((try? result.get()) as? NSNumber)?.intValue ?? 0
            toolbarOverText = hits >= 2
        }
    }

    private func collapseToolbar() {
        withAnimation(.easeOut(duration: 0.15)) {
            isToolbarCollapsed = true
            omniboxFocused = false
        }
    }

    /// Room the collapsed bottom controls take above the safe area, plus a small gap
    /// so a page's own bottom bar doesn't sit flush against them.
    /// Page bars move above the toolbar only while it's pinned, so they don't bounce
    /// up and down with every scroll.
    private var activeTabBottomChromeHeight: CGFloat {
        isChromeHidden || toolbarScrollState != .pinned ? 0 : activeTabBottomScrollInset
    }

    private var activeTabBottomScrollInset: CGFloat {
        isChromeHidden ? 0 : 24 + toolbarPillHeight + 6
    }

    private func handleToolbarScrollEvent(_ event: ToolbarScrollEvent) {
        switch event {
        case .scrollBegan:
            setToolbarScrollState(.hidden)
        case .scrollEnded(let atTop):
            setToolbarScrollState(atTop ? .pinned : .minimized)
        case .pin:
            setToolbarScrollState(.pinned)
        }
    }

    private func setToolbarScrollState(_ state: ToolbarScrollState) {
        guard toolbarScrollState != state else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            toolbarScrollState = state
        }
        if state == .pinned {
            refreshToolbarBackdrop()
            // Showing the bar changes the page's bottom spacing, which can move what sits
            // under it; check again once that has settled so the frost matches the page.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard toolbarScrollState == .pinned else { return }
                refreshToolbarBackdrop()
            }
        }
    }

    private func setChromeHidden(_ hidden: Bool) {
        if hidden {
            omniboxFocused = false
        }
        withAnimation(.easeOut(duration: 0.2)) {
            isChromeHidden = hidden
            if hidden {
                isToolbarCollapsed = true
            }
        }
        if !hidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                refreshToolbarBackdrop()
            }
        }
    }

    /// Safari-style address strip shown while the page rests with the toolbar away.
    /// It sits in the home-indicator band; tapping it brings the full toolbar back.
    private func minimizedAddressStrip(for tab: BrowserTab) -> some View {
        Button {
            setToolbarScrollState(.pinned)
        } label: {
            MinimizedAddressLabel(tab: tab)
                .font(.footnote.weight(.semibold))
                .foregroundColor(isSidebarDark ? .white : .primary)
                .padding(.horizontal, 14)
                .frame(maxWidth: isPhone ? 220 : 280)
                .frame(height: minimizedStripHeight)
                .toolbarBackdrop(in: Capsule(), frosted: true)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .environment(\.colorScheme, isSidebarDark ? .dark : .light)
        .accessibilityLabel("Show toolbar")
        .accessibilityValue(tab.currentURL?.host() ?? "")
    }

    private var showToolbarHandle: some View {
        Button {
            setChromeHidden(false)
        } label: {
            Image(systemName: "chevron.compact.up")
                .font(.title3.weight(.semibold))
                .foregroundColor(isSidebarDark ? .white.opacity(0.85) : .primary)
                .frame(width: 64, height: 26)
                .toolbarBackdrop(in: Capsule(), frosted: toolbarOverText)
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, isSidebarDark ? .dark : .light)
        .accessibilityLabel("Show toolbar")
    }

    @ViewBuilder
    private func pageActionsMenuItems(for tab: BrowserTab) -> some View {
        let _ = pageMenuRevision
        Button {
            presentShareSheet(for: tab)
        } label: {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
        .disabled(tab.currentURL == nil)

        if !tab.isBlank, tab.liveWebView != nil {
            let zoom = PageZoomStore.zoom(for: tab.currentURL, isIncognito: tab.isIncognito)
            ControlGroup {
                Button {
                    stepPageZoom(-1, for: tab)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .disabled(!PageZoomStore.canZoomOut(zoom))
                Button {
                    stepPageZoom(0, for: tab)
                } label: {
                    Label("\(Int((zoom * 100).rounded()))%", systemImage: "textformat.size")
                }
                .accessibilityLabel("Reset zoom")
                Button {
                    stepPageZoom(1, for: tab)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .disabled(!PageZoomStore.canZoomIn(zoom))
            }

            if tab.translatedFrom != nil {
                Button {
                    showOriginalPage(for: tab)
                } label: {
                    Label("Show Original", systemImage: "translate")
                }
            } else {
                Button {
                    startPageTranslation(for: tab)
                } label: {
                    Label(
                        tab.isTranslating
                            ? "Translating…"
                            : "Translate to \(PageTranslator.displayName(for: PageTranslator.targetLanguage))",
                        systemImage: "translate"
                    )
                }
                .disabled(tab.isTranslating)
            }

            Button {
                startDistractionPicker(for: tab)
            } label: {
                Label("Hide Distracting Items", systemImage: "eye.slash")
            }
            if DistractionHider.hasHiddenItems(for: tab.currentURL, isIncognito: tab.isIncognito) {
                Button {
                    DistractionHider.showHiddenItems(in: tab.activateWebView(), isIncognito: tab.isIncognito)
                    pageMenuRevision &+= 1
                    showPageStatus("Hidden items are back")
                } label: {
                    Label("Show Hidden Items", systemImage: "eye")
                }
            }
        }

        if !tab.isBlank, tab.liveWebView != nil {
            Button {
                collapseToolbar()
                sitePrivacyTabID = tab.id
            } label: {
                Label("Site Protection…", systemImage: "shield.lefthalf.filled")
            }
        }

        // Private tabs and non-web pages can never be watched.
        if !tab.isIncognito, !tab.isBlank, tab.liveWebView != nil,
           let pageURL = tab.currentURL, PageWatch.isWebURL(pageURL) {
            Button {
                collapseToolbar()
                pageWatchDraft = PageWatchDraft(
                    url: pageURL,
                    title: tab.title.isEmpty ? (pageURL.host ?? pageURL.absoluteString) : tab.title
                )
            } label: {
                Label("Watch This Page…", systemImage: "eye")
            }
        }

        Button {
            setChromeHidden(true)
        } label: {
            Label("Hide Toolbar", systemImage: "arrow.up.left.and.arrow.down.right")
        }
    }

    // MARK: - Page translation

    private struct PendingPageTranslation {
        let tabID: UUID
        let plan: PageTranslator.Plan
        let agentOwnerID: UUID?
        let shouldContinue: (() -> Bool)?
    }

    private enum PageTranslationActionError: LocalizedError {
        case alreadyRunning
        case noActivePage

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "A translation is already in progress for this tab."
            case .noActivePage: return "This tab has no active webpage to translate."
            }
        }
    }

    private func browserTab(withID id: UUID) -> BrowserTab? {
        vm.tabs.first { $0.id == id }
    }

    private func startPageTranslation(
        for tab: BrowserTab,
        targetLanguage: Locale.Language? = nil,
        agentRunIsCurrent: (() -> Bool)? = nil,
        onPrepared: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard !tab.isTranslating, let webView = tab.liveWebView else {
            if let onPrepared {
                onPrepared(.failure(tab.isTranslating ? PageTranslationActionError.alreadyRunning : PageTranslationActionError.noActivePage))
            }
            return
        }
        let agentOwnerID = agentRunIsCurrent == nil ? nil : UUID()
        if let agentOwnerID {
            pageTranslationAgentOwners[tab.id] = agentOwnerID
            pageTranslationAgentStates[tab.id] = "preparing"
        }
        collapseToolbar()
        tab.isTranslating = true
        pageMenuRevision &+= 1
        showPageStatus("Translating…", autoHide: false)
        Task {
            do {
                let plan = try await PageTranslator.prepare(in: webView, targetLanguage: targetLanguage)
                guard tab.isTranslating else {
                    if let agentOwnerID, pageTranslationAgentOwners[tab.id] == agentOwnerID {
                        pageTranslationAgentStates[tab.id] = "cancelled"
                        pageTranslationAgentOwners.removeValue(forKey: tab.id)
                    }
                    onPrepared?(.failure(CancellationError()))
                    return
                }
                if let agentOwnerID,
                   pageTranslationAgentOwners[tab.id] != agentOwnerID || agentRunIsCurrent?() == false {
                    cancelOwnedAgentTranslation(tab: tab, ownerID: agentOwnerID)
                    onPrepared?(.failure(CancellationError()))
                    return
                }
                if let agentOwnerID, browserTab(withID: tab.id) !== tab {
                    cancelOwnedAgentTranslation(tab: tab, ownerID: agentOwnerID)
                    onPrepared?(.failure(CancellationError()))
                    return
                }
                pendingTranslation = PendingPageTranslation(
                    tabID: tab.id,
                    plan: plan,
                    agentOwnerID: agentOwnerID,
                    shouldContinue: agentRunIsCurrent
                )
                if agentOwnerID != nil { pageTranslationAgentStates[tab.id] = "waiting for the system language download or approval" }
                var configuration = TranslationSession.Configuration(
                    source: plan.source,
                    target: plan.target
                )
                if #available(iOS 26.4, *), plan.lowLatencyInstalled {
                    // Whole pages are hundreds of strings; the fast model keeps them
                    // flowing in while people read.
                    configuration = TranslationSession.Configuration(
                        source: plan.source,
                        target: plan.target,
                        preferredStrategy: .lowLatency
                    )
                }
                if var current = translationConfiguration, current == configuration {
                    current.invalidate()
                    translationConfiguration = current
                } else {
                    translationConfiguration = configuration
                }
                onPrepared?(.success(()))
            } catch {
                if let agentOwnerID {
                    guard pageTranslationAgentOwners[tab.id] == agentOwnerID,
                          agentRunIsCurrent?() != false else {
                        cancelOwnedAgentTranslation(tab: tab, ownerID: agentOwnerID)
                        onPrepared?(.failure(CancellationError()))
                        return
                    }
                    pageTranslationAgentStates[tab.id] = "failed: \(agentTranslationError(error))"
                    pageTranslationAgentOwners.removeValue(forKey: tab.id)
                }
                tab.isTranslating = false
                pageMenuRevision &+= 1
                switch error {
                case PageTranslator.PreparationError.alreadyInTargetLanguage(let name):
                    showPageStatus("This page is already in \(name)")
                case PageTranslator.PreparationError.unsupported(let from, let to):
                    showPageStatus("Translating \(from) to \(to) isn't available")
                default:
                    showPageStatus("There's no text to translate")
                }
                let message = agentOwnerID == nil ? error.localizedDescription : agentTranslationError(error)
                onPrepared?(.failure(NSError(domain: "BrowserAgentTranslation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
            }
        }
    }

    private func cancelOwnedAgentTranslation(tab: BrowserTab, ownerID: UUID) {
        guard pageTranslationAgentOwners[tab.id] == ownerID else { return }
        if pendingTranslation?.agentOwnerID == ownerID { pendingTranslation = nil }
        pageTranslationAgentOwners.removeValue(forKey: tab.id)
        pageTranslationAgentStates[tab.id] = "cancelled"
        if tab.translatedFrom == nil { tab.isTranslating = false }
        pageMenuRevision &+= 1
    }

    private func agentTranslationError(_ error: Error) -> String {
        guard let error = error as? PageTranslator.PreparationError else {
            return error.localizedDescription
        }
        switch error {
        case PageTranslator.PreparationError.noText:
            return "There is no readable text to translate."
        case PageTranslator.PreparationError.alreadyInTargetLanguage(let name):
            return "The page is already in \(name)."
        case PageTranslator.PreparationError.unsupported(let from, let to):
            return "Translation from \(from) to \(to) is unavailable."
        default:
            return error.localizedDescription
        }
    }

    /// Runs inside `.translationTask`, which owns the session and shows the system
    /// prompt to download languages when needed.
    private func runPageTranslation(with session: TranslationSession) async {
        guard let pending = pendingTranslation,
              let tab = browserTab(withID: pending.tabID),
              let webView = tab.liveWebView else { return }
        pendingTranslation = nil
        if let ownerID = pending.agentOwnerID,
           pageTranslationAgentOwners[tab.id] != ownerID || pending.shouldContinue?() == false {
            cancelOwnedAgentTranslation(tab: tab, ownerID: ownerID)
            return
        }
        do {
            // Languages that aren't on the device yet: iOS asks before downloading.
            if !(await session.isReady) {
                if let ownerID = pending.agentOwnerID, pending.shouldContinue?() == false {
                    cancelOwnedAgentTranslation(tab: tab, ownerID: ownerID)
                    return
                }
                showPageStatus("Waiting for \(pending.plan.sourceName) to download…", autoHide: false)
                try await session.prepareTranslation()
                if let ownerID = pending.agentOwnerID,
                   pageTranslationAgentOwners[tab.id] != ownerID || pending.shouldContinue?() == false {
                    cancelOwnedAgentTranslation(tab: tab, ownerID: ownerID)
                    return
                }
                guard tab.isTranslating else { return }
                showPageStatus("Translating…", autoHide: false)
            }
            if pending.agentOwnerID != nil { pageTranslationAgentStates[tab.id] = "translating" }
            let finished = try await PageTranslator.translate(
                pending.plan.segments,
                with: session,
                in: webView,
                progress: { fraction in
                    guard tab.isTranslating else { return }
                    pageStatusMessage = "Translating… \(Int(fraction * 100))%"
                },
                onScreenTranslated: {
                    // What the reader can see is done; the rest of the page keeps
                    // translating quietly below.
                    guard tab.isTranslating else { return }
                    tab.isTranslating = false
                    tab.translatedFrom = pending.plan.sourceName
                    if pending.agentOwnerID != nil { pageTranslationAgentStates[tab.id] = "translated from \(pending.plan.sourceName)" }
                    pageMenuRevision &+= 1
                    showPageStatus("Translated from \(pending.plan.sourceName)")
                },
                shouldContinue: {
                    (pending.shouldContinue?() ?? true) && (tab.isTranslating || tab.translatedFrom != nil)
                }
            )
            guard finished else {
                if let ownerID = pending.agentOwnerID, pending.shouldContinue?() == false {
                    cancelOwnedAgentTranslation(tab: tab, ownerID: ownerID)
                }
                return
            }

            // Keep up with text the page adds later, until the page changes or
            // someone asks for the original.
            while tab.translatedFrom != nil {
                try await Task.sleep(for: .seconds(1.5))
                guard tab.translatedFrom != nil else { break }
                guard pending.shouldContinue?() ?? true else { break }
                let fresh = await PageTranslator.collectNewSegments(in: webView)
                if !fresh.isEmpty {
                    _ = try await PageTranslator.translate(
                        fresh,
                        with: session,
                        in: webView,
                        shouldContinue: { (pending.shouldContinue?() ?? true) && tab.translatedFrom != nil }
                    )
                }
            }
            if let ownerID = pending.agentOwnerID, pageTranslationAgentOwners[tab.id] == ownerID {
                pageTranslationAgentOwners.removeValue(forKey: tab.id)
            }
        } catch is CancellationError {
            if let ownerID = pending.agentOwnerID {
                cancelOwnedAgentTranslation(tab: tab, ownerID: ownerID)
            }
            if tab.isTranslating {
                tab.isTranslating = false
                pageMenuRevision &+= 1
                dismissPageStatus()
            }
        } catch {
            if pending.agentOwnerID != nil {
                pageTranslationAgentStates[tab.id] = "failed: \(agentTranslationError(error))"
                pageTranslationAgentOwners.removeValue(forKey: tab.id)
            }
            guard tab.isTranslating else { return }
            tab.isTranslating = false
            pageMenuRevision &+= 1
            showPageStatus("Couldn't translate this page")
        }
    }

    private func showOriginalPage(for tab: BrowserTab) {
        collapseToolbar()
        pageTranslationAgentOwners.removeValue(forKey: tab.id)
        pageTranslationAgentStates[tab.id] = "idle"
        tab.translatedFrom = nil
        tab.isTranslating = false
        if let webView = tab.liveWebView {
            PageTranslator.restoreOriginal(in: webView)
        }
        pageMenuRevision &+= 1
    }

    // MARK: - Hide distracting items

    private func startDistractionPicker(for tab: BrowserTab) {
        guard let webView = tab.liveWebView else { return }
        collapseToolbar()
        withAnimation(.easeOut(duration: 0.2)) {
            distractionPickerTabID = tab.id
        }
        DistractionHider.startPicking(in: webView)
    }

    private func finishDistractionPicker(save: Bool = true) {
        guard let tabID = distractionPickerTabID else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            distractionPickerTabID = nil
        }
        guard let tab = browserTab(withID: tabID), let webView = tab.liveWebView else { return }
        Task {
            await DistractionHider.finishPicking(in: webView, isIncognito: tab.isIncognito, save: save)
            pageMenuRevision &+= 1
        }
    }

    private func distractionPickerBar(for tab: BrowserTab) -> some View {
        HStack(spacing: 12) {
            Text("Tap items to hide")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.leading, 6)
            Button {
                if let webView = tab.liveWebView {
                    DistractionHider.undoLastPick(in: webView)
                }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .accessibilityLabel("Undo")
            Button {
                finishDistractionPicker()
            } label: {
                Text("Done")
                    .font(.subheadline.weight(.bold))
            }
        }
        .foregroundColor(isSidebarDark ? .white : .primary)
        .padding(.horizontal, 16)
        .frame(height: toolbarPillHeight)
        // Solid material rather than glass: glass takes its tone from the page behind
        // it, which left white labels on a light capsule over bright pages.
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: BrowserDesign.Shadow.controlRadius, y: 4)
        .environment(\.colorScheme, isSidebarDark ? .dark : .light)
    }

    // MARK: - Page status

    private func showPageStatus(_ message: String, autoHide: Bool = true) {
        pageStatusClearTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            pageStatusMessage = message
        }
        guard autoHide else { return }
        pageStatusClearTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            dismissPageStatus()
        }
    }

    private func dismissPageStatus() {
        withAnimation(.easeOut(duration: 0.2)) {
            pageStatusMessage = nil
        }
    }

    private var pageStatusCapsule: some View {
        HStack(spacing: 8) {
            if pageStatusMessage?.hasPrefix("Translating") == true
                || pageStatusMessage?.hasPrefix("Waiting for") == true {
                ProgressView()
                    .controlSize(.small)
            }
            if pageStatusMessage?.hasPrefix("Private tab") == true {
                Image(systemName: "eye.slash")
                    .font(.subheadline.weight(.semibold))
            }
            Text(pageStatusMessage ?? "")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundColor(isSidebarDark ? .white : .primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: BrowserDesign.Shadow.controlRadius, y: 4)
        .environment(\.colorScheme, isSidebarDark ? .dark : .light)
        .allowsHitTesting(false)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The page menu as the first control inside the collapsed address pill.
    private func inlinePageMenuButton(for tab: BrowserTab) -> some View {
        Menu {
            pageActionsMenuItems(for: tab)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 32, height: toolbarPillHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page options")
    }

    private func pageActionsMenu(for tab: BrowserTab) -> some View {
        Menu {
            pageActionsMenuItems(for: tab)
        } label: {
            // The tap area lives on the label: a frame added outside a Menu doesn't widen
            // what it responds to, so only the three dots were tappable.
            Image(systemName: "ellipsis")
                .foregroundColor(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page options")
    }

    private func stepPageZoom(_ direction: Int, for tab: BrowserTab) {
        PageZoomStore.step(direction, webView: tab.activateWebView(), isIncognito: tab.isIncognito)
        pageMenuRevision &+= 1
    }

    private func presentShareSheet(for tab: BrowserTab) {
        guard let url = tab.currentURL,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }

        var items: [Any] = [url]
        // With the com.apple.developer.web-browser entitlement, iOS adds
        // "Add to Home Screen" when the share sheet is handed the web view itself.
        if let webView = tab.liveWebView,
           let scheme = webView.url?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            items.append(webView)
        }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            let bounds = presenter.view.bounds
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.maxY - 90, width: 1, height: 1)
            popover.permittedArrowDirections = .down
        }
        presenter.present(controller, animated: true)
    }

    private func preserveIOS26PhoneOmniboxFocusAfterClear() {
        if #available(iOS 27.0, *) {
            return
        }
        guard isPhone else { return }
        DispatchQueue.main.async {
            omniboxFocused = true
        }
    }

    private var phoneSecondaryPanelIsVisible: Bool {
        isPhone
            && phoneSecondaryPanel != .none
            && !phonePanelHiddenForTabDrag
    }

    private var phoneSecondaryPanelIsPresented: Bool {
        isPhone && phoneSecondaryPanel != .none
    }

    private func togglePhoneSecondaryPanel(_ panel: PhoneSecondaryPanel) {
        guard isPhone else { return }

        if phoneSecondaryPanel == panel {
            dismissPhoneSecondaryPanel()
            return
        }

        if phoneSecondaryPanel == .ai {
            resignPhonePanelInput()
        }

        if panel == .ai {
            syncAIContextSelection(forceVisibleTab: true)
            prepareAIContext()
            showAIPanel = true
            phoneAIPanelExpanded = phoneAIPanelExpanded || aiService.isProcessing || !aiService.messages.isEmpty
        }

        collapseToolbar()
        withAnimation(.easeOut(duration: 0.22)) {
            phoneSecondaryPanel = panel
            phonePanelDragOffset = 0
            phonePanelHiddenForTabDrag = false
        }
    }

    private func dismissPhoneSecondaryPanel() {
        guard isPhone else { return }
        resignPhonePanelInput()
        withAnimation(.easeOut(duration: 0.22)) {
            phoneSecondaryPanel = .none
            phonePanelDragOffset = 0
            phonePanelHiddenForTabDrag = false
        }
    }

    private func resignPhonePanelInput() {
        guard isPhone else { return }
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func phonePanelDismissGrabber(
        for panel: PhoneSecondaryPanel,
        panelHeight: CGFloat
    ) -> some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 42, height: 5)
        }
        .frame(width: 100, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(panel == .ai ? "Drag to dismiss AI assistant" : "Drag to dismiss tabs")
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .local)
                .onChanged { value in
                    guard phoneSecondaryPanel == panel else { return }
                    phonePanelDragOffset = max(0, min(panelHeight, value.translation.height))
                }
                .onEnded { value in
                    guard phoneSecondaryPanel == panel else { return }
                    let dismissThreshold = max(80, panelHeight * 0.12)
                    if value.translation.height > dismissThreshold {
                        dismissPhoneSecondaryPanel()
                    } else {
                        withAnimation(.easeOut(duration: 0.16)) {
                            phonePanelDragOffset = 0
                        }
                    }
                }
        )
    }

    private func isPrimarilyRightwardPhoneSwipe(_ translation: CGSize) -> Bool {
        guard translation.width > 0 else { return false }
        return translation.width > abs(translation.height) * 1.25
    }

    private func phonePanelHorizontalDismissGesture(
        for panel: PhoneSecondaryPanel
    ) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onEnded { value in
                guard isPhone,
                      phoneSecondaryPanel == panel,
                      isPrimarilyRightwardPhoneSwipe(value.translation) else {
                    return
                }

                let horizontalTravel = max(
                    value.translation.width,
                    value.predictedEndTranslation.width
                )
                guard horizontalTravel >= 48 else { return }
                dismissPhoneSecondaryPanel()
            }
    }

    private func phonePanelEdgeDismissTarget(
        for panel: PhoneSecondaryPanel
    ) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 36)
                .contentShape(Rectangle())
                .gesture(phonePanelHorizontalDismissGesture(for: panel))
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private func toolbarCollapsedPill(for tab: BrowserTab) -> some View {
        // Phone widths are tight: toggles + pill must fit a 402pt screen with margins.
        HStack(spacing: isPhone ? 4 : 8) {
            inlinePageMenuButton(for: tab)

            ToolbarHistoryNavigationButton(tab: tab, direction: .back)
            ToolbarHistoryNavigationButton(tab: tab, direction: .forward, hidesWhenUnavailable: isPhone)

            ToolbarAddressButton(
                tab: tab,
                // The address shares the room the site-protection shield used to have
                // with the page menu, which now sits in the pill on every device.
                maxWidth: isPhone ? (splitMode == nil ? 124 : 76) : 228,
                maxWidthWithoutForward: isPhone ? (splitMode == nil ? 172 : 124) : nil,
                hugsContent: !isPhone
            ) {
                expandToolbar(focusOmnibox: true)
            }
        }
        .font(.subheadline.weight(.semibold))
        .dynamicTypeSize(...DynamicTypeSize.large)
        .foregroundColor(isSidebarDark ? .white : .primary)
        .padding(.horizontal, isPhone ? 10 : 12)
        .frame(height: toolbarPillHeight)
        .overlay(alignment: .bottom) {
            ToolbarLoadingProgressBar(tab: tab)
                .padding(.horizontal, 18)
        }
        .toolbarBackdrop(in: Capsule(), frosted: toolbarOverText)
        .shadow(radius: BrowserDesign.Shadow.controlRadius, y: 4)
    }

    private var splitPrimaryTab: BrowserTab? {
        guard let id = splitPrimaryID else { return nil }
        return vm.tabs.first(where: { $0.id == id })
    }

    private var splitSecondaryTab: BrowserTab? {
        if let external = splitSecondaryExternalTab {
            return external
        }
        guard let id = splitSecondaryID else { return nil }
        return vm.tabs.first(where: { $0.id == id })
    }

    private var activeWebProviderTab: BrowserTab? {
        guard let external = splitSecondaryExternalTab,
              external.webAIProvider != nil else { return nil }
        return external
    }

    private var aiContextOptions: [AISidebar.ContextOption] {
        var tabs = vm.tabs
        if let external = splitSecondaryExternalTab,
           external.webAIProvider == nil,
           !tabs.contains(where: { $0.id == external.id }) {
            tabs.append(external)
        }
        let filtered = tabs.filter { $0.webAIProvider == nil }
        return filtered.map { aiContextOption(for: $0) }
    }

    private var activeAIContextTab: BrowserTab? {
        if let id = aiContextTabID,
           let tab = vm.tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let id = aiContextTabID,
           let external = splitSecondaryExternalTab,
           external.id == id {
            return external
        }
        if let idx = vm.selectedIndex {
            return vm.tabs[idx]
        }
        return nil
    }

    private var activeAISelectionText: String? {
        guard let tab = activeAIContextTab,
              pageContextIsAllowed(for: tab) else { return nil }
        return selectionContextText(for: tab.id).map { BrowserAgentAutofillPrivacy.shared.redactKnownValues($0) }
    }

    private var activeAIContextStatusText: String? {
        guard let tab = activeAIContextTab,
              let url = tab.currentURL,
              PageContentExtractor.isRedditURL(url),
              let entry = cachedAIPageContentEntry(for: tab) else { return nil }

        if let coverage = entry.content.redditCoverage {
            return coverage.statusText
        }
        if let commentCount = entry.content.redditCommentCount {
            let commentLabel = commentCount == 1 ? "comment" : "comments"
            return "Reddit thread context loaded: post + \(commentCount) \(commentLabel)"
        }
        return "Reddit post context loaded"
    }

    private func selectionContextText(for tabID: UUID?) -> String? {
        guard let tabID,
              let context = aiSelectionContext,
              context.tabID == tabID else { return nil }
        let trimmed = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : BrowserAgentAutofillPrivacy.shared.redactKnownValues(trimmed)
    }

    private var mlxAvailable: Bool {
        MLXLocalService.isAvailable()
    }

    private var isCompactWidth: Bool {
        horizontalSizeClass == .compact
    }

    /// Phone layout: on iPhone, and on iPad whenever the window is compact width
    /// (Slide Over, narrow Split View, small Stage Manager windows), where the
    /// side-panel layout has no room.
    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
            || (isNativeIPadDevice && horizontalSizeClass == .compact)
    }

    private enum SplitMode {
        case vertical
        case horizontal
    }

    private enum SplitAxis {
        case vertical
        case horizontal
    }

    private enum SplitDropZone: Equatable {
        case left
        case right
        case top
        case bottom

        var mode: SplitMode {
            switch self {
            case .left, .right:
                return .vertical
            case .top, .bottom:
                return .horizontal
            }
        }

        var isLeading: Bool {
            switch self {
            case .left, .top:
                return true
            case .right, .bottom:
                return false
            }
        }

        var title: String {
            switch self {
            case .left: return "Split left"
            case .right: return "Split right"
            case .top: return "Split top"
            case .bottom: return "Split bottom"
            }
        }

        var systemImage: String {
            switch self {
            case .left: return "arrow.left"
            case .right: return "arrow.right"
            case .top: return "arrow.up"
            case .bottom: return "arrow.down"
            }
        }
    }

    private struct AIReplacement {
        let tabID: UUID
        let markerID: String
    }

    private struct AISelection {
        let tabID: UUID
        let markerID: String
        let text: String
    }

    private struct AISelectionContext {
        let tabID: UUID
        let text: String
    }

    private enum PendingRedditTask {
        case summary(content: String, length: SummaryLength, sourceTab: BrowserTab, sourceBinding: BrowserAgentPageContextBinding?)
        case query(prompt: String, content: String, sourceTab: BrowserTab, sourceBinding: BrowserAgentPageContextBinding?)

        var sourceTabID: UUID {
            switch self {
            case .summary(_, _, let sourceTab, _), .query(_, _, let sourceTab, _):
                return sourceTab.id
            }
        }
    }

    private struct PendingRedditPreflightTask: Identifiable {
        let id = UUID()
        let task: PendingRedditTask
        let chunkCount: Int

        var sourceTabID: UUID { task.sourceTabID }
    }

    private enum RedditPreflightChoice: CaseIterable, Hashable {
        case cloud
        case chatGPT
        case gemini
        case local

        var title: String {
            switch self {
            case .cloud:
                return "Private Cloud Compute"
            case .chatGPT:
                return "ChatGPT (free account)"
            case .gemini:
                return "Gemini (free account)"
            case .local:
                return "Continue with Apple Local"
            }
        }

        var backend: AIModelBackend {
            switch self {
            case .cloud:
                return .cloudShortcuts
            case .chatGPT:
                return .webChatGPT
            case .gemini:
                return .webGemini
            case .local:
                return .localApple
            }
        }
    }

    private struct LargeRedditThreadOverlay: View {
        let chunkCount: Int
        let onChoice: (RedditPreflightChoice) -> Void

        @Environment(\.colorScheme) private var colorScheme

        private var isDark: Bool {
            colorScheme == .dark
        }

        var body: some View {
            GeometryReader { proxy in
                let availableWidth = max(0, proxy.size.width - 32)
                let panelWidth = min(500, availableWidth)

                ZStack {
                    Color.black
                        .opacity(isDark ? 0.42 : 0.24)
                        .ignoresSafeArea()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Large Reddit Thread")
                                .font(.title2.weight(.bold))
                                .fixedSize(horizontal: false, vertical: true)

                            Text("This thread exceeds Apple Local’s single-pass 7K-token window, requires approximately \(chunkCount) processing parts, and may be slow.")
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(spacing: 10) {
                                ForEach(RedditPreflightChoice.allCases, id: \.self) { choice in
                                    Button {
                                        onChoice(choice)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Text(choice.title)
                                                .font(.body.weight(.semibold))
                                                .multilineTextAlignment(.leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 8)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .accessibilityHidden(true)
                                        }
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .glassEffectCompat(
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                            material: .ultraThinMaterial,
                                            strokeOpacity: isDark ? 0.16 : 0.28,
                                            isInteractive: true
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(choice.title)
                                }
                            }
                            .glassEffectContainerCompat(spacing: 10)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffectCompat(
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                            material: .regularMaterial,
                            strokeOpacity: isDark ? 0.18 : 0.32,
                            isInteractive: false
                        )
                    }
                    .frame(width: panelWidth)
                    .frame(maxHeight: proxy.size.height - 32)
                    .scrollIndicators(.hidden)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .ignoresSafeArea()
            .accessibilityAddTraits(.isModal)
        }
    }

    private struct WebAILoginWarningOverlay: View {
        let provider: WebAIProvider
        let onCancel: () -> Void
        let onContinue: () -> Void

        @Environment(\.colorScheme) private var colorScheme

        private var isDark: Bool {
            colorScheme == .dark
        }

        private var continueTitle: String {
            "Continue to \(provider.displayName)"
        }

        var body: some View {
            GeometryReader { proxy in
                let availableWidth = max(0, proxy.size.width - 32)
                let panelWidth = min(520, availableWidth)
                let panelHeight = max(0, proxy.size.height - 32)

                ZStack {
                    Color.black
                        .opacity(isDark ? 0.48 : 0.28)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { }

                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("IMPORTANT")
                                .font(.title2.weight(.bold))
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Do not use your main ChatGPT or Gemini account. Create a free new account just to use with this app. The providers may terminate access at any time. These model options are optional and come with no guarantees.")
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(.primary)

                            VStack(spacing: 10) {
                                Button(action: onCancel) {
                                    Text("Cancel")
                                        .font(.body.weight(.semibold))
                                        .multilineTextAlignment(.center)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .glassEffectCompat(
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                            material: .ultraThinMaterial,
                                            strokeOpacity: isDark ? 0.16 : 0.28,
                                            isInteractive: true
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Cancel")

                                Button(action: onContinue) {
                                    Text(continueTitle)
                                        .font(.body.weight(.semibold))
                                        .multilineTextAlignment(.center)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .glassEffectCompat(
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                            material: .ultraThinMaterial,
                                            strokeOpacity: isDark ? 0.16 : 0.28,
                                            isInteractive: true
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(continueTitle)
                            }
                            .glassEffectContainerCompat(spacing: 10)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffectCompat(
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                            material: .regularMaterial,
                            strokeOpacity: isDark ? 0.18 : 0.32,
                            isInteractive: false
                        )
                    }
                    .frame(width: panelWidth)
                    .frame(maxHeight: panelHeight)
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.hidden)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .ignoresSafeArea()
            .accessibilityAddTraits(.isModal)
        }
    }

    private var hibernationProtectedTabIDs: Set<UUID> {
        Set([vm.selectedTabID, splitPrimaryID, splitSecondaryID, aiContextTabID].compactMap { $0 })
    }

    private func refreshHibernationProtection() {
        vm.updateProtectedTabIDs(hibernationProtectedTabIDs)
    }


    var body: some View {
        mainLayout
            .sheet(isPresented: $showHistory) {
                HistoryView(viewModel: vm) { url in
                    if let tab = selectedTab {
                        vm.navigate(to: url, in: tab)
                    }
                }
            }
            .sheet(item: $downloadManager.presentedExport) { export in
                BrowserDocumentExportSheet(fileURL: export.fileURL) { exported in
                    downloadManager.finishExport(id: export.id, exported: exported)
                }
            }
            .sheet(isPresented: $showTabGroupManager) {
                TabGroupManagerSheet(viewModel: vm)
            }
            .sheet(item: $favoritesSheet) { request in
                FavoritesView(viewModel: vm, startFolderID: request.folderID) { favorite in
                    vm.openFavoriteInNewTab(favorite)
                }
            }
            .alert(
                "Import Bookmarks",
                isPresented: Binding(
                    get: { bookmarkImportMessage != nil },
                    set: { if !$0 { bookmarkImportMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
                if !vm.favoriteFolders.isEmpty {
                    Button("Show Favorites") {
                        favoritesSheet = FavoritesSheetRequest(folderID: nil)
                    }
                }
            } message: {
                Text(bookmarkImportMessage ?? "")
            }
            .alert(
                "Rename Favorite",
                isPresented: Binding(
                    get: { favoritePendingRename != nil },
                    set: { if !$0 { favoritePendingRename = nil } }
                )
            ) {
                TextField("Name", text: $favoriteRenameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let favoritePendingRename {
                        vm.renameFavorite(favoritePendingRename, to: favoriteRenameText)
                    }
                    favoritePendingRename = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    vm.saveSession()
                } else {
                    vm.activateSelectedTab()
                    vm.enforceWebViewBudget()
                }
            }
            .onChange(of: vm.selectedTabID) { _, _ in
                refreshHibernationProtection()
                vm.activateSelectedTab()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    refreshToolbarBackdrop()
                }
            }
            .onChange(of: splitPrimaryID) { _, _ in
                refreshHibernationProtection()
            }
            .onChange(of: splitMode) { _, mode in
                guard let mode, splitSecondaryExternalTab == nil,
                      let primaryID = splitPrimaryID, let secondaryID = splitSecondaryID,
                      vm.splitPair(containing: primaryID)?.partner(of: primaryID) == secondaryID else { return }
                vm.setSplitPair(primaryID: primaryID, secondaryID: secondaryID, isHorizontal: mode == .horizontal)
            }
            .onChange(of: splitSecondaryID) { _, _ in
                refreshHibernationProtection()
            }
            .onChange(of: vm.tabGroups) { _, groups in
                if case .group(let id) = selectedTabScope,
                   !groups.contains(where: { $0.id == id }) {
                    selectedTabScope = .all
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillChangeFrameNotification
                )
            ) { notification in
                updateIPadKeyboardOverlap(from: notification)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillHideNotification
                )
            ) { notification in
                resetIPadKeyboardOverlap(from: notification)
            }
            .overlay {
                keyboardCommandButtons
            }
    }

    private var keyboardCommandButtons: some View {
        Group {
            Button("New Tab") {
                vm.addTabBlank()
                expandToolbar(focusOmnibox: true)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("New Incognito Tab") {
                openIncognitoTab()
                expandToolbar(focusOmnibox: true)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Close Tab") {
                if let index = vm.selectedIndex {
                    performClose(vm.tabs[index])
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("Reopen Closed Tab") {
                if let record = vm.recentlyClosedTabs.first {
                    vm.reopenRecentlyClosed(record)
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("Show History") {
                showHistory = true
            }
            .keyboardShortcut("y", modifiers: .command)

            Button("Focus Address Bar") {
                expandToolbar(focusOmnibox: true)
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Search Tabs") {
                focusTabSearch()
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Go Back") {
                selectedTab?.navigateBack()
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("Go Forward") {
                selectedTab?.navigateForward()
            }
            .keyboardShortcut("]", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0.001)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func largeRedditThreadOverlay(for pending: PendingRedditPreflightTask) -> some View {
        LargeRedditThreadOverlay(chunkCount: pending.chunkCount) { choice in
            handleRedditPreflightChoice(choice)
        }
    }

    @MainActor
    private func makeRedditPreflightTask(
        _ task: PendingRedditTask
    ) -> PendingRedditPreflightTask? {
        guard aiService.backend == .localApple else { return nil }

        let content: String
        switch task {
        case .summary(let summaryContent, _, _, _):
            content = summaryContent
        case .query(_, let queryContent, _, _):
            content = queryContent
        }

        guard RedditSummaryPlanner.requiresAppleLocalMultiPassPreflight(
            content: content,
            backend: aiService.backend
        ) else {
            return nil
        }

        let plan = RedditSummaryPlanner.plan(content: content, backend: aiService.backend)
        return PendingRedditPreflightTask(task: task, chunkCount: plan.chunkCount)
    }

    /// Dispatches a fully resolved summary. The callback from AISidebar calls
    /// this before enqueuing so an oversized Apple Local Reddit source can ask
    /// for a provider choice without extracting the page a second time.
    @MainActor
    @discardableResult
    private func dispatchResolvedSummary(
        content: String,
        length: SummaryLength,
        sourceTab: BrowserTab,
        sourceBinding: BrowserAgentPageContextBinding? = nil
    ) -> Bool {
        guard let safeContent = safePageText(content, for: sourceTab, capturedBinding: sourceBinding) else {
            reportBlockedPageContext()
            return true
        }
        let task = PendingRedditTask.summary(
            content: safeContent,
            length: length,
            sourceTab: sourceTab,
            sourceBinding: sourceBinding ?? pageContextBinding(for: sourceTab)
        )
        if let pending = makeRedditPreflightTask(task) {
            pendingRedditPreflight = pending
            return true
        }
        aiService.enqueueSummary(safeContent, length: length)
        return true
    }

    @MainActor
    private func dispatchResolvedQuery(
        prompt: String,
        content: String?,
        sourceTab: BrowserTab,
        reusingStoredSourceContext: Bool = false,
        sourceBinding: BrowserAgentPageContextBinding? = nil
    ) {
        guard pageContextIsAllowed(for: sourceTab, capturedBinding: sourceBinding) else {
            reportBlockedPageContext()
            return
        }
        if let content {
            guard let safeContent = safePageText(content, for: sourceTab, capturedBinding: sourceBinding) else {
                reportBlockedPageContext()
                return
            }
            if reusingStoredSourceContext && !RedditSummaryPlanner.isRedditContext(content) {
                aiService.replaceSourcePageContextForPrivacy(
                    BrowserAgentAutofillPrivacy.shared.redactPotentiallyTruncated(
                        aiService.sourcePageContextText ?? safeContent,
                        wasTruncated: true
                    )
                )
                aiService.enqueueQuery(prompt, pageContent: nil)
                return
            }
            let task = PendingRedditTask.query(
                prompt: prompt,
                content: safeContent,
                sourceTab: sourceTab,
                sourceBinding: sourceBinding ?? pageContextBinding(for: sourceTab)
            )
            if let pending = makeRedditPreflightTask(task) {
                pendingRedditPreflight = pending
                return
            }
            aiService.enqueueQuery(prompt, pageContent: safeContent)
            return
        }

        // A nil context intentionally preserves the existing follow-up path,
        // where SimpleAIService reuses its stored source context.
        if let stored = aiService.sourcePageContextText {
            aiService.replaceSourcePageContextForPrivacy(
                BrowserAgentAutofillPrivacy.shared.redactPotentiallyTruncated(stored, wasTruncated: true)
            )
        }
        aiService.enqueueQuery(prompt, pageContent: nil)
    }

    @MainActor
    private func handleRedditPreflightChoice(_ choice: RedditPreflightChoice) {
        guard let pending = pendingRedditPreflight else { return }
        pendingRedditPreflight = nil
        aiService.backend = choice.backend
        dispatchPendingRedditTask(pending, backend: choice.backend)
    }

    @MainActor
    private func dispatchPendingRedditTask(
        _ pending: PendingRedditPreflightTask,
        backend: AIModelBackend
    ) {
        switch pending.task {
        case .summary(let rawContent, let length, let sourceTab, let sourceBinding):
            guard pageContextIsAllowed(for: sourceTab, capturedBinding: sourceBinding) else {
                reportBlockedPageContext()
                return
            }
            let content = BrowserAgentAutofillPrivacy.shared.redactPotentiallyTruncated(rawContent, wasTruncated: true)
            guard backend == .webChatGPT || backend == .webGemini else {
                aiService.enqueueSummary(content, length: length)
                return
            }
            let prompt = length == .short
                ? "Provide a brief 2-paragraph summary of the following text. First paragraph: main topic. Second paragraph: key points. Be concise:"
                : "Summarize the following text clearly, highlighting key themes and points. Provide a detailed analysis:"
            let safeContent = RedditSummaryPlanner.webSafeContext(
                content: content,
                maxCharacters: redditWebProviderContextMaxChars
            )
            let composedPrompt = "\(safeContent)\n\nUser prompt:\n\(prompt)"
            startCapturedWebAIRequest(
                provider: backend == .webChatGPT ? .chatgpt : .gemini,
                userPrompt: prompt,
                composedPrompt: composedPrompt,
                sourceTab: sourceTab,
                sourceBinding: sourceBinding
            )

        case .query(let rawPrompt, let rawContent, let sourceTab, let sourceBinding):
            guard pageContextIsAllowed(for: sourceTab, capturedBinding: sourceBinding) else {
                reportBlockedPageContext()
                return
            }
            let privacy = BrowserAgentAutofillPrivacy.shared
            let prompt = privacy.redactPotentiallyTruncated(rawPrompt, wasTruncated: true)
            let content = privacy.redactPotentiallyTruncated(rawContent, wasTruncated: true)
            guard backend == .webChatGPT || backend == .webGemini else {
                aiService.enqueueQuery(prompt, pageContent: content)
                return
            }
            let safeContent = RedditSummaryPlanner.webSafeContext(
                content: content,
                maxCharacters: redditWebProviderContextMaxChars
            )
            let composedPrompt = "\(safeContent)\n\nUser prompt:\n\(prompt)"
            startCapturedWebAIRequest(
                provider: backend == .webChatGPT ? .chatgpt : .gemini,
                userPrompt: prompt,
                composedPrompt: composedPrompt,
                sourceTab: sourceTab,
                sourceBinding: sourceBinding
            )
        }
    }

    private var selectedTab: BrowserTab? {
        guard let index = vm.selectedIndex else { return nil }
        return vm.tabs[index]
    }

    private func phoneSecondaryPanels(in proxy: GeometryProxy) -> some View {
        let sheetWidth = max(0, proxy.size.width - BrowserDesign.Phone.panelHorizontalInset)
        let availableHeight = max(0, proxy.size.height - 8)
        let tabsHeight = min(
            availableHeight,
            max(BrowserDesign.Phone.tabsPanelMinHeight, proxy.size.height * BrowserDesign.Phone.tabsPanelHeightFraction)
        )
        let aiHeight = phoneAIPanelExpanded
            ? min(availableHeight, max(BrowserDesign.Phone.aiPanelExpandedMinHeight, proxy.size.height - 18))
            : min(
                availableHeight,
                max(BrowserDesign.Phone.aiPanelMinHeight, proxy.size.height * BrowserDesign.Phone.aiPanelHeightFraction)
            )
        let tabsVisible = phoneSecondaryPanel == .tabs && !phonePanelHiddenForTabDrag
        let aiVisible = phoneSecondaryPanel == .ai && !phonePanelHiddenForTabDrag
        let panelOffset = phonePanelDragOffset

        return ZStack(alignment: .bottom) {
            if phoneSecondaryPanelIsVisible {
                // Behind the tabs sheet the page turns to frosted glass; the AI panel keeps the light dim.
                ZStack {
                    if phoneSecondaryPanel == .tabs {
                        // A see-through glass, not a heavy frost: the material is faded so the page shows.
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .opacity(0.85)
                        Color.black.opacity(isSidebarDark ? 0.06 : 0.02)
                    } else {
                        Color.black.opacity(isSidebarDark ? 0.12 : 0.06)
                    }
                }
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissPhoneSecondaryPanel()
                    }
                    .transition(.opacity)
                    .zIndex(0)
            }

            phoneSidebarPanel
                .frame(width: sheetWidth, height: tabsHeight)
                .overlay(alignment: .top) {
                    phonePanelDismissGrabber(for: .tabs, panelHeight: tabsHeight)
                        .padding(.top, 2)
                }
                .offset(y: tabsVisible ? panelOffset : availableHeight + 40)
                .opacity(tabsVisible ? 1 : 0)
                // Keep the row gesture alive while the sheet moves offscreen
                // for a tab-to-split drag.
                .allowsHitTesting(phoneSecondaryPanel == .tabs)
                .accessibilityHidden(!tabsVisible)
                .accessibilityAddTraits(tabsVisible ? .isModal : [])
                .accessibilityAction(.escape) { dismissPhoneSecondaryPanel() }
                .zIndex(phoneSecondaryPanel == .tabs ? 2 : 1)

            phoneAISidebarPanel
                .frame(width: sheetWidth, height: aiHeight)
                .overlay(alignment: .top) {
                    phonePanelDismissGrabber(for: .ai, panelHeight: aiHeight)
                        .padding(.top, 2)
                }
                .offset(y: aiVisible ? panelOffset : availableHeight + 40)
                .opacity(aiVisible ? 1 : 0)
                .allowsHitTesting(phoneSecondaryPanel == .ai)
                .accessibilityHidden(!aiVisible)
                .accessibilityAddTraits(aiVisible ? .isModal : [])
                .accessibilityAction(.escape) { dismissPhoneSecondaryPanel() }
                .zIndex(phoneSecondaryPanel == .ai ? 2 : 1)

            if phoneSecondaryPanelIsVisible {
                phonePanelEdgeDismissTarget(for: phoneSecondaryPanel)
                    .zIndex(4)
            }
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .animation(.easeOut(duration: 0.22), value: phoneSecondaryPanel)
        .animation(.easeOut(duration: 0.22), value: phonePanelHiddenForTabDrag)
        .animation(.easeOut(duration: 0.22), value: phoneAIPanelExpanded)
    }

    @ViewBuilder
    private var mainLayout: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let verticalInset = max(24, min(72, proxy.size.height * 0.08))
                let horizontalInset: CGFloat = 24
                let aiSidebarKeyboardOverlap = isNativeIPadDevice
                    && showAIPanel
                    && isAISidebarInputFocused
                    ? min(
                        max(0, iPadKeyboardOverlap),
                        max(0, proxy.size.height - verticalInset * 2)
                    )
                    : 0
                let leadingDropInset = currentSidebarWidth > 1
                    ? horizontalInset + currentSidebarWidth + splitSpacing
                    : 0
                let trailingDropInset = showAIPanel
                    ? horizontalInset + aiSidebarBaseWidth + splitSpacing
                    : 0
                let splitDropRect = isPhone
                    ? CGRect(origin: .zero, size: proxy.size)
                    : CGRect(
                        x: leadingDropInset,
                        y: 0,
                        width: max(0, proxy.size.width - leadingDropInset - trailingDropInset),
                        height: proxy.size.height
                    )

                ZStack {
                    activeContentPanel
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .overlay {
                            if !isPhone {
                                splitDropPreviewOverlay(contentRect: splitDropRect)
                            }
                        }
                        .simultaneousGesture(
                            TapGesture()
                                .onEnded {
                                    if showSettingsMenu {
                                        showSettingsMenu = false
                                    }
                                    if isPhone {
                                        if phoneSecondaryPanel != .none {
                                            dismissPhoneSecondaryPanel()
                                        }
                                        return
                                    }
                                    if !isSidebarCollapsed && !pinTabSidebar {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            isSidebarCollapsed = true
                                            sidebarDrag = 0
                                        }
                                    }
                                    if showAIPanel && !pinAISidebar {
                                        dismissAIPanel()
                                    }
                                }
                        )

                    if isPhone {
                        phoneSecondaryPanels(in: proxy)
                    } else {
                        let panelBottomInset = sidePanelsClearToolbar
                            ? max(verticalInset, 24 + toolbarPillHeight + 12)
                            : verticalInset

                        // Left sidebar
                        HStack {
                            sidebarPanel
                                .frame(height: proxy.size.height - verticalInset - panelBottomInset, alignment: .top)
                                .padding(.leading, horizontalInset)
                                .padding(.top, verticalInset)
                                .padding(.bottom, panelBottomInset)
                            Spacer()
                        }

                        // Right AI sidebar
                        HStack {
                            Spacer()
                            aiSidebarPanel
                                .frame(
                                    height: proxy.size.height
                                        - verticalInset
                                        - panelBottomInset
                                        - aiSidebarKeyboardOverlap,
                                    alignment: .top
                                )
                                .padding(.trailing, horizontalInset)
                                .padding(.top, verticalInset)
                                .padding(.bottom, panelBottomInset)
                                .padding(.bottom, aiSidebarKeyboardOverlap)
                                .offset(x: showAIPanel ? 0 : aiSidebarBaseWidth + horizontalInset * 2)
                                .opacity(showAIPanel ? 1 : 0)
                                .allowsHitTesting(showAIPanel)
                                .accessibilityHidden(!showAIPanel)
                        }
                    }

                    if isPhone {
                        splitDropPreviewOverlay(contentRect: splitDropRect)
                            .zIndex(90)
                    }

                    if let draggedSidebarTabID,
                       let dragLocation = sidebarTabDragLocation,
                       let draggedTab = vm.tabs.first(where: { $0.id == draggedSidebarTabID }) {
                        sidebarTabDragPreview(draggedTab)
                            .position(dragLocation)
                            .allowsHitTesting(false)
                            .zIndex(100)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .coordinateSpace(name: splitDragCoordinateSpace)
                .onAppear {
                    splitDropContentRect = splitDropRect
                    layoutWidth = proxy.size.width
                }
                .onChange(of: splitDropRect) { _, newRect in
                    splitDropContentRect = newRect
                }
                .onChange(of: proxy.size.width) { _, width in
                    layoutWidth = width
                }
            }
            .ignoresSafeArea(
                .keyboard,
                edges: isPhone && phoneSecondaryPanel == .ai ? Edge.Set() : .all
            )

            // Toolbar - outside GeometryReader for proper keyboard avoidance
            if let idx = vm.selectedIndex {
                if distractionPickerTabID == vm.tabs[idx].id {
                    distractionPickerBar(for: vm.tabs[idx])
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if isChromeHidden && isToolbarCollapsed {
                    if !isPhone || !phoneSecondaryPanelIsPresented {
                        showToolbarHandle
                            .padding(.bottom, 6)
                            .opacity(isToolbarScrolledAway ? 0 : 1)
                            .allowsHitTesting(!isToolbarScrolledAway)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                } else if (!isPhone || !phoneSecondaryPanelIsPresented) && isToolbarCollapsed {
                    HStack(spacing: isPhone ? 8 : 12) {
                        if isPhone || isSidebarCollapsed {
                            sidebarToggleButton
                        }
                        toolbarCollapsedPill(for: vm.tabs[idx])
                        if splitMode != nil {
                            exitSplitViewButton
                        }
                        aiSidebarToggleButton
                    }
                    .glassEffectContainerCompat(spacing: 12)
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    // Icons turn white with Dark Web Pages; the frost and glass must
                    // follow the same appearance or it's white on white.
                    .environment(\.colorScheme, isSidebarDark ? .dark : .light)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, toolbarSideInset)
                    .padding(.bottom, 24)
                    .opacity(isToolbarScrolledAway ? 0 : 1)
                    .allowsHitTesting(!isToolbarScrolledAway)
                } else if (!isPhone || !phoneSecondaryPanelIsPresented) {
                    VStack(spacing: 8) {
                        AddressSuggestionsView(
                            tab: vm.tabs[idx],
                            isEditing: omniboxFocused,
                            favorites: vm.favorites
                        ) { url in
                            let tab = vm.tabs[idx]
                            tab.address = url.absoluteString
                            vm.navigate(to: url, in: tab)
                            collapseToolbar()
                        }
                        .frame(maxWidth: 560)
                        .padding(.horizontal, isPhone ? 8 : 0)
                        toolbarView(for: vm.tabs[idx])
                    }
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .environment(\.colorScheme, isSidebarDark ? .dark : .light)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                        .padding(.horizontal, toolbarSideInset)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .opacity(isToolbarScrolledAway ? 0 : 1)
                        .allowsHitTesting(!isToolbarScrolledAway)
                }

                if toolbarScrollState == .minimized,
                   !isChromeHidden,
                   distractionPickerTabID != vm.tabs[idx].id,
                   !isPhone || !phoneSecondaryPanelIsPresented {
                    minimizedAddressStrip(for: vm.tabs[idx])
                        .padding(.bottom, minimizedStripBottomGap)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .transition(.opacity)
                }
            }

            if pageStatusMessage != nil {
                pageStatusCapsule
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24 + toolbarPillHeight + 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(160)
            }

            if let request = activeWebAIRequest {
                webAIOverlay(for: request)
            }

            if showFilterListSettings {
                filterListOverlay
            }

            if let pendingRedditPreflight {
                largeRedditThreadOverlay(for: pendingRedditPreflight)
                    .transition(.opacity)
                    .zIndex(200)
            }

            if downloadManager.hasVisibleStatus {
                BrowserDownloadStatusOverlay(manager: downloadManager)
                    .zIndex(150)
            }
        }
        .statusBarHidden(isChromeHidden)
        .sheet(isPresented: Binding(
            get: { sitePrivacyTabID != nil },
            set: { if !$0 { sitePrivacyTabID = nil } }
        )) {
            if let id = sitePrivacyTabID, let tab = browserTab(withID: id) {
                SitePrivacyPanel(
                    url: tab.currentURL,
                    webView: tab.activateWebView(),
                    onOpenAdBlockSettings: {
                        sitePrivacyTabID = nil
                        showFilterListSettings = true
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $pageWatchDraft) { draft in
            PageWatchEditorView(url: draft.url, title: draft.title, existing: nil)
        }
        .translationTask(translationConfiguration) { session in
            await runPageTranslation(with: session)
        }
        .onChange(of: vm.tabs.count) { _, _ in
            syncSplitState()
            syncAIContextSelection()
        }
        .onChange(of: vm.selectedTabID) { _, _ in
            setToolbarScrollState(.pinned)
            if distractionPickerTabID != nil {
                finishDistractionPicker()
            }
            let previousSelected = lastSelectedTabID
            lastSelectedTabID = vm.selectedTabID
            syncSplitState()
            restoreSplitPairIfNeeded()
            syncAIContextSelection(previousSelectedTabID: previousSelected)
        }
        .onChange(of: aiContextTabID) { _, _ in
            refreshHibernationProtection()
            if showAIPanel {
                prepareAIContext()
            }
        }
        .onChange(of: aiService.isProcessing) { _, isProcessing in
            if isPhone, isProcessing {
                withAnimation(.easeOut(duration: 0.22)) {
                    phoneAIPanelExpanded = true
                }
            }
        }
        .onChange(of: aiService.messages) { _, messages in
            if isPhone, !messages.isEmpty {
                withAnimation(.easeOut(duration: 0.22)) {
                    phoneAIPanelExpanded = true
                }
            }
        }
        .onChange(of: omniboxFocused) { _, focused in
            if focused {
                if isChromeHidden {
                    setChromeHidden(false)
                }
                if isToolbarCollapsed {
                    expandToolbar(focusOmnibox: false)
                }
            }
        }
        .onChange(of: requestDesktopSite) { _, _ in
            applyUserAgentPreference()
        }
        .onChange(of: aiService.backend) { _, newValue in
            handleBackendSelection(newValue)
            drainPendingAgentTaskQueue()
            drainWindowAgentTasks()
        }
        .onChange(of: mlxModelID) { _, newValue in
            mlxWarmupTask?.cancel()
            let capturedModelID = newValue
            mlxWarmupTask = Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.mlxModelID == capturedModelID else { return }
                    self.aiService.warmUpMLXIfNeeded()
                }
            }
        }
        .onAppear {
            UBlockLiteService.shared.attach(vm)
            lastSelectedTabID = vm.selectedTabID
            refreshHibernationProtection()
            vm.activateSelectedTab()
            restoreSplitPairIfNeeded()
            applyUserAgentPreference()
            setupSharedURLHandling()
            setupAgentTaskHandling()
            registerBrowserIntentEndpoint()
            startSpotlightIndexing()
            checkForSharedURL()
            mlxMaxOutputTokens = min(max(64, mlxMaxOutputTokens), 512)
            mlxMaxContextTokens = min(max(0, mlxMaxContextTokens), 8192)
            aiService.warmUpAppleLocalIfNeeded(force: true)
            aiService.warmUpMLXIfNeeded()

            // Defer heavy service initialization to after UI is interactive
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                adBlockService.prepareAsync()
            }
        }
        .onDisappear {
            mlxWarmupTask?.cancel()
            darwinObserver.stopObserving()
            agentTaskObserver.stopObserving()
            cancelAgentTaskStartup(returnToWindowQueue: true)
            browserIntentRuntime.unregister(windowID: browserIntentWindowID)
        }
        .onChange(of: scenePhase) { _, newPhase in
            browserIntentRuntime.setActive(
                newPhase == .active,
                windowID: browserIntentWindowID,
                invalidateRequest: newPhase == .background
            )
            if newPhase == .active {
                // Check when becoming active (in case Darwin notification was missed)
                checkForSharedURL()
                checkForPendingAgentTasks()
                drainWindowAgentTasks()
                checkDuePageWatchesIfIdle()
            } else if newPhase == .background {
                PageWatchBackgroundScheduler.refreshSchedule()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PageWatchNotification.openRequested)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                handleIncomingURL(url)
            }
        }
        .onChange(of: browserIntentRuntime.isBusy) { _, busy in
            if !busy {
                checkForPendingAgentTasks()
                drainWindowAgentTasks()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenSharedURL"))) { notification in
            if let urlString = notification.userInfo?["url"] as? String {
                openSharedContent(urlString)
            }
        }
        .onReceive(darwinObserver.notifications) {
            checkForSharedURL()
        }
        .onReceive(agentTaskObserver.notifications) {
            checkForPendingAgentTasks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .savedAgentTasksDidChange)) { _ in
            AgentWidgetReloader.reloadAll()
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
    }

    private func webAIOverlay(for request: BrowserWebAIRequest) -> some View {
        GeometryReader { proxy in
            let panelWidth = min(max(420, proxy.size.width * 0.78), proxy.size.width - 32)
            let panelHeight = min(max(320, proxy.size.height * 0.72), proxy.size.height - 80)

            ZStack(alignment: .bottomTrailing) {
                if isWebAIOverlayExpanded {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture {
                            if request.shouldAutoCapture {
                                minimizeWebAIOverlay()
                            }
                        }
                }

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.title)
                                .font(.headline)
                            Text(request.provider.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if webAIIsLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if request.shouldAutoCapture {
                            Button {
                                minimizeWebAIOverlay()
                            } label: {
                                Image(systemName: "minus")
                                    .frame(width: BrowserDesign.Size.hitTarget, height: BrowserDesign.Size.hitTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Minimize \(request.provider.displayName)")
                            .accessibilityHint("Keeps the request running in the background")
                        }
                        Button {
                            dismissWebAIOverlay(userCancelled: true)
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: BrowserDesign.Size.hitTarget, height: BrowserDesign.Size.hitTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(request.shouldAutoCapture ? "Cancel \(request.provider.displayName) request" : "Close \(request.provider.displayName)")
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)

                    Divider()

                    BrowserWebAIRepresentable(
                        request: request,
                        isLoading: $webAIIsLoading,
                        didInject: $webAIDidInject,
                        fallbackMessage: $webAIFallbackMessage,
                        onResponseCaptured: { response in
                            handleCapturedWebAIResponse(response)
                        },
                        onCaptureFailed: { message in
                            handleWebAICaptureFailure(message)
                        },
                        canTransmitPageContext: { binding in
                            browserAgentPageContextCanTransmit(binding)
                        }
                    )
                    .overlay {
                        if webAIIsLoading && !webAIDidInject {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Loading \(request.provider.displayName)...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.ultraThinMaterial)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let webAIFallbackMessage, isWebAIOverlayExpanded {
                            Text(webAIFallbackMessage)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.black.opacity(0.7))
                                .clipShape(Capsule())
                                .padding(.bottom, 12)
                        }
                    }
                }
                // Keep a stable viewport size even when minimized. Shrinking to
                // 1x1 breaks provider DOM/composer detection and delays capture
                // until the overlay is reopened.
                .frame(width: panelWidth, height: panelHeight)
                .glassEffectCompat(
                    in: RoundedRectangle(cornerRadius: BrowserDesign.Radius.panel, style: .continuous),
                    material: .regularMaterial,
                    strokeOpacity: 0.2,
                    isInteractive: false
                )
                .clipShape(RoundedRectangle(cornerRadius: BrowserDesign.Radius.panel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: BrowserDesign.Radius.panel, style: .continuous)
                        .strokeBorder(BrowserDesign.chromeBorder(isDark: isSidebarDark), lineWidth: 1)
                )
                .shadow(
                    color: BrowserDesign.Shadow.color(isDark: isSidebarDark),
                    radius: BrowserDesign.Shadow.panelRadius,
                    x: 0,
                    y: 12
                )
                .opacity(isWebAIOverlayExpanded ? 1 : 0.001)
                .allowsHitTesting(isWebAIOverlayExpanded)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isWebAIOverlayExpanded ? .center : .bottomTrailing)

                if request.shouldAutoCapture && isWebAIOverlayMinimized {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isWebAIOverlayExpanded = true
                            isWebAIOverlayMinimized = false
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.title)
                                .font(.subheadline.weight(.semibold))
                            Text("\(request.provider.displayName) working · Tap to open")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .glassEffectCompat(
                            in: Capsule(),
                            material: .ultraThinMaterial,
                            strokeOpacity: 0.18
                        )
                        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 8)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 84)
                }
            }
        }
    }

    @MainActor
    private func startCapturedWebAIRequest(
        provider: WebAIProvider,
        userPrompt: String,
        composedPrompt: String,
        sourceTab: BrowserTab? = nil,
        sourceBinding: BrowserAgentPageContextBinding? = nil
    ) {
        let contextSourceTab = sourceTab ?? webProviderContextSourceTab()
        let binding = sourceBinding ?? contextSourceTab.flatMap { pageContextBinding(for: $0) }
        guard browserAgentPageContextCanTransmit(binding),
              contextSourceTab.map({ pageContextIsAllowed(for: $0, capturedBinding: binding) }) ?? true else { return }
        let privacy = BrowserAgentAutofillPrivacy.shared
        let safeUserPrompt = privacy.redactPotentiallyTruncated(userPrompt, wasTruncated: true)
        let safeComposedPrompt = privacy.redactPotentiallyTruncated(composedPrompt, wasTruncated: true)
        if let sourceTab {
            webProviderContextTabID = sourceTab.id
            webProviderContextURLString = sourceTab.currentURL.map { normalizedContextURL($0) }
        }
        aiService.prepareForNewContext(contextSourceTab?.currentURL)
        browserAIWebLog("startCapturedWebAIRequest prepare userChars=\(safeUserPrompt.count) promptChars=\(safeComposedPrompt.count) sourceContextChars=\(aiService.sourcePageContextText?.count ?? 0)")
        guard let requestID = aiService.beginExternalWebRequest(userMessage: safeUserPrompt) else { return }
        browserAIWebLog("startCaptured request=\(requestID.uuidString.prefix(8)) provider=\(provider.displayName) userChars=\(safeUserPrompt.count) promptChars=\(safeComposedPrompt.count)")
        activeWebAIServiceRequestID = requestID
        webAIIsLoading = true
        webAIDidInject = false
        webAIFallbackMessage = nil
        activeWebAIRequest = BrowserWebAIRequest(
            provider: provider,
            title: provider.displayName,
            prompt: safeComposedPrompt,
            shouldAutoCapture: true,
            shouldStartMinimized: true,
            sourceBinding: binding
        )
        isWebAIOverlayExpanded = false
        isWebAIOverlayMinimized = true
    }

    private func sendCapturedWebProviderPrompt(
        provider: WebAIProvider,
        prompt: String,
        contextOverride: String? = nil
    ) {
        let trimmedPrompt = BrowserAgentAutofillPrivacy.shared
            .redactPotentiallyTruncated(prompt.trimmingCharacters(in: .whitespacesAndNewlines), wasTruncated: true)
        guard !trimmedPrompt.isEmpty else { return }
        let trimmedOverride = contextOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        browserAIWebLog("sendCapturedWebProviderPrompt start provider=\(provider.displayName) promptChars=\(trimmedPrompt.count) overrideChars=\(trimmedOverride?.count ?? 0) sourceContextChars=\(aiService.sourcePageContextText?.count ?? 0)")

        let sourceTab = webProviderContextSourceTab()
        let sourceBinding = sourceTab.flatMap { pageContextBinding(for: $0) }
        if let sourceTab, !pageContextIsAllowed(for: sourceTab, capturedBinding: sourceBinding) {
            reportBlockedPageContext()
            return
        }
        if let sourceTab {
            let contextURL = sourceTab.currentURL
            webProviderContextTabID = sourceTab.id
            webProviderContextURLString = contextURL.map { normalizedContextURL($0) }
        } else {
            webProviderContextTabID = nil
            webProviderContextURLString = nil
        }

        if let trimmedOverride, !trimmedOverride.isEmpty {
            let safeOverride: String
            if let sourceTab {
                guard let safe = safePageText(trimmedOverride, for: sourceTab, capturedBinding: sourceBinding) else {
                    reportBlockedPageContext()
                    return
                }
                safeOverride = safe
            } else {
                safeOverride = BrowserAgentAutofillPrivacy.shared.redactKnownValues(trimmedOverride)
            }
            let composed = "Selected text:\n\(safeOverride)\n\nUser prompt:\n\(trimmedPrompt)"
            startCapturedWebAIRequest(provider: provider, userPrompt: trimmedPrompt, composedPrompt: composed, sourceTab: sourceTab, sourceBinding: sourceBinding)
            return
        }

        guard let sourceTab else {
            startCapturedWebAIRequest(provider: provider, userPrompt: trimmedPrompt, composedPrompt: trimmedPrompt)
            return
        }

        if let cached = cachedAIPageContent(for: sourceTab) {
            let context = RedditSummaryPlanner.isRedditContext(cached)
                ? RedditSummaryPlanner.webSafeContext(
                    content: cached,
                    maxCharacters: redditWebProviderContextMaxChars
                )
                : cached
            let composed = "\(context)\n\nUser prompt:\n\(trimmedPrompt)"
            startCapturedWebAIRequest(provider: provider, userPrompt: trimmedPrompt, composedPrompt: composed, sourceTab: sourceTab, sourceBinding: sourceBinding)
            return
        }

        if let sourceContext = aiService.sourcePageContextText {
            let condensed = RedditSummaryPlanner.isRedditContext(sourceContext)
                ? RedditSummaryPlanner.webSafeContext(
                    content: sourceContext,
                    maxCharacters: redditWebProviderContextMaxChars
                )
                : Self.condenseText(sourceContext, maxChars: webProviderContextMaxChars)
            let composed = condensed.isEmpty ? trimmedPrompt : "\(condensed)\n\nUser prompt:\n\(trimmedPrompt)"
            browserAIWebLog("sendCaptured reusing sourcePageContext chars=\(sourceContext.count)")
            startCapturedWebAIRequest(provider: provider, userPrompt: trimmedPrompt, composedPrompt: composed, sourceTab: sourceTab, sourceBinding: sourceBinding)
            return
        }

        let sourceWebView = sourceTab.activateWebView()
        let contextURL = sourceWebView.url ?? sourceTab.currentURL
        let sourceTabID = sourceTab.id
        let contextURLString = contextURL.map { normalizedContextURL($0) }
        guard let contextURL else {
            reportBlockedPageContext()
            return
        }
        let capturedBinding = BrowserAgentPageContextBinding(tabID: sourceTab.id, webView: sourceWebView, url: contextURL)
        Task {
            let extracted = await PageContentExtractor.extractContent(from: sourceWebView, url: contextURL, preferFast: true)
            await MainActor.run {
                guard webProviderContextTabID == sourceTabID,
                      webProviderContextURLString == contextURLString,
                      pageContextIsAllowed(for: sourceTab, capturedBinding: capturedBinding) else {
                    browserAIWebLog("sendCaptured abort stale extraction start provider=\(provider.displayName)")
                    if !pageContextIsAllowed(for: sourceTab, capturedBinding: capturedBinding) { reportBlockedPageContext() }
                    return
                }
                let safeExtracted = extracted.map { BrowserAgentAutofillPrivacy.shared.sanitized($0) }
                let pageText = safeExtracted?.formattedForAIContext ?? ""
                let condensed = RedditSummaryPlanner.isRedditContext(pageText)
                    ? RedditSummaryPlanner.webSafeContext(
                        content: pageText,
                        maxCharacters: redditWebProviderContextMaxChars
                    )
                    : Self.condenseText(pageText, maxChars: webProviderContextMaxChars)
                let composed = condensed.isEmpty ? trimmedPrompt : "\(condensed)\n\nUser prompt:\n\(trimmedPrompt)"
                if let extracted {
                    storeAIPageContent(safeExtracted ?? extracted, for: sourceTab, capturedBinding: capturedBinding)
                }
                startCapturedWebAIRequest(provider: provider, userPrompt: trimmedPrompt, composedPrompt: composed, sourceTab: sourceTab, sourceBinding: capturedBinding)
            }
        }
    }

    private func handleCapturedWebAIResponse(_ response: String) {
        browserAIWebLog("captured response request=\(activeWebAIServiceRequestID?.uuidString.prefix(8) ?? "nil") chars=\(response.count)")
        let sanitizedResponse = sanitizeCapturedWebAIResponse(
            response,
            provider: activeWebAIRequest?.provider
        )
        if let requestID = activeWebAIServiceRequestID {
            aiService.completeExternalWebRequest(with: sanitizedResponse, requestID: requestID)
        }
        activeWebAIServiceRequestID = nil
        activeWebAIRequest = nil
        isWebAIOverlayExpanded = false
        isWebAIOverlayMinimized = false
        webAIFallbackMessage = nil
    }

    private func sanitizeCapturedWebAIResponse(
        _ response: String,
        provider: WebAIProvider?
    ) -> String {
        guard let provider else { return response }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidatePrefixes = [
            "\(displayName) said:",
            "\(displayName) said",
            "\(displayName):"
        ]

        for prefix in candidatePrefixes {
            guard trimmed.count >= prefix.count else { continue }
            if trimmed.prefix(prefix.count).localizedCaseInsensitiveCompare(prefix) == .orderedSame {
                let withoutPrefix = trimmed.dropFirst(prefix.count)
                return String(withoutPrefix).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return response
    }

    private func handleWebAICaptureFailure(_ message: String) {
        browserAIWebLog("captured failure request=\(activeWebAIServiceRequestID?.uuidString.prefix(8) ?? "nil") message=\(message)")
        if let requestID = activeWebAIServiceRequestID {
            aiService.failExternalWebRequest(message: message, requestID: requestID)
        }
        activeWebAIServiceRequestID = nil
        withAnimation(.easeOut(duration: 0.2)) {
            isWebAIOverlayExpanded = true
            isWebAIOverlayMinimized = false
        }
    }

    private func minimizeWebAIOverlay() {
        withAnimation(.easeOut(duration: 0.2)) {
            isWebAIOverlayExpanded = false
            isWebAIOverlayMinimized = true
        }
    }

    private func dismissWebAIOverlay(userCancelled: Bool) {
        browserAIWebLog("dismiss overlay request=\(activeWebAIServiceRequestID?.uuidString.prefix(8) ?? "nil") userCancelled=\(userCancelled)")
        if userCancelled, let requestID = activeWebAIServiceRequestID {
            aiService.failExternalWebRequest(message: "Web AI request cancelled.", requestID: requestID)
        }
        activeWebAIServiceRequestID = nil
        activeWebAIRequest = nil
        isWebAIOverlayExpanded = false
        isWebAIOverlayMinimized = false
        webAIFallbackMessage = nil
    }

    private func requestWebAILogin(for provider: WebAIProvider) {
        pendingWebAILoginProvider = provider
    }

    private func cancelPendingWebAILogin() {
        pendingWebAILoginProvider = nil
    }

    private func continueWebAILogin(for provider: WebAIProvider) {
        guard let pendingProvider = pendingWebAILoginProvider,
              pendingProvider.rawValue == provider.rawValue else { return }
        pendingWebAILoginProvider = nil
        openWebAILoginSession(for: pendingProvider)
    }

    private func webAILoginWarningOverlay(for provider: WebAIProvider) -> some View {
        WebAILoginWarningOverlay(
            provider: provider,
            onCancel: {
                cancelPendingWebAILogin()
            },
            onContinue: {
                continueWebAILogin(for: provider)
            }
        )
    }

    private func openWebAILoginSession(for provider: WebAIProvider) {
        showSettingsMenu = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            webAISettingsStatusMessage = nil
            activeWebAIServiceRequestID = nil
            webAIIsLoading = true
            webAIDidInject = false
            webAIFallbackMessage = nil
            activeWebAIRequest = BrowserWebAIRequest(
                provider: provider,
                title: "\(provider.displayName) Login",
                prompt: "",
                shouldAutoCapture: false,
                shouldStartMinimized: false,
                sourceBinding: nil
            )
            isWebAIOverlayExpanded = true
            isWebAIOverlayMinimized = false
        }
    }

    private func resetWebAISession(for provider: WebAIProvider) {
        BrowserWebAISessionManager.shared.resetSession(for: provider) { message in
            DispatchQueue.main.async {
                switch provider {
                case .chatgpt:
                    self.isChatGPTLoggedIn = false
                case .gemini:
                    self.isGeminiLoggedIn = false
                }
                self.webAISettingsStatusMessage = message
                if self.activeWebAIRequest?.provider == provider {
                    self.dismissWebAIOverlay(userCancelled: false)
                }
                // A split-view provider tab shares the same store; reload it so
                // it shows the signed-out page instead of a stale session.
                if let providerTab = self.activeWebProviderTab,
                   providerTab.webAIProvider == provider {
                    providerTab.activateWebView().load(URLRequest(url: provider.url))
                }
            }
        }
    }

    private func refreshWebAILoginStates() {
        BrowserWebAISessionManager.shared.isLoggedIn(to: .chatgpt) { isLoggedIn in
            DispatchQueue.main.async {
                self.isChatGPTLoggedIn = isLoggedIn
            }
        }
        BrowserWebAISessionManager.shared.isLoggedIn(to: .gemini) { isLoggedIn in
            DispatchQueue.main.async {
                self.isGeminiLoggedIn = isLoggedIn
            }
        }
    }

    // MARK: - Shared URL Handling (from Share Extension)
    private func setupSharedURLHandling() {
        darwinObserver.startObserving()
    }

    private func setupAgentTaskHandling() {
        agentTaskObserver.startObserving()
        checkForPendingAgentTasks()
    }

    @MainActor
    private func makePendingAgentTaskQueue() throws -> PendingAgentTaskQueue {
        guard let defaults = UserDefaults(suiteName: AgentTaskStoreLocation.appGroupIdentifier),
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw AgentTaskStoreError.appGroupUnavailable
        }
        return PendingAgentTaskQueue(
            defaults: defaults,
            storageKey: try AgentTaskStoreLocation.defaultsKey(bundleIdentifier: bundleIdentifier)
        )
    }

    private func checkForPendingAgentTasks() {
        guard scenePhase == .active else { return }
        do {
            let tasks = try makePendingAgentTaskQueue().pendingTasks()
            guard !tasks.isEmpty else { return }
            revealAgentTaskSidebar()
            drainPendingAgentTaskQueue()
        } catch {
            agentTaskQueueStatusMessage = error.localizedDescription
            showPageStatus(error.localizedDescription, autoHide: false)
        }
    }

    /// Shows the agent library on one stored run's detail page, from a `webmebrowser://run?id=` link.
    private func openAgentRunDetail(_ runID: UUID) {
        revealAgentTaskSidebar()
        agentRunDetailRequest = AgentRunDetailRequest(runID: runID)
    }

    /// Shows the agent library on the Watches tab for one page watch, from a `webmebrowser://watch?id=` link.
    private func openAgentWatchDetail(_ watchID: UUID) {
        revealAgentTaskSidebar()
        agentWatchOpenRequest = AgentWatchOpenRequest(watchID: watchID)
    }

    /// Checks due page watches in the foreground, but only when the window is ready and no agent work is running.
    /// The coordinator itself allows at most one check of due watches per 15 minutes.
    private func checkDuePageWatchesIfIdle() {
        guard agentTaskSidebarForegroundReady,
              !aiService.isProcessing,
              !isAgentSidebarBusy,
              !browserIntentRuntime.isBusy,
              agentTaskStartup == nil,
              stagedAgentTask == nil,
              windowAgentTaskQueue.isEmpty else { return }
        Task { @MainActor in
            _ = await PageWatchCoordinator.shared.checkOnActivation(isIdle: true)
            PageWatchBackgroundScheduler.refreshSchedule()
        }
    }

    private func revealAgentTaskSidebar() {
        let wasAlreadyVisible = showAIPanel
        showAIPanel = true
        if !wasAlreadyVisible,
           !aiService.isProcessing,
           !isAgentSidebarBusy,
           agentTaskStartup == nil,
           stagedAgentTask == nil {
            syncAIContextSelection(forceVisibleTab: true)
        }
        if isPhone {
            withAnimation(.easeOut(duration: 0.22)) {
                phoneSecondaryPanel = .ai
                phoneAIPanelExpanded = true
                phonePanelDragOffset = 0
                phonePanelHiddenForTabDrag = false
            }
        }
    }

    private func handleAgentSidebarReadiness(isReady: Bool, isBusy: Bool, supportsAgent: Bool) {
        isAgentSidebarReady = isReady
        isAgentSidebarBusy = isBusy
        isAgentBackendSupported = supportsAgent
        if supportsAgent { lastAgentBackendStatusShown = nil }
        if isReady {
            drainPendingAgentTaskQueue()
            drainWindowAgentTasks()
            checkDuePageWatchesIfIdle()
        }
    }

    private func drainPendingAgentTaskQueue() {
        guard agentTaskSidebarForegroundReady,
              !aiService.isProcessing,
              !isAgentSidebarBusy,
              !browserIntentRuntime.isBusy,
              agentTaskStartup == nil,
              stagedAgentTask == nil,
              windowAgentTaskQueue.isEmpty,
              let tab = activeAIContextTab,
              tab.webAIProvider == nil else { return }
        guard isAgentBackendSupported else {
            showAgentBackendUnavailableIfNeeded()
            return
        }
        do {
            let queue = try makePendingAgentTaskQueue()
            guard let first = try queue.pendingTasks().first else { return }
            if first.startURL == nil {
                guard let webView = tab.liveWebView,
                      !webView.isLoading,
                      let pageURL = webView.url,
                      AgentTaskURLParser.isAllowedStartURL(pageURL) else {
                    agentTaskQueueStatusMessage = "A browser task is waiting. Open an HTTP(S) webpage in this window, then it will start."
                    showPageStatus("Open a webpage before running a browser task without a starting address.", autoHide: false)
                    return
                }
            } else if tab.liveWebView?.isLoading == true {
                return
            }
            guard let request = try queue.consumeNextIfReady(
                isForeground: true,
                hasBrowserView: first.startURL != nil || tab.liveWebView != nil,
                aiBusy: false,
                agentBusy: false,
                startupBusy: false
            ) else { return }
            agentTaskQueueStatusMessage = nil
            windowAgentTaskQueue.append(request)
            drainWindowAgentTasks()
        } catch {
            agentTaskQueueStatusMessage = error.localizedDescription
            showPageStatus(error.localizedDescription, autoHide: false)
        }
    }

    private func enqueueWindowAgentTask(_ request: AgentTaskLaunchRequest) {
        guard !request.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.task.utf8.count <= AgentTaskURLParser.maximumTaskUTF8Bytes else {
            let message = "The saved browser task is invalid and was not started."
            agentTaskQueueStatusMessage = message
            showPageStatus(message, autoHide: false)
            return
        }
        if let startURL = request.startURL,
           !AgentTaskURLParser.isAllowedStartURL(startURL) {
            let message = "The saved browser task is invalid and was not started."
            agentTaskQueueStatusMessage = message
            showPageStatus(message, autoHide: false)
            return
        }
        guard windowAgentTaskQueue.count < PendingAgentTaskQueue.maximumPendingTasks else {
            let message = "This window already has 8 browser tasks waiting. Finish one before adding another."
            agentTaskQueueStatusMessage = message
            showPageStatus(message, autoHide: false)
            return
        }
        windowAgentTaskQueue.append(PendingAgentTask(
            task: request.task,
            startURL: request.startURL,
            savedTaskID: request.savedTaskID
        ))
        revealAgentTaskSidebar()
        drainWindowAgentTasks()
    }

    private func drainWindowAgentTasks() {
        guard agentTaskSidebarForegroundReady,
              !aiService.isProcessing,
              !isAgentSidebarBusy,
              !browserIntentRuntime.isBusy,
              agentTaskStartup == nil,
              stagedAgentTask == nil,
              let request = windowAgentTaskQueue.first,
              let tab = activeAIContextTab,
              tab.webAIProvider == nil else { return }
        guard isAgentBackendSupported else {
            showAgentBackendUnavailableIfNeeded()
            return
        }

        if request.startURL != nil {
            beginAgentTaskStartingNavigation(request, in: tab)
            return
        }
        guard let webView = tab.liveWebView,
              !webView.isLoading,
              let pageURL = webView.url,
              AgentTaskURLParser.isAllowedStartURL(pageURL) else {
            if request.startURL == nil {
                agentTaskQueueStatusMessage = "A browser task is waiting. Open an HTTP(S) webpage in this window, then it will start."
            }
            return
        }
        stagedAgentTask = request
        stagedAgentTaskContext = AgentTaskPreparedContext(
            requestID: request.id,
            tabID: tab.id,
            webView: webView,
            finalURL: pageURL,
            documentRevision: agentTaskDocumentRevisions[ObjectIdentifier(webView), default: 0],
            navigationID: agentTaskLastFinishedNavigationIDs[ObjectIdentifier(webView)]
        )
        agentTaskQueueStatusMessage = nil
    }

    private func showAgentBackendUnavailableIfNeeded() {
        let status = BrowserAgentEngineFactory.status(for: aiService.backend)
        agentTaskQueueStatusMessage = "A browser task is waiting. \(status) Choose a supported model to continue."
        guard lastAgentBackendStatusShown != status else { return }
        lastAgentBackendStatusShown = status
        showPageStatus("A browser task is waiting. \(status)", autoHide: false)
    }

    private func beginAgentTaskStartingNavigation(_ request: PendingAgentTask, in tab: BrowserTab) {
        guard agentTaskStartup == nil,
              let url = request.startURL,
              AgentTaskURLParser.isAllowedStartURL(url) else { return }
        let webView = tab.liveWebView ?? tab.activateWebView()
        aiContextTabID = tab.id
        vm.selectedTabID = tab.id
        do {
            let attempt = try AgentTaskNavigationAttempt(request: request, tab: tab, webView: webView)
            agentTaskStartupGeneration = UUID()
            let generation = agentTaskStartupGeneration
            agentTaskStartup = attempt
            agentTaskStartupTimeout?.cancel()
            agentTaskStartupTimeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled,
                      self.agentTaskStartupGeneration == generation,
                      self.agentTaskStartup === attempt else { return }
                self.finishAgentTaskStartup(attempt, with: .failed("The starting page took too long to load."))
            }
            // A task URL is not started until the exact visible host has
            // installed the WKNavigationDelegate that will report its chain.
            if agentTaskReadyWebViews.contains(ObjectIdentifier(webView)) {
                startAgentTaskNavigation(attempt, generation: generation)
            }
        } catch {
            let message = "The saved starting address is invalid."
            agentTaskQueueStatusMessage = message
            showPageStatus(message, autoHide: false)
            windowAgentTaskQueue.removeAll { $0.id == request.id }
            AgentRunCompletionBroker.shared.reject(requestID: request.id, message: message)
        }
    }

    private func startAgentTaskNavigation(_ attempt: AgentTaskNavigationAttempt, generation: UUID) {
        guard agentTaskStartupGeneration == generation,
              agentTaskStartup === attempt,
              attempt.isCurrent(in: vm, selectedContextID: aiContextTabID),
              attempt.markNavigationRequested() else { return }
        launchAgentTaskNavigation(attempt, generation: generation)
    }

    private func launchAgentTaskNavigation(_ attempt: AgentTaskNavigationAttempt, generation: UUID) {
        guard agentTaskStartupGeneration == generation,
              agentTaskStartup === attempt,
              attempt.isCurrent(in: vm, selectedContextID: aiContextTabID),
              let tab = attempt.tab,
              let url = attempt.request.startURL else { return }

        vm.navigateForAgentTask(
            to: url,
            in: tab,
            shouldProceed: {
                self.agentTaskSidebarForegroundReady
                    && self.agentTaskStartupGeneration == generation
                    && self.agentTaskStartup === attempt
                    && attempt.isCurrent(in: self.vm, selectedContextID: self.aiContextTabID)
            },
            onNavigationStarted: { startedWebView, navigation, _ in
                guard self.agentTaskStartupGeneration == generation,
                      self.agentTaskStartup === attempt,
                      attempt.bind(webView: startedWebView, navigation: navigation) else {
                    self.finishAgentTaskStartup(attempt, with: .failed("The requested starting page was superseded."))
                    return
                }
            },
            onFailure: { message in
                guard self.agentTaskStartupGeneration == generation,
                      self.agentTaskStartup === attempt else { return }
                if !self.agentTaskSidebarForegroundReady {
                    self.cancelAgentTaskStartup(returnToWindowQueue: true)
                    return
                }
                self.finishAgentTaskStartup(attempt, with: .failed(message))
            }
        )
    }

    private func handleAgentTaskWebViewReadiness(tab: BrowserTab, webView: WKWebView, isReady: Bool) -> Bool {
        let webViewID = ObjectIdentifier(webView)
        if isReady {
            let wasReady = agentTaskReadyWebViews.contains(webViewID)
            agentTaskReadyWebViews.insert(webViewID)
            if let attempt = agentTaskStartup,
               attempt.tab === tab,
               attempt.webView === webView {
                let generation = agentTaskStartupGeneration
                if attempt.markNavigationRequested() {
                    Task { @MainActor in
                        self.launchAgentTaskNavigation(attempt, generation: generation)
                    }
                }
                // While this attempt owns the tab, suppress WebViewHost's normal
                // restoration load so it cannot race the requested URL.
                return true
            }
            if !wasReady {
                Task { @MainActor in
                    self.drainPendingAgentTaskQueue()
                    self.drainWindowAgentTasks()
                }
            }
            return false
        }
        agentTaskReadyWebViews.remove(webViewID)
        return false
    }

    private func handleAgentTaskNavigationEvent(
        tab: BrowserTab,
        webView: WKWebView,
        navigation: WKNavigation,
        kind: AgentTaskNavigationEventKind
    ) {
        let webViewID = ObjectIdentifier(webView)
        if kind == .finished {
            agentTaskLastFinishedNavigationIDs[webViewID] = ObjectIdentifier(navigation)
        }
        if kind == .committed {
            let isPreparedNavigation = stagedAgentTaskContext?.tabID == tab.id
                && stagedAgentTaskContext?.webViewID == webViewID
                && stagedAgentTaskContext?.navigationID == ObjectIdentifier(navigation)
            if !isPreparedNavigation {
                agentTaskDocumentRevisions[webViewID, default: 0] += 1
                if stagedAgentTaskContext?.tabID == tab.id,
                   stagedAgentTaskContext?.webViewID == webViewID {
                    rejectStagedAgentTask("The page changed before the browser task could start. Run it again on the current page.")
                }
            }
        }

        guard let attempt = agentTaskStartup else {
            if kind == .started,
               stagedAgentTaskContext?.tabID == tab.id,
               stagedAgentTaskContext?.webViewID == webViewID,
               stagedAgentTaskContext?.navigationID != ObjectIdentifier(navigation) {
                rejectStagedAgentTask("A new page navigation started before the browser task could begin. Run it again when the page is ready.")
            } else if kind == .finished || kind == .failed {
                // Keep external tasks queued while the window has no usable
                // page; retry when any ordinary navigation becomes ready.
                drainPendingAgentTaskQueue()
                drainWindowAgentTasks()
            }
            return
        }
        guard attempt.isCurrent(in: vm, selectedContextID: aiContextTabID) else {
            finishAgentTaskStartup(attempt, with: .failed("The browser tab changed before the starting page finished loading."))
            return
        }
        let result = attempt.receive(
            kind,
            tab: tab,
            webView: webView,
            navigation: navigation,
            finalURL: webView.url,
            isLoading: webView.isLoading
        )
        switch result {
        case .waiting:
            break
        case .completed, .failed:
            finishAgentTaskStartup(attempt, with: result)
        }
    }

    private func finishAgentTaskStartup(
        _ attempt: AgentTaskNavigationAttempt,
        with result: AgentTaskNavigationResolution
    ) {
        guard agentTaskStartup === attempt else { return }
        if case .waiting = result { return }
        agentTaskStartupTimeout?.cancel()
        agentTaskStartupTimeout = nil
        agentTaskStartup = nil
        agentTaskStartupGeneration = UUID()
        switch result {
        case .completed:
            if windowAgentTaskQueue.first?.id == attempt.request.id {
                windowAgentTaskQueue.removeFirst()
            }
            stagedAgentTask = attempt.request
            guard let tab = attempt.tab,
                  let webView = attempt.webView,
                  let finalURL = webView.url,
                  AgentTaskURLParser.isAllowedStartURL(finalURL),
                  !webView.isLoading else {
                rejectStagedAgentTask("The starting page changed before the browser task could start. Run it again.")
                drainWindowAgentTasks()
                return
            }
            stagedAgentTaskContext = AgentTaskPreparedContext(
                requestID: attempt.request.id,
                tabID: tab.id,
                webView: webView,
                finalURL: finalURL,
                documentRevision: agentTaskDocumentRevisions[ObjectIdentifier(webView), default: 0],
                navigation: attempt.expectedNavigation
            )
            agentTaskQueueStatusMessage = nil
        case .failed(let message):
            windowAgentTaskQueue.removeAll { $0.id == attempt.request.id }
            AgentRunCompletionBroker.shared.reject(requestID: attempt.request.id, message: message)
            agentTaskQueueStatusMessage = message
            showPageStatus(message, autoHide: false)
            drainPendingAgentTaskQueue()
            drainWindowAgentTasks()
        case .waiting:
            break
        }
    }

    private func validateAgentTaskDispatch(requestID: UUID, webView: WKWebView) -> Bool {
        guard agentTaskSidebarForegroundReady,
              !aiService.isProcessing,
              !isAgentSidebarBusy,
              !browserIntentRuntime.isBusy,
              agentTaskStartup == nil,
              isAgentBackendSupported,
              let request = stagedAgentTask,
              request.id == requestID,
              let context = stagedAgentTaskContext,
              let tab = activeAIContextTab,
              tab.webAIProvider == nil,
              tab.id == context.tabID,
              tab.liveWebView === webView,
              context.matches(
                requestID: requestID,
                tabID: tab.id,
                webView: webView,
                currentURL: webView.url,
                documentRevision: agentTaskDocumentRevisions[ObjectIdentifier(webView), default: 0],
                isLoading: webView.isLoading,
                isForegroundReady: agentTaskSidebarForegroundReady
                    && !aiService.isProcessing
                    && !isAgentSidebarBusy
              ) else {
            rejectStagedAgentTask("The browser page or navigation changed before the task could start. Review the current page and run it again.")
            return false
        }
        if request.startURL != nil, vm.selectedTabID != tab.id {
            rejectStagedAgentTask("The browser tab changed before its starting page could be used. Run the task again from the current tab.")
            return false
        }
        return true
    }

    private func rejectStagedAgentTask(_ message: String) {
        guard let request = stagedAgentTask else { return }
        stagedAgentTask = nil
        stagedAgentTaskContext = nil
        windowAgentTaskQueue.removeAll { $0.id == request.id }
        AgentRunCompletionBroker.shared.reject(requestID: request.id, message: message)
        agentTaskQueueStatusMessage = message
        showPageStatus(message, autoHide: false)
    }

    private func handlePendingAgentTaskStarted(_ requestID: UUID) {
        var pending = windowAgentTaskQueue
        var staged = stagedAgentTask
        var isBusy = isAgentSidebarBusy
        guard AgentTaskWindowQueuePolicy.acknowledgeStarted(
            requestID: requestID,
            pending: &pending,
            staged: &staged,
            isBusy: &isBusy
        ) else { return }
        windowAgentTaskQueue = pending
        stagedAgentTask = staged
        isAgentSidebarBusy = isBusy
        stagedAgentTaskContext = nil
        agentTaskQueueStatusMessage = nil
    }

    private func cancelAgentTaskStartup(returnToWindowQueue: Bool) {
        guard let attempt = agentTaskStartup else { return }
        agentTaskStartupTimeout?.cancel()
        agentTaskStartupTimeout = nil
        agentTaskStartupGeneration = UUID()
        agentTaskStartup = nil
        if returnToWindowQueue,
           !windowAgentTaskQueue.contains(where: { $0.id == attempt.request.id }) {
            windowAgentTaskQueue.insert(attempt.request, at: 0)
        }
    }

    private func handleAgentTaskCompletion(
        _ snapshot: BrowserAgentController.CompletionSnapshot,
        replyID: UUID
    ) {
        // Waiting App Intents must hear about every run, private ones included.
        AgentRunCompletionBroker.shared.complete(snapshot)
        // The reply ID is captured by the exact String completion callback in the
        // sidebar. Private runs return before even constructing the store provider.
        guard !snapshot.isPrivate else { return }
        do {
            let store = try AgentTaskStoreLocation.makeDefaultStore(bundleIdentifier: Bundle.main.bundleIdentifier)
            try AgentTaskHistoryRecorder.record(snapshot.historyRecord, isPrivate: false, storeProvider: { store })
            if let savedTaskID = snapshot.savedTaskID,
               var saved = try store.savedTask(id: savedTaskID) {
                saved.lastRunAt = snapshot.date
                try store.updateTask(saved)
            }
            AgentTaskShortcutMetadata.refresh()
        } catch {
            showPageStatus(error.localizedDescription, autoHide: false)
        }
        _ = replyID // Exact reply association remains in AISidebar for Save as Task.
    }

    private func checkForSharedURL() {
        print("DEBUG: checkForSharedURL called")

        guard let sharedDefaults = UserDefaults(suiteName: DarwinNotificationObserver.appGroupID) else {
            print("DEBUG: Failed to access App Group: \(DarwinNotificationObserver.appGroupID)")
            return
        }

        if let sharedSearchText = sharedDefaults.string(forKey: BrowserSharePayload.sharedSearchTextKey) {
            sharedURLRetryCount = 0
            sharedDefaults.removeObject(forKey: BrowserSharePayload.sharedSearchTextKey)
            sharedDefaults.synchronize()
            openSharedSearch(sharedSearchText)
            return
        }

        guard let sharedURLString = sharedDefaults.string(forKey: "sharedURL") else {
            print("DEBUG: No sharedURL found in App Group")
            if sharedURLRetryCount < 10 {
                sharedURLRetryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.checkForSharedURL()
                }
            }
            return
        }

        sharedURLRetryCount = 0
        print("DEBUG: Found shared content (\(sharedURLString.count) characters)")

        // Remove the URL from shared defaults immediately
        sharedDefaults.removeObject(forKey: "sharedURL")
        sharedDefaults.synchronize()

        openSharedContent(sharedURLString)
    }

    private func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            importBookmarksFile(at: url)
            return
        }
        // Web links arrive here once Vortex is the default browser.
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            openSharedContent(url.absoluteString)
            return
        }
        if aiService.handleCloudShortcutCallback(url) {
            return
        }
        if url.scheme?.lowercased() == AgentIncomingURLRouter.appScheme,
           url.host?.lowercased() == "agent" {
            do {
                guard let request = try AgentTaskURLParser.parse(url) else {
                    throw AgentTaskURLParseError.malformedAgentURL
                }
                try AgentTaskHandoffCoordinator(queue: makePendingAgentTaskQueue()).enqueue(request)
                showPageStatus("Browser task queued.")
                revealAgentTaskSidebar()
                checkForPendingAgentTasks()
            } catch {
                showPageStatus(error.localizedDescription, autoHide: false)
            }
            return
        }
        if url.scheme?.lowercased() == AgentIncomingURLRouter.appScheme,
           url.host?.lowercased() == AgentRunURLParser.host {
            do {
                guard let runID = try AgentRunURLParser.parse(url) else {
                    throw AgentRunURLParseError.malformedRunURL
                }
                openAgentRunDetail(runID)
            } catch {
                showPageStatus(error.localizedDescription, autoHide: false)
            }
            return
        }
        if url.scheme?.lowercased() == AgentIncomingURLRouter.appScheme,
           url.host?.lowercased() == PageWatchURLParser.host {
            do {
                guard let watchID = try PageWatchURLParser.parse(url) else {
                    throw PageWatchURLParseError.malformedWatchURL
                }
                openAgentWatchDetail(watchID)
            } catch {
                showPageStatus(error.localizedDescription, autoHide: false)
            }
            return
        }
        if AgentControlURLParser.isControlURL(url) {
            handleControlURL(url)
            return
        }
        guard url.scheme?.lowercased() == shareAppURLScheme else {
            return
        }

        if handleSharedSearchURL(url) {
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let text = components?.queryItems?.first(where: { $0.name == "text" })?.value,
           !text.isEmpty {
            openSharedContent(text)
        } else {
            checkForSharedURL()
        }
    }

    /// Widget and control links: a private tab, the clipboard search, or one saved task.
    private func handleControlURL(_ url: URL) {
        do {
            guard let action = try AgentControlURLParser.parse(url) else { return }
            switch action {
            case .privateTab:
                openIncognitoTab()
            case .searchClipboard:
                fillOmniboxFromClipboard()
            case .savedTask(let taskID):
                try queueSavedTaskFromControl(taskID)
            }
        } catch {
            showPageStatus(error.localizedDescription, autoHide: false)
        }
    }

    /// Puts the clipboard text into the address field and focuses it. The text is never submitted here.
    private func fillOmniboxFromClipboard() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            showPageStatus(AgentControlURLParser.emptyClipboardMessage)
            return
        }
        guard BrowserIntentShareParser.isValidSearchText(text) else {
            showPageStatus(AgentControlURLParser.unsearchableClipboardMessage, autoHide: false)
            return
        }
        if !vm.tabs.contains(where: { $0.id == vm.selectedTabID }) {
            vm.addTabBlank()
        }
        guard let tab = vm.tabs.first(where: { $0.id == vm.selectedTabID }) else { return }
        tab.address = text
        expandToolbar(focusOmnibox: true)
    }

    /// Queues one saved task through the same path as Run Saved Browser Task. Approvals still apply when it runs.
    private func queueSavedTaskFromControl(_ taskID: UUID) throws {
        guard let savedTask = try AgentTaskIntentRuntime.savedTask(id: taskID) else {
            showPageStatus(AgentControlURLParser.missingSavedTaskMessage, autoHide: false)
            return
        }
        try AgentTaskIntentRuntime.enqueue(AgentControlURLParser.pendingRequest(for: savedTask))
        showPageStatus("Browser task queued.")
        revealAgentTaskSidebar()
        checkForPendingAgentTasks()
    }

    /// An exported bookmarks file opened with "Open in Vortex" from Files, AirDrop or Mail.
    private func importBookmarksFile(at url: URL) {
        do {
            bookmarkImportMessage = try vm.importBookmarks(fromFileAt: url).message
        } catch {
            bookmarkImportMessage = error.localizedDescription
        }
        // Files opened from other apps arrive as a copy in Documents/Inbox; drop it.
        if url.pathComponents.contains("Inbox") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func openSharedContent(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        guard let url = vm.destinationURL(from: trimmed) else { return }

        print("DEBUG: Opening shared content at \(browserURLForLog(url))")

        // Create a new tab with the shared URL
        let newTab = BrowserTab(title: "Loading...", url: url)
        vm.tabs.append(newTab)
        vm.selectedTabID = newTab.id
        vm.navigate(to: url, in: newTab)
    }

    private func handleSharedSearchURL(_ url: URL) -> Bool {
        guard url.host?.lowercased() == BrowserIntentShareParser.searchHost else {
            return false
        }
        do {
            if let text = try BrowserIntentShareParser.parseSearchText(from: url) {
                openSharedSearch(text)
            }
        } catch {
            showPageStatus(error.localizedDescription, autoHide: false)
        }
        return true
    }

    private func openSharedSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BrowserIntentShareParser.isValidSearchText(trimmed),
              let url = vm.defaultSearchEngine.searchURL(for: trimmed) else { return }
        let newTab = BrowserTab(title: "Loading...", url: url, isIncognito: false)
        vm.tabs.append(newTab)
        vm.selectedTabID = newTab.id
        vm.navigate(to: url, in: newTab)
    }

    private func registerBrowserIntentEndpoint() {
        browserIntentRuntime.register(
            windowID: browserIntentWindowID,
            isActive: scenePhase == .active,
            isReady: {
                !aiService.isProcessing
                    && !isAgentSidebarBusy
                    && agentTaskStartup == nil
                    && stagedAgentTask == nil
                    && windowAgentTaskQueue.isEmpty
            },
            execute: { command, confirm, isCurrent in
                try await makeBrowserIntentExecutor(isCurrent: isCurrent).execute(command, confirm: confirm)
            }
        )
        browserIntentRuntime.registerTabSnapshot(windowID: browserIntentWindowID) {
            vm.tabs
        }
    }

    /// Starts Spotlight syncing for bookmarks, saved tasks and history, then rebuilds once per launch.
    private func startSpotlightIndexing() {
        BrowserSpotlightIndexer.shared.startObserving()
        Task(priority: .background) {
            await BrowserSpotlightIndexer.shared.reindexAll()
        }
    }

    private func makeBrowserIntentExecutor(
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) -> BrowserIntentExecutor {
        BrowserIntentExecutor(
            viewModel: vm,
            downloadManager: downloadManager,
            isCurrent: isCurrent,
            backendProvider: { aiService.backend },
            callbacks: makeBrowserIntentCallbacks()
        )
    }

    private func makeBrowserIntentCallbacks() -> BrowserIntentExecutor.Callbacks {
        var callbacks = BrowserIntentExecutor.Callbacks()
        callbacks.translatePage = { tab, tag, shouldContinue in
            guard tab.webAIProvider == nil else {
                throw BrowserIntentError.noEligiblePage
            }
            let language = Locale.Language(identifier: tag)
            try await withCheckedThrowingContinuation { continuation in
                startPageTranslation(
                    for: tab,
                    targetLanguage: language,
                    agentRunIsCurrent: shouldContinue
                ) { result in
                    continuation.resume(with: result)
                }
            }
        }
        callbacks.openSplit = { primaryID, secondaryID in
            splitPrimaryID = primaryID
            splitSecondaryID = secondaryID
            splitSecondaryExternalTab = nil
            splitMode = .vertical
            vm.isSplitViewActive = true
            refreshHibernationProtection()
            syncAIContextSelection()
        }
        callbacks.endSplit = {
            clearSplitView()
        }
        callbacks.sendToWebAI = { provider, userPrompt, composedPrompt, sourceTab, binding in
            let previousRequestID = activeWebAIRequest?.id
            aiContextTabID = sourceTab.id
            startCapturedWebAIRequest(
                provider: provider,
                userPrompt: userPrompt,
                composedPrompt: composedPrompt,
                sourceTab: sourceTab,
                sourceBinding: binding
            )
            return activeWebAIRequest != nil && activeWebAIRequest?.id != previousRequestID
        }
        callbacks.onTabSelected = { id in
            aiContextTabID = id
            refreshHibernationProtection()
        }
        callbacks.translationPageIsCurrent = { tab, webView, url in
            let windowID = browserIntentWindowID
            let viewModel = vm
            let runtime = browserIntentRuntime
            let revision = agentTaskDocumentRevisions[ObjectIdentifier(webView), default: 0]
            return { [weak tab, weak webView] in
                guard let tab, let webView else { return false }
                return runtime.isWindowRegisteredAndActive(windowID: windowID)
                    && viewModel.tabs.first(where: { $0.id == tab.id }) === tab
                    && tab.liveWebView === webView
                    && webView.url == url
                    && agentTaskDocumentRevisions[ObjectIdentifier(webView), default: 0] == revision
            }
        }
        return callbacks
    }

    private func dismissAIPanel(isExplicitCancellation: Bool = false) {
        guard AIPanelDismissalPolicy.allowsDismissal(
            isProcessing: aiService.isProcessing,
            isExplicitCancellation: isExplicitCancellation
        ) else {
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            showAIPanel = false
            if isPhone {
                resignPhonePanelInput()
                phoneSecondaryPanel = .none
                phonePanelDragOffset = 0
                phonePanelHiddenForTabDrag = false
                if isExplicitCancellation {
                    phoneAIPanelExpanded = false
                }
            }
        }
        if activeWebProviderTab != nil {
            clearSplitView()
        }
    }

    private func makeAISidebar() -> AISidebar {
        AISidebar(
            aiService: aiService,
            onSend: { text in
                guard !browserIntentRuntime.isBusy else {
                    showPageStatus("Finishing a Siri or Shortcuts action\u{2026}")
                    return
                }
                aiQuery = text
                if let tab = activeAIContextTab {
                    sendAIQuery(for: tab, selection: pendingAISelection)
                }
            },
            onDismiss: {
                dismissAIPanel(isExplicitCancellation: true)
            },
            contextOptions: aiContextOptions,
            selectedContextID: $aiContextTabID,
            selectionText: activeAISelectionText,
            contextStatusText: activeAIContextStatusText,
            onSummaryExtraction: { content, length, capturedBinding, extractedContent in
                if browserIntentRuntime.isBusy {
                    showPageStatus("Finishing a Siri or Shortcuts action\u{2026}")
                    return true
                }
                if let tab = capturedBinding.flatMap({ browserTab(withID: $0.tabID) }) ?? activeAIContextTab {
                    if let extractedContent {
                        storeAIPageContent(extractedContent, for: tab, capturedBinding: capturedBinding)
                    }
                    return dispatchResolvedSummary(
                        content: content,
                        length: length,
                        sourceTab: tab,
                        sourceBinding: capturedBinding
                    )
                }
                reportBlockedPageContext()
                return true
            },
            onContextSelected: { id in
                if let tab = vm.tabs.first(where: { $0.id == id }) {
                    _ = tab.activateWebView()
                    refreshHibernationProtection()
                }
            },
            onClearConversation: {
                pendingRedditPreflight = nil
                aiService.reset()
            },
            onInputFocusChanged: { focused in
                isAISidebarInputFocused = focused
                if isNativeIPadDevice, !focused {
                    iPadKeyboardOverlap = 0
                }
                guard isPhone, focused else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    phoneAIPanelExpanded = true
                    phoneSecondaryPanel = .ai
                    phonePanelDragOffset = 0
                    phonePanelHiddenForTabDrag = false
                }
            },
            isPinned: isPhone ? nil : $pinAISidebar,
            onAgentOpenTab: { url, sourceWebView in
                openAgentTab(url: url, after: sourceWebView)
            },
            onLookupOpenSource: { source in
                guard !browserIntentRuntime.isBusy, !aiService.isProcessing,
                      let tab = activeAIContextTab,
                      vm.tabs.contains(where: { $0.id == tab.id }),
                      tab.webAIProvider == nil,
                      tab.isIncognito == source.isPrivate else { return false }
                let webView = tab.liveWebView ?? tab.activateWebView()
                guard AISidebar.lookupSourceOpenEligible(
                    source,
                    contextIsPrivate: tab.isIncognito,
                    webViewDataStoreIsPersistent: webView.configuration.websiteDataStore.isPersistent
                ) else { return false }
                return openAgentTab(url: source.url, after: webView) != nil
            },
            onAgentAutofillQuarantine: { tabID, webView in
                handleAgentAutofillQuarantine(tabID: tabID, webView: webView)
            },
            browserAgentAdapter: BrowserAgentBrowserAdapter(
                viewModel: vm,
                downloadManager: downloadManager,
                onTabSelected: { id in
                    aiContextTabID = id
                    refreshHibernationProtection()
                },
                onSplitPairOpened: { primaryID, secondaryID, isHorizontal in
                    splitPrimaryID = primaryID
                    splitSecondaryID = secondaryID
                    splitSecondaryExternalTab = nil
                    splitMode = isHorizontal ? .horizontal : .vertical
                    vm.isSplitViewActive = true
                    aiContextTabID = secondaryID
                    refreshHibernationProtection()
                    syncAIContextSelection()
                },
                readerModeAction: { id, enabled in
                    guard let tab = browserTab(withID: id), tab.webAIProvider == nil,
                          let scheme = tab.currentURL?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                        throw NSError(domain: "BrowserAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reader mode requires a regular HTTP(S) browser tab."])
                    }
                    if tab.isReaderMode == enabled { return }
                    let webView = tab.liveWebView ?? tab.activateWebView()
                    let value: Any? = try await withCheckedThrowingContinuation { continuation in
                        webView.evaluateJavaScript(ReaderModeService.toggleScript) { result, error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume(returning: result) }
                        }
                    }
                    guard (value as? Bool) == enabled else {
                        throw NSError(domain: "BrowserAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "The page could not change reader mode."])
                    }
                    tab.isReaderMode = enabled
                },
                translationAction: { id, target, shouldContinue in
                    guard let tab = browserTab(withID: id), tab.webAIProvider == nil else {
                        throw NSError(domain: "BrowserAgent", code: 3, userInfo: [NSLocalizedDescriptionKey: "The page tab is no longer available."])
                    }
                    let language = target.map { Locale.Language(identifier: $0) }
                    if let language, language.languageCode == nil {
                        throw NSError(domain: "BrowserAgent", code: 4, userInfo: [NSLocalizedDescriptionKey: "Use a valid BCP-47 language tag such as pt or pt-BR."])
                    }
                    let preparation: Result<Void, Error> = await withCheckedContinuation { continuation in
                        startPageTranslation(
                            for: tab,
                            targetLanguage: language,
                            agentRunIsCurrent: shouldContinue
                        ) { result in
                            continuation.resume(returning: result)
                        }
                    }
                    switch preparation {
                    case .failure(let error): throw error
                    case .success: break
                    }

                    let deadline = Date().addingTimeInterval(15)
                    while Date() < deadline {
                        guard shouldContinue() else { throw CancellationError() }
                        if let sourceLanguage = tab.translatedFrom {
                            return "Translation is applied on screen from \(sourceLanguage). Remaining below-screen text may continue translating."
                        }
                        if let status = pageTranslationAgentStates[id], status.hasPrefix("failed:") {
                            throw NSError(domain: "BrowserAgent", code: 6, userInfo: [NSLocalizedDescriptionKey: String(status.dropFirst("failed: ".count))])
                        }
                        if !tab.isTranslating {
                            throw NSError(domain: "BrowserAgent", code: 7, userInfo: [NSLocalizedDescriptionKey: pageTranslationAgentStates[id] ?? "Translation stopped before any page text was translated."])
                        }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    guard shouldContinue() else { throw CancellationError() }
                    if let sourceLanguage = tab.translatedFrom {
                        return "Translation is applied on screen from \(sourceLanguage). Remaining below-screen text may continue translating."
                    }
                    return "Translation is prepared and waiting for the system language download or user approval. Use page_translation_status to check again."
                },
                translationStatusAction: { id in
                    pageTranslationAgentStates[id]
                        ?? (browserTab(withID: id)?.translatedFrom.map { "translated from \($0)" }
                            ?? (browserTab(withID: id)?.isTranslating == true ? "in progress" : "idle"))
                },
                originalPageAction: { id in
                    guard let tab = browserTab(withID: id), tab.webAIProvider == nil else {
                        throw NSError(domain: "BrowserAgent", code: 5, userInfo: [NSLocalizedDescriptionKey: "The page tab is no longer available."])
                    }
                    showOriginalPage(for: tab)
                }
            ),
            agentTaskStoreProvider: {
                try AgentTaskStoreLocation.makeDefaultStore(bundleIdentifier: Bundle.main.bundleIdentifier)
            },
            onAgentTaskLaunch: { request in
                enqueueWindowAgentTask(request)
            },
            pendingAgentTask: stagedAgentTask,
            onPendingAgentTaskStarted: { requestID in
                handlePendingAgentTaskStarted(requestID)
            },
            onPendingAgentTaskDispatchCheck: { requestID, webView in
                validateAgentTaskDispatch(requestID: requestID, webView: webView)
            },
            onPendingAgentTaskRejected: { requestID in
                guard stagedAgentTask?.id == requestID else {
                    AgentRunCompletionBroker.shared.reject(
                        requestID: requestID,
                        message: "The browser page or navigation changed before the task could start. Review the current page and run it again."
                    )
                    return
                }
                rejectStagedAgentTask("The browser page or navigation changed before the task could start. Review the current page and run it again.")
            },
            agentTaskStatusMessage: agentTaskQueueStatusMessage,
            isAgentTaskSidebarVisible: showAIPanel && (!isPhone || (phoneSecondaryPanel == .ai && !phonePanelHiddenForTabDrag)),
            browserActionIsBusy: browserIntentRuntime.isBusy,
            onAgentReadinessChanged: { ready, busy, supported in
                handleAgentSidebarReadiness(isReady: ready, isBusy: busy, supportsAgent: supported)
            },
            onAgentRunCompleted: { snapshot, replyID in
                handleAgentTaskCompletion(snapshot, replyID: replyID)
            },
            onAgentNeedsAttention: {
                revealAgentTaskSidebar()
            },
            agentRunDetailRequest: agentRunDetailRequest,
            onAgentRunDetailRequestHandled: {
                agentRunDetailRequest = nil
            },
            agentWatchOpenRequest: agentWatchOpenRequest,
            onAgentWatchOpenRequestHandled: {
                agentWatchOpenRequest = nil
            }
        )
    }

    /// Opens a tab for the browser agent right after the tab it is working in,
    /// keeping that tab's private-browsing mode and group, and selects it.
    private func openAgentTab(url: URL, after sourceWebView: WKWebView) -> WKWebView? {
        let sourceIndex = vm.tabs.firstIndex { $0.liveWebView === sourceWebView }
        let sourceTab = sourceIndex.map { vm.tabs[$0] }
        let tab = BrowserTab(
            title: url.host ?? "New Tab",
            url: url,
            isIncognito: sourceTab?.isIncognito ?? false,
            useDesktopUserAgent: requestDesktopSite,
            groupID: sourceTab?.groupID
        )
        if let sourceIndex {
            vm.tabs.insert(tab, at: sourceIndex + 1)
        } else {
            vm.tabs.append(tab)
        }
        vm.selectedTabID = tab.id
        aiContextTabID = tab.id
        vm.navigate(to: url, in: tab)
        refreshHibernationProtection()
        return tab.activateWebView()
    }

    private var aiSidebarPanel: some View {
        makeAISidebar()
        .frame(width: aiSidebarBaseWidth)
        .overlay(alignment: .leading) {
            sidebarDismissHandle
        }
    }

    private var phoneAISidebarPanel: some View {
        makeAISidebar()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: sidebarCornerRadius, style: .continuous))
    }

    private var sidebarDismissHandle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.clear)
                .frame(width: 28, height: 76)
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 4, height: 40)
        }
        .padding(.leading, 2)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityLabel("Drag to dismiss")
        .gesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .local)
                .onEnded { value in
                    let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                    if isHorizontal, value.translation.width > 80 {
                        dismissAIPanel()
                    }
                }
        )
    }

    private func openSplitView(with tab: BrowserTab, mode: SplitMode) {
        guard let selectedID = vm.selectedTabID else { return }
        let secondaryTab: BrowserTab?
        if selectedID == tab.id {
            if let selectedIndex = vm.selectedIndex {
                let nextIndex = selectedIndex + 1
                if nextIndex < vm.tabs.count {
                    secondaryTab = vm.tabs[nextIndex]
                } else if selectedIndex > 0 {
                    secondaryTab = vm.tabs[selectedIndex - 1]
                } else {
                    secondaryTab = nil
                }
            } else {
                secondaryTab = nil
            }
        } else {
            secondaryTab = tab
        }
        guard let secondaryTab else { return }
        if let primary = vm.tabs.first(where: { $0.id == selectedID }) {
            vm.captureTabThumbnail(for: primary)
        }
        vm.captureTabThumbnail(for: secondaryTab)
        splitPrimaryID = selectedID
        splitSecondaryID = secondaryTab.id
        splitSecondaryExternalTab = nil
        splitMode = mode
        vm.isSplitViewActive = true
        vm.setSplitPair(primaryID: selectedID, secondaryID: secondaryTab.id, isHorizontal: mode == .horizontal)
        syncAIContextSelection()
    }

    private func openSplitView(with favorite: Favorite, mode: SplitMode) {
        guard vm.selectedTabID != nil else { return }
        if let selectedID = vm.selectedTabID,
           let primary = vm.tabs.first(where: { $0.id == selectedID }) {
            vm.captureTabThumbnail(for: primary)
        }
        let newTab = BrowserTab(title: favorite.title, url: favorite.url, useDesktopUserAgent: requestDesktopSite)
        if let data = favorite.favicon, let image = UIImage(data: data) {
            newTab.favicon = image
        }
        vm.tabs.append(newTab)
        vm.saveSession()
        splitPrimaryID = vm.selectedTabID
        splitSecondaryID = newTab.id
        splitSecondaryExternalTab = nil
        splitMode = mode
        vm.isSplitViewActive = true
        if let primaryID = vm.selectedTabID {
            vm.setSplitPair(primaryID: primaryID, secondaryID: newTab.id, isHorizontal: mode == .horizontal)
        }
        if newTab.favicon == nil {
            vm.fetchFavicon(for: newTab)
        }
        syncAIContextSelection()
    }

    private func openWebProviderSplit(provider: WebAIProvider, mode: SplitMode = .vertical) {
        guard vm.selectedTabID != nil else { return }
        if let existing = activeWebProviderTab, existing.webAIProvider == provider {
            if let selectedID = vm.selectedTabID,
               let primary = vm.tabs.first(where: { $0.id == selectedID }) {
                vm.captureTabThumbnail(for: primary)
            }
            vm.captureTabThumbnail(for: existing)
            splitPrimaryID = vm.selectedTabID
            splitSecondaryID = nil
            splitSecondaryExternalTab = existing
            if isCompactWidth {
                showWebProviderSheet = true
            } else {
                splitMode = mode
                vm.isSplitViewActive = true
                if mode == .vertical {
                    splitVerticalRatio = 0.7
                } else {
                    splitHorizontalRatio = 0.7
                }
            }
            syncAIContextSelection()
            return
        }
        let newTab = BrowserTab(title: provider.displayName, url: provider.url, useDesktopUserAgent: true)
        newTab.webAIProvider = provider
        splitPrimaryID = vm.selectedTabID
        splitSecondaryID = nil
        splitSecondaryExternalTab = newTab
        if isCompactWidth {
            showWebProviderSheet = true
        } else {
            splitMode = mode
            vm.isSplitViewActive = true
            if mode == .vertical {
                splitVerticalRatio = 0.7
            } else {
                splitHorizontalRatio = 0.7
            }
        }
        syncAIContextSelection()
    }

    private func splitDropZone(at location: CGPoint, contentRect: CGRect) -> SplitDropZone? {
        guard (!isCompactWidth || isPhone),
              contentRect.width > 0,
              contentRect.height > 0,
              contentRect.contains(location) else { return nil }

        if isPhone {
            return location.y <= contentRect.midY ? .top : .bottom
        }

        let horizontalZone: (zone: SplitDropZone, distance: CGFloat)
        let distanceToLeft = location.x - contentRect.minX
        let distanceToRight = contentRect.maxX - location.x
        if distanceToLeft <= distanceToRight {
            horizontalZone = (.left, distanceToLeft)
        } else {
            horizontalZone = (.right, distanceToRight)
        }

        let verticalZone: (zone: SplitDropZone, distance: CGFloat)
        let distanceToTop = location.y - contentRect.minY
        let distanceToBottom = contentRect.maxY - location.y
        if distanceToTop <= distanceToBottom {
            verticalZone = (.top, distanceToTop)
        } else {
            verticalZone = (.bottom, distanceToBottom)
        }

        return horizontalZone.distance <= verticalZone.distance
            ? horizontalZone.zone
            : verticalZone.zone
    }

    private func sidebarTabDragGesture(for tab: BrowserTab) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named(splitDragCoordinateSpace))
            .onChanged { value in
                guard (!isCompactWidth || isPhone), tab.webAIProvider == nil else { return }
                if isPhone, isPrimarilyRightwardPhoneSwipe(value.translation) {
                    return
                }
                if isPhone,
                   phoneSecondaryPanel == .tabs,
                   !phonePanelHiddenForTabDrag {
                    withAnimation(.easeOut(duration: 0.16)) {
                        phonePanelHiddenForTabDrag = true
                        phonePanelDragOffset = 0
                    }
                }
                draggedSidebarTabID = tab.id
                sidebarTabDragLocation = value.location
                activeSplitDropZone = splitDropZone(
                    at: value.location,
                    contentRect: splitDropContentRect
                )
            }
            .onEnded { value in
                if isPhone, isPrimarilyRightwardPhoneSwipe(value.translation) {
                    resetSidebarTabDragState()
                    return
                }
                guard draggedSidebarTabID == tab.id else {
                    resetSidebarTabDragState()
                    if isPhone {
                        withAnimation(.easeOut(duration: 0.2)) {
                            phonePanelHiddenForTabDrag = false
                            phonePanelDragOffset = 0
                            phoneSecondaryPanel = .tabs
                        }
                    }
                    return
                }

                let dropZone = splitDropZone(
                    at: value.location,
                    contentRect: splitDropContentRect
                )
                let didDrop = dropZone.map { handleTabDrop(tab.id, in: $0) } ?? false
                resetSidebarTabDragState()
                if isPhone {
                    withAnimation(.easeOut(duration: 0.2)) {
                        phonePanelHiddenForTabDrag = false
                        phonePanelDragOffset = 0
                        phoneSecondaryPanel = didDrop ? .none : .tabs
                    }
                }
            }
    }

    private func resetSidebarTabDragState() {
        draggedSidebarTabID = nil
        sidebarTabDragLocation = nil
        activeSplitDropZone = nil
    }

    private func sidebarTabDragPreview(_ tab: BrowserTab) -> some View {
        HStack(spacing: 10) {
            if let favicon = tab.favicon {
                Image(uiImage: favicon)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: tab.isIncognito ? "eye.slash" : "globe")
                    .font(.body.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(tab.url?.host ?? (tab.isBlank ? "Blank Tab" : tab.address))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 8)
        .scaleEffect(1.03)
    }

    @ViewBuilder
    private func splitDropPreviewOverlay(contentRect: CGRect) -> some View {
        if let activeSplitDropZone {
            splitDropPreview(activeSplitDropZone, contentRect: contentRect)
        }
    }

    private func splitDropPreview(_ zone: SplitDropZone, contentRect: CGRect) -> some View {
        let inset: CGFloat = 10
        let width = zone.mode == .vertical
            ? max(0, contentRect.width / 2 - inset * 1.5)
            : max(0, contentRect.width - inset * 2)
        let height = zone.mode == .horizontal
            ? max(0, contentRect.height / 2 - inset * 1.5)
            : max(0, contentRect.height - inset * 2)
        let x = zone == .left
            ? contentRect.minX + contentRect.width / 4
            : zone == .right
                ? contentRect.minX + contentRect.width * 3 / 4
                : contentRect.midX
        let y = zone == .top
            ? contentRect.minY + contentRect.height / 4
            : zone == .bottom
                ? contentRect.minY + contentRect.height * 3 / 4
                : contentRect.midY

        return ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                )

            Label(zone.title, systemImage: zone.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .frame(width: width, height: height)
        .position(x: x, y: y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func handleTabDrop(_ draggedTabID: UUID, in zone: SplitDropZone) -> Bool {
        activeSplitDropZone = nil
        guard (!isCompactWidth || isPhone),
              let draggedTab = vm.tabs.first(where: { $0.id == draggedTabID }),
              draggedTab.webAIProvider == nil,
              let selectedID = vm.selectedTabID else {
            return false
        }

        if splitMode != nil,
           let primary = splitPrimaryTab,
           let secondary = splitSecondaryTab {
            return updateExistingSplit(
                draggedTab: draggedTab,
                primary: primary,
                secondary: secondary,
                zone: zone
            )
        }

        guard let selectedTab = vm.tabs.first(where: { $0.id == selectedID }) else {
            return false
        }

        if selectedTab.id == draggedTab.id {
            guard let selectedIndex = vm.tabs.firstIndex(where: { $0.id == selectedTab.id }) else {
                return false
            }
            let adjacentIndex: Int?
            if selectedIndex + 1 < vm.tabs.count {
                adjacentIndex = selectedIndex + 1
            } else if selectedIndex > 0 {
                adjacentIndex = selectedIndex - 1
            } else {
                adjacentIndex = nil
            }
            guard let adjacentIndex,
                  vm.tabs.indices.contains(adjacentIndex) else {
                return false
            }
            let adjacentTab = vm.tabs[adjacentIndex]
            if zone.isLeading {
                return setRegularTabSplit(
                    primary: draggedTab,
                    secondary: adjacentTab,
                    mode: zone.mode,
                    selectionFallbackID: draggedTab.id
                )
            } else {
                return setRegularTabSplit(
                    primary: adjacentTab,
                    secondary: draggedTab,
                    mode: zone.mode,
                    selectionFallbackID: draggedTab.id
                )
            }
        }

        if zone.isLeading {
            return setRegularTabSplit(
                primary: draggedTab,
                secondary: selectedTab,
                mode: zone.mode,
                selectionFallbackID: draggedTab.id
            )
        } else {
            return setRegularTabSplit(
                primary: selectedTab,
                secondary: draggedTab,
                mode: zone.mode,
                selectionFallbackID: draggedTab.id
            )
        }
    }

    private func updateExistingSplit(
        draggedTab: BrowserTab,
        primary: BrowserTab,
        secondary: BrowserTab,
        zone: SplitDropZone
    ) -> Bool {
        let target = zone.isLeading ? primary : secondary
        if draggedTab.id == target.id {
            return true
        }

        if draggedTab.id == primary.id {
            if zone.isLeading {
                return true
            }
            if splitSecondaryExternalTab != nil {
                guard let replacement = vm.tabs.first(where: { $0.id != draggedTab.id }) else {
                    clearSplitView()
                    return true
                }
                return setRegularTabSplit(
                    primary: replacement,
                    secondary: draggedTab,
                    mode: zone.mode,
                    selectionFallbackID: draggedTab.id
                )
            }
            return setRegularTabSplit(
                primary: secondary,
                secondary: draggedTab,
                mode: zone.mode,
                selectionFallbackID: draggedTab.id
            )
        }

        if draggedTab.id == secondary.id {
            if zone.isLeading {
                return setRegularTabSplit(
                    primary: draggedTab,
                    secondary: primary,
                    mode: zone.mode,
                    selectionFallbackID: draggedTab.id
                )
            }
            return true
        }

        if zone.isLeading {
            if let external = splitSecondaryExternalTab {
                return setExternalSecondarySplit(
                    primary: draggedTab,
                    external: external,
                    mode: zone.mode,
                    selectionFallbackID: draggedTab.id
                )
            }
            return setRegularTabSplit(
                primary: draggedTab,
                secondary: secondary,
                mode: zone.mode,
                selectionFallbackID: draggedTab.id
            )
        }

        return setRegularTabSplit(
            primary: primary,
            secondary: draggedTab,
            mode: zone.mode,
            selectionFallbackID: draggedTab.id
        )
    }

    @discardableResult
    private func setRegularTabSplit(
        primary: BrowserTab,
        secondary: BrowserTab,
        mode: SplitMode,
        selectionFallbackID: UUID?
    ) -> Bool {
        guard primary.id != secondary.id else { return false }
        vm.captureTabThumbnail(for: primary)
        vm.captureTabThumbnail(for: secondary)
        splitPrimaryID = primary.id
        splitSecondaryID = secondary.id
        splitSecondaryExternalTab = nil
        splitMode = mode
        vm.isSplitViewActive = true
        vm.setSplitPair(primaryID: primary.id, secondaryID: secondary.id, isHorizontal: mode == .horizontal)
        if let selectedID = vm.selectedTabID,
           selectedID != primary.id,
           selectedID != secondary.id {
            vm.selectedTabID = selectionFallbackID ?? primary.id
        }
        refreshHibernationProtection()
        syncAIContextSelection()
        return true
    }

    @discardableResult
    private func setExternalSecondarySplit(
        primary: BrowserTab,
        external: BrowserTab,
        mode: SplitMode,
        selectionFallbackID: UUID?
    ) -> Bool {
        vm.captureTabThumbnail(for: primary)
        vm.captureTabThumbnail(for: external)
        splitPrimaryID = primary.id
        splitSecondaryID = nil
        splitSecondaryExternalTab = external
        splitMode = mode
        vm.isSplitViewActive = true
        if let selectedID = vm.selectedTabID,
           selectedID != primary.id,
           selectedID != external.id {
            vm.selectedTabID = selectionFallbackID ?? primary.id
        }
        refreshHibernationProtection()
        syncAIContextSelection()
        return true
    }

    private func scheduleSplitThumbnailRefresh() {
        guard splitMode == nil else { return }
        scheduleThumbnailRefresh(for: [splitPrimaryTab, splitSecondaryTab].compactMap { $0 })
    }

    private func scheduleActiveThumbnailRefresh() {
        guard let idx = vm.selectedIndex else { return }
        scheduleThumbnailRefresh(for: [vm.tabs[idx]])
    }

    private func scheduleThumbnailRefresh(for tabs: [BrowserTab]) {
        guard !tabs.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Task { @MainActor in
                for tab in tabs {
                    vm.captureTabThumbnail(for: tab)
                }
            }
        }
    }

    private func handleBackendSelection(_ backend: AIModelBackend) {
        switch backend {
        case .webChatGPT:
            if activeWebProviderTab != nil {
                clearSplitView()
            }
        case .webGemini:
            if activeWebProviderTab != nil {
                clearSplitView()
            }
        case .localApple:
            BrowserWebAISessionManager.shared.releaseAllWebViews()
            if activeWebProviderTab != nil {
                clearSplitView()
            }
            aiService.warmUpAppleLocalIfNeeded()
        case .mlxLocal:
            BrowserWebAISessionManager.shared.releaseAllWebViews()
            if activeWebProviderTab != nil {
                clearSplitView()
            }
            aiService.warmUpMLXIfNeeded()
        default:
            BrowserWebAISessionManager.shared.releaseAllWebViews()
            if activeWebProviderTab != nil {
                clearSplitView()
            }
        }
    }

    private func handleWebProviderReady(_ tab: BrowserTab) {
        guard let tabProvider = tab.webAIProvider,
              let prompt = pendingWebProviderPrompt,
              let provider = pendingWebProviderProvider else { return }
        if let targetID = pendingWebProviderTargetID, targetID != tab.id {
            return
        }
        if tabProvider != provider {
            return
        }
        let contextOverride = pendingWebProviderContextOverride
        pendingWebProviderPrompt = nil
        pendingWebProviderProvider = nil
        pendingWebProviderTargetID = nil
        pendingWebProviderContextOverride = nil
        handleWebProviderPrompt(provider: provider, prompt: prompt, from: tab.activateWebView(), contextOverride: contextOverride)
    }

    @MainActor
    private func handlePrimaryNavigation(_ tab: BrowserTab, url: URL) {
        guard tab.webAIProvider == nil,
              tab.id == splitPrimaryID else { return }
        let urlString = normalizedContextURL(url)
        if lastPrimaryURLString == urlString {
            return
        }
        lastPrimaryURLString = urlString
        if webProviderContextTabID == tab.id,
           let contextURLString = webProviderContextURLString,
           contextURLString != urlString {
            resetWebProviderContext()
            return
        }
        guard let providerTab = activeWebProviderTab,
              let provider = providerTab.webAIProvider else { return }
        pendingWebProviderPrompt = nil
        pendingWebProviderProvider = nil
        pendingWebProviderTargetID = nil
        pendingWebProviderContextOverride = nil
        providerTab.activateWebView().load(URLRequest(url: provider.url))
    }

    @MainActor
    private func handleAutofillPrivacyNavigation(_ tab: BrowserTab, webView: WKWebView, url: URL) {
        guard tab.liveWebView === webView else { return }
        BrowserAgentAutofillPrivacy.shared.reconcileNavigation(
            tabID: tab.id,
            webView: webView,
            navigationURL: url
        ) { [weak tab] in
            guard let tab, tab.liveWebView === webView else { return false }
            return self.browserTab(withID: tab.id) === tab || self.splitSecondaryExternalTab === tab
        }
    }

    /// Shows a saved split pair again when one of its tabs is selected.
    private func restoreSplitPairIfNeeded() {
        guard splitMode == nil,
              splitSecondaryExternalTab == nil,
              !showWebProviderSheet,
              let selectedID = vm.selectedTabID,
              let pair = vm.splitPair(containing: selectedID),
              let primary = browserTab(withID: pair.primaryID),
              let secondary = browserTab(withID: pair.secondaryID) else { return }
        splitPrimaryID = primary.id
        splitSecondaryID = secondary.id
        splitSecondaryExternalTab = nil
        splitMode = pair.isHorizontal ? .horizontal : .vertical
        vm.isSplitViewActive = true
        _ = primary.activateWebView()
        _ = secondary.activateWebView()
        refreshHibernationProtection()
        syncAIContextSelection()
    }

    /// Ends the split for good: the pair is forgotten and both tabs become normal tabs.
    private func endSplitPair() {
        if let primaryID = splitPrimaryID {
            vm.removeSplitPair(containing: primaryID)
        }
        clearSplitView()
    }

    private func clearSplitView() {
        activeSplitDropZone = nil
        let tabsToRefresh = [splitPrimaryTab, splitSecondaryTab].compactMap { $0 }
        splitMode = nil
        splitPrimaryID = nil
        splitSecondaryID = nil
        splitSecondaryExternalTab = nil
        lastInteractedSplitTabID = nil
        showWebProviderSheet = false
        pendingWebProviderPrompt = nil
        pendingWebProviderProvider = nil
        pendingWebProviderTargetID = nil
        pendingWebProviderContextOverride = nil
        lastPrimaryURLString = nil
        webProviderContextTabID = nil
        webProviderContextURLString = nil
        vm.isSplitViewActive = false
        syncAIContextSelection()
        if tabsToRefresh.isEmpty {
            scheduleActiveThumbnailRefresh()
        } else {
            scheduleThumbnailRefresh(for: tabsToRefresh)
        }
    }

    private func syncSplitState() {
        guard splitMode != nil || showWebProviderSheet else { return }
        guard let primaryID = splitPrimaryID else {
            clearSplitView()
            return
        }
        let hasPrimary = vm.tabs.contains { $0.id == primaryID }
        let hasSecondary = splitSecondaryExternalTab != nil
            || (splitSecondaryID != nil && vm.tabs.contains { $0.id == splitSecondaryID })
        if !hasPrimary || !hasSecondary {
            clearSplitView()
            return
        }

        if let selectedID = vm.selectedTabID,
           selectedID != primaryID && selectedID != splitSecondaryID {
            clearSplitView()
        }
    }

    private func aiContextOption(for tab: BrowserTab) -> AISidebar.ContextOption {
        let title = tab.title.isEmpty ? "New Tab" : tab.title
        let subtitle = tab.url?.host ?? (tab.isBlank ? "Blank Tab" : tab.address)
        return AISidebar.ContextOption(
            id: tab.id,
            title: title,
            subtitle: subtitle,
            webView: tab.liveWebView as WKWebView?,
            isPrivate: tab.isIncognito
        )
    }

    /// Marks a split-view pane as the one the user is working in so AI
    /// queries target it without requiring a manual tab selection.
    private func handleSplitPaneInteraction(_ tab: BrowserTab) {
        guard splitMode != nil, tab.webAIProvider == nil else { return }
        if lastInteractedSplitTabID != tab.id {
            lastInteractedSplitTabID = tab.id
        }
        if aiContextTabID != tab.id {
            aiContextTabID = tab.id
        }
    }

    private func syncAIContextSelection(
        previousSelectedTabID: UUID? = nil,
        forceVisibleTab: Bool = false
    ) {
        let options = aiContextOptions
        guard !options.isEmpty else {
            aiContextTabID = nil
            return
        }
        let preferredSplitTabID: UUID?
        if splitMode != nil,
           let lastInteracted = lastInteractedSplitTabID,
           options.contains(where: { $0.id == lastInteracted }) {
            preferredSplitTabID = lastInteracted
        } else {
            preferredSplitTabID = nil
        }
        if forceVisibleTab,
           let preferred = preferredSplitTabID ?? vm.selectedTabID,
           options.contains(where: { $0.id == preferred }) {
            aiContextTabID = preferred
            return
        }
        if let selected = aiContextTabID,
           options.contains(where: { $0.id == selected }) {
            if let previousSelectedTabID,
               selected == previousSelectedTabID,
               let currentSelected = preferredSplitTabID ?? vm.selectedTabID,
               options.contains(where: { $0.id == currentSelected }) {
                aiContextTabID = currentSelected
            }
            return
        }
        if let preferred = preferredSplitTabID,
           options.contains(where: { $0.id == preferred }) {
            aiContextTabID = preferred
        } else if let currentSelected = vm.selectedTabID,
                  options.contains(where: { $0.id == currentSelected }) {
            aiContextTabID = currentSelected
        } else {
            aiContextTabID = options.first?.id
        }
    }

    @MainActor
    private func prepareAIContext() {
        let tab = activeAIContextTab
        let contextURL = tab?.currentURL
        let isPrivate = tab?.isIncognito ?? false
        if AIConversationContextPolicy.preservesConversation(
            previousContextWasPrivate: aiContextWasPrivate,
            nextContextIsPrivate: isPrivate
        ) {
            aiService.updateContextPreservingConversation(contextURL)
        } else {
            aiService.prepareForNewContext(contextURL)
        }
        aiContextWasPrivate = isPrivate
    }

    @MainActor
    private func pageContextBinding(for tab: BrowserTab) -> BrowserAgentPageContextBinding? {
        guard let webView = tab.liveWebView,
              let url = webView.url ?? tab.currentURL else { return nil }
        return BrowserAgentPageContextBinding(tabID: tab.id, webView: webView, url: url)
    }

    @MainActor
    private func pageContextIsAllowed(
        for tab: BrowserTab,
        capturedBinding: BrowserAgentPageContextBinding? = nil
    ) -> Bool {
        let privacy = BrowserAgentAutofillPrivacy.shared
        guard !privacy.withholdsPageData(tabID: tab.id) else { return false }
        guard let capturedBinding else { return true }
        guard let currentBinding = pageContextBinding(for: tab) else { return false }
        if case .blocked = BrowserAgentModelEgress.evaluate(
            nil,
            captured: capturedBinding,
            current: currentBinding,
            privacy: privacy
        ) {
            return false
        }
        return true
    }

    @MainActor
    private func safePageText(
        _ text: String,
        for tab: BrowserTab,
        capturedBinding: BrowserAgentPageContextBinding? = nil
    ) -> String? {
        let privacy = BrowserAgentAutofillPrivacy.shared
        guard let currentBinding = pageContextBinding(for: tab) else { return nil }
        switch BrowserAgentModelEgress.evaluate(
            text,
            captured: capturedBinding ?? currentBinding,
            current: currentBinding,
            privacy: privacy
        ) {
        case .allowed(let safeText):
            return safeText.map { privacy.redactPotentiallyTruncated($0, wasTruncated: true) }
        case .blocked:
            return nil
        }
    }

    @MainActor
    private func reportBlockedPageContext() {
        aiService.discardSourcePageContextForPrivacy()
        aiService.appendAssistantMessage("Page-derived content from a tab that received autofill stays out of agent context. Switch to an unfilled tab to continue.")
    }

    @MainActor
    private func handleAgentAutofillQuarantine(tabID: UUID, webView: WKWebView) {
        aiPageContentCache.removeValue(forKey: tabID)
        if pendingAISelection?.tabID == tabID {
            if let selection = pendingAISelection { clearAISelectionHighlight(selection) }
            pendingAISelection = nil
            pendingAIReplacement = nil
        }
        if aiSelectionContext?.tabID == tabID {
            clearAISelectionContext()
        }
        pendingAIQueryTask?.cancel()
        pendingAIQueryTask = nil
        pendingAIQueryToken = UUID()
        aiService.installModelEgressRedactor { text in
            BrowserAgentAutofillPrivacy.shared.redactPotentiallyTruncated(text, wasTruncated: true)
        }
        if let pendingRedditPreflight,
           pendingRedditPreflight.sourceTabID == tabID {
            self.pendingRedditPreflight = nil
        }
        aiService.discardSourcePageContextForPrivacy()

        if webProviderContextTabID == tabID {
            pendingWebProviderPrompt = nil
            pendingWebProviderProvider = nil
            pendingWebProviderTargetID = nil
            pendingWebProviderContextOverride = nil
            webProviderContextTabID = nil
            webProviderContextURLString = nil
        }
        if activeWebAIRequest?.sourceBinding?.tabID == tabID {
            dismissWebAIOverlay(userCancelled: true)
        }
        _ = webView
    }

    @MainActor
    private func browserAgentPageContextCanTransmit(_ binding: BrowserAgentPageContextBinding?) -> Bool {
        guard let binding else { return true }
        guard let tab = browserTab(withID: binding.tabID) ?? splitSecondaryExternalTab,
              tab.id == binding.tabID else { return false }
        guard pageContextIsAllowed(for: tab, capturedBinding: binding) else {
            reportBlockedPageContext()
            return false
        }
        return true
    }

    private func webProviderContextSourceTab() -> BrowserTab? {
        if let id = aiContextTabID,
           let tab = vm.tabs.first(where: { $0.id == id && $0.webAIProvider == nil }) {
            return tab
        }
        if let id = aiContextTabID,
           let external = splitSecondaryExternalTab,
           external.id == id,
           external.webAIProvider == nil {
            return external
        }
        if let primary = splitPrimaryTab, primary.webAIProvider == nil {
            return primary
        }
        return vm.tabs.first(where: { $0.id == vm.selectedTabID && $0.webAIProvider == nil })
    }

    private func handleAskAISelection(in tab: BrowserTab) {
        guard pageContextIsAllowed(for: tab) else {
            reportBlockedPageContext()
            return
        }
        let webView = tab.liveWebView ?? tab.activateWebView()
        guard let selectionURL = webView.url ?? tab.currentURL else { return }
        let capturedBinding = BrowserAgentPageContextBinding(tabID: tab.id, webView: webView, url: selectionURL)
        if let existing = pendingAISelection {
            clearAISelectionHighlight(existing)
            pendingAISelection = nil
            aiSelectionContext = nil
        }
        let markerID = "codex-ai-\(UUID().uuidString)"
        let script = """
        (function() {
          var sel = window.getSelection();
          if (!sel || sel.rangeCount === 0) { return null; }
          var range = sel.getRangeAt(0);
          if (range.collapsed) { return null; }
          var text = sel.toString();
          var span = document.createElement('span');
          span.id = '\(markerID)';
          span.setAttribute('data-codex-ai', 'pending');
          span.style.backgroundColor = 'rgba(255, 213, 0, 0.18)';
          var frag = range.extractContents();
          span.appendChild(frag);
          range.insertNode(span);
          sel.removeAllRanges();
          return text;
        })();
        """

        webView.evaluateJavaScript(script) { result, _ in
            guard tab.liveWebView === webView,
                  self.pageContextIsAllowed(for: tab, capturedBinding: capturedBinding) else {
                self.reportBlockedPageContext()
                return
            }
            let rawSelectedText = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let selectedText = BrowserAgentAutofillPrivacy.shared.redactKnownValues(rawSelectedText)
            guard !selectedText.isEmpty else { return }
            pendingAISelection = AISelection(tabID: tab.id, markerID: markerID, text: selectedText)
            aiSelectionContext = AISelectionContext(tabID: tab.id, text: selectedText)
            aiContextTabID = tab.id
            aiHasUnreadResponse = false
            if isPhone {
                togglePhoneSecondaryPanel(.ai)
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    showAIPanel = true
                }
            }
        }
    }

    private func applyAIReplacement(_ text: String, to replacement: AIReplacement) {
        guard let tab = tabForID(replacement.tabID) else { return }
        let escaped = jsonStringLiteral(text)
        let script = """
        (function() {
          var span = document.getElementById('\(replacement.markerID)');
          if (!span) { return false; }
          span.textContent = \(escaped);
          span.style.backgroundColor = 'transparent';
          span.removeAttribute('data-codex-ai');
          return true;
        })();
        """
        tab.activateWebView().evaluateJavaScript(script, completionHandler: nil)
    }

    private func clearAISelectionHighlight(_ selection: AISelection) {
        guard let tab = tabForID(selection.tabID) else { return }
        let script = """
        (function() {
          var span = document.getElementById('\(selection.markerID)');
          if (!span) { return false; }
          var parent = span.parentNode;
          if (!parent) { return false; }
          while (span.firstChild) { parent.insertBefore(span.firstChild, span); }
          parent.removeChild(span);
          return true;
        })();
        """
        tab.activateWebView().evaluateJavaScript(script, completionHandler: nil)
    }

    private func clearAISelectionContext() {
        aiSelectionContext = nil
    }

    private func tabForID(_ id: UUID) -> BrowserTab? {
        if let tab = vm.tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let external = splitSecondaryExternalTab, external.id == id {
            return external
        }
        return nil
    }

    private func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }

    private func toggleReaderMode(for tab: BrowserTab) {
        guard let url = tab.currentURL else { return }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        tab.activateWebView().evaluateJavaScript(ReaderModeService.toggleScript) { result, _ in
            let enabled = (result as? Bool) == true
            Task { @MainActor in
                tab.isReaderMode = enabled
            }
        }
    }

    private func toggleDarkMode(for tab: BrowserTab) {
        if tab.hasDarkModeOverride {
            tab.isDarkMode.toggle()
        } else {
            tab.isDarkMode = !darkModeService.isDarkMode
            tab.hasDarkModeOverride = true
        }

        // Mark this webview as having a per-tab override so global toggle won't affect it
        let webView = tab.activateWebView()
        DarkModeService.shared.setOverride(for: webView, hasOverride: true)

        if tab.isDarkMode {
            DarkModeService.shared.enableDarkMode(for: webView)
        } else {
            DarkModeService.shared.disableDarkMode(for: webView)
        }
        webView.overrideUserInterfaceStyle = tab.isDarkMode ? .dark : .light
        tab.lastAppliedDarkMode = tab.isDarkMode
    }

    private func effectiveDarkMode(for tab: BrowserTab) -> Bool {
        tab.hasDarkModeOverride ? tab.isDarkMode : darkModeService.isDarkMode
    }

    private func applyUserAgentPreference() {
        let useDesktop = requestDesktopSite
        vm.setUserAgentPreference(useDesktop)
        if let external = splitSecondaryExternalTab {
            external.setUserAgentPreference(useDesktop)
        }
        reloadVisibleTabsForUserAgentChange()
    }

    private func reloadVisibleTabsForUserAgentChange() {
        if splitMode != nil {
            reloadTabIfNeeded(splitPrimaryTab)
            reloadTabIfNeeded(splitSecondaryTab)
        } else if let idx = vm.selectedIndex {
            reloadTabIfNeeded(vm.tabs[idx])
        }
    }

    private func reloadTabIfNeeded(_ tab: BrowserTab?) {
        guard let tab, tab.currentURL != nil else { return }
        tab.activateWebView().reload()
    }

    private var sidebarPanel: some View {
        VStack(spacing: 12) {
            sidebarContent
            Spacer(minLength: 0)
            settingsButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: currentSidebarWidth)
        .opacity(currentSidebarWidth > 0 ? 1 : 0)
        .allowsHitTesting(currentSidebarWidth > 1)
        .background(
            sidebarBackground
        )
        .clipShape(RoundedRectangle(cornerRadius: sidebarCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: sidebarCornerRadius, style: .continuous)
                .strokeBorder(BrowserDesign.chromeBorder(isDark: isSidebarDark), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(isSidebarDark ? 0.4 : 0.2),
            radius: 18,
            x: 0,
            y: 10
        )
        .contentShape(RoundedRectangle(cornerRadius: sidebarCornerRadius, style: .continuous))
    }

    private var phoneSidebarPanel: some View {
        VStack(spacing: 8) {
            sidebarContent
            Spacer(minLength: 0)
            settingsButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(sidebarBackground)
        .clipShape(RoundedRectangle(cornerRadius: sidebarCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: sidebarCornerRadius, style: .continuous)
                .strokeBorder(BrowserDesign.chromeBorder(isDark: isSidebarDark), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(isSidebarDark ? 0.4 : 0.2),
            radius: 18,
            x: 0,
            y: 10
        )
        .contentShape(RoundedRectangle(cornerRadius: sidebarCornerRadius, style: .continuous))
    }

    private var sidebarContent: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 10) {
                BrowserTabSearchField(
                    searchText: $tabSearchText,
                    isFocused: $tabSearchFocused,
                    showsShortcutHint: !isPhone
                )
                .dynamicTypeSize(...DynamicTypeSize.xLarge)

                // Folders, then favorites, each one row that scrolls sideways; hidden while searching tabs.
                if tabSearchText.isEmpty {
                    favoritesSection
                }

                tabsSectionHeader
                tabGroupChips

                ForEach(sidebarTabEntries) { entry in
                    switch entry {
                    case .single(let tab):
                        TabRowView(tab: tab, showsPreview: !tabPreviewsCollapsed) { observedTab in
                            tabRow(observedTab)
                        }
                    case .pair(let primary, let secondary):
                        TabRowView(tab: primary, showsPreview: !tabPreviewsCollapsed) { observedPrimary in
                            TabRowView(tab: secondary, showsPreview: !tabPreviewsCollapsed) { observedSecondary in
                                splitPairRow(primary: observedPrimary, secondary: observedSecondary)
                            }
                        }
                    }
                }

                if visibleSidebarTabs.isEmpty {
                    Text(tabSearchText.isEmpty ? "No tabs in this group." : "No matching tabs.")
                        .font(.subheadline)
                        .foregroundStyle(sidebarSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }

                if tabSearchText.isEmpty && !vm.recentlyClosedTabs.isEmpty {
                    recentlyClosedRow
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func focusTabSearch() {
        if isPhone {
            if phoneSecondaryPanel != .tabs {
                togglePhoneSecondaryPanel(.tabs)
            }
        } else if isSidebarCollapsed {
            withAnimation(.easeOut(duration: 0.15)) {
                isSidebarCollapsed = false
                sidebarDrag = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            tabSearchFocused = true
        }
    }

    /// "Tabs" with the open count; the count opens the tab group menu.
    private var tabsSectionHeader: some View {
        HStack(spacing: 8) {
            sidebarSectionHeader("Tabs", systemImage: "rectangle.on.rectangle")
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if isHoldingNewTab {
                    Label("Hold for private tab", systemImage: "eye.slash")
                        .transition(.opacity)
                } else {
                    Text(tabScopeSummary)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isHoldingNewTab)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(sidebarSecondaryText)
            .frame(minHeight: 44)
            .padding(.top, 8)

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    tabPreviewsCollapsed.toggle()
                }
            } label: {
                Image(systemName: tabPreviewsCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    .font(.system(size: sidebarIconFontSize, weight: .semibold))
                    .foregroundColor(sidebarSecondaryText)
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .accessibilityLabel(tabPreviewsCollapsed ? "Show tab previews" : "Hide tab previews")

            // Tap for a new tab; press and hold for a new private tab. While held, a ring fills
            // around the button and the header says what will happen.
            ZStack {
                Circle()
                    .fill(sidebarIconBackground)
                Circle()
                    .trim(from: 0, to: newTabHoldProgress)
                    .stroke(sidebarPrimaryText, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "plus")
                    .font(.system(size: sidebarIconFontSize, weight: .semibold))
                    .foregroundColor(sidebarPrimaryText)
            }
            .frame(width: 36, height: 36)
            .scaleEffect(isHoldingNewTab ? 1.15 : 1)
            .animation(.easeOut(duration: 0.15), value: isHoldingNewTab)
            .contentShape(Circle())
            .gesture(
                // Tap and hold are timed by hand: a quick tap must always open a normal tab,
                // and the ring only appears once the finger has stayed down for a moment.
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if newTabHoldTimers.isEmpty && !newTabHoldFired {
                            startNewTabHold()
                        } else if hypot(value.translation.width, value.translation.height) > 30 {
                            // Finger slid away: cancel, and do nothing more until it lifts.
                            cancelNewTabHold()
                            newTabHoldFired = true
                        }
                    }
                    .onEnded { value in
                        let fired = newTabHoldFired
                        let wasTracking = !newTabHoldTimers.isEmpty
                        cancelNewTabHold()
                        newTabHoldFired = false
                        guard !fired, wasTracking,
                              hypot(value.translation.width, value.translation.height) <= 30 else { return }
                        vm.addTabBlank()
                        omniboxFocused = true
                    }
            )
            .onChange(of: isHoldingNewTab) { _, holding in
                if holding {
                    newTabHoldProgress = 0
                    withAnimation(.linear(duration: 0.45)) { newTabHoldProgress = 1 }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { newTabHoldProgress = 0 }
                }
            }
            .help("New Tab · hold for a private tab")
                .padding(.top, 8)
                .accessibilityLabel("New Tab")
                .accessibilityHint("Touch and hold for a private tab")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    vm.addTabBlank()
                    omniboxFocused = true
                }
                .accessibilityAction(named: "New Private Tab") {
                    openIncognitoTab()
                }

            if !isPhone {
                sidebarPinButton(
                    isPinned: $pinTabSidebar,
                    label: "tab sidebar"
                )
            }
        }
    }

    /// Finger down on ＋: after 0.15 s show the ring, after 0.6 s open a private tab.
    private func startNewTabHold() {
        let showRing = DispatchWorkItem {
            isHoldingNewTab = true
        }
        let openPrivate = DispatchWorkItem {
            newTabHoldFired = true
            isHoldingNewTab = false
            newTabHoldTimers = []
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if isPhone {
                dismissPhoneSecondaryPanel()
            }
            openIncognitoTab()
        }
        newTabHoldTimers = [showRing, openPrivate]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: showRing)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: openPrivate)
    }

    private func cancelNewTabHold() {
        newTabHoldTimers.forEach { $0.cancel() }
        newTabHoldTimers = []
        isHoldingNewTab = false
    }

    private enum TabGroupNamePrompt: Identifiable {
        case new
        case rename(BrowserTabGroup)

        var id: String {
            switch self {
            case .new: return "new"
            case .rename(let group): return group.id.uuidString
            }
        }
    }

    /// All, each group, and "+ Group". Tap to switch; hold a group to rename or delete it.
    /// Tabs move between groups from their long-press menu.
    private var tabGroupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                groupChip(
                    title: "All",
                    systemImage: nil,
                    count: vm.tabs.count,
                    isSelected: selectedTabScope == .all
                ) {
                    selectedTabScope = .all
                }

                ForEach(vm.tabGroups) { group in
                    groupChip(
                        title: group.title,
                        systemImage: "folder",
                        count: vm.tabs.filter { $0.groupID == group.id }.count,
                        isSelected: selectedTabScope == .group(group.id)
                    ) {
                        selectedTabScope = .group(group.id)
                    }
                    .contextMenu {
                        Button {
                            tabGroupNameText = group.title
                            tabGroupNamePrompt = .rename(group)
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                        Button {
                            showTabGroupManager = true
                        } label: {
                            Label("Manage Groups…", systemImage: "folder.badge.gearshape")
                        }
                        Divider()
                        Button(role: .destructive) {
                            vm.deleteTabGroup(group)
                        } label: {
                            Label("Delete Group", systemImage: "trash")
                        }
                    }
                }

                Button {
                    tabGroupNameText = ""
                    tabGroupNamePrompt = .new
                } label: {
                    Label("Group", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(sidebarSecondaryText)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .overlay(
                            Capsule().strokeBorder(
                                sidebarSecondaryText.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New tab group")
            }
            .padding(.vertical, 2)
        }
        .alert(
            tabGroupNamePromptTitle,
            isPresented: Binding(
                get: { tabGroupNamePrompt != nil },
                set: { if !$0 { tabGroupNamePrompt = nil } }
            )
        ) {
            TextField("Name", text: $tabGroupNameText)
            Button("Cancel", role: .cancel) {
                tabGroupNamePrompt = nil
            }
            Button("Save") {
                saveTabGroupName()
            }
        }
    }

    private var tabGroupNamePromptTitle: String {
        switch tabGroupNamePrompt {
        case .rename: return "Rename Group"
        default: return "New Tab Group"
        }
    }

    private func saveTabGroupName() {
        let name = tabGroupNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tabGroupNamePrompt {
        case .new:
            let group = vm.createTabGroup(title: name)
            selectedTabScope = .group(group.id)
        case .rename(let group):
            if !name.isEmpty {
                vm.renameTabGroup(group, title: name)
            }
        case nil:
            break
        }
        tabGroupNamePrompt = nil
    }

    private func groupChip(
        title: String,
        systemImage: String?,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        return Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
                Text("\(count)")
                    .foregroundStyle(sidebarSecondaryText)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(sidebarPrimaryText)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            // Every chip shares the same plain look; blue text on a pale blue fill was
            // hard to read in light mode.
            .background(
                Capsule().fill(sidebarIconBackground)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) tabs")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var tabScopeSummary: String {
        "\(visibleSidebarTabs.count) open"
    }

    private var recentlyClosedRow: some View {
        Button {
            showHistory = true
        } label: {
            HStack(spacing: 10) {
                sidebarIconContainer {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: sidebarIconFontSize, weight: .semibold))
                        .foregroundColor(sidebarPrimaryText)
                }
                Text("Recently Closed")
                    .font(.system(size: sidebarTitleFontSize, weight: .semibold))
                    .foregroundColor(sidebarPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(vm.recentlyClosedTabs.count)")
                    .font(.system(size: sidebarSubtitleFontSize))
                    .foregroundColor(sidebarSecondaryText)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(sidebarSecondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .glassEffectCompat(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                material: .ultraThinMaterial,
                tint: sidebarRowBackground,
                strokeOpacity: isSidebarDark ? 0.35 : 0.45
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityHint("Opens history")
    }

    private func sidebarPinButton(isPinned: Binding<Bool>, label: String) -> some View {
        Button {
            isPinned.wrappedValue.toggle()
        } label: {
            Image(systemName: isPinned.wrappedValue ? "pin.fill" : "pin")
                .font(.system(size: sidebarSectionFontSize, weight: .semibold))
                .foregroundStyle(isPinned.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(sidebarSecondaryText))
                .frame(width: BrowserDesign.Size.hitTarget, height: BrowserDesign.Size.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityLabel(isPinned.wrappedValue ? "Unpin \(label)" : "Pin \(label)")
        .accessibilityHint("When pinned, tapping the page keeps the sidebar open")
    }

    @ViewBuilder
    private func splitViewMenuItems(canSplit: Bool, open: @escaping (SplitMode) -> Void) -> some View {
        if !isPhone {
            Button {
                open(.vertical)
            } label: {
                Label("Open Side by Side", systemImage: "rectangle.split.2x1")
            }
            .disabled(!canSplit)
        }
        Button {
            open(.horizontal)
        } label: {
            Label("Open Top and Bottom", systemImage: "rectangle.split.1x2")
        }
        .disabled(!canSplit)
    }

    private var visibleSidebarTabs: [BrowserTab] {
        vm.tabs(matching: tabSearchText, scope: selectedTabScope)
    }

    private func sidebarSectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: sidebarSectionFontSize, weight: .semibold))
            .foregroundColor(sidebarSecondaryText)
            .padding(.top, 8)
            .padding(.leading, 6)
    }

    private func sidebarRow<Icon: View>(
        title: String,
        subtitle: String? = nil,
        isSelected: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let tint = isSelected ? sidebarRowSelectedBackground : sidebarRowBackground
        let material: Material = isSelected ? .regularMaterial : .ultraThinMaterial
        return Button(action: action) {
            HStack(spacing: 10) {
                sidebarIconContainer {
                    icon()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: sidebarTitleFontSize, weight: .semibold))
                        .foregroundColor(sidebarPrimaryText)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: sidebarSubtitleFontSize))
                            .foregroundColor(sidebarSecondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .glassEffectCompat(
                in: shape,
                material: material,
                tint: tint,
                strokeOpacity: isSidebarDark ? 0.35 : 0.45
            )
        }
        .buttonStyle(.plain)
    }

    private func sidebarIconContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(sidebarIconBackground)
            content()
        }
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func performClose(_ tab: BrowserTab) {
        Task { @MainActor in
            if splitMode != nil,
               tab.id == splitPrimaryID || tab.id == splitSecondaryID {
                clearSplitView()
            }
            vm.closeTab(tab)
        }
    }

    /// A tab on its own, or two tabs saved together in split view.
    private enum SidebarTabEntry: Identifiable {
        case single(BrowserTab)
        case pair(BrowserTab, BrowserTab)

        var id: UUID {
            switch self {
            case .single(let tab): return tab.id
            case .pair(let primary, _): return primary.id
            }
        }
    }

    /// The visible tabs in order, with each split pair shown once, where its first tab sits.
    private var sidebarTabEntries: [SidebarTabEntry] {
        let visible = visibleSidebarTabs
        let visibleIDs = Set(visible.map(\.id))
        var shown = Set<UUID>()
        var entries: [SidebarTabEntry] = []
        for tab in visible where !shown.contains(tab.id) {
            if let pair = vm.splitPair(containing: tab.id),
               let partnerID = pair.partner(of: tab.id),
               visibleIDs.contains(partnerID),
               let primary = vm.tabs.first(where: { $0.id == pair.primaryID }),
               let secondary = vm.tabs.first(where: { $0.id == pair.secondaryID }) {
                entries.append(.pair(primary, secondary))
                shown.formUnion([primary.id, secondary.id])
            } else {
                entries.append(.single(tab))
                shown.insert(tab.id)
            }
        }
        return entries
    }

    /// One card for a split pair: both pages side by side. Tap a half to show the pair;
    /// the ✕ separates them and both stay open as normal tabs.
    private func splitPairRow(primary: BrowserTab, secondary: BrowserTab) -> some View {
        let isActive = vm.selectedTabID == primary.id || vm.selectedTabID == secondary.id
        let isHorizontal = vm.splitPair(containing: primary.id)?.isHorizontal ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isHorizontal ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    .font(.system(size: sidebarIconFontSize, weight: .semibold))
                    .foregroundColor(sidebarSecondaryText)
                Text("Split View")
                    .font(.system(size: sidebarSubtitleFontSize, weight: .semibold))
                    .foregroundColor(sidebarSecondaryText)
                Spacer(minLength: 0)
                Button {
                    separateSplitPair(containing: primary.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(sidebarPrimaryText)
                        .padding(6)
                        .background(Circle().fill(sidebarIconBackground))
                }
                .buttonStyle(.plain)
                .frame(width: 40, height: 32)
                .contentShape(Rectangle())
                .accessibilityLabel("Separate split view")
                .accessibilityHint("Both tabs stay open")
            }

            HStack(alignment: .top, spacing: 8) {
                splitPairHalf(primary)
                splitPairHalf(secondary)
            }
        }
        .padding(10)
        .glassEffectCompat(
            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            material: isActive ? .regularMaterial : .ultraThinMaterial,
            tint: isActive ? sidebarRowSelectedBackground : sidebarRowBackground,
            strokeOpacity: isSidebarDark ? 0.35 : 0.45
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func splitPairHalf(_ tab: BrowserTab) -> some View {
        let title = tab.title.isEmpty ? "New Tab" : tab.title
        let subtitle = tab.url?.host ?? (tab.isBlank ? "Blank Tab" : tab.address)
        return Menu {
            tabMenuItems(for: tab)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Group {
                        if let favicon = tab.favicon {
                            Image(uiImage: favicon)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: tab.isIncognito ? "eye.slash" : "globe")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(sidebarPrimaryText)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: sidebarSubtitleFontSize, weight: .semibold))
                            .foregroundColor(sidebarPrimaryText)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: max(10, sidebarSubtitleFontSize - 2)))
                            .foregroundColor(sidebarSecondaryText)
                            .lineLimit(1)
                    }
                }
                if !tabPreviewsCollapsed {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(sidebarIconBackground)
                    if let thumbnail = tab.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .clipped()
                    }
                }
                .frame(height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        } primaryAction: {
            vm.selectedTabID = tab.id
            if tab.isBlank { omniboxFocused = true }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), split view")
    }

    private func separateSplitPair(containing tabID: UUID) {
        let isShowing = splitPrimaryID == tabID || splitSecondaryID == tabID
        vm.removeSplitPair(containing: tabID)
        if isShowing {
            withAnimation(.easeOut(duration: 0.2)) {
                clearSplitView()
            }
        }
    }

    /// Long-press menu for a tab, shared by normal tab cards and split pair cards.
    @ViewBuilder
    private func tabMenuItems(for tab: BrowserTab) -> some View {
        let canSplit = vm.selectedTabID != nil && vm.tabs.count > 1
        if !tab.isBlank && tab.url != nil {
            Button {
                toggleReaderMode(for: tab)
            } label: {
                Label(
                    tab.isReaderMode ? "Disable Reader Mode" : "Enable Reader Mode",
                    systemImage: tab.isReaderMode ? "text.book.closed.fill" : "text.book.closed"
                )
            }
            Button {
                toggleDarkMode(for: tab)
            } label: {
                Label(
                    effectiveDarkMode(for: tab) ? "Disable Dark Web Page" : "Enable Dark Web Page",
                    systemImage: effectiveDarkMode(for: tab) ? "moon.fill" : "moon"
                )
            }
            Divider()
        }
        if tab.currentURL != nil {
            Button {
                presentShareSheet(for: tab)
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        }
        if vm.isFavorite(tab.url) {
            Button("Remove from Favorites") {
                if let favorite = vm.favorites.first(where: { $0.url == tab.url }) {
                    vm.removeFromFavorites(favorite)
                }
            }
        } else {
            Button("Add to Favorites") {
                vm.addToFavorites(tab)
            }
            .disabled(tab.url == nil)
        }
        Menu("Move to Tab Group", systemImage: "folder") {
            Button {
                vm.move(tab, to: nil)
            } label: {
                Label("Ungrouped", systemImage: tab.groupID == nil ? "checkmark" : "tray")
            }
            ForEach(vm.tabGroups) { group in
                Button {
                    vm.move(tab, to: group.id)
                } label: {
                    Label(group.title, systemImage: tab.groupID == group.id ? "checkmark" : "folder")
                }
            }
        }
        Divider()
        splitViewMenuItems(canSplit: canSplit) { mode in
            openSplitView(with: tab, mode: mode)
        }
        Divider()
        Button(role: .destructive) {
            performClose(tab)
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    private func tabRow(_ tab: BrowserTab) -> some View {
        let title = tab.title.isEmpty ? "New Tab" : tab.title
        let subtitle = tab.url?.host ?? (tab.isBlank ? "Blank Tab" : tab.address)
        let isSelected = tab.id == vm.selectedTabID
        let canSplit = vm.selectedTabID != nil && vm.tabs.count > 1
        let controlHitSize: CGFloat = 44
        let controlInset: CGFloat = 6
        let rowContent = VStack(alignment: .leading, spacing: 0) {
            // Header row with favicon and title
            HStack(spacing: 10) {
                sidebarIconContainer {
                    ZStack(alignment: .bottomTrailing) {
                        if let favicon = tab.favicon {
                            Image(uiImage: favicon)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 18, height: 18)
                                .clipped()
                        } else {
                            Image(systemName: tab.isIncognito ? "eye.slash" : "globe")
                                .font(.system(size: sidebarIconFontSize, weight: .semibold))
                                .foregroundColor(sidebarPrimaryText)
                        }

                        if tab.isIncognito {
                            Circle()
                                .fill(BrowserDesign.Tint.incognito)
                                .frame(width: 8, height: 8)
                                .overlay(
                                    Image(systemName: "eye.slash.fill")
                                        .font(.system(size: 5))
                                        .foregroundColor(.white)
                                )
                                .offset(x: 4, y: 4)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: sidebarTitleFontSize, weight: .semibold))
                        .foregroundColor(sidebarPrimaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: sidebarSubtitleFontSize))
                        .foregroundColor(sidebarSecondaryText)
                        .lineLimit(1)
                }
                if tab.showsHibernationIndicator {
                    Image(systemName: "moon.zzz.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(sidebarSecondaryText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(sidebarIconBackground))
                        .accessibilityLabel("Sleeping tab")
                        .accessibilityHint("Reloads when selected")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, tab.thumbnail != nil && !tabPreviewsCollapsed ? 8 : 10)

            // Thumbnail preview
            if !tabPreviewsCollapsed, let thumbnail = tab.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: 120, alignment: .topLeading)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }

        let showsSplitHandle = canSplit && (!isCompactWidth || isPhone) && tab.webAIProvider == nil
        let closeButton = Button {
            performClose(tab)
        } label: {
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundColor(sidebarPrimaryText)
                .padding(6)
                .background(
                    Circle().fill(sidebarIconBackground)
                )
        }
        .buttonStyle(.plain)
        .frame(width: controlHitSize, height: controlHitSize)
        .contentShape(Rectangle())
        .accessibilityLabel("Close \(title)")
        .zIndex(2)
        let splitHandle = Image(systemName: "line.3.horizontal")
            .font(.caption2.weight(.bold))
            .foregroundColor(sidebarSecondaryText)
            .frame(width: controlHitSize, height: controlHitSize)
            .contentShape(Rectangle())
            .simultaneousGesture(sidebarTabDragGesture(for: tab))
            .accessibilityLabel("Drag tab to split view")
            .accessibilityHint("Drag toward an edge of the page")
            .zIndex(2)
        // Collapsed cards put ≡ and ✕ side by side on the title line; with previews they stack.
        let controlsWidth = tabPreviewsCollapsed && showsSplitHandle ? controlHitSize * 2 : controlHitSize

        return ZStack(alignment: .topTrailing) {
            Menu {
                tabMenuItems(for: tab)
            } label: {
                rowContent
                    .padding(.trailing, controlsWidth + controlInset)
            } primaryAction: {
                vm.selectedTabID = tab.id
                if tab.isBlank { omniboxFocused = true }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Group {
                if tabPreviewsCollapsed {
                    HStack(spacing: 0) {
                        if showsSplitHandle { splitHandle }
                        closeButton
                    }
                } else {
                    VStack(spacing: 4) {
                        closeButton
                        if showsSplitHandle { splitHandle }
                    }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, controlInset)
            .zIndex(2)
        }
        .glassEffectCompat(
            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            material: isSelected ? .regularMaterial : .ultraThinMaterial,
            tint: isSelected ? sidebarRowSelectedBackground : sidebarRowBackground,
            strokeOpacity: isSidebarDark ? 0.35 : 0.45
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Favorites: folders get the first row, favorites the second; each row scrolls sideways.
    private var favoritesSection: some View {
        let folders = vm.favoriteFolders(inFolder: nil)
        let favorites = vm.favorites(inFolder: nil)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Tap the header to fold the folder and favorite rows away, and again to show them.
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        favoritesCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        sidebarSectionHeader("Favorites", systemImage: "star.fill")
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(sidebarSecondaryText)
                            .rotationEffect(.degrees(favoritesCollapsed ? -90 : 0))
                            .padding(.top, 8)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(favoritesCollapsed ? "Show favorites" : "Hide favorites")
                Spacer(minLength: 0)
            }

            if !favoritesCollapsed {
                if !folders.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(folders) { folder in
                                favoriteFolderTile(folder)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(favorites) { favorite in
                            favoriteTile(favorite)
                        }
                        if let tab = selectedTab, tab.currentURL != nil, !vm.isFavorite(tab.url) {
                            addFavoriteTile(for: tab)
                        }
                    }
                    .padding(.vertical, 2)
                }

                HStack {
                    Button {
                        favoritesSheet = FavoritesSheetRequest(folderID: nil)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Manage")
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(sidebarSecondaryText)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Manage favorites")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private let favoriteTileWidth: CGFloat = 84
    private let favoriteTileHeight: CGFloat = 76

    /// Icon on top, then name and a detail line, with a "…" menu in the corner.
    private func favoriteTileContent<Icon: View>(
        title: String,
        detail: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            icon()
                .frame(width: 22, height: 22)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(sidebarPrimaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundColor(sidebarSecondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.top, 9)
        .padding(.bottom, 8)
        // Every tile is exactly the same size; the text sizes are fixed so it always fits.
        .frame(width: favoriteTileWidth, height: favoriteTileHeight, alignment: .topLeading)
    }

    private func favoriteTileMoreButton<Items: View>(@ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption2.weight(.bold))
                .foregroundColor(sidebarSecondaryText)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More options")
    }

    @ViewBuilder
    private func favoriteFolderMenuItems(_ folder: FavoriteFolder) -> some View {
        let count = vm.favoriteCount(inFolderTree: folder.id)
        Button {
            favoritesSheet = FavoritesSheetRequest(folderID: folder.id)
        } label: {
            Label("Open Folder", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            vm.deleteFavoriteFolder(folder.id)
        } label: {
            Label(count == 0 ? "Delete Folder" : "Delete Folder and \(count) \(count == 1 ? "Favorite" : "Favorites")", systemImage: "trash")
        }
    }

    private func favoriteFolderTile(_ folder: FavoriteFolder) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let count = vm.favoriteCount(inFolderTree: folder.id)

        return Menu {
            favoriteFolderMenuItems(folder)
        } label: {
            favoriteTileContent(
                title: folder.title,
                detail: "\(count) \(count == 1 ? "favorite" : "favorites")"
            ) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BrowserDesign.Tint.favorite)
            }
            .contentShape(shape)
        } primaryAction: {
            favoritesSheet = FavoritesSheetRequest(folderID: folder.id)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(width: favoriteTileWidth, height: favoriteTileHeight)
        .overlay(alignment: .topTrailing) {
            favoriteTileMoreButton {
                favoriteFolderMenuItems(folder)
            }
        }
        .glassEffectCompat(
            in: shape,
            material: .ultraThinMaterial,
            tint: sidebarRowBackground,
            strokeOpacity: isSidebarDark ? 0.35 : 0.45
        )
        .accessibilityLabel("\(folder.title), folder, \(count) \(count == 1 ? "favorite" : "favorites")")
        .accessibilityHint("Opens the folder. Touch and hold for more options.")
        .id("favorite-folder-\(folder.id)")
    }

    @ViewBuilder
    private func favoriteMenuItems(_ favorite: Favorite) -> some View {
        let canSplit = vm.selectedTabID != nil
        splitViewMenuItems(canSplit: canSplit) { mode in
            openSplitView(with: favorite, mode: mode)
        }
        Divider()
        Button {
            favoriteRenameText = favorite.title
            favoritePendingRename = favorite
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        if !vm.favoriteFolders.isEmpty {
            Menu {
                ForEach(vm.favoriteFolderPaths) { item in
                    Button(item.path) {
                        vm.moveFavorite(favorite, toFolder: item.id)
                    }
                }
            } label: {
                Label("Move to Folder", systemImage: "folder")
            }
        }
        Button(role: .destructive) {
            vm.removeFromFavorites(favorite)
        } label: {
            Label("Remove Favorite", systemImage: "trash")
        }
    }

    private func favoriteTile(_ favorite: Favorite) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let name = favorite.title.isEmpty ? (favorite.url.host ?? favorite.url.absoluteString) : favorite.title
        let host = (favorite.url.host ?? favorite.url.absoluteString)
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)

        return Menu {
            favoriteMenuItems(favorite)
        } label: {
            favoriteTileContent(title: name, detail: host) {
                if let faviconData = favorite.favicon,
                   let favicon = UIImage(data: faviconData) {
                    Image(uiImage: favicon)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundColor(sidebarPrimaryText)
                }
            }
            .contentShape(shape)
        } primaryAction: {
            vm.openFavoriteInNewTab(favorite)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(width: favoriteTileWidth, height: favoriteTileHeight)
        .overlay(alignment: .topTrailing) {
            favoriteTileMoreButton {
                favoriteMenuItems(favorite)
            }
        }
        .glassEffectCompat(
            in: shape,
            material: .ultraThinMaterial,
            tint: sidebarRowBackground,
            strokeOpacity: isSidebarDark ? 0.35 : 0.45,
            // No glass light-up and grow when the tile is pressed.
            isInteractive: false
        )
        .accessibilityLabel(name)
        .accessibilityHint("Opens in a new tab. Touch and hold for more options.")
        .id("favorite-\(favorite.id)")
    }

    /// Dashed tile at the end of the favorites row that saves the current page.
    private func addFavoriteTile(for tab: BrowserTab) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            vm.addToFavorites(tab)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                Text("Add Favorite")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundColor(sidebarSecondaryText)
            .frame(width: favoriteTileWidth, height: favoriteTileHeight)
            .overlay(
                shape.strokeBorder(sidebarSecondaryText.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add current page to Favorites")
    }

    private var settingsButton: some View {
        sidebarRow(
            title: "Settings",
            action: {
                if isPhone {
                    dismissPhoneSecondaryPanel()
                }
                if isCompactWidth {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isSidebarCollapsed = true
                        sidebarDrag = 0
                    }
                }
                if !showSettingsMenu {
                    refreshWebAILoginStates()
                }
                showSettingsMenu.toggle()
            }
        ) {
            Image(systemName: "gearshape")
                .font(.system(size: sidebarIconFontSize, weight: .semibold))
                .foregroundColor(sidebarPrimaryText)
        }
        .popover(isPresented: settingsPopoverBinding) {
            settingsMenuView
                .frame(width: 380, height: 640)
                .presentationBackground(.regularMaterial)
                .preferredColorScheme(systemColorScheme)
        }
    }

    private var settingsPopoverBinding: Binding<Bool> {
        Binding(
            get: { showSettingsMenu && !isCompactWidth },
            set: { newValue in
                if !newValue {
                    showSettingsMenu = false
                } else if !isCompactWidth {
                    showSettingsMenu = true
                }
            }
        )
    }

    private var activeContentPanel: some View {
        VStack(spacing: 0) {
            if let idx = vm.selectedIndex {
                let tab = vm.tabs[idx]
                if let primary = splitPrimaryTab,
                   let secondary = splitSecondaryTab,
                   let mode = splitMode {
                    splitTabView(primary: primary, secondary: secondary, activeTab: tab, mode: mode)
                } else {
                    activeTabView(tab)
                }
            } else {
                Color.black
            }
        }
        .sheet(isPresented: $vm.showSafari) {
            if let url = vm.safariURL {
                SafariView(url: url)
            }
        }
        .sheet(isPresented: compactSettingsSheetBinding) {
            settingsMenuView
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
                .preferredColorScheme(systemColorScheme)
        }
        .onChange(of: showAIPanel) { _, isShowing in
            if isShowing {
                syncAIContextSelection()
                prepareAIContext()
                aiHasUnreadResponse = false
            } else {
                if isPhone, phoneSecondaryPanel == .ai {
                    resignPhonePanelInput()
                    phoneSecondaryPanel = .none
                    phonePanelDragOffset = 0
                    phonePanelHiddenForTabDrag = false
                }
                pendingAIQueryTask?.cancel()
                pendingAIQueryTask = nil
                pendingAIQueryToken = UUID()
                if activeWebAIServiceRequestID == nil {
                    if let selection = pendingAISelection, pendingAIReplacement == nil {
                        clearAISelectionHighlight(selection)
                        pendingAISelection = nil
                    }
                    clearAISelectionContext()
                }
            }
        }
        .onChange(of: aiService.messages) { _, messages in
            guard let last = messages.last, last.role == .assistant else { return }
            if let replacement = pendingAIReplacement,
               !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                applyAIReplacement(last.text, to: replacement)
                pendingAIReplacement = nil
                pendingAISelection = nil
                clearAISelectionContext()
            } else if let selection = pendingAISelection,
                      !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearAISelectionHighlight(selection)
                pendingAISelection = nil
                clearAISelectionContext()
            }
            if !showAIPanel {
                aiHasUnreadResponse = true
            }
        }
        .overlay(
            Group {
                if passwordManager.showPasswordPrompt,
                   let loginForm = passwordManager.currentLoginForm {
                    VStack {
                        HStack {
                            Spacer()
                            VStack(alignment: .leading, spacing: 12) {
                                Label {
                                    Text("Save Password?")
                                        .font(.headline)
                                } icon: {
                                    Image(systemName: "key.fill")
                                        .foregroundStyle(BrowserDesign.Tint.password)
                                }

                                Text("Save password for \(loginForm.username) on \(loginForm.website)?")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                HStack(spacing: 12) {
                                    Button("Not Now") {
                                        passwordManager.dismissPasswordPrompt()
                                    }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)

                                    Button("Save") {
                                        Task {
                                            await passwordManager.saveCurrentCredentials()
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .buttonBorderShape(.capsule)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .padding(16)
                            .frame(maxWidth: 360)
                            .glassEffectCompat(
                                in: RoundedRectangle(cornerRadius: BrowserDesign.Radius.card, style: .continuous),
                                material: .regularMaterial,
                                strokeOpacity: 0.25,
                                isInteractive: false
                            )
                            .shadow(
                                color: BrowserDesign.Shadow.color(isDark: isSidebarDark),
                                radius: BrowserDesign.Shadow.cardRadius,
                                y: 8
                            )
                            .padding()
                        }
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        )
        .fullScreenCover(isPresented: $showWebProviderSheet, onDismiss: {
            clearSplitView()
        }) {
            if let providerTab = splitSecondaryExternalTab {
                webProviderFullScreenView(for: providerTab)
            }
        }
    }

    private func webProviderFullScreenView(for tab: BrowserTab) -> some View {
        NavigationStack {
            splitPane(for: tab)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle(tab.webAIProvider?.displayName ?? "Web AI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            if let provider = tab.webAIProvider {
                                tab.activateWebView().load(URLRequest(url: provider.url))
                            }
                        } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                        .accessibilityLabel("Reload \(tab.webAIProvider?.displayName ?? "Web AI")")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showWebProviderSheet = false
                        }
                    }
                }
        }
    }

    private func activeTabView(_ tab: BrowserTab) -> some View {
        ZStack(alignment: .top) {
            Group {
                if tab.isBlank && !agentTaskNeedsNavigationHost(for: tab) {
                    Color(UIColor.systemBackground)
                } else {
                    GeometryReader { proxy in
                        WebViewHost(
                            tab: tab,
                            viewModel: vm,
                            downloadManager: downloadManager,
                            allowEdgeGestures: true,
                            allowThumbnailCapture: true,
                            viewportSize: proxy.size,
                            onScroll: {
                                if !isToolbarCollapsed {
                                    collapseToolbar()
                                }
                            },
                            onScrollEnd: {
                                refreshToolbarBackdrop()
                            },
                            onUserInteraction: {
                                if omniboxFocused {
                                    omniboxFocused = false
                                }
                            },
                            onAskAI: {
                                handleAskAISelection(in: tab)
                            },
                            onWebProviderPrompt: { webView, provider, prompt in
                                handleWebProviderPrompt(provider: provider, prompt: prompt, from: webView)
                            },
                            onWebProviderReady: { tab in
                                handleWebProviderReady(tab)
                            },
                            onNavigate: { tab, webView, url in
                                handleAutofillPrivacyNavigation(tab, webView: webView, url: url)
                                handlePrimaryNavigation(tab, url: url)
                                // Late layout (fonts, images) can move text under the toolbar.
                                refreshToolbarBackdrop()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    refreshToolbarBackdrop()
                                }
                            },
                            onAgentTaskNavigationEvent: { tab, webView, navigation, kind in
                                handleAgentTaskNavigationEvent(tab: tab, webView: webView, navigation: navigation, kind: kind)
                            },
                            onAgentTaskWebViewReadiness: { tab, webView, ready in
                                handleAgentTaskWebViewReadiness(tab: tab, webView: webView, isReady: ready)
                            },
                            isAgentTaskLoadOwned: { tab, webView in
                                agentTaskStartup?.tab === tab && agentTaskStartup?.webView === webView
                            },
                            bottomChromeHeight: activeTabBottomChromeHeight,
                            bottomStripHeight: activeTabBottomStripHeight,
                            bottomScrollInset: activeTabBottomScrollInset,
                            onToolbarScrollEvent: handleToolbarScrollEvent
                        )
                        .id(tab.id)
                        .edgesIgnoringSafeArea(.all)
                        .allowsHitTesting(true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func splitTabView(primary: BrowserTab, secondary: BrowserTab, activeTab: BrowserTab, mode: SplitMode) -> some View {
        ZStack(alignment: .top) {
            splitContentStack(primary: primary, secondary: secondary, mode: mode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Like a single page, split pages run under the status bar and home indicator
        // instead of leaving black bands there.
        .ignoresSafeArea(.container, edges: .vertical)
    }

    @ViewBuilder
    private func splitContentStack(primary: BrowserTab, secondary: BrowserTab, mode: SplitMode) -> some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let totalHeight = proxy.size.height
            let spacing = splitSpacing

            if mode == .vertical {
                let availableWidth = max(1, totalWidth - spacing)
                let ratio = min(max(splitVerticalRatio, splitMinRatio), splitMaxRatio)
                let primaryWidth = availableWidth * ratio
                let secondaryWidth = availableWidth - primaryWidth

                ZStack {
                    HStack(spacing: 0) {
                        splitPane(for: primary, touchesBottom: true)
                            .frame(width: primaryWidth, height: totalHeight)
                        splitDivider(axis: .vertical)
                            .frame(width: spacing, height: totalHeight)
                        splitPane(for: secondary, touchesBottom: true)
                            .frame(width: secondaryWidth, height: totalHeight)
                    }

                    splitDividerDragOverlay(
                        axis: .vertical,
                        axisLength: totalWidth,
                        crossLength: totalHeight,
                        dividerPosition: primaryWidth + spacing / 2
                    )
                        .position(x: primaryWidth + spacing / 2, y: totalHeight / 2)
                        .zIndex(2)
                }
                .coordinateSpace(name: "splitArea")
            } else {
                let availableHeight = max(1, totalHeight - spacing)
                let ratio = min(max(splitHorizontalRatio, splitMinRatio), splitMaxRatio)
                let primaryHeight = availableHeight * ratio
                let secondaryHeight = availableHeight - primaryHeight

                ZStack {
                    VStack(spacing: 0) {
                        splitPane(for: primary)
                            .frame(width: totalWidth, height: primaryHeight)
                        splitDivider(axis: .horizontal)
                            .frame(width: totalWidth, height: spacing)
                        splitPane(for: secondary, touchesBottom: true)
                            .frame(width: totalWidth, height: secondaryHeight)
                    }

                    splitDividerDragOverlay(
                        axis: .horizontal,
                        axisLength: totalHeight,
                        crossLength: totalWidth,
                        dividerPosition: primaryHeight + spacing / 2
                    )
                        .position(x: totalWidth / 2, y: primaryHeight + spacing / 2)
                        .zIndex(2)
                }
                .coordinateSpace(name: "splitArea")
            }
        }
    }

    private func splitDivider(axis: SplitAxis) -> some View {
        let handleColor = isSidebarDark ? Color.white.opacity(0.6) : Color.black.opacity(0.25)

        return ZStack {
            Rectangle()
                .fill(Color.clear)
            Capsule()
                .fill(handleColor)
                .frame(
                    width: axis == .vertical ? splitDividerHandleThickness : splitDividerHandleLength,
                    height: axis == .vertical ? splitDividerHandleLength : splitDividerHandleThickness
                )
        }
        .allowsHitTesting(false)
    }

    private func splitDividerDragOverlay(
        axis: SplitAxis,
        axisLength: CGFloat,
        crossLength: CGFloat,
        dividerPosition: CGFloat
    ) -> some View {
        let crossSize = max(splitSpacing, splitDividerHitSize)
        let width = axis == .vertical ? crossSize : crossLength
        let height = axis == .vertical ? crossLength : crossSize

        return Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("splitArea"))
                    .onChanged { value in
                        let start = axis == .vertical ? value.startLocation.x : value.startLocation.y
                        let hitRadius = crossSize / 2

                        if splitDragAxis == nil {
                            if abs(start - dividerPosition) > hitRadius {
                                return
                            }
                            splitDragAxis = axis
                        }

                        guard splitDragAxis == axis else { return }
                        let position = axis == .vertical ? value.location.x : value.location.y
                        let available = max(1, axisLength - splitSpacing)
                        let rawRatio = (position - splitSpacing / 2) / available
                        let clamped = min(max(rawRatio, splitMinRatio), splitMaxRatio)

                        if axis == .vertical {
                            splitVerticalRatio = clamped
                        } else {
                            splitHorizontalRatio = clamped
                        }
                    }
                    .onEnded { _ in
                        if splitDragAxis == axis {
                            splitDragAxis = nil
                            scheduleSplitThumbnailRefresh()
                        }
                    }
            )
    }

    @ViewBuilder
    /// `touchesBottom`: the pane reaches the bottom edge, where the toolbar floats over it.
    private func splitPane(for tab: BrowserTab, touchesBottom: Bool = false) -> some View {
        Group {
            if tab.isBlank && !agentTaskNeedsNavigationHost(for: tab) {
                Color(UIColor.systemBackground)
            } else {
                GeometryReader { proxy in
                    WebViewHost(
                        tab: tab,
                        viewModel: vm,
                        downloadManager: downloadManager,
                        allowEdgeGestures: true,
                        allowThumbnailCapture: true,
                        viewportSize: proxy.size,
                        onScroll: {
                            if !isToolbarCollapsed {
                                collapseToolbar()
                            }
                            handleSplitPaneInteraction(tab)
                        },
                        onScrollEnd: nil,
                        onUserInteraction: {
                            if omniboxFocused {
                                omniboxFocused = false
                            }
                            handleSplitPaneInteraction(tab)
                        },
                        onAskAI: {
                            handleAskAISelection(in: tab)
                        },
                        onWebProviderPrompt: { webView, provider, prompt in
                            handleWebProviderPrompt(provider: provider, prompt: prompt, from: webView)
                        },
                        onWebProviderReady: { tab in
                            handleWebProviderReady(tab)
                        },
                        onNavigate: { tab, webView, url in
                            handleAutofillPrivacyNavigation(tab, webView: webView, url: url)
                            handlePrimaryNavigation(tab, url: url)
                        },
                        onAgentTaskNavigationEvent: { tab, webView, navigation, kind in
                            handleAgentTaskNavigationEvent(tab: tab, webView: webView, navigation: navigation, kind: kind)
                        },
                        onAgentTaskWebViewReadiness: { tab, webView, ready in
                            handleAgentTaskWebViewReadiness(tab: tab, webView: webView, isReady: ready)
                        },
                        isAgentTaskLoadOwned: { tab, webView in
                            agentTaskStartup?.tab === tab && agentTaskStartup?.webView === webView
                        },
                        bottomChromeHeight: touchesBottom ? activeTabBottomChromeHeight : 0,
                        bottomStripHeight: touchesBottom ? activeTabBottomStripHeight : 0,
                        bottomScrollInset: touchesBottom ? activeTabBottomScrollInset : 0,
                        onToolbarScrollEvent: handleToolbarScrollEvent
                    )
                    .id(tab.id)
                    .allowsHitTesting(true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
        .clipped()
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if tab.webAIProvider != nil {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showAIPanel = false
                        if isPhone {
                            phoneSecondaryPanel = .none
                            phonePanelDragOffset = 0
                            phonePanelHiddenForTabDrag = false
                        }
                    }
                    clearSplitView()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(7)
                        .background(
                            Circle().fill(Color.black.opacity(0.35))
                        )
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Close AI pane")
            }
        }
    }

    private func agentTaskNeedsNavigationHost(for tab: BrowserTab) -> Bool {
        guard let attempt = agentTaskStartup else { return false }
        return attempt.tab === tab
    }

    @ViewBuilder
    private func toolbarView(for tab: BrowserTab) -> some View {
        if isPhone {
            HStack(spacing: 8) {
                GlassTextField(
                    tab: tab,
                    placeholder: tab.isIncognito ? "Search privately" : "Search or enter address",
                    onSubmit: {
                        vm.submitAddress(tab.address, for: tab)
                        collapseToolbar()
                    },
                    trailingAccessory: AnyView(
                        Button {
                            toggleReaderMode(for: tab)
                        } label: {
                            Image(systemName: tab.isReaderMode ? "text.book.closed.fill" : "text.book.closed")
                                .foregroundColor(tab.isReaderMode ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                        .ios26PhoneButtonHitTargetCompat()
                        .accessibilityLabel(tab.isReaderMode ? "Exit reader mode" : "Enter reader mode")
                        .disabled(tab.currentURL == nil)
                    ),
                    onClear: preserveIOS26PhoneOmniboxFocusAfterClear,
                    frosted: toolbarOverText
                )
                .focused($omniboxFocused)
                .frame(minWidth: 0, maxWidth: .infinity)
                .layoutPriority(1)

                Button {
                    collapseToolbar()
                } label: {
                    Image(systemName: "chevron.down")
                        .foregroundColor(.secondary)
                }
                .browserToolbarControl()
                .ios26PhoneButtonHitTargetCompat()
                .accessibilityLabel("Close search")

                pageActionsMenu(for: tab)
                    .ios26PhoneButtonHitTargetCompat()

                if splitMode != nil {
                    exitSplitViewButton
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        } else {
        HStack(spacing: 8) {
            GlassTextField(
                tab: tab,
                placeholder: tab.isIncognito ? "Search privately" : "Search or enter address",
                onSubmit: {
                    vm.submitAddress(tab.address, for: tab)
                    collapseToolbar()
                },
                trailingAccessory: AnyView(
                    Button {
                        toggleReaderMode(for: tab)
                    } label: {
                        Image(systemName: tab.isReaderMode ? "text.book.closed.fill" : "text.book.closed")
                            .foregroundColor(tab.isReaderMode ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.isReaderMode ? "Exit reader mode" : "Enter reader mode")
                    .disabled(tab.currentURL == nil)
                ),
                frosted: toolbarOverText
            )
            .focused($omniboxFocused)

            Button {
                collapseToolbar()
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundColor(.secondary)
            }
            .browserToolbarControl()
            .accessibilityLabel("Close search")

            pageActionsMenu(for: tab)

            if splitMode != nil {
                exitSplitViewButton
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        }
    }

    // MARK: - Settings Menu View
    private var settingsMenuView: some View {
        BrowserSettingsView(
            vm: vm,
            isChatGPTSignedIn: isChatGPTLoggedIn,
            isGeminiSignedIn: isGeminiLoggedIn,
            webAIStatusMessage: webAISettingsStatusMessage,
            isLoadingMLXModel: $isLoadingMLXModel,
            mlxDownloadProgress: $mlxDownloadProgress,
            mlxLoadError: $mlxLoadError,
            onSignIn: { provider in
                requestWebAILogin(for: provider)
            },
            onSignOut: { provider in
                resetWebAISession(for: provider)
            },
            onFontSizeChanged: {
                if let tab = selectedTab {
                    fontSizeService.applyFontSize(to: tab.activateWebView())
                }
            },
            onDownloadMLXModel: { modelID, location in
                downloadModel(modelID, to: location)
            },
            onCancelMLXDownload: {
                cancelModelDownload()
            },
            onAppear: {
                refreshWebAILoginStates()
            },
            onDone: {
                showSettingsMenu = false
            }
        )
        .overlay {
            if let pendingWebAILoginProvider {
                webAILoginWarningOverlay(for: pendingWebAILoginProvider)
                    .transition(.opacity)
                    .zIndex(300)
            }
        }
    }

    private var compactSettingsSheetBinding: Binding<Bool> {
        Binding(
            get: { showSettingsMenu && isCompactWidth },
            set: { newValue in
                if !newValue {
                    showSettingsMenu = false
                }
            }
        )
    }

    private func openIncognitoTab() {
        let incognitoTab = BrowserTab(title: "Incognito", url: nil, isIncognito: true, useDesktopUserAgent: requestDesktopSite)
        vm.tabs.append(incognitoTab)
        vm.selectedTabID = incognitoTab.id
        incognitoMode.isActive = true
        showSettingsMenu = false
        omniboxFocused = true
        showPageStatus("Private tab · not saved in history")
    }

    private var filterListOverlay: some View {
        GeometryReader { proxy in
            let width = isCompactWidth
                ? min(settingsMenuPreferredWidth, max(280, proxy.size.width - 32))
                : min(720, max(420, proxy.size.width - 140))
            let height = isCompactWidth
                ? min(settingsMenuPreferredHeight, max(320, proxy.size.height - 72))
                : min(820, max(520, proxy.size.height - 120))
            let shape = RoundedRectangle(cornerRadius: isCompactWidth ? 30 : 32, style: .continuous)

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        showFilterListSettings = false
                    }

                // Regular material keeps the glass look but tints enough for text to
                // stay readable over light pages when the panel uses the dark scheme.
                NavigationStack {
                    FilterListSettingsView()
                }
                .preferredColorScheme(systemColorScheme)
                .background(.regularMaterial)
                .frame(width: width, height: height)
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(BrowserDesign.chromeBorder(isDark: isSidebarDark), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .overlay(alignment: .topTrailing) {
                    Button {
                        showFilterListSettings = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var settingsMenuPreferredWidth: CGFloat {
        isCompactWidth ? 340 : 360
    }

    private var settingsMenuPreferredHeight: CGFloat {
        isCompactWidth ? 620 : 760
    }

    /// Downloads a Hugging Face model, either into app storage (`location == nil`)
    /// or into a user-picked folder, then makes it the active MLX model.
    private func downloadModel(_ requestedModelID: String, to location: URL?) {
        mlxDownloadTask?.cancel()
        mlxLoadError = nil
        mlxDownloadProgress = nil

        guard mlxAvailable else {
            mlxLoadError = "MLX Local is not available on this device/build."
            return
        }

        let modelID = requestedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty, !MLXModelStorage.isExternal(modelID) else {
            mlxLoadError = "Enter a Hugging Face model ID, like \(MLXLocalSettings.defaultModelID)."
            return
        }

        isLoadingMLXModel = true
        mlxDownloadTask = Task { @MainActor in
            defer {
                isLoadingMLXModel = false
                mlxDownloadProgress = nil
                mlxDownloadTask = nil
            }

            let progressHandler: @Sendable (Progress) -> Void = { progress in
                Task { @MainActor in
                    mlxDownloadProgress = progress
                }
            }

            do {
                guard let location else {
                    try await MLXLocalService.shared.downloadModel(
                        modelID: modelID,
                        progressHandler: progressHandler
                    )
                    // App-storage models are selected by id: the sandbox path can
                    // change across app updates, the id never does.
                    MLXExternalModelStore.clearSelection()
                    mlxModelID = modelID
                    return
                }

                guard location.startAccessingSecurityScopedResource() else {
                    throw NSError(
                        domain: "MLXDownload",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot access the selected folder"]
                    )
                }
                defer { location.stopAccessingSecurityScopedResource() }

                // Bookmark the picked folder before downloading: it carries the
                // security scope, a bookmark of the model subfolder may not.
                let bookmarkData: Data
                do {
                    #if os(iOS)
                    bookmarkData = try location.bookmarkData(options: .minimalBookmark)
                    #else
                    bookmarkData = try location.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
                    #endif
                } catch {
                    throw NSError(
                        domain: "MLXDownload",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to save folder bookmark: \(error.localizedDescription)"]
                    )
                }

                let modelPath = try await MLXLocalService.shared.downloadModelToLocation(
                    modelID: modelID,
                    location: location,
                    progressHandler: progressHandler
                )
                let relativePath = "models/\(modelID)"
                MLXExternalModelStore.addEntry(path: modelPath.path, bookmark: bookmarkData, relativePath: relativePath)
                MLXExternalModelStore.setSelected(path: modelPath.path, bookmark: bookmarkData)
                mlxModelID = "external:\(modelPath.path)"
            } catch is CancellationError {
                // Cancelled from settings; partial files resume on the next download.
            } catch {
                if !Task.isCancelled {
                    mlxLoadError = error.localizedDescription
                }
            }
        }
    }

    private func cancelModelDownload() {
        mlxDownloadTask?.cancel()
    }

    // MARK: - AI Helpers
    @MainActor
    private func sendAIQuery(for tab: BrowserTab, selection: AISelection? = nil) {
        let query = BrowserAgentAutofillPrivacy.shared.redactPotentiallyTruncated(
            aiQuery.trimmingCharacters(in: .whitespacesAndNewlines),
            wasTruncated: true
        )
        guard !query.isEmpty else { return }
        let sourceBinding = pageContextBinding(for: tab)
        guard pageContextIsAllowed(for: tab, capturedBinding: sourceBinding) else {
            aiQuery = ""
            reportBlockedPageContext()
            return
        }
        browserAIFlowLog("sendAIQuery START backend=\(aiService.backend.rawValue) tab=\(tab.id.uuidString.prefix(8)) queryChars=\(query.count) hasSelection=\(selection != nil)")
        aiQuery = ""

        // Always cancel any previous extraction task before starting a new
        // query path (fast or slow). Otherwise stale tasks can complete later
        // and enqueue unexpected follow-up work.
        pendingAIQueryTask?.cancel()
        pendingAIQueryTask = nil
        pendingAIQueryToken = UUID()

        let rawSelectionText = selectionContextText(for: tab.id)
        let selectionText = rawSelectionText.flatMap { safePageText($0, for: tab, capturedBinding: sourceBinding) }

        if aiService.backend.isWebProvider {
            let provider: WebAIProvider
            switch aiService.backend {
            case .webChatGPT:
                provider = .chatgpt
            case .webGemini:
                provider = .gemini
            default:
                return
            }
            aiService.prepareForNewContext(tab.currentURL)

            if let selection, selection.tabID == tab.id {
                clearAISelectionHighlight(selection)
                pendingAISelection = nil
                pendingAIReplacement = nil
                clearAISelectionContext()
            }

            sendCapturedWebProviderPrompt(provider: provider, prompt: query, contextOverride: selectionText)
            browserAIFlowLog("sendAIQuery routed to web provider=\(provider.displayName)")
            return
        }

        aiService.prepareForNewContext(tab.currentURL)

        if let selection, selection.tabID == tab.id {
            pendingAISelection = selection
        } else {
            clearAISelectionContext()
        }

        let shouldUseInlineContext = aiService.backend == .localApple
            && selectionText == nil
            && SimpleAIService.hasInlineContextCandidate(query)
        if shouldUseInlineContext {
            aiService.enqueueQuery(query, pageContent: nil)
            return
        }

        let canReuseSourcePageContext = aiService.hasSourcePageContext
        browserAIFlowLog("sendAIQuery start queryChars=\(query.count) hasSelection=\(selectionText != nil) hasCached=\(cachedAIPageContent(for: tab) != nil) canReuseSourcePageContext=\(canReuseSourcePageContext) sourceContextChars=\(aiService.sourcePageContextText?.count ?? 0)")

        // Fast path for follow-ups: avoid spinning an extraction Task when we
        // already have usable context. This runs for all backends.
        if let selectionText {
            browserAIFlowLog("sendAIQuery fast-path selection context chars=\(selectionText.count)")
            dispatchResolvedQuery(prompt: query, content: selectionText, sourceTab: tab, sourceBinding: sourceBinding)
            return
        }
        if let cached = cachedAIPageContent(for: tab) {
            browserAIFlowLog("sendAIQuery fast-path cached page context chars=\(cached.count)")
            dispatchResolvedQuery(prompt: query, content: cached, sourceTab: tab, sourceBinding: sourceBinding)
            return
        }
        if canReuseSourcePageContext {
            browserAIFlowLog("sendAIQuery fast-path sourcePageContext reuse")
            dispatchResolvedQuery(
                prompt: query,
                content: aiService.sourcePageContextText,
                sourceTab: tab,
                reusingStoredSourceContext: true,
                sourceBinding: sourceBinding
            )
            return
        }

        // Extract visible page text for context (best-effort)
        if pendingAIQueryTask != nil {
            browserAIFlowLog("sendAIQuery cancelling previous extraction task")
            pendingAIQueryTask?.cancel()
        }
        browserAIFlowLog("sendAIQuery starting extraction task")
        let queryToken = UUID()
        pendingAIQueryToken = queryToken
        pendingAIQueryTask = Task {
            browserAIFlowLog("sendAIQuery task START token=\(queryToken.uuidString.prefix(8)) selectionChars=\(selectionText?.count ?? 0)")
            let contentText: String?
            if let selectionText {
                browserAIFlowLog("sendAIQuery using selection context chars=\(selectionText.count)")
                contentText = selectionText
            } else if let cached = cachedAIPageContent(for: tab) {
                browserAIFlowLog("sendAIQuery using cached page context chars=\(cached.count)")
                contentText = cached
            } else {
                browserAIFlowLog("sendAIQuery extracting page context from webView")
                let webView = tab.activateWebView()
                let extractionBinding = webView.url.map {
                    BrowserAgentPageContextBinding(tabID: tab.id, webView: webView, url: $0)
                } ?? sourceBinding
                let extracted = await PageContentExtractor.extractContent(
                    from: webView,
                    url: tab.currentURL,
                    preferFast: true
                )
                if let extracted {
                    let currentAndSafe = await MainActor.run { () -> (Bool, String) in
                        guard self.pageContextIsAllowed(for: tab, capturedBinding: extractionBinding) else {
                            self.reportBlockedPageContext()
                            return (false, "")
                        }
                        let safe = BrowserAgentAutofillPrivacy.shared.sanitized(extracted)
                        self.storeAIPageContent(safe, for: tab, capturedBinding: extractionBinding)
                        return (true, safe.formattedForAIContext)
                    }
                    guard currentAndSafe.0 else { return }
                    browserAIFlowLog("sendAIQuery extracted page context bodyChars=\(currentAndSafe.1.count)")
                    contentText = currentAndSafe.1
                } else {
                    browserAIFlowLog("sendAIQuery extraction returned nil")
                    contentText = nil
                }
            }
            guard !Task.isCancelled, pendingAIQueryToken == queryToken else {
                browserAIFlowLog("sendAIQuery task ABORT token=\(queryToken.uuidString.prefix(8)) cancelledOrStale=true")
                return
            }
            guard let safeContentText = await MainActor.run(body: {
                self.safePageText(contentText ?? "", for: tab, capturedBinding: sourceBinding)
            }) else {
                await MainActor.run { self.reportBlockedPageContext() }
                return
            }
            browserAIFlowLog("sendAIQuery enqueue token=\(queryToken.uuidString.prefix(8)) pageContentChars=\(contentText?.count ?? 0)")
            await MainActor.run {
                self.dispatchResolvedQuery(prompt: query, content: safeContentText.isEmpty ? nil : safeContentText, sourceTab: tab, sourceBinding: sourceBinding)
            }
            if pendingAIQueryToken == queryToken {
                pendingAIQueryTask = nil
                browserAIFlowLog("sendAIQuery task END token=\(queryToken.uuidString.prefix(8))")
            }
        }
    }

    private func handleWebProviderPrompt(
        provider: WebAIProvider,
        prompt: String,
        from webView: WKWebView,
        contextOverride: String? = nil
    ) {
        let trimmedPrompt = BrowserAgentAutofillPrivacy.shared
            .redactPotentiallyTruncated(prompt.trimmingCharacters(in: .whitespacesAndNewlines), wasTruncated: true)
        guard !trimmedPrompt.isEmpty,
              provider.matches(webView.url) else { return }
        let trimmedOverride = contextOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOverride = !(trimmedOverride?.isEmpty ?? true)

        let sourceTab = webProviderContextSourceTab()
        let sourceBinding = sourceTab.flatMap { pageContextBinding(for: $0) }
        if let sourceTab, !pageContextIsAllowed(for: sourceTab, capturedBinding: sourceBinding) {
            reportBlockedPageContext()
            return
        }
        if let sourceTab {
            let contextURL = sourceTab.currentURL
            webProviderContextTabID = sourceTab.id
            webProviderContextURLString = contextURL.map { normalizedContextURL($0) }
        } else {
            webProviderContextTabID = nil
            webProviderContextURLString = nil
        }

        if hasOverride, let trimmedOverride {
            let safeOverride: String
            if let sourceTab {
                guard let safe = safePageText(trimmedOverride, for: sourceTab, capturedBinding: sourceBinding) else {
                    reportBlockedPageContext()
                    return
                }
                safeOverride = safe
            } else {
                safeOverride = BrowserAgentAutofillPrivacy.shared.redactKnownValues(trimmedOverride)
            }
            let composed = "Selected text:\n\(safeOverride)\n\nUser prompt:\n\(trimmedPrompt)"
            sendWebProviderPrompt(composed, to: webView, provider: provider, targetID: webProviderTabID(for: webView), sourceBinding: sourceBinding)
            return
        }

        guard let sourceTab else {
            sendWebProviderPrompt(trimmedPrompt, to: webView, provider: provider, targetID: webProviderTabID(for: webView))
            return
        }

        if let cached = cachedAIPageContent(for: sourceTab) {
            let context = RedditSummaryPlanner.isRedditContext(cached)
                ? RedditSummaryPlanner.webSafeContext(
                    content: cached,
                    maxCharacters: redditWebProviderContextMaxChars
                )
                : cached
            let composed = "\(context)\n\nUser prompt:\n\(trimmedPrompt)"
            sendWebProviderPrompt(composed, to: webView, provider: provider, targetID: webProviderTabID(for: webView), sourceBinding: sourceBinding)
            return
        }

        if let sourceContext = aiService.sourcePageContextText {
            let condensed = RedditSummaryPlanner.isRedditContext(sourceContext)
                ? RedditSummaryPlanner.webSafeContext(
                    content: sourceContext,
                    maxCharacters: redditWebProviderContextMaxChars
                )
                : Self.condenseText(sourceContext, maxChars: webProviderContextMaxChars)
            let composed = condensed.isEmpty ? trimmedPrompt : "\(condensed)\n\nUser prompt:\n\(trimmedPrompt)"
            browserAIWebLog("handleWebProviderPrompt reusing sourcePageContext chars=\(sourceContext.count)")
            sendWebProviderPrompt(composed, to: webView, provider: provider, targetID: webProviderTabID(for: webView), sourceBinding: sourceBinding)
            return
        }

        let sourceWebView = sourceTab.activateWebView()
        let contextURL = sourceWebView.url ?? sourceTab.currentURL
        guard let contextURL else { return }
        let capturedBinding = BrowserAgentPageContextBinding(tabID: sourceTab.id, webView: sourceWebView, url: contextURL)
        Task {
            let extracted = await PageContentExtractor.extractContent(from: sourceWebView, url: contextURL, preferFast: true)
            await MainActor.run {
                guard self.pageContextIsAllowed(for: sourceTab, capturedBinding: capturedBinding) else {
                    self.reportBlockedPageContext()
                    return
                }
                let safeExtracted = extracted.map { BrowserAgentAutofillPrivacy.shared.sanitized($0) }
                let pageText = safeExtracted?.formattedForAIContext ?? ""
                let condensed = RedditSummaryPlanner.isRedditContext(pageText)
                    ? RedditSummaryPlanner.webSafeContext(
                        content: pageText,
                        maxCharacters: redditWebProviderContextMaxChars
                    )
                    : Self.condenseText(pageText, maxChars: webProviderContextMaxChars)
                let composed = condensed.isEmpty ? trimmedPrompt : "\(condensed)\n\nUser prompt:\n\(trimmedPrompt)"
                if let extracted {
                    storeAIPageContent(safeExtracted ?? extracted, for: sourceTab, capturedBinding: capturedBinding)
                }
                self.sendWebProviderPrompt(composed, to: webView, provider: provider, targetID: self.webProviderTabID(for: webView), sourceBinding: capturedBinding)
            }
        }
    }

    private func sendWebProviderPrompt(
        _ text: String,
        to webView: WKWebView,
        provider: WebAIProvider,
        targetID: UUID?,
        sourceBinding: BrowserAgentPageContextBinding? = nil,
        attempt: Int = 0
    ) {
        guard browserAgentPageContextCanTransmit(sourceBinding) else {
            pendingWebProviderPrompt = nil
            pendingWebProviderProvider = nil
            pendingWebProviderTargetID = nil
            pendingWebProviderContextOverride = nil
            return
        }
        let safeText = BrowserAgentAutofillPrivacy.shared.redactPotentiallyTruncated(text, wasTruncated: true)
        guard provider.matches(webView.url) else {
            if pendingWebProviderPrompt == safeText && pendingWebProviderProvider == provider {
                pendingWebProviderPrompt = nil
                pendingWebProviderProvider = nil
                pendingWebProviderTargetID = nil
                pendingWebProviderContextOverride = nil
            }
            return
        }
        guard let payloadData = try? JSONSerialization.data(withJSONObject: ["text": safeText], options: []),
              var payloadString = String(data: payloadData, encoding: .utf8) else { return }

        // Escape Unicode characters that are valid in JSON but break JavaScript
        payloadString = payloadString
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

        let script = "(function(){ return window.__webProviderReceiveFromNative ? window.__webProviderReceiveFromNative(\(payloadString)) : false; })();"
        webView.evaluateJavaScript(script) { result, error in
            guard provider.matches(webView.url) else {
                if self.pendingWebProviderPrompt == safeText && self.pendingWebProviderProvider == provider {
                    self.pendingWebProviderPrompt = nil
                    self.pendingWebProviderProvider = nil
                    self.pendingWebProviderTargetID = nil
                    self.pendingWebProviderContextOverride = nil
                }
                return
            }
            let success = (result as? Bool) ?? false
            if error != nil || !success {
                self.pendingWebProviderPrompt = safeText
                self.pendingWebProviderProvider = provider
                self.pendingWebProviderTargetID = targetID
                guard attempt < 20 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let pending = self.pendingWebProviderPrompt,
                          let pendingProvider = self.pendingWebProviderProvider else { return }
                    if pending == safeText && pendingProvider == provider {
                        self.sendWebProviderPrompt(
                            pending,
                            to: webView,
                            provider: provider,
                            targetID: targetID,
                            sourceBinding: sourceBinding,
                            attempt: attempt + 1
                        )
                    }
                }
                } else if self.pendingWebProviderPrompt == safeText && self.pendingWebProviderProvider == provider {
                self.pendingWebProviderPrompt = nil
                self.pendingWebProviderProvider = nil
                self.pendingWebProviderTargetID = nil
            }
        }
    }

    private func webProviderTabID(for webView: WKWebView) -> UUID? {
        guard let external = splitSecondaryExternalTab else { return nil }
        if external.liveWebView === webView {
            return external.id
        }
        return nil
    }

    private func normalizedContextURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }

    @MainActor
    private func resetWebProviderContext() {
        if aiService.backend.isWebProvider {
            aiService.reset()
        }
        pendingWebProviderContextOverride = nil
        clearSplitView()
    }

    private static func condenseText(_ text: String, maxChars: Int) -> String {
        guard !text.isEmpty else { return "" }
        let collapsed = text
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.prefix(maxChars))
    }

    private func cachedAIPageContent(for tab: BrowserTab) -> String? {
        guard let entry = cachedAIPageContentEntry(for: tab) else { return nil }
        guard pageContextIsAllowed(for: tab, capturedBinding: entry.binding) else {
            aiPageContentCache.removeValue(forKey: tab.id)
            return nil
        }
        let safe = BrowserAgentAutofillPrivacy.shared.sanitized(entry.content).formattedForAIContext
        let trimmed = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cachedAIPageContentEntry(for tab: BrowserTab) -> AICachedPageContent? {
        guard let url = tab.currentURL else { return nil }
        let key = normalizedContextURL(url)
        guard let entry = aiPageContentCache[tab.id] else { return nil }
        guard entry.urlKey == key,
              let currentBinding = pageContextBinding(for: tab),
              entry.binding == currentBinding else {
            aiPageContentCache.removeValue(forKey: tab.id)
            return nil
        }
        return entry
    }

    private func storeAIPageContent(
        _ content: PageContentExtractor.ExtractedPageContent,
        for tab: BrowserTab,
        capturedBinding: BrowserAgentPageContextBinding? = nil
    ) {
        guard let url = tab.currentURL,
              let binding = capturedBinding ?? pageContextBinding(for: tab),
              pageContextIsAllowed(for: tab, capturedBinding: binding) else {
            aiPageContentCache.removeValue(forKey: tab.id)
            return
        }
        let safeContent = BrowserAgentAutofillPrivacy.shared.sanitized(content)
        let trimmed = safeContent.formattedForAIContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        aiPageContentCache[tab.id] = AICachedPageContent(
            urlKey: normalizedContextURL(url),
            binding: binding,
            content: safeContent
        )
    }

    // MARK: - Simple Start Page with Search
    struct StartPage: View {
        @State private var input: String = ""
        var onSubmit: (String) -> Void

        var body: some View {
            VStack(spacing: 24) {
                Text("New Tab")
                    .font(.largeTitle.weight(.semibold))
                HStack {
                    TextField("Search or enter address", text: $input, onCommit: { onSubmit(input) })
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button(action: { onSubmit(input) }) {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .frame(maxWidth: 640)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    // MARK: - WKWebView host
    struct WebViewHost: UIViewRepresentable {
        let tab: BrowserTab
        @ObservedObject var viewModel: BrowserViewModel
        let downloadManager: BrowserDownloadManager
        var allowEdgeGestures: Bool = true
        var allowThumbnailCapture: Bool = true
        var viewportSize: CGSize = .zero
        var onScroll: (() -> Void)?
        var onScrollEnd: (() -> Void)?
        var onUserInteraction: (() -> Void)?
        var onAskAI: (() -> Void)?
        var onWebProviderPrompt: ((WKWebView, WebAIProvider, String) -> Void)?
        var onWebProviderReady: ((BrowserTab) -> Void)?
        var onNavigate: ((BrowserTab, WKWebView, URL) -> Void)?
        var onAgentTaskNavigationEvent: (@MainActor (BrowserTab, WKWebView, WKNavigation, AgentTaskNavigationEventKind) -> Void)?
        var onAgentTaskWebViewReadiness: (@MainActor (BrowserTab, WKWebView, Bool) -> Bool)?
        var isAgentTaskLoadOwned: (@MainActor (BrowserTab, WKWebView) -> Bool)?
        /// Space the floating bottom controls cover, above the bottom safe area.
        var bottomChromeHeight: CGFloat = 0
        var bottomStripHeight: CGFloat = 0
        var bottomScrollInset: CGFloat = 0
        var onToolbarScrollEvent: ((ToolbarScrollEvent) -> Void)?

        func makeCoordinator() -> Coordinator {
            Coordinator(
                tab: tab,
                viewModel: viewModel,
                downloadManager: downloadManager,
                onScroll: onScroll,
                onScrollEnd: onScrollEnd,
                onUserInteraction: onUserInteraction,
                onWebProviderPrompt: onWebProviderPrompt,
                onWebProviderReady: onWebProviderReady,
                onNavigate: onNavigate,
                onAgentTaskNavigationEvent: onAgentTaskNavigationEvent,
                onAgentTaskWebViewReadiness: onAgentTaskWebViewReadiness,
                onToolbarScrollEvent: onToolbarScrollEvent
            )
        }

        func makeUIView(context: Context) -> BrowserWebViewContainer {
            let webView = tab.activateWebView()
            webView.navigationDelegate = context.coordinator
            webView.uiDelegate = context.coordinator
            webView.scrollView.delegate = context.coordinator
            webView.scrollView.alwaysBounceVertical = true
            webView.scrollView.refreshControl = context.coordinator.refreshControl
            Self.applySiteSpecificTopInset(to: webView, url: webView.url ?? tab.url)
            webView.onAskAI = onAskAI
            ThirdPartyCookieBlocker.shared.register(webView: webView)
            context.coordinator.installWebProviderMessageHandler(on: webView)
            context.coordinator.installGestures(on: webView)
            let agentOwnsInitialLoad = onAgentTaskWebViewReadiness?(tab, webView, true) ?? false
            if !agentOwnsInitialLoad, webView.url == nil, let url = tab.url, !webView.isLoading {
                // Wait for ad block rules before loading (prevents race condition)
                loadWhenReady(webView: webView, url: url, tab: tab)
            }
            let container = BrowserWebViewContainer(webView: webView)
            container.bottomScrollInset = bottomScrollInset
            container.bottomChromeHeight = bottomChromeHeight
            container.bottomStripHeight = bottomStripHeight
            return container
        }

        func updateUIView(_ uiView: BrowserWebViewContainer, context: Context) {
            uiView.bottomScrollInset = bottomScrollInset
            uiView.bottomChromeHeight = bottomChromeHeight
            uiView.bottomStripHeight = bottomStripHeight
            let webView = tab.liveWebView ?? tab.activateWebView()
            webView.navigationDelegate = context.coordinator
            webView.uiDelegate = context.coordinator
            webView.scrollView.delegate = context.coordinator
            Self.applySiteSpecificTopInset(to: webView, url: webView.url ?? tab.url)
            context.coordinator.installWebProviderMessageHandler(on: webView)
            context.coordinator.installGestures(on: webView)
            let agentOwnsInitialLoad = onAgentTaskWebViewReadiness?(tab, webView, true) ?? false
            if !agentOwnsInitialLoad, webView.url == nil, let url = tab.url, !webView.isLoading {
                // Wait for ad block rules before loading (prevents race condition)
                loadWhenReady(webView: webView, url: url, tab: tab)
            }

            if webView.scrollView.refreshControl !== context.coordinator.refreshControl {
                webView.scrollView.refreshControl = context.coordinator.refreshControl
            }

            webView.onAskAI = onAskAI

            ThirdPartyCookieBlocker.shared.register(webView: webView)

            webView.allowsBackForwardNavigationGestures = false
            context.coordinator.setEdgeGesturesEnabled(allowEdgeGestures)

            if !webView.isLoading {
                let shouldDark = tab.hasDarkModeOverride ? tab.isDarkMode : DarkModeService.shared.isDarkMode
                webView.overrideUserInterfaceStyle = shouldDark ? .dark : .light
                if tab.lastAppliedDarkMode != shouldDark {
                    if shouldDark {
                        DarkModeService.shared.enableDarkMode(for: webView)
                    } else {
                        DarkModeService.shared.disableDarkMode(for: webView)
                    }
                    tab.lastAppliedDarkMode = shouldDark
                }
            }

            if allowThumbnailCapture,
               webView.url != nil,
               !webView.isLoading,
               viewportSize.width > 1,
               viewportSize.height > 1 {
                let dx = abs(viewportSize.width - tab.lastThumbnailSize.width)
                let dy = abs(viewportSize.height - tab.lastThumbnailSize.height)
                let needsThumbnail = tab.thumbnail == nil || dx > 1 || dy > 1
                if needsThumbnail {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [tab] in
                        Task { @MainActor in
                            context.coordinator.captureThumbnail(for: tab, targetSize: viewportSize)
                        }
                    }
                }
            }
        }

        /// Site headers sit directly beneath the platform's scroll-edge glass when
        /// the browser extends under the top safe area. A small device-specific
        /// content inset makes their top controls reliably tappable at rest while
        /// leaving the WebView itself underlapping the glass during scrolling.
        private static func applySiteSpecificTopInset(to webView: WKWebView, url: URL?) {
            let scrollView = webView.scrollView
            let desiredTop = BrowserSiteViewportPolicy.topContentInset(
                for: url,
                idiom: UIDevice.current.userInterfaceIdiom
            )
            let oldTop = scrollView.contentInset.top
            guard abs(oldTop - desiredTop) > 0.5 else { return }

            let wasAtTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1
            var contentInset = scrollView.contentInset
            contentInset.top = desiredTop
            scrollView.contentInset = contentInset

            var indicatorInset = scrollView.verticalScrollIndicatorInsets
            indicatorInset.top = desiredTop
            scrollView.verticalScrollIndicatorInsets = indicatorInset

            if wasAtTop {
                scrollView.layoutIfNeeded()
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
                    animated: false
                )
            }
        }

        static func dismantleUIView(_ uiView: BrowserWebViewContainer, coordinator: Coordinator) {
            let webView = uiView.webView
            coordinator.notifyWebViewHostUnavailable(webView)
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "webProviderPrompt")
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.scrollView.delegate = nil
            webView.scrollView.refreshControl = nil
        }

        /// Wait for ad block rules to be ready before loading URL (prevents race condition on fast devices)
        private func loadWhenReady(webView: WKWebView, url: URL, tab: BrowserTab) {
            let canStartLoad: @MainActor () -> Bool = {
                AgentTaskWebViewLoadPolicy.shouldStartRestorationLoad(
                    requestedURL: url,
                    currentTabURL: tab.url,
                    isLoading: webView.isLoading,
                    agentOwnsLoad: isAgentTaskLoadOwned?(tab, webView) ?? false
                )
            }
            guard canStartLoad() else { return }
            if !AdBlockService.shared.isEnabled || AdBlockService.shared.isReady {
                webView.load(URLRequest(url: url))
                return
            }
            Task { @MainActor in
                    // Wait up to 3 seconds for rules to compile
                    for _ in 0..<30 {
                        guard canStartLoad() else { return }
                        if !AdBlockService.shared.isEnabled || AdBlockService.shared.isReady { break }
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
                    }
                    guard canStartLoad() else { return }
                    webView.load(URLRequest(url: url))
            }
        }

        final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
            private static let webProviderHandlerName = "webProviderPrompt"
            private let tab: BrowserTab
            private let viewModel: BrowserViewModel
            private let downloadManager: BrowserDownloadManager
            private let onScroll: (() -> Void)?
            private let onScrollEnd: (() -> Void)?
            private let onUserInteraction: (() -> Void)?
            private let onWebProviderPrompt: ((WKWebView, WebAIProvider, String) -> Void)?
            private let onWebProviderReady: ((BrowserTab) -> Void)?
            private let onNavigate: ((BrowserTab, WKWebView, URL) -> Void)?
            private let onAgentTaskNavigationEvent: (@MainActor (BrowserTab, WKWebView, WKNavigation, AgentTaskNavigationEventKind) -> Void)?
            private let onAgentTaskWebViewReadiness: (@MainActor (BrowserTab, WKWebView, Bool) -> Bool)?
            private let onToolbarScrollEvent: ((ToolbarScrollEvent) -> Void)?
            let refreshControl = UIRefreshControl()
            private var didNotifyScrollStart = false
            /// A sideways swipe anywhere on the page goes back or forward, on iPhone and iPad.
            private var navigationPanGesture: UIPanGestureRecognizer?
            private var interactionTapGesture: UITapGestureRecognizer?
            private var navigationFeedbackGenerator: UIImpactFeedbackGenerator?
            private var navigationSwipeTriggered = false

            init(
                tab: BrowserTab,
                viewModel: BrowserViewModel,
                downloadManager: BrowserDownloadManager,
                onScroll: (() -> Void)?,
                onScrollEnd: (() -> Void)?,
                onUserInteraction: (() -> Void)?,
                onWebProviderPrompt: ((WKWebView, WebAIProvider, String) -> Void)?,
                onWebProviderReady: ((BrowserTab) -> Void)?,
                onNavigate: ((BrowserTab, WKWebView, URL) -> Void)?,
                onAgentTaskNavigationEvent: (@MainActor (BrowserTab, WKWebView, WKNavigation, AgentTaskNavigationEventKind) -> Void)?,
                onAgentTaskWebViewReadiness: (@MainActor (BrowserTab, WKWebView, Bool) -> Bool)?,
                onToolbarScrollEvent: ((ToolbarScrollEvent) -> Void)?
            ) {
                self.tab = tab
                self.viewModel = viewModel
                self.downloadManager = downloadManager
                self.onScroll = onScroll
                self.onScrollEnd = onScrollEnd
                self.onUserInteraction = onUserInteraction
                self.onWebProviderPrompt = onWebProviderPrompt
                self.onWebProviderReady = onWebProviderReady
                self.onNavigate = onNavigate
                self.onAgentTaskNavigationEvent = onAgentTaskNavigationEvent
                self.onAgentTaskWebViewReadiness = onAgentTaskWebViewReadiness
                self.onToolbarScrollEvent = onToolbarScrollEvent
                super.init()
                if UIDevice.current.userInterfaceIdiom == .phone {
                    navigationFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
                }
                refreshControl.addTarget(self, action: #selector(handlePullToRefresh(_:)), for: .valueChanged)
            }

            @MainActor
            func notifyWebViewHostUnavailable(_ webView: WKWebView) {
                _ = onAgentTaskWebViewReadiness?(tab, webView, false)
            }

            func installWebProviderMessageHandler(on webView: WKWebView) {
                let controller = webView.configuration.userContentController
                controller.removeScriptMessageHandler(forName: Self.webProviderHandlerName)
                guard tab.webAIProvider != nil else { return }
                controller.add(self, name: Self.webProviderHandlerName)
            }

            @MainActor
            func captureThumbnail(for tab: BrowserTab, targetSize: CGSize? = nil) {
                viewModel.captureTabThumbnail(for: tab, targetSize: targetSize)
            }

            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                guard message.name == Self.webProviderHandlerName else { return }
                guard let body = message.body as? [String: Any],
                      let providerID = body["provider"] as? String,
                      let provider = WebAIProvider(rawValue: providerID),
                      let assignedProvider = tab.webAIProvider,
                      provider == assignedProvider,
                      WebAIMessagePolicy.allows(
                        provider: assignedProvider,
                        url: message.frameInfo.request.url ?? message.webView?.url,
                        isMainFrame: message.frameInfo.isMainFrame
                      ),
                      let prompt = body["prompt"] as? String,
                      let targetWebView = message.webView else { return }
                onWebProviderPrompt?(targetWebView, provider, prompt)
            }

            private func webProviderBridgeScript(for provider: WebAIProvider) -> String {
                let providerID = provider.rawValue
                return """
                (function() {
                    if (!window.__webProviderBridge) { window.__webProviderBridge = {}; }
                    if (window.__webProviderBridge["\(providerID)"]) { return; }
                    window.__webProviderBridge["\(providerID)"] = true;
                    const provider = "\(providerID)";
                    const handlerName = "\(Self.webProviderHandlerName)";
                    const isChatGPT = provider === "chatgpt";
                    const isGemini = provider === "gemini";

                    function pickFirst(list) {
                        for (let i = 0; i < list.length; i++) {
                            if (list[i]) { return list[i]; }
                        }
                        return null;
                    }

                    function findInput() {
                        if (isChatGPT) {
                            return pickFirst([
                                document.getElementById('prompt-textarea'),
                                document.querySelector('.ProseMirror[contenteditable="true"]'),
                                document.querySelector('#prompt-textarea[contenteditable="true"]'),
                                document.querySelector('[data-testid="composer-input"] [contenteditable="true"]'),
                                document.querySelector('div[contenteditable="true"][data-placeholder]'),
                                document.querySelector('textarea'),
                                document.querySelector('[contenteditable="true"]')
                            ]);
                        }
                        if (isGemini) {
                            return pickFirst([
                                document.querySelector('rich-textarea .ql-editor[contenteditable="true"]'),
                                document.querySelector('rich-textarea [contenteditable="true"]'),
                                document.querySelector('textarea'),
                                document.querySelector('[contenteditable="true"]')
                            ]);
                        }
                        return pickFirst([
                            document.querySelector('textarea'),
                            document.querySelector('[contenteditable="true"]')
                        ]);
                    }

                    function getValue(el) {
                        if (!el) { return ""; }
                        if (el.tagName === "TEXTAREA" || el.tagName === "INPUT") {
                            return el.value || "";
                        }
                        return el.innerText || "";
                    }

                    function setValueChatGPT(el, value) {
                        if (!el) return false;
                        el.focus();

                        // Check for ProseMirror editor (uses <p> tags inside contenteditable)
                        const isProseMirror = el.classList.contains('ProseMirror') || el.querySelector('p') !== null;

                        if (isProseMirror) {
                            let p = el.querySelector('p');
                            if (!p) {
                                p = document.createElement('p');
                                el.innerHTML = '';
                                el.appendChild(p);
                            }
                            p.textContent = value;
                            el.dispatchEvent(new InputEvent('input', {
                                bubbles: true, cancelable: true, inputType: 'insertText', data: value
                            }));
                            return true;
                        }

                        // Textarea/Input with React native setter workaround
                        if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
                            try {
                                const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                                const nativeSetter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                                nativeSetter.call(el, value);
                                if (el.setSelectionRange) el.setSelectionRange(value.length, value.length);
                            } catch (e) { el.value = value; }
                            el.dispatchEvent(new Event('input', { bubbles: true }));
                            return true;
                        }

                        // Contenteditable div
                        if (el.getAttribute('contenteditable') === 'true') {
                            const p = document.createElement('p');
                            p.textContent = value;
                            el.innerHTML = '';
                            el.appendChild(p);
                            el.dispatchEvent(new InputEvent('input', {
                                bubbles: true, cancelable: true, inputType: 'insertText', data: value
                            }));
                            return true;
                        }
                        return false;
                    }

                    function setValueGemini(el, value) {
                        if (!el) { return false; }
                        el.focus();
                        const geminiHost = el.closest('rich-textarea') || document.querySelector('rich-textarea');
                        const geminiQuill = geminiHost && geminiHost.__quill
                            ? geminiHost.__quill
                            : (el.parentElement && el.parentElement.__quill ? el.parentElement.__quill : null);
                        if (geminiQuill && typeof geminiQuill.setText === 'function') {
                            geminiQuill.setText(value, 'user');
                            if (typeof geminiQuill.setSelection === 'function' && typeof geminiQuill.getLength === 'function') {
                                geminiQuill.setSelection(Math.max(0, geminiQuill.getLength() - 1), 0, 'silent');
                            }
                            if (typeof geminiQuill.focus === 'function') {
                                geminiQuill.focus();
                            }
                            if (typeof geminiQuill.update === 'function') {
                                geminiQuill.update('user');
                            }
                            return true;
                        }

                        if (el.getAttribute('contenteditable') === 'true') {
                            const p = document.createElement('p');
                            p.textContent = value;
                            el.innerHTML = '';
                            el.appendChild(p);
                            el.dispatchEvent(new InputEvent('input', {
                                bubbles: true,
                                cancelable: true,
                                inputType: 'insertText',
                                data: value
                            }));
                            return true;
                        }

                        return false;
                    }

                    function setValue(el, value) {
                        if (!el) { return false; }
                        if (isChatGPT) { return setValueChatGPT(el, value); }
                        if (isGemini) { return setValueGemini(el, value); }
                        el.focus();
                        if (el.tagName === "TEXTAREA" || el.tagName === "INPUT") {
                            try {
                                const proto = el.tagName === "TEXTAREA"
                                    ? HTMLTextAreaElement.prototype
                                    : HTMLInputElement.prototype;
                                const descriptor = Object.getOwnPropertyDescriptor(proto, "value");
                                if (descriptor && descriptor.set) {
                                    descriptor.set.call(el, value);
                                } else {
                                    el.value = value;
                                }
                            } catch (e) {
                                el.value = value;
                            }
                            if (el.setSelectionRange) {
                                el.setSelectionRange(el.value.length, el.value.length);
                            }
                        } else {
                            el.innerText = value;
                            el.textContent = value;
                        }
                        try {
                            const inputEvent = new InputEvent('input', {
                                bubbles: true,
                                data: value,
                                inputType: 'insertText'
                            });
                            el.dispatchEvent(inputEvent);
                        } catch (e) {
                            el.dispatchEvent(new Event('input', { bubbles: true }));
                        }
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                        return true;
                    }

                    function dispatchEnter(el) {
                        if (!el) { return; }
                        el.focus();

                        const eventInit = {
                            key: 'Enter',
                            code: 'Enter',
                            keyCode: 13,
                            which: 13,
                            bubbles: true,
                            cancelable: true
                        };

                        ['keydown', 'keypress', 'keyup'].forEach(type => {
                            el.dispatchEvent(new KeyboardEvent(type, eventInit));
                        });

                        const form = el.closest('form');
                        if (form && typeof form.requestSubmit === 'function') {
                            form.requestSubmit();
                        }
                    }

                    function nudgeGeminiComposer(el) {
                        if (!isGemini || !el) { return; }
                        dispatchEnter(el);
                    }

                    function geminiDraftText(el) {
                        if (!isGemini) { return ""; }
                        const host = (el && el.closest && el.closest('rich-textarea')) || document.querySelector('rich-textarea');
                        const quill = host && host.__quill ? host.__quill : null;
                        if (quill && typeof quill.getText === 'function') {
                            return (quill.getText() || '').trim();
                        }
                        if (el && typeof el.innerText === 'string') {
                            return el.innerText.trim();
                        }
                        return "";
                    }

                    function dispatchPress(el) {
                        if (!el) { return false; }
                        const base = { bubbles: true, cancelable: true, composed: true, view: window };
                        try { el.focus(); } catch (e) {}
                        try {
                            el.dispatchEvent(new PointerEvent('pointerdown', Object.assign({
                                pointerId: 1,
                                pointerType: 'mouse',
                                isPrimary: true,
                                button: 0,
                                buttons: 1,
                                clientX: 1,
                                clientY: 1
                            }, base)));
                        } catch (e) {}
                        ['mousedown', 'pointerup', 'mouseup', 'click'].forEach(type => {
                            const init = Object.assign({
                                button: 0,
                                buttons: type === 'mousedown' ? 1 : 0,
                                clientX: 1,
                                clientY: 1
                            }, base);
                            try {
                                if (type.startsWith('pointer')) {
                                    el.dispatchEvent(new PointerEvent(type, Object.assign({
                                        pointerId: 1,
                                        pointerType: 'mouse',
                                        isPrimary: true
                                    }, init)));
                                } else {
                                    el.dispatchEvent(new MouseEvent(type, init));
                                }
                            } catch (e) {}
                        });
                        if (typeof el.click === 'function') {
                            try {
                                el.click();
                                return true;
                            } catch (e) {}
                        }
                        return true;
                    }

                    function triggerGeminiSend(button, input) {
                        if (!isGemini || !button) { return false; }
                        if (!geminiDraftText(input)) { return false; }
                        const wrapper = button.parentElement;
                        let triggered = false;
                        if (wrapper) { triggered = dispatchPress(wrapper) || triggered; }
                        triggered = dispatchPress(button) || triggered;
                        return triggered;
                    }

                    function findSendButton() {
                        if (isChatGPT) {
                            return pickFirst([
                                document.querySelector('button[data-testid="send-button"]'),
                                document.querySelector('button[data-testid="composer-send-button"]'),
                                document.querySelector('button[aria-label="Send prompt"]'),
                                document.querySelector('button[aria-label="Send message"]'),
                                document.querySelector('button[aria-label="Send"]'),
                                document.querySelector('form button[type="submit"]'),
                                document.querySelector('button[type="submit"]')
                            ]);
                        }
                        if (isGemini) {
                            return pickFirst([
                                document.querySelector('button[aria-label="Send message"]'),
                                document.querySelector('button[aria-label="Send"]'),
                                document.querySelector('button[type="submit"]'),
                                document.querySelector('div[role="button"][aria-label*="Send"]')
                            ]);
                        }
                        return pickFirst([
                            document.querySelector('button[aria-label*="Send"]'),
                            document.querySelector('button[type="submit"]'),
                            document.querySelector('div[role="button"][aria-label*="Send"]')
                        ]);
                    }

                    function dismissKeyboard() {
                        if (!isGemini) { return; }
                        try {
                            const active = document.activeElement;
                            if (!active) { return; }
                            if (active.tagName === "TEXTAREA" || active.tagName === "INPUT" || active.getAttribute("contenteditable") === "true") {
                                active.blur();
                            }
                        } catch (e) {}
                    }

                    function sendPrompt(text) {
                        const input = findInput();
                        if (!input) { return false; }
                        if (!setValue(input, text)) { return false; }
                        if (isGemini) {
                            nudgeGeminiComposer(input);
                        }
                        function attemptSend(tries) {
                            const button = findSendButton();
                            const ariaDisabled = button && button.getAttribute ? button.getAttribute('aria-disabled') : null;
                            const isDisabled = button && (button.disabled || ariaDisabled === 'true');
                            if (isGemini && triggerGeminiSend(button, input)) {
                                setTimeout(dismissKeyboard, 50);
                                return true;
                            }
                            if (button && !isDisabled) {
                                button.click();
                                setTimeout(dismissKeyboard, 50);
                                return true;
                            }
                            if (isGemini && tries > 0) {
                                nudgeGeminiComposer(input);
                            }
                            if (tries <= 0) {
                                const form = input.closest('form');
                                if (form && typeof form.requestSubmit === 'function') {
                                    form.requestSubmit();
                                    setTimeout(dismissKeyboard, 50);
                                    return true;
                                }
                                window.__webProviderSuppress = true;
                                dispatchEnter(input);
                                window.__webProviderSuppress = false;
                                setTimeout(dismissKeyboard, 50);
                                return true;
                            }
                            setTimeout(function() { attemptSend(tries - 1); }, 250);
                            return true;
                        }
                        // ChatGPT needs extra delay for React state to propagate
                        const initialDelay = isChatGPT ? 800 : 500;
                        setTimeout(function() { attemptSend(40); }, initialDelay);
                        return true;
                    }

                    window.__webProviderReceiveFromNative = function(payload) {
                        if (!payload || !payload.text) { return false; }
                        return sendPrompt(payload.text);
                    };

                    function attachListener() {
                        const input = findInput();
                        if (!input || input.__webProviderListenerAttached) { return; }
                        input.__webProviderListenerAttached = true;
                        input.addEventListener('keydown', function(e) {
                            if (window.__webProviderSuppress) { return; }
                            if (e.key !== 'Enter' || e.shiftKey || e.isComposing) { return; }
                            const value = getValue(input).trim();
                            if (!value) { return; }
                            e.preventDefault();
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handlerName]) {
                                window.webkit.messageHandlers[handlerName].postMessage({ provider: provider, prompt: value });
                            }
                        });
                    }

                    attachListener();
                    const observer = new MutationObserver(attachListener);
                    observer.observe(document.documentElement, { childList: true, subtree: true });
                })();
                """
            }

            func webView(_ webView: WKWebView,
                         decidePolicyFor navigationAction: WKNavigationAction,
                         decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
                let downloadDecision = BrowserDownloadPolicy.navigationActionDecision(
                    shouldPerformDownload: navigationAction.shouldPerformDownload,
                    scheme: navigationAction.request.url?.scheme,
                    isIncognito: tab.isIncognito
                )
                switch downloadDecision {
                case .download:
                    decisionHandler(.download)
                    return
                case .cancel:
                    decisionHandler(.cancel)
                    return
                case .allow:
                    break
                }

                if let url = navigationAction.request.url {
                    if BrowserExternalNavigationPolicy.shouldForceXHTTPSNavigationInWebView(
                        url,
                        navigationType: navigationAction.navigationType
                    ) {
                        webView.load(navigationAction.request)
                        decisionHandler(.cancel)
                        return
                    }

                    if BrowserExternalNavigationPolicy.shouldCancelXAppDeepLink(url) {
                        print("Blocked X app deep link: \(browserURLForLog(url))")
                        decisionHandler(.cancel)
                        return
                    }

                    if BrowserExternalNavigationPolicy.shouldCancelWidgetControlLink(url) {
                        decisionHandler(.cancel)
                        return
                    }

                    // For incognito tabs, be very strict about navigation
                    if tab.isIncognito {
                        // Block navigation that tries to open new windows (often external apps)
                        if navigationAction.targetFrame == nil {
                            print("Blocked new window in incognito: \(browserURLForLog(url))")
                            // Load it in the current frame instead
                            webView.load(navigationAction.request)
                            decisionHandler(.cancel)
                            return
                        }
                        
                        // Only allow http and https URLs
                        if let scheme = url.scheme?.lowercased(), scheme != "http" && scheme != "https" {
                            print("Blocked non-http scheme in incognito: \(browserURLForLog(url))")
                            decisionHandler(.cancel)
                            return
                        }
                        
                        // Block known app-triggering domains
                        let blockedPatterns = [
                            "apps.apple.com", "itunes.apple.com", 
                            "redirect.googlevideo.com", "play.google.com",
                            "accounts.google.com/ServiceLogin"
                        ]
                        let urlString = url.absoluteString.lowercased()
                        if blockedPatterns.contains(where: { urlString.contains($0) }) {
                            print("Blocked app-triggering URL in incognito: \(browserURLForLog(url))")
                            decisionHandler(.cancel)
                            return
                        }
                    } else {
                        // Normal tabs: check for auth domains
                        if viewModel.handleAuthIfNeeded(for: url) {
                            decisionHandler(.cancel)
                            return
                        }
                    }
                }
                if navigationAction.targetFrame?.isMainFrame == true {
                    let enabled = !SitePrivacyStore.shared.isCookieBlockingAllowed(for: navigationAction.request.url)
                    ThirdPartyCookieBlocker.shared.setProtectionEnabled(enabled, for: webView)
                    Task { @MainActor in
                        await UBlockLiteService.shared.preparePage(webView, url: navigationAction.request.url)
                        decisionHandler(.allow)
                    }
                    return
                }
                decisionHandler(.allow)
            }

            func webView(_ webView: WKWebView,
                         navigationAction: WKNavigationAction,
                         didBecome download: WKDownload) {
                // WKDownload.delegate is weak. Assign it before any other routing work so the
                // manager receives the destination callback even when WebKit calls it immediately.
                download.delegate = downloadManager
                downloadManager.register(
                    download,
                    sourceURL: navigationAction.request.url,
                    isIncognito: tab.isIncognito
                )
            }

            func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
                Task { @MainActor in
                    self.tab.isReaderMode = false
                    WebViewHost.applySiteSpecificTopInset(to: webView, url: webView.url ?? self.tab.url)
                    if let navigation {
                        self.onAgentTaskNavigationEvent?(self.tab, webView, navigation, .started)
                    }
                }
            }

            func webView(_ webView: WKWebView,
                         decidePolicyFor navigationResponse: WKNavigationResponse,
                         decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
                let responseURL = navigationResponse.response.url
                let downloadDecision = BrowserDownloadPolicy.navigationResponseDecision(
                    canShowMIMEType: navigationResponse.canShowMIMEType,
                    contentDisposition: BrowserDownloadPolicy.contentDispositionHeader(from: navigationResponse.response),
                    scheme: responseURL?.scheme,
                    isIncognito: tab.isIncognito
                )
                switch downloadDecision {
                case .download:
                    decisionHandler(.download)
                    return
                case .cancel:
                    decisionHandler(.cancel)
                    return
                case .allow:
                    break
                }

                // For incognito, block any response that might trigger an app
                if tab.isIncognito {
                    if let url = navigationResponse.response.url {
                        // Block any non-http(s) responses
                        if let scheme = url.scheme, scheme != "http" && scheme != "https" {
                            print("Blocked response redirect in incognito: \(browserURLForLog(url))")
                            decisionHandler(.cancel)
                            return
                        }
                    }
                }
                decisionHandler(.allow)
            }

            func webView(_ webView: WKWebView,
                         navigationResponse: WKNavigationResponse,
                         didBecome download: WKDownload) {
                // See the action callback above. Keep this assignment in the callback itself so
                // every download path is routed even if a coordinator is recreated later.
                download.delegate = downloadManager
                downloadManager.register(
                    download,
                    sourceURL: navigationResponse.response.url,
                    isIncognito: tab.isIncognito
                )
            }
            
            func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
                onToolbarScrollEvent?(.pin)
                Task { @MainActor in
                    if let navigation {
                        self.onAgentTaskNavigationEvent?(self.tab, webView, navigation, .committed)
                    }
                    // A new document starts untranslated.
                    self.tab.translatedFrom = nil
                    self.tab.isTranslating = false
                    PageZoomStore.apply(to: webView, isIncognito: self.tab.isIncognito)
                    DistractionHider.apply(to: webView, isIncognito: self.tab.isIncognito)
                }
            }

            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                Task { @MainActor in
                    self.tab.restoreScrollPositionIfNeeded(on: webView)
                    self.tab.title = webView.title ?? self.tab.title
                    if let u = webView.url {
                        self.tab.url = u
                        self.tab.address = u.absoluteString
                        if !self.tab.isIncognito, self.tab.webAIProvider == nil {
                            HistoryStore.shared.record(url: u, title: webView.title)
                        }
                        WebViewHost.applySiteSpecificTopInset(to: webView, url: u)

                        SitePrivacyStore.shared.applyPolicies(to: webView, url: u, reloadIfChanged: true)
                        
                        // Apply dark mode with per-tab override support
                        let shouldDark = self.tab.hasDarkModeOverride ? self.tab.isDarkMode : DarkModeService.shared.isDarkMode
                        webView.overrideUserInterfaceStyle = shouldDark ? .dark : .light
                        if shouldDark {
                            DarkModeService.shared.enableDarkMode(for: webView)
                        } else {
                            DarkModeService.shared.disableDarkMode(for: webView)
                        }
                        self.tab.lastAppliedDarkMode = shouldDark
                        
                        // Apply font size
                        FontSizeService.shared.applyFontSize(to: webView)
                        
                        // Debug: Check if we're on a Microsoft auth completion page
                        let microsoftAccountDomains = [
                            "microsoft.com",
                            "microsoftonline.com",
                            "office.com",
                            "office365.com",
                            "live.com",
                            "outlook.com"
                        ]
                        if HostMatchingPolicy.matches(u.host, any: microsoftAccountDomains) {
                            print("DEBUG: Loaded Microsoft page: \(browserURLForLog(u))")
                            
                            // Inject script to handle window.close() and other auth completion scenarios
                            let script = """
                            (function() {
                                // Override window.close to prevent blank page
                                window.close = function() {
                                    console.log('Window.close() intercepted');
                                    // Try to navigate back or to Office 365 home
                                    if (window.history.length > 1) {
                                        window.history.back();
                                    } else {
                                        window.location.href = 'https://www.office.com';
                                    }
                                };
                                
                                // Check if page is trying to communicate with opener
                                if (window.opener) {
                                    console.log('Window.opener detected - auth popup scenario');
                                    // Try to trigger any pending callbacks
                                    if (window.opener.postMessage) {
                                        window.opener.postMessage('auth-complete', '*');
                                    }
                                }
                                
                                // Check for blank page and try to redirect
                                setTimeout(function() {
                                    if (document.body && document.body.innerHTML.trim() === '') {
                                        console.log('Blank page detected, redirecting to Office 365');
                                        window.location.href = 'https://www.office.com';
                                    }
                                }, 1000);
                            })();
                            """
                            do {
                                _ = try await webView.evaluateJavaScript(script)
                            } catch {
                                print("Script injection error: \(error)")
                            }
                        }

                        if let provider = self.tab.webAIProvider, provider.matches(u) {
                            let script = self.webProviderBridgeScript(for: provider)
                            _ = try? await webView.evaluateJavaScript(script)
                            self.onWebProviderReady?(self.tab)
                        }
                    }
                    if let u = self.tab.url {
                        self.onNavigate?(self.tab, webView, u)
                    }
                    if let navigation {
                        self.onAgentTaskNavigationEvent?(self.tab, webView, navigation, .finished)
                    }
                    self.viewModel.fetchFavicon(for: self.tab)
                    self.viewModel.saveSession()

                    // Capture thumbnail after a brief delay to ensure page is rendered
                    if !self.viewModel.isSplitViewActive {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            Task { @MainActor in
                                self.viewModel.captureTabThumbnail(for: self.tab)
                            }
                        }
                    }
                }
                refreshControl.endRefreshing()
            }

            func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
                if let navigation {
                    Task { @MainActor in
                        self.onAgentTaskNavigationEvent?(self.tab, webView, navigation, .failed)
                    }
                }
                refreshControl.endRefreshing()
            }

            func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
                if let navigation {
                    Task { @MainActor in
                        self.onAgentTaskNavigationEvent?(self.tab, webView, navigation, .failed)
                    }
                }
                refreshControl.endRefreshing()
            }

            // MARK: - WKUIDelegate methods
            func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
                // Handle window.open() by loading in current view
                if let url = navigationAction.request.url {
                    print("DEBUG: window.open intercepted: \(browserURLForLog(url))")
                    webView.load(navigationAction.request)
                }
                return nil
            }
            
            func webViewDidClose(_ webView: WKWebView) {
                print("DEBUG: webViewDidClose called")
                // Handle window.close() - navigate back or to home
                if webView.canGoBack {
                    tab.navigateBack()
                } else if let url = URL(string: "https://www.office.com") {
                    webView.load(URLRequest(url: url))
                }
            }

            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                tab.recordScrollPosition(scrollView.contentOffset.y)
                guard scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking else { return }
                notifyScrollStartIfNeeded()
            }

            func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
                notifyScrollStartIfNeeded()
            }

            func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
                if !decelerate {
                    notifyScrollEndIfNeeded(scrollView)
                }
            }

            func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
                notifyScrollEndIfNeeded(scrollView)
            }

            private func notifyScrollStartIfNeeded() {
                guard !didNotifyScrollStart else { return }
                didNotifyScrollStart = true
                onScroll?()
                onToolbarScrollEvent?(.scrollBegan)
            }

            private func notifyScrollEndIfNeeded(_ scrollView: UIScrollView) {
                guard didNotifyScrollStart else { return }
                didNotifyScrollStart = false
                onScrollEnd?()
                let atTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 8
                onToolbarScrollEvent?(.scrollEnded(atTop: atTop))
            }

            // MARK: - Gesture handling
            func installGestures(on webView: WKWebView) {
                if navigationPanGesture?.view === webView { return }
                [navigationPanGesture, interactionTapGesture]
                    .compactMap { $0 }
                    .forEach { $0.view?.removeGestureRecognizer($0) }
                navigationPanGesture = nil
                interactionTapGesture = nil

                let navigationPan = UIPanGestureRecognizer(target: self, action: #selector(handleNavigationPan(_:)))
                navigationPan.maximumNumberOfTouches = 1
                navigationPan.allowedScrollTypesMask = .continuous
                navigationPan.cancelsTouchesInView = false
                navigationPan.delegate = self
                webView.addGestureRecognizer(navigationPan)
                navigationPanGesture = navigationPan

                let interactionTap = UITapGestureRecognizer(target: self, action: #selector(handleInteractionTap(_:)))
                interactionTap.cancelsTouchesInView = false
                interactionTap.delegate = self
                webView.addGestureRecognizer(interactionTap)
                interactionTapGesture = interactionTap
            }

            func setEdgeGesturesEnabled(_ enabled: Bool) {
                navigationPanGesture?.isEnabled = enabled
            }

            @objc private func handleNavigationPan(_ gesture: UIPanGestureRecognizer) {
                if gesture.state == .began {
                    navigationSwipeTriggered = false
                    navigationFeedbackGenerator?.prepare()
                } else if gesture.state == .changed, !navigationSwipeTriggered {
                    guard let view = gesture.view else { return }
                    let translation = gesture.translation(in: view)
                    let horizontalTravel = abs(translation.x)
                    let requiredTravel = min(max(view.bounds.width * 0.075, 64), 96)
                    guard horizontalTravel >= requiredTravel,
                          horizontalTravel > abs(translation.y) * 1.25 else { return }

                    // A zoomed-in page pans sideways first; navigation waits for its edge.
                    let webView = tab.activateWebView()
                    if translation.x > 0, webView.canGoBack,
                       Self.isScrolledToLeadingEdge(webView.scrollView) {
                        navigationSwipeTriggered = true
                        tab.navigateBack()
                        navigationFeedbackGenerator?.impactOccurred(intensity: 1.0)
                    } else if translation.x < 0, webView.canGoForward,
                              Self.isScrolledToTrailingEdge(webView.scrollView) {
                        navigationSwipeTriggered = true
                        tab.navigateForward()
                        navigationFeedbackGenerator?.impactOccurred(intensity: 1.0)
                    }
                } else if gesture.state == .ended
                            || gesture.state == .cancelled
                            || gesture.state == .failed {
                    navigationSwipeTriggered = false
                }
            }

            /// Whether the swipe began inside a part of the page that scrolls sideways on
            /// its own (WebKit backs CSS overflow scrolling with native scroll views).
            private static func startsInHorizontalScroller(_ pan: UIPanGestureRecognizer) -> Bool {
                guard let webView = pan.view as? WKWebView else { return false }
                let point = pan.location(in: webView)
                var view = webView.hitTest(point, with: nil)
                while let current = view, current !== webView.scrollView, current !== webView {
                    if let scroller = current as? UIScrollView,
                       scroller.isScrollEnabled,
                       scroller.contentSize.width > scroller.bounds.width + 1 {
                        return true
                    }
                    view = current.superview
                }
                return false
            }

            private static func isScrolledToLeadingEdge(_ scrollView: UIScrollView) -> Bool {
                scrollView.contentOffset.x <= -scrollView.adjustedContentInset.left + 1
            }

            private static func isScrolledToTrailingEdge(_ scrollView: UIScrollView) -> Bool {
                let maxOffsetX = scrollView.contentSize.width + scrollView.adjustedContentInset.right - scrollView.bounds.width
                return scrollView.contentOffset.x >= max(maxOffsetX, 0) - 1
            }

            @objc private func handleInteractionTap(_ g: UITapGestureRecognizer) {
                if g.state == .ended {
                    onUserInteraction?()
                    // A tap on the page brings the controls back to stay; the tap
                    // still reaches the page.
                    onToolbarScrollEvent?(.pin)
                }
            }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                if gestureRecognizer == navigationPanGesture,
                   let pan = gestureRecognizer as? UIPanGestureRecognizer {
                    let velocity = pan.velocity(in: pan.view)
                    guard abs(velocity.x) > abs(velocity.y) * 1.15 else { return false }
                    // Sideways swipes on galleries and carousels scroll them instead.
                    return !Self.startsInHorizontalScroller(pan)
                }
                return true
            }

            func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
                if gestureRecognizer == navigationPanGesture
                    || gestureRecognizer == interactionTapGesture {
                    return true
                }
                return false
            }

            @objc private func handlePullToRefresh(_ sender: UIRefreshControl) {
                tab.activateWebView().reload()
            }
        }
    }

    // MARK: - Safari wrapper (auth)
    struct SafariView: UIViewControllerRepresentable {
        let url: URL
        var entersReaderIfAvailable: Bool = false

        func makeUIViewController(context: Context) -> SFSafariViewController {
            let config = SFSafariViewController.Configuration()
            config.entersReaderIfAvailable = entersReaderIfAvailable
            return SFSafariViewController(url: url, configuration: config)
        }

        func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
    }
}

// MARK: - Font Size Settings View
struct FontSizeSettingsView: View {
    @ObservedObject var fontSizeService: FontSizeService
    var onFontSizeChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Font Size", systemImage: "textformat.size")
                    .font(.headline)
                Spacer()
                Text("\(Int(fontSizeService.baseFontSize))pt")
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("A")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                
                Slider(value: $fontSizeService.baseFontSize, in: 10...24, step: 1) { _ in
                    onFontSizeChanged()
                }
                
                Text("A")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            }
            
            Text("Preview: The quick brown fox jumps over the lazy dog")
                .font(.system(size: fontSizeService.baseFontSize))
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(8)
            
            HStack {
                Button("Reset") {
                    fontSizeService.baseFontSize = 14.0
                    onFontSizeChanged()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

// MARK: - App entry
@main
struct BrowserApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup { UBlockLiteRootView() }
    }
}

// MARK: - App Delegate for Notification Handling
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Background refresh for page watches must be registered before launch finishes.
        PageWatchBackgroundScheduler.register()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { @MainActor in
            PageWatchBackgroundScheduler.refreshSchedule()
        }
        return true
    }

    // Handle notification tap when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show the notification even when app is in foreground
        completionHandler([.banner, .sound])
    }

    // Handle notification tap
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let watchLink = userInfo[PageWatchNotification.routeKey] as? String,
           let watchURL = URL(string: watchLink) {
            // Page-watch taps route through the same handler as webmebrowser://watch links.
            NotificationCenter.default.post(
                name: PageWatchNotification.openRequested,
                object: nil,
                userInfo: ["url": watchURL]
            )
        } else if let urlString = userInfo["url"] as? String {
            // Post notification to ContentView to open this URL
            NotificationCenter.default.post(
                name: Notification.Name("OpenSharedURL"),
                object: nil,
                userInfo: ["url": urlString]
            )
        }
        completionHandler()
    }
}
