# LocalCodex

LocalCodex is a clean-room macOS desktop-agent client for the Codex App Server installed with the Codex/ChatGPT desktop app. Its signed Swift host owns the agent runtime and macOS permissions, while a compiled Octane interface renders in the system `WKWebView`. It recreates the shape of a local Codex-style desktop experience without copying the Codex GUI, private source, or application assets.

The project has moved beyond a static UI shell: it launches an isolated App Server over stdio, loads and resumes its LM Studio threads, starts turns, streams thread/turn/item updates into the transcript, presents native approval requests, and exposes a versioned clean-room computer-use contract for desktop observation and control.

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
          │     mlx-community/Qwen3.8-27B-4bit (default)
          │     lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit (optional)
          │     lmstudio-community/Qwen3.5-9B-MLX-4bit (optional)
          │     lmstudio-community/Qwen3.5-4B-MLX-4bit (optional)
          │
          └── LocalCodex dynamic tools: computer_v2_*
                ├── AutomationCore (AppKit, Accessibility, ScreenCaptureKit)
                └── native visual fallback (external pinned MLX worker)
```

The Octane/WebKit layer owns ordinary presentation. `CodexAppServerRuntime` translates App Server requests and notifications into the typed task, status, timeline, and connection events consumed by `AppState`. A narrow native bridge sends revisioned, data-minimized snapshots to the page and accepts only validated UI actions; it never exposes Accessibility or ScreenCaptureKit directly. Privileged approval decisions remain in a native Swift overlay and are never accepted from JavaScript. App Server remains responsible for the agent loop, thread state, sandbox selection, approval requests, and model-provider integration. LocalCodex deliberately removes unrelated built-in tools, plugins, memories, skills, and MCP configuration from its constrained local-model turns.

New tasks default to `mlx-community/Qwen3.8-27B-4bit`. Settings can change the persisted default for new tasks, and the composer selector can change an individual idle task's model. The selected model ID is sent to App Server on thread start, resume, and turn start; existing threads keep their recorded model unless explicitly changed. Other turn defaults are:

- model provider: `lmstudio`;
- workspace: the current user's Documents directory;
- sandbox: `workspace-write`;
- approval policy: `on-request`;
- reasoning effort: `medium`;
- declared context window: 4,096 tokens for 27B (automatic compaction at 3,584), or 8,192 for 9B/4B (compaction at 7,168);
- isolated App Server home: `~/Library/Application Support/LocalCodex/CodexHome`;
- persistent App Server threads (`ephemeral: false`).

The private `CODEX_HOME` prevents personal Codex memories, plugins, MCP configuration, and task state from inflating or leaking into these local turns. The compact base instruction is under 1 KiB. Workspace policy files such as `AGENTS.md` remain authoritative and are still honored.

## Application surface

- searchable task sidebar backed by App Server threads;
- user, assistant, reasoning, system, and tool-event transcript rows;
- bottom-anchored prompt composer;
- model selector for each idle task and a persisted default for new tasks;
- resizable Octane inspector for the selected task and event;
- Octane settings modal with system, light, and dark appearance;
- connection and macOS automation-permission status;
- a native approval gate with explicit **Allow Once** and **Decline** decisions;
- accessible labels and keyboard actions;
- sample/state injection support for isolated development and tests.

## Native computer tool

New tasks register action-specific `computer_v2_*` dynamic tools backed by the clean-room `AutomationCore` Swift target. The schemas describe each call, and Swift validates every field before dispatch because the local model server can accept malformed arguments despite a `required` schema. The legacy `computer` dispatcher remains only for threads that persisted its older tool schema:

| V2 tools | Behavior |
| --- | --- |
| `computer_v2_status`, `computer_v2_apps` | Read macOS authorization state or list running applications. |
| `computer_v2_open` | Launch and bind an application by bundle identifier. A Chrome URL opens in a project-owned isolated Chrome process and returns a task-scoped opaque tab handle plus document epoch. |
| `computer_v2_snapshot` | Return a bounded semantic Accessibility tree for the bound native app or exact brokered Chrome tab, with snapshot-scoped element indices. |
| `computer_v2_ax`, `computer_v2_set_text` | Perform a checked semantic action on a current inspected native element or exact brokered-tab element. |
| `computer_v2_capture` | For native apps, return a PNG of the focused, bound app window with a `capture_id` and image dimensions. The runtime retains a separate downscaled display baseline for target and occlusion checks. Brokered Chrome tabs reject this tool. |
| `computer_v2_ground_click` | For supported local models, ground a concise target description in the current native-app capture, require agreement between independent visual grounders, then request approval for the resolved click. Brokered Chrome tabs reject this tool. |
| `computer_v2_click`, `computer_v2_pointer` | For native apps, use image-pixel coordinates from that capture. The runtime maps them to screen points and checks the bound window before move, double-click, right-click, or scroll. V2 drag and brokered-tab pointer input are unavailable. |
| `computer_v2_keypress`, `computer_v2_type` | For native apps, send approved keyboard input only while the exact observed window and focused control still match. Brokered Chrome tabs reject these tools. |

All mutations pause for a native approval decision. The V2 executor binds the launched app to its task and rechecks its process, bundle, and inspected target across approval; native input also retains the existing focus checks. The model need not repeat a process ID on every call. For a Chrome URL, LocalCodex launches an isolated, project-owned Chrome profile with a random loopback DevTools port and no wildcard-origin override. It retains an opaque task-scoped handle and changes the document epoch when observation detects a changed main-frame loader or URL, including its fragment. Semantic reads and actions address that exact target without explicitly foregrounding it. The broker rejects overlapping operations for a task, consumes a valid mutation snapshot before awaiting transport, and rechecks that a revoked handle has not disappeared before publishing an observation or preparing input. The transport repeats document and element checks on its mutation connection, resolves the node into a main-frame isolated JavaScript world, and checks document membership, URL, connection, and control state in the synchronous mutation function. Revocation and the one-shot WebSocket enqueue share a lock: revocation that wins before enqueue prevents that command; a command already enqueued cannot be recalled. These checks are not an atomic lock on the browser DOM or a record of all intervening navigation events. Coordinate capture, pointer, and keyboard calls intentionally fail closed for brokered tabs; native-app AX and guarded screenshot paths remain separate. A semantic mutation requires the current snapshot UUID and element index; pointer input requires a current `capture_id` and image-space coordinates. The runtime maps those image pixels to global screen points and rejects stale or changed native windows and targets. A consumed observation must be replaced with a fresh snapshot or capture to verify the result. Window capture is read-only and does **not** present a per-screenshot native approval gate: once macOS Screen Recording access is granted, a local model turn can request native-window captures while LocalCodex runs.

LocalCodex remains semantic-first: it uses native Accessibility or the brokered browser DOM whenever those surfaces expose the intended control. `computer_v2_ground_click` is the native-app screenshot fallback for the 4B and 9B Qwen options, which leave enough memory headroom for a resident visual sidecar on this 24 GB Mac. GoClick and GUI-Owl 2B run on every request; ShowUI 2B runs only when either result is missing or the two disagree. The worker returns only parsed normalized points and diagnostics. Swift independently selects the closest pair, requires that pair to agree within 3% of the screenshot diagonal, uses their midpoint, and otherwise fails closed without presenting a click approval. The entire window is recaptured and fingerprinted after inference and again after approval, so a grounded click cannot use a capture whose surrounding context changed. The 27B and 35B model options do not register this resident sidecar tool on this machine.

Browser approvals include `observed_page_url` from the immutable retained browser snapshot, in addition to the bundle, PID, handle, and epoch. No title is inferred from page-controlled labels or parsed out of formatted text. URL display does not replace post-approval document and node revalidation. Runtime-owned lifetimes also cover targets still being created: terminal cleanup can synchronously revoke a pending open or mutation before scheduling network cleanup.

The opt-in model-free production broker gate is `CuaV2SafeChromeSemanticLiveTests/testProductionBrokerMutatesOnlyBackgroundTabAndShutsDown`, enabled with `LOCALCODEX_LIVE_CHROME_BROKER_PRIMITIVE_TEST=1`. It uses an inline, nonce-restricted loopback fixture, same-title tabs, independent acknowledged page telemetry, a retained-snapshot reuse refusal, and process-group/profile-marker cleanup checks. It does not start App Server or LM Studio and does not request a LocalCodex approval. The ordinary semantic and same-title model gates honor `LOCALCODEX_LIVE_MODEL_ID` for the supplied 4B/9B IDs. Their capability deadline is 180 seconds; the 30-second performance SLO is reported separately and does not terminate a capability trial. Every gate prints `BROWSER_GATE_ARTIFACT_DIR`; set the absolute `LOCALCODEX_LIVE_ARTIFACT_DIR` to choose a durable root. Model wire traces and result/cleanup records are retained there. Model-run JSON records use schema version 8, with separate functional, protocol, harness/model-failure, active-tab, global-application-focus, and owned-cleanup outcomes. The model gates await independent successful-press proof before the tool response and normal terminal tab closure; B can also be checked after the turn. No new gate result is claimed here.

Permission onboarding is explicit. AutomationCore can read permission state without prompting, and only the human-operated **Request access** buttons in LocalCodex Settings call the macOS permission-request APIs. A button press is not proof of a grant: on this macOS 27 installation, Screen Recording returned denied without a system prompt. If the request remains denied, LocalCodex opens **System Settings → Privacy & Security → Screen & System Audio Recording** when that pane link is available, or opens System Settings as a fallback, so the user can add and enable the app in the screen-recording list, not the audio-only list. Relaunch LocalCodex after granting access, then refresh its Settings status. Permission-dependent tool calls fail closed when authorization is absent; the local model cannot grant or request access itself.

## Prerequisites

- macOS 14 or newer;
- Xcode with a Swift 6.2-capable toolchain (the Swift Package manifest uses tools version 6.2);
- XcodeGen when regenerating the Xcode project (`brew install xcodegen`);
- the Codex/ChatGPT desktop app installed at `/Applications/ChatGPT.app`, including its executable `Contents/Resources/codex`;
- for live inference, LM Studio with its local server running and the selected model downloaded and available;
- for native visual grounding, `uv` plus approximately 4.0 GB for the three pinned model directories and 0.6 GB for their isolated Python runtime;
- Accessibility permission for semantic inspection and native input, plus Screen Recording permission for window capture. Use **Settings → Computer use → Request access** or the applicable macOS Privacy & Security pane, relaunch after granting Screen Recording, then verify that the app reports **Granted**. On this macOS 27 installation, Screen Recording needs manual registration in System Settings.

The UI and App Server transport can start without LM Studio, but a model turn cannot complete until the selected model and server are available. The optional [Qwen3.6-35B-A3B MLX 4-bit build](https://huggingface.co/lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit) is about 20.4 GB on disk. That leaves very little of this 24 GB Mac's unified memory for macOS, LM Studio, context, and screenshots. The smaller [Qwen3.5-9B MLX 4-bit build](https://huggingface.co/lmstudio-community/Qwen3.5-9B-MLX-4bit/tree/main) is about 5.98 GB, and [Qwen3.5-4B MLX 4-bit](https://huggingface.co/lmstudio-community/Qwen3.5-4B-MLX-4bit/tree/main) is about 3.06 GB. These figures are model-file sizes, not total running-memory requirements. LM Studio currently indexes the 27B, 9B, and 4B builds; the 35B build remains a selectable but not downloaded option. The smaller models now have production-runtime V2 read-only evidence, but their semantic and visual mutation behavior must be judged by the separate live gates below. Keep a bounded context rather than using the models' advertised maxima, and load only one large model at a time.

## Local LM Studio compatibility

This Mac has `mlx-community/Qwen3.8-27B-4bit` installed under LM Studio and served at `127.0.0.1:1234`. The installed model directory is about 16.08 GB; its three weight shards total 16,054,541,349 bytes. The validated 27B runs used one parallel request and a bounded 22 GiB custom model-loading guardrail. The guardrail remains enabled.

LM Studio is configured to request an 8,192-token default context, but the current MLX runtime auto-fits this 27B model to 4,096 tokens on the 24 GB Mac. LocalCodex therefore declares 4,096 tokens for 27B, with auto-compaction at 3,584. The 4B and 9B builds fit substantially larger contexts on this Mac; LocalCodex conservatively declares 8,192 tokens for them, with auto-compaction at 7,168. A loaded task cannot switch between these context classes because App Server ignores new config overrides for a loaded thread; create a new task when changing between 27B and a smaller model.

One model-local compatibility patch is required on this installation. Codex exposes a `request_user_input` tool schema even though LocalCodex does not implement that tool; with that schema serialized, this MLX/model path stalled. The installed model's `chat_template.jinja` skips only that schema when rendering tools. The original template is preserved beside it as `chat_template.jinja.localcodex-original` (SHA-256 `c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041`); the patched template hash is `c73f9ec1cfc68a6ce7e19f06b1779afa4b1a55e1da8775d498f379a09b8fae75`.

That compatibility patch lives in LM Studio's model directory, not in either LocalCodex ZIP. Redownloading the model may replace it.

## Install the native visual-grounding sidecar

The app bundle contains the worker, prompts, manifests, and warm-up image, but not the approximately 4.0 GB of visual model weights or its approximately 0.6 GB Python environment. Install them once into `~/Library/Application Support/LocalCodex/VisualGrounding`:

```sh
cd LocalCodex
Scripts/install-visual-grounding.sh
```

The installer pins the Python patch version, every direct and transitive package with hashes, every model revision, and every installed model file with SHA-256. It synchronizes away extra packages, rejects unexpected `.pth` startup code, and writes a private installation receipt. The shipped worker independently rechecks that receipt, the manifests, the exact package and `.pth` sets, and all model files before loading. The three models stay resident in one persistent worker after its cold load and warm-up.

This integrity boundary is not an OS sandbox. The Python process receives a minimal environment and is forced into the Hugging Face/Transformers offline modes during inference, but it still runs as the logged-in user. A first-time installation downloads pinned model revisions; the pinned GoClick conversion executes its upstream model code through `--trust-remote-code`. Review that boundary before installing on another machine.

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

The packaged application is a universal macOS app containing both Apple Silicon and Intel slices. Extract `LocalCodex-macOS.zip`, move `LocalCodex.app` to Applications if desired, and open it. The archive contains the compiled Octane interface, system-WebKit Swift host, and visual-grounding worker/manifests; it does not contain Bun, Node.js, Electron, Chromium, visual or language-model weights, the external Python environment, or the LM Studio chat-template patch described above.

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

Two opt-in integration tests exercise the production `CodexAppServerRuntime`, `AppState`, Web UI snapshot, and a selected local model without mutating the desktop. With no model override they select the 27B catalog default explicitly, independent of the user's saved UI preference. The read-only computer-use gate requires one `computer_v2_status` call with `{}` arguments, its matching raw App Server and rollout primitives, and the final completion token:

```sh
LOCALCODEX_LIVE_MODEL_TEST=1 swift test \
  --filter LocalQwenLiveTests/testProductionRuntimeCompletesLocalQwenTurn

