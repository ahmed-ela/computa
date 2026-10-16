# Embedded website provider qualification

## Candidate127: API JSON parser failures

Foundation parser errors in Chat JSON, Chat SSE and Responses JSON previously
escaped the typed decoder failure and appeared as generic `unavailable` errors.
They now retain `invalid_response`, the finite `json_parse` guard, wire format,
native context and attempt number. The existing parser options also reject
scalar roots; this label describes the parser failure without claiming its cause.
Parsed root-shape, UTF-8, truncation, atomic tool validation and correction rules
remain unchanged.

The new tests reproduced the defect against the unchanged codec. All three
focused regressions and all 94 API codec/server/correction tests then passed.
Loopback cases verified one request on an initial parser failure and two when
the permitted argument-correction attempt returned malformed JSON, with no tool
output or private payload in the failure. The cohort source and diff remained
unchanged; its log SHA is
`fdc70e96699b6ae76ba6ed0daf76d094fce5ecc5c2d9945119d5ce413c1884fc`.
Independent source review was clear. Signed packaging and live qualification
remain pending. This fixes a reproduced classification defect, not the
unattributed historical V38 response failure or the website providers' blockers.

## Candidate126: deferred ChatGPT verification

The source candidate defers model-picker verification during running ChatGPT
responses and requires full current proof before exposing a stable answer or
executing tools. Pending results remain empty; current-header contradictions,
submission lineage, route ownership and revocation checks remain enforced.
This changes observation sequencing; it does not establish the cause of the
website's earlier `Load failed` or native `bad URL` failures.

All 555 adapter tests and 298 selected native tests passed. The native cohort
covers the transport, server, continuation, model evidence, bounded Gemini
diagnostic and runtime cleanup contract. Source, HEAD and working diff remained
unchanged during each run; the final native log SHA is
`d0d99aafcefd482b9a596201fd274c2b6f5d1e85cb5f1b09a4cdf5b461740606`.
The adapter log SHA is
`ce9048ce40db27caf98255824154324fe87231c4f7787335360a81dd2ca55906`;
the later native-only fixture corrections did not change those adapter inputs.
Signed build **0.7.0 (126)** from
`de5c4726f54614a00d74d41d30b41986ce9c3165` was packaged and installed. All 54
installed files, exact resources, signatures, unchanged engine and 2,132 frozen
inputs matched the independently checked candidate. The explicit Gemini
diagnostic compiler flag is enabled in this diagnostic artifact; no Gemini
request or diagnostic enrollment occurred in this build's live test.

The fresh V44 normal ChatGPT Instant browser task **failed** after 318.508 s.
Its first website inference passed full model/ownership verification and issued
one successful `browser_open`. The second inference remained pending until its
original five-minute deadline. A fresh abort-only page read then found two user
bodies, one assistant body and visible Stop, with no second answer or Retry.
This establishes that the website itself still lacked a second answer at the
deadline; a missed notification alone cannot explain the result. It does not
establish the HTTP outcome, network cause or a repaired request path. Resource
Timing contained no attributable conversation observations, whose absence is
inconclusive. No Send, refresh or challenge action was repeated.

The code task remained held without Send. The exact native receipt and fresh app
observation confirmed automatic disposal of the one task-created browser tab;
the existing human tab was preserved. The separate website cleanup receipt
recorded closed. Automatic disposal is not the requested model-issued close and
does not change the failed qualification. The fixture server stopped, with its
exact process and port verified absent. The finite deadline diagnostic SHA is
`08bc80f5fee2b1119506dc5cc4a8e7ef10cd646511b00b345aa41979b84c5e37`.

An additional ordinary, unpaused ChatGPT Instant control sent one synthetic
55,369-unit message and returned its exact marker. Completion was observed
27.482 seconds after Send; actual completion latency and HTTP/request details
were not measured. This control does not qualify the harness. Its disposable
tab closed, and the prior approved Inspector settings remain restored off.
Google's fresh ordinary-tab CAPTCHA control below remains an unresolved
external blocker; no permanent CAPTCHA or ChatGPT request-path fix is claimed.

## Historical installed build124 qualification

Computa 0.7.0 (124), compiled from
`c4c973afd40453eedadeb7eb2580d5d68100eced`, was installed. All 54 installed
bundle files match its signed candidate; the 614 frozen inputs, exact resources,
signature and unchanged engine were checked separately. Its explicit diagnostic
compiler flag was observed both in compilation and in the live enrollment below.
The later cleanup source changes described below were versioned as build125;
they are included in the installed126 artifact above.

| Fresh installed124 case | Native time | Result |
| --- | ---: | --- |
| V42 normal ChatGPT Instant, browser | 5.440 s | `website_response_failed`, zero tools. Submission was verified; actual failed HTTP outcome is unknown. Code case held without Send. |
| V42 Gemini 3.8 Flash, browser | 52 s displayed | Six clean tools, seven verified website inferences, exact fixture result, explicit tab closure corroborated by the native host receipt and fresh app observation. |
| V42 Gemini 3.8 Flash, code/terminal/browser | 0.688 s | Google verification before tools. Seed and original tests unchanged; no code test result claimed. |
| V43 hosted Cerebras GPT-OSS, code/terminal/browser | 8.439 s | Thirteen clean tools, intended one-line patch, four independently rerun original tests passed, exact browser result and explicit tab closure corroborated. Zero API correction records. |
| V43 hosted Cerebras GPT-OSS, browser | 3.518 s | Correct exact result and five clean tools, but the model omitted the requested `browser_close`. Strict qualification failed. Native automatic disposal and fresh UI confirmed cleanup separately. |

Both owned fixture servers stopped; their processes and listening ports were
verified absent. Original human tabs and failed receipts were preserved. The
GPT-OSS runs do not establish the historical V38 decoder failure's cause, and
automatic disposal does not substitute for the requested model-issued close.

The V42 Gemini checkpoint committed and finished after 255 ms, without a Gemini
document commit. The five-second opt-in native diagnostic enrolled, then normal
runtime error cleanup cancelled it after only 48 ms. This truncated observation
does not establish whether that page would naturally navigate again. The source
now separates ordinary failed-turn cleanup from user cancellation: only an
already-enrolled diagnostic can retain its original deadline. Stop, shutdown and
cancelled waiters still shorten it. A cancelled waiter's callback binds its
original transport/token, so it cannot interrupt a newer session. Manual cleanup
while busy remains a rejected no-op. All 90 selected native cleanup, server and
terminal-contract tests passed with unchanged source before the build-number
increment. Independent source review found no remaining blocker. No live repair
is claimed.

A subsequent prompt-free control loaded the canonical Gemini `/app` URL once in
one fresh ordinary human tab, in the same profile. It also immediately showed
Google's unusual-traffic CAPTCHA. No prompt, refresh, challenge action or Inspector
access occurred; the disposable tab was closed. A background model view is
therefore unnecessary to reproduce this checkpoint. The particular network or
server-side risk trigger remains unknown; the saved verification gate remains.

With separately approved Inspector access, a fresh ordinary ChatGPT temporary
Instant tab completed one 55,369-unit synthetic first message. Its conversation
POST returned HTTP 200, with 3.21 s shown in Network and the exact response marker.
The fetch was paused for 126 s, so this is instrumented diagnostic evidence, not
an uninstrumented harness pass or a request-size explanation. The prepared full
request/header projections were not executed; actual serialized upload bytes and
options remain unknown. Both Inspector settings were restored off, the
breakpoint and Inspector removed, and the synthetic tab closed. The installed
ChatGPT harness remains unqualified.

## Historical installed build122 qualification

Computa 0.7.0 (122), compiled from
`c85cc35f7e295472cdbbcd82748dbdf2abbe1f54`, is installed and running.
The signed candidate and installed app matched all 54 bundle files. The frozen
613 inputs, resources, signatures and unchanged engine were checked separately.
All 88 API tests passed on that source.

Fresh hosted Cerebras GPT-OSS code/terminal/browser repetitions used the same
off-by-one bug, four unchanged tests and browser form, with new isolated values:

