# Usage: jq -s -f Benchmarks/summarize-computer-v2-matrix.jq RUN_DIR/trials.jsonl
# Scope deliberately excludes 27B. Times are whole XCTest task durations,
# including model inference and tool calls; they are not driver-only latency.
def nearest_rank($quantile):
  if length == 0 then null
  else sort | .[((length * $quantile | ceil) - 1)]
  end;

def executed:
  .result == "pass"
  or (.result == "fail" and .test_seconds != null)
  or .result == "timeout"
  or .result == "killed";

[.[] | select(.model == "4b" or .model == "9b")]
| sort_by(.model, .task)
| group_by([.model, .task])
| map(
    . as $trials
    | {
        model: .[0].model,
        task: .[0].task,
        trials: length,
        strict_passes: ([.[] | select(.result == "pass")] | length),
        failures: ([.[] | select(.result == "fail")] | length),
        timeouts: ([.[] | select(.result == "timeout" or .result == "killed")] | length),
        skipped: ([.[] | select(.result == "skip")] | length),
        unverified: ([.[] | select(.result == "unverified")] | length),
        nonexecuted_failures: ([.[] | select(.result == "fail" and .test_seconds == null)] | length),
        executed_trials: ([.[] | select(executed)] | length),
        task_seconds_p50: ([.[] | select(executed) | .test_seconds // .wall_seconds | select(. != null)] | nearest_rank(0.50)),
        task_seconds_p95: ([.[] | select(executed) | .test_seconds // .wall_seconds | select(. != null)] | nearest_rank(0.95)),
        successful_task_seconds_p50: ([$trials[] | select(.result == "pass") | .test_seconds // .wall_seconds | select(. != null)] | nearest_rank(0.50))
      }
  )