LOCALCODEX_LIVE_MODEL_TEST=1 swift test \
  --filter LocalQwenLiveTests/testProductionRuntimeExecutesReadOnlyComputerTool
```

Run the same read-only V2 gate separately with each smaller installed model by setting `LOCALCODEX_LIVE_MODEL_ID` to its catalog ID:

```sh
LOCALCODEX_LIVE_MODEL_TEST=1 \
LOCALCODEX_LIVE_MODEL_ID=lmstudio-community/Qwen3.5-9B-MLX-4bit \
  swift test --filter LocalQwenLiveTests/testProductionRuntimeExecutesReadOnlyComputerTool

LOCALCODEX_LIVE_MODEL_TEST=1 \
LOCALCODEX_LIVE_MODEL_ID=lmstudio-community/Qwen3.5-4B-MLX-4bit \
  swift test --filter LocalQwenLiveTests/testProductionRuntimeExecutesReadOnlyComputerTool
```

The V2 desktop gates are separate, explicit opt-ins. Set `LOCALCODEX_LIVE_MODEL_ID` to the installed model being checked and run one model at a time; the Chrome gate requires an explicit model ID. It opens a unique `https://example.com/` URL, reads the bound Chrome Accessibility tree, and checks the nonce URL and page heading independently. The Calculator gates observe the bound app, approve a single digit-1 `AXPress`, or approve one image-coordinate click only if its resolved point lies inside the independently measured digit-1 button. They also inspect the resulting Calculator display. These gates do not exercise the blocked historical browser fixture:

```sh
LOCALCODEX_LIVE_CHROME_V2_READ_TEST=1 \
LOCALCODEX_LIVE_MODEL_ID=lmstudio-community/Qwen3.5-4B-MLX-4bit \
  swift test --filter ChromeV2LiveTests/testBoundChromeReadOnlyV2WithSelectedModel

LOCALCODEX_LIVE_SEMANTIC_COMPUTER_TEST=1 \
LOCALCODEX_LIVE_MODEL_ID=lmstudio-community/Qwen3.5-4B-MLX-4bit \
  swift test --filter LocalQwenLiveTests/testProductionRuntimeObservesBoundCalculatorWithV2

LOCALCODEX_LIVE_CALCULATOR_MUTATION_TEST=1 \
LOCALCODEX_LIVE_MODEL_ID=lmstudio-community/Qwen3.5-4B-MLX-4bit \
  swift test --filter LocalQwenLiveTests/testProductionRuntimePressesCalculatorDigitOneWithV2

LOCALCODEX_LIVE_VISUAL_CALCULATOR_TEST=1 \
LOCALCODEX_LIVE_MODEL_ID=lmstudio-community/Qwen3.5-4B-MLX-4bit \
  swift test --filter CalculatorVisualV2LiveTests/testModelClicksCalculatorDigitOneFromDisplayCapture
```

