# Claude harness qualification

Claude qualification resumed on October 31, 2026. The November 1 picker in the
installed build359 presents Sonnet 5.5, Haiku 5.5, Sonnet 5 and Sonnet 4.6, plus
Opus 5.5, Opus 5, Opus 4.8, Opus 4.7, Opus 4.6 and Opus 3 as enabled controls.
Fable 5.1 and Fable 5 require usage credits. Haiku 4.5 remains absent. This
read-only inspection sent no prompt and changed no model; enabled picker controls
are availability observations, not successful inference or workflow evidence.
The newly visible Opus choices still require independent qualification.

As of November 1, build359 is installed and published as `v0.8.0-alpha.359`.
PRs #14 and #16 were squash-merged at `c3ca191`; the released binary was compiled
from `92b4b3e`, with build-input equivalence checked after merge. No live Claude
qualification has yet been recorded after build354. The Claude adapter,
instructions, projection and codec in build359 match build354, while shared
transport/server code changed for Groq. Component equivalence is not a current
live-model pass.

The build353 exact-submission
proof and bounded correction passed native tests and live transaction checks.
The latest Sonnet 5 and Sonnet 4.6 workflows returned refusals, so neither is
qualified for tool workflows. Haiku 5.5 passed a fresh response control but its
next workflow failed on a rejected call shape. Sonnet 5.5 completed the fresh
build353 workflow; earlier successful build349 workflows remain separate
evidence. Build354 adds capture for the missing rejection category; its fresh
Haiku workflow ended in a capability refusal after verified tool execution.
The release includes these known limitations; full qualification remains open
in issue #15.

## Candidate 360: capture the post-tabs request

The build354 Haiku refusal correctly recalled its previous edits, passing tests,
reference and browser controls. The retained transcript does not identify lost
history, but it also does not contain the exact final projected request. Repeating
the same workflow without that evidence would not distinguish missing tools from
a model refusing an intact handoff.

Candidate360 adds a private, default-off request capture immediately before Send.
An operator-created `ClaudeRequestDiagnostics-v1/arm.json` must name one exact
native task, turn and concrete Claude model, a nonce and an expiry within ten
minutes. Its fixed `after_browser_tabs` trigger matches only an immediate linked
native call/output pair. Earlier requests and mismatched arms do not consume it.
The one-shot `request.json` preserves the final prompt, original canonical request,
finite projected tool catalog, hashes and native inference/session identifiers.
It is explicitly `pre_send`, with `submissionVerified=false`; later submission,
ownership, model and cleanup records remain necessary evidence.

The capture reuses the rejected-reply diagnostic's private file and exclusive
publication checks. Missing, expired or unsafe arms, capture failures and existing
output files do not change inference behavior. It adds no replay, format repair,
tool permission or website authority, and writes no prompt contents to logs.
The bounded next experiment is a fresh loopback browser workflow that opens a
page, inventories tabs, reads it, submits one harmless reference, reads its nonce
receipt and closes only its own tab. This diagnostic experiment does not replace
the full browser, terminal and file-editing qualification requirements.

Validation: nine capture tests and 18 existing rejected-reply tests passed. The
native open→tabs handoff test verifies that the capture equals the actual third
transport prompt, retains original schemas/history and shares the later verified
inference identifiers and prompt hash. Its first run failed because Foundation's
temporary-path normalization retained `/var`, a symlink correctly rejected by the
private-file guard. Changing only the fixture to POSIX `realpath` produced a
passing rerun (0.997 seconds); production checks were unchanged. Both run logs
and unchanged-source receipts are retained. Nine version tests also passed.
These are local diagnostic/integration tests, not a live Claude qualification.

## Baseline: completion remains unverified

Signed installed Computa 0.7.0 (340), source
`b8ffe5794793633c1f362e0db28cb8310d0b530d`, sent one fresh Sonnet 5.5 marker task.
Website selection and first-message ownership verified at submission acknowledgment. Within
about three seconds the native adapter saw one answer, 63 text bytes and
`busy=false`, but no scoped Copy controls and `answerComplete=false`.
The turn failed at its five-minute deadline after 301.305 seconds; no final
answer or local tool call was accepted.

An independent failure audit joined the started/failed inference, session,
preparation and runtime identities to its saved `closed/not_created` receipt,
recorded 119 ms after failure. Selection-only Sonnet 5.5 evidence was present at
submission; there is no completed-response model proof. The failed transcript,
native logs and screenshot are retained, and its prompt was not replayed.

A separate harmless direct Incognito control in the ordinary embedded browser
returned its exact marker. Its accessibility tree exposed a completed assistant
message, a Message actions toolbar with Copy/Read aloud/Retry, and the status
"Claude finished the response." That is a direct website result, not a repaired
harness result.

## Candidate 341: bounded structural diagnostics

