# Source packaging validation — September 26, 2026

This records the source-distribution checks, not a claim that every computer-use
task succeeds or that installation on a second Mac has been completed.

This historical validation record uses the current product name, Computa.
The original artifact names, paths and results below are retained and
do not establish validation of the renamed build or installer.

| Check | Result |
| --- | --- |
| Full Swift package suite | 1,544 passed, 49 opt-in live tests skipped, zero failures |
| Setup, Rust reconstruction and script tests | 36 passed, 10 opt-in cases/hooks skipped, zero failures |
| Chrome signing probes against production Swift code, separately opted in | 8 passed, 42 assertions |
| Chrome extension tests | 63 passed, zero failures |
| Source-only WebUI frozen dependency install, typecheck, tests and build | Passed; 83 tests, 330 assertions |
| Fresh isolated Python 3.12.13 environment | 54 hash-locked packages installed; dependency check and actual MLX/server imports passed |
| Python server/installer tests in that fresh environment | 63 passed, zero failures |
| Git-index-only source export, `./Scripts/setup.sh --check` | Passed; no ignored build/runtime artifacts copied |
| Xcode Release build with signing disabled and development team cleared | Passed |
| Default installer signing sequence on that build | Ad-hoc helper and outer-app signatures passed deep/strict verification |
| Bundled Rust executable after outer-app signing | Size and SHA-256 still matched its `mactopus-5` manifest |

These historical checks predate removal of the Chrome connection implementation,
extension, helper and associated test fixtures. They are not current setup requirements.

The Chrome probes accepted mutually authenticated Apple-signed app/helper roles
and rejected ad-hoc, unsigned, non-Apple, wrong-role and wrong-identifier peers.
They used temporary local fixtures, not a real browser connection. Those builds
required an Apple signing identity for that former optional feature.

The Rust tree was reconstructed independently from the public pinned upstream
commit plus the committed checksum-locked patch. Its 13 modified/added paths
exactly matched the packaged source, and its locked normal/build dependency
graph resolved. See [the detailed source audit](../Runtime/SOURCE-AUDIT-2026-09-27.md).
No unpublished experimental Rust edits are required.

## Not verified by this packaging pass

- A complete clean-machine installation or a fresh full Rust release compile.
  The native Release check used the existing manifest-verified runtime artifact.
- A new multi-gigabyte model download. Pinned upstream metadata and synthetic
  downloader, integrity, idempotence and failure cases passed; real 4B weights
  were not downloaded again. The existing local 4B chat template's Git blob
  digest matched the pinned stock template, with no local template patch needed.
- Live Chrome pairing under another developer's certificate or a new live
  Messages/Chrome/Qwen task. Those are separate operational gates.

The installed `/Applications/Mactopus.app`, inference environment, conversations,
model weights, browser pairing and macOS permissions were left unchanged. The
bundled StudyLock policy remained byte-for-byte unchanged through the source
directory rename.
