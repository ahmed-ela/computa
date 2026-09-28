# Computa compaction history repair — 2026-09-24

Prose uses the current product name, Computa. Historical artifact paths,
identifiers, quoted records, and measured results retain their original values.

## Outcome

Latest: the approved app-owned runtime is implemented and the native regression
suite passed. Its fixed five-sample strict series passed **4/5 overall**; all four
runs that actually reached within-turn compaction retained the exact key and
executed the requested action only once. The other run failed before compaction
on Qwen instruction following. See **Final app-owned runtime validation** below;
the earlier failures and superseded implementation notes remain chronological
evidence, not claims about the final candidate.

The development runtime now serializes idle automatic compaction and preserves
bounded genuine assistant history before admitting the next user prompt. Native
context-ring and Ask/Full-access behavior remain in place. **The long-context
4B model-quality gate is not fully green**. The first strict automatic series
passed 1/2; a later fresh production run also passed (2/3 observed in total).
The failure was an exact-character copying error despite correct retained source
text. The follow-up below records a separate native within-turn repeated-tool
failure; it is not hidden by the passing idle-maintenance results.

No commit, push, installed-app replacement, or StudyLock change was made. Prior
rename, UI, queue, grounding, and unrelated benchmark work remains preserved.

## Exact-request causal experiment

An actual fresh failed post-compaction provider request was captured on fixed
loopback and replayed without any tool executor.

| Variant | Correct exact key | Observation |
| --- | --- | --- |
| Original failed request, warm | 0/4 | Returned the expired `KEY_SAVED` acknowledgment |
| Identical request after model unload/reload | 0/4 | First request had zero cached tokens and still failed |
| Original plus the actual prior completed assistant reply | 4/4 | Only 12 additional input tokens; no sampler/user/policy/tool changes |

Missing assistant-role history explains this captured failure better than cache
reuse. This is one request, not a generalization success rate. The cache reset
restored the model's original 123,648 context / parallel-4 configuration.

The diagnostic helper uses private bounded artifacts, fixed loopback upstream,
no saved headers, no hosted tools, and no tool executor. Its 12 tests and 53
assertions passed. Raw recording remains opt-in and disabled in the shipped app.

Evidence: `../../outputs/HeyDash-context-replay-2026-09-24/`, with `warm-exact`,
`cold-then-warm-exact`, and `warm-assistant-history` replay directories.

## Production behavior

At a measured 6,144-token footprint, the next idle submission performs native
compaction before delivering its unchanged prompt. The task remains reserved
through the compact RPC acknowledgment, exact completed compaction item,
successful enclosing turn, and durable assistant-history append acknowledgment.
Early lifecycle notifications cannot be lost. Maintenance never publishes a
premature user-task completion or drains the queue.

Only the latest real final assistant reply from a successfully completed turn
is preserved. Replies within 2,048 UTF-8 bytes remain unchanged; larger replies
become explicitly labeled first/last excerpts within that same total bound.
The record stays assistant-role text, never user/developer authority. No tool
calls, reasoning, approvals, or live capabilities are restored. No extra model
call is introduced beyond the existing native summarizer.

Stop during injection prevents prompt dispatch. Disconnects, invalid lifecycle,
and a 180-second timeout fail closed; uncertain appends are never automatically
retried. Unsolicited tools and approval requests during maintenance are rejected
even in Full access. The ring excludes the summarizer's own request footprint
and waits for the next real measurement after compaction.

Cold resume hydrates at most three recent native turns. Unknown usage stays
unknown, not invented for the ring or threshold. Native in-turn compaction
remains enabled for unmeasured or within-turn growth; that fallback does not
have the same synchronous assistant-history restoration barrier. The tests
declare 8,192 tokens (7,782 effective); LM Studio's actual loaded hard capacity
remained 123,648. They do not prove an actual 8K server hard cap.

## Live results

| Gate | Result | Whole-fixture time |
| --- | --- | --- |
| Fresh manual compaction, exact recall, one status call | 3/3 passed | 19.804 / 21.973 / 16.376 s |
| Long-conversation automatic compaction | 1/2 strict passes | 145.401 s failed / 116.126 s passed |
| Cold shutdown/resume, compaction, exact recall, status | Passed | 15.818 s |
| Production Ask → Full → Ask | Passed | 18.625 s |

