import Combine
import SwiftUI
import WebKit

/// Only included in the isolated Vortex Lite experiment.
@MainActor
final class UBlockLiteService: ObservableObject {
    enum Engine: String, CaseIterable, Identifiable {
        case ublockLite, vortex, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ublockLite: "uBlock Origin Lite"
            case .vortex: "Vortex"
            case .off: "Off"
            }
        }
    }

    static let shared = UBlockLiteService()
    @Published private(set) var engine: Engine
    @Published private(set) var isReady = false
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var version = "2026.907.2003"
    /// Version of the network rule data currently loaded; equals `version` until an update is applied.
    @Published private(set) var rulesVersion = "2026.907.2003"
    /// True while the extension loads from the extracted package directory rather than the bundled zip.
    private(set) var loadsFromPackageStore = false
    /// Wall-clock duration of the startup preparation that gates the first UI frame.
    private(set) var prepareDuration: TimeInterval?
    let regular = UBlockLiteRuntime(isPrivate: false)
    let privateRuntime = UBlockLiteRuntime(isPrivate: true)
    let packageStore = UBOLPackageStore()
    lazy var rulesUpdater = UBOLRulesUpdater(store: packageStore)
    private var preparation: Task<Void, Never>?
    private var extensionResource: WKWebExtension?
    /// The private runtime is nonpersistent, so WebKit recompiles its rule list on every load. It starts
    /// after the first regular page is ready, or immediately when a private page needs it.
    private var privateLoad: Task<Void, Error>?
    private var deferredPrivateLoad: Task<Void, Never>?
    private static let compiledRulesKey = "experimental.ubolCompiledRules"

    private init() {
        WKWebExtension.MatchPattern.registerCustomURLScheme("safari-web-extension")
        engine = Engine(rawValue: UserDefaults.standard.string(forKey: "experimental.blockerEngine") ?? "") ?? .ublockLite
        regular.owner = self
        privateRuntime.owner = self
    }

    func prepare() async {
        if isReady { return }
        if let preparation { await preparation.value; return }
        let task = Task { @MainActor in
            let start = Date()
            await changeEngine(to: engine, reload: false)
            prepareDuration = Date().timeIntervalSince(start)
            isReady = true
        }
        preparation = task
        await task.value
    }

    func select(_ value: Engine) {
        guard !isChanging, value != engine else { return }
        Task { await changeEngine(to: value, reload: true) }
    }

    private func changeEngine(to value: Engine, reload: Bool) async {
        guard !isChanging else { return }
        isChanging = true
        defer { isChanging = false }
        errorMessage = nil
        do {
            if value == .ublockLite {
                if extensionResource == nil { extensionResource = try await loadExtensionResource() }
                guard let extensionResource else { throw failure("Could not load the extension.") }
                try await regular.load(extensionResource)
                AdBlockService.shared.isEnabled = false
                Task { await rulesUpdater.checkIfDue() }
            } else {
                await cancelPrivateRuntimeLoad()
                try regular.unload()
                try privateRuntime.unload()
                AdBlockService.shared.isEnabled = value == .vortex
                if value == .vortex { AdBlockService.shared.prepareAsync() }
            }
            engine = value
            UserDefaults.standard.set(value.rawValue, forKey: "experimental.blockerEngine")
        } catch {
            // Never advertise Lite protection after a failed load, or run two blockers accidentally.
            await cancelPrivateRuntimeLoad()
            try? regular.unload()
            try? privateRuntime.unload()
            engine = .vortex
            AdBlockService.shared.isEnabled = true
            AdBlockService.shared.prepareAsync()
            errorMessage = "uBlock Origin Lite could not start: \(error.localizedDescription) Vortex protection is active."
        }
        if reload {
            for runtime in [regular, privateRuntime] {
                for window in runtime.windows {
                    for tab in window.tabBridges.values { tab.tab?.liveWebView?.reload() }
                }
            }
        }
    }

    /// Loads the extension from the extracted, policy-filtered official package so rule data can be updated.
    /// Falls back to the bundled pre-filtered zip if the package directory cannot be prepared.
    private func loadExtensionResource() async throws -> WKWebExtension {
        if let official = Bundle.main.url(forResource: "UBOLite.safari", withExtension: "zip") {
            do {
                let state = try packageStore.prepareActivePackage(bundledArchive: official, packageVersion: version)
                let resource = try await WKWebExtension(resourceBaseURL: packageStore.activeURL)
                rulesVersion = state.rulesVersion
                loadsFromPackageStore = true
                return resource
            } catch {
                print("uBOL package store unavailable, using bundled package: \(error.localizedDescription)")
            }
        }
        guard let url = Bundle.main.url(forResource: "UBOLite.webkit", withExtension: "zip") else {
            throw failure("The bundled uBlock Origin Lite package is missing.")
        }
        rulesVersion = version
        loadsFromPackageStore = false
        return try await WKWebExtension(resourceBaseURL: url)
    }

    /// Applies a staged network-rules update: swaps the rule files, reloads the extension from the updated
    /// package, waits for WebKit to compile and re-enable the rulesets, and rolls back if that fails.
    func applyRulesUpdate() async {
        guard engine == .ublockLite, !isChanging, loadsFromPackageStore else { return }
        isChanging = true
        rulesUpdater.markApplying(true)
        defer { isChanging = false; rulesUpdater.markApplying(false) }
        errorMessage = nil
        await cancelPrivateRuntimeLoad()
        try? regular.unload()
        try? privateRuntime.unload()
        regular.discardContext()
        privateRuntime.discardContext()
        var appliedVersion: String?
        do {
            let state = try packageStore.applyPending()
            appliedVersion = state.rulesVersion
            rulesUpdater.setStatus("Applying \(state.rulesVersion)…")
            try await reloadRegularRuntime(expectedRulesets: Self.expectedRulesetCount())
            rulesVersion = state.rulesVersion
            rulesUpdater.setStatus("Rules \(state.rulesVersion) are active.")
        } catch {
            let failed = appliedVersion ?? "update"
            var message = "Rules update \(failed) failed to load and was rolled back: \(error.localizedDescription)"
            if let appliedVersion {
                _ = try? packageStore.rollback(rejecting: appliedVersion)
            }
            do {
                try await reloadRegularRuntime(expectedRulesets: nil)
                rulesVersion = packageStore.loadState()?.rulesVersion ?? version
            } catch {
                message += " Restoring the previous rules also failed; Vortex protection is active."
                await failOver(error)
            }
            rulesUpdater.setStatus(message)
        }
        for runtime in [regular, privateRuntime] {
            for window in runtime.windows {
                for tab in window.tabBridges.values { tab.tab?.liveWebView?.reload() }
            }
        }
    }

    /// Recreates the extension from the package directory and requires the refreshed rulesets to load cleanly.
    private func reloadRegularRuntime(expectedRulesets: Int?) async throws {
        let resource = try await WKWebExtension(resourceBaseURL: packageStore.activeURL)
        extensionResource = resource
        try await regular.load(resource)
        let enabled = try await regular.awaitRulesRefresh()
        if let context = regular.context, !context.errors.isEmpty {
            throw failure(context.errors.map(\.localizedDescription).joined(separator: " "))
        }
        if let expectedRulesets, enabled.count != expectedRulesets {
            throw failure("Expected \(expectedRulesets) enabled rulesets, found \(enabled.count).")
        }
    }

    private static func expectedRulesetCount() -> Int? {
        UserDefaults.standard.object(forKey: "experimental.ubolEnabledRulesetCount") as? Int
    }
    func recordEnabledRulesetCount(_ count: Int) {
        UserDefaults.standard.set(count, forKey: "experimental.ubolEnabledRulesetCount")
    }

    /// Hold navigation until this view has native rules from the current controller load.
    func preparePage(_ webView: WKWebView) async {
        guard engine == .ublockLite else { return }
        let isPrivate = !webView.configuration.websiteDataStore.isPersistent
        do {
            if isPrivate { try await loadPrivateRuntimeIfNeeded() }
            try await runtime(isPrivate: isPrivate).preparePage(webView)
            if !isPrivate { schedulePrivateRuntimeLoad() }
        } catch {
            await failOver(error)
        }
    }

    /// A runtime that cannot become ready must not keep advertising Lite protection.
    func runtimeFailed(_ error: Error) {
        Task { @MainActor in await failOver(error) }
    }

    private func failOver(_ error: Error) async {
        guard engine == .ublockLite, !isChanging else { return }
        await changeEngine(to: .vortex, reload: false)
        errorMessage = "Lite filtering could not become ready: \(error.localizedDescription) Vortex protection is active."
    }

    private func loadPrivateRuntimeIfNeeded() async throws {
        deferredPrivateLoad?.cancel()
        deferredPrivateLoad = nil
        if privateRuntime.context?.isLoaded == true { return }
        let load: Task<Void, Error>
        if let privateLoad {
            load = privateLoad
        } else {
            guard let extensionResource else { throw failure("Could not load the extension.") }
            load = Task { @MainActor in try await self.privateRuntime.load(extensionResource) }
            privateLoad = load
        }
        do { try await load.value } catch {
            if privateLoad == load { privateLoad = nil }
            throw error
        }
    }

    private func schedulePrivateRuntimeLoad() {
        guard engine == .ublockLite, deferredPrivateLoad == nil, privateLoad == nil, privateRuntime.context?.isLoaded != true else { return }
        deferredPrivateLoad = Task { @MainActor in
            // Let the first page render before WebKit compiles the private rule list.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, engine == .ublockLite else { return }
            do { try await loadPrivateRuntimeIfNeeded() } catch { runtimeFailed(error) }
        }
    }

    private func cancelPrivateRuntimeLoad() async {
        deferredPrivateLoad?.cancel()
        deferredPrivateLoad = nil
        if let privateLoad { _ = try? await privateLoad.value }
        privateLoad = nil
    }

    /// WebKit caches the compiled rule list for the persistent regular runtime; the cache is keyed by
    /// the translated rules, so it stays valid until the package, app build or OS changes.
    private var compiledRulesMarker: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(version)|\(rulesVersion)|\(build)|\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
    var compiledRulesAreCurrent: Bool { UserDefaults.standard.string(forKey: Self.compiledRulesKey) == compiledRulesMarker }
    func markCompiledRulesCurrent() { UserDefaults.standard.set(compiledRulesMarker, forKey: Self.compiledRulesKey) }

    func configure(_ configuration: WKWebViewConfiguration, isPrivate: Bool) {
        configuration.webExtensionController = runtime(isPrivate: isPrivate).controller
    }

    func runtime(isPrivate: Bool) -> UBlockLiteRuntime { isPrivate ? privateRuntime : regular }

    func attach(_ model: BrowserViewModel) {
        regular.attach(model)
        privateRuntime.attach(model)
    }

    func didCreateWebView(for tab: BrowserTab) {
        let runtime = runtime(isPrivate: tab.isIncognito)
        for window in runtime.windows {
            guard let previous = window.tabBridges[tab.id] else { continue }
            let replacement = UBlockLiteTab(tab: tab, window: window, position: previous.position)
            window.tabBridges[tab.id] = replacement
            runtime.controller.didReplaceTab(previous, with: replacement)
            if window.model?.selectedTabID == tab.id {
                runtime.controller.didActivateTab(replacement, previousActiveTab: previous)
            }
        }
    }

    func showPopup(for webView: WKWebView) {
        guard engine == .ublockLite, !isChanging else { return }
        let runtime = runtime(isPrivate: !webView.configuration.websiteDataStore.isPersistent)
        guard let tab = runtime.windows.lazy.flatMap({ Array($0.tabBridges.values) }).first(where: { $0.tab?.liveWebView === webView }),
              let context = runtime.context else { return }
        runtime.focusedWindow = tab.hostWindow
        context.userGesturePerformed(in: tab)
        context.performAction(for: tab)
    }

    func showSettings(isPrivate: Bool = false) {
        guard let context = runtime(isPrivate: isPrivate).context,
              let url = context.optionsPageURL,
              let configuration = context.webViewConfiguration else { return }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        webView.load(URLRequest(url: url))
        present(title: isPrivate ? "uBlock Lite · Private" : "uBlock Origin Lite", webView: webView)
    }

    func failure(_ message: String) -> NSError {
        NSError(domain: "VortexLite", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
final class UBlockLiteRuntime: NSObject, WKWebExtensionControllerDelegate {
    let isPrivate: Bool
    let controller: WKWebExtensionController
    private(set) var context: WKWebExtensionContext?
    private let readyViews = NSHashTable<WKWebView>.weakObjects()
    #if DEBUG
    private(set) var rulesRefreshCount = 0
    private(set) var bridgePageCreationCount = 0
    #endif
    private var refreshTask: Task<[String], Error>?
    private var bridgePage: UBlockLiteBridgePage?
    private var generation = 0
    weak var owner: UBlockLiteService?
    var windows: [UBlockLiteWindow] = []
    weak var focusedWindow: UBlockLiteWindow?

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
        let configuration: WKWebExtensionController.Configuration = isPrivate ? .nonPersistent() : .init(identifier: UUID(uuidString: "3D291E32-96AA-4A30-AC13-6E565D596C24")!)
        if isPrivate {
            let store = WKWebsiteDataStore.nonPersistent()
            configuration.defaultWebsiteDataStore = store
            let webConfiguration = WKWebViewConfiguration()
            webConfiguration.websiteDataStore = store
            configuration.webViewConfiguration = webConfiguration
        }
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    func load(_ resource: WKWebExtension) async throws {
        if context?.isLoaded == true { return }
        let context = self.context ?? WKWebExtensionContext(for: resource)
        context.uniqueIdentifier = isPrivate ? "vortex-ubol-private" : "vortex-ubol"
        context.baseURL = URL(string: "safari-web-extension://\(context.uniqueIdentifier)/")!
        context.isInspectable = true
        context.hasAccessToPrivateData = isPrivate
        // This host only loads the pinned, bundled uBOL package, never arbitrary extensions.
        // Selecting Lite grants the permissions declared by that package for filtering.
        for permission in resource.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission, expirationDate: nil)
        }
        for pattern in resource.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern, expirationDate: nil)
        }
        self.context = context
        generation += 1
        readyViews.removeAllObjects()
        try controller.load(context)
        try await context.loadBackgroundContent()
        startRulesRefresh(context)
    }

    /// Upstream uBOL's Safari adapter re-enables the rulesets once per realm after startup (WebKit bug 300236).
    /// One refresh per load also proves the compiled native rule list exists before a page waits on it.
    private func startRulesRefresh(_ context: WKWebExtensionContext) {
        let currentGeneration = generation
        refreshTask = Task { @MainActor in
            do {
                let page: UBlockLiteBridgePage
                if let existing = bridgePage {
                    page = existing
                } else {
                    page = try UBlockLiteBridgePage(context: context)
                    bridgePage = page
                    #if DEBUG
                    bridgePageCreationCount += 1
                    #endif
                }
                let enabled = try await page.refreshRules()
                guard generation == currentGeneration else { throw CancellationError() }
                #if DEBUG
                rulesRefreshCount += 1
                #endif
                if !isPrivate {
                    owner?.markCompiledRulesCurrent()
                    owner?.recordEnabledRulesetCount(enabled.count)
                }
                return enabled
            } catch {
                if generation == currentGeneration, !(error is CancellationError) { owner?.runtimeFailed(error) }
                throw error
            }
        }
    }

    /// Waits for this load's ruleset refresh and returns the enabled ruleset identifiers.
    func awaitRulesRefresh() async throws -> [String] {
        guard let refreshTask else { throw NSError(domain: "VortexLite", code: 6, userInfo: [NSLocalizedDescriptionKey: "The extension is not loaded."]) }
        return try await refreshTask.value
    }

    func unload() throws {
        guard let context, context.isLoaded else { return }
        generation += 1
        readyViews.removeAllObjects()
        refreshTask?.cancel()
        refreshTask = nil
        bridgePage = nil
        try controller.unload(context)
    }

    /// Drops an unloaded context so the next load binds to a new `WKWebExtension` (after a package update).
    func discardContext() {
        guard context?.isLoaded != true else { return }
        context = nil
    }

    func preparePage(_ webView: WKWebView) async throws {
        guard let context, context.isLoaded, !readyViews.contains(webView) else { return }
        let currentGeneration = generation
        // The nonpersistent private runtime compiles on every load; the regular runtime only needs the
        // refresh awaited until its compiled list is known to exist for this package, build and OS.
        if let refreshTask, isPrivate || owner?.compiledRulesAreCurrent != true {
            try await refreshTask.value
        }
        guard generation == currentGeneration else { return }
        await Self.awaitRuleListAttachment()
        guard generation == currentGeneration, context.isLoaded else { return }
        readyViews.add(webView)
    }

    /// WebKit attaches a loaded context's compiled rule list to a new web view's user content controller
    /// asynchronously: creating the view enqueues a lookup on the shared ContentRuleListStore work queue
    /// (WebExtensionContext::addDeclarativeNetRequestRules), and the attach happens in that lookup's
    /// main-thread completion. The queue is serial and completions are delivered in order, so a lookup
    /// enqueued after view creation completes only once the view's rules are attached. The identifier
    /// never exists; the lookup failure is the expected signal.
    static func awaitRuleListAttachment() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: "vortex.ubol.readiness-barrier") { _, _ in
                continuation.resume()
            }
        }
    }

    func attach(_ model: BrowserViewModel) {
        for window in windows where window.model == nil { controller.didCloseWindow(window) }
        windows.removeAll { $0.model == nil }
        guard !windows.contains(where: { $0.model === model }) else { return }
        let window = UBlockLiteWindow(model: model, runtime: self)
        windows.append(window)
        focusedWindow = window
        controller.didOpenWindow(window)
        window.startObserving()
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        windows.filter { $0.model != nil }
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        focusedWindow ?? windows.first
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        owner?.showSettings(isPrivate: isPrivate)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView = action.popupWebView else {
            completionHandler(owner?.failure("The extension popup is unavailable.")); return
        }
        owner?.present(title: isPrivate ? "uBlock Lite · Private" : "uBlock Origin Lite", webView: webView, action: action)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        guard let url = configuration.url, let window = focusedWindow ?? windows.first,
              let model = window.model else {
            completionHandler(nil, owner?.failure("No browser window is available.")); return
        }
        if url.scheme == context.baseURL.scheme {
            guard let webConfiguration = context.webViewConfiguration else {
                completionHandler(nil, owner?.failure("Extension is not loaded.")); return
            }
            let webView = WKWebView(frame: .zero, configuration: webConfiguration)
            webView.load(URLRequest(url: url))
            owner?.present(title: "uBlock Origin Lite", webView: webView)
            completionHandler(nil, nil)
            return
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            completionHandler(nil, owner?.failure("Only web links can be opened.")); return
        }
        let tab = BrowserTab(title: url.host ?? "New Tab", url: url, isIncognito: isPrivate)
        model.tabs.append(tab)
        window.reconcile(model.tabs)
        if configuration.shouldBeActive { model.selectTab(tab) }
        model.navigate(to: url, in: tab)
        completionHandler(window.tabBridges[tab.id], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        completionHandler(permissions.intersection(context.webExtension.requestedPermissions), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        completionHandler(patterns.filter { $0.string == "<all_urls>" || $0.string.hasPrefix("http://") || $0.string.hasPrefix("https://") }, nil)
    }
}

@MainActor
final class UBlockLiteWindow: NSObject, WKWebExtensionWindow {
    weak var model: BrowserViewModel?
    unowned let runtime: UBlockLiteRuntime
    var tabBridges: [UUID: UBlockLiteTab] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private weak var previousActive: UBlockLiteTab?

    init(model: BrowserViewModel, runtime: UBlockLiteRuntime) {
        self.model = model
        self.runtime = runtime
    }

    func startObserving() {
        guard let model else { return }
        reconcile(model.tabs)
        model.$tabs.sink { [weak self] tabs in
            self?.reconcile(tabs)
        }.store(in: &subscriptions)
        model.$selectedTabID.sink { [weak self] id in
            guard let self, let id, let tab = tabBridges[id] else { return }
            runtime.focusedWindow = self
            runtime.controller.didFocusWindow(self)
            runtime.controller.didActivateTab(tab, previousActiveTab: previousActive)
            previousActive = tab
        }.store(in: &subscriptions)
    }

    func reconcile(_ tabs: [BrowserTab]) {
        let eligible = tabs.filter { $0.isIncognito == runtime.isPrivate }
        let ids = Set(eligible.map(\.id))
        for (id, bridge) in tabBridges where !ids.contains(id) {
            runtime.controller.didCloseTab(bridge)
            tabBridges.removeValue(forKey: id)
        }
        for (index, tab) in eligible.enumerated() {
            if let bridge = tabBridges[tab.id] {
                if bridge.position != index {
                    let oldIndex = bridge.position
                    bridge.position = index
                    runtime.controller.didMoveTab(bridge, from: oldIndex, in: self)
                }
                continue
            }
            let bridge = UBlockLiteTab(tab: tab, window: self, position: index)
            tabBridges[tab.id] = bridge
            runtime.controller.didOpenTab(bridge)
        }
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabBridges.values.sorted { $0.position < $1.position } }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let id = model?.selectedTabID else { return nil }
        return tabBridges[id]
    }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { runtime.isPrivate }
}

