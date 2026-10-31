# Gemini harness qualification

Gemini qualification resumed on October 29, 2026. Gemini uses Computa's
shared Responses interface and browser, terminal and file tools, retaining
one owned temporary website conversation across tool rounds. Claude and the
broader browser-engine expansion in issue #9 remain outside this work.

Current status (October 31): build332, source `05d364f`, is installed and audited.
CAPTCHA investigation takes priority over all-model qualification. After one
specifically approved CAPTCHA completion, the direct website marker passed;
another direct marker passed after restart, followed by an owned 3.1 Pro marker
after a second restart. The owned task completed in 11.158 seconds with one
verified submission, exact answer, zero tools and confirmed cleanup. A future
exemption-cookie candidate remained present at both startups. This is bounded
recovery evidence on the unchanged build, not a CAPTCHA-prevention fix.

The preceding failure capture remains relevant: normal human navigation returned
a 302 redirect to Google's 429 challenge with current Dates and no-store headers.
One navigation with Disable Caches visually checked also received a newly dated
302/429. This argues against a simple stale local redirect. Initial
redirected-request cookie metrics remain unavailable, and earlier count changes
did not demonstrate restart loss.
No browser-version, hidden-session or prompt-interaction trigger has been
established. Developer/cache settings are restored, and the latest comparison
kept Inspector off and default cache behavior throughout.
The subsequent read-only network audit found no Tailscale exit node and matching
public IPv6 egress at one diagnostic destination in Computa and Codex. Two real
WebKit loopback tests also passed for transmitted headers, cookie eligibility
and redirect counts through the unchanged human/model factories. These narrow
checks do not establish Google's actual request routing or challenge trigger.
Earlier staged/installed statements below describe historical evidence, not the
current installation.

## Ownership failure and repair

The installed 0.7.0 (321) baseline displayed a healthy signed-in Gemini page.
A fresh 3.5 Flash-Lite marker task nevertheless failed with
`website_ownership_unverified` before any local tool call. Cleanup was
unconfirmed. Its evidence was retained and the prompt was not replayed.

Gemini's rich user-message scaffold contained the complete prompt and marker.
The parser rejected its accessibility heading because it required an exact
1-pixel CSS box. Captured facts established a semantic, absolutely positioned
heading with hidden overflow and a zero-area clip rectangle, but
`onePixelBox=false`. Actual dimensions were not collected. Rejecting this
heading caused canonical text extraction to return empty and the ownership
check to report `marker_not_final`.

Build 322 removes the box-size requirement for an otherwise fully clipped
heading. It retains semantic and structural checks, the absolute-position and
hidden-overflow requirements, complete clipping, noninteractive header
validation, exact full-payload reconstruction and equality, marker and
fingerprint verification, and the existing model/session ownership checks.
The `onePixelBox` diagnostic remains available.

## Local regression evidence

The candidate passes **150 Gemini JavaScript tests** with 5,429 assertions
and **31 focused native tests**. New JavaScript cases fail against the old
adapter and pass against the candidate for both zero-area rectangle clipping
and `inset(50%)` clipping with synthetic non-1-pixel dimensions.

Native WebKit cases also pass after replacing only the adapter resource in
the same test binary. The old-resource native failure remains recorded as
its actual `InvalidTransition(deinit)` error; it is not relabeled as the live
marker diagnostic. Visible or partially clipped headings, interactive header
contents, changed payloads and eligibility changes during digest evaluation
remain rejected. Synthetic dimensions are test inputs, not measurements of
the live page.

## Installed build 322 results

| Model | Controlled result | Qualification boundary |
| --- | --- | --- |
| Gemini 3.5 Flash-Lite | Exact marker returned in 7.476 seconds; model, full prompt and temporary-session cleanup verified | One completed marker run; no local tools requested |
| Gemini 3.8 Flash | Code, terminal and local-browser task completed in 91.145 seconds across 10 verified inference rounds and 9 tool calls | Successful composed workflow with one safely rejected and recovered patch-format error |
| Gemini 3.1 Pro | Fresh navigation reached Google's verification route before prompt submission or model-selection proof | Blocked; no model response or local tool qualification |
| Gemini 4 Argon | Not exercised in this qualification | Unqualified |
| Claude | Deferred by scope | Not tested |

The fixed Flash-Lite run verified a complete 61,456-character, 270-line
payload. Its live accessibility heading still reported `onePixelBox=false`
with complete rectangle clipping. The original marker failure therefore has
both a controlled reproducer and a live successful verification after the
repair. This does not establish broad repeatability across models or account
conditions.

The 3.8 Flash task read a local invoice exercise, repaired only its aggregation
helper, ran six passing Python tests and computed a reference. It opened the
loopback fixture in the built-in browser, filled the observed field, used the
fresh post-fill submit reference, read the receipt and closed its task-created
tab. The independent fixture audit confirmed unchanged protected inputs, the
code result, exactly one accepted POST and the matching receipt. No real mail
or external submission was involved.

The first `apply_patch` proposal had malformed hunk formatting and was rejected
before modification. The next proposal corrected the patch and succeeded.
This is evidence of safe rejection and automatic recovery, not zero tool
errors. The captured native proposal is downstream of adapter/codec processing;
raw website response bytes were not retained, so the precise origin of that
formatting error is not independently established.

All ten completed model responses retained the same session, document and
first-message fingerprint, while each completion recorded its own submitted
prompt fingerprint and advanced the response count by one. Completion proof
preceded each tool dispatch. Continuation `submission_verified` journal rows
can have an empty prompt fingerprint while pending; the completed-response
records contain the required proof. The final website release and cleanup
receipt were verified, separately from closing the task's local-browser tab.

## Build 322 provider blocker

The later Pro attempt stopped after 1.299 seconds with
`website_verification_required` and zero tool calls. Its first native
inspection recorded a fresh server redirect to Google's `/sorry` route,
with a settled document and no Gemini document commit. The native classifier
uses the HTTPS Google checkpoint route, not a loose CAPTCHA keyword match.
The session was admitted before that first failure, so a stale saved block
alone does not explain this attempt. The failed untouched inference view was
closed with a saved cleanup receipt; no prompt was replayed.

A subsequent single reload of the normal human Gemini tab also displayed a
Google CAPTCHA. That UI observation is separate from the task's finite route
diagnostics. The reason Google selected the checkpoint remains unknown; the
evidence does not attribute it to WebKit version, request rate, IP reputation,
model choice or the heading repair. The task failed before the Gemini adapter
could submit a prompt or verify Pro selection.

At this point Gemini live attempts paused at the verification boundary.
Resolving a displayed challenge and completing a fresh controlled qualification
are separate steps. The successful Flash-Lite and Flash runs do not establish
that the Google checkpoint is fixed, nor that Pro, Argon or Claude is qualified.

Both local fixture servers were stopped and their process/port shutdowns
verified. The second Flash-Lite tool fixture was prepared but never dispatched.
The installed app is signed Computa 0.7.0 (322), source `46da292`; its artifact
audit passed. It is not a notarized or published release.

## Provider-scoped selector refresh

The task composer now names and refreshes only its selected website provider.
A Gemini task's **Refresh Gemini models** action uses the existing guarded
Gemini discovery path without probing ChatGPT or Claude. Settings retains the
explicit all-provider action. Invalid provider payloads fail closed; they do not
fall back to all providers. Successful discovery replaces only Gemini's catalog;
failed or invalid discovery preserves the saved entries. A removed model stays
unavailable in historical selections instead of being silently substituted.

The last observed Gemini choices are 3.5 Flash-Lite, 3.8 Flash, 3.1 Pro and
4 Argon. New supported versions are discovered from the website's enabled
choices, not populated from marketing names or a guessed API catalog. The
then-current CAPTCHA prevented a fresh account-specific catalog claim. This refresh
change is not a CAPTCHA-prevention fix and does not replay stopped tasks.

Build323 selector validation passed 128 WebUI tests (594 assertions), typecheck,
the production UI build, and 39 native tests. The native run covers scoped
replacement, malformed requests, retained unavailable selections, failure
atomicity, idle rechecks and explicit recovery intent. Two stale test expectations
were first reproduced in the preserved build322 binary, then corrected to assert
the existing safeguards; production queue behavior was unchanged. These are
local validation results, not a new Google catalog read or CAPTCHA clearance.

