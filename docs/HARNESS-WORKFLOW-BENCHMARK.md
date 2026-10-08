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

An installed build 35 check exposed a startup gap: browser tools were emitted
in legacy form alongside canonical native definitions, so `thread/start` was
rejected before inference. Build 36 makes that manifest consistent. The
workflow now checks the complete combined payload and its actual native
acceptance, closing the earlier fixture gap.

Production threads retain their normal `workspace-write` sandbox and
`on-request` approval policy. The benchmark explicitly approves only its own
disposable actions. A separate rejection scenario declines an elevated command
and verifies that its requested file never appears. These decisions exercise
the runtime approval boundary; they do not qualify the app's Full Access UI.

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

## Results

The final native validation on 2026-10-08 passed **512 selected tests with zero
failures in 335.490 seconds**. `native-build38-final.log` and
`native-build38-final-validation.json` are bound to the 310 unchanged input
hashes in `native-source-freeze-build38-final.json` for Computa **0.6.0 (38)**.
Earlier build 37 validation separately passed 404 selected tests in 154.862
seconds; the current run adds the entire 108-test WebKit transport group.
The native suite includes actual combined thread startup, editing/diffs,
protocol/streaming, isolated WebKit, approval/Stop, and durable cleanup tests.

| Scripted provider ID | Scenario | Seconds | Inference requests | Matched tool outputs | Approvals | Outcome |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `browser/chatgpt` | Editing, tests, Git push, localhost, TTY | 6.325 | 13 | 12 | 3 | Passed |
| `browser/gemini` | Editing, tests, Git push, localhost, TTY | 6.012 | 13 | 12 | 3 | Passed |
| `browser/claude` | Editing, tests, Git push, localhost, TTY | 6.133 | 13 | 12 | 3 | Passed |
| `browser/chatgpt` | Declined command has no side effect | 1.681 | 2 | 1 | 1 | Passed |
| `browser/chatgpt` | Stop cancels inference and reaps server | 2.859 | 2 | 1 | 1 | Passed |

Every scenario confirmed removal of its owned fixture. The interrupted server's
exit remained unconfirmed in presentation, while its PID and port were
independently verified closed before shutdown. Five additional consecutive Stop
runs passed; the maximum observed physical retirement latency after logical
acknowledgement was **98.275 ms**, with no extra signal or shutdown used to pass.
The original immediate-PID check exposed the pinned engine's asynchronous reap
boundary; finite structural diagnostics now survive failure cleanup.

Every scripted workflow uses fresh owned website leases while retaining the
same real native user turn. Long-history regressions verify more than 80 native
turns, 90-turn receipt retention, summary eviction, conflicting identities,
partial persistence failure, exact retry and storage bounds. Separate native
patch qualification passed for all three provider IDs; malformed/stale patches
were rejected before writes and were not replayed.

Build 36 installed coding attempts exposed ChatGPT's rendered whitespace change
and Claude's virtualized old website message roots. Their failures remain
separate records. Build 37 narrowly handles ASCII whitespace during guarded
first-message promotion and uses [fresh website inference
transactions](WEBSITE-INFERENCE-TRANSACTIONS.md).

Installed **0.6.0 (37)**, source
`cbf199d8bebc69b146b2a58af9bd4039ff1ec7db`, completed one fresh **Claude Sonnet
5.5** coding turn in **91.468 seconds**. The live collector verified **43/43
checks**, including nine distinct website leases, nine durable closures and
release before native tools, the next inference and the final response. Nine
matched tool calls produced nine outputs: eight `exec_command` calls and one
native `apply_patch`. The archived evidence matches the 310 frozen inputs with
zero mismatches; `live-claude-coding-build37-receipt.json` binds the exact turn,
process, model selection and transaction journals.

The model fixed addition, added test instructions, deleted the obsolete fixture
and renamed the helper without changing its content. Both Python tests passed
twice through native commands and again in the independent **15/15** filesystem
oracle. Commit `367667eb070c96378efc8ac8d36210a414d1444f` matched the disposable
bare remote; only the original user note remained dirty. The model recovered
from a shell glob error and sandbox Git denials before using explicit elevated
Git requests. The live run did not execute the broken baseline tests first.

Operator AX observations in `live-coding-build37-diff-ui-observations.json`
confirmed that Last Turn showed the three files changed by the native patch,
with 18 additions and two removals; the terminal rename was outside that
aggregate. Commit showed
four changes, including the 100% helper rename with zero line changes. Split
showed `return a - b` beside `return a + b`; Unstaged showed only `notes.txt`
with its one preserved addition. No stage or revert action was tested.

This live result is separate from scripted provider coverage. It proves an
observed Claude website selection, not an immutable backend revision; guarded
cleanup acknowledgements do not independently prove provider-side deletion.
The push used a local remote, so external Git hosting authentication remains
unqualified.

The same build completed a separate **Claude Sonnet 5.5** flight-browser turn
in **102.777 seconds**. The collector passed **37/37** checks: thirteen matched
browser calls (one open, seven reads, four clicks and one fill), fourteen fresh
website transactions and fourteen durable closures. The synthetic board
recorded one matching flight search and one gate reveal. Fresh DOM observations
supported the final **18:37 EDT, gate B49** answer. Expected facts were absent
from the natural-language prompt. This exercises navigation, forms and dynamic
page results in Computa's own WebKit browser; it does not access a real United
account or establish personal booking data.

A subsequent Claude combined preview attempt stopped on its actual website
usage limit before any tool ran. Its exact cleanup receipt confirmed an
untouched session was closed; no preview server or run directory was created.
A separate build 37 ChatGPT flight attempt stopped before tools on first-message
verification after a permitted initial chat route change, without replaying
the prompt. Its cleanup remained unconfirmed. Both are retained failure records,
not successful qualification. The reproduced route/expansion regression is
being repaired and the combined localhost preview remains pending.