@MainActor
final class UBlockLiteTab: NSObject, WKWebExtensionTab {
    weak var tab: BrowserTab?
    weak var hostWindow: UBlockLiteWindow?
    var position: Int
    private var subscriptions: Set<AnyCancellable> = []

    init(tab: BrowserTab, window: UBlockLiteWindow, position: Int) {
        self.tab = tab
        self.hostWindow = window
        self.position = position
        super.init()
        tab.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let window = self.hostWindow else { return }
                window.runtime.controller.didChangeTabProperties([.URL, .title, .loading], for: self)
            }
        }.store(in: &subscriptions)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { hostWindow }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { position }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.liveWebView }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.currentURL }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.liveWebView?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab?.id == hostWindow?.model?.selectedTabID }
    func size(for context: WKWebExtensionContext) -> CGSize { tab?.liveWebView?.bounds.size ?? .zero }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let tab { hostWindow?.model?.selectTab(tab) }
        completionHandler(nil)
    }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let tab else {
            completionHandler(NSError(domain: "VortexLite", code: 2)); return
        }
        hostWindow?.model?.navigate(to: url, in: tab)
        completionHandler(nil)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if fromOrigin { tab?.liveWebView?.reloadFromOrigin() } else { tab?.liveWebView?.reload() }
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let tab { hostWindow?.model?.closeTab(tab) }
        completionHandler(nil)
    }
}

