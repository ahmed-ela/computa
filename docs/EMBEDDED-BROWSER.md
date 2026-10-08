# Human-operated embedded browser

## Scope

Computa owns a native WKWebView tab pane beside the chat. General browsing remains
human-operated; Qwen has no general embedded-browser tools. The Swift app's
ChatGPT, Gemini, and Claude models use fixed inference actions in separate owned
Temporary Chat or Incognito tabs sharing this profile. They do not require Chrome
for inference; ordinary browser tools still use the separately approved Chrome connection.
General agent control is [explicitly deferred](../TODO.md#embedded-browser-agent-control-deferred).

## Composition

- `EmbeddedBrowserSession` owns tabs, WebViews, independent website data,
  navigation state and teardown on the main actor. Hiding a view does not
  destroy its session. The default limit is eight tabs (configurable 1–32).
- `EmbeddedBrowserPane` presents only human tabs from its injected session: tab strip, address field,
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
  responder, including a text field's editing owner, unsent buffer and selection.
  AppKit's shared field editor can detach during WebKit focus changes; the narrow
  native bridge reenters editing through the still-attached original control.
  New human field choices replace that destination, detached controls are ignored,
  and secure-field contents are never copied into the model's focus snapshot.
  Model pages never appear in the human tab strip and cannot be
  selected or presented by its navigation API, including retained sessions.
  Closing the last human tab shows the empty browser while model work continues;
  model loading, errors and teardown do not replace the human browser's errors.

Sign in through a regular human browser tab. Both use the same persistent WebKit
profile; inference never takes over the sign-in tab. Saved model catalogs are
reused on startup; only missing catalogs are discovered once. **Refresh website
models** explicitly reads all provider menus sequentially without sending a
prompt.

When a provider reports a CAPTCHA, sign-in requirement or usage limit, Computa
stops new sessions for that provider and wakes its active waits with the same
failure. Resolve the issue in the built-in Browser, or wait for quota recovery,
then choose **Refresh website models**. Successful menu discovery and cleanup
clear the provider gate; failed refreshes leave it in place. Then start a new
task attempt: recovery does not resume failed tasks or replay their messages.
Cached startup and provider gates reduce unnecessary page loads, but cannot
guarantee the absence of CAPTCHAs or establish that a WebKit version caused one.
See [website model behavior](WEBSITE-MODEL-CHOICES.md#external-website-gates).

This uses ordinary rendered WKWebViews attached behind the opaque workspace,
not a headless engine. It does not prevent providers from requesting sign-in,
applying usage limits or rejecting embedded browsers. Existing limits still
include background sessions. Unverified cleanup retains the owned page; if
retained sessions exhaust capacity, restarting frees local pages without
claiming their website conversations were deleted.

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

### Earlier ChatGPT and sign-in qualification

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
That run qualified browser sign-in for the tested account/session. In that
`0.1.2 (3)` build, Claude inference still used the Chrome transport.

### Three-provider inference

The `0.2.0 (4)` Swift build routes ChatGPT, Gemini and Claude inference through
the embedded browser. See [provider qualification](EMBEDDED-PROVIDERS-QUALIFICATION.md)
for live harness results, automated checks and the remaining limits.

### Private background sessions

The locally installed `0.3.1 (7)` Swift build keeps inference pages private from
the human Browser pane and preserves native typing focus. See
[background session qualification](BACKGROUND-WEBSITE-SESSIONS.md) for the final
three-provider terminal/UI results and 91-test regression run.