| Case | Native time | Result |
| --- | ---: | --- |
| V39 code/terminal/browser | 15.878 s | Functional recovery: two shell commands failed before corrected commands, patch, tests and exact lookup succeeded. |
| V40 first code/terminal/browser | 8.375 s | Native tools passed; one rejected API call required a validated correction. Recovered completion. |
| V40 second code/terminal/browser | 6.785 s | Clean native and API completion, with no correction. |

Independent file checks passed for both V40 tasks, with existing tests and the
unrelated note preserved. Model-issued tab closure was corroborated by each
native host receipt and a later app observation. The fixture server stopped;
its process and listener were verified absent. No fatal response-guard failure
recurred, so these runs do not identify V38's decoding cause. A Swift String
equality check is not a UTF8-byte equality claim.

An ordinary human Gemini tab loaded the canonical app route without a challenge
and showed 3.8 Flash selected. The saved recovery record was verified and its
checkpoint absent; the precise clearance timing was not independently captured.
No refresh, challenge interaction or preference edit was performed. V41 then
tested the actual background harness:

| Gemini 3.8 Flash task | Native time | Result |
| --- | ---: | --- |
| Browser lookup | 49.607 s | Passed: six clean tools, seven verified website inferences, exact result, confirmed temporary-session and explicit task-tab closure. |
| Code/terminal/browser | 1.047 s | Verification-blocked before any tool. The original helper and tests remain unchanged. |

The failed code task was not retried, and its tests were not executed as a model
result. Native events show a new Google checkpoint settling after 331.475 ms,
then being rejected with no prior Gemini document commit. The three-second
settlement budget did not expire. PID/time correlation supplies this evidence;
these log events do not carry a task/turn identifier. Its private website session
closed. The server received only the browser
case's accepted form submission, then stopped with process and port absence
verified. Both original human tabs were preserved. These results do not qualify
permanent CAPTCHA prevention. Human and model views share the persistent store,
configuration, URL loading and navigation policy; background geometry, focus,
popup handling and view lifetime differ. Their causal relevance remains unproven.
The passive post-block diagnostic below remains disabled in normal builds.

ChatGPT's ordinary-tab `bad URL` failure below remains unresolved. It is not
qualified by the GPT-OSS or Gemini results.

## Build123 Cerebras stream-error classification

Cerebras documents an error envelope inside an HTTP-200 SSE response. Previously
this reached the generic malformed-response guard. The codec now classifies
only the exact bounded, unambiguous Cerebras error shape through the existing
sanitized HTTP failure types. Malformed or unknown envelopes still fail closed.
Errors after partial tool fragments publish no tool, and errors after `[DONE]`
retain the original ordering failure. Request counts, correction limits and
successful-response validation are unchanged. This is a documented classification
repair, not an established explanation of V38's failure.

All 91 native API tests passed, including the new first/second-attempt stream
error cases, finite error privacy, normal success controls and no extra request.
This source change has not been installed; the running app remains build122.

## Build124 Gemini post-block diagnostic

V38 and V41 both rejected a newly settled Google verification route, before any
provider adapter or prompt dispatch. The next experiment asks whether the exact
private view would naturally navigate again after that first `didFinish`.
This remains a hypothesis, not a CAPTCHA fix.

Normal builds leave the probe disabled. An explicit
`COMPUTA_GEMINI_POST_BLOCK_DIAGNOSTIC` compilation condition enables one eligible
capture per browser instance. Only the original inspect/before failure can
enroll an untouched, settled, app-owned Gemini view after its failure and saved
gate are latched. The initial three-second settlement policy is unchanged.

The probe observes native lifecycle facts for at most five seconds, with one
nonrenewable timer and at most 32 finite records. It does not evaluate page
JavaScript, enter input, navigate, refresh, retry, clear a gate or grant adapter
authority. Finish and cancellation await the same bounded task. A later route
change cannot turn the failed task into success or reuse its old checkpoint
cleanup receipt. Separate physical disposal retains its own exact-view proof.
Closure means stop, detach and registry removal; a failed session can retain
the stopped WK object until ordinary Finish. No deallocation claim is made.

The integrated source passed all 115 selected native API and Gemini tests,
including nine new diagnostic cases and 15 existing initial-navigation cases.
These cover default-off behavior, no-Finish timing, changed generations,
concurrent Finish, cancellation, revocation, privacy and bounded records.
No live probe or new provider request was run, and the installed app remains
build122. A diagnostic candidate requires a separately verified signed build
with the explicit compilation condition before any installation or live trial.

## Historical build121 qualification

Computa 0.7.0 (121), compiled from `cb912ae830e922edd1aa429160d3a5210adb7d86`,
was installed for V38. Its signed-build audit verified 613 frozen inputs, all 54 bundle
files, 50 resources and the unchanged engine. Installed-file verification and
the fresh running-process binding are retained separately.

The fresh V38 matrix produced these results; earlier failures remain failed:

| Provider and task | Native time | Result |
| --- | ---: | --- |
| Normal ChatGPT Instant: browser | 318.553 s | Failed: one successful browser open, then the second inference timed out. |
| Normal ChatGPT Instant: code/terminal/browser | — | Held after the browser failure; never dispatched. |
| Gemini 3.8 Flash: browser | 74.449 s | Passed: six clean tools, seven website inferences and the exact submitted result. |
| Gemini 3.8 Flash: code/terminal/browser | 1.260 s | Blocked before tools on a settled Google verification route. |
| Hosted Cerebras GPT-OSS 120B: browser | 4.245 s | Passed: six clean tools, zero corrections and the exact result. |
| Hosted Cerebras GPT-OSS 120B: code/terminal/browser | 3.105 s | Failed before tools with decode-stage `invalid_response`. |

Both successful browser cases have independently corroborated explicit tab
cleanup. ChatGPT's failed task tab closed automatically; that does not supply a
model close or a passing task. All three code workspaces retain their original
incorrect helpers, unchanged tests and protected notes. No code task passed.
The fixture received exactly two accepted form submissions and no rejected
submissions. Its owned server exited normally, and its process and listening
port were verified absent. Test evidence and the selected human tabs remain.

Gemini's initial-navigation experiment waited 510 ms for native settlement,
then rejected the committed, finished verification route. It did not expire its
three-second budget. No challenge was completed or saved gate bypassed. This
does not establish why Google selected that route or permanent CAPTCHA
prevention. GPT-OSS's finite log identifies decoding, but the failed guard was
not retained; no cause or repair can be inferred from that event.

With separately approved temporary Inspector access, an ordinary build121
ChatGPT test tab completed a short synthetic request: HTTP 200 in 1.98 seconds
with its exact marker. Its second synthetic request used 55,370 observed
composer characters and failed at `/backend-api/f/conversation` after 113 ms,
with no HTTP status and a visible `bad URL` console error. The website remained
busy until stopped. The actual upload body type/size and underlying native
error were not measured. A large paste had first created an automatically
uploaded synthetic text attachment; it was removed before Send. Text insertion
used native AX value setting, so this is a website diagnostic, not equivalent
harness qualification or proof of a request-size threshold. No third Send,
Retry or reload was performed. The breakpoint was removed, Inspector windows
closed, and both the tab permission and Safari developer-features setting were
verified restored off. The Safari Start Page was preserved.

## Build122 API decoder diagnostic

The V38 code failure exposed a diagnostic gap before argument validation.
Build122 labels fatal response guards with finite format and guard enums,
attempt number and typed current native context. It retains no response text,
arguments, headers or remote identifiers. Parser conditions, public failures,
atomic validation, request counts and correction limits remain unchanged.
Missing observations stay unknown. Independent reversal of the added
instrumentation reconstructs the prior codec byte for byte.

All six focused native tests passed, including malformed JSON/SSE/Responses
guards, privacy checks, unchanged successful/nonfatal paths, and loopback
first/second-attempt failures without extra requests. These tests used the
reviewed source before its build-number increment. The full 88-test API cohort,
signed build, installation and fresh live diagnostic were subsequently verified
separately, as recorded above. This diagnostic does not repair or identify the
V38 decoder failure.

## Candidate119 task-tab cleanup accounting

