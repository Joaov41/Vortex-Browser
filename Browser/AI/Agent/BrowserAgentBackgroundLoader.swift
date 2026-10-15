import Foundation
import WebKit

/// Loads a page in an isolated, offscreen WebKit view and returns only bounded readable text.
/// It shares the starting tab's data store, but never its user-content controller or delegates.
@MainActor
final class BrowserAgentBackgroundLoader: NSObject, WKNavigationDelegate, WKUIDelegate {
    struct Page: Equatable {
        let title: String
        let url: URL
        let text: String
        let truncated: Bool
        var searchLinks: [SearchLink] = []
    }

    struct SearchLink: Equatable {
        let title: String
        let url: URL
    }

    enum LoadError: LocalizedError, Equatable {
        case invalidURL
        case timedOut
        case unsupportedNavigation
        case downloadBlocked
        case autofillProtectedOrigin
        case pageUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "fetch_page only accepts HTTP or HTTPS addresses."
            case .timedOut:
                return "The page did not finish loading within 15 seconds."
            case .unsupportedNavigation:
                return "The page tried to navigate outside a supported read-only web address."
            case .downloadBlocked:
                return "The page attempted to start a download, which fetch_page does not allow."
            case .autofillProtectedOrigin:
                return "Background reads are unavailable for a site that received autofill."
            case .pageUnavailable:
                return "The page loaded without readable text."
            }
        }
    }

    typealias RequestLoader = @MainActor (WKWebView, URLRequest) -> Void
    typealias PagePreparation = @MainActor (WKWebView, URL) async -> Void
    typealias FetchURLPolicy = @MainActor (URL, WKWebsiteDataStore) -> Bool

    static let maximumTextCharacters = 8_000
    static let maximumLoadDuration: TimeInterval = 15

    private let timeout: TimeInterval
    private let requestLoader: RequestLoader
    private let pagePreparation: PagePreparation
    private var fetchURLPolicy: FetchURLPolicy?
    private var fetchDataStore: WKWebsiteDataStore?
    private var collectsSearchResults = false
    private(set) var activeGeneration: UUID?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Page, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?

    init(
        timeout: TimeInterval = 15,
        requestLoader: RequestLoader? = nil,
        pagePreparation: PagePreparation? = nil
    ) {
        self.timeout = min(max(timeout, 0.01), Self.maximumLoadDuration)
        self.requestLoader = requestLoader ?? { webView, request in
            _ = webView.load(request)
        }
        self.pagePreparation = pagePreparation ?? { webView, url in
            await UBlockLiteService.shared.preparePage(webView, url: url)
        }
        super.init()
    }

    func fetch(
        url: URL,
        startingDataStore: WKWebsiteDataStore,
        isPrivate: Bool,
        urlPolicy: FetchURLPolicy? = nil,
        collectSearchResults: Bool = false
    ) async throws -> Page {
        guard Self.isHTTPURL(url) else { throw LoadError.invalidURL }
        guard urlPolicy?(url, startingDataStore) ?? true else { throw LoadError.autofillProtectedOrigin }
        guard continuation == nil, activeGeneration == nil else { throw LoadError.pageUnavailable }

        let webView = makeWebView(
            websiteDataStore: startingDataStore,
            isPrivate: isPrivate,
            initialURL: url
        )
        let generation = UUID()
        activeGeneration = generation
        fetchURLPolicy = urlPolicy
        fetchDataStore = startingDataStore
        collectsSearchResults = collectSearchResults
        self.webView = webView

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(.failure(CancellationError()), generation: generation, webView: webView)
                    return
                }
                timeoutTask = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self.finish(.failure(LoadError.timedOut), generation: generation, webView: webView)
                }
                preparationTask = Task { [weak self] in
                    self?.startLoad(url: url, generation: generation, webView: webView)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelLoad(generation: generation, webView: webView)
            }
        }
    }

    /// Kept internal so tests can inspect the exact store and fresh script controller without
    /// opening an external page or adding a production launch flag.
    func makeWebView(
        websiteDataStore: WKWebsiteDataStore,
        isPrivate: Bool,
        initialURL: URL? = nil
    ) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.userContentController = WKUserContentController()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if isPrivate {
            configuration.userContentController.addUserScript(
                WKUserScript(source: IncognitoMode.shared.getPrivacyScript(), injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
        UBlockLiteService.shared.configure(configuration, isPrivate: isPrivate)

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        AdBlockService.shared.configureWebView(webView)
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: Self.readOnlyPageScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        ThirdPartyCookieBlocker.shared.register(webView: webView)
        SitePrivacyStore.shared.applyPolicies(to: webView, url: initialURL, reloadIfChanged: false)
        return webView
    }

    private func startLoad(url: URL, generation: UUID, webView: WKWebView) {
        guard isActive(generation: generation, webView: webView) else { return }
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
        request.httpMethod = "GET"
        requestLoader(webView, request)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let generation = activeGeneration, isActive(generation: generation, webView: webView) else {
            decisionHandler(.cancel)
            return
        }
        let hasTargetFrame = navigationAction.targetFrame != nil
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        guard Self.allowsNavigation(
            url: navigationAction.request.url,
            isMainFrame: isMainFrame,
            hasTargetFrame: hasTargetFrame,
            isDownload: navigationAction.shouldPerformDownload,
            method: navigationAction.request.httpMethod
        ) else {
            decisionHandler(.cancel)
            if Self.shouldFailForBlockedNavigation(isMainFrame: isMainFrame) {
                finish(
                    .failure(navigationAction.shouldPerformDownload ? LoadError.downloadBlocked : LoadError.unsupportedNavigation),
                    generation: generation,
                    webView: webView
                )
            }
            return
        }
        if let url = navigationAction.request.url, !isAllowedByFetchPolicy(url) {
            decisionHandler(.cancel)
            if Self.shouldFailForBlockedNavigation(isMainFrame: isMainFrame) {
                finish(
                    .failure(LoadError.autofillProtectedOrigin),
                    generation: generation,
                    webView: webView
                )
            }
            return
        }
        if isMainFrame, let url = navigationAction.request.url {
            AdBlockService.shared.setProtectionEnabled(!SitePrivacyStore.shared.isAdBlockingPaused(for: url), for: webView)
            ThirdPartyCookieBlocker.shared.setProtectionEnabled(!SitePrivacyStore.shared.isCookieBlockingAllowed(for: url), for: webView)
            preparationTask?.cancel()
            preparationTask = Task { [weak self, weak webView] in
                guard let self, let webView else {
                    decisionHandler(.cancel)
                    return
                }
                await self.pagePreparation(webView, url)
                guard self.isActive(generation: generation, webView: webView), !Task.isCancelled else {
                    decisionHandler(.cancel)
                    return
                }
                decisionHandler(.allow)
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard let generation = activeGeneration, isActive(generation: generation, webView: webView) else {
            decisionHandler(.cancel)
            return
        }
        let disposition = BrowserDownloadPolicy.contentDispositionHeader(from: navigationResponse.response)
        if let url = navigationResponse.response.url, !isAllowedByFetchPolicy(url) {
            decisionHandler(.cancel)
            if Self.shouldFailForBlockedNavigation(isMainFrame: navigationResponse.isForMainFrame) {
                finish(
                    .failure(LoadError.autofillProtectedOrigin),
                    generation: generation,
                    webView: webView
                )
            }
            return
        }
        guard Self.allowsResponse(
            url: navigationResponse.response.url,
            isMainFrame: navigationResponse.isForMainFrame,
            canShowMIMEType: navigationResponse.canShowMIMEType,
            contentDisposition: disposition
        ) else {
            decisionHandler(.cancel)
            if Self.shouldFailForBlockedNavigation(isMainFrame: navigationResponse.isForMainFrame) {
                let isAttachment = BrowserDownloadPolicy.contentDispositionIndicatesAttachment(disposition)
                finish(
                    .failure(isAttachment || !navigationResponse.canShowMIMEType ? LoadError.downloadBlocked : LoadError.unsupportedNavigation),
                    generation: generation,
                    webView: webView
                )
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let generation = activeGeneration, isActive(generation: generation, webView: webView) else { return }
        guard let committedURL = webView.url else {
            finish(.failure(LoadError.pageUnavailable), generation: generation, webView: webView)
            return
        }
        guard isAllowedByFetchPolicy(committedURL) else {
            finish(.failure(LoadError.autofillProtectedOrigin), generation: generation, webView: webView)
            return
        }
        Task { [weak self, weak webView] in
            guard let self, let webView, self.isActive(generation: generation, webView: webView) else { return }
            do {
                let value = try await webView.callAsyncJavaScript(
                    Self.readablePageScript,
                    arguments: ["limit": Self.maximumTextCharacters],
                    in: nil,
                    contentWorld: .page
                )
                guard self.isActive(generation: generation, webView: webView) else { return }
                guard let object = value as? [String: Any],
                      let text = object["text"] as? String,
                      (self.collectsSearchResults || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                      let documentURLString = object["url"] as? String,
                      let documentURL = URL(string: documentURLString),
                      documentURL == committedURL,
                      let pageURL = BrowserAgentExtractionParser.safeSourceURL(committedURL) else {
                    finish(.failure(LoadError.pageUnavailable), generation: generation, webView: webView)
                    return
                }
                var page = Page(
                    title: Self.bounded(object["title"] as? String ?? "", limit: 240),
                    url: pageURL,
                    text: Self.bounded(text, limit: Self.maximumTextCharacters),
                    truncated: object["truncated"] as? Bool ?? false
                )
                if self.collectsSearchResults {
                    page.searchLinks = await self.collectSearchLinks(
                        webView: webView,
                        generation: generation
                    )
                    guard self.isActive(generation: generation, webView: webView),
                          webView.url == committedURL else { return }
                }
                finish(.success(page), generation: generation, webView: webView)
            } catch {
                guard self.isActive(generation: generation, webView: webView) else { return }
                finish(.failure(LoadError.pageUnavailable), generation: generation, webView: webView)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let generation = activeGeneration else { return }
        finish(.failure(LoadError.pageUnavailable), generation: generation, webView: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let generation = activeGeneration else { return }
        finish(.failure(LoadError.pageUnavailable), generation: generation, webView: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let generation = activeGeneration else { return }
        finish(.failure(LoadError.pageUnavailable), generation: generation, webView: webView)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        return nil
    }

    /// Completes only the captured request and view, so delayed callbacks cannot end a later fetch.
    func cancelLoad(generation: UUID, webView: WKWebView) {
        finish(.failure(CancellationError()), generation: generation, webView: webView)
    }

    private func isActive(generation: UUID, webView: WKWebView) -> Bool {
        activeGeneration == generation && self.webView === webView && continuation != nil
    }

    private func isAllowedByFetchPolicy(_ url: URL) -> Bool {
        guard let fetchURLPolicy, let fetchDataStore else { return true }
        return fetchURLPolicy(url, fetchDataStore)
    }

    private func collectSearchLinks(
        webView: WKWebView,
        generation: UUID
    ) async -> [SearchLink] {
        let deadline = Date().addingTimeInterval(2)
        while true {
            guard isActive(generation: generation, webView: webView), !Task.isCancelled else { return [] }
            guard let value = try? await webView.callAsyncJavaScript(
                Self.searchLinksScript,
                arguments: [:],
                in: nil,
                contentWorld: .page
            ), isActive(generation: generation, webView: webView), !Task.isCancelled else { return [] }
            let links = Self.parseSearchLinks(value)
            if !links.isEmpty || Date() >= deadline { return links }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func parseSearchLinks(_ value: Any?) -> [SearchLink] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let href = entry["href"] as? String,
                  let url = URL(string: href),
                  isHTTPURL(url) else { return nil }
            return SearchLink(title: entry["title"] as? String ?? "", url: url)
        }
    }

    private func finish(_ result: Result<Page, Error>, generation: UUID, webView expectedWebView: WKWebView) {
        guard activeGeneration == generation,
              webView === expectedWebView,
              let continuation else { return }
        self.continuation = nil
        activeGeneration = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        preparationTask?.cancel()
        preparationTask = nil
        fetchURLPolicy = nil
        fetchDataStore = nil
        collectsSearchResults = false
        expectedWebView.stopLoading()
        expectedWebView.navigationDelegate = nil
        expectedWebView.uiDelegate = nil
        self.webView = nil
        continuation.resume(with: result)
    }

    static func isHTTPURL(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    static func isReadOnlyMethod(_ method: String?) -> Bool {
        let method = (method ?? "GET").uppercased()
        return method == "GET" || method == "HEAD"
    }

    static func allowsNavigation(
        url: URL?,
        isMainFrame: Bool,
        hasTargetFrame: Bool,
        isDownload: Bool,
        method: String?
    ) -> Bool {
        guard hasTargetFrame,
              !isDownload,
              isReadOnlyMethod(method),
              allowsFrameURL(url, isMainFrame: isMainFrame) else { return false }
        return true
    }

    static func allowsResponse(
        url: URL?,
        isMainFrame: Bool,
        canShowMIMEType: Bool,
        contentDisposition: String? = nil
    ) -> Bool {
        guard canShowMIMEType,
              allowsFrameURL(url, isMainFrame: isMainFrame),
              !BrowserDownloadPolicy.contentDispositionIndicatesAttachment(contentDisposition) else { return false }
        return true
    }

    /// Child frames are untrusted page content and receive the same HTTP(S)-only scheme allowlist.
    /// In particular, a non-main-frame request is never an escape hatch for file:, javascript:,
    /// mailto:, or other browser-handled URL schemes.
    private static func allowsFrameURL(_ url: URL?, isMainFrame: Bool) -> Bool {
        guard isHTTPURL(url) else { return false }
        guard !isMainFrame else { return true }
        return url?.scheme?.lowercased() == "http" || url?.scheme?.lowercased() == "https"
    }

    static func shouldFailForBlockedNavigation(isMainFrame: Bool) -> Bool {
        isMainFrame
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        String(value.replacingOccurrences(of: "\u{0000}", with: "").prefix(limit))
    }

    private static let readablePageScript = #"""
    const maxChars = Math.max(1, Math.min(8000, Number(limit) || 8000));
    const root = document.querySelector('main,article,[role=main]') || document.body || document.documentElement;
    const ignored = 'script,style,template,noscript,input,textarea,select,option,button,[contenteditable],[role=textbox],[role=searchbox],[hidden],[aria-hidden="true"],[inert]';
    const block = 'address,article,blockquote,dd,div,dl,dt,fieldset,figcaption,figure,footer,h1,h2,h3,h4,h5,h6,header,li,main,nav,ol,p,pre,section,table,td,th,ul';
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const maxNodes = 20000;
    let visitedNodes = 0;
    let text = '';
    let truncated = false;
    let previousBlock = null;
    let node;
    while ((node = walker.nextNode()) && visitedNodes < maxNodes && text.length < maxChars) {
      visitedNodes++;
      const parent = node.parentElement;
      if (!parent || parent.closest(ignored)) continue;
      let visible = true;
      for (let ancestor = parent; ancestor; ancestor = ancestor.parentElement) {
        const style = getComputedStyle(ancestor);
        if (ancestor.hasAttribute('hidden') || ancestor.getAttribute('aria-hidden') === 'true' || ancestor.hasAttribute('inert') ||
            style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || Number(style.opacity) === 0) {
          visible = false;
          break;
        }
        if (ancestor === root) break;
      }
      if (!visible) continue;
      const rawPart = String(node.nodeValue || '');
      const boundedPart = rawPart.slice(0, maxChars + 1024);
      if (rawPart.length > boundedPart.length) truncated = true;
      const part = boundedPart.replace(/\s+/g, ' ').trim();
      if (!part) continue;
      const blockElement = parent.closest(block) || parent;
      const separator = text && blockElement !== previousBlock ? '\n'
        : (text && /[\w]$/.test(text) && /^[\w]/.test(part) ? ' ' : '');
      const remaining = Math.max(0, maxChars - text.length);
      const addition = separator + part;
      if (addition.length > remaining) {
        text += addition.slice(0, remaining);
        truncated = true;
        break;
      }
      text += addition;
      previousBlock = blockElement;
    }
    if (visitedNodes >= maxNodes || text.length >= maxChars) truncated = true;
    text = text.replace(/\n{3,}/g, '\n\n').trim();
    return { url: String(document.URL || ''), title: String(document.title || '').slice(0, 240), text: text.slice(0, maxChars), truncated };
    """#

    static let searchLinksScript = #"""
    const searchHost = String(location.hostname || '');
    const specific = new Set(Array.from(document.querySelectorAll(
      'a[data-testid="result-title-a"], a.result__a, h2 a[href], h3 a[href]'
    )));
    const anchors = Array.from(document.querySelectorAll('a[href]')).filter(anchor =>
      specific.has(anchor) || anchor.querySelector('h2,h3') !== null
    );
    const seen = new Set();
    const results = [];
    for (const anchor of anchors) {
      if (results.length >= 20) break;
      if (anchor.getClientRects().length === 0) continue;
      const style = getComputedStyle(anchor);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') continue;
      if (anchor.closest('[aria-hidden="true"],[inert],[data-text-ad],[data-testid="ad"],.result--ad') !== null) continue;
      let resolved;
      try {
        resolved = new URL(anchor.getAttribute('href') || '', document.baseURI);
      } catch (_) {
        continue;
      }
      if (resolved.hostname === searchHost && (resolved.pathname === '/url' || resolved.pathname === '/l/')) {
        let target = null;
        for (const key of ['q', 'url', 'uddg']) {
          const value = resolved.searchParams.get(key);
          if (!value) continue;
          try {
            const candidate = new URL(value);
            if (candidate.protocol === 'http:' || candidate.protocol === 'https:') {
              target = candidate;
              break;
            }
          } catch (_) {}
        }
        if (target === null) continue;
        resolved = target;
      } else if (resolved.hostname === searchHost) {
        continue;
      }
      if (resolved.protocol !== 'http:' && resolved.protocol !== 'https:') continue;
      if (seen.has(resolved.href)) continue;
      seen.add(resolved.href);
      const rawTitle = String(anchor.textContent || anchor.getAttribute('aria-label') || '').trim();
      results.push({ title: rawTitle.slice(0, 160), href: resolved.href });
    }
    return results;
    """#

    private static let readOnlyPageScript = #"""
    (() => {
      try { window.open = () => null; } catch (_) {}
      const safeMethod = method => ['GET', 'HEAD'].includes(String(method || 'GET').toUpperCase());
      document.addEventListener('submit', event => { event.preventDefault(); event.stopImmediatePropagation(); }, true);
      for (const methodName of ['submit', 'requestSubmit']) {
        try { HTMLFormElement.prototype[methodName] = function() {}; } catch (_) {}
      }
      if (typeof globalThis.fetch === 'function') {
        const originalFetch = globalThis.fetch.bind(globalThis);
        globalThis.fetch = function(input, init) {
          const method = init && init.method ? init.method : (input instanceof Request ? input.method : 'GET');
          return safeMethod(method) ? originalFetch(input, init) : Promise.reject(new TypeError('Read-only page loads do not allow write requests.'));
        };
      }
      if (globalThis.XMLHttpRequest) {
        const methods = new WeakMap();
        const open = XMLHttpRequest.prototype.open;
        const send = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, ...args) {
          methods.set(this, method);
          return open.call(this, method, ...args);
        };
        XMLHttpRequest.prototype.send = function(...args) {
          if (!safeMethod(methods.get(this))) { this.abort(); return; }
          return send.apply(this, args);
        };
      }
      try { if (navigator.sendBeacon) navigator.sendBeacon = () => false; } catch (_) {}
    })();
    """#
}
