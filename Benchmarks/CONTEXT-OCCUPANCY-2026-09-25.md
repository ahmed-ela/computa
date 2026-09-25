# Provider cost versus context occupancy — 2026-09-25

## Observed cause

The interrupted 71.158-second Amazon trial contains two Responses requests with
multiple internal LM Studio prompt passes after schema-invalid scroll calls.
LM Studio sums those passes into one usage record. The bundled Codex runtime
treats that record as the size of its latest active context.

| Usage checkpoint UTC | Internal prompt sizes | Reported input tokens | Reported cached tokens |
| --- | --- | ---: | ---: |
| 08:41:04.883 | 8,680 + 9,167 | 17,847 | 16,484 |
| 08:41:43.104 | 10,576 + 10,762 | 21,338 | 19,938 |

The corresponding cached/uncached sums are 7,357+1,323, then 9,127+40;
and 9,216+1,360, then 10,722+40. No HTTP POST intervenes between the passes of
either pair. The parser copies the aggregate input/cached numbers unchanged;
this is not a client-side arithmetic duplication of a single usage event.

The configured 4B window is 16,384 tokens, with a 12,288-token compaction trigger;
the reported 15,564-token effective window is the normal 95% buffer. The final
aggregate triggered a second summary request even though the largest actual
prompt was 10,762 tokens and only small failed-call receipts followed. That
trigger is not proof of genuine context pressure. The earlier trigger is less
conclusive: a new high-detail screenshot and text followed the request and must
also be included before evaluating the compaction threshold.

Both internal repair rounds followed a scroll call missing required x/y
arguments. The tool schema and corrective-feedback changes target that observed
source of retries; they do not establish a general solution to provider usage
aggregation or prove the model can no longer emit invalid calls.

## Rejected shortcut: disable parallel calls

The [official function-calling contract](https://developers.openai.com/api/docs/guides/function-calling#parallel-function-calling)
specifies that `parallel_tool_calls=false` limits a response to zero or one
function call. The installed local compatible backend did not enforce this:

| Request setting | Returned calls | Echoed setting | Seconds |
| --- | ---: | --- | ---: |
| false | 2 | true | 1.515 |
| true | 2 | true | 1.536 |
| false | 2 | true | 1.359 |

These three serial, inert two-function probes executed no tools. Each returned
367 input tokens, so they demonstrate the ignored setting, not an aggregate-cost
spike. Invalid-argument repair rounds and multiple valid function calls are
distinct cases. No shipping setting was changed based on this experiment.

## Evidence and safety boundary

- Installed LM Studio: 0.4.25+1. Source SHA-256:
  `ff9a642757c7119515f6082011086111a6cfc5f10944807a19de51c9696dd718`.
- `/Users/ahmedelamin/.lmstudio/server-logs/2026-09/2026-09-25.1.log`, numeric
  cached/uncached records at lines 5443/5446 and 8358/8361.
- Private app rollout `rollout-2026-09-25T01-40-33-01a0d7b9-31e1-7961-b0a4-b39e52f9028e.jsonl`,
  usage records at lines 82/136. Private prompt/order content is not copied here.
- Installed `index.js` contains `ResponsesUsageCollector`, whose
  `getInputTokens()` sums `promptDetailsByRound.totalPromptTokens` and whose
  `buildUsage()` also sums cached counts. Per-round progress is logged but is
  not exposed as a usable per-round SSE usage extension. Response completion
  includes the aggregate only.
- Pinned runtime: `codex-api/src/sse/responses.rs:138` copies usage;
  `core/src/context_manager/history.rs:771` consumes the last total as occupancy;
  `core/src/session/context_window.rs:57` uses that in compaction decisions.
- Inert probe requests/results: `/tmp/heydash-parallel-usage-20260925.iI3OlR/`.

Do not divide reported usage by the number of calls, subtract an assumed retry,
or silently reduce context safeguards. Valid multi-call outputs do not reveal
how many prompt passes occurred. A future fix must distinguish aggregate cost
from bounded context occupancy with independently validated evidence. Neither
vendor code, model settings, context limits, nor native compaction accounting was
modified during this investigation.
