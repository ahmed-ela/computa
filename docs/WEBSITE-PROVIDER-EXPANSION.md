# Kimi, Qwen and DeepSeek website adapters

Status: installed 0.8.0 (394), 2026-11-02 UTC, source
`80b917bff6f38e30654a789c476c3801f9ebd748`. Fresh native markers remain
unqualified: Kimi rejects the initial first-user root ID; Qwen passes the route
transition then rejects the response scope; DeepSeek completes its response but
fails saved-chat deletion. No failed Send was replayed and no tool workflow ran.
The exact timing and cleanup failures are retained below. Candidate395 changes
only provider icons/version: official Gemini four-color and Alibaba Cloud marks.
Provider fixes remain under investigation. PR #20 remains draft.

The requested route is each provider's signed-in website in Computa's browser.
Qwen's website is separate from Alibaba's existing Qwen 3.7 Flash API option.
Do not seed website choices from API catalogs or marketing model lists.

## Prepared implementation

- Provider-first menus recognize Kimi, Qwen and DeepSeek with bundled icons.
  They expose only supplied concrete choices, hide Website default and retain
  missing saved selections as disabled. No placeholder choices are supplied.
- Existing native providers declare their session lifecycle exhaustively:
  ChatGPT, Gemini and Claude use temporary chats; Groq clears the visible
  transcript; Kimi explicitly deletes its owned saved conversation. A future
  provider cannot inherit temporary mode merely by being different from Groq.
- Model selection, ownership, response acceptance and cleanup remain separate
  verification requirements. No retries or parsing protections changed.

Validation: 21 model-selector tests (404 assertions), WebUI type checking,
and 10 focused real-WebKit lifecycle tests passed. The latter include changed
ownership, lost temporary proof, ambiguous clearing controls and delayed or
unacknowledged cleanup without repeated actions. These are preparation and
regression results, not qualification of a new adapter.

Kimi's fixed adapter and native transport now implement one fresh inference
per saved conversation. The native Send claim precedes dispatch; a finite
acknowledgment binds only that click to the exact outbound digest, owner and
document. Provisional routes cannot authorize an answer. The canonical route
must independently prove the complete first user message, including the native
session marker, before response or deletion authority is acquired.

Deletion claims the header menu, Delete selection and confirmation separately,
once each. Subsequent observations are read-only. Success requires the exact
confirmed operation, return to the fresh page, an empty composer/transcript,
disconnected captured roots/dialog and removal of the owned history link.
It does not prove remote erasure. Ambiguous dispatch, foreign routes or lost
acknowledgments retain failure and the owned view instead of replaying actions.

The original plain WebKit fixture exposed rendered paragraph spacing and
smart-quote changes during prompt insertion. Its escaped `insertHTML` solution
passed that fixture, but a draft-only check in the actual Kimi Lexical editor
caught a missing behavior: the editor applies input asynchronously and flattens
the inserted paragraph HTML. The candidate was withheld before installation.
In the same approved test tab, one `insertText` operation instead preserved exact
multiline text, quotes and trailing spaces after asynchronous reconciliation,
in a `p > span[data-lexical-text="true"]` structure. No provider message was sent;
the draft was cleared and both developer settings restored. The corrected adapter
claims one text insertion, then uses the existing event-driven readiness wait
for exact settled readback before Send. Empty pending input grants no Send or
conversation authority; changed, replaced, cancelled or late drafts cannot be
reinserted. No fixed delay or text normalization was added.

The real-WebKit controlled-editor fixture now obtains its payload from the actual
`beforeinput` event, cancels default editing and commits asynchronously. A bounded
comparison established that unhandled default editing emits smart-quote replacement
events, whereas the controlled path returns success and preserves all input bytes.
This reproduces the live DOM result without claiming Kimi's exact framework version.
The corrected resource passed 39 JavaScript tests/349 assertions and 30 Kimi native
tests, including the full harness payload, delayed/failed insertion, deletion and
the actual WebKit-to-server durable receipt. Installed qualification remains pending.

Validation passed 31 JavaScript tests/242 assertions and 21 Kimi native tests
(10 contract and 11 real-WebKit cases). The native cases are included in the
230-test instruction/codec/correction/Kimi integration run, not additional to
it. They cover the full harness prompt, provisional/canonical transitions,
malformed output, delayed cleanup, cancellation and thrown callbacks after
Send or deletion confirmation. These fixture results support the installed
pilot; they do not establish live completion or cross-site tool reliability.
Only Instant is admitted: K3.1 Pro, K2.8 Preview, K3 and unknown/agent-family
choices remain unavailable to native inference.
The final Instant catalog-admission change and added native discovery regression
also passed a separate 51-test run: 12 existing transport, 11 Kimi contract,
12 Kimi real-WebKit and 16 catalog cases. These overlap the earlier batch and
must not be summed as independent coverage. Installed discovery and live
tool-use qualification remain pending.

A preinstall audit found that Kimi was absent from the durable cleanup receipt
provider enum and the persisted human-verification checkpoint set. Native
deletion had passed, but the missing receipt identity would have prevented the
server from saving its confirmation and releasing the response. Both finite
provider sets now include Kimi. A separate 24-test gate passed, including an
actual offline WebKit → server → durable deletion receipt/reload/retry workflow,
receipt schema/identity checks and checkpoint persistence. No affected build
was signed or installed. Shared server and app-state fixtures now use Kimi's
single admitted Instant choice; they do not invent a default or second model.