## Build 323 resumed qualification

An ordinary human Gemini navigation initially loaded a healthy composer and
triggered verified, provider-scoped recovery. The enabled website choices were
again 3.5 Flash-Lite, 3.8 Flash, 3.1 Pro and 4 Argon. A subsequent Pro task reached
a fresh Google verification redirect before model selection or prompt submission.
After the user authorized the displayed CAPTCHA, one checkbox action returned
the normal Gemini composer and completed verified recovery. No browser identity,
profile, cookie or network configuration was changed. Neither recovery establishes
CAPTCHA prevention or identifies Google's triggering signal.

The first composed Flash-Lite workflow failed despite ten verified inference
rounds. The model read the complete source, README and tests but never requested
an edit. It ran the unchanged helper and submitted its incorrect reference; the
fixture rejected it. The source remained byte-identical to baseline and independent
tests failed. Browser-tab closure and website cleanup were separately confirmed.
The UI's completed turn therefore did not establish completion of the user's work.

A fresh Pro workflow after CAPTCHA completion attempted seven patches, all with
numeric unified-diff hunk headers that the custom patch grammar interpreted as
nonexistent source context. Two replies also batched the patch with dependent
tests. Later proposals changed, including assumptions that rejected edits had
already applied; this was not one identical response replayed throughout. The
controlled task was stopped after 129.651 seconds. No repair or browser submission
completed. Its original cleanup failed; one explicit cleanup retry later verified
closure of the same temporary session.

The cleanup diagnostic identified `action=stop`, `stage=proof_missing` with the
current submitted body already verified. The Gemini adapter excluded Stop from
its submission-proof result paths, while native cleanup required that proof.
The repair must prove the current prompt before Stop and return fresh proof
afterward; changed ownership must still prevent cleanup. Separately, shared
instruction changes clarify authorized repair/retest dependencies and the custom
patch grammar. Instruction delivery tests alone cannot establish model adherence.

All build 323 failures are retained as failures. Fresh tasks are required to
qualify the candidate; no stopped prompt or uncertain submission is replayed.

## Build 324 local repairs and validation

Gemini Stop now uses the existing full current-submission observer before input
and again for its returned proof. Both awaited reads reject a superseded
invocation. No model-picker interaction, prompt replay, parser relaxation or
ownership exemption was added. The old adapter reproduces the live
`stop/proof_missing` failure in the same native test binary; replacing only its
resource passes that case.

A separate native regression reproduced failure of valid Gemini cleanup when
its caller was already cancelled. All providers now use the existing bounded
cleanup task and receipt cache previously used for ChatGPT. Actual cleanup still
performs all route, temporary-mode and prompt-ownership checks. This separate
reproduction does not replace the Stop-proof explanation for the captured live
failure.

Fresh website handoffs clarify that authorized repairs require edits and retests
before dependent actions, and that custom patches use bare/contextual `@@`, not
numeric unified-diff headers. Edits and dependent checks must await matching
results; rejected patches require reading actual state before a changed retry.
The full native instruction contract shares these rules. The existing API
checkpoint and its hard size limits remain unchanged.

Local validation passed 155 Gemini JavaScript tests (5,648 assertions) and
188 relevant native tests: 27 transport/ownership cases plus 161 instruction and
response-codec cases. New JavaScript Stop cases fail against the old resource.
Changed first/current prompts, changed ownership, superseded reads and uncertain
post-click state retain their rejection behavior. The cancelled-caller regression
fails before the shared cleanup-task change and passes after it. An initial test
scaffolding compile error and prompt-budget failures were corrected; their logs
are retained. These tests establish local behavior, not live model reliability.

Installed build 324 matched the signed artifact and preserved the four original
human browser tabs. Fresh Flash-Lite and Pro workflows then stopped with
`invalid_model_output`: the custom tool proposal did not satisfy the required
literal-string input / no-function-arguments shape. Flash-Lite had dispatched
two read/test commands and Pro one read command; no calls from the invalid
reply were dispatched. Both temporary website sessions closed successfully.
These are failed workflows, not successful code-edit qualifications. The raw
rejected proposals were not retained, so their exact malformed fields cannot
be reconstructed from the error alone.

Inspection found an inconsistency in the shared website response handoff: its
last catalog called all tools functions, including custom tools, and its final
tool-call example only demonstrated `arguments`. The earlier custom-tool
instructions correctly required literal `input`. The next candidate separates
function/custom catalogs and demonstrates their distinct wire shapes at the
final serialization point, respecting the current tool-choice policy. Build 325
passes 59 instruction and 103 response-codec tests for these changes, including
function-only, custom-only, mixed, no-tool and restricted-tool cases across the
website providers. Canonical request bytes, schemas, literal input and strict
rejection remain unchanged. The unchanged adapter and cleanup code retain their
155 JavaScript / 27 native transport checks. No automatic retry was added, and
live qualification is still required before claiming reliable workflows.


## Build 325 controlled workflows

The installed, signed build matched commit `0103b68`. A fresh 3.5 Flash-Lite
workflow passed in 65.389 seconds across nine verified inferences and eight tool
calls. It repaired only the requested function, passed all six independent tests,
printed the expected reference, and submitted it exactly once through the built-in
browser. The page receipt matched the final answer. Persisted receipts separately
confirmed physical task-tab closure and temporary website-session closure.

A fresh 3.1 Pro workflow repaired the same bug, passed the tests, submitted the
correct reference once, read the receipt and closed its task tab. Its eighth
inference failed the model-selection check after the response finished rendering,
so the overall workflow failed after 76.941 seconds and no final answer was
accepted. All seven accepted tool rounds and the eighth submission carried
3.1 Pro selection evidence. The failing observed identity was not retained; the
existing logs cannot distinguish a real website model switch from a verification
defect. The failure is retained without replay, and both cleanup receipts are
closed. A bounded mismatch diagnostic is required before further controlled
reproduction can establish the cause.

Build 326 adds a Gemini-only, once-per-session mismatch diagnostic at the adapter,
evidence-validation, pinned-selection and post-await rejection boundaries. It
retains only recognized expected, pinned and observed model identities plus a
finite action/stage/sequence; invalid values are reduced to presence flags. It
does not log prompt/response text, relax verification, or retry a prompt. For a
concrete Gemini model, both successful native validations must equal the same
immutable selection; a post-await disagreement cannot arise after both pass.
The diagnostic is scoped to investigating the captured concrete-model failure,
not a claim that every future provider mismatch is fully explained.


## Build 326 live results

The diagnostic tests passed after correcting one new test expectation: the
synthetic Gemini picker initially selects its third label, not the first. The
diagnostic correctly reported the actual changed selection. Thirty other cases
passed unchanged; the corrected real-WebKit drift case then passed separately.
The signed installed artifact matched commit `9799ab7`.

A fresh Pro task stopped after 2.051 seconds with `model_unavailable`, before any
prompt or tool dispatch. Exact-window picker diagnostics showed Flash-Lite enabled
and Flash, Pro and Argon disabled. A subsequent normal-browser inspection showed
all three disabled rows saying “Limit resets Oct 29 at 4:42 PM” (America/New_York).
The provider-scoped catalog refresh retained only enabled choices and marked the
saved Pro choice unavailable. This is current website usage-limit evidence; the
unretained identity in the earlier build325 failure prevents exact retroactive
attribution. The advertised reset time is not proof of restored availability.

The next Flash-Lite workflow failed and was stopped after 129.986 seconds. All
17 accepted inferences retained model, prompt and temporary-session proofs. Six
custom patch calls were routed correctly but rejected for missing hunk-line
prefixes or incorrect context. A later whole-file shell rewrite removed the
opening module-docstring quotes, introducing a syntax error outside the requested
function. It repeated failing commands and filled an unverified reference in the
browser; no submission occurred. The independent audit refused to execute the
malformed helper. Protected inputs remained unchanged, and both website-session
and automatic task-tab cleanup were verified. This is failed repair behavior,
not successful qualification or recurrence of the custom-call envelope error.