The V35 GPT-OSS failure exposed a separate host bookkeeping gap: native turn
completion scheduled task-tab disposal, but published terminal status without
waiting for that disposal or retaining an exact-turn result. The model had
already claimed closure without issuing `browser_close`.

Candidate119 records the original task, thread, turn, runtime generation and
owned tab instance. Explicit close, replacement, automatic cleanup and shutdown
have separate provenance. The runtime waits for browser and inference cleanup
before terminal publication. Failed physical closure or failure to save its
private receipt leaves the task waiting with a cleanup warning. Existing user
tabs remain preserved; old-turn callbacks cannot certify a newer submission.

An unconfirmed earlier close and an unresolved opening remain unconfirmed.
An empty later context cannot replace those observations with success, and
evicting old report details cannot restore a retired key's browser authority.
The immutable receipt contains native identifiers and finite outcomes only,
without page content, URLs, prompts or replies. This is host resource evidence;
it does not invent a model tool call, verify the answer or regrade old tests.

All 97 selected native tests passed: eight receipt-store tests, 33 controller
tests, 22 runtime/browser tests, 15 turn/steer contract tests and 19 streaming
regressions. The first compiled check caught a macOS `/var` alias that Foundation
keeps after URL symlink resolution; the final factory resolves the trusted
existing app-data home with `realpath`, preserving the new receipt directory's
strict checks. Its regression passes through the real runtime fixture. An older
released-key assertion now expects the earlier `handleMissing` rejection while
retaining its no-dispatch and backend-counter checks. The failed test log remains
preserved; it was not counted as a pass.

Signed Computa 0.7.0 (119), compiled source `6b11a6fd`, built successfully.
Its 613-input source freeze, exact resources and signatures were verified;
the bundled engine is unchanged. Build119 was installed on October 15 after
normal shutdown of build118. All 54 installed files match the signed candidate,
and its deep strict signature verifies. The new process is PID20978, started
at 14:21:58 local time. Provider and cleanup behavior still require fresh live
qualification; the installation alone is not a provider pass.

## October 15 ordinary ChatGPT diagnostic

With the user's approved, temporary Inspector access, the retained ordinary
build118 ChatGPT tab was observed before any retry. The original failed Send's
request was no longer in the timing buffer. A WebSocket connection-lost error
was visible, but could not be attributed to that Send and is not its established
cause.

One controlled Retry restored the synthetic prompt into the composer rather
than submitting it. One subsequent native Send completed with the exact marker
and a visible Response complete state. Inspector recorded the conversation POST
as HTTP200, 12.10 seconds and 5.59KB, followed by a successful conversation GET.
No headers, bodies, credentials or HAR were retained. This demonstrates a
successful ordinary-browser response, not repaired harness reliability or an
explanation of the earlier failure. The original failed result remains failed.

The remote Inspector window was closed, Safari's developer-features setting
restored off, the per-tab inspection grant revoked, and the exact synthetic tab
closed. The user's Safari Start Page was preserved. No challenge was completed.

## Build120 repair candidate (superseded before installation)

The candidate adds one passive, native-only settlement window to the initial
untouched Gemini navigation. A committed but unfinished Google checkpoint can
finish under a single three-second deadline, clipped by the original preparation
deadline. It does not inspect the foreign document, refresh, submit, solve a
challenge or bypass an existing saved gate. Settled, failed and previously
Gemini-committed documents retain the ordinary blocker. This is a controlled
navigation experiment, not an established permanent CAPTCHA fix.

ChatGPT now recognizes an exact Load failed label beside one enabled Retry in a
small direct widget, including plain text and nested inert labels inside dialogs.
It no longer requires the label to be a leaf span. This aborts an already failed
owned response without waiting for the full response deadline. It never clicks
Retry or accepts an answer. Quoted content, editable regions, custom ARIA controls,
navigation/sidebar/menu ancestry, broad or split containers and unknown text
cannot supply that failure. Repeated terminal polls do not evaluate the page again.
An unrelated modal still triggers the existing model-verification rejection
before error classification; the abort rule never bypasses that guard.

Separately, bounded, finite Retry/status-widget observations supplement the
existing response-progress diagnostic. They contain no page text, URL, prompt or
reply and grant no ownership, response acceptance or retry authority.
API correction journals additionally retain a
finite first-validation reason and counts, preserving legacy schema1 when the
new projection is absent. No command or argument is normalized or repaired.

A fresh ordinary build119 ChatGPT short-message control completed with its exact
marker. A separate native chunked-paste experiment visibly failed with Load failed,
but its retained user text did not begin with the expected marker. Its actual
transmitted length was not measured, so it is **not** a valid same-length control
and does not establish a message-size threshold. The failed observation and its
qualification correction are retained separately. Source inspection found no
production pretty-print encoder; whitespace compaction may save nothing on the
actual harness request and is not adopted as a speculative failure fix.

A nonpersistent local WebKit control on macOS26.5.1 uploaded strings, Uint8Arrays
and Blobs at both 32 and 70,000 bytes with exact server hashes. Direct
ReadableStream uploads with duplex half and keepalive false failed with
NotSupportedError before any POST. This is a platform capability result, not the
ChatGPT root cause: the retained October13 failed request used a 69,917-byte
string body with keepalive false, and its Blob control also failed. The current
build119 website request shape remains unmeasured. No stream workaround, private
WebKit preference, authentication change or network setting was adopted.

The full native selection covered 82 API, 172 transport and 15 initial-navigation
tests. Its only failure was a new test incorrectly expecting no document-binding
context after an ordinary adapter read; the corrected test verifies the exact
generation, zero/empty proof fields, absent readiness evidence and rejected Send.
All 18 targeted tests then passed. The first new real-WebKit error fixture also
incorrectly expected a modal to bypass model verification. A test-only correction
separates generic-widget success from the modal guard's rejection. Original failed
logs remain preserved. The final 21-test native run passed all 15 navigation tests
and six focused response-error/diagnostic tests, including direct/nested labels,
bound/unbound ownership, zero Retry clicks and no second terminal evaluation.
The final adapter run passed 289 tests and 8,017 assertions with unchanged inputs.
These are retained regression results. Build120 was signed and verified but
superseded before installation; it supplies no live provider qualification.
No earlier failed live receipt was regraded.

## Build121 nested ChatGPT error alert

Approved inspection of the retained ordinary build119 test tab identified the
actual error widget: nine elements rooted at `aside[role="alert"]`, with a
wrapped Load failed label and one wrapped Retry button. Build120 excluded all
asides and only matched a direct label/Retry widget. That classifier gap could
leave an already failed website response waiting until the full deadline.

Build121 adds a bounded traversal for this exact semantic alert. It accepts only
the known label and one enabled Retry, rejecting extra text, controls, hidden
labels, oversized/deep trees, transcripts, editors and enclosing navigation.
The existing native ownership/model checks and generic-widget path are
unchanged. Recognition only aborts; it never clicks Retry, replays a request or
accepts an answer. The private adapter suite passed 294 tests with 8,237
assertions; independent review added 75 pure counterexample checks. All four
focused native WebKit tests passed with unchanged Swift inputs, covering the
measured alert, generic widgets, typed terminal failure and the unrelated-modal
guard. The new fixture checks bound and unbound first-message state, one Send,
zero Retry clicks, no second terminal evaluation, cleanup and a fresh session.
Signed artifact and installed behavior are separate verification steps.

One controlled ordinary-tab Retry restored the synthetic prompt to its composer.
One subsequent native Send did not pause at the URL breakpoint and returned to
an empty root-page composer. Fetch access-control failures were visible, but
their request attribution and the actual upload body were not established.
This is not an underlying request-cause diagnosis or a successful model task.
No headers, bodies, credentials or HAR were retained. The created breakpoint
was removed, remote Inspector closed, Safari developer features restored off,
and the per-tab Inspector grant revoked. The Safari Start Page was preserved.

## Build119 fresh provider observations

The first fresh, unarmed normal ChatGPT Instant health check failed after
304.996 seconds with `provider_timeout`, zero tools and zero completed
inferences. The exact submission, selected model and ownership were verified,
but the cached observation stayed at one user, zero responses and zero answer
bytes. Automatic physical website disposal was saved 63 milliseconds after
native engine completion; this is disposal evidence, not a qualified inference.