The candidate records finite completion-landmark state and at most four nearby
ancestor shapes. It distinguishes missing scopes from observed zero counts,
contains no reply text, URLs, arbitrary identifiers or CSS classes, and retains
the existing completion and ownership checks. Native validation uses a closed
schema and bounded records. A reserved idle observation ensures streaming
changes cannot consume the diagnostic needed for this failure. Diagnostic
exceptions or invalid values cannot authorize or reject an otherwise valid
response.

Signed build341, source `7da9620e364924b21746d53d356380acb9bbaf1a`, passed 108
adapter tests and six native tests and was installed after all artifact checks.
Its fresh Sonnet 5.5 request captured the mismatch at the first idle read:
one article, one assistant, one reply body and one message-actions bar;
`data-is-streaming=false`; one Copy-labelled button in that bar; **zero** buttons
matching the old `data-testid="action-bar-copy"` requirement. The obsolete test
identifier prevented completion despite the semantically correct Copy control.
The diagnostic did not record whether the identifier was removed or renamed.

After preserving those facts, the operator stopped the diagnostic request at
77.050 seconds. Its genuine interrupted turn, zero tool calls and matching saved
closed cleanup receipt are captured separately. It is not a qualification pass.
No Web Inspector settings were enabled for these observations.

## Candidate 342: semantic Copy-control binding

The repair locates the unique Copy-labelled button in the latest owned response's
single message-actions bar instead of relying on the obsolete button test ID.
The response, article, model, first-user ownership, streaming/interruption,
visibility and cleanup checks remain required. Authored reply content, other
messages, ambiguous bars and duplicate, hidden or disabled controls cannot
supply completion. After the final awaited model proof, a synchronous check
requires the same latest answer, physical control and response text; changes
withdraw completion until a fresh read can establish it.

Signed build342, source `edd3a0e1f966a723cca27107d50faf7fbf8e72b7`, passed 113
adapter tests (1,670 assertions) and six native tests. Its installed fresh Sonnet
5.5 check reached verified completion but failed strict envelope parsing after
4.516 seconds with `malformed_website_reply/invalid_json`. No tools ran; the saved
closed cleanup receipt followed failure by 76 ms. This is a preserved failure,
not a model qualification pass.

The captured extraction diagnostic found one code body containing valid JSON of
type `message`, but returned `outside_content`. The website's language caption
had changed from `text-text-500 font-small pb-0` to
`text-secondary text-caption-regular font-sans pb-0`. The unrecognized caption
also prevented exclusion of the code block's Copy control, contaminating the
rendered reply. A separate direct Incognito control exposed the `json code`
container, exact `json` caption, Copy to clipboard control and completed literal
JSON in Accessibility. Its tab was closed. No Inspector settings were enabled.

## Candidate 343: current code-block caption

The next repair recognizes the observed caption structure while retaining exact
`json` text, a single leaf caption/control and PRE/CODE, strict code-wrapper scope,
whole-answer outside-prose rejection and literal JSON/envelope validation.
Signed build343, source `4922a4c35042292e2b46068ba2de69a99dd29aaf`, passed 114
adapter tests (1,786 assertions) plus both native completion/extraction regressions.
The installed artifact passed all source, signature and copied-resource checks.

| Fresh marker task | Result | Native duration |
| --- | --- | --- |
| Sonnet 5.5 | Exact marker, model/ownership and closed cleanup verified | 4.628 s |
| Haiku 5.5 | Invalid JSON: 235 characters of authored prose outside valid literal JSON; zero tools, closed cleanup | 4.470 s |
| Haiku 5.5, instrumented new task | Exact marker and complete proof; unused exact-task diagnostic arm disarmed and retained | 4.315 s |
| Sonnet 5 | Valid response envelope, but refused the wrapper instead of returning the marker; closed cleanup | 10.361 s |
| Sonnet 4.6 | Exact marker, model/ownership and closed cleanup verified | 6.073 s |

These samples establish two extraction fixes, not reliable qualification of all
Claude models. Haiku's later success does not erase its earlier format failure.
Sonnet 5 explicitly identified the app-owned phrases "You are Computa" and
"Assistant refusals are not policy," plus the unexplained session marker, as
conflicting authority cues. The outer relay disclaimer did not prevent that
misinterpretation. Its response is preserved as a failed marker result, despite
successful transport and cleanup.

## Candidate 344: clarify external relay instructions

Clarify the generated app-owned instructions at their source: Computa identifies
the local application, host permission modes do not override website governing
rules, prior capability speculation is not a host access result, and the session
marker is only an opaque correlation label. Preserve actual denials, Stop, the
message/refusal option, exact schemas, user data and canonical history. Do not
strip authored prose or add automatic correction attempts to Claude.
Signed and installed build344, source `92de0ccf6a9a9e0740e6881ee2d6efe747220572`,
preserves all artifact/signature/resource checks. Its instruction and codec
regressions passed across the final targeted runs; the earlier failed test runs
remain in the private evidence.