Both automatic runs used only the requested status tool. In the failure, both
summaries and the original retained user message contained
`HD_KEEP_672B3428BEA64916B812507DB908F5EA`; the final answer instead copied
`HD_KEEP_672B3428BEA4916B812507DB908F5EA`. No summarizer corruption was found for
that key. The passing run reduced measured footprint from 7,296 to 4,114 tokens.
Times include long text generation and must not be called compaction latency.

The first follow-up full-suite run exposed an obsolete oversized-fixture
expectation: preflight correctly interrupted compaction and rejected the pending
submission synchronously; the test expected only an asynchronous failure. The
updated test still requires a real correlated interrupt, no history append, no
third prompt dispatch, and bounded attempts. No correctness assertion is relaxed
to excuse a model answer or additional tool call.

## Final validation

The final full native run passed: 387 app tests, 17 skipped, zero failures;
108 AutomationCore tests, two skipped, zero failures. This includes three live
gates: Ask → Full → Ask (17.948 s), oversized fail-closed behavior (14.279 s), and
cold-resume exact recall (16.344 s). Deterministic checks total **526 passed**:
367 app + 106 AutomationCore + 41 UI + 12 replay-helper tests. Type checking,
the production UI build, strict deep signature verification, and diff whitespace
checks passed. The separate strict automatic-quality run remains 1/2, not green.

Eight real-child-process deterministic transport tests cover lifecycle-before-
acknowledgment ordering, no premature queue completion, stop during append,
disconnect, missing item completion, exact threshold boundaries, malformed
acknowledgments, and unsolicited maintenance tool/approval denial. These tests
use a synthetic server and no model or desktop actions.

The final rendered debug app showed Ask every time after relaunch and exactly
two native access choices. Enter sent a confirmed-4B no-tools prompt, producing
`HEYDASH_NATIVE_CONTEXT_OK`. Its native Gauge and popover showed **72%, 5,615 /
7,782 tokens**. The development app remains open in Ask mode; installed app
unchanged. A preceding UI model-picker selection failed to persist and attempted
the unloaded 27B model; LM Studio's memory guard rejected the load. No guard was
weakened. The final response/ring verification used an existing confirmed-4B task.
The picker observation is not a proven application defect: the automation also
reported stale accessibility-state warnings and selected a different task once.
Source and compiled-handler review found proper native change-event forwarding;
no speculative picker patch was applied.

Evidence: `../../outputs/HeyDash-context-retained-history-2026-09-24/`.

| Evidence | SHA-256 |
| --- | --- |
| manual-three-runs.log | ca296499f5ca8696c3fcb604268d4788e0652569f63c4041074a1e1c0e51f839 |
| automatic-two-runs.log | 60bff175f0d8bceebea00cffce7587960a485e524fc15de4d8a27f9996ef47c4 |
| automatic-copy-failure.jsonl | 5bf96e09794d75a9f859253c04078539ae1285ceaa60f88d91125a69a5024e36 |
| automatic-pass.jsonl | 25a32f1a854b5897c6e8910e2b79c700caa458ae7b0c9d2f2c21668966e8d066 |
| cold-resume.jsonl | caa7e088bea1cdd6ea0e3c20f2fd263ad4ac8e00f8b1194b8b61cf4a5f089419 |
| final-validation.log | da62407a0b0ab0e30ddfc09c18923b957a1d27b8c4bfb20a484fc07fa4251d70 |

Summarization is not lossless; this patch does not guarantee exact identifier
copying by Qwen 4B. No output rewriting or hidden generation retry masks that
remaining model-quality limitation.

## Follow-up: resume, stream ordering, and paired controls

The latest fresh production automatic run passed in **139.911 seconds**, using
exactly one real read-only status call and retaining its exact key. It observed
two completed compactions, with measured footprints 2964, 5674, 8745, 6936,
4053, and 4208 tokens. This is whole-fixture time, not compaction latency.

Its exact final provider request was compared with a provenance-checked
uncompressed completed-text-history counterfactual, in five counterbalanced
serial pairs. Settings, policy, tools, current user request, and current
function-call/result suffix were unchanged. Old hidden reasoning was explicitly
omitted from the counterfactual, so it is not a literal restoration of the old
token sequence. Neither replay has a tool executor.