The finite abort diagnostic found a Retry control inside an excluded
menu/dialog/navigation region and a separate unrecognized status. Their shared
widget and actual error literal are not established. Neither broadening the
error classifier nor blaming the network is justified by those fields alone.
No ended conversation timing entry was retained; absence is inconclusive.

A separate cold ordinary Gemini tab loaded the canonical `/app` page normally.
The existing prompt-free owned recovery then verified discovery and disposal,
clearing the exact previously saved checkpoint. Finite before/after records
link the recovery to that checkpoint. No challenge, refresh loop or model task
was performed by this recovery observation. It demonstrates recovery at that
moment, not permanent CAPTCHA prevention.

The subsequent fresh build119 trials retained the original strict contracts:

| Case | Native duration | Outcome |
| --- | ---: | --- |
| Hosted GPT-OSS browser | 4.828 seconds | Strict clean; seven successful calls, exact reference/result and explicit close |
| Hosted GPT-OSS code/terminal/browser | 26.521 seconds | Functional patch, four unchanged tests, helper CLI and browser result passed; strict failure after two shell syntax errors |
| Independent GPT-OSS automatic-cleanup probe | 2.595 seconds | Two browser calls and no model close; automatic host disposal corroborated separately |
| Gemini 3.8 Flash browser | 55.378 seconds | Strict clean; six tools, seven verified website inferences and causal final website closure |
| Gemini fresh code session | 0.575 seconds | Verification block before any tool or verified submission; code and tests untouched |

The GPT-OSS code run generated two command strings with a stray closing brace;
zsh returned a parse error each time. The model corrected them and completed the
task. Separately, the adapter accepted one bounded corrective inference for
invalid tool arguments; its exact initial validation defect was not retained.
These are distinct failures. Neither successful repair nor final file/test
verification regrades that strict receipt. Both remaining GPT-OSS repeat cases
are held. V36 has two strict attempts, one clean and one failed, plus the
independent host probe.

All three V36 host receipts and the Gemini browser receipt were settled, with
matching explicit or automatic provenance, preserved human control tab and a
later completed app observation. The live checks do not independently expose
the private runtime-generation UUID or measure first terminal publication;
the native delayed-disposal tests cover that ordering barrier. Automatic
cleanup supplies no model-close or answer-correctness credit.

V37 Gemini has two attempts: one clean browser task and one verification-blocked
code session. The block returned despite an absent checkpoint immediately before
the second Send. This repeats the earlier successful-session/blocked-fresh-session
pattern; the triggering cause remains under investigation. No challenge was
completed and no blocked task was replayed. Both fixture servers stopped with
exit zero, final stop events and absent processes/listeners; synthetic source,
tests and failed evidence remain retained.

## Build118 V34 and V35 outcomes

V35 prepared twelve fresh cases: three attempted, one strict clean, two failed
and nine held. Its results remain separate from the earlier V34 matrix.

| V35 case | Native duration | Result |
| --- | ---: | --- |
| Gemini code/terminal/browser | 0.565 seconds | Verification required before any tool or verified website submission |
| Hosted GPT-OSS browser R1 | 3.576 seconds | Strict clean: six successful calls, exact form result and explicit tab close |
| Hosted GPT-OSS browser R2 | 4.154 seconds | Failed task: eight valid calls, rejected reference and no explicit close |

Both hosted GPT-OSS runs used the exact selected Cerebras API model, with zero
corrective inferences, native agent errors or failed tool calls. In R2 the
model supplied `UA2078` instead of the requested `UA 2078`; the browser's filled
value and rejected server submission agree. Existing instructions already
required verbatim identifiers and preserved whitespace. Later reads exposed
the rejection, but the model did not correct it and falsely claimed the tab
was closed. The fixture deliberately requires exact spacing and one form
submission. This establishes a literal-copy and close-obligation failure in
that controlled task; it does not establish a general flight-search failure
or an adapter mutation. The failed receipt is unchanged.

Gemini's fresh owned navigation reached Google's main-frame verification
checkpoint via a server redirect. The native guard stopped inference with
`website_verification_required`. A later finite store read found the new
checkpoint; the older healthy recovery report no longer matched it. The
subsequent `closed/not_created` disposal does not qualify a completed model
conversation. No challenge was completed or prompt replayed. The trigger and
permanent CAPTCHA prevention remain unresolved.

Separately, V34 Gemini completed the code/terminal/browser workflow in 81.368
seconds: nine successful calls, the actual helper patch, four unchanged tests,
independent CLI validation, the exact browser result, explicit task-tab close
and a causally qualified final website closure. Its original strict receipt
remains unqualified solely because the private shell-scope checker rejected
the decorative `echo '--- TEST ---'` separator. A bounded, reviewed checker
correction was prepared prospectively for V35 with regression coverage; it did
not regrade or replay V34. V34 had twelve prepared cases, one attempted,
zero strict clean and eleven held.

Both fixture servers stopped with exit zero, final stop events and their
processes and listeners gone. A later UI inventory corroborated removal of
the GPT-OSS R2 task tab while preserving the failed ordinary ChatGPT control;
it is not a durable proof of closure before native completion. The projectless
V34 task could not display a review diff without selecting a workspace, so no
review-pane pass is claimed. Remaining provider cases were held.

## Build118 V33 workflow failure and ordinary-browser control

V33 prepared twelve fresh cases and attempted one normal ChatGPT Instant
browser task. It remains failed and unqualified; eleven cases were held.
The first website inference completed and opened the controlled fixture tab.
The second submission was verified, but no answer completed before the
unchanged deadline. Native completion reported `provider_timeout` after
317.337 seconds, with one successful tool call and no final task result.
No ownership failure or first-failed-context sidecar was recorded.

The second outbound body was 55,369 UTF-8 bytes, 1,146 bytes larger than the
successful first body. That observation does not establish a size or network
cause. A separate ordinary visible temporary ChatGPT tab, using native paste
and Send rather than the model harness, showed `Load failed` on its first
short marker prompt. Its power picker showed Instant; model family was not
independently verified. No Retry or second message was sent. The hidden
harness is therefore not necessary for this observed failure, while its
underlying cause remains unknown.

The failed workflow has no causally qualified final website closure or
explicit task-tab close. A later automatic model-session cleanup was saved
540 milliseconds after native completion; it does not qualify the failed
inference. The fixture server stopped with exit zero and its process and
listener gone. An empty browser pane corroborated task-tab removal, but
there is no durable receipt proving that exact tab's physical disposal.
The ordinary ChatGPT control tab is retained pending approval for inspection.
No failed receipt was replayed or regraded.

## Build118 installed diagnostic health

Signed Computa 0.7.0 (118), compiled source `2386e1de`, is installed and running.
All 54 bundle files and 50 resources match the retained signed build; signatures
and the unchanged bundled engine were verified.

One fresh, unarmed normal ChatGPT Instant health task returned its exact marker
in 16.572 seconds with zero tools, one completed website inference and one
causally verified physical website closure. Native model identity and the
unchanged lifecycle checks passed. The earlier ownership failure did not recur,
so this check supplies no first-failed-context diagnosis and does not qualify
browser or code/terminal workflows.

The receipt collector initially rejected its own binding due to a shadowed
local variable, then incorrectly assumed a UI Send intent could not precede
asynchronous native start. Both private collector defects were corrected with
meaningful regressions and independent review; the final 16 pure tests passed.
The original completed task was collected without replay, preserving the exact
identity, literal result and causal closure gates. Its Send intent preceded
native start by 541 milliseconds and remains diagnostic, not acceptance proof.

A fresh ordinary Gemini navigation before V34 showed its signed-in composer
and Flash picker without a CAPTCHA. Finite store reads then showed no saved
checkpoint and `verified / healthy_human_document`, indicating guarded recovery.
The store has no transition timestamp, so completion cannot be tied conclusively
to that navigation, and prompt-free discovery may have created another owned
view. No refresh, provider prompt or CAPTCHA completion was performed in the
control. The control tab was closed and the browser pane restored.
V35 subsequently encountered a new verification checkpoint, as recorded above;
the earlier recovery observation does not clear that later checkpoint.

