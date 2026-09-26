# Native receipt-overflow reproduction

This is an opt-in, offline regression for the recorded 28-pair failure. It does not
start App Server, call a model, access UI, dispatch tools, change permissions, or
build/replace the shipped runtime. No private receipt bodies enter stdout or this
directory.

Run `bun Benchmarks/ReceiptOverflow/native-floor-audit.ts` with three arguments:
an absolute private rollout path, its target turn UUID, and an existing empty
mode-0700 temporary directory. The rollout must contain the recorded shape: three
same-turn compactions, then 21 retained pairs plus seven new pairs before the
serialized-budget failure. It intentionally rejects different cases.

The runner verifies the installed resource manifest, pin, reviewed patch and
cached source diff agree. It freezes baseline allocator SHA-256
`ebef138ff0b4808fe21f081ad645f48311d2940b19f4994155796b87c6b46f6f`.
The complete allocator source is compiled unchanged inside a benchmark module;
the existing external-provider projection is extracted unchanged from `client.rs`.
An additional measurement function calls the allocator's actual private truncation
helper at every native cap combination and serializes with its cached Rust types.
The real allocator is called separately and must reject the recorded final shape.
No JavaScript port is used for receipt extraction, truncation, or byte accounting.

The cached Rust rollout parser reconstructs the final checkpoint and subsequent
records, preserving interleaving and envelope metadata. Seven newly recorded calls
have absent metadata; they must not be changed into default metadata. The normal
post-checkpoint output truncator is applied and verified to make no body changes.
Earlier checkpoint images have already been omitted; the final 28 pairs have zero
images. Output success is retained as decoded from the rollout: the probe does not
invent success fields absent from persisted evidence.

Six native controls check: the previous checkpoint fits; short-result synthetic
controls retain all 28 original call/result envelopes except deliberately replaced
bodies; recompaction is idempotent; duplicate call IDs reject; orphan outputs reject;
and a dispatched call without a completed result rejects. These are structural
offline controls, not evidence of successful remote input or end-to-end computer use.

The first verified baseline measured **12,469 provider bytes / 12,288 allowed**,
**21,083 canonical bytes / 24,576 allowed**, with **0 fitting combinations out of
42**. All individual receipt caps passed. The cached-dependency compile took 2.153
seconds and produced a 46.2 MB executable. The canonical count is 147 bytes below
the earlier nonauthoritative port because that port filled seven absent metadata
objects. Provider overflow remains exactly 181 bytes.

`audit.json` and any compiler diagnostics are mode 0600 in the supplied private
directory. The audit records hashes of source, instrumentation, complete compiler
input, cached dependencies, rollout and output binary. Cache filenames are explicit;
missing/incompatible cache artifacts fail instead of silently downloading or
rebuilding dependencies. Future allocator candidates require a separately reviewed
probe configuration and their own output directory; this frozen baseline must not
be relabeled as a candidate pass.
