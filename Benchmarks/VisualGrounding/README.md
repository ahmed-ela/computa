# Native visual-grounding benchmark

This directory retains the reproducible fixture corpus and production-worker replay for Computa's native-window visual fallback. It measures screenshot target localization, not the entire agent loop or a general computer-use success rate.

## Production method

The shipped `goclick-guiowl-showui-agreement-v2` worker uses this fixed cascade:

1. Run GoClick and GUI-Owl 2B on the screenshot and concise target description.
2. If either result is missing or their distance exceeds 3% of the screenshot diagonal, run ShowUI 2B as a tie-breaker.
3. Select the closest valid pair across the available points.
4. Return the pair midpoint only when its distance is at most that same 3% threshold; otherwise return the structured `no_pair_agreement` refusal.

The Rust client parses the worker's restricted response and independently recomputes the pair selection, threshold, and midpoint. A model's free-form output never becomes a click coordinate directly. Production then performs capture identity, complete-window freshness, focus/occlusion, approval, and post-approval freshness checks before posting native input. Global input remains unresolved until explicit verification establishes a changed, originally observed property. A post-action image grants no reusable pointer authority.

The tool is offered only to the Qwen3.5 4B and 9B options on this 24 GB Mac. It is a native-window fallback after Accessibility; brokered Chrome uses the semantic tab/DOM path and rejects screenshot-coordinate tools.

## Corpus and interpretation

The corpus has 13 unique target instructions repeated across seven visual variants of one synthetic browser-style application:

- `development`: 52 task instances over four variants;
- `heldout`: 39 task instances over three additional layout/theme/scale perturbations;
- total: 91 correlated task instances, not 91 independent semantic tasks.

The held-out set measures robustness to those visual perturbations. It does not test unseen applications, target vocabulary, instruction wording, operating-system controls, or adversarial content. Report its result as the highest observed single-pass accuracy on this fixture, not as general reliability.

Each row includes the exact expected bounding box. An accepted point is a hit only when it falls inside that box. A refusal is considered expected only for the single exact tuple `heldout / zoom90 / preferences / workspace-name` with error code `no_pair_agreement`. Every other refusal, worker error, wrong point, changed refusal tuple, or process-lifecycle failure makes the replay exit nonzero.

## Run

Build the Rust grounding worker with `native-mlx`, stage it beside its exact generated `mlx.metallib` and `manifest.json`, and supply an explicitly reviewed installed model root. The runner never downloads or substitutes weights:

```sh
cargo run -p xtask -- grounding-cascade \
  --corpus /absolute/path/to/VisualGrounding/corpus.json \
  --worker /absolute/path/to/InferenceRuntime/computa-grounding-worker \
  --model-root /absolute/path/to/reviewed/VisualGrounding/models \
  --output /absolute/path/to/fresh-private-audit-directory
```

The Rust runner retains each fixture's exact PNG bytes and hashes, starts one owned worker process, requires its exact parent/instance/three-model ready record, and warms all three production models through a closed benchmark-only request. It executes all 91 requests serially over bounded length-prefixed frames, verifies capture/target hashes and dimensions on every reply, independently checks the frozen midpoint, requests a clean shutdown, and requires the exact child to exit and be reaped. Missing reviewed artifacts stop the run with a finite failed audit; synthetic coordinates cannot qualify a live replay. `cascade.json` retains the report in the private output directory.

Latency definitions:

- `ready_wall_seconds`: process launch through the ready record, including model load and worker warm-up;
- `request_latency_*`: caller wall time from writing one NDJSON request through parsing its response;
- `worker_latency_*`: worker-reported routing and inference time for the same 91 requests, including the expected refusal;
- `wall_seconds`: the complete one-process replay, including startup, all requests, and shutdown.

The p95 is a percentile over one serial, uncontended pass through this correlated task mix. It is not a repeated-process service-tail estimate. OS, filesystem, and Metal caches are not cleared. Use multiple fresh-process runs and an unseen-app corpus before making broader cold-start, reliability, or tail-latency claims.

## Historical Swift/Python result on this Mac

The earlier Swift/Python production-worker replay on September 24, 2026 completed all 91 requests and shut down cleanly. This historical result does not qualify the Rust tensor implementation or Rust worker:

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

## ShowUI alone

