# Editing, terminal, Git and localhost benchmark

`RuntimeWorkflowBenchmarkTests` exercises Computa's production Swift runtime,
the verified bundled App Server, the local Responses bridge, native
`apply_patch`, `exec_command`, and `write_stdin`. Only the website's model replies
are scripted. Filesystem changes, reported command exit codes, terminal
sessions, Git commits, pushes and HTTP requests are real. Process termination
is verified separately from command success.

The same workflow runs with ChatGPT's canonical `chat/latest/medium` choice,
`browser/gemini` and `browser/claude`. Every inference request must retain the
requested model ID. The ChatGPT fixture supplies an explicit synthetic plain
GPT family, Medium power and highest-offered-family proof; it does not observe
the live website.
This checks provider routing and tool composition with scripted inference. It
does not test website sign-in, selection of a concrete website model, the
model's own judgment, or live website session cleanup. Those require separate
qualification of the installed app and selected provider/model pair.

A separate [local-model goal comparison](GOAL-MODE-BENCHMARK.md) records the
completed build 39 and build 44 comparisons. All six trials in each comparison
failed the complete task; Computa goal mode was N/A. These results do not
establish a product ranking.

## Installed validation and history

Build 41 passed 2,261 native tests and 622 public tests with zero failures;
49 native opt-in tests were explicitly skipped. Its signed package and installed
bundle passed exact resource, signature and source checks, and the new running
process was recorded. This did not qualify live website behavior.

The first installed ChatGPT GPT-6 qualification failed before any native tool
call: the expanded first user message differed from the submitted prompt by
18 characters after ASCII whitespace normalization. One inference was sent;
its website cleanup remains unconfirmed. The failure and original evidence are
retained, and the prompt was not replayed.

Build 42 encodes literal backticks inside the complete request JSON as Unicode
escapes and describes the response fence without literal backticks. Parsed
request values, tool grammar, custom patch text and ownership checks remain
unchanged. A regression reproduces an 18-character Markdown delimiter loss and
rejects it; the escaped request passes the same strict check and still rejects
changed content. A fresh installed ChatGPT GPT-6 marker-read task now passes. The encoding
change resolves this controlled case; broader provider workflows remain pending. Focused validation passed 69 Swift and 365 adapter tests.
The seven public groups then passed 623 tests without failures or skips;
complete native validation passed 2,263 tests with zero failures and 49 opt-in
skips in 527.297 seconds.

