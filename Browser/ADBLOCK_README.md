# Ad blocking in Vortex

`AdBlockService` combines downloaded filter lists, user rules, WebKit content rules, and a JavaScript runtime.

## Platform behavior

- On iOS 26, Vortex compiles enabled network filters into `WKContentRuleList` objects and also runs the JavaScript blocker.
- On iOS 27, the legacy native converter remains disabled. A separate bounded native resource layer is enabled only on the isolated-probe-verified OS build `24A5430a` / SDK `24A5380g` pair. Other builds retain the JavaScript network and cosmetic fallback.
- A global switch and per-site exception control both reconcile existing WebViews. Disabling protection removes native lists, restores elements hidden by Vortex, and makes the installed JavaScript hooks pass requests through.

## Filter sources

The default configuration includes EasyList, with EasyPrivacy and Fanboy's Annoyance available as optional lists. Users can add filter-list URLs and custom URL regular expressions. Downloaded rules are cached under the app's caches directory with count and file-size limits.

Supported list syntax is intentionally bounded:

- an indexed JavaScript network subset: domain/URL patterns, request and document exceptions, resource types, party restrictions, document-domain scopes, and case-sensitive patterns;
- generic `##` cosmetic selectors;
- unsupported network modifiers, raw regular-expression filters, cosmetic exceptions and procedural cosmetic rules are skipped. The older iOS 26 native converter is unchanged.

This is not a complete implementation of the Adblock Plus grammar.

## Bounded iOS 27 native resources

`NativeAdResourceRules` uses up to 20,000 third-party domain slots and 2,000 compatible pattern rules. Its limits are separate from the 100,000-domain JavaScript budget. Common built-in destinations get priority only if already present in the active index; remaining domain slots are sampled deterministically across it. Host patterns precede generic patterns within their shared budget, so native coverage is intentionally incomplete.

On iOS 27, `SupplementalAdResourceRules` adds 12 explicitly selected cross-site endpoints for Google/YouTube, Amazon, Facebook, Reddit, Pinterest and Twitter/X. Both native and JavaScript layers use the same host/own-service definitions. These rules include advertiser tools as well as ad/analytics addresses; they do not imply every request to those hosts is tracking. They apply on arbitrary source websites, not only known testers, and have no wildcards for entire Google, Facebook, Reddit or AWS services. Own-service requests, document navigation, existing downloaded exceptions and global/per-site disabling remain permitted. The Reddit ad-hiding selectors and existing same-service compatibility policy are unchanged. iOS 26 receives no supplement.

The supplement reserves 12 of the existing native domain slots. The original sample is generated unchanged first, then up to 12 non-priority domains are displaced from native rules only; they remain in the JavaScript index. This avoids reshuffling the entire sample or raising the 22,000 block-rule ceiling. JavaScript configuration identity includes the supplement, and the full native content hash invalidates the prior compiled cache automatically.

Only main-frame script, image, stylesheet, font, media and raw resources are eligible. Native rules do not block document navigations or child-frame resources. This keeps frame-local document exceptions and Reddit/X compatibility consistent with the existing JavaScript behavior. Explicit first-party patterns can apply; ordinary domain rules retain third-party-only safety. Browser-created matching scripts can be stopped before their requests, without adding a JavaScript scan for every resource.

The converter avoids unsupported WebKit regex disjunctions, uses strict authority boundaries for domain blocks, skips document-domain-scoped blocks, and appends exceptions after blocks. Request exceptions retain their URL patterns, request types, case sensitivity and source-site conditions. First-party exceptions with a known destination host use the existing JavaScript same-site policy, so subdomain requests remain compatible. Essential and same-service social allowances are retained.

Interior ABP separators followed by required text are translated without an impossible end-of-string branch. Unsupported hosted exception patterns retain a conservative host fallback, but keep the exception's other conditions; unsupported hostless exceptions fail the whole native batch rather than silently losing an allowance. Hostless first-party exceptions conservatively permit both parties because their source site cannot be derived. Exceptions requiring combined include/exclude URL conditions, document exceptions with additional source scopes, an oversized payload or compilation failure also fall back to JavaScript-only protection. The tested WebKit build rejects multiple source-URL conditions in one trigger. Native domain blocks still conservatively skip URLs with userinfo. These limits are not a complete ABP implementation.

Compilation is serialized, keyed by content identity and cached under a separate identifier. Only the current index generation can be attached. When a changed index is ready, the old native snapshot is detached before replacement compilation. Global and per-site switches still control attachment. Arbitrary custom URL regexes stay JavaScript-only on iOS 27. Settings reports native rule count/status separately; native blocks are not in the JavaScript session counter.

See `docs/ios27-native-adblock-validation-2026-09-05.md` and the isolated probe for evidence and limitations. A passing synthetic resource probe is not proof that every ad-block test URL is present in the enabled lists or included in this bounded subset. RAM and real-site latency require separate measurements.

The follow-up `docs/ios27-scoped-exceptions-validation-2026-09-05.md` records the correction of overly broad native exceptions and checks for actual analytics script URLs. It supersedes the initial native converter's whole-host exception policy without increasing any rule budget.

`docs/ios27-hardcoded-ad-resources-validation-2026-09-05.md` records the subsequent user-approved hardcoded supplement, full endpoint checks, and optional device HEAD-request validation. A host tester measures reachability, not whether ads are visible or tracking data was sent.

## Runtime lifecycle

Call `prepareAsync()` after the initial UI is responsive. Call `configureWebView(_:)` for every new normal or incognito WebView. The service weakly tracks those WebViews so global, per-site, filter-list, and custom-rule changes apply to live tabs.

The JavaScript runtime intercepts `fetch`, `XMLHttpRequest`, `WebSocket`, and `sendBeacon`, performs bounded DOM scans, and reports its blocked count through `adBlockHandler`. It cannot intercept every browser-loaded script, image, iframe, or service-worker request. Configuration data is JSON encoded before injection.

Simple third-party domains use a sorted text index with a shared 100,000-domain capacity, not 100,000 regular expressions. Host-scoped patterns (12,000), generic patterns (1,000), and exceptions (5,000) have separate budgets. Enabled lists share each budget round-robin. Request decisions and scoped regex caches are bounded. Supported exceptions are retained as a complete set; an exception/payload budget failure keeps the previous snapshot. Default first-party safety remains in place.

Versioned caches trigger a one-time download of previously truncated lists. Parsing and index construction run off the main actor. Failed downloads preserve cached rules; lists without a new cache keep the bounded legacy fallback during migration. Settings reports indexed counts, omitted/unsupported rules, and update errors. No website data is cleared for this migration.

Each web view retains one managed ad-block script. Configuration replacement preserves other features' user scripts and their order. Unchanged refreshes do not reload pages; startup preparation updates the current page without forcing a second navigation. Disabled protection skips selector/regex compilation, and unchanged rules are reused within the current document.

## Privacy boundary

Third-party cookie blocking is a separate service. It must not be implemented by globally pruning the shared cookie store, because that can erase first-party login sessions for hibernated or closed tabs.

The cookie service retains iOS 26 support and also permits the verified iPadOS 27 build `24A5430a` / SDK `24A5380g` combination. Cookie and bounded ad-resource compatibility guards remain separate; neither revives the legacy full ad-block converter on iOS 27. Re-run `scripts/WebKitRegressionProbe` before extending either allowlist. WebKit's own privacy policy still applies; disabling Vortex's extra cookie rule does not override it. See [WebKit's content-blocker semantics](https://webkit.org/blog/3476/content-blockers-first-look/).
