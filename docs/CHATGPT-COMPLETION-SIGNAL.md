# ChatGPT completion admission

ChatGPT's decoded `message_stream_complete` event can bypass the 1600ms quiet
fallback only when it refers to the submitted input and to the exact final
answer currently displayed. The event is an optional hint to run the existing
full verification; it cannot provide a transport response or dispatch tools.

`chatgpt-completion.js` observes an already initialized decoder in the recognized
website runtime. Its bounded, single-use lease binds the input's exact SHA-256,
sequence, one Send, decoder instance, conversation, and observed message lineage.
A successful final message with a subsequent terminal event is required. The
observer preserves the original decoder result or error and restores its own
wrapper on revocation. Unsupported runtime versions and response formats retain
the quiet fallback; no network stream interception or alternate Send path is used.

`ChatGPTResponseCompletion` binds that hint to the native view, document generation,
private owner, sequence, and original response deadline. The adapter then matches
its source text and assistant message ID to the current DOM. The transport retains
fresh model, Chat product, Temporary mode, user-message ownership, response-count,
nonbusy, and completion-control verification. It checks that the native receipt
is still current after the final await and immediately before publication.

Late mutations, errors, cancellation, navigation, another Send, conflicting IDs,
or expired leases revoke the hint. Empty or partial DOM, missing controls, changed
model or ownership, and unsupported text representations cannot use the fast path.
Tool envelopes still go through the normal parser and permission checks. A fenced
JSON envelope can match only an accepted literal code body or the specifically
observed DIL paragraph/span structure. The latter must retain the same message ID,
visible literal text, and exact source relation, including the observed outer
`<escape>` wrapper when present. This is a bounded representation match, not a
general Markdown or DIL parser. Extra prose, hidden content, ambiguous structure,
or different bytes retain the quiet fallback.

The optimization does not remove the 1600ms fallback globally. The recognized
runtime signature is deliberately narrow; website updates can reduce fast-path
coverage without admitting an unverified response.

## Validation

Focused JavaScript tests cover decoder identity, exact input hashing, lineage,
terminal order, late errors and text, retained rounds, duplicate streams,
cancellation, and restoration. Native tests cover lease boundaries and actual
WKWebView message delivery, fast completion after fresh full proof, stale/absent
hints, delayed DOM, retained rounds, final-await mutation, cancellation, and
revocation. Installed benchmarks and live tool results are recorded separately.

The first installed trial also exposed an existing Temporary-mode check that
rejected the optimistic user message's direct `SPAN` body before ChatGPT remounted
it inside a `DIV`. That check now accepts only the observed direct body while
retaining its exact SVG outline, visibility, scope, and child-count checks.
