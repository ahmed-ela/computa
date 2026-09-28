# App-owned headless MLX migration: consolidated validation

Prose uses the current product name, Computa. Historical artifact paths,
identifiers, quoted records, and measured results retain their original values.

Evidence snapshot: September 25, 2026, after the loaded-model parent-death and
controlled delayed-cancellation gates. This report distinguishes code/build validation,
synthetic provider primitives, and actual Computa native-runtime trials. It is
not a claim that the installed application has already been migrated or that the
larger Screen Sharing goal is complete. Nothing has been committed or pushed.

## Result at this snapshot

Qwen3.5-4B MLX 4-bit runs through Computa's app-owned, loopback-only MLX-VLM
backend without an LM Studio serving process. Actual Computa text, native status
tool, Chrome window capture, manual compaction, and production-threshold
automatic compaction gates passed. Normal runtime shutdown released its listener.
A separate loaded-model supervisor-crash gate also passed: the watched server
exited in **520.381 ms**, released port 1237, and required no fallback cleanup.

An important unfinished gate remains: model rotation/release. The controlled
delayed-cancellation probe passed at its observable boundary, but does not prove
GPU prefill instrumentation or independent drain. The strict bare-JSON screenshot benchmark **still failed its
format requirement**, even though the recorded image answer was semantically
correct. The installed app has not been replaced by these tests. The unresolved
28-receipt retention floor also remains; these results do not establish that
every arbitrarily long task can compact indefinitely.

## What is being validated

The new backend is one app-owned Python process hosting pinned MLX-VLM 0.7.1
and MLX 0.32.2 directly, with in-process request/Responses compatibility checks.
It reuses existing local weights and the pinned VisualGrounding environment;
there is no extra proxy process, Electron shell, model download, or permanent
serving daemon in this design. The default remains Qwen3.5-4B 4-bit. Saved model
IDs and the legacy provider identity are retained for conversation compatibility;
the `lmstudio-community/…` weights name does not imply an LM Studio dependency.

The provider reserves one sequence, a 16,384-token context and at most 4,096
output tokens, with a 512-token thinking budget. Thinking-budget enforcement is
a forced closing of the thinking section with a small overshoot, **not** a strict
512-total-token cap or an accuracy guarantee. The app's reported effective
window in the live compaction trials was 15,564 tokens; its shipping automatic
compaction threshold is 12,288. These are different measurements/limits.

The compatibility boundary addresses two verified upstream problems:

- Public output is derived only from actual public deltas. Known final-parser
  whitespace stripping is corrected; arbitrary final-text disagreement fails
  closed. Unfinished reasoning is never promoted to an assistant answer.
- Completed executable tool items are withheld until the terminal envelope and
  clean EOF validate. Call IDs and arguments are retained. Exhausted generation
  produces `response.incomplete`, not a false successful completion. The exact
  pinned context-overflow HTTP error maps narrowly to the typed
  `context_length_exceeded` Responses failure.

Bounds, local-model allowlisting, offline loading, parent ownership, native
approvals, screenshot input restrictions and StudyLock protections are preserved.

## Actual native-runtime and regression results

All latencies below are single test-case wall-clock observations, not medians,
tokens/sec, or a matched comparison with LM Studio.

| Gate | Observed result | Test-case time |
| --- | --- | ---: |
| Full native deterministic suite | **725 passed, 34 skipped, 0 failed**; 759 discovered across both bundles | xcodebuild test operation 40.811 s |
| Owned MLX text + native read-only status tool | Passed exact public markers, exactly one successful `computer_v2_status`, rollout and App Server primitive traces, and listener release after shutdown | 16.736 s |
| Owned MLX production Chrome capture | Passed `computer_v2_open` followed by capture of bound Chrome window, PNG tool output, synchronized AX metadata, exact final marker, and shutdown/listener release | 19.328 s |
| Manual native compaction | One lifecycle completed, exact retained canary and one successful subsequent read-only status tool | 24.108 s |
| Production-threshold automatic compaction | One lifecycle completed at the shipping threshold; measured context shrank; exact canary and one subsequent read-only status tool retained | 189.165 s |

The full deterministic count is computed from the logged bundles:
`HeyDashTests` 518 discovered / 32 skipped, and AutomationCoreTests 241 discovered /
2 skipped, both with zero failures. It must not be described as 759 passing tests.

