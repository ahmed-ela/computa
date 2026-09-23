# LocalCodex

LocalCodex is a clean-room macOS desktop-agent client for the Codex App Server installed with the Codex/ChatGPT desktop app. Its signed Swift host owns the agent runtime and macOS permissions, while a compiled Octane interface renders in the system `WKWebView`. It recreates the shape of a local Codex-style desktop experience without copying the Codex GUI, private source, or application assets.

The project has moved beyond a static UI shell: it launches an isolated App Server over stdio, loads and resumes its LM Studio threads, starts turns, streams thread/turn/item updates into the transcript, presents native approval requests, and exposes one compact clean-room `computer` tool for desktop observation and control.

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
          └── LocalCodex dynamic tool: computer
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

## Native computer tool

The App Server exposes one prompt-efficient dynamic tool named `computer`, backed by the clean-room `AutomationCore` Swift target. Its `action` selects the operation and its `parameters` carry only the fields needed for that action:

| Actions | Behavior |
| --- | --- |
| `permission_status`, `apps` | Read macOS authorization state or list running applications and process metadata. |
| `open` | Launch an application by bundle identifier and optionally open an `http`, `https`, or `file` URL. |
| `snapshot` | Return a bounded semantic Accessibility tree with snapshot-scoped element indices; an optional query prioritizes matching labels and values. |
| `ax`, `set_text` | Perform a checked semantic Accessibility action or set a value on an inspected element. |
| `capture` | Capture a display through ScreenCaptureKit as PNG image content, downscaled to fit the local model's 4K context. |
| `move`, `click`, `double_click`, `right_click`, `scroll`, `drag` | Send native pointer input to an explicitly identified target process. |
| `keypress`, `type` | Send approved keyboard input to an explicitly identified target process. |

All mutations pause for a native approval decision. Before raw input, LocalCodex reactivates the approved target process so a focus change during approval cannot silently redirect the event. Each semantic Accessibility mutation is bound to the exact process, snapshot UUID, and element index the model inspected; an attempted mutation invalidates the snapshot so the model must inspect again before another action. The model is instructed to observe again after every action instead of treating an acknowledgement as proof of success. Display `capture` is read-only and does **not** present a per-screenshot native approval gate: once macOS Screen Recording access is granted, a local model turn can request captures while LocalCodex runs.

Permission onboarding is explicit. AutomationCore can read permission state without prompting, and only the human-operated **Request access** buttons in LocalCodex Settings call the macOS permission-request APIs. A button press is not proof of a grant: on this macOS 27 installation, Screen Recording returned denied without a system prompt. If the request remains denied, LocalCodex opens **System Settings → Privacy & Security → Screen & System Audio Recording** when that pane link is available, or opens System Settings as a fallback, so the user can add and enable the app in the screen-recording list, not the audio-only list. Relaunch LocalCodex after granting access, then refresh its Settings status. Permission-dependent tool calls fail closed when authorization is absent; the local model cannot grant or request access itself.

## Prerequisites

- macOS 14 or newer;
- Xcode with a Swift 6.2-capable toolchain (the Swift Package manifest uses tools version 6.2);
- XcodeGen when regenerating the Xcode project (`brew install xcodegen`);
- the Codex/ChatGPT desktop app installed at `/Applications/ChatGPT.app`, including its executable `Contents/Resources/codex`;
- for live inference, LM Studio with its local server running and `mlx-community/Qwen3.8-27B-4bit` downloaded and available;
- Accessibility permission for semantic inspection and native input, plus Screen Recording permission for display capture. Use **Settings → Computer use → Request access** or the applicable macOS Privacy & Security pane, relaunch after granting Screen Recording, then verify that the app reports **Granted**. On this macOS 27 installation, Screen Recording needs manual registration in System Settings.

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

The local release is signed for this machine with Ahmed's Apple Development identity (`TeamIdentifier=MSMG8CJLB3`) and hardened runtime enabled. macOS can still bind Accessibility approval for a local development build to that build's exact code hash, so replacing the application may require requesting Accessibility again even though the signing identity is unchanged. Screen Recording can remain attached to the designated signing requirement. It is not Developer ID signed or notarized, so Gatekeeper assessment still rejects it as a distribution build; that is expected for this private local install.

For faster command-line iteration, the same targets are available through Swift Package Manager:

