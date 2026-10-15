# Browser agent extension plan

Date: 2026-10-10
Checkout: `/Volumes/BackUP /My projects 2/browser with pcc cli/Vortex 2 copy`
Implementation agent: GPT-6 Luna, reasoning effort xhigh.

## Objective and implementation scope

Extend the existing browser agent through additive tools. The user selected **all ten actions from the table** during implementation. Complete the core tab/extraction/export set, then the approved browser and page actions below. The phases describe implementation order, not optional delivery.

The current working tree already contains modified AI/sidebar/browser files and untracked agent files. Those files are the baseline, not disposable work. A source backup, original tracked diff, status, and SHA-256 manifest are saved under `/private/tmp/vortyra-agent-extension-20261010/`.

## Preservation requirements

- Keep all current agent tools, argument names, routing behavior for existing requests, the 25-turn limit, stop behavior, approval cards, conversation summaries, ChatGPT Plan authentication, and build availability gates.
- Keep ordinary browsing, provider selection, reader/translation controls, downloads, bookmarks, groups, tab lifecycle, split view, incognito, and existing UI layouts unchanged.
- Do not modify signing, bundle IDs, build numbers, entitlements, project/package configuration, ad/cookie blocking, browser stores, AI service implementations, share extension, website assets, screenshots, or media.
- Prefer new files in `Browser/AI/Agent/` and new focused tests. Integration edits are limited to the agent controller/router and small optional callbacks in `AISidebar.swift` and `ContentView.swift`. A narrow optional target-language parameter in `PageTranslator.prepare` is permitted if needed for explicit language requests; its default and all existing callers must retain their current behavior.
- Use the current browser's public APIs through an agent-only adapter. Do not introduce a second tab store, download queue, bookmark store, or alternate navigation delegate.
- New tools are available only during an existing authorized agent run. Missing adapters report unavailable; existing standalone/sidebar callers continue working.

## Phase 1: tab access, extraction, and export

### 1. Browser adapter and existing-tab tools

Add a small main-actor adapter with narrowly scoped access to `BrowserViewModel` and `BrowserDownloadManager`. Pass it through the existing sidebar/controller as an optional dependency.

Expose tab listing and switching, and obtain a fresh page snapshot after switching. Use stable UUID tab IDs and reject invalid, stale, closed, or unsupported targets. Keep the agent's active web view and visible AI context synchronized. Reuse selection/activation APIs and hibernation protection. Add closing only with an explicit confirmation and correct handling when the agent's tab is closed. Do not expose a normal run to incognito tab titles/URLs, or mix private and normal contexts. Exclude dedicated Web-AI provider tabs.

### 2. Structured extraction

Add bounded, read-only page scripts in a separate file to list links and extract real HTML tables. Return row/column data, page title, full source URL, and explicit truncation metadata. Resolve relative links, retain only supported web URLs, and exclude hidden/script content and sensitive field values. Use stable table selection and sensible row/column/text limits. Treat extracted content as untrusted just like existing page snapshots.

Store extracted datasets only for the current agent run. Allow collecting several datasets across tabs and exporting a selected dataset or an explicitly supplied comparison. Do not claim arbitrary visual product grids are HTML tables; return a clear explanation and let the model read existing page text when no table is present.

### 3. CSV and PDF exports

Add a dedicated export service. CSV must preserve Unicode, delimiters, quotes, and line breaks; guard spreadsheet formula cells and include source information. Support a page PDF and a readable PDF report for collected/comparison results. Bound file size and input dimensions. Do not fetch new remote content solely to generate a report.

Write sanitized, collision-safe filenames into the existing download manager's session directory. Queue exports through `enqueueCompletedFile` and the existing Files export UI. Preserve the user's choice of destination and cancellation behavior. Report "ready to save" while native export is pending; never equate generating a temporary file with saving it to Files. Incognito exports stay in the existing temporary lifecycle and are explicitly user initiated.

### 4. Routing and model instructions

