# Editing, terminal, Git and localhost benchmark

`RuntimeWorkflowBenchmarkTests` exercises Computa's production Swift runtime,
the verified bundled App Server, the local Responses bridge, native
`apply_patch`, `exec_command`, and `write_stdin`. Only the website's model replies
are scripted. Filesystem changes, reported command exit codes, terminal
sessions, Git commits, pushes and HTTP requests are real. Process termination
is verified separately from command success.

The same workflow runs with `browser/chatgpt`, `browser/gemini` and
`browser/claude`. Every inference request must retain the requested provider ID.
This checks provider routing and tool composition with scripted inference. It
does not test website sign-in, selection of a concrete website model, the
model's own judgment, or live website session cleanup. Those require separate
qualification of the installed app and selected provider/model pair.

A separate [local-model goal comparison](GOAL-MODE-BENCHMARK.md) records six
build 39/Codex trials, their failures and limits; it does not qualify build 41.
All six official trials failed the complete task; Computa goal mode was N/A.

## Current candidate: 0.6.0 (41)

Build 41 is **not yet qualified, installed or pushed**. The installed app remains
build 39 with runtime `mactopus-5`, and is quit.

The corrected Source19 engine compiled all **275 test binaries**. Fresh discovery
covers **19,035 runnable tests and 56 declared exclusions**. Its full App Server
follow-up passed all **1,705 tests**, with unchanged source, runtime inputs,
binaries and protected processes. The original startup failures and diagnostic
follow-up remain separate evidence; this passing run establishes no general
cold-start or signing guarantee.

Eight disjoint smaller-package batches cover another **7,618 tests**. The first
five passed **953, 953, 952, 952 and 951 tests**, with preservation and fixture
cleanup checks. The second batch required a separate re-audit after a checker
rejected a valid Nextest header; its original validation failure remains
recorded. The sixth batch's original timeout remains preserved; its full
953-case follow-up passed with preservation and cleanup checks. The final two
package batches each passed all 952 cases and completed cleanup.
Core recorded 4,434 first-pass outcomes with unchanged source and runtime
inputs and completed fixture cleanup. Its attributed output includes 24
remote-only and 13 optional execve-wrapper guard exits; those are not assertion
proof for those features. Twenty selected coding/terminal cases had first PASS
results and no observed guard exit. CLI passed all 458 cases and completed
cleanup. Source20 corrects five TUI test fixtures without changing production
code or golden snapshots: version normalization now preserves validated header
padding, and the update-card fixture accepts its wrapped Windows command.
The ordinary graph compiled all 275 binaries; the five mapped runtime helpers
have identical bytes to Source19. A complete 4,820-case TUI run then recorded
4,817 PASS, three failures and seven exclusions, with unchanged source, runtime
inputs, binary metadata and protected processes. All five corrected cases passed.
The remaining failures are the terminal pet renderer's inline-payload assertion
and two PTY startup cases with empty screens. The two startup cases had passed
an earlier isolated diagnostic; their full-package failures remain recorded.
This is not a green upstream workspace result. Computa's app-server and installed
workflow qualification is separate from the standalone terminal UI.
The original Source19 negative run and generated snapshots remain preserved.
Final lint produced five reviewed source changes. Source21 makes debug-only
imports and loader mutation explicit so release lint cannot remove declarations
needed by debug builds. Prior Source19 and Source20 tests retain their original
attribution. Source21 compiled all 275 debug test binaries and passed the final
scoped lint and formatting checks with unchanged source. These phases executed
no further tests. Release packaging passed and its current artifact freeze binds
runtime `mactopus-6`, the source pin, patch, manifest and signed arm64 executable.
All seven public checks passed: 123 frontend tests, 106 MLX tests with one skip,
364 provider-adapter tests, three instruction tests and 21 identity/version tests,
plus frontend type-checking and build. The selected native run finished with
three failures across 652 tests and one skip. The permission fixture required
a lifecycle item even when the native sandbox returned a denied command's
output directly, its cleanup rejected an already absent root, and the website
routing fixture used non-UUID identities. The corrected three-case diagnostic
passed. A supplemental real-tokenizer check caught a stale single-event SSE
parser; all four pinned MLX checks now pass without an asset-path override.
The fresh shared run subsequently passed 622 tests with no skips. Complete Swift
validation then ran 2,310 tests: 2,252 passed, 49 opt-in checks skipped and nine
cases failed, producing 28 failure reports. Eight older website-evidence cases
lacked the current durable turn/lease setup and journal contract. Their fixtures
now verify schema-2 journals, fresh sessions, bounded failures and rejected
journal admission. The WebKit failure was traced to a rounded-down inner timer
firing before a short wait's caller deadline; the host timer now uses that same
absolute deadline. All 68 focused checks passed, including ten complete real
WebKit flight workflows. Fresh public final3 passed all 622 tests with no skips.
Complete native final3 passed 2,261 tests with zero failures and 49 opt-in skips
in 545.894 seconds. All required cohorts, scripted workflow/patch matrices,
permission checks, 26 unique cleanup identities and source/resource/engine
guards passed. The independent Git deadline gate verified the three regression
passes from this same full run. Installed qualification remains pending.
Eight obsolete installed backups were preserved in verified archives before
retirement. The temporarily relocated local MLX model has been restored and
verified at its original internal path; the duplicate and temporary alias are
removed. The first signed Release build passed, but exact resource validation
rejected a repository `.gitignore` copied into AgentRuntime. Its ignore rules
now live at the repository root; a fresh package must pass the same exact gate.

The affected Git review/process suites passed all **62 tests**, including three
new regressions for inherited output pipes, backpressured input and continuous
output. Packaging and complete native validation passed; installed provider
benchmarks remain pending. Historical attempts, fixture corrections and cleanup receipts
are recorded in the [validation ledger](HARNESS-VALIDATION-NOTES.md).

| Check | Current evidence and remaining work |
| --- | --- |
| Full upstream workspace | Source19 discovery covers 19,035 runnable identities. App Server, core, CLI and all eight smaller-package batches have 14,215 first-pass outcomes under Source19. Source20 changes four TUI test files only; its complete TUI run recorded 4,817 PASS and three failures, so the upstream workspace is not fully green. Inherited guard exits do not prove their skipped assertions. Earlier failed runs and diagnostics retain their original source attribution. |
| Engine package | Source21 release packaging passed with unchanged bound inputs. Runtime mactopus-6 is a signed arm64 executable; the pin, patch, manifest and executable match the current engine artifact freeze. |
| Computa native validation | Fresh final3 passed 2,261 tests with zero failures and 49 opt-in skips. All nine required cohorts, permission checks, exact workflow/patch matrices, cleanup and source/resource/engine guards passed. The independent Git deadline gate verified all three regressions. Earlier selected/full failures remain preserved separately. This does not qualify live provider behavior. |
| Installed provider tasks | Fresh concrete-model qualification and coding, interactive terminal, Git, localhost and browser tasks are pending for ChatGPT, Claude and Gemini. Scripted inference is separate evidence. |
| Delivery | Signed install/resource parity, owned-fixture cleanup, commit and PR push are pending. |

Historical engine attempts, failed runs, fixture corrections and cleanup records
are preserved in the [validation ledger](HARNESS-VALIDATION-NOTES.md). They do
not qualify the current candidate.

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

## Last qualified results and live limitations

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

No installed ChatGPT coding/browser pass is established by this record.
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