| Check | Current evidence and remaining work |
| --- | --- |
| Upstream runtime | Source19/20 observations cover 19,035 runnable identities: 19,032 passed and three standalone TUI cases failed. Optional guard exits do not prove skipped assertions. Source21 compiled all 275 debug test binaries and passed scoped lint and formatting. This is not a green complete upstream workspace result. |
| Engine package | Source21 release packaging passed. The signed arm64 App Server, source pin, patch and manifest match runtime mactopus-6. Build 59 reuses these unchanged artifacts. |
| App validation | Build 66 passed 2,318 native and 644 public tests with zero failures; 49 native opt-in cases were explicitly skipped. All 414 frozen inputs, the unchanged engine, 52 browser-session tests and 26 cleanup identities verified. Signed staging and installed bundle checks each passed 98 checks. Installed inspection usability and provider workflows are separate gates. |
| Installed provider tasks | Claude Sonnet 5.5 passed build 43 coding and flight-browser cases, then build 48 marker, localhost composition and interactive-session cases. The latter cases closed twelve and five website leases. Corrected, controlled graders accept PTY Ctrl-C echo, post-stop read-only shutdown checks and exact replies in Markdown code spans; original failed grades and immutable traces remain. ChatGPT build 44 coding/Git passed with a verified local bare-origin push. Build 48 marker qualification passed; its browser case reached search/details navigation before an adapter inspection timeout, with eleven leases closed and its local server independently stopped. Gemini build 48 recovered through the explicit prompt-free model refresh and passed a fresh marker qualification with two closed sessions. Its coding case then hit the 45-second preparation deadline before submission or tools; its single startup session closed with reason not_created. Seven workflow cases remain incomplete. The full current live matrix is not qualified. |
| Build 49 live tasks | Fresh marker qualifications passed for ChatGPT GPT-6, Gemini 3.1 Pro and Claude Sonnet 5.5, each with two verified closed leases. Gemini coding completed an initial terminal read, then a second-inference preparation timeout; no edits or commit occurred, and both leases closed. ChatGPT browser use executed nine native actions and reached search/details before another adapter inspection timeout; ten leases closed and its owned HTTP server independently stopped. Claude composition completed initial project reads, then hit a website usage limit before starting the preview; all three leases closed. The original collectors' missing-effect errors remain failures, with separate finite failure/cleanup projections. A subsequent normal Gemini browser tab showed Google's unusual-traffic CAPTCHA. No CAPTCHA action or model replay was performed. The DOM batching change is offline-validated but has not resolved these live failures. |
| Build 51 live tasks | ChatGPT GPT-6 passed marker qualification with 39 checks and two closed leases. Its browser case completed eight native actions and read search results, then hit another inspection timeout before details or a final answer. All nine leases closed and the owned HTTP server independently stopped. The snapshot had no accepted adapter phase, a 10,431 ms operation age and no pending native clock. This does not distinguish JavaScript dispatch failure from receipt rejection. The native clock is offline-validated but the live failure remains. |
| Build 52 live tasks | ChatGPT GPT-6 passed marker qualification with 39 checks and two closed leases. The browser case recovered from one invalid snapshot identifier and executed nine successful browser actions, then timed out before details or a final answer. All eleven leases closed and the owned HTTP server independently stopped. The timeout received zero phase diagnostics despite three DOM notifications during the operation and current origin/generation. WebKit logs show evaluation entry 14.007 seconds after enqueue, later than the ten-second native timeout. The website workload responsible for that delay is unknown; this run remains a failure. |
| Build 53 live tasks | ChatGPT GPT-6 passed a fresh marker qualification with 39 checks and two closed leases. The browser case executed ten successful actions with five page reads, searched once for the correct flight and reached its details page. The inspection failure did not recur in this run. It remains a failed benchmark: the model ended without pressing the observed enabled control to reveal the requested gate. Three outcome checks failed; all eleven leases closed and the owned HTTP server independently stopped. The original failure and fixture are retained. |
| Build 55 live tasks | ChatGPT GPT-6 passed a fresh marker qualification with all collector checks and four closed leases. It recovered from two reads of an incorrect path and returned the exact marker after reading the submitted path. The browser case opened the fixture and read its landing page three times, then requested an unoffered tool. That reply dispatched no calls. The case failed before search/details or a final answer; all five leases closed and the owned server independently stopped. The rejected tool name was not captured, so the exact mismatch is unknown. |
| Build 57 live qualification | ChatGPT GPT-6 produced a verified website reply, but no response or tools were released: the cleanup summary cache had reached its 256-task limit. Its exact closure was already synced and read back in the per-turn journal; failure to create an optional summary caused the save to report failure. The failed qualification and original evidence remain preserved. Build 58 addresses that cache-capacity result. |
| Build 58 live tasks | Fresh ChatGPT GPT-6 qualification passed: a real terminal read returned the exact fixture marker and both inference leases closed durably without a new summary slot. Its browser case executed fourteen calls, including ten reads and a field fill rejected for a stale snapshot. It failed at a later thirty-second model-page inspection before search, details or a final answer. All fourteen leases closed and the owned HTTP server independently stopped. The failed grade, fixture and sealed evidence remain; no prompt was replayed. Seven workflow cases remain incomplete. |
| Build 59 | The final ChatGPT model/product context recheck is combined only after first-message binding; pending appends and replacement recovery retain independent checks. A controlled handoff delay expires the old source's shared inspection budget and passes with the change. Full validation passed 2,295 native and 637 public tests with zero failures and 49 explicit native skips. All twelve new/existing context, drift, binding and deadline controls passed in the full run. Signed staging and installed verification each passed 98 checks. Fresh ChatGPT GPT-6 marker qualification passed with two durably closed leases. The browser case completed four calls without a transport error, but ended before following the observed search link. Its missing search/details/final outcome remains a failure. All five inference leases closed and its owned HTTP server independently stopped. Seven workflow cases remain incomplete. |
| Build 59 composition and Gemini | ChatGPT composition completed a real project-file listing, then returned a capability refusal before starting the preview. Both leases closed durably; no preview server was started. The original collector errors on the absent preview address; a separate failure projection preserves this as a failed workflow. A normal Gemini page showed signed-in 3.1 Pro without a CAPTCHA, but its saved verification checkpoint still blocked qualification before submission. No lease was acknowledged or tool called. Its unconfirmed startup receipt could not be persisted because the 256-task summary cache is full; transaction-linked cleanup still persists. Gemini testing stopped. Its startup, failure and absent-cleanup evidence are preserved without replay. |
| Build 63 read recovery | One actual inspection timeout can get a fresh read only after temporary-session ownership and first-message lineage are bound. The original response deadline and current model/Chat-mode checks remain. Insertion, Send, selection and expansion cannot replay. Four queue-delay controls passed; the old source fails the recovery control. An older ten-second immediate-failure expectation was updated to reject a late reply at the original response deadline. Its original complete failed run is retained; the final complete run is green. |
| Installed diff UI | Build 44 passed split/unified/wrapped presentation, hunk collapse, selective staging/unstaging/reverting, stale-snapshot rejection, binary notices, filtering and read-only branch/commit comparisons. Independent Git/file snapshots verify preservation. A scope selection after switching chats changed the dropdown without changing native state. A native commit-event regression reproduces that failure. Installed build 45 now passes all four scope selections, including Unstaged after switching chats; independent before/after snapshots prove that this recheck changed no fixture files or Git state. |
| Model comparison | All six fresh build 44 trials are complete and failed the full task. They use the same pinned local model and actual Full access settings in both products. Both Computa ordinary trials stopped at the receipt compaction bounds. Codex ordinary r1 and both goal trials stopped on unadvertised generated tool calls; ordinary r2 stopped on missing generated public output. Computa goal mode remains N/A. The twelve owned project/origin directories were verified against their archive and removed. |
| Delivery | Build 66 is signed, installed and pushed as 63fe9af to draft PR #5. Its runtime identity and default-off inspector toolbar state verified. Four single-send human controls failed: original GPT-6 Pro temporary chat, the same control after normal app restart, GPT-5.6 Sol temporary chat, and GPT-6 Pro ordinary chat. Each correlated native failure is NSURLErrorDomain -1000 with underlying POSIX EINVAL; the original Inspector control identified the conversation POST. Restart, family and temporary-mode changes were insufficient; the cause remains unproven. Owned tabs and inspection windows closed, Safari's developer setting returned to off, and the browser pane returned to hidden. No build-66 native provider inference ran. ChatGPT qualification and the five live workflows remain incomplete. Gemini and Claude live work remain deferred. |
| Current requested Chat selector | The user now requests Chat-only power presets—Instant, Medium, High, Extra High and Pro—with automatic selection of the highest observed enabled plain GPT family, excluding Sol and Work. This supersedes the earlier request to remove Latest as an option. “Latest” is this family-selection policy, not a literal website menu item. Empty-page structural inspection supports the selector shape; it establishes neither implementation qualification nor a network fix. |

