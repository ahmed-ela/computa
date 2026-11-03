# Kimi, Qwen and DeepSeek website adapters

Status: installed 0.8.0 (400), source `9d0c06f`. The fresh controlled
native checks still fail independently: Kimi Instant stops at
`authored_source_markdown_count`; Qwen3.7-Plus stops at
`initial_response_body / full_prompt_mismatch`; DeepSeek Chat completes its
first inference and one terminal read, then rejects the second response's
literal source. Kimi and both DeepSeek inference sessions have verified deletion
receipts. Qwen cleanup remains unconfirmed. No failed Send was replayed and no
combined workflow passed. PR #20 remains draft.

Candidate401 adds explicitly armed structural diagnostics at the existing
rejections, before cleanup removes the page. The diagnostic path records only
bounded counts, finite shape categories and comparison measurements. It neither
accepts new response shapes nor supplies ownership, model or execution proof.
This is preparation for the next root-cause observation, not a provider fix.
The integrated candidate passed 303 native tests and 330 JavaScript tests
(19,172 assertions). Native checks cover exact task/model identity, a later
inference failing after an earlier success, capture before cleanup, page
replacement during file preparation, one-shot publication and private storage.
Two new fixture defects were corrected: Foundation's shortened `/var` path was
replaced with the existing POSIX-realpath helper, and the expiry boundary uses
an exact timestamp. Production checks and test assertions were unchanged.
A separate normal-tab Kimi probe used `kimi.com`, while the adapter uses
`kimi.ai`; that unsent, signed-out probe was cleaned up and is excluded from
production-provider evidence.

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

### Installed397 results and next transition fixes

Signed build397 (`e8055b34b072bead7a6bc206662f45421fcfe565`) was installed
with source, package, signature, installed-file and running-process receipts.
Each fresh marker was dispatched once. Neither is a qualification pass:

| Selection | Duration | Result |
| --- | ---: | --- |
| Kimi Instant | 2,717 ms | Required model evidence rejected 50.6 ms after Send; no final answer; cleanup unconfirmed |
| DeepSeek Chat | 4,118 ms | Response and Chat mode verified; deletion confirmation read rejected the still-visible menu; no released final answer; cleanup unconfirmed |

Kimi's `detail=absent` means its error supplied no predicate detail, not that
the model control was absent. The next diagnostic distinguishes the existing
five model-evidence predicates and their call stage; it changes no acceptance
condition, action or recovery behavior.

DeepSeek's new finite diagnostic was `delete_confirm_menu_still_visible` in
`selectConversationDeletion`. The engine reads confirmation immediately after
clicking Delete, before the website necessarily removes the menu. The candidate
waits without a confirmation target only for the same pinned menu, before any
dialog has been bound. Foreign, duplicate, authored or returning menus and
changed conversation ownership still fail. The original deadline, one-click
claims and full dialog/deletion checks remain required. The DOM regression
fails on the previous code and passes with this change.

A separate Qwen3.7-Plus direct website probe on installed396 observed an answer
container with the exact ID prefix but an empty UUID suffix at 415 ms after
Send, still empty after canonical route promotion at 844 ms, and valid on the
same nodes at 2,019 ms. Full prompt, selected model, user UUID and physical
ancestry checks held. The exact marker returned and its test conversation was
deleted once with root, empty composer and history-absence checks. Developer
settings and test tabs were restored. This is direct website evidence, not a
native harness pass or retroactive proof of build394's exact DOM.

The Qwen candidate grants only an explicit negative initial-identity wait while
those strict predicates hold. UUID settlement must re-enter normal ownership
and response proof. A Qwen-only ID mutation wakeup makes that transition
observable; generic canonical `ownershipPending` remains prohibited. The
integrated adapter suite passed 302 JavaScript tests with 8,463 assertions,
plus nine version tests with 56 assertions. All 121 distinct native tests passed:
23 DeepSeek transport, 26 Qwen transport, 46 Kimi transport, three Kimi model
diagnostics, 19 saved-adapter diagnostics and four Qwen server pending-contract
cases. Native coverage includes both Qwen models, both DeepSeek modes, exact
negative packets, ID-only wakeups, delayed menu removal with and without dialog
overlap, foreign/replaced menus, one-dispatch claims and unchanged deadlines.
These candidates were installed as build398; fresh results follow below.
Failed397 tasks were preserved and no provider submission was replayed.
Evidence is private under the build397 and build398 workspace directories.

### Installed398 results (2026-11-02)

Signed build398, source `6692a5c8eb7eec4a1acbb7ce5b65e02634c9906a`,
has verified source, package, installed-file and running-process receipts.
Each fresh marker was sent once:

| Selection | Duration | Result |
| --- | ---: | --- |
| DeepSeek Chat | 5,300 ms | Exact final marker, Chat/Search-off proof and durable deleted-conversation receipt |
| DeepSeek DeepThink | 5,475 ms | Exact final marker, DeepThink/Search-off proof and durable deleted-conversation receipt |
| Qwen3.7-Plus | 4,100 ms | First-user ownership rejected; no final answer; cleanup unconfirmed |
| Kimi Instant | 2,604 ms | Initial model-trigger replacement rejected; no final answer; cleanup unconfirmed |

