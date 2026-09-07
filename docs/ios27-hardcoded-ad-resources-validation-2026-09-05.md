# iOS 27 hardcoded cross-site supplement, 2026-09-05

## Approval and rollback

The user approved fixing the remaining reported endpoint failures while leaving working Reddit ad hiding intact, and explicitly requested hardcoding the missing addresses. Work is confined to the ad-resource supplement, its integration, tests and documentation. No AI, hibernation, navigation, dark-mode implementation, cookie implementation, or iOS 26 blocking policy changes.

A pre-edit file backup is `.codex-checkpoints/pre-supplemental-ad-resources-20260905.tar.gz` (12 blocker/test/documentation files). This is a local file backup, not a new Git commit. The earlier Git checkpoint remains `80c2ad8`. Existing dirty changes and the unrelated screenshot deletion remain untouched; no remote push or publication.

## Exact added endpoints

- `ads.google.com`
- `analyticsengine.s3.amazonaws.com`
- `affiliationjs.s3.amazonaws.com`
- `advertising-api-eu.amazon.com`
- `ads.facebook.com`
- `ads.reddit.com`
- `d.reddit.com`
- `ads.pinterest.com`
- `ads-dev.pinterest.com`
- `ads.youtube.com`
- `ads-api.twitter.com`
- `advertising.twitter.com`

These are user-requested cross-site restrictions, not a claim that every listed endpoint exclusively serves tracking. Some are advertiser dashboards/APIs. Own-service families are explicitly retained in the shared policy; native document navigations are not blocked. Matching uses real destination-host boundaries, never substrings or test-site detection. Downloaded request/document exceptions retain priority. Existing global/per-site switches still disable protection. Reddit's cosmetic selectors and existing social-site allowances are unchanged.

`SupplementalAdResourceRules` supplies both layers from one definition and is JS-enabled only on major version 27. The native layer retains its exact OS/SDK guard. It reserves 12 existing domain slots after the old sampling step, removing at most 12 non-priority native domains without changing their JS coverage or reshuffling other selections. The native total stays 22,000 block rules. The JS configuration version includes the supplement and built-in domain data; the native cache remains keyed by full generated content.

## Validation

- Pure Swift/native builder and matching tests: PASS for all 12 cross-site blocks, own-service/source boundaries, first-party use, document navigation, unchanged frame policy, scoped exceptions, unsupported-condition fallback and iOS 26 exclusion.
- Full public EasyList/EasyPrivacy fixture: 22,000 native blocks, 81,741 omitted index entries/patterns (JS retained), 5,990,200 JSON bytes. Previously 5,987,920 bytes: +2,280 serialized bytes, not a RAM measurement.
- Full fixture URL matching: PASS for all 12 added destinations on both the reported tester source and an unrelated website; own-service and navigation controls pass. Prior Google tag, Hotjar, Yandex and scoped-exception controls still pass. No requests made by this script.
- Isolated macOS WebKit JS suite: PASS for all 12 endpoints on unrelated and Reddit/Google/Amazon/Facebook/Pinterest/X sources, disabled-state passthrough, Reddit promoted-post hiding, managed-script ownership, 50 configuration refreshes, CSS uniqueness, indexed interception and early dark rendering. Network calls are stubbed in this suite.
- Byte-comparison against the backup: PASS; Reddit selector definitions, Reddit CSS and the existing social/essential whitelist function are unchanged.
- Probe Release build: PASS (6,250 ms). Browser Release build: PASS (119,241 ms, warmed `.derived`). Browser deep/strict signature verification passed. Browser and BrowserShare remain 1.1 (20), SDK `24A5380g`.
- Generated and probe-bundled native fixture hashes match: `c460fa748932ad2d3c98b0d8241b6fe6a53272d9368f1b1d7e09aa8b950a2e19`.
- Physical M1 probe: PASS, exit 0, on iPadOS 27.0 `24A5430a` / SDK `24A5380g`. Compiled 23,399 rules (including allowances and test controls), 5,990,622 bytes, in 8,283 ms and 8,085 ms. All eight private/persistent native script cycles and the existing cookie/lifecycle controls passed.
- Live physical-device endpoint checks: **12/12 PASS**. Every endpoint listed above was reachable before native attachment, rejected while attached, and reachable again after removal. No baseline failures were credited. This is actual WKWebView network behavior in the separate probe app, not an emulator or a public-site score in Browser.
- Browser installation: PASS on M1 iPad `FDFA143F-2E8F-58A5-BC84-EF9E9EE6D64F`. Installed-app metadata confirms `com.web.me.Browser` 1.1 (20), installation `/private/var/containers/Bundle/Application/1F245A9D-31B5-4CB6-A2D4-E74B76EDC082/Browser.app/`.
- Browser launch/process verification: PASS. PID 9141 was confirmed running the executable from that exact new installation. The public tester score and real Reddit browsing after this install remain user-verification steps; probe success is not substituted for them.
- Final `git diff --check`: PASS. No unrelated files were edited or deleted in this follow-up.

Commands:

```sh
node scripts/test-native-ad-resources.mjs /private/tmp/vortex-indexed-adblock.UMw31X
node scripts/make-native-adblock-fixture.mjs /private/tmp/vortex-indexed-adblock.UMw31X .codex-checkpoints/native-ad-rules.json
node scripts/test-native-ad-coverage.mjs .codex-checkpoints/native-ad-rules.json
VORTEX_BASELINE_SOURCE=/private/tmp/vortex-indexed-adblock.UMw31X/AdBlockService.before.swift node scripts/test-webview-scripts.mjs
```

The physical probe's opt-in `--live-supplement-urls` mode uses credential-free HEAD requests in its own private store. It credits a block only when an endpoint is reachable before attachment, rejected with native rules, and reachable after removal. Baseline failure or timeout is not proof of blocking. Synthetic native/cookie lifecycle controls remain separate.

## Limits

No guarantee of a particular public tester percentage, complete ABP support, universal website compatibility, or measured iPad RAM/latency change. Native child-frame coverage is unchanged. First-party service use remains permitted by design, so this supplement does not prevent every first-party analytics request. The user should reload the test after native preparation and confirm Reddit still hides ads and browses normally.

Sources: [tester endpoint definitions](https://github.com/paileActivist/toolz/blob/main/resources/adblock/data.js), [tester HEAD-request/category logic](https://github.com/paileActivist/toolz/blob/main/adblock.html), [Google advertiser platform](https://business.google.com/us/google-ads/), [Amazon advertising API](https://advertising.amazon.com/API/docs/en-us/info/api-overview).