The Chrome gate used a benign Example Domain test page and allowed no click,
typing or further navigation after opening it. The model received PNG and AX
together. This proves the native capture/tool-result/continuation path, **not**
image-only understanding independent of AX or arbitrary desktop-task success.

Compaction details from the retained test proof:

| Mode | Before maximum | Measurements after compaction | Completed compactions | Canary / continued native status tool |
| --- | ---: | --- | ---: | --- |
| Manual | 3,759 tokens | 4,269; 4,278 | 1 | Exact / 1 successful |
| Production auto | 13,200 tokens | 7,047; 6,998; 7,002 | 1 | Exact / 1 successful |

Manual compaction of this short fixture **increased**, rather than reduced, the
measured footprint; it establishes lifecycle and retention, not compression
efficiency. The automatic fixture did shrink measured context and continued in
the same task. Neither test is the long current-turn receipt-floor stress case.

## Synthetic guarded provider primitives

The original detailed audit is
[GUARDED-RESULTS-2026-09-25.md](GUARDED-RESULTS-2026-09-25.md). Its raw evidence is
`/tmp/heydash-mlx-guarded-20260925.yinNsm`.

| Primitive | Result | Observed timing |
| --- | --- | ---: |
| Exact text marker | Pass; public deltas equal final text | 8.073 s; first public text 7.956 s |
| Read-only synthetic tool + result | Pass; exact call ID, arguments, lifecycle and continuation answer | 1.338 s + 0.702 s |
| Screenshot inside function result | **Strict bare-JSON format failure**; independently audited `left=Queued`, `right=Complete` values correct | 1.606 s + 5.046 s |
| Cancellation after first public text, then new request | Pass at observed stream boundary | Cancel 0.454 s; following request 3.606 s |
| Immediate cancellation after response creation, then new request | Pass at observed boundary only | Cancel 7.249 ms; following request 3.560 s |
| Separate controlled delayed cancellation, then new request | Pass at observed boundary only | 251.320 ms delay after creation; following request 0.686 s |

No synthetic function was dispatched to the computer. The screenshot fixture is
frozen, synthetic and independently scored. Its Markdown JSON fence is retained
as a strict test failure; no parser relaxation or retrospective oracle change
converts it into a pass. Image transport and the recorded semantic reading are
separate positive observations.

The first text timing includes startup effects and 526 generated tokens including
reasoning. Immediate cancellation may occur before GPU generation begins.
Guarded health reports boundary `busy`, not internal worker queue depth or GPU
drain. Successful following requests supplement that observation but do not
prove all possible cancellation phases.

The separate delayed probe retained the original production instructions and
policy, used 512 synthetic records, and cancelled **251.320 ms** after an observed
`response.created` (planned 250 ms). Cancellation occurred 992.642 ms after
request start. It had received created/in-progress/item-added/content-part-added,
but no reasoning or public text delta and no terminal event. Guarded `busy` was
false afterward, and the next non-thinking exact-marker response completed in
686.468 ms (first public text 592.352 ms). The report explicitly keeps internal
worker counts/queue depth unavailable and `workerDrainProven:false`.

Delayed-probe evidence:
`/tmp/heydash-mlx-cancel-delayed-20260925.mKk29S/summary.json`.
This was a separate opt-in run; it does not redefine the original all-suite or
its immediate-early gate. It ran the source loaded before subsequent model-
rotation work. Historical results must not be substituted for validating later
source changes.

## Overflow and exhaustion boundary

Actual live boundary probes passed, with no computer/shell tool execution:

| Probe | Verified result | Time |
| --- | --- | ---: |
| Oversized context | Exactly typed `response.failed` / `context_length_exceeded`; not a false completed response | 0.996 s |
| One-token output allowance | `response.incomplete`, one output token; unfinished thinking not exposed as a public answer | 0.505 s |
| Following ordinary inference | Successful completed response after both boundaries | 0.544 s |

Evidence: `/tmp/heydash-mlx-boundary-20260925.ErBWVH/summary.json` and its three
private request/event pairs. This provider-only summary correctly states
`appServerRecoveryProven:false`: it does not itself exercise App Server recovery.
The separate native compaction trials above prove the named compaction paths,
not that every possible forced provider overflow was recovered end-to-end.

## Memory and crash cleanup

