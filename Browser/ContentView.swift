import SwiftUI
import Combine
import WebKit
import SafariServices
import UIKit
import UserNotifications
import UniformTypeIdentifiers

private func browserAIFlowLog(_ message: @autoclosure () -> String) {
    print("🌐 [AIFlow] \(message())")
}

private func browserAIWebLog(_ message: @autoclosure () -> String) {
    print("🕸️ [AIWeb] \(message())")
}

// MARK: - Darwin Notification Observer (for Share Extension IPC)
class DarwinNotificationObserver: ObservableObject {
    static let notificationName = "com.browser.sharedURL" as CFString
    static let appGroupID = "group.com.browser.app"  // Update with your actual App Group ID

    var onNotificationReceived: (() -> Void)?

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
                    observerInstance.onNotificationReceived?()
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

    deinit {
        stopObserving()
    }
}

// MARK: - Glass TextField Component
struct GlassTextField: View {
    @Binding var text: String
    var placeholder: String = "Search or enter address"
    var onSubmit: (() -> Void)?
    var showClearButton: Bool = true
    var trailingAccessory: AnyView? = nil
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(.secondary)
            
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .onSubmit { onSubmit?() }
            
            if let trailingAccessory {
                trailingAccessory
            }

            if showClearButton && !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .glassEffectCompat(
            in: Capsule(),
            material: .regularMaterial,
            strokeOpacity: 0.35
        )
        .shadow(radius: 8, y: 3)
    }
}

private struct GlassEffectCompatModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let material: Material
    let tint: Color?
    let strokeOpacity: Double

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(material)
                    if let tint {
                        shape.fill(tint)
                    }
                }
            }
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(strokeOpacity),
                            Color.white.opacity(strokeOpacity * 0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
            )
    }
}

private extension View {
    func browserToolbarControl() -> some View {
        frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

extension View {
    @ViewBuilder
    func glassEffectCompat<S: InsettableShape>(
        in shape: S,
        material: Material = .ultraThinMaterial,
        tint: Color? = nil,
        strokeOpacity: Double = 0.25,
        isInteractive: Bool = true
    ) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                if isInteractive {
                    self.glassEffect(.regular.interactive().tint(tint), in: shape)
                } else {
                    self.glassEffect(.regular.tint(tint), in: shape)
                }
            } else {
                if isInteractive {
                    self.glassEffect(.regular.interactive(), in: shape)
                } else {
                    self.glassEffect(.regular, in: shape)
                }
            }
        } else {
            modifier(
                GlassEffectCompatModifier(
                    shape: shape,
                    material: material,
                    tint: tint,
                    strokeOpacity: strokeOpacity
                )
            )
        }
    }

    @ViewBuilder
    func glassEffectContainerCompat(spacing: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                self
            }
        } else {
            self
        }
    }
}

