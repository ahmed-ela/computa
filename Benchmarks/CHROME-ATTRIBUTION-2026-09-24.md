# Chrome failure attribution investigation — 2026-09-24

Prose uses the current product name, Computa. Historical artifact paths,
identifiers, quoted records, and measured results retain their original values.

## Renewed quiet-window real-app trial — 2026-09-25, 03:02 PDT

**Not an accuracy pass.** The user confirmed the Mac would remain untouched.
The current development app ran a fresh Qwen 4B task through its actual UI,
asking when the Amazon package was coming using the existing Chrome session,
with explicit read-only constraints. No tool sequence, page URL, product answer,
or navigation hints were supplied. A clipboard API timeout was inspected before
retrying: the prompt was already in the composer, so it was submitted exactly
once rather than pasted twice.

- UI submit timestamp: `2026-09-25T10:02:48.812Z`.
- Runtime task start: `10:02:49.370Z`; completion: `10:03:49.434Z`.
- Submit-to-completion: **60.622 s**, **13 tool calls**, **one compaction**.
- All three native opens reused the exact preexisting ordinary Chrome PID
  `99015`, preserved the existing-profile contract, and reported no activation
  failure. The same Chrome PID remained afterward. No focus failure appeared
  in this trial; that is not a general reliability guarantee.
- Two invalid calls were rejected: `AXPress` on a node lacking that action,
  then visual grounding with an AX snapshot ID instead of a current capture ID.
  A later screenshot capture succeeded. No native input safeguards were relaxed.
- The final answer correctly reported the first two visible orders' delivered
  statuses and reasonably asked which package was intended, but also falsely
  presented a sidebar recommendation as a third delivered order.

Independent native Chrome AX inspection after terminal completion confirmed
the first two associations and placed the third claimed product only inside
the `Buy it again` recommendation section, not the displayed order list. The
retained screenshot was then decoded without modification into private local
evidence and inspected directly. It shows the recommendation in the right
column and a different third order with its delivery status in the left column.
The claim is a cross-column association error, not a verified delivery fact.

The incorrect third product name occurs in **none of the 13 pre-compaction text
tool receipts**. It is visible in the retained screenshot's recommendation
column, first enters generated text in the compaction summary at
`10:03:41.723Z`, and persists in the final answer at `10:03:49.425Z`. The evidence
therefore identifies a visual association / compaction-summary fidelity
failure. It does not establish a stale image, native focus loss, or StudyLock
enforcement as the cause. The final answer made no false StudyLock-block claim.

Private order identifiers, product names, prices, and raw screenshots are not
copied into this repository report. Source rollout:
`~/Library/Application Support/LocalCodex/CodexHome/sessions/2026/09/25/rollout-2026-09-25T03-02-48-01a0d804-808d-7f10-a521-c7a2e43bf047.jsonl`.
Private retained capture: `/tmp/heydash-amazon-trial-evidence-20260925.RoKHGR/last-capture.png`.
SHA-256 at verification: rollout
`90cee9da0e4657c4d7880d5cde9d74e9e04712a417cf96bc0554550696b18466`;
capture `030bded2ec44dfc9ef373bc3d73b45bd3157ff2cf69784cea5b0cd6a0280830b`.

The user was told the desktop was free again after the terminal response and
independent Chrome observation. Remaining inspection used saved local evidence;
no further desktop interaction, order/account change, installation, commit, or
push occurred. The tested turn is terminal and the local model was idle after
the audit; the installed app remains unchanged. Chrome access now has an observed completed real-app
turn, but the overall fast/correct delivery-lookup objective is **not achieved**.

## Readable AX text ranking parity — 2026-09-25, 02:57 PDT

**Partial native correction; not an end-to-end fix.** Document `AXHeading` and
`AXStaticText` nodes previously received +400 relevance for a label, +300 for
a value, or +700 for both. Equivalent readable text could therefore lose its
place in a bounded snapshot solely because Chrome exposed it as a value. These
two document roles now receive one +400 text-presence boost for either or both
fields. Native non-document nodes and interactive-control scoring are unchanged;
so are query/root/focus priority, geometry hints, source-order ties, observed
fields, output budgets, and all input/approval/freshness guards.

Five new deterministic tests vary document and text roles, target position,
title/value encoding, duplicated fields, query/focus/geometry priority, native
and control preservation, and both 1,000/3,000-character card budgets. The same
first-card fact now survives the six-element fixture regardless of field
encoding. Two earlier assertion setups that depended on label superiority were
adjusted while retaining their actual sibling-cue/ancestry invariants.

The complete suite passed **681 enabled tests, 33 opt-in skips, zero failures**
(714 total), with successful strict deep code-sign and whitespace checks.
This includes a new deterministic check that the two separate real-model
recovery fixtures still genuinely omit the requested status initially.

The first recovery fixture is now explicitly a **new source-unavailable case**:
the first AX acquisition lacks the target value, and the subsequent queried
acquisition exposes it. Its new case ID prevents confusing it with the earlier
ranking-omission failure. It still contains the distractor and uses the unchanged
natural prompt; no model instructions, hidden answer hints, or verdicts were
relaxed. This tests recovery when later data becomes available, not a claim that
querying repairs permanently unavailable AX data. The second case still loses
the later card's value to the real formatter's initial output budget.

Two serial real-Qwen/owned-App-Server gates then produced:

| Case | Sequence and actual answer | Through-shutdown time | Verdict |
| --- | --- | ---: | --- |
| First target value initially unavailable | open, initial; wrong `Delivered Friday`, no query | 8.141 s | Factual/recovery failure |
| Later target omitted by output budget | open, initial, query; `The delivery status for Shipment Cedar is: Expected Thursday` | 8.489 s | Correct status/recovery, exact-output instruction failure |

Both prove exact App Server receipt/identity/terminal provenance and unchanged
inherited policy; neither executes a desktop action. The strict XCTest result
is **2 failed**, for the distinct reasons above. Do not describe both as factual
errors or use the native regression pass as model reliability evidence.

