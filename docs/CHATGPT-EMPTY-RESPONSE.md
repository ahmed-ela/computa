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

A separate instrumented long-response diagnostic returned content outside the
required response envelope. The runtime translated that local format error into
a generic "high demand" error; that generic text is not evidence of a provider
outage. Computa's current UI retained the specific local diagnosis, but the
failure-history allowlist did not persist the new error classification.

A later fresh greeting failed before provider dispatch because both local
transaction stores had reached their 256-task active limit. Finally, terminal
provider errors were projected into the same `Waiting` state as interruptions.

## Changes

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
