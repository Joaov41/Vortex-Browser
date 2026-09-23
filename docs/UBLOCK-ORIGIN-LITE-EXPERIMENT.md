# Vortex Lite Lab

Independent experimental copy created on 2026-09-09 from:
`/Users/johnval/Downloads/browser use this one WITH FM CLI`

Working copy:
`/Users/johnval/Downloads/Vortex uBlock Origin Lite`

The complete directory was copied using APFS copy-on-write. These are independent file inodes, not hard links or a linked worktree. All 158 tracked/non-ignored source files matched before edits, including the original's uncommitted media changes. The baseline hashes are in `ubol-original-source-sha256.json`. No source changes were made in the original folder.

## Running

Open `Browser.xcodeproj` and use the Browser scheme. The display name remains **Vortex Lite Lab**. At the user's request on 2026-09-09, the duplicate now uses the main app's existing signing identity: bundle `com.web.me.Browser`, share extension `com.web.me.Browser.BrowserShare`, App Group `group.com.browser.app`, callback scheme `webmebrowser`, and notification `com.browser.sharedURL`. Installing this build updates the existing Vortex app on the selected device and uses its existing data container. The original source directory remains untouched. The earlier Simulator reports below used the separate `com.web.me.VortexLiteLab` identity. The two newly registered Lite Lab identifiers are unused; no original signing profile was modified.

In Settings, select **uBlock Origin Lite**, **Vortex**, or **Off**. Selecting Lite disables the existing Vortex ad blocker. Selecting Vortex unloads both Lite contexts. Existing pages reload when the engine changes. Original filter list settings remain available under Vortex. A Lite startup/readiness failure explicitly returns to Vortex and displays the error.

The page shield retains the cookie controls and provides a button for Lite's site controls. **uBlock Origin Lite Settings** opens the bundled extension's actual options page. Lite's default filtering mode is Optimal; Complete adds generic cosmetic filtering. Its own settings and site exceptions apply independently from the saved Vortex settings.

Private tabs use a separate nonpersistent extension controller, website data store, and extension storage. These private extension settings last for the app process lifetime and are not shared with the regular profile.

## Implementation

- `UBlockLiteService.swift`: extension loading, permissions for the pinned package, regular/private contexts, tab/window adapters, lifecycle events, options and popup routing, exclusive engine switching, and per-view rule readiness.
- `UBlockLiteViews.swift`: experimental startup, engine selector, and extension panel presentation.
- `BrowserSession.swift`: controller assignment before WKWebView creation and tab adapter rebinding on view recreation.
- `ContentView.swift`: startup and controls wiring, and a main-frame navigation gate.
- Existing `AdBlockService.swift` and its rule engines are unchanged.

The host registers the `safari-web-extension` scheme so the unmodified Safari package selects its Safari compatibility paths. It also waits for background initialization and a native enabled-ruleset refresh before the first main-frame navigation in each new WKWebView. This addresses the activation race exposed by the network probe, consistent with the refresh workaround in the upstream Safari adapter (`js/ext-compat.js`). Subsequent navigations in the same view use the already-ready state. Engine changes invalidate that state. The empty extension helper page is now retained and reused within each profile while the context is loaded, rather than recreated for each web view. Concurrent navigation requests share the same preparation task, with readiness published before waiters resume.

## Bundled upstream component

- Project: https://github.com/uBlockOrigin/uBOL-home
- Release: `2026.907.2003`
- Artifact: https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.907.2003/uBOLite_2026.907.2003.safari.zip
- Bundled as: `Browser/UBOLite.safari.zip`
- SHA-256: `851254d65c768cf23ba4fa27e51250344cee293d7e58b9387dbc62de6bc7c306`
- The official `UBOLite.safari.zip` archive is retained unmodified. It includes source JavaScript, its upstream README and GPL license. The host now loads the derived `UBOLite.webkit.zip` compatibility package described below; a copy of the license is beside this document.
- The package is pinned for repeatable testing. There is no automatic package updater in this prototype.

## Verification

The opt-in DEBUG launch argument `--ubol-probe` runs the integration checks and writes `Documents/ubol-probe.json` inside the experimental app's own data container. It never runs during ordinary browsing. Run `python3 scripts/ubol-fixture-server.py` on the simulator host first (loopback port 18764).