The standalone extraction generator was also corrected: `limited` no longer
automatically means `UNOBSERVED`. Expected answers now follow actual emitted
target-status lines, and the runner rejects stale fixtures without visibility
metadata. All 16 freshly generated fixtures expose their target under the new
ranking; they are not a missing-information corpus. Generation, bounds/ablation
checks, and runner transpilation passed; no 16-case model batch was run.

Evidence: `/tmp/heydash-text-rank-parity-regression-20260925.log`,
`/tmp/heydash-text-rank-parity-model-gates-20260925.log`, and
`/tmp/heydash-ax-parity-fixtures-20260925.json`. Model idle was verified after
the gates. The installed app, remote repository, and StudyLock are unchanged.
No commit or push. Real Chrome/Amazon verification still needs the renewed
quiet window; the overall goal remains incomplete.

## Exact wire verification and rejected block-layout probe — 2026-09-25

**Amazon completion is still unverified. No production layout change was made.**
An opt-in byte-preserving loopback relay captured two isolated real-Qwen/owned-
App-Server synthetic cases, then was stopped cleanly. Order A again failed the
missing-status recovery gate (8.124 s complete XCTest); Shipment Cedar passed
in 8.172 s through shutdown (8.315 s complete XCTest). No desktop executor ran.

The offline redacted wire audit verifies all seven correlated Responses POSTs:

- Exact 1,779-byte production base instructions and expected Qwen 4B model.
- Exact inherited policy in model input; policy file unchanged, SHA-256
  `47ebd203f659b71526cf412119e716042b9cb80c647f643cf089a20203f65509`.
- All 12 dynamic tool names/descriptions preserved, plus one built-in
  `request_user_input` tool on the model-facing wire.
- Exact initial AX receipts including their `sibling_heading` cue; Cedar's
  targeted receipt also matched its Swift fixture and audited tool-result hash.
- Schema preservation is **not** exact: query min/max length, display-ID
  min/max, and pointer x/y minimum constraints are removed by schema conversion.
  Required fields and enums survive. Native validation still checks the omitted
  bounds. This does not explain the wrong-card answer, whose needed textual
  instruction and grouping cue demonstrably reached Qwen.

The next controlled probe replayed each recorded prefix after its initial
snapshot with either unchanged flat text or explicit direct-parent blocks.
The block transform only factors repeated terminal `parent=N` fields; it adds
no missing observations and preserves the header and exact record multiset.
It passed 19 deterministic tests / 164 assertions, including malformed ancestry,
duplicates, quoted metadata, nested groups, budgets, and the 32-link boundary.

Both arms retained identical instructions, policy, tools, and pre-snapshot
history for their case. Both used temperature 0.1, a 2,048-token output cap,
non-streaming requests, and at most one synthetic literal-query continuation.
These are direct provider replays, **not** App Server or desktop acceptance gates.

| Case / layout | Query | Observed answer | Exact contract | Lane time |
| --- | --- | --- | --- | ---: |
| Order A / flat | None | Other card's `Delivered Friday` | Fail | 3.283 s |
| Order A / blocks | None | Other card's `Delivered Friday` | Fail | 2.654 s |
| Cedar / blocks | `Cedar` | Correct `Expected Thursday`, but extra sentence | Fail | 5.193 s |
| Cedar / flat | `Cedar` | Exact `Expected Thursday` | Pass | 3.490 s |

The original raw replay summary labels all nonexact answers
`wrong_or_unsupported_answer`; that label includes Cedar's correct status with
extra wording and must not be interpreted as a factual error. The runner now
uses `nonexact_answer` for future runs; original generated evidence is unchanged.
Four single-pass lanes, different captured histories, sampling, and warm-cache
continuations cannot establish general reliability or a production speedup.
This probe gives no reason to promote the block representation. The existing
wrong-association / missing-information recovery failure remains reproducible.

Evidence:

- Private wire captures: `/tmp/heydash-wire-grounding-20260925.KQzGX6/`.
- Redacted audit: `/tmp/heydash-wire-grounding-audit-20260925.json`.
- App Server tests: `/tmp/heydash-wire-grounding-20260925.log` and
  `/tmp/heydash-wire-grounding-cedar-20260925.log`.
- Raw paired replay: `/tmp/heydash-layout-replay-20260925.4XJG3V/`.
- Reproduction helpers: `Benchmarks/AXAssociation/audit-wire.ts`,
  `parent-blocks.ts`, `parent-blocks.test.ts`, and `replay-layout.ts`.

The recorder is stopped; model idle was checked after the serial probe. No
installation, commit, push, StudyLock change, or actual Chrome interaction.
Real-browser verification requires the renewed quiet window previously requested.

## Inline heading candidate: mixed model result — 2026-09-25

**Do not call this fixed or end-to-end verified.** The formatter now supplies a
bounded `sibling_heading=#id:"label"` alongside static text when there is exactly
one observed heading sibling in the same validated non-landmark document group.
It does not infer semantic ownership. The lookup is precomputed over at most
2,000 observations, rejects ambiguous/malformed relationships, preserves the
existing parent suffix, and charges its escaped label against the same output
budget. Guidance requires one literal query before answering when the requested
item's fact is absent or its association is uncertain in truncated output.

Two isolated, real-Qwen/owned-App-Server cases on this candidate produced:

| Synthetic case | Actual sequence and answer | Through-shutdown time | Verdict |
| --- | --- | ---: | --- |
| Requested first card, Order A | status, apps, open, initial snapshot; answered the other card's `Delivered Friday` | 9.527 s | Incorrect; no recovery query |
| Requested second card, Shipment Cedar | open, initial snapshot, query `Cedar`; answered `Expected Thursday` | 10.999 s | Correct missing-text recovery |

