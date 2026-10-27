# ChatGPT empty-response investigation

## Observed failures

The installed 0.7.0 (270) app submitted and verified the complete prompt for
the October 26 failed email task. ChatGPT became idle without exposing an
assistant message or a recognized error. Computa waited until its 300-second
response deadline. No local tool ran. The owned website session closed.
The upstream cause of that particular empty response is not established.
A bounded re-query of the app-owned WebKit logs found that the adjacent HTTP
429 resource was first scheduled at 05:18:26.432 UTC, after the adapter observed
an idle page with no assistant at 05:18:25.983 UTC. Its endpoint and method were
not retained, so it does not establish a failure of the initial model request.
The original observer never armed, and request metadata capture was off; no
decoded terminal, content, or error evidence was recovered. Closing the owned
tab removed its observer and page state. Later passing requests cannot recover
that evidence or establish the original upstream trigger.

The October 27 follow-up found a separate diagnostic defect before the new
controlled trial: the opt-in decoded-metadata hook still imported an old
hard-coded runtime and required the old validator binding. The ordinary
completion observer already used observed runtime discovery. Merely updating
the diagnostic's runtime identifier would also make the two observers wrap the
same decoder method independently, causing one to reject the other's wrapper.
The capture path now shares the verified decoder tap, with independent
completion and diagnostic lifetimes. This fixes a capture defect, not evidence
of the original empty-response trigger. Finite diagnostic counts describe the
leased view; when multiple decoder instances or input messages are observed,
they cannot alone attribute content or an error to the submitted prompt.

Separate controlled, unsent `example.invalid` email drafts reproduced another
failure: ChatGPT rendered a native email card. Computa's ordinary-prose
compatibility path accepted the card's controls and suggestions as the final
answer. These reproductions establish a response-format bug, but do not prove
that the original empty response took that path.

An offline structural probe of a retained website renderer found another
plausible explanation for zero text markers: its writing-only branch can omit
the assistant Markdown marker. The actual card descendants and the original
page's layout mode are unknown, so this is a hypothesis, not a reproduction.
Opaque or widget-only content must not be classified as a proven empty stream,
accepted as a completed action, or replayed automatically.

The completion observer also rejected the current website runtime because its
asset/module identifiers had changed. The decoder method's verified source
remained unchanged. This disabled the event shortcut and explains fallback use;
it does not establish why ChatGPT produced no assistant message.

Build 272's scoped inspection exposed another discovery problem: only 64–74
recent resource records remained, with no startup runtime record. The website's
loader clears resource timings when its buffer fills. Its loaded assets also use
`link` initiators, which the observer's script-only filter rejected. Looking up
startup assets only when a prompt is submitted cannot survive that lifecycle.

Later on October 26, build 274 completed a new Instant task through the quiet
fallback while both inference observers reported `runtime_cache_unsupported`.
A separate controlled built-in ChatGPT tab exposed one initialized decoder in
the observed public runtime. Its `recordCompletion` method had the same body,
but the validator identifier had changed from `T` to `x`. The literal source
comparison rejected that minifier-only change. Recognition now permits only
consistent identifier renaming in the exact complete method grammar; method
shape, operations, descriptors, unique identity and input ownership remain
required. Finite cache-stage diagnostics distinguish this guard from cache,
getter and ambiguity failures. This explains the later observer failure, not
the upstream cause of the original blank reply.

That new task also stopped after an empty browser inventory, claiming compose
controls were unavailable. The native catalog intentionally withheld page
operations until a page was bound, but the inference contract did not explain
the transition. A separate notice now identifies only registered native tools
deferred by that binding state and the currently offered entry operations.
Successful open/bind refreshes the next callable catalog. The notice does not
make a deferred tool callable or grant action permission.

A build276 attachment fixture stopped after filling recipient and subject,
claiming local relay actions were unavailable despite a current writable body
field and enabled Send button. No POST occurred. The exact offered catalog was
not retained for that attempt, so its semantic cause is unresolved. Finite
per-inference diagnostics now record native browser capability masks and parsed
policy after projection, without prompts, page contents or schema text.

