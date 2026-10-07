# Private background website sessions

## Behavior

The Swift desktop app runs ChatGPT, Gemini and Claude inference in ordinary
rendered WKWebViews attached behind the opaque workspace. The Browser pane may
remain closed. A model page never appears in the human tab strip and cannot be
selected or presented through the human browser API. This also applies to pages
retained after unconfirmed cleanup.

Sign in through a normal human tab. Model pages share its persistent WebKit
profile, while each local turn retains its own temporary website session and
ownership checks. Navigation and DOM events wake the existing transport. This
change does not introduce headless browsing, a separate window, a Chrome
dependency or a different website identity. Providers can still require sign-in,
apply limits or reject embedded browsers.

Model lifecycle events do not replace human navigation errors or change the
selected human tab. Closing the last human tab leaves an empty Browser pane;
background work continues. AppKit focus restoration follows the current human
editing control in the same window and preserves its latest unsent buffer and
selection. Detached controls are ignored. Secure-field plaintext is never copied
into the model view's focus snapshot.

Cleanup remains conservative: an uncertain website session stays owned and
private, counts toward the existing limits, and produces a local warning.
Restarting can free local capacity but does not confirm website deletion.
Visibility of the human tab strip alone cannot prove cleanup or website Send
counts. Existing sandbox and approval requirements continue to apply.

## October 7, 2026 qualification

The final Developer ID signed Swift app, **0.3.1 (7)**, was installed locally.
Independent verification matched the installed executable and runtime to the
signed candidate, matched all 17 bundled WebUI/provider resources to source and
the candidate, and passed strict signature verification. This is a local signed
update; it is not a notarized/public release or Rust-app qualification.

With Chrome disconnected, each provider received an ordinary request to wait
15 seconds in the terminal and read a fresh synthetic file. Each performed one
actual native command, exited 0, and returned the exact marker absent from its
prompt. Native receipts correlate the offered tool call, command completion,
tool output, final reply and unchanged fixture.

| Provider | Native terminal task | Human tab, address buffer and focus | Turn duration |
| --- | --- | --- | --- |
| ChatGPT | Passed | Preserved | 32.993 seconds |
| Gemini | Passed | Preserved | 37.194 seconds |
| Claude | Passed | Preserved | 23.377 seconds |

During each real command, the operator typed an unsent sentinel into the normal
Browser address field. The same human tab remained selected, only its tab was
exposed, and the exact sentinel and native focus survived turn completion.
Further keyboard input reached that field without another click. A separate
pixel observation verified Gemini's model page remained behind the workspace.
Durations include the requested wait and are not performance benchmarks.

A separate fresh ChatGPT terminal task also returned its exact synthetic marker
with the Browser pane closed throughout submission and completion. The final
native UI and pixel observation showed only the local chat, with the Browser
toggle still off.

No unconfirmed-cleanup warning appeared in these three observed turns. Native
terminal receipts do not establish website Send counts or server-side deletion;
those remain separate from the UI checks and automated cleanup-contract tests.
Claude's terminal result does not qualify the earlier code-editing request that
was blocked by the account's usage limit.

The final focused regression run passed **91 Swift tests with zero failures**:
38 session tests, seven pane tests, 42 model-transport tests, two AppState tests
and two runtime-routing tests. Coverage includes private presentation rejection,
interleaved human/model close selection, human error preservation, the real
workspace render host with the pane closed, ownership/lineage and cleanup,
the actual SwiftUI address field, AppKit shared-editor detach/reentry, edits and
new field choices during an awaited action, detached/moved controls and secure
fields.

The initial candidate exposed a real shared-field-editor focus regression;
the final implementation and regression tests correct it. An earlier Gemini
attempt executed the command but added prose to its reply, so its exact-output
receipt remains failed. It was not relabeled as the passing final turn. Local
qualification archives preserve these attempts separately from the final
receipts.

See [the embedded browser contract](EMBEDDED-BROWSER.md),
[earlier provider qualification](EMBEDDED-PROVIDERS-QUALIFICATION.md), and
[code-editing qualification](CODE-EDITING.md) for distinct earlier results and
remaining capabilities.
