# App-owned Agent Runtime

Computa builds the standalone open-source `codex-app-server` component from
`codex-source.lock.json`, with the reviewable patch under `patches/`. The pinned
upstream revision matches the previously used installed runtime release. The
installed Codex/ChatGPT application is neither changed nor used as a fallback.

```sh
bun Scripts/build-agent-runtime.ts            # Small development validation build
bun Scripts/build-agent-runtime.ts --release  # Optimized distribution build
bun Scripts/build-agent-runtime.ts --isolated-source  # Preserve an unrelated dirty source checkout
bun Scripts/build-agent-runtime.ts --prepare-only --isolated-source  # Obtain and verify all Rust source, without compiling
```

The complete runtime source is reproducible from the public upstream Git commit
`4607249e430dac1c961df4dc615beae88e33cec8` plus the tracked
[`compaction-retention.patch`](patches/compaction-retention.patch). New Rust files
and their tests are included in that patch, not merely referenced in a private
cache. The exact patch checksum is in [`codex-source.lock.json`](codex-source.lock.json).
No installed Codex app, unpublished source, or prebuilt executable is required.
Upstream retains its Apache-2.0 license and NOTICE, which are copied into the
app alongside the generated runtime.

To audit from a new directory without disturbing any existing source checkout:

```sh
bun Scripts/build-agent-runtime.ts --prepare-only --source-dir "$PWD/.build/runtime/source-audit"
git -C .build/runtime/source-audit diff --stat HEAD
```

Source-only preparation needs Git and Bun and works independently of the macOS
compiler/signing step. It fetches the pinned public tag, verifies the resolved
commit, checks and applies the patch, and verifies the entire resulting diff
(including newly added files). It never imports experimental cached source.
An unexpected origin, revision, tracked change, or untracked file fails closed
without resetting the checkout. `--source-dir` cannot be combined with
`--isolated-source`.

Build prerequisites are Rust 1.95.0 installed through rustup, Git, Bun, Xcode command-line tools, and enough
free storage for Cargo's dependency/build cache. Source and build products stay
under the ignored `.build/runtime` directory. The script refuses an unexpected
source revision, origin, patch checksum, or unreviewed cached modification. It
always invokes `cargo build --locked`, so a stale binary cannot be packaged just
because its source directory looks correct. Do not edit the installed app binary.
The command selects `rustup run 1.95.0 cargo` explicitly; another Cargo version
earlier on PATH cannot silently replace the pinned toolchain. It does not install
or download Rust toolchains on the user's behalf.

`--isolated-source` uses a separate pinned checkout at
`.build/runtime/codex-source-reviewed`, applies only the checksum-locked patch,
and reuses the existing Cargo target cache. The same source, untracked-file, and
artifact integrity checks still apply; cached experimental edits are never
silently folded into the shipped runtime. Do not run builds against that shared
target cache concurrently.

Generated binary, post-signing integrity manifest, and upstream LICENSE/NOTICE
are copied to `Sources/Computa/Resources/AgentRuntime` before the normal Xcode
build seals the app bundle. Generated binary artifacts are not tracked in Git.
The native resolver accepts only the pinned arm64 macOS standalone executable,
checks size and SHA-256, and rejects symlinks, invalid manifests, and missing
artifacts. Manifest hashes detect corruption; the app's code signature supplies
the packaging trust boundary, not the manifest alone.

The patch covers local mid-turn compaction and bounded context-overflow recovery. It retains bounded genuine
completed tool-call/result records inside the native atomic history replacement,
before inference continues. Original tool identities and authority stay intact;
large text results are explicitly truncated. No action is replayed, fabricated,
or silently approved by this change. Overflow and unsupported retained results
fail closed. Native approvals, StudyLock, and computer-use freshness checks are
not weakened. Manual/idle compaction retains Computa's separately tested
assistant-history restoration flow.

For loopback, non-OpenAI providers using local summarizing compaction, a typed
context-window rejection permits one compaction and inference-continuation retry
per successful sampling step. The completed tool-call/result receipts are retained;
no input or action is replayed. Provider-projected history must become strictly
smaller before retrying. This byte-size comparison is only a progress guard, not
an exact token estimate: the owned MLX server checks the actual prepared input
tokens plus the requested output allowance before generation. A second overflow,
nonreducing summary, unsupported provider, or unrelated error remains terminal.
Token-budget resets and Guardian-specific recovery retain their existing behavior.

For review, this experiment has three separable stages: (1) atomic current-turn
text receipts and idempotent byte bounds, (2) mixed-image receipts with explicit
image omission and fresh-observation requirements, and (3) bounded real prior
assistant replies beside uniquely matched user boundaries. The first is the
smallest useful no-repeat repair; the latter two add distinct safety/retention
coverage. Their helpers and regression tests are separate from the orchestration
site. The combined experimental patch exceeds the upstream preferred change
size; split these stages before proposing it upstream rather than removing tests
to make the diff appear smaller. The mechanical workspace lock correction is
independent of all three.

Only the app-server binary is built by this command. GStreamer and the optional
voice/TUI/full-workspace test dependencies are not required for that binary.
Experimental changes in a developer's other upstream checkout are deliberately
not part of this release source or its manifest.

