# Agent and App Intents expansion: implementation plan

Status: all 11 phases implemented and committed on 2026-10-15 (commits 4ae77f2 to 50cee08, one `checkpoint-vortyra-agent-expansion-phaseN` tag per phase). Final full suite: 635 passed, 1 known pre-existing failure, 2 skipped. Each phase was implemented by a Haiku 5.5 agent and reviewed, built and tested by a supervising agent before commit.

Still to verify on a device or by hand: Siri and Shortcuts result cards, Spotlight results, the browser schemas in Siri, page-watch background refresh and notification taps, the widgets and controls in their galleries, the teach-mode banner and recording, the Calendar/Reminders/Mail/Messages sheets, and a Mac Catalyst build. Deferred: tab group and reading list schemas, window intents, incremental Spotlight sync, lazy loading of research tabs.

Restore point: commit `d14e1ad`, tag `checkpoint-vortyra-pre-agent-expansion-20261015-121908`. Work stays on the current branch (`codex/ublock-origin-lite-experiment`). Nothing is pushed.

## Goals

1. Return agent results to Shortcuts (run a task and wait for the answer and files).
2. Make bookmarks, open tabs, saved tasks and (opt-in) history searchable in Spotlight.
3. Adopt Apple Intelligence browser schemas so Siri understands Vortyra actions without exact phrases.
4. Show interactive result snippets in Siri and Shortcuts.
5. Control Center, Lock Screen and Home Screen controls and widgets.
6. Page watches: check pages on a schedule and notify on change.
7. Research in tabs: open sources in a tab group and return a report.
8. Teach mode: record a task once, replay it as guided steps.
9. Hand agent results to Calendar, Reminders, Mail and Messages (prepared, the user sends).
10. A detailed run history (steps, approvals, questions, sources, files, duration).
11. Split the 3,000-line `BrowserAgentController.swift` into focused files.

## Rules for every phase

These rules are mandatory. A phase that breaks one is rejected.

- **Scope.** Change only what the phase lists. Do not reformat, rename or "tidy" unrelated code. Do not touch `PageTranslator.swift`, the content blockers, uBO Lite, MLX, `.gitignore`, signing, the team ID, bundle IDs or version numbers.
- **Safety model is fixed.** Never weaken an existing gate: approvals for buy/send/post/delete/sign-in, sensitive-field masking and refusal, autofill privacy, private-tab isolation, `AgentTrustStore` matching, the Apple-backend purchase block, stale-approval checks. New features route every page action through the existing agent tools so those gates apply. Private (incognito) tabs never feed Spotlight, history, watches, recordings, widgets or Shortcuts results.
- **Existing behavior is preserved.** The 64 existing agent tool definitions stay byte-identical unless the phase says otherwise. Existing App Intents keep their type names, titles, parameters and phrases, so users' Shortcuts keep working. New intents are added beside them.
- **Persistence is backward compatible.** New stored fields are optional with defaults, so old JSON still decodes. Never bump a stored document version unless the phase says so. Never delete or rewrite user data on decode failure.
- **Style.** Match the surrounding code: `@MainActor` where the neighbors use it, `LocalizedError` enums with clear user-facing messages, bounded inputs (size and count limits like the existing stores), no force unwraps on external data, no `print` debugging left behind.
- **Project file.** The app, share extension and tests use Xcode synchronized folders (`objectVersion = 77`). New `.swift` files under `Browser/` or `BrowserTests/` are picked up automatically; do not edit `project.pbxproj` for them. Only Phase 8 edits the project file, using the `xcodeproj` Ruby gem (1.27 is installed), never by hand.
- **Tests.** Every phase adds focused XCTest cases in a new file under `BrowserTests/` named after the phase. Use the existing fakes and injection seams (see `BrowserAgentLoopTests.swift`, `AgentTasksTests.swift`, `BrowserIntentsTests.swift`). No test depends on the network or a real model.
- **No commits.** The implementing agent does not run `git commit`, `git push`, `git reset`, `git checkout --`, `git stash` or `git clean`. The supervisor commits after review.
- **Report.** End each phase with: files added, files changed (with a one-line reason each), tests added, the exact build and test commands run with their result counts, anything skipped and why, and open risks.

## Build and test commands

Run from the repository root. One simulator exists: `Vortyra-iPad-Air` (`F49938B2-C241-4E4B-B255-8E71E79FD6B5`, iOS 27.0).