The native history contains each correlated custom-tool rejection. The continuation
validator requires those outputs and the Gemini serializer preserves the complete
input; no feedback-loss defect was demonstrated. The shared patch guidance will
make required line prefixes explicit and use a valid patch-specific serialization
example. That is a targeted instruction improvement whose adherence still needs
fresh live qualification, not a parser relaxation or a claimed transport repair.

Build327 shares a complete update-patch example between native instructions and
the final serialized custom-call example. It includes unchanged-context, deletion
and addition lines with source indentation, quotes and backslashes preserved.
Fresh guidance requires a prefix on every hunk line, including blank lines. The
specialized example is emitted only for the actual allowed custom `apply_patch`
name; other custom tools retain their generic literal-input example. Existing
instruction size limits, response parser, tool policy and ownership checks are
unchanged. All 162 instruction/response-codec tests passed; the unchanged transport
and adapter retain their 31 native and 155 JavaScript checks. Fresh live model
qualification remains necessary.

The signed installed build327 matched commit `84681dd`. Its first fresh
Flash-Lite attempt stopped after 0.885 seconds with website verification required,
before prompt submission or tools. The fixture remained pristine and its server
was stopped. One normal Gemini navigation then displayed Google's `/sorry`
checkbox challenge at 20:16:52 UTC. This is a new challenge after the earlier
approved CAPTCHA was completed; it does not qualify the patch guidance or show
that CAPTCHA prevention is solved. Fresh action-time approval is pending for the
displayed challenge. The separately observed higher-model usage limits also still
require a new availability check after the advertised reset.

## Resumed build 327: first-query digest race

The user approved the displayed challenge, and one checkbox action cleared it at
approximately 23:10:46 UTC. The normal Gemini composer returned, and its picker
showed all four concrete models enabled. Computa's provider-scoped refresh then
exposed the same choices. This establishes recovery for that challenge, not
prevention of future challenges.

The next fresh Flash-Lite task failed after 4.607 seconds with
`website_ownership_unverified` / `submission_message`, after submission proof but
before any tools. The retained first failure came from `verifyModel` while
hashing the first submitted query. The digest matched, but the old query root and
body disconnected during the await; the count remained one and the current root
changed. The replacement's text was not retained, so equality cannot be assumed.
The adapter's post-digest recovery covered later queries but omitted the first.
It revoked the session, and automatic cleanup plus one explicit cleanup retry
remained unconfirmed. No prompt was replayed, no fixture submission occurred, and
the fixture files remained unchanged. The original failure and cleanup receipts
are retained separately from any subsequent fixed-build qualification.

Build328 extends the existing first-query replacement proof to a replacement
during the verified submission's digest. Only a read-only inspection with both
native prompt pins may request it. The helper checks the full replacement text,
marker, hash, owner, route and temporary mode again, while a stable invocation
guard prevents a superseded read from installing a certificate. The interrupted
read supplies no answer or submission proof; the existing native budget allows
one fresh full inspection. A current-submission rejection now retains its
original cause instead of being masked by a later first-message recovery check.
Nothing replays a prompt or relaxes the action, response or cleanup requirements.

Both new timing regressions failed against the previous adapter. The final
JavaScript suite passed 182 tests and 6,046 assertions, including 27 new cases.
The retained failed test attempts include three legacy expectations of the old
error masking; their assertions now require the original rejection and finite
diagnostic evidence, with the rejection and no-replay checks preserved.

All 33 relevant native checks passed: 31 existing cases passed in the first run,
and both new real-WebKit cases passed after correcting their callback recorder
to observe the actual `inspect` read and its single fresh inspection. No
production code changed between those native runs. The unchanged instruction
and codec source retains its 162 passing checks. Live qualification of build328
remains separate from these offline results.

## Build 328 live qualification

The signed installed artifact matched `e9a3dfe`; executable, resource and signature
audits passed, and the four original user tabs were restored.

| Model | Controlled result |
| --- | --- |
| 3.5 Flash-Lite | One composed workflow passed in 60.533 seconds: 9 verified inference rounds and 8 tool calls. |
| 3.1 Pro | Verification blocked after 0.882 seconds, before a prompt or tool call; session cleanup confirmed. |
| 3.8 Flash | Not yet rerun on this build. |
| 4 Argon | Not yet run on this build. |

The Flash-Lite run first reproduced the failing tests, read the source and README,
applied one valid custom patch only to `summarize`, and passed all six tests. It
opened the loopback page, filled the independently expected reference, submitted
once, and returned the page's exact receipt. Independent audits confirmed the
protected files, complete source diff, commands, ledger, observed receipt and
reported answer. All nine responses retained the selected model, full current
prompt proof and stable first-query/session lineage. Website cleanup was verified.
The model omitted `browser_close`; Computa's automatic task cleanup closed the
exact task tab, with a persisted receipt and original tabs preserved. This is
app cleanup, not evidence that the model followed that final instruction.

The next Pro attempt encountered a fresh verification block. One normal Gemini
navigation also showed a new unchecked CAPTCHA, and testing stopped. The prior
approval was used to complete the earlier challenge; fresh action-time approval
is pending for this distinct challenge. No prompt was replayed. Fixture servers
are stopped. These results establish one current-build Flash-Lite workflow, not
repeated reliability, Pro/Argon qualification or prevention of Google's CAPTCHA.

## CAPTCHA recurrence audit and overlapping model refreshes

The earlier October 8 recovery removed stale local admission state after Google
was already healthy. It did not establish CAPTCHA prevention. The build328
incident is a new server verification redirect, also visible in the normal
Gemini tab. The exact signal that triggered Google's decision remains unknown;
neither the WebKit version nor a lost verification cookie has been established
as its cause.

The audited normal, Gemini inference and Gemini discovery views share the same
persistent website data store and browser identity. The isolated ChatGPT store
is a separate path. Cache migration clears HTTP caches, and cookie retirement
selects only ChatGPT temporary-conversation cookies. No explicit Google cookie
deletion or Gemini reload/search loop was found in those paths. Total provider
HTTP traffic and server-side verification state were not measured.

One avoidable page load was reproduced: a manual catalog refresh queued behind
automatic human-verification recovery performed a second discovery even after
the first discovery succeeded. Two native regression tests failed on that old
queue behavior, observing two Gemini discovery calls instead of one.

The fix satisfies an overlapping manual request from a successful recovery only
after catalog validation and publication, with the app still idle, the same
trusted settled human document, and no saved verification checkpoint. Failure,
unconfirmed cleanup, an invalid catalog, a replacement checkpoint or a revoked
human source preserves the manual request. Other providers retain their order,
and a later explicit refresh still performs new discovery. The freshness check
does not clear checkpoints or authorize recovery; existing transport verification
and cleanup remain authoritative.

All 59 targeted native tests passed, including scoped/global refresh behavior,
recovery admission, checkpoint persistence and WebKit source revocation. The
source remained unchanged during the run, and independent review found no
actionable issue. These offline fixtures made no live provider requests. The
change is not installed yet; Computa remains on build328 while the displayed
challenge awaits fresh action-time approval. This fixes the reproduced duplicate
load, not proven CAPTCHA causation or prevention. Whether this overlap occurred
before the latest challenge remains unestablished.

Computa 0.7.0 (329) was subsequently built from `b303fea` with the same tested
production source; only the build number changed after the 59-test run. The
signed artifact passed executable, resource, version, Developer ID and hardened
runtime checks. It is staged locally, not installed, notarized or published.
Build328 and its open challenge remain in place. A read-only inspection confirmed
that the same unchecked challenge was still displayed; no CAPTCHA action or new
provider request was dispatched. Current-build live tests and recurrence testing
remain incomplete pending challenge approval and verified recovery.

## Build 329 live results

The user approved the displayed challenge on October 30. One checkbox action
returned the normal Gemini composer and all four enabled models. The redirect
displayed an exemption expiry around 02:39 UTC, preceding completion around
04:40 UTC. That is an observed timing confounder, not proof of the actual cookie
state or the cause of previous challenges. No token or IP value is retained in
the bounded evidence. Build329 was installed from `b303fea`, passed its full
bundle/signature audit, restored the original four tabs, and successfully loaded
a new normal Gemini page after restart.