The recurring CAPTCHA trigger and broad provider reliability remain unresolved.
The old failed receipts are unchanged. One duplicate install backup was removed
only after its 54 files matched the retained signed build117 original.

## Build118 original-read ChatGPT diagnostic preparation

The ChatGPT ownership failure in build117 needs the first failed context check
from the original admitted native read. The candidate records a finite,
short-circuited boolean prefix and distinguishes unbound message pointers from
detached pointers. Its synchronous, inference-scoped sidecar is attached only
to the exact current failed native journal. It contains no prompt, reply, URL,
credentials or submission proof; later cleanup cannot replace it.

Ownership, model selection, request counts, retry allowances and deadlines are
unchanged. The HTTP error is unchanged. All 268 ChatGPT adapter tests passed
with 7,317 assertions; nine selected native diagnostic, ownership, cancellation
and continuation tests passed. An earlier test wrongly assumed that skipping
the caller's first poll meant Send had not bound the body. The final fixture
explicitly establishes a verified body before revocation and proves that failed
cleanup retains its exact private view while preserving the human tab.

These results qualify diagnostic capture, not a behavioral repair. The
separate installed health and V33 workflow outcomes are recorded above.
The build117 failed health check and its unconfirmed cleanup remain unchanged.

## Build117 V32 installed outcomes

At V32 qualification, signed Computa 0.7.0 (117), source `95587e82`, was installed and running.
All 54 bundle files and 50 resources match the retained signed build.
The Cerebras selector still offers only GPT-OSS; the Qwen3.8 27B source flag
remains disabled with higher token usage documented as its temporary rationale.

V32 prepared twelve fresh cases and attempted two Gemini 3.8 Flash browser
tasks: one strict clean pass, one verification block and ten held cases.
The first task completed six successful native calls, one accepted form
submission and the exact final result in 52.585 seconds. Seven verified
website inferences shared one temporary conversation; both the explicit
task-tab close and final website closure were confirmed.

The fresh repeat stopped after 0.764 seconds, with zero tools and no verified
website submission or completed inference. Its canonical native failure is
`website_verification_required`, `retryable=false`, with the required action
`complete_website_verification`. A separate fresh ordinary navigation to the
same Gemini home route also showed Google's unusual-traffic CAPTCHA. The
untouched private view's later `closed/not_created` disposal is recorded
separately; it does not qualify the failed task. No challenge was completed.
The trigger and permanent CAPTCHA prevention remain unresolved.

A separate unarmed ChatGPT Instant marker health check failed message ownership
in 12.356 seconds, before any tool or completed inference. Its website cleanup
remains unconfirmed, and the check is outside the twelve-case matrix. The
aggregate context diagnostic cannot identify the original failed conjunct;
unbound first-message pointers do not establish a physical remount. No ChatGPT
retry, inspection arm or Safari setting change followed.

The fixture server stopped with terminal exit zero, a final stop event and its
process and listener gone. Both Root-created ordinary control tabs were closed
and the browser pane restored to its prior hidden state. A duplicate install
backup was removed only after all 54 files matched the retained signed original.
These cleanup actions do not upgrade failed model-conversation cleanup.
The broader reliability goal remains open; no merge or release was performed.

## Build116 V31 Gemini diagnosis and build117 preparation

The fresh V31 Gemini 3.8 Flash browser task reached four successful browser
calls and one accepted form submission. Its fifth website submission was
verified, then a later read failed with the saved native classification
`website_ownership_unverified`, `ownership_reason=submission_message` and
`retryable=false`. Final website cleanup was unconfirmed. The task remains
failed; an accepted form submission does not prove the final result or tab close.

Finite logs from the exact installed process and bounded time window identify
the first refusal at `observe_digest`, sequence five. The original complete
message hash, first root, owner/document context and user count still matched,
while the fifth message's old root and body detached during the hash await.
The later `observe_state` failure followed revocation. The live evidence does
not establish that the replacement text was identical. This failure is separate
from Google's CAPTCHA; the engine's generic high-demand wording does not
establish a provider-capacity cause.

The build117 candidate reuses the existing full-body/native-hash replacement
proof at this boundary, only for an already verified submission with whole-root
detachment and unchanged context. It returns a read-discard certificate; the
unchanged native single fresh-inspect allowance governs the next proof.
Changed text, markers, partial replacements, counts and native pins still fail.
An invocation witness prevents a superseded awaited read from changing current
state or publishing stale diagnostics. Send and deadlines are unchanged.

The original adapter fails the controlled reproduction. The final applied
adapter passes 147 Bun tests with 5,298 assertions and five selected native
Gemini regressions. All ten native inspector-lease tests also pass. Earlier
failed receipts are retained: one eleven-case test exceeded its standard
timeout and was split into eleven identical parameterized cases; a patch
changed the resource's physical filename spelling, causing native startup to
reject it as unavailable. Restoring canonical `gemini.js` preserved its bytes
and made the selected native tests pass. The build preflight checks exact names.

The ChatGPT diagnostic lease permits public WebKit inspection only after a
manual same-UID arm and exact current native turn/view/token/generation binding.
It expires and revokes on lifecycle changes; it does not capture content or
expose a model/wire grant. Same-UID scope is not human authentication.
These offline results do not qualify an installed build117 provider task or
resolve ChatGPT's response stall or Google's CAPTCHA trigger. Build117 live
qualification remains pending; no failed V31 prompt is replayed or regraded.

## Build116 V30 installed outcomes

At V30 qualification, signed Computa 0.7.0 (116), source `32412096`, was running. All
54 bundle files and 50 resources match the retained signed build. The actual
selector offers only GPT-OSS under Cerebras; Qwen3.8 27B remains hidden behind
the disabled flag with its higher token usage recorded in the source comment.

Four fresh GPT-OSS tasks were attempted within the prepared twelve-case
matrix: three strict clean passes, one strict nonqualification, and eight
ChatGPT/Gemini cases held without dispatch. All four GPT-OSS tasks produced the
correct literal browser result, exactly one accepted form submission and a
confirmed task-tab close. No API correction or native task error was recorded.

| Case | Duration | Strict result and observed outcome |
| --- | --- | --- |
| GPT-OSS 120B, first code/terminal/browser task | 7.546 s | Clean. Thirteen native calls, exact helper patch, four preserved tests passed, independently verified CLI and browser result, confirmed close. |
| GPT-OSS 120B, fresh code repeat | 10.702 s | Not qualified under the zero-failure gate: the model first ran the deliberately broken seed's tests, which exited 1 with five expected off-by-one assertions. It then patched only the helper, reran the identical command with all four tests passing, and completed the correct CLI/browser/result/close sequence. No receipt was regraded. |
| GPT-OSS 120B, first browser-only task | 2.984 s | Clean. Six successful browser calls, exact result, one accepted submission and confirmed close. |
| GPT-OSS 120B, fresh browser-only repeat | 3.840 s | Clean. Six successful browser calls with the same independent result and cleanup checks. |

The strict code-repeat failure is a benchmark-policy mismatch with test-first
repair, rather than a rejected provider tool call. The original nonqualification
remains visible. The browser-only tests were released separately after explicit
review of that expected baseline failure; the earlier clean-only sequence did
not continue automatically. These bounded results establish working task
composition, not a guarantee of future provider reliability.

Build116 removes the build115 strict-tool wire experiment that Cerebras rejected.
It retains bounded schema feedback, unchanged authoritative validation, finite
ChatGPT response-progress diagnostics and manually armed private-capture
publication dispositions. The final 89 API/capture/bundled-engine checks passed
on unchanged source. The 165 browser-transport checks passed for the unchanged
transport cohort. Tests do not upgrade earlier failed live results.