```bash
DEST='platform=iOS Simulator,id=F49938B2-C241-4E4B-B255-8E71E79FD6B5'
COMMON="-project Browser.xcodeproj -scheme Browser -destination $DEST -derivedDataPath .derived -clonedSourcePackagesDirPath .spm-checkouts CODE_SIGNING_ALLOWED=NO"
# compile app and tests
xcodebuild build-for-testing $COMMON 2>&1 | tail -40
# focused tests (repeat -only-testing per class)
xcodebuild test-without-building $COMMON -only-testing:BrowserTests/<TestClass> 2>&1 | tail -60
# full suite (supervisor runs this at every gate)
xcodebuild test-without-building $COMMON 2>&1 | tail -80
```

Always pass `-parallel-testing-enabled NO` to test runs. The internal disk has about 9 GB free, and parallel runs create simulator clones that can fill it. In serial mode results print as `Test Case '-[BrowserTests.Class testName]' passed (…)`. If xcodebuild hangs after printing results, stop it with `perl -e 'alarm shift; exec @ARGV' 1500 xcodebuild …` (there is no `timeout` command on this Mac). Never delete files outside the repository or kill system services; if the disk fills up, stop and report.

To find compile errors quickly: `xcodebuild build-for-testing $COMMON 2>&1 | grep -E "error:|warning: .*(Browser|Intents|Agent)" | head -40`.

The baseline (402 tests: 399 passed, 1 failed, 2 skipped) is in `.codex-checkpoints/agent-expansion/baseline-tests.log`, with a sorted per-test list in `baseline-results.txt`. Known pre-existing failure: `AIResponseCanvasTests/testRedditReductionGroupsRetainAllPartialSummaries`. A phase may not add new failures.

## Phase order

| # | Phase | Depends on |
| --- | --- | --- |
| 1 | Split `BrowserAgentController` | none |
| 2 | Detailed run records | 1 |
| 3 | Run task and wait (results to Shortcuts) | 2 |
| 4 | Interactive snippets | 3 |
| 5 | Spotlight entities | none |
| 6 | Apple Intelligence browser schemas | 5 |
| 7 | Page watches | 3 |
| 8 | Widget extension and controls | 5, 7 |
| 9 | Research in tabs | 3 |
| 10 | Teach mode (record and replay) | 2 |
| 11 | Hand results to Calendar, Reminders, Mail, Messages | 2 |

---

## Phase 1: split `BrowserAgentController.swift`

A pure move. No behavior change, no renamed symbols, no new logic.

**Target layout** (all in `Browser/AI/Agent/`):

| File | Contents moved from the controller |
| --- | --- |
| `BrowserAgentController.swift` | Class declaration, published state, nested types (`Step`, `Confirmation`, `UserQuestion`, `CompletionSnapshot`, `RunContext`, …), `init`, start/stop, the run loop. |
| `BrowserAgentController+ToolCatalog.swift` | The tool-name sets (`browserToolNames`, `coreToolNames`, `dataToolNames`, `researchToolNames`, bundles), intent-cue arrays and the tool-selection functions (around lines 2410–2600). |
| `BrowserAgentController+Confirmation.swift` | Approval and question flow: confirmation continuation handling, `ConfirmationDecision`, purchase scope checks (`applePurchaseIsOutOfScope`), trust-store lookups. |
| `BrowserAgentController+PageTools.swift` | Execution of page tools (click, type, scroll, navigate, tabs, read_page, screenshot, fill_form…). |
| `BrowserAgentController+DataTools.swift` | Extraction, datasets, comparison and export tools, `fetch_page`. |
| `BrowserAgentController+Failures.swift` | `BrowserToolFailure` and other error types. |

**How:**
- Use Swift `extension BrowserAgentController { … }` in the new files.
- `private` members that are now used across files become `internal` (drop `private`), and `private` stored properties referenced from extensions become `internal` or `private(set)`. Nothing else changes visibility. Stored properties stay in the main file (extensions cannot hold stored properties).
- Move code with copy-and-delete of whole declarations. Keep each declaration's text byte-identical apart from the access modifier.
- Keep the header comment in the main file.

