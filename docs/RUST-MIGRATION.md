# Computa Rust migration

Status: in progress. The running installed Computa app remains the verified Swift baseline until the Rust app passes all qualification gates. Compiling a library, rendering a UI, or passing isolated unit tests does not qualify the product.

The migration covers first-party production code in the native app and computer harness, chat runtime, local inference and grounding workers, browser extension, WebUI, website build, setup/distribution tooling and executable benchmark utilities. The exact upstream App Server is already Rust and continues to own existing private SQLite/rollout history. CSS, images, model weights and protocol data remain resources. Chrome requires generated WebAssembly bindings and a small JavaScript API/DOM boundary; permission, ownership, retry, provider selection and session state decisions belong to Rust.

| Existing responsibility | Rust destination | Qualification required |
|---|---|---|
| Models, native actions, tools, bridge and App Server wire contracts | `computa-contracts` | Validate untrusted JSON, preserve persisted IDs and exact serialization |
| OS process/window binding, AX reads/mutations, screenshots and input | `computa-macos` | Real foreground/background fixtures, permissions, stable identities and coordinate evidence |
| Computer tools, observation/continuation lifetimes, verification and recovery | `computa-harness` | Every active tool, revoked/stale refs, postconditions, uncertain dispatch and native approvals |
| Chrome signed-peer messaging, leases, pairing/Keychain and native helper | `computa-browser` | Signed helper/Chrome/app relationships, existing pairing migration, disconnect/replay races |
| Extension admission, commands, temporary copies and three website providers | `computa-extension` | MV3 worker/DOM integration and equivalent provider ownership/cleanup test matrix |
| Rust App Server IPC, threads/history, turns, queues, compaction and model lifecycle | `computa-runtime` | Existing SQLite chats, cold resume, ordered IPC, current scopes, cancellation and approval races |
| Durable first-party preferences and failure evidence | `computa-state` | Existing defaults import, private paths, atomic writes, idempotence and readback |
| Offline 4B/9B MLX inference and GoClick/GUI-Owl/ShowUI grounding | `computa-inference` | Exact installed weights, multimodal/context/stream contracts, resident memory, cancellation and cascade parity |
| Interface rendering, drafts, activity, queue actions and model selection | `computa-ui` | Native and WASM tests plus real desktop model picker/composer/history/keyboard/stream behavior |
| AppKit trusted controls, human browser pane and app lifecycle | `computa-desktop` | Same app identity, inert approval fences, persistent unprivileged browser, launch/shutdown and all routing |
| Build, source pins, model installation, signing, packaging, installation and benchmarks | `xtask` | Exact reproducibility and source/artifact identities, backups/rollback and first-party runtime closure |

Required final gates:

1. Every executable first-party responsibility and its regression tests has an implemented Rust owner. Archived historical experiments are evidence, never a production dependency.
2. Native tests, WASM tests, formatting, linting, dependency/source integrity and packaged-resource checks pass.
3. The Rust product has no first-party Swift, TypeScript or Python production execution path. Generated browser glue is confined to documented platform primitives.
4. Installed local-model generation, image/context limits, clean streaming completion, interruption, model switching and all three grounding models pass.
5. ChatGPT, Gemini and Claude each complete an actual computer-tool fixture task through the Rust desktop harness. A manual website reply or synthetic codec test is insufficient.
6. Each provider uses its verified temporary mode and closes only its owned website session. Local history survives restart and cold resume; cleanup uncertainty is visibly retained.
7. Signed Rust app/helper/worker artifacts pass their identity checks, source/install paths match the reviewed PR commit, and the actual installed app passes the desktop qualification matrix.

Until those gates pass, the rewrite must be reported as incomplete and must not be marked complete merely because one subsystem compiles. Before a controlled installed qualification, gates 1–4 and signed artifact/resource checks must pass, the exact source commit must be reviewable on the PR, and a verified rollback copy of the existing app must be retained. Gates 5–7 then require the actual installed Rust app, including any explicit Chrome consent needed to activate the updated extension.

Qualification recorded on 2026-10-06 for the current working tree:

- The dedicated Rust desktop qualifier completed an actual pinned App Server / native 4B turn with the exact final answer `RUST_DESKTOP_OK`. Its status tool also ran through the production dispatcher. After quitting and relaunching the app, the exact original prompt, answer and selected 4B model reappeared from local history.
- The runtime integration fixture completed an actual 4B turn with the exact answer `READY`, then recovered the original local-model thread and answer through a second App Server process using the same SQLite store. Its exact owned worker and listener were removed at shutdown.
- The owned native AppKit fixture qualified exact process/window binding, a real AX text mutation, a fresh postcondition, foreground preservation and termination. That direct fixture is narrower than a model-driven computer task.
- The private desktop qualifier is ad hoc signed. These results do not qualify the installed Swift app, signed Rust release artifacts, three website providers, real grounding models, or the complete computer-task matrix. Those gates remain open.
- All nine native app/browser library suites passed: 188 tests. Their all-target Clippy checks passed with warnings denied. The inference stream regressions also passed for output exhaustion, withheld tool bundles, context failures and the following request. These tests do not establish live website-provider behavior.
- The exact owned unloaded inference worker exited and removed its listener after its supervisor was killed. The legacy loaded-model parent-death gate still requires a separate live run.
- Rust-native GoClick and GUI-Owl conversions passed independent dtype-bit comparisons for all 870 and 1,019 tensors, respectively; the corrected GoClick tokenizer also matched all 1,030 upstream added-token records. Real grounding task accuracy remains unqualified.
- Chrome startup now derives and verifies only the exact installed signed app/helper before repairing a matching old native-host registration with a private backup. Persistent extension reconnect is covered by native and generated-WASM tests. No live Chrome registration or extension activation was performed for this source check.
- The optimized native inference and grounding workers built with their exact colocated Metal resource. The first actual 9B lifecycle run reached a completed response but failed the exact-answer oracle; later image, context, cancellation and switching checks were not reached. That model gate remains open.
- The inference library passed all 50 tests, including native numerical fixtures and forced-reasoning-close whitespace preservation. The tooling library passed all 113 tests, including eight source receipt regressions. The receipt binds a clean Git checkpoint and compiler to signed executable code and resources; it still needs qualification against the actual signed release bundle.
