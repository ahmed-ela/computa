# Working on Kolmogor

The shipping Mac app has a Swift host, an Octane interface rendered in WebKit, and a bundled Rust agent runtime. Keep the [README](README.md) focused on what users can do and how to get started. Put contributor instructions here and detailed designs and qualification results in the relevant guide.

## Keep Swift at the macOS boundary

Use Swift only where Kolmogor needs a native macOS interface, such as hosting a WebKit view, receiving an AppKit callback, or presenting a system dialog. Keep those adapters small. Build shared UI in Octane and put portable state transitions, provider logic, and tool orchestration in the Rust runtime. Keep permission enforcement on the trusted side of the bridge as logic moves. The table below describes the current shipping layout.

## Where to make a change

| Area | Entry point |
| --- | --- |
| Chat, composer, model picker, and Settings | [WebUI/src](WebUI/src) contains the Octane components and styles. The [website](Website) is a separate client. |
| Native window, task state, and approval prompts | [Sources/Computa/State](Sources/Computa/State) owns task state. [Sources/Computa/Web](Sources/Computa/Web) bridges it to the UI through revisioned snapshots and validated actions. Approval decisions belong in the native host. |
| Providers and tools | [Sources/Computa/Runtime](Sources/Computa/Runtime) contains provider adapters, CLI discovery, and tool dispatch. The app-owned Codex App Server is built from pinned upstream source and a checked-in patch. See the [runtime provenance and build commands](Runtime/README.md). |
| Browser and native app control | [Sources/Computa/Browser](Sources/Computa/Browser) owns WebKit sessions and tabs. [Sources/AutomationCore](Sources/AutomationCore) handles macOS Accessibility and screen capture. |
| Rust app migration | [crates](crates) contains the separate Rust app and workers. Track its qualification against the shipping Swift app in the [migration guide](docs/RUST-MIGRATION.md). |

## Build and test

Start with the [source-build prerequisites](docs/BUILDING.md#requirements). From the repo root, `./Scripts/setup.sh --check` checks the local toolchain. For a source install or optional model weights, follow the [setup guide](docs/BUILDING.md#checkout-and-setup).

- **WebUI.** From `WebUI/`, run `bun install --frozen-lockfile`, `bun run check`, `bun test tests`, and `bun run build`. Commit the rebuilt [app resources](Sources/Computa/Resources/WebUI) with UI changes. The Mac app loads that bundle.
- **Native host.** Run `swift test` from the root, or use `swift test --filter <TestName>` for a focused check. [project.yml](project.yml) defines the Xcode project. Run `xcodegen generate` after editing it.
- **Rust workspace.** Run `cargo xtask check` for the native and WASM checks. To inspect the patched App Server source separately, run `bun Scripts/build-agent-runtime.ts --prepare-only --isolated-source`.
- **Live tool or provider changes.** Default tests use fixtures. When reporting live results, record the build, provider, model, task, and observed outcome. The [workflow benchmark](docs/HARNESS-WORKFLOW-BENCHMARK.md) covers terminal, file editing, Git, and localhost. The [provider qualification notes](docs/EMBEDDED-PROVIDERS-QUALIFICATION.md) distinguish fixture coverage from installed-app checks.

## Runtime contracts

- **Website models.** Preserve a person's signed-in tab. Verify the model and conversation on the app-owned inference page before sending, and track cleanup of that page separately from the local chat. See [model discovery](docs/WEBSITE-MODEL-CHOICES.md) and [inference ownership and cleanup](docs/WEBSITE-INFERENCE-TRANSACTIONS.md).
- **Browser actions.** Human browsing tabs, model inference pages, and the privileged chat UI have separate roles. A browser action uses a current observation of its target. Verify the outcome before reporting success or retrying an uncertain action. See the [browser tool contract](docs/BUILT-IN-BROWSER-TOOLS.md) and [action verification](docs/BROWSER-ACTION-RELIABILITY.md).
- **Commands and edits.** Report the command's working directory, output, and exit status. The native review layer validates file and hunk identities when staging or reverting changes. See [terminal sessions](docs/COMMANDS.md) and [code editing](docs/CODE-EDITING.md).
- **Task continuity.** The follow-up queue belongs to its task. A failed, stopped, or disconnected turn pauses the queue. Check acknowledgments before resending. Preserve existing bundle, storage, preference, and bridge identifiers when changing product-facing names. See [installation and existing data](docs/BUILDING.md#installation-data-and-permissions).
- **Permissions.** Ask Every Time and Full Access are resolved by the native host. macOS Accessibility and Screen Recording permissions are separate user grants. See the [runtime instructions](docs/AGENT-INSTRUCTIONS.md).

## Pull requests

For every PR, record the app version decision and a one-sentence reason in the
description. Follow [Kolmogor’s versioning policy](docs/VERSIONING.md#version-decision-for-each-pr)
and include any major, minor, or patch bump in the same PR. Recheck against
the current `kolmogor` branch before squash merge.

A squash merge to `kolmogor` queues a signed macOS alpha. See the [release guide](docs/RELEASING.md#release-on-merge) for the signing worker, notarization, public download, and Sparkle feed checks.

The [pre-reorganization README](https://github.com/ahmed-ela/kolmogor/blob/5541a0fc28801c27eedd7bd7ea8917b961c35d52/README.md) preserves the original build recipes, compatibility identifiers, and dated verification records. Current work is tracked in [TODO.md](TODO.md).
