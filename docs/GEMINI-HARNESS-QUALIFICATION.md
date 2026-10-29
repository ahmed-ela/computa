# Gemini harness qualification

Gemini qualification resumed on October 29, 2026. Gemini uses Computa's
shared Responses interface and browser, terminal and file tools, retaining
one owned temporary website conversation across tool rounds. Claude and the
broader browser-engine expansion in issue #9 remain outside this work.

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
