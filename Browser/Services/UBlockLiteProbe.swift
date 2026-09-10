#if DEBUG
import SwiftUI
import Combine
import WebKit

/// Opt-in development probe. Never runs during ordinary browsing.
struct UBlockLiteProbeView: View {
    @StateObject private var probe = UBlockLiteProbe()
    var body: some View {
        VStack {
            ScrollView { Text(probe.status).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if let webView = probe.page { ProbeWebView(webView: webView).id(ObjectIdentifier(webView)).frame(height: 180) }
        }.padding().task { await probe.run() }
    }
}
private struct ProbeWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class UBlockLiteProbe: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var status = "Running uBlock Origin Lite probe…"
    /// Fixture server host; pass `--ubol-fixture-host=<lan-ip>` to reach the Mac from a physical device.
    static let fixtureHost = ProcessInfo.processInfo.arguments.lazy.compactMap { $0.hasPrefix("--ubol-fixture-host=") ? String($0.dropFirst("--ubol-fixture-host=".count)) : nil }.first ?? "127.0.0.1"
    @Published var page: WKWebView?
    private var navigation: CheckedContinuation<Void, Error>?
    private var pendingNavigation: WKNavigation?
    private var report: [String: Any] = [:]
    private var model: BrowserViewModel?
    private var started = false

    private func record(_ name: String, _ value: Any) {
        report[name] = value
        status += "\n\(name): \(value)"
        print("UBOL_PROBE \(name): \(value)")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--ubol-audit-sites") ? "ubol-site-audit.json" : "ubol-probe.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
    }