Both final runs verified exact tool receipts, call IDs, turn completion, durable
rollout, and unchanged inherited policy. Every tool result was synthetic;
no desktop executor ran. The second case's correct answer was absent from the
initial observation and appeared only in the queried observation. These are
two single-pass diagnostic cases, not an accuracy estimate or a controlled
before/after speed comparison. Labels, dates, and source order vary; requested
status is still value-backed and distractor status title-backed. The reversed
field-encoding case was omitted because the real ranking would show its target
fact initially, invalidating this specific missing-information test.

Two intervening fixture mismatches are preserved separately, not counted as
wrong model answers: an optional app inventory query was initially rejected,
then a valid shorter query `Cedar` was rejected. The fixture now supplies one
synthetic production-formatted inventory and accepts the shorter target literal
only after Swift verifies byte-identical real formatter output for both queries.
It still rejects unrelated/repeated actions and enforces its call/time limits.

Four more formatter tests cover omitted headings, ambiguous/invalid/nonlocal
relationships, Unicode/escaping/field and whole-output limits, and ancestry/
observation bounds. The candidate passed **675 enabled regression tests, 33
opt-in skips, zero failures** (708 total), plus strict deep code-sign validation
and `git diff --check`. The two opt-in model verdicts above remain separate from
that passing deterministic suite.
The extraction fixture generator now removes inline heading cues as well as
parent annotations in its ablation; all 16 generated fixtures passed bound and
ablation-leak checks. No 16-case model batch was run.

Evidence:

- Wrong answer: `/tmp/heydash-ax-query-recovery-cue-first-v2-20260925.log`, fixture
  `HeyDashAXQueryRecovery-order-a-first-valueLive-DA00FFEE-3042-4168-A9F5-27D0AB852F33`.
- Correct recovery: `/tmp/heydash-ax-query-recovery-cue-second-v2-20260925.log`, fixture
  `HeyDashAXQueryRecovery-shipment-cedar-second-valueLive-817B2109-A460-4650-9579-20B999C6F220`.
- Preserved fixture mismatches: `/tmp/heydash-ax-query-recovery-cue-first-20260925.log`
  and `/tmp/heydash-ax-query-recovery-cue-second-20260925.log`.
- Generated synthetic extraction pairs: `/tmp/heydash-ax-cue-fixtures-20260925.J5zDGH/fixtures.json`.
- Candidate regression suite: `/tmp/heydash-sibling-cue-final-regression-20260925.log`.

Installed app, remote repository, StudyLock policy and enforcement remain
unchanged. No commit or push. Actual Chrome/Amazon acceptance remains pending.

## Targeted-query selection and provider accounting — 2026-09-25

**Actual Amazon completion remains unverified.** The follow-up work below uses
deterministic observations and an isolated real-model diagnostic; it does not
interact with Chrome or establish end-to-end browser reliability.

A query for an observed card heading could keep that heading but omit its
status while retaining another card's status. The reproduction used a native
main landmark, navigation links, 70-character headings, and a 1,000-character
output budget. The formatter now reserves bounded direct-group context after
all explicitly matched, root, and focused elements: up to two static facts and
one action for each of two validated non-landmark AXGroups. Facts precede
actions. Missing, duplicate, cyclic, disconnected, or over-depth ancestry cannot
establish related context. This is observed containment, not a claim that all
siblings are semantically associated. Native non-document query behavior and
all focus, approval, identity, and freshness guards remain unchanged.

Seven deterministic tests cover realistic long headings, pinned priorities,
direct-only selection, quantity/group caps, malformed sibling IDs and parents,
landmark boundaries, and native-query preservation. The production instructions
also explicitly require app binding before computer use each turn without
adding that requirement to text-only tasks.

The first isolated Qwen diagnostic attempted `computer_v2_snapshot({})` before
binding Chrome. The initial test fixture rejected it rather than emulating the
production no-bound-app error, stopping after 6.067 seconds with no answer.
That is not a completed recovery benchmark. Its retained trace confirms the
production 4B model, all 12 dynamic tools, disabled built-in desktop/shell tools,
and zero calls forwarded to the desktop executor. The revised fixture permits
one exact production binding error, accepts production-equivalent padded
literal queries, and distinguishes a valid direct lookup from missing-text
recovery. It verifies actual tool-result bytes, IDs, order, final turn, unchanged
inherited policy, and durable rollout before evaluating answer correctness.

Separately, local provider source/log analysis found that internal invalid-tool
repair passes are summed into Responses usage and then mistaken for active
context occupancy. The final aggregate caused an unnecessary compaction in the
71.158-second live trial. Disabling parallel calls did not work in three inert
probes. See [provider cost versus context occupancy](CONTEXT-OCCUPANCY-2026-09-25.md)
for exact numbers and limitations. No guessed token correction, vendor edit,
or context-safeguard reduction was applied.

The revised real-Qwen gate completed normally but **failed accuracy**: after
binding Chrome and reading the initial synthetic snapshot, Qwen returned the
other group's `Delivered Friday` rather than querying for the requested group's
missing `Arrives Tuesday`. It took 7.791 seconds through shutdown (8.173 seconds
for the complete XCTest). The first snapshot contained the requested heading
under parent 27 and the distractor status under parent 31; it omitted the other
heading. Exact transport, receipt, terminal, rollout, and unchanged-policy
provenance passed before the strategy/answer gate failed. No screenshot, scroll,
or real desktop action occurred. This proves the remaining wrong-association
failure, not a successful or representative browser benchmark.

Before the inline-heading candidate, the deterministic suite passed **671 enabled tests, 32 skips, zero
failures** (703 total), including seven query-context tests. Native correctness
and a passing regression suite do not establish model answer correctness.
No installation, commit, push, or StudyLock change was performed.

