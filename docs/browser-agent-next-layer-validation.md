# Browser agent next layer: implementation and verification

Status: implementation and verification complete, with the runtime limits documented below. A1 through E2b passed their phase gates. The final full suite preserved all 94 baseline passing tests and had no new failures. The unsigned iOS device build succeeded, and the final Simulator UI checks passed.

The implementation follows `/Users/johnval/.devin/plans/plan-01641e80bb8c7482.md` in this checkout. GPT-6 Luna implements one phase at a time; the supervising agent reviews the source and runs the checks before accepting it.

## Baseline and preservation

The checkpoint is `/private/tmp/vortyra-agent-next-layer-20261010T030400Z`. It contains the source copy, hashes for 320 files, the pre-existing Git changes, the approved plan, and all 47 original tool definitions.

The full baseline BrowserTests run had 95 tests: 94 passed and one failed. The pre-existing failure is `AIResponseCanvasTests/testRedditReductionGroupsRetainAllPartialSummaries`. Its grouping/whitespace assertions failed before the next-layer edits. The test and its implementation are outside this change.

Preservation checks compare source hashes, original tool definitions, and regression results against this checkpoint. Changes already present before the checkpoint are part of the baseline.

## Phase checks

| Phase | Result | Evidence |
| --- | --- | --- |
| A1: gap tools | Accepted, 63 tests passed, none failed or skipped | `A1-final-tests.xcresult` |
| A2: questions, background fetch, bundles | Accepted, 77 tests passed, none failed or skipped | `A2-final-tests.xcresult` |
| B: Apple engines and screenshot vision | Accepted after source review, behavioral repairs, and Simulator UI checks. Final readiness checks: 18 passed, 0 failed, 2 explicitly skipped | `B-final-readiness-tests.xcresult`; broader guard checks: `B-runtime-guard-tests.xcresult` (61 passed, 0 failed, 1 skipped) |
| C: research and site permissions | Accepted after trust, privacy, stale-approval, routing, and export review. Broad run: 127 passed, 2 new export-test failures, 2 known runtime skips. Both repaired export checks then passed | `C-final-tests.xcresult`; `C-export-confirmation-tests.xcresult` (2 passed, 0 failed or skipped) |
| D: private autofill | Accepted after source, native approval/privacy, service egress, research-preservation, and Simulator authentication-UI review. Broad D2 run: 188 passed, 1 new lifetime-fixture failure, 2 known runtime skips; follow-up repaired the fixture and verified decline/Stop/stale approval | `D2-final-confirmation-tests.xcresult`; `D2-final-privacy-tests.xcresult` (lifetime and decline/Stop passed); `D2-stale-approval-confirmation-tests.xcresult` (1 passed) |
| E1: task storage and Shortcut handoff | Accepted after compilation, actor-isolation, Unicode-limit and storage-validation repairs. 18 checks passed in the broad run; the repaired write-failure fixture then passed | `E1-repaired-tasks-tests.xcresult`; `E1-write-confirmation-tests.xcresult` (1 passed) |
| E2a: immutable completion and queue readiness | Accepted. Broad run: 62 passed and 1 new timing-fixture failure; the repaired full-log check then passed | `E2a-repaired-completion-queue-tests.xcresult`; `E2a-full-log-confirmation-tests.xcresult` (1 passed) |
| E2b: task/history UI and native launch integration | Accepted after source review, first-tap save repair, navigation/task checks, and native Simulator library, Shortcuts and URL-scheme checks | `E2b-navigation-task-routing-tests.xcresult` (34 passed); `E2b-repaired-navigation-tests.xcresult` (7 passed); `E2b-save-presentation-tests.xcresult` (2 passed) |

The result bundles and per-phase source snapshots are in the checkpoint directory. Each phase must pass its checks before the next begins.

E1 adds only four new files after D. Task/history files and the pending-task defaults key use the actual bundle ID, separating the development Test app from the main app. Writes publish only after success; corrupt or semantically invalid files retain their bytes and displayed state. The queue preserves up to eight requests in order and rejects replayed UUIDs. Private history does not construct or read the persistent store. E1's 19 checks cover those behaviors, including separate defaults clients and Unicode byte boundaries. The write-failure repair injects a failure at commit, after a valid read, and checks failed save, update and delete leave the file and arrays unchanged.

