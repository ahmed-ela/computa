# LocalCodex

LocalCodex is a clean-room macOS desktop-agent client for the Codex App Server installed with the Codex/ChatGPT desktop app. Its signed Swift host owns the agent runtime and macOS permissions, while a compiled Octane interface renders in the system `WKWebView`. It recreates the shape of a local Codex-style desktop experience without copying the Codex GUI, private source, or application assets.

The project has moved beyond a static UI shell: it launches an isolated App Server over stdio, loads and resumes its LM Studio threads, starts turns, streams thread/turn/item updates into the transcript, presents native approval requests, and exposes eight clean-room desktop automation tools.

## Current architecture

```text
Swift application host
  WKWebView · compiled Octane task UI · narrow message bridge
          │ native full-state snapshots and validated actions
          ▼
CodexAppServerRuntime + AutomationCore
  typed AgentRuntimeClient adapter + JSON-RPC event mapping
          │ stdio
          ▼
/Applications/ChatGPT.app/Contents/Resources/codex
  app-server --listen stdio://
          │
          ├── LM Studio provider
          │     mlx-community/Qwen3.8-27B-4bit
          │
          └── LocalCodex dynamic tools
                AutomationCore (AppKit, Accessibility, ScreenCaptureKit)
```

The Octane/WebKit layer owns ordinary presentation. `CodexAppServerRuntime` translates App Server requests and notifications into the typed task, status, timeline, and connection events consumed by `AppState`. A narrow native bridge sends revisioned, data-minimized snapshots to the page and accepts only validated UI actions; it never exposes Accessibility or ScreenCaptureKit directly. Privileged approval decisions remain in a native Swift overlay and are never accepted from JavaScript. App Server remains responsible for the agent loop, thread state, sandbox selection, approval requests, and model-provider integration. LocalCodex deliberately removes unrelated built-in tools, plugins, memories, skills, and MCP configuration from its constrained local-model turns.

New turns currently use these defaults:

- model provider: `lmstudio`;
- model: `mlx-community/Qwen3.8-27B-4bit`;
- workspace: the current user's Documents directory;
- sandbox: `workspace-write`;
- approval policy: `on-request`;
- reasoning effort: `medium`;
- declared context window: 4,096 tokens, with automatic compaction at 3,584 tokens;
- isolated App Server home: `~/Library/Application Support/LocalCodex/CodexHome`;
- persistent App Server threads (`ephemeral: false`).

The private `CODEX_HOME` prevents personal Codex memories, plugins, MCP configuration, and task state from inflating or leaking into these local turns. The compact base instruction is under 1 KiB. Workspace policy files such as `AGENTS.md` remain authoritative and are still honored.

## Application surface

- searchable task sidebar backed by App Server threads;
- user, assistant, reasoning, system, and tool-event transcript rows;
- bottom-anchored prompt composer;
- resizable Octane inspector for the selected task and event;
- Octane settings modal with system, light, and dark appearance;
- connection and macOS automation-permission status;
- a native approval gate with explicit **Allow Once** and **Decline** decisions;
- accessible labels and keyboard actions;
- sample/state injection support for isolated development and tests.

## Desktop tools

The App Server dynamic-tool surface is backed by the clean-room `AutomationCore` Swift target:

| Tool | Behavior |
| --- | --- |
| `desktop_permission_status` | Reads Accessibility and Screen Recording authorization without prompting. |
| `desktop_list_apps` | Lists running applications and process metadata. |
| `desktop_focused_window` | Reads metadata for the focused window through Accessibility. |
| `desktop_snapshot_app` | Returns a bounded semantic Accessibility tree with snapshot-scoped element indices. |
| `desktop_perform_action` | Performs a checked semantic action such as `AXPress`; always pauses for GUI approval. |
| `desktop_set_text` | Types into a settable Accessibility element; always pauses for GUI approval. |
| `desktop_list_windows` | Lists windows visible to ScreenCaptureKit. |
| `desktop_capture_window` | Returns a PNG capture of a selected window. |