**Done when:**
- The app and tests build; the full suite has the same pass/fail set as the baseline.
- `BrowserAgentController.swift` is under 1,200 lines.
- A diff check shows no changed lines other than moves and dropped `private`: `git diff -M --stat` plus a script that sorts the old and new declaration lines and compares (put the script in `.codex-checkpoints/agent-expansion/`, not in the repo).
- New test file `BrowserTests/AgentControllerSplitTests.swift`: asserts the full tool-name catalog (every name in every set) equals a literal list copied from the current code, so later phases cannot change it by accident.

---

## Phase 2: detailed run records

Extend what a finished run remembers. Used by Phases 3, 4, 10 and 11.

**Model changes:**
- `BrowserAgentController.CompletionSnapshot` gains:
  - `requestID: UUID?` — the `PendingAgentTask.id` that started the run (nil for runs typed in the sidebar).
  - `startedAt: Date`, `status: AgentRunStatus` (`completed`, `stopped`, `failed`, `stepLimit`).
  - `approvals: [AgentRunApproval]` — `{ reason, host, decision: allowed | denied | alwaysAllowed, date }`.
  - `questions: [AgentRunQuestion]` — `{ prompt, answered: Bool, date }`. Never store the answer text.
  - `exportedFiles: [AgentRunExport]` — `{ filename, kind: csv | pdf | other, fileURL }`, only files the run itself created through the export tools.
  - `sources` already exists; keep it.
- Thread `requestID` from `PendingAgentTask` → `AgentTaskLaunchRequest`/startup → controller start call → `RunContext` → snapshot. Sidebar-typed runs pass nil.
- Record approvals, questions and exports where those events already happen (the confirmation flow, `ask_user`, the export tools and `enqueueExport`). Find where export files land (`BrowserAgentExportService`, `BrowserAgentBrowserAdapter.enqueueExport`) and capture the file URL there.
- `AgentRunRecord` (persisted, `AgentTaskStore.swift`) gains the same fields as optionals, except `fileURL` (store only `filename` and `kind`), plus `savedTaskID: UUID?`, `duration: TimeInterval?`. Old documents decode unchanged. Respect the existing per-field byte limits; add limits for the new arrays (max 50 approvals, 20 questions, 20 exports, 50 sources per run).
- Private runs: unchanged — nothing is recorded.

**UI:**
- New `AgentRunDetailView.swift`: opened by tapping a history row in `AgentTaskLibrarySheet`. Shows task, status, start time and duration, backend, start URL, the action timeline (existing `actions`), approvals with decision, questions (prompt only), sources as links, exported file names. Buttons: Run Again (existing behavior), Save as Task, Share Log (plain text via `ShareLink`).

**Done when:** old history JSON from `AgentTasksTests` fixtures still decodes; new fields round-trip; the detail view builds; tests in `BrowserTests/AgentRunRecordTests.swift` cover decoding old documents, limits, private runs recording nothing, and requestID threading through the snapshot.

---

## Phase 3: run task and wait (results to Shortcuts)

**New types** (`Browser/Intents/AgentResultIntents.swift`, `Browser/AI/Agent/AgentRunCompletionBroker.swift`):

- `AgentRunCompletionBroker` (`@MainActor`, singleton `shared`):
  - `func wait(for requestID: UUID, timeout: Duration) async -> AgentRunWaitOutcome` — `.finished(CompletionSnapshot)`, `.timedOut`, `.cancelled`.
  - `func complete(_ snapshot: CompletionSnapshot)` — called from `ContentView.handleAgentTaskCompletion` (and for private runs too, before the private early-return, so a waiting intent does not hang).
  - Holds continuations keyed by request ID; a completion that arrives before anyone waits is kept for 10 minutes (max 16 entries) so a fast run is not missed. Timeouts resume exactly once. No leaks: entries are removed on resume.
- `AgentRunResultEntity: AppEntity` (transient, `TransientAppEntity` if available, otherwise an entity with an in-memory query) with properties: `outcome: String`, `status: String`, `taskTitle: String`, `finishedAt: Date`, `sources: [URL]`, `files: [IntentFile]`.
- `RunAgentTaskAndWaitIntent` — title "Run Browser Task and Get Result". Parameters: `task: String`, `startURL: URL?`, `timeoutSeconds: Int` (default 180, range 15…900). Foreground mode like the existing intent. Enqueues exactly like `RunAgentTaskIntent` (same validation), then awaits the broker. Returns `ReturnsValue<AgentRunResultEntity>` and a dialog with the first 300 characters of the outcome.
- `RunSavedAgentTaskAndWaitIntent` — same, for an `AgentTaskEntity`.
- `GetLastAgentRunResultIntent` — returns the most recent non-private run record as an `AgentRunResultEntity` (files omitted: records keep only names).