```sh
swift build
swift test
swift run LocalCodex
```

Run the deterministic Swift suite with warnings promoted to errors:

```sh
swift test -Xswiftc -warnings-as-errors
```

Two opt-in integration tests exercise the production `CodexAppServerRuntime`, `AppState`, Web UI snapshot, and the loaded local model without mutating the desktop:

```sh
LOCALCODEX_LIVE_MODEL_TEST=1 swift test \
  --filter LocalQwenLiveTests/testProductionRuntimeCompletesLocalQwenTurn

LOCALCODEX_LIVE_MODEL_TEST=1 swift test \
  --filter LocalQwenLiveTests/testProductionRuntimeExecutesReadOnlyComputerTool
```

The end-to-end Chrome fixture is a separate opt-in gate. It requires Google Chrome and Accessibility access for the test host, launches a local HTML fixture, approves the test's computer mutations, asks Qwen to press a semantic button and re-observe the page, and requires both the expected tool activity and completion token:

```sh
LOCALCODEX_LIVE_COMPUTER_TEST=1 swift test \
  --filter LocalQwenLiveTests/testProductionRuntimeControlsChromeFixture
```

A second Chrome gate exercises the visual fallback and raw coordinate path. It requires both Accessibility and Screen Recording, limits Qwen to one downscaled screenshot, requires the exact `open → capture → click → snapshot` action sequence, and independently checks Chrome's resulting Accessibility state:

```sh
LOCALCODEX_LIVE_VISUAL_COMPUTER_TEST=1 swift test \
  --filter LocalQwenLiveTests/testProductionRuntimeVisuallyControlsChromeFixture
```

Normal test runs compile the live cases but skip their external model and desktop work. The presence of a live test is not evidence that it passed; record Chrome as verified only after the command above completes successfully on the target machine.

The live gates verify protocol primitives as well as projected application state. Each run parses the isolated App Server rollout for the model-level `function_call` and matching `function_call_output`, and enables a test-only recorder for the exact newline-delimited App Server frames. Each layer is validated independently for the required action order; the App Server trace must also contain `item/started`, `item/tool/call`, the matching successful client response, and authoritative `item/completed` for every call. The final snapshot output at both layers must contain the run's unique completion token. Visual runs additionally require a valid PNG in both the model rollout and raw App Server response. These Chrome gates do not record the separate App Server-to-LM Studio HTTP/SSE hop; the read-only `permission_status` run below supplies that raw SSE proof. The shipped app leaves its recorder disabled so LocalCodex does not make a second copy of prompts or tool payloads.

## Verification status

As of September 23, 2026, this workspace has established:

- successful Swift Package and native Xcode application builds;
- the separate opt-in production-runtime test passing against LM Studio, including an exact `LOCAL_QWEN_OK` assistant entry, task status `Completed`, and the corresponding Web UI snapshot;
- a production-runtime turn using the unified `computer` tool's read-only `permission_status` action and returning the expected completion token;
- primitive-level proof for that same live turn across all three transport layers: the persisted model `function_call`/`function_call_output`, exact App Server stdio frames, and the two real LM Studio `/v1/responses` SSE exchanges captured on loopback;
- exact call-ID continuity from LM Studio's streamed function call, through App Server's `item/tool/call` and native result, into the continuation request and final streamed `LOCAL_COMPUTER_TOOL_OK` response;
- the semantic Chrome gate passing in 83.418 seconds with `open → snapshot → ax → snapshot`, call IDs `call_1293236275110009` through `call_1293236275110012`, and final snapshot token `LOCALCODEX_CHROME_OK_002BB3D4C85F4AFBAA6914E223BB5D19` present in both rollout and raw App Server results;
- the visual Chrome gate passing in 273.905 seconds with exactly `open → capture → click → snapshot`, call IDs `call_1293236275110013` through `call_1293236275110016`, one valid PNG at both validated layers, a click inside the independently measured fixture-button frame, and final snapshot token `LOCALCODEX_CHROME_OK_F2A624DDE65F413EB5CB7DB18E360F0C`;
- the current hardened installed signed app (binary SHA-256 `c93d16fa5124001c8a4ab07c557aa774aaed0292e54f92aebe5ae9626f188bc1`) completing a manually approved semantic Chrome turn with `open → snapshot → ax` (`AXPress`) `→ snapshot`, call IDs `call_1293236275110045` through `call_1293236275110048`: the final model-visible Chrome snapshot identified bundle `com.google.Chrome`, and it and an independent native Chrome Accessibility read both contained `HARDENED_INSTALLED_AX_OK_C93D16FA`; LocalCodex reached `Completed` with that token as its final answer;
- the Octane sidebar, transcript, composer, inspector, settings, and light/dark appearance rendering inside the native WebKit window;
- initialization of the installed Codex App Server over stdio;
- an App Server `thread/start` accepting the `lmstudio` provider, configured Qwen model, workspace sandbox, approval policy, and compact `computer` dynamic-tool schema;
- App Server thread listing, persisted-thread resumption, event mapping, and fail-closed approval handling in the native client;
- the exact Qwen model downloaded, indexed, and visible through LM Studio's OpenAI-compatible model endpoint;
- the loaded MLX runtime reporting one parallel request and a 4,096-token context;
- direct `/v1/responses` inference completing with the exact visible answer `LOCAL_QWEN_OK`;
- an otherwise exact Codex-shaped request, including the unified computer-tool schema, completing after the model-template compatibility filter;
- a fresh task in the packaged native release completing end to end with the visible assistant text `LOCAL_QWEN_OK`, task status `Completed`, and the assistant event selected in the inspector;
- approval decisions round-tripping only from the native Swift gate back to App Server, with stale/replaced requests rejected;
- a bundle-only custom URL scheme, production CSP with network connections disabled, no shipped source maps, and no production demo-state fallback;
- bounded, tamper-checked Accessibility snapshots and approval-gated semantic, pointer, and keyboard actions;
- targeted semantic searches scanning up to 1,000 bounded source elements while keeping the formatted result within a 1,000-character local-model budget.

The current Xcode Swift suite has 116 total tests: 112 deterministic tests passed, four external model/desktop gates skipped unless explicitly enabled, and zero failures. The Bun typecheck, production UI build, and signed universal Xcode Release build also passed. The Swift suite covers the local composer, injected runtime snapshots, exact App Server frame decoding, model-rollout primitive decoding, permission guards and onboarding, capture sizing, strict model-argument parsing, Accessibility snapshot formatting and tamper checks, guarded semantic mutations, strict fixture-target approval, and native input routing. Both opt-in Chrome gates above were run separately against the production runtime; the installed-app semantic turns were separate, human-approved runs.

## Current limitations

- The constrained 4,096-token profile exposes the native `computer` tool, not the App Server's shell or built-in coding/editing tool set. LocalCodex is a local chat and desktop-automation client, not a shell-capable coding agent.
- Chrome is controlled through the same generic app launch, Accessibility, capture, pointer, and keyboard actions as other macOS applications; there is no browser extension or Chrome-specific automation protocol.
- This Mac also has Codex's richer installed `cua_repl`/computer-use stack, but LocalCodex does not load or copy it. The project-owned clean-room `computer` tool is the only desktop tool exposed to Qwen.
- The successful semantic and visual smoke turns prove both model/runtime paths on the controlled Chrome fixture; they do not establish that this quantized model will reliably select and format every desktop tool call on arbitrary interfaces.
- The current signed installed app passed separate `open → capture → snapshot` and natively approved `open → snapshot → AXPress → snapshot` Chrome turns, both ending `Completed`. Screen Recording is **Granted** after the user enabled it in macOS and relaunched the app. The screenshot turn took 540 seconds; this capability result is not a speed benchmark. The coordinate-click path was separately validated in the opt-in production-runtime test host, not repeated in this exact installed binary.
- App Server persists a task's dynamic-tool schema when that task is created. Tasks created by an older LocalCodex build do not gain the new `computer` tool when resumed; start a new task for computer use after upgrading.
- The App Server executable path, default provider/model, and initial workspace are currently fixed in code rather than selected in the settings UI.
- The distributed ZIP is Apple Development signed with hardened runtime enabled for Ahmed's local use. It is not Developer ID signed or notarized for public distribution.

## Source layout

```text
Sources/
├── AutomationCore/
│   ├── permission inspection and guards
│   ├── application launch and running-app metadata
│   ├── ScreenCaptureKit display capture and native pointer/keyboard input
│   └── bounded Accessibility snapshots and guarded semantic actions
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