The fixture's `/ads/!rotator/` URL matches an existing shipped EasyList rule. No dummy rule is added to improve the result. The control script must run, while the matching script must be blocked; Off and Lite's own site exception must allow it. The probe also covers switching back to Vortex, re-enabling Lite, hibernating/recreating a tab, generic cosmetic hiding in Complete mode, private network blocking, separate private extension storage, and popup availability.

See the adjacent validation JSON reports for observed results. These tests establish integration behavior, not broad real-site parity with Firefox uBlock Origin. Device performance, battery use, physical-device behavior and multiwindow UI still require wider testing. Nothing has been uploaded to App Store Connect or TestFlight.

### Observed results (2026-09-09)

- Full Debug simulator build: passed (arm64 and x86_64).
- iOS 27.0 (`24A5355p`) full-app probe: all 14 behavioral assertions passed.
- iOS 26.5 (`23F73`) full-app probe: all 14 behavioral assertions passed.
- Original folder: all 158 source hashes unchanged. The existing blocker service and rule engines are also unchanged in the duplicate.
- Actual uBOL popup rendered and visually inspected; screenshot: `ubol-popup-ios27.png`.
- The final build also retains the per-site cookie controls and permits an intentionally empty enabled-list selection. These small follow-up changes passed compilation; the preceding behavioral reports exercise the same filtering paths with the default enabled lists.
- The iOS 26.5 run logged the existing Vortex native converter's unsupported-regex warning when selecting the Vortex alternative. Its JavaScript fallback remains available; that converter was deliberately left unchanged.
- Full-app network proof uses a controlled fixture; broad real-site comparisons and physical iPhone/iPad testing remain outstanding.

## M1 iPad installation (2026-09-09)

At the user's request, built the duplicate in Release using the main app's existing Apple Development signing certificate and Xcode-managed profiles. Bundle `com.web.me.Browser`, version 1.1 (21), display name Vortex Lite Lab. Signature verification passed, including the share extension; App Group and Private Cloud Compute entitlements were retained. Installed over Vortex on the M1 iPad Air (5th generation), preserving the existing app container. After the user unlocked it, foreground launch succeeded (PID 2082) and a screenshot confirmed the browser UI with existing tabs. Physical-site blocking quality remains for testing. All 158 original source files still match the baseline. Evidence: `ubol-m1-device-validation.json`, `ubol-device-build.json`, and `ubol-m1-installed.png`.

## Navigation follow-up (2026-09-09)

User reported a roughly one-second white loading screen and lower scores on Turtlecute and AdBlock Tester. The duplicate now reuses the extension helper page per profile, serializes rule readiness, skips the legacy blocker readiness wait while that blocker is disabled, and uses a nonopaque WKWebView with a themed host background. Per-view native rule installation is retained: experiments skipping it exposed unblocked requests in fresh web views. The regression probe adds fresh-tab blocking with a reused bridge, bridge lifetime across engine changes, and nonopaque loading-surface checks. No filter-list or filtering-mode defaults were changed, and no rules were added specifically to increase test scores.

The upstream FAQ says generic cosmetic filtering requires Complete mode: https://github.com/uBlockOrigin/uBOL-home/wiki/Frequently-asked-questions-(FAQ). Turtlecute documents decoy-script/cosmetic-list coverage and compatibility limits: https://adblock.turtlecute.org/. AdBlock Tester documents caching and scoring limits: https://adblock-tester.com/. These are possible contributors to differing scores; the exact score gap has not been independently reproduced.

Navigation follow-up validation: all 17 regression assertions passed on iOS 26.5 and iOS 27. The signed Release build was installed and launched on the M1 (PID 2145, version 1.1/build 21) using the same main-app identity. Original source hashes remain unchanged. These checks verify filtering behavior and the installed running artifact; the user-reported physical white-flash duration still needs a visual retest. Reports: `ubol-navigation-validation-ios27.json`, `ubol-navigation-validation-ios26-5.json`, and `ubol-navigation-m1-validation.json`.

## Integration audit after poor site scores (2026-09-09)

A confirmed host integration defect duplicated extension user scripts. WebKit's `removeAllUserScripts()` preserves web-extension scripts; Vortex's existing clear-and-readd helpers re-added that retained snapshot. In the native audit, a new view already contained 154 scripts (21 distinct sources), with extension sources repeated eight times. One managed-script update increased the count to 307 and repeated extension sources sixteen times. This is an integration defect, not evidence against the upstream filter lists.

