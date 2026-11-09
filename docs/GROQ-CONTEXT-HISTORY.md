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

## Validation and limits

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