The fresh Flash-Lite workflow failed independent review after 44.049 seconds.
Seven inference rounds and six tool calls retained their model/session/prompt
proofs, but the model ran the failing baseline tests, read the full README and
source, then skipped editing and verification. It submitted an invented reference
once and read `wrong_reference` twice. Its final claim that the file was repaired
and tests passed was false: the source remained unchanged and no successful
retest or reference-producing command occurred. The fixture rejected the single
submission. Website cleanup succeeded, and automatic app cleanup closed the
task tab. This is a failed task, not a passing browser or code-edit workflow.

Independent inspection found the failed test output and complete source in the
native history. The successful build328 run used identical developer
instructions and unchanged codec, tool catalog and Gemini driver. No captured
transport defect explains this omission; exact outbound schemas were not retained,
so per-round full tool availability is not independently attested. Another
instruction change is not justified by this result alone.

The next Pro attempt was blocked after 0.916 seconds before prompt submission or
tools. Native diagnostics show a server redirect without a Gemini document
commit. One normal-browser reload displayed a new CAPTCHA as well. The fixture
remained unchanged, with no submission, and website cleanup succeeded. Both
fixture servers were stopped. This recurrence demonstrates that the redundant
discovery fix alone did not prevent the issue. New challenge approval and the
remaining model runs are pending. A bounded, read-only cookie-metadata diagnostic
is being prepared to compare callback-time native candidate metadata across
healthy and verification pages. It cannot establish which cookies a rejected
request sent or why Google rejected it. It is not yet installed and does not
change admission or cookies.

Build330 adds this diagnostic after successful committed navigations to exact
Gemini and Google verification routes. It reports only finite destination/role
enums, shared-store identity, and bounded candidate-cookie counts split into
future-expiring, expired and session categories. Gemini and verification-page
destinations are evaluated separately. Values, arbitrary cookie names/domains,
URLs, queries, IP addresses and absolute expiry times are excluded. Metadata is
not proof of an HTTP Cookie header, authentication or CAPTCHA clearance.

Reads are asynchronous, limited to once per document generation and 16 per app
session. A callback whose entry, view, document, route, store or tool-use state
changed reports unavailable with no counts. No callback is pending, not a known
zero. The hook adds no navigation, wait, cookie mutation or recovery authority.
All 111 targeted native tests passed with unchanged source, including 13 new
metadata/privacy and local-WebKit lifecycle tests. Independent review found no
actionable issue. Live collection is pending; no causal conclusion is drawn.

The signed build330 artifact from `f8381b7` passed executable, resource, version,
Developer ID and hardened-runtime audits. It is staged, not installed or
published. Build329 and its current challenge remain open. The approved earlier
challenge was consumed once; fresh action-time confirmation is pending for the
new challenge. Remaining models and repeats are unfinished.

## Build 330 live results

The newly approved checkbox cleared at 06:08:33 UTC. The normal composer and
all four enabled model choices returned. Its displayed redirect exemption
expiry was 07:49:48 UTC, still in the future. Build330 from `f8381b7` was then
installed and independently audited against the complete staged bundle,
production source, version, executable/resources and signature. The original
four user tabs were restored; a normal Gemini page loaded after restart.
The app has not been notarized or published.

| Model | Current-build result | Qualification boundary |
| --- | --- | --- |
| 3.1 Pro | Passed in 141.554 seconds: eight verified inference rounds and seven tool calls | One complete file-edit, terminal and built-in-browser workflow; repeat remains open |
| 4 Argon | Blocked in 0.929 seconds by `website_verification_required` | No prompt submitted, model response or tool call; not exercised |
| 3.8 Flash | Not dispatched on build330 | Current-build qualification pending |
| 3.5 Flash-Lite | Not dispatched on build330 | Prior build329 task failure remains retained; current-build qualification pending |

Pro reproduced the original test failures, changed only the permitted aggregation
function, reran all six tests successfully, and printed the independently expected
reference. It opened the local fixture through the built-in browser, submitted
exactly once, observed and reported the unique accepted receipt, and explicitly
closed its task-created tab. The persisted physical cleanup receipt confirms
closure with no pending action or failure. Independent code, protected-input,
server-ledger, provider/model, exact-prompt and session reviews passed. The initial
nonzero command was the intended baseline reproduction, followed by the successful
retest. No later user instructions were added.

The next fresh Argon task observed a server redirect to Google's verification
route without any Gemini document commit. Its fixture stayed unchanged and its
submission ledger stayed empty; the failing fixture audit is preserved, classified
as not exercised rather than a model failure. Website-session cleanup succeeded
for both tasks, and both local servers were stopped. One reload of the normal
Gemini tab then displayed a new unchecked CAPTCHA at 06:22:39 UTC. Fresh action-time
approval is pending. No prompt or uncertain submission was replayed.

The metadata hook completed reads in the shared store for the healthy human
Gemini `/app` page (25 scoped candidates), healthy model `/app` page (24), and
blocked model `www.google.com/sorry/index` page (18). Each reported zero
`GOOGLE_ABUSE_EXEMPTION` candidates in all expiry categories. These are different
destination scopes and callback times; they do not prove equal sent cookies,
cookie loss, or absence of exemption state elsewhere. Query parameters and other
storage are outside this diagnostic. The current evidence cannot determine
whether a cookie was set before the restart. The recurrence happened before the
displayed expiry, so the earlier already-past redirect expiry is not necessary
for the observed recurrence pattern; it still does not establish actual cookie
validity or Google's rejection cause. The next controlled comparison is recovery
and a fresh task without restarting, if the new challenge is approved.

## CAPTCHA persistence comparison on unchanged build330

The next approved checkbox cleared at 06:35:28 UTC without restarting the app.
At 06:35:31 and 06:35:32, the normal page and automatic model-discovery page each
reported one future-expiring, non-session exemption candidate and 25 scoped
cookies. A fresh normal Gemini tab at 06:38:21 reported the same counts and loaded
the composer without a challenge. These are native candidate observations, not
cookie-value comparisons or proof of the request Cookie header.

The app then quit normally and reopened the same installed build, without
reinstallation or settings changes. Its PID changed from 46181 to 58017. Gemini
was the first provider opened after restart; its composer loaded, and the native
callback at 06:42:52 again reported one future exemption candidate and 25 scoped
cookies. The original four user tabs were restored afterward. This paired test
does not reproduce automatic loss on ordinary restart. The earlier zero-after-
restart and current one-after-restart followed different challenge completions;
they do not establish that a particular cookie was lost.

Two fresh, single-response Pro tasks then tested owned-session creation and
cleanup without file, terminal or browser-action workflows. Both returned their
exact unique marker and retained model, prompt, temporary-mode, ownership and
cleanup proofs: 11.539 seconds and 8.433 seconds, with zero tool calls. The latter
page's native callback at 06:59:00 still reported one future exemption candidate
and 25 scoped cookies. No CAPTCHA was observed in these completed comparisons.
These checks do not resume or replace the deferred full model qualification.

An intervening task failed with `inference_evidence_unsaved` after observed
prompt insertion. Local storage briefly reported `ENOSPC`; no response or tool
call was released, and the cleanup receipt initially could not be saved. The
failed attempt and its incomplete journal are retained. After removing about
306 MiB of old, rebuildable Clang cache, a cleanup-only action durably saved the
original closed-session receipt without resending the prompt or restarting the
model. The subsequent passing task used a new prompt and new session. This
storage failure is not a CAPTCHA result and does not establish the cause of the
earlier Google redirects.

A separate local fixture used a unique app identity and new WebKit profile,
without loading a URL or accessing Computa's profile. Two synthetic cookies with
explicit 24-hour expiry survived immediate view/store teardown and a separate
reader process; the session-cookie control did not. The initial cleanup-only
process crashed before its callback. A separately built cleanup helper initialized
WebKit and deferred termination outside the callback, then acknowledged removal
of exactly that synthetic profile. Original writer/reader evidence and the crash
remain preserved. This is a generic persistence control, not a reproduction of
real-cookie loss or a production fix.

