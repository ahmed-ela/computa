# Browser-pane release scope — 29 September 2026

## Included

The human-operated native tab pane and its separate profile, plus the existing
locally installed MLX/Chrome corrections needed to avoid a runtime rollback:

- MLX Responses producer/consumer channel agreement, strict complete tool-span
  parsing, payload-free protocol errors and request-local cleanup.
- Typed Chrome preflight guidance, exact-intent/document recovery correlation,
  busy-target handling and bounded structured inventory through compaction.
- The previously approved optional temporary Chrome tab capability: versioned
  native grant, inactive creation, exact task ownership, no takeover of existing
  tabs, cancellation/timeout handling and conservative cleanup.

The source-pinned Rust runtime and its patch are unchanged. Local validation
reuses the matching cached runtime artifact rather than rebuilding Rust:
`0af92fcce887ec371f622432370384f895ae5fc15a24d453f9bdacb08790e3c4`.
The repository's existing source installer remains the rebuild path.

## Excluded

Unfinished Goal-mode UI, embedded-browser agent read/action adapters, speculative
focus/message-channel prototypes and unrelated benchmark edits remain in the
original worktree. The release does not grant Qwen access to the embedded
profile. It does not modify macOS permissions, Chrome permissions, saved pairing,
StudyLock enforcement, model downloads, account state or existing website tabs.

## Validation checkpoint

- WebUI type check and production build passed; 83 WebUI tests passed.
- 106 Chrome extension tests passed.
- 93 MLX Python tests passed using the existing pinned environment with bytecode
  writes disabled. No model was loaded for these deterministic tests.
- 1,773 native tests passed, zero failed and 49 optional live tests skipped in
  `Test-Computa-2026.09.29_06-51-18--0700.xcresult`. The test result retains a
  main-thread responsiveness warning; this is not a performance qualification.
- 57 build/installer script tests passed, with 10 optional signing tests skipped;
  16 Python packaging tests passed.
- Inspected the real chat/browser split and approval-overlay renders from the
  clean PR branch. The unfinished Goal controls are absent.
- Signed release and installed-app checks are recorded in the PR after actual
  completion; prior dirty-checkout results are not substituted.

No successful live research-thread lookup or production memory/concurrency
qualification is implied by these checks. All broader goals remain separate.