Xcode's extracted App Intents metadata contains both `RunAgentTaskIntent` and `RunSavedAgentTaskIntent`, their App Shortcuts, and the saved-task entity. Both intents are foreground-only; the entity exposes display metadata. The E1 native Simulator check listed Vortyra's “Run browser task” action (`E1-shortcuts-discovery-runtime.jpg`). With no saved tasks, its parameterized saved-task tile was absent. Saved-entity discovery and actual handoff execution were subsequently verified in E2b, as recorded below.

E2a captures immutable completion data before clearing run state and retains the existing chat callback order. Native checks cover Stop, delayed return from an old run, private tab metadata even with a persistent WebKit store and failed adapter setup, and zero history-provider calls for that private completion. A twelve-scroll test proves the stored log retains every action while the existing chat summary still displays eight plus “+4 more.” Only that test's deadline changed to 20 seconds; its shared helper and production timing remain unchanged. Queue checks retain requests while inactive, missing a browser view, or busy, and retain the FIFO head when consumption cannot be written. A history replay carries no fabricated saved-task ID.

E2b adds the Tasks/History sheet, native run/edit/delete/run-again controls, and Save Run as Task on the exact completed assistant reply. The first Simulator save tap initially opened an empty library instead of the prefilled editor. The repair carries the draft and presentation mode together in an identifiable sheet payload; a new assertion and the actual first-tap flow both pass. Cancelling a draft, creating another task, and editing an existing task clear the original reply association.

Starting-page loads use a separate request-scoped navigation method; the original `navigate(to:in:)` remains byte-identical to the accepted E2a version. Startup binds the exact WebView, tab and WKNavigation, accepts its server redirects, and checks the final document again immediately before dispatch. Native tests cover superseding navigation, changed WebView/tab/document revision, inactive state, FIFO acknowledgement and initial cancellation before metadata changes. The deferred content-blocker cancellation path is source-reviewed and has policy coverage; it has not been forced through that delay in the Simulator UI.

The final phase scope check found all 320 baseline files present: 301 unchanged and 19 changed for the planned agent work. All 47 original tool definitions are exact matches; 17 additions bring the total to 64. The Xcode project, all existing entitlements, bundle/version settings, PageTranslator and the baseline failing canvas test remain unchanged.

C keeps ordinary web-search commands on their existing route and adds the research preset for explicit multi-source work. Site permissions match the exact host and eligible action reason, and never bypass sign-in, payment, sensitive-field, download, tab-close, or autofill approvals. Private runs do not read or write the trust store. Approval IDs and isolated-world target tickets reject changed documents, elements, forms, and stale cards. All 47 original tool definitions remain unchanged.

The two C export failures were new fixture expectations, not lost PDF content. The comparison export contains the authored comparison and source metadata, while the fetched-source report contains the source body. Root rendered both PDFs and checked a second PDF text extractor: the original sentinel was intact. iOS 27 PDFKit reordered underscore glyphs in extracted text, so the new fixture uses an exact alphanumeric sentinel. The existing renderer was preserved; the PDF and extracted-text attachments remain in the result bundles.

D's controller review covers dedicated Keychain storage, authentication cancellation, one-time approval, field/label/document binding, focus escalation, and safe cross-tab metadata. The supervising review rejected a shared agent controller, restored the original per-sidebar ownership, retained the exact original form-risk code, and split the new DOM fixtures from the existing regression fixture. The disabled-country repair checks that the fill skips the disabled option and leaves the browser's original selection unchanged. Profile data stays native; model context from an autofilled tab is withheld.

D's final gates cover ordinary query/summary dispatch, selections, cached and stored context, delayed extraction, web-provider sends, queued service requests and recent model history. Background reads remain usable for unrelated origins; affected-origin reads and redirects are blocked for the exact website data store. Weak origin records preserve the existing lifetime of private stores. The repaired lifetime fixture compares against WebKit's no-ledger control instead of mistaking WebKit teardown retention for a ledger reference. Stale form/document approvals reject before authentication or profile access and report the changed page clearly.

The D Simulator check showed the Autofill Profile settings entry and native passcode authentication requirement. Authentication was cancelled without unlocking a profile; settings remained usable. Positive profile storage and fills use injected synthetic authentication/Keychain clients in the native tests. The only Info.plist change is the required Face ID usage description. All 47 original tool definitions remain unchanged (64 tools now).

