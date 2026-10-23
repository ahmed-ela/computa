# Computa agent instructions

Computa owns its instructions and tool contracts. Users can describe ordinary
tasks without naming tools or teaching the model the harness. Tool execution,
permissions, local history and outcome verification remain in the local App
Server and native host.

`ComputaAgentInstructions.developerInstructions` supplies the app's instructions
when starting and resuming threads. For website models,
`WebModelResponseCodec.prepareRequest` also constructs a fresh capability
contract outside the complete Responses JSON on **every inference request**,
including requests after local tool outputs. It uses that request's validated
tool schemas and their exact qualified names. The original request remains
byte-for-byte intact; history is not silently truncated to fit the prompt limit.
An explicit response handoff follows the complete JSON so long histories cannot
bury it: pending supported actions require returning a `tool_calls` envelope
before the host can execute them and return matching local results.

A fresh locator after the JSON identifies its latest actual user message by
input index, without copying the text or treating role-like fields in quoted
tool output as messages. String input and maintenance/output-only continuations
are handled separately. Follow-up and status requests can retain unfinished
authorized work; completed earlier tasks are context rather than a checklist
to replay. Once current observations satisfy the request, the model should
answer and stop. Newly started terminal sessions must finish or be stopped
before that answer unless the user requested ongoing background behavior.

This repeated contract is deliberate. The pinned App Server replays retained
developer messages, but two independent cold-resume probes retained old
developer text despite new overrides. Base instructions updated in both probes.
Putting current website capability guidance outside retained history avoids
depending on those overrides or a reminder every N messages. Empty-tool context
maintenance remains valid and cannot revive historical tool names.

Instructions distinguish general questions from requested inspections and
actions. Completion of an operation requires the relevant local observations
and outcome. A familiar or plausible answer does not establish that the
requested operation happened. Unsupported surfaces must be reported accurately.

Code tasks receive guidance to inspect existing files and changes, preserve
unrelated work, prefer the offered native `apply_patch` tool for targeted edits,
and check actual results and relevant tests. The website contract projects
custom tools separately from JSON function tools: a custom patch call uses the
exact offered name and a literal string `input`; functions retain object
`arguments`. Neither schema permits converting an unoffered tool into a command.
The engine executes patches and emits file-change items and aggregate turn
diffs. Proposed, failed, or interrupted changes are not labeled applied merely
because the model returned a patch. See [code editing](CODE-EDITING.md).

Current website models receive text observations. The `browser_*` tools control
Computa's normal built-in WebKit tabs through a separate owned controller;
the `computer_v2_*` tools operate native applications.
Embedded ChatGPT, Gemini and Claude model pages remain private inference surfaces
and cannot be selected as browser-tool targets. See [built-in browser tools](BUILT-IN-BROWSER-TOOLS.md).
Image/audio input remains unavailable. Full Access uses the engine's
`danger-full-access` terminal/file mode and automatically resolves permitted
approval requests. Private HOME, native privacy grants and the native interaction
policy still apply.

Background-only is an input-delivery constraint. It forbids native activation,
focus theft and global keyboard/pointer input; it does not prohibit user-authorized
changes through offered background browser or native controls. Filling forms,
submitting them and sending a requested message remain available subject to the
user's scope, approvals, actual access denials and outcome verification. A read-only
lookup allows navigation and search/filter input, but not sends, edits, deletions
or settings changes. A later explicit send request can authorize that
send without permitting unrelated changes or cancelling continuing constraints.
The host repeats this distinction in each turn's interaction policy and in each
website browser handoff, including after retained assistant refusals.

Each new user turn must acquire current browser bindings and observations; prior
turn handles and cursors are not reusable, and task-owned pages may already have
been cleaned up. Prior failed-action receipts are retained as historical outcome
evidence, explicitly separated from the current turn's permission and tool state.
They prevent unsupported success claims without creating a permanent read-only
restriction or revoking a later user authorization. The host also repeats current
browser lifecycle guidance in every turn's policy suffix, because cold-resumed
threads can retain old developer instructions. A closed task tab can be reopened
at its supplied or previously observed URL for the authorized follow-up; its old
snapshot, handle and cursor cannot be reused. Website handoffs repeat this rule
outside retained history as well.

The instruction design takes inspiration from the public Codex autonomy/task
template and terminal session/output schemas in the pinned source revision
`4607249e430dac1c961df4dc615beae88e33cec8`. It does not discover or import another
application's active prompts, user configuration, credentials or private chats.

## Verification

- `ComputaAgentInstructionsTests` and `WebModelResponseCodecTests` cover current
  tool projection, namespace identity, a 90-message history, matching tool
  outputs, omitted resumed instructions, untrusted quoted markers, removed
  tools, empty-tool summaries and prompt-size admission.
- `bun test Scripts/persistent-instructions.integration.test.ts` exercises the
  real pinned App Server with scripted loopback Responses. It checks actual
  developer roles, successful command output, matched tool continuations, cold
  resume, compaction and an 80-message replay. Missing default artifacts skip
  clearly; an explicit `COMPUTA_INSTRUCTION_TEST_RESOURCES` override or a present
  mismatched artifact fails closed. The fixture uses a private home and an outer
  sandbox denying external network. Its thread sandbox differs from production
  to avoid unsupported nested macOS sandboxes.
- Real ChatGPT behavior must also be checked through the installed desktop app,
  using ordinary prompts and actual local receipts. The protocol fixture does
  not simulate model judgment or qualify the Swift Accessibility executor.

These checks establish instruction delivery and the tested behavior. They do
not guarantee perfect model compliance for every future task or history length.