Keep `/do` and `/ask` unchanged. Add only unambiguous new action phrases for tab comparison, extracting information, saving, and exporting. Existing generic summarize/translate questions must keep their current chat routing. Append instructions for choosing tools, sources, bounds, privacy, and honest export status. Keep every existing tool intact.

## Phase 2: remaining approved actions

These build on the same adapter and remain separate from existing feature implementations. All six areas below are now included in this implementation:

1. Tab groups and bookmark actions through existing model APIs. Enumerate and use stable IDs; reuse create/move/rename/save APIs. Explicit approval is required for destructive changes and any new private-page persistence. Never mutate a store by duplicating its implementation.
2. Download initiation/progress/status through WebKit and the current manager, without new cookie/network behavior. Start downloads using the active web view so the current session is retained, register them with the existing manager, and report actual manager state. Filter listings by the run's privacy scope; distinguish download completion, pending Files export, saved, failed, and cancelled states.
3. User-selected attachment workflow using the native website file picker. The user chooses the file, can cancel, and keeps control of submission. Do not grant the model arbitrary device-file access. Report selection only after the file input confirms it; opening a picker alone is not a completed upload. Avoid changing the existing WKUIDelegate behavior.
4. Find/highlight/reveal page text with reversible highlights. Use bounded matches, omit sensitive/hidden/editable fields, avoid replacing page nodes or event handlers, and clear only agent-owned highlights.
5. Reader mode and translation through optional callbacks to existing ContentView entry points and state. Support reader on/off, page translation into the requested supported language, and restoring the original. A default-preserving optional target may be passed through the existing prepare/start functions; do not duplicate translation logic or alter preferred-language behavior for manual actions. Wait for actual completion and propagate cancellation/errors. Preserve current manual controls and generic translation questions routed to chat; explicit page-action wording and `/do` may use these tools.
6. Additional targeted page controls: element scrolling, hover, sliders, and bounded drag-and-drop where the website supports synthetic events. Use fresh element references, validate target types and ranges, preserve existing guarded click/type behavior, and return unsupported when browser/native restrictions prevent completion. Synthetic events must not be advertised as trusted physical gestures.

Screenshot understanding, PDF-reading workflows, scheduled monitoring, and saved repeatable workflows are separate future projects and are outside this implementation.

## Verification and completion criteria

- Compare every baseline hash; only the documented integration files and new agent/test/documentation files may change. Review the diff against the pre-task snapshot, not just Git HEAD.
- Run the unchanged existing router/page-script tests and targeted browser tab/bookmark/download tests relevant to exposed APIs. Add meaningful tests for privacy boundaries, stale tab IDs, cancelled operations, dataset truncation, source retention, CSV injection/escaping, filename collisions, export status, PDF validity, group/bookmark changes, page highlighting, additional controls, and upload selection/cancellation. Test callback state and failure handling for reader/translation where feasible; report any native picker/language-service validation limitations precisely.
- Use synthetic web pages, isolated UserDefaults, and temporary output directories. Do not use personal tabs/cookies, make purchases, post messages, or submit real forms to validate.
- Compile the app and focused XCTest target with DerivedData outside the source tree. Compare any failures with the pre-change snapshot before changing unrelated code.
- Verify emitted CSV contents and PDF pages with actual parsers/rendering. Inspect the adapter/UI integration and the old agent path with new tools unused.
- Completion means the selected set is implemented and checked, existing behavior is preserved within the validation performed, and remaining limitations are stated with evidence. No release upload, physical-device replacement, commit, or push is part of this request.

## Rollback

Remove the new modules and tests, and reverse only the integration hunks identified against the source backup. Preserve every pre-existing change. Do not reset or clean the working tree.

## Completion

All ten approved action categories are implemented. The final Simulator build/test run passed 51/51 tests (40 unchanged baseline tests and 11 extension tests), with no skips. All ten original tool definitions are unchanged, and 86 of 91 baseline app/test/project files remain byte-for-byte identical. See `docs/browser-agent-extension-validation.md` for the implemented actions, evidence, and runtime limits.
