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

## Current candidate: 0.6.0 (42)

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
changed content. This is an offline experiment until a fresh installed run
confirms the cause. Focused validation passed 69 Swift and 365 adapter tests.
The seven public groups then passed 623 tests without failures or skips;
complete native validation passed 2,263 tests with zero failures and 49 opt-in
skips in 527.297 seconds.

| Check | Current evidence and remaining work |
| --- | --- |
| Upstream runtime | Source19/20 observations cover 19,035 runnable identities: 19,032 passed and three standalone TUI cases failed. Optional guard exits do not prove skipped assertions. Source21 compiled all 275 debug test binaries and passed scoped lint and formatting. This is not a green complete upstream workspace result. |
| Engine package | Source21 release packaging passed. The signed arm64 App Server, source pin, patch and manifest match runtime mactopus-6. Build 42 reuses these unchanged artifacts. |
| App validation | Build 41 passed all required native cohorts, permission checks, workflow and patch matrices, Git deadline regressions and cleanup guards. Build 42 passed 2,263 native tests and 623 public tests with zero failures; 49 native opt-in tests were skipped. |
| Installed provider tasks | Build 41's first ChatGPT qualification failed with unconfirmed cleanup. Fresh build 42 qualification plus coding/Git, browser, localhost and interactive-terminal cases remain pending for ChatGPT, Claude and Gemini. |
| Installed diff UI | Scope selection, split/unified views, hunk staging/unstaging/reverting and stale-state rejection still require installed-app checks. |
| Model comparison | The earlier six build 39/Codex trials failed the complete task. Computa goal mode was N/A. A fresh comparison using the same actual model is pending. |
| Delivery | Build 42 signed installation, live qualification, fixture/process cleanup, documentation and PR push remain pending. The temporarily moved local model is restored; eight obsolete app backups were verified in archives before retirement. |

Detailed historical failures, corrections, receipts and source attribution remain
in the [validation ledger](HARNESS-VALIDATION-NOTES.md).

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