Both DeepSeek records passed independent marker audits. Their closed journals
had moved into the existing retention database; exact task/turn byte strings,
stored hashes and cleanup receipts were joined without replay or reconstructing
evidence. Neither marker establishes browser, terminal or file-edit qualification.

Kimi's finite diagnostic identifies `model_evidence_trigger_replaced` during
`optimistic_first`: Send was claimed, no first body was bound, the original
picker trigger was disconnected, and the unique closed replacement retained
the exact selected label. This is a specific DOM-lifecycle mismatch, not an
account limit. Qwen's `first_user_message` remains a compound predicate; the
failure alone does not identify whether its ID, chat link, visibility or parent
structure changed. Qwen Max remains untested on398 after this failure.

The failed tasks and unconfirmed cleanup records remain intact. No uncertain
Send was replayed. The complete selectable-model workflow matrix, Claude
failures and Gemini verification block remain open.

### Candidate399: first-submit picker replacement and durable errors

Kimi can now revalidate one detached model trigger during the observed
optimistic first-user window, after the sole Send returns its acknowledgement.
The prior checked selection/catalog, exact complete echoed prompt and original
outbound digest remain required. The new unique, closed picker, first-user
nodes, owner, document, route and composer must stay stable across the digest
check. A second replacement, returning old trigger, different model or changed
prompt fails. The result remains negative/pending until normal canonical
first-user and response verification succeeds; it cannot authorize cleanup.

Qwen adds failure-only first-user predicates distinguishing visibility, message
ID, chat-ID link and parent structure. Its error category, ownership rejection
and one-dispatch behavior are unchanged. Only finite booleans/enums enter the
native log; page content, identifiers and URLs do not.

The history fix in `027c80e` preserves the exact fixed native model-verification
and cleanup envelopes instead of silently losing them and restoring a generic
engine error. Unknown prose and extra metadata remain rejected, and failed
persistence is reported. It passed 55 focused native tests, including cold
runtime restoration without provider replay. Previously lost diagnoses are not
guessed from generic historical errors. Build399 was subsequently installed;
its fresh provider results are recorded below.

The integrated399 source passed 123 distinct native adapter/diagnostic tests
and 324 JavaScript/version tests (9,857 assertions). The native Kimi regression
verifies a first-trigger replacement through exact Instant selection, canonical
reply and once-only deletion, and rejects second/canonical replacements without
replaying Send. The separate 55-test history gate still matches its unchanged
implementation/test files; these are separate results, not duplicate counts.

### Installed399 results and candidate400 (2026-11-02)

Signed build399, source `972bca697ed8b3dc0441e2ed9f7ec1675e683a36`, has
matching source, signed-package, installation and process receipts. These fresh
controlled tasks were each dispatched once:

| Selection / task | Duration | Result |
| --- | ---: | --- |
| Kimi Instant / marker | 17,078 ms | Exact selection/submission verified, then `unsupported_website_response` / `authored_source`; no final or tools; saved deleted-session receipt |
| Qwen3.7-Plus / marker | 3,890 ms | Exact selection/submission verified, then `website_ownership_unverified` / `first_user_message`; no final or tools; cleanup unconfirmed |
| DeepSeek Chat / combined workflow | 17,100 ms | Four successful terminal reads across two completed inferences; third reply rejected as invalid JSON (867 bytes); no edits, tests, browser receipt or final; saved-session deletions recorded |
| DeepSeek DeepThink / combined workflow | 7,200 ms | `unsupported_website_response` before any tool or final; fixture unchanged and no browser receipt; cleanup journal records saved deletion |

Kimi passed the earlier initial model-trigger gate, but the broad authored-source
error did not identify its exact failed format predicate. Candidate400 applies
the existing exclusion of recognized reasoning regions consistently before
counting authored markdown, and emits finite reasons for each format guard.
Unknown regions, multiple authored sources, outside prose and changed ownership
remain rejected. This is not a live diagnosis of the uncaptured failed body.

Qwen's prior DOM-predicate diagnostic did not identify the shared-engine guard
that rejected this task. Candidate400 adds failure-only stage/reason tags for
provisional and initial-response admission, complete-body hashing and pinned
first-user binding. Native exact-key and stage/reason allowlists reject arbitrary
text. The original error/detail, ownership predicates and terminal behavior are
unchanged. The root cause remains unknown until a fresh bounded capture identifies
it; no speculative ownership relaxation is included.

DeepSeek's failed workflow supplied no rejected-reply capture. A separate bounded
direct observation then showed one complete JSON code block rendered as a PRE
with syntax-highlight spans and a `json`/Copy/Download header. The old reader
accepted only the observed raw paragraph shape. Candidate400 adds that exact
single code-block source, verifies its complete surrounding structure and reads
the entire PRE text. It does not join blocks, remove authored prose, repair JSON,
accept a partial response or change model/ownership/completion/deletion checks.
The direct observation establishes this missing format support; it does not
reconstruct the earlier failed reply or qualify the workflow.

