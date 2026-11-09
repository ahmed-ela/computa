# Website context capacity

The website codec limits both the original request and the complete rendered
prompt to 163,840 bytes. This is a local admission limit: exceeding it submits
nothing. Its HTTP 400 `input_too_large` diagnostic now persists bounded native
byte counts and `submitted:false` across reload. The failure store accepts only
the complete regenerated envelope, with strict numeric/Boolean types and no
arbitrary page or provider prose. The limit and HTTP classification are unchanged.

## Remaining compaction gap

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

Capacity-aware automatic recovery remains unfinished. Keep this distinct from
diagnostic retention, successful short tasks and Groq's reversible history
presentation.