All four task tabs were explicitly closed. The synthetic fixture server was
stopped with a final stop event, terminal exit 0 and its process gone; its ten
events contain four page opens and four accepted submissions. Original source,
fixtures, outputs and immutable receipts remain available in the private V30
artifacts. ChatGPT's third-response stall and Google's CAPTCHA trigger remain
unresolved. During V30, no CAPTCHA was completed and no ChatGPT/Gemini task was dispatched,
and the broader provider-reliability goal remains open.

## Build115 installed outcomes and build116 preparation

The fresh matrix attempted two tasks: zero clean passes, two failures and ten
held without dispatch. GPT-OSS rejected the tools parameter in 0.307 seconds,
before publishing any tool. The strict-decoding candidate is therefore being
removed; the next build restores the previously accepted wire format while
retaining bounded schema feedback and authoritative native validation. The
specific vendor constraint is unresolved: the primary schema and migration
documentation disagree about optional fields, and no detailed rejection was
retained. Static schema eligibility did not establish compatibility.

ChatGPT Instant in normal Chat completed browser open and read, then timed out
on its third website response after 330.024 seconds overall. The terminal
progress record had three verified user submissions, verified model evidence,
current owned view and document, and no pending submission. Its last inspect
still showed busy, two assistants, zero current response text and no recognized
load failure. Native hosting was attached, nonhidden, visible and nonoccluded;
adapter phases and DOM notifications were still arriving near the deadline.
This localizes the observed stall after local admission, without establishing
frontend transport versus model generation. One prior completed conversation
fetch was observed; the third had no ended timing entry, which is inconclusive
for an unfinished stream.

A separate marker-only GPT-OSS diagnostic message also received invalid tools
with zero native calls. It did not replay or qualify the original task. The
exact-task private arm was consumed but no rejection record was saved. Existing
projection and record bounds are already 7 KiB and 8 KiB; an oversized record is
not an established cause. The build116 candidate records finite disposition
only after a validated private arm and at its existing capture/publication
guards. It exposes no paths, identities, provider text or values and changes
neither record bytes, limits, filesystem guards nor replay authority. All 89
selected API, private-capture and bundled-engine tests passed on unchanged
source. This does not establish a build116 live provider result.

The owned fixture process and listener were stopped. Neither failed task gains
model conversation or task-tab closure proof. Build114, which includes the
requested Cerebras selector filter, was restored for availability; all 54
installed files match the retained signed bundle. The next candidate is still
being prepared. Gemini remains held; no CAPTCHA was completed
and no permanent prevention or old-WebKit cause has been established. The
build115 strict candidate has not been pushed.

## Build114 installed outcomes and build115 preparation

Five fresh tasks were attempted; two passed cleanly and three failed. Seven
remaining cases were held without dispatch. Cerebras offers only GPT-OSS in the
selector; Qwen3.8 27B is temporarily hidden at the user's request because of its
higher token usage.

| Case | Duration | Observed result |
| --- | --- | --- |
| Cerebras GPT-OSS 120B, first code/terminal/browser task | 6.860 s | Passed thirteen tools, independent preserved tests and CLI checks, exact form result and task-tab close. No corrective inference was claimed. |
| Cerebras GPT-OSS 120B, fresh code repeat | 1.051 s | The one corrective inference was attempted, but its response still failed schema validation. No tool was published. The specific rejected argument remains unknown. |
| Gemini 3.8 Flash, first browser task | 57.607 s | Passed six tools, exact result and task-tab close, seven verified website inferences and one confirmed final conversation closure. |
| Gemini 3.8 Flash, fresh browser repeat | 0.613 s | Committed Google checkpoint before adapter or Send; zero tools. A separate fresh visible same-profile Gemini tab also showed the actual unusual-traffic CAPTCHA. |
| ChatGPT Instant in normal Chat, browser task | 317.923 s | First inference completed and opened the fixture. The second inference expired at its original five-minute response deadline. No final result or task-tab close qualified. |

The Gemini checkpoint is a trusted Google `/sorry` route, not a normal account
sign-in redirect. Its trigger and permanent prevention remain unresolved. The
fresh visible challenge remains pending action-time approval. No challenge was
completed and no failed prompt was replayed.

ChatGPT's post-terminal finite abort observation had two visible user roots,
one assistant and a Stop control. It does not establish the second full-body
proof or the cause of the response stall. Empty recognized network-timing
counts are explicitly inconclusive. Failed website view-disposal receipts do
not add confirmed conversation closures. The owned fixture server was stopped
and its process/listener disappeared; the app remains open for the challenge.

Build115 preparation adds bounded schema-only feedback to the existing single
corrective inference, without copying rejected keys, values or reasoning. The
authoritative schema validator, catalog, confirmed history, ownership, deadline
and whole-batch tool-publication gates remain unchanged. It also records finite
terminal ChatGPT progress from the latest already-completed inspect, bound to
the current sequence, owned view and document. Missing observations stay unknown;
the diagnostic does not inspect, retry, admit an answer or change cleanup.
The final API-only candidate passed all 85 API and bundled-engine checks on
unchanged source. The 165 browser-transport checks passed before that API-only
addition; their transport source is unchanged. These checks do not qualify an
installed build115 provider task.

