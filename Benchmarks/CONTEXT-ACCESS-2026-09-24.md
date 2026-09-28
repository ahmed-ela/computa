# Computa context and access validation — 2026-09-24

Prose uses the current product name, Computa. Historical artifact paths,
identifiers, quoted records, and measured results retain their original values.

## Outcome

Follow-up: [retained-history repair and validation](CONTEXT-RETENTION-2026-09-24.md)
supersedes the implementation and final-state notes below. This report preserves
the original failures and evidence. The long-context model-quality gate remains
separate from deterministic runtime correctness.

Final approved-runtime update: 504 native tests passed, 19 skipped; all five
enabled live access/context gates passed in that batch. The separately recorded
five-sample within-turn series passed 4/5 overall, with four successful native
compactions and one Qwen instruction-following failure before compaction. See
the linked report's **Final app-owned runtime validation** section for the
complete denominator, artifact hashes and actual development-app UI check.

Automatic compaction, the native context indicator, and the two native access
modes are implemented in the development build. The deterministic contracts,
overflow guard, and production approval-mode gate passed. **Model-quality
acceptance is not complete:** the strict automatic-compaction run failed on an
extra tool call, and forced-compaction recall was intermittent. Neither result
has been hidden by weakening its assertions.

No commit, push, installed-app replacement, or StudyLock change was made.
Existing rename, queue, UI, grounding, and unrelated benchmark edits remain.

## Final configuration

- Mac17,8, 24 GiB unified memory, macOS 27.0.
- Qwen3.5-4B MLX 4-bit served by the local LM Studio server.
- Computa declares 8,192 tokens; App Server reports an effective 7,782-token
  window. Automatic compaction starts at 6,144 configured tokens (75%).
- LM Studio's already-loaded model context is 123,648. That server capacity is
  distinct from Computa's smaller declared budget and the ring's effective
  window. This test does not prove behavior with an actual 8K server hard cap.
- Native App Server compactor, with no custom checkpoint prompt or additional
  developer-instruction experiment. Those experiments did not demonstrate a
  reliable fidelity improvement and were removed.
- Same-model summarization; no second summarizer, transcript deletion, or
  background polling. Manual compaction remains an opt-in diagnostic, not UI.

The ring is a SwiftUI circular Gauge outside WebKit. It shows the last measured
request, not lifetime consumption. Unknown capacity, malformed measurements,
stale turns, and zero-breakdown post-compaction estimates cannot fabricate a
percentage. After compaction, it waits for a fresh measured request.

The no-progress guard stops a turn when retained context exceeds the effective
window, repeated above-limit estimates do not shrink, or repeated compactions
make no material progress. Tool output alone and tiny token reductions cannot
reset that budget. It revokes computer capabilities immediately but keeps the
task busy until the exact interrupt terminal is confirmed. Queue dispatch is
paused on failure; it does not race an unresolved compaction.

## Test results

| Check | Final result |
| --- | --- |
| Deterministic native app tests | 330 passed |
| Deterministic AutomationCore tests | 106 passed |
| Bun UI tests | 41 passed, 148 assertions |
| Type check and production WebUI build | Passed |
| Debug code signature, deep and strict | Passed |
| Production Ask → Full → Ask | Passed, 18.831 seconds |
| Oversized retained-input guard | Passed, 25.748 seconds, one compaction |
| Production automatic-compaction quality | Failed strict no-extra-tools assertion; recall and continuation succeeded |
| Forced manual-compaction exact recall | 1/2 passed, 15.950-second failure / 20.681-second pass |
| Identical uncompacted recall control | 2/2 passed, 6.198 / 6.736 seconds |

Total deterministic checks: **477 passed**. The full native run included 349
Computa tests (16 skipped, one failed test with two assertion failures) and 108
AutomationCore tests (2 skipped). It therefore correctly exited with
`TEST FAILED`; it must not be described as an entirely green suite. The two
successful live safety/mode gates are separate from the deterministic count.
Other opt-in live tests were not run.

### Production mode gate

Three fresh tasks each requested exactly one Calculator launch. Ask-mode
requests were held for 300 ms with no raw tool result, then explicitly approved.
The Full-access request was resolved only by production AppState, without a
manual test decision or visible gate. Returning to Ask restored the wait.
Raw JSON-RPC matched all three requests, results, completed items, and distinct
turn identities. No unexpected approval was accepted.

