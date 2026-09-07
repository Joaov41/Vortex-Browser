# Bounded iOS 27 native ad-resource validation

## Scope and checkpoint

Requested: make a local checkpoint, then fix the missing iOS 27 pre-load ad-resource blocking while retaining the indexed JavaScript layer and limiting compatibility/resource risk.

- Checkout: `/Users/johnval/Downloads/browser use this one WITH FM CLI`.
- Before-change local commit: `80c2ad8`.
- Tag: `codex/checkpoint-before-ios27-resource-blocking-20260905`.
- Unrelated existing deletion `iPad Framed Transparent/11.png` was excluded and left untouched.
- No push, TestFlight upload, app-data export, AI/provider changes, hibernation changes or cookie-policy changes.
- iOS 26 retains its existing converter/path. No iOS 26 device validation was performed for this change.

## Evidence and implementation

The legacy native path was disabled after a historical WebCore rule-tree destruction crash. That old report is a reason to test cautiously, not proof that the current OS still crashes. On the current M1, the old generated rules instead failed compilation: WebKit rejected a regex disjunction (`(?:[/?#]|$)`) with WKErrorDomain code 6. This makes simply re-enabling the legacy converter inadequate; its exception handling is also not suitable for this new layer.

The new `NativeAdResourceRules` builder uses the active indexed payload, up to 20,000 domain and 2,000 pattern block rules, plus complete/broadened exceptions. Total output is capped at 30,000 rules and 8 MB JSON. Unknown OS/SDK combinations, unsupported exceptions and compilation failures fall back to JavaScript-only filtering. Only the verified OS build `24A5430a` / SDK `24A5380g` pair is enabled, independently of the cookie guard.

All native blocks are main-frame subresources only. Child frames remain JavaScript-only, because the index's frame-local exceptions cannot safely be substituted with top-page exceptions. Host authority patterns handle numeric ports without mistaking a username for the destination. Native domain blocks conservatively skip userinfo URLs, while exceptions recognize their actual destination. The builder does not block top-level documents or reactivate arbitrary native custom regex rules on iOS 27. Native compilation is cached/serialized and stale generations cannot attach after list changes.

The existing JavaScript index remains at 100,000 domains. Native domain selection prioritizes already-indexed built-in hosts then distributes remaining capacity across the index. Patterns have a separate shared cap, with host patterns before generic ones. This is intentionally incomplete coverage; no test-specific host blacklist was added.

## Reproducible checks

Public fixtures used in this run: `/private/tmp/vortex-indexed-adblock.UMw31X/easylist.txt` and `easyprivacy.txt`. They are downloaded public list snapshots, not the iPad's private cache. Production counts can differ with enabled lists and update dates.

```sh
node scripts/test-native-ad-resources.mjs /private/tmp/vortex-indexed-adblock.UMw31X
node scripts/make-native-adblock-fixture.mjs /private/tmp/vortex-indexed-adblock.UMw31X .codex-checkpoints/native-ad-rules.json
VORTEX_BASELINE_SOURCE=/private/tmp/vortex-indexed-adblock.UMw31X/AdBlockService.before.swift node scripts/test-webview-scripts.mjs
xcodegen generate --spec scripts/WebKitRegressionProbe/project.yml
asc xcode build --project scripts/WebKitRegressionProbe/VortexWebKitProbe.xcodeproj --scheme VortexWebKitProbe --configuration Release --destination 'generic/platform=iOS' --derived-data-path .codex-checkpoints/WebKitProbeDerived --xcodebuild-flag=-allowProvisioningUpdates --xcodebuild-flag=-quiet --output json
asc xcode build --project Browser.xcodeproj --scheme Browser --configuration Release --destination 'generic/platform=iOS' --derived-data-path .derived --xcodebuild-flag=-allowProvisioningUpdates --xcodebuild-flag=-quiet --output json
```

The fixture script accepts a final `legacy` argument for the legacy negative control. Device install/run commands and fixture design are documented in `scripts/WebKitRegressionProbe/README.md`; launch on an authorized device only.

## Results

