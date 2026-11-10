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

The fresh Build 466 workflow stopped during local evidence preparation with no
matching native task retained. Both live journal stores had reached 256 tasks;
the retained-session archival incompatibility and definitive pre-dispatch queue
handling are documented in [Website journal retention](WEBSITE-JOURNAL-RETENTION.md).

### Literal response preservation (2026-11-10)

A bounded normal-browser comparison on build 477 exposed loss in Groq's rendered reply. The same synthetic reply's Copy output matched the exact 126-byte JSON fixture, while its Accessibility text lost quote escapes, path backslashes and Markdown characters. This demonstrates why rendered paragraph text is not a lossless protocol representation. The earlier 143-byte rejected command reply was not captured, so this comparison does not establish its exact cause.

The strict follow-up distinguishes the existing verified nested JSON code-block profile from rendered fallback text. Only the literal code profile can establish response bytes. Native completion requires that proof on every terminal observation, including a final reread with otherwise unchanged text. A rendered fallback remains available for diagnostics, but it cannot release a message or tool call, even if it happens to parse as JSON. No JSON repair, byte substitution, prose clipping or action replay is authorized. Ownership, current model, first-user proof, deadlines and cleanup remain independent requirements.

The generic Groq and compact native-history response instructions require the entire visible envelope inside one JSON code block. Other providers retain their existing presentation. This is a response representation change; schema loading remains read-only and proves no task execution. One grounded terminal control on 477 does not qualify the combined coding/browser workflow, and neither this finding nor the literal change resolves earlier provider timeouts.

### Bounded stream ending diagnostics (2026-11-10)

The build 478 instrumented workflow released one schema load, then Groq restored
its draft with a generic submission error. Its matched HTTP 2xx stream prefix
contained reasoning-channel activity and no observed content before the 256 KiB
capture cap. The second session's cleanup remained unconfirmed. This is not a
completed reasoning-only response, a token count, a quota diagnosis, or a repair
of earlier failures; everything after that cap remains unknown.

The separate `groq_120b_fixture_response_stream_tail_metadata_v2` purpose extends
only this controlled GPT-OSS 120B diagnostic. V1 retains its original 256 KiB,
4,096-event, 8,192-chunk and 60-second bounds. V2 permits at most 16 MiB of offered
clone bytes, 131,072 events, 262,144 chunks and 90 seconds. Both keep 16 KiB
line/frame buffers, the same JSON depth/node limits, the same 20 closed output
fields and the same 2 KiB packet / 4 KiB private carrier limits. The immutable
native purpose determines the version; a controller packet or publication cannot
borrow another version's bounds. Neither mode retains content, reasoning,
headers or arbitrary provider error text.

The probe distinguishes finish reason, DONE, natural EOF, read rejection and
capture limits; none alone supplies an answer or execution proof. Larger bounds
do not guarantee a complete stream. Cloning tees the response and can affect
scheduling, backpressure and browser queue use, so this remains an invasive
synthetic diagnostic. It adds no response acceptance, Inspector, Send, replay,
cleanup or pacing authority. Ordinary model requests keep the probe disabled.

### Format-failure evidence coverage (2026-11-10)

The fresh private build 479 workflow completed two schema-loading responses,
then rejected its third reply as `unsupported_website_response` before any task
action. All three owned website sessions closed. The fixture did not pass.
The literal source rejection does not establish whether the provider ignored
the requested fenced format or the page used an unsupported representation.

Two independent diagnostic gaps prevented that run from retaining useful failure
evidence. The native failure-store parser did not admit Groq's exact transport
format-error envelope, so record construction returned nil before append or I/O.
Separately, the stream probe's closed trigger list omitted the new transport
format-error category, so it did not publish its existing metadata before cleanup.
Neither observation is evidence of storage exhaustion or a provider stream cause.

The follow-up keeps strict literal verification. Its persistence change admits
only the existing exact native Groq envelope. Its stream publication change is
limited to the already opted-in v2 synthetic fixture purpose; v1 and ordinary
requests retain their previous trigger set. Diagnostics do not supply response
acceptance, execution, retry or cleanup authority.

### Late stream error captured (2026-11-10)

The fresh build 480 diagnostic workflow failed on its second inference after one
schema-only load and no task action. Its matched response had HTTP 2xx headers,
then a complete, uncensored SSE observation reached natural EOF with an in-band
`invalid_request_error`, reasoning-channel activity and no answer content. The
closed error-code projection was `other`; its actual value and message were not
retained. One website session closed and the failing session's cleanup remained
unconfirmed. The native failure record and the pre-cleanup stream packet were
saved separately. This is not a workflow pass.

