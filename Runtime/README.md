# App-owned Agent Runtime

HeyDash builds the standalone open-source `codex-app-server` component from
`codex-source.lock.json`, with the reviewable patch under `patches/`. The pinned
upstream revision matches the previously used installed runtime release. The
installed Codex/ChatGPT application is neither changed nor used as a fallback.

```sh
bun Scripts/build-agent-runtime.ts            # Small development validation build
bun Scripts/build-agent-runtime.ts --release  # Optimized distribution build
```

Build prerequisites are Rust 1.95, Git, Bun, Xcode command-line tools, and enough
free storage for Cargo's dependency/build cache. Source and build products stay
under the ignored `.build/runtime` directory. The script refuses an unexpected
source revision, origin, patch checksum, or unreviewed cached modification. It
always invokes `cargo build --locked`, so a stale binary cannot be packaged just
because its source directory looks correct. Do not edit the installed app binary.

Generated binary, post-signing integrity manifest, and upstream LICENSE/NOTICE
are copied to `Sources/HeyDash/Resources/AgentRuntime` before the normal Xcode
build seals the app bundle. Generated binary artifacts are not tracked in Git.
The native resolver accepts only the pinned arm64 macOS standalone executable,
checks size and SHA-256, and rejects symlinks, invalid manifests, and missing
artifacts. Manifest hashes detect corruption; the app's code signature supplies
the packaging trust boundary, not the manifest alone.

The patch is limited to local mid-turn compaction. It retains bounded genuine
completed tool-call/result records inside the native atomic history replacement,
before inference continues. Original tool identities and authority stay intact;
large text results are explicitly truncated. No action is replayed, fabricated,
or silently approved by this change. Overflow and unsupported retained results
fail closed. Native approvals, StudyLock, and computer-use freshness checks are
not weakened. Manual/idle compaction retains HeyDash's separately tested
assistant-history restoration flow.

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

Retained historical replies remain assistant-role excerpts, not new assertions
of success. Up to four replies use at most 1 KiB of text each and 4 KiB serialized
in total. Ambiguous, truncated, or misordered user boundaries are skipped. Tool
receipts retain at most 32 genuine pairs and 12 KiB serialized text/headers in
total. When needed, bounded shared excerpt sizes reduce output text rather than
forgetting completed call identities or arguments. Empty IDs, duplicate IDs,
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