The broader shared integration gate passed 227 tests, with the optional synthetic
performance benchmark skipped. A separate 24-test failure-history gate passed:
Kimi's fixed unsupported-literal-response diagnostic now persists and restores
the exact failed turn, while altered or foreign-provider envelopes are rejected.
These counts include overlapping persistence coverage; they are not additional
live-provider qualifications. The subsequent nonempty production Lexical check
found the asynchronous insertion gap described above; its corrected focused gates
passed before installation.

## Live observations

### Build383 startup discovery and candidate384

After build383 was signed and installed, Settings showed `Kimi: The owned model
page or conversation changed (js_document_changed). No prompt was replayed.`
The normal Kimi tab was signed in at its root page. No native prompt was sent;
no Kimi choices were saved or exposed. The provider registry, snapshot bridge
and frontend all recognize Kimi: the selector intentionally hides Website
default and waits for concrete observed choices. The failure receipt is
`work/new-website-providers-20261102/build383/kimi-discovery-failure383.json`.

An offline reproduction removed each initial composer, Send control, model
trigger or model label in turn. All four returned `document_changed` with a
fixed structural detail that native code previously collapsed into the same
`js_document_changed` reason. This reproduces the reported error class; it does
not yet identify which control failed in the installed session.

Candidate384 accepts only a metadata-only pending signal while the untouched,
empty owned root is still mounting its first controls. It retains the existing
DOM wakeups and preparation deadline; it adds no fixed delay or input retry.
Any controls already seen are pinned. Duplicate or hidden controls, an existing
draft or transcript, changed owner/document/route, replaced controls and missing
controls after the first complete read or model claim still fail. Pending
hydration cannot supply readiness, model, conversation or Send authority.
Native diagnostics record only fixed action/error/detail identifiers; unexpected
JavaScript exceptions expose a fixed enum rather than arbitrary exception text.

The initial updated JavaScript suite passed 46 tests and 485 assertions, including
partial mounting, eventual discovery, changed bindings, post-claim disappearance
and no mutation while waiting. Native gate21 passed 46 tests: 13 saved-conversation
contract, 21 real-WebKit and 12 existing transport cases. Gate20's one failing
test had inspected a cached ready Poll snapshot after removing controls; it now
exercises Send's strict pre-input reinspection and proves zero input/Send. This
corrected the test boundary without relaxing production verification.

The subsequent attribute-only mounting check extends Kimi's existing observer
to the six selector attributes (`role`, `contenteditable`, `data-lexical-editor`,
`data-testid`, `aria-haspopup`, `id`). They emit wakeups only. Groq's observer
filter is unchanged. Kimi/Groq's focused JavaScript gate passed 109 tests and
1,390 assertions, including the new signal test and exact shared-core prefixes.
Final native gate22 passed 47 tests, including the real-WebKit case that restores
only the existing editor's `contenteditable` attribute and completes discovery
without input or Send. These overlapping fixture runs do not establish a live
fix, successful installed discovery, a response or tool-use qualification.

### Build384 installed discovery and nested selection

The signed build384 was installed and its running process and main binary were
verified. Its fixed diagnostic reported `action=discoverModels
error=model_unverified detail=absent generationBound=true sequence=0`.
Settings showed the model-verification failure, and no Kimi choice or prompt
was created. This reached a later stage than build383's initial document error;
it did not establish a completed discovery or response.

The normal Kimi page showed K3 High. Its top menu offered K3.1 Pro, K2.8 Preview
and Instant, with K3 shown beside More models. Hovering that submenu revealed
the checked K3 row. No model was changed, prompt sent or Inspector enabled.
The retained DOM separately identifies K3 as a nested `data-model-id=k3-agent`
row, outside the top-level list. An inert reproduction with K3 selected and no
checked top-level row produces the exact installed error, after one menu open
and zero model changes or inputs. The live diagnostic did not capture the
specific failing assertion, so that causal boundary remains explicit.

Candidate385 must verify the selected nested row through its actual menu
relationships and preserve exact selection before exporting Instant. It must
not alias K3 to a top-level model or expose that agent product as a qualified
inference option. Live evidence is retained in
`work/new-website-providers-20261102/build384/kimi-nested-selection-observation.json`.

The implementation now opens and closes only the bound More models submenu,
checks its single selected row against the closed picker label, and pins the
parent/submenu controls across each stage. It exports only top-level plain-chat
choices; the catalog continues to admit only Instant. Unknown, duplicate,
replaced or contradictory selections remain failures, and uncertain actions
cannot be repeated. The JavaScript gate passed 53 tests with 594 assertions.
The native gate passed 50 tests, including real-WebKit discovery from K3,
switching to Instant followed by one Send and verified deletion, and rejection
of a foreign submenu binding. These fixture passes did not establish installed
discovery recovery; the build385 result follows.

### Build385 discovery deadline and candidate386 diagnostics

Signed build385, source `5d7a1fc662c7632687d48bd1ec45819b99b19cd0`, was installed
and running as process 32050. Startup discovery still reached the existing
45-second preparation deadline. No fixed adapter error or specific pending
phase was retained, no model choices were exposed, no prompt was sent, and no
website cleanup task was created. This does not establish whether the nested
menu failed to open, selection was still pending, or another preparation step
was waiting. The bounded installed observation is
`work/new-website-providers-20261102/build385/kimi-discovery-timeout385.json`.