Evidence: `/tmp/heydash-query-context-regression-20260925.log`,
`/tmp/heydash-ax-query-recovery-20260925.log`, and isolated fixture
`HeyDashAXQueryRecoveryLive-8D432F35-2881-4EB3-9551-975AD6AA03AA` in macOS temporary
storage. Revised gate: `/tmp/heydash-ax-query-recovery-v2-20260925.log` and fixture
`HeyDashAXQueryRecoveryLive-DE915C53-C1EE-44E5-A3BC-F55144C4E5CE`. Final suite:
`/tmp/heydash-query-context-final-regression-20260925.log`. Both failure traces
are preserved, not overwritten by retries.

## Quiet-window trial and compact containment — 2026-09-25, 01:51 PDT

**The end-to-end goal is still open.** A fresh task in the actual development
app, using Qwen 4B and the user's existing ordinary Chrome process, reached the
Orders page in 17.839 seconds. The operator stopped the trial after 71.158 seconds:
14 tool calls, one compaction, no final answer. This was an interrupted bounded
trial, not a provider-declared terminal failure or a successful delivery lookup.
No order/account changes were requested. Private order data is not copied here.

The first Orders snapshot contained a dated delivered-status heading, but did
not establish the latest pending order. The last snapshot reached Order Details
yet exposed only 13/240 nodes and no delivery status or date. Three attempted
scrolls all failed: two omitted `x`, and the third reused an invalidated capture.
No targeted text query was attempted. One grounded details-link click dispatched;
its combined post-action screenshot/AX observation and the following capture
rejected a changing image. A plain AX snapshot then succeeded. Four ordinary
snapshot call-to-result times were 86–237 ms; these include transport overhead
and are not model task times. No user-facing invented StudyLock block appeared.

Follow-up changes preserve all native approval, identity, and freshness checks:

- Exact observed containment now uses one bounded `parents=[child:parent,...]`
  map and short per-line parent references, including omitted container paths.
  Missing, duplicated, cyclic, disconnected, and over-depth ancestry is not
  asserted. Unused map entries disappear when complete output lines are dropped.
- Compact output omits absent label/value fields and default `settable=0`.
- Snapshot guidance recommends a short literal query before screenshot/scroll
  fallback and answering once the requested facts are established.
- Pointer schema descriptions explicitly require current capture ID and both
  coordinates even for scrolling. Missing-field feedback explains the complete
  contract without inventing coordinates or relaxing validation.

In a deterministic long-common-ancestry fixture, factoring ancestry alone
retained **25 readable nodes versus 18** at the same 3,000-character budget and
candidate order (2,897 vs 2,904 characters). This is representation density, not
proof of a live speed or accuracy improvement.

The revised signed development build passed **664 tests, 31 opt-in skips, zero
failures** (695 total). `git diff --check` and strict deep code-sign verification
passed. Independent review found no blocking containment correctness issue.
The latest build has not yet repeated the actual Amazon task; another quiet
window was requested. Installed app, StudyLock policy/enforcement, and remote
repository remain unchanged; no commit or push was performed.

Evidence: `/tmp/heydash-parentmap-regression-20260925.log`,
`/tmp/heydash-parent-map-fixture.Oqvd6h/main.swift`, and the private app-local
rollout `rollout-2026-09-25T01-40-33-01a0d7b9-31e1-7961-b0a4-b39e52f9028e.jsonl`.
The separate [synthetic extraction diagnostic](AXAssociation/RESULTS-2026-09-25.md)
records the remaining missing-information reasoning failure; do not conflate
deterministic formatter correctness with reliable Qwen task completion.

## Snapshot and observed-link follow-up — 2026-09-25

The end-to-end goal remains open. A same-window native read-only probe passed
after one explicitly enabled setup activation of the existing ordinary Chrome
process. It neither navigated nor posted input during measurement. On the loaded
Orders page, the existing depth-16 / 240-node acquisition contained order and
arrival-status text, and the revised 3,000-character formatter retained it. The
first and repeated baseline reads took 143.289 and 78.264 ms. These are native
snapshot latencies, **not model task response times**.

Increasing depth alone to 24 or 32 with the same 240-node cap lost those facts:
depth-first traversal consumed the budget earlier. With 1,000 nodes, deeper reads
recovered the facts in 322.993–324.647 ms. No acquisition defaults were changed.
The prior 156-node failed-task snapshot and this later loaded-page read are not
the same observation; this probe does not establish why that earlier source was
shorter.

The native URL-presence traversal found AXURL on 125/125 observed links, with no
attribute errors. Previously these destinations were discarded. The candidate
now retains exact bounded HTTP(S) link URLs and exposes complete destinations up
to 512 bytes in compact output; unsupported/oversized destinations are omitted,
never shortened into actionable URLs. Guidance retains supported AXPress first
and limits URL navigation to a fallback for navigation links, not script/menu
actions. Existing approval, same-window, and freshness checks remain in place.

Formatter selection now shares the output budget between document facts and
controls, searches bounded observations before applying the output count cap,
and softly demotes zero/tiny/clipped geometry without deleting those nodes.
Queries and focus retain priority; short post-action summaries no longer pin
every heading ahead of facts. Native apps without an observed document retain
their prior selection behavior.

The final candidate passed **655 tests with 31 opt-in skips and zero failures**
(686 total); its signed development build and `git diff --check` verified.
Follow-up review identified that omitted link destinations also need independent
identity protection before mutation. The final guard preserves an independent
SHA-256 identity for at most 8,192 UTF-8 bytes, distinguishes a missing attribute
from an unverifiable destination, and fails closed for changed or unverifiable
destinations. Unchanged bounded JavaScript links remain usable through supported
AXPress; raw unsupported destinations and identity hashes are not emitted in the
model-facing formatter. Tests cover changed omitted destinations, byte limits,
stable script links, and backward-compatible snapshot decoding. Both review
findings were rechecked after the fixes.

The next live coverage attempt stopped during exact-target activation with
`targetChanged`, before collecting measurements. A fresh Chrome inspection showed
a different page and tab set. The cause of activation failure remains unknown;
it is not evidence of a StudyLock block. A new uninterrupted test window was
requested. No new complete Qwen/Amazon task result is claimed.

