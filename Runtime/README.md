# App-owned Agent Runtime

Mactopus builds the standalone open-source `codex-app-server` component from
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
are copied to `Sources/Mactopus/Resources/AgentRuntime` before the normal Xcode
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
not weakened. Manual/idle compaction retains Mactopus's separately tested
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
receipts retain at most 32 genuine pairs and 12 KiB of serialized provider-input
text/headers, including array punctuation. The budget uses the same external-
provider projection as the request builder: LM Studio does not receive internal
chat metadata or encrypted arguments. This projection is measured on a clone;
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

The release tag's Cargo lock file contains `0.0.0` for local workspace packages
while its manifest declares the release version. The mechanical lock correction
changes those local version fields only; third-party dependency versions,
sources, and hashes remain unchanged.

Validation results belong in the dated context benchmark report. A proposed
runtime patch or successful build alone is not evidence that Qwen passes the
strict within-turn no-repeat gate.