Source review found no Google-cookie deletion in discovery, temporary-session
cleanup, app shutdown or cache migration. ChatGPT retirement rechecks a
ChatGPT-only domain/name/path filter. No new production patch is justified by
the current persistence evidence. The current verification is working, but the
earlier rejection trigger and behavior after future provider expiry or risk
changes remain unresolved; no permanent CAPTCHA-prevention claim is made.

## Build331: observe the missing lifecycle boundaries

The build330 persistence comparisons sampled only after a provider navigation.
Those callbacks cannot distinguish a cookie that survived restart from one
reissued during navigation. Build331 adds a read-only observer bound to the
shared WebKit store, with initial, settled-navigation, model-closure and early
shutdown observations. It projects the same seven fixed destination scopes and
coarse remaining-lifetime buckets from one native callback. Cookie values,
identifying metadata, absolute expiry and arbitrary URLs are not logged.

Reads are single-flight, coalesced and bounded by rolling budgets. Deadline,
supersession, exhaustion and shutdown gaps remain explicit unknowns; a timeout
does not cancel a native operation or permit overlapping reads. Late callbacks
cannot publish stale data. These observations do not delay navigation, mutate
cookies, authorize recovery or weaken any model/session verification. They are
diagnostics, not a CAPTCHA-prevention fix or request-header proof.

The controlled restart comparison must collect the initial store callback while
a blank view is open, before navigating to any provider. Compare that baseline
with shutdown and fresh owned-session samples. A challenge while an unexpired
candidate remains would falsify simple absence/expiry as the explanation for
that run; it would still not reveal Google's private rejection criteria.

Local qualification caught two diagnostic assumptions before installation.
First, OSLog truncated the rich JSON projection at about 1,020 bytes: 34 of 87
synthetic records were invalid JSON. The versioned compact wire format retains
all seven scope/count/lifetime rows under a 1,000-byte whole-message limit.
The real XCTest log collector then accepted all 546 records, including 206
available snapshots, without malformed JSON. Per-session sequence resets in a
multi-session test process are reported, not rejected as truncated records.

Second, the isolated nonpersistent WebKit fixture delivered no cookie-change
notifications to either the timeline or an independent observer after verified
native and document.cookie writes. Re-registering after document initialization
did not change that result. The early JavaScript probe also used the SDK's void
completion-less overload; its corrected probe confirmed the write but still
received no notification. These failed controls are preserved. Native change
notifications remain best-effort; silence is not evidence of an unchanged store.
Explicit lifecycle snapshots are required for the restart comparison and are
tested against the actual synthetic cookie state independently of notifications.

Storage is a separate unresolved hypothesis. A retained receipt reports only
156,160,000 bytes free at 06:20:26 UTC, two seconds before the blocked Argon
cookie observation. No correlated WebKit/SQLite cookie-write failure was retained.
The later ordinary restart retained a future candidate, and the 06:49 ENOSPC
failure affected inference evidence. This chronology establishes storage pressure
before a recurrence, not the cause of Google's challenge.

The final targeted cohort passed 137 tests with zero failures and unchanged
sources during execution, including the explicit lifecycle fallback. Earlier
failed diagnostic probes remain separately retained. This establishes local
metadata, lifecycle and verification regressions; it is not live CAPTCHA
prevention evidence.

## Build331 live recurrence with persisted, unexpired state

Build331 from `cf36dc6` passed complete source, executable, resource, version,
Developer ID and hardened-runtime audits and was installed. Before any Gemini
navigation, the initial shared-store callback at 08:15:50 UTC contained one
future exemption candidate with more than an hour remaining. The normal Gemini
page loaded, and a fresh Pro task completed eight verified inference rounds over
94.941 seconds without CAPTCHA. That task nevertheless failed its exact-marker
instruction: it unnecessarily used seven browser tools, filled the marker into
the normal tab and ultimately clicked the model picker, then returned the wrong
answer. Two stale click proposals were rejected before dispatch. No Send action
was captured. Its exact unsent test draft was cleared separately, and its owned
session was confirmed closed. This is an adherence failure, not a passing task
or proof that CAPTCHA recurrence was fixed.

The model-close sample at 08:19:48 and early shutdown sample at 08:21:56 still
contained one future candidate with more than an hour remaining. The app quit
normally and reopened the identical build: PID 92783 became 94965. With a blank
view and before any provider navigation, the 08:22:22 callback again found one
future candidate with more than an hour remaining.

The next fresh, explicitly tool-free connectivity task hit a Google verification
redirect in 1.313 seconds. No prompt was submitted, no model selection was
established and no tool ran; cleanup was confirmed. The first-failure navigation
diagnostic reports `serverRedirectObservedInCurrentNavigation=true` and
`geminiDocumentCommitObserved=false`, so WebKit observed a redirect during the
new navigation rather than rejection solely by a stale local checkpoint. The
delegate callback does not establish whether the HTTP redirect came from the
network or cache. The challenge-settled callback at
08:23:29 and model-close callback at 08:23:30 still found one future candidate.
Its lifetime bucket was now more than ten minutes and at most one hour; the
67-second interval is consistent with crossing the one-hour bucket boundary,
not expiry. These results hold across all seven fixed scopes.

A single normal-browser navigation at 08:26:40 also displayed Google's unchecked
CAPTCHA; its native callback retained the future candidate. No new challenge was
completed, no blocked prompt was replayed, and model qualification remains
stopped. The cookie survives ordinary restart before navigation, and its native
metadata is not expired when the challenge occurs. Complete candidate loss or
metadata expiry therefore does not explain this occurrence. Cookie identity,
actual request-header inclusion, partition eligibility and Google's acceptance
are still unproven. Inspector approval was pending at this boundary;
no root-cause fix or permanent CAPTCHA-prevention claim is justified yet.


### Redirect provenance and one bounded reload comparison

The redirect flag records `didReceiveServerRedirectForProvisionalNavigation` on
the bound view; it contains no response headers, cache-source metric or HTTP
status. It must not be read as proof that Google freshly rejected that request
over the network. The remaining inspection needs both actual request-cookie
inclusion and response/cache provenance before choosing an HTTP-cache change.

At 08:43:25 UTC, one ordinary Reload of the normal tab's visible challenge left
its unchecked CAPTCHA in place. The new settled callback at 08:43:26 retained
one future candidate with more than ten minutes and at most an hour remaining.
No checkbox was clicked, no model prompt was replayed and no verification state
was cleared. This does not reproduce the earlier reload recovery; because it
reloads the current challenge URL, it also does not determine the cache source
of the original Gemini redirect. No repeated reload or speculative cache purge
is justified by this result. Inspector approval was still pending at this point.

### Approved request inspection and another restart recurrence

The user approved temporary inspection of the normal Gemini tab. Computa's
per-tab Inspector control and Safari's developer feature setting were both
originally off. Both were enabled for this inspection and restored to off;
Inspector and its app-selection window closed afterward. Network caching stayed
enabled. No HAR, raw Cookie/Set-Cookie header, cookie value or page-body capture
was retained.

One ordinary navigation to `https://gemini.google.com/app` at 13:15:46 UTC
loaded the signed-in composer without another CAPTCHA completion. Inspector's
document details explicitly reported **Source: Network**, status **200**, and
a response Date matching that navigation. The actual Request section contained
a Cookie header but no `GOOGLE_ABUSE_EXEMPTION` name. The response did not set
that name and specified `Cache-Control: no-cache, no-store, max-age=0,
must-revalidate` and a past Expires date, with no Age header.
This is direct request-boundary evidence for this successful navigation only.
The earlier blocked redirect's headers and cache source remain unavailable.

Three native lifecycle samples at 13:15:48–50 also found zero exemption
candidates in all seven scopes. More than four hours had passed since the
08:23 sample with at most an hour remaining, so current absence is consistent
with expiry. It is not evidence of lost persistence or that removing a cookie
caused recovery. The old challenge remaining visible throughout the idle
interval is not proof of continuous network rejection.

