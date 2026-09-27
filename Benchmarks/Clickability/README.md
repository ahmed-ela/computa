# Redacted clickability rollout audit

Offline, read-only inspection of one explicitly selected turn in one rollout:

```sh
bun Benchmarks/Clickability/summarize-rollout.ts ABSOLUTE_ROLLOUT_PATH TURN_UUID [UPPERCASE_FIXTURE_MARKER]
bun test Benchmarks/Clickability/summarize-rollout.test.ts
```

The summary contains tool order, relative request/receipt timing, bounded native
evidence categories, snapshot `press_source` counts, and final-message presence.
It supports original string and typed-content-array tool outputs and original
`response_item` assistant messages. It skips unrelated turns, reasoning,
compaction replacement histories, and user-message bodies.

Arguments, labels, URLs, raw errors, reasoning and answer bodies are never
printed. Fixture markers are reported only as match Booleans. An explicit
runtime dispatch receipt differs from `VERIFIED_PROPERTY`; neither proves the
whole task. Missing verification is not converted into success by model prose.
Receipt latency uses rollout timestamps, not profiler measurements. Foreground,
pointer and clipboard preservation require separately measured evidence.

Recognized-error counts cover fixed native error prefixes only, not every
possible failure. A currently running or interrupted turn may have no native
completion record. The file SHA-256 identifies the exact audited bytes, which
can change while the turn is still running.