Detailed historical failures, corrections, receipts and source attribution remain
in the [validation ledger](HARNESS-VALIDATION-NOTES.md).

## Installed fixes: 0.6.0 (43)

A captured ChatGPT reply contained a progress paragraph before a code block
with otherwise valid tool-call JSON. The strict parser rejected it. The relay
now permits a `commentary` string inside `tool_calls`: it emits a standard
Responses commentary message before the validated function/custom calls and
keeps `end_turn=false`. Fresh instructions demonstrate this format. Outside
prose, malformed commentary and disallowed calls remain rejected.

The normal Gemini page displayed both a selected model and a selected Low
thinking-effort row. The shared verifier treated that effort indicator as an
invalid model selection. A regression reproduced the failure. Recognized Low
and High effort rows now remain separate from model proof; missing,
contradictory, duplicate and unknown model indicators still fail closed.

Focused validation passed 114 Swift tests, including real App Server workflows
for all three scripted provider routes, and all 366 adapter tests. Complete
candidate validation then passed 624 public tests and 2,266 native tests with
zero failures; 49 native tests were explicitly skipped. The native run executed
2,315 tests in 509.268 seconds and retained all required permission, workflow,
patch and cleanup guards. Signed installation passed 98 checks. Fresh Claude and Gemini qualifications
passed; the Gemini check confirms model selection for that controlled task.
ChatGPT returned an inline wrapper that the strict parser still rejected.

## Installed follow-up: 0.6.0 (44)

An exact-task diagnostic captured a complete, valid JSON tool envelope enclosed
in triple backticks on one line, with `json` separated from the object by a
space. There was no surrounding prose. The parser required a newline after the
label, so it rejected the entire response before dispatching any call.

