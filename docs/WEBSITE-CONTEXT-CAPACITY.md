# Website context capacity

The website codec limits both the original request and the complete rendered
prompt to 163,840 bytes. This is a local admission limit: exceeding it submits
nothing. Its HTTP 400 `input_too_large` diagnostic now persists bounded native
byte counts and `submitted:false` across reload. The failure store accepts only
the complete regenerated envelope, with strict numeric/Boolean types and no
arbitrary page or provider prose. The limit and HTTP classification are unchanged.

## Accounting gap

The native browser-model configuration advertises a 65,536-token context window
and a 49,152-token automatic-compaction threshold. Those token limits do not
guarantee that an expanded website prompt fits the byte limit. Website responses
also intentionally have `usage:null`; Computa must not present locally estimated
counts as provider-reported usage.

A controlled bundled-engine experiment on 2026-11-09 used synthetic ChatGPT
responses, five actual read-only status calls and a 2,048-token compaction
threshold. Six rendered prompts grew from 53,031 to 55,796 bytes. All six native
token-count records had null info; there were no usage-update notifications or
compaction events. The exact five native call/result pairs remained present.
This demonstrates the accounting gap in that bounded experiment, not the token
count or complete composition of a user's failed task. The experiment stayed
below the byte cap and made no provider or browser requests.

The pinned runtime treats the current HTTP 400 as an invalid request. Changing
only the error code cannot repair compaction: inline summarization changes the
configuration and history that website continuation verification intentionally
protects. Recovery needs native history accounting and an authenticated
maintenance transition for the summary and resumed inference. It must preserve
completed tool outcomes, verify fresh website ownership and avoid replaying
uncertain input. A second overflow or an unreduced request must remain terminal.

## ChatGPT byte-aware maintenance (2026-11-16, build 570)

The failed Pro review reached 179,057 request bytes after ten tool calls, above
the 163,840-byte hard cap. Its token-based maintenance had not run. The rejected
request was never sent to ChatGPT.

ChatGPT now requests native compaction when either the canonical request or its
complete rendered website prompt exceeds 131,072 bytes. This leaves 32 KiB before
the hard ceiling. The preflight sends the engine a standard `response.failed`
event with `context_length_exceeded`, before creating a website session. It does
not invent provider usage, trim tool results, or replay the previous tool call.
The pinned engine already permits one summarizing recovery per model step.

Only native App Server compaction start/completion events can authorize the
rewritten history. Checkpoints bind the task, thread, turn, runtime generation
and item ID. They require confirmed closure of the preceding website session;
the summary is tool-free, and resumed model, instructions and tool definitions
must match. Engine window metadata may rotate. Ordinary continuations retain
their exact history/configuration checks and cumulative turn budgets.

The engine also emits a context-full estimate while producing its summary. The
progress guard now evaluates the final retained estimate at the completed
checkpoint instead of interrupting on that intermediate sentinel. Oversized or
non-progressing completed checkpoints still stop.

Validation before live qualification: 116 focused Swift tests and 18 managed
compaction integration tests passed, including
the real bundled engine over HTTP. That fixture executed seven commands,
compacted once, retained matching call/result receipts, edited a file, and
returned its exact completion marker. A separate execution ledger verified that
no command ran twice. Boundary tests retain the hard cap and reject unauthorized
history, model, instruction or tool changes. Wider-suite failures in Groq/Grok
fixtures are tracked separately; this is not an all-provider qualification.

The soft boundary is qualified for ChatGPT only. A single oversized input or tool
result that jumps over the hard cap can still fail before this maintenance path;
the cap has not been raised.

### Installed Instant review: partial, not a completed qualification

Build 570 was signed and installed from `c1fad81139b25d0a49b654b0a4a26e9e6c1cb70c`.
The signed 68-file bundle changed only the executable and Info.plist; browser
adapters and the pinned runtime were unchanged. The original prompt was sent
unchanged to a fresh Instant task. It returned a repository inventory after four
tool calls (56.689 seconds), explicitly saying no detailed review had been done.
A follow-up requested the actual implementation/test review without source edits.

That turn triggered byte maintenance at **143,863 bytes**. The tool-free summary
was 110,495 bytes; the verified resumed prompt was **99,967 bytes**. Two subsequent
source-reading commands executed successfully. The next 137,789-byte request
triggered another early compaction; its 104,422-byte summary request stopped at
ChatGPT's pre-submit selected-model check. No final review was produced.

A fresh controlled task combining the original prompt with the requirement for
actual source findings also stopped at that picker check after four commands,
without triggering byte maintenance. This separates the current picker failure
from the new byte-budget trigger; it does not identify the picker failure's root
cause. Diagnostics show the initial selection was verified, but the subsequent
submit precheck requested an opening and observed no associated model menu.
The native engine's generic high-demand message was not the real diagnostic:
the persisted failure is `browser_model_error`, selected model unverified.

Both failed sessions retain durable unconfirmed-cleanup receipts. One explicit
cleanup retry for the first session remained unconfirmed. No failed prompt was
replayed and no verification check was relaxed. The live byte reduction and
post-compaction tool use passed; **completion of the requested review remains
blocked by the separate picker/cleanup failure**. Pro and other ChatGPT choices
share this budgeting path but were not live-qualified in this run.

Local evidence: `work/context-budget-20261116/` in the Codex task workspace,
including `live-review-results.json`, per-turn transaction/cleanup journals,
`live-app.log`, the 134 passing test receipts, and build/sign/install receipts.
First thread: `01a1e68a-ba15-78b2-8226-e2cb544f9d04`.
Second thread: `01a1e690-abbb-78e0-bf91-c6f3fbb08f5c`.
