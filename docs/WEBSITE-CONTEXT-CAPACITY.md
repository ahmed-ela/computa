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

Validation before live qualification: 116 focused Swift tests passed, including
the real bundled engine over HTTP. That fixture executed seven commands,
compacted once, retained matching call/result receipts, edited a file, and
returned its exact completion marker. A separate execution ledger verified that
no command ran twice. Boundary tests retain the hard cap and reject unauthorized
history, model, instruction or tool changes. Wider-suite failures in Groq/Grok
fixtures are tracked separately; this is not an all-provider qualification.

The soft boundary is qualified for ChatGPT only. A single oversized input or tool
result that jumps over the hard cap can still fail before this maintenance path;
the cap has not been raised. Live Instant review results are recorded separately
below once the installed build completes the original task.