After restoring inspection settings, fresh case C selected 3.1 Pro and verified
the exact no-tools marker prompt at 13:19:45. Computa recorded no assistant answer
or tool calls before `provider_timeout`, after 302.341 seconds. Its model and
initial-submission evidence were preserved; the same owned session closed with
a durable cleanup receipt. Native snapshots at navigation and closure had zero
exemption candidates. No CAPTCHA block was recorded for this task, but no finite
inspection-progress records were available to distinguish provider generation
from extraction or completion-detection failure. This is a failed task, not
model qualification or a CAPTCHA fix; it was not replayed.

The idle app then quit normally at 13:25:27 and reopened the unchanged build
at 13:25:35 (PID 94965 to 91508). A blank WebKit tab's initial callback at
13:26:03, before provider navigation, contained zero exemption candidates.
The first normal Gemini navigation at 13:26:34 displayed an unchecked CAPTCHA;
the challenge-settled callback at 13:26:35 also contained zero candidates.
No model prompt or CAPTCHA action was dispatched after restart. The user's
four original tabs were restored and the challenged Gemini tab left selected.
Inspection of this new tab required a new approval, received the following day. The next
causal boundary is the blocked request's outgoing cookie-name presence and
explicit response/cache provenance, rather than another speculative cache or
cookie change.

Local evidence: `captcha331-lifecycle/inspector-current-recovery.json`,
`captcha331-lifecycle/marker-c/capture/independent-boundary-review.json` (SHA-256
`c938179a1d7c0f18746882fbb9786364f3ec8e61e915a9f5589e03b278ba4230`),
`captcha331-lifecycle/restart-two.json`, and the corresponding
`cookie-timeline331-*` receipts under the October 29 qualification evidence
directory. The prematurely bounded pre-tab collector's empty result is retained
separately from the later successful blank-tab initial capture.

### October 31: approved inspection of the new tab

The same installed build331 and process91508 remained running, with the same
normal Gemini tab showing the old unchecked challenge. After the user approved
temporary inspection, one user-dispatched navigation to Gemini `/app` at
06:19:52 UTC reached its composer. Inspector explicitly reported Source Network,
HTTP200 and zero redirects. Its response Date matched the navigation, with
`Cache-Control: no-cache, no-store, max-age=0, must-revalidate`, `Pragma: no-cache`,
a past Expires date and no Age header. The actual outgoing Cookie header was
present but lacked the exemption-cookie name; the response did not set that
name. Caching remained enabled, and no CAPTCHA action or model prompt was sent.

The historical blocked `/app` resource listed unknown status and source,
"No request headers" and "No response headers." Those fields are unavailable
historical evidence, not proof that the request lacked cookies or never reached
the network. This successful request cannot reconstruct that blocked chain.
Three shared-store lifecycle snapshots during the inspection window contained
zero exemption candidates across all seven scopes, without rejected records or
explicit gaps. These events lack tab attribution and do not exclude automatic
recovery/discovery activity.

Inspector and its app-selection window were closed. Safari's developer setting,
the exact Gemini tab's inspection permission and Preserve Log were restored to
their original off states by 06:21:53 UTC. No source or browser setting was
changed to produce the recovery. The overnight interval remains an uncontrolled
factor, so this is another bounded recovery observation, not a root-cause fix,
CAPTCHA-prevention result or model-task qualification.

Evidence: `captcha331-lifecycle/inspector-oct31-recovery.json` and
`cookie-timeline331-oct31-inspected-navigation.json` in the same local evidence
directory. The missing blocked request boundary still needs to be captured
during a recurrence before choosing a production change.

### Build332 candidate: preserve final-response metadata

Delayed Inspector attachment twice captured a later recovery while the earlier
blocked resource exposed no response metadata. Build332 adds a synchronous,
read-only sample at the existing native navigation-response policy callback,
before the unchanged admission and navigation decisions. It records only fixed
Gemini `/app` or Google `/sorry` route classes, HTTP status and conservative
finite projections of Cache-Control, Date, Age and Expires. It never reads or
logs Cookie, Set-Cookie, Location, response bodies or arbitrary header fields.
Unsupported or malformed metadata remains unknown.

The context identifies the current physical view and document generation at
callback time. WebKit supplies no navigation token at this boundary, so it does
not establish the exact redirect-hop identity. The record explicitly leaves
request cookies, redirect-chain completeness and network/cache source unknown.
Final challenge-page cache headers cannot establish the preceding Gemini
redirect's policy. This diagnostic fills the final-document status gap; it is
not a CAPTCHA-prevention fix or a substitute for contemporaneous Inspector
evidence of the complete blocked request chain.

Sampling is capped at two records per current document generation and twelve
per rolling sixty seconds across the browser session. The fixed JSON projection
is capped at768bytes and the entire event at1,000bytes. Missing samples must not
be interpreted as an unchanged page or absence of a request. The diagnostic
does not navigate, retry, clear verification state, mutate cookies, enable
Inspector or change an allow/cancel decision.

All16 new local tests passed, covering privacy canaries, unknown values,
current-view/closed-view checks, generation limits and staggered rolling-budget
boundaries. An independent local nonpersistent WebKit fixture observed the final
429 response after a302 redirect; it does not claim all redirect responses are
exposed. An actual XCTest log capture accepted38 events with no malformed records
and a maximum544bytes. The complete targeted verification cohort passed153 tests
with unchanged sources. These results qualify the local diagnostic only;
installed Google callback capture and CAPTCHA prevention remain unproven.

Evidence: `native332-focused`, `native332-final` and the source-bound build/audit
receipts in the same local evidence directory. At staging, build331 remained
installed while current-tab Inspector reproduction approval was pending;
staging alone did not establish installation or live qualification.

### October 31: bounded inspection and captured restart response

The approved inspection of build 331's current normal Gemini tab captured two
address navigations and one ordinary reload between 07:27:43 and 07:28:52 UTC.
All three were explicitly Source Network, HTTP 200, with zero document redirects,
current response Dates, no-cache/no-store/max-age=0/must-revalidate, a past
Expires date and no Age header. Each outgoing Cookie header was present but
omitted the exemption name; none of these responses set that name. Three native
navigation samples also contained zero exemption candidates in all seven scopes.
The initial Inspector accessibility list showed only older virtualized rows;
filtering revealed the three new requests. An intervening computer-use timeout
was recovered by rebinding and checking the current UI, without another request.

One harmless prompt was then sent directly in a temporary website chat. Gemini's
visible Pro mode returned the exact requested marker. This is direct website
evidence, not verified selection of the app's specific 3.1 Pro choice or harness
qualification. The later answer observation is an upper time bound, not a
generation latency measurement. No CAPTCHA appeared or was completed. Preserve
Log, Safari's developer preference and the tab's inspection permission were all
restored off, and Inspector/chooser windows closed by 07:34:11 UTC.

Diagnostic build 332, source `05d364f`, was subsequently installed with complete
source/resource/executable/version/signature audits and a preserved rollback
build. Inspector remained off. The first normal Gemini navigation after this
update returned a native HTTP 200 callback and reached the composer. Its response
metadata was captured automatically with the correct human-tab identity. Cookie
samples before any provider navigation and afterward both contained zero
exemption candidates. Fresh owned-session marker A then passed in 9.332 seconds with
verified 3.1 Pro selection, one verified submission, the exact answer, zero tools
and saved closed/not_created cleanup. Its native response callback was 200 and
its document generation matched the ownership journal.

An ordinary restart of the same installed build reproduced the failure. With
only a blank human tab created beforehand, the first owned provider navigation
for marker B received HTTP 429 at Google www/sorry at 07:45:10 UTC. The response Date
was in the up-to-one-minute bucket and its cache metadata indicated no-cache,
no-store and must-revalidate. The native observer saw a redirect before any
Gemini document commit. The task failed in 0.977 seconds before model selection or prompt
submission, with zero tools and saved closed cleanup. Initial, challenge and
closure cookie samples all contained zero exemption candidates in all seven
scopes, which does not distinguish this failure from marker A's success.

This captures an actual challenge response rather than only a saved application
error. Its attribution is the exact process, model role and single-task window;
the pre-submission journal lacks a document generation for a direct join. Native
callbacks still do not prove outgoing-cookie inclusion, network/cache source or
the initiating redirect's cache policy. These results establish current
observability and another recurrence, not a root-cause fix or CAPTCHA prevention.
Further inference attempts stopped. Inspection of a separate blank human test
tab for one contemporaneous navigation was requested, with no CAPTCHA-completion
authorization inferred.

