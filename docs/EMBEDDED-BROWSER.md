# Human-operated embedded browser

## Scope

Computa owns a native WKWebView tab pane beside the chat. General browsing remains
human-operated; Qwen has no general embedded-browser tools. The Swift app's
ChatGPT model uses fixed inference actions in separate owned Temporary Chat tabs
sharing this profile. Gemini and Claude continue to use the Chrome extension.
General agent control is [explicitly deferred](../TODO.md#embedded-browser-agent-control-deferred).

## Composition

- `EmbeddedBrowserSession` owns tabs, WebViews, independent website data,
  navigation state and teardown on the main actor. Hiding a view does not
  destroy its session. The default limit is eight tabs (configurable 1–32).
- `EmbeddedBrowserPane` presents an injected session: tab strip, address field,
  history/reload/stop controls and errors. Only a human new-tab action focuses
  the address field.
- `EmbeddedBrowserURLPolicy` accepts HTTP(S) and exact `about:blank`, rejects
  credentials and native/file/JavaScript schemes, normalizes bare domains, and
  sends ordinary address-field text to Google search.
- `WebWorkspaceView` places the browser beside—not inside—the privileged
  Octane WebView. Human browsing pages have no native script-message handlers.
  Owned model views have only a private-world change-notification handler; it
  accepts ownership metadata, never tool requests or page content.
  Approval blocking covers both surfaces; Settings hides but retains the pane.
- `AppState` owns session lifetime and shuts it down with the application.
- `EmbeddedWebModelTransport` uses the profile's separate owned model views.
  Navigation and DOM-change signals wake inference reads, with streaming changes
  coalesced over approximately 100 ms. Document, route, first-message lineage and
  temporary-mode checks remain mandatory; deadlines and stable-response timers
  remain. The local harness executes tools and stores transcripts.
  Before the first Send, the entire editor contents must match the outbound
  prompt, including an opaque session marker at its end. The first rendered
  user message must contain that marker as its last nonempty line. Its normalized
  rendered body is fingerprinted once and must match on every later read,
  mutation and cleanup, including the one allowed local-to-server SPA route
  promotion. This supports Markdown rendering without treating rendered text as
  the original prompt bytes.
- Owned model views stay attached to a permanent render host behind the workspace,
  including while the Browser pane is hidden. The host does not accept input or
  expose model pages in Accessibility. DOM editor focus preserves the native
  responder; manually selecting a model tab presents that same view.

Profiles initialize lazily. Session cookies can persist, but open-tab restoration
is not implemented. No Chrome/Codex data or signed-in sessions are imported.

## Deliberate first-version limitations

Human browser pages can open pop-ups as visible tabs, using WebKit's supplied
configuration so the opener relationship and signed-in profile remain intact.
Closing a child from the website returns selection to its surviving opener.
Pop-ups count toward the normal tab limit and obey the same URL policy.
Inference-owned pages cannot create or close browser tabs this way.

Downloads, file selection, camera/microphone requests, external-app schemes and
JavaScript modal dialogs are declined. Google can independently reject embedded
browser OAuth; pop-up support alone does not establish sign-in compatibility.
Website models accept text/Accessibility observations;
image, screenshot and audio inputs are unsupported. A tab count
limit does not guarantee bounded memory on arbitrarily heavy websites.

## Validation

Session tests cover independent WebViews, profile separation, navigation,
selection, capacity, close/shutdown cleanup and delegate behavior using local
fixtures. Pane tests mount the real native/Octane workspace offscreen with
synthetic content, verify split layout and approval blocking, and export renders
without accessing accounts or sending desktop input. Launch tests preserve the
isolated test-host runtime.

Run the pane tests with `xcodebuild test -project Computa.xcodeproj -scheme
Computa -destination 'platform=macOS,arch=arm64' -only-testing:ComputaTests/EmbeddedBrowserSessionTests
-only-testing:ComputaTests/EmbeddedBrowserPaneStateTests`. These tests use blank
and in-memory documents; no fixture server is needed. No production model or
signed-in-account qualification is implied by these checks.

On October 6, 2026, the Developer ID signed Swift app installed at
`~/Applications/Computa.app` completed two live ChatGPT harness tasks with Chrome
disconnected and the Browser pane hidden. A local `/usr/bin/uname -m` execution
exited 0 and returned `arm64`. A separate task opened the existing synthetic
fixture app and read its exact marker through `computer_v2_read_page`, without a
CLI call. Each task closed only its owned Temporary Chat tab; the human ChatGPT
home tab stayed selected. After restarting Computa, both assistant replies were
present in local history and the ChatGPT profile remained usable. This verifies
the installed Swift transport, not the deferred Rust runtime migration or other
providers. Open browser tabs are still not restored after restart.

The focused event, session, transport, response-codec, catalog, routing and
AppState scopes passed 86 Swift tests; the fixed adapter passed 8 JavaScript
tests. These scopes cover lost wakeups, source and owner validation, bounded
deadlines, cancellation, late completion evidence, literal insertion, rendered
Markdown lineage, changed-body rejection and exact-tab cleanup.

The later signed Swift build `0.1.2 (3)` qualified human pop-up support with
57 focused Swift tests across session lifecycle, pane state, launch isolation and
embedded model transport. A separate nonpersistent native loopback fixture
passed six paths: direct navigation, blank-first asynchronous navigation,
targeted form POST, `noopener`, COOP and blank `document.write`. It verified
shared synthetic cookies, exact opener callbacks where permitted, one initial
request, child-only teardown and selection restoration. The fixture's ports
are separate origins on the same site; it does not establish cross-site cookie
or provider compatibility.

With the existing Google profile already signed in, the installed app's Claude
"Continue with Google" opened the real account chooser, completed the standard
identity consent, closed its pop-up and returned to the authenticated
`https://claude.ai/new` composer. The previous build rejected this same action
as a disabled pop-up. No user-agent change or Chrome connection was needed.
This qualifies browser sign-in for the tested account/session, not an embedded
Claude model transport; Claude inference still uses the Chrome transport.