final class AIWebView: WKWebView {
    var onAskAI: (() -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(askAI(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func askAI(_ sender: Any?) {
        onAskAI?()
    }

    static func installAskAIMenu() {
        let menu = UIMenuController.shared
        let selector = #selector(AIWebView.askAI(_:))
        if let items = menu.menuItems, items.contains(where: { $0.action == selector }) {
            return
        }
        let askItem = UIMenuItem(title: "Ask Vortex", action: selector)
        menu.menuItems = (menu.menuItems ?? []) + [askItem]
    }
}

private struct BrowserWebAIRequest: Identifiable, Equatable {
    let id = UUID()
    let provider: WebAIProvider
    let title: String
    let prompt: String
    let shouldAutoCapture: Bool
    let shouldStartMinimized: Bool
}

@MainActor
private final class BrowserWebAISessionManager {
    static let shared = BrowserWebAISessionManager()

    private let processPool = WKProcessPool()
    private let websiteDataStore = WKWebsiteDataStore.default()
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
        configuration.websiteDataStore = websiteDataStore
        configuration.processPool = processPool

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

        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let domainFragments = sessionDomainFragments(for: provider)
        websiteDataStore.fetchDataRecords(ofTypes: dataTypes) { [weak self] records in
            guard let self else { return }
            let matching = records.filter { record in
                let name = record.displayName.lowercased()
                return domainFragments.contains { name.contains($0) }
            }

            self.websiteDataStore.removeData(ofTypes: dataTypes, for: matching) {
                completion("\(provider.displayName) session reset.")
            }
        }
    }

    func isLoggedIn(to provider: WebAIProvider, completion: @escaping (Bool) -> Void) {
        websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let hasAuthenticatedCookie = cookies.contains { cookie in
                let domain = cookie.domain.lowercased()
                let name = cookie.name.lowercased()

                switch provider {
                case .chatgpt:
                    let isChatGPTDomain = domain.contains("chatgpt.com") || domain.contains("openai.com")
                    let isSessionCookie = name.contains("session-token") || name.contains("auth-session")
                    return isChatGPTDomain && isSessionCookie
                case .gemini:
                    let isGoogleDomain = domain == "google.com" || domain.hasSuffix(".google.com")
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
            guard host.contains("chatgpt.com") || host.contains("openai.com") else {
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

    private func sessionDomainFragments(for provider: WebAIProvider) -> [String] {
        switch provider {
        case .chatgpt:
            return ["chatgpt.com", "openai.com", "auth.openai.com"]
        case .gemini:
            return ["gemini.google.com", "google.com", "accounts.google.com"]
        }
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

            browserAIWebLog("update request=\(parent.request.id.uuidString.prefix(8)) provider=\(parent.request.provider.displayName) changed=\(requestChanged) url=\(webView.url?.absoluteString ?? "nil") loading=\(webView.isLoading)")

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
                browserAIWebLog("update loading provider home request=\(parent.request.id.uuidString.prefix(8)) url=\(parent.request.provider.url.absoluteString)")
                webView.load(URLRequest(url: parent.request.provider.url))
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            injectionAttempts = 0
            captureFinished = false
            hasInjectedCurrentRequest = false
            expectedChunks.removeAll()
            chunkBuffers.removeAll()
            browserAIWebLog("didStart request=\(parent.request.id.uuidString.prefix(8)) url=\(webView.url?.absoluteString ?? "nil")")
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.didInject = false
                self.parent.fallbackMessage = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browserAIWebLog("didFinish request=\(parent.request.id.uuidString.prefix(8)) url=\(webView.url?.absoluteString ?? "nil")")
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            armCaptureSession(in: webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.injectPrompt(into: webView)
            }
        }

        private func injectPrompt(into webView: WKWebView) {
            if parent.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                browserAIWebLog("inject skipped empty prompt request=\(parent.request.id.uuidString.prefix(8))")
                hasInjectedCurrentRequest = true
                DispatchQueue.main.async {
                    self.parent.didInject = true
                    self.parent.fallbackMessage = nil
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
            guard parent.request.shouldAutoCapture else { return }
            captureFinished = false
            expectedChunks.removeAll()
            chunkBuffers.removeAll()
            browserAIWebLog("armCapture request=\(parent.request.id.uuidString.prefix(8)) provider=\(parent.request.provider.displayName)")
            webView.evaluateJavaScript(buildArmCaptureScript(), completionHandler: nil)
        }

        private func canReuseCurrentPage(in webView: WKWebView, for provider: WebAIProvider) -> Bool {
            guard !webView.isLoading else { return false }
            guard let host = webView.url?.host?.lowercased() else { return false }
            switch provider {
            case .chatgpt:
                return host.contains("chatgpt.com") || host.contains("openai.com")
            case .gemini:
                return host.contains("gemini.google.com") || host.contains("google.com")
            }
        }

        private func isProviderPageLoading(in webView: WKWebView, for provider: WebAIProvider) -> Bool {
            guard webView.isLoading else { return false }
            guard let host = webView.url?.host?.lowercased() else { return false }
            switch provider {
            case .chatgpt:
                return host.contains("chatgpt.com") || host.contains("openai.com")
            case .gemini:
                return host.contains("gemini.google.com") || host.contains("google.com")
            }
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
    @ScaledMetric(relativeTo: .caption) private var scaledSidebarSectionFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var scaledSidebarTitleFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var scaledSidebarSubtitleFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var scaledSidebarIconFontSize: CGFloat = 15
    @State private var tabSearchText = ""
    @State private var selectedTabScope: BrowserTabScope = .all
    @State private var showRecentlyClosedTabs = false
    @State private var showTabGroupManager = false
    @State private var showAIPanel = false
    @State private var aiHasUnreadResponse = false
    @State private var aiQuery: String = ""
    @StateObject private var aiService = SimpleAIService.shared
    @State private var splitMode: SplitMode? = nil
    @State private var splitPrimaryID: UUID?
    @State private var splitSecondaryID: UUID?
    @State private var splitSecondaryExternalTab: BrowserTab?
    @State private var showWebProviderSheet = false
    @State private var aiContextTabID: UUID?
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
    @State private var splitDropContentRect: CGRect = .zero
    private let splitDragCoordinateSpace = "browserSplitDragSpace"
    private let splitMinRatio: CGFloat = 0.25
    private let splitMaxRatio: CGFloat = 0.75
    private let splitDividerHandleLength: CGFloat = 80
    private let splitDividerHandleThickness: CGFloat = 4
    private let splitDividerHitSize: CGFloat = 16
    @State private var isToolbarCollapsed: Bool = true
    @State private var isScrolling: Bool = false
    private let toolbarPillHeight: CGFloat = 44
    // New service states
    @StateObject private var adBlockService = AdBlockService.shared
    @StateObject private var passwordManager = PasswordManager.shared
    @StateObject private var incognitoMode = IncognitoMode.shared
    @StateObject private var darkModeService = DarkModeService.shared
    @StateObject private var fontSizeService = FontSizeService.shared
    @StateObject private var thirdPartyCookieBlocker = ThirdPartyCookieBlocker.shared
    @State private var showFontSizeSettings = false
    @State private var showSettingsMenu = false
    @State private var showFilterListSettings = false
    @AppStorage("requestDesktopSite") private var requestDesktopSite: Bool = false
    @State private var pendingAISelection: AISelection?
    @State private var pendingAIReplacement: AIReplacement?
    @State private var aiSelectionContext: AISelectionContext?
    @State private var pendingWebProviderPrompt: String?
    @State private var pendingWebProviderProvider: WebAIProvider?
    @State private var pendingWebProviderTargetID: UUID?
    @State private var pendingWebProviderContextOverride: String?
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
    @State private var isTestingPCCGateway = false
    @State private var pccGatewayStatusMessage: String?
    
    // MLX Local settings
    @AppStorage("mlxModelID") private var mlxModelID: String = MLXLocalSettings.defaultModelID
    @AppStorage("mlxMaxOutputTokens") private var mlxMaxOutputTokens: Int = MLXLocalSettings.defaultMaxOutputTokens
    @AppStorage("mlxMaxContextTokens") private var mlxMaxContextTokens: Int = MLXLocalSettings.defaultMaxContextTokens
    @State private var isLoadingMLXModel: Bool = false
    @State private var mlxDownloadProgress: Progress? = nil
    @State private var mlxLoadError: String? = nil
    @State private var showMLXModelManager: Bool = false
    @State private var showDownloadLocationPicker: Bool = false
    @State private var mlxWarmupTask: Task<Void, Never>? = nil
    private let webProviderContextMaxChars = 80000

    private struct AICachedPageContent {
        let urlKey: String
        let content: PageContentExtractor.ExtractedPageContent
    }

    // Share Extension handling
    @StateObject private var darwinObserver = DarwinNotificationObserver()
    @State private var sharedURLRetryCount = 0
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

    private var isNativeIPadDevice: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad && !isMacRuntimeForIPadBuild
#else
        false
#endif
    }

    private var currentSidebarWidth: CGFloat {
        if isSidebarCollapsed {
            return max(0, min(leftSidebarBaseWidth, sidebarDrag))
        } else {
            return max(0, min(leftSidebarBaseWidth, leftSidebarBaseWidth + sidebarDrag))
        }
    }

    private var isSidebarDark: Bool {
        colorScheme == .dark || darkModeService.isDarkMode
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
            withAnimation(.easeOut(duration: 0.15)) {
                isSidebarCollapsed.toggle()
                sidebarDrag = 0
            }
        } label: {
            Image(systemName: isSidebarCollapsed ? "chevron.right" : "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(sidebarToggleForeground)
                .padding(.horizontal, 12)
                .frame(height: toolbarPillHeight)
                .glassEffectCompat(
                    in: Capsule(),
                    material: .ultraThinMaterial,
                    strokeOpacity: isSidebarDark ? 0.2 : 0.15
                )
                .shadow(
                    color: Color.black.opacity(isSidebarDark ? 0.35 : 0.2),
                    radius: 8,
                    x: 0,
                    y: 4
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSidebarCollapsed ? "Show sidebar" : "Hide sidebar")
    }

    private var aiSidebarToggleButton: some View {
        Button {
            let isOpening = !showAIPanel
            if isOpening {
                syncAIContextSelection(forceVisibleTab: true)
                prepareAIContext()
            }
            withAnimation(.easeOut(duration: 0.2)) {
                showAIPanel = isOpening
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isSidebarDark ? .white.opacity(0.85) : .primary)
                .padding(.horizontal, 12)
                .frame(height: toolbarPillHeight)
                .glassEffectCompat(
                    in: Capsule(),
                    material: .ultraThinMaterial,
                    strokeOpacity: isSidebarDark ? 0.2 : 0.15
                )
                .shadow(
                    color: Color.black.opacity(isSidebarDark ? 0.35 : 0.2),
                    radius: 8,
                    x: 0,
                    y: 4
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showAIPanel ? "Hide AI sidebar" : "Show AI sidebar")
    }

    private var exitSplitViewButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                clearSplitView()
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: splitMode == .horizontal ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.red)
                    .offset(x: 5, y: -5)
            }
            .foregroundColor(isSidebarDark ? .white.opacity(0.85) : .primary)
            .padding(.horizontal, 12)
            .frame(height: toolbarPillHeight)
            .glassEffectCompat(
                in: Capsule(),
                material: .ultraThinMaterial,
                strokeOpacity: isSidebarDark ? 0.2 : 0.15
            )
            .shadow(
                color: Color.black.opacity(isSidebarDark ? 0.35 : 0.2),
                radius: 8,
                x: 0,
                y: 4
            )
        }
        .buttonStyle(.plain)
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

    private func collapseToolbar() {
        withAnimation(.easeOut(duration: 0.15)) {
            isToolbarCollapsed = true
            omniboxFocused = false
        }
    }

    private func toolbarCollapsedPill(for tab: BrowserTab) -> some View {
        HStack(spacing: 12) {
            Button { tab.activateWebView().goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .browserToolbarControl()
            .disabled(!tab.canGoBack)

            Button { tab.activateWebView().goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .browserToolbarControl()
            .disabled(!tab.canGoForward)

            SitePrivacyShieldButton(
                url: tab.currentURL,
                webView: tab.activateWebView(),
                onOpenAdBlockSettings: { showFilterListSettings = true }
            )

            Button {
                expandToolbar(focusOmnibox: true)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .browserToolbarControl()
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(darkModeService.isDarkMode ? .white : .primary)
        .padding(.horizontal, 12)
        .frame(height: toolbarPillHeight)
        .glassEffectCompat(
            in: Capsule(),
            material: .ultraThinMaterial,
            strokeOpacity: 0.18
        )
        .shadow(radius: 8, y: 4)
        .contentShape(Capsule())
        .onTapGesture {
            expandToolbar(focusOmnibox: true)
        }
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
        selectionContextText(for: aiContextTabID)
    }

    private var activeAIContextStatusText: String? {
        guard let tab = activeAIContextTab,
              let url = tab.currentURL,
              PageContentExtractor.isRedditURL(url),
              let entry = cachedAIPageContentEntry(for: tab) else { return nil }

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
        return trimmed.isEmpty ? nil : trimmed
    }

    private var mlxAvailable: Bool {
        MLXLocalService.isAvailable()
    }

    private var isCompactWidth: Bool {
        horizontalSizeClass == .compact
    }

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
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

    private var hibernationProtectedTabIDs: Set<UUID> {
        Set([vm.selectedTabID, splitPrimaryID, splitSecondaryID, aiContextTabID].compactMap { $0 })
    }

    private func refreshHibernationProtection() {
        vm.updateProtectedTabIDs(hibernationProtectedTabIDs)
    }


    var body: some View {
        mainLayout
            .sheet(isPresented: $showRecentlyClosedTabs) {
                RecentlyClosedTabsSheet(viewModel: vm)
            }
            .sheet(isPresented: $showTabGroupManager) {
                TabGroupManagerSheet(viewModel: vm)
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
            }
            .onChange(of: splitPrimaryID) { _, _ in
                refreshHibernationProtection()
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

            Button("Focus Address Bar") {
                expandToolbar(focusOmnibox: true)
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Go Back") {
                selectedTab?.activateWebView().goBack()
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("Go Forward") {
                selectedTab?.activateWebView().goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0.001)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var selectedTab: BrowserTab? {
        guard let index = vm.selectedIndex else { return nil }
        return vm.tabs[index]
    }

    @ViewBuilder
    private var mainLayout: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let verticalInset = max(24, min(72, proxy.size.height * 0.08))
                let horizontalInset: CGFloat = 24
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
                                    if !isSidebarCollapsed {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            isSidebarCollapsed = true
                                            sidebarDrag = 0
                                        }
                                    }
                                    if showAIPanel {
                                        dismissAIPanel()
                                    }
                                }
                        )

                    // Left sidebar
                    HStack {
                        sidebarPanel
                            .frame(height: proxy.size.height - verticalInset * 2, alignment: .top)
                            .padding(.leading, horizontalInset)
                            .padding(.vertical, verticalInset)
                        Spacer()
                    }

                    // Right AI sidebar
                    HStack {
                        Spacer()
                        if showAIPanel {
                            aiSidebarPanel
                                .frame(height: proxy.size.height - verticalInset * 2, alignment: .top)
                                .padding(.trailing, horizontalInset)
                                .padding(.vertical, verticalInset)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }

                    edgeDragDetector

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
                }
                .onChange(of: splitDropRect) { _, newRect in
                    splitDropContentRect = newRect
                }
            }
            .ignoresSafeArea(.keyboard)

            // Toolbar - outside GeometryReader for proper keyboard avoidance
            if let idx = vm.selectedIndex {
                if isToolbarCollapsed {
                    HStack(spacing: 12) {
                        if isSidebarCollapsed {
                            sidebarToggleButton
                        }
                        toolbarCollapsedPill(for: vm.tabs[idx])
                        if splitMode != nil {
                            exitSplitViewButton
                        }
                        aiSidebarToggleButton
                    }
                    .glassEffectContainerCompat(spacing: 12)
                    .padding(.bottom, 24)
                    .opacity(isScrolling ? 0 : 1)
                } else {
                    toolbarView(for: vm.tabs[idx])
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .opacity(isScrolling ? 0 : 1)
                }
            }

            if let request = activeWebAIRequest {
                webAIOverlay(for: request)
            }

            if isCompactWidth && showSettingsMenu {
                compactSettingsOverlay
            }

            if showFilterListSettings {
                filterListOverlay
            }
        }
        .onChange(of: vm.tabs.count) { _ in
            syncSplitState()
            syncAIContextSelection()
        }
        .onChange(of: vm.selectedTabID) { _ in
            let previousSelected = lastSelectedTabID
            lastSelectedTabID = vm.selectedTabID
            syncSplitState()
            syncAIContextSelection(previousSelectedTabID: previousSelected)
        }
        .onChange(of: aiContextTabID) { _ in
            refreshHibernationProtection()
            if showAIPanel {
                prepareAIContext()
            }
        }
        .onChange(of: omniboxFocused) { focused in
            if focused {
                if isToolbarCollapsed {
                    expandToolbar(focusOmnibox: false)
                }
            }
        }
        .onChange(of: requestDesktopSite) { _ in
            applyUserAgentPreference()
        }
        .onChange(of: aiService.backend) { newValue in
            handleBackendSelection(newValue)
        }
        .onChange(of: mlxModelID) { newValue in
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
            lastSelectedTabID = vm.selectedTabID
            refreshHibernationProtection()
            vm.activateSelectedTab()
            applyUserAgentPreference()
            setupSharedURLHandling()
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
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                // Check when becoming active (in case Darwin notification was missed)
                checkForSharedURL()
            } else {
            }
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
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        Button {
                            dismissWebAIOverlay(userCancelled: true)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(UIColor.secondarySystemBackground))

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
                .background(Color(UIColor.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.24), radius: 24, x: 0, y: 12)
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
                                .font(.system(size: 15, weight: .semibold))
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
    private func startCapturedWebAIRequest(provider: WebAIProvider, userPrompt: String, composedPrompt: String) {
        aiService.prepareForNewContext(webProviderContextSourceTab()?.currentURL)
        browserAIWebLog("startCapturedWebAIRequest prepare userChars=\(userPrompt.count) promptChars=\(composedPrompt.count) sourceContextChars=\(aiService.sourcePageContextText?.count ?? 0)")
        guard let requestID = aiService.beginExternalWebRequest(userMessage: userPrompt) else { return }
        browserAIWebLog("startCaptured request=\(requestID.uuidString.prefix(8)) provider=\(provider.displayName) userChars=\(userPrompt.count) promptChars=\(composedPrompt.count)")
        activeWebAIServiceRequestID = requestID
        webAIIsLoading = true
        webAIDidInject = false
        webAIFallbackMessage = nil
        activeWebAIRequest = BrowserWebAIRequest(
            provider: provider,
            title: provider.displayName,
            prompt: composedPrompt,
            shouldAutoCapture: true,
            shouldStartMinimized: true
        )
        isWebAIOverlayExpanded = false
        isWebAIOverlayMinimized = true
    }

    private func sendCapturedWebProviderPrompt(
        provider: WebAIProvider,
        prompt: String,
        contextOverride: String? = nil
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        let trimmedOverride = contextOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        browserAIWebLog("sendCapturedWebProviderPrompt start provider=\(provider.displayName) promptChars=\(trimmedPrompt.count) overrideChars=\(trimmedOverride?.count ?? 0) sourceContextChars=\(aiService.sourcePageContextText?.count ?? 0)")

        let sourceTab = webProviderContextSourceTab()
        if let sourceTab {
            let contextURL = sourceTab.currentURL
            webProviderContextTabID = sourceTab.id
            webProviderContextURLString = contextURL.map { normalizedContextURL($0) }
        } else {
            webProviderContextTabID = nil
            webProviderContextURLString = nil
        }

        if let trimmedOverride, !trimmedOverride.isEmpty {
            let composed = "Selected text:\n\(trimmedOverride)\n\nUser prompt:\n\(trimmedPrompt)"
            startCapturedWebAIRequest(provider: provider, userPrompt: trimmedPrompt, composedPrompt: composed)
            return
        }

        guard let sourceTab else {
            startCapturedWebAIRequest(provider: provider, userPrompt: trimmedPrompt, composedPrompt: trimmedPrompt)
            return
        }

        if let cached = cachedAIPageContent(for: sourceTab) {
            let composed = "\(cached)\n\nUser prompt:\n\(trimmedPrompt)"
            startCapturedWebAIRequest(provider: provider, userPrompt: trimmedPrompt, composedPrompt: composed)
            return
        }

        if let sourceContext = aiService.sourcePageContextText {
            let condensed = Self.condenseText(sourceContext, maxChars: webProviderContextMaxChars)
            let composed = condensed.isEmpty ? trimmedPrompt : "\(condensed)\n\nUser prompt:\n\(trimmedPrompt)"
            browserAIWebLog("sendCaptured reusing sourcePageContext chars=\(sourceContext.count)")
            startCapturedWebAIRequest(provider: provider, userPrompt: trimmedPrompt, composedPrompt: composed)
            return
        }

        let sourceWebView = sourceTab.activateWebView()
        let contextURL = sourceTab.currentURL
        let sourceTabID = sourceTab.id
        let contextURLString = contextURL.map { normalizedContextURL($0) }
        Task {
            let extracted = await PageContentExtractor.extractContent(from: sourceWebView, url: contextURL, preferFast: true)
            let pageText = extracted?.formattedForAIContext ?? ""
            let condensed = Self.condenseText(pageText, maxChars: webProviderContextMaxChars)
            let composed = condensed.isEmpty ? trimmedPrompt : "\(condensed)\n\nUser prompt:\n\(trimmedPrompt)"
            await MainActor.run {
                guard webProviderContextTabID == sourceTabID,
                      webProviderContextURLString == contextURLString else {
                    browserAIWebLog("sendCaptured abort stale extraction start provider=\(provider.displayName)")
                    return
                }
                if let extracted {
                    storeAIPageContent(extracted, for: sourceTab)
                }
                startCapturedWebAIRequest(provider: provider, userPrompt: trimmedPrompt, composedPrompt: composed)
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
                shouldStartMinimized: false
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

    private func testPCCGatewayConnection() {
        pccGatewayStatusMessage = nil
        isTestingPCCGateway = true

        Task {
            do {
                let message = try await aiService.testPCCGatewayConnection()
                await MainActor.run {
                    self.pccGatewayStatusMessage = message
                    self.isTestingPCCGateway = false
                }
            } catch {
                await MainActor.run {
                    self.pccGatewayStatusMessage = "Connection failed: \(error.localizedDescription)"
                    self.isTestingPCCGateway = false
                }
            }
        }
    }

    // MARK: - Shared URL Handling (from Share Extension)
    private func setupSharedURLHandling() {
        darwinObserver.onNotificationReceived = { [weak darwinObserver] in
            self.checkForSharedURL()
        }
        darwinObserver.startObserving()

        // Listen for notification taps from share extension
        NotificationCenter.default.addObserver(
            forName: Notification.Name("OpenSharedURL"),
            object: nil,
            queue: .main
        ) { notification in
            if let urlString = notification.userInfo?["url"] as? String {
                self.openSharedContent(urlString)
            }
        }
    }

    private func checkForSharedURL() {
        print("DEBUG: checkForSharedURL called")

        guard let sharedDefaults = UserDefaults(suiteName: DarwinNotificationObserver.appGroupID) else {
            print("DEBUG: Failed to access App Group: \(DarwinNotificationObserver.appGroupID)")
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
        print("DEBUG: Found shared URL: \(sharedURLString)")

        // Remove the URL from shared defaults immediately
        sharedDefaults.removeObject(forKey: "sharedURL")
        sharedDefaults.synchronize()

        openSharedContent(sharedURLString)
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == shareAppURLScheme else {
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

    private func openSharedContent(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        guard let url = vm.destinationURL(from: trimmed) else { return }

        print("DEBUG: Opening new tab with URL: \(url)")

        // Create a new tab with the shared URL
        let newTab = BrowserTab(title: "Loading...", url: url)
        vm.tabs.append(newTab)
        vm.selectedTabID = newTab.id
        vm.navigate(to: url, in: newTab)
    }

    private func dismissAIPanel() {
        withAnimation(.easeOut(duration: 0.2)) {
            showAIPanel = false
        }
        if activeWebProviderTab != nil {
            clearSplitView()
        }
    }

    private var aiSidebarPanel: some View {
        AISidebar(
            aiService: aiService,
            onSend: { text in
                aiQuery = text
                if let tab = activeAIContextTab {
                    sendAIQuery(for: tab, selection: pendingAISelection)
                }
            },
            onDismiss: {
                dismissAIPanel()
            },
            contextOptions: aiContextOptions,
            selectedContextID: $aiContextTabID,
            selectionText: activeAISelectionText,
            contextStatusText: activeAIContextStatusText,
            onSummaryExtraction: { extractedContent in
                if let tab = activeAIContextTab {
                    storeAIPageContent(extractedContent, for: tab)
                }
            },
            onContextSelected: { id in
                if let tab = vm.tabs.first(where: { $0.id == id }) {
                    _ = tab.activateWebView()
                    refreshHibernationProtection()
                }
            }
        )
        .frame(width: aiSidebarBaseWidth)
        .overlay(alignment: .leading) {
            sidebarDismissHandle
        }
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
                draggedSidebarTabID = tab.id
                sidebarTabDragLocation = value.location
                activeSplitDropZone = splitDropZone(
                    at: value.location,
                    contentRect: splitDropContentRect
                )
            }
            .onEnded { value in
                guard draggedSidebarTabID == tab.id else {
                    resetSidebarTabDragState()
                    return
                }

                let dropZone = splitDropZone(
                    at: value.location,
                    contentRect: splitDropContentRect
                )
                resetSidebarTabDragState()
                if let dropZone {
                    _ = handleTabDrop(tab.id, in: dropZone)
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
                    .font(.system(size: 17, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(tab.url?.host ?? (tab.isBlank ? "Blank Tab" : tab.address))
                    .font(.system(size: 12))
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
                .font(.system(size: 15, weight: .semibold))
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

    private func clearSplitView() {
        activeSplitDropZone = nil
        let tabsToRefresh = [splitPrimaryTab, splitSecondaryTab].compactMap { $0 }
        splitMode = nil
        splitPrimaryID = nil
        splitSecondaryID = nil
        splitSecondaryExternalTab = nil
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
            webView: tab.liveWebView as WKWebView?
        )
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
        if forceVisibleTab,
           let currentSelected = vm.selectedTabID,
           options.contains(where: { $0.id == currentSelected }) {
            aiContextTabID = currentSelected
            return
        }
        if let selected = aiContextTabID,
           options.contains(where: { $0.id == selected }) {
            if let previousSelectedTabID,
               selected == previousSelectedTabID,
               let currentSelected = vm.selectedTabID,
               options.contains(where: { $0.id == currentSelected }) {
                aiContextTabID = currentSelected
            }
            return
        }
        if let currentSelected = vm.selectedTabID,
           options.contains(where: { $0.id == currentSelected }) {
            aiContextTabID = currentSelected
        } else {
            aiContextTabID = options.first?.id
        }
    }

    @MainActor
    private func prepareAIContext() {
        let contextURL = activeAIContextTab?.currentURL
        aiService.prepareForNewContext(contextURL)
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

        tab.activateWebView().evaluateJavaScript(script) { result, _ in
            let selectedText = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !selectedText.isEmpty else { return }
            pendingAISelection = AISelection(tabID: tab.id, markerID: markerID, text: selectedText)
            aiSelectionContext = AISelectionContext(tabID: tab.id, text: selectedText)
            aiContextTabID = tab.id
            aiHasUnreadResponse = false
            withAnimation(.easeOut(duration: 0.2)) {
                showAIPanel = true
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
        webView.overrideUserInterfaceStyle = .light
        tab.lastAppliedDarkMode = tab.isDarkMode
    }

    private func effectiveDarkMode(for tab: BrowserTab) -> Bool {
        tab.hasDarkModeOverride ? tab.isDarkMode : darkModeService.isDarkMode
    }

    private func applyUserAgentPreference() {
        let useDesktop = requestDesktopSite
        let userAgent = useDesktop ? BrowserTab.desktopUserAgent : BrowserTab.mobileUserAgent
        vm.setUserAgentPreference(useDesktop)
        if let external = splitSecondaryExternalTab {
            external.activateWebView().customUserAgent = userAgent
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
                .strokeBorder(Color.white.opacity(isSidebarDark ? 0.2 : 0.2), lineWidth: 1)
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
                BrowserTabOrganizerHeader(
                    searchText: $tabSearchText,
                    selectedScope: $selectedTabScope,
                    groups: vm.tabGroups,
                    recentlyClosedCount: vm.recentlyClosedTabs.count,
                    onManageGroups: { showTabGroupManager = true },
                    onShowRecentlyClosed: { showRecentlyClosedTabs = true }
                )
                sidebarSectionHeader("Tabs", systemImage: "rectangle.on.rectangle")
                sidebarNewTabRow

                ForEach(visibleSidebarTabs) { tab in
                    TabRowView(tab: tab) { observedTab in
                        tabRow(observedTab)
                    }
                }

                if visibleSidebarTabs.isEmpty {
                    Text(tabSearchText.isEmpty ? "No tabs in this group." : "No matching tabs.")
                        .font(.subheadline)
                        .foregroundStyle(sidebarSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }

                if !vm.favorites.isEmpty {
                    sidebarSectionHeader("Favorites", systemImage: "star.fill")
                    ForEach(vm.favorites) { favorite in
                        favoriteRow(favorite)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sidebarNewTabRow: some View {
        sidebarRow(
            title: "New Tab",
            action: {
                vm.addTabBlank()
                omniboxFocused = true
            }
        ) {
            Image(systemName: "plus")
                .font(.system(size: sidebarIconFontSize, weight: .semibold))
                .foregroundColor(sidebarPrimaryText)
        }
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
                                .fill(Color.purple)
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
                        .font(.system(size: 10, weight: .semibold))
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
            .padding(.bottom, tab.thumbnail != nil ? 8 : 10)

            // Thumbnail preview
            if let thumbnail = tab.thumbnail {
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

        return ZStack(alignment: .topTrailing) {
            Menu {
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
                if isPhone {
                    Button("Open in Split View Vertically") {
                        openSplitView(with: tab, mode: .horizontal)
                    }
                    .disabled(!canSplit)
                } else {
                    Button("Open in Split View Vertically") {
                        openSplitView(with: tab, mode: .vertical)
                    }
                    .disabled(!canSplit)
                    Button("Open in Split View Horizontally") {
                        openSplitView(with: tab, mode: .horizontal)
                    }
                    .disabled(!canSplit)
                }
                Divider()
                Button(role: .destructive) {
                    performClose(tab)
                } label: {
                    Label("Close Tab", systemImage: "xmark")
                }
            } label: {
                rowContent
                    .padding(.trailing, controlHitSize + controlInset)
            } primaryAction: {
                vm.selectedTabID = tab.id
                if tab.isBlank { omniboxFocused = true }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(spacing: 4) {
                // Close button
                Button {
                    performClose(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(sidebarPrimaryText)
                        .padding(6)
                        .background(
                            Circle().fill(sidebarIconBackground)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: controlHitSize, height: controlHitSize)
                .contentShape(Rectangle())
                .zIndex(2)

                if canSplit && (!isCompactWidth || isPhone) && tab.webAIProvider == nil {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(sidebarSecondaryText)
                        .padding(6)
                        .background(
                            Circle().fill(sidebarIconBackground)
                        )
                        .frame(width: controlHitSize, height: controlHitSize)
                        .contentShape(Rectangle())
                        .simultaneousGesture(sidebarTabDragGesture(for: tab))
                        .accessibilityLabel("Drag tab to split view")
                        .accessibilityHint("Drag toward an edge of the page")
                        .zIndex(2)
                }

                // More options menu (only for tabs with content)
                if !tab.isBlank && tab.url != nil {
                    Menu {
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
                                effectiveDarkMode(for: tab) ? "Disable Dark Mode" : "Enable Dark Mode",
                                systemImage: effectiveDarkMode(for: tab) ? "moon.fill" : "moon"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(sidebarPrimaryText)
                            .padding(6)
                            .background(
                                Circle().fill(sidebarIconBackground)
                            )
                            .frame(width: controlHitSize, height: controlHitSize)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .zIndex(2)
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

    private func favoriteRow(_ favorite: Favorite) -> some View {
        let canSplit = vm.selectedTabID != nil
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        // Note: Favorites are never "selected" in the same persistent way as tabs in this model,
        // but if we wanted to show selection we could check vm.selectedTabID match.
        // For now, we use default styling.
        let tint = sidebarRowBackground
        let material: Material = .ultraThinMaterial

        return Menu {
            if isPhone {
                Button("Open in Split View Vertically") {
                    openSplitView(with: favorite, mode: .horizontal)
                }
                .disabled(!canSplit)
            } else {
                Button("Open in Split View Vertically") {
                    openSplitView(with: favorite, mode: .vertical)
                }
                .disabled(!canSplit)
                Button("Open in Split View Horizontally") {
                    openSplitView(with: favorite, mode: .horizontal)
                }
                .disabled(!canSplit)
            }
            Divider()
            Button(role: .destructive) {
                vm.removeFromFavorites(favorite)
            } label: {
                Label("Remove Favorite", systemImage: "trash")
            }
        } label: {
            HStack(spacing: 10) {
                sidebarIconContainer {
                    if let faviconData = favorite.favicon,
                       let favicon = UIImage(data: faviconData) {
                        Image(uiImage: favicon)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 18, height: 18)
                            .clipped()
                    } else {
                        Image(systemName: "star.fill")
                            .font(.system(size: sidebarIconFontSize, weight: .semibold))
                            .foregroundColor(.yellow)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(favorite.title)
                        .font(.system(size: sidebarTitleFontSize, weight: .semibold))
                        .foregroundColor(sidebarPrimaryText)
                        .lineLimit(1)
                    Text(favorite.url.host ?? favorite.url.absoluteString)
                        .font(.system(size: sidebarSubtitleFontSize))
                        .foregroundColor(sidebarSecondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        } primaryAction: {
            vm.openFavoriteInNewTab(favorite)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .glassEffectCompat(
            in: shape,
            material: material,
            tint: tint,
            strokeOpacity: isSidebarDark ? 0.35 : 0.45
        )
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .clipped()
        .id("favorite-\(favorite.id)")
    }

    private var settingsButton: some View {
        sidebarRow(
            title: "Settings",
            action: {
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
        .sheet(isPresented: $showMLXModelManager) {
            ManageMLXModelsView(selectedModelID: $mlxModelID)
        }
        .onChange(of: showAIPanel) { isShowing in
            if isShowing {
                syncAIContextSelection()
                prepareAIContext()
                aiHasUnreadResponse = false
            } else {
                pendingAIQueryTask?.cancel()
                pendingAIQueryTask = nil
                pendingAIQueryToken = UUID()
                if activeWebAIServiceRequestID == nil {
                    aiService.reset()
                    if let selection = pendingAISelection, pendingAIReplacement == nil {
                        clearAISelectionHighlight(selection)
                        pendingAISelection = nil
                    }
                    clearAISelectionContext()
                }
            }
        }
        .onChange(of: aiService.messages) { messages in
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
                                HStack {
                                    Image(systemName: "key.fill")
                                        .foregroundColor(.yellow)
                                    Text("Save Password?")
                                        .font(.headline)
                                }

                                Text("Save password for \(loginForm.username) on \(loginForm.website)?")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                HStack(spacing: 12) {
                                    Button("Save") {
                                        Task {
                                            await passwordManager.saveCurrentCredentials()
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("Not Now") {
                                        passwordManager.dismissPasswordPrompt()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding()
                            .background(Color(UIColor.systemBackground))
                            .cornerRadius(10)
                            .shadow(radius: 10)
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
        VStack(spacing: 0) {
            // Top navigation bar
            HStack {
                Button {
                    showWebProviderSheet = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Done")
                            .font(.system(size: 17))
                    }
                    .foregroundColor(.accentColor)
                }
                Spacer()
                Text(tab.webAIProvider?.displayName ?? "Web AI")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                // Balance the layout
                Button {
                    if let provider = tab.webAIProvider {
                        tab.activateWebView().load(URLRequest(url: provider.url))
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(UIColor.systemBackground))

            Divider()

            // Web provider content
            splitPane(for: tab)
        }
        .background(Color(UIColor.systemBackground))
    }

    private func activeTabView(_ tab: BrowserTab) -> some View {
        ZStack(alignment: .top) {
            Group {
                if tab.isBlank {
                    Color(UIColor.systemBackground)
                } else {
                    GeometryReader { proxy in
                        WebViewHost(
                            tab: tab,
                            viewModel: vm,
                            allowEdgeGestures: true,
                            allowThumbnailCapture: true,
                            viewportSize: proxy.size,
                            onScroll: {
                                if !isToolbarCollapsed {
                                    collapseToolbar()
                                }
                                withAnimation(.easeOut(duration: 0.15)) {
                                    isScrolling = true
                                }
                            },
                            onScrollEnd: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    isScrolling = false
                                }
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
                            onNavigate: { tab, url in
                                handlePrimaryNavigation(tab, url: url)
                            }
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
                        splitPane(for: primary)
                            .frame(width: primaryWidth, height: totalHeight)
                        splitDivider(axis: .vertical)
                            .frame(width: spacing, height: totalHeight)
                        splitPane(for: secondary)
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
                        splitPane(for: secondary)
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
    private func splitPane(for tab: BrowserTab) -> some View {
        Group {
            if tab.isBlank {
                Color(UIColor.systemBackground)
            } else {
                GeometryReader { proxy in
                    WebViewHost(
                        tab: tab,
                        viewModel: vm,
                        allowEdgeGestures: true,
                        allowThumbnailCapture: true,
                        viewportSize: proxy.size,
                        onScroll: {
                            if !isToolbarCollapsed {
                                collapseToolbar()
                            }
                            withAnimation(.easeOut(duration: 0.15)) {
                                isScrolling = true
                            }
                        },
                        onScrollEnd: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                isScrolling = false
                            }
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
                        onNavigate: { tab, url in
                            handlePrimaryNavigation(tab, url: url)
                        }
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
                    }
                    clearSplitView()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
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

    @ViewBuilder
    private func toolbarView(for tab: BrowserTab) -> some View {
        if isPhone {
            HStack(spacing: 8) {
                GlassTextField(
                    text: Binding(
                        get: { tab.address },
                        set: { tab.address = $0 }
                    ),
                    placeholder: "Search or enter address",
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
                    )
                )
                .focused($omniboxFocused)
                .frame(minWidth: 0, maxWidth: .infinity)
                .layoutPriority(1)

                Button {
                    collapseToolbar()
                } label: {
                    Image(systemName: "chevron.up")
                        .foregroundColor(.secondary)
                }
                .browserToolbarControl()

                if splitMode != nil {
                    exitSplitViewButton
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        } else {
        HStack(spacing: 8) {
            Button { tab.activateWebView().goBack() } label: { Image(systemName: "chevron.left") }
                .browserToolbarControl()
                .disabled(!tab.canGoBack)

            Button { tab.activateWebView().goForward() } label: { Image(systemName: "chevron.right") }
                .browserToolbarControl()
                .disabled(!tab.canGoForward)

            Button { tab.activateWebView().reload() } label: { Image(systemName: "arrow.clockwise") }
                .browserToolbarControl()

            SitePrivacyShieldButton(
                url: tab.currentURL,
                webView: tab.activateWebView(),
                onOpenAdBlockSettings: { showFilterListSettings = true }
            )

            GlassTextField(
                text: Binding(
                    get: { tab.address },
                    set: { tab.address = $0 }
                ),
                placeholder: "Search or enter address",
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
                )
            )
            .focused($omniboxFocused)

            Button {
                collapseToolbar()
            } label: {
                Image(systemName: "chevron.up")
                    .foregroundColor(.secondary)
            }
            .browserToolbarControl()

            if passwordManager.showPasswordPrompt {
                Button(action: {
                    Task {
                        await passwordManager.saveCurrentCredentials()
                    }
                }) {
                    Image(systemName: "key.fill")
                        .foregroundColor(.yellow)
                }
                .browserToolbarControl()
                .help("Save password?")
            }

            if splitMode != nil {
                exitSplitViewButton
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        }
    }

    private var edgeDragDetector: some View {
        Group {
            if isSidebarCollapsed {
                Color.clear
                    .frame(width: 10)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Settings Menu View
    private var settingsMenuView: some View {
        settingsMenuContent
            .frame(width: 360)
        .fileImporter(
            isPresented: $showDownloadLocationPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                downloadModel(to: url)
            case .failure(let error):
                mlxLoadError = error.localizedDescription
            }
        }
    }

    private var settingsMenuContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings")
                    .font(.headline)
                    .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Default Search Engine", systemImage: "magnifyingglass")
                    Picker("Default Search Engine", selection: $vm.defaultSearchEngine) {
                        ForEach(BrowserSearchEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }

                Text("Used for new tabs and searches typed in the address bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle(isOn: $adBlockService.isEnabled) {
                    HStack {
                        Image(systemName: adBlockService.isEnabled ? "shield.fill" : "shield")
                            .foregroundColor(adBlockService.isEnabled ? .green : .primary)
                        VStack(alignment: .leading) {
                            Text("Ad Blocker")
                            if adBlockService.isEnabled {
                                Text("\(adBlockService.blockedCount) blocked")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Toggle(isOn: $thirdPartyCookieBlocker.isEnabled) {
                    HStack {
                        Image(systemName: thirdPartyCookieBlocker.isEnabled ? "shield.lefthalf.filled" : "shield")
                            .foregroundColor(thirdPartyCookieBlocker.isEnabled ? .orange : .primary)
                        Text("Block Third-Party Cookies")
                    }
                }

                Button(action: {
                    showSettingsMenu = false
                    showFilterListSettings = true
                }) {
                    HStack {
                        Image(systemName: "list.bullet.rectangle")
                            .foregroundColor(.blue)
                        Text("Manage Filter Lists")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Divider()

                Toggle(isOn: $darkModeService.isDarkMode) {
                    HStack {
                        Image(systemName: darkModeService.isDarkMode ? "moon.fill" : "moon")
                            .foregroundColor(darkModeService.isDarkMode ? .yellow : .primary)
                        Text("Dark Mode")
                    }
                }

                Divider()

                Toggle(isOn: $requestDesktopSite) {
                    HStack {
                        Image(systemName: "desktopcomputer")
                        Text("Request Desktop Site")
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Persistent Web AI Sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Log in inside Browser so ChatGPT and Gemini sessions are reused by the in-app Web AI browser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button(isChatGPTLoggedIn ? "Logged in" : "Log In to ChatGPT") {
                            openWebAILoginSession(for: .chatgpt)
                        }
                        .buttonStyle(.bordered)

                        Button("Reset ChatGPT") {
                            resetWebAISession(for: .chatgpt)
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 10) {
                        Button(isGeminiLoggedIn ? "Logged in" : "Log In to Gemini") {
                            openWebAILoginSession(for: .gemini)
                        }
                        .buttonStyle(.bordered)

                        Button("Reset Gemini") {
                            resetWebAISession(for: .gemini)
                        }
                        .buttonStyle(.bordered)
                    }

                    if let webAISettingsStatusMessage, !webAISettingsStatusMessage.isEmpty {
                        Text(webAISettingsStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "textformat.size")
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(fontSizeService.baseFontSize))pt")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("A")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Slider(value: $fontSizeService.baseFontSize, in: 10...24, step: 1) { _ in
                            if let idx = vm.selectedIndex {
                                let tab = vm.tabs[idx]
                                fontSizeService.applyFontSize(to: tab.activateWebView())
                            }
                        }

                        Text("A")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("MLX Settings (paste any MLX Hugging Face model ID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Hugging Face model id (e.g. \(MLXLocalSettings.defaultModelID))", text: $mlxModelID)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .textFieldStyle(.roundedBorder)

                    Stepper(value: $mlxMaxOutputTokens, in: 64...512, step: 64) {
                        Text("Max output tokens: \(mlxMaxOutputTokens)")
                    }

                    Stepper(value: $mlxMaxContextTokens, in: 0...8192, step: 512) {
                        Text("Context tokens: \(mlxMaxContextTokens == 0 ? "Auto" : "\(mlxMaxContextTokens)")")
                    }

                    HStack(spacing: 10) {
                        Button {
                            showDownloadLocationPicker = true
                        } label: {
                            if isLoadingMLXModel {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isLoadingMLXModel || !mlxAvailable)

                        Button {
                            mlxLoadError = nil
                            mlxDownloadProgress = nil

                            Task {
                                let modelID = mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !modelID.isEmpty else { return }
                                await MLXLocalService.shared.unloadModel(modelID: modelID)
                            }
                        } label: {
                            Image(systemName: "eject")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isLoadingMLXModel || !mlxAvailable)

                        Button {
                            showMLXModelManager = true
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isLoadingMLXModel || !mlxAvailable)
                    }

                    if let progress = mlxDownloadProgress {
                        ProgressView(progress)
                    }

                    if let mlxLoadError {
                        Text(mlxLoadError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if !mlxAvailable {
                        Text("Requires MLX packages + Apple Silicon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Button(action: {
                    let incognitoTab = BrowserTab(title: "Incognito", url: nil, isIncognito: true, useDesktopUserAgent: requestDesktopSite)
                    vm.tabs.append(incognitoTab)
                    vm.selectedTabID = incognitoTab.id
                    incognitoMode.isActive = true
                    showSettingsMenu = false
                }) {
                    HStack {
                        Image(systemName: "eye.slash")
                            .foregroundColor(.purple)
                        Text("New Incognito Tab")
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .onAppear {
                refreshWebAILoginStates()
            }
        }
    }

    private var compactSettingsOverlay: some View {
        GeometryReader { proxy in
            let width = min(settingsMenuPreferredWidth, max(280, proxy.size.width - 32))
            let height = min(settingsMenuPreferredHeight, max(320, proxy.size.height - 72))
            let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        showSettingsMenu = false
                    }

                settingsMenuContent
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: width)
                    .frame(maxHeight: height)
                    .glassEffectCompat(
                        in: shape,
                        material: .ultraThinMaterial,
                        strokeOpacity: 0.18,
                        isInteractive: false
                    )
                    .clipShape(shape)
                    .overlay(
                        shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                    .preferredColorScheme(isSidebarDark ? .dark : .light)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .fileImporter(
            isPresented: $showDownloadLocationPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                downloadModel(to: url)
            case .failure(let error):
                mlxLoadError = error.localizedDescription
            }
        }
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

                NavigationStack {
                    FilterListSettingsView()
                }
                .preferredColorScheme(isSidebarDark ? .dark : .light)
                .background(Color.clear)
                .frame(width: width, height: height)
                .glassEffectCompat(
                    in: shape,
                    material: .ultraThinMaterial,
                    strokeOpacity: 0.18,
                    isInteractive: false
                )
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .overlay(alignment: .topTrailing) {
                    Button {
                        showFilterListSettings = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
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

    private func downloadModel(to location: URL) {
        mlxLoadError = nil
        mlxDownloadProgress = nil
        isLoadingMLXModel = true

        Task {
            defer {
                Task { @MainActor in
                    isLoadingMLXModel = false
                }
            }

            guard mlxAvailable else {
                await MainActor.run {
                    mlxLoadError = "MLX Local is not available on this device/build."
                }
                return
            }

            let modelID = mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty else {
                await MainActor.run {
                    mlxLoadError = "Please enter a Hugging Face model id."
                }
                return
            }

            do {
                guard location.startAccessingSecurityScopedResource() else {
                    throw NSError(
                        domain: "MLXDownload",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot access the selected folder"]
                    )
                }
                defer { location.stopAccessingSecurityScopedResource() }

                try await MLXLocalService.shared.downloadModelToLocation(
                    modelID: modelID,
                    location: location,
                    progressHandler: { progress in
                        Task { @MainActor in
                            mlxDownloadProgress = progress
                        }
                    }
                )

                let modelPath = location.appending(path: "models/\(modelID)")
                do {
                    #if os(iOS)
                    let bookmarkData = try modelPath.bookmarkData(options: .minimalBookmark)
                    #else
                    let bookmarkData = try modelPath.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
                    #endif
                    MLXExternalModelStore.addEntry(path: modelPath.path, bookmark: bookmarkData)
                    MLXExternalModelStore.setSelected(path: modelPath.path, bookmark: bookmarkData)
                } catch {
                    throw NSError(
                        domain: "MLXDownload",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to save folder bookmark: \(error.localizedDescription)"]
                    )
                }

                await MainActor.run {
                    mlxModelID = "external:\(modelPath.path)"
                }
            } catch {
                await MainActor.run {
                    mlxLoadError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - AI Helpers
    @MainActor
    private func sendAIQuery(for tab: BrowserTab, selection: AISelection? = nil) {
        let query = aiQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        browserAIFlowLog("sendAIQuery START backend=\(aiService.backend.rawValue) tab=\(tab.id.uuidString.prefix(8)) queryChars=\(query.count) hasSelection=\(selection != nil)")
        aiQuery = ""

        // Always cancel any previous extraction task before starting a new
        // query path (fast or slow). Otherwise stale tasks can complete later
        // and enqueue unexpected follow-up work.
        pendingAIQueryTask?.cancel()
        pendingAIQueryTask = nil
        pendingAIQueryToken = UUID()

        let selectionText = selectionContextText(for: tab.id)

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
            aiService.enqueueQuery(query, pageContent: selectionText)
            return
        }
        if let cached = cachedAIPageContent(for: tab) {
            browserAIFlowLog("sendAIQuery fast-path cached page context chars=\(cached.count)")
            aiService.enqueueQuery(query, pageContent: cached)
            return
        }
        if canReuseSourcePageContext {
            browserAIFlowLog("sendAIQuery fast-path sourcePageContext reuse")
            aiService.enqueueQuery(query, pageContent: nil)
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
                let extracted = await PageContentExtractor.extractContent(
                    from: webView,
                    url: tab.currentURL,
                    preferFast: true
                )
                if let extracted {
                    await MainActor.run {
                        self.storeAIPageContent(extracted, for: tab)
                    }
                    browserAIFlowLog("sendAIQuery extracted page context bodyChars=\(extracted.body.count)")
                    contentText = extracted.formattedForAIContext
                } else {
                    browserAIFlowLog("sendAIQuery extraction returned nil")
                    contentText = nil
                }
            }
            guard !Task.isCancelled, pendingAIQueryToken == queryToken else {
                browserAIFlowLog("sendAIQuery task ABORT token=\(queryToken.uuidString.prefix(8)) cancelledOrStale=true")
                return
            }
            browserAIFlowLog("sendAIQuery enqueue token=\(queryToken.uuidString.prefix(8)) pageContentChars=\(contentText?.count ?? 0)")
            aiService.enqueueQuery(query, pageContent: contentText)
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
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        let trimmedOverride = contextOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOverride = !(trimmedOverride?.isEmpty ?? true)

        let sourceTab = webProviderContextSourceTab()
        if let sourceTab {
            let contextURL = sourceTab.currentURL
            webProviderContextTabID = sourceTab.id
            webProviderContextURLString = contextURL.map { normalizedContextURL($0) }
        } else {
            webProviderContextTabID = nil
            webProviderContextURLString = nil
        }

        if hasOverride, let trimmedOverride {
            let composed = "Selected text:\n\(trimmedOverride)\n\nUser prompt:\n\(trimmedPrompt)"
            sendWebProviderPrompt(composed, to: webView, provider: provider, targetID: webProviderTabID(for: webView))
            return
        }

        guard let sourceTab else {
            sendWebProviderPrompt(trimmedPrompt, to: webView, provider: provider, targetID: webProviderTabID(for: webView))
            return
        }

        if let cached = cachedAIPageContent(for: sourceTab) {
            let composed = "\(cached)\n\nUser prompt:\n\(trimmedPrompt)"
            sendWebProviderPrompt(composed, to: webView, provider: provider, targetID: webProviderTabID(for: webView))
            return
        }

        if let sourceContext = aiService.sourcePageContextText {
            let condensed = Self.condenseText(sourceContext, maxChars: webProviderContextMaxChars)
            let composed = condensed.isEmpty ? trimmedPrompt : "\(condensed)\n\nUser prompt:\n\(trimmedPrompt)"
            browserAIWebLog("handleWebProviderPrompt reusing sourcePageContext chars=\(sourceContext.count)")
            sendWebProviderPrompt(composed, to: webView, provider: provider, targetID: webProviderTabID(for: webView))
            return
        }

        let sourceWebView = sourceTab.activateWebView()
        let contextURL = sourceTab.currentURL
        Task {
            let extracted = await PageContentExtractor.extractContent(from: sourceWebView, url: contextURL, preferFast: true)
            let pageText = extracted?.formattedForAIContext ?? ""
            let condensed = Self.condenseText(pageText, maxChars: webProviderContextMaxChars)
            let composed: String
            if condensed.isEmpty {
                composed = trimmedPrompt
            } else {
                composed = "\(condensed)\n\nUser prompt:\n\(trimmedPrompt)"
            }
            await MainActor.run {
                if let extracted {
                    storeAIPageContent(extracted, for: sourceTab)
                }
                self.sendWebProviderPrompt(composed, to: webView, provider: provider, targetID: self.webProviderTabID(for: webView))
            }
        }
    }

    private func sendWebProviderPrompt(
        _ text: String,
        to webView: WKWebView,
        provider: WebAIProvider,
        targetID: UUID?,
        attempt: Int = 0
    ) {
        guard let payloadData = try? JSONSerialization.data(withJSONObject: ["text": text], options: []),
              var payloadString = String(data: payloadData, encoding: .utf8) else { return }

        // Escape Unicode characters that are valid in JSON but break JavaScript
        payloadString = payloadString
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

        let script = "(function(){ return window.__webProviderReceiveFromNative ? window.__webProviderReceiveFromNative(\(payloadString)) : false; })();"
        webView.evaluateJavaScript(script) { result, error in
            let success = (result as? Bool) ?? false
            if error != nil || !success {
                self.pendingWebProviderPrompt = text
                self.pendingWebProviderProvider = provider
                self.pendingWebProviderTargetID = targetID
                guard attempt < 20 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let pending = self.pendingWebProviderPrompt,
                          let pendingProvider = self.pendingWebProviderProvider else { return }
                    if pending == text && pendingProvider == provider {
                        self.sendWebProviderPrompt(
                            pending,
                            to: webView,
                            provider: provider,
                            targetID: targetID,
                            attempt: attempt + 1
                        )
                    }
                }
            } else if self.pendingWebProviderPrompt == text && self.pendingWebProviderProvider == provider {
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
        let trimmed = entry.content.formattedForAIContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cachedAIPageContentEntry(for tab: BrowserTab) -> AICachedPageContent? {
        guard let url = tab.currentURL else { return nil }
        let key = normalizedContextURL(url)
        guard let entry = aiPageContentCache[tab.id] else { return nil }
        guard entry.urlKey == key else { return nil }
        return entry
    }

    private func storeAIPageContent(_ content: PageContentExtractor.ExtractedPageContent, for tab: BrowserTab) {
        guard let url = tab.currentURL else { return }
        let trimmed = content.formattedForAIContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        aiPageContentCache[tab.id] = AICachedPageContent(
            urlKey: normalizedContextURL(url),
            content: content
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
        var allowEdgeGestures: Bool = true
        var allowThumbnailCapture: Bool = true
        var viewportSize: CGSize = .zero
        var onScroll: (() -> Void)?
        var onScrollEnd: (() -> Void)?
        var onUserInteraction: (() -> Void)?
        var onAskAI: (() -> Void)?
        var onWebProviderPrompt: ((WKWebView, WebAIProvider, String) -> Void)?
        var onWebProviderReady: ((BrowserTab) -> Void)?
        var onNavigate: ((BrowserTab, URL) -> Void)?

        func makeCoordinator() -> Coordinator {
            Coordinator(
                tab: tab,
                viewModel: viewModel,
                onScroll: onScroll,
                onScrollEnd: onScrollEnd,
                onUserInteraction: onUserInteraction,
                onWebProviderPrompt: onWebProviderPrompt,
                onWebProviderReady: onWebProviderReady,
                onNavigate: onNavigate
            )
        }

        func makeUIView(context: Context) -> WKWebView {
            let webView = tab.activateWebView()
            webView.navigationDelegate = context.coordinator
            webView.uiDelegate = context.coordinator
            webView.scrollView.delegate = context.coordinator
            webView.scrollView.alwaysBounceVertical = true
            webView.scrollView.refreshControl = context.coordinator.refreshControl
            if let aiWebView = webView as? AIWebView {
                aiWebView.onAskAI = onAskAI
                AIWebView.installAskAIMenu()
            }
            ThirdPartyCookieBlocker.shared.register(webView: webView)
            context.coordinator.installWebProviderMessageHandler(on: webView)
            context.coordinator.installGestures(on: webView)
            if webView.url == nil, let url = tab.url, !webView.isLoading {
                // Wait for ad block rules before loading (prevents race condition)
                loadWhenReady(webView: webView, url: url)
            }
            return webView
        }

        func updateUIView(_ uiView: WKWebView, context: Context) {
            let webView = tab.liveWebView ?? tab.activateWebView()
            webView.navigationDelegate = context.coordinator
            webView.uiDelegate = context.coordinator
            webView.scrollView.delegate = context.coordinator
            context.coordinator.installWebProviderMessageHandler(on: webView)
            context.coordinator.installGestures(on: webView)
            if webView.url == nil, let url = tab.url, !webView.isLoading {
                // Wait for ad block rules before loading (prevents race condition)
                loadWhenReady(webView: webView, url: url)
            }

            if webView.scrollView.refreshControl !== context.coordinator.refreshControl {
                webView.scrollView.refreshControl = context.coordinator.refreshControl
            }

            if let aiWebView = webView as? AIWebView {
                aiWebView.onAskAI = onAskAI
            }

            ThirdPartyCookieBlocker.shared.register(webView: webView)

            webView.allowsBackForwardNavigationGestures = allowEdgeGestures
            context.coordinator.setEdgeGesturesEnabled(allowEdgeGestures)

            if !webView.isLoading {
                let shouldDark = tab.hasDarkModeOverride ? tab.isDarkMode : DarkModeService.shared.isDarkMode
                webView.overrideUserInterfaceStyle = .light
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

        static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
            uiView.configuration.userContentController.removeScriptMessageHandler(forName: "webProviderPrompt")
            uiView.navigationDelegate = nil
            uiView.uiDelegate = nil
            uiView.scrollView.delegate = nil
            uiView.scrollView.refreshControl = nil
        }

        /// Wait for ad block rules to be ready before loading URL (prevents race condition on fast devices)
        private func loadWhenReady(webView: WKWebView, url: URL) {
            if AdBlockService.shared.isReady {
                webView.load(URLRequest(url: url))
            } else {
                Task {
                    // Wait up to 3 seconds for rules to compile
                    for _ in 0..<30 {
                        if AdBlockService.shared.isReady { break }
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
                    }
                    await MainActor.run {
                        webView.load(URLRequest(url: url))
                    }
                }
            }
        }

        final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
            private static let webProviderHandlerName = "webProviderPrompt"
            private let tab: BrowserTab
            private let viewModel: BrowserViewModel
            private let onScroll: (() -> Void)?
            private let onScrollEnd: (() -> Void)?
            private let onUserInteraction: (() -> Void)?
            private let onWebProviderPrompt: ((WKWebView, WebAIProvider, String) -> Void)?
            private let onWebProviderReady: ((BrowserTab) -> Void)?
            private let onNavigate: ((BrowserTab, URL) -> Void)?
            let refreshControl = UIRefreshControl()
            private var didNotifyScrollStart = false
            private var leftEdgeGesture: UIScreenEdgePanGestureRecognizer?
            private var rightEdgeGesture: UIScreenEdgePanGestureRecognizer?
            private var swipeRightGesture: UISwipeGestureRecognizer?
            private var swipeLeftGesture: UISwipeGestureRecognizer?
            private var interactionTapGesture: UITapGestureRecognizer?

            init(
                tab: BrowserTab,
                viewModel: BrowserViewModel,
                onScroll: (() -> Void)?,
                onScrollEnd: (() -> Void)?,
                onUserInteraction: (() -> Void)?,
                onWebProviderPrompt: ((WKWebView, WebAIProvider, String) -> Void)?,
                onWebProviderReady: ((BrowserTab) -> Void)?,
                onNavigate: ((BrowserTab, URL) -> Void)?
            ) {
                self.tab = tab
                self.viewModel = viewModel
                self.onScroll = onScroll
                self.onScrollEnd = onScrollEnd
                self.onUserInteraction = onUserInteraction
                self.onWebProviderPrompt = onWebProviderPrompt
                self.onWebProviderReady = onWebProviderReady
                self.onNavigate = onNavigate
                super.init()
                refreshControl.addTarget(self, action: #selector(handlePullToRefresh(_:)), for: .valueChanged)
            }

            func installWebProviderMessageHandler(on webView: WKWebView) {
                let controller = webView.configuration.userContentController
                controller.removeScriptMessageHandler(forName: Self.webProviderHandlerName)
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
                      let prompt = body["prompt"] as? String else { return }
                let targetWebView = message.webView ?? tab.liveWebView ?? tab.activateWebView()
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
                         decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
                if let url = navigationAction.request.url {
                    // For incognito tabs, be very strict about navigation
                    if tab.isIncognito {
                        // Block navigation that tries to open new windows (often external apps)
                        if navigationAction.targetFrame == nil {
                            print("Blocked new window in incognito: \(url)")
                            // Load it in the current frame instead
                            webView.load(navigationAction.request)
                            decisionHandler(.cancel)
                            return
                        }
                        
                        // Only allow http and https URLs
                        if let scheme = url.scheme?.lowercased(), scheme != "http" && scheme != "https" {
                            print("Blocked non-http scheme in incognito: \(url)")
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
                            print("Blocked app-triggering URL in incognito: \(url)")
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
                decisionHandler(.allow)
            }

            func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
                Task { @MainActor in
                    self.tab.isReaderMode = false
                }
            }

            func webView(_ webView: WKWebView,
                         decidePolicyFor navigationResponse: WKNavigationResponse,
                         decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
                // For incognito, block any response that might trigger an app
                if tab.isIncognito {
                    if let url = navigationResponse.response.url {
                        // Block any non-http(s) responses
                        if let scheme = url.scheme, scheme != "http" && scheme != "https" {
                            print("Blocked response redirect in incognito: \(url)")
                            decisionHandler(.cancel)
                            return
                        }
                    }
                }
                decisionHandler(.allow)
            }
            
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                Task { @MainActor in
                    self.tab.restoreScrollPositionIfNeeded(on: webView)
                    self.tab.title = webView.title ?? self.tab.title
                    if let u = webView.url {
                        self.tab.url = u
                        self.tab.address = u.absoluteString

                        ThirdPartyCookieBlocker.shared.updateHost(for: webView, url: u)
                        SitePrivacyStore.shared.applyPolicies(to: webView, url: u, reloadIfChanged: true)
                        
                        // Apply dark mode with per-tab override support
                        let shouldDark = self.tab.hasDarkModeOverride ? self.tab.isDarkMode : DarkModeService.shared.isDarkMode
                        webView.overrideUserInterfaceStyle = .light
                        if shouldDark {
                            DarkModeService.shared.enableDarkMode(for: webView)
                        } else {
                            DarkModeService.shared.disableDarkMode(for: webView)
                        }
                        self.tab.lastAppliedDarkMode = shouldDark
                        
                        // Apply font size
                        FontSizeService.shared.applyFontSize(to: webView)
                        
                        // Debug: Check if we're on a Microsoft auth completion page
                        if u.host?.contains("microsoft") == true || u.host?.contains("office") == true {
                            print("DEBUG: Loaded Microsoft page: \(u)")
                            
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
                            webView.evaluateJavaScript(script) { _, error in
                                if let error = error {
                                    print("Script injection error: \(error)")
                                }
                            }
                        }

                        if let provider = self.tab.webAIProvider, provider.matches(u) {
                            let script = self.webProviderBridgeScript(for: provider)
                            webView.evaluateJavaScript(script, completionHandler: nil)
                            self.onWebProviderReady?(self.tab)
                        }
                    }
                    if let u = self.tab.url {
                        self.onNavigate?(self.tab, u)
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
                refreshControl.endRefreshing()
            }

            func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
                refreshControl.endRefreshing()
            }

            // MARK: - WKUIDelegate methods
            func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
                // Handle window.open() by loading in current view
                if let url = navigationAction.request.url {
                    print("DEBUG: window.open intercepted: \(url)")
                    webView.load(navigationAction.request)
                }
                return nil
            }
            
            func webViewDidClose(_ webView: WKWebView) {
                print("DEBUG: webViewDidClose called")
                // Handle window.close() - navigate back or to home
                if webView.canGoBack {
                    webView.goBack()
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
                    notifyScrollEndIfNeeded()
                }
            }

            func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
                notifyScrollEndIfNeeded()
            }

            private func notifyScrollStartIfNeeded() {
                guard !didNotifyScrollStart else { return }
                didNotifyScrollStart = true
                onScroll?()
            }

            private func notifyScrollEndIfNeeded() {
                guard didNotifyScrollStart else { return }
                didNotifyScrollStart = false
                onScrollEnd?()
            }

            // MARK: - Gesture handling
            func installGestures(on webView: WKWebView) {
                if leftEdgeGesture?.view === webView { return }
                [leftEdgeGesture, rightEdgeGesture, swipeRightGesture, swipeLeftGesture, interactionTapGesture]
                    .compactMap { $0 }
                    .forEach { $0.view?.removeGestureRecognizer($0) }
                leftEdgeGesture = nil
                rightEdgeGesture = nil
                swipeRightGesture = nil
                swipeLeftGesture = nil
                interactionTapGesture = nil
                let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleLeftEdge(_:)))
                leftEdge.edges = .left
                leftEdge.cancelsTouchesInView = false
                leftEdge.delegate = self
                webView.addGestureRecognizer(leftEdge)

                let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleRightEdge(_:)))
                rightEdge.edges = .right
                rightEdge.cancelsTouchesInView = false
                rightEdge.delegate = self
                webView.addGestureRecognizer(rightEdge)

                let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeRight(_:)))
                swipeRight.direction = .right
                swipeRight.cancelsTouchesInView = false
                swipeRight.delegate = self
                webView.addGestureRecognizer(swipeRight)

                let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeLeft(_:)))
                swipeLeft.direction = .left
                swipeLeft.cancelsTouchesInView = false
                swipeLeft.delegate = self
                webView.addGestureRecognizer(swipeLeft)

                let interactionTap = UITapGestureRecognizer(target: self, action: #selector(handleInteractionTap(_:)))
                interactionTap.cancelsTouchesInView = false
                interactionTap.delegate = self
                webView.addGestureRecognizer(interactionTap)

                leftEdgeGesture = leftEdge
                rightEdgeGesture = rightEdge
                swipeRightGesture = swipeRight
                swipeLeftGesture = swipeLeft
                interactionTapGesture = interactionTap

                let pan = webView.scrollView.panGestureRecognizer
                pan.require(toFail: leftEdge)
                pan.require(toFail: rightEdge)
            }

            func setEdgeGesturesEnabled(_ enabled: Bool) {
                leftEdgeGesture?.isEnabled = enabled
                rightEdgeGesture?.isEnabled = enabled
                swipeRightGesture?.isEnabled = enabled
                swipeLeftGesture?.isEnabled = enabled
            }

            @objc private func handleLeftEdge(_ g: UIScreenEdgePanGestureRecognizer) {
                if g.state == .ended || g.state == .recognized {
                    let webView = tab.activateWebView()
                    if webView.canGoBack { webView.goBack() }
                }
            }

            @objc private func handleRightEdge(_ g: UIScreenEdgePanGestureRecognizer) {
                if g.state == .ended || g.state == .recognized {
                    let webView = tab.activateWebView()
                    if webView.canGoForward { webView.goForward() }
                }
            }

            @objc private func handleSwipeRight(_ g: UISwipeGestureRecognizer) {
                if g.state == .ended { let webView = tab.activateWebView(); if webView.canGoBack { webView.goBack() } }
            }

            @objc private func handleSwipeLeft(_ g: UISwipeGestureRecognizer) {
                if g.state == .ended { let webView = tab.activateWebView(); if webView.canGoForward { webView.goForward() } }
            }

            @objc private func handleInteractionTap(_ g: UITapGestureRecognizer) {
                if g.state == .ended {
                    onUserInteraction?()
                }
            }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                if let edge = gestureRecognizer as? UIScreenEdgePanGestureRecognizer {
                    let velocity = edge.velocity(in: edge.view)
                    return abs(velocity.x) > abs(velocity.y)
                }
                return true
            }

            func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
                if gestureRecognizer == leftEdgeGesture
                    || gestureRecognizer == rightEdgeGesture
                    || gestureRecognizer == swipeRightGesture
                    || gestureRecognizer == swipeLeftGesture
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
        WindowGroup { ContentView() }
    }
}

// MARK: - App Delegate for Notification Handling
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
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
        if let urlString = userInfo["url"] as? String {
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
