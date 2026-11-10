# Groq native context presentation

This is an internal presentation for newly registered Groq website threads. The
native Responses request and the locally stored transcript remain intact. It
does not establish that a signed-in website model has passed live qualification.

The adapter counts the complete rendered prompt against the existing 6,000-token
body limit and 2,000-token reserve. It first tries the inline presentation. On
overflow it can replace eligible older native data with
`{"$computa_history":"opaque reference"}`. User messages, governing rules,
current schemas, pending/latest results, browser data and unproved outcomes
remain inline. If the complete presentation still exceeds the limit, the
request is rejected before a website session starts.

## Data and authority

`computa_read_context` accepts only `{"ref":"..."}`. References contain all 128
bits of their digest in canonical base64url form. They belong to the current
task, thread, turn, model, preparation, runtime and transport. They grant no
command, browser reference, schema, permission or outcome authority.

The reader returns pieces of the original JSON VALUE token, including its
quotes and escapes. Reconstruct its UTF-8 bytes, verify the returned identity,
length and SHA-256, then decode that complete value once. Pagination cursors
become usable only after the exact native RPC response was written and its
matching output was observed in the next admitted native HTTP request.

Older command/patch fields require the actual emitted call identity, successful
HTTP delivery, a matching typed native completion and the exact matching
call/output in admitted history. A running command or an output string claiming
success is insufficient. Reader outputs have a separate committed-publication
witness. Failed writes, duplicate completions, changed scope and cancellation
cannot publish new references.

The implementation separates lexical indexing, native publication facts,
manifest projection, HTTP delivery and RPC publication into the corresponding
`GroqContextJSONLayout`, `GroqNativePublicationLedger`,
`GroqContextManifestProjector`, `GroqHistoryHTTPDelivery` and
`GroqHistoryReadPublication` types. The server retains native continuation proof
even though Groq's website transcript is cleared after each inference.

## Correctness fixes

The native runtime can serialize the same configuration with different JSON
formatting. History revisions now compare configuration values through the
same lossless parser used by native continuation verification. Original source
hashes, raw input prefixes, payload bytes and schema authentication remain
unchanged. Actual policy/configuration changes still invalidate references.

Every supported native-array inference also prepares a legitimate zero-reference
snapshot, even when inline text fits. This lets the next schema-load preview
use authenticated history without depending on an earlier overflow. Fitting
requests do not wait for completion facts. Initial string input stays inline;
it cannot discard an established history context.

## Prompt size

The registered profile omits unloaded discovery purpose hints while retaining
exact names and kinds; loading supplies the complete authoritative schema.
Known duplicate app framing is suppressed only with the complete current native
instruction blocks. Native tool call IDs are shorter actual IDs shared by every
encoder and staging path; they are not display aliases.

One exact pinned native on-request permission template has a reviewed concise
equivalent. Its full source and replacement are hash-pinned. Replacement requires
the registered native profile, an allowed exact reader, one unambiguous trusted
permission envelope and the complete original unit at its documented position.
All shell-segmentation, escalation, justification, retry, prefix-scope and prefix
ban rules remain. Mode/network text, writable roots, unknown suffixes and other
surrounding bytes are preserved. Unknown variants remain literal. Native
permissions, canonical requests and executor checks are never rewritten.

The native runtime's optional `command_output_token_limit` now gives Groq
exec/write-stdin results a 1,024-unit formatter cap. These native units are a
byte-based estimate; the final Groq tokenizer and 6,000/2,000 admission limits
remain authoritative. Exit codes and truncation notices remain visible, and
failed command outputs remain inline and ineligible for history publication.
The generic 10,000-byte tool policy remains unchanged for structured results.
The value belongs to each model's metadata, including exact catalog rows, so
switching providers does not carry a thread-wide scalar limit into another model.

## Validation and limits

The final handoff distinguishes eligible unloaded schemas from unavailable
capabilities. With a currently allowed loader, the model loads missing schemas
itself. A missing browser-entry hint appears only when no recognized browser
entry is callable and an eligible entry remains unloaded. Native `computer_v2_*`
tools control native apps; webpage tasks use the separate `browser_*` contract.
Loading still executes nothing and does not bypass binding, permissions or exact
schema validation.

The bundled schema-loading regression reproduces the observed four-tool
selection (`exec_command` plus three native-app tools), then loads
`browser_open`. It checks the exact native/display call and result pairs,
immutable history prefixes, current schema, prompt hashes and three cleanup
receipts. No command, app inspection or browser action runs:

```sh
COMPUTA_TEST_GROQ_LOADER_SELF_SERVICE=1 swift test --filter GroqBundledPreflightProducerTests/testBundledNativeComputerSelection
```

Run the controlled native fixture with:

```sh
COMPUTA_TEST_GROQ_CODING_LOOKUP=1 swift test --filter GroqBundledCodingHistoryLookupTests
```

It uses the real bundled runtime, terminal commands, patch tool and local HTTP
bridge, with synthetic model replies and no provider/account/browser requests.
Both GPT-OSS 120B and Qwen 27B paths must complete six coding steps, pass the six
fixture tests, reproduce the reference output, reconstruct the earlier native
output byte-for-byte through multiple reader fragments and join every inference
to a saved cleanup receipt. Independent checks verify the unchanged original
permission unit and the exact reviewed displayed unit and surrounding bytes.

On 2026-11-09, m17 passed 66 focused native unit methods and a separate native
process control that preserved a 6,000-byte JSON tool result exactly on the next
HTTP request. The command-only fixture retained a 22,518-byte failed command log
locally while presenting 4,308 bytes with its failure and truncation notice. Both
omitted and oversized requested limits admitted their continuation at 4,997 and
5,009 local body tokens, with three saved cleanup receipts each. The full
15-field history reader also reconstructed its 1,381-byte value in two fragments.
These checks use synthetic model replies; installed provider workflows supply
the separate live qualification evidence.

Run the command-limit and full-reader checks together with:

```sh
COMPUTA_TEST_GROQ_COMMAND_OUTPUT_POLICY=1 swift test --filter 'GroqBundledPreflightProducerTests/testBundledGroqCommandOnlyLimit|GroqBundledCodingHistoryLookupTests/testGroqCommandOnlyLimit'
```

The separate TypeScript runtime fixtures require `MACTOPUS_TEST_BUN` when Bun
is not installed at a supported location. Point it at an absolute, regular,
executable binary named `bun` that is not group/world writable. The resolver
checks the resolved filename; a symlink to an npm-installed `bun.exe` does not
satisfy that requirement. Production uses the verified bundled App Server.

This establishes a bounded harness result, not live model routing, provider
quota availability or browser coverage. Historical provenance is not imported
across turns or restarts. Existing threads without the new native registration
keep the legacy route. CAPTCHA, provider limits, uncertain website ownership and
unconfirmed cleanup remain separate stop conditions.

On 2026-11-09, installed Build 463 returned exact zero-tool markers for GPT-OSS
120B (5.624 seconds) and Qwen/Qwen3.8-27B (6.002 seconds), with verified website
selection and saved transcript cleanup. Its fresh 120B combined workflow remained
unqualified: after successfully loading native-app schemas, the model asked for
browser tools to be enabled rather than loading them. It performed no command,
patch or browser action. Build 464 advanced to two schema loads and four terminal
probes. Its failing baseline test retained a 10,214-byte result; the next local
preflight rejected 7,354 body tokens. No patch, browser action or form submission
occurred, and no third website inference started. The command-output change still
needs a passing live combined workflow; these earlier runs remain unqualified.

Installed Build 465 then completed its first tool-discovery inference, but the
second website submission restored the draft and reported an error at 3,743
local body tokens (17,086 prompt bytes). No terminal command, patch or browser
action ran. Its original ownership error and unconfirmed cleanup were retained;
the error alone does not establish an HTTP status, quota or backend cause.

A separately approved normal-browser control on the same installed build used
harmless padding to match those local byte/token counts, before the native
ownership suffix and website framing. One ordinary Send
returned HTTP 200 and the exact requested marker. The test exchange was cleared,
its tab closed and both Inspector settings restored. This excludes a blanket
size-only rejection in that control. Its content and request timing differ from
the native workflow; it neither identifies that failure nor qualifies tool use.

The opt-in invoice-fixture status capture now has distinct fixed Qwen 27B and
GPT-OSS 120B purposes and case templates. The server retains either purpose
across that fixture's tool continuations, while each child still requires the
same model, user instruction and native turn identity. The existing first-body,
outbound fingerprint, current view/document and single-failure checks remain.
Only a finite request status is saved, without headers or response bodies. A
captured status does not authorize a reply, replay or transcript cleanup.
