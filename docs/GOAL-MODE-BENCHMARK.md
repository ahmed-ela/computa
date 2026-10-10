# Local-model goal comparison — 2026-10-09

All six official trials failed the complete task. There were two repeats each for Computa ordinary mode, Codex ordinary mode and Codex native goal mode. Computa goal mode was unavailable and is **N/A**. These results identify integration failures; they establish neither a product ranking nor a general conclusion about goal efficiency.

## Conditions

- Computa was the installed **0.6.0 (39)** desktop app, with engine **0.155.0-alpha.9.2**. Codex was the unmodified desktop-bundled **0.162.0-alpha.2** app-server, driven through RPC rather than its graphical task UI.
- Every trial used the same actual `lmstudio-community/Qwen3.5-4B-MLX-4bit` files and Computa-owned endpoint `http://127.0.0.1:1237/v1/codex`, serially, with medium reasoning. Configured context was **16,384**, compaction **12,288**; all six runtimes reported an effective model context window of **15,564**.
- Each trial had a fresh owned project/thread, a 600-second ceiling and a 120-completed-response ceiling. An error ended the trial; there was no retry, coaching or manually supplied continuation.
- Computa's “Full access” UI actually serialized `workspace-write` / `on-request`, with network access disabled. Codex used the corresponding sandbox and scoped approvals. Its configured MCPs/apps/plugins were disabled; it retained its approved normal Codex home.
- Product instructions, tool catalogs and engine versions differed. Both products received the same task with its final LF removed; Computa also supplied its background-only policy content item. This was a shared-model task comparison, not an identical-system-prompt experiment.
- Computa configured `features.goals=false`; asking its model to initiate a goal did not create persisted state or an automatic scheduler. No extra prompts were used to simulate that feature.

## Task and controls

The standard-library Python event-ledger project required arbitrary-size exact signed decimal amounts, normalization, duplicate idempotency/conflict handling, transactional reload/append, atomic v1 migration with byte-preserving failure and temporary-file cleanup, and correct CLI behavior. The model also had to preserve five public tests and an existing uncommitted note, add meaningful regressions, update the README, run tests, and selectively commit/push to the disposable local bare origin.

The submitted task was:

```text
Repair this event ledger to satisfy every requirement in README.md, including
exact amounts, duplicate/conflict handling, transactional reload and append,
and atomic v1 migration. Preserve the existing public tests and my uncommitted
notes.txt edit. Add meaningful regression tests, update the README, and run all
tests. Commit only requested changes and push that commit to this project's
already-configured disposable local origin. Report the actual results.
```

All trials shared the baseline commit, Git tree and visible-file hashes. Hidden checks were outside model projects. Hidden scores count **16 unique testcase groups**, deduplicating subtest failures/errors. The unchanged baseline passed 3/16 hidden groups and 0/5 public tests. Deliberately broken controls were rejected; the correct reference passed 16/16 and the completion/commit/push controls. These controls validate this finite grader, not universal correctness. A local bare-origin push does not test GitHub authentication.

## Actual results

Rows follow the official chronological order. Every row has `fullTaskPassed=false`.

| Trial | Public / 5 | Hidden / 16 | Wall seconds | Completed responses | Reported input tokens | Output tokens | Total tokens |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Computa ordinary r1 | 3 | 7 | 231.795 | 6 | 54,145 | 2,422 | 56,567 |
| Codex ordinary r1 | 0 | 3 | 252.211 | 6 | 47,344 | 379 | 47,723 |
| Codex ordinary r2 | 0 | 3 | 270.121 | 6 | 47,285 | 372 | 47,657 |
| Computa ordinary r2 | 2 | 5 | 235.494 | 6 | 54,148 | 2,497 | 56,645 |
| Codex native goal r1 | 0 | 3 | 361.541 | 9 | 86,582 | 1,034 | 87,616 |
| Codex native goal r2 | 0 | 3 | 306.806 | 9 | 87,030 | 943 | 87,973 |

Computa partially changed `ledger.py` in both trials, then stopped at the compaction error `function call exceeds the 1 KiB bound`. Codex made no file edits: ordinary r1 and goal r1 stopped at `unadvertised_generated_tool_call`; ordinary r2 stopped at `incomplete_generated_tool_call`, all in the shared local-model bridge. Goal r2 returned an incomplete response labeled `max_output_tokens`. That label **does not prove token exhaustion**: the old boundary could classify missing public output below the budget with the same reason.

None added the required new tests/README changes or committed/pushed; all preserved the original public tests and dirty note. Recorded `exec_command` call counts were 6, 6, 6, 6, 8 and 9 in table order, with zero `apply_patch` calls. No runtime falsely reported task success.

