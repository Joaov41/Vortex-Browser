# Navigation, dark mode and cookie-blocking fixes

## Local recovery points

- Pre-fix checkpoint: `72dbb029954a6d877f534ee23fe358d285aa2ee2`. Includes the existing tracked changes and untracked project media, not ignored build caches. Nothing was pushed.
- Ad-block fix: `10e62c0`.
- Document-start dark mode: `597bad8` (depends on the managed-script utility in the preceding fix).
- Verified cookie compatibility and site exceptions: `bcaacf7`.

## Changes

Ad-block configuration now replaces its own script instead of appending every prior configuration. Other features' scripts retain their identity and order. Configuration/rule rebuilding is idempotent, disabled protection skips selector/regex compilation, CSS insertion is guarded, repeated style writes are avoided, and startup preparation cannot run twice or force a second page load.

DarkReader is enabled at document start using the effective per-tab/global setting, with a matching loading background. Later recovery is idempotent. Global changes preserve per-tab overrides; recreated web views receive their override before their first navigation.

The native third-party-cookie control is available on the verified iPadOS 27 `24A5430a` / SDK `24A5380g` pair, retaining the existing iOS 26 path. Untested iOS 27+ combinations remain guarded. The separate native ad-block list restriction is unchanged. Rule loading/registration is deduplicated, pending loads retain site exceptions, and main-frame navigation applies the destination's cookie exception before allowing navigation. Unsupported/global-off states are explained in the site panel.

No AI/PCC/Shortcuts routing, user-agent preferences, navigation gestures, password bridges, website data or unrelated user changes were rewritten.

## Executed validation

- `git diff --check`: passed.
- Signed Release device build: passed; deep/strict signature verification passed.
- Simulator `build-for-testing`: passed for arm64 and x86_64, including `WebViewRegressionTests`. XCTest cases were compiled, not executed; no simulator was booted. Xcode emitted legacy copied-cache-path and MLX compiler warnings.
- `node scripts/test-webview-scripts.mjs`: passed in real macOS WebKit with synthetic filters/pages. Fifty refreshes leave one owned script; other scripts survive; duplicate CSS drops from 3 nodes to 1; disabled selector-validation calls drop from 6,002 to 0. Unchanged configurations do not rebuild rules, and disabling restores hidden elements.
- DarkReader was enabled before the fixture's first inline script; its first animation-frame background was `rgb(36, 37, 37)`. The finish-time fallback did not call `DarkReader.enable()` again.
- Isolated M1 iPad probe: six native lifecycle cycles passed. Persistent/private first-party sessions survived native positive-control blocking, removal, and production-service setting changes. Native `block-cookies` stripped Cookie headers in the positive control. The actual production service accepted the verified OS/SDK pair.
- WebKit already suppressed cross-site cookies in the baseline fixture. Cross-site emptiness alone is not evidence that the additional rule changed those requests. See the probe README for test boundaries.
- Lint remains nonzero: 11 pre-existing size/complexity violations resurface with changed counts. Each matches an existing baseline entry by file, rule and declaration. No new style warnings remain, and the lint baseline was not expanded.

## Remaining device checks

The fixed local Release build was installed and launched on the M1 iPad. Post-launch verification found Browser process `7153` from the newly installed bundle. Version remains `1.1 (20)`; this was not an App Store/TestFlight release. Binary SHA-256: `7ccb6b143d17abb8322ceb374e3b4077312da771728c9cd23329a822dfc76663`. The temporary probe app and its synthetic sessions were then removed; Vortex's data was not exported or cleared.

The full reported 1–2-second real-site link delay has not been independently reproduced or timed end-to-end on the iPad. Synthetic cold/warm timings must not be presented as a device speedup. Check ordinary links on Reddit and other sites, dark/light overrides, redirects, back/forward, split/private/restored tabs and real-site login/OAuth flows. Do not call these checks complete based only on build/install success.

The global cookie preference was not forced on: enable **Block Third-Party Cookies** in the main settings menu if desired. Disabling this extra rule does not override WebKit's own privacy policy.
