# Evidence association and newest-observation retention

## Scope and decision

This evaluation addresses false entity/value associations and lost current
observations around local compaction. It does not prove that arbitrarily long
chats or computer-use turns cannot fail. No desktop actions were executed by the
controlled replay experiments. A subsequent real-app trial is separately recorded
below. The original account-page recording stayed in private local
files; prompts, answers, account data, and screenshots are not included here.

Two prompt candidates were tested, not promoted. The structured checkpoint
frequently exhausted its output allowance without producing a summary. The
short association guard modestly improved a stress test, but did not improve
held-out exact task completion or recover the recorded production failure.
Production instructions and the default compaction prompt remain unchanged.

A separate structural fix gives the newest completed tool observation priority
within the existing receipt budget. It preserves the missing current AX evidence
and identity, but has not fixed the recorded answer's false association. It must
not be described as a successful browser fix.

## Prompt comparison

Model: `lmstudio-community/Qwen3.5-4B-MLX-4bit`, the sole loaded instance,
parallelism one. Every request required an idle preflight. Direct local Responses
requests used temperature 0.1, 2,048 generated tokens per stage, non-streaming
output, and a 60-second timeout. No requested tool was dispatched.

Twelve fixed synthetic cases cover orders, invoices, calendars, and issues:
cards/tables, different column orders, duplicate names, stale observations,
missing values, unrelated sections, and screenshot/AX disagreement. Four cases
were development-only and eight held out from prompt selection. Synthetic AX is
contract-shaped text, not a production accessibility acquisition. The private
account-page screenshot was not added to the synthetic corpus.

| Comparison | Baseline | Candidate | Median total latency |
| --- | --- | --- | --- |
| Development, association guard | 4/4 exact | 4/4 exact | 12.334 s / 12.328 s |
| Development, structured checkpoint | 4/4 exact | 1/4 exact; three empty summaries | 12.334 s / 25.697 s |
| Held-out summary + continuation, association guard | 6/8 exact | 6/8 exact | 15.102 s / 14.852 s |
| Corrupted-memory continuation stress, association guard | 5/7 exact | 6/7 exact | 4.109 s / 4.355 s |

Latencies include finished failed lanes, not just successes. The structured
checkpoint's only successful lane took 35.932 seconds. The corrupted-memory
stress reused seven held-out cases, deliberately inserted a plausible false
checkpoint, and omitted the summary-generation stage. It is post-hoc stress
evidence, not a new untouched holdout or a comparable end-to-end latency.

Held-out baseline failures were one empty summary and one unsupported choice
between indistinguishable entities. The guard avoided that arbitrary choice but
failed the required format (an array instead of null) and omitted requested
unknowns in another case. Format violations are not counted as hallucinations.
Both arms still made an arbitrary association in the duplicate-entity stress
case. The differences are small single-pass observations, not reliable estimates
of overall accuracy or speed. Warm/cache/order effects remain possible.

## Recorded-failure replay

The original live turn completed thirteen tool calls and one compaction, but
associated a recommendation's product name with an unrelated order's status.
The replay is reconstructed from the durable checkpoint, not an original wire
request: reasoning items are omitted, exact inherited policy restored, and the
old summarizer message removed only after matching bytes and provenance.
All thirteen call/result identities and the one retained image are checked.

- Baseline again made the false association: 25.385 seconds, summary + answer.
- The association guard did not provide a final answer: 26.587 seconds. It
  requested an AX action against an old snapshot and an index not present in
  that snapshot. Native validation would reject it; no action was executed.
- The guard's summary also inferred an enforcement cause without an observed
  enforcement status. A standing policy is not evidence that a navigation
  failure was caused by that policy.

The first replay attempt was invalidated and excluded: it retained the previous
summary and omitted inherited policy. The corrected replay verifies both
conditions explicitly. No conclusions here use the invalid run.

Investigation found the newest captured AX text had been reduced from 3,119
bytes to 318 bytes, losing its snapshot header/identity while older snapshot
identifiers remained. The old allocator shrank every output with the same cap;
this was not greedy allocation to older outputs.

## Structural candidate and invariants

Before reducing the newest completed output, try reducing older excerpts. Latest
text may use 4 KiB (6 KiB serialized output); older outputs retain their existing
2 KiB text/3 KiB serialized maximums. This is tool-agnostic and based on completion
order, including parallel calls, not a website, product, or named tool.

All previous uniform-cap candidates remain in the search. Existing 12 KiB
external-provider and 24 KiB canonical aggregate bounds remain unchanged. Keep
every call/result pair, arguments, identities, outcome, order, and canonical
metadata. The latest single image retains its separate 2 MiB bound and final
context-fit check. No action is replayed or approved, and retained evidence does
not renew capture freshness. StudyLock and native permission checks are intact.