**Rules:**
- Private run → result status `completed`, outcome replaced by "This task ran in a private tab, so its result isn't shared with Shortcuts.", no sources, no files.
- Timeout → status `stillRunning`, outcome "The task is still running in Vortyra." The run itself continues.
- Stopped by the user → status `stopped` with whatever outcome exists.
- Files are read from the run's own export URLs only, size-capped at 25 MB each, max 5.
- Add App Shortcut phrases: "Get a browser task result from \(.applicationName)". Keep `BrowserAgentShortcuts` within Apple's 10-shortcut limit: if adding exceeds it, add the new intent without a phrase rather than removing an existing one.

**Done when:** tests in `BrowserTests/AgentRunWaitTests.swift` cover: completion before wait, completion after wait, timeout, private redaction, two concurrent waits for different IDs, cancellation. The existing `RunAgentTaskIntent` behavior is unchanged.

---

## Phase 4: interactive snippets

iOS 26 `SnippetIntent` is available (deployment target is 26.0).

- `AgentRunResultSnippetIntent: SnippetIntent` showing a SwiftUI card: task title, status, outcome (max 12 lines), up to 3 source domains. Buttons (as `Button(intent:)`): **Open in Vortyra** (opens the app on the run's detail view via `webmebrowser://run?id=<runID>` — add this route to `AgentIncomingURLRouter`, accepting only a UUID), **Copy Result** (copies outcome; an intent with `supportedModes` background).
- `PageSummarySnippetIntent` for `SummarizeBrowserPageIntent` output: page title, domain, summary, **Open Page** button.
- Use the snippets from `RunAgentTaskAndWaitIntent`, `RunSavedAgentTaskAndWaitIntent` and `SummarizeBrowserPageIntent` results (`.result(value:, dialog:, snippetIntent:)` or the matching API in the iOS 27 SDK). Existing return values stay the same type so Shortcuts that consume them don't break.
- Snippet views follow the app's colors and support Dynamic Type and dark mode.

**Done when:** builds; `BrowserTests/AgentSnippetTests.swift` covers the `run` URL route (valid UUID accepted; anything else rejected) and the snippet view-model text truncation.

---

## Phase 5: Spotlight entities

**Entities** (`Browser/Intents/BrowserSpotlightEntities.swift`, `Browser/Intents/BrowserSpotlightIndexer.swift`):

| Entity | Source | Indexed | Open action |
| --- | --- | --- | --- |
| `BookmarkEntity: IndexedEntity` | `browser_favorites` + folder paths (`BrowserIntentEntityStorage`) | yes | `OpenBookmarkInVortyraIntent: OpenIntent` opens the URL in a new tab |
| `AgentTaskEntity` (existing) → also `IndexedEntity` | `AgentTaskStore` | yes | `OpenIntent` that queues the saved task (same path as `RunSavedAgentTaskIntent`) |
| `OpenTabEntity: AppEntity` | live non-private tabs from `BrowserSession` | no (tabs are volatile) | `SwitchToTabIntent: OpenIntent` |
| `HistoryEntity: IndexedEntity` | `HistoryStore` | **only if** the new setting "Show history in Spotlight" is on (default off) | open URL in a new tab |

- Reading list: if Vortyra stores its own reading list, add a `ReadingListEntity` the same way; if "Save to Reading List" uses Safari's system list, skip it and say so in the report.
- `BrowserSpotlightIndexer` (`@MainActor`): `reindexAll()`, `index(bookmark:)`, `remove(bookmarkIDs:)`, etc., using `CSSearchableIndex.default().indexAppEntities` / `deleteAppEntities`. Call it after bookmark add/move/remove, saved-task save/update/delete, history record/clear (when enabled), and once on launch (debounced, background priority). Clearing history or turning the setting off deletes all history entities.
- Settings (`BrowserSettingsView`): a "Spotlight" section with toggles: Bookmarks (on), Saved tasks (on), History (off). Turning one off deletes those entities.
- Private browsing never indexes anything. Titles and URLs are bounded (240 and 2,048 characters).

**Done when:** `BrowserTests/SpotlightEntityTests.swift` covers entity mapping from stored data, the history opt-in default, private exclusion and deletion on toggle-off (inject a fake index client protocol; do not call the real `CSSearchableIndex` in tests).

---

## Phase 6: Apple Intelligence browser schemas

The iOS 27 SDK defines `AppSchema` browser schemas (the older `AssistantSchemas` is deprecated): intents `createTab`, `switchTab`, `closeTabs`, `bookmarkTab`, `bookmarkURL`, `openBookmark`, `deleteBookmarks`, `findOnPage`, `openURLInTab`, `clearHistory`, `createWindow`, `closeWindows`; entities `tab`, `bookmark`, `window`, and on iOS 27 `tabGroup`, `readingListItem`; `.system.searchInApp` replaces `search`. Check the exact spelling in `AppIntents.framework/.../arm64e-apple-ios.swiftinterface` (search `extension AppIntents::AppSchema.AppIntents::BrowserIntent`).

- Add **new** schema-conforming types in `Browser/Intents/BrowserSchemaIntents.swift`; do not convert the existing intents. Each new intent calls the same `BrowserIntentExecutor` commands the existing ones use.
- Entities: `@AppEntity(schema: .browser.bookmark)` on a schema bookmark entity backed by Phase 5's data, `@AppEntity(schema: .browser.tab)` backed by `OpenTabEntity` data, `@AppEntity(schema: .browser.tabGroup)` for groups (`@available(iOS 27.0, *)`).
- Intents in this order: `createTab`, `openURLInTab`, `findOnPage`, `bookmarkTab`, `openBookmark`, `switchTab`, `closeTabs`, `.system.searchInApp`, then `deleteBookmarks` and `clearHistory` (both must call `requestConfirmation` and respect private mode).
- The schema macros validate parameter names and types at compile time. Fix the shape the compiler asks for. If a schema still cannot compile after two attempts, leave it out and list it in the report with the compiler message. Do not stub a schema with fake behavior.
- `createWindow`/`closeWindows`: implement only if the app already supports multiple windows on iPad; otherwise skip and report.

**Done when:** builds; App Intents metadata extraction succeeds (no `appintentsmetadataprocessor` errors in the build log); `BrowserTests/BrowserSchemaIntentTests.swift` covers that each schema intent maps to the right `BrowserIntentCommand` using the executor's test seam, and that destructive ones require confirmation.

---

## Phase 7: page watches

**Model** (`Browser/AI/Agent/PageWatch.swift`, `PageWatchStore.swift` in the app group container next to the task store):

`PageWatch { id, title, url, mode: .text(selector: String?) | .agent(savedTaskID: UUID), interval: hourly | every6h | daily | weekly, notify: Bool, createdAt, lastCheckedAt, lastValueHash, lastValuePreview (≤ 500 chars), lastChangeAt, lastError }`. Max 20 watches. JSON document with version 1, same validation and atomic-commit style as `AgentTaskStore`.

**Checking** (`PageWatchChecker.swift`):
- `.text` mode: in the foreground, load with `BrowserAgentBackgroundLoader`; in background refresh, fetch with `URLSession` (ephemeral configuration, no cookies) and reduce HTML to visible text (strip `script`/`style`, collapse whitespace). If a selector is given, use it only in the foreground loader path. Normalize (trim, collapse whitespace, drop digits-only timestamps like `12:34:56`), hash with SHA-256, compare to `lastValueHash`.
- `.agent` mode: foreground only. Queue the saved task with a request ID, wait on the Phase 3 broker, hash the outcome.
- Respect autofill-protected origins and never use private tabs.
- On change: update the record and post a local notification (`UNUserNotificationCenter`) titled with the watch title, body "Changed: <first 120 chars of new preview>", tapping opens `webmebrowser://watch?id=<uuid>` (new route, UUID only) which opens the watch detail.

**Scheduling:**
- `BGAppRefreshTask` with identifier `com.web.me.Browser.pagewatch`: add `fetch` to `UIBackgroundModes` (keep `audio`), add `BGTaskSchedulerPermittedIdentifiers`. Register at launch; reschedule after each run for the earliest due watch. Background runs check `.text` watches only, max 5 per run, 25 s budget.
- On app activation, check due watches (all modes) after the window is ready and the agent is idle.
- `CheckWatchedPagesIntent` (App Intent, foreground): checks all due watches now and returns a summary string listing changed watches. Users can schedule it with a Shortcuts time-of-day automation.
- `WatchPageIntent`: create a `.text` watch for a URL with an interval.

**UI:**
- "Watch This Page…" in the page/tools menu where "Bookmark" and "Export PDF" live: sheet with title, interval, optional CSS selector (advanced), and a toggle to use a saved task instead.
- A "Watches" tab in `AgentTaskLibrarySheet` listing watches with last checked, last change, Check Now, Edit, Delete.
- Ask for notification permission the first time a watch with `notify` is saved.

**Done when:** `BrowserTests/PageWatchTests.swift` covers: store limits and decoding, normalization (timestamps ignored, whitespace collapsed), change detection, due-date calculation, background-mode skipping `.agent` watches, the `watch` URL route, and no private-tab use. Use an injected fetcher and notifier.

---

## Phase 8: widget extension and controls

**Project change** (Ruby script kept at `.codex-checkpoints/agent-expansion/add_widget_target.rb`, run once):
- Add an app extension target `VortyraWidgets` (product type `com.apple.product-type.app-extension`, extension point `com.apple.widgetkit-extension`), bundle ID `com.web.me.Browser.Widgets`, deployment target 26.0, same team, `SKIP_INSTALL = YES`, its own `Info.plist` with `NSExtension.NSExtensionPointIdentifier = com.apple.widgetkit-extension`, entitlements file with the app group `group.com.browser.app`. Embed it in the `Browser` app ("Embed Foundation Extensions"). If the Mac Catalyst build complains, set the embed build file's platform filter to iOS.
- Source folder `VortyraWidgets/` as a synchronized root group for the new target.
- No shared source files (revised 2026-10-15). The widget reads the app's JSON files directly with its own small read-only `Codable` readers (saved tasks: `AgentTasks.<app bundle id>.json` → `savedTasks[].id/title`; watches: `PageWatches.<app bundle id>.json` → the fields the widget shows). The app bundle ID is the widget's bundle ID without the trailing `.Widgets`. Both files live in the `group.com.browser.app` container.
- Verify with `xcodebuild -list` and a full build. Back up `project.pbxproj` to `.codex-checkpoints/agent-expansion/project.pbxproj.before-phase8` first.

**Controls** (iOS 18+ `ControlWidget`):
- **New Private Tab**: `ControlWidgetButton` with `OpenURLIntent(webmebrowser://private-tab)`.
- **Search Clipboard**: `OpenURLIntent(webmebrowser://search-clipboard)`. The app puts the clipboard text into the address/search field and focuses it; it never searches automatically, so a web page that opens this link cannot send the clipboard anywhere.
- **Run Saved Task** (configurable): `AppIntentControlConfiguration` with `SelectSavedTaskControlIntent: ControlConfigurationIntent` whose parameter is a widget-side `SavedTaskOption` entity read from the shared store; action `OpenURLIntent(webmebrowser://saved-task?id=<uuid>)`.
- App side: add the three routes to `AgentIncomingURLRouter`. `saved-task` only accepts a UUID that exists in the user's store and queues it exactly like `RunSavedAgentTaskIntent` (all approvals still apply). Unknown IDs show "That saved task no longer exists."

**Widgets:**
- **Saved Tasks** (small/medium): up to 4 saved tasks as `Link`s to `webmebrowser://saved-task?id=`.
- **Page Watches** (medium): up to 4 watches with last change time and a changed badge, linking to `webmebrowser://watch?id=`.
- The app calls `WidgetCenter.shared.reloadAllTimelines()` and `ControlCenter.shared.reloadAllControls()` after saved-task or watch changes.

**Done when:** the app with the embedded extension builds for the simulator; `xcodebuild -list` shows the new target; `BrowserTests/WidgetRouteTests.swift` covers the three new URL routes (valid and invalid input). The supervisor checks the controls appear in the simulator's control gallery.

---

## Phase 9: research in tabs

Builds on the existing research preset (`fetch_page`, `compose_comparison`, comparison exports).

- New agent tool `open_sources_in_group` (data/research bundle only): arguments `{ groupTitle: String, urls: [String] (max 8) }`. Creates a tab group with that title and opens each HTTP(S) URL in it, in the background; never in a private window; asks no approval (it only opens pages). Add it to the tool catalog and to the Phase 1 catalog test's expected list (the only allowed change to that list).
- Update the research preset's instructions so that, when the user asks to "research … in tabs" or "open the sources", the model calls `open_sources_in_group` after picking sources.
- `ResearchTopicIntent` — title "Research a Topic". Parameters: `topic: String`, `openSourcesInTabs: Bool` (default true), `makePDF: Bool` (default true), `timeoutSeconds` (default 300). Builds a task string like "Research <topic>. Compare the most relevant sources, open them in a tab group named <topic>, and export a PDF report." and runs it through the Phase 3 wait path. Returns the `AgentRunResultEntity`.

**Done when:** `BrowserTests/ResearchTabsTests.swift` covers argument validation (max 8, HTTP(S) only, title bounds), that the tool is unavailable outside the research/data bundle, and the intent's generated task text.

---

## Phase 10: teach mode (record and replay)

Replay goes through the agent so every safety gate still applies. There is no raw, unsupervised replay.

**Recording:**
- `AgentTaskRecorder.swift` + `AgentTaskRecorderScript.swift`: a user script injected into an isolated `WKContentWorld` only while recording, capturing `click`, `change`, `submit` and top-level navigations. Each step: `{ kind: click | input | select | submit | navigate, label (accessible name or visible text, ≤ 120 chars), role, selectorHint (≤ 300 chars), url, value? }`.
- `value` is recorded only for plain text, search and select inputs. For password, email, tel, credit-card, one-time-code, hidden inputs, or any field the existing sensitive-field detector flags, record `value = nil` and `needsUserInput = true`.
- Recording is disabled in private tabs. Max 60 steps. A visible "Recording — Stop" banner while active.
- Entry point: "Record a New Task" in `AgentTaskLibrarySheet`. On Stop, open the existing save editor prefilled with a generated title and a task text that summarizes the steps.

**Storage:** `SavedAgentTask` gains `recipe: [RecordedStep]?` (optional; old data decodes). Respect a 64 KB per-recipe limit.

**Replay:** when a saved task with a recipe runs, the agent's task text gets an appended section: "Follow these recorded steps in order. Match each step to the current page by its label and role. If a step needs user input, ask with ask_user. If the page differs, adapt or ask." followed by the numbered steps. No new tools.

**Done when:** `BrowserTests/TeachModeTests.swift` covers: sensitive values never recorded (feed the recorder script fixture events through the existing page-script test harness), step limits, recipe Codable round-trip and old-document decoding, replay prompt text, private-tab refusal.

---

## Phase 11: hand results to other apps

Everything is prepared for the user, who confirms or sends.

- `AgentResultHandoff.swift`: an action row under a finished agent reply in `AISidebar` and in `AgentRunDetailView`: **Add to Calendar**, **Add Reminder**, **Email**, **Message**, **Share**.
  - Calendar: `EKEventEditViewController` prefilled (title = task title, notes = outcome + sources, date from the first `NSDataDetector` date in the outcome, else none). On iOS 17+ this needs no calendar permission; do not request any.
  - Reminder: request reminders access only when tapped (`NSRemindersFullAccessUsageDescription` added to `Info.plist` with a clear reason), then create an `EKReminder` with the title and a due date from the detector, after a confirmation sheet showing what will be saved.
  - Email: `MFMailComposeViewController` with subject, body and the run's exported files attached; if Mail isn't set up, fall back to the share sheet.
  - Message: `MFMessageComposeViewController` with the outcome text; fall back to the share sheet.
- Agent tools (core bundle): `prepare_calendar_event { title, start?, end?, notes? }`, `prepare_reminder { title, due? }`, `prepare_email { subject, body, attachExports: Bool }`. Each only **presents** the system sheet after the run finishes; the agent never sends. Add them to the catalog test's expected list.
- Private runs: the row is shown, but nothing is prefilled from page sources.

**Done when:** `BrowserTests/ResultHandoffTests.swift` covers date detection, prefill text, attachment selection (run exports only), and that the tools only queue a presentation request.

---

## Supervisor gate per phase

1. Read the agent's report and the diff (`git diff --stat`, then the full diff of changed files).
2. Check the phase rules, especially the safety model, scope and persistence compatibility.
3. Build for testing, run the phase's focused tests, then the full suite. Compare to the baseline.
4. If something fails: send the agent the exact errors to fix (up to two rounds), otherwise fix it directly.
5. Commit `Phase N: <name>` locally with a tag `checkpoint-vortyra-agent-expansion-phaseN`.

## Out of scope

Pushing, TestFlight builds, physical-device runs, real-model end-to-end runs (they need signing and accounts), Gmail/Outlook APIs, and any change to the blocker, MLX, translation or reader engines.