Build 44 recognizes this complete inline wrapper as well as the existing
multiline fence. It removes only the exact outer delimiters and still parses
the entire remaining JSON body. Outside prose, multiple objects/fences,
unsupported labels, incomplete or malformed JSON and disallowed calls remain
rejected. Custom patch text, including literal backticks, remains unchanged.
Fresh response instructions explicitly request newlines. A regression failed
with the old parser and passes with the change. Complete validation passed 624
public tests and 2,268 native tests with zero failures and 49 explicit native
skips. Signed installation passed all 98 checks. Fresh ChatGPT GPT-6 qualification passed all 39 checks, including a real marker-file read and two closed inference sessions.

## Reusable boundaries

- `WorkflowBenchmarkFixture` owns a unique temporary project, an isolated
  runtime home, a loopback server, a local bare Git remote, and independent
  outcome verification. Setup and verification use fixed process argument
  arrays. The benchmark workflow uses the actual offered tools.
- `WorkflowBenchmarkTransport` replaces inference only. Each continuation must
  retain the exact native tool call and one output with its matching call ID.
  The fixture refuses to emit its final success message when a preceding tool
  result differs from the expected operation.
- `RuntimeWorkflowBenchmarkTests` owns runtime events, approval decisions,
  deadlines, protocol identity checks, timing and cleanup. It observes actual
  patch and command receipts before checking final files and remote Git state.

The workflow also configures the built-in browser controller before creating
its thread, matching the app's startup composition. The full native/browser
dynamic-tool list must use canonical `type: "function"` definitions, contain
all nine browser tools and the native app/outcome tools, and be accepted by the
real pinned App Server's `thread/start` parser. The browser backend is inert in
this workflow; acceptance does not establish browser action execution.

This benchmark submits with the production Ask policy: `workspace-write`
and `on-request`. It explicitly approves only its own disposable actions.
A separate rejection scenario declines an elevated command and verifies that
its requested file never appears. These decisions exercise the runtime
approval boundary. Full access uses a different execution policy and requires
the separate same-thread permission-boundary checks described below.

The native access choice is captured for each submission: Full uses
`danger-full-access`/`never`; Ask uses `workspace-write`/`on-request`. A new
submission overrides the policy even on an already-loaded thread. Running
turns retain the execution policy under which they began.

## Workflow and pass criteria

1. Run two Python tests against broken code; observe the real assertion failure
   and nonzero exit.
2. Apply a native patch that updates the function, creates a README and deletes
   a disposable file. Preserve a pre-existing dirty user note.
3. Compile the code, rerun both tests, inspect the actual Git diff and status,
   and verify the native file-change item and aggregate turn diff.
4. Stage an explicit list of changed files, make a real commit and push to the
   fixture's bare remote. Independently compare the local and remote commit
   IDs, remote source, changed-file list and remaining dirty user note.
5. Start a localhost server on `127.0.0.1` with an OS-assigned port. Derive the
   port and terminal session from actual readiness evidence. Make a real HTTP
   request and observe the fixture's unique body.
6. Stop the server with terminal input. Require its actual `SERVER_STOPPED`
   output and reported zero exit, then independently verify both its PID and
   listening socket are gone. Start a second interactive TTY, supply input
   through `write_stdin`, and check its completed response and reported exit.
7. Run a command that writes stderr and exits 23. Check the native failed
   command receipt. Input to the retired interactive session must fail
   explicitly, rather than silently targeting another process.
8. Require exact tool continuations, one thread and one user turn, the expected
   number of inferences, no replay and a confirmed runtime shutdown.

A separate cancellation scenario starts an owned localhost server and holds
the next inference open. Its exact offered command and arguments, uniquely
matched tool output, native running item ID and terminal session must agree.
The pinned engine emits an approval-stage start before launch with no
`processId` and suppresses a duplicate canonical start for the same item. That
initial optional field must remain null or absent; the real terminal session
comes from the call-ID-matched tool output. The approval request must match the
same item, thread, turn and command workspace.
The interrupt request and successful reply must belong to the same thread and
turn, and that turn must finish as interrupted. Inference must be canceled,
without a final assistant reply or normal website finish operation.