The explicitly loaded parent-death gate used one synthetic no-tool 4B marker
with reasoning disabled, current inherited policy, offline weights, exact
response validation and owned-process/nonce checks. It then sent SIGKILL only to
its own supervisor, exercising the actual Python parent watcher.

| Observation | Recorded result |
| --- | --- |
| Ready but unloaded server physical footprint | `91.5M` from `vmmap` |
| After successful 4B inference, physical footprint | `3.5G` from `vmmap`; peak `4.6G` |
| MLX active/cache/peak after inference | 3,127,421,394 / 43,807,938 / 4,078,300,962 bytes |
| Synthetic marker response | Exact, no tools, 1.402 s; 827 input / 9 output tokens |
| Child disappearance after supervisor SIGKILL | **520.381 ms** |
| Listener and cleanup | Port 1237 free; child absent; no fallback cleanup field/operation required |

Evidence: `/tmp/heydash-mlx-parent-death-20260925.AJ2x0b/summary.json`.
That summary records exact source hashes, launch nonce, parent/child identity,
start time, command and exit facts without prompt or reasoning bodies.

These observations establish lightweight unloaded serving, a measured loaded
process footprint, normal owned shutdown and parent-death cleanup. They are
**not** a matched LM Studio RAM A/B, a universal model-memory ceiling, or an exact
whole-system free-RAM delta. `vmmap` physical footprint and MLX allocator counters
measure different things. The earlier roughly 800 MB unloaded LM Studio process-
group RSS observation cannot be directly subtracted from these footprint numbers.
Other apps, visual grounders, model weights and KV state still consume unified
memory. Idle weight unloading without app exit is not established here.

## Durable evidence references and hashes

Temporary artifact paths can disappear after system cleanup; retain private
artifacts before reboot/cleanup if deeper auditing will be required. Logs may
contain private protocol data and must not be published wholesale.

| Evidence file | SHA-256 |
| --- | --- |
| `/tmp/heydash-mlx-native-tests-r2-20260925.log` | `1e498873cef0bb1bcfef6d276dbcb8d9706f4d8b696806bd03e676eb1ffecb03` |
| `/tmp/heydash-owned-mlx-live-20260925.log` | `6af109157f785386d9a51fb449f883afc68d41d77259d4b27e8662fc470632d6` |
| `/tmp/heydash-owned-mlx-chrome-20260925.log` | `8d08497927ba68869e45979b4f1676201e85c26aa9aada59c74653189c23b2bb` |
| `/tmp/heydash-owned-mlx-compaction-20260925.log` | `8eb4e59fdc18818688453d221c0fa1e995d50b9b1e3d948cb5d482d1ee366481` |
| `/tmp/heydash-mlx-boundary-20260925.ErBWVH/summary.json` | `5045193aa3d1ef715f852354d9f1b4cb81a9737fef70f579df835d64519537e2` |
| `/tmp/heydash-mlx-parent-death-20260925.AJ2x0b/summary.json` | `1939148194c47d662e323af6c7c95bea4ff8b9e30ecf7e472e32757b186d9c6f` |
| `/tmp/heydash-mlx-cancel-delayed-20260925.mKk29S/summary.json` | `2ec891ba6dc234ba3901988c41647a15f2386cdc4ed8617d7dc6b53250be3d93` |

Native result bundle:
`.build/HeyDash/Logs/Test/Test-HeyDash-2026.09.25_17-55-39--0700.xcresult`.

Native primitive artifacts:

- Text/status:
  `/var/folders/r7/885nhb5j0nvbt691yqp4jzyw0000gn/T/LocalCodexLiveTest-09CDC990-44EA-4997-8789-EEF72AF45D8D`.
- Chrome wire trace:
  `/var/folders/r7/885nhb5j0nvbt691yqp4jzyw0000gn/T/LocalCodexChromeCapture-E4AB454D-7234-498E-A439-0F06C99EF59D/app-server-wire.jsonl`.
- Manual compaction wire trace:
  `/var/folders/r7/885nhb5j0nvbt691yqp4jzyw0000gn/T/HeyDashContextLive-B04A5616-ABCB-4525-A71E-FE627F33DF31/protocol.jsonl`.
