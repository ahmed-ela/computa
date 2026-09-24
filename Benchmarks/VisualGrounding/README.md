# Native visual-grounding benchmark

This directory retains the reproducible fixture corpus and production-worker replay for LocalCodex's native-window visual fallback. It measures screenshot target localization, not the entire agent loop or a general computer-use success rate.

## Production method

The shipped `goclick-guiowl-showui-agreement-v2` worker uses this fixed cascade:

1. Run GoClick and GUI-Owl 2B on the screenshot and concise target description.
2. If either result is missing or their distance exceeds 3% of the screenshot diagonal, run ShowUI 2B as a tie-breaker.
3. Select the closest valid pair across the available points.
4. Return the pair midpoint only when its distance is at most that same 3% threshold; otherwise return the structured `no_pair_agreement` refusal.

The Swift client parses the worker's restricted response and independently recomputes the pair selection, threshold, and midpoint. A model's free-form output never becomes a click coordinate directly. Production then performs capture identity, complete-window freshness, focus/occlusion, approval, and post-approval freshness checks before posting native input.

The tool is offered only to the Qwen3.5 4B and 9B options on this 24 GB Mac. It is a native-window fallback after Accessibility; brokered Chrome uses the semantic tab/DOM path and rejects screenshot-coordinate tools.

## Corpus and interpretation

The corpus has 13 unique target instructions repeated across seven visual variants of one synthetic browser-style application:

- `development`: 52 task instances over four variants;
- `heldout`: 39 task instances over three additional layout/theme/scale perturbations;
- total: 91 correlated task instances, not 91 independent semantic tasks.

The held-out set measures robustness to those visual perturbations. It does not test unseen applications, target vocabulary, instruction wording, operating-system controls, or adversarial content. Report its result as the highest observed single-pass accuracy on this fixture, not as general reliability.

Each row includes the exact expected bounding box. An accepted point is a hit only when it falls inside that box. A refusal is considered expected only for the single exact tuple `heldout / zoom90 / preferences / workspace-name` with error code `no_pair_agreement`. Every other refusal, worker error, wrong point, changed refusal tuple, or process-lifecycle failure makes the replay exit nonzero.

## Run

Install and verify the sidecar first, then replay the source-tree worker against the installed pinned runtime and weights:

```sh
Scripts/install-visual-grounding.sh

PYTHONDONTWRITEBYTECODE=1 \
  Benchmarks/VisualGrounding/run-production-cascade.py \
  --output ../outputs/LocalCodex-production-grounding-cascade-2026-09-24.json
```

The runner creates a private request directory, copies each image to a unique request path, starts one worker process, waits for its explicit ready record, executes all 91 requests serially, requests a clean shutdown, and requires the child process to exit. Worker stderr is retained in a temporary file while it runs so pipe backpressure cannot deadlock the benchmark.

Latency definitions:

- `ready_wall_seconds`: process launch through the ready record, including model load and worker warm-up;
- `request_latency_*`: caller wall time from writing one NDJSON request through parsing its response;
- `worker_latency_*`: worker-reported routing and inference time for the same 91 requests, including the expected refusal;
- `wall_seconds`: the complete one-process replay, including startup, all requests, and shutdown.

The p95 is a percentile over one serial, uncontended pass through this correlated task mix. It is not a repeated-process service-tail estimate. OS, filesystem, and Metal caches are not cleared. Use multiple fresh-process runs and an unseen-app corpus before making broader cold-start, reliability, or tail-latency claims.

## Verified result on this Mac

The final production-worker replay on September 24, 2026 completed all 91 requests and shut down cleanly:

| Result | Value |
| --- | ---: |
| Correct accepted points | 90/91 |
| Expected safe refusals | 1/91 |
| Unexpected errors or wrong accepted points | 0 |
| ShowUI tie-break invocations | 29/91 |
| Request p50 | 1.200 s |
| Request p95 | 2.603 s |
| Worker p50 | 1.200 s |
| Worker p95 | 2.603 s |
| Worker load | 2.263 s |
| Worker warm-up | 3.688 s |
| Ready wall time | 8.441 s |
| Complete replay wall time | 157.231 s |

This is 90 correct actions plus one deliberate refusal, not 91 correct actions. The retained JSON artifact is `../outputs/LocalCodex-production-grounding-cascade-2026-09-24.json` relative to the repository's parent project directory.

## Product acceptance beyond this corpus

The corpus replay verifies deterministic routing, grounding accuracy on retained fixtures, refusal behavior, and worker lifecycle. Product acceptance additionally requires:

- Python protocol and parsing tests;
- Swift decision, cancellation, worker-restart, temp-file, and runtime-lifecycle tests;
- an Xcode-built app whose resource bundle contains the worker/manifests and no Python bytecode caches;
- the opt-in Calculator gate, which approves only a grounded point independently proven inside Calculator's digit-1 AX frame, verifies the display transition through a fresh AX read, verifies raw App Server lifecycle evidence, and requires clean runtime shutdown.

The Calculator gate is intentionally separate because a retained-image hit is not proof that capture, model tool choice, approval, coordinate conversion, click delivery, post-action verification, and cleanup work together on the live desktop.

The final September 24 opt-in run with Qwen3.5-4B passed that gate in 25.753 seconds: exactly `open → capture → ground_click → snapshot`, an independently verified digit-1 point, Calculator display transition `0 → 1`, matching rollout/raw-wire lifecycles, and successful owned cleanup. The immediately preceding attempt safely returned an occlusion error because a stale full-display macOS Screenshot overlay was above the target; it posted no click. This is one successful live run plus one correctly refused obstructed run, not a statistical reliability result.