Build115 also enables [Cerebras strict tool decoding](https://inference-docs.cerebras.ai/capabilities/tool-use)
for GPT-OSS 120B on the validated official Cerebras endpoint, only when each
existing tool parameter schema satisfies a conservative supported subset.
It does not rewrite schemas, add required fields or remove unsupported tools.
Uncertain schemas retain their existing wire path. The harness's generic
Responses `strict: false` flag is not treated as a vendor decoding opt-out;
the accepted native argument contract remains unchanged and is still validated
before any whole batch can publish. The existing single corrective inference
remains available when needed. Live reliability remains unqualified until the
installed candidate completes the controlled tasks.

## Build112 installed outcomes

The fresh matrix attempted four tasks: GPT-OSS's first code/terminal/browser
task passed in 7.149 seconds with fourteen successful tools; Gemini's first
browser task passed in 55.812 seconds with six tools, seven verified website
inferences and confirmed final closure. Both results passed the strict task and
cleanup checks. Their independent fresh repeats failed: Gemini reached a
committed Google checkpoint before any adapter or Send in 0.552 seconds;
GPT-OSS rejected tool arguments before publishing any tool in 2.629 seconds.
Eight remaining cases were held. The test server was stopped separately.

The exact Gemini view recorded a native server redirect and no previously
observed allowed Gemini document commit. A subsequent ordinary visible tab also
showed Google's actual reCAPTCHA while the saved checkpoint was still present.
At that time the tab was retained pending action-time confirmation. The app was
later restarted for build114 without completing that challenge. This established
an ordinary-navigation block; it did not identify Google's trigger or
establish an old WebKit cause. CAPTCHA prevention remains unresolved.

GPT-OSS's finite diagnostics established a schema mismatch with known usage and
valid envelope shape, but the whole-envelope JSON scanner refused corrective
eligibility. A separate reproducible incompatibility was found in the
[official Cerebras response example](https://inference-docs.cerebras.ai/api-reference/chat-completions):
the top-level `created` is integral, while `time_info.created` is fractional.
The scanner applied the root timestamp's integer rule to every nested property
with the same name. The build113 candidate limits that rule to the root field;
duplicate-key, counter, size, ownership and correction-budget checks remain.
All 76 final native checks passed on unchanged Swift source, including the
documented metadata, the one-correction loopback variants and three bundled-engine
checks. The later build114 qualification is recorded above. Build112 was initially
left open for the visible CAPTCHA. The preceding diagnostic-only run passed 72 of 73 tests; its
new fixture's mistaken rejection category is retained and corrected separately.

## Build111 installed outcomes

Installed build110's Gemini 3.8 Flash browser task passed in 55.475 seconds:
six successful native tools, one accepted form submission, the exact result,
confirmed task-tab close and seven verified inferences in one temporary website
conversation with confirmed final closure. No CAPTCHA appeared in that task.
The fresh repeat stopped after 0.588 seconds with no tool calls or verified Send.
Its private WebKit view had a trusted Google `/sorry` URL while its current
navigation was still loading and had not committed. The native blocker persisted
that provisional observation before the initial loading gate ran. The separate
human Gemini tab remained healthy. No redirect-chain evidence establishes
whether the private navigation would have returned to Gemini or committed a
challenge. These results do not establish an old WebKit cause or permanent
CAPTCHA prevention.

The candidate waits on existing native navigation events only for that exact,
untouched initial Gemini provisional checkpoint. It performs no adapter,
editor or Send action while waiting and retains the original preparation
deadline. A committed Google checkpoint still stops and persists the block,
even while loading. An allowed Gemini page must pass the existing readiness and
ownership checks. There is no reload, CAPTCHA completion or request replay.

Build110 also isolated ChatGPT's second-message refusal: a product-only recheck
encountered a collapsed current body and attempted expansion despite having no
model-selection authority. The candidate returns a narrowly guarded pending
product observation with no current body proof or answer. The subsequent
authorized model/inspect read remains responsible for one scoped expansion and
the actual full canonical digest. Invalid prefixes, changed prior bodies, mode
or model drift and changed expanded bytes remain refused. Complete provider
qualification remains pending. All 499 provider-adapter tests and all 182 selected
native tests passed on held source, including the complete 162-test transport
suite and the new navigation and collapsed-second-message fixtures. The 12
product-identity tests also passed. Earlier compilation and fixture-measurement
failures are retained separately; they are not counted as passing runs.

The fresh build111 matrix (`1159564f`, private `live-v26`) prepared twelve cases
and attempted six: two strict clean passes, four failures and six held without
dispatch. Each browser case required the observed form result, exact hidden
alphanumeric confirmation, one accepted POST and explicit task-tab close.

| Case | Duration | Observed result |
| --- | --- | --- |
| Gemini 3.8 Flash, first browser task | 55.647 s | Passed: six successful tools, seven verified inferences in one temporary session, exact result and confirmed task-tab and final website closure. |
| Gemini 3.8 Flash, fresh browser repeat | 0.630 s | Blocked before adapter or Send on a native committed Google checkpoint. The provisional-navigation wait correctly refused it; no owned-view visual CAPTCHA or external trigger was established. |
| ChatGPT Instant, browser task | 14.953 s | Valid completed website inference and confirmed final closure, but the model refused the task and issued zero tools. Task qualification failed. |
| ChatGPT Instant, code task | 303.676 s | First submission verified, then the original response deadline expired with zero tools. The helper remained unchanged; no code-task result qualified. |
| Cerebras GPT-OSS 120B, browser task | 3.128 s | Passed all six tools, literal result, POST and close checks. Exact-turn correction evidence established zero corrective inferences. |
| Cerebras GPT-OSS 120B, code task | 1.881 s | Three successful read commands and a successful helper patch preceded decode-stage `invalid_arguments`. Independent rerun passed the four preserved tests, but the model never ran them or completed the CLI/browser/final/close requirements. |

Same-profile ordinary visible Gemini pages were healthy during the failure and
in bounded reload/fresh-tab checks; these observations do not isolate a
visibility, network or session cause.

The GPT-OSS code rejection claimed no corrective inference. Its precise
eligibility exclusion was not recorded by build111, so missing usage or malformed
envelope details are hypotheses rather than findings. Prior accepted edits
remain preserved; no call from the rejected response was published. API evidence
uses corrected log queries with explicit UTC offsets. Earlier queries treated
bare UTC dates as local time; their unreliable absence proofs are preserved and
superseded, without changing the original task receipts.

Two task tabs closed explicitly, and two completed website conversations have
qualified final closure. Four website receipts record closed views; the untouched
blocked Gemini view and failed ChatGPT code view do not add completed conversation
closures. Root separately closed its human tab, quit the app and stopped the
owned fixture server. The shutdown verifier confirmed absent app/server PIDs and
listener, an exit-zero drain and six server events. App disposal does not upgrade
task or website cleanup evidence. The immutable matrix summary is
`7840a8d9…`; the separate shutdown receipt is `f9b9a422…`.

## Build112 diagnostics

Build112 adds finite observations only: API argument-rejection categories,
existing correction-eligibility gates and correlated native context; and whether
the exact model-owned view ever committed an allowed Gemini route or received a
server redirect during its current provisional navigation. Neither navigation
flag changes readiness or checkpoint handling, and false means unobserved.
The API diagnostics do not alter parsing, tool admission, the corrective-inference
budget or response bytes. No prompt, argument, nonce, URL, credential or raw
response is logged. Separate unchanged-source native cohorts passed 70 API tests
and 65 navigation/session tests with zero failures. These offline checks do not
qualify installed build112 or establish Google's trigger, permanent CAPTCHA
prevention or repeated provider reliability.

## Build109 ownership pilot

ChatGPT now negotiates one owned temporary page per native turn. Each inference
still receives the full request and a distinct marker, and requires the actual
complete canonical submission digest. The pilot stops before insertion at
sixteen inferences or one MiB of cumulative outbound bytes. Exact first-Send
route acknowledgement and certified first-body replacement retain their existing
native checks; neither can publish an answer without a fresh body proof.
Transformed Markdown or substituted whitespace cannot manufacture that digest.

All 495 adapter tests passed on the held candidate. The focused native run passed
64 checks, including refresh concurrency, submission proofs and ten repaired
transport regressions. The final complete transport run passed all 160 tests
with unchanged source. Installed build109's pilot failed after 18.681 seconds:
the first inference completed and opened the fixture, then the second native
Send was claimed but did not establish submission ownership. One saved cleanup
receipt records unconfirmed closure. The exact result and fixture-tab close were
not verified. Eleven remaining cases were held, and the app and fixture server
were stopped separately; stopping them does not qualify model cleanup.

Build110 adds failure-stage, count and boolean diagnostics for this seam without
changing ownership, Send, body validation or cleanup decisions. The failed
build109 receipts remain immutable. No prompt, nonce, hash or URL is added to
the diagnostic sidecar. Its installed result and diagnosed sequencing fault are
recorded above.
Older failed attempts below retain their original
outcomes. Conversation reuse is an experiment for the second-inference stall,
not an established root cause or a permanent Google CAPTCHA remedy.

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

Installed build101's sole-wrapper diagnostic reached 293 nodes, 99 BR elements and one paragraph before rejecting interactive markup after 23,609 literal characters. The task failed after 5.621 seconds with zero tools and unconfirmed website cleanup. Its rendered mismatch remained at ASCII-collapsed offset23,589; the offsets use different representations and cannot identify the offending field or node. Exact insertion and two pre-Send DOM comparisons passed, but those checks do not prove the website editor's private state or server-side serialized message. The next diagnostic records only the finite tag and parent of the refused control. It grants no ownership or tool authority.

Build102's control-node diagnostic passed 469 browser-adapter tests and four selected native tests, including strict type/privacy/log-size validation and the real WebKit literal-insertion/owned-cleanup fixture. Its installed diagnosis is pending. The diagnostic preserves refusal of interactive message markup and cannot authorize a response or any tool call.

Installed build102 identified the refused node as an A element inside a P. Build103 can traverse only the diagnostic text of such an inline anchor under a direct paragraph of the exact logical body. It never reads the destination or acts on the link. A bounded link count records what was traversed; ownership remains rejected. The final source passed 471 browser-adapter tests and eight selected native navigation/diagnostic tests. Full literal comparison in the installed app remains pending.

The fresh build102 Gemini code/terminal/browser task qualified after independent file verification and a separate, bounded console-separator adjudication. It completed nine valid tools and ten verified website inferences in one temporary conversation, with four Python tests, exact result reproduction and confirmed website/task-tab cleanup, in 80.688 seconds. The original failed collector receipt is preserved. The subsequent fresh browser task was verification-blocked before dispatch; disposal of its untouched private view was confirmed. These results qualify the completed task, not permanent CAPTCHA prevention.

Installed build103's ChatGPT diagnostic completed the literal DOM traversal: 808 nodes, 168 BR elements, one paragraph and one inline link. The observed literal stream equalled the rendered stream and differed from the exact submitted prompt; its unique request frame contained invalid JSON. The task failed in 5.625 seconds with no tools and unconfirmed website cleanup. This localizes the failure after the exact composer checks and rules out an innerText-only presentation discrepancy; it does not identify the website's precise transformation. The next Chat-only candidate shields `.`, `:` and `/` inside JSON strings using the existing lossless encoder. Decoded request values, structural JSON and all ownership checks remain exact. This mitigation requires installed qualification.

Build103's fresh Gemini browser task failed after 20.137 seconds, with two valid browser calls and two verified website yields before the third inference's ownership refusal. It did not hit a CAPTCHA. The post-digest aggregate diagnostic must distinguish root replacement, text change, state change and digest mismatch before an implementation repair is chosen. Both build103 task failures remain failed; neither the earlier build100 browser pass nor build102 code pass qualifies this fresh matrix.

The build104 candidate passed all 473 browser-adapter tests and 79 selected native codec/submission tests. Two invalid new test fixtures were corrected without changing the production request policy; their failed receipts are retained. Chat-only URL-punctuation shielding preserves complete decoded request values and applies the existing expanded-prompt size bound. Gemini's finite post-digest facts are collected only after the unchanged refusal predicate and before revocation; they grant no proof or retry. Independent reviews found no ownership or cleanup relaxation. Installed qualification remains pending.

Installed build104's first ChatGPT inference verified the exact user body, completed a valid `browser_open` response and released its temporary session. Its second inference verified submission but produced no observed assistant before the five-minute deadline. The deadline diagnostic found one user, zero assistants, no Stop control and an enabled composer. Backend acceptance, capacity, request size and storage causality remain unproven. This qualifies crossing the earlier first-message boundary for one request, not the full task.

The build104 GPT-OSS browser task visibly reached the correct alphanumeric result and closed its tab, after one safely rejected fill containing a fabricated snapshot UUID. That UUID combined the real snapshot prefix with the document epoch's suffix. Disk exhaustion also prevented complete persisted final/terminal evidence, so this task is inconclusive and is not regraded as a clean pass. Redundant, hash-verified test-build backups were removed; original task evidence remains unchanged.

The next candidate omits only the unused document epoch from the model-facing `AXSNAPSHOT` header. Native canonical snapshots, epoch checks, exact snapshot identifiers, pagination provenance and page text remain unchanged. All 31 browser-controller tests passed, including the reported identifier mixture's rejection, exact single-use input, page-literal preservation, pagination and byte-budget fallbacks. Independent review was clear. A successor live collector must explicitly describe the new presentation and retain all outcome and cleanup gates; the older collector and receipts remain unchanged. Installed qualification is pending.

Installed build105 passed three fresh GPT-OSS tasks with the explicit `snapshot_epoch_hidden_v1` collector: browser lookups in 3.742 and 3.188 seconds, and a combined code/terminal/browser task in 5.993 seconds. These used six, six and thirteen successful native tools, respectively. The combined task applied a patch, preserved the existing tests and unrelated note, passed all four Python tests, returned the exact observed result and closed its task tab. Independent file verification passed. The second code task failed after 2.234 seconds: an admitted command contained a stray brace and failed, two later reads succeeded, and a native patch changed the helper. A subsequent local API inference was rejected as `invalid_arguments` before tests or browser work. Current diagnostics cannot distinguish a retained-history preparation failure from rejection of a new provider response; neither the precise arguments nor the failed boundary were retained. The full four-task GPT-OSS repetition is therefore not qualified.

ChatGPT build105 again completed its first inference and a valid `browser_open`, then timed out on the second inference after roughly 299 seconds. This recurrence after disk cleanup does not identify a storage cause. The deadline observation again contained one owned user message, zero assistant roots, no Stop control and an enabled composer. Exact outbound sizes were not retained; a payload-size threshold is not established.

Gemini build105 failed its first inference's message verification after 8.246 seconds, with no native tools and no CAPTCHA. Its initial full projected body matched the trusted prompt before a later observation saw revoked submission state. Source inspection found a diagnostic masking path: an outer first-message replacement discard can replace an existing inner refusal, leaving the next read with only the generic revoked-state error. A diagnostic-only candidate retains the first finite refusal on the exact private state and record. It cannot grant ownership, clear revocation or replay Send.

The build106 candidate passed all 477 browser-adapter tests and 66 selected native tests. These cover the retained Gemini refusal, exact Unicode message-size measurements, conservative Cerebras strict-tool schemas, actual loopback preparation versus decoding failures, unchanged rate-limit handling and WebKit deadline/cleanup behavior. API failures now retain a finite internal stage without saving request/response text; argument-error wording distinguishes invalid retained history from a rejected provider response. ChatGPT size measurements record a Send claim, not backend acceptance. Independent reviews found no ownership, response-validation or replay relaxation. Installed provider qualification remains pending.

Installed build106's fresh Gemini browser task passed in 54.864 seconds: six clean native tools, exactly one accepted form submission, exact result reproduction and confirmed task-tab close. Seven verified website inferences reused one physical temporary conversation, with six yields and confirmed final website closure. Scoped logs contained no submission-refusal or verification-blocker event. This successful run supplies no first-failure predicate to repair and does not qualify permanent CAPTCHA prevention.

The build106 GPT-OSS code task failed immediately, after 0.301 seconds and zero native tools, with `invalid_tools`. The new finite stage diagnostic identifies `request_transport`, so this is a provider tools-parameter rejection rather than local history preparation or response decoding. The specific rejected schema or flag remains unisolated; no response was replayed. Build107 rolls back only the strict-tool wire experiment and its five tests to exact build105 source, retaining all new failure-stage and website diagnostics. All 48 codec/server tests passed with unchanged source. Browser-adapter and unrelated diagnostic code are byte-identical to the passing build106 cohort. Live acceptance of the restored configuration remains required.

Installed build107's fresh GPT-OSS code/terminal/browser task passed in 8.668 seconds with thirteen clean native calls, an exact patch, four unchanged passing Python tests, exact observed form result and confirmed task-tab close. Independent file verification passed. Its second code task failed in 7.515 seconds. A relative patch and mistyped working directory were safely refused, then corrected; the patch, four tests, CLI reference and lookup succeeded. The terminal API error now identifies invalid arguments in a newly decoded provider response. No tool from that rejected response executed, no final answer was produced and task-tab close was not confirmed. Partial successes do not qualify that repeated task.

Gemini 3.8 Flash's fresh build107 code/terminal/browser task passed in 88.971 seconds: nine clean native calls, four unchanged Python tests, exact helper and unrelated-note preservation, one accepted form submission, exact result and confirmed task-tab close. Ten verified website inferences reused one temporary conversation with confirmed final website closure. No CAPTCHA appeared. This and build106's browser pass qualify their exact tasks, not permanent challenge prevention.

Installed build106 ChatGPT's first outbound claim contained 54,223 UTF16 units and UTF8 bytes; its second contained 55,369, with exact Native/adapter agreement. The first inference completed, while the second again timed out with one owned user, no assistant, no Stop control and an enabled composer. These ASCII prompts do not cross a 60,000-character or 64KiB threshold. Actual website upload bytes and backend acceptance remain unknown.

The build108 diagnostic candidate records bounded public Resource Timing observations for ChatGPT conversation and preparation requests. It preserves the exact private send mark, current view/document/sequence guards and original deadlines. It never intercepts requests or records URLs, bodies or headers; response byte counts are not upload sizes. Missing entries, missing status support and status zero remain inconclusive. All 482 browser-adapter tests and five selected native WebKit/privacy/deadline tests passed with unchanged source, and independent review was clear. Installed diagnosis remains pending.

Installed build108 repeated the same ChatGPT failure: its first inference completed and opened the fixture page; its second verified submission but timed out after 298.169 seconds. The full task failed after 318.321 seconds with one tool. Outbound claims again measured 54,223 and 55,369 UTF16 units/UTF8 bytes. The first completed inference had one ended conversation fetch and one preparation fetch, while the second deadline scan had no matching ended entry among 112 untruncated resource entries. HTTP status was unavailable. Missing entries do not establish that no request was dispatched or that the backend rejected it. Both temporary pages closed with saved receipts; the unfinished task's fixture-tab close was not verified. The original failed task and website receipts remain preserved.
