#!/bin/bash
# Serial, opt-in LocalCodex V2 computer-use benchmark. No V1 fixture tests.
set -u
set -o pipefail

usage() {
    printf '%s\n' \
        'Usage: Benchmarks/run-computer-v2-matrix.sh [--models 4b,9b] [--tasks status,chrome,semantic,combined,visual,interrupt] [--reps N]' \
        '' \
        'Defaults: 4B and 9B, all five V2 gates, three fresh trials per cell.' \
        '27B remains opt-in with --models 27b; it is never selected by default.' \
        'interrupt is an optional transport-cancellation gate, not a desktop-action task.' \
        'The runner is serial. Results go to a unique directory under ../outputs.' \
        'Use --dry-run to print the selected matrix without running live tests.'
}

models_arg='4b,9b'
tasks_arg='status,chrome,semantic,combined,visual'
reps=3
dry_run=0
while (( $# > 0 )); do
    case "$1" in
        --models|--tasks|--reps)
            option="$1"
            shift
            if (( $# == 0 )); then
                printf 'Missing value for %s\n' "$option" >&2
                usage >&2
                exit 2
            fi
            case "$option" in
                --models) models_arg="$1" ;;
                --tasks) tasks_arg="$1" ;;
                --reps) reps="$1" ;;
            esac
            ;;
        --dry-run) dry_run=1 ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ "$models_arg" == 'all' ]] && models_arg='4b,9b'
[[ "$tasks_arg" == 'all' ]] && tasks_arg='status,chrome,semantic,combined,visual'
if [[ ! "$reps" =~ ^[0-9]+$ ]] || (( reps < 1 || reps > 20 )); then
    printf '%s\n' '--reps must be an integer from 1 through 20.' >&2
    exit 2
fi

IFS=, read -r -a requested_models <<< "$models_arg"
IFS=, read -r -a requested_tasks <<< "$tasks_arg"
if (( ${#requested_models[@]} == 0 || ${#requested_tasks[@]} == 0 )); then
    printf '%s\n' 'Select at least one model and task.' >&2
    exit 2
fi
for model in "${requested_models[@]}"; do
    case "$model" in 4b|9b|27b) ;; *) printf 'Unknown model: %s\n' "$model" >&2; exit 2 ;; esac
done
for task in "${requested_tasks[@]}"; do
    case "$task" in status|chrome|semantic|combined|visual|interrupt) ;; *) printf 'Unknown task: %s\n' "$task" >&2; exit 2 ;; esac
done

# Canonical order avoids reloading a model between task types.
models=()
tasks=()
for model in 4b 9b 27b; do
    [[ ",$models_arg," == *",$model,"* ]] && models+=("$model")
done
for task in status chrome semantic combined visual interrupt; do
    [[ ",$tasks_arg," == *",$task,"* ]] && tasks+=("$task")
done

model_id() {
    case "$1" in
        4b) printf '%s' 'lmstudio-community/Qwen3.5-4B-MLX-4bit' ;;
        9b) printf '%s' 'lmstudio-community/Qwen3.5-9B-MLX-4bit' ;;
        27b) printf '%s' 'mlx-community/Qwen3.8-27B-4bit' ;;
    esac
}

gate() {
    case "$1" in
        status) printf '%s\n' 'LOCALCODEX_LIVE_MODEL_TEST' 'LocalQwenLiveTests/testProductionRuntimeExecutesReadOnlyComputerTool' ;;
        chrome) printf '%s\n' 'LOCALCODEX_LIVE_CHROME_V2_READ_TEST' 'ChromeV2LiveTests/testBoundChromeReadOnlyV2WithSelectedModel' ;;
        semantic) printf '%s\n' 'LOCALCODEX_LIVE_CALCULATOR_MUTATION_TEST' 'LocalQwenLiveTests/testProductionRuntimePressesCalculatorDigitOneWithV2' ;;
        combined) printf '%s\n' 'LOCALCODEX_LIVE_COMBINED_CAPTURE_TEST' 'LocalQwenLiveTests/testProductionRuntimeUsesCombinedCalculatorCaptureWithV2' ;;
        visual) printf '%s\n' 'LOCALCODEX_LIVE_VISUAL_CALCULATOR_TEST' 'CalculatorVisualV2LiveTests/testModelClicksCalculatorDigitOneFromDisplayCapture' ;;
        interrupt) printf '%s\n' 'LOCALCODEX_LIVE_INTERRUPT_TEST' 'LocalQwenLiveTests/testProductionRuntimeInterruptsActiveTurn' ;;
    esac
}