Same-history recompaction must be idempotent. A formerly latest result may be
shortened when another result completes. The bounded search grows from seven
to at most 42 cap combinations (32 pairs maximum); image bytes are cloned once
after text fits. Four KiB text can exceed 1,000 tokens, so this is a reviewed
increase in individual item allowance, not a claim of token equivalence.

The existing 32-call bound, unsupported-result and context-fit failure modes
remain. This patch does not make unlimited-turn compaction infallible and does
not itself correct visual reasoning or a poisoned summary.

## Native target-provenance repair

The combined diagnostic exposed a second structural bug, independent of prompt
quality. Keeping a native AX handle in a larger cache was enough to address it,
even if its index had never been returned to the model. A guessed current index
could therefore reach native revalidation instead of requiring observation.

The formatter now returns typed `AccessibilityModelObservation` data alongside
the unchanged rendered text: exact snapshot identity and the unambiguous,
nonnegative indices of the final displayed element lines. Exposure comes from
render candidates after all element/text trimming, never by parsing labels or
numbers out of a string. Ancestor maps, sibling headings, duplicate identities,
and malicious labels cannot grant target exposure. A new snapshot replaces this
scope; scopes are not unioned.

Native V2 AX/type and legacy AX/set-text paths now require membership before
approval or input dispatch. Unlisted targets return a fresh/targeted-observation
instruction with an explicit no-input-dispatched result. Current snapshot,
window, target-rebinding, permission, and approval checks still apply. Browser
DOM and screenshot-coordinate paths are unchanged. This blocks the demonstrated
guessed-index action, but is not proof that Qwen will recover or answer correctly.

Eight formatter tests and six runtime-scope tests include a cross-layer case:
the real formatter omits an otherwise cached, actionable index 149; the real
runtime predicate rejects it and accepts the displayed target. These are
deterministic synthetic tests without desktop input, not a live click benchmark.

## Validation status

- Corpus/scorer/corruption generator: 20 tests, 2,554 assertions, all passed.
- Rust compaction unit tests: 37 passed, including all 19 receipt tests.
- Opt-in Rust exporter: passed exact original/canonical identity, success, order,
  metadata, 13-pair, full latest-output/image, bounds, and recompaction checks.
- Integration tests: final rerun 7/7 passed. Initial run passed 5/7; two old
  expectations still assumed a 2 KiB latest output. Expectations now use 4 KiB
  for the newest output and explicitly test its later demotion to 2 KiB.
- Fixed-summary replay with the actual Rust-exported receipts: 11.735 seconds,
  completed, no tool calls. The complete latest 348-byte capture metadata and
  3,119-byte AX block survive. The model still makes the same false recommendation
  to order association. No enforcement-cause claim. This is a failure of answer
  accuracy, not a failed retention/export test.
- The original fixed-summary baseline continuation alone took 9.440 seconds;
  25.385 seconds above includes its summary stage. New retention is not a measured
  inference speedup. Requests preserve every non-output field, including the same
  faulty summary; ten result bodies differ while all calls and the image match.
- Combined frozen association guard/checkpoint plus new receipts: 6.033 seconds,
  one AX action requested, no final answer. It uses the correct current snapshot
  but guesses element 149, absent from every shown original and retained
  observation. The native cache contains 240 elements and did not restrict actions
  to the 16 shown nodes, so this was not guaranteed to be rejected. No action was
  executed. This exposed a separate model-visible target provenance gap; the
  association prompt is still not promoted.
- Runtime rebuilt from the exact reviewed patch, packaged as `heydash-4`, and
  strictly code-signature verified. Full app regression: 695 passed, 33 opt-in
  tests skipped, zero failures (728 discovered). Both new formatter/scope suites,
  including the cross-layer guard, passed. Development app strict/deep signature
  verification passed.
- Two serial real-Qwen/owned-runtime no-desktop gates passed: text canary in
  37.102 seconds and previously unseen image colors in 28.766 seconds. Each
  performed exactly one synthetic status call and one native mid-turn compaction,
  returned the correct answer, and did not replay the tool. Gates include initial
  acknowledgment and warmup, so their totals are not compaction-only latency.
  They explicitly lower the compaction trigger to 6,144 tokens (pre-turn usage
  4,808 and 4,335) without changing the shipping 16,384-token window or policy.
  Shipping-threshold stress and real desktop execution are not established.
- Real current-browser task: the subsequent trial below completed, but did not
  resolve a specific package's delivery status.

## Subsequent real-app trial — 2026-09-25, 04:10 PDT

After the user provided another quiet window, the rebuilt development app was
restarted and a fresh Qwen 4B task submitted exactly once through its actual UI.
The request asked when the Amazon package was coming, using the existing Chrome
session with read-only constraints. No order identity, answer, page URL, or tool
sequence was supplied.

- Submit at `2026-09-25T11:10:18.402Z`; runtime start `11:10:19.869Z`;
  terminal completion `11:11:10.579Z`: **52.177 seconds** from submit.