| Build344 controlled task | Result | Native duration |
| --- | --- | --- |
| Sonnet 5 marker | Invalid JSON inside the literal code block; zero tools, closed cleanup | 7.443 s |
| Haiku 5.5 code/browser workflow | Failed: one malformed command request, two executed commands, no edit or browser action; fourth response denied relay access and returned prose | 25.461 s |
| Sonnet 5.5 code/browser workflow | Passed independent fixture grade: only allowed function edited, six tests passed, exact reference and one browser receipt, task tab closed | 58.931 s |
| Sonnet 4.6 code/browser workflow | Correct edit and six passing tests, then `website_usage_limit`; no browser workflow, final website cleanup unconfirmed | 32.631 s |

Haiku's rejected fourth reply is captured and joined to its own inference,
model, document and session. The three recorded tool calls include one argument
parse rejection (`query` instead of `cmd`); only two commands executed. The
fixture remained broken and its browser ledger empty. All four website sessions
closed. This failure is model response behavior, not response extraction.

Sonnet 5.5 completed eight tool calls across nine independently verified fresh
Incognito sessions. Every accepted response retained model/ownership proof and a
closed cleanup receipt before local dispatch. Its successful workflow shows that
fresh website sessions do not universally prevent the relay from working; it
does not establish reliability for the other Claude models.
The exact task-created browser target also has a persisted native cleanup record
with `closed: true`, no failures and no pending operation; a subsequent native UI
inventory was empty. The tool's generic `existing_user_tab_preserved` field alone
would not have established that task-tab closure.

Sonnet 4.6 exhausted the account's website usage allowance before its browser
step. The fourth inference's cleanup is unconfirmed; the previous three have
closed receipts. Live Claude requests stopped at that error. Local fixture
servers were stopped, evidence retained, and no uncertain task action was replayed.
The account limit must reset before remaining live qualification can resume.
The quota admission gate is process-local and has no reset timer. With manual
model refresh controls hidden, the supported recovery is to wait for the actual
account reset, restart Computa, and start a fresh authorized task. Restart alone
does not reset the provider allowance or prove readiness. Preserve the failed
task and its unconfirmed cleanup; do not replay its uncertain actions.


## Candidate 345: literal request presentation

Present Claude's complete request inside one literal code block and suppress
outer instruction duplicates only when the complete current native contract is
already present in a trusted instruction field. Preserve decoded request values,
user/history/tool data, schemas, governing rules, permission checks, response
parsing and dispatch behavior. Claude does not inherit ChatGPT's single-action
policy or automatic correction path. This is a bounded presentation experiment;
live qualification remains blocked by the account quota.

Validation: 189 instruction, codec, request-frame and failure-history tests passed
on the final source, plus two native quota/checkpoint regressions. The earlier
169-test run had two new fixture-assertion failures: removing an optional suffix
left a complete shorter supported native contract. Correcting that negative
fixture, without changing production behavior, produced the passing full rerun.
The tests preserve complete decoded values and numeric/string lexemes, exact
trusted-context boundaries, permissions/tool choice, refusal envelopes and
strict malformed-response rejection. Exact old quota diagnostics remain readable;
near misses and changed metadata are rejected.

Signed build345, source `b1cfe31b385054d01a58eda3683dae0a12781315`, passed
all 11 clean-source, identity/version, signature and exact-resource checks. Its
artifact is retained locally; it is not installed, published or notarized.
Build345 is a review candidate. Keep the live-tested build344 installed until
Claude's allowance permits fresh qualification of the presentation follow-up.
No claim is made that build345 is installed or that all Claude models are reliable.

## Candidate 347: quota-banner cleanup

The saved build344 failure exposed a local cleanup mismatch in addition to the
external account quota. Its exact quota banner was recognized, and both Incognito
indicators remained physically rendered, but the quota surface made the background
inert or accessibility-hidden. Cleanup allowed physical mode inspection for the
recognized quota popup only, so the banner variant could not establish temporary
mode. The original failed task and unconfirmed receipt remain preserved.

The adapter now identifies either exact quota surface for cleanup only. It
requires one unambiguous surface and one physical Incognito header/exit pair,
outside authored messages, quota content and dialog scopes. A separate unknown
dialog, ambiguous surfaces, missing mode, changed ownership or changed first-user
proof still prevents cleanup. Normal readiness, Send, response acceptance and
quota admission remain strict. The quota cleanup path does not click any page
control; native code closes only its already-owned view after all proofs pass.

Validation: all 871 embedded-provider JavaScript adapter tests passed, with
38,422 assertions. Three real-WebKit native tests passed, including the submitted
banner's valid cleanup and seven rejected mode/ownership/ambiguity cases, plus
the existing popup and empty initial-banner paths. Human tabs were preserved;
blocked attempts did not add input, focus, Send or quota-control clicks.

A separate fresh Sonnet 4.6 Incognito marker returned the exact requested text
on October 31 after the earlier quota failure. This establishes current direct
website readiness, not qualification of the presentation follow-up or the local
harness. Its one test tab was closed, no prior task was replayed, and the old
cleanup warning remains unconfirmed. Build347 still requires installation and
fresh per-model harness qualification before it can be called reliable.

