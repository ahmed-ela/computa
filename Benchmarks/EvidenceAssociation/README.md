# Evidence-association checkpoint experiment

This is a paired diagnostic of the local Qwen3.5 4B model, not a claim of general
computer-use accuracy. It tests source/entity/value association through a summary
and a continuation, using synthetic screenshots and accessibility text. It never
opens Chrome, dispatches a generated tool, or touches account data.

## Frozen comparison

Three candidates are frozen in `prompts.ts` before the development batch:

1. Current production base instructions and upstream checkpoint prompt.
2. The same checkpoint, with an entity/scope association guard in base instructions
   for both stages.
3. Unchanged base instructions, with a structured source-preserving checkpoint.

The current production base/tool template is read from an earlier **synthetic**
loopback capture and checked against the Swift source. Inherited policy remains
unchanged. The model, observations, retained image, output bounds, decoding and
requested answer are identical within a case. Arm order rotates between cases.
Only the intended instruction component changes. Model inference is serial and
requires the sole 4B instance to be idle before every request.

Four development cases select a candidate; eight held-out cases compare the
frozen candidate with baseline. Select by exact completed task count first, then
unsupported claims, then total summary-plus-answer latency. An instruction-only
format violation is not a hallucination. A requested tool is not executed and is
reported separately, not counted as a fabricated fact. If no candidate improves
held-out correctness without introducing new unsupported claims, do not promote
an experimental prompt merely because it sounded convincing. No tuning against
held-out results.

## Measurements and limits

The evaluator requires a JSON object with the requested entity keys and exact
observed values or null when unsupported. It distinguishes known-fact omissions,
correct uncertainty, unsupported relationships, extra entities, malformed output,
unfinished generation and tool requests. It does not repair markdown or prose.
Both request times, usage, status and incomplete details are retained; a failed
summary remains part of the result denominator and its elapsed time is recorded.

Raw evidence and model output are private local artifacts. Summaries remain
model-generated, untrusted text. A better final answer is not itself proof that
every summary statement is correct. The retained screenshot can independently
cause or correct a final mistake. These small synthetic cases, low-temperature
single runs, controlled output format, short constructed history and warmed
model/cache do not establish production or real-site success rates. Promotion
also needs an owned-runtime forced-compaction gate and native regression tests.
An actual natural-language browser task remains a separate acceptance gate.

The runner uses direct local Responses requests with `stream=false`, temperature
0.1, 2,048 generated tokens per stage and a 60-second timeout. These diagnostic
bounds are not the production agent loop. No generated function call is executed.

## Files

- `fixtures.ts` and `fixtures.test.ts`: synthetic page structure, truth and controls.
- `prompts.ts`: frozen candidates.
- `score.ts` and `score.test.ts`: deterministic scoring, separate from inference.
- `run.ts`: two-stage paired replay. Supply a private output directory, rendered
  PNG directory, and synthetic capture directory as absolute paths.
- `poisoned-memory.ts`: independently constructs plausible wrong checkpoints
  for post-hoc stress, using observed alternatives rather than answer labels.
- `replay-regression.ts`: private recorded-failure summary/continuation replay,
  with exact old-summary removal and inherited-policy identity checks.
- `replay-retention.ts`: substitutes only verified Rust-exported result bodies
  into a fixed saved continuation request. It preserves the same summary,
  instructions, calls and screenshot; generated actions are never dispatched.

Recorded-failure evidence is private and separate from the synthetic corpus.
Read `../EVIDENCE-RETENTION-2026-09-25.md` for results, exclusions, and limitations.

```sh
bun test Benchmarks/EvidenceAssociation
bun Benchmarks/EvidenceAssociation/run.ts development OUTPUT IMAGE_ROOT CAPTURE_ROOT
bun Benchmarks/EvidenceAssociation/run.ts holdout OUTPUT IMAGE_ROOT CAPTURE_ROOT baseline,SELECTED_ARM
```