| Variant | Exact key / no extra calls | Input tokens | Median final-response latency |
| --- | --- | --- | --- |
| Captured compacted request | 5/5 | 4,111 | 1.308 s |
| Uncompressed completed text history | 5/5 | 11,843 | 1.538 s |

The compacted input is 65.3% smaller. This one passing fixture does not reproduce
or explain the earlier copying failure and is not a general accuracy estimate.
The initial pair had different cache-hit counts; subsequent requests were warm.
The request, explicit pairing plan, invariant hashes, and complete response
artifacts are in `../../outputs/HeyDash-context-paired-2026-09-24/`.
The two offline helper files pass **33 tests / 123 assertions**.

### Cold-resume telemetry repair

App Server publishes persisted usage just after the resume response. Computa
previously discarded it because no live turn identity existed yet. The runtime
now registers a bounded buffer before the RPC, then accepts usage only for the
exact newest completed turn in the acknowledged bounded page. It does not make
that historical turn active. Missing model provenance invalidates the number.
Delayed telemetry gets at most 500 ms; absent/invalid telemetry stays unknown
and causes one conservative preflight, never a zero-context assumption.
Valid short histories avoid the extra model call. Stop, disconnect, stale
generations, and operation identity are rechecked before prompt dispatch.

### Ordered transport repair

A real 16,982-byte synthetic tool response exposed reordered stdout fragments:
the tail of a JSONL item arrived at the actor before its head because separate
unstructured Tasks forwarded each read. Two malformed records were silently
discarded and the completed tool item disappeared. One AsyncStream consumer now
processes both chunks and EOF in order. Deterministic tests reconstruct an exact
128 KiB assistant item split across writes, including immediate drained EOF,
and require item/turn completion before connection failure.

All **18 deterministic real-child-process transport tests** passed, including
eight cold-resume cases and both fragmented-stream regressions. The first run
of the newly written resume fixture omitted the required idle status; that test
fixture was corrected to match the real resume response, without relaxing the
production validation.

### Remaining native within-turn model issue

The new live gate uses real Qwen and App Server but a test-only status executor.
It preserves normal protocol, replaces one status result with a bounded
synthetic observation, and rejects all other or repeated tool requests. It is
**not** a production desktop-broker test.

After a genuine short assistant warmup and one status result, native compaction
ran within the same user turn. The summary correctly said the status call had
completed, yet Qwen requested it again. The wrapper rejected the duplicate; no
desktop operation occurred. This failed the strict gate. Adding a generic
continuation instruction did not fix it, so that experimental instruction was
removed from production. The failing test remains opt-in and its exact-call
assertion remains unchanged.

Cold-fixture setup also exposed model over-refusal of benign benchmark wording
and excessive reasoning about exact word counts. These were setup failures,
not successful cold-compaction measurements. The filler was changed to ordinary
approximate-length prose, preserving the same measured threshold, exact-key,
tool-count, and lifecycle requirements. No StudyLock policy or enforcement was
changed. A five-minute bound now applies to each entire runtime phase.

Actual hard-8K validation is unavailable with the installed MLX 1.11.0 backend:
it auto-fits a requested 8192 to 123648. CLI and both HTTP model listings agree,
and backend logs explicitly distinguish configured/fitted/effective capacity.
The original model identifier, requested 123648 context, parallel4, and no TTL
were restored. No engine update or unsupported sampler override was made.
See `ContextReplay/LMSTUDIO-SAMPLING-NOTES.md` for the installed-source evidence.

Follow-up logs and failing raw traces are preserved under
`../../outputs/HeyDash-context-robustness-2026-09-24/`. The native access menu,
context Gauge, approval validation, and existing computer-use protections remain
intact. No commit, push, or installed-app replacement was performed.

### Final follow-up validation and handoff boundary

The final full native run passed **399 app tests, 18 skipped**, and **108
AutomationCore tests, two skipped**, with zero failures in the enabled suite.
Four opt-in live gates were enabled:

| Gate | Result | Whole-fixture time |
| --- | --- | --- |
| Production Ask → Full → Ask | Passed | 19.859 s |
| Cold automatic preflight, exact recall, one synthetic status | Passed | 68.003 s |
| Oversized retained input fails closed without looping | Passed | 25.254 s |
| Cold manual compaction, genuine assistant restore, one real status | Passed | 13.790 s |