Build347 was then Developer ID signed and installed from source
`ea8d3a84b0b968ed840cea423cd33e5930240727`. The signed main and runtime's code/data
matched the original build; only signature-related fields and runtime integrity
metadata changed. The installed main and all resources matched the signed receipt.

| Build347 fresh marker | Result | Native duration |
| --- | --- | --- |
| Sonnet 5 | Accepted refusal of the relay instructions; expected marker absent | 7.225 s |
| Haiku 5.5 | Exact marker, model/ownership and closed cleanup verified | 4.375 s |
| Sonnet 5.5 | Exact marker, model/ownership and closed cleanup verified | 7.830 s |
| Sonnet 4.6 | Exact marker, model/ownership and closed cleanup verified | 5.679 s |

All four were single-dispatch, zero-tool tasks with completed website responses
and closed cleanup. Sonnet 5's transport completed correctly, but its marker test
failed. It explicitly rejected the claimed Computa identity and tool relay. The
literal-request presentation alone therefore did not solve that model's behavior.
Unused exact-task diagnostics were archived and disarmed; no failed task was replayed.
These marker results do not qualify browser, terminal or file-edit workflows.

## Candidate 348: remove residual identity reassignment

The review found two app-owned templates still beginning "You are Computa":
the runtime's base instructions, sent through website thread/start and resume,
and the model catalog's fallback instruction template. The earlier outer/developer
wording changes had not changed those sources. This is a confirmed instruction
contradiction; whether correcting it resolves Sonnet 5's refusal requires a fresh test.

Both templates now describe Computa as the local host application, retain the
provider's identity and governing rules, and distinguish proposed host work from
execution proved by matching host outputs. The base instruction suffix is unchanged
and the full base remains within its existing 1,024-byte limit at 988 bytes.
No user/history payload, tool schema, permission, parsing, retry or ownership rule
changes. Validation and installed live qualification of this candidate remain pending.

Seven targeted native tests then passed, covering the real website thread/start
contract across providers and access modes, catalog capabilities, the base-size
limit, evidence instructions and native bridge compatibility. The initial routing
run and a diagnostic rerun failed before thread/start because local test-only Bun
discovery resolved the installed executable to `bun.exe`, not the required `bun`.
A byte-verified private copy supplied through `MACTOPUS_TEST_BUN` resolved that
fixture dependency; the original failed logs remain retained. Production interpreter
discovery, permissions and assertions were not relaxed. The installed build348
results below qualify only the explicitly recorded checks.

Developer ID signed build348 was installed from source
`d94ad4f94e7f8499d716316e993b7a6803fbc069`, with source/signature/resource receipts
and unchanged executable payloads after signing. Its fresh Sonnet 5 marker still
returned an explicit refusal of the tool-harness framing after 6.254 seconds.
Model, ownership, completion and closed cleanup all verified; zero tools ran.
The instruction contradiction is removed, but that model remains unqualified.

The first Haiku workflow attempt on build348 was invalidated by the operator's
multiline text-entry method: the first paragraph was submitted and the remaining
two paragraphs became queued messages. The frozen full-prompt baseline therefore
matched no task. The separate partial-task evidence records zero tools, no verified
website submission and closed cleanup. Its finite selection diagnostic saw Haiku
5.5 selected but could not verify that the picker popup had closed. Concurrent
input makes this unsuitable for attributing a new production regression.
The queued fragments were removed without resuming, the fixture server was
stopped, its receipt ledger remained empty and protected fixture files were
unchanged. This attempt has no qualification verdict; it is not a passing or
failed full workflow. Future controlled multiline inputs must use paste and
verify the entire draft before the single explicit Send.

A fresh Haiku 5.5 workflow on build348 used the complete pasted prompt and one
explicit Send. It completed in 92.261 seconds across 12 verified website
inferences, each with verified selection, ownership, completion and closed
cleanup. The independent local fixture audit passed: only the intended function
changed, all six protected tests passed after the edit, the correct reference was
submitted once, the unpredictable receipt was returned, and the task-created
browser tab closed. The browser inventory was empty before and after the task;
the exact local fixture server was stopped afterward.

This was not an error-free run. The initial pre-fix test failure is retained, and
one `exec_command` call supplied empty arguments and was rejected for missing
`cmd` before execution. A later correctly formed call completed the tests. The
workflow succeeded, but the recovered argument-schema defect remains under
investigation; it is not a clean reliability pass. Sonnet 5.5 and Sonnet 4.6
workflow qualification on build348 remains pending, and Sonnet 5 remains
unqualified after its explicit refusal. These draft-PR results do not alter the
public build346 package.

### Required tool arguments (build349)

