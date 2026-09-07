# Scoped ad-blocking repair: validation

## Checkpoint, implementation and review

Full source checkpoint: `5e831f83f79e083b0fcd0c61588fdd34fd828f21`, tag `codex/checkpoint-before-scoped-script-filtering-20260907`. Complete-history bundle verified at `.codex-checkpoints/full-source-checkpoint-20260907.bundle`. Ignored build caches were not copied. Nothing pushed.

The plan was written before delegation in `docs/ios27-scoped-script-repair-plan-2026-09-07.md`. The requested `gpt-5.6-luna` sub-agent at `max` reasoning implemented the production changes. The primary agent reviewed and required conservative old-cache decoding, preservation of legacy matching and domain sampling, payload-only adtago prioritization, a round-robin budget-boundary correction, and post-ready migration without automatic page reload. The primary agent added independent compatibility/cache/native-WebKit tests and the device probe extension. Production source was frozen before the final builds/tests.

Production changes are confined to `AdBlockService.swift`, `IndexedAdBlockRules.swift` and `NativeAdResourceRules.swift`. Other changes are directly related tests and documentation. Reddit hiding JavaScript/selectors, navigation, hibernation, dark mode, cookies, AI/PCC, UI and version settings were not changed.

## Final public-list fixture

Fresh official EasyList/EasyPrivacy downloads from September 7 were used for both checkpoint and repaired-source comparisons.

- EasyList SHA-256: `342bd7466c2acaf98fcb7f242cf896cb1b8a94ee96b49f1794dc3704dbdc18f5`.
- EasyPrivacy SHA-256: `30754ce3d1804efb576ac212921b9088ec8b65acb524ab455fd76129ab604f9c`.
- Generated native fixture SHA-256: `f3fc955a25cc76b8072ddec82b216b833ce21cd23551820341ef656303257309`.
- 22,000 block actions, 5,948,829 JSON bytes; existing 20,000-domain / 2,000-pattern / 8 MB budgets retained. Exceptions increase total JSON action count beyond the block-action cap.
- Builder reports 78,437 omitted candidates. This is still a bounded native subset, not complete ABP support.
- Ordinary-domain stability regression compared with the original sampler: three removed, one added. Supplemental additions and pattern allocation are separately bounded.

## Passing automated checks

- `test-native-ad-resources.mjs`: source/party/type/exception boundaries; all 14 supplements and own-service/navigation controls; exact OS/SDK gate; fair-allocation final-slot regression.
- `test-indexed-adblock.mjs`: synthetic 100k fixture and public-list index tests.
- `test-scoped-policy-compatibility.mjs`: all 9,045 legacy effective patterns and domain matching equal the checkpoint. 6,625 raw-list implicit path/source rules gain the intended iOS 27 policy; explicit party restrictions are preserved.
- `test-scoped-cache-migration.mjs`: v1 disk caches remain conservative; refreshed provenance round-trips; malformed/partial caches rejected; migration scheduled after readiness and no automatic page reload.
- `test-native-ad-coverage.mjs`: actual public-list URL cases, 14 supplements, source scope and negative controls.
- `test-scoped-native-webkit.mjs`: actual macOS WebKit compiled synthetic, full public, and combined native lists. Static/dynamic scripts, same-site and source exclusion, explicit third-party restrictions, exceptions, ordinary scripts and removal passed. HTTP server counts confirmed blocked scripts never reached the server. Loopback only.
- `test-webview-scripts.mjs`: actual embedded JavaScript, Reddit promoted-post hiding, disable/re-enable, 50 managed refreshes, CSS uniqueness, early-dark regression and fetch/XHR/beacon/WebSocket interception passed. This uses stubbed network, not real endpoint evidence.
- `git diff --check` passed.

## Physical M1 iPad: passed

Device: iPad Air (5th generation), iPadOS 27.0 build `24A5430a`; SDK `24A5380g`. An isolated development probe, bundle `com.web.me.VortexWebKitProbe`, was built, installed and launched on the unlocked device. It never reads Browser's container, tabs or preferences.

- Six native lifecycle cycles and private/persistent synthetic cookie/session controls passed. Cookie implementation was not modified.
- Full native fixture plus test-only controls compiled twice, in 8,268 ms and 8,258 ms. These are cold probe compilation times, not per-navigation work or a browsing-speed benchmark.
- Eight native ad cycles passed: pre-request blocking, scoped path/type/site exception, ordinary scripts and child-frame negative control, removal and coexistence with cookie rules.
- Scoped private/persistent before/protected/outside/removed phases all passed, checking both script execution and server request counts.
- All 14 live supplemental URLs demonstrated reachable before attachment, rejected with native protection, and reachable after removal using credential-free HEAD requests: `ads.google.com`, `click.googleanalytics.com`, `analyticsengine.s3.amazonaws.com`, `affiliationjs.s3.amazonaws.com`, `analytics.s3.amazonaws.com`, `advertising-api-eu.amazon.com`, `ads.facebook.com`, `ads.reddit.com`, `d.reddit.com`, `ads.pinterest.com`, `ads-dev.pinterest.com`, `ads.youtube.com`, `ads-api.twitter.com`, `advertising.twitter.com`.
- Probe terminated with exit code 0 and final PASS.

## Build and remaining acceptance

Final signed Browser Release build passed using `.derived` (49,739 ms). Deep/strict signature verification passed. Browser and BrowserShare remain version 1.1, build 20. The build emitted a nonfatal Swift capture-ownership warning in the new background migration task; build and signing completed successfully.

Only the isolated probe was installed during this validation. The repaired Browser build has not yet replaced the user's Browser installation. Real browsing and the public tester score in that installed app remain user acceptance steps. Actual RAM/energy use was not measured; fixed rule/byte budgets alone do not prove zero resource impact.

No tester-specific dummy filenames were added to production to force a green score. A harmless dummy script without a matching production rule may still load. Unsupported ABP constructs and native child-frame coverage remain outside this repair; mixed source include/exclude conditions retain the existing JavaScript fallback rather than dropping restrictions. Offline v1 caches remain conservative until a successful background list refresh. No physical iOS 26 run was performed; legacy matching was verified by source-level fixture comparison.
