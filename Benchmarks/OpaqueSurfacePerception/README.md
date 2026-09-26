# Opaque-surface perception — benchmark only

This experiment compares original image + host AX against the exact same input
plus bounded native OCR text. It is not an end-to-end computer-use gate and does
not establish input delivery, remote-control capability, tab enumeration, or
task completion. No production source or computer executor is imported.

## Frozen cases and oracles

`fixtures.ts` defines six independent synthetic images. The seventh is one
privately retained original image from the live regression. The synthetic
oracles come from the rendered visible content, never OCR output. The common
question asks for `{visible,left,right}`: a content classification and the two
exact status words when applicable. The blank panel's state is `unknown`, not
an inference that the remote machine is locked or disconnected. The real
image's oracle is frozen privately from pixel inspection before model calls.

The synthetics include misleading host labels, a real login prompt, an error,
a desktop, an empty surface, repeated record labels across columns, and
instruction-like page text. They are a small component-level diagnostic corpus,
not a general accuracy benchmark. A model that correctly classifies a screenshot
may still choose the wrong tool in a real task.

`write-fixtures.ts` writes `fixtures.json` for the existing offscreen renderer
and `manifest.json` with cases shaped as:

```text
{ id, imagePath, hostAX, group: "synthetic", expected: {visible,left,right}, question }
```

The manifest also records the frozen fixture source hash. Keep expected answers
out of model requests. Compare identical baseline and candidate host AX, image,
question, model settings, and policy; only candidate OCR observation text changes.

## Commands

Run from the HeyDash repository. Use fresh private temp directories; scripts
refuse to overwrite outputs or put private captures into the repository.

```sh
bun test Benchmarks/OpaqueSurfacePerception/format.test.ts Benchmarks/OpaqueSurfacePerception/receipt-text.test.ts
mktemp -d /tmp/heydash-opaque-synthetic.XXXXXX
bun Benchmarks/OpaqueSurfacePerception/write-fixtures.ts /ABS/PRIVATE/TEMP/DIRECTORY
swift Benchmarks/EvidenceAssociation/render.swift /ABS/PRIVATE/TEMP/DIRECTORY/fixtures.json /ABS/PRIVATE/TEMP/DIRECTORY
mktemp -d /tmp/heydash-opaque-actual.XXXXXX
bun Benchmarks/OpaqueSurfacePerception/extract-capture.ts /ABS/ROLLOUT.jsonl CAPTURE_UUID /ABS/PRIVATE/TEMP/DIRECTORY
swift Benchmarks/OpaqueSurfacePerception/native-ocr.swift /ABS/IMAGE.png /ABS/NEW-OCR.json
bun Benchmarks/OpaqueSurfacePerception/format.ts /ABS/NEW-OCR.json /ABS/SOURCE.json /ABS/NEW-OBSERVATION.txt
bun test Benchmarks/OpaqueSurfacePerception/runner-support.test.ts
bun Benchmarks/OpaqueSurfacePerception/run.ts /ABS/FRESH/OUTPUT /ABS/manifest.json /ABS/ACTUAL_CAPTURE_DIRECTORY /ABS/ROLLOUT.jsonl lmstudio-community/Qwen3.5-9B-MLX-4bit --max-output-tokens=4096 --case=host-locked-browser
```

`source.json` is `{capture_id,image_sha256,width,height}`. For synthetic images,
derive these values from their actual rendered PNGs, not fixture geometry alone.
The extractor creates it for the selected actual capture. Image hashes refer to
the exact PNG file bytes. Neither an OCR hash nor a capture ID grants permission
to dispatch input.

## Acquisition and formatting boundaries

- The extractor reads original `response_item` tool receipts, including string
  text output and typed image-bearing arrays. It never reads model reasoning or
  synthesized compaction summaries as observation evidence.
- Actual capture selection requires exactly one matching original capture tool
  receipt and one PNG with matching declared dimensions. Paired AX is either
  from that same capture or the latest preceding standalone snapshot since
  open, labeled with its timestamp, age, and non-synchronized relationship.
  Intervening actions mean preceding AX must not be treated as current pixels.
- The OCR adapter uses Apple Vision `.accurate`, English, no custom vocabulary,
  no language correction, no expected-target filtering, and the input PNG's
  original orientation and resolution. It supports at most 32 MiB / 8 million
  pixels, 128 records, 512 UTF-8 bytes per record, and a 60-second hard native
  recognition deadline. It writes private JSON only after success.
- Recognition timing excludes Swift compilation/process startup and PNG decode.
  Report adapter wall time separately from `elapsed_ms` if comparing end-to-end
  overhead. No previous synthetic OCR score establishes this corpus's accuracy.
- The formatter requires matching image hash/dimensions, emits escaped literal
  text/confidence/coarse locations with explicit source binding and no action
  authority, and omits whole records to fit 1536 UTF-8 bytes. Empty OCR is not
  proof of empty/locked content. Positions do not establish semantic ownership.
- Standalone formatting/receipt tests are deterministic; OCR and model quality
  require separate runs. Preserve unanswered, malformed, timed-out, and wrong
  results in denominators, and retain partial output on an interrupted sweep.
- OCR failures remain unavailable observations, not fabricated empty results.
  No OCR or synthetic output may enable an input capability, relax a grounding
  threshold, or change approval/window/freshness checks.

## Serial model runner

`run.ts` requires the sole requested local model to be idle, with parallelism
one and no queued work, before each call. It preserves the original production
instructions and inherited policy. Optional `--case=EXACT_FROZEN_CASE_ID` retains
the original case's AB/BA order and source ID. Output budgets are explicitly
restricted to 1024 (default), 2048, or 4096 tokens; budget changes must be reported
as a condition difference, not silently merged into an accuracy score.

The summary freezes runner/helper/formatter/native-source and input hashes at
startup; native compilation uses that retained private source snapshot. SIGINT
or SIGTERM records a stop request but lets an outstanding provider response
finish. It stops before the next request and verifies provider idle before exit.
Requests have a 180-second response deadline, with an additional idle check after
errors. `provider_state_unconfirmed` is a blocker to another inference, never a
claim of successful cancellation.

An empty assistant answer with only reasoning consuming the output budget is
`budget_censored`, even if the provider calls the response completed. It counts
against answer yield but is not evidence of visual misclassification. Missing,
malformed, valid-wrong, and valid-correct answers remain separate outcomes; no
reasoning text is printed in the summary or terminal.

## Production caveats

Nothing here is promoted. Adding OCR to real capture results would require
explicit total observation/compaction byte budgeting, private-data handling,
task/capture identity checks after recognition, and updating positional
post-action observation parsing without re-arming its verification-only image.
The archived AX-pointer experiment remains unrelated and unpromoted.