Evidence: `/tmp/heydash-ax-coverage4-20260924.log`,
`/tmp/heydash-observed-links-regression-20260925.log`, and
`/tmp/heydash-observed-links-final-regression-20260925.log`, plus
`/tmp/heydash-observed-links-coverage-20260925.log`. Private page contents, URLs,
and order identifiers are excluded from this report. No commit, push, installed
app replacement, cache deletion, or StudyLock changes were performed.

## Validated runtime-3 checkpoint — 23:44 PDT

The overall Amazon reliability/speed goal is **still open**. The owned runtime
and test isolation repairs are validated, but the final real Amazon task again
failed after excessive model actions; do not present the following passing
component tests as end-to-end success.

| Gate | Result |
| --- | --- |
| Final full Swift suite | 636 passed, 30 opt-in skipped, zero failures |
| Rust receipt unit regressions | 17/17 passed |
| Deterministic Codex Core receipt integration | 6/6 passed, including 20 actual dynamic calls and 40 matched receipts |
| Real Qwen 4B Chrome read | 3/3: 13.823, 13.516, 13.773 seconds |
| Native approval-focus/input gate | 3/3: 2.983, 2.600, 2.581 seconds complete-test time |
| Isolated shipping-threshold compaction | Passed in 190.788 seconds, including generated-text warmup |
| Actual app Amazon task | Failed in 115.801 seconds, 26 calls, two completed compactions |

The real compaction test retained its exact canary and continued with exactly one
read-only status call. Measured context fell from 12,779 to 7,035 tokens; configured
limits were 16,384/12,288. All ten model requests belonged to the same isolated
fixture, with zero production-home activity. Printed resource samples showed
minimum free disk 4.879 GiB, maximum swap 1.469 GiB, no swap growth and no critical
pressure. LM Studio finished idle with zero queued requests and parallelism one.
The preceding runtime-3 stress attempt generated zero numbered lines and refused
the harmless workload as StudyLock-related; it did not exercise compaction. A
subsequent scope clarification explicitly preserved enforcement and distinguished
its restricted-work list from unrelated work. The original policy file is unchanged.

The Amazon task used the production UI, Qwen 4B, the existing normal Chrome session,
and unchanged Full access preference. It reached the Orders page but produced no
answer: after unnecessary navigation, screenshots, and a grounding disagreement,
the 26-call receipt set exceeded the bounded projection. No history was discarded
to continue. This confirms the old 20-call accounting failure was addressed, not
that arbitrarily long or poorly planned turns now succeed. The last snapshot spent
its output on navigation controls rather than order details; read-only AX coverage
and text selection are being investigated next. Private order data is omitted here.

Low free disk also disables the installed MLX backend's disk prompt-cache fallback:
its final load log reports a zero cache budget, limited by free space. The backend
requires at least 10 GiB free before allowing that cache, and a model reload to
recompute the budget. Hot reuse still works: the final fixture tool continuation
reused 7,061 tokens and processed 39 uncached tokens. New-turn reasoning removal in
the model's template prevents rolling back its non-trimmable hot cache. No vendor
code, disk safeguard, model template, or reasoning history was modified. Cleanup
permission was requested; nothing was deleted.

Evidence logs are `/tmp/heydash-runtime3-final-regression-20260924.log`,
`/tmp/heydash-runtime3-receipt-unit-20260924.log`,
`/tmp/heydash-runtime3-receipt-integration-20260924.log`,
`/tmp/heydash-runtime3-chrome-20260924.log`, and
`/tmp/heydash-runtime3-scoped-compaction-20260924.log`. The Amazon rollout ends in
`01a0d748-526b-76f2-b371-09878bd60da8.jsonl`. The deterministic Rust integration
uses the production Codex Core loop with mock Responses SSE, not real Qwen or
raw App Server NDJSON. Its cached rebuild overlapped the Chrome batch; these
Chrome times are descriptive reliability checks, not controlled speedup claims.

Packaged development runtime: `heydash-3`, patch SHA-256
`9d7fc4ee4792065dd21d16b02b3970c57cb761f1f10da43c60cc53600c9d91d5`, signed
binary SHA-256 `47a04435558ed07fec8a5f4f45b73e6df6e70eaafe1995b0b34a974e2cdd4ab1`
(290,913,152 bytes). Strict deep app-signature verification passed. Unified patch
files preserve required space-only context lines; their generated-source checkout
is checked separately for whitespace. No commit, push or installed-app replacement.

## Follow-up isolation and receipt-budget investigation — 23:02 PDT

The 22:47 production-threshold stress run was **interrupted, not passed**. Four
warmups generated all 120 requested lines each, reaching 11,115 measured context
tokens. A fifth request (10,973 uncached input tokens) overlapped a separate
production Amazon compaction request (9,556 uncached tokens and four screenshots).
macOS then reported low memory. This contaminated run does not establish the
memory cost of an isolated 16K context. Subsequent force-quit activity was recorded;
the exact cause of the main LM Studio process's exit is not established.

The second App Server belonged to the XCTest application's ordinary UI startup,
not the fixture's isolated home or the earlier Amazon app process. Startup only
lists tasks; the trigger for its later submission remains unknown. The app's
XCTest composition root is now inert: no production runtime, production preference
reads, permission requests, or interactive task UI. Explicit fixture runtimes
remain available. All **26 focused tests passed**, including six new host-isolation
tests. Log: `/tmp/heydash-isolation-grounding-20260924.log`.

The 20-call Amazon failure had exactly 20 genuine call/result pairs, not duplicate
history. Its smallest receipt projection was 13,692 bytes, including 4,477 bytes
of internal metadata that the existing non-OpenAI request path removes before
sending to LM Studio. A provider-aware accounting fix is under validation; stored
receipt identities, arguments, ordering, turn metadata, and failure evidence must
remain intact. The 12 KiB model-facing cap is not being increased.

