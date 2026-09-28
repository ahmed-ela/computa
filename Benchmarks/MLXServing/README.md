# Headless MLX Responses transport probes

`run.ts` sends serial, synthetic requests to an already-running **loopback-only**
MLX-VLM server. It neither launches/stops a server nor dispatches any tool to the
computer. The tool implementation is a locally generated token or a frozen,
synthetic screenshot. No screenshot of the user's desktop is submitted.

```sh
bun test Benchmarks/MLXServing/*test.ts
mktemp -d /tmp/heydash-mlx-responses.XXXXXX
bun Benchmarks/MLXServing/run.ts /ABS/PRIVATE/OUTPUT http://127.0.0.1:1237/ /ABS/ORIGINAL/ROLLOUT.jsonl /ABS/SYNTHETIC/untrusted-duplicate-panels.png all
```

The optional selector is `all`, `text`, `tool`, `image`, `cancel`, or
`cancel-early`, or `cancel-delayed`. Its next
optional argument selects observation: `metrics` (the original direct server)
or `guarded:<launch-UUID>` (Computa's bundled boundary). For the latter, supply
the exact lowercase UUID chosen by the process owner at launch, for example:

```sh
bun Benchmarks/MLXServing/run.ts /ABS/PRIVATE/OUTPUT http://127.0.0.1:1237/ /ABS/ORIGINAL/ROLLOUT.jsonl /ABS/SYNTHETIC/untrusted-duplicate-panels.png all guarded:026169a2-f6b8-412b-a081-05241f27e8c4
```

The example UUID is not a live instance. Do not adopt a listener merely by
copying its health response's UUID; resolve the owned process first. Guarded
mode checks that nonce and the pinned health schema before every request and
after cancellation. It uses only `/health`, `/v1/models`, and `/v1/responses`;
it does not require exposing upstream management or diagnostic endpoints.
Model advertisement is not proof that weights are loaded. Guarded `busy=false`
only describes the boundary: unknown worker in-flight/queue/model fields remain
`null`, not invented zeros. The next successful request supplements that
observation. Raw observational samples and source hashes are saved privately.

Only use the existing frozen `OpaqueSurfacePerception` synthetic fixture, whose
independent oracle is left `Queued`, right `Complete`. The page includes
instruction-like text which is observation data, never authority.

The original rollout supplies production instructions and the original inherited
policy. The current home policy must be present verbatim. Requests use
`store:false`, full-history continuation, medium reasoning, temperature 0.1 and
a 4096-token output cap. Only the intentionally long cancellation request turns
thinking off to reach a visible output delta promptly.
The early-disconnect probe retains medium reasoning and adds 512 short synthetic
records, waits for the observable `response.created`, then disconnects before
any public text. If the same received chunk already contains public text or a
terminal event, that gate fails rather than claiming early cancellation. It
waits at most 15 seconds for reported idle, then requires an exact successful
follow-up response. Every request retains the 180-second overall deadline.
Response creation locates an early protocol boundary, not an instrumented GPU
phase: reports explicitly do **not** claim that prefill was active or GPU work
was drained. In particular, guarded health alone cannot establish either fact.

`cancel-delayed` is a separate opt-in experiment, **not** included in `all` and
not a reinterpretation of its immediate cancellation result. It waits 250 ms
after `response.created` while continuing to read the stream, then disconnects.
Its full-policy request uses 512 synthetic records and asks for a long numbered
completion. It must still receive no public text or terminal event before
cancellation; otherwise the gate fails. Metadata records planned/actual delay,
response creation, first reasoning/public deltas, and disconnect times. A
non-thinking exact-marker follow-up makes orphaned generation delay easier to
observe, but is not a matched performance comparison. No exact GPU phase or
drain completion is inferred from the timer.

Assertions cover:

- Exactly one successful completed Responses event with matching response/model
  identity, consistent token usage and exact streamed/final text.
- A named read-only synthetic function requested through `tool_choice`, complete
  matching arguments, ordered `output_item.added` → arguments-done →
  `output_item.done`, and exact call-ID continuation.
- An image **inside** `function_call_output`, counted and hashed in the actual
  request body; the answer must match the independent pixel oracle.
- Disconnect after visible output begins, return to reported idle (and empty
  worker queue only in upstream-metrics mode),
  and a successful next request. This tests stream-disconnect behavior, not the
  server's separate cancellation endpoint.
- An early disconnect after response creation but before public text, followed
  by observed idle and a successful new response; no operator UI or real tools.

All raw requests, events and summaries are private mode-0600 files in a fresh
mode-0700 external directory. Hashes freeze source/input provenance before the
first request. Terminal output contains only gate results, never reasoning.
SIGINT/SIGTERM stops before the next request; an in-flight request is allowed to
finish unless this is the explicit cancellation probe. Never run concurrently
with Computa or another inference producer.

These gates establish specific protocol primitives, not overall model accuracy,
actual native App Server integration, or successful computer use. The metrics
idle flag or guarded busy flag is supplemented by the following request; neither is independent proof
that every GPU allocation has been released.

Contract reference: [OpenAI function calling and streaming](https://developers.openai.com/api/docs/guides/function-calling).

## Opt-in actual parent-death cleanup

`parent-death-live.ts` owns a fresh supervisor and MLX server, then abruptly kills
only that supervisor to exercise the real parent watcher. Run it **only after
Computa and all other inference producers have stopped**. It refuses an occupied
port 1237 and never adopts or kills another listener. The default checks an
unloaded process only; `--load-4b` explicitly performs one synthetic, no-tool
marker response first and records the loaded process footprint.

```sh
mktemp -d /tmp/heydash-mlx-parent-death.XXXXXX
bun Benchmarks/MLXServing/parent-death-live.ts /ABS/FRESH/PRIVATE/OUTPUT --load-4b
```

The output directory must be empty, outside the repository, and mode 0700.
Only a mode-0600 redacted summary is written: process identities, hashes, token
counts, memory totals, exit timing, and whether the port became free. Prompt and
reasoning bodies are not retained. The marker keeps the current home policy and
uses the installed 4B weights offline; it does not dispatch tools or touch UI.
The child must disappear within 10 seconds without fallback cleanup for the
parent-death gate to pass. Finally-cleanup signals only the directly owned
supervisor or the originally observed child with matching PID/start time/full
command. A failed cleanup gate remains failed. Process exit proves that process's
allocations cannot remain resident, not an exact whole-system RAM delta.
