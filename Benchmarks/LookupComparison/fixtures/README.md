# Synthetic lookup comparison inputs

These fixtures are deterministic inputs for later Chrome and Mactopus/Qwen runs. They contain invented records and addresses under `example.invalid`. Adding the fixtures or passing their integrity tests does **not** establish model correctness, browser accessibility coverage, native-app access, or a successful live comparison.

`manifest.json` separates model-facing `tasks[].prompt` from evaluator-only `oracles`. Give the model only the task prompt. Do not attach the manifest, oracle values, HTML source, expected source filename, or a suggested tool sequence. Page filenames in the oracle identify expected sources; the actual run must record its observed localhost URL.

## Browser runs

From the repository root, start the local allowlisted server:

```sh
bun Benchmarks/LookupComparison/fixtures/serve.ts
```

The default base URL is `http://127.0.0.1:8765/`; a numeric port may be supplied as the last argument. The server exposes only the sixteen HTML surfaces. It returns 404 for the manifest, native text, test code, and other files, and rejects write requests. Pages make no external requests, submit no forms, use no persistent storage, and reset on reload. Their visible controls affect only local fixture DOM state; most decoy controls intentionally do nothing.

For each browser task, open its `initialPages` in separate test-owned Chrome tabs using the same base URL, preserving the user's existing tabs and drafts. Begin a fresh Mactopus chat with Qwen 3.5 4B and submit the exact prompt alone. Keep browser starting state and tab count consistent between compared runs, record any unavoidable differences, and do not leave a discovered answer tab selected as a shortcut. Capture the production app's own task-scoped observations and timing. Reload the virtualized page before every run, since it begins with only records 1-2 mounted. Close only the tabs created for these fixtures after evaluation and stop the local server.

| Task | What the evaluator checks |
| --- | --- |
| `exact-title` | Exact metadata title versus a nearly matching draft title; content reading is not required. |
| `document-content` | Actual report text versus a matching sidebar shortcut and matching toolbar button inside `main`. |
| `email-details` | Sender and current message details versus a contradictory older preview. |
| `absent-landmarks` | Readable text without main/article landmarks. |
| `long-field` | Answer beyond character 512 of one paragraph text node. |
| `continued-field` | Answer beyond 10,000 UTF-8 bytes of one field, below 16,384 bytes; the 4096-byte fragment limit requires continuation. |
| `search-discovery` | Discover a generic search affordance on an unfamiliar workspace, enter a query, open matching results, then read the separate supporting record. |
| `dialog-search-discovery` | Discover a button that opens a same-document dialog, enter a query, open matching results, then read a separate supporting record; the original navigation fixture stays unchanged. |
| `virtualized-records` | Initially absent record mounted after two observed pager actions; each page is a different DOM observation. |

A correct positive content answer needs the observed supporting content and source. Exhausting an output cursor covers only that captured source and filter; it does not establish completeness of a virtualized ledger or external collection. Record unsupported assertions, refusals, latency, inventory coverage, document coverage, continuations, and compactions separately. Do not equate a control label with document evidence, or a matching answer string with semantic correctness.

The continued-field input is intended to force field pagination; live receipts must confirm no source truncation, a retained cursor, stable immutable source identity, advancing UTF-8 spans, and supporting tail exposure. Its static structure does not itself prove Chrome AX capture behavior. Other fixtures do not independently force source-tree truncation, stale source replacement, pagination, or compaction. Those remain separate deterministic runtime tests and/or instrumented live evaluation gates. In particular, do not trigger compaction by replaying completed actions.

## Native read gate

`native-read.txt` is a separate inert input, not an HTML imitation of a native app. At the native evaluation stage, open that file as a separate test-owned TextEdit document, preserve existing documents, and issue the native task prompt from the manifest. Verify the fact through Mactopus's native application read path. Reading this source file directly or opening it in Chrome is insufficient. No native app has been opened by creating or testing these fixtures; the manifest deliberately marks this gate pending.

## Fixture integrity checks

```sh
bun test Benchmarks/LookupComparison/fixtures/fixtures.test.ts
```

These checks validate fixture/oracle consistency, structural placement of decoys, the long-field boundary, local virtualized pager logic, and server isolation. Pager checks use a tiny inert DOM stub; they do not prove Chrome's accessibility tree or the model's ability to operate it.


The held-out `search-discovery` task starts only at `meridian-home.html`; do not
preopen its support pages. Reload the home before each trial. Its search field
changes only an observed results-link destination; it does not navigate or show
answers while typing. Following the link opens a real `?q=` results route, with
an explicitly labeled results region and named records. A separate observed
record link leads to the supporting body. No source, record key, control name,
search strategy, or answer is supplied in the task prompt. Only the fixture
server provides these static local pages; no network API, form submission,
external request, or persistent storage is used.

Typing alone must remain a value change, not verified search completion. The
query/results interface and the final supporting body are separate evaluation
steps. The current host search verifier recognizes `q`/`query`/`search` routes and
structured result scopes; other site designs may remain unverified. These inert
checks do not prove live Chrome role/ancestry capture or discovery by Qwen.