- Pure native builder tests: PASS. Separate native budget, host/credential/port boundaries, complete document and destination exceptions, types/party scope, main-frame-only behavior, essential/social allowances, unsupported-exception fail-safe and exact OS/SDK guard.
- Existing macOS WebKit JavaScript regression suite: PASS. Indexed fetch/XHR/WebSocket/beacon behavior, exceptions at first inline script, managed script ownership, 50 refreshes, disabled/re-enabled behavior, CSS uniqueness and early dark rendering.
- Indexed parser/matcher suite: PASS with 100,000 synthetic domains and current public EasyList/EasyPrivacy fixtures. Existing JavaScript budgets and matching semantics remain covered.
- Independent read-only review: reported frame-exception and credential-boundary issues; both corrected and covered. Final bounded source review reported no remaining release-blocking issue.
- Final public-list fixture: 22,000 block rules, 81,729 omitted index entries/patterns, 5,664,830 JSON bytes before two probe-only rules. Omitted does not mean removed from the full JavaScript index.
- Bundled fixture SHA-256 verified against generated output: `46a9874cc4dab8bda43fbba2ae3dd94b50c06f6481589fc4531db5dddd66d173`.
- Final physical-device probe: PASS, exit 0 on M1 iPad Air 5, iPadOS 27.0 `24A5430a`, SDK `24A5380g`. Two compilations of 23,395 total rules (22,000 blocks, exceptions, two probe controls), 5,665,085 bytes. All eight static/dynamic/third-party script cycles preserved the exception, ordinary script and child-frame fallback; server request count matched exactly two permitted candidate requests. Removal restored scripts. Separate cookie tests and private/persistent lifecycles also passed. No crash observed in these tested cycles.
- Final signed Browser Release build: PASS using `.derived`, 33.883 seconds. `codesign --verify --deep --strict` passed with macOS trust-service access. Browser and BrowserShare are both version/build 1.1 (20), SDK `24A5380g`.
- Browser install: PASS on the authorized M1; device metadata confirms `com.web.me.Browser`, version 1.1 (20), installation `A209D190-EE65-457F-BCAA-4DD6F755DC53`.
- Browser launch: PASS; subsequent process inspection confirms PID 8647 running the executable from that exact new installation. No visual screen inspection or production-settings native count was captured. The probe is a separate app and does not itself prove production UI status or real-site coverage.

Handoff: let native preparation finish, check Ad Blocking statistics for `Active: pre-load resource blocking` and a nonzero native count, then reload the public tests. A subsequent OS or SDK update intentionally falls back to JavaScript-only until separately verified. The before-change checkpoint remains available; no remote publication was performed.

## Performance and coverage limits

The old converter cannot provide a meaningful performance baseline because compilation fails. Initial successful prototype compilations took about 0.74 seconds on the M1, before final frame/authority hardening, so this is not a comparable correctness-equivalent baseline. The fully hardened optional-userinfo version compiled in 7,773 and 7,733 ms; all eight correctness cycles passed. Restricting userinfo matching to allowances reduced serialized fixture size, but final compilations were 7,438 and 7,792 ms (mean 7,615 ms vs 7,753 ms). With only two samples and overlapping timing, there is no meaningful demonstrated speed improvement from that narrowing. The final version conservatively falls through to JavaScript for authenticated-domain blocks and keeps authenticated exceptions intact.

Further regex optimization was stopped rather than widening the patch. Native compilation remains asynchronous and cached by content identity, not performed for every click. Expect roughly eight seconds on the tested M1 when this full snapshot must compile; first-page resources before native preparation may still rely on JavaScript. No RAM, CPU, per-navigation latency or battery improvement claim is established by these tests. Real device profiling is still required to quantify steady-state cost.

The isolated app has its own bundle ID and serves synthetic local pages. It compiles the generated production-shaped list plus two explicit test-only block/allow rules. Request counters prove those synthetic scripts were prevented before loading; they do not prove the public lists match Turtlecute's same-origin dummy scripts. Test-site scores, missing Amazon/analytics hosts, ordinary-site logins, social sites and real-world memory/latency still require separate user/device testing. Native requests are not counted in the JavaScript session counter.

## References

- [Apple content-blocker schema](https://developer.apple.com/documentation/SafariServices/creating-a-content-blocker): resource types, top/child frame contexts and URL conditions.
- [WebKit content blockers](https://webkit.org/blog/3476/content-blockers-first-look/): native blocking and rule compilation semantics.