At that checkpoint Inspector approval was pending. Build386's next
change was diagnostic-only: preserve finite discovery-stage evidence before
cleanup closes the owned page. Existing picker reads expose a fixed phase and
booleans for main/submenu presence, expansion, collapse and claimed actions.
Native validation admits only exact keys and Boolean types, removes the
diagnostic metadata before ordinary verification, and retains at most 12 distinct
records plus the last observation before discovery-error cleanup. No requests,
timers, Send actions, uncertain-menu retries or deadline extensions are added.
The focused build386 native gate passed 99 tests. The combined JavaScript and
version gate passed 64 tests with 682 assertions (55 Kimi adapter tests and nine
version tests). Results and log hashes are retained in
`work/new-website-providers-20261102/build386/final-source-gates.json`.
The installed reproduction below captured the missing stage; these diagnostic
fixture passes do not establish a fix or Kimi qualification.

A separate normal-UI observation on installed385 found that Accessibility Press
on More models left the submenu closed, while pointer hover opened the checked
K3 row. The top menu was dismissed without changing a model or sending a prompt.
Screenshots are retained as `build386/kimi-more-axpress385.png` and
`build386/kimi-more-hover385.png` under the workspace evidence directory. This is
UI interaction evidence, not proof of how the adapter's DOM event behaves.

### Build386 reproduction and candidate387 hover interaction

The signed build386 was installed and verified as process 41226. One fresh
startup discovery reached the deadline with `phase=moreOpening`, a present,
expanded main menu, and a claimed but absent, collapsed submenu. The same
finite state was retained before cleanup. The existing DOM observer accepted
17 events; no prompt was submitted. The exact log and evidence receipt are
`build386/kimi-startup386-complete.log` and
`build386/kimi-discovery386-evidence.json` in the workspace evidence directory.

In a normal signed-in Kimi tab on the same build, hovering over More models
opened the checked K3 row; moving into blank page space closed the submenu
while leaving the main menu open. The main menu was then dismissed without
changing the model or sending a message. No Web Inspector setting was enabled.

Candidate387 changes only the claimed submenu interactions to `pointerover`
and `pointerout`. It keeps the exact physical controls, ARIA relationships,
checked-row proof, native deadline and later Instant selection verification.
An unacknowledged event remains spent; there is no click fallback or sequence
of alternate events. This is a reversible interaction hypothesis requiring a
fresh live discovery, not a claim that synthetic events already work on Kimi.

The candidate387 gate passed 44 native tests, including delayed actual-WebKit
submenu acknowledgements with one entry, one exit, zero submenu clicks and
zero Send actions. The combined JavaScript/version gate passed 72 tests with
799 assertions. The prior click implementation fails the new hover-only
fixture. These fixtures validate the candidate mechanism and protections;
live discovery and response checks remain required.

### Build387 result and shared provider foundation