Local evidence: `captcha331-lifecycle/inspector-bounded-oct31.json`,
`cookie-timeline331-bounded-inspection.json`, `artifact332-installed-audit.json`,
`captcha332-lifecycle/restarts.json`, both marker capture directories and their
independent reviews, `response332-postrestart.json`, `response332-marker-a.json`,
`response332-marker-b.json`, and the matching `cookie-timeline332-*` receipts.

### October 31: approved blank-tab navigation reproduces the challenge

The user approved temporary inspection of the existing blank human tab and one
normal navigation to Gemini, without CAPTCHA completion. Web Inspector was
attached before the address submission at 08:09:57 UTC. Network was selected,
Preserve Log enabled and Disable Caches left off. The tab reached Google's
unusual-traffic page with an unchecked CAPTCHA. The native callback at
08:09:58 UTC captured HTTP 429 on Google www/sorry, with the exact human tab and
current generation, a recent Date bucket and no-cache/no-store/must-revalidate.
The native cookie sample had zero exemption candidates in all seven scopes.

Inspector's title followed the navigation, but the unfiltered Network view
contained zero resources and zero transferred bytes; filtering for the initial
Gemini URL also returned no records. Preserve Log was visually confirmed on.
No request headers or initial redirect source were available. An empty Inspector
recording does not establish that no requests or redirects occurred, and native
cookie metadata is not an outgoing-header observation. The recording gap itself
requires investigation before another live capture is useful.

This reproduces the challenge in a normal human tab on the same process roughly
25 minutes after the owned-task failure. It weakens an explanation confined to
the model view but does not rule out an earlier model request affecting shared
browser or server state. Request order, time and startup state remain confounded.
No prompt, reload, CAPTCHA completion or uncertain action replay occurred.

Preserve Log, Safari's developer preference and the Computa tab's inspection
permission were restored off and visually verified by 08:11:49 UTC. Inspector
and the app/device chooser were closed. ChatGPT, both Kimi tabs and Gmail's Sent
folder were restored, with ChatGPT selected. The earlier individual Gmail
message subview was not restored, and no mail action was taken.

Local evidence: `captcha332-lifecycle/inspector-blank-failure-oct31.json`,
`response332-approved-blank-navigation.json` and
`cookie-timeline332-approved-blank-navigation.json`.

### October 31: local control isolates the failed recording sequence

Two disposable standalone WebKit apps used nonpersistent storage, one retained
native view and an identical loopback fixture server. Both permitted one explicit
navigation through a 302 redirect to synthetic 429 HTML, then one explicit fetch
returning 200. No provider or user-profile request was made. Inspector's Network
tab used Preserve Log on and Disable Caches off in both arms.

Arm A matched Computa's untouched new-tab construction: a WebKit view existed
but no document had been loaded before Inspector attachment. Server and native
receipts proved the redirect and final response; the page also confirmed the
fetch. Inspector recorded zero resources throughout. Closing and reattaching
Inspector after the page loaded revealed only historical document placeholders
without status, source or request headers.

Arm B completed a local `about:blank` document before Inspector attachment.
The subsequent fixture navigation appeared with GET, HTTP 429, Source Network,
the initial request headers, the 302 redirect response and final response
headers. The later fetch appeared with HTTP 200. Server receipts independently
confirmed exactly one request to each fixture path, and the native view remained
inspectable with nonpersistent storage in both arms.

This single paired control supports initializing a document before Inspector
attachment, or attaching to an already-loaded human test document, for the next
capture. It reproduces a recording failure independently of Google and Computa's
adapter logic. It does not establish the exact WebKit defect, a process swap or
the Google rejection trigger. App identities, ephemeral ports and execution
times necessarily differed. No production navigation or verification behavior
was changed. Inspector/chooser windows were closed, Preserve Log and Safari's
developer setting restored off, both fixture apps quit and their loopback
servers stopped. Local source, build, native/server and UI receipts are retained
under `inspector-local332` and `inspector-local332b`.

### October 31: capture succeeds; cache comparison does not clear the challenge

Inspection of the already-loaded human challenge tab retained the next normal
navigation's metadata. At 08:38:56 UTC the same process and tab reached Gemini
with HTTP 200, explicit Source Network, no redirects and a current Date. Its
outgoing Cookie header was present without the exemption name; the response did
not set that name. This was 28 minutes 58 seconds after the previous human 429,
without a restart or CAPTCHA completion in between. Request history, timing and
provider state changed, so it is recovery evidence rather than an isolated fix.

A second, model-owned 200 appeared 1.969 seconds later and its view closed. The
source-defined automatic recovery path creates one owned catalog-discovery page
after a healthy human document settles while a saved checkpoint exists. The
persisted recovery report said verified and the checkpoint was absent. These
facts support that attribution, although the report does not bind the response's
tab ID. This extra request is counted separately from the single manually
dispatched navigation. It sends no user prompt; ordinary healthy navigations
without a checkpoint do not repeatedly start this recovery probe.

After settings were restored, fresh marker C passed in 9.101 seconds with exact
prompt/answer, verified 3.1 Pro selection, zero tools, continuous ownership and
saved closed cleanup. A separately approved bounded comparison then restarted
the unchanged build, initialized only a human `about:blank` document and attached
Inspector before any human Gemini visit. Marker D was dispatched 120.975 seconds
after launch and failed in 1.124 seconds: no website model-selection proof,
submission, tool or answer, with matching closed cleanup. A native callback
captured the model view's actual HTTP 429 before Gemini committed.

| Observation | UTC | Result |
| --- | --- | --- |
| Fresh owned D after restart | 08:53:56 | Native model-view HTTP 429; no prompt sent |
| Approved normal human navigation | 08:54:30 | Inspector 302 to Google `/sorry`, then 429 |
| Approved navigation with Disable Caches visually on | 08:56:27 | Another 302 to `/sorry`, then 429 |

Both captured redirect responses and both final challenge responses had a Date
matching their respective new request, no-store/no-cache/must-revalidate, a past
Expires date and no Age header. Inspector reported Network for the final resource
in both cases. The cache-disabled comparison did not recover. Its checkbox was
visibly checked although Accessibility still reported zero, so no independent
backend acknowledgment of the setting is claimed. Summary Network also is not a
source observation for every redirect hop. Together, the metadata and comparison
argue against a simple stale cached redirect as the explanation for this run;
they do not prove the whole HTTP-cache implementation correct.

