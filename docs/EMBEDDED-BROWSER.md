# Human-operated embedded browser

## Scope

Computa owns a native WKWebView tab pane beside the chat. This release does not
give Qwen access to that profile, and does not replace the Chrome extension.
Agent control is [explicitly deferred](../TODO.md#embedded-browser-agent-control-deferred).

## Composition

- `EmbeddedBrowserSession` owns tabs, WebViews, independent website data,
  navigation state and teardown on the main actor. Hiding a view does not
  destroy its session. The default limit is eight tabs (configurable 1–32).
- `EmbeddedBrowserPane` presents an injected session: tab strip, address field,
  history/reload/stop controls and errors. Only a human new-tab action focuses
  the address field.
- `EmbeddedBrowserURLPolicy` accepts HTTP(S) and exact `about:blank`, rejects
  credentials and native/file/JavaScript schemes, and normalizes bare domains.
- `WebWorkspaceView` places the browser beside—not inside—the privileged
  Octane WebView. External pages have no native script-message handlers.
  Approval blocking covers both surfaces; Settings hides but retains the pane.
- `AppState` owns session lifetime and shuts it down with the application.
  The agent runtime is not given a session or browser adapter.

Profiles initialize lazily. Session cookies can persist, but open-tab restoration
is not implemented. No Chrome/Codex data or signed-in sessions are imported.

## Deliberate first-version limitations

Popups, downloads, file selection, camera/microphone requests, external-app
schemes and JavaScript modal dialogs are declined. Popup-dependent OAuth may
therefore be unavailable. The address field is not a search engine. A tab count
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
