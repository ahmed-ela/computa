# Lookup comparison measurement

Offline analysis of **one selected turn** from the production app's existing
rollout. This does not launch a model, dispatch tools, alter app instructions,
or enable a second production log. Keep raw rollouts and private review notes
outside the repository; commit only reviewed, redacted aggregate results.

```sh
bun Benchmarks/LookupComparison/summarize-rollout.ts /absolute/private/rollout.jsonl TURN_UUID
bun test Benchmarks/LookupComparison/summarize-rollout.test.ts
```

The analyzer separates inventory metadata, browser semantic receipts and native
semantic receipts. It reports per-receipt source/output/field truncation and
structural counts when available. These are **receipt occurrences**, not unique
pages or documents read. It never merges different observations, filters or
subtrees into a completeness claim. Main-region counts do not prove readable
content: controls can be inside main regions. An empty filtered read is not a
verified negative search result.

Continuation requests report whether their opaque cursor appeared in a prior
host receipt in this turn, and whether the request produced another read-shaped
receipt. Historical linkage does not prove current cursor authority or tool
success. Compacted replacement history and duplicate outputs do not add reads.
Compaction checkpoint records and notifications are separate counts, not a sum.

Tool success/failure comes only from a matching `dynamic_tool_call_response`
event with the exact turn, call and tool. The pinned runtime's ordinary
`function_call_output.output` serialization is a string or typed content array;
its internal success flag is not serialized. Missing lifecycle events therefore
leave outcomes **unknown**, even if the output looks successful. Conflicting
events are explicit. A successful call is not whole-task completion. See the
pinned upstream [output serializer](https://github.com/openai/codex/blob/4607249e430dac1c961df4dc615beae88e33cec8/codex-rs/protocol/src/models.rs)
and [dynamic-tool event schema](https://github.com/openai/codex/blob/4607249e430dac1c961df4dc615beae88e33cec8/codex-rs/protocol/src/protocol.rs).

Elapsed and receipt latency are rollout timestamp differences. Aborted, failed,
completed and missing-terminal turns remain separate. Final-answer correctness,
semantic support, unsupported-claim count and refusal are deliberately
unmeasured: evaluate these against independently verified displayed source
content. Exhaustive inventory/document coverage and unique-document counts are
also unmeasured. No output text, URLs, labels, arguments, opaque IDs, model prose
or raw error messages are emitted; only fixed labels, counts and file/turn hashes.

Some providers omit the assistant message's `phase`. In that case, the analyzer
counts one final response only when a successful terminal event's
`last_agent_message` exactly matches the last unphased assistant response in the
selected turn. Whitespace is preserved. Earlier matching prose, commentary,
failed/aborted turns, and retained compaction history cannot create this match.
Explicit final phases are counted once without adding another terminal copy.
`finalMessageBasis` identifies the evidence used; terminal-message presence and
byte count are reported separately when no assistant response item matches.
These fields describe recorded output, not its correctness or semantic support.

Post-action browser/native reads from `computer_v2_ax` and `computer_v2_set_text`
are recognized after the exact host `VERIFIED_PROPERTY`, `ALREADY_SATISFIED`, or
`VERIFICATION_PENDING` wrapper, correlated with the action call ID. Verified
wrappers must also identify the following snapshot. Typed content-block
boundaries are preserved. Pending wrappers append arbitrary diagnostic text, so
a flattened pending string cannot safely identify the following observation;
that case is explicitly counted as `postActionObservationsUnmeasured`. The parser
never searches diagnostic or page bodies for later read headers. Other wrappers,
including standalone `computer_v2_verify` output, are outside this parser's
measured scope. Post-action receipt counts remain distinct in the report and
never establish an action's success or the final answer's correctness.

Each semantic header has a 32 KiB parser budget, allowing the host's long URL and
Unicode title fields; rejected larger headers are reported in
`semanticHeaderBudgetRejectedOutputs` and leave the observation unmeasured.

The fixed runtime may prepend an exact `READ_COVERAGE` block containing bounded
historical counts. The analyzer recognizes only its fixed vocabulary, order and
128-byte limit in the first typed text block or first flattened line. It then
parses the immediately following normal receipt; it never searches later body
text. Summary-only/error output does not count as a read, and historical counts
never establish current content exposure, correctness or exhaustive coverage.
Native `field_truncated` is recorded when present; older receipts leave it unknown.

New browser headers distinguish metadata clipping from body-field clipping and
report content-kind counts separately from ancestry counts. They are retained as
host classification claims, never independent semantic support. Controls within
main no longer count as document content; these two groupings are not summed.
An `immutable_capture` header does not establish complete exposure by itself.