The exact same controlled task in build277 exposed a confirmed app-side cause
of a missing final answer: the local message was delivered exactly once, but
Computa rejected inference 11 before provider startup. Ten complete canonical
prompts had consumed 934,397 bytes; the next 131,032-byte request exceeded the
old 1 MiB cumulative limit by 16,853 bytes. Its current browser tools were
present and allowed. The request was within the existing 160 KiB individual
limit and 16-inference allowance. This cumulative budget charged repeated full
history and could terminate legitimate work after an irreversible action.
The delivery was not replayed. This reproduction is distinct from the original
build270 empty provider response and build276's unsupported capability claim.

The build280 fresh diagnostic trial captured a new premature final in a local
mailbox: all fields were filled, but the model returned an unsent final instead
of invoking the available Send control. Six provider responses verified; there
was no failed tool, denial, missing browser function, or POST. The initial
instrumented view returned nonempty content without a decoded error. This is
not the original empty response. Input-receipt scope is a plausible presentation
ambiguity, but the model's internal reason is not established; details and
failed-trial evidence bounds are retained in the qualification report.

A separate instrumented long-response diagnostic returned content outside the
required response envelope. The runtime translated that local format error into
a generic "high demand" error; that generic text is not evidence of a provider
outage. Computa's current UI retained the specific local diagnosis, but the
failure-history allowlist did not persist the new error classification.

A later fresh greeting failed before provider dispatch because both local
transaction stores had reached their 256-task active limit. Finally, terminal
provider errors were projected into the same `Waiting` state as interruptions.

## Changes

- Scope browser input receipts to that input, preserving unverified outcomes and
  no-replay behavior. Refresh conditional form-submission guidance after website
  history: verify current field values and submission state, perform a distinct
  authorized pending submit once, then verify its receipt. Draft-only scope,
  governing rules, approvals, Stop and uncertain-outcome verification remain.
  This addresses a presentation ambiguity; live model adherence is qualified
  separately, and no final message is coerced into another action.
- Require the ChatGPT response envelope, including ordinary final messages.
  Explicit relay instructions keep drafts in `message.text` and actions in
  Computa's offered tools. Native card/prose output is rejected without an
  automatic correction request or action replay.
- Retain a bounded set of completed runtime resource observations from document
  start, including module preloads, across the website's timing-buffer clears.
  Locate the one observed runtime and inspect its bounded initialized module
  cache. Wrap only the uniquely verified decoder method. Unsupported or
  ambiguous runtimes retain the normal fallback; finite diagnostic reasons
  identify the discovery, import, cache or identity check that failed.
- Recognize exact-prompt-owned terminal empty/error streams. A failure receipt
  must pass fresh document, session, submission, model and empty-DOM checks.
  An idle page, first HTTP error, missing event or diagnostic alone cannot end
  a request. Late content revokes the empty-stream receipt. No request is replayed.
- Display terminal errors as `Failed`, including restored history. User and
  native safety interruptions retain their distinct waiting behavior.
- Persist the exact canonical ChatGPT response-format failure so reopening a
  chat retains the specific diagnosis instead of a generic runtime error.
- Derive the cumulative byte budget from the existing finite count and
  per-request limits: 16 × 160 KiB for canonical prompts, and 16 × 180,000 bytes
  for the transport's marker-inclusive submissions. Every actual byte and
  correction attempt remains charged. Keep ownership, cancellation, correction
  deadlines and no-replay checks. A limit still stops execution; its persistent
  error tells the user to review earlier actions before continuing.
- Refresh completion guidance after canonical history on every website response.
  A final message ends the turn; an unfinished action is not a completed result.
  Plans, summaries and partial observations are final deliverables when requested.
  Preserve necessary clarification, governing-rule refusals, observed blockers,
  permissions, Stop and no-replay behavior. This addresses instruction ambiguity;
  model adherence still requires live qualification.
- Preserve closed journals in a durable SQLite archive before removing them
  from the bounded active set. Recover interrupted retirement under the shared
  writer lock, retain historical identity checks, and protect unresolved or
  running tasks. Native chat history is retained.

## Qualification boundaries

Use synthetic greetings, unsent drafts, terminal markers and a local mailbox
with an independently checked receipt. Never replay the failed real email as
a software test. Record the installed artifact and each completed outcome;
passing fixtures do not establish universal provider reliability. Validation
and installed results are recorded in `EMBEDDED-PROVIDERS-QUALIFICATION.md`.