The B review repaired compile errors, overly short WebKit test waits, schema-fixture assumptions, screenshot ownership/cleanup races, Local context sizing, and Stop-button visibility. All 77 A2 checks passed in the broad B behavioral runs. The final outstanding schema assertion passed in `B-schema-final-tests.xcresult`; subsequent model readiness changes passed the focused checks above.

Manual testing exposed two Simulator framework mismatches: the new Apple image attachment and session-profile APIs crashed despite nominal availability, and Local reported availability with context size zero while its legacy generation probe failed. Simulator Apple image/PCC paths are therefore unavailable, and Local zero-context readiness is rejected. The UI now reports these requirements without crashing. Positive Local contexts keep their exact reported size and budget checks; supported device code remains enabled. The temporary diagnostic probe was removed from permanent tests; its evidence remains in `B-legacy-local-probe-tests.xcresult` and its build log.

## Runtime coverage

Verification uses the isolated iPhone 18 Pro iOS 27 Simulator. Before B, the browser page and existing AI sidebar rendered successfully. This is UI smoke evidence, not proof of a real model completing a task.

Real ChatGPT Plan, Apple Local, and PCC generation must be reported separately from fake-engine tests, compilation, and Simulator UI checks. Local native token measurement and Apple image construction are explicitly skipped on this unsupported Simulator runtime. PCC requires an eligible physical device for the plan's runtime check; no physical-device installation is part of this verification run.

The B ChatGPT Plan smoke check reached the explicit sign-in requirement; this Simulator has no authenticated ChatGPT Plan session. Its transport and tool loop are covered with injected test turns, but an authenticated model completing a task has not been verified here.

The E2b Simulator library check saved a disposable task, edited its title while preserving instructions and website, ran it through a server redirect, displayed its history, and ran a history entry again. The native tests also cover atomic deletion and failed writes. The native UI delete button has not been exercised.

Shortcuts initially discovered both actions and the saved entity, but saved-action execution and App Shortcut tiles failed. The system log showed `linkd` rejecting the ad-hoc Simulator signature because its Team ID was absent, immediately before the unregistered-entity error. Exact runtime type/conformance/getter probes passed, and disabling debug dylib did not repair it. Root then development-signed only a disposable Simulator artifact with the existing identity, retaining the app's bundle ID and entitlements. The same configured saved action reached `RunSavedAgentTaskIntent.perform()`, foregrounded Vortyra and followed its saved redirect. Both catalogue tiles appeared and worked; the free-task tile prompted for Task. No intent, signing-setting, identity or entitlement source changes were required. The temporary diagnostic test was removed; its result bundles and source are retained in the checkpoint.

After the full suite, root repeated the free and saved App Shortcut tile flows on a development-signed copy of the final default Debug build, including its normal debug-dylib layout. Both dispatched successfully after indexing refreshed; saved task data remained intact. This confirms no debug-dylib project change is needed. The final URL handoff also showed its queued acknowledgement and then dismissed it. Luna's repair changed only that successful-enqueue call to use the existing 2.5-second timeout; persistent error and waiting messages were preserved. Evidence: `final-default-saved-shortcut-success.jpg` and `final-deeplink-toast-dismissed.jpg`.

Safari's `webmebrowser://agent` handoff was exercised with controlled loopback fixtures. A connection failure showed the explicit starting-page error without adding an agent run or history entry. A subsequent five-second page load completed and dispatched the exact `QA URL slow + & café` instruction, showing the queue remained usable after failure. Ordinary Back navigation returned to the landing document. These runs reached the model sign-in requirement, rather than completing a real model request. Evidence includes `E2b-saved-shortcut-handoff-success.jpg`, `E2b-shortcuts-tiles-success.jpg`, `E2b-free-shortcut-tile-handoff-success.jpg`, `E2b-deeplink-navigation-failure.jpg`, `E2b-deeplink-slow-Unicode-success.jpg`, and `E2b-shortcut-URL-run-history.jpg`.

Agent mode retained its existing on value through those handoffs. Automatic approval review rejected the attempted off-mode toggle because this verification must preserve the preference; no toggle occurred. The off-mode handoff path is source-reviewed, but its native UI case is unverified. No physical-device app was installed or changed during these phase checks.

## Examples to try on a build containing this plan

Open a normal webpage, choose an authenticated ChatGPT Plan session or an eligible Apple backend in the AI assistant, and enable Agent mode. `/do` forces a page-action request; ordinary questions keep their normal chat route. Full research and the browser-library actions use ChatGPT Plan or eligible PCC. Local provides a smaller set of basic page actions when its model and context are available.

