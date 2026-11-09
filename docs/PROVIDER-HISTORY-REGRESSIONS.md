# Provider history regression checks

## 2026-11-09: native engine and website presentation

The Groq preflight fixture launches the verified bundled engine with an isolated
workspace and Codex home. It uses the real Responses HTTP client, native tool
registration, schema loader and tool loop. Only the model response transport is
synthetic; it never opens a provider page or uses an account.

The DEBUG observer is configured before startup. It observes the original native
HTTP input, each actual builder candidate, and its budget admission or rejection.
The fixture immediately reduces these values to finite identities, hashes,
counts and sizes. It does not persist request bodies or tool content. The
observer changes neither validation nor pacing. This synthetic fixture separately
opts into the existing zero-delay test pacer; production pacing is unchanged.

Run the two explicit diagnostic methods with:

```sh
COMPUTA_TEST_GROQ_BUNDLED_PREFLIGHT=1 swift test --filter GroqBundledPreflightProducerTests
```

The controlled sequence loads `computer_v2_status`, executes two sequential
native status reads, then returns a marker. Both profiles completed four
inferences, preserved the full 23-tool native registry and each prior call/result
pair, and confirmed all four synthetic session cleanups. The final measured
body-token counts were:

| Source profile | Initial | After loader | After first status | After second status |
| --- | ---: | ---: | ---: | ---: |
| Groq GPT-OSS 120B | 5,476 | 5,948 | 5,674 | 5,801 |
| Groq Qwen 3.8 27B | 5,649 | 5,775 | 5,940 | 5,039 |

These are separate native requests with their own generated identities. Each
candidate is measured with the source model's pinned tokenizer. The 6,000-token
body limit and 2,000-token reserve remain enforced; essential/loaded-only schema
fallbacks account for the non-monotonic counts. This sequence does not establish
that the larger coding/browser fixture fits, or qualify either live provider.

The pinned `mactopus-16` runtime deliberately omits local function-call/result
record IDs from external HTTP copies while retaining `call_id`. Stored history
keeps its record IDs. The fixture checks ID absence in the original HTTP input
and exact paired website presentation, rather than assuming another artifact's
record-ID shape. Existing continuation validation still validates supplied IDs
strictly. Older integration fixtures were also corrected to expect API-only
controls to be omitted from website presentation and to provide explicit
synthetic ChatGPT literal-text extraction evidence. Application guards are
unchanged.

An initial compile failure and obsolete fixture expectations were retained in
the private validation records. Buffered stdout also split a finite report with
an XCTest status line; the fixture now writes each encoded report directly to
stdout. The final two reports parsed completely. Across the final focused runs,
59 distinct native methods passed with no failures or skips.

## Alibaba API history control

The installed build 461 completed an independent code/terminal/browser fixture
through the configured Qwen 3.7 Flash API route in 39.739 seconds with 11 tool
calls. A fresh repeat completed the requested fixture in 73.260 seconds with
14 calls, but redundantly issued the already-applied patch after closing its
browser tab. Patch verification rejected that second call. The repeat is kept
as a separate nonclean completion, rather than a clean reliability pass.

Both final fixtures passed their six code tests, retained protected files,
recorded exactly one accepted browser submission with the matching receipt,
and explicitly closed the task-created tab. These are local fixture results;
the capture does not attest the provider's wire model.

The codec regression retains the completed custom patch and multipart browser
outputs across unbound/bound/unbound availability, both tool naming modes, and
host checkpoint/reminder additions. It also rejects orphaned outputs and newly
unavailable browser actions. It passed without a production API change. It does
not establish what the earlier provider request contained or justify suppressing
a distinct model call solely because its arguments repeat.

These additions are source-only work for build 462. Installed build 461 and
provider qualification status remain separate; no package or release was made.