The recovered Haiku call contained an explicit empty object. The response codec
and event stream preserve arguments; the native parser rejected the missing
`cmd` before command execution and returned a model-visible error. The following
inference supplied a valid command. Raw accepted website text was not retained,
so the original website bytes cannot be independently reconstructed.

The response handoff nevertheless contained a concrete instruction defect: a
copyable function-call example with empty arguments, even for required-field
tools. Build349 removes executable function examples and describes their shape
in prose, requiring arguments to satisfy the offered schema. Custom literal
examples, canonical request data, tool choices, namespaces, legitimate
argumentless calls and native validation/recovery remain unchanged. No new
retry or schema-repair path was added.

All 106 response-codec tests passed. The first instruction run caught a seven-byte
prompt-budget overflow; the wording was shortened by 40 bytes without raising
the limit, and all 62 instruction tests then passed. New coverage spans the three
website providers, plain and namespaced tools, allowed and disabled tool choices,
required command arguments and legitimate empty schemas. Sonnet 5's explicit
refusal is a separate limitation, with no remaining identity contradiction
established by inspection.

### Installed build349 workflows (October 31, 2026)

Developer ID signed build349 was installed from
`358294e2db9b67a34e42d43d02f47497a6fcff7f`. All 11 clean-source build checks and
10 signing-derivative checks passed; installed executable and resource hashes
matched the signed artifact. Two earlier signing attempts failed with confirmed
`ENOSPC` while writing the bundled runtime's code signature. Removing verified
generated duplicates and test products freed enough space for signing; no source
or signing-policy change was needed. Those failed attempts remain in the private
evidence. This build was not published and does not replace public build346.

| Website model | Elapsed | Result |
| --- | ---: | --- |
| Haiku 5.5 | 88.158 s | Completed the local fixture across 12 verified, closed website sessions and 11 tool calls. Recovered from one nonexistent working directory; no empty-arguments call occurred. |
| Sonnet 5.5 | 54.823 s | Completed the local fixture across nine verified, closed website sessions and eight tool calls, with no observed returned tool errors. |
| Sonnet 4.6 | 39.640 s | Completed the code edit, six tests and reference command. The fifth website inference hit the account quota before any browser action; cleanup was unconfirmed. |
| Sonnet 5 | Not run on build349 | Its build348 marker returned a verified refusal. A fresh build349 marker remains pending after the account quota resets. |

For both completed workflows, independent checks confirmed a function-only edit,
unchanged protected tests/data, six passing tests, one form submission, an exact
unpredictable receipt read and returned in the final answer, and closure of the
task-created tab. The ordinary browser inventory was empty afterward. Haiku's
wrong-directory call failed before process creation; its subsequent valid call
succeeded and its final answer disclosed the correction. This is bounded
workflow evidence, not repeated-run or cross-model reliability proof.

Sonnet 4.6 had four accepted responses with verified model, ownership, completion
and closed cleanup, and five successful tool calls. Its fifth submitted session
reported `website_usage_limit`, then `cleanup_unverified` 71 ms later. No browser
call, form POST, receipt or final answer occurred. All three fixture servers were
stopped and the failed task was not replayed. The concrete quota reset time was
not retained; all further Claude requests stopped.

The quota-cleanup failure remains unresolved. Bounded diagnostics recorded one
physical Incognito header and exit control, with neither strictly visible while
the background was inert. The native cleanup first inspects the page and uses
the adapter's quota-only `stop` proof after a usage-limit error. Existing logs
redact the failing action and do not record whether the quota surface remained
recognized, an unrelated dialog was present, or the mode controls still met
their eligibility checks. They establish a temporary-mode proof rejection, but
not its exact cause. The earlier banner fix therefore cannot be claimed to
resolve every live quota-cleanup transition.

Private evidence is retained under `evidence/haiku55-workflow349-f/`,
`evidence/sonnet55-workflow349-f/` and `evidence/sonnet46-workflow349-f/`, with
independent workflow reviews, native traces, frozen fixtures, UI captures and
the bounded quota-cleanup log. Sonnet 4.6 remains partially tested, Sonnet 5
remains unqualified, and this PR remains a draft.

### Candidate build350: capture the failed temporary-mode proof

The next candidate records the actual temporary-mode decision, including the
action, quota surface counts, eligible mode-control counts, unrelated-dialog
result, Incognito query result and a finite rejection reason. Fields skipped by
an early return remain unknown. Quota observations explicitly distinguish the
`stop` check from an earlier classification, so an earlier read cannot be
mistaken for current page state. A later diagnostic read cannot replace the
captured decision.

The native layer accepts only a fixed schema of finite labels, bounded counts
and booleans. Records are size-limited and each session has a small observation
budget with reserved failure and cleanup slots. No page text, account details,
URLs or response bodies are added. These diagnostics do not change quota
classification, model/ownership checks, cleanup admission or retries. Build350
has not been installed or published; the running app remains build349, and the
public release remains build346. The exact live cleanup cause still requires
evidence from a future naturally occurring failure.

