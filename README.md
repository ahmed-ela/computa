# Macndash - you deserve faster mac use 

Private repository: [ahmed8372/heydash](https://github.com/ahmed8372/heydash).

HeyDash is a clean-room macOS desktop-agent client with its own source-pinned build of the open-source Codex App Server. Its signed Swift host owns the agent runtime and macOS permissions, while a compiled Octane interface renders in the system `WKWebView`. It recreates the shape of a local Codex-style desktop experience without copying the Codex GUI, private source, or application assets. It does not modify or launch the App Server inside an installed Codex/ChatGPT app.

The project has moved beyond a static UI shell: it launches an isolated App Server over stdio, loads and resumes local-model threads, starts turns, streams thread/turn/item updates into the transcript, presents native approval requests, and exposes a versioned clean-room computer-use contract for desktop observation and control.

## Rename compatibility

HeyDash was previously named LocalCodex. The app, executable, Swift module, Xcode project/scheme, and source/test directories now use HeyDash. To preserve existing installations, the signing team and bundle identifier (`com.ahmedelamin.LocalCodex`), Application Support directory (`~/Library/Application Support/LocalCodex`), and saved model preference (`LocalCodex.defaultModelID`) are deliberately unchanged. No settings, conversations, or downloaded visual-grounding models are moved or reset.

The internal `localCodex` WebKit bridge, `localcodex-app` resource scheme, `local_codex` App Server source identity, `LOCALCODEX_*` environment variables, fingerprint domains, and benchmark schema/result identifiers also remain stable. Dated verification records retain their original artifact names and hashes. These compatibility names are not current product branding.

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
HeyDash.app/Contents/Resources/AgentRuntime/codex-app-server
  --listen stdio:// (verified app-owned artifact)
          │
          ├── app-owned headless MLX-VLM process (loopback only)
          │     lmstudio-community/Qwen3.5-4B-MLX-4bit (default)
          │     lmstudio-community/Qwen3.5-9B-MLX-4bit (optional)
          │
          └── HeyDash dynamic tools: computer_v2_*
                ├── AutomationCore (AppKit, Accessibility, ScreenCaptureKit)
                └── native visual fallback (external pinned MLX worker)
```

The Octane/WebKit layer owns ordinary presentation. `CodexAppServerRuntime` translates App Server requests and notifications into the typed task, status, timeline, and connection events consumed by `AppState`. A narrow native bridge sends revisioned, data-minimized snapshots to the page and accepts only validated UI actions; it never exposes Accessibility or ScreenCaptureKit directly. Privileged approval decisions remain in native Swift: the approval overlay in Ask every time, or AppState's automatic resolver in Full access. They are never accepted from JavaScript. App Server remains responsible for the agent loop, thread state, sandbox selection, approval requests, and model-provider integration. HeyDash deliberately removes unrelated built-in tools, plugins, memories, skills, and MCP configuration from its constrained local-model turns.

New tasks default to `lmstudio-community/Qwen3.5-4B-MLX-4bit`. Settings can change the persisted default for new tasks, and the composer selector can change an individual idle task's model. The selected model ID is sent to App Server on thread start, resume, and turn start; existing threads keep their recorded model unless explicitly changed. Historical 27B/35B catalog entries and saved preferences are preserved, but the owned MLX backend rejects unsupported models explicitly instead of silently substituting one. Other turn defaults are:

- model provider identifier: `lmstudio` (retained for saved-thread compatibility; the default endpoint is now owned MLX, not LM Studio);
- workspace: the app-owned `~/Library/Application Support/LocalCodex/CodexHome/Workspace`;
- sandbox: `workspace-write`;
- approval policy: `on-request`;
- reasoning effort: `medium`;
- declared context window: 4,096 tokens for 27B/35B (automatic compaction at 3,072), or 16,384 for 9B/4B (compaction at 12,288);
- isolated App Server home: `~/Library/Application Support/LocalCodex/CodexHome`;
- persistent App Server threads (`ephemeral: false`).

The private `CODEX_HOME` keeps existing HeyDash chats separate from personal Codex chats. It is not sufficient by itself to isolate configuration: a Documents workspace inside a home Git repository could previously discover the ancestor `.codex/config.toml` and `AGENTS.md`. HeyDash now launches in its private workspace with `project_root_markers=[]` at both process and thread boundaries. The engine child's `HOME` is its private `CodexHome/ProcessHome`, preventing global `.agents` skill imports; the native app and real macOS home are unchanged. It forwards only explicit home paths, a system PATH, temporary-directory/locale settings, and the selected local inference endpoint; it does not forward ambient Codex routing variables, API keys, proxies, or startup hooks. Login-shell initialization and shell snapshots are disabled for this shell-tool-free engine. Auth stores are file-backed inside the private home, not shared desktop credentials. This is application configuration isolation, not an OS sandbox.

The compact base instruction is under 1 KiB. HeyDash additionally supplies its own bundled developer instructions on new and resumed chats, including the **complete unchanged StudyLock non-bypass policy**. No protected source or enforcement state is removed or altered. The policy governs StudyLock enforcement only; it does not turn HeyDash into a StudyLock-only assistant or establish that an unrelated page is blocked. Saved chats and their history remain intact; restarting the app applies the owned instruction boundary on resume. Updates to bundled instructions require a new build/restart, not live editing of another application's configuration. Machine-managed/system-wide engine policy is not bypassed by these app settings.

## Application surface

- searchable task sidebar backed by App Server threads;
- user, assistant, reasoning, system, and tool-event transcript rows;
- bottom-anchored prompt composer: Enter sends, Shift+Enter adds a newline;
- native per-task follow-up queue with drag/keyboard reorder and an Edit/Delete/Steer menu;
- model selector for each idle task and a persisted default for new tasks;
- optional Octane inspector for the selected task and event, closed by default;
- Octane settings modal with system, light, and dark appearance;
- connection and macOS automation-permission status;
- a native approval gate with explicit **Allow Once** and **Decline** decisions in Ask every time;
- accessible labels and keyboard actions;
- sample/state injection support for isolated development and tests.

### Follow-up queue

Sending while a turn is busy queues the prompt for the same task. A successful
turn completion dispatches the next message once; stopping, disconnecting, or
failing pauses the queue. Resume is explicit, and unconfirmed delivery stays
visible for review rather than automatically retrying. Editing holds that item
until Save or Cancel, and a message already being sent cannot be changed.
Queued messages are app-session-local: keep HeyDash open until they are sent.

Steer delivers a queued message into the current turn using the App Server's
[`turn/steer` contract](https://learn.chatgpt.com/docs/app-server#steer-an-active-turn).
It requires an exact active turn ID and a matching acknowledgment; it never
silently starts a new turn or interrupts the current one. Steering is unavailable
while a native approval is pending and does not bypass approval or undo actions
already performed. An unconfirmed steer remains in the paused queue.

### Context and access

The native status bar uses a SwiftUI circular Gauge for the selected task's
context. It displays App Server's **last request** token usage, never cumulative
token consumption or the model's advertised maximum. Missing measurements and
post-compaction usage remain unknown until the runtime reports fresh data.

Automatic compaction is performed by the app-owned App Server with the same local
model and the native default summarization instructions. It does not run a second
summarizer, add experimental summary instructions, delete transcript messages, or poll the
conversation. The trigger is 75% of the configured context budget: 12,288 of 16,384
tokens for Qwen 4B/9B, and 3,072 of 4,096 for the constrained model profiles. This
leaves 25% of the nominal budget for new input, tool results, and summary
generation. The runtime can report a smaller effective window (for example,
15,564 for a 16,384 configuration); the ring honors that reported limit. It is a
conservative policy, not a guarantee that arbitrarily large individual inputs
will fit. Summaries are lossy; the full transcript remains visible. Queue
dispatch waits for the enclosing turn to finish, and failure pauses the queue.

Idle automatic compaction is serialized before sending the next unchanged user
prompt. It preserves a bounded excerpt of the latest genuine completed assistant
reply, at assistant authority, after the native summary completes. Queue dispatch
waits for that durable append. Cold resume correlates native usage with the exact
latest completed turn; absent or invalid usage triggers conservative compaction
instead of assuming an empty window. Short tasks with valid usage avoid that
extra model call. No extra summarizer, saved-token estimate, or history polling
is introduced.

During an active turn, the app-owned runtime patch atomically retains bounded
genuine function-call/result pairs before continuation. It also keeps bounded
prior assistant replies beside uniquely matched historical user messages, so old
requests retain their answer boundaries. Retained tool-output images are omitted
with an explicit fresh-capture notice; malformed, unsupported, or oversized receipts fail with a
visible error instead of continuing without action history. No action is replayed
or implicitly approved. See `Runtime/README.md` for exact bounds and provenance.

Model fidelity is not perfect: stress tests found stale responses, exact-key
copying errors, and a repeated status request after native within-turn compaction.
The idle-history repair fixed the captured stale-response case. The final owned
runtime passed four of five unchanged strict end-to-end samples: all four runs
that reached within-turn compaction passed; one failed on Qwen instruction
following before compaction occurred. Neither repair makes summaries lossless or
guarantees Qwen will never repeat a step. Strict diagnostic
assertions remain in `RuntimeContextLiveTests` and
`RuntimeAutomaticCompactionPathsLiveTests`; manual compaction is not exposed in
the UI. See `Benchmarks/CONTEXT-RETENTION-2026-09-24.md` for recorded outcomes.

The runtime may retain user messages that exceed this local model budget.
HeyDash interrupts the exact turn if the post-compaction estimate still exceeds
the effective window, or repeated compactions make no forward progress. It
revokes that turn's computer capabilities immediately and keeps the task busy
until the runtime confirms termination. The user can then shorten the input or
start a new task; HeyDash never silently deletes retained instructions to make
them fit. Diagnostic estimates are not displayed as measured ring occupancy.

Access is deliberately simple and is changed only through a **native macOS
menu**, not a web bridge action or model tool:

- **Ask every time** (default): each protected action requires its own native
  approval. Read-only inspection does not prompt.
- **Full access**: native action-approval requests are approved automatically.
  Tool validation, stale-target checks, sandbox rules, macOS permissions, and
  StudyLock restrictions are unchanged. This is not a grant of macOS permissions.

The mode applies to all tasks and is remembered across app launches. A missing
or invalid saved preference defaults to Ask every time. Switching back cannot
undo an action already dispatched.
An automatic approval failure is shown as “Action paused” and is not retried in
a loop; switch to Ask every time to review or decline it.

The separate native **Connect Chrome** control grants a revocable connection
to the already-running, ordinary Chrome session. It requires an idle runtime and
an explicit confirmation even in Full access. Chrome Remote Debugging must be
enabled by the user, and Chrome may show its own Allow prompt. If macOS denies
the connection-file read, check **Files & Folders → LocalCodex (or HeyDash) →
Google Chrome**. That OS permission covers Chrome's app-data directory; HeyDash
reads only `DevToolsActivePort`, not cookies or other profile files. Full Disk
Access is not required. Disconnect revokes consent immediately, including while
a connection is pending; quitting ends the live connection. **Connect & Remember**
(or **Reconnect automatically…** for an already connected session) explicitly
authorizes one reconnect attempt on each launch, when the runtime is idle and the
same Chrome app/profile is already running. Only that approved scope is saved;
process IDs, ports, endpoints and live consent tokens are never persisted. The
first message waits for a pending reconnect. Chrome/macOS approval remains
required if requested. **Disconnect Chrome** also forgets the saved choice;
**Forget automatic connection** leaves the current session connected but disables
future reconnection. Missing, changed, or invalid scope fails closed without
launching Chrome, changing permissions, or retrying automatically.

## Native computer tool

New tasks register action-specific `computer_v2_*` dynamic tools backed by the clean-room `AutomationCore` Swift target. The schemas describe each call, and Swift validates every field before dispatch because the local model server can accept malformed arguments despite a `required` schema. The legacy `computer` dispatcher remains only for threads that persisted its older tool schema:

| V2 tools | Behavior |
| --- | --- |
| `computer_v2_status`, `computer_v2_apps` | Read macOS authorization state or list running applications. |
| `computer_v2_tabs`, `computer_v2_bind_tab` | With an explicitly connected Chrome session, list a bounded page of tab metadata and bind an observed opaque candidate token. Follow `next_cursor` until null for a complete inventory. Tokens belong to this task turn and connection; binding does not activate, navigate, or close the tab. |
| `computer_v2_open` | Launch and bind an application by bundle identifier. Chrome defaults to the user's normal session and logins; omit `url` to inspect its current tab, or supply a URL to open a new tab. `browser_mode: "isolated"` explicitly selects the separate project-owned profile and exact task-scoped tab. |
| `computer_v2_snapshot` | Return a bounded semantic Accessibility tree for the bound native app or exact brokered Chrome tab, with snapshot-scoped element indices. |
| `computer_v2_ax`, `computer_v2_set_text` | Perform a checked semantic action on a current inspected native element or exact brokered-tab element. |
| `computer_v2_capture` | For native apps, return a PNG of the focused, bound app window with a `capture_id` and image dimensions. The runtime retains a separate downscaled display baseline for target and occlusion checks. Brokered Chrome tabs reject this tool. |
| `computer_v2_ground_click` | For supported local models, ground a concise target description in the current native-app capture, require agreement between independent visual grounders, request approval for the resolved click, and return a fresh verification-only post-action screenshot with synchronized Accessibility when available. Brokered Chrome tabs reject this tool. |
| `computer_v2_click`, `computer_v2_pointer` | For native apps, use image-pixel coordinates from that capture. The runtime maps them to screen points and checks the bound window before move, double-click, right-click, or scroll. V2 drag and brokered-tab pointer input are unavailable. |
| `computer_v2_keypress`, `computer_v2_type` | For native apps, send approved keyboard input only while the exact observed window and focused control still match. Brokered Chrome tabs reject these tools. |

All mutations use the native approval controller: Ask every time waits for a human decision; Full access automatically resolves valid requests. The V2 executor binds the launched app to its task and rechecks its process, bundle, and inspected target across approval; native input also retains the existing focus checks. The model need not repeat a process ID on every call. `computer_v2_open` keeps its ordinary Chrome native Accessibility/capture/input route, excluding custom-data-directory and command-line remote-debugging instances. The separately approved connection exposes `tabs` → `bind_tab` → semantic snapshot/action tools for exact background tabs. It validates the selected process, connection-file generation and loopback listener at connection and wire admission. Ambiguous or unreadable identity fails closed instead of guessing. No cookies, credentials, or profile files are copied, and normal Chrome remains user-owned during shutdown.

Borrowed-tab inventories are capped at 12 KiB of encoded JSON per page, with
UTF-8-safe title truncation and explicit omission of oversized URLs; shortened
URLs are never presented as navigable addresses. Native binding metadata stays
intact. Two turns cannot reserve the same target concurrently. Cancellation
revokes the original turn and detaches its original session, never closing a
user-owned tab or browser. Borrowed semantic reads/actions do not take the global
desktop-input lane. Browser screenshot, coordinate and keyboard tools remain
unavailable; actions still need fresh snapshots and normal native approval.
This routing is not yet evidence of real-Qwen accuracy or concurrent-user
non-interference; those live qualifications remain pending.

Only an explicit `browser_mode: "isolated"` Chrome URL launches a project-owned profile with a random loopback DevTools port and no wildcard-origin override. It retains an opaque task-scoped handle and changes the document epoch when observation detects a changed main-frame loader or URL, including its fragment. Semantic reads and actions address that exact target without explicitly foregrounding it. The broker rejects overlapping operations for a task, consumes a valid mutation snapshot before awaiting transport, and rechecks that a revoked handle has not disappeared before publishing an observation or preparing input. The transport repeats document and element checks on its mutation connection, resolves the node into a main-frame isolated JavaScript world, and checks document membership, URL, connection, and control state in the synchronous mutation function. Revocation and the one-shot WebSocket enqueue share a lock: revocation that wins before enqueue prevents that command; a command already enqueued cannot be recalled. These checks are not an atomic lock on the browser DOM or a record of all intervening navigation events. Coordinate capture, pointer, and keyboard calls intentionally fail closed for brokered tabs; native-app AX and guarded screenshot paths remain separate. A semantic mutation requires the current snapshot UUID and element index; pointer input requires a current `capture_id` and image-space coordinates. The runtime maps those image pixels to global screen points and rejects stale or changed native windows and targets. A consumed observation must be replaced with a fresh snapshot or capture to verify the result. Window capture is read-only and does **not** present a per-screenshot native approval gate: once macOS Screen Recording access is granted, a local model turn can request native-window captures while HeyDash runs.

HeyDash remains semantic-first: it uses native Accessibility or the brokered browser DOM whenever those surfaces expose the intended control. `computer_v2_ground_click` is the native-app screenshot fallback for the 4B and 9B Qwen options, which leave enough memory headroom for a resident visual sidecar on this 24 GB Mac. The runtime starts preparing that sidecar in the background when a supported-model turn begins so model planning can overlap model load and warm-up. GoClick and GUI-Owl 2B run on every request; ShowUI 2B runs only when either result is missing or the two disagree. The worker returns only parsed normalized points and diagnostics. Swift independently selects the closest pair, requires that pair to agree within 3% of the screenshot diagonal, uses their midpoint, and otherwise fails closed without presenting a click approval. The entire window is recaptured and fingerprinted after inference and again after approval, so a grounded click cannot use a capture whose surrounding context changed. After dispatch, the same tool returns a fresh verification-only screenshot with synchronized Accessibility when available. That observation intentionally has no reusable `capture_id`, so it cannot authorize another pointer action. An observation failure is reported as post-action uncertainty rather than as a failed click that might be repeated. The 27B and 35B model options do not register this resident sidecar tool on this machine.

Browser approvals include `observed_page_url` from the immutable retained browser snapshot, in addition to the bundle, PID, handle, and epoch. No title is inferred from page-controlled labels or parsed out of formatted text. URL display does not replace post-approval document and node revalidation. Runtime-owned lifetimes also cover targets still being created: terminal cleanup can synchronously revoke a pending open or mutation before scheduling network cleanup.

The opt-in model-free production broker gate is `CuaV2SafeChromeSemanticLiveTests/testProductionBrokerMutatesOnlyBackgroundTabAndShutsDown`, enabled with `LOCALCODEX_LIVE_CHROME_BROKER_PRIMITIVE_TEST=1`. It uses an inline, nonce-restricted loopback fixture, same-title tabs, independent acknowledged page telemetry, a retained-snapshot reuse refusal, and process-group/profile-marker cleanup checks. It does not start App Server or LM Studio and does not request a HeyDash approval. The ordinary semantic and same-title model gates honor `LOCALCODEX_LIVE_MODEL_ID` for the supplied 4B/9B IDs. Their capability deadline is 180 seconds; the 30-second performance SLO is reported separately and does not terminate a capability trial. Every gate prints `BROWSER_GATE_ARTIFACT_DIR`; set the absolute `LOCALCODEX_LIVE_ARTIFACT_DIR` to choose a durable root. Model wire traces and result/cleanup records are retained there. Model-run JSON records use schema version 8, with separate functional, protocol, harness/model-failure, active-tab, global-application-focus, and owned-cleanup outcomes. The model gates await independent successful-press proof before the tool response and normal terminal tab closure; B can also be checked after the turn. No new gate result is claimed here.

Permission onboarding is explicit. AutomationCore can read permission state without prompting, and only the human-operated **Request access** buttons in HeyDash Settings call the macOS permission-request APIs. A button press is not proof of a grant: on this macOS 27 installation, Screen Recording returned denied without a system prompt. If the request remains denied, HeyDash opens **System Settings → Privacy & Security → Screen & System Audio Recording** when that pane link is available, or opens System Settings as a fallback, so the user can add and enable the app in the screen-recording list, not the audio-only list. Relaunch HeyDash after granting access, then refresh its Settings status. Permission-dependent tool calls fail closed when authorization is absent; the local model cannot grant or request access itself.

## Prerequisites

- macOS 14 or newer;
- Xcode with a Swift 6.2-capable toolchain (the Swift Package manifest uses tools version 6.2);
- XcodeGen when regenerating the Xcode project (`brew install xcodegen`);
- the app-owned Agent Runtime built from the pinned source and patch below (Rust 1.95 and Bun are build-time requirements only);
- for live inference, the pinned local MLX-VLM Python environment and existing Qwen 4B/9B MLX weights described below; LM Studio does not need to run;
- for native visual grounding, `uv` plus approximately 4.0 GB for the three pinned model directories and 0.6 GB for their isolated Python runtime;
- Accessibility permission for semantic inspection and native input, plus Screen Recording permission for window capture. Use **Settings → Computer use → Request access** or the applicable macOS Privacy & Security pane, relaunch after granting Screen Recording, then verify that the app reports **Granted**. On this macOS 27 installation, Screen Recording needs manual registration in System Settings.

The default is [Qwen3.5-4B MLX 4-bit](https://huggingface.co/lmstudio-community/Qwen3.5-4B-MLX-4bit/tree/main), about 3.06 GB of model files. [Qwen3.5-9B MLX 4-bit](https://huggingface.co/lmstudio-community/Qwen3.5-9B-MLX-4bit/tree/main), about 5.98 GB, is also supported by the headless backend. These are file sizes, not total unified-memory requirements. Saved 27B/35B choices are preserved, but explicitly require an external backend; they are never silently replaced with 4B. The optional 35B build was not downloaded. Historical LM Studio results below do not establish current headless performance or reliability.

## App-owned headless MLX

HeyDash starts one loopback-only MLX-VLM process on `127.0.0.1:1237` and stops it with its owned runtime. The process also watches its parent so an app crash does not intentionally leave a model daemon running. There is no LM Studio GUI, extra proxy process, or cloud inference. The native App Server still handles the agent loop, tools, approvals and conversation storage; MLX handles model inference and images.

This machine reuses `~/Library/Application Support/LocalCodex/VisualGrounding/venv/bin/python` (MLX 0.32.2 / MLX-VLM 0.7.1) and the existing model folders under `~/.lmstudio/models/lmstudio-community/`. No copy or re-download is performed. These legacy paths and model/provider IDs preserve saved tasks; they are not a dependency on a running LM Studio app. Startup checks the pinned environment and local weights and fails explicitly if they are missing. Do not upgrade the shared visual-grounding environment independently.

The initial profile uses one sequence, a 16,384-token context, at most 4,096 generated tokens, a 512-token thinking allowance, 512-token prefill chunks, and one vision-cache entry. The thinking allowance bounds reasoning before the closing marker; it is not a claim of unchanged model accuracy versus unrestricted thinking. Automatic prefix/disk caches and response-history storage are disabled. MLX's reusable allocation cache is limited to 256 MiB and its allocation limit to 10 GiB; neither is a cap on whole-system RAM or the entire process. Weights load lazily and remain warm until runtime shutdown; visual grounders have a separate lifetime and memory footprint.

Each inference process is pinned to its first valid model request. Changing between 4B and 9B retires and reaps that owned process before starting a fresh one, preserving the App Server and conversation. This avoids the pinned upstream loader retaining old weights while loading the replacement. A switch has cold-start cost; it is not an in-memory hot swap. Native turns, submissions, compaction and tool work must be idle before switching. The owned backend reserves one inference lane across tasks; a competing task gets an explicit busy result, not a hidden provider queue or an interrupted active task.

The bundled boundary preserves streaming text, function call identities and inline image results while correcting pinned upstream final-text/unfinished-reasoning inconsistencies. It withholds executable final calls until terminal validation, reports exhausted output as incomplete, and maps only the known context-overflow error to the typed error used by App Server recovery. Inputs remain full-history `store:false`; browser origins, arbitrary model paths, remote/file image URLs and concurrent queued work are rejected. This is a local process boundary, not an OS sandbox.

Deterministic tests are in `Tests/MLXServer/`; transport probes and their measured limitations are in `Benchmarks/MLXServing/`. Native live tests select this backend only when `HEYDASH_LIVE_OWNED_MLX_TEST=1` is explicitly enabled; other historical live gates retain their external-server configuration unless their source says otherwise. Use `TEST_RUNNER_` before that variable when launching tests with Xcode. A source default or a passing synthetic probe is not proof an installed app has been updated.

See [the migration validation record](Benchmarks/MLXServing/MIGRATION-VALIDATION-2026-09-25.md) for measured native transport, image, compaction, cancellation and process-lifetime checks, including remaining limitations. On September 25 the unused 27B model download was removed with the user's explicit approval; 4B/9B weights and saved conversations were retained.

## Historical / external LM Studio compatibility

Earlier runs served `mlx-community/Qwen3.8-27B-4bit` through LM Studio at `127.0.0.1:1234`. That model directory was about 16.08 GB; its three weight shards totaled 16,054,541,349 bytes. Those 27B runs used one parallel request and a bounded 22 GiB custom model-loading guardrail. They are historical evidence, not the current default serving path.

HeyDash declares 4,096 tokens for the constrained 27B/35B profile, with auto-compaction at 3,072. The 4B and 9B computer-use profile declares 16,384 tokens with auto-compaction at 12,288, leaving more working space beyond the fixed instructions and tool definitions. These are application budgets, not the LM Studio backend's advertised or automatically fitted maximum. The shared profile permits 4B/9B switches without changing the loaded task's context class. App Server ignores context overrides for already-loaded threads; after a profile update, restarting HeyDash's owned runtime lets the same saved task resume with the new configuration. Switching a still-loaded task between the constrained and small-model classes remains guarded.

One model-local compatibility patch is required on this installation. Codex exposes a `request_user_input` tool schema even though HeyDash does not implement that tool; with that schema serialized, this MLX/model path stalled. The installed model's `chat_template.jinja` skips only that schema when rendering tools. The original template is preserved beside it as `chat_template.jinja.localcodex-original` (SHA-256 `c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041`); the patched template hash is `c73f9ec1cfc68a6ce7e19f06b1779afa4b1a55e1da8775d498f379a09b8fae75`.

That compatibility patch lives in LM Studio's model directory, not in either HeyDash ZIP. Redownloading the model may replace it.

## Install the native visual-grounding sidecar

The app bundle contains the worker, prompts, manifests, and warm-up image, but not the approximately 4.0 GB of visual model weights or its approximately 0.6 GB Python environment. Install them once into `~/Library/Application Support/LocalCodex/VisualGrounding`:

```sh
cd HeyDash
Scripts/install-visual-grounding.sh
```

The installer pins the Python patch version, every direct and transitive package with hashes, every model revision, and every installed model file with SHA-256. It synchronizes away extra packages, rejects unexpected `.pth` startup code, and writes a private installation receipt. The shipped worker independently rechecks that receipt, the manifests, the exact package and `.pth` sets, and all model files before loading. The three models stay resident in one persistent worker after its cold load and warm-up.

This integrity boundary is not an OS sandbox. The Python process receives a minimal environment and is forced into the Hugging Face/Transformers offline modes during inference, but it still runs as the logged-in user. A first-time installation downloads pinned model revisions; the pinned GoClick conversion executes its upstream model code through `--trust-remote-code`. Review that boundary before installing on another machine.

## Build the Octane UI

The interface uses `@octanejs/shadcn` components compiled by Octane, with Tailwind
CSS and the neutral shadcn theme. It does not replace Octane with React. The build
rejects React/React DOM runtime modules in shipped chunks. The TypeScript check
uses `tsrx-tsc` because the native shadcn package publishes `.tsrx` component source.

Interface icons use the same native `@octanejs/lucide` port as shadcn, with
per-icon imports instead of hand-drawn SVG paths or a whole-library loader.
They share Lucide's stroke style and retain explicit sizes; decorative icons are
hidden from accessibility while their buttons keep descriptive labels.

The main view keeps one task action, a compact list, and the composer. Tool payloads
and the inspector are opt-in; native Swift still owns all privileged approvals.
Component license texts are bundled under `WebUI/licenses/` inside the app resources.

Generated replies use Marked's lexer and an Octane-only element renderer for
paragraphs, lists, headings, code, and tables. Blank model-output lines no longer
become empty display rows. The original text remains unchanged in native state and
the inspector. HTML is displayed literally, images do not load, and only HTTP(S)
links are active through the existing native navigation policy. `bun run test`
checks response formatting and inert-content behavior using real Octane rendering.

The checked-in browser bundle is produced with Bun and runs as static JavaScript in WebKit. Bun and Node are not included in the application:

```sh
cd HeyDash/WebUI
bun install
bun run check
bun run build
```

Octane currently declares Node.js 22.22.2 or newer for its supported development toolchain. The app's `.tsx` and the component package's `.tsrx` sources both typecheck and build with the installed Bun toolchain; retain a current Node installation as the upstream-compatible fallback.

## Generate, build, and test the app

`project.yml` is the source of truth for the native Xcode project:

```sh
cd HeyDash
bun Scripts/build-agent-runtime.ts
xcodegen generate

xcodebuild -project HeyDash.xcodeproj -scheme HeyDash \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  build

xcodebuild -project HeyDash.xcodeproj -scheme HeyDash \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  test
```

The debug application is written to:

```text
.build/DerivedData/Build/Products/Debug/HeyDash.app
```

Run it with:

```sh
open .build/DerivedData/Build/Products/Debug/HeyDash.app
```

## Release bundle

The packaged application is a universal macOS app containing both Apple Silicon and Intel slices. Extract `HeyDash-macOS.zip`, move `HeyDash.app` to Applications if desired, and open it. The archive contains the compiled Octane interface, system-WebKit Swift host, and visual-grounding worker/manifests; it does not contain Bun, Node.js, Electron, Chromium, visual or language-model weights, the external Python environment, or the LM Studio chat-template patch described above.

The local release is signed for this machine with Ahmed's Apple Development identity (`TeamIdentifier=MSMG8CJLB3`) and hardened runtime enabled. macOS can still bind Accessibility approval for a local development build to that build's exact code hash, so replacing the application may require requesting Accessibility again even though the signing identity is unchanged. Screen Recording can remain attached to the designated signing requirement. It is not Developer ID signed or notarized, so Gatekeeper assessment still rejects it as a distribution build; that is expected for this private local install.

For faster command-line iteration, the same targets are available through Swift Package Manager:

```sh
swift build
swift test
swift run HeyDash
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

The live gates parse the isolated App Server rollout for model-level `function_call` and matching `function_call_output`, and enable a test-only recorder for exact newline-delimited App Server frames. They check matching call IDs and successful client responses. For each call, both `item/started` and `item/tool/call` must precede that response, with `item/completed` afterward; App Server can emit the first two in either order. The shipped app leaves its recorder disabled so HeyDash does not make a second copy of prompts or tool payloads. Historical Chrome gate evidence below applies only to V1; it is not V2 proof.

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

A standalone ShowUI replay is not a substitute for that agreement policy. Under the same production prompt/parser contract, ShowUI returned 91/91 syntactically valid points but only 74/91 landed in the exact target box; the other 17 were wrong accepted points. Its misses were systematic on small repeated controls: the weekly-summary checkbox was 0/7, the Atlas checkbox 1/7, and the Harbor trash icon 3/7. On the retained Calculator corpus it was 0/6, representing two unique screenshots repeated three times each. Its 91-instance warm latency was 1.365 seconds p50 and 1.383 seconds p95, with a 3.264 GB reported MLX peak. This fixture evidence directly rejects a 100%-accuracy claim while remaining too correlated to establish a general 81.3% real-world rate.

The baseline opt-in 4B Calculator grounding gate passed end to end in 25.753 seconds. Qwen issued exactly `open → capture → ground_click → snapshot`; the sidecar's selected point was independently inside Calculator's digit-1 AX frame, the runtime revalidated the full window and approval boundary, Calculator changed from `0` to `1`, rollout and raw App Server call lifecycles matched, and owned App Server/worker cleanup succeeded. A preceding attempt failed closed because a stale system Screenshot overlay covered the action point; it posted no click.

After overlapping visual-sidecar preparation with Qwen and embedding a fresh verification-only screenshot with synchronized Accessibility in `ground_click`, a subsequent settled-app run passed with exactly `open → capture → ground_click` in 18.904 seconds of XCTest wall time, 6.849 seconds or 26.6% below that baseline. The raw turn itself fell from 23.885 to 17.051 seconds, a 28.6% reduction, and total tool time fell from 10.751 to 3.369 seconds, a 68.7% reduction. The post-action image exposed no reusable `capture_id`; Qwen explicitly reported reading the visible `1` from that screenshot, while the synchronized AX text did not contain the display value. Input plus output tokens fell from 19,010 to 15,254, a 19.8% reduction. This is one before/after capability comparison and may include model/OS cache effects; it is not a throughput distribution. Non-tool/Qwen time was 13.682 seconds, 80.2% of the optimized raw turn and 4.2% above the baseline run, so model planning is now the dominant remaining latency. An earlier post-action capture attempt safely returned uncertainty while Calculator pixels were still moving; Qwen requested a separate capture and verified the result rather than repeating the click. Other intervening attempts safely refused an ambiguous duplicate digit, a changed window, and a moving cold-launch window without posting a wrong click.

## Current limitations

- New tasks expose native `computer_v2_*` tools, not the App Server's shell or built-in coding/editing tool set. HeyDash is a local chat and desktop-automation client, not a shell-capable coding agent.
- Ordinary Chrome uses native AX/capture/input unless the native user separately connects it for exact background DOM tab access. Existing-mode navigation requires a positively identified native address bar and fails closed otherwise. Explicit isolated mode uses a separate temporary profile with no imported tabs, cookies, credentials, or extensions. This is not full Codex CUA/browser parity. Owned brokered tasks within one runtime reuse that runtime's owned process/profile. Task-scoped handles restrict broker calls, not shared-profile cookies, storage, same-origin scripting, or site-triggered cross-tab effects.
- Brokered actions use DOM click/value operations, not general trusted keyboard/pointer input. Text entry rejects read-only controls; mutations reject disabled, inert, detached, non-main-document, or unsupported controls. Browser screenshot/coordinate/keyboard support remains disabled. The visual-grounding cascade is a native-window fallback and does not add browser visual control.
- Loader/URL comparisons detect observed document changes, not every possible intervening navigation. Same-document changes that return to the previous URL between reads and arbitrary semantic changes between the final AX read and browser execution require a persistent event/DOM invalidation design for stronger guarantees. Local DevTools clients remain inside the trust boundary; loopback, origin checks, and a private profile directory are not authentication against other local processes. Terminal task cleanup revokes its lifetime before asynchronous exact-session detachment (borrowed) or exact-target closure (owned). Explicit runtime shutdown stops its owned App Server and isolated Chrome process groups, reaps their roots, and removes owned profiles after observed group exit. Shutdown has bounded waits and reports incomplete cleanup; the app termination delegate also has a ten-second reply deadline. Force quit, host failure, or descendants escaping their created process group are not covered by an unlimited cleanup guarantee. The bootstrap blank tab is retained during use rather than closing unrelated blank or loading tabs by URL.
- This Mac also has Codex's richer installed `cua_repl`/computer-use stack, but HeyDash does not load or copy it. Only project-owned clean-room tools are exposed to Qwen.
- The historical semantic and visual smoke turns proved V1 model/runtime paths on the controlled Chrome fixture; they do not establish V2 performance or reliable tool selection on arbitrary interfaces.
- The focused-window screenshot reduces visible image size, but a visual grounder is still probabilistic. The agreement threshold, whole-window freshness checks, native approval, and post-action verification reduce risk; they do not establish reliability on arbitrary apps, targets, display scales, or instructions.
- The previously signed installed app passed separate `open → capture → snapshot` and natively approved `open → snapshot → AXPress → snapshot` Chrome turns, both ending `Completed`. Screen Recording was **Granted** for that app. The screenshot turn took 540 seconds; this capability result was not a speed benchmark. The coordinate-click path was separately validated in the V1 production-runtime test host, not repeated in that installed binary.
- App Server persists a task's dynamic-tool schema when that task is created. Existing threads can retain older schemas and lack the new tab tools. Durable in-place schema migration is unfinished; the app must not claim old chats have gained these tools or that a new chat is the intended long-term recovery mechanism.
- The App Server is bundle-only: missing, incompatible, or corrupt runtime artifacts fail closed, without silently falling back to the installed Codex/ChatGPT application. LM Studio provider and initial workspace are fixed in code; the default model is selectable in Settings.
- The distributed ZIP is Apple Development signed with hardened runtime enabled for Ahmed's local use. It is not Developer ID signed or notarized for public distribution.

## Source layout

```text
Sources/
├── AutomationCore/
│   ├── permission inspection and guards
│   ├── application launch and running-app metadata
│   ├── ScreenCaptureKit display capture and native pointer/keyboard input
│   └── bounded Accessibility snapshots and guarded semantic actions
└── HeyDash/
    ├── Assets.xcassets/    clean-room application icon
    ├── HeyDashApp.swift
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
