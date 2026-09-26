# HeyDash checkpoint — September 26, 2026

This checkpoint saves the current implementation and research, not a claim of
complete production qualification.

## Included work

- App-owned headless MLX serving for the local Qwen 4B/9B profiles, with bounded
  request/response handling, cancellation, model switching and process cleanup.
- Separately authorized background access to the user's existing Chrome session,
  tab ownership checks, and remembered reconnect authorization.
- Native window binding, accessibility/capture improvements and regression tests.
- App-owned agent configuration and instructions: private engine HOME/workspace,
  allowlisted environment, no personal Codex configuration or global skills,
  and file-backed credentials in the private app home. Existing chats survive.
- The complete unchanged StudyLock protection policy remains bundled. General
  assistance is distinguished from enforcement restrictions; prior assistant
  refusals are not treated as proof of current tool capability or permission.
- Capability-routing, opaque-surface, receipt-overflow and instruction-isolation
  experiments. Rejected/unpromoted candidates remain labeled research artifacts.

## Validation

- Latest full optimized native run: 1,082 passed, 46 skipped, one interrupted test
  (1,129 total). The runner exited with code 0 before that compaction test
  finished; the cause is unproven. This is not a clean full-suite pass.
- All managed-compaction integration and isolation-transport tests were then
  rerun: **20/20 passed**, including the interrupted case.
- Publish-time offline checks: **61 Bun tests passed** (725 assertions) across
  CapabilityRouting, InstructionIsolation, MLXServing and OpaqueSurfacePerception;
  **40 Python MLXServer tests passed**. These did not start model inference.
- Synthetic Qwen 4B instruction recovery passed four bounded cases: contaminated
  email and calendar histories, a general greeting, and a refusal to disable
  protections. Successful synthetic lookups each used three calls and took
  approximately 10.5 seconds. This is not a live inbox test or reliability rate.
- Signed Release build succeeded and passed deep/strict signature verification.
  The installed `/Applications/HeyDash.app` opened with local runtime and Chrome
  connected; existing chats remained. The user's subsequent Outlook request was
  in progress when observed, so its final outcome is not claimed here.

## Remaining qualifications

Durable existing-chat dynamic-tool migration, uninterrupted full-suite checks,
signed-in Chrome with simultaneous human use, and complete Mac mini Screen
Sharing tab collection remain unfinished. Runtime configuration isolation is
not an OS sandbox. Raw local captures, private conversations, model weights,
build artifacts and app backups are not part of this source checkpoint.

See the individual benchmark READMEs and
`MLXServing/MIGRATION-VALIDATION-2026-09-25.md` for measured limits and opt-in live
test requirements. The previously installed app remains in a local rollback
backup; publishing source does not change the currently running app.