The experimental copy now preserves the retained script objects and adds only scripts not already installed. The media monitor uses the same helper. After the fix, a fresh audit recorded 25 scripts / 25 distinct sources, then 26 / 26 after each of two managed updates, with no duplicate sources. These baseline totals also depend on filtering mode; the invariant is that repeated updates do not multiply scripts. Reports: `ubol-script-audit-before.json`, `ubol-script-audit-after.json`. Existing blocker engines and the original source folder remain unchanged (158 baseline hashes verified).

All 17 behavioral regression checks passed on iOS 26.5 after the fix. The Release build succeeded and its signature verified; installed on the M1 as Vortex Lite Lab 1.1 (21), bundle `com.web.me.Browser`, using the requested original signing. Initial launch attempt was blocked because the device was locked. Installation is verified; launch and physical-site behavior need separate verification.

Real-site probes on the dedicated iOS 27 simulator used the bundled extension's actual settings APIs. Required permissions were present, all four default lists enabled, 104 dynamic rules active, and Complete mode registered ten content-script entries. No extension context errors were reported. Before and after the duplication fix, Optimal scored 93/132 on Turtlecute and 77/100 on AdBlock Tester; Complete scored 95/132 and 83/100 respectively. Thus this fix does not explain or resolve the observed score gap. Reports: `ubol-site-audit-before.json`, `ubol-site-audit-after.json`.

The simulated Vortex alternative used only its default EasyList and reported its native path as unverified OS/SDK. It is not a valid comparison with the user's configured physical-device blocker. The debug site harness uses actual BrowserTab web views but its own navigation delegate, so it also does not establish full normal-browser UI parity. No standalone Safari comparison has been completed.

A focused Complete-mode audit captured tracker globals (`ubol-site-function-audit.json`); these are insufficient to prove network blocking or harmless substitution. In particular, a Sentry initialization function exists, and Hotjar has a queue function. A simplistic capitalized Bugsnag lookup is not authoritative for that library. The remaining failures must not be dismissed as compatibility stubs or attributed to upstream Lite without a matched-request or equivalent Safari comparison. The earlier conclusion that Lite itself was worse was premature.

The final iOS 27 regression also passed all 17 assertions after the duplication fix: `ubol-duplication-validation-ios27.json`.

After the user unlocked the M1, the already-installed update launched successfully (PID 2325). A separate process query confirmed that PID running from the newly installed app bundle. No rebuild or reinstall was needed. This verifies launch and process state, not the physical website scores. Evidence: `ubol-duplication-m1-launch.json` and `ubol-duplication-m1-running.json`.

## Confirmed script bypass and compatibility package (2026-09-09)

After the user confirmed unchanged results on the M1, request-level tests reproduced an actual problem in the iOS 27 Simulator: Hotjar, Sentry, and Bugsnag requests failed via fetch but loaded as script elements. Removing the app's injected scripts and clearing disk/memory caches did not change it. Disabling the uBlock filters ruleset made all three scripts block. Disabling EasyList or AdGuard Mobile did not. Ordinary modern and legacy domain conditions worked correctly on a normal HTTPS site; a separate local-port domain test failed because WebKit's generated frame-URL expression does not account for that port, so it was not used as evidence for this issue.

The isolated culprit is upstream uBlock filters rule 5154: block third-party scripts ending in `/8b3ytkn.js`, excluding destinations under `com`, `net`, and `org`. Reintroducing only this rule with uBlock filters disabled made all three unrelated tracker scripts load. Removing its `excludedRequestDomains` field made them block again. The other initially suspected exceptions (148 and 1382) did not reproduce the problem. Evidence: `ubol-excluded-domain-root-cause.json`, `ubol-rule-isolation-audit.json`.

WebKit's DNR converter generates `ignore-following-rules` entries for excluded request domains and replaces the original URL filter with the excluded domain. In this case that loses the filename restriction and suppresses other script-blocking rules for requests containing those broad domain strings. Primary source inspected: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/_WKWebExtensionDeclarativeNetRequestRule.mm (`ruleInWebKitFormat`, `createModifiedConditionsForURLFilter`). This is a WebKit compatibility defect that this integration must account for; the package's presence and basic fixture checks were insufficient validation.