The historical semantic and visual Chrome fixture tests are retained as V1 evidence but now skip unconditionally. They use a blocked local file-URL fixture and the persisted legacy `computer` schema; do not invoke them as V2 acceptance tests.

Normal test runs compile the live cases but skip external model and desktop work. The presence of a live test is not evidence that it passed.

The live gates parse the isolated App Server rollout for model-level `function_call` and matching `function_call_output`, and enable a test-only recorder for exact newline-delimited App Server frames. They check matching call IDs and successful client responses. For each call, both `item/started` and `item/tool/call` must precede that response, with `item/completed` afterward; App Server can emit the first two in either order. The shipped app leaves its recorder disabled so LocalCodex does not make a second copy of prompts or tool payloads. Historical Chrome gate evidence below applies only to V1; it is not V2 proof.

## Verification status

The following results are historical V1 verification records from September 23, 2026. They are not proof that a new V2 thread or a rebuilt application has passed the same desktop gates:

- successful Swift Package and native Xcode application builds;
- the separate opt-in production-runtime test passing against LM Studio, including an exact `LOCAL_QWEN_OK` assistant entry, task status `Completed`, and the corresponding Web UI snapshot;
- a production-runtime turn using the legacy `computer` tool's read-only `permission_status` action and returning the expected completion token;
- primitive-level proof for that same live turn across all three transport layers: the persisted model `function_call`/`function_call_output`, exact App Server stdio frames, and the two real LM Studio `/v1/responses` SSE exchanges captured on loopback;
- exact call-ID continuity from LM Studio's streamed function call, through App Server's `item/tool/call` and native result, into the continuation request and final streamed `LOCAL_COMPUTER_TOOL_OK` response;
- the semantic Chrome gate passing in 83.418 seconds with `open → snapshot → ax → snapshot`, call IDs `call_1293236275110009` through `call_1293236275110012`, and final snapshot token `LOCALCODEX_CHROME_OK_002BB3D4C85F4AFBAA6914E223BB5D19` present in both rollout and raw App Server results;
- the visual Chrome gate passing in 273.905 seconds with exactly `open → capture → click → snapshot`, call IDs `call_1293236275110013` through `call_1293236275110016`, one valid PNG at both validated layers, a click inside the independently measured fixture-button frame, and final snapshot token `LOCALCODEX_CHROME_OK_F2A624DDE65F413EB5CB7DB18E360F0C`;
- the previously installed hardened signed app (binary SHA-256 `c93d16fa5124001c8a4ab07c557aa774aaed0292e54f92aebe5ae9626f188bc1`) completing a manually approved semantic Chrome turn with `open → snapshot → ax` (`AXPress`) `→ snapshot`, call IDs `call_1293236275110045` through `call_1293236275110048`: the final model-visible Chrome snapshot identified bundle `com.google.Chrome`, and it and an independent native Chrome Accessibility read both contained `HARDENED_INSTALLED_AX_OK_C93D16FA`; LocalCodex reached `Completed` with that token as its final answer;
- the Octane sidebar, transcript, composer, inspector, settings, and light/dark appearance rendering inside the native WebKit window;
- initialization of the installed Codex App Server over stdio;
- an App Server `thread/start` accepting the `lmstudio` provider, configured Qwen model, workspace sandbox, approval policy, and compact legacy `computer` dynamic-tool schema;
- App Server thread listing, persisted-thread resumption, event mapping, and fail-closed approval handling in the native client;
- the exact Qwen model downloaded, indexed, and visible through LM Studio's OpenAI-compatible model endpoint;
- the loaded MLX runtime reporting one parallel request and a 4,096-token context;
- direct `/v1/responses` inference completing with the exact visible answer `LOCAL_QWEN_OK`;
- an otherwise exact Codex-shaped request, including the legacy computer-tool schema, completing after the model-template compatibility filter;
- a fresh task in the packaged native release completing end to end with the visible assistant text `LOCAL_QWEN_OK`, task status `Completed`, and the assistant event selected in the inspector;
- approval decisions round-tripping only from the native Swift gate back to App Server, with stale/replaced requests rejected;
- a bundle-only custom URL scheme, production CSP with network connections disabled, no shipped source maps, and no production demo-state fallback;
- bounded, tamper-checked Accessibility snapshots and approval-gated semantic, pointer, and keyboard actions;
- targeted semantic searches scanning up to 1,000 bounded source elements while keeping the formatted result within a 1,000-character local-model budget.

