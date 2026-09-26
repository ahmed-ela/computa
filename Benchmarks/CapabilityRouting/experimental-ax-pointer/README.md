# Native AX pointer target experiment — UNBUILT / UNPROMOTED

This patch is preserved research work, not shipped HeyDash behavior. It has not
been compiled, tested, benchmarked, or exercised against a real desktop. No
pointer input was dispatched while authoring it. The runtime/tool integration
was intentionally not completed or promoted.

The latest existing-tool 9B trial reached the remote Screen Sharing connection;
its subsequent failure was a compaction receipt budget overflow. This did not
establish that adding a native AX pointer tool would fix the remaining blocker.

## Preserved design

- An immutable `AccessibilityPointerTarget` retains only native AX identities
  and value-type observation metadata, never a mutable session or mock backend.
- `AccessibilitySession.preparePointerTarget(at:in:)` copies exact retained
  target/window identity. No label-based or stable-identifier rebinding occurs.
- `@MainActor validatedPoint()` checks current semantics, positive finite frame
  within the unchanged window, exact focused window/PID, system-wide AX hit
  testing, and a cycle/depth-bounded live ancestry chain.
- Only the exact target or a narrowly verified noninteractive static-text/image
  descendant qualifies. Ancestors, siblings, replacement nodes, other windows,
  and independently actionable descendants fail closed.
- The helper never dispatches input. Production integration would still need
  exposed-index/task/approval scope, window z-order checks, same-point validation
  immediately before one synchronous click, observation invalidation, and fresh
  post-action verification.
- Eighteen mock-backed tests are included but have NOT been run.

## Caveats before any future promotion

- Native hit-testing may return a row ancestor rather than its label; that must
  remain a refusal, not a reason to relax identity rules.
- Strict descendant capability reads can reject legitimate presentation nodes
  when macOS reports unavailable/unsupported metadata. Unknown is not proof of
  noninteractivity.
- Truncated semantic metadata fails closed. There is no atomic lock over AX
  reads and WindowServer input; the proposed rechecks are best effort.
- The patch does not add a model tool or integrate runtime dispatch, and cannot
  be cited as a successful end-to-end test or speed/accuracy improvement.

The source files were restored after archiving this exact patch. Review and
compile in isolation before considering any future implementation.