The initial redirected request lacked Cookie, Accept-Encoding, Accept-Language
and HTTP-version fields in Inspector; the final challenge request included those
fields and cookies without the exemption name. This is not evidence that the
initial wire request omitted cookies. [WebKit issue 190214](https://bugs.webkit.org/show_bug.cgi?id=190214)
documents missing refined load metrics for earlier redirect hops, including
headers and protocol; current upstream source retains those refinements only for
the final resource. The local fixture showed the same display pattern. This
supports an Inspector limitation, not an exact installed-version diagnosis or a
cookie-delivery fix.

The seven scoped total-cookie counts were 29/20/20/20/21/21/21 at marker C's
closure, but already 28/19/19/19/20/20/20 in the old process's shutdown sample.
The first sample after restart exactly matched that latter matrix. Thus this
count reduction is not demonstrated restart loss. All exemption categories
remained zero. The www.google.com scopes later decreased from 20 to 19 at the
cache-disabled sample; no cookie identity/value was retained, and the change
cannot be attributed to the toggle. Equal counts are not proof of equal cookies.

The approved budgets were exhausted without CAPTCHA completion or prompt
replay. Cache disabling, Preserve Log and both developer settings were restored
off by 08:57:42 UTC; Inspector/chooser windows closed. The three user tabs present
before restart were restored by 08:58:21 UTC. The ChatGPT tab was already absent
and was not recreated. Root cause, prevention and current broader qualification
remain unresolved. The differing startup delays and prior request histories
prevent treating these runs as a matched causal experiment.

Evidence: `captcha332-lifecycle/inspector-loaded-recovery-oct31.json`,
`loaded-inspector-recovery-report.json`, marker C/D capture directories,
`controlled-restart-d.json`, `restart-d-normal-failure.json`,
`restart-d-cache-bypass-failure.json`, `restart-d-comparison-summary.json`,
`response332-loaded-inspector-recovery.json`, `response332-marker-c.json`,
`response332-controlled-restart-d.json` and matching cookie receipts, including
`cookie-timeline332-pre-restart-d-shutdown.json`. All paths are relative to the
local qualification evidence root, with lifecycle records under its named folder.

### October 31: approved recovery passes foreground and owned restart comparison

The user approved completion of the challenge currently displayed in the human
Gemini test tab, followed by the prepared bounded comparison. The checkbox
cleared without an image-selection step. Native callbacks captured human Gemini
HTTP 200 at 09:15:29 UTC and a separate model-role HTTP 200 at 09:15:31 UTC,
followed by model closure. The latter is consistent with the separately counted
automatic recovery catalog probe; it preceded the direct prompt. Thus the
baseline's request history was not exclusively foreground navigation.

Cookie callbacks now contained one future exemption candidate with over one hour
remaining, applicable in each of the seven fixed scopes. Earlier C/D runs had
zero exemption candidates. Completing the challenge changed provider/browser
state, so this is a new baseline rather than an isolated change to interaction
style. The scopes overlap and do not imply seven distinct cookies.

| Case | Path | Startup to first Gemini action | Verified result |
| --- | --- | --- | --- |
| E | Direct website after approved recovery | Existing process | UI-selected 3.1 Pro, exact marker, one submission |
| F | Direct website after ordinary restart | 125.331 seconds to navigation | Human HTTP 200, UI-selected 3.1 Pro, exact marker, one submission |
| G | Owned task after second ordinary restart | 126.873 seconds to dispatch | Model HTTP 200, verified 3.1 Pro, exact marker, 11.158 seconds, zero tools, closed cleanup |

F and G each began with only an initialized human `about:blank` document; no
earlier Gemini visit or owned task occurred in either process. Inspector remained
off and cache behavior unchanged. F's initial and settled cookie samples, and
G's initial, settled and model-closure samples, all retained the future candidate
and unchanged aggregate counts. This disproves mandatory complete loss on every
restart, but does not establish cookie identity or actual transmission. The
roughly two-minute startup delays are comparable, not identical, to D's failed
120.975-second run; request order, elapsed time and server state still differ.

G's independent native review confirmed the exact prompt and answer, one
submission, stable website model evidence, session/runtime/document identity,
both ownership fingerprints and the matching saved release receipt. Its HTTP 200
callback directly joins the ownership journal's document generation. E/F marker
answers and model selection are website UI evidence. Their 21.460/11.998-second
observation upper bounds must not be compared with G's native duration as a
latency benchmark. F's native
response capture ended before its final answer/release observations, which are
retained separately as UI evidence.

E/F temporary views were released by verified navigation to `about:blank` after
their answers; this does not claim server-side deletion. No new CAPTCHA appeared,
no additional challenge was completed, and no uncertain prompt was replayed.
The comparison used its prepared limits: two direct submissions, one owned task,
two restarts and one specifically approved CAPTCHA completion. The three user
tabs were restored by 09:29:27 UTC; no temporary developer settings were enabled.

Both paths working on unchanged code after recovery does not identify why the
prior challenge was issued, prove prevention, or qualify browser/terminal/file
tools. No production patch is justified by these successes alone. Root-cause
investigation remains open; an isolated foreground-versus-owned failure was not
reproduced under this fresh verification state.

A read-only identity check also found no installed bundle-version mismatch:
Safari 26.5 and system WebKit both report build `21624.2.5.11.4`. The shared
configuration retains WebKit's platform/engine prefix and adds Safari product
tokens only when those exact builds match, plus `Computa/0.7.0`. Human and model
views use that same configuration path. This source/bundle check is not a live
wire-header capture and does not rule out provider compatibility or risk scoring.

Evidence: `captcha332-lifecycle/foreground-comparison-plan.json`,
`foreground-e/{plan,outcome,view-release}.json`, `foreground-f/{plan,outcome}.json`,
`marker-g/{plan,restart,dispatch}.json`, its native capture directory,
`response332-approved-captcha-foreground-e-full-window.json`,
`response332-foreground-f.json`, `response332-marker-g-navigation.json` and the
matching cookie timelines. Lifecycle subpaths are relative to that named folder;
response/cookie receipts are at the local qualification evidence root.

### October 31: network-path audit and real request-factory controls

Read-only system snapshots found no enabled HTTP/HTTPS/SOCKS/PAC proxy flags.
One connected network service is Tailscale; its CLI reported Running, no exit
node status, and no health entries. Current kernel routes for Gemini's eight
IPv4 and eight IPv6 results all use `en0`. An active StudyLock content-filter
extension was also listed. Neither a default route nor extension presence
establishes actual per-app or historical egress. No network, DNS or protection
setting was changed.

One normal navigation to Cloudflare's documented diagnostic endpoint in each
browser observed the same public IPv6 address: Computa at 09:36:36 UTC and the
Codex in-app browser at 09:37:09 UTC. Computa's response reported HTTP/3 and the
expected Safari 26.5/Computa identity; Codex reported HTTP/2 and Chrome 156. Both
reported TLS 1.3 and WARP off. Only address equality/family was retained; raw
addresses were discarded, both test tabs closed, and the original selection
restored. This tests a single diagnostic host, not Gemini routing, a historical
failure, or HTTP-version causation.

The live hosts file maps Google Search hosts to Google's SafeSearch VIP.
Current `www.google.com` IPv4/IPv6 results both match the resolution of
`forcesafesearch.google.com`; Gemini's do not. Google's
[documented SafeSearch setup](https://support.google.com/websearch/answer/186669?hl=en)
uses this mapping. It is not, by itself, a faulty configuration or proof that it
caused the initial Gemini redirect. The inspected StudyLock checkout contains a
hosts/DNS guard but does not identify the active canary filter; its installed
metadata was inaccessible. No claim about that installed filter's exact behavior
or a SafeSearch bypass is justified.

`EmbeddedBrowserInitialRequestTests` now observes real loopback HTTP requests
through unchanged human/model factories, their retained production delegates,
and one isolated nonpersistent store. Both factory orders are covered: human
then model through 302 to 200, and model then human through 302 to 429. Each case
observed exactly four requests: one initial GET and one redirect per tab, with
identical transmitted User-Agent, expected Host, no body, a shared synthetic
cookie on both hops, and exclusion of a cookie with a different path. Both
cookies remained in the store. The two focused tests passed in 0.455 seconds;
incremental compilation/linking succeeded, and source hashes were unchanged.

The test window is attached but unshown. These controls establish generic
factory/navigation behavior during the observed loads, not visible foreground
equivalence, delayed retry absence, Google provider transport, HTTPS/TLS,
cross-site cookie eligibility or persistent-profile restart behavior. The
installed app and production source were not changed. This closes a concrete
wire-observation coverage gap without declaring an unproven prevention fix.

Four additional native turns occurred in the existing G chat between 09:30:31
and 09:32:01 UTC, outside the controlled comparison. Their model document
generations exactly join four HTTP 200 callbacks. Each had one user-role input,
verified submission/completion and saved closed cleanup, with no native terminal
error. They used Pro once and Flash-Lite three times; the last turn had four
inference rounds and three tool calls. Metadata does not identify the human/UI
source of submission, and prompt/answer contents were not inspected. These are
not fixture qualification, and this interval must not be described as idle or
unexplained recovery traffic. The later bounded response capture contained no
records, which is not proof of no requests.

Evidence: `network332-system-snapshot.json`, `network332-tailscale-status.json`,
`network332-google-routes.json`, `network332-safesearch-resolution.json`,
`network332-browser-comparison.json`, `response332-post-g-idle-{a,b}.json`
(filenames predate `native332-post-g-turn-attribution.json`), and
`initial-request-loopback332/{test.log,result.json}` at the local evidence root.
Cloudflare describes the diagnostic endpoint in its
[endpoint documentation](https://developers.cloudflare.com/fundamentals/reference/cdn-cgi-endpoint/).
