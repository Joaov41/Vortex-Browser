# Bounded regex compatibility follow-up

## Scope and implementation

User approved improving real coverage and compatibility while retaining the 22,000 native-block budget. This follow-up modifies only the indexed parser/cache metadata, associated tests and documentation, on top of the preserved previous scoped-script repair. No unrelated production code, UI, Reddit hiding, version/signing settings or native capacity was changed. No test-site special cases were added.

`IndexedAdBlockRules.boundedRegex` accepts a deliberately narrow raw ABP regex subset: ASCII HTTP(S)-anchored URLs or slash-prefixed paths, literals, escaped punctuation, simple character classes, optional atoms and finite repetitions. Closing slash parsing preserves `$` inside the expression as an anchor rather than treating it as an option delimiter. Request types, explicit party, source includes/excludes, case and exception fields remain on the resulting rule.

Limits: 512 source bytes, 1,024 expanded bytes, repetition maximum 64, at most two variable atoms and eight optional positions. No groups, lookarounds, backreferences, alternation, wildcard or unbounded repetition. Finite repetitions expand to atoms/optionals for the narrower native grammar. These constraints reduce regex complexity; they are not a claim that arbitrary filter regexes are safe or supported.

Raw provenance is persisted only on new regex rules. Legacy policy removes these rules before budget selection, preserving iOS 26 matching. Format-3 caches cause the existing post-ready, non-reloading migration to refresh format-1/2 lists. Offline cached protection remains available. Metadata is excluded from semantic deduplication.

ABP syntax reference: https://help.adblockplus.org/adblock-plus-help-center/how-to-write-filters

## Actual additional coverage

The same September 7 EasyList/EasyPrivacy fixture used for the previous repair contains three newly accepted rules:

1. A 32-character hexadecimal path followed by `invoke.js`, explicitly third-party script requests (EasyList).
2. Bounded changing script names on `fdts.ebay-kleinanzeigen.de`, restricted to `kleinanzeigen.de` source pages (EasyPrivacy).
3. A bounded changing path on `www.ebay-kleinanzeigen.de`, restricted to `kleinanzeigen.de` source pages (EasyPrivacy).

Tests assert all three survive the merged index and native pattern selection. These are list rules, not hardcoded production addresses. Coverage improvement is incremental; most other complex regex syntax and redirect behavior remain unsupported.

Final fixture: 22,000 block actions, 5,949,379 bytes, 78,437 omitted candidates. SHA-256 `5a05be8395f3c6ffe55bf1111aa1ddbe41ae2ad03f306212164006e0d3c67d5d`. JSON size is 550 bytes above the prior repaired fixture. This is not a RAM measurement. Fixed-budget selection can replace other patterns; the prior endpoint coverage regression still passes.

## Passed checks

- `scripts/test-bounded-regex.mjs`: positive/negative lengths, end anchors and options, source/type/party/case restrictions, regex exceptions, malformed and complex regex rejection, cache roundtrip and format-2 migration, exclusion from legacy policy, all three public rules retained in both layers.
- `scripts/test-scoped-policy-compatibility.mjs`: all 9,045 effective legacy matching patterns and domains still equal checkpoint `5e831f8`.
- `scripts/test-scoped-cache-migration.mjs`: conservative old-cache retention, migration ordering/no automatic reload and malformed-cache rejection.
- `scripts/test-native-ad-resources.mjs` and `scripts/test-native-ad-coverage.mjs`: budgets, existing endpoints, own-site/navigation controls and source/exception safety retained.
- `scripts/test-scoped-native-webkit.mjs`: actual macOS WebKit compiled the final public list and synthetic/combined lists. Regex-based static/dynamic scripts blocked before reaching the loopback server; regex exception, ordinary scripts, out-of-scope requests and rule removal passed. Final public/combined compilation: 5,020 / 5,027 ms. This is not an iPad navigation benchmark.
- `scripts/test-webview-scripts.mjs`: embedded JavaScript/Reddit hiding, protection toggles, managed refreshes and existing dark/lifecycle regressions passed with stubbed network.
- Final Browser signed Release build passed in 36,088 ms; strict/deep code-signature verification passed. Build remains 20. The previously reported nonfatal capture-ownership warning remains; unrelated service code was not changed in this follow-up.
- Updated isolated iPad probe build passed in 7,480 ms and installed successfully.

## Physical M1 validation: passed after unlock

The first launch was denied because the M1 iPad was locked. After the user unlocked it, the already-installed updated probe ran successfully on iPadOS 27.0 build `24A5430a`, SDK `24A5380g`, with no rebuild. Two full native compilations completed in 8,434 and 8,267 ms. All eight native ad cycles and all private/persistent before/protected/outside/removed scoped phases passed. The scoped fixtures now use raw regex rules for static/dynamic scripts and a raw regex exception; both execution and loopback server request counts were asserted. Existing cookie/session lifecycle controls also passed. Final probe exit code: 0. This run used synthetic loopback pages, not live public endpoints.

## Pending / not claimed

After explicit user approval, the tested Browser 1.1 (20) build was installed on the M1 iPad and launched successfully. No app-data clearing was performed. Real-site browsing acceptance, new tester scores, physical iOS 26 behavior, RAM and energy measurements remain unverified. Neither full ABP compatibility nor a 100% test score is claimed.
