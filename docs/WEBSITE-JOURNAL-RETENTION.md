# Website journal retention

Website inference evidence and cleanup receipts are partitioned by native task
and turn. Each store admits at most 256 active task directories. Before a new
turn starts, the retention store can move verified terminal history into its
SQLite archive, preserving the original journal files as byte-for-byte BLOBs.
Protected, uncertain, incomplete and unfamiliar histories remain in the live set.

On 2026-11-09, both installed stores reached 256 tasks. A private copy reproduced
the capacity refusal even with no protected tasks. The old archive validator
expected a separate start and cleanup receipt for every inference. Retained
website conversations instead reuse one physical session across tool rounds and
save their final cleanup receipt when that session closes. A verified nine-round
Gemini conversation with a saved final receipt exposed this incompatibility.

The retained-session validator recognizes the explicit version 2
`temporary_conversation_per_turn` serialization. It requires:

- One exact task, thread, turn, runtime generation, preparation, provider, model,
  physical token, document and first-user fingerprint throughout the chain.
- An initial start followed by contiguous completed/yielded and continued
  inferences, with matching sequence, response count, baseline and timestamps.
- Source-shaped metadata phases, full submission fingerprints at completion,
  and an actual saved final closed receipt linked by `release_verified`.
- Unambiguous original evidence, cleanup and summary JSON. Duplicate keys,
  contradictory ownership fields and unresolved cleanup refuse retirement.

Every inference receives its own exact identity index. The ordinary token index
still anchors to the actual final receipt. A tagged `retained_token_v1` relation
links only the validated members to that physical close; it never invents
intermediate cleanup receipts. Archived turns remain immutable. The existing
database schema and ordinary single-inference validation remain compatible.

Archive files, actual receipts and identity indexes commit in one transaction
before live files are removed. Recovery verifies the committed bytes under the
same writer lock. The tests cover all three durable interruption points, identity
collisions, malformed chains, protected tasks and unconfirmed receipts.

Local preparation can fail before the current user prompt reaches native
`turn/start`. Core now creates `PromptNotDispatched` only at that boundary.
AppState uses this native type to retain the failed prompt with a definitive
non-delivery indication and a paused queue requiring manual resume. Earlier
thread setup may have occurred. A shared persistence error, matching RPC prose,
cancelled submission or lost acknowledgement provides no equivalent proof.

Run the retention and dispatch regression suites with a verified executable
named `bun` configured through `MACTOPUS_TEST_BUN`:

```sh
swift test --filter 'WebsiteJournalRetentionStoreTests|WebsiteJournalRetainedSessionArchiveTests|WebModelRuntimeRoutingTests|AppStateQueueTests'
```

These local tests use synthetic transport responses. Live model and browser
qualification remains a separate check.

The repaired code also admitted a new task against a disposable copy of the
saturated journals in about 0.10 seconds. It retired one verified closed task,
kept each store at 256 tasks and recovered the exact original evidence, cleanup
bytes and receipt. The live journals and all 952 frozen source files stayed
unchanged during that probe.

On 2026-11-11, both installed stores again reached 256 tasks. A fresh Qwen Max
fixture stopped before native turn dispatch. A disposable copy reproduced the
capacity error with no protected tasks. The archive contained 721 committed
operations and had space for additional history.

A saved schema 4 receipt can establish that native startup rejected the
request before it created a website session. Retention now recognizes the
matching tokenless `start_requested` and `failed` records. Each inference must
have exactly one saved rejection with matching scope and a timestamp between
those records. The original journal bytes and inference identity move into
the archive together. The receipt keeps its `no_owned_session` outcome, and
the archive records no session token for that inference. Older builds can
continue to read the existing closed-receipt index after a rollback.

On a fresh copy of the same snapshot, the repaired store admitted a new task
in 0.192 seconds and kept both stores at 256 tasks. The archive contained the
two original journal files byte for byte and the saved rejection. Its existing
rows and all unresolved live records were preserved, and SQLite integrity
validation passed.