- Auto-compaction wire trace:
  `/var/folders/r7/885nhb5j0nvbt691yqp4jzyw0000gn/T/HeyDashContextLive-8111899B-BF3D-4C05-8FA2-9A4EAC4A4951/protocol.jsonl`.

## Final model-rotation and native-cancellation gates

After adding native single-inference-lane ownership and process rotation, the
full deterministic suite passed **732 tests, 35 skipped, zero failures** (767
discovered). All 20 owned-process lifecycle tests and six post-action image
tests passed. A preceding run correctly rejected accidental generated Python
cache files in the bundle; only those regenerable cache files were removed,
and the strict packaging assertion was kept. The repeat build's strict/deep
signature verified. Forty Python boundary tests and 14 Bun probe tests passed.

Actual production AppState/App Server gates then passed serially:

| Gate | Result | Time |
| --- | --- | ---: |
| 4B → 9B → 4B in one task | Three exact answers, three distinct MLX process IDs/nonces, each old PID absent, health model matches; one App Server initialize, one thread/start, same thread for all turns; verified shutdown | 25.280 s |
| Interrupt and continue | Actual reasoning delta observed at wire sequence 23 before correlated interrupt/terminal; following exact no-tool answer in the same task; awaited shutdown | 8.151 s |

Rotation process IDs were 96238 → 96305 → 96385. Native checks proved old
process exit before replacement inference; this is not a measured whole-system
RAM delta. Memory pressure briefly reached the system warning level during 9B
inference, so 4B remains the lower-memory default. No 9B process-footprint
measurement was obtained before its verified exit.

The owned backend rejects a different model within a pinned Python process with
`409 owned_restart_required`. Native code performs the safe replacement only
when turns, submissions, compaction and tool work are idle. The existing
conversation and approvals are not reset.

Latest evidence:

- `/tmp/heydash-mlx-model-rotation-native-r2-20260925.log`, SHA-256
  `45a2d2a70e1c39694655606e32d1cd7de773f04886f9c29aaef4ef119024a9f4`.
- `/tmp/heydash-owned-mlx-interrupt-switch-20260925.log`, SHA-256
  `898d49d1997db82893ebb53470018ddc92292596da9a8871ace16ed3189deeb6`.
- Result bundles: `Test-HeyDash-2026.09.25_18-25-22--0700.xcresult` and
  `Test-HeyDash-2026.09.25_18-26-25--0700.xcresult` under `.build/HeyDash/Logs/Test`.
- Final sticky-model `server.py` SHA-256:
  `dfc6633b275012051c9036ecd1c25e174d764ab4ff40c5f1a30cfcf08b00e695`.

The verified development build was opened and reloaded the existing saved task
list. Its actual process owns the loopback MLX child; LM Studio remains stopped.
The user-approved unused 27B download was removed, increasing free disk space
from about 3.3 GiB to 18 GiB. 4B/9B weights and conversations were retained.
This deletion is recoverable by re-downloading the model, not by an in-app undo.

## Remaining work and claims expressly not made

1. Model rotation and normal/crash process cleanup passed as described above;
   no 27B/35B capability or universal memory ceiling is claimed for this backend.
2. Finish/review installation and user-facing startup behavior. These native tests
   ran the development build; they did not migrate the installed app or prove
   all saved user conversations resumed successfully.
3. Resume the macOS Screen Sharing task after serving acceptance. No complete
   list of the remote Mac mini's existing YouTube tabs has been produced.
4. Address the independent long-current-turn receipt floor and opaque-surface
   post-action observation problems with general changes and held-out tests.
   The retained native receipt audit found **28 pairs requiring at least 12,469
   provider bytes versus the 12,288-byte bound** (21,083 canonical bytes), with
   none of 42 tested caps fitting. Ordinary manual/auto compaction passes do not
   eliminate that failure mode. See
   [SCREEN-SHARING-2026-09-25.md](../SCREEN-SHARING-2026-09-25.md).

No universal computer-use accuracy, infinite-chat guarantee, matched speed/RAM
improvement percentage, completed Screen Sharing outcome, installation, commit,
or push is claimed by this report.

## Independent serving checkpoint — September 25, 20:28 PDT

This read-only source/evidence audit plus deterministic rerun supersedes the
opening snapshot's **unfinished model rotation** statement: rotation and native
interruption subsequently passed as recorded above. It does not rerun inference,
GUI actions, a native build, or installation. No serving source, dependency,
oracle, prompt, or previously saved result was changed by this audit.