The recorded399 failures and the two historical398 DeepSeek marker passes remain
separate. Build400's integrated gate passed 264 native tests and 338 JavaScript tests
(10,930 assertions). It has not been installed or tested against a live provider. Fresh exact selections,
complete workflow outputs and durable cleanup are still required. The private
matrix retains the original 27 cached choices plus the separate Gemini block;
no catalog refresh or broad provider reliability claim was made.

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

### Long Qwen messages and literal tool replies (2026-11-03)

Build 401 rejected a Qwen3.7-Plus first message because its visible paragraph
was empty. In a separate normal-tab test, Qwen answered a 62,805-character
synthetic prompt with the exact requested marker. Once settled, the paragraph
contained only the first 10,240 characters. Clicking its adjacent **Expand**
button once exposed the full prompt in the same paragraph; its SHA-256 matched
the pre-submit draft. The button became **Collapse**. The normal-tab observer
stopped during the initial route change, so it did not time the empty phase.
The test conversation was deleted and the empty home page verified.

Build 402 uses that display control only after an acknowledged first submission,
on the bound Qwen conversation, with an exact preview of the submitted text.
An empty paragraph can wait within the original deadline. Neither an empty
paragraph nor a preview proves ownership. The normal full-message, selection
and response checks still run after expansion. Plus and Max need separate live
qualification.

A fresh DeepSeek Chat task on build 401 ran three terminal calls, then returned
a patch envelope containing unescaped quotes. The strict parser rejected it
before the patch could run. Both website sessions have saved deletion receipts.
The record does not distinguish malformed model output from Markdown rendering.
Build 402 requests the site's supported literal JSON code block so the reader
can preserve backslashes; it does not repair invalid JSON or infer a call type.

Kimi Instant's reader now excludes the same known reasoning subtrees when
counting Markdown regions as it excludes when extracting the final source.
Unknown final markup still fails closed. A normal-tab fenced marker passed;
it did not reproduce the native task's unknown final leaf.

On installed build 402, Qwen Plus verified its selection at submission and
failed the subsequent selection check. No answer was accepted and deletion
was unconfirmed. Build 403 records which picker condition failed in the local
log without recording page content.

A fresh DeepSeek Chat workflow on build 402 opened the local browser fixture,
patched the file and passed all six tests. A later call returned its arguments
as a quoted JSON string. The decoder rejected the entire reply before
dispatch, and the fixture received no form submission. History uses the Open
Responses wire format for previous calls. The website prompt now specifies
the object form required for a new function call and shows the custom tool
name before its literal patch text.

On installed build 403, the Qwen Plus log identified a detached model picker
on the first conversation read, before the Expand action. Build 404 can hold
one replacement while inspecting this long first message. The old picker must
be disconnected and the only current picker must be closed and show the exact
requested label. The adapter pins its replacement and commits it only after
the full first message, fingerprint and turn identity verify.

DeepSeek Chat on build 403 repaired the file, passed the six tests, submitted
the form exactly once and returned its receipt. Its final answer claimed the
tab had closed. The browser recorded automatic cleanup after the turn and no
model-issued close. When the browser is bound and the close tool is permitted,
the response instructions now distinguish the page receipt from the close
acknowledgment. ChatGPT Instant completed the same workflow including an
explicit close after recovering from an indentation error in its first edit.

### Installed workflow results and build 407 changes (2026-11-03)

DeepSeek DeepThink on build 403, DeepSeek Chat on 404, and ChatGPT High and
Extra High on 406 each completed one fresh invoice fixture. Each edited the
designated file, passed six tests, submitted the reference once, returned the
receipt and explicitly closed its task tab. The provider journals confirmed
the selected mode or preset throughout each run.

ChatGPT Medium on 405 completed three inferences. On the next fresh tab, the picker
opening was never acknowledged before submission. Build 407 allows one more opening
attempt on that same verified, untouched composer and still requires the
selected family and power. Groq GPT OSS 120B on 404 requested page tools before
binding a tab. Its compact schema now lists the exact tool names the current
catalog revision can load.

Qwen Plus and Max on 406 both failed before expanding the first message.
Every sampled point on the verified Expand button was covered. Build 407
scrolls that button into view once, rechecks the conversation and model, and
requires the same exposed point immediately before clicking. The WebKit tests
cover a scrollable container, a fixed header and a persistent overlay.

## Remaining gates

1. Check each installed model with a fresh task. Verify the response and
   site-selected model or mode, then check the cleanup receipt.
2. Use Qwen's finite stage/reason evidence to identify the actual failing guard;
   preserve the failed tasks and do not replay uncertain submissions.
3. Verify both DeepSeek modes on complete browser/terminal/file workflows,
   including streaming completion and the observed literal response shapes.
4. Preserve negative coverage for foreign routes/models, outside prose,
   partial/repeated remounts, uncertain Send and delayed/unconfirmed deletion.
5. Record each installed selection's actual outputs, protected fixture tests,
   accepted browser receipt and durable cleanup; repeat coverage separately.
