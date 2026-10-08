# Website inference transactions

Computa keeps canonical conversation history, terminal sessions, browser-tool
tabs and file diffs locally. The Responses bridge sends the full current
request, including offered tools and their outputs, to a website. Each API
inference therefore uses a new owned temporary website conversation. Reusing a
website conversation would append duplicate full histories and eventually
depend on old message nodes that the site can virtualize away.

An inference conversation is distinct from a native user turn. A turn may need
many inference conversations while retaining one native thread, turn, command
session and browser-tool lease. The website sees the current canonical request
on each continuation; temporary-site history is not Computa's source of truth.

## Responsibilities

| Component | Responsibility |
| --- | --- |
| `CodexAppServerRuntime.Core` | Prepare context before the native RPC, register the actual native turn, retire it on completion/Stop, and finish maintenance before starting the pending user turn. |
| `WebModelServer` | Admit the exact request identity, own each website lease, validate model/document/prompt proof, and withhold output until durable cleanup. |
| `EmbeddedWebModelTransport` and provider adapters | Execute guarded website operations and report observed finite state; never infer ownership from a matching title or URL. |
| `WebsiteSessionCleanupStore` | Persist exact cleanup transactions and a bounded presentation summary. |
| `AppState` | Display cleanup state and permit an identical unsaved receipt to advance to saved. Presentation history never recreates live authority. |
| `EmbeddedBrowserToolController` | Own the separate task browser lease and fresh action capabilities across model inferences. |

## Native identity and handoff

The host prepares a canonical task/thread/runtime scope and a fresh preparation
nonce before `turn/start` or managed compaction. The native engine supplies its
actual thread and turn in `x-codex-turn-metadata`; the request body may also
carry that JSON string inside `client_metadata`. When both are present they
must agree. The bridge waits for the matching host registration event for at
most five seconds. It does not substitute a user-supplied ID or poll for one.

Registration requires the same preparation nonce, server generation, native
thread and active turn. Delayed acknowledgements and notifications from
completed, stopped or restored historical turns cannot register a newer scope
or turn a completed task into a server failure.

## Inference lifecycle

1. Save `start_requested` before asking the transport to create a conversation.
2. Retain the returned UUID lease, save `started`, and verify the requested
   concrete model and product mode.
3. Submit once, save `submission_verified`, and observe completion through the
   transport's event-driven page waits. Website sequence is always one and its
   response baseline is zero for this fresh conversation.
4. Require current model, document generation and first-user-message proof;
   parse the strict response envelope and save `complete`.
5. Close only that owned lease, synchronize and read back its exact linked
   cleanup receipt, then save `release_verified` with that cleanup attempt ID.
6. Only then return HTTP/SSE output or release native tool calls.

An uncertain mutation is not replayed. Failed closure retains the exact lease.
A physically closed conversation whose receipt could not be saved retains a
pending persistence transaction; retry saves the same receipt without issuing
another website close. A failed or lost Start acknowledgement retains an
unresolved start attempt and blocks further inference rather than guessing a
token or borrowing an earlier closure. Public finish/cancel revokes prepared
context before cleanup; private inference cleanup preserves native context for
the next tool continuation.

Build 38 lets a native-approved same-document first route, followed by its
local-to-public promotion, continue one already-clicked ChatGPT display
expansion. Each edge must match the candidate's previous URL and the current
native URL. The exact physical document, message root and body, private owner,
prompt, marker, user count, model choice, product and temporary mode must remain
valid. The original 1.8-second deadline and captured prefix stay fixed; the full
canonical content may differ only by collapsed ASCII whitespace runs, with one
unique final marker. Crossed reads are discarded. Continuation issues no extra
click or Send and grants no lineage until normal full-body proof succeeds.
Cleanup never receives expansion or route-continuation authority.

A distinct timing boundary remains: if the public route arrives before the
next native inspect captures its entry URL, the preceding edge's destination no
longer matches. The consumed candidate fails closed instead of adopting that
uncertified edge. Tests for two sequentially consumed edges do not establish
success for this pre-entry timing; installed provider qualification remains
separate.

## Durable evidence

New schema-2 journals are scoped to one native turn:

```text
WebsiteModelEvidence-v1/transactions/<task>/<turn>.jsonl
WebsiteSessionCleanup-v1/transactions/<task>/<turn>.jsonl
```

The last-64 cleanup summary supports the UI; it cannot replace an inference's
primary closure record. Existing legacy flat evidence is preserved separately.
Writes synchronize and verify exact bytes before publication. Per-turn,
per-task and global bounds produce finite failures instead of unbounded writes.
Website evidence contains identity, structural counts, finite phases and
fingerprints, not prompt text, tool payloads, responses, cookies or credentials.

Qualification must correlate each inference's native context and release with
its exact durable cleanup attempt. A later `no_owned_session` observation does
not prove an earlier conversation was closed. See the [workflow
benchmark](HARNESS-WORKFLOW-BENCHMARK.md) and [built-in browser
contract](BUILT-IN-BROWSER-TOOLS.md) for distinct execution and page-action proof.