That V1 baseline Xcode suite had 116 total tests: 112 deterministic tests passed, four external model/desktop gates skipped by default, and zero failures. The Bun typecheck, production UI build, and signed universal Xcode Release build also passed. Both historical Chrome gates were run against the V1 production runtime; the installed-app semantic turns were separate, human-approved V1 runs.

For V2, the production-runtime `computer_v2_status({})` gate passed with all three installed models (27B, 9B, and 4B), including matching rollout and raw App Server call IDs. A stricter Chrome gate that uses a fresh URL nonce and independently checks the page heading passed with 4B and 27B; the corrected 27B raw-lifecycle rerun passed in 117.343 seconds. In 9B, the same Chrome actions and observations completed, but the strict gate failed because the final answer included extra prose rather than its exact token. These are per-run results, not a reliability rate or proof of a signed installed V2 build.

That earlier warnings-as-errors Swift suite passed: 71 LocalCodex tests (eight opt-in live tests skipped by default) and 104 AutomationCore tests, with no failures. The Bun TypeScript check and production UI build passed. That universal Release build was installed at `/Applications/LocalCodex.app`; its strict/deep signature verified under Ahmed's Apple Development identity with hardened runtime, and its executable SHA-256 was `93ff180f124bde6d2b9000072ffb6560523bb86c3b5382567b84d416b883e741`. The preceding installed app was moved to `../work/LocalCodex-before-v2-2026-09-23.app` for recovery.