Signed installed build387, process 46928, again reached the discovery deadline
at `moreOpening`. The exact claimed submenu remained absent and collapsed;
the main menu remained present and expanded. No prompt or marker was sent.
Evidence is `build387/kimi-startup387-complete.log`. The local pointer-event
fixtures passed, but did not represent a website listening to legacy mouse
events. The next candidate tests a fixed boundary sequence rather than retrying
the spent live operation. Normal pointer input can include mouse compatibility
events; see the [W3C mapping](https://www.w3.org/TR/pointerevents3/#compatibility-mapping-with-mouse-events).

Qwen and DeepSeek now share the saved-conversation state machine and strict
native deletion lease. DeepSeek has typed Chat/DeepThink mode intent/evidence,
separate from named model evidence; Search must be off and no backend model
version is asserted. Its request IDs are `browser/deepseek/mode/chat` and
`browser/deepseek/mode/deepthink`. Qwen admits only the observed Plus/Max
choices when its public pilot is enabled.

Canonical shared engine, provider DOM drivers, generation command and fixtures
are included under `Scripts/EmbeddedSavedProviders` and
`Scripts/embedded-saved-provider-resources.ts`. Generated-resource equality is
tested; a clean checkout does not depend on private workspace source files.
The first integrated foundation gate passed 98 native tests and 89 JavaScript
tests with 1,636 assertions. Two test compilation gaps (an exhaustive provider
switch and an optional Boolean assertion) were corrected before that pass.
Logs remain under `build388/native-foundation*.log` and `js-foundation.log`.
These are local foundation results, not installed provider qualification.

### Candidate388 integration corrections

The Kimi candidate now dispatches one fixed pointer-and-mouse boundary sequence
for each claimed submenu entry or exit. Every event retains the exact physical
target and ownership checks; a partial or unacknowledged operation cannot replay.
Native WebKit fixtures accept its exact legacy mouse-coordinate flooring only
when the delivered point still hits that same bound control. This changes the
fixture's representation check, not production targeting or verification.

The initial integrated native suite exposed a missing DeepSeek engine metadata
prefix: the tool catalog had been seeded from UI options, but DeepSeek has no
selectable default model. Registered provider prefixes now supply the pinned
terminal and freeform patch capabilities independently of UI defaults. Request
admission still requires an exact supported model or mode. DeepSeek failure
history now also rejects a bare provider ID. An older mixed-provider prompt test
was updated to expect the observed raw-JSON format for Qwen and DeepSeek.

Qwen's two observed named models and DeepSeek's two observed modes are enabled
for controlled pilot testing. A separate validated mode cache and shared startup
queue preserve their identities. Actual WebKit-to-server fixtures exercise all
four selections through response publication and durable saved-chat cleanup.
Finite adapter failure identifiers are captured once per owned session for all
three saved-chat providers; page prose, URLs and exception text are excluded.
Installed replies and tool workflows remain separate required evidence.

The combined candidate388 native gate passed 421 tests with no failures,
including the new provider server/cleanup paths and existing provider regressions.
The JavaScript/resource/version gate passed 168 tests with 2,767 assertions;
the provider selector passed 23 tests with 420 assertions, type checking and
the production WebUI build. Earlier failed runs remain retained alongside the
passing logs under `build388/`. These results do not establish live qualification.

### Installed build388 result

Build388 (`239e343`) was signed, installed and launched as process 61936.
Kimi discovery now fails immediately with `more_binding`; the earlier timeout
became a concrete rejection, but the grouped guard does not yet identify its
cause. Qwen discovery similarly fails with a detail-less `model_unverified`.
Neither provider received a native prompt. DeepSeek discovered both modes.

One fresh DeepSeek Chat marker was submitted once. Selection evidence proved
Chat with Search off at dispatch, but the first post-send inspection failed
`mode_unverified`, and native saved-chat cleanup remained unconfirmed. The task
has no accepted answer or tool call and remains a failed qualification record.
Reopening that exact synthetic conversation in the normal browser showed the
expected raw-JSON marker response and Search on. This later UI observation does
not prove the earlier failing state or rule out replaced controls. The synthetic
conversation was manually deleted through its scoped menu and confirmation;
the root route, empty composer and absent test history entry were observed.
The original native failed/unconfirmed receipt was not rewritten.

Evidence: `build388/provider-startup388-complete.log`,
`build388/deepseek-chat388-marker-a-capture/summary.json` and
`build388/deepseek-marker-manual-cleanup.json`. Candidate389 adds only finite
diagnostic reasons at these existing checks. It does not relax their acceptance,
repeat a spent operation or claim that the underlying live issue is repaired.
Its focused gate passed 68 native WebKit/diagnostic tests and 176 JavaScript,
resource and version tests with 3,225 assertions. Fresh installed diagnosis is
still required; the build388 failure is not converted into a pass.

### Installed build389 diagnosis and candidate390

Build389 (`0f3f358`) reached Kimi's `moreClosing` phase before rejecting
`picker_menu_binding`. Offline tests reproduce the rejection when a claimed
close updates ARIA and physical visibility in separate steps. Candidate390
waits for both acknowledgements of that one close, retaining the previously
verified control, menu, checked selection and owner. It never replays entry,
exit or click events. The exact live acknowledgement order remains unproved.

Qwen rejected `picker_open_occluded` before its first picker click. Initial
readiness now requires the retained trigger to pass the same hit test used
immediately before dispatch. Existing DOM events wake the pending read within
the original preparation deadline. A permanently obstructed or replaced
control still fails without input. Pure paint or animation completion without
an observed DOM change can still reach that deadline; the live obstruction's
source has not yet been identified.

One fresh DeepSeek Chat request failed `first_user_message` about 370 ms after
dispatch, before any answer or tool call was accepted. Native cleanup remained
unconfirmed. Read-only inspection of that exact synthetic conversation later
found the full prompt and expected JSON reply. Its collapsed controls contained
no extra text, and the settled structure satisfied the current body checks.
This does not identify which initial check failed. Candidate390 adds finite,
content-free reasons for the existing prompt, structure and binding guards;
none of their acceptance conditions change. No failed prompt was replayed.
Temporary Inspector settings were restored.

Candidate390 passed 73 focused native WebKit/diagnostic tests, plus 186
JavaScript/resource/version tests with 3,686 assertions across two disjoint
runs. These are fixture results, not installed-provider qualification.
Review also caught that the new diagnostic details would otherwise lose the
native `first_user_message` failure category. An exact DeepSeek-only finite
mapping preserves that category and its recorder while keeping the detailed
adapter diagnostic. Unknown details and other providers cannot use the mapping.
The final mapping correction passed 23 focused native tests, including a real
WebKit changed-body failure with no answer, replay or deletion authority. These
overlap the earlier 73-test run and are not additional independent coverage.

### Installed build390 results

Signed build390 (`046f348`) launched as process 79931. Kimi startup discovery
completed. Its live trace captured the exact split close: the same submenu
remained present after ARIA became collapsed, then disappeared; the main menu
also acknowledged ARIA before disappearance. This confirms the timing case
addressed by candidate390 for that discovery run.

The first fresh Kimi Instant marker task failed during model selection with
`more_center_changed`, before website Send. It has no response or tool result.
Qwen startup progressed past the initial hit check, then failed
`picker_menu_collapsed`; no Qwen prompt was sent. These are separate remaining
selection failures, not provider qualification passes.

One fresh DeepSeek Chat marker failed `first_container_children` at the first
post-send inspection. The new diagnostic identifies the rejected structural
condition, but not the extra child's identity. Native ownership remains
`first_user_message`; no answer or tool call was accepted. Kimi and DeepSeek
cleanup receipts remain unconfirmed. Neither failed request was replayed.

Evidence is retained under `build390/provider-startup-and-markers390.log`,
`kimi-instant390-marker-a-capture/summary.json` and
`deepseek-chat390-marker-a-capture/summary.json` in the workspace evidence
directory. All native/signed/install/launch receipts bind this exact build.

### Candidate391 targeting, close acknowledgement and structural capture

Kimi retains each boundary's original coordinates. A small layout shift can
move the center while leaving that fixed point inside the same physical target;
exact center equality was not needed to establish that hit. The candidate
requires the original point to remain inside the current rectangle/viewport and
hit the same bound control, alongside the existing ownership, ARIA, selected-row
and event-sequence checks. Movement outside, occlusion or replacement remains
terminal; coordinates are never recentered and events are never replayed.
Each constructed event is checked too: WebKit's exact legacy mouse-coordinate
flooring must still be inside and hit that target. Fractional rectangle edges
are checked independently because native hit testing can include such an edge.

Qwen's driver observes split DOM/ARIA completion only for the engine's already
claimed final close. A still-visible menu must remain the same physical menu
with the same checked row, selected label and verified choice list. Both
visibility and ARIA must close before selection proof is published. Other
phases retain their strict checks and the native preparation deadline.
The model option's automatic close has a separate claimed pending phase. Its
label and checked row may acknowledge the prior choice or exact clicked target
in either order; the retained menu, target and choice list cannot change. Both
close channels and the target label must settle before one fresh reopening
verifies the checked row. Pending option state never publishes model evidence.

DeepSeek's child-count rejection remains unchanged. The rejected read now
provides capped child counts, tag enums and text-equality/emptiness flags from
those same nodes. Native code reconstructs exact fields and types, emitting at
most five bounded records under the existing once-per-session failure latch.
Prompt text, URLs, classes and arbitrary page metadata are excluded. The packet
is diagnostic only and cannot authorize an answer, another Send or deletion.
The first native run exposed two incorrect new fixture assumptions: failed
started sessions retain their owned views, and WebKit can hit a fractional
edge outside the DOM rectangle. The fixture expectations were corrected while
keeping explicit coordinate bounds, event counts and no-input checks intact;
no production cleanup or targeting rule was relaxed to satisfy those assertions.
The final combined candidate passed 84 focused native WebKit/diagnostic tests
and 203 JavaScript/resource/version tests with 4,414 assertions in two disjoint
runs. Independent read-only review found no new authority or replay regression.
Installed responses and cleanup are still required before qualification.

### Installed391 and candidate392

Installed391 was verified against its signed artifact and running executable.
A name-only macOS launch initially selected an older staged app; the identity
check caught it before any baseline or prompt. That copy was closed and the
installed app was launched by its absolute path. Subsequent cases bind PID90113,
the exact source commit and all four artifact/install receipts.

Kimi and Qwen startup discovery succeeded. One fresh Instant task failed before
website Send at `inspect / model_unverified / picker_menu_binding`, sequence0,
after 2,735 ms. A fixture reproduces that failure when an already-clicked option
collapses ARIA before its menu disappears. A separate still-open transition
also exposed row-processing fallthrough. The installed diagnostic does not yet
distinguish those guards. Candidate392 retains the claimed option, physical
menu/trigger/target, prior or exact target selection and unchanged ordered
choices during the pending close. It withholds model evidence until DOM, ARIA
and the requested label settle, then opens once for fresh checked-row verification.
It never repeats the option click, extends the deadline or adopts replacement
controls. Finite diagnostic reasons distinguish any remaining binding failure.

One fresh Qwen Plus task failed after 3,595 ms. The native UI showed a high-demand
message, but its retained provider failure was `unexpected_website_page`.
The bounded native log identifies `submit / after / sequence=1`, with settled
navigation and no navigation error. The submit invocation may have dispatched
before rejection; the task must not be replayed. The runtime converts HTTP500
into generic high-demand wording, so that text is not evidence of a provider
capacity limit. No rejected URL shape was retained in this run. Selection or
submission proof was not published, and its cleanup remains unconfirmed.

Candidate392 logs only closed route-shape enums and booleans, never URL values,
identifiers or unknown query keys; route admission is unchanged. Unexpected-page
errors now use HTTP400 with the existing full typed error body. The pinned
runtime maps this to nonretryable `InvalidRequest`; HTTP500 becomes generic
high demand, and the initially considered HTTP409 takes an outer retry path.
The latter was discarded before installation. The actual bundled-engine fixture
also examines raw protocol errors, since the app's saved failure history can
replace a generic engine message and otherwise make a UI-only check misleading.

One fresh DeepSeek Chat task verified Chat mode with Search off and its
submission, then failed after 1,268 ms. The primary provider failure was recorded
at 11:08:19.319Z and the raw engine terminated at 11:08:19.332Z. The retained
native error identifies `modelUnverified`; its precise initial DOM observation
was not retained. The `first_container_children` packet arrived later, at
11:08:19.415Z, during cleanup. It shows two container children: the first DIV
contains the complete prompt leaf; the second is an empty DIV with no element
children. Entire-root and entire-container text equal the prompt leaf.
Candidate392 permits only that empty noninteractive decoration beside the
existing prompt wrapper while preserving unique body, whole-text equality,
exact digest/private marker, physical nodes, canonical route and all action
checks. This fixes the observed cleanup-read blocker; it is not evidence of
fixing the earlier primary failure. Optional mode-evidence reads can return
no proof for several distinct conditions without retaining their reason, so
a source path is identified but no particular initial condition is established.

All three failed native records are preserved. None produced an accepted answer
or tool result, and later website rendering does not change their outcome.
No failed operation was replayed. The prepared browser/terminal/file workflows
remain unstarted until a selection passes its response and cleanup checks.

Candidate392 passed 86 distinct native tests and 208 JavaScript/resource/version
tests (5,258 assertions). The native total combines 15 DeepSeek tests, 69 Kimi,
Qwen and diagnostic tests, the corrected HTTP gate, and one actual bundled-engine
regression. Initial HTTP-fixture failures were caused by missing synthetic Qwen
model proof; the fixture now supplies explicit proof before the intended failure.
The initial engine gate also incorrectly expected API-only streaming fields in
Qwen's compact website prompt. Its corrected assertions require those fields
absent while retaining the exact user task and tool schemas. Production selection
and prompt projection were not weakened. The passing engine gate verifies the
raw terminal error JSON, no retry notification, one provider start/Send/finish
and zero tools or assistant answers. These are native-action counts, not a count
of all HTTP requests. Installed provider qualification remains pending.

### Installed392 results and bounded candidate393 evidence

Build392 was signed, installed and matched to source
`a7d4d774659ab6b028e8000b9870e6d95bd58f10`, its four artifact/install receipts,
and the running executable (PID5490). One fresh zero-tool marker was submitted
per selection; these failed records are retained separately:

| Selection | Duration | Observed failure | Cleanup |
| --- | ---: | --- | --- |
| Kimi Instant | 2,159 ms | `sendReady / composer_unavailable`, sequence0; no website Send | Closed, `not_created` |
| Qwen3.7-Plus | 3,048 ms | `unexpected_website_page` at `submit / after`, sequence1 | Unconfirmed |
| DeepSeek Chat | 1,343 ms | Primary `browser_model_error` after mode and submission proof; detailed initial condition not retained | Unconfirmed |

Kimi startup discovery separately rejected `picker_menu_scope`. The marker
still reached the pre-Send readiness check, where the exact unavailable control
was not retained; these observations must not be collapsed into one cause.

Qwen's first rejection was at 11:49:36.529Z; cleanup repeated the same finite
route shape 97 ms later. Its expected HTTPS origin had a `/c/` path whose token
was not a UUID, with no encoding, trailing slash, port, query, fragment or user
info. Earlier direct Plus/Max captures showed only lowercase UUID routes. The
actual token and whether it represents a transient provisional conversation
remain unknown. Send may already have dispatched; it was not replayed. The
native terminal now preserves the full `unexpected_website_page` model error,
`retryable: false` and `required_action: inspect_website`, without high-demand
text. No selection/submission proof or answer was released.

DeepSeek's primary journal failure was recorded at 11:51:48.535Z and its engine
terminated at 11:51:48.550Z. The `deepthink_replaced` diagnostic arrived at
11:51:48.605Z during cleanup, after an exact first-body read. It establishes
that the required cleanup read saw a different DeepThink node, not which
condition caused the initial optional mode-evidence read to fail. Current mode,
Search-control replacement and old composer/control connectivity are not all
established by that packet. No mode repair, control adoption or Send replay was
performed.

Candidate393 stages finite Qwen segment/token length, character-class and
reserved-prefix classifications without raw identifiers or broader admission.
DeepSeek's candidate retains the first negative optional mode-evidence packet
before cleanup can obscure it, using fixed booleans and reason enums only.
These are diagnostic proposals, not demonstrated fixes or installed results.
Kimi's bounded unsent composer inspection is separate from provider qualification.
One normal empty Kimi tab received a 21,723-character synthetic draft, without
Send. The settled text matched its exact SHA-256 and retained the same editor,
scope and Send controls: one `P[dir=ltr]`, one lexical span and one text node.
The editor extended above the viewport inside a scrolling ancestor. The current
viewport-only hit point was outside that ancestor's visible area; its center
hit the same editor. Candidate393 corrects this editor-only clipping calculation
and still requires a topmost hit inside the exact editor. Native confirmation
remains pending; this probe alone does not prove the cause of the earlier task.
The synthetic draft was cleared, no conversation was created, the test tab was
closed, and both temporary Inspector settings were restored.
Candidate393 passed 91 distinct native tests and 163 JavaScript/resource/version
tests (4,831 assertions). The real WebKit regressions reproduce the old hit-test
failure with a long exact draft in ordinary and transformed scroll containers,
then verify one Send and owned deletion. A real overlay still prevents Send and
reinsertion. Its first run expected the wrong native error variant; correcting
only the test to assert the existing `editorFailure("composer_unavailable")`
made that focused rerun pass. The initial failure log is retained. DeepSeek's
same-read diagnostic regression preserves its initial remount reason through
later cleanup, with unchanged mode rejection and action counts.
The five prepared browser/terminal/file fixtures remain unstarted until the
corresponding native response and durable cleanup gates pass. Qwen Max and
DeepThink were not submitted in this build392 marker set.

### Installed393 results and candidate394 boundaries

Signed build393 was installed and matched to source
`e39490152c7f463bb4c5b4382ba78cf0707a2f04`, its artifact/install receipts and
running executable (PID20347). One fresh zero-tool marker per selection failed:

| Selection | Duration | Primary observation | Cleanup |
| --- | ---: | --- | --- |
| Kimi Instant | 2,361 ms | Verified Instant and Send handoff, then `inspect / conversation_changed / first_user_message` | Unconfirmed |
| Qwen3.7-Plus | 3,228 ms | `unexpected_website_page` at `submit / after`, sequence1 | Unconfirmed |
| DeepSeek Chat | 1,255 ms | Initial optional mode proof rejected after the complete composer/control replacement | Unconfirmed |

Kimi's submission record at 12:26:24.613Z contains an empty first-user fingerprint,
so it is not proof of the complete website echo. The first ownership error at
12:26:24.653Z preceded task failure and cleanup. A read-only normal-browser reload
of that exact saved conversation later showed the requested marker response and
a visible, connected SPAN with one text node, no element children, equal valid
root/turn UUIDs and one valid final session-marker suffix. Its 62,794-character
body was unchanged by NFC and contained no terminal LF, CR or NBSP. Expected full
outbound bytes/fingerprint were not retained, so exact outbound equality and the
failed-time predicate remain unknown. This later website response does not
change the failed native result. The saved conversation was retained; only the
normal inspection tab was closed and developer settings restored.

DeepSeek's first negative mode packet at 12:28:47.493Z now precedes failure and
cleanup. The previously pinned composer, DeepThink control and Search control
were all disconnected and replaced; the current mode still matched Chat with
Search off, and no first body had been bound. This identifies the primary
rejected observation, unlike the cleanup-only packets from 391/392. It does not
authorize automatic adoption of replacement controls or establish a final answer.

Qwen's native failure retained only a finite eight-byte ASCII slug beginning
with `new`, not the full token. A separate one-Send normal-browser probe observed
the exact same-document sequence root → `/c/new-chat` → canonical UUID. The exact
provisional path appeared 57 ms after Send, lasted 727 ms, and became canonical
at 784 ms. One exact user and answer were observed. The direct probe conversation
was manually deleted through its scoped confirmation; the fresh root, empty
composer/transcript, disconnected captured nodes/dialog and absent history
reference were verified. Its test tab and developer settings were restored.
This direct response/deletion does not qualify the native adapter or resolve
its original failed cleanup receipt.

Candidate394 splits Kimi's existing first-user checks into finite reasons while
preserving predicate order, native ownership classification, verification and
one-time logging. The DeepSeek source candidate permits only a held, complete
initial composer replacement after the acknowledged single Send. Pending reads
carry no mode, body, answer or cleanup authority; exact first-body/hash and fresh
Chat/DeepThink/Search proof must establish the handoff before normal processing.
Partial, repeated, foreign or already-bound replacements remain failures.
Qwen's exact `/c/new-chat` transition has a narrowly scoped provisional path;
it grants no conversation identity, response or deletion authority before
canonical first-body verification. The integrated source passed 115 distinct
native tests and 226 JavaScript/resource/version tests (6,481 assertions).
Real WebKit cases cover the post-Send placeholder, a read crossing canonical
promotion, both Qwen models, both DeepSeek modes, strict negative observations,
unchanged deadlines, no replay and durable owned deletion. Three test-only
compile/assertion issues were corrected; no unresolved test failure remains.
Packaging and fresh installed qualification are pending; no live394 pass is claimed.
Qwen Max, DeepThink and all prepared browser/terminal/file workflows remain
unstarted in this 393 marker set. Evidence is retained privately under
`work/new-website-providers-20261102/build393/` in the three marker-capture
summaries, `kimi-settled-first-user-probe.json` and
`qwen-exact-new-chat-probe.json`.

### Installed394 fresh native results

Signed 0.8.0 (394) was installed, with its exact running executable and all
artifact receipts matched to `80b917bff6f38e30654a789c476c3801f9ebd748`.
The source checks passed 115 distinct native tests and 226 JavaScript/resource/
version tests; installed outcomes remain separate:

| Selection | Duration | Result |
| --- | ---: | --- |
| Kimi Instant | 2,627 ms | First-user ownership rejected as `first_root_id_invalid` |
| Qwen3.7-Plus | 3,412 ms | Post-Send route progressed; initial answer rejected as `response_scope` |
| DeepSeek Chat | 5,878 ms | Exact response completed; cleanup rejected at `selectConversationDeletion / delete_phase` |

Kimi's primary error occurred 57 ms after its acknowledged Send. The ID was
absent or not UUID-shaped; this does not yet prove its actual temporary format.
Qwen's error occurred 456 ms after acknowledged Send and before first-body
adoption. The existing compound response-scope predicate still needs a precise
initial-DOM observation. DeepSeek accepted ownership/current Chat mode and
observed completion at 13:17:54.209Z; its later deletion-stage error at
13:17:55.974Z withheld release. It is not a native-final or cleanup pass.
All three tasks retained failed/unconfirmed cleanup evidence. Qwen Max,
DeepThink and tool workflows were not started. Fresh394 workflow fixtures remain
prepared only. Evidence is private under the build394 marker-capture directories
and `provider-live394.log`.

### Candidate397: Kimi initial user identity and DeepSeek cleanup diagnostics

The build394 Kimi marker failed `first_root_id_invalid` 57 ms after Send
acknowledgement. A separate owned browser probe observed one exact first-user
body on the provisional route with both ID attributes present but empty and
no assistant message. About 1.3 seconds later, a different physical user root
carried matching UUIDs before canonical route promotion. This establishes a
legitimate website phase; it does not reconstruct the original native page's
exact attribute values.

Candidate397 waits on only that initial empty-ID state. The existing native
gate requires the single acknowledged Send, pending first body and no bound
conversation. The adapter additionally requires one visible leaf body matching
the full sent prompt and marker, zero answers, the same provisional route and
verified selected model. The observation grants no response, fingerprint or
cleanup authority and does not retain the temporary root. Normal canonical
route, UUID, turn linkage, full-body hash and physical identity checks still
establish ownership after replacement. Deadlines, cancellation, action counts
and cleanup verification remain unchanged; no prompt is replayed.

DeepSeek's build394 response completed before saved-chat cleanup failed with
`delete_phase`. Candidate397 distinguishes six existing cleanup predicates
using fixed diagnostic labels. It preserves their evaluation order, DOM reads,
failures and actions. A closing menu remaining visible after the sole Delete
row click is a hypothesis, not a proved cause or repaired transition. The shared
deletion engine and its one-dispatch policy are unchanged.

The integrated source passed **65 distinct native tests** (46 Kimi transport,
19 saved-adapter diagnostics) and **150 JavaScript/version tests** with
**4,657 assertions**. Real WebKit cases cover physical user replacement, exact
proof before response/deletion, invalid evidence, fixed deadline, cancellation
and no late revival or second Send. The current source hashes match the two
reviewed candidates; counts are taken from unique test cases and final suite
summaries, without adding overlapping summaries.

At documentation preparation, build396 remains installed. Packaging and fresh
native model qualification of397 are pending. Earlier Kimi, Qwen and DeepSeek
failures and unconfirmed cleanup remain failed records. No new reply,
browser/terminal/file workflow or live cleanup pass is claimed. Evidence is
retained privately under `work/new-website-providers-20261102/build397/`, with
source/test hashes in `final-source-gates.json`.

### Direct website observations before native qualification

Kimi's approved test tab uses `https://www.kimi.ai/`. Its model menu offered
K3.1 Pro, K2.8 Preview and Instant, plus K3 in the More models submenu. Two
harmless Instant JSON marker requests returned the exact expected objects.
No local tools were requested. The second approved Inspector check captured
the Lexical composer, enabled Send, exact user/assistant containers, literal
JSON code and assistant action rail. Thinking/tool-flow nodes are separate
from the final answer; an adapter must not treat their text as response text.

Submission first changed to a provisional `/chat/p…` route, then a final
`/chat/…` identifier. The adapter must bind any transition to the exact first
user message and owned document rather than adopting an arbitrary new URL.
Kimi uses a Lexical contenteditable composer and explicit saved-chat deletion.
For the synthetic conversation, the current-chat menu's Delete action opened
a confirmation; confirming once returned to the home page, cleared the
composer and removed that test row from rendered history. No deletion toast or
remote-erasure guarantee was established. This manual UI observation does not
alone establish an automated deletion-completion contract. The second test
confirmed the current header's ARIA-linked menu, a `confirm-dialog` with a
dedicated confirmation button, and the subsequent empty home page with no
test entry. Both test conversations are deleted. The original K3/High
selection, split position and developer settings were restored. No more
than the two approved messages were sent to the inspected Kimi tab.

Qwen is now signed in in Computa. Two bounded direct website checks on build382
selected Qwen3.7-Plus and Qwen3.8-Max, sent one harmless marker each and observed
the exact requested replies. Each test conversation was deleted through its
scoped menu and confirmation; the post-delete observations were retained.
These were direct website/DOM checks, not native harness requests or API tests.
The native Qwen adapter, completion/ownership contract and tool workflows remain
unqualified. Evidence is retained privately as `qwen-plus-direct-observation.json`
and `qwen-max-direct-observation.json` in
`work/new-website-providers-20261102/`.

DeepSeek is now signed in through the recognized existing account. Two bounded
direct checks, with DeepThink off and on, returned the exact raw JSON markers.
Each owned test conversation was deleted through its history entry and modal;
the fresh route, empty composer/transcript and absent test entry were verified.
Its page exposes a DeepThink mode toggle, not a named backend model picker.
Both responses had already finished by the first read, so a negative streaming
completion check and native harness qualification remain pending. Existing human
conversations were untouched. All three provider Inspector settings and Safari's
developer setting were restored after the approved two-message-per-provider scope.

## Remaining gates

1. Install the gated Kimi initial empty-ID wait and require a fresh native
   Instant reply and durable deletion without weakening full-body ownership.
2. Resolve Qwen's initial answer identity transition and use DeepSeek's finite
   cleanup diagnostics to identify its failing predicate; require fresh native
   responses and cleanup without replay for both providers.
3. Verify DeepSeek's completion signal while an actual response is still streaming.
4. Preserve negative fixtures for foreign routes/models, partial/repeated remounts,
   uncertain Send, lost ownership and delayed/unconfirmed deletion.
5. Record each installed selection's actual browser, terminal and file results
   with durable cleanup. Fixture passes and direct markers are separate evidence.