The interrupted command's presentation must retire as failed with its final
exit status unconfirmed. An interrupted server need not emit an
`item/completed` command notification or a known exit code; neither is invented
to make the test pass. The fixture independently requires that the owned PID
and localhost socket are gone **before runtime shutdown**, within a five-second
observation-only deadline. The pinned engine acknowledges logical termination
after sending the signal while its OS waiter continues asynchronously; an
empty native session inventory cannot substitute for `ESRCH` and a refused
socket. The benchmark records this physical retirement latency and emits
bounded structural diagnostics on failure before emergency cleanup. This proves that
Stop terminates the owned process; it does not prove a successful command exit.
Shutdown must then report confirmed cleanup, and the PID and port are checked
again.

Cleanup runs on every outcome. Emergency cleanup can kill only a recorded PID
whose command contains that unique fixture path. It never kills by executable
name, port or a general process search. Emergency cleanup cannot establish that
Stop passed. A passing scenario requires removal of its temporary project,
remote, home and protocol trace; test logs retain bounded scenario, duration,
request/output counts, approval counts and failure details.

## Running

The benchmark is opt-in because it launches the real bundled engine and child
processes. Explicit enablement fails when the pinned artifact is absent or
mismatched.

```sh
COMPUTA_WORKFLOW_ENGINE_TEST=1 xcrun swift test \
  --filter RuntimeWorkflowBenchmarkTests
```

Use the configured Xcode toolchain and serialize shared Swift build runs.
Existing native editing qualification remains available with
`COMPUTA_FILE_EDITING_ENGINE_TEST=1` and `RuntimeFileEditingLiveTests`.

The permission cohort checks persisted choices, provider routing and policy
changes on an already-loaded thread. Its real-engine fixture uses scripted
inference to verify that Full access can write outside the workspace, then
that Ask blocks both an ordinary outside write and a declined elevated write
on that same thread. Enable it with the workflow flag:

```sh
COMPUTA_WORKFLOW_ENGINE_TEST=1 xcrun swift test \
  --filter 'AppStateAccessModeTests|RuntimeIsolationTransportTests|WebModelRuntimeRoutingTests|AccessModeLiveTests'
```

This does not enable the separate optional model/native-app UI fixture or
qualify a live website model.

After packaging the candidate engine, run the instruction protocol check with
the source resource directory explicitly selected. Its default searches the
installed app first, which can select an older engine. Run the product-identity
check against the newly packaged manifest. The version-contract cohort can run
independently; repeat it if its source or canonical metadata changes:

```sh
COMPUTA_INSTRUCTION_TEST_RESOURCES="$PWD/Sources/Computa/Resources" \
  bun test Scripts/persistent-instructions.integration.test.ts
bun test Scripts/product-identity.test.ts
bun test Scripts/version.test.ts
```

These checks have separate source and engine bindings; a native-suite receipt
does not establish that they passed.

Build39's historical 311-input freeze excluded WebUI and MLX resources, which
needed separate committed-to-bundle checks. Candidate41's expanded inventory
includes those sources and verifies their generated payloads separately.
Current native/stage acceptance binds the supplied current engine artifact
freeze; historical engine pin or patch hashes cannot qualify a new package.

The three synthetic provider-adapter suites can be run together independently:

```sh
bun test Scripts/embedded-chatgpt-adapter.test.ts \
  Scripts/embedded-gemini-adapter.test.ts Scripts/embedded-claude-adapter.test.ts
```

## Fresh installed-provider qualification

Build 41 uses one shared case configuration and collector for normal ChatGPT,
Claude and Gemini. Each provider first needs a completed opaque-marker read
from a concrete model actually offered by its website, with current installed
identity and confirmed temporary-session cleanup. The same natural requests
then test code edits and selective commit/local push, flight-board browser
search/details, a localhost preview with browser input and server stop, and a
two-input interactive terminal session followed by rejected input after exit.
The prompts contain no tool protocol or manually supplied capability padding.

Independent file/Git, HTTP, native tool/output and cleanup evidence must agree;
the model's final message alone cannot qualify a case. CAPTCHA, quota, changed
model/session, malformed replies or uncertain cleanup stop that provider's run.
Separate installed review fixtures cover five diff scopes, unified/split views,
stage/unstage/revert of a single hunk and rejection of stale snapshots.

The shared preparation has been reviewed but no installed build-41 case has
run. Its four pure-data regression methods passed in **0.022 seconds**, covering
atime stability, inspection versus TTY launch, ordered empty drains, missing or
misassociated output/final facts, and preservation/revalidation of per-case
proof at cleanup. Receipt `provider-benchmark-data-regressions-build41-1/receipt.json`
has SHA `7fbbac49f6004a59505a738bcf8a5a534d593062c2af38877a7365ebbd4fa6e6`.
This qualifies those collector boundaries, not the app, provider or UI.