In the installed V2 app, a fresh 4B task completed one `computer_v2_status({})` call, reported Accessibility and Screen Recording as granted, and returned the exact `LOCALCODEX_INSTALLED_V2_STATUS_OK` token. A second fresh 4B task received native approval for one public `https://example.com/` URL with a unique nonce, completed `computer_v2_open → computer_v2_snapshot`, and returned `LOCALCODEX_INSTALLED_CHROME_V2_OK_830C9F3A`. An independent Chrome Accessibility read found the same nonce URL in the address bar and the `Example Domain` page heading. This is an installed-app V2 read/launch pass, not a visual-click pass.

The earlier model-selected-coordinate Calculator V2 visual-click gate did **not** pass with any model. Observed 4B and 9B image points were outside the independently measured digit-1 frame. Both were denied; after correcting a test-only reporting race, the 9B rerun showed its denial reaching App Server with no click posted. The 27B visual attempt was aborted after a malformed first call and a later capture without a click. Separately, the 27B semantic-`AXPress` gate passed its strict rerun in 515.696 seconds: the exact four-call sequence and final token completed, and an independent Accessibility read verified the Calculator display changed from `11` to `111`. The lengthy turn included context compactions. This was the earlier visual-only baseline, before the combined observation and visual-grounding sidecar below.

