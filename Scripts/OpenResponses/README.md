# Open Responses conformance checks

This test-only package pins the official [Open Responses repository](https://github.com/openresponses/openresponses/tree/21a5dbc23578eaf66040755e1b00a1e3476cabda) at commit `21a5dbc23578eaf66040755e1b00a1e3476cabda` and specification version `2026-04-24`. `upstream-manifest.json` records each original file's source URL and SHA-256; the runner verifies every hash before a check. Vendored files are unmodified and retain the upstream Apache 2.0 license.

Install the isolated, pinned test dependencies:

```sh
bun install --cwd Scripts/OpenResponses --frozen-lockfile
bun test Scripts/OpenResponses/conformance.test.ts
```

Validate actual wire artifacts produced by native tests:

```sh
bun Scripts/open-responses-conformance.ts --artifacts /absolute/artifact/directory
```

The directory must contain `manifest.json` matching `artifact-manifest.schema.json`, plus each named JSON or SSE file. Example:

```json
{
  "version": 1,
  "cases": [
    {"name": "text-json", "file": "text.json", "kind": "response", "expectStatus": "completed"},
    {"name": "function-stream", "file": "function.sse", "kind": "sse", "expectStatus": "completed"},
    {"name": "custom-stream", "file": "custom.sse", "kind": "sse", "profile": "codex-custom-tools", "expectStatus": "completed"}
  ]
}
```

`standard` validates raw objects against the exact upstream OpenAPI schema with AJV, with no defaults or coercion. It also checks response/item/content/tool lifecycles, matching SSE event names, increasing sequence numbers, accumulated deltas, terminal output, and the final `[DONE]` sentinel. `codex-custom-tools` adds explicitly described custom calls, custom input events, namespace descriptors and custom choices for Computa's owned Codex engine; this profile does **not** establish standard compliance for those extensions. HTTP error artifacts validate the nested error against the official `ErrorPayload` schema. Request artifacts validate `CreateResponseBody`.

`codex-local-usage` covers the separate owned local MLX `/v1/codex/responses` route. It permits the pinned Codex parser's genuine token counts without a complete standard usage breakdown. All three nonnegative counts remain required, their total must equal input plus output, and any provided detail object must still satisfy its official schema. This exception does not invent reasoning-token counts or apply to the standard `/v1/responses` route, and it does not relax tools, response fields, or stream lifecycles. The standard route uses nullable usage and measured metadata when complete standard details are unavailable.

Run the unmodified official HTTP acceptance templates against a deterministic, authenticated loopback instance of the actual server:

```sh
# Supply the ephemeral server token via the child process environment.
bun Scripts/open-responses-conformance.ts --official \
  --base-url http://127.0.0.1:PORT/v1 --model browser/chatgpt
```

Set `COMPUTA_OPEN_RESPONSES_API_KEY` in that process's environment. The wrapper runs templates sequentially, injects a fresh UUID in `x-computa-task-id` for each request, and additionally validates the raw HTTP response. It prints status and validation errors without printing request/response content or credentials. Server shutdown remains the native test fixture's responsibility.

The selected official tests are basic response, assistant phase input, output phase schema, streaming response, system prompt, function calling, and full-history multi-turn input. The official output phase schema test uses its own local fixture and sends no HTTP request; its success alone proves no server behavior. Image input, compaction, WebSocket and stored `previous_response_id` continuation are excluded. A passing deterministic suite establishes protocol behavior, not live browser/provider reliability or complete Open Responses feature support.
