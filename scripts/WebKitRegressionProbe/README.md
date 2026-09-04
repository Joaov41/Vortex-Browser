# Isolated iPad WebKit probe

This development-only app has a separate bundle ID and never reads Vortex data. It serves synthetic cookie fixtures on device loopback. Its test-only HTTP allowance is not part of Browser's Info.plist.

Generate and build from the repository root:

```sh
xcodegen generate --spec scripts/WebKitRegressionProbe/project.yml
asc xcode build --project scripts/WebKitRegressionProbe/VortexWebKitProbe.xcodeproj --scheme VortexWebKitProbe --configuration Release --destination 'generic/platform=iOS' --derived-data-path .codex-checkpoints/WebKitProbeDerived --xcodebuild-flag=-allowProvisioningUpdates
```

Install/launch only on an explicitly authorized test device. Console output uses `VORTEX_PROBE:` and exits 0 on success. No user cookies or preferences are exported.

Coverage:

- Six native rule compilation/attachment/navigation/removal/teardown cycles.
- Persistent and nonpersistent synthetic sessions.
- Native `block-cookies` positive control (all loads) strips the first-party Cookie header.
- The production-shaped third-party rule preserves the first-party header and sends no cookies on the cross-site request.
- Removing rules preserves stored synthetic cookies and first-party requests.

On the tested iPad, WebKit already suppressed the cross-site cookies in the baseline. Therefore that assertion alone does not prove the extra rule changed cross-site behavior. The all-load positive control independently verifies native cookie-header enforcement. Real-site login/OAuth compatibility still needs manual smoke testing.

The separate macOS regression suite is `node scripts/test-webview-scripts.mjs`. It uses the production embedded scripts, synthetic filters, and the local `72dbb02` pre-fix checkpoint. Its cold/warm load times are diagnostics, not an iPad speed benchmark.
