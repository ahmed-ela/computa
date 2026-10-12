# API model providers

Computa can connect native API providers without a browser session. Open **Settings → API providers → Manage providers**, select Cerebras or enter a custom provider, and choose Chat Completions or Open Responses. Connect loads the provider's actual `/models` catalog; unavailable saved selections stay unavailable instead of silently selecting another model. API keys are stored only in macOS Keychain, outside the WebUI, model snapshots, App Server configuration, and local transcript.

## Boundary and extension points

The existing native App Server owns instructions, terminal sessions, `apply_patch`, approvals, access mode, browser tools, diffs, and history. API adapters supply inference through the same local Responses interface. An API provider therefore does not own tool execution or permissions.

- `APIProviderDefinition` describes endpoint, wire format, and discovered models. Stable namespaced app model IDs retain the remote provider/model identity.
- `APIProviderCatalog` validates metadata and contains isolated capability profiles. New Chat Completions or Responses endpoints can be configured without changing the agent loop or frontend model selector. A different wire protocol belongs in an adapter at this boundary.
- `APIModelServer` admits requests only for the current native task/thread/turn, reads credentials in native code, and drains cancellation before retiring that context. Configuration/key updates are atomic and rejected while inference is active.
- `APIModelResponseCodec` translates structured history and namespaced/custom tools, validates tool names, schemas, arguments, call IDs and completion policy, and produces complete Responses resources/events. Private reasoning continuation is encrypted and bound to provider, endpoint, model and durable native thread.
- `APIProviderHTTPClient` owns outbound HTTP, bounds responses, rejects redirects before forwarding credentials, disables cookies/cache/ambient credentials, and exposes finite errors without raw provider bodies or automatic replay.

Changing API model, endpoint or context capacity requires a new task while an incompatible native thread is loaded. Provider reasoning also rejects incompatible continuation after a cold restart rather than replaying or silently discarding it.

## Cerebras compatibility

Qwen 3.8 27B uses the exact catalog ID `qwen-3.8-27b`. The official Cerebras endpoint profile combines system/developer instructions, in their original order, into one opening system message while preserving user/assistant/tool history. It preserves `reasoning` continuation with `clear_thinking:false`, and maps extra-high effort to the provider's high setting. Minimal effort is explicitly unsupported. User PNG/JPEG attachments are supported; this provider's assistant/tool messages accept text. Native screenshot capture is therefore omitted from its tool catalog, while accessibility and browser text tools remain available.

The adapter currently buffers a bounded provider response before forwarding Responses events. This allows complete tool-call validation before execution, but does not provide progressive first-token streaming. API support does not repair or qualify a blocked website provider session.

## Validation

The API unit/contract suite covers both wire formats, actual pinned Open Responses schemas, SSE lifecycles, interleaved/custom/namespaced tools, schema references and unions, encrypted reasoning, stale native turns, cancellation, model discovery, redirects, credential admission races, unavailable selections, and secret-free metadata/error projections.

The opt-in `APIProviderHarnessLiveTests` uses the pinned bundled native engine with a loopback synthetic API and in-memory credentials. It exercises a native patch, an actual command/file check, shutdown, and cold resume with the same encrypted continuation. Enable it with `TEST_RUNNER_COMPUTA_API_ENGINE_TEST=1` when running Swift tests. This fixture is distinct from a live Cerebras account test.

Request rejections expose only fixed error categories by default. Local diagnosis can arm a single authenticated task/thread in a private `APIRequestDiagnostics-v1` directory; the consumed arm records a bounded, credential-redacted rejection description without headers, request prompts, or raw response bodies. It never sends another inference automatically.

A controlled installed Cerebras request identified a concrete Qwen chat-template rejection: `wrong_api_format` on `messages`, with “System message must be at the beginning.” The shared Responses history had a later developer instruction that became a later system message. The correction is confined to the official Cerebras/Qwen Chat Completions profile; generic providers and Responses adapters retain their original roles. Tests cover interleaved instructions, resumed private reasoning, and native/custom tool result identities.