/// Uses an empty page from the unmodified extension package to call its public APIs.
/// Safari's own uBOL adapter refreshes enabled rulesets once per realm after startup.
/// One bridge page is reused while the context is loaded and refreshes the rulesets once per load.
@MainActor
final class UBlockLiteBridgePage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let url: URL
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var hasLoaded = false

    init(context: WKWebExtensionContext) throws {
        guard let configuration = context.webViewConfiguration else {
            throw NSError(domain: "VortexLite", code: 4, userInfo: [NSLocalizedDescriptionKey: "Extension context is not loaded."])
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        url = context.baseURL.appendingPathComponent("web_accessible_resources/noop.html")
        super.init()
        webView.navigationDelegate = self
    }

    /// Re-enables the enabled rulesets and returns their identifiers.
    func refreshRules() async throws -> [String] {
        if !hasLoaded {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                webView.load(URLRequest(url: url))
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.finish(NSError(domain: "VortexLite", code: 5, userInfo: [NSLocalizedDescriptionKey: "Extension page loading timed out."]))
                }
            }
            hasLoaded = true
        }
        try Task.checkCancellation()
        let result = try await webView.callAsyncJavaScript("""
        return await Promise.race([
            (async () => {
                await browser.runtime.sendMessage({what: 'getDefaultFilteringMode'});
                const ids = await browser.declarativeNetRequest.getEnabledRulesets();
                if (ids.length === 0) return ids; // Respect an intentionally empty list selection.
                await browser.declarativeNetRequest.updateEnabledRulesets({disableRulesetIds: ids, enableRulesetIds: ids});
                return ids;
            })(),
            new Promise((_, reject) => setTimeout(() => reject(new Error('Filter initialization timed out.')), 60000))
        ]);
        """, contentWorld: .page)
        try Task.checkCancellation()
        return result as? [String] ?? []
    }
    private func finish(_ error: Error? = nil) {
        timeout?.cancel(); timeout = nil
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
}
