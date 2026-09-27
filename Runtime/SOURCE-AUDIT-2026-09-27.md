# Runtime source reproducibility audit

Verified on 2026-09-27 UTC. This is a source-completeness check, not a claim that
a clean-machine release compilation or every runtime integration test passed.

## Public source and exact local changes

- A fresh network clone from `https://github.com/openai/codex.git`, outside the
  existing development caches, resolved tag `rust-v0.155.0-alpha.9.2` to commit
  `4607249e430dac1c961df4dc615beae88e33cec8`.
- `build-agent-runtime.ts --prepare-only --source-dir <fresh-directory>` applied
  and verified the tracked patch with SHA-256
  `0116caa8f6f1c7960c851c00621551ce03351bd6cdba86cf8753a052390d43d2`.
- The resulting diff contained exactly 13 changed/added paths, matching the
  reviewed source cache and the current bundled runtime manifest. No untracked
  source files remained. Newly added compaction helpers and their tests were
  present in the reconstructed source.
- Experimental dynamic-tool/schema/workspace-test edits in the separate
  development cache were not imported. They are not part of the shipped
  `mactopus-5` runtime.
- The source tree includes upstream `LICENSE`, `NOTICE`, workspace manifests,
  Rust sources, tests, generated schemas and `Cargo.lock`; no installed desktop
  Codex app was used.

## Build-graph checks

On the fresh prepared source, these commands succeeded:

```sh
cd codex-rs
cargo metadata --locked --offline --format-version 1 --no-deps
cargo tree --locked --offline -p codex-app-server \
  --target aarch64-apple-darwin --edges normal,build
```

The upstream toolchain file pins Rust `1.95.0`; the selected local `rustc` and
`cargo` both reported `1.95.0`. The graph check reused the local Cargo dependency
cache: it validates source/manifests and locked resolution, not a fresh download
of every third-party crate.

The app-server target does not require the optional GStreamer/voice/full-workspace
test dependencies. Its protobuf compiler is vendored. In the selected arm64
feature graph, bzip2/lzma build scripts fall back to bundled C sources when
optional pkg-config probing fails; their presence in the graph does not imply a
mandatory Homebrew installation. The standard AWS-LC build uses its C compiler
path, with CMake reserved for alternate/fallback configurations. Xcode's compiler
and SDK remain required.

## Deterministic packaging tests

`bun test Scripts/runtime-source.test.ts`: 7 passed, 0 failed.

Coverage includes added-file reconstruction, idempotence, preserving/rejecting
unknown tracked and untracked changes, wrong revisions/origins/checksums,
independence from user diff formatting, and argument validation.

No Rust release compilation, running-app restart, signing, model download or
personal-state access was performed by this audit. A release build remains a
separate acceptance step and needs substantial free space for Cargo artifacts.