The cold automatic fixture grew actual measured input through 2,974, 4,026,
5,415, and 6,662 tokens, stopped the owned runtime, then created a new runtime
and resumed the persisted task. No test-invoked compact operation was used.
The next unchanged submission caused managed compaction and an acknowledged
genuine assistant-history append before its user turn; the exact key and
single synthetic status-call requirement passed.

Deterministic coverage totals **557 passed**: 377 app, 106 AutomationCore,
41 UI, and 33 replay-helper tests. The known-failing native within-turn gate
was deliberately not enabled in this final green run; its two failing runs
above remain part of the result, not a passed or waived requirement.

The final signed debug build was reopened and verified visually and through
native accessibility. Enter sent the no-tools Qwen 4B prompt; its answer was
exactly `HEYDASH_NATIVE_CONTEXT_OK`. The native Gauge and popover showed **72%,
5,630 / 7,782 tokens**. The native menu exposed exactly **Ask every time** and
**Full access**, with the session-reset and macOS-permission caveats. The app
remains open in Ask mode. Strict deep signature verification and whitespace
checks passed; the installed app was not replaced.

The remaining within-turn repair is an ownership boundary, not another prompt
tweak. The installed App Server emits compaction as a notification with no
client acknowledgment barrier. Its generic history injection and steering
APIs do not promise atomic restoration of a completed function-call/result
pair before the next inference. A principled next step is an app-owned runtime
dependency that retains bounded genuine tool receipts inside compaction before
continuation. That would require a separately approved runtime-dependency
change; the installed Codex/ChatGPT binary was not modified. No race-prone
injection, fabricated receipt, re-execution, or hidden retry was introduced.

Evidence under `../../outputs/HeyDash-context-robustness-2026-09-24/`:

| Evidence | SHA-256 |
| --- | --- |
| final-validation.log | b2b0bfb90beefe230a1443e0849721fcea2822ad95e3bf17851fc8a386f06531 |
| cold-auto-before.jsonl | 561fbe0b996712c867539ac37c037a81906405c6717a0b50282e8c34baf54d0e |
| cold-auto-after.jsonl | 778abe61bc4643f7727444e19151440657bb84f60d374779dccc5b9c048d4f06 |
| cold-auto-tool-audit.jsonl | 4873ccf9a793649db86478b84257a74e2b550cd1acde5dae9167c8755f272d84 |

### Runtime dependency boundary revalidation

The follow-up read-only audit confirmed the running dependency is
`codex-cli 0.155.0-alpha.9.2`, SHA-256
`9280c0754e8f1f6b72f495d30c8c82a006dbc4995bf0492916fa0901f6bfd1f9`.
Computa's `Configuration.localQwen` still names the installed ChatGPT executable;
neither `project.yml` nor `Package.swift` bundles a separate App Server.
No local source checkout was found in the bounded temporary/workspace search,
so a precise Rust patch location has not been established.