The [2026-09-23 Codex app/CUA runtime audit](../outputs/LocalCodex-Codex-app-CUA-runtime-audit-2026-09-23.md) compared Codex's live `cua_repl`/signed service/Chrome extension path with LocalCodex's Swift V2 host. LocalCodex now offers opt-in `computer_v2_capture({"include_accessibility":true})`, which retains a synchronized AX snapshot alongside its PNG while keeping screenshot-only capture unchanged. Compact AX lines include screen-point frames. Both Qwen3.5-4B and 9B performed the approved Calculator `AXPress` from a combined capture and independently changed the display; 4B passed 1/1 strict run, while 9B passed 1/2 strict final-format checks and 2/2 functional actions. A live 4B `turn/interrupt` gate passed, and the UI now exposes Stop for Running tasks. The full Swift suite, Bun check/build, strict code signature, and installed-app Stop check passed. That audit's installed universal executable SHA-256 was `316b3449384ce795587d41c4c5360e213d5e07a7aadd191251cbcf42e6e3d2ae`; its predecessor is preserved at `../work/LocalCodex-before-cua-runtime-2026-09-23.app`. The signed archive was `../outputs/LocalCodex-macOS-CUA-runtime-2026-09-23.zip` (SHA-256 `5ae56ae4c83a012a0fec8c910d683c45b9f3b83217ac669364dc7f5c44ee171f`). No 27B model was used in that audit.

The subsequent browser-benchmark build is now installed at `/Applications/LocalCodex.app`. Its universal executable SHA-256 is `6eb14344924ea033c89d39ec3076cecaa91069c8d13c133fd9cf88bf1d089b4f`; the preceding installed build is preserved at `../work/LocalCodex-before-browser-benchmark-2026-09-23.app`. The exact installed app reported Accessibility and Screen Recording **Granted**, then a fresh 4B task completed exactly one `computer_v2_status` tool row and the final token `INSTALLED_BROWSER_BENCHMARK_STATUS_OK`. Its signed archive is `../outputs/LocalCodex-macOS-browser-benchmark-2026-09-23.zip` (SHA-256 `d3dca9b11cb5fdb75c3d1c76e57a2f764c7c12a989e3f66145a32283d450fa92`).

Two additional 4B public-page Chrome probes after the audit changes were **not** strict passes. In one, Chrome lost focus before LocalCodex's AX snapshot, so the runtime failed closed. In the other, App Server recorded a successful `open → snapshot` sequence and completed the turn, but the independent post-turn verifier found Chrome was no longer frontmost. These focus-sensitive results reinforce the remaining need for a tab-bound browser driver; they do not show a model/tool-schema regression.