Full access only changes Computa's native approval decisions. Tool validation,
macOS permissions, sandbox constraints, and StudyLock remain binding. Read-only
inspection does not prompt in either mode. The mode is session-only, resets to
Ask on relaunch, and cannot be changed through the web bridge or a model tool.
Uncertain automatic-approval failures stop for review instead of auto-retrying.

### Automatic-compaction quality failure

Final measured footprint before compaction: 6,889 tokens. Subsequent measured
requests included 3,683 tokens after the first compaction and 3,645 after the
second. The exact random retention key was returned after one requested
`computer_v2_status` call.

However, during disposable text generation following the first compaction,
Qwen also emitted `computer_v2_keypress({"key":"enter"})`. The runtime rejected
it in 12 ms because no application was bound; no input was dispatched. The
strict assertion requiring exactly the single requested status call failed.
This is evidence that safety checks held, not evidence of perfect model behavior.

The forced-compaction failures had the original key in context but sometimes
returned the expired `KEY_SAVED` acknowledgment instead. Several prompt-only
variants failed to reliably improve this. These small, synthetic samples are
diagnostics, not statistically established success rates. Native default
automatic compaction also passed an earlier complete strict run, so success is
possible but not yet reliable enough to claim a clean quality gate.

## Rendered app verification

The final debug app was opened and inspected through native Accessibility and
screenshots, not only from source:

- Relaunch selected **Ask every time**; menu exposed only Ask and Full access.
- Enter sent the draft. A protected request displayed the native approval card
  and made the underlying web surface inaccessible.
- Cmd+, could not cover the pending approval with Settings.
- The UI fixture's model added an unrequested URL to its Calculator request.
  It was **declined**, not approved to force a success. The decline reached the
  tool transcript and the model's final response.
- A subsequent read-only status request completed with exactly
  `HEYDASH_CONTEXT_RING_OK` and no approval prompt.
- The native ring and popover displayed **3,105 / 7,782 tokens, 40%**, updated
  from the preceding 3,077-token measurement.

The development app is left open in Ask every time. Full-mode execution was
verified by the isolated production gate; the final UI check did not broaden
the user's running app permissions.

## Reproduction and evidence

Run live inference serially. These tests use isolated Codex homes and synthetic
prompts. They require the named 4B model already loaded in LM Studio.

```sh
TEST_RUNNER_HEYDASH_LIVE_ACCESS_MODE_TEST=1 \
TEST_RUNNER_HEYDASH_LIVE_AUTO_COMPACTION_TEST=1 \
TEST_RUNNER_HEYDASH_LIVE_OVERSIZED_CONTEXT_TEST=1 \
xcodebuild -project Computa.xcodeproj -scheme Computa \
  -configuration Debug -derivedDataPath .build/Computa \
  -destination 'platform=macOS,arch=arm64' test

TEST_RUNNER_HEYDASH_LIVE_MANUAL_COMPACTION_TEST=1 \
TEST_RUNNER_HEYDASH_LIVE_CONTEXT_BASELINE_TEST=1 \
xcodebuild -project Computa.xcodeproj -scheme Computa \
  -configuration Debug -derivedDataPath .build/Computa \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ComputaTests/RuntimeContextLiveTests/testManualCompactionConfirmsLifecycleAndRetainsCanary \
  -only-testing:ComputaTests/RuntimeContextLiveTests/testUncompactedControlRetainsCanaryAfterReadOnlyToolUse \
  -test-iterations 2 test
```

Saved local evidence, outside the repository:
`../../outputs/HeyDash-context-access-2026-09-24/` (relative to this report).
Raw transport capture remains opt-in and disabled in the production app.

| Evidence file | SHA-256 |
| --- | --- |
| `heydash-native-default-full-validation.log` | e5c97b2725e1efa21edbae3157356723a5d3079f31e46e0204ecfea4cbae6818 |
| `heydash-native-default-paired-quality.log` | 162ea29785c92a8c286847705351f8d8bb98ccbad766f83aec4ca14d21cfe80f |
| automatic-compaction-protocol.jsonl | db2ab71da0fdaf8401871ccc040f3c94ddcc77c1af0494d2e59d49991c1d8e67 |
| oversized-input-protocol.jsonl | c597f1deb09a31fe896bedd437e9f5edfd9cf246d84b0c5c7943ae9f756b2d67 |
| access-mode-protocol.jsonl | e4230431b9e5bdbea39702dac5fb862126e6617a1b7ffa74b949d2320f9d4665 |

Remaining acceptance gap: reliable post-compaction instruction-following by the
4B model. Do not call this lossless memory, optimal performance, or a fully green
computer-use reliability result. No automatic retry or output rewriting has
been added to disguise that gap.
