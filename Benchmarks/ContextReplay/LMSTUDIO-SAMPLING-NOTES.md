# LM Studio sampling and capacity audit — 2026-09-24

Prose uses the current product name, Computa. Historical artifact paths,
identifiers, quoted records, and measured results retain their original values.

Read-only audit; no inference, sampling/default changes, model unload/reload, or process changes were performed. These findings identify controls and confounds, not the cause of a failed canary copy.

## Exact installed target

- LM Studio `0.4.25+1` (both `CFBundleShortVersionString` and `CFBundleVersion` in `/Applications/LM Studio.app/Contents/Info.plist`).
- Adapter inspected: `/Applications/LM Studio.app/Contents/Resources/app/.webpack/main/index.js`.
- Adapter SHA-256: `ff9a642757c7119515f6082011086111a6cfc5f10944807a19de51c9696dd718`.
- Installed MLX backend directory: `~/.lmstudio/extensions/backends/mlx-llm-mac-arm64-apple-metal-nax-advsimd-1.11.0`.
- Vendor Python package root: `~/.lmstudio/extensions/backends/vendor/_amphibian/app-mlx-generate-mac26-arm64@33/lib/python3.11/site-packages/`; installed package metadata identifies MLX `0.32.0`, mlx-lm `0.31.3`, mlx-vlm `0.6.5`.

## Actual production response settings

All four completed SSE responses in `../outputs/HeyDash-context-replay-2026-09-24/capture/` (relative to the Computa repository root) reported:

```json
{"temperature":0.1,"top_p":false,"presence_penalty":0,"frequency_penalty":1.1,"max_output_tokens":null}
```

Captured original requests omitted sampling overrides. Evidence files are `001-0874cfb0-d1f0-42bd-a0df-067543ecf068.response.sse`, `002-c3c387d6-95bd-4d98-aa77-9935351a4e13.response.sse`, `003-3c4fcb64-3ba0-4880-b946-2a765d41ec60.response.sse`, and `004-c3a68437-39b8-41ba-b888-9ffc5c78a813.response.sse`. Read the `response.completed.response` object, not a request default or generic SDK schema default.

### `frequency_penalty: 1.1` is mislabeled repeat penalty

In the installed adapter, JavaScript character offset **13791998** assigns `_0x5a779c` from `resolvedPredictionConfig.repeatPenalty` (false/undefined become zero). At **13792845**, the Responses serializer emits that variable as `frequency_penalty`. This is **not evidence of additive frequency penalty 1.1**.

Independently, installed `mlx_lm/sample_utils.py:282–312` implements sign-aware multiplicative repetition penalty: recent-token positive logits are divided by the factor and negative logits multiplied by it. `mlx_engine/utils/generation_helpers.py:31` skips that processor for `None`, `0.0`, or `1.0`. The public SDK documents **`repeatPenalty: 1.0` or `false` as neutral**; use that documented semantic, not OpenAI's additive frequency-penalty zero convention. [Official prediction configuration](https://lmstudio.ai/docs/typescript/api-reference/llm-prediction-config-input)

The cache-aware wrapper, `mlx_engine/processors/repetition_penalty_processor.py:37–52`, includes historical cached tokens in the same recent-token window. Repetition suppression can therefore be an exact-copy confound, but these source observations do not establish that it caused the missing canary characters.

## Supported per-request controls in this Responses adapter

The entire request-to-prediction configuration function begins at adapter character **13778381** (locate `{temperature:_0x30aab2,top_p:` at **13778482**). It reads and maps:

| Field | Installed mapping |
| --- | --- |
| `temperature` | Prediction temperature |
| `top_p` | Enabled top-P sampler with supplied value |
| `presence_penalty` | Enabled presence-penalty configuration |
| `max_output_tokens` | Enabled `maxPredictedTokens` generation limit |
| `reasoning.effort` | Model custom reasoning configuration |

It also maps tools/tool choice. Its custom-field builder receives **only reasoning**, not arbitrary request fields.

The Responses input schema near character **13837328** accepts `frequency_penalty` with default zero, but the prediction adapter **does not read or map it**. The schema has no `repeat_penalty`, `repetition_penalty`, `preset`, or `extra_body`. Consequently, sending `frequency_penalty: 0` is not a repeat-penalty neutralization experiment in this build. No supported per-request repeat-penalty override was found for this endpoint.