Grounding guidance now includes visible AX links lacking a supported press action,
and recommends target-description grounding over guessed image coordinates for
models with grounding headroom. Tools and native authorization guards remain
unchanged. This guidance change has deterministic coverage, not yet new live
success evidence.

LM Studio was restarted on loopback only, with the sole loaded Qwen 4B instance
verified as `parallel: 1`. Its backend still advertises 123,648 effective context
tokens despite a 16,384 load request; Computa's separate 16,384/12,288 application
limits remain authoritative for this experiment. No inference was submitted during
these setup checks. End-to-end acceptance and shipping-threshold compaction remain
pending; no commit or push was performed.

## Latest validation — 22:50 PDT

The final candidate passed **625 tests, 30 opt-in skipped, zero failures** (655
total), strict deep code-signature verification, and `git diff --check`.
Logs: `/tmp/heydash-page-final-regression-20260924.log` and
`/tmp/heydash-page-final-chrome-20260924.log`. The final live Chrome checks both
passed: Qwen public-page read in **13.396 seconds** and the native approval-focus
handoff in **2.620 seconds** for its three-call sequence (3.963 seconds complete).

Snapshot presentation now prioritizes structurally observed document content
over browser tabs/toolbars, retaining explicit text-query and focused-control
priority. Six regressions cover the normal output budget, tab queries, focused
omnibox, malformed parent ancestry, bounded traversal, and unchanged native-app
ordering. Tool schemas now explain targeted AX queries and the optional positive
display ID instead of leaving the model to infer those conventions.

The last real Amazon trial was **not successful**: it reached Orders but stopped
after **68.770 seconds / 20 calls**, with one completed compaction and a later
`all genuine tool receipts cannot fit the 12 KiB serialized bound` error. The
model made unnecessary typing/clicking calls and did not provide a final answer.
The safety bound was not relaxed and completed-action history was not discarded.
Its app-owned rollout ends in `01a0d717-fa7b-7512-86c0-94e3a016ca56.jsonl`.
This remains a model-planning / receipt-budget limitation, not evidence of a
StudyLock block. The earlier 82.803-second run's correct delivery status does
not make this later failure a pass.

The original production-threshold stress workload also exposed false policy
refusals: 0 of 720 requested numbered lines, only 4,294 measured context tokens
versus the unchanged 12,288 trigger. General scope wording alone did not fix
that model behavior. The final instruction explicitly distinguishes forbidden
enforcement weakening from harmless text generation/read-only testing. No
inherited policy was removed, hidden, or edited. The fixture now fails promptly
and distinctly when its workload never exercises compaction, rather than
misdiagnosing a below-threshold refusal as a broken trigger. The final real
compaction validation is recorded below when complete.

No commit, push, release package, or `/Applications` replacement was performed.
The unrelated `Benchmarks/RESULTS-2026-09-23.md` edit is preserved. The overall
Chrome/Amazon reliability goal remains open.

## Follow-up validation — 22:36 PDT

The 4B-only 16,384-token profile and bounded native tab-read retry passed the
regular suite: **619 passed, 30 opt-in skipped, zero failures** (649 total).
The final log is `/tmp/heydash-16k-regression-final-20260924.log`; two preceding
runs failed obsolete exact-wording assertions and are not counted as passes.
The development app also passed strict deep code-signature verification.

Serial production Qwen Chrome reads passed **3/3** in 13.770, 13.744, and 12.649
seconds. The separate native approval-focus gate passed **2/3** (three-call
execution 2.472 and 2.791 seconds). The third stopped after telemetry recorded
another application taking focus during initial page verification, before the
deliberate approval-handoff phase. This batch exits 65; it is not a clean six-test
pass. Evidence: `/tmp/heydash-16k-chrome-live-20260924.log` and the printed
sanitized focus-audit files.

The real UI Amazon task completed in **82.803 seconds**, with 17 tool calls and
one automatic compaction. It reached the existing signed-in Orders page and
reported the latest two orders' delivery status correctly. An independent
browser readback confirmed the delivery status, but also exposed a miscopied
order identifier in the screenshot-derived summary and final answer. Therefore
this is a navigation/status improvement, **not a fully accurate answer pass**.
No order/account changes were made. The rollout ends in
`01a0d70d-eb7a-7920-b9b4-e9f8fec7409b.jsonl`; private order contents and identifiers
are intentionally not reproduced here.

This trial had no false StudyLock-block claim. It still included unnecessary
typing, invalid screenshot arguments, and a recovered focus loss. Default AX
output spent much of its budget on browser tabs rather than document content;
a general structural presentation improvement is being validated next. The
one-versus-seven compaction count is descriptive, not a controlled speedup
measurement: the two trials took different action paths.

## Follow-up investigation — 22:24 PDT

The resumed full regression run passed **613 tests, 30 opt-in skipped** (643
total). Its log is `/tmp/heydash-improvement-regression-resumed-20260924.log`.
An earlier run exposed an instruction-wording assertion and the next was
interrupted; neither is counted as a passing full run.

The subsequent live batch was **not a clean pass**: native approval/input plus
fresh post-action observation passed 3/3 (2.613, 2.511, 1.571 seconds for the
three-call sequence; complete test times 3.954, 3.568, 2.737 seconds). Real Qwen
read passed 1/3 (14.494 seconds). The other failures had distinct causes:

- The second read's initial open failed on native tab inventory `AXRole/-25202`
  while AX, AppKit, and system focus still agreed on Chrome. The later
  `CancellationError` was test cleanup, not the original failure.
- The third lost focus to another application before snapshot. The model then
  attempted a second URL-open, which the single-open fixture correctly declined.

The tab-inventory read now has one bounded whole-traversal retry for detached
AX elements, checking the same retained focused window before/between/after
reads. No navigation or input action is replayed. This follow-up patch still
requires its own regression/live validation.