The experimental host now loads `Browser/UBOLite.webkit.zip`, generated by `scripts/prepare-ubol-webkit.py`. The script verifies the pinned official archive SHA-256 and the exact offending rule, then omits only rule 5154. All other rules, JavaScript, manifest, settings and files remain byte-identical except serialization of that one ruleset. The verified rule array differs by exactly that one entry (6532 to 6531). The official archive is retained unchanged. `ubol-webkit-package-validation.json` records provenance and both hashes.

Tradeoff: the single filename-specific block is omitted rather than broadening it to domains deliberately excepted upstream. This is a temporary host compatibility workaround, not an upstream uBOL release or extra tester-specific blocking list. Re-audit the omission when the upstream package or WebKit changes; the generator refuses an unexpected archive or rule.

Turtlecute's detailed Complete-mode report recorded 95/132, with both cosmetic checks passing. Rule inspection accounts for six apparent host failures through built-in harmless replacement redirects, 29 host checks with no matching active default rule, and two unblocked local decoy scripts. This inspection models the tested HEAD/XHR requests and is not a general DNR conformance suite. Evidence: `ubol-turtle-detailed.json`, `ubol-turtle-rule-inspection.json`. Its score should not be confused with the independently reproduced tracker-script bypass.

Compatibility validation: iOS 27 Simulator AdBlock Tester rose from 83 to 96/100 with all four default lists still enabled. The actual Hotjar, Sentry and Bugsnag script loads now error under Complete mode, and load when the site is set to Off; Complete is restored afterwards. All 17 regression checks passed on iOS 26.5. Physical M1 and final iOS 27 regression results follow below when complete.

Final compatibility validation: all 17 regression checks passed on both iOS 26.5 and iOS 27. On the physical M1 iPad Air (iPad13,16, iPadOS 27 build 24A5430a), the signed diagnostic build scored 96/100 on AdBlock Tester and 95/132 on Turtlecute with Complete mode and all four default lists enabled. The report was copied from the actual app container: `ubol-compat-m1-site-validation.json`. This confirms the improved device result, not only simulator behavior. The normal Release build also built and passed deep signature verification; final install/launch evidence is recorded separately.

For the user's X/Reddit question, the pinned active EasyList/uBlock filters contain X promoted-post selectors and procedural removals, and Reddit `.promotedlink`, promoted tracking-context selectors, `shreddit-ad-post` and `shreddit-comments-page-ad`. Presence of these rules is verified. Logged-in feed effectiveness relative to the custom blocker is not yet visually verified and is not implied by the tester scores. The mobile UI connector could list the M1 but could not capture it because its on-device agent was not installed; no additional agent was installed.

The final Release app was installed and launched normally on the M1 (PID 2524), and a separate process query verified the new installed executable running. App identity and version were queried after installation. Evidence: `ubol-compat-m1-final-validation.json`. All 158 original source hashes remain unchanged; `git diff --check` passed.

## Tab-open latency and startup (2026-09-10)

User report: with Lite active, every tab (new or restored) took 2–3 s to open and the app showed a blank page area at start; the Vortex engine was unaffected. Reproduced on the M1 with the site audit's readiness timers (`ubol-tab-latency-baseline-m1.json`): new tab 2106 ms, restored tab 1892 ms, private tab 2176 ms, first tab after launch 6599 ms, and every fresh view performed a full ruleset refresh.

Root cause: the host re-enabled all enabled DNR rulesets for every new `WKWebView` before its first main-frame navigation. In WebKit, `updateEnabledRulesets` re-runs `loadDeclarativeNetRequestRules` (read ~12 MB of ruleset JSON from the package, translate every rule, hash, look up the compiled list), so the per-view guard cost seconds. The upstream Safari adapter (`js/ext-compat.js`, WebKit bug 300236) refreshes once per realm per session, not per view. WebKit commit 302465@main (2025-11-03, bug 301720) attaches a loaded context's compiled rule list to newly created user content controllers, but asynchronously via a lookup on the shared `ContentRuleListStore` work queue (`WebExtensionContext::addDeclarativeNetRequestRules`); the earlier "fresh view unblocked" observation was this race.

Changes (`UBlockLiteService.swift`, Vortex engine untouched):