The native visual-grounding production worker passed its final retained 91-instance fixture replay on September 24, 2026: 90 accepted points landed inside the exact expected boxes, and the remaining exact case failed closed with `no_pair_agreement`. ShowUI ran on 29 disagreements. End-to-end worker-request latency was 1.200 seconds p50 and 2.603 seconds p95; process launch through verified load and warm-up readiness was 8.441 seconds. These are one serial pass over 13 target intents repeated across seven variants of one synthetic application, so they establish the highest observed single-pass accuracy on this fixture rather than general computer-use reliability. See [`Benchmarks/VisualGrounding/README.md`](Benchmarks/VisualGrounding/README.md) for the exact method and timing boundaries.

The final opt-in 4B Calculator grounding gate then passed end to end in 25.753 seconds. Qwen issued exactly `open → capture → ground_click → snapshot`; the sidecar's selected point was independently inside Calculator's digit-1 AX frame, the runtime revalidated the full window and approval boundary, Calculator changed from `0` to `1`, rollout and raw App Server call lifecycles matched, and owned App Server/worker cleanup succeeded. A preceding attempt failed closed because a stale system Screenshot overlay covered the action point; no click occurred. Closing that exact overlay and rerunning produced the pass. This is one live capability run, not a reliability rate.

## Current limitations

- New tasks expose native `computer_v2_*` tools, not the App Server's shell or built-in coding/editing tool set. LocalCodex is a local chat and desktop-automation client, not a shell-capable coding agent.
- Chrome URL tasks use a separate temporary profile. The broker does not attach to the user's ordinary signed-in Chrome profile or import its existing tabs, cookies, credentials, or extensions. This is not full Codex CUA/browser parity. Brokered tasks within one runtime reuse that runtime's owned process/profile. Task-scoped handles restrict broker calls, not shared-profile cookies, storage, same-origin scripting, or site-triggered cross-tab effects.
- Brokered actions use DOM click/value operations, not general trusted keyboard/pointer input. Text entry rejects read-only controls; mutations reject disabled, inert, detached, non-main-document, or unsupported controls. Browser screenshot/coordinate/keyboard support remains disabled. The visual-grounding cascade is a native-window fallback and does not add browser visual control.
- Loader/URL comparisons detect observed document changes, not every possible intervening navigation. Same-document changes that return to the previous URL between reads and arbitrary semantic changes between the final AX read and browser execution require a persistent event/DOM invalidation design for stronger guarantees. Local DevTools clients remain inside the trust boundary; loopback, origin checks, and a private profile directory are not authentication against other local processes. Terminal task cleanup revokes its lifetime before asynchronous exact-target closure. Explicit runtime shutdown stops its owned App Server and isolated Chrome process groups, reaps their roots, and removes owned profiles after observed group exit. Shutdown has bounded waits and reports incomplete cleanup; the app termination delegate also has a ten-second reply deadline. Force quit, host failure, or descendants escaping their created process group are not covered by an unlimited cleanup guarantee. The bootstrap blank tab is retained during use rather than closing unrelated blank or loading tabs by URL.
- This Mac also has Codex's richer installed `cua_repl`/computer-use stack, but LocalCodex does not load or copy it. Only project-owned clean-room tools are exposed to Qwen.
- The historical semantic and visual smoke turns proved V1 model/runtime paths on the controlled Chrome fixture; they do not establish V2 performance or reliable tool selection on arbitrary interfaces.
- The focused-window screenshot reduces visible image size, but a visual grounder is still probabilistic. The agreement threshold, whole-window freshness checks, native approval, and post-action verification reduce risk; they do not establish reliability on arbitrary apps, targets, display scales, or instructions.
- The previously signed installed app passed separate `open → capture → snapshot` and natively approved `open → snapshot → AXPress → snapshot` Chrome turns, both ending `Completed`. Screen Recording was **Granted** for that app. The screenshot turn took 540 seconds; this capability result was not a speed benchmark. The coordinate-click path was separately validated in the V1 production-runtime test host, not repeated in that installed binary.
- App Server persists a task's dynamic-tool schema when that task is created. Existing V1 threads retain `computer`; start a new task to receive `computer_v2_*` after upgrading.
- The App Server executable path, LM Studio provider, and initial workspace are currently fixed in code; the default model is selectable in Settings.
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