The rebuilt app's second real Amazon trial also **failed** and was stopped:
05:18:27.487Z–05:20:26.033Z, 12 tool calls and seven compactions. Compact app
discovery returned 1,085 characters instead of 23,094. AX and typing returned
usable fresh observations, removing the earlier skipped-observation failures,
but Qwen repeatedly pressed the omnibox instead of submitting navigation. The
trial did not establish an orders page or delivery date. Its app-owned rollout
ends in `01a0d700-2891-7be3-8187-e358ffbfadef.jsonl`.

Measured compaction time was 65.427 seconds of 118.545 seconds (55.19%); native
tool-call time totaled 3.678 seconds. An initial prompt of 3,147 tokens plus
five tool steps reached 6,016 tokens against the 6,144 trigger. Later summaries
left the next inference near/above the same trigger. This motivates a separate
4B-only 16,384/12,288 context/compaction experiment; it is not evidence of that
experiment succeeding yet. 9B and larger-model limits remain unchanged.

LM Studio remained available after the later test shutdown. Read-only source
review found separate owned process groups and no Computa shutdown operation
targeting LM Studio. Earlier observer-process exits and the interrupted shell
session do not identify a proven server-shutdown cause.

## Follow-up investigation — 22:07 PDT

The first real UI Amazon acceptance attempt in this pass **failed**. Its turn
started at 04:55:58.048Z, but the first tool call did not arrive until
05:01:42.764Z. Direct checks found the LM Studio HTTP server unavailable and no
loaded model. Starting the localhost server and loading the already-installed
4B model allowed the original turn to resume; no duplicate prompt was sent.
The run was explicitly stopped at 05:03:39.332Z after 13 calls and eight
compactions without a verified orders page. The app reached its terminal Waiting
state and the persisted rollout records `turn_aborted`.

The app-list output was 23,094 characters. A compaction immediately after that
inventory and later summaries misstated action outcomes. In particular, a
rejected typing action became a claimed completed action. Subsequent keyboard
calls also failed because the model skipped required fresh observations.
No StudyLock block, HTTP status, or delivery estimate was established. This is
evidence for reducing observation overhead, not for weakening freshness checks
or policy instructions.

Separately, the unchanged focus gates with new sanitized telemetry passed all
six serial repetitions: real Qwen Chrome read **3/3** (14.244, 13.925, 14.316 s),
and native approval/focus handoff **3/3** (three-call execution 2.435, 2.695,
2.780 s). The telemetry confirms target focus through successful observations;
it does not retrospectively explain the older failed run or establish general
reliability. Records include only application categories, focus flags, phases,
and numeric AX errors, not page text or private URLs.

Evidence: `/tmp/heydash-focus-traced-20260924.log` and each printed fixture's
`focus-audit.jsonl`. The real UI attempt is the app-owned rollout ending in
`01a0d6eb-9153-76e0-94a9-16962d817c39.jsonl`; private transcript content is not
copied into this report. No commit or push has been performed.

## Follow-up improvement — 21:52 PDT

The narrow activation-failure attribution path is now deterministic. This is
**not** a claim that Chrome focus or general Qwen compaction is fully reliable.