The native `/api/v1/chat` and Chat Completions adapters do map `repeat_penalty`; the SDK exposes `repeatPenalty`. Those are different paths, not exact replays of retained Responses bodies. [Native chat parameters](https://lmstudio.ai/docs/developer/rest/chat)

Low-impact exact-request experiments can change documented/mapped `temperature` (explicitly label changed-sampler) or `max_output_tokens`. Testing neutral repeat penalty requires a separately controlled model/default setting with restoration, or a deliberately different SDK/chat experiment. Neither was performed. `max_output_tokens` is a generation budget, not a context-capacity setting; reasoning may consume generation tokens. Its hard-stop behavior still needs an actual bounded test.

## Loaded context and safe, scoped capacity experiment

Fresh `lms ps --json` showed exactly one loaded model:

```json
{"modelKey":"qwen3.5-4b-mlx","identifier":"lmstudio-community/Qwen3.5-4B-MLX-4bit","contextLength":123648,"maxContextLength":262144,"parallel":4,"ttlMs":null,"status":"idle","queued":0}
```

The settings preference `defaultContextLength.value=8192` is **not** the loaded model's capacity. `lms load --help` confirms `--context-length`, `--parallel`, `--identifier`, and `--ttl`; `lms unload --help` confirms an explicit model identifier. No Responses request-level context-length control was found.

The following commands are provided for the root agent's serial, owned-model experiment only; **not executed by this audit**. First stop/finish the test owner's pending inference, verify the exact identifier is idle with zero queued work, and ensure no other client will start using it. The CLI check is a snapshot, not an atomic ownership lock. Never use `unload --all`.

```sh
/Users/ahmedelamin/.lmstudio/bin/lms ps --json
/Users/ahmedelamin/.lmstudio/bin/lms unload 'lmstudio-community/Qwen3.5-4B-MLX-4bit'
/Users/ahmedelamin/.lmstudio/bin/lms load 'qwen3.5-4b-mlx' --identifier 'lmstudio-community/Qwen3.5-4B-MLX-4bit' --context-length 8192 --parallel 4
/Users/ahmedelamin/.lmstudio/bin/lms ps --json
```

Require the post-load listing to show that identifier, `contextLength:8192`, and `parallel:4` before any test. After the bounded test, restore the observed capacity/configuration even on test failure, again only when the owned model is idle:

```sh
/Users/ahmedelamin/.lmstudio/bin/lms ps --json
/Users/ahmedelamin/.lmstudio/bin/lms unload 'lmstudio-community/Qwen3.5-4B-MLX-4bit'
/Users/ahmedelamin/.lmstudio/bin/lms load 'qwen3.5-4b-mlx' --identifier 'lmstudio-community/Qwen3.5-4B-MLX-4bit' --context-length 123648 --parallel 4
/Users/ahmedelamin/.lmstudio/bin/lms ps --json
```

Omitting `--ttl` requests no explicit TTL; verify restored `ttlMs:null`. These restore the **observed** identifier/context/parallel/TTL, not unreported opaque load settings. Do not claim complete restoration from command success alone. A real 8192-capacity test must inspect overflow/compaction outcomes and actual server usage; the CLI parameter alone is not behavioral proof.

### Follow-up: the installed backend expands the requested capacity

The root agent performed the scoped idle-model reload above. The CLI accepted
`--context-length 8192`, but `lms ps`, `/api/v1/models`, and `/api/v0/models`
all reported **123648** afterward. The 2026-09-24 server log at 10:18:54
explicitly records `configured=8,192 fitted=123,648 effective=123,648`.
Thus the argument reached the backend; this is not evidence of an 8K hard cap.

Installed backend 1.11.0's `batched_vision/model_kit.py:242–250` calls the Qwen
auto-fit path; `cache_store.py:116–125` chooses the larger configured/fitted
capacity. The app's `mlxContextAutoFit` feature gate begins at runtime **1.11.1**
(bundle feature table near character 9230752); its load-argument adapter only
forwards `mlx_context_auto_fit` when that gate is available. No supported
auto-fit-off control was established for the installed 1.11.0 path. Changing the
CLI to REST would not itself prove the cap; no runtime update or backend patch
was performed.

After the experiment, the same model was reloaded explicitly with its original
123648 capacity, parallel4, identifier, and no TTL. A fresh CLI readback confirmed
those values and idle/queued0. Actual hard-8K validation remains unavailable on
this installed backend; the native 8192/6144 app compaction policy is a separate
tested contract.
