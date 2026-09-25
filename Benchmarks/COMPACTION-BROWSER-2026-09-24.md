# Browser compaction failure — 2026-09-24

Status: source repair, 25 targeted native regressions, the full app suite, and
both real-Qwen continuation gates passed. The image gate passed three serial
runs with three distinct image hashes. The updated debug app is open and connected.

## Observed cause

The failed 19:33 PDT turn contained nine calls and nine outputs with unique,
nonempty call IDs and no orphaned pairs. The old runtime's `MAX_PAIRS = 8` guard
reported a shared "duplicate, empty, or excessive function calls" error. This
was the ninth-call count limit, not duplicate IDs.

Call order: open, open, snapshot, rejected click, capture, compaction, click,
capture, compaction, click, capture, count-limit stop. The failed turn lasted
28.093 seconds. The first rejected click used an AX snapshot ID as a capture ID;
the existing screenshot requirement correctly blocked it. The target point lay
inside an accessible link supporting AXPress.

Each of the three captures triggered compaction before normal model continuation.
Both successful compactions dropped every image, including the screenshot needed
by the next action-planning request. Later clicks reused the same coordinates, and
all three screenshots were byte-identical. This establishes unchanged visible
pixels, not proof that every dispatched action had no effect.

| Capture | Context before compaction | Estimated compacted context | Next actual prompt |
| --- | ---: | ---: | ---: |
| 1 | 7,303 | 2,637 | 4,552 |
| 2 | 6,710 | 2,817 | 4,829 |
| 3 | 6,984 | Count guard stopped | None |

The effective context was 7,782 tokens. Images were 748 x 1083 at high detail,
757,946 decoded bytes; each image-bearing result serialized to 1,011,054 bytes
with only 347 text bytes. This is one failed user turn, not a performance corpus.
Only metadata/counts were examined for this report; page contents, delivery
details, screenshots, and raw traces are not included.

## Source repair

- Keep up to 32 paired calls without increasing the 12 KiB text/header ceiling.
  A bounded set of shared excerpt budgets preserves call IDs, arguments, output
  identities, failure status, and order rather than dropping completed actions.
- Preserve exactly one bounded image from the most recent completed output.
  Older images are explicit omissions; a newer text result prevents reusing an
  earlier screenshot. Native context-fit, freshness, and approval checks remain.
- Give empty-ID, duplicate-ID, count-limit, and image/byte-budget failures distinct
  diagnostics. Overflow still stops; the history is not silently corrupted.
- Direct accessible targets to `computer_v2_ax` with `AXPress`, explicitly separate
  snapshot IDs from capture IDs, and discourage blind repeated clicks.

New native mock-provider tests exercise nine calls, continuation, a tenth call,
and a second compaction. They check original identities and failure state,
once-only dispatch, byte budgets, and the exact latest image in the next provider
request. Unit tests cover shared budgeting, idempotence, malformed receipts,
image age/order/type/size, and the 32/33 boundary. All passed.

## Validation results

| Check | Result |
| --- | --- |
| Native receipt/history and provider-request regressions | 25/25 passed; 1.371 s test execution, excluding compilation |
| Full Xcode suite | 545 passed, 26 optional live tests skipped, zero failures |
| Real Qwen 4B text retention, no repeated action | Passed; 29.437 s whole fixture |
| Real Qwen 4B image retention and correct unseen color order | 3/3 passed; 22.423, 24.540, 26.631 s whole fixtures |
| WebUI type checking and regression suite | Passed; 41/41 tests |
| Runtime build and signed app verification | Passed; app-owned `heydash-2` bundled |

Live gates use `lmstudio-community/Qwen3.5-4B-MLX-4bit`, the shipping 8,192-token
declared window and 6,144-token auto-compaction threshold. Each requires exactly
one synthetic status call, one native within-turn compaction, no desktop action,
no history injection or manual compaction RPC, and successful final continuation.
The fixture timings include warmup turns and are not single-click latency or an
Amazon before/after speed benchmark.

A separate opt-in real-Qwen gate returns a newly randomized synthetic color
image from a strictly read-only tool fixture. It requires one tool call, one
native mid-turn compaction, the correct color order, and byte-identical retained
image evidence. The summarizer can also see the image, so correct final text alone
is not proof that continuation independently decoded its pixels. The native
mock-provider request assertions supply complementary transport-level evidence.
All three image runs dispatched exactly one status call with no unexpected
requests, used separate isolated homes and freshly generated images, and had
zero failures. This is a small regression check, not a broad accuracy benchmark.

The core-scoped Clippy fix/check completed. Three warnings in the changed code
were addressed with controlled retention errors and a descriptive test assertion;
an unrelated upstream unused-import cleanup was not retained. Formatting and
native source whitespace checks passed. The reviewable patch applies in reverse
without conflicts to the exact pinned source. No whole Rust workspace test run
was performed.

## Runtime identity

- Source: `4607249e430dac1c961df4dc615beae88e33cec8`
- Runtime: `heydash-2`, arm64 macOS, development validation build
- Patch SHA-256: `ca36f16a32bd5d6b8651adea6b1d28f6054b44392e806ef370d63dba6ac83428`
- Signed runtime SHA-256: `0b93296fa63b89065398a73d3c763c187225061cd8e0bc1402c93e215c5b4130`
- Runtime size: 290,912,864 bytes

The reopened debug app reported `Local runtime connected`. Process inspection
verified the running app owns an App Server child from its own bundled
`Contents/Resources/AgentRuntime` path, with the signed runtime hash above.

The generated runtime is ignored by Git and built from the committed pin/patch.
Native freshness, approvals, failure results, and final context-fit checks remain
authoritative. This fixes the measured truncation/count failure; it does not prove
universal browsing competence or completion of the user's private Amazon task.
That task was not replayed.

## Validation environment

The internal disk had approximately 3.7 GiB free; the previous Rust build profile
was no longer present. A fresh pinned runtime compile/test needs additional
space. Available space subsequently rose to approximately 10 GiB without any
assistant cleanup, allowing a bounded two-job cold build. No user files, model
weights, system caches, or StudyLock state were removed. The rebuilt debug app
contains the corrected runtime; the installed Applications copy and installed
Codex app were not modified. Runtime binaries and isolated raw test traces are
not published to Git.

Local test logs:

- `/tmp/heydash-receipt-runtime-tests-20260924.log`
- `/tmp/heydash-compaction-xcode-20260924.log`
- `/tmp/heydash-compaction-live-20260924.log`
- `/tmp/heydash-compaction-image-repeat-20260924.log`

## Local diagnostic source

Private rollout (not copied into Git):
`~/Library/Application Support/LocalCodex/CodexHome/sessions/2026/09/24/rollout-2026-09-24T18-51-48-01a0d642-f894-7890-b379-c37bd559fb9d.jsonl`

Failed turn: `01a0d668-cdf3-7143-b512-a173d01bced0`. Calls/results at lines
202-241, 258-270, and 287-299; compacted checkpoints at 248 and 277; error at 301.
Native diagnostic rows 606040, 606244, and 606437 identify threshold-triggered,
not full-context-triggered, compaction after each capture.
