# Open Responses interface

Computa incrementally adopts [Open Responses](https://www.openresponses.org/specification) at its existing model boundary. The agent runtime still owns tool execution, approvals, browser ownership, workspace edits and locally saved history. A model adapter supplies inference through `/v1/responses`.

This is a supported subset, not a claim of full specification compliance. Website inference and the constrained local MLX adapter have different capabilities; a common response shape does not grant either adapter capabilities it cannot provide.

## Website adapter

The production Swift `WebModelServer` listens on an ephemeral loopback port. Requests require its per-process bearer token and a bounded `x-computa-task-id` identifying the owning task. Requests with a website `Origin` are rejected. These protections apply to both response modes; there is no public or CORS-enabled endpoint.

- `POST /v1/responses` accepts `application/json` (including a charset).
- Omitted `stream` and `stream:false` return a JSON response resource. `stream:true` returns `text/event-stream`.
- Responses have the required resource fields, assistant message items, output text, and function call items. Unknown website token usage and reasoning details are `null`.
- SSE event names match each JSON event's `type`; sequence numbers increase, item and content lifecycles finish before `response.completed`, and `data: [DONE]` terminates the stream.
- Website output is buffered and validated before emission. SSE represents the validated response lifecycle; it does not provide live website token streaming.
- Full text history, system/developer messages, assistant `commentary`/`final_answer` phases, and matching function results remain in the original request sent to the adapter.
- `tool_choice` (`auto`, `none`, `required`, a selected function, or `allowed_tools`), `parallel_tool_calls:false`, and `max_tool_calls` are enforced locally. A forbidden call or missing required call fails before any output item reaches the execution loop. Rejected inference is never automatically replayed.
- Function tools require object parameter schemas and object arguments. Explicit `strict:true` is rejected because this adapter does not implement full JSON Schema constrained generation; omitted, null and false remain supported. The website envelope remains Computa's structured handoff; it is normalized into response items at the boundary.

Reasoning effort, summaries, verbosity and output-token limits are advisory website prompt context. Computa cannot verify or force those website settings. The response leaves unknown reasoning and token bounds `null`. Numeric sampler fields use the adapter's declared default profile (temperature/top-p 1, penalties/logprobs 0); they do not attest to the website's private sampler. Nondefault sampling requests fail explicitly. The native Codex engine's optional `reasoning.encrypted_content` include hint is accepted without inventing reasoning items or encrypted data.

Storage and asynchronous background responses, `previous_response_id`, unresolved `item_reference` inputs, structured output formats, image/audio/file/video inputs, logprob expansion and requested stream obfuscation are unsupported by the website adapter and fail before provider access. `store:false` concerns response-server storage; Computa continues to save its own chats locally. WebSocket responses and server compaction are outside this implementation.

Independent website model-selection proof remains in `metadata.computa_website_model` when available. It is a Computa extension describing observed website UI labels, not proof of a private backend build.

## Codex compatibility

The bundled Codex engine uses namespace tools and raw `custom_tool_call` items for operations such as `apply_patch`. Computa retains those wire types so the existing native execution loop keeps working. They are tested under an explicit `codex-custom-tools` compatibility profile, separate from the unmodified standard schema. Standard function and text output is tested against the exact upstream schema. The adapter preserves complete tool payloads and the engine's `end_turn` extension.

Errors use the standard `error.type`, `code`, `message`, and nullable `param` fields. Typed local preflight failures are reported as prompts not delivered. Invalid controls produce 400, unknown models 404, contention or quota limits 429, and provider failures/timeouts use suitable server statuses. Task-correlated local diagnostics survive the bundled engine's generic HTTP-error translation. Sign-in and human-verification gates retain finite Computa `retryable:false` and `required_action` extensions. Model output errors expose finite diagnostics rather than page content, and emit no successful response or tool call.

## Local MLX profile

The existing memory-bounded MLX profile requires streaming, `store:false`, full conversation input and its current token/context limits. Its response resources and terminal framing follow the same contract. Effective generation parameters are captured at the pinned model-library boundary rather than copied from website defaults. At `/v1/responses`, usage is null when the library cannot measure the complete standard breakdown; genuine partial counts remain in `metadata.computa_measured_usage`. The app-owned Codex engine uses an explicit `/v1/codex` compatibility route that retains the original partial `usage` object for its context budget and token reporting. This exception is tested as `codex-local-usage`; it is not standard usage-schema compliance and never fabricates a reasoning-token count. The engine continues its existing internal defaults for absent breakdowns. This profile does not add nonstreaming inference, website capabilities or relaxed memory limits.

## Verification

The test package in `Scripts/OpenResponses` pins the official Open Responses repository to `21a5dbc23578eaf66040755e1b00a1e3476cabda`. Exact upstream OpenAPI, acceptance templates, SSE parser and generated schema files are vendored with their Apache-2.0 license, hashes and provenance. Dependency versions and a Bun lockfile are isolated from application dependencies.

Run from the repository root:

```sh
bun install --cwd Scripts/OpenResponses --frozen-lockfile
bun test Scripts/OpenResponses/conformance.test.ts
MACTOPUS_TEST_BUN=/absolute/path/to/bun swift test \
  --filter 'ComputaTests.(WebModelResponseCodecTests|WebModelServerTests|WebsiteModelEvidenceTests|OpenResponsesIntegrationTests|OpenResponsesAppServerTests|WebModelFailureDiagnosticTests)'
```

`OpenResponsesIntegrationTests` starts the real authenticated HTTP listener with a deterministic model transport. It runs seven selected unmodified official acceptance templates sequentially (six HTTP requests and one local schema fixture). Raw exported JSON/SSE is also checked with AJV against the official schema, without defaults repairing missing fields, and with stricter ordering, reconstruction and terminal checks. Coverage includes JSON defaults, text streaming, function streaming, multiple calls, explicit Codex compatibility, errors, and rejection before provider access.

To retain raw synthetic artifacts, set `COMPUTA_OPEN_RESPONSES_ARTIFACT_DIR` to an empty directory for the integration test. Then run:

```sh
bun Scripts/open-responses-conformance.ts --artifacts /absolute/path/to/artifacts
```

The external runner can target a separately owned test listener with `--official --base-url http://127.0.0.1:PORT/v1 --model browser/chatgpt`. Supply its token through `COMPUTA_OPEN_RESPONSES_API_KEY`, never a command-line argument. These transport tests establish protocol behavior, not live provider routing, website account availability or installed-app qualification.

For offline local-adapter verification, use the already-installed pinned MLX-VLM 0.7.1 Python environment. Its tests replace generation with synthetic iterators and load no model weights:

```sh
PYTHONDONTWRITEBYTECODE=1 COMPUTA_OPEN_RESPONSES_ARTIFACTS=/absolute/path/to/mlx-artifacts \
  /absolute/path/to/pinned/python -B -m unittest discover -s Tests/MLXServer
bun Scripts/open-responses-conformance.ts --artifacts /absolute/path/to/mlx-artifacts
```