ShowUI is not 100% accurate on this fixture. A separate one-process replay exercised the installed 2B 4-bit model alone through the production prompt and parser contract:

| Result | Value |
| --- | ---: |
| Syntactically valid points | 91/91 |
| Correct points inside the exact target box | 74/91 (81.3%) |
| Wrong accepted points | 17/91 |
| Development cohort | 42/52 |
| Held-out visual-perturbation cohort | 32/39 |
| Warm request p50 | 1.365 s |
| Warm request p95 | 1.383 s |
| Reported MLX peak | 3.264 GB |
| Complete 91-request replay | 124.206 s |

The errors were systematic: `weekly-check` was 0/7, `atlas-check` was 1/7, and `harbor-trash` was 3/7; every other retained target was 7/7. Because the model returned valid-looking coordinates for all 17 misses, ShowUI alone has no independent signal with which to reject those clicks. On the retained Calculator set it was 0/6, although those six rows are only two unique screenshots repeated three times each. The smaller Calculator images produced a 154 ms warm median, showing that speed did not imply correct localization.

The retained artifacts are `LocalCodex-showui-alone-production-contract-2026-09-24.json`, `LocalCodex-showui-alone-2026-09-24.json`, and `LocalCodex-showui-alone-calculator-2026-09-24.json` in the parent project's `outputs` directory. As with the cascade result, this is one correlated synthetic-app pass, not a general real-world accuracy estimate.

## Product acceptance beyond this corpus

The corpus replay verifies deterministic routing, grounding accuracy on retained fixtures, refusal behavior, and worker lifecycle. Product acceptance additionally requires:

- Rust protocol, exact architecture/processor, and frozen upstream numerical fixture tests;
- Rust decision, cancellation, worker-restart, artifact, and runtime-lifecycle tests;
- a native app whose resource bundle contains the exact worker/manifests and Metal closure;
- the opt-in Calculator gate, which approves only a grounded point independently proven inside Calculator's digit-1 AX frame, verifies the display transition through a fresh AX read, verifies raw App Server lifecycle evidence, and requires clean runtime shutdown.

The Calculator gate is intentionally separate because a retained-image hit is not proof that capture, model tool choice, approval, coordinate conversion, click delivery, post-action verification, and cleanup work together on the live desktop.

The historical September 24 Swift baseline opt-in run with Qwen3.5-4B passed that gate in 25.753 seconds: exactly `open → capture → ground_click → snapshot`, an independently verified digit-1 point, Calculator display transition `0 → 1`, matching rollout/raw-wire lifecycles, and successful owned cleanup. The immediately preceding attempt safely returned an occlusion error because a stale full-display macOS Screenshot overlay was above the target; it posted no click.

After the runtime began preparing the sidecar in parallel with Qwen and `ground_click` began returning a fresh verification-only screenshot with synchronized Accessibility, a settled-app rerun passed with exactly `open → capture → ground_click` in 18.904 seconds of XCTest wall time. The raw wire turn fell from 23.885 to 17.051 seconds (28.6%), while tool time fell from 10.751 to 3.369 seconds (68.7%). The verification observation carried no reusable `capture_id`; Qwen explicitly reported reading the visible `1` from its screenshot, while the synchronized AX text did not contain the display value. Total input-plus-output tokens fell from 19,010 to 15,254 (19.8%). Non-tool/Qwen time was 13.682 seconds, 80.2% of the optimized wire turn and 4.2% above the baseline run; the six-second capture-to-ground planning interval is now the largest single stage. This is one before/after run, potentially affected by model and OS caches, not a latency distribution. One preceding run safely reported post-action uncertainty while Calculator pixels were still moving, after which Qwen requested a separate capture and verified the result without repeating the click. Other intervening runs safely refused a duplicate visible digit, a changed capture, and a still-moving cold-launch window without posting a wrong click.

The current run's raw App Server trace and rollout are retained in `../outputs/LocalCodex-4B-calculator-speed-2026-09-24/` relative to the repository's parent project directory. Their SHA-256 digests are `fbf814bae97c3fdbb3dfe9264009e3e5d9b72ae21a2336fc72d66650ade8f568` and `96e32d41931c66625f4e1f0412437a33b4117d9e021d1760cb6aefe77446f1e4`, respectively.
