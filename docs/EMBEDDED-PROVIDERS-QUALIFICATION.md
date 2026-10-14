# Embedded website provider qualification

## Target

The Developer ID signed Swift app `0.2.0 (4)` was installed at
`~/Applications/Computa.app` on October 6, 2026. Each website model uses its own
owned temporary session in the app's WKWebView profile. The local App Server
executes the offered tools and saves the conversation. Chrome was disconnected
during these tests.

These results qualify the installed Swift app. They do not qualify the separate
Rust desktop runtime migration or constitute a public release.

## Live harness checks

The user requests were plain language, without tool syntax or response-format
instructions. The fixture marker values were absent from those requests. Each
terminal marker came from a synthetic file in `/private/tmp`; the independent
native marker came from an already-running AppKit fixture identified by its
bundle ID. Local rollout records were checked against the expected markers,
actual tool call IDs, matching tool outputs and clean final assistant replies.

| Provider | Terminal file, exit 0 | Native Accessibility read | Interactive terminal, matching input and exit 0 |
| --- | --- | --- | --- |
| Gemini | Passed on latest installed candidate | Passed on latest installed candidate | Passed on latest installed candidate |
| Claude | Passed earlier; fresh final check quota-blocked | Passed earlier; fresh final check quota-blocked | Passed earlier; fresh final check quota-blocked |
| ChatGPT | Passed on explicit repeat; initial refusal retained | Passed on explicit repeat; initial refusal retained | Passed on qualified functional candidate |

The interactive check started a TTY process that waited for input, returned a
session ID, received a marker through `write_stdin` for that same session, then
echoed the marker and exited 0. This verifies tool continuation rather than a
model merely describing a command.

Checks run with the Browser pane hidden. The functional checks also exercised
idle model switches in one local chat. Exact-turn receipts require fresh native binding before the current read,
matching call results and a completed clean final. They reject extra historical
commands or interactive sessions. Every inference identifies the current user
message within the unchanged request, so completed historical tasks remain
context. Five successful phases passed on the same signed functional candidate before the Claude quota-only follow-ups: ChatGPT
marker/native and interactive checks in 24/24 seconds, and Gemini marker/native,
interactive and a fresh marker/native repeat in 31/26/29 seconds. The Gemini
repeat issued only the three requested read calls, with no interactive session
or historical work replayed. Native browser inspection after completion showed
only the original selected human Gemini home tab, with no owned model tabs left.

On the latest installed candidate, a fresh Gemini local chat passed the
marker/native check in 32 seconds and the interactive check in 40 seconds.
The first phase issued exactly the three requested read calls; the second used
one terminal session and its matching input continuation. Both returned clean
final replies with the actual expected outputs. Gemini's completed owned tabs
closed and the selected human Gemini home tab remained open. The separate
quota-blocked Claude tab remained retained; this is not a claim that all owned
model tabs closed on the latest candidate.

On that functional candidate, ChatGPT initially declined the marker request without
dispatching any tools. That turn failed qualification. An explicit repeat of the
identical plain-language request then used the three real local tools and
returned both markers; its interactive terminal check also passed. No model
instructions or code changed between these attempts. The initial refusal is
retained in the evidence, and these checks do not establish that every website
reply will follow the relay contract.

Claude's earlier strict marker/native and interactive checks passed in 12 and
11 seconds. During final requalification, its requested terminal and native
tools completed, but the website's free-message limit blocked the final reply.
The visible website said messages return at **11:40 PM EDT on October 6, 2026**.
That attempt does not qualify as a successful turn, and earlier Claude receipts
are not presented as successful inference on the latest installed candidate.
A separate fresh-chat smoke verified the exact typed Claude usage-limit error,
with zero local tool calls and no final response. This is an error-handling pass,
not a successful inference. The fixed adapter recognizes the quota popup through
its reset heading and unique enabled Not now / See all plans controls; its price
label is not part of that proof. The official quota banner requires its exact
link destinations and direct warning structure, independently of hidden link
label markup. It grants only an abort, never a popup click or mode proof.

An untouched initial Claude page can issue an exact empty-quota receipt. Native
code admits it only after the same view, generation, origin and URL checks, in
the initial loading state with no preparation, submission or messages. It pins
only the document for closing that exact empty owned tab, and still returns the
quota error. Missing proof, earlier activity, messages, navigation races or
uncertain state retain the tab. Native fixtures verify this already-visible
initial quota case with no focus, insertion or Send and confirmed empty-tab
cleanup. In the latest live check, the quota appeared after readiness; the exact
typed limit was reported, but cleanup ownership could not be confirmed and the
tab was retained. That live check does not establish zero website Sends or
successful early-abort cleanup.