- **12 calls: 11 succeeded, one rejected**; three opens, seven snapshots, one
  pointer-scroll, and one capture. All opens retained ordinary Chrome PID
  `99015`. No focus or compaction failure was observed; one compaction completed.
- The scroll supplied a previous AX snapshot ID as a screenshot capture ID.
  Native validation rejected it before input because no screenshot existed yet.
  The subsequent capture succeeded. This is still an avoidable model error.
- The final response asked which package was intended and gave two actual
  visible-order examples. It did not reproduce the earlier recommendation/order
  association error or falsely attribute navigation to StudyLock. It also omitted
  the displayed order count's time-range qualifier, so it is not a flawless answer.
- Independent browser inspection after completion confirmed the examples and
  inspected the visible not-yet-shipped filter. That filter reported all orders
  shipped; this does **not** establish that all orders were delivered. This audit
  was not performed by Qwen and is not credited to its result. The original Orders
  view was restored. No purchases, messages, or account-setting changes occurred.

The trial still did not resolve a specific package's delivery status. A single
completed clarification turn is not evidence of general reliability, or a paired
speedup over the earlier failed trial. Chrome was released for normal use after
the audit; no further live browser tests were run before publication.

The snapshots also exposed a generic inefficiency: the model supplied keyword
bags to a literal-substring query, producing misses without an explicit match
count. A proposed match-count header passed its new tests but displaced an
existing sibling-heading cue under a tight output budget. That unvalidated
candidate was removed before publication. No fuzzy search, expanded fallback
budget, or new prompt experiment was promoted.

Private source rollout:
`~/Library/Application Support/LocalCodex/CodexHome/sessions/2026/09/25/rollout-2026-09-25T04-10-19-01a0d842-4eca-7451-9d65-100c427cf567.jsonl`.
SHA-256: `cb4ef19c7aaf88588ac706d76a382e9f10fad158404e5baa79f7588cae35b60a`.
Raw account data and screenshots remain outside the repository.

## Private evidence index

- Development: `/tmp/heydash-evidence-development-20260925.Yc8Xuk/summary.json`
- Held-out: `/tmp/heydash-evidence-holdout-20260925.twQfaa/summary.json`
- Corrupted memory: `/tmp/heydash-evidence-corrupt-20260925.iFZJMM/summary.json`
- Corrected replay: `/tmp/heydash-evidence-regression-20260925.LSjuX7/summary.json`
- Excluded replay: `/tmp/heydash-evidence-regression-20260925.JF4LGP/INVALIDATED.json`
- Actual native receipts: `/tmp/heydash-native-retention-20260925.Hz9gPW/receipts.json`
- Fixed-summary new retention: `/tmp/heydash-retention-replay-20260925.WSwArx/summary.json`
- Combined diagnostic: `/tmp/heydash-retention-association-20260925.rlTgvC/summary.json`
- App regression log: `/tmp/heydash-evidence-retention-regression-20260925.log`
- Synthetic live compaction log: `/tmp/heydash-evidence-retention-live-20260925.log`
- Original rollout SHA-256:
  `90cee9da0e4657c4d7880d5cde9d74e9e04712a417cf96bc0554550696b18466`
- Original retained screenshot SHA-256:
  `030bded2ec44dfc9ef373bc3d73b45bd3157ff2cf69784cea5b0cd6a0280830b`
- Corrected replay retained-receipts SHA-256:
  `3acf77247d7641420730df6a993c159ddff1762f12172be8a155fb75b7450d82`
- Runtime patch SHA-256:
  `8f83d56ea759e3b32031244014fd22808f1f9268ae50b3e597f02674687106c6`
- Packaged runtime binary SHA-256:
  `7195c96d4a8db62341fcc31b66f8f241e0a5c5a685d15f4c3ddf1f73482438e4`

All development checks above are complete; the recorded semantic association
failure is not resolved. No claim of faster inference, general computer-use
reliability, or infallible auto-compaction is warranted. The production prompt
experiments remain out. The retained changes address independently verified
evidence-loss and unobserved-target gaps.

No commit, push, or installed-app replacement was performed for this evaluation.
LM Studio was idle again with the same sole 4B model when the serial gates ended.

## User-requested publication checkpoint

The user subsequently requested committing and pushing the current work, without
further optimization. After removing the unpromoted query-count candidate, the
full application suite passed again: **695 passed, 33 opt-in skips, zero failures**
(728 discovered). The four deterministic benchmark test files passed **39 tests,
2,718 assertions**. Final application log:
`/tmp/heydash-precommit-final-20260925.log`. This checkpoint does not change the
recorded model failures or establish completion of the delivery-lookup goal.
The unrelated `Benchmarks/RESULTS-2026-09-23.md` edit is excluded from publication.