When bounded native activation fails, Computa saves its exact typed diagnostic
as app-owned evidence, revokes this turn's computer capabilities, and interrupts
the exact App Server turn while the tool is still pending. It displays a native
system diagnostic with an unknown cause and an explicit retry step, not a
fabricated assistant answer. The saved record is not represented as a successful
canonical App Server tool receipt: the outstanding call can legitimately be
cancelled there. The distinction and correlated terminal-state handling follow
the [official App Server lifecycle](https://learn.chatgpt.com/docs/app-server#lifecycle-overview).

Private, atomic evidence files survive task reload and retain original timestamps
and call identities. Strict byte/record bounds, duplicate/conflict validation,
file-type checks, readback, and cross-process locking protect the store. If
storage or interruption fails, Computa reports that explicitly and never claims
an unverified turn completion. Stale tool calls and late assistant messages from
older turns are rejected. Blank model messages no longer create empty replies.

The approved input handoff now permits one bounded restoration when Computa's
own approval host reclaims focus. It stops if another application takes focus,
and still requires continuous exact-window focus plus the existing final target
checks before input. It does not repeat the approved input action.

| Validation | Result | Timing / scope |
| --- | --- | --- |
| Full regular suite | **586 passed, 30 opt-in skipped, 0 failed** | 616 total; final invocation succeeded |
| Real Qwen 4B + owned App Server, synthetic native activation failure | **3/3 passed** | 3.432, 3.889, 3.410 seconds; startup, failure boundary, reload, and shutdown included |
| Real Qwen 4B + production Chrome open/snapshot | **2/3 fully verified** | Successful complete tests: 15.865 and 13.549 seconds; third failed final independent focused-window verification at 12.596 seconds |
| Deterministic transport + production native input/approval handoff | **2/3 passed** | Successful three-call execution: 2.833 and 2.732 seconds; third hit AXSubrole invalid-element read during setup before the input gate |

The final three native-failure trials verify the actual server-to-client tool
call, client-to-server interrupt, interrupted terminal notification, absence of
post-failure assistant text/compaction, and restored native evidence. No real
desktop failure is induced by that test: a DEBUG-only, explicitly selected
fixture supplies the typed error. It cannot be enabled with the bundled
production transport. The Chrome gates do use the user's existing normal
Chrome process and public nonce example.com tabs; no Amazon/account actions
were performed in this follow-up.

Two earlier test-assertion defects are preserved in the logs: a whitespace-only
pre-call message was incorrectly counted as a failure explanation, and an RPC
helper searched the client-to-server direction for a server-to-client tool call.
The corrected tests inspect the relevant direction and post-failure interval;
they do not accept or suppress a generated failure explanation.

Evidence:

- `/tmp/heydash-improve-full-20260924.log`: full passing regression suite.
- `/tmp/heydash-improve-final-live-20260924.log`: final 3 native-error passes and 2/3 real Chrome passes; overall command exits 65 due to the Chrome failure.
- `/tmp/heydash-improve-live-repeat-20260924.log`: 2/3 native input gates, AX failure, and the incorrect-direction assertion failures.
- `/tmp/heydash-improve-real-boundary-20260924.log`: first live boundary and whitespace assertion failure.
- `/tmp/heydash-improve-unit3-20260924.log`: initial deterministic store/runtime checks.

StudyLock and inherited policies are unchanged, including the home-policy hash
below. The owned Rust runtime remains `heydash-2`. No commit, push, release package,
or installed `/Applications` replacement was performed. Remaining work is
foreground/AX reliability and then a real read-only Amazon acceptance trial;
general generated-summary fidelity also remains unproven.

## Status

Patched, but **not accepted as a fully reliable end-to-end fix**. No commit,
push, release package, or installed-app replacement was performed for this work.
The rebuilt development app was reopened; its UI reported the local runtime
connected, Qwen3.5-4B selected, and the existing Full access preference retained.

## Evidence and cause

The original Amazon trial's tools did not diagnose StudyLock enforcement. The
two failing native calls reported that Chrome's process could not be activated.
A `Page Not Found` page is not HTTP-status telemetry. The model's third
compaction summary speculated about StudyLock, and later output promoted that
speculation into a definite diagnosis.

Computa's unchanged production workspace is `~/Documents`. The existing home
Git root makes the home `AGENTS.md` part of inherited project instructions.
The original rollout contains that policy verbatim. This explains why the model
knows the policy; it does not establish that the policy caused a browser error.
The [official instruction-loading documentation](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
informed the provenance investigation, which was checked against local source
and the actual rollout.

The home policy SHA-256 before and after testing is unchanged:
`47ebd203f659b71526cf412119e716042b9cb80c647f643cf089a20203f65509`.
No StudyLock instruction, enforcement file, setting, or process was changed.

## Implemented changes

- Typed activation errors now expose the measured failure, an undetermined
  cause, and unobserved website status. They tell the model not to repeat the
  failed action or invent an explanation. Genuine permission denials and other
  errors remain verbatim.
- Reply and compaction guidance distinguishes observations from hypotheses;
  policies are constraints, not evidence of a block. Unknown causes must not be
  invented or ruled out.
- Native Chrome input/AX preparation now shares the ordinary-Chrome open
  path's bounded, exact-PID AX activation recovery. Approval, turn epoch,
  retained window/control, screenshot freshness, and final input guards remain.
- Typing is explicitly described as editing the focused control, not navigation
  or submission; its receipt no longer implies otherwise.
- Native tab inventory now accepts nested tab groups within exactly one
  top-level strip. Live sanitized AX evidence showed two groups, one nested,
  ten radio tabs, one selection, and no traversal/ownership failures. The old
  total-group-count check rejected that legitimate layout. Peer strips,
  ambiguous selection, changed tab identities, and traversal limits still fail
  closed. Eleven deterministic tests cover topology and retained-tab identity.

## Validation and limitations

All **567 regular tests passed** in the final full run. There were 28 skipped
opt-in tests and one enabled native live failure; the full invocation therefore
returned failure, not a clean acceptance result.

The new native focus fixture uses a deterministic transport but the real Swift
V2 executor and approval path. It opens a disposable public page, observes it,
deliberately focuses a test-owned window during approval, approves one Cmd+L,
then independently verifies the exact retained Chrome window and omnibox.
It is not an LLM or shipped-App-Server benchmark.

From a stable public setup tab, **2 of 3** serial native checks passed. The three
production calls took 2.609 and 2.611 seconds in the successful runs. The third
failed safely before key dispatch: the inspected AX window did not become
focused. An earlier post-topology-fix run stopped with a changed-target error.
Do not infer that all focus races are resolved.

Real Qwen3.5-4B tests use the shipped owned App Server, unchanged Documents
workspace/inherited policy, shipping context thresholds, and a no-desktop
transport wrapper returning the exact new activation diagnostic. Compaction
tests verify native same-turn continuation and retained tool/policy evidence.
They do not demonstrate actual Amazon access.

The latest six bounded trials produced **3 automated passes and 3 failures**.
Manual review is essential: one automatically passing compaction sample still
invented exclusions for possible causes and mistyped the process ID. Two
automated failures were conservative standing-policy wording checks; one short
answer omitted explicit uncertainty. No final answer in this six-sample batch
asserted that StudyLock was blocking Chrome, but summary factual fidelity is
not consistently reliable. These results are not a 100% accuracy claim.

Earlier exploratory attempts also exposed and preserved: retry advice causing
a repeat-call loop, a rejected legitimate optional `browser_mode=existing`,
permission-preflight variation, and an uncontrolled generated-text warmup
crossing the threshold before the intended gate. The bounded diagnostic prompt
now specifies one exact tool call without supplying a cause or expected answer;
the generated-text warmup was removed. These are regression-fixture changes,
not proof of broad natural-language task success.

## Local evidence

- `/tmp/heydash-native-final-20260924.log`: final regular suite plus native failure.
- `/tmp/heydash-native-stable-20260924.log`: first successful exact-window input gate.
- `/tmp/heydash-native-repeat-20260924.log`: one success and one focus-settling failure.
- `/tmp/heydash-attribution-bounded-20260924.log`: six bounded real-Qwen trials, including summaries/finals.
- `/tmp/heydash-attribution-live3-attachments/`: earlier successful diagnostic pair and manual-review caveats.
- `/tmp/heydash-attribution-repeat-attachments/`: earlier repeats, including conservative-checker false positives.

The remaining acceptance work is reliable native focus settling and faithful
model summaries, followed by an actual read-only Amazon task. Neither the
delivery date nor a StudyLock block was established in this investigation.