All 875 provider-adapter tests passed (39,515 assertions). Both changed Swift
files parsed successfully. An exact-source standalone Foundation harness
compiled and ran the native sanitizer, record splitter, action allowlist and
logging budget with four regression cases and 2,023 assertions; the largest
finite proof record was 415 bytes under the unchanged 960-byte cap. This was not
an app/XCTest integration run. Independent review confirmed the native cleanup
path remained byte-identical and all JavaScript verification predicates remained
equivalent. Tests cover private/unknown fields, malformed types, bounded counts,
reserved failure slots and a page changing during diagnostic extraction.

### Evening recovery and rejected startup (October 31, 2026)

After the user reported that quota should have reset, the app was still running
build349 in its original process. A new Haiku 5.5 `hi` request failed between
`start_requested` and `website_usage_limit` in 18 ms, without a session token,
`started` event or submission. Code and native logs establish rejection by
Computa's remembered provider gate before tab creation. This is not a fresh
observation of Claude's account limit. The gate currently has no timer; a
verified explicit catalog recheck or app restart is needed after recovery.

One separately authorized cleanup-only retry ran against the original Sonnet
4.6 session at 9:11:42 p.m. Eastern. Its fresh page diagnostic preceded a new
manual receipt by 9 ms. Cleanup remained unconfirmed: the physical Incognito
header and exit were present, but neither was strictly visible. No prompt was
sent, no inference was restarted, and the original website and tool traces
remained unchanged. The exact cause of the disabled background remains unknown.

The new Haiku attempt exposed a separate bookkeeping defect. The server marks a
Start as unresolved before calling the native transport. An ordinary thrown
error cannot prove whether a page was acquired, so that conservative behavior
is required for unknown failures. However, the native provider-gate rejection
occurs before any page is reserved or created, and the server previously had
no way to distinguish it. It therefore displayed an unverified-cleanup warning
for an attempt that never created a session.

Candidate build351 adds a native-only proof bound to the exact Start invocation
and its context. Only that initial gate rejection may produce the proof. A
matching current proof records a durable, inference-linked `no_owned_session`
receipt; it grants no session-closure or model-response authority. Arbitrary
errors, page JSON, stale or foreign proofs, and failures after page acquisition
remain unresolved. A failed receipt save can retry persistence without calling
the transport or resuming the model. Earlier cleanup failures, including the
original Sonnet session, remain separate and unverified.

Focused native validation selected 142 tests: 141 passed, one opt-in persistence
microbenchmark was skipped, and none failed. This includes the six real-WebKit
precreation regressions, eight new receipt-store cases, AppState persistence-only
retry, server continuation/cleanup checks and six bundled-runtime restart cases.
The source and tests remained unchanged during the passing run. Earlier runs
exposed a test-helper actor-isolation error and an outdated handoff suffix
assertion; both were corrected without changing production prompt instructions
or dropping assertions.

Build351 was Developer ID signed and installed from `9fef5a2`; all 11 source
checks, 10 signing checks and installed-artifact comparisons passed. The
historical failed cleanup remains unconfirmed after restart. A fresh Sonnet 5
marker failed in 3.569 seconds before prompt submission. Its own exact session
closed successfully with `not_created`; it was not replayed. No quota surface
was observed during this attempt.

The bounded selector diagnostic recorded a clicked selection, observed checked
proof and the header `Model: Sonnet 5 Medium`, followed by `close_unconfirmed`:
the same associated menu remained physically visible. A manual check in an
ordinary Claude tab confirmed Sonnet 5 remains offered and selecting its row
closes the picker. That inspection sent no prompt and its tab was closed.
The log proves failed closure acknowledgement; it cannot alone distinguish an
ignored dismissal from a menu reopened by the trigger toggle. The native
transcript's generic high-demand wording is not evidence of a provider outage.

Candidate build352 replaces Claude's toggle-based dismissal with one Escape on
the exact associated popup. Escape itself supplies no model or closure proof:
the existing popup, trigger, document and ownership checks must still pass.
This addresses a normal selection auto-close racing with the subsequent toggle.
All 878 provider-adapter tests passed (39,576 assertions). Eleven focused native
WebKit tests passed, including the retained-portal race, ignored Escape,
discovery, model drift, and quota cleanup. The two new native cases passed again
after making the fixture's closing commit deterministic. They require real
popup removal before readiness and withhold all prompt insertion when Escape
is ignored.

Build352 was Developer ID signed and installed from `d958ec7`, with all 11
source-build checks, 10 signing checks and installed-artifact comparisons
passing. A fresh Sonnet 5 marker reached a verified response in 7.982 seconds
and its exact website session closed successfully. This establishes that the
picker no longer blocked this attempt. The response declined the unexplained
marker and questioned the external tool contract, so the marker did not pass
and Sonnet 5 remains unqualified. No tool was proposed or dispatched.

