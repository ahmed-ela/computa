# Rust benchmark entry points

The active benchmark implementations live in `crates/xtask/src/benchmarks`.
`cargo run -p xtask -- <command> --help` describes each command. Legacy scripts
and their recorded results remain qualification baselines; they are not invoked
by the Rust tools. A passing offline test does not establish a live model,
browser, desktop mutation, or model-driven task result.

| Baseline | Rust implementation | Evidence boundary |
| --- | --- | --- |
| AXAssociation formatter, fixture maker, replay, wire audit | `association`, `fixtures`, `parent_blocks`, `replay`, `wire`; shared production `computa_harness::formatter` | Exact legacy fixture protocol and opaque current production receipts remain distinct. |
| ContextReplay capture/replay/paired history | `context`, `paired_context` | Captured requests stay byte-exact unless an explicit documented edit is requested; no hidden protocol conversion. |
| Clickability and LookupComparison audit/fixtures | `rollouts`, `lookup_server` | Only correlated recorded tool results prove an observation; finite local fixture HTML never serves its oracles. |
| OpaqueSurfacePerception extraction, fixtures, OCR, formatting and runs | `opaque`, `images`; native file-only `computa_macos::benchmark_image` | Static PNG classification, not desktop control. Actual capture is taken from an exact recorded receipt. |
| MLXServing protocol, boundary and parent-death probes | `serving`, `streams`, `lifecycle` | Explicit owned instance identity; no upstream process adoption. Parent-death cleanup retains exact kernel identity and never signals a bare observed PID. |
| ReceiptOverflow native-floor audit | `receipt_floor` | Offline, pinned original Rust allocator instrumentation and explicit cached dependencies; no model/network/UI actions. |
| EvidenceAssociation | `evidence`, `evidence_replay`, `evidence_runner` | Exact frozen scoring and recorded-history provenance. |
| InstructionIsolation | `instruction_isolation` | Complete policy/schema retained; finite actual Responses protocol checks. |
| VisualGrounding cascade | `grounding_cascade` | Separate native grounding service and exact corpus geometry/refusal oracles. |
| Computer V2 matrix runner/summary | `matrix_runner`, `matrix` | Canonical serial trials; only real model-driven Production Runtime gate evidence can pass. Missing drivers pause their trials. |

## Responses protocol variants

`opaque-run --observation rust:<owned-instance-uuid>` sends the exact same
instructions, inherited policy, observations, tools, temperature, reasoning
effort and output-token budget as its classification request, with the native
endpoint's required `stream: true` and `store: false`. It retains the raw SSE in
a private artifact, bounds it to 2 MiB and 10,000 events, and requires one terminal
response with the same created-response identity and matching public text
deltas. A max-token incomplete sample remains an unsuccessful/censored sample
in the denominator. Failed, duplicate, mismatched and truncated streams fail.

The `metrics` and `guarded:<uuid>` OpaqueSurface variants retain the baseline
`stream: false` JSON request. Artifacts explicitly record the request protocol;
these variants are not silently interchangeable. ContextReplay does not modify
an original captured request to make it accepted by a different endpoint.
Serving and native parent-death marker requests already use streamed Responses
with storage disabled.

## Matrix gate requirements

The matrix defaults remain 4B and 9B, the five desktop gates, and three serial
trials per cell. Interruption and 27B require explicit selection. The runner
preserves canonical ordering, bounded 950-second trials and 10-second exact-owned
cleanup, private per-trial evidence, checkpoints, and interruption handling.
Unconfirmed cleanup pauses subsequent trials. It never scans unrelated temporary
directories to invent artifact ownership.

Each gate has an explicit legacy-to-Rust definition: read-only status tool;
bound Chrome read; Calculator semantic digit press; combined image/AX observation;
capture-scoped grounded digit click; or correlated active-turn interruption and
same-task recovery. A direct AX field-setting fixture, a text-only model reply,
or a protocol cancellation probe is narrower evidence and cannot substitute for
one of these gates. The default CLI registry reports missing model-driven
fixtures, so its rows are `paused`, with zero executed trials and zero passes.
`matrix-run --native-config` explicitly registers the first-party native subprocess
qualifier using closed, bounded JSON and exact absolute executable/resource/model
paths. `--dry-run` cannot enable that qualifier. Source availability is
recorded per model, and a pass requires exact trial/model/task evidence and
confirmed owned cleanup.

The native Rust scope variants use a disposable exact-PID calculator-equivalent
AppKit fixture for semantic/combined/visual gates and a private owned Chrome
process/profile with a nonce HTML file for the Chrome gate. Their independent
digit/heading, observed-reference/capture, tool-order and approval oracles remain
explicit. They do not claim the old borrowed example.com/real Calculator fixture
was rerun. Preparing the Chrome file and running its offline oracle tests do not
launch Chrome or activate an extension.

The Rust boundary overflow probe has its own exact event-order oracle: one
`response.created`, one `response.in_progress`, then a matching
`response.failed` with a checked context budget. The legacy boundary oracle
continues to require a single failure event. Saved summaries identify which
oracle was used; passing the Rust variant does not imply the legacy raw event
sequence was reproduced.

## Explicit archival exclusions

CapabilityRouting's rejected candidate modes and historical pointer/mention
experiments remain archived research evidence. They are not supported product
modes and are not included in production benchmark discovery. The baseline
Swift/TypeScript executables are retained for comparison, not relabeled as Rust
production code. No live qualification is claimed by this inventory.