    func run() async {
        guard !started else { return }; started = true
        do {
            let service = UBlockLiteService.shared
            await service.prepare()
            record("prepareMs", (service.prepareDuration ?? 0) * 1000)
            record("privateRuntimeDeferredAtStartup", service.privateRuntime.context?.isLoaded != true)
            record("compiledRulesCachedAtStartup", service.compiledRulesAreCurrent)
            if service.engine != .ublockLite { service.select(.ublockLite); try await waitForEngine(.ublockLite) }
            guard service.engine == .ublockLite, let regular = service.regular.context else {
                throw NSError(domain: "Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: service.errorMessage ?? "Lite not active"])
            }
            if ProcessInfo.processInfo.arguments.contains("--ubol-dnr-audit") {
                try await auditDomainConditions(service: service, context: regular)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--ubol-script-audit") {
                try await auditScriptUpdates(service: service, context: regular)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--ubol-audit-sites") {
                try await auditSites(service: service, context: regular)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--ubol-rules-update-audit") {
                try await auditRulesUpdate(service: service)
                return
            }
            record("loaded", true)
            record("version", service.version)
            record("builtinDisabled", !AdBlockService.shared.isEnabled)
            let standardDashboard = try await dashboard(regular)
            let enabled = try await standardDashboard.callAsyncJavaScript("return await browser.declarativeNetRequest.getEnabledRulesets();", contentWorld: .page)
            record("enabledRulesets", enabled ?? [])
            _ = try await standardDashboard.callAsyncJavaScript("await browser.storage.local.set({vortexIsolationProbe: 'regular-only'});", contentWorld: .page)
            record("contextErrors", regular.errors.map(\.localizedDescription))
            let defaults = UserDefaults(suiteName: "VortexLiteProbe")!
            let model = BrowserViewModel(userDefaults: defaults)
            self.model = model
            service.attach(model)
            let tab = BrowserTab(title: "uBOL Probe", url: nil)
            let webView = tab.activateWebView()
            model.tabs.append(tab)
            model.selectTab(tab)
            self.page = webView
            record("firstTabReadinessMs", await timedReadiness(webView))
            let blocked = try await fixture(webView, stage: "lite")
            record("liteAllowsControl", blocked.control)
            record("liteBlocksMatchingScript", !blocked.ad)
            let refreshCount = service.regular.rulesRefreshCount
            let bridgeCount = service.regular.bridgePageCreationCount
            let extraTab = BrowserTab(title: "Second tab probe", url: nil)
            model.tabs.append(extraTab)
            let extraView = extraTab.activateWebView()
            self.page = extraView
            record("newTabReadinessMs", await timedReadiness(extraView))
            let second = try await fixture(extraView, stage: "second-tab")
            record("newTabBlocksWithoutRulesetRefresh", !second.ad && second.control && service.regular.rulesRefreshCount == refreshCount && service.regular.bridgePageCreationCount == bridgeCount)
            record("loadingSurfaceIsNonOpaque", !extraView.isOpaque)
            self.page = webView
            service.select(.off)
            try await waitForEngine(.off)
            let off = try await fixture(webView, stage: "off")
            record("offAllowsMatchingScript", off.ad && off.control)
            service.select(.vortex)
            try await waitForEngine(.vortex)
            record("vortexAlternativeActive", AdBlockService.shared.isEnabled && service.regular.context?.isLoaded == false && service.privateRuntime.context?.isLoaded == false)
            service.select(.ublockLite)
            try await waitForEngine(.ublockLite)
            let again = try await fixture(webView, stage: "reenabled")
            record("reenableBlocksMatchingScript", !again.ad && again.control)
            // Verify a recreated BrowserTab web view receives protection too.
            let hibernated = await tab.hibernate()
            let restored = tab.activateWebView()
            self.page = restored
            record("restoredTabReadinessMs", await timedReadiness(restored))
            let restoredResult = try await fixture(restored, stage: "restored")
            record("restoredTabBlocksMatchingScript", hibernated && !restoredResult.ad && restoredResult.control)
            record("regularRefreshCount", service.regular.rulesRefreshCount)
            record("bridgeRecreatedOnlyAfterEngineReload", service.regular.bridgePageCreationCount == bridgeCount + 1)
            let settings = try await dashboard(regular)
            _ = try await settings.callAsyncJavaScript("return await browser.runtime.sendMessage({what:'setFilteringMode',hostname:'127.0.0.1',level:3});", contentWorld: .page)
            _ = try await fixture(restored, stage: "complete")
            var cosmetic = false
            for _ in 0..<50 {
                cosmetic = (try await restored.evaluateJavaScript("getComputedStyle(document.getElementById('adElement')).display === 'none'") as? Bool) == true
                if cosmetic { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            record("completeModeHidesAdElement", cosmetic)
            if !cosmetic {
                let scripts = try await settings.callAsyncJavaScript("return (await browser.scripting.getRegisteredContentScripts()).map(s=>({id:s.id,matches:s.matches}));", contentWorld: .page)
                record("cosmeticDiagnostics", scripts ?? [])
            }
            _ = try await settings.callAsyncJavaScript("return await browser.runtime.sendMessage({what:'setFilteringMode',hostname:'127.0.0.1',level:0});", contentWorld: .page)
            let excepted = try await fixture(restored, stage: "site-paused")
            record("siteExceptionAllowsMatchingScript", excepted.ad && excepted.control)
            _ = try await settings.callAsyncJavaScript("return await browser.runtime.sendMessage({what:'setFilteringMode',hostname:'127.0.0.1',level:2});", contentWorld: .page)
            // Private views use their own controller and extension storage.
            let privateTab = BrowserTab(title: "Private Probe", url: nil, isIncognito: true)
            model.tabs.append(privateTab)
            model.selectTab(privateTab)
            let privateWebView = privateTab.activateWebView()
            self.page = privateWebView
            record("privateTabReadinessMs", await timedReadiness(privateWebView))
            let privateResult = try await fixture(privateWebView, stage: "private")
            record("privateBlocksMatchingScript", !privateResult.ad && privateResult.control)
            record("privateDataStoreNonPersistent", !privateWebView.configuration.websiteDataStore.isPersistent)
            guard let privateContext = service.privateRuntime.context, privateContext.isLoaded else { throw NSError(domain: "Probe", code: 4, userInfo: [NSLocalizedDescriptionKey: "Private runtime did not load on demand"]) }
            let privateDashboard = try await dashboard(privateContext)
            let separated = try await privateDashboard.callAsyncJavaScript("return (await browser.storage.local.get('vortexIsolationProbe')).vortexIsolationProbe === undefined;", contentWorld: .page)
            record("privateStorageIsolated", separated ?? false)
            record("liteStillSelected", service.engine == .ublockLite && !AdBlockService.shared.isEnabled)
            model.selectTab(tab)
            service.showPopup(for: restored)
            record("popupAvailable", service.regular.context?.action(for: service.regular.windows.first(where: { $0.model === model })?.tabBridges[tab.id])?.popupWebView != nil)
            let passed = ["builtinDisabled", "privateStorageIsolated", "liteAllowsControl", "liteBlocksMatchingScript", "offAllowsMatchingScript", "reenableBlocksMatchingScript", "privateBlocksMatchingScript", "privateDataStoreNonPersistent", "popupAvailable", "vortexAlternativeActive", "liteStillSelected", "restoredTabBlocksMatchingScript", "completeModeHidesAdElement", "siteExceptionAllowsMatchingScript", "newTabBlocksWithoutRulesetRefresh", "bridgeRecreatedOnlyAfterEngineReload", "loadingSurfaceIsNonOpaque", "privateRuntimeDeferredAtStartup"].allSatisfy { report[$0] as? Bool == true }
            record("passed", passed)
        } catch {
            record("error", error.localizedDescription)
            record("passed", false)
        }
    }

    /// Tests whether the system honors modern and legacy DNR domain restrictions.
    /// Temporary diagnostic rules are removed before and after this opt-in probe.
    private func auditDomainConditions(service: UBlockLiteService, context: WKWebExtensionContext) async throws {
        let settings = try await dashboard(context)
        _ = try await settings.callAsyncJavaScript("await browser.runtime.sendMessage({what:'setFilteringMode',hostname:'127.0.0.1',level:3}); await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:[2000000001]});", contentWorld: .page)
        let model = BrowserViewModel(userDefaults: UserDefaults(suiteName: "VortexLiteDNRAudit")!)
        self.model = model
        service.attach(model)
        let tab = BrowserTab(title: "DNR domain audit", url: nil)
        model.tabs.append(tab)
        model.selectTab(tab)
        let view = tab.activateWebView()
        self.page = view
        let baseline = try await fixture(view, stage: "domain-baseline")
        record("baseline", ["control": baseline.control, "ad": baseline.ad])
        do {
            for (key, hostname, expectedControl) in [
                ("initiatorDomains", "unrelated.invalid", true),
                ("initiatorDomains", "127.0.0.1", false),
                ("domains", "unrelated.invalid", true),
                ("domains", "127.0.0.1", false),
                ("excludedInitiatorDomains", "127.0.0.1", true),
                ("excludedDomains", "127.0.0.1", true)
            ] {
                let condition: [String: Any] = ["urlFilter": "|http://127.0.0.1:18764/control.js", "resourceTypes": ["script"], key: [hostname]]
                _ = try await settings.callAsyncJavaScript("await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:[2000000001],addRules:[{id:2000000001,priority:1000,action:{type:'block'},condition}]});", arguments: ["condition": condition], contentWorld: .page)
                let result = try await fixture(view, stage: key + hostname)
                record(key + "-" + hostname, ["control": result.control, "expectedControl": expectedControl, "passed": result.control == expectedControl])
            }
        } catch {
            _ = try? await settings.callAsyncJavaScript("await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:[2000000001]});", contentWorld: .page)
            throw error
        }
        _ = try await settings.callAsyncJavaScript("await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:[2000000001]});", contentWorld: .page)
        let restored = try await fixture(view, stage: "domain-restored")
        record("restored", ["control": restored.control, "ad": restored.ad])
        record("domainAuditComplete", true)
    }

    private func auditScriptUpdates(service: UBlockLiteService, context: WKWebExtensionContext) async throws {
        let model = BrowserViewModel(userDefaults: UserDefaults(suiteName: "VortexLiteScriptAudit")!)
        self.model = model
        service.attach(model)
        let tab = BrowserTab(title: "Script audit", url: nil)
        model.tabs.append(tab)
        model.selectTab(tab)
        let view = tab.activateWebView()
        self.page = view
        try await Task.sleep(for: .milliseconds(500))
        let controller = view.configuration.userContentController
        func snapshot() -> [String: Any] {
            let scripts = controller.userScripts
            let groups = Dictionary(grouping: scripts, by: { $0.source })
            return ["count": scripts.count, "uniqueSources": groups.count,
                    "duplicates": groups.filter { $0.value.count > 1 }.map { ["prefix": String($0.key.prefix(150)), "copies": $0.value.count] as [String: Any] }]
        }
        record("scripts-before", snapshot())
        ManagedUserScript.install(source: "void 0;", identifier: "script-audit", in: controller)
        record("scripts-after-one-update", snapshot())
        ManagedUserScript.install(source: "void 1;", identifier: "script-audit", in: controller)
        record("scripts-after-two-updates", snapshot())
        record("scriptAuditComplete", true)
    }

    private func auditSites(service: UBlockLiteService, context: WKWebExtensionContext) async throws {
        if ProcessInfo.processInfo.arguments.contains("--ubol-audit-clear-cache") {
            await WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast)
            record("networkCacheCleared", true)
        }
        let settings = try await dashboard(context)
        let model = BrowserViewModel(userDefaults: UserDefaults(suiteName: "VortexLiteSiteAudit")!)
        self.model = model
        service.attach(model)
        let tab = BrowserTab(title: "Site audit", url: nil)
        model.tabs.append(tab)
        model.selectTab(tab)
        let view = tab.activateWebView()
        self.page = view
        if ProcessInfo.processInfo.arguments.contains("--ubol-audit-no-app-scripts") {
            view.configuration.userContentController.removeAllUserScripts()
            record("appScriptsRemoved", true)
        }
        let sites = ProcessInfo.processInfo.arguments.contains("--ubol-audit-requests") ? ["https://adblock-tester.com/", "https://adblock-tester.com/"] : ["https://adblock.turtlecute.org/", "https://adblock-tester.com/"]
        record("version", service.version)
        let modes = ProcessInfo.processInfo.arguments.contains("--ubol-audit-quick") ? [("lite-complete", 3)] : [("lite-optimal", 2), ("lite-complete", 3), ("vortex", -1)]
        for (name, mode) in modes {
            if mode < 0 {
                service.select(.vortex)
                try await waitForEngine(.vortex)
                for _ in 0..<100 {
                    if AdBlockService.shared.isReady { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                record("vortexLists", AdBlockService.shared.filterLists.filter(\.isEnabled).map(\.name))
                record("vortexNativeStatus", AdBlockService.shared.nativeResourceStatus)
            } else {
                let diagnostics = try await settings.callAsyncJavaScript("""
                const mode = await browser.runtime.sendMessage({what:'setDefaultFilteringMode',level:level});
                for (const hostname of ['adblock.turtlecute.org','adblock-tester.com']) {
                    await browser.runtime.sendMessage({what:'setFilteringMode',hostname,level});
                }
                return {
                    mode,
                    permissions: await browser.permissions.getAll(),
                    rulesets: await browser.declarativeNetRequest.getEnabledRulesets(),
                    dynamicRules: (await browser.declarativeNetRequest.getDynamicRules()).length,
                    sessionRules: (await browser.declarativeNetRequest.getSessionRules()).length,
                    scripts: (await browser.scripting.getRegisteredContentScripts()).map(s=>({id:s.id,matches:s.matches,excludeMatches:s.excludeMatches})),
                    tabs: await browser.tabs.query({})
                };
                """, arguments: ["level": mode], contentWorld: .page)
                record(name + "-configuration", diagnostics ?? [:])
            }
            for (index, site) in sites.enumerated() {
                let key = name + "-" + String(index)
                let start = Date()
                await service.preparePage(view)
                record(key + "-readinessMs", Date().timeIntervalSince(start) * 1000)
                view.navigationDelegate = self
                pendingNavigation = view.load(URLRequest(url: URL(string: site)!, cachePolicy: .reloadIgnoringLocalCacheData))
                try await Task.sleep(for: .seconds(20))
                let snapshot = try await view.evaluateJavaScript("""
                ({url:location.href,readyState:document.readyState,title:document.title,
                  text:document.body.innerText.slice(0,18000),
                  scripts:[...document.scripts].map(s=>s.src).filter(Boolean),
                  resources:performance.getEntriesByType('resource').map(r=>({name:r.name,type:r.initiatorType,size:r.encodedBodySize,duration:r.duration})),
                  globals:{adsbygoogle:typeof window.adsbygoogle,gtag:typeof window.gtag,hj:typeof window.hj,Sentry:typeof window.Sentry,ym:typeof window.ym},
                  functionSources: {hj:String(window.hj),sentryInit:String(window.Sentry?.init),bugsnagStart:String(window.Bugsnag?.start),bugsnagKeys:Object.keys(window.Bugsnag||{})},
                  cosmeticStyles:[...document.querySelectorAll('style')].map(s=>({id:s.id,content:s.textContent.slice(0,500)}))})
                """)
                record(key, snapshot)
                record(key + "-contextErrors", context.errors.map(\.localizedDescription))
                if ProcessInfo.processInfo.arguments.contains("--ubol-audit-requests"), index == 1 {
                    if let bridge = service.regular.windows.first(where: { $0.model === model })?.tabBridges[tab.id] {
                        context.userGesturePerformed(in: bridge)
                    }
                    let rules = try await settings.callAsyncJavaScript("return {dynamic:await browser.declarativeNetRequest.getDynamicRules(), matched:await browser.declarativeNetRequest.getMatchedRules({tabId:(await browser.tabs.query({active:true}))[0].id}).catch(e=>({error:String(e)}))};", contentWorld: .page)
                    record("requestRules", rules ?? [:])
                    let requests = try await view.callAsyncJavaScript("""
                    return await Promise.all([
                     'https://adblock-tester.com/head.inject.8b1bdd48.js',
                     'https://static.hotjar.com/c/hotjar-1639117.js?sv=6',
                     'https://js.sentry-cdn.com/98eefed2636036c3bdb8377b11ff28fe.min.js',
                     'https://d2wy8f7a9ursnm.cloudfront.net/v4/bugsnag.min.js'
                    ].map(async url=>{ const controller=new AbortController(); const timer=setTimeout(()=>controller.abort(),8000); try {const r=await fetch(url,{cache:'no-store',mode:'no-cors',signal:controller.signal}); return {url,type:r.type,status:r.status};} catch(e){return {url,error:String(e)};}finally{clearTimeout(timer);} }));
                    """, contentWorld: .page)
                    record("requestOutcomes", requests ?? [])
                    let scriptTest = """
                    return await Promise.all([
                     'https://static.hotjar.com/c/hotjar-1639117.js?sv=6',
                     'https://js.sentry-cdn.com/98eefed2636036c3bdb8377b11ff28fe.min.js',
                     'https://d2wy8f7a9ursnm.cloudfront.net/v4/bugsnag.min.js'
                    ].map(url=>new Promise(resolve=>{const s=document.createElement('script'); const timer=setTimeout(()=>{s.remove();resolve({url,result:'timeout'})},8000);s.onload=()=>{clearTimeout(timer);resolve({url,result:'loaded'})};s.onerror=()=>{clearTimeout(timer);resolve({url,result:'error'})};s.src=url;s.async=true;document.head.append(s);})))
                    """
                    record("scriptOutcomesLite", try await view.callAsyncJavaScript(scriptTest, contentWorld:.page) ?? [])
                    if ProcessInfo.processInfo.arguments.contains("--ubol-audit-rule-isolation") {
                        let enabled = try await settings.callAsyncJavaScript("return await browser.declarativeNetRequest.getEnabledRulesets();", contentWorld:.page) as? [String] ?? []
                        for disabled in ["easylist", "ublock-filters", "adguard-mobile"] {
                            _ = try await settings.callAsyncJavaScript("await browser.declarativeNetRequest.updateEnabledRulesets({disableRulesetIds:all,enableRulesetIds:all.filter(x=>x!==disabled)});", arguments:["all":enabled,"disabled":disabled], contentWorld:.page)
                            record("without-" + disabled, try await view.callAsyncJavaScript(scriptTest, contentWorld:.page) ?? [])
                        }
                        _ = try await settings.callAsyncJavaScript("await browser.declarativeNetRequest.updateEnabledRulesets({enableRulesetIds:all});", arguments:["all":enabled], contentWorld:.page)
                        _ = try await settings.callAsyncJavaScript("await browser.declarativeNetRequest.updateEnabledRulesets({disableRulesetIds:['ublock-filters']});", contentWorld:.page)
                        for ruleID in [5154] {
                            for legacy in [false, true] {
                                let loadedRule = try await settings.callAsyncJavaScript("""
                                const rules=await (await fetch(browser.runtime.getURL('rulesets/main/ublock-filters.json'))).json();
                                const rule=rules.find(r=>r.id===ruleID);rule.id=2000000001;
                                if(legacy){delete rule.condition.excludedRequestDomains;}
                                await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:[2000000001],addRules:[rule]});
                                return rule;
                                """, arguments:["ruleID":ruleID,"legacy":legacy], contentWorld:.page)
                                record("isolated-rule-" + String(ruleID) + "-" + String(legacy), ["rule":loadedRule ?? [:],"scripts":try await view.callAsyncJavaScript(scriptTest,contentWorld:.page) ?? []])
                            }
                        }
                        _ = try await settings.callAsyncJavaScript("await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:[2000000001]});await browser.declarativeNetRequest.updateEnabledRulesets({enableRulesetIds:all});", arguments:["all":enabled], contentWorld:.page)
                        for priority in [10, 1000] {
                            _ = try await settings.callAsyncJavaScript("await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:[2000000001],addRules:[{id:2000000001,priority,action:{type:'block'},condition:{urlFilter:'||d2wy8f7a9ursnm.cloudfront.net/',resourceTypes:['script']}}]});", arguments:["priority":priority], contentWorld:.page)
                            record("explicit-script-priority-" + String(priority), try await view.callAsyncJavaScript(scriptTest, contentWorld:.page) ?? [])
                        }
                        _ = try await settings.callAsyncJavaScript("await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:[2000000001]});", contentWorld:.page)
                    }

                    _ = try await settings.callAsyncJavaScript("await browser.runtime.sendMessage({what:'setFilteringMode',hostname:'adblock-tester.com',level:0});", contentWorld:.page)
                    record("scriptOutcomesOff", try await view.callAsyncJavaScript(scriptTest, contentWorld:.page) ?? [])
                    _ = try await settings.callAsyncJavaScript("await browser.runtime.sendMessage({what:'setFilteringMode',hostname:'adblock-tester.com',level:3});", contentWorld:.page)

                    for (conditionKey, hostname) in [("initiatorDomains", "unrelated.invalid"), ("initiatorDomains", "adblock-tester.com"), ("domains", "unrelated.invalid"), ("domains", "adblock-tester.com")] {
                        let condition: [String: Any] = ["urlFilter": "|https://adblock-tester.com/head.inject.8b1bdd48.js", "resourceTypes": ["xmlhttprequest"], conditionKey: [hostname]]
                        _ = try await settings.callAsyncJavaScript("await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:[2000000001],addRules:[{id:2000000001,priority:1000,action:{type:'block'},condition}]});", arguments: ["condition":condition], contentWorld:.page)
                        let outcome = try await view.callAsyncJavaScript("try {const r=await fetch('https://adblock-tester.com/head.inject.8b1bdd48.js',{cache:'no-store'}); return {status:r.status,length:(await r.text()).length};}catch(e){return {error:String(e)};}", contentWorld:.page)
                        record("https-" + conditionKey + "-" + hostname, outcome ?? [:])
                    }
                    _ = try await settings.callAsyncJavaScript("await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:[2000000001]});", contentWorld:.page)
                }
            }
        }
        // Tab-open latency on this device: readiness of a fresh tab, a hibernated-and-restored tab, and a private tab.
        let refreshBefore = service.regular.rulesRefreshCount
        let extraTab = BrowserTab(title: "Second tab latency", url: nil)
        model.tabs.append(extraTab)
        let extraView = extraTab.activateWebView()
        self.page = extraView
        record("newTabReadinessMs", await timedReadiness(extraView))
        record("newTabRefreshedRulesets", service.regular.rulesRefreshCount != refreshBefore)
        _ = await tab.hibernate()
        let restored = tab.activateWebView()
        self.page = restored
        record("restoredTabReadinessMs", await timedReadiness(restored))
        let privateTab = BrowserTab(title: "Private latency", url: nil, isIncognito: true)
        model.tabs.append(privateTab)
        let privateView = privateTab.activateWebView()
        self.page = privateView
        record("privateTabReadinessMs", await timedReadiness(privateView))
        record("regularRefreshCount", service.regular.rulesRefreshCount)
        record("auditComplete", true)
    }

    /// Exercises the network-rules update pipeline against the release fixture named by `--ubol-releases-url`.
    /// The synthetic release adds a rule blocking adblock-tester.com's own `head.inject` script, so a
    /// successful apply is observable as that fetch failing. The package store is reset afterwards.
    private func auditRulesUpdate(service: UBlockLiteService) async throws {
        let updater = service.rulesUpdater
        record("loadsFromPackageStore", service.loadsFromPackageStore)
        record("rulesVersionBefore", service.rulesVersion)
        record("activeManifestVersion", (try? UBOLPackageStore.readManifest(at: service.packageStore.activeURL).version) ?? "unreadable")
        let model = BrowserViewModel(userDefaults: UserDefaults(suiteName: "VortexLiteRulesUpdate")!)
        self.model = model
        service.attach(model)
        let tab = BrowserTab(title: "Rules update audit", url: nil)
        model.tabs.append(tab)
        model.selectTab(tab)
        var view = tab.activateWebView()
        self.page = view
        func probeFetch(_ label: String) async throws {
            try await load(view, url: URL(string: "https://adblock-tester.com/")!)
            let outcome = try await view.callAsyncJavaScript("try { const r = await fetch('https://adblock-tester.com/head.inject.8b1bdd48.js', {cache: 'no-store'}); return {status: r.status}; } catch (e) { return {error: String(e)}; }", contentWorld: .page)
            record(label, outcome ?? [:])
        }
        try await probeFetch("headInjectBeforeUpdate")
        await updater.check()
        record("checkStatus", updater.statusMessage ?? "")
        record("availableRelease", updater.availableRelease?.tag ?? "none")
        guard updater.availableRelease != nil else { record("rulesUpdateAuditComplete", false); return }
        await updater.downloadAndStage()
        record("downloadStatus", updater.statusMessage ?? "")
        record("pendingRulesVersion", service.packageStore.loadState()?.pendingRulesVersion ?? "none")
        let start = Date()
        await service.applyRulesUpdate()
        record("applyMs", Date().timeIntervalSince(start) * 1000)
        record("applyStatus", updater.statusMessage ?? "")
        record("rulesVersionAfter", service.rulesVersion)
        record("engineAfterApply", service.engine.rawValue)
        record("contextErrorsAfterApply", service.regular.context?.errors.map(\.localizedDescription) ?? [])
        record("rejectedReleases", service.packageStore.loadState()?.rejectedReleases ?? [])
        view = tab.activateWebView()
        try await probeFetch("headInjectAfterUpdate")
        if let context = service.regular.context, context.isLoaded {
            let settings = try await dashboard(context)
            record("enabledRulesetsAfterApply", try await settings.callAsyncJavaScript("return await browser.declarativeNetRequest.getEnabledRulesets();", contentWorld: .page) ?? [])
        }
        // Leave the device on the bundled rules: remove the store so the next launch re-extracts the package.
        try? FileManager.default.removeItem(at: service.packageStore.root)
        record("storeResetForNextLaunch", !FileManager.default.fileExists(atPath: service.packageStore.root.path))
        record("rulesUpdateAuditComplete", true)
    }

    /// Time the navigation gate for a freshly created view, exactly as the browser's policy delegate awaits it.
    private func timedReadiness(_ view: WKWebView) async -> Double {
        let start = Date()
        await UBlockLiteService.shared.preparePage(view)
        return Date().timeIntervalSince(start) * 1000
    }

    private func waitForEngine(_ engine: UBlockLiteService.Engine) async throws {
        for _ in 0..<300 {
            if UBlockLiteService.shared.engine == engine && !UBlockLiteService.shared.isChanging { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "Probe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Engine change timed out"])
    }

    private func dashboard(_ context: WKWebExtensionContext) async throws -> WKWebView {
        guard let configuration = context.webViewConfiguration, let url = context.optionsPageURL else { throw NSError(domain: "Probe", code: 2) }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        try await load(view, url: url)
        return view
    }

    private func fixture(_ view: WKWebView, stage: String) async throws -> (control: Bool, ad: Bool) {
        try await load(view, url: URL(string: "http://127.0.0.1:18764/?stage=\(stage)")!)
        try await Task.sleep(for: .milliseconds(500))
        let value = try await view.evaluateJavaScript("({control: window.controlLoaded === true, ad: window.adLoaded === true})") as? [String: Bool] ?? [:]
        return (value["control"] == true, value["ad"] == true)
    }

    private func load(_ view: WKWebView, url: URL) async throws {
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            pendingNavigation = view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true, navigationAction.request.url?.scheme == "http" {
            Task { await UBlockLiteService.shared.preparePage(webView); decisionHandler(.allow) }
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === pendingNavigation else { return }
        self.navigation?.resume(); self.navigation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === pendingNavigation else { return }
        self.navigation?.resume(throwing: error); self.navigation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === pendingNavigation else { return }
        self.navigation?.resume(throwing: error); self.navigation = nil
    }
}
#endif
