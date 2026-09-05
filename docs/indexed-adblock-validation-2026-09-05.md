# Indexed ad-block test build — 2026-09-05

## Scope and rollback

User authorized a local checkpoint and indexed-blocker implementation for testing.
Checkpoint: `codex/checkpoint-before-indexed-adblock-20260905` at
`22c7f9a6f81793c84e8d050c821da4cd2e5bc444`. No remote push or release.

Changed only the ad-block parser, indexed JavaScript matcher, service integration,
filter-list status UI, tests, and documentation. Native ad-block lists remain
disabled on iOS 27. Cookie rules, AI/PCC, hibernation and navigation/dark-mode
implementations are unchanged.

## Validation

- Standalone Swift parser typecheck and JavaScript syntax check passed.
- Exhaustive lookup of 100,000 synthetic domains passed; two 60,000-domain lists
  received 50,000 slots each. Host-boundary negatives passed.
- Tests cover request/document exceptions, document-domain inclusions/exclusions,
  resource masks, party restrictions, case sensitivity and unsupported modifiers.
- Isolated macOS WKWebView tests passed indexed fetch/XHR/WebSocket/beacon blocking
  and request exceptions from the first inline page script. Requests are stubbed;
  these fixtures send no traffic and use no user website data.
- Existing checks passed managed-script ownership, 50 configuration refreshes,
  stylesheet uniqueness, disabled fast path, re-enabling, first-frame dark mode,
  and idempotent dark-mode fallback.

Public EasyList/EasyPrivacy fixtures downloaded for this run yielded approximately
96,044 simple domains and 9,044 scoped/pattern/exception entries, with a 3.57 MB
UTF-8 payload. Both lists contributed. Rules beyond the complex-pattern budget and
unsupported modifiers are deliberately omitted; this is not complete ABP support.

## Performance evidence and limits

Desktop Node tests with the public-list snapshot measured approximately 0.0056–0.0066
ms per varied clean request after warmup. This measures only the matcher, not page
loading, iPad tap latency, or overall browser performance. Grouping patterns with
identical conditions removed the initial generic-regex cache-thrashing issue.

An eight-context macOS JavaScriptCore experiment on the grouped matcher, before
the final scoped-WebSocket and hostname hardening changes, measured incremental process
footprint of 93.6 MiB for a legacy 5,000-regex model and 123.6 MiB for the indexed
public-list matcher: about 30 MiB more across eight contexts. The baseline is a
model, not the full previous app. These isolated contexts do not represent total
iPad app/WebContent memory, iframe amplification, startup peaks, or battery use.
No claim of negligible RAM increase or measured iPad speedup is justified.

## User test

After the user approved retrying the interrupted deployment, final Release 1.1
(20) built successfully (16.8 seconds, warmed checkout-local `.derived`). Signature
verification passed. Bundled matcher SHA-256 matches final source:
`33bd7c7a0b2da17c6ada2929b4b2f49ede0e287fea743093b3e94a4b525ed20d`.
The final parser/matcher regression run passed. Independent read-only review found
no must-fix crash or matcher correctness regression for the supplied lists.

Deployment completed on M1 iPad Air (5th generation), CoreDevice
`FDFA143F-2E8F-58A5-BC84-EF9E9EE6D64F`: install succeeded, launch succeeded,
installed-app query confirmed `com.web.me.Browser` 1.1 (20), and process 8268
matched the newly installed bundle container
`6A0CB13C-BF3E-4624-941E-18DFD7D56A09`. Feature-level user testing and iPad
memory/latency profiling remain unverified. No app data was exported or cleared.

Review follow-up: on an exceptional index-budget failure, retaining the previous
snapshot may also retain a just-disabled list. The UI reports that previous
protection was retained; global/per-site disabling is still available. This edge
case needs a future configuration-failure regression test. No device RAM claim
follows from the source review or desktop benchmarks.

Open filter-list settings, keep EasyList and EasyPrivacy enabled, and use Update
All if automatic migration has not completed. Confirm the indexed counts and
check for update errors. Reload test pages after updating.

Compare both the blocking test and ordinary sites: news links, Reddit/X, logins,
video, global off/on, and a per-site pause. Check one tab and multiple live tabs.
Report broken requests, renewed tap delays, reloads, or memory pressure. The JS
fallback still cannot block every resource type; a perfect test score is not
promised. Physical-device responsiveness and memory remain manual/profiling work.
