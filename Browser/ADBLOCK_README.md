# Ad blocking in Vortex

`AdBlockService` combines downloaded filter lists, user rules, WebKit content rules, and a JavaScript runtime.

## Platform behavior

- On iOS 26, Vortex compiles enabled network filters into `WKContentRuleList` objects and also runs the JavaScript blocker.
- On iOS 27, the native rule-list path is intentionally disabled because it has caused WebKit startup/teardown crashes. Vortex downloads the same enabled lists and uses its JavaScript network and cosmetic fallback.
- A global switch and per-site exception control both reconcile existing WebViews. Disabling protection removes native lists, restores elements hidden by Vortex, and makes the installed JavaScript hooks pass requests through.

## Filter sources

The default configuration includes EasyList, with EasyPrivacy and Fanboy's Annoyance available as optional lists. Users can add filter-list URLs and custom URL regular expressions. Downloaded rules are cached under the app's caches directory with count and file-size limits.

Supported list syntax is intentionally bounded:

- an indexed JavaScript network subset: domain/URL patterns, request and document exceptions, resource types, party restrictions, document-domain scopes, and case-sensitive patterns;
- generic `##` cosmetic selectors;
- unsupported network modifiers, raw regular-expression filters, cosmetic exceptions and procedural cosmetic rules are skipped. The older iOS 26 native converter is unchanged.

This is not a complete implementation of the Adblock Plus grammar.

## Runtime lifecycle

Call `prepareAsync()` after the initial UI is responsive. Call `configureWebView(_:)` for every new normal or incognito WebView. The service weakly tracks those WebViews so global, per-site, filter-list, and custom-rule changes apply to live tabs.

The JavaScript runtime intercepts `fetch`, `XMLHttpRequest`, `WebSocket`, and `sendBeacon`, performs bounded DOM scans, and reports its blocked count through `adBlockHandler`. It cannot intercept every browser-loaded script, image, iframe, or service-worker request. Configuration data is JSON encoded before injection.

Simple third-party domains use a sorted text index with a shared 100,000-domain capacity, not 100,000 regular expressions. Host-scoped patterns (12,000), generic patterns (1,000), and exceptions (5,000) have separate budgets. Enabled lists share each budget round-robin. Request decisions and scoped regex caches are bounded. Supported exceptions are retained as a complete set; an exception/payload budget failure keeps the previous snapshot. Default first-party safety remains in place.

Versioned caches trigger a one-time download of previously truncated lists. Parsing and index construction run off the main actor. Failed downloads preserve cached rules; lists without a new cache keep the bounded legacy fallback during migration. Settings reports indexed counts, omitted/unsupported rules, and update errors. No website data is cleared for this migration.

Each web view retains one managed ad-block script. Configuration replacement preserves other features' user scripts and their order. Unchanged refreshes do not reload pages; startup preparation updates the current page without forcing a second navigation. Disabled protection skips selector/regex compilation, and unchanged rules are reused within the current document.

## Privacy boundary

Third-party cookie blocking is a separate service. It must not be implemented by globally pruning the shared cookie store, because that can erase first-party login sessions for hibernated or closed tabs.

The cookie service retains iOS 26 support and also permits the verified iPadOS 27 build `24A5430a` / SDK `24A5380g` combination. This does **not** enable iOS 27's separate full ad-block native rule lists. Re-run `scripts/WebKitRegressionProbe` before extending the cookie compatibility allowlist. WebKit's own privacy policy still applies; disabling Vortex's extra cookie rule does not override it. See [WebKit's content-blocker semantics](https://webkit.org/blog/3476/content-blockers-first-look/).
