# iOS 27 script-filter coverage repair

## Checkpoint and scope

The user requested a full local checkpoint, an implementation plan, and implementation by a Luna sub-agent at maximum reasoning under the primary agent's supervision. No unrelated changes are authorized.

Before implementation, all tracked and nonignored untracked project changes (including the user's pre-existing screenshot deletion) were committed as `5e831f83f79e083b0fcd0c61588fdd34fd828f21`. Tag: `codex/checkpoint-before-scoped-script-filtering-20260907`. `.codex-checkpoints/full-source-checkpoint-20260907.bundle` was verified and contains complete Git history. This is a source checkpoint, not a copy of ignored build caches or local tool state. No remote push.

## Requirements and implementation sequence

1. Add exact hosts `analytics.s3.amazonaws.com` and `click.googleanalytics.com` to the shared iOS 27 supplemental policy. Keep hostname boundaries, cross-site-only application, own-service exceptions, and navigation safety. Do not broadly block Amazon, Google, Facebook, or Reddit.
2. Correct the unintended third-party restriction for appropriately scoped script/path rules on iOS 27. Respect explicit party modifiers and request types. Keep broad host-only first-party safety and the entire iOS 26 policy unchanged. The native and JavaScript layers must agree on the supported rule semantics. Version or separate cached rule representations so existing installations actually receive the correction without mixing policies across OS versions.
3. Convert supported source-domain restrictions into native main-frame conditions. Preserve includes/excludes, URL/path, case and resource-type restrictions and all request/document exceptions. Never drop a condition to make a rule compile, or use a broad ignore rule that cancels unrelated blocking. Truly unrepresentable cases retain explicit fallback rather than accidental widening.
4. Ensure useful source-scoped and script/path rules reach the existing 2,000-pattern native budget instead of being permanently starved behind alphabetically ordered host rules. Keep the 20,000-domain / 2,000-pattern / 8 MB budgets, the OS/SDK safety gate, and full JS fallback. Do not add per-navigation recompilation or per-node scans.
5. Add synthetic regression cases demonstrating both static and dynamic same-site script prevention, source include/exclude boundaries, explicit third-party-only behavior, allowed normal scripts, exception priority, rule removal, disabled-list/protection behavior, cache migration, and iOS 26 invariance. Include Turtlecute-shaped paths only as test fixtures: no test-site special casing or blanket `ads.js` production rule solely to turn a benchmark green.
6. Regenerate a full public EasyList/EasyPrivacy fixture; verify rule count, byte budget, existing endpoint coverage and newly supported real-list rules. Compile and exercise the actual native rules in isolated WebKit, not just a JavaScript regex emulator. Build Browser without changing version/signing settings. Report physical-iPad validation separately from local tests and compilation.

## Invariants / excluded work

- Reddit cosmetic selectors and social-site allowances remain unchanged.
- No changes to hibernation, navigation, dark-mode implementation, cookies, AI/PCC/Shortcuts, UI layout, version numbers, screenshots, or publishing.
- No automatic subscription to a tester's own list, no promised score, no invented rules to imitate complete ABP compatibility.
- Unsupported ABP constructs and native child-frame behavior are not a full-engine rewrite in this repair; document remaining limitations precisely.

## Risks and acceptance gates

- First-party expansion can break site scripts: constrain it to the intended path/source-specific policy, test ordinary files and explicit exceptions, keep broad service hosts safe.
- Scope conversion can accidentally overblock or over-allow: positive and negative host/source/path/type tests are mandatory; test the compiled WebKit output.
- Priority changes can displace existing native coverage: document displacement, preserve preferred/common endpoints, retain the full JS index and fixed caps.
- Cache changes can leave stale rules or disable protection offline: test migration and policy identity, retain safe existing protection where possible.
- Beta WebKit can reject apparently valid JSON: native compilation and request/execution controls are required; do not weaken the current OS/SDK guard.

The primary agent will review Luna's changes against this document, request corrections where needed, run independent verification, and record exact remaining gaps before marking the goal complete.

## Primary references

- [ABP filter options and source-domain restrictions](https://help.adblockplus.org/adblock-plus-help-center/how-to-write-filters)
- [WebKit content blocker trigger/action model](https://webkit.org/blog/3476/content-blockers-first-look/)