## Earlier qualification and limitations (builds 37–39)

Build 39's native validation on 2026-10-08 passed **535 selected tests**, zero
failures, in **361.278 seconds**, against **311 unchanged inputs**. All **26** selected
streaming/child cleanup records verified removal. Its separate provider-adapter
suite passed **361 tests/6,194 assertions**; the live-evidence collector passed
**90 synthetic oracle tests**. These historical results do not qualify build 41.

| Scripted provider | Scenario | Seconds | Inferences / matched outputs / approvals |
| --- | --- | ---: | ---: |
| ChatGPT | Editing, tests, Git push, localhost, TTY | 6.300 | 13 / 12 / 3 |
| Gemini | Same workflow | 6.158 | 13 / 12 / 3 |
| Claude | Same workflow | 5.881 | 13 / 12 / 3 |
| ChatGPT | Declined command, no side effect | 1.666 | 2 / 1 / 1 |
| ChatGPT | Stop cancels inference and reaps server | 2.806 | 2 / 1 / 1 |

All five passed with owned fixture removal. Stop left command exit unconfirmed
while independently verifying PID/socket closure before shutdown. Five extra
build 37 Stop runs passed, with maximum physical retirement latency **98.275 ms**.

Installed build 37 separately completed **Claude Sonnet 5.5** coding in **91.468 seconds**
(**43/43** collector checks, nine tool calls/closures, **15/15** filesystem
oracle), including native edits and a commit/push to its disposable bare remote.
It did not run the broken baseline first. Its separate synthetic flight-board
browser task completed in **102.777 seconds** (**37/37** checks, thirteen browser calls,
fourteen transactions/closures), answering **18:37 EDT, gate B49** from fresh DOM.

Those earlier builds established no installed ChatGPT coding/browser pass.
Builds 36–39 ChatGPT attempts stopped on guarded message verification; the latest
build 39 attempt reported `text_mismatch` and cleanup remained unconfirmed.
A Claude combined preview attempt stopped at its website usage limit before
tools. The combined localhost preview remains pending. Synthetic flight data
is not a real United booking; local Git pushes do not qualify external hosting
authentication. Observed website selection is not an immutable backend revision,
and guarded cleanup acknowledgments do not independently prove provider deletion.

[Validation notes](HARNESS-VALIDATION-NOTES.md) preserve every historical result,
failed attempt, prerequisite, source-fix detail, receipt reference and cleanup
record moved from this page. They also explain why workspace V8/voice tests are
separate from the shipped App Server and WebKit browser. The private receipt
scripts are evidence, not additional reproduction tools shipped in this repo.

## Validated candidate: 0.6.0 (47)

Build 47 encodes literal HTML delimiters inside the request JSON, preserving
parsed request values and strict first-message ownership. Its complete suite
passed 2,274 native tests and 625 public tests with zero failures; 49 native
opt-in cases were explicitly skipped. The controlled WebKit regression rejects
the original 17-character alteration and remaining five-character alteration,
and accepts the encoded request after one Send. This does not yet prove a live
website fix. Signed staging, installed verification and fresh live checks remain.

## Validated candidate: 0.6.0 (48)

The JSON string encoder now covers all printable ASCII punctuation, including
underscores and literal backslashes, while preserving decoded values, JSON
structure, control escapes and Unicode. The complete suite passed 2,276 native
and 625 public tests with zero failures; 49 native opt-in cases were skipped.
The five-case WebKit regression rejects the observed quote, HTML and underscore
mutations and accepts protected requests without relaxing ownership. Signed
packaging, installed checks and a fresh live browser task remain required.


## Installed validation: 0.6.0 (65)

Build 65 passed 2,314 native tests and 644 public tests, with zero failures;
49 opt-in native cases were explicitly skipped. Frontend checking and the
production build passed. Signed staging and installed bundle verification
passed all 98 checks, bound to source 4d03c287820de9a26664182c2fd8c6a0728b9e91.

Fresh visible temporary ChatGPT/GPT-6 controls at both Pro and Instant effort
returned “Load failed” immediately after a single Send. Retry was not clicked,
Pro was restored and the owned tabs were closed. Native qualification and the
five installed coding/Git, browser, localhost, interactive-terminal and diff
review checks therefore remain incomplete for this build. PR #5 stays draft.
The detailed receipts and limitations are recorded in the validation notes.