A separate Sonnet 4.6 workflow then failed in 15.665 seconds after one successful
terminal read of the fixture README. The second response contained authored
narration outside an otherwise valid JSON tool proposal. Its full 484-byte
response correctly failed strict parsing with `invalid_json`; the proposed
second terminal read was never dispatched. This was not malformed path escaping
or merely a code-block caption. Both exact website sessions closed with durable
`not_created` receipts. No code was changed, and no tests, browser actions or
fixture submissions ran. The rejected reply and partial workflow evidence
were preserved before cleanup. Claude lacks the exact submission capability
required by the existing ChatGPT format-correction path; adding equivalent
proof and a bounded correction is under investigation, without relaxing the
parser or replaying completed actions.

One fresh Sonnet 5 display control then explained why an exact marker was
requested. It returned that marker exactly in 4.454 seconds with one verified
inference, zero tools and a saved closed receipt. The same host instructions,
schemas, permissions and strict parser were used. This qualifies the explained
display control only; it neither retroactively passes the earlier refusal nor
establishes browser or editing support.

The ensuing Sonnet 5 local workflow returned a verified refusal in 9.869
seconds. It declined the externally executed tool contract; zero tools ran,
the fixture remained unchanged, and its exact website session closed. Its
workflow audit therefore failed despite healthy transport. Repeating that
request or treating the display-control pass as tool support is not justified.

Candidate353 adds a distinct first-submission proof for concrete Claude model
choices. Native code binds the canonical prompt and entire outbound body before
Send. A proof is available only after the single native Send acknowledgment,
exact first-user body, current document, model and completed answer agree.
Claude still gets a fresh website page for each inference; this capability
does not claim retained website-conversation support. Legacy bare-provider
requests retain their existing path without gaining format-correction rights.

For a rejected reply with one valid tool-call JSON code block and outside
content, that proof can authorize one response-format correction. The existing
strict parser still rejects the original full reply. The canonical request,
completed tool outputs, selected model and absolute deadline are frozen; the
first website session must have a saved closed receipt before the correction
starts. The durable per-turn claim prevents another correction after restart
or a later inference. Ordinary prose/message refusals and parsed unknown-tool
or schema failures are not corrected. All proposed calls must pass the normal
parser and tool contract on the new response before dispatch.

All 157 selected native tests passed with unchanged source during the run,
including 13 new Claude correction tests and five real-WebKit first-submission
proof tests. Coverage includes changed bodies, lost Send acknowledgments,
model/document drift, ordinary refusal passthrough, single correction claims
across restart, canonical tool-output history, cancellation, saved cleanup,
original deadlines and finite inference budgets. The first attempt exposed a
test-only call passing `nil` to a nonoptional transport API; the fixture now
uses a distinct real transport wrapper to test generation changes. No
production guard was removed to pass that test.

Build353 passed all 11 source-build checks and 10 Developer ID signing checks,
then the installed executable/resources matched the signed receipt. The live
Sonnet 4.6 workflow reproduced narration outside its second response's JSON.
Native proof confirmed the exact submitted prompt on Claude's actual page.
The rejected inference closed with a saved receipt before one new correction
inference began. That reply was a refusal, accepted as a message without any
tool authority. The task ended after 25.801 seconds with only the first README
read dispatched; all three sessions closed. No file edit, test execution,
browser action or form submission occurred. The correction store's
`response_validated` outcome proves response/transaction validation, not task
completion. The workflow remains failed, with its original rejection and
correction records preserved separately.

Haiku 5.5's separate explained display control returned the exact marker in
4.136 seconds with zero tools, the new native submission proof and confirmed
cleanup. Both runs have matching before/pre-arm/after witnesses for the installed
executable, process ID and process start time. They do not establish repeated
reliability or replace the required current-build tool-workflow checks.

Haiku's ensuing build353 workflow failed after 46.439 seconds. It proposed three
separate unchanged pre-edit test runs, then read the source, edited only
`summarize`, opened the loopback form and passed all six protected tests. The
three repeats had distinct inference and call IDs; they were model proposals,
not app replay. It never ran the requested reference-printing command, filled
or submitted the form, or obtained a receipt. The independent fixture grader
confirmed the edited function's output, which is separate from model execution.

Its eighth website reply failed `argumentsMustBeObject`; no calls from that
reply were released. This error also covers missing or extra call fields, so
the exact malformed shape cannot be inferred from its name. All eight website
sessions closed with saved receipts. Computa reported closing the task-created
browser tab during cleanup; that is not a model-issued close or proof of task
completion. The rejected-reply recorder did not cover this error category, so
the actual rejected text was not retained and the unused opt-in arm was archived.

Candidate354 fills only that diagnostic gap. Exact-task, opt-in capture now
recognizes function-call and custom-call shape failures with finite diagnostic
reason codes. The original parser error, whole-reply rejection, correction
eligibility and cleanup remain unchanged. In particular, it neither normalizes
arguments nor retries a parsed call-shape failure. Capturing a fresh failure is
necessary before attributing it to an argument value type or instruction issue.
All 56 focused capture/correction native tests passed with unchanged source,
including 28 new matrix cases across two test methods. They cover both response
stream modes, valid-call prefixes that must not escape rejection, missing and
extra fields, wrong value types, exact-task opt-in and private-file permissions,
unconfigured or mismatched capture requests, existing-record preservation and
ordinary cleanup without correction or replay.

