# Context replay diagnostics

Opt-in, synthetic prompts only. The capture listener and upstream are loopback;
the CLI always forwards to `http://127.0.0.1:1234`. There is no tool executor.
Only custom function schemas are accepted; hosted/MCP tools are rejected.
Requests must carry their input history, without server-side conversation IDs.

```sh
bun Benchmarks/ContextReplay/context-replay.ts capture --out /ABS/capture --port 1235
bun Benchmarks/ContextReplay/context-replay.ts replay --request /ABS/capture/REQUEST.request.json --out /ABS/replays --count 3
bun test Benchmarks/ContextReplay/context-replay.test.ts
```

Capture forwards POST `/v1/responses` without changing request or response bytes.
GET `/v1/models` and `/api/v1/models` are forwarded for discovery, not recorded.
Only the test client's base URL should point at the capture listener. This helper
does not change Computa, LM Studio, model loading, or user preferences. Stop it
after the bounded experiment. Capture stops accepting inference after 30 requests.

Replay preserves the saved request body byte-for-byte by default, including all
tool definitions. It records returned tool calls **without executing them**.
Optional `--temperature 0` explicitly changes and labels the sampler.
Optional `--assistant-history /ABS/assistant.json` inserts a supplied original
assistant message before the latest user message. It must be a text-only
Responses message (type/role/content, optional id/phase), at most 2048 UTF-8
bytes. Supply actual retained assistant output, never a fabricated answer or
user/policy instruction promoted to assistant authority. Original input items,
including standing policy and tool results, stay unchanged and ordered.

Files are created exclusively (no overwrite), with mode 0600. Each request,
raw response, and compact summary is retained. No headers are persisted.
Artifacts contain prompt bodies and must remain local. Bounds: 1 MiB request,
8 MiB response, 120 seconds per request, 1–10 serial replays. Failed/missing/
duplicate terminal responses fail validation; partial transport failures are
not successful outcomes. Run inference serially with other Computa tests.

For a cache experiment, compare the same captured post-tool request cold and
warm. The helper does not clear caches. A model reload is a separate explicit
operator action; `store:false` is not a KV-cache-disable switch. Repeated
samples are needed because the original sampler can be stochastic. Report
changed-sampler and assistant-history variants separately from exact replay.