## Diagnostic installation: 0.6.0 (66)

Build 66 adds opt-in Web Inspector support for ordinary human browser views.
The complete suite passed 2,318 native and 644 public tests, with 49 explicit
native skips. All 414 inputs, 52 browser-session tests and 26 cleanup identities
verified. Signed staging and installed verification each passed 98 checks,
bound to source 63fe9af835609cdc68844d24f2ea45edf79e2553. The fresh runtime
identity and installed toolbar's default-off state were checked separately.

After human approval, Safari's developer menu was enabled temporarily and the
public inspector attached only to an owned temporary ChatGPT test tab. One
GPT-6 / Pro control failed with `Load failed` at the first read, 923 ms after
Send. For the conversation fetch, POST `/backend-api/f/conversation`, Inspector
exposed neither an HTTP status nor a transfer-byte count; its correlated console
error was `Failed to load resource: bad URL`. Three preparation requests returned
HTTP 200. The app logged resource 4419 failing after 98.403 ms, closely matching
Inspector's 98.5 ms. Its proved Networking process links that resource to task 61,
which failed with NSURLErrorDomain -1000 and underlying NSPOSIXErrorDomain 22
(EINVAL). Native logs redact the request URL; their independent endpoint match
remains unverified. The specific invalid argument and cause remain unproven.

No Retry or native inference was dispatched. The owned inspector, inspection
list and test tab closed; Safari's developer setting returned to off and the
Computa browser pane returned to its prior hidden state. Sanitized control
and log receipts retain no headers, cookies, bodies or HAR. The ChatGPT website
failure, native qualification and five live workflows remain unresolved.

Three additional single-send human controls isolated normal app restart,
model-family selection and temporary-chat mode. The restarted app was still
the identical installed build 66; its new app PID 3257 and owned Networking
PID 3261 were independently verified. GPT-6 / Pro temporary chat failed at the
first UI read after 829 ms, GPT-5.6 Sol / Pro temporary chat after 806 ms, and
GPT-6 / Pro ordinary chat after 1,051 ms. All three have exact native
task/resource associations for the same -1000 / POSIX 22 error chain. The
restart also reproduced the connection write/read EINVAL sequence. This is a
normal-app-restart comparison, not a Networking-only or HTTP/2-only reset.
Other preparatory POST requests succeeded in the original Inspector control;
these results do not establish a generic POST failure. No Retry or native
inference followed, and closing the tabs did not independently verify website
conversation deletion.

## Requested Chat power presets and selector observations

The latest human instruction replaces the earlier remove-Latest preference:
offer Chat powers **Instant, Medium, High, Extra High and Pro**, while choosing
the highest observed enabled plain GPT family automatically. Sol and Work are
excluded. The website did not expose a literal Latest family. This section
records the requested contract and observed controls; implementation and live
qualification require their own evidence.

On an owned empty Chat page with zero prompts, Chat was pressed and Work was
not. The native power control exposed values 1–5 in that order. Public Inspector
showed a `SPAN` slider with range 0–4, current value 0 / Instant, horizontal
orientation and tabindex -1, without a label, labelledby or describedby. Its
owning `DIV` menuitem was labelled Power. The containing menu was exactly the
popup referenced by the expanded **Select ChatGPT model** button. That same
popup contained three enabled family radios: GPT-6 selected, Sol unselected,
and GPT-5.5 unselected with a separate “Leaving on Oct 14” notice. Family radios
and power values are distinct controls.

GPT-6 and Pro 5 of 5 were restored before the owned tab and inspection windows
closed at 2026-10-12T00:36:46.174Z. Safari's developer setting was 0 with Develop
absent, the browser pane was hidden, and the human's Gemini 3.8 Flash new task
was preserved. No inference followed the human correction. These structural
observations do not resolve the network failure. The immutable root-observation
receipts and native correlations are listed in the validation ledger.

## Build 67 Chat preset validation

ChatGPT now exposes Instant, Medium, High, Extra High and the observed GPT-6
Pro choice. Each new inference resolves the highest offered enabled plain GPT
family. Work and Sol cannot satisfy this contract. Family and power are pinned
within an inference; a change rejects the response without repairing selection
or replaying the prompt. Pro keeps a stable saved intent while its observed
family label can advance after discovery.

