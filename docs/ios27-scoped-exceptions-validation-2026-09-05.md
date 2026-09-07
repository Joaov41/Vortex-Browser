# iOS 27 scoped-exception correction, 2026-09-05

## Scope

User approved correcting overly broad native exceptions after reporting unchanged 85% host-test results and a screenshot of analytics execution failures (69/100 on a different test). No new blocklist domains, higher budgets, broader frame coverage, cookie changes, AI changes, or iOS 26 converter changes were authorized or made. The prior local checkpoint remains `80c2ad8`; this follow-up is local and uncommitted. The unrelated screenshot deletion remains untouched.

## Cause and correction

The initial native converter turned every hosted exception into a whole-host permission, stripping paths, request types, party flags and document-domain conditions. Generated rules therefore cancelled native blocks for Google tag/ads, Hotjar, Yandex, AWS and Facebook destinations. JavaScript filtering remained separate and did not gain this blanket allowance.

`NativeAdResourceRules.exceptionRules` now preserves representable URL patterns, types, case sensitivity, and source-site conditions. First-party hosted exceptions use the same last-two-label source-site definition as the existing JavaScript matcher rather than WebKit's stricter first-party load type. A source include OR exclude list is supported, but their combination falls back to JavaScript-only protection: the physical probe established that this WebKit build rejects multiple source-URL conditions, even across different top/frame keys. None of the 1,373 exceptions in the public fixtures requires the unsupported combination. Document exceptions continue to apply to the source page, not the request destination.

Unsupported hosted regex shapes keep a conservative host allowance with their other conditions retained. Hostless first-party exceptions conservatively allow both parties. Unsupported hostless patterns, combined include/exclude scopes, and document exceptions with extra source scopes cause JavaScript-only fallback. These limitations avoid deleting an exception to force a higher score. No scripts are neutered or test-specific hosts added.

## Validation commands

```sh
node scripts/test-native-ad-resources.mjs /private/tmp/vortex-indexed-adblock.UMw31X
node scripts/make-native-adblock-fixture.mjs /private/tmp/vortex-indexed-adblock.UMw31X .codex-checkpoints/native-ad-rules.json
node scripts/test-native-ad-coverage.mjs .codex-checkpoints/native-ad-rules.json
VORTEX_BASELINE_SOURCE=/private/tmp/vortex-indexed-adblock.UMw31X/AdBlockService.before.swift node scripts/test-webview-scripts.mjs
```

The public fixtures are the same EasyList/EasyPrivacy snapshots used in the prior run, not a copy of iPad app data. The generated fixture contains 22,000 native block rules, 5,987,920 JSON bytes and unchanged block selection. SHA-256 of the generated and probe-bundled fixture agrees: `b33861df04eefe643f30c6f9ad0a3c29888d01fab7c66cccd7d4476d0d6c8a81`.

## Results

- Pure exception regression: PASS for path/type/source/case restrictions, separate include and exclude scopes, fail-safe rejection of unsupported combined scopes, same-site subdomain allowances, document-path exemptions and existing safety guards.
- Public-list matching: PASS for Google tag, Hotjar, Yandex, Google Ads, AWS and Facebook URL cases; known legitimate site/path exceptions remain allowed. This check performs no network requests and emulates native rule matching.
- Existing macOS WebKit JavaScript/dark-mode regression suite: PASS, including 50 configuration refreshes and enable/disable behavior.
- Updated isolated probe build: PASS. It uses the production exception converter for the synthetic permission, checks script versus fetch behavior on the same URL, and verifies that a permission does not apply after switching source sites.
- First device attempt: cookie/lifecycle checks passed, then WebKit rejected the probe's intentionally combined include/exclude condition with WKErrorDomain code 6. Browser was not installed. Added a production guard against that unsupported combination and changed the positive control to a supported single source condition before rebuilding.
- Final physical probe: PASS on the M1 iPad, iPadOS 27.0 `24A5430a`, SDK `24A5380g`, exit code 0. Two compilations of 23,399 rules / 5,988,342 bytes (public fixture plus synthetic controls) took 8,290 ms and 8,162 ms. All eight native cycles passed in private/persistent stores: script blocking before the request reached the loopback server, path/type/source-site exception boundaries, ordinary script and child-frame preservation, removal/restoration, and cookie-rule coexistence. Existing cookie and production cookie-service lifecycle checks also passed. These are isolated fixture results, not real-site score or latency measurements.
- Final Browser Release build: PASS using the warmed `.derived` directory, duration 66,296 ms. Final probe Release build: PASS, duration 10,746 ms. Browser signature verification with `codesign --verify --deep --strict` passed. Browser and BrowserShare metadata both remain 1.1 (20), SDK `24A5380g`.
- Browser installation and launch: PASS on device `FDFA143F-2E8F-58A5-BC84-EF9E9EE6D64F`. Installed metadata confirms `com.web.me.Browser` 1.1 (20) at `/private/var/containers/Bundle/Application/B3DD33A2-2410-49E7-8F32-F05D4158E5D8/Browser.app/`. After launch, PID 8911 was verified running the executable in that new installation. This confirms deployment/process state, not the public tester result or the app's current native-rule readiness.
- Final `git diff --check`: PASS. No push or publishing performed.

## Limits and handoff

This does not fill filter-list gaps, change first-party safety, or add native child-frame blocking. The score on either public tester is not yet verified for this correction. A real login/social-site smoke test and RAM/steady-state latency profiling are still separate checks. Native preparation is asynchronous and cached; first-page resources before preparation can still rely on JavaScript only.

References: [Apple rule schema](https://developer.apple.com/documentation/safariservices/creating-a-content-blocker), [AdBlock Tester's public checks](https://github.com/whitematchmarketing/adblock-tester.com/blob/master/src.cd761dad.js.map).