AutomationCore never opens a permission prompt itself. Permission-dependent calls fail closed with a typed error when authorization is absent. Each Accessibility mutation is bound to the exact process, snapshot UUID, and element index the model inspected; an attempted mutation invalidates the snapshot so the model must inspect again before another action.

## Prerequisites

- macOS 14 or newer;
- Xcode with a Swift 6.2-capable toolchain (the Swift Package manifest uses tools version 6.2);
- XcodeGen when regenerating the Xcode project (`brew install xcodegen`);
- the Codex/ChatGPT desktop app installed at `/Applications/ChatGPT.app`, including its executable `Contents/Resources/codex`;
- for live inference, LM Studio with its local server running and `mlx-community/Qwen3.8-27B-4bit` downloaded and available;
- Accessibility permission for focused-window inspection and Screen Recording permission for window discovery/capture.

The UI and App Server transport can start without LM Studio, but a model turn cannot complete until the configured model and server are available.

## Local LM Studio compatibility

This Mac has `mlx-community/Qwen3.8-27B-4bit` installed under LM Studio and served at `127.0.0.1:1234`. The installed model directory is about 16.08 GB; its three weight shards total 16,054,541,349 bytes. It is loaded with one parallel request and a bounded 22 GiB custom model-loading guardrail. The guardrail remains enabled.

LM Studio is configured to request an 8,192-token default context, but the current MLX runtime auto-fits this 27B model to 4,096 tokens on the 24 GB Mac. LocalCodex therefore declares the context that is actually loaded instead of advertising 8,192 or the model's much larger training limit.

One model-local compatibility patch is required on this installation. Codex exposes a `request_user_input` tool schema even though LocalCodex does not implement that tool; with that schema serialized, this MLX/model path stalled. The installed model's `chat_template.jinja` skips only that schema when rendering tools. The original template is preserved beside it as `chat_template.jinja.localcodex-original` (SHA-256 `c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041`); the patched template hash is `c73f9ec1cfc68a6ce7e19f06b1779afa4b1a55e1da8775d498f379a09b8fae75`.

That compatibility patch lives in LM Studio's model directory, not in either LocalCodex ZIP. Redownloading the model may replace it.

## Build the Octane UI

The checked-in browser bundle is produced with Bun and runs as static JavaScript in WebKit. Bun and Node are not included in the application:

```sh
cd LocalCodex/WebUI
bun install
bun run check
bun run build
```

Octane currently declares Node.js 22.22.2 or newer for its supported development toolchain. This UI uses ordinary `.tsx`, whose typecheck and production build work with the installed Bun toolchain; retain a current Node installation as the upstream-compatible fallback.

## Generate, build, and test the app

`project.yml` is the source of truth for the native Xcode project:

```sh
cd LocalCodex
xcodegen generate

xcodebuild -project LocalCodex.xcodeproj -scheme LocalCodex \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  build

xcodebuild -project LocalCodex.xcodeproj -scheme LocalCodex \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  test
```

The debug application is written to:

```text
.build/DerivedData/Build/Products/Debug/LocalCodex.app
```

Run it with:

```sh
open .build/DerivedData/Build/Products/Debug/LocalCodex.app
```

## Release bundle

The packaged application is a universal macOS app containing both Apple Silicon and Intel slices. Extract `LocalCodex-macOS.zip`, move `LocalCodex.app` to Applications if desired, and open it. The archive contains the compiled Octane interface and the system-WebKit Swift host; it does not contain Bun, Node.js, Electron, Chromium, model weights, or the LM Studio chat-template patch described above.

The local release is ad-hoc signed with hardened runtime enabled. Because it is not Developer ID signed or notarized, macOS may require an explicit **Open** confirmation on first launch.

For faster command-line iteration, the same targets are available through Swift Package Manager:

```sh
swift build
swift test
swift run LocalCodex
```

