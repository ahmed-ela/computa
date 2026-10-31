# Claude harness qualification

Claude qualification resumed on October 31, 2026. The current live account offers
Sonnet 5.5, Haiku 5.5, Sonnet 5 and Sonnet 4.6; Fable and Opus choices are upgrade
gated. The prior cached Haiku 4.5 choice was absent from the observed menu.
These account-specific observations are not model qualification results.

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