Completed turns close only their owned website tab and preserve the selected
human Gemini home tab. Website response code widgets are read as one literal
JSON envelope; a provider-specific language header and scoped Copy control may
be omitted from extraction only when their observed structure matches. Extra
prose, extra code blocks and malformed envelopes remain rejected.
ChatGPT's long PRE/CODE and short DIV/CODE layouts both passed live.

Gemini fingerprints the observed control-free message payload rather than
sibling Copy/expand controls. If its acknowledged continuation is rendered
during a read's awaited hash, that read is discarded only when the expected
single pending append is the sole change and the original private/native
fingerprints, body, owner, route and temporary-mode proofs still match. The
next DOM wake takes a fresh read. Mutations are never replayed, and other
changes remain ownership failures.

## Automated coverage

The focused suites passed 188 Swift tests, 104 adapter tests (1,272 assertions)
and 83 WebUI tests (330 assertions). The final full native transport scope passed
all 42 tests with zero failures in 79 seconds, including the delayed pending
append during a read, first-body changes, roleless Claude quota popup, no further
Send, preserved prior response and pinned cleanup. Final regressions cover
empty initial quota cleanup, exact abort receipts, prior activity and messages,
changed route/generation and bounded diagnostics against the final Claude resource.
WebUI type checks/build and the
synchronized version check passed. The exact-turn live evidence verifier passed
43 positive/negative oracle cases.
The latest-candidate receipt collector also passed six focused oracle cases.

- Fixed adapters: literal insertion and rendered first-message lineage; provider
  origins, Gemini account routes, temporary-mode proof, one Send, DOM rerender,
  exact owned cleanup and guarded code-widget extraction.
- Native WKWebView transport: event wakeups, delayed/disabled mode controls,
  preparation and response deadlines, cancellation, route ownership and real
  Quill paragraph insertion with quotes, backslashes, whitespace and Unicode.
- Runtime and codec: all three embedded routes, fresh instructions and exact
  offered tool schemas on every inference, strict envelope and argument
  validation, typed failures and cleanup.
- Queue: proven pre-dispatch rejection permits an idle model change; uncertain
  delivery remains blocked and never automatically replays.
- WebUI, session lifecycle, pane state and launch isolation checks passed.

## Limits

The model transport supports text and Accessibility observations. Image,
screenshot and audio transfer are unavailable. The native harness implements built-in browser tools separately from these fixed inference adapters. Controlled API-provider tasks have exercised navigation, reading, filling, clicking and task-owned tab cleanup. Chrome tools are currently hidden from model catalogs; the retained connection controls do not make that route available by default.

Full Access does not override macOS privacy controls. These terminal tests use
synthetic `/private/tmp` files and do not establish access to protected folders.
Website sign-in, usage limits and future page changes can independently prevent
inference. Open browser tabs are not restored after app restart.


## Current repair qualification (2026-10-14)

Build100's fresh Gemini 3.8 Flash flight-form task passed six valid built-in browser calls and seven verified website inferences in one temporary conversation, with confirmed final website and task-tab closure, in 68.512 seconds. The next code task hit a new native Google checkpoint before any provider adapter or prompt dispatch. No challenge was solved, and automated Gemini checks stopped. Earlier failed attempts remain paused with unconfirmed website cleanup.

The installed GPT-OSS browser flow completed six valid calls and closed the task-owned tab, but the strict final receipt check failed. Finite API-boundary metadata locates its non-breaking-hyphen substitutions in the provider's logical content, before local serialization. This does not qualify exact receipt reproduction.

ChatGPT Instant's fresh build100 task failed first-message ownership before any tool call. Its rendered request has a bracket/brace mismatch; bounded diagnostics identify a DIV inside a DIV as the first unsupported literal child. This does not prove that child is the only child. The next diagnostic candidate traverses one sole immediate DIV only when the outer body's complete child list contains exactly that node. Both nodes remain validated; siblings, deeper wrappers, controls and hidden content fail closed. The comparison remains diagnostic and cannot grant ownership. Build100 passed 466 browser-adapter tests and 13 selected native diagnostics/ownership tests. No acceptance or cleanup requirement was relaxed.
