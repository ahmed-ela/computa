# AX association extraction experiment

This narrow experiment asks the loaded local Qwen 4B to read synthetic order
cards rendered by the actual `AutomationCore` formatter. It does not open a
browser, dispatch tools, use App Server, or establish end-to-end task reliability.
No real order data is used.

Eight cases vary flat/nested cards, swapped status text, and full/limited output.
Each is paired with an ablation that removes only parent/ancestry and observed
sibling-heading annotations from the
same rendered output. This isolates the grouping information; it is not a replay
of an older binary. Cases with an actually omitted target require `UNOBSERVED`.
The status labels are explicit (`Arrives Tuesday` / `Delivered Friday`).
The old limited fixtures omitted Order A's value because label-backed facts
ranked higher. After text-field ranking parity, a limited output can expose the
target. Fresh fixtures derive `targetObserved` and the expected answer from the
actual emitted target-status line, not from the requested element limit. The
runner rejects older fixtures lacking that marker. This set therefore no longer
guarantees missing-information coverage; the separate App Server recovery gates
retain explicit missing-information preconditions. Historical results are not
relabeled as results for these regenerated fixtures.
The current prompt describes the formatter's header `parents=[child:parent,...]`
map and per-line `parent`: omitted group lines remain usable through the map,
and sharing a page does not establish membership in the same card. Generate
fresh fixtures for this format; older ancestry-path runs used different prompts
and are not interchangeable experimental results.
New compact observations may also carry `sibling_heading` from one unique
observed direct heading sibling. It is structural context, not inferred semantic
ownership. The ablation removes that cue as well; comparisons to older runs
without the cue are not a controlled representation-only speed measurement.

The runner validates all 16 fixtures before any model-state check or request,
then makes serial Responses requests to the sole already-loaded 4B instance on
loopback. It requires an idle model with parallelism one before each
request, applies a 45-second request timeout and a 2,048-token generation cap,
and stops on transport/provider failure or an empty final answer. It never
changes model settings, unloads a model, or retries a failed request. Reasoning
tokens count toward the cap; inspect recorded usage rather than interpreting an
empty final answer as an incorrect extraction.

Build `AutomationCore` through the regular Computa Xcode build with
`-derivedDataPath .build/DerivedData` first, then compile:

```sh
swiftc -I .build/DerivedData/Build/Products/Debug \
  -L .build/DerivedData/Build/Products/Debug -lAutomationCore \
  Benchmarks/AXAssociation/make-fixtures.swift \
  -o /tmp/heydash-ax-association-fixtures
```

Create a fresh output directory, write the fixture generator's stdout to its
`fixtures.json`, then run:

```sh
bun Benchmarks/AXAssociation/run.ts /absolute/output/fixtures.json /absolute/output
```

Each attempted result retains its synthetic request, local response when
available, usage, exact-match verdict, and elapsed request time. Outcomes are
`answered_correct`, `answered_wrong`, `no_final_answer`, `server_error`, or
`transport_error`. Only answered outcomes have a boolean `correct`; other
outcomes use null rather than counting a missing answer as a wrong extraction.
An incomplete response is not an answered extraction, even if it has partial text.

`summary.json` is atomically replaced before the first request, after every
attempt, and on completion or a caught failure. It includes attempted and unrun
counts, unrun fixture IDs, outcome counts, and the stop reason. Validation or
idle-model preflight failure does not count as a request attempt. An abrupt
process termination can leave the last completed partial summary; an unwritable
output directory cannot preserve results. Outputs are compared without stripping
explanations or repairing model text. A provider `completed` status alone is not
a passing answer.

This is a tiny, single-pass, fixed-order diagnostic set. Ancestry variants run
before their ablations; cache/warmup and order are latency confounds. Neither
100% on these fixtures nor a lower median establishes general accuracy or a
production speedup. The actual Chrome/Amazon acceptance gate remains separate.
All queries also target the first card, Order A, whose status is always
value-backed while Order B's is title-backed. Status-word swaps do not remove
this shortcut; counterbalance the queried card and field encoding before making
broader association-accuracy claims.

## Captured-context layout probe

`audit-wire.ts` reads the opt-in loopback recording and isolated test protocol
files. It makes no requests and emits a redacted audit rather than prompt,
header, or reasoning bodies. It parses all Content-Length HTTP messages and
rejects unsupported framing. Exact instruction and receipt preservation is
reported separately from tool-schema preservation.

`replay-layout.ts` tests a representation hypothesis on the two synthetic
missing-status fixtures. It reuses the actual model-facing request immediately
after the initial snapshot (connections 03 and 06 in the recorded diagnostic
pair), including the complete inherited policy, tools, and conversation prefix.
Only the last snapshot's layout differs within each pair. The block arm factors
repeated direct-parent suffixes into explicit groups using `parent-blocks.ts`;
it must preserve the header and every emitted record, without adding an omitted
fact. Both initial and one possible queried observation receive the same arm's
format. Unsupported or expanding transformations leave the original unchanged;
the probe rejects an unchanged treatment.

The four serial lanes alternate arm order across the two cases. Both arms use
the same explicit temperature 0.1, 2,048-token output cap, non-streaming request,
and 45-second timeout; these are diagnostic differences from production. Each
lane makes at most two requests and can receive exactly one synthetic response
to an accepted literal snapshot query. No emitted tool call is executed. An
unsupported call is recorded, not relabeled as a wrong factual answer. The
runner requires the sole 4B instance to be idle with parallelism one before
each request and does not change server/model settings.

Supply an existing private output directory, such as one created with
`mktemp -d`, plus absolute capture and fixture paths:

```sh
bun Benchmarks/AXAssociation/replay-layout.ts \
  /absolute/capture-directory \
  /absolute/order-a-fixture/ax-query-recovery.json \
  /absolute/cedar-fixture/ax-query-recovery.json \
  /absolute/private-output-directory
```

Generated raw requests/responses remain private local evidence, not repository
content. The summary excludes prompt and reasoning bodies. This is a tiny
single-pass replay: fixed captured prefixes, caching, sampling, field encoding,
and execution order limit interpretation. It is neither a production App Server
continuation nor an actual Chrome/Amazon acceptance test. Do not promote a
formatter change solely because this probe passes.