Retained historical replies remain assistant-role excerpts, not new assertions
of success. Up to four replies use at most 1 KiB of text each and 4 KiB serialized
in total. Ambiguous, truncated, or misordered user boundaries are skipped. Tool
receipts retain at most 32 genuine calls and 12 KiB of serialized provider-input
text/headers, including array punctuation. The budget uses the same external-
provider projection as the request builder: external providers do not receive
internal chat metadata, encrypted arguments, or optional function item IDs. They
still receive exact call IDs for pairing. This projection is measured on a clone;
canonical call identities, turn IDs, timestamps, failures, and ordering remain
unchanged in history. A separate 24 KiB bound covers serialized canonical items
and their metadata arrays. Both byte budgets use a placeholder for the separately
bounded latest image described below, not its pixel payload. When needed,
older excerpts shrink before the newest completed observation. The newest output
may retain up to 4 KiB of text and 6 KiB serialized (excluding its separately
bounded image); historical outputs remain capped at 2 KiB text/3 KiB serialized.
If necessary the newest excerpt also shrinks. All former shared-cap candidates
remain available, within the unchanged aggregate budgets. Completion order, not
tool name or call order, determines priority. No call identities or arguments
are shortened. The larger individual item has been manually reviewed; byte
counts are not token counts, and final context-fit validation still applies.
Successful native `browser_read`, `browser_click` and `browser_fill` observations
can opt into complete retention with the exact leading
`complete_browser_observation_v1` marker. Reads have two text items; inputs have
three: marker, the existing compact dispatch cue, and the complete post-input JSON.
Rejected stale inputs and changed-filter reads may also carry three items: the
marker, a closed rejection cue, and a separately captured complete read. Their
outer result remains failed, undispatched and unverified. Unavailable recoveries
remain ordinary failures. The cue and available observation must match the exact native shape and
action kind. The producer pages within the existing 4 KiB text limit, including
the marker, cue, references and continuation, and the native 4.5 KiB encoded-item
limit. For the newest complete browser page, even when a later inventory or
terminal result exists, compaction retains all items
unchanged or stops if the existing aggregate bounds cannot fit them. It never
cuts out rows while retaining a cursor that skips them. Older marked pages use
`browser_observation_excerpt_v1`: the exact dispatch cue remains separate from
whole observed rows, with optional historical URL/title fragments. Rows too large
for the current budget are omitted entirely; labels and action references are
never separated. Old cursors, snapshot IDs and completeness claims are removed.
Compact-row defaults remain explicit when rows survive. Repeated compaction
recognizes this closed historical shape and removes only whole rows within the
same bounds; it cannot turn the excerpt back into a complete observation or renew
a reference. Malformed marked shapes fail closed. Custom/namespaced tools and
unmarked results retain the generic behavior. The marker grants no authority,
does not verify an action, and never replaces native target freshness checks.

If ordinary receipts cannot fit, older successful native `browser_read` and
`browser_tabs` pairs may become versioned historical read records. Only typed
provenance issued by the native controller after successful execution qualifies;
page text, tool names and imported Responses items cannot create it. Changed
post-tool-hook output loses that provenance. Mutations, failures, foreign tools,
unsupported metadata combinations and the protected newest outputs keep their
ordinary pairs. Records combine serial reads only when adjacent or separated
solely by current-turn reasoning items already omitted by receipt projection;
messages and all other item types remain boundaries. Existing stored run
boundaries survive repeated compaction. Records retain the original ordering,
raw arguments, IDs and timestamps. Their model-visible
text explicitly omits old page content and claims neither content nor absence,
current references, or action authority. This is a lossy history projection;
the original rollout still contains the actual outputs.

Both the readable text and typed local records count toward the existing byte
bounds. Repeated compaction validates and recounts the original calls, including
records restored from disk; it never refunds the 32-call limit or emits invented
tool replies. These assistant-role records are excluded from prior-answer and
compaction-summary selection. If the bounded projection still cannot fit, the
existing retention error remains terminal.
Empty IDs, duplicate IDs,
count overflow, and byte overflow have distinct errors.

Only the most recent completed tool output may retain one original inline
PNG/JPEG image, capped separately at 2 MiB serialized. The final candidate history
must still fit the effective model context with that image included. This avoids
discarding a just-captured screenshot before action planning can consume it. Older
images are explicitly omitted; a later text-only output prevents resurrecting an
older image. Unsupported, malformed, multiple, or oversized latest images fail
closed rather than silently continuing without perception. Audio/encrypted
results still fail closed. Retaining an image does not renew native capture
freshness, permission, or approval; those checks remain authoritative. Repeated
compaction must not repeatedly truncate an already-bounded receipt.
Other tool families fail closed instead of being silently forgotten; this is a
function-receipt contract, not universal retention of every upstream tool type.
Generated summarizer messages receive the existing `compaction.summary` content
classification before persistence, including failed compaction attempts, so they
cannot later be restored as ordinary task replies. Legacy unmarked messages
cannot retrospectively prove successful completion merely from their text/role.

External-provider projection also preserves the authority distinction. A
user-role message whose complete, cardinality-matched content provenance is
`compaction.summary` is sent as assistant history before internal metadata is
removed. Genuine user messages, mixed content and missing/malformed provenance
keep their original roles and bytes. Classification never relies on a summary
prefix or a text hash. Canonical history, current user instructions, approvals,
tool receipts and retention limits remain unchanged. This prevents generated
notes from acquiring user-message authority merely through serialization.

The release tag's Cargo lock file contains `0.0.0` for local workspace packages
while its manifest declares the release version. The mechanical lock correction
changes those local version fields only; third-party dependency versions,
sources, and hashes remain unchanged.

Validation results belong in the dated context benchmark report. A proposed
runtime patch or successful build alone is not evidence that Qwen passes the
strict within-turn no-repeat gate.