Both Codex goal trials started by setting an active goal on a fresh idle thread, without manual `turn/start`. Bound native prepared-request receipts verify the exact objective, active-goal guidance, Qwen model and medium reasoning in their first inference. Both goals ended **blocked**. All six trials had **zero additional runtime turns**, so automatic-continuation effectiveness was not measured.

Only one task and two repeats per supported arm were measured. Corrected active-goal trials followed all four ordinary trials; the order was not paired or rotated. The earlier `codex-goal-r1` paused-goal/manual-turn/activation diagnostic lacked initial active-goal guidance and is preserved outside all aggregates; prepared-unused `codex-goal-r2` is not a result.

Computa wall time uses raw task/terminal event timestamps. Codex ordinary timing starts before `turn/start`, goal timing before `goal/set`; cleanup is excluded. Goal tracing adds local I/O and a correlation header. It captures a native prepared Responses request **before HTTP serialization**, not wire bytes or provider receipt. These timings support no speed ranking. Response IDs are deduplicated, and tokens are usage actually reported for completed responses; failed-stream usage may be incomplete and HTTP attempt counts are unknown. Stock metadata lookup received 403 and used native fallback metadata; its effect on these failures is unproven.

## Evidence and reproduction boundary

The complete evidence lives in the private Codex workspace at `work/goal-mode-benchmark-20261009`, under `/Users/ahmed/Documents/Codex/2026-10-05/testing-testing-okay-the-mic-works`. Its generator, templates and hidden grader are **not shipped in this repository**. Reproduction requires that preserved workspace, a fresh disposable fixture, the pinned model files and recorded product/configuration; cloning this repository alone does not reproduce these trials.

| Identity | SHA-256 / commit |
| --- | --- |
| `fixture-freeze.json` | `c95de858650957133144d87d63b7f5f020db759a2c619120c13f9a7b10edac69` |
| Baseline commit | `5e8d7e7ba67fea218cb429badb3c85b511b41eec` |
| `task.txt` (461 bytes) | `45fe247fd485a52a3666a16d441660b949f33056f5ab272ed1fb68c3a2cb73f9` |
| Submitted task (460 bytes; final LF removed) | `d1a4d54ba49b581c03fd3de9f9e179cb5ff0e5872ae1650a29c11aa97f1b4880` |
| `shared-model-identity.json` | `dd83d19357abd717d210cb56521423d0aa018e13d1f0109e16b178918c4e7d5a` |
| Actual `model.safetensors` | `52dc943eaf6093a2313271a7a0abc36d127b2a16609a0a7c54ee1b4e4ed06cb8` |
| Stock Codex binary | `cb4e4994627e770800a940b42969c77855a3fc09a6e60b02aa6319f670d6b6ab` |
| `benchmark-analysis-final.json` | `18b3b1c0a0958710ef473c9de116c1a799278c48c58060bd2db6ce34930fd287` |

`BENCHMARK_REPORT.md` and `benchmark-analysis-final.md` retain the narrative and per-run table. `fixture-freeze.json`, `control-validation.json`, `git-control-validation-v2.json`, `prepare_v2.py` and `GOAL_START_PROTOCOL_V3.md` preserve fixture/control and corrected goal-entry details. Per-trial `grade.json`, Computa raw rollout snapshots/`rollout-summary-v2.json`, stock `*-runtime/events.jsonl`/`receipt.json`, and the two `goal-context-verification.json` receipts plus native traces retain execution and grading evidence. The original report's “output ceiling” explanation is qualified by the classification caveat above.

## Cleanup and subsequent source work

Owned stock goals were cleared, threads archived and app-server processes stopped. Computa returned to the pre-existing ChatGPT / GPT-5.6 Sol task and quit normally, restoring its initially closed state. Its app, engine and MLX processes exited and port 1237 closed; the pre-existing Codex desktop app-server remained running.

Eighteen disposable project/origin directories were archived, with ZIP CRC/member hashes and matching live contents verified before removal. `owned-fixtures.zip` SHA-256 is `0a4533d26e0ecc3a5578665b01002ee2618a149f9df527810721c5ca082f9f93`. `owned-fixtures.zip.archive-verified.json`, `owned-fixtures.zip.cleanup-receipt.json` and `application-cleanup-receipt.json` record cleanup. Templates, controls, scripts, receipts and request traces were retained.

At documentation time, source41 has applied a canonical 24 KiB receipt-budget admission rule in place of the arbitrary 1 KiB call bound. Its MLX boundary also distinguishes missing generated public output below the budget from actual output-limit incompleteness; the 107 offline MLX tests passed. These changes have **not yet been qualified by an installed build41 rerun of this benchmark**. Source edits and component tests do not alter the six historical build39/Codex outcomes or establish robust installed task completion. Computa goal support remains disabled.