Fresh deterministic results on the current boundary source:

- Pinned environment Python, `-B -m unittest discover -s Tests/MLXServer
  -p 'test_*.py' -v`: **40/40 passed**, 0.050 seconds. Tests import the boundary
  without importing MLX, loading models, or starting a listener.
- `bun test` on `cancellation.test.ts`, `provider-observation.test.ts`,
  `stream-contract.test.ts`, and `parent-death-live.test.ts`: **14/14 passed**,
  67 assertions, 29 milliseconds. Only deterministic tests ran, not the
  opt-in parent-death script entry point.
- Distribution metadata still reports MLX **0.32.2**, MLX-VLM **0.7.1**, and
  llguidance **1.8.0**; no package import or dependency update was needed to
  check these versions.

All seven evidence hashes in the table above and both later rotation/native-
interrupt log hashes were independently recomputed and matched. The saved logs
contain the following exact passed native acceptance tests:

| Acceptance boundary | Saved passing test |
| --- | --- |
| Owned text and real read-only tool continuation | `LocalQwenLiveTests.testOwnedHeadlessRuntimeTextAndReadOnlyTool` |
| PNG tool result through native Chrome capture | `ChromeCaptureV2LiveTests.testProductionRuntimeCapturesBoundChromeWindow` |
| Manual compaction with retention/continuation | `RuntimeContextLiveTests.testManualCompactionConfirmsLifecycleAndRetainsCanary` |
| Shipping-threshold automatic compaction | `RuntimeContextLiveTests.testProductionAutoCompactionPreservesCanaryAndContinuesReadOnlyToolUse` |
| Streamed generation interrupted, same-task reuse | `LocalQwenLiveTests.testProductionRuntimeInterruptsActiveTurn` |
| Reap old weights before 4B/9B/4B replacement | `HeadlessMLXModelSwitchLiveTests.testOwnedProcessRotatesFourNineFourWhilePreservingOneTask` |

Those are historical live passes, corroborated by current test definitions and
unchanged artifact hashes, **not new live passes on unrelated subsequent native
harness edits**. Normal and parent-death cleanup evidence remains separate from
an uninstrumented GPU-drain claim. The source review found no new blocking
serving defect within these named boundaries; it cannot prove all possible
request, memory-pressure, or cancellation schedules.

The strict screenshot result was independently re-scored from saved request and
event files using the current transport oracle. The completed response, model,
call-ID continuation, public-delta/final-text consistency and single tool-result
image all validate. Decoding that submitted image reproduces the frozen fixture
SHA-256 `4b77a20428bfdba6c236967ccca4f266992c81c0c98dd0bdb192e9a84964aa56`.
The public answer is a fenced JSON object with the correct two fixture values;
bare `JSON.parse` still fails. Therefore this is an **output-format compliance
failure**, not evidence that screenshot transport or model serving failed. The
original compound image gate remains failed; no relaxed parser changed its
result.

A general next experiment, if structured output is required, is a separately
named constrained-output gate with an explicit JSON schema, varied held-out
fixtures and unchanged strict parsing. The installed MLX-VLM
`server/request_normalization.py:95` accepts Responses `text.format` or
`response_format`, and `:124` builds schema-constrained logits processors;
`structured.py` contains a thinking-aware processor. This is source evidence of
a candidate mechanism, **not a tested guarantee** for the current Qwen/stream
combination. Do not strip fences or add the oracle answers to the schema to make
the old test pass. No such experiment or production behavior change was made.

Current boundary source SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `server.py` | `dfc6633b275012051c9036ecd1c25e174d764ab4ff40c5f1a30cfcf08b00e695` |
| `response_boundary.py` | `740c7e26deefcc1b3414bfdf3c18cf8c4741eb82b00ff930c6ca42ad1c9af899` |
| `sse_contract.py` | `c596d63643be81064f5ee064e93dc3a67ebc09bfdf6bb328bdff42d059a9fcef` |

Remaining work is release/installation acceptance, broader task-quality and
structured-output validation, and the independent durable-history/receipt-floor
work—not replacement of an observed broken MLX transport. The later Screen
Sharing retry and subsequent user-priority pivot are recorded in its separate
benchmark report; this checkpoint does not authorize resuming that live task.