| Try | Example instruction | What to expect |
| --- | --- | --- |
| Page navigation | `/do Go back, go forward, then reload this page.` | Existing and added navigation actions use the active page. |
| Keyboard and field inspection | `/do Inspect the search box, type sample, then press Enter.` | Field details and keyboard behavior; protected forms still require approval. |
| Checkbox | `/do Uncheck Subscribe for updates.` | The requested state is set once, rather than toggled blindly. Use a disposable test form. |
| Overlay and hiding | `/do Dismiss the cookie banner using its reject option.` Then `/do Hide the newsletter overlay.` | Safe dismissal; hiding asks for approval. |
| Browser tools | `/do Search my browser history for Apple.` Then `/do Use the desktop version of this page.` | History is excluded in private runs; desktop preference reloads the page. |
| Split and close | `/do Open https://example.com in split view beside this tab.` Then `/do Close this tab.` | Split presentation; closing asks for approval and refuses the last tab. |
| Clipboard | `/do Copy the page title to the clipboard.` | Copies the selected result. |
| Ask before continuing | `/do Find the available options on this page, then ask me which one to use.` | An in-sidebar question with Send/Skip; Stop cancels the waiting question. |
| Background fetch | `/do Fetch https://example.com and summarize its readable text.` | A read-only offscreen fetch. |
| Screenshot | `/do Take a screenshot and describe the layout.` | Image context when the selected engine supports it; an explicit requirement otherwise. |
| Research and export | `Research accessibility guidelines across three official sources and return a comparison table with source links. Export the comparison as a PDF.` | Research preset, sourced result and the existing export workflow. |
| Private autofill | `/do Fill the name and address fields from my private autofill profile. Do not submit.` | Configure the profile in Settings → AI → Autofill Profile first; native authentication and fill approval remain required. Profile values stay out of model input. |

For eligible approval reasons, the approval card offers “Always allow on this site.” Revoke saved permissions in Settings → AI → Agent site permissions. Sign-in, sensitive fields, payment, deletion, downloads, tab-close and autofill keep their approval requirements.

After an agent run finishes, tap **Save Run as Task** on its reply. Open **Saved agent tasks and history** to run, edit or delete the task, create a new task, or replay a history record. Private runs do not create history or a Save control. A starting website is loaded and settled before the task begins.

In Apple Shortcuts, search Vortyra's **Run Browser Task** or **Run Saved Browser Task** action. Set Task/Starting Website or choose a saved task, then run it. The app comes to the foreground and continues through the same queue. A URL-scheme example is `webmebrowser://agent?task=Read%20the%20page%20title&url=https%3A%2F%2Fexample.com`.

## Final results

The final full run is `final-confirmation-full.xcresult`, with ordinary Debug project settings and no test skip flags. It ran all 228 tests: **225 passed, 1 failed, 2 skipped**. The failure is the unchanged baseline `AIResponseCanvasTests/testRedditReductionGroupsRetainAllPartialSummaries`; the suite therefore reports failure, even though the comparison finds no added failure or regression.

`final-confirmation-full-original-test-comparison.json` confirms all 95 baseline tests were present, all 94 previously passing tests still passed, the one previous failure remained, and there were zero new failing tests. The two explicit Simulator skips are `testAppleVisionToolOutputPromptCarriesImageAttachment` and `testNativeTokenizerAcceptsCompactLocalTitleClickAndTypeRequestsWithinOutputReserve`. Their supported-device code compiled in the final device build; successful device runtime behavior remains unverified.

The first complete run (`final-full.xcresult`) had the same 225/1/2 result. The full suite was repeated after the single toast repair, then the production and test source hashes were checked against the final pre-test manifest. No compiled source changed afterward. The final scope/tool reports retain all original files and tool definitions, with no project, identity, version, signing-setting or entitlement edits.

The generic iOS device build used `CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`, and succeeded with Xcode 27/iPhoneOS 27.0. Its extracted metadata contains both intents and the saved-task entity. This is compilation evidence only; the device artifact was not signed for distribution or installed. Evidence: `final-device-compile.log` and `final-device-compile-summary.json`.

All result bundles, source snapshots, scope comparisons, diagnostic logs and runtime screenshots are retained in `/private/tmp/vortyra-agent-next-layer-20261010T030400Z`. The loopback QA server was stopped after verification. The work is left uncommitted in this checkout. The M1 installation was not updated during this implementation/verification run.