The installed `ThreadInjectItemsParams` schema requires only `threadId` and
`items`; it exposes no expected-turn or compaction acknowledgment field. The
[official API overview](https://learn.chatgpt.com/docs/app-server#api-overview)
documents asynchronous compaction notifications and history appends, but does
not promise an atomic append-before-next-inference barrier. The lack of such a
documented client contract supports a runtime-owned retention experiment; it
does not establish that retaining tool receipts alone will fix every model
failure.

If the dependency change is approved, first pin and inspect an appropriate
open-source runtime revision. Retain only genuine completed call/result pairs
at the atomic history replacement point, preserving IDs, roles, order, and
bounded original output. Never restore an approval or live capability, promote
tool text into policy, fabricate a receipt, or re-execute the action. The existing
strict within-turn gate must pass unchanged, followed by serial production-
broker continuation tests and the existing access/compaction regression suite.
If retention cannot fit safely, failure must remain bounded and explicit.
This is a proposed validation plan, not an implemented or proven fix. The
runtime-dependency change remains awaiting user approval.

### Approved app-owned runtime experiment (subsequent update)

The user approved this dependency change. Computa now resolves only its bundled
standalone App Server, built from upstream tag `rust-v0.155.0-alpha.9.2`, commit
`4607249e430dac1c961df4dc615beae88e33cec8`, with a reviewable pinned source patch.
The installed Codex/ChatGPT binary is unchanged; no PATH fallback is permitted.
Sixteen artifact-integrity tests and eighteen managed-compaction integration
tests passed against the first packaged candidate. The latter include a
test-only causal audit barrier correction; production deadlines were unchanged.

The **first strict live within-turn gate failed** (30.859 seconds). It made one
successful synthetic status call, compacted once, and finished without repeating
the tool. The exact key survived in both the original retained user message and
the summary, but Qwen returned the old `KEY_SAVED` acknowledgment. All 1,319
transport records parsed. This is partial tool-continuity progress, not a passing
retention or general computer-use result. Compaction still removed all actual
prior assistant replies, leaving historical user instructions without their
original answer boundaries. Retaining bounded real prior replies is the next
experiment; this failure alone does not prove that hypothesis.

The first candidate manifest, full synthetic rollout/protocol/tool audit, and
test log are preserved in `../../outputs/HeyDash-context-robustness-2026-09-24/owned-runtime/`.
No commit, push, installed-app replacement, model reload, or StudyLock change
was made. This candidate is a development build, not an optimized release.

### Final app-owned runtime validation

The final candidate restores bounded genuine prior assistant replies beside
uniquely matched historical user messages, as well as genuine current-turn
function receipts, at the native atomic history-replacement point. IDs, roles,
ordering and non-content metadata are preserved. Large retained content is
explicitly truncated; repeated compaction is byte-stable within those bounds.
Retained tool-output images are replaced by an honest omission/fresh-observation
notice, not by saved live capabilities. Unsupported tool families, malformed
receipts and overflow produce an explicit error without replacing live history.
The candidate must also fit the native coarse context estimate before replacement;
this is not a tokenizer-exact or physical server-capacity guarantee.

Summarizer messages are classified `compaction.summary` before persistence, even
when a compaction attempt later fails. They cannot be mistaken for an ordinary
prior task answer by the retention helper. Existing unmarked legacy summaries
cannot be retrospectively classified with certainty.

#### Deterministic and native regression checks

| Check | Final result |
| --- | --- |
| App XCTest suite | 398 passed, 17 skipped, zero failures |
| AutomationCore XCTest suite | 106 passed, 2 skipped, zero failures |
| Focused upstream Rust tests | 20 passed, zero retries |
| Bun UI tests | 41 passed, 148 assertions |
| Bun replay-helper tests | 36 passed, 132 assertions |
| Rust formatting and focused Clippy/fix | Passed; unrelated baseline import change restored |
| Debug app strict/deep signature and whitespace checks | Passed |

The 504 passed native tests include the five opted-in live gates below; do not
add those gates again when counting tests. The full upstream Rust workspace suite
was not run. Twenty selected tests cover retained text/image receipts, exact
request shapes, repeated compaction, unsupported/overflow cases, and failure
without history replacement. They are not a claim that every upstream behavior
was tested. The first integration run's invalid synthetic message ID and PNG
fixture were corrected; the strict identity and image assertions were retained.
Its genuine missing-error-event defect was fixed in production and regression
tested. Failed candidate logs remain preserved.

#### Production-path live gates, run serially

| Gate | Result | Whole-fixture time |
| --- | --- | --- |
| Ask → Full → Ask | Passed; two manual approvals, one automatic | 18.172 s |
| Cold automatic preflight and exact recall | Passed; one synthetic status | 64.854 s |
| Oversized retained input | Passed; interrupted, no compaction loop or continuation | 24.548 s |
| Cold manual resume and exact recall | Passed; one real status | 16.659 s |

The Ask/Full gate used three distinct Qwen 4B tasks and exactly three Calculator
launch calls. Raw calls/results/completed items correlate; production AppState
assertions prove which decisions were manual versus automatic. The transport
does not itself carry an access-mode flag. The cold automatic gate resumed a
6,416-token history, compacted and restored actual assistant history before the
unchanged new user turn, then returned the exact key.

The final candidate was also subjected to five separately recorded, unchanged
strict within-turn fixtures. After the third failed, two further samples were
declared in advance; there were no hidden retries or relaxed assertions.

| Sample | Strict result | Native compaction exercised | Whole-fixture time |
| --- | --- | --- | --- |
| 1 | Passed | Once, within the current tool turn | 30.361 s |
| 2, included in full native suite | Passed | Once, within the current tool turn | 26.611 s |
| 3 | Failed exact final key | No | 11.297 s |
| 4 | Passed | Once, within the current tool turn | 28.374 s |
| 5 | Passed | Once, within the current tool turn | 30.768 s |

Every passing sample had exactly one completed synthetic status call, retained
matching native call/result identity, returned the complete original key, and
completed with `error:null`. There were no manual compaction or history-injection
RPCs in those within-turn samples. They use synthetic read-only tool outputs,
not actual desktop mutations or a general computer-use reliability benchmark.

Sample 3 returned `KEY_SAVED` instead of the requested warmup text, then returned
that old acknowledgment instead of the key after its one status call. Its 678
transport records parse; the actual key and real prior assistant replies were
present. No compaction event/checkpoint or compact/inject RPC occurred. Usage
ended at 5,653 tokens, below the 6,144 threshold. This is a real end-to-end Qwen
instruction-following failure, not demonstrated loss inside the new compactor.
It remains in the **4/5** denominator. Four successful compactions are a small
diagnostic sample, not evidence of 100% reliability. Cache reuse alone does not
explain the failure; earlier byte-identical cold/warm controls also failed with
zero cached tokens. No additional model reload or sampler change was made here.

The app still declares 8,192 tokens / 7,782 effective tokens, while LM Studio's
already-loaded model has 123,648 capacity and parallelism four. These fixtures
do not establish a physically hard-loaded 8K server limit. Their durations are
whole conversations, not compaction latency or generation-token throughput.

#### Actual development-app verification and artifacts

The final signed development build was reopened. Process inspection confirmed
Computa launched its own bundled `AgentRuntime/codex-app-server --listen stdio://`.
Enter sent a fresh Qwen 4B no-tools request and the rendered reply was exactly
`HEYDASH_OWNED_RUNTIME_OK`. Native accessibility and a screenshot verified the
context Gauge at **37%, 2,918 / 7,782 tokens** and its explanatory popover. The
native menu exposes Ask every time and Full access, with session-reset and macOS
permission caveats. The development app remains open in **Ask every time**.

The source pin remains `4607249e430dac1c961df4dc615beae88e33cec8`. The final
development artifact is an unoptimized arm64 build, not an optimized release.
The installed Codex/ChatGPT executable remains unchanged at SHA-256
`9280c0754e8f1f6b72f495d30c8c82a006dbc4995bf0492916fa0901f6bfd1f9`.
No installed app was replaced, no StudyLock enforcement changed, and nothing
was committed or pushed. Only generated project build caches were removed to
recover storage; they can be recreated by rebuilding.

Evidence is retained locally in
`../../outputs/HeyDash-context-robustness-2026-09-24/owned-runtime/`, including
all five final within-turn protocols, tool audits and rollouts, the full-suite
log, other live-gate transports, and earlier failed-candidate evidence.

| Artifact | SHA-256 |
| --- | --- |
| Reviewed source patch | 8b5e575b14ff6d8eb16fa52804094ff1d2665f945bfd5fb9020d699edf67dc3c |
| Packaged runtime executable | cca6664305c3d56e2f4f54e7f565b342540344d218df5aa1718afbacaaf9aeb9 |
| final-validation.log | 4efadc93d238271525d6113b4c5a59ee8b8c31ef58836c31b0f1004afeeae116 |
| final-within-1-protocol.jsonl | dc17388881aeab9f79070e5ddda0cfd58fd20611e9395c12051941c2f4da4372 |
| final-within-2-protocol.jsonl | 8b72682b91e7baf77aa10ef7a994797c25af4103ad289368fc6b7636ec624f96 |
| final-within-3-protocol.jsonl | dc71caa437db2c8bcb859ec93e05642d192b1466d05272eff6bf714717413d2a |
| final-within-4-protocol.jsonl | 566aa7c9a1b92327edd7e0adf2d830882991bf7caeb86f3344049601d024cf14 |
| final-within-5-protocol.jsonl | bff790810a7d7c60ffcaa1d6e29df161b7be4e356b562034225d9201ff707688 |