An opt-in integration test exercises the production `CodexAppServerRuntime`, `AppState`, and web snapshot against the loaded local model:

```sh
LOCALCODEX_LIVE_MODEL_TEST=1 swift test \
  --filter LocalQwenLiveTests/testProductionRuntimeCompletesLocalQwenTurn
```

Normal test runs compile this test but skip its live model call.

## Verified status

As of September 22, 2026, this workspace has verified:

- successful Swift Package and native Xcode application builds;
- all 39 deterministic unit tests passing: 12 application/web-boundary tests and 27 AutomationCore tests;
- the separate opt-in production-runtime test passing against LM Studio, including an exact `LOCAL_QWEN_OK` assistant entry, task status `Completed`, and the corresponding Web UI snapshot;
- the Octane sidebar, transcript, composer, inspector, settings, and light/dark appearance rendering inside the native WebKit window;
- initialization of the installed Codex App Server over stdio;
- an App Server `thread/start` accepting the `lmstudio` provider, configured Qwen model, workspace sandbox, approval policy, and dynamic-tool schemas;
- App Server thread listing, persisted-thread resumption, event mapping, and fail-closed approval handling in the native client;
- the exact Qwen model downloaded, indexed, and visible through LM Studio's OpenAI-compatible model endpoint;
- the loaded MLX runtime reporting one parallel request and a 4,096-token context;
- direct `/v1/responses` inference completing with the exact visible answer `LOCAL_QWEN_OK`;
- an otherwise exact Codex-shaped request, including the eight desktop-tool schemas, completing after the model-template compatibility filter;
- a fresh task in the packaged native release completing end to end with the visible assistant text `LOCAL_QWEN_OK`, task status `Completed`, and the assistant event selected in the inspector;
- approval decisions round-tripping only from the native Swift gate back to App Server, with stale/replaced requests rejected;
- a bundle-only custom URL scheme, production CSP with network connections disabled, no shipped source maps, and no production demo-state fallback;
- bounded, tamper-checked Accessibility snapshots and approval-gated semantic action/text tools;

The passing tests cover local composer behavior, injected runtime snapshots, permission guards, capture sizing, and the guarded Accessibility mutation primitives. Live inference is verified separately from that unit coverage.

## Current limitations

- The constrained 4,096-token profile disables shell and built-in file-edit/coding tools. This build is currently a local chat and desktop-automation client, not a full shell-capable coding agent.
- The clean-room tool set supports semantic Accessibility actions and text entry, but not yet coordinate clicks, scrolling, drag gestures, arbitrary key chords, or browser-specific control.
- This Mac also has Codex's richer installed `cua_repl`/computer-use stack, but it is deliberately not loaded into LocalCodex's isolated and pruned turns. Only the eight project-owned desktop tools are exposed.
- A successful smoke turn proves the model/runtime path works; it does not establish that this quantized model will reliably select and format every desktop tool call.
- The App Server executable path, default provider/model, and initial workspace are currently fixed in code rather than selected in the settings UI.
- The distributed ZIP is ad-hoc signed with hardened runtime enabled for local use. It is not Developer ID signed or notarized.

## Source layout

```text
Sources/
├── AutomationCore/
│   ├── permission inspection and guards
│   ├── running/focused-window metadata
│   ├── ScreenCaptureKit window capture
│   └── bounded Accessibility snapshots and guarded actions
└── LocalCodex/
    ├── Assets.xcassets/    clean-room application icon
    ├── LocalCodexApp.swift
    ├── Models/             Task and timeline value types
    ├── Runtime/            App Server transport and runtime boundary
    ├── State/              Root-owned observable application state
    ├── Web/               WKWebView host, native approval gate, bridge, snapshot DTOs
    └── Resources/WebUI/   compiled Octane bundle and third-party notice
WebUI/
├── src/                   Octane components and styling
├── public/                files copied into the application bundle
├── package.json
└── vite.config.ts
```