The final frozen source passed 2,335 native tests with zero failures and 49
explicit opt-in skips (2,384 executed, 581.843 seconds). The seven public
cohorts passed 663 tests with zero failures or skips, including 404 adapter
tests. Actual WebKit fixtures exercise all five powers through two responses
each. The bundled-engine fixtures verify real patches, interactive commands,
Git commits/pushes, localhost requests, permissions and owned process cleanup
using scripted model replies. They do not prove live ChatGPT cooperation.

A queue regression covers bare and historical Chat selections rejected before
dispatch. The queued prompt remains saved, discovery can recover its model,
and only explicit Resume sends it. Generic delivery failures remain uncertain.
Signed packaging, installed selector observation and fresh live qualification
are separate steps; the earlier direct website network failure remains open.

## Build 68 inert Power metadata

Signed installed build 67 passed bundle verification but failed prompt-free
Chat discovery before producing choices. Its finite log identified
`primary_open_requested`, one associated popup and no secondary action or
selection proof. Inspection of an owned empty ordinary Chat popup then found
the 0–4 SPAN slider marked inert on itself, under a non-inert Power menuitem.
The adapter incorrectly applied interactive visibility to this metadata.
Temporary Chat's native controls separately showed Pro 5 of 5 and the three
family choices; the failed background thumb's attributes were not logged.
This separates the measured mismatch from proof of its startup causality.

The fix reads that narrowly scoped metadata and directs arrows to its enabled
Power item. Actual WebKit fixtures now mirror the inert thumb and require
Power-targeted input, including all five presets through two responses each.
New cases reject inert/hidden ancestors, disabled controls and focus-time
metadata replacement or drift. The focused native run passed 201 tests, and
the adapter run passed 407 tests with 6,689 assertions.

Final frozen build 68 passed 2,336 native tests, with 49 explicit opt-in skips
and zero failures (2,385 executed, 615.177 seconds). Seven public cohorts passed
666 tests with zero failures/skips. These remain source and controlled-runtime
results; signed installed discovery and live model responses require fresh
checks. No provider prompt was submitted during the build 67 diagnosis.

Installed build 68 also failed prompt-free discovery. Its new finite diagnostics
showed physically rendered slider metadata hidden from Accessibility below a
visible, enabled Power item. The following candidate treats this scoped data
separately from input authority, including self and wrapper suppression. Inert
or hidden state at or above the Power item still blocks input. No live prompt
was sent during either discovery failure; the prior network failure remains
unresolved.

## Build 69 closed-power observations

Signed installed build 69 passed its 98 bundle checks, then failed prompt-free
Chat discovery after the first Power read and family navigation. Reopening the
picker showed the remembered Family panel rather than active Power controls.
This is separate from the older network failure, and no prompt was sent.

On one owned empty ordinary Chat tab, every closed button label matched its
actual ordinal: Instant 0, Medium 1, High 2, Extra High 3 and Pro 4. The open
button instead read Thinking effort. Pro was restored, the owned tab and
Inspector closed, Safari's temporary developer setting restored, and the human
task preserved. These observations support combining the active checked family
with fresh closed selected-power labels. They are selector observations, not
completed provider responses; current-source and installed validation remain
separate.

## Build 70 closed-power verification

The adapter now combines an active checked latest plain GPT family with matching
fresh closed-power labels. It accepts a remembered Family panel for reads and
uses only the visible enabled Power control for changes. Header drift remains
latched across replacement and same-batch detachment; unrelated page updates
cannot consume the header observer's bounds.

Current source passed 206 affected native tests and 675 public tests, all with
zero failures or skips. The native cohort uses real WebKit for all five presets
through two fixture responses, owned cleanup, input boundaries and restored
header drift. The public run includes 416 adapter/policy tests and passed
frontend checking/building. Source inputs and built script identities held.
Build 68 remains the prior complete native-suite baseline; no full native-70
run is claimed. Signed installed discovery and fresh provider responses require
their own receipts. Earlier failed runs remain in the validation ledger.

Signed installed build 70 passed 98 bundle checks and now discovers exactly the
five Chat choices in the real selector, with no Work or Sol options. The fresh
Medium file-read qualification failed before tools at first-message ownership;
website cleanup remains unconfirmed. The body was a 10,240-character prefix of
the 58,077-character harness message. One expansion control was present, but
the model precheck rejected before clicking and discarded its detailed cause.
The catalog result does not qualify a response. Further live tests stopped;
the following diagnostic correction preserves that missing finite cause without
weakening verification or replaying the prompt.