- The rulesets are refreshed once per extension load, started right after the background content loads (matching upstream). The first regular page awaits that refresh only until a successful refresh has been recorded for the current package version, app build and OS build; afterwards WebKit's cached compiled list is known to exist and the wait is skipped.
- Each new view now waits on an ordering barrier instead: a lookup of a nonexistent identifier on `WKContentRuleListStore.default()`. That store is the same singleton and serial work queue WebKit uses to attach the extension's rules to the new view, and both completions are delivered on the main run loop in order, so the barrier completes only after the view's rules are attached. Public API only.
- The nonpersistent private runtime (which WebKit recompiles on every load) no longer loads at startup. It starts two seconds after the first regular page is ready, or immediately when a private page needs it; a private view created earlier waits for that load. Load failures still fail over to Vortex with the error shown.

M1 iPad Air (iPad13,16, iPadOS 27) Debug results with the same audit (`ubol-tab-latency-fix-cold-m1.json` first launch of the new build, `ubol-tab-latency-fix-warm-m1.json` second launch): new tab 239/214 ms, restored tab 3/3 ms, private tab 203/193 ms, first tab 2025 ms cold (awaiting the once-per-load refresh) and 156 ms warm, startup preparation 677/695 ms, private runtime deferred at startup, exactly one ruleset refresh per launch. AdBlock Tester remained 96 points in Complete mode before and after, and the Turtlecute page recorded the same 37 resource entries. The remaining ~200 ms on brand-new views is consistent with WebKit mapping and validating the compiled list on first use (the restored view, created seconds later, took 3 ms); this is an inference, not a measured breakdown.

### Matched engine comparison on the M1 (2026-09-10)

User report: Lite scores lower than the embedded Vortex blocker on ad-blocker test pages (about 51 versus 90 on AdBlock Tester). Ran the full site audit once on the M1 with all three engines in one session, same two pages, cache ignored on each load (`ubol-engine-comparison-m1.json`). Vortex ran with the user's configured lists (EasyList, EasyPrivacy) and reported `JavaScript only: unverified OS/SDK`, i.e. its native content-rule path is disabled on this iPadOS 27 build.

| Engine | AdBlock Tester | Turtlecute |
| --- | --- | --- |
| Lite Optimal | 91 | 93/132 |
| Lite Complete | 96 | 95/132 |
| Vortex (JS only) | 50 | 106/132 |

On AdBlock Tester the 50-point result belongs to Vortex: 24 ad/analytics resources loaded (Yandex Metrica and partner bundles, Google `pagead/ads`, Sentry, Bugsnag, banner images) because the JavaScript layer cannot stop script and image element loads at the network level. Lite let one resource through. On Turtlecute Vortex blocked 11 more hostnames than Lite. Of the 17 hosts Lite did not fail, `ads.tiktok.com` and `ads-api.twitter.com` are neutralized by uBOL redirect-to-`noop.txt` rules (ublock-filters 6265/6269), which the tester counts as loaded; the remaining hosts (metrika.yandex.ru, xiaomi mistat, byteoversea, udcm.yahoo.com, click.googleanalytics.com, grs.hicloud.com, appmetrica) are absent from both uBOL's default rulesets and the current upstream EasyPrivacy text, so Vortex blocks them through its own built-in host/heuristic layer, not through the shared lists. Lite in turn blocked 12 hosts Vortex missed (Unity Ads, OPPO, realme, iadsdk.apple.com, metrics.icloud.com). Neither engine dominates; the two testers measure different mechanisms.

## Network-rules updater (2026-09-10)

Decision (user): filter rule *data* may be updated from official uBOL releases, applied only on request; the extension's JavaScript, manifest and resources stay pinned; availability is checked once a day; WebKit compatibility is handled by policy rather than by a pinned rule id.

Implementation:

- `ZipArchive.swift`: minimal read-only ZIP reader (Stored and Deflate via the Compression framework, CRC-32 verified per entry). Extracting the official archive reproduces `unzip` byte-for-byte (1004 entries, 44 MB, 0.2 s on the Mac).
- `UBOLPackageStore.swift`: on first launch of each app build, extracts the bundled official `UBOLite.safari.zip` into `Application Support/UBOLite/active/`, applies the compatibility policy, and records provenance in `state.json`. WebKit loads the extension from that directory (`loadsFromPackageStore`); if the store cannot be prepared the host falls back to the bundled pre-filtered `UBOLite.webkit.zip`. Updates replace only `rulesets/main`, `rulesets/regex`, `rulesets/strictblock`, `rulesets/urlskip` and `rulesets/ruleset-details.json` for ruleset ids declared by the pinned manifest, after shape validation (array of rules, unique positive ids, known action types, non-empty conditions, no path traversal in redirects). `pending/` holds a verified update, `previous/` the replaced files for rollback; a release that fails to load is recorded as rejected and never retried.
- Compatibility policy: omit block rules that carry `excludedRequestDomains` but no `initiatorDomains`. Only such global-scope rules can suppress unrelated blocking the way upstream rule 5154 did; rules limited to initiator sites are kept. On the pinned release this omits ids 4286, 5154 and 5165 of `ublock-filters` (the earlier package omitted 5154 only) and touches no other default list. `scripts/test-ubol-package-store.mjs` holds this as a golden check with the validation and stage/apply/rollback round trip.
- `UBOLRulesUpdater.swift`: one request per day to `api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest` (ephemeral session, no cookies). A download happens only when the user taps: the `uBOLite_<tag>.safari.zip` asset must carry GitHub's `sha256:` digest and the file must match it before it is opened; archives over 40 MB are refused. Applying is the user's second tap: `UBlockLiteService.applyRulesUpdate()` unloads both runtimes, swaps the files, recreates the `WKWebExtension` from the directory, waits for the once-per-load ruleset refresh, requires an error-free context and the previously recorded number of enabled rulesets, then reloads open tabs; on failure it rolls back and reloads the previous rules, falling over to Vortex only if that also fails. The compiled-rules marker includes the rules version, so the first page after an update waits for WebKit's one-time recompile.
- Controls in the Lite settings: rules version, "Check for rule updates", "Download rules <tag>", "Apply rules <tag> now (reloads open tabs)", status and last-check time.