total=$(( ${#models[@]} * ${#tasks[@]} * reps ))
printf 'Selected %d serial trials: models=%s tasks=%s reps=%d\n' "$total" "${models[*]}" "${tasks[*]}" "$reps"
if (( dry_run )); then
    for model in "${models[@]}"; do
        for task in "${tasks[@]}"; do
            printf '%s %s x%d\n' "$model" "$task" "$reps"
        done
    done
    exit 0
fi

for command_name in jq swift mktemp gtimeout; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'Missing command: %s\n' "$command_name" >&2
        exit 2
    fi
done
if [[ ! -x /usr/bin/time ]]; then
    printf '%s\n' '/usr/bin/time is required for wall-time measurements.' >&2
    exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd -P)" || exit 2
repo_dir="$(cd "$script_dir/.." && pwd -P)" || exit 2
output_root="$repo_dir/../outputs"
mkdir -p "$output_root" || exit 2
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$(mktemp -d "$output_root/LocalCodex-V2-benchmark-$stamp-XXXXXX")" || exit 2
trials_jsonl="$run_dir/trials.jsonl"
: > "$trials_jsonl"
git_head="$(cd "$repo_dir" && git rev-parse HEAD 2>/dev/null || true)"
system_tmp="$(swift -e 'import Foundation; print(FileManager.default.temporaryDirectory.path)' 2>/dev/null)"
if [[ ! -d "$system_tmp" ]]; then
    printf 'Could not locate the Foundation temporary directory: %s\n' "$system_tmp" >&2
    exit 2
fi

printf 'Results: %s\n' "$run_dir"
trial_number=0
for model in "${models[@]}"; do
    selected_model_id="$(model_id "$model")"
    for task in "${tasks[@]}"; do
        gate_lines="$(gate "$task")"
        gate_env="${gate_lines%%$'\n'*}"
        test_filter="${gate_lines#*$'\n'}"
        test_method="${test_filter#*/}"
        for (( rep=1; rep<=reps; rep++ )); do
            trial_number=$((trial_number + 1))
            printf -v rep_label '%02d' "$rep"
            trial_dir="$run_dir/$model-$task-$rep_label"
            mkdir -p "$trial_dir/tmp" || exit 2
            touch "$trial_dir/started.marker" || exit 2
            stdout_path="$trial_dir/stdout.log"
            stderr_path="$trial_dir/stderr.log"
            started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            started_epoch="$(date -u +%s)"
            printf '[%d/%d] %s %s trial %d: %s\n' "$trial_number" "$total" "$model" "$task" "$rep" "$test_filter"
            if (
                cd "$repo_dir" || exit 90
                export TMPDIR="$trial_dir/tmp/"
                export LOCALCODEX_LIVE_MODEL_ID="$selected_model_id"
                export "$gate_env=1"
                # GNU timeout uses a separate command process group by default.
                # TERM then KILL bounds the test host and its App Server children.
                gtimeout --signal=TERM --kill-after=10s 950s \
                    /usr/bin/time -p swift test --filter "$test_filter"
            ) > "$stdout_path" 2> "$stderr_path"; then
                exit_code=0
            else
                exit_code=$?
            fi
            finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            finished_epoch="$(date -u +%s)"

            wall_seconds=''
            test_seconds=''
            passed=0
            skipped=0
            for log_path in "$stdout_path" "$stderr_path"; do
                while IFS= read -r line || [[ -n "$line" ]]; do
                    if [[ "$line" =~ ^real[[:space:]]+([0-9]+([.][0-9]+)?)$ ]]; then
                        wall_seconds="${BASH_REMATCH[1]}"
                    fi
                    if [[ "$line" == *"$test_method"* ]]; then
                        [[ "$line" == *' passed ('* ]] && passed=1
                        [[ "$line" == *' skipped ('* ]] && skipped=1
                        if [[ "$line" =~ \(([0-9]+([.][0-9]+)?)\ seconds\) ]]; then
                            test_seconds="${BASH_REMATCH[1]}"
                        fi
                    fi
                done < "$log_path"
            done
            [[ -n "$wall_seconds" ]] || wall_seconds="$((finished_epoch - started_epoch))"
            result='fail'
            if (( exit_code == 124 )); then
                result='timeout'
            elif (( exit_code == 137 )); then
                result='killed'
            elif (( skipped )); then
                result='skip'
            elif (( exit_code == 0 && passed )); then
                result='pass'
            elif (( exit_code == 0 )); then
                result='unverified'
            fi

            # On macOS, Foundation may ignore an overridden TMPDIR. Discover
            # only test homes created after this trial's marker.
            artifact_paths='[]'
            artifact_records='[]'
            for artifact_dir in "$system_tmp"/LocalCodexLiveTest-* \
                "$system_tmp"/LocalCodexChromeV2-* \
                "$system_tmp"/LocalCodexVisualCalculator-*; do
                [[ -d "$artifact_dir" && "$artifact_dir" -nt "$trial_dir/started.marker" ]] || continue
                artifact_paths="$(jq -n --argjson paths "$artifact_paths" --arg path "$artifact_dir" '$paths + [$path]')"
                wire_path=''
                [[ -f "$artifact_dir/app-server-wire.jsonl" ]] && wire_path="$artifact_dir/app-server-wire.jsonl"
                rollout_paths='[]'
                for rollout_path in "$artifact_dir"/sessions/*/*/*/rollout-*.jsonl; do
                    [[ -f "$rollout_path" ]] || continue
                    rollout_paths="$(jq -n --argjson paths "$rollout_paths" --arg path "$rollout_path" '$paths + [$path]')"
                done
                artifact_records="$(jq -n --argjson records "$artifact_records" \
                    --arg home "$artifact_dir" --arg wire "$wire_path" \
                    --argjson rollouts "$rollout_paths" \
                    '$records + [{codex_home: $home,
                                  wire: (if $wire == "" then null else $wire end),
                                  rollouts: $rollouts}]')"
            done

            jq -cn \
                --arg model "$model" --arg model_id "$selected_model_id" \
                --arg task "$task" --arg gate "$test_filter" --arg result "$result" \
                --arg started_at "$started_at" --arg finished_at "$finished_at" \
                --arg wall "$wall_seconds" --arg test_seconds "$test_seconds" \
                --arg stdout "$stdout_path" --arg stderr "$stderr_path" \
                --arg tmpdir "$system_tmp" --argjson artifacts "$artifact_paths" \
                --argjson artifact_records "$artifact_records" \
                --argjson rep "$rep" --argjson exit_code "$exit_code" \
                '{model: $model, model_id: $model_id, task: $task, trial: $rep,
                  gate: $gate, result: $result, exit_code: $exit_code,
                  started_at: $started_at, finished_at: $finished_at,
                  wall_seconds: (if $wall == "" then null else ($wall | tonumber) end),
                  test_seconds: (if $test_seconds == "" then null else ($test_seconds | tonumber) end),
                  stdout: $stdout, stderr: $stderr, tmpdir: $tmpdir,
                  artifact_paths: $artifacts, artifacts: $artifact_records}' >> "$trials_jsonl"
            jq -s --arg run_dir "$run_dir" --arg git_head "$git_head" \
                '{run_dir: $run_dir, git_head: $git_head, trials: .,
                  totals: {pass: ([.[] | select(.result == "pass")] | length),
                           fail: ([.[] | select(.result == "fail")] | length),
                           timeout: ([.[] | select(.result == "timeout")] | length),
                           killed: ([.[] | select(.result == "killed")] | length),
                           skip: ([.[] | select(.result == "skip")] | length),
                           unverified: ([.[] | select(.result == "unverified")] | length)}}' \
                "$trials_jsonl" > "$run_dir/summary.json"
            printf '  %s (exit=%d, wall=%ss)\n' "$result" "$exit_code" "${wall_seconds:-unknown}"
        done
    done
done

printf 'Summary: %s/summary.json\n' "$run_dir"