This establishes an in-stream provider error for that specific run, rather than
a successful response inferred from HTTP headers. It does not establish the
specific error code, the earlier runs' causes, or a formatting/DOM root cause.
Groq's SDK explicitly checks top-level errors within streamed data after headers:
[streaming implementation](https://github.com/groq/groq-typescript/blob/main/src/core/streaming.ts).
The matched request profile has no `tools`, `functions`, `tool_choice` or
`response_format` field. Tool-generation or validation remains a hypothesis.

The next bounded v2 projection adds only three literal observational candidates:
`tool_use_failed`, `tool_call_validation_failed` and `json_validate_failed`. These
are diagnostic hypotheses, not an asserted complete vendor error-code contract
or the observed code from build 480. V1 retains its previous vocabulary. Unknown
codes still collapse to `other`; messages, `failed_generation` and reasoning text
are not retained. The same 20-field packet, finite bounds and no-authority rules
continue to apply. No request, prompt, model setting or pacing change is implied.

### Final-text relay clarification (2026-11-10)

The fresh build 481 workflow released two responses and executed four terminal
commands in the fixture directory. It read the README and source, ran the six
seeded tests (three failing methods, including 24 permutation subtests), and
printed the incorrect seed reference. It made no edit or browser submission.
Its third inference reached the five-minute native response deadline.

That inference's complete stream projection reached natural EOF with `stop`
and `[DONE]`, recognized reasoning, and no recognized string answer content or
tool calls. The page remained user-only across 19 admitted reads. These facts
explain the missing supported answer in this run; the existing diagnostic parser
is not a strict validator of every alternative answer shape, so they do not
exclude unrepresented refusal, array-content or message forms. No raw reasoning
was inspected or retained. The provider's exact cause remains unresolved and
the separate build 480 in-band error is not retrospectively explained.

The next controlled change appends exactly one outer-handoff sentence:
“Emit JSON in final assistant text, never reasoning or API tool calls.”
It disambiguates the text relay from provider-native tool channels. Existing
fence, schema, policy, grounding and handoff prose remain byte-identical. This
is a testable clarification, not a claim that channel ambiguity caused or now
prevents the failures. Native body-budget checks still cover the added text.
Reasoning and private diagnostic packets never become executable responses.
The five-minute empty-response wait remains a separate termination issue.

### Explicit no-API-tools experiment (2026-11-10)

The fresh build 482 workflow failed on its second inference after one schema
load and no terminal, editing or browser action. Its matched HTTP 2xx stream
reached natural EOF with the explicit code `tool_use_failed` and type
`invalid_request_error`, recognized reasoning and no recognized string answer.
The exact error message and attempted tool were not captured. One session
closed; the failing session's cleanup remains unconfirmed. The extra handoff
sentence did not prevent this failure; its causal effect is not established.

The next experiment adds only `tool_choice: "none"` to one exact owned
GPT-OSS 120B fixture request. Groq documents this as the default when no API
tools are supplied, so an explicit parameter is a testable hypothesis, not an
established repair. It does not disable server-side tool validation or register
Computa tools with Groq's API. Computa still accepts only verified literal
assistant text through its existing response codec.

The transform requires the separate private purpose
`groq_120b_fixture_tool_choice_none_v1` and current registered native history.
Ordinary sessions and all earlier diagnostic purposes remain observation-only.
Only a stable data-only request initialization object and the exact existing
six-field body can produce a copied seven-field request. The original caller
object and original body remain intact; header contents and authentication
material are not inspected.
Unmatched, stale or unsafe inputs pass to the original fetch once without a
matched-transform claim. A matched diagnostic attests the reviewed outgoing
arguments, not backend parameter adoption or successful model behavior.

Existing ownership, literal response, tool policy and cleanup checks are
unchanged. Diagnostic stream metadata never becomes an answer, a tool call,
or authority to replay an uncertain action. Live qualification remains open.

### Verified reply followed by tool-discovery refusal (2026-11-10)

Build 483's fresh workflow released two verified literal replies and cleared
both website sessions. Its one schema-only load requested and received
`apply_patch`, `exec_command`, `computer_v2_open` and `computer_v2_fill`.
The second reply claimed browser tools were unavailable, without requesting
another schema or attempting a terminal, editing or browser operation. The
independent coding/browser oracle failed. A valid final reply and closed
sessions do not establish completion of the user's task.

The private request-experiment arm was absent afterward, and its failure-only
capture produced no packet. This does not attest that either outgoing request actually
contained `tool_choice: "none"`, or establish an improvement over build 482.
Source inspection preserves the loader and browser-entry discovery after that
four-tool selection; page action schemas intentionally await an open/bind.
The exact second website projection was not retained, so a delivery defect
has not been excluded. The next diagnostic measures the admitted discovery
contract without storing prompt text or changing response/action authority.

### Literal-format rejection before the parser (2026-11-10)

The ordinary build 484 task loaded `exec_command`, `browser_open`,
`browser_bind` and `browser_tabs`. Its two saved native discovery records
confirm the loader remained offered and the second request offered both
browser entry schemas. The second inference failed literal-format verification
before response parsing. No terminal, editing or browser action was dispatched;
both website transcripts closed and the failure record was saved. Native
discovery and prompt fingerprints alone do not prove the website's exact
received text or the unsupported reply's representation.

The armed rejected-reply capture stayed unused because that writer previously
ran only after the transport returned a complete reply to the parser. Groq's
initial and final literal checks throw earlier. This is a diagnostic coverage
gap; neither the raw reply nor its layout/generation cause was retained.

The follow-up reuses the exact-task arm and atomic private writer at those two
unchanged checks. It captures only the candidate already returned by the
adapter, labelled `rendered_nonliteral` with no response authority. The exact
configured directory and attribution arrive through native admission, never
page fields. Current task, owner, model, document, submission and deadline
checks guard publication. No new page read, Copy operation, request, repair,
replay or acceptance path is introduced. The original format error and cleanup
rules remain intact. A captured candidate may explain its apparent format;
it does not establish authored literal bytes or prove a selector cause.