Sonnet 5.5's independent build353 workflow completed in 53.443 seconds: nine
verified and closed website inferences, eight tool calls, and no returned tool
errors. It edited only `summarize`, passed all six protected tests, printed the
correct reference, filled the loopback form, submitted exactly once, observed
the unpredictable receipt through the browser and included it in its final
answer. A model-issued `browser_close` released its task tab. The independent
fixture audit passed; the ordinary browser panel was empty afterward. The
initial diagnostic watcher expired before the prompt was sent during an
operator interruption; its untouched receipt was archived after checking that
no matching task or capture arm existed. The unchanged watcher then armed for
one Send. Before/pre-arm/after installed-process witnesses matched. This is one
current-build workflow pass, not a reliability rate or an all-model pass.

Build354 passed all 11 source-build and 10 Developer ID signing checks and was
installed with the exact signed executable and resources. Its fresh Haiku
workflow ended after 62.033 seconds with nine verified, closed website
inferences and nine dispatched calls. Two separate pre-edit test calls failed
on the original bug; after the function-only edit, all six tests passed and
`python3 reconcile.py` printed the correct reference. The browser opened the
ready fixture with usable fill/click references, and a tab inventory confirmed
the bound page. The final response then said Computa's tools were unavailable.
No fill, submission, receipt or model-issued close occurred. Computa reported
closing the task tab during cleanup. The workflow failed despite successful
transport and preserved history; no call-shape error occurred on this run, so
the earlier argument-shape defect remains unproven resolved. The unused exact
diagnostic arm was archived after terminal capture and independent audit.

Review found no concrete contradiction or omitted handoff in this run's relay
contract. It already distinguishes JSON action proposals from website-native
tool execution, identifies host execution and matching outputs, and resends
current schemas and the response contract with complete canonical history.
The refusal itself accurately recalls the earlier edit, tests, reference and
page fields. Fresh per-inference website sessions could still influence model
behavior, but this evidence does not establish that causal explanation. No
parser relaxation, speculative prompt change or automatic retry was made. A
second fresh fixture was prepared but remains unsubmitted; the partial task
was not replayed. Current evidence supports a bounded Sonnet 5.5 workflow pass,
not reliable tool support for every Claude model.

An offline follow-up on 2026-11-01 at 03:32 UTC passed
`RuntimeEmbeddedBrowserToolsTests.testHaikuFreshSessionsPreserveHistoryAndBoundCatalogAfterOpenThenTabs`
(one test, zero failures, 1.254 seconds). It used the production native runtime's
JSON-RPC browser operations and actual task/thread/turn/preparation-bound browser
availability, with an inert browser backend. Three fresh, concrete-Haiku server
inferences used explicitly synthetic website replies and submission proofs.
After `browser_open` and `browser_tabs`, the captured transport prompts retained
all canonical history and tool-output text parts, the current browser schemas,
and the bound-browser execution handoff. The test also checked distinct website
sessions, sequence-one submission hashes and verified release records. It
performed no real website request, fill or submission.

The retained evidence is
`work/groq-qualification-20261031/native-claude-projection-g-receipt.json` and
`native-claude-projection-g.log`. The receipt records exit zero, unchanged source
during the run, and log SHA-256
`0e294f2050ed92a390ed22fde19a061f0a66721d07cb138a83cd37d9f5df8f3b`.
This checks the local projection/history boundary in a controlled case; it does
not reproduce the live refusal, verify WebKit rendering, or qualify Haiku tool
behavior. The build354 failure retained submission fingerprints but not the
final assembled request and projected catalog, so this test cannot retrospectively
establish their exact contents or the refusal's root cause.

## Qualification contract

Each available family will receive an independent controlled response check and
a safe local browser/terminal/file-editing workflow. The workflow uses separate
fixture folders, immutable tests, a loopback form and a uniquely checkable
receipt. Code diffs, command exit statuses, browser actions, receipt observation
and task-tab closure must agree with the native transcript.

Claude currently uses a fresh owned Incognito website session for each inference,
including tool-result continuations. Every accepted inference must carry the
exact selected model and ownership proof plus a matching closed cleanup receipt
before its tool proposal is dispatched. Gemini's retained-session behavior must
not be assumed for Claude. Website selection does not attest an immutable
backend model version.

Private evidence is retained locally in `work/claude-qualification-20261031/`,
including `evidence/sonnet55-marker340/`, `sonnet55-marker340-timeout.log`,
`direct-control-ax.txt`, and the prepared `fixtures/` cases. No fixture server or
real-mail workflow was started for the failed baseline.