Validation on the M1 (`ubol-rules-update-audit-m1.json`, DEBUG probe `--ubol-rules-update-audit` against a synthetic release served from the Mac by `scripts/ubol-release-fixture.py`, which re-tags the official archive as 2026.999.0001 and adds one rule blocking adblock-tester.com's own `head.inject` script): the extension loaded from the package store with manifest 2026.907.2003; the check found the synthetic release; the download verified against its digest and staged with 8 WebKit-incompatible rules omitted; apply took 17.8 s (WebKit recompile) with no context errors, the nine enabled rulesets intact, and `rulesVersion` 2026.999.0001; the `head.inject` fetch changed from HTTP 200 before the update to `Load failed` after it, proving the new rule was live. The probe then removed the store so the device returned to bundled rules on the next launch. Against the real GitHub release the check reports the installed 2026.907.2003 as current (verified from the Mac; the device check runs on its daily schedule). The Release build was signed with the existing identity, verified, installed and launched: `ubol-rules-update-m1-release-install.json`, `ubol-rules-update-m1-release-launch.json`.

Limits: rollback after a WebKit load failure is covered by the offline round-trip test, not by a device run (no way to make WebKit reject validated rules on demand). A future uBOL release that changes its rule-data schema in a way the pinned JavaScript cannot consume would pass validation but could misbehave; the enabled-ruleset count check and the user-visible status are the only guards. Cosmetic and scriptlet filters remain at the bundled version until the app is rebuilt with a newer package. Storage use grows by roughly 45 MB for the extracted package plus the replaced rule files.

Limits of the latency fix: the fast path is used on every OS version per the user's decision; iOS 26.0–26.4 were not tested and predate or may predate the WebKit attach fix, so fresh views there are unverified. The 18-assertion fixture suite was not re-run for this change (the user declined simulator runs; the probe now accepts `--ubol-fixture-host=<lan-ip>` so it can run against a physical device later). The Release build was signed with the existing Apple Development identity, verified, installed and launched on the M1: `ubol-tab-latency-m1-release-install.json`, `ubol-tab-latency-m1-release-launch.json`. All 158 original source hashes remain unchanged; `git diff --check` passed.

## Update rollback and failover fixes (2026-09-23)

Review of the updater found that its failure paths could not work as written:

- Rollback reloaded the rejected rules: `UBlockLiteRuntime.load` returns early for a loaded context and otherwise reuses the context bound to the old `WKWebExtension`. `reloadRegularRuntime` now unloads and discards both contexts first (`unloadForPackageChange`).
- A second failure during an apply called `failOver`, whose `isChanging` guard made it a no-op, leaving no blocker active while reporting Vortex. Failover is now `activateVortexFallback`, which has no guard; `failOver` takes `isChanging` itself. Refresh failures carry their load generation, so a failure from a replaced load is ignored.
- `applyPending` is all or nothing: a failed move or state write undoes earlier moves and keeps the update pending.
- Package preparation, applying and rolling back, and download verification (hash, unzip, validation) run off the main actor. `UBOLPackageStore` and `ZipArchive` are `nonisolated` and `Sendable`.
- Compatibility policy version 3: redirect rules of the same global excluded-domain shape are omitted too, and the policy now covers `rulesets/regex` and `rulesets/strictblock` (loaded by uBOL as dynamic rules) in the bundled package as well as in updates. The bundled release omits 16 rules: main `ublock-filters` 4286, 5154, 5165; regex `ublock-filters` 8; strictblock `ublock-filters` 2 and `jpn-1` 3. Omission keys are prefixed by folder so regex/strictblock no longer overwrite the static ruleset's record. A policy version change re-prepares the active package and re-filters an accepted overlay.
- Update validation rejects redirects to an `extensionPath` the pinned package lacks.
- Engine selection sets the Vortex blocker without saving `adBlockEnabled`, which the main app shares under the same bundle identifier.
- Tab property changes are forwarded only when URL, title or loading state actually change.
- Settings label updates as network rules only; cosmetic filters and scriptlets stay at the bundled uBOL version.

Verification: `node scripts/test-ubol-package-store.mjs <tmp>` passes, including a forced partial-apply failure, policy re-prepare with an applied overlay, redirect omission and missing redirect targets. Debug simulator and Release device builds succeed. The in-app `--ubol-probe` and `--ubol-rules-update-audit` runs were not repeated: CoreSimulator on the Mac could not create a simulator (permission error in its log). They still need to run on a simulator or the M1.

## Extra blocklist: HaGeZi Pro (2026-09-24)

User decision: add HaGeZi's Multi PRO list alongside Lite, updated through a button, leaving hosts uBOL handles with harmless redirects to uBOL.

- `ExtraBlocklistService.swift`: the bundled `Browser/hagezi-pro.txt` (version 2026.0923.1517.16, 225,658 `||domain^` entries, license https://github.com/hagezi/dns-blocklists/blob/main/LICENSE) or a newer downloaded copy becomes WebKit content rule lists of at most 50,000 rules (WebKit refuses a list above 150,000). One block rule per domain covers the domain, its subdomains, any scheme and port.
- Hosts left to uBOL: domains named by global host-level `redirect`/`allow` rules in uBOL's default rulesets (ublock-filters, easylist, easyprivacy) are dropped with their subdomains (426 on the bundled versions, including doubleclick.net and pagead2.googlesyndication.com); such hosts under a blocked parent get an `ignore-previous-rules` exception. Every list also ends with an exception for top-frame documents, so a page the user opens is never blocked, only what it loads.
- Attachment: only while Lite is the engine and the switch is on. At each main-frame navigation (`UBlockLiteService.preparePage(_:url:)`) the lists are added or removed for that site; uBOL's "no filtering" sites are read from the extension (`getFilteringModeDetails`) through the bridge page and re-read after the popup or settings are shown.
- Compiled lists are cached by list version, uBOL rules version and rule format; a uBOL rules update regenerates them. Updates: a daily ranged request reads only the version header; "Download and apply" fetches, validates (HaGeZi title, version, at least 50,000 domains, at most 20 MB) and compiles before replacing the saved list, so failures keep the current lists.

Verification: `node scripts/test-extra-blocklist.mjs <tmp>` passes with the real list and uBOL rulesets: 225,232 blocked / 426 left to uBOL, the seven previously missed Microsoft/Yahoo/Amazon hosts blocked, Google/DoubleClick/Facebook and ordinary hosts left alone, top-frame pages allowed, and all five lists compile in macOS WebKit (3.1 s on an M4). On the M1 (Release, installed), the five lists compiled on first launch and the daily version check ran (state copied from the app container). Site-level results on the iPad still need to be checked.
