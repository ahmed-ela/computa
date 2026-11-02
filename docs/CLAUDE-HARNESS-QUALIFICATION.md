# Claude harness qualification

Installed build380 uses source `e62bbbaf80018b4edbc027112af1d5636a048a4a`.
Later documentation commits do not change that installed source. Four fresh,
independently audited local workflows have passed on this build:

| Model | Duration | Inferences / tools | Result |
| --- | ---: | ---: | --- |
| Sonnet 5.5 | 50.569 s | 9 / 8 | Full fixture passed without recorded tool errors. |
| Haiku 5.5 | 89.894 s | 13 / 13 | Full fixture passed; three pre-edit test commands failed, including two redundant reruns. |
| Opus 5.5 | 71.237 s | 9 / 10 | Full fixture passed without recorded tool errors. |
| Opus 4.6 | 134.677 s | 10 / 11 | Fresh full fixture passed without recorded errors or correction. |

A separate earlier Opus 4.6 run completed the functional fixture in 153.929 s
after one malformed reply and bounded correction. Its raw rejected reply was not
captured, so its full transport/correction audit remains incomplete. The later
pass does not diagnose or erase that failure.

Each completed pass joins the permitted function edit, six protected tests,
correct reference, exactly one accepted loopback submission, browser-observed
receipt, final answer, task-tab closure and saved website-session cleanup.
These are separate bounded results, not an all-model pass or a reliability rate.

Opus 5 remains unqualified. The captured build379 request timed out in the
harness; a separate foreground copy of that exact prompt showed Claude's
`reasoning_extraction` safeguards pause. Build380 recognizes the observed
warning layout in tested fixtures, but that detection fix has not been exercised
by a new live Opus 5 case and does not establish prompt acceptance. The failed
native page's exact state was not retained. No Retry or alternate-model action
is authorized by the warning.

Sonnet 5, Sonnet 4.6, Opus 4.7 and Opus 4.8 retain their recorded workflow or
marker refusals. Opus 3 retains its two-attempt format failure. Prior picker
observations marked Fable models credit-gated and did not expose Haiku 4.5;
those observations do not establish current eligibility. Historical failures,
including unconfirmed cleanup, remain recorded below. Full qualification stays
open in [issue #15](https://github.com/ahmed-ela/computa/issues/15).

The earlier `v0.8.0-alpha.363` release followed PR #19's squash merge at
`0c182d7`; its tree matches build source `e2a0fe4`, and its signed inputs were
revalidated before publication. It was not notarized. That release and its older
passes remain distinct from the installed build380 results.

## Subsequent ownership failure and installed diagnostics

The fresh `fable51-marker370` task verified the selected model and first-user
submission, then failed `website_ownership_unverified` with
`ownership_reason=user_count` after 2.346 seconds. It executed no tools and
returned no final answer. Its own cleanup journal records `unconfirmed`;
restarting into build371 did not establish cleanup, and the prompt was not
replayed. The failed read did not retain its actual user-message count.
This case also does not establish current Fable entitlement: the earlier
ordinary picker marked Fable choices `Buy credits`.

Build373 added finite count and remount-completion diagnostics
first prepared in build372, plus the later Alibaba selector change. The count
projection preserves the exact count used by the existing failed guard. Remount
observations capture completion structure at entry and failed exit of the
existing wait. Neither projection changes verification, deadlines, parsing,
cleanup or action dispatch. Source checks and evidence limits are recorded in
`HARNESS-VALIDATION-NOTES.md`. These diagnostics do not establish a root cause
or repair. Fable testing requires its own current eligibility proof.

## Installed build373 reproduction, November 1

The approved restart installed source `0b465935ad69eab75be368ee13eebaf1b74088e8`,
process 39393. Its signed package, installed executable and resource inventory
were matched to the retained receipts. The installed model menu separately
confirmed that Alibaba exposes only the undated Qwen3.7 Flash choice.

Before the fresh `opus5-marker373-a` task, an ordinary Claude picker showed
Opus 5 enabled. Fable 5.1 instead had `Requires usage credits`, and the page
reported that usage credits were off. That current observation does not explain
the historical Fable ownership failure. The ordinary inspection tab was closed
before the harness task.

The fresh Opus 5 marker failed after 4.959 seconds, with one inference, zero
native tools and no accepted final answer. Its submission journal records exact
Opus 5 selection and a nonempty native first-user fingerprint before the
failure. The new diagnostic again reports `trigger_remount_timeout`: the
previously recognized same-context model button was disconnected and no current
model trigger was recognized. At both entry and exit of the 1,849 ms wait,
the completion projection had zero logical answers, `no_message`, no scoped
copies, and false busy/interrupted/complete flags. An outer assistant landmark
was nevertheless present. These samples do not establish absent provider
output, a rendering cause, entitlement failure or that extending the wait fixes
the problem.

The exact session has a saved `closed / not_created` cleanup receipt. As in the
earlier case, `not_created` does not mean that no prompt was sent. Eight finite
events were captured without omissions; no early count diagnostic was emitted.
The independent audit is retained under `evidence/opus5-marker373-a/`, with
SHA-256 `cfe820ec5e8837f42f06ef60ab39c02c72bbd13b268616eb00d56577d754aec2`.

A distinct direct message in a visible ordinary Incognito tab returned its
exact marker. The first sampled completed response was at 2.291 seconds, and
all seven samples from 0.664 through 12.282 seconds exposed `Model: Opus 5 High`.
Only this test-created tab was closed afterward. This is a direct-response
control, not a harness pass or a matched latency benchmark: payload, viewport
and foreground presentation differed. It does not isolate the cause of the
harness failure. Verification and timeout behavior remain unchanged.

Build374 adds a diagnostic capture at this existing failure boundary. Its
content-free DOM inventory distinguishes missing reply elements from hidden
ones and records bounded control counts and response subtree shapes. A
separate native record joins the exact session, tab and document generation to
view/host dimensions, clipping and window visibility before cleanup. Neither
record supplies model or response authority, extends a deadline, retains the
page or replays a prompt. The subsequent build374 capture is recorded below;
these diagnostics do not themselves repair the failure.

The candidate passed 969 cross-provider adapter tests (41,752 assertions),
11 focused native tests and nine versioning tests. The native cases verify
capture before cleanup, no duplicate emission, suppression for stale views and
successful remounts, and unchanged error/deadline behavior. The DOM cases cover
missing, hidden, inert and alternate reply structures, bounded text occupancy,
exceptions, changed ownership and output-size limits. Source hashes were
unchanged during both adapter and native runs. Their retained log SHA-256 values
are `ee08a87d9bc6c862db5ae8547e6c3aea029026b4a1ac49c9d8e838fa5f3de4df`
and `f299f34d047d4ce53d7a4b63abc4757da061e281ff3f00aed4200ed397eb6933`.

## Installed build374 empty-response capture, November 1

After the approved restart, process 19847 ran the exact signed build374
(`c58d43d29b384fb7b6e56b12bf77702d9e2ea34a`). Installed executable and resources
matched the package receipt. An ordinary picker independently showed Opus 5
selected, enabled and without a credit requirement; the empty inspection tab
was closed before the harness test. Fable choices still required usage credits.

One fresh `opus5-marker374-a` prompt was sent at 18:57:44 UTC. It failed after
5.856 seconds with one inference, zero tools and no final answer. The server
journal had already verified Opus 5, the document generation and first-user
fingerprint. The exact session subsequently closed with a saved cleanup receipt.
The failed prompt was not replayed.

The captured `trigger_remount_timeout` lasted 1,871 ms. Both completion samples
had zero logical answers. At the failed exit, the bounded structural capture
found no composer, Send/Stop button, model-prefix control or rendered reply.
One visible assistant root had two descendants and zero UTF-16 text units;
neither that traversal nor the root inventory was truncated. This supports an
empty sampled response shell, rather than a completed response hidden by the
expected reply selector. It does not establish the provider's internal state.

The native record matched the journal's session and document generation. The
view was attached, nonhidden and in a visible, nonoccluded window. Its frame
was 1024 by 768, while the visible rectangle and host were 1024 by 650. This
establishes vertical clipping geometry; it does not establish that clipping
caused the empty shell or disappearance of the controls. The document itself
reported visible and ready, with a 1024 by 768 viewport.

All 13 finite events and seven diagnostic chunks were retained without
omission. The independent audit passed 18 evidence checks and is retained in
`evidence/opus5-marker374-a/failure-audit374.json`, SHA-256
`7bbef73200820762ec6c8048ed0d5c38d8a1e64efdf3b48829048e2551706982`.
The next change targets premature rejection of this strictly empty, already
owned state. Any eventual answer still needs fresh model and ownership proof;
neither an old picker observation nor this diagnostic can authorize it.

## Candidate build375: bounded waiting without answer authority

The candidate changes one previously terminal condition into an empty running
observation: an already verified first Claude submission, unchanged ownership,
a detached remembered model control, no current conflicting model or popup,
and a fresh bounded read proving that no reply markup or assistant text exists.
Hidden reply markup, nonempty assistant content, an incomplete traversal or
ambiguous roots prevent that waiting state. Quota, sign-in, interruption and
ownership changes keep their failure paths. A semantic blocker or output seen
during a delivered observer callback permanently disqualifies the empty waiting
branch for that read, even if it disappears before timeout. This does not prevent
an ordinary positive read after the exact header returns. Diagnostics do not
participate in the decision.

Only ordinary native response polling can request this behavior. Its exact
negative page receipt is checked against the acknowledged Send, pre-insertion
prompt binding, native view, document generation, URL and first-user fingerprint.
The server independently requires its own previously verified submission pins,
the canonical submitted prompt hash, and no earlier observed output. The
pending snapshot contains no model evidence, response text, tool proposal,
completion proof or continuation capability. It cannot establish first ownership.

The original response deadline remains in force. A later ordinary read must
restore fresh model and ownership proof before response ingestion or completion.
Output that appears while the control is still missing does not qualify for
the empty waiting branch. There is no replay, extra Send, model-switch action
or cached-model fallback. Finite pending/restored transition records identify
the exact session, document generation and sequence without page content. They
help distinguish an exercised recovery path from an unrelated successful run;
they do not establish completion. Build374 remains installed; build375 still
requires a fresh live test before any repair claim.

Candidate validation passed 978 JavaScript tests (42,658 assertions): 573
ChatGPT, 223 Claude and 182 Gemini cases, with unchanged source hashes. The
server run passed 86 tests, including four new tests whose rejection matrix
covers 33 invalid negative receipts. After the final adapter change, all 35
Claude transport tests and five host-diagnostic tests passed. Those native
cases cover restoration, cancellation, stale callbacks, appearing output and
the original deadline. Nine versioning tests also passed.

The final JavaScript and native transport log SHA-256 values are
`d790b68efae6401d9eb9c3549a96cd21a0b0e9f505628947a69757956b8b1589`
and `c04ffefca8c90e5981f39f6da6614e695cc1131437e5c8d85fe31cc74a63e489`.
The server source and tests still match the earlier passing native receipt,
whose log SHA-256 is
`d3ccdd9111aa844fa3f318e4c4bc8e75a4b5070970ec80af0a3eafc6cff6327f`.
The initial cross-provider run exposed a throwing-getter regression; its failed
receipt is retained, and the final suite includes that corrected guard plus
transient-blocker tests. These are synthetic/native validation results, not a
live Opus 5 pass.

## Installed build374 Opus 4.6 workflow, November 1

The fresh `opus46-workflow374-b` task ran on source `c58d43d`, process 19847,
without a restart. The ordinary website picker showed Opus 4.6 available and
then selected as `Opus 4.6 Medium`; its empty inspection tab was closed before
the harness task. The harness independently verified the requested Opus 4.6
selection, document and first-user fingerprint for every accepted response.

The task completed in 124.798 seconds with nine website inferences and eleven
native tool calls. It changed only the permitted aggregation function, ran the
six protected tests successfully, printed the correct reference, and used
`browser_open`, `browser_fill`, `browser_click` and `browser_close` to complete
one loopback form submission. Its final answer reported the unpredictable
receipt observed in the browser. The model explicitly closed its exact test
tab; this was not a cleanup-only closure. All nine website sessions have saved
closed cleanup receipts and verified release records.

After the exact fixture server stopped, the independent audit reran the six
tests, checked protected files and the allowed diff, and verified exactly one
accepted POST and matching browser receipt. All 19 fixture checks, 27 transport
checks and seven checks for each of the nine inference chains passed. A second
read-only review independently joined the tool calls, outputs and command
scope. The model requested the test and reference commands in the same response:
both completed before browser submission, but waiting for the test result
before starting the reference command is not established.

No correction, malformed reply or tool error was recorded in this run. The
task-scoped rejection capture remained unused and was explicitly disarmed,
with its original arm retained in the case evidence. The independent transport
audit is `evidence/opus46-workflow374-b/capture/independent-audit-v6.json`, SHA-256
`53e54fd97d1d49ec5d7c61fc6a38c7325c9b81c376fb56cecb19cfbd01ffd2d5`.
The fixture audit SHA-256 is
`9e6a3c765229f37980bcb4f79fd5d6d44822a87cbf38c767934ee832d1b577bc`.

This is one bounded local workflow pass, not a measured reliability rate,
backend model attestation, a diagnosis of the build368 failure or a live test
of the Opus 5 remount change. Candidate build376 includes that still-unqualified
change plus the provider-first model submenu; build374 remains installed.

## Installed build374 Opus 4.8 workflow refusal, November 1

The distinct `opus48-workflow374-c` task used a fresh fixture and loopback port
on the same installed build374. Opus 4.8 was present in the ordinary picker.
The owned session verified its selection, first-user submission and completed
response, then saved a closed cleanup receipt and release record.

After 16.890 seconds, the model returned a prose refusal and made zero tool
calls. It described the long runtime-contract instructions as claiming tools
were attached to Claude's website and declined to emit action JSON for the
external runner. This is the model's stated interpretation, not proof that
Computa lacks those tools or that one particular instruction caused the refusal.
The parser preserved this response as ordinary final text; there was no parse,
ownership, cleanup or correction error.

The fixture remained unchanged, no browser submission or receipt occurred,
and the workflow failed qualification. The exact fixture server was stopped;
the unused task-scoped rejection arm was archived and disarmed. The retained
audit is `evidence/opus48-workflow374-c/capture/independent-audit-v6.json`,
SHA-256 `e40eb72c8d667f994e88dc53171a817a4307362cdad58201bbf688ed445eb60d`.
Its seven per-inference identity/cleanup checks passed, while
`workflowActuallyDispatchedTools` failed. The separate fixture audit SHA-256 is
`7755ee2f5c023e2b3809f154d5ce1b7cbf18d087519ee51e20d285321faed8f8`.
This gives a concrete instruction-design hypothesis for a later controlled
comparison, not a successful workflow or permission to reinterpret the refusal
as an executable tool call.

## Installed build374 Opus 4.7 workflow refusal, November 1

The fresh `opus47-workflow374-d` task used a separate fixture and loopback port
on build374, source `c58d43d29b384fb7b6e56b12bf77702d9e2ea34a`, process 19847.
The ordinary picker exposed an enabled Opus 4.7 under More models; selection
showed `Opus 4.7 Extra`, and the empty inspection tab was closed before the
native task. That observation is separate from the harness's exact Opus 4.7
selection proof and does not attest to the backend model or inference effort.

The exact 729-byte prompt was sent once. After 13.886 seconds and one inference,
the model returned a valid prose refusal with zero native tool calls. It
declined the Computa/JSON-envelope framing and stated that the local tools were
unavailable in that website conversation. The parser preserved the refusal as
ordinary final text; no native error, website error, correction or rejected-reply
capture occurred. This is the model's stated interpretation, not proof that
Computa lacks those tools or that any one instruction caused the refusal.

All five lifecycle phases and seven per-inference identity/cleanup checks
passed, including the saved closed cleanup receipt and verified release. The
task browser was never opened. All four fixture files remained unchanged, the
receipt ledger stayed empty, and no POST or browser receipt occurred. The fixture
grader retained `FAIL_LOCAL_FIXTURE` (7/19 checks); its independent test run did
not constitute model-dispatched work. The workflow audit retained
`failed_or_unverified`, `transportVerified=false` and
`qualifiedLocalFixture=false`: 26/27 checks passed, with
`workflowActuallyDispatchedTools` failing. The exact fixture server was stopped,
and the unused task-scoped rejection arm was archived and disarmed.

The case joins task `f9885273-a5f8-4a6a-af57-a66e7d4426b1`, thread
`01a198ef-3eb7-7ef3-b667-8ce3a9944ee2`, turn
`01a198ef-3fc0-70a0-974d-77abba1b4a54` and inference
`6e3e2830-54d6-42d2-832d-2d022d6fd6db`. Under
`evidence/opus47-workflow374-d/`, the retained SHA-256 values are:

- `capture/native-turn-private.jsonl`:
  `0eea6a6ba354bb7f180dcc2c8499f2c97456f6e1b3f3b4e5b2b0e1fabbdf7839`.
- `capture/independent-audit-v6.json`:
  `54f4e2a81fe4e62fc6da07820824960d80c1589fdab576f2246c7167d7992008`.
- `independent-refusal-review.json`:
  `509d60790fc802780902c46d9a4089b9d5cf9804d4d9cf8519c3d9b54e692700`.

The fixture audit SHA-256 is
`02818852ca5f68c8bb899dbe468e1e7be795c888ab5aaaa274bfad458911cbed`.
A separate read-only review passed 30 checks and verified 50 retained-file
hashes, preserving both negative qualification verdicts. No prompt was replayed
and no alternative framing was tested in this case. The refusal supplies a
bounded instruction-design hypothesis, not a unique root cause or workflow pass.

## Installed build374 Opus 3 workflow format failure, November 1

The fresh `opus3-workflow374-e` task used its own fixture and loopback port on
build374, source `c58d43d29b384fb7b6e56b12bf77702d9e2ea34a`, process 19847.
The ordinary picker showed Opus 3 enabled under More models; its empty inspection
tab was closed before the verified native Opus 3 draft was sent once. The exact
728-byte task reached terminal in 19.251 seconds with two failed inferences,
zero tool calls and no final answer.

The armed recorder retained the first 416-byte reply with exact task, session
and submission proofs. Substantive prose before and after a syntactically valid
156-byte `tool_calls` JSON object, plus a private-use glyph and `json` UI label,
made the full response invalid JSON at offset zero. The object proposed opening
the exact fixture URL. Its syntactic validity does not establish a valid tool
call or authorize extracting and executing it. The adapter recorded one code
block, `literalCodeValidJSON=true`, `extractionReason=outside_content` and
`selectedExtraction=rendered_fallback`; the prose prevents an isolated-code
projection. No proposed action was dispatched.

One format correction followed the first session's saved closure. Its response
also failed: `invalid_json`, unfenced, 240 bytes. The one-shot recorder had
already captured the first reply, so the second raw text is unavailable and
its structure cannot be inferred from the first. The native UI displayed the
240-byte malformed-reply diagnostic. A separate generic high-demand runtime
error event does not establish provider load as the cause. Both sessions have
saved closed cleanup receipts; the second closure followed native terminal by
87 ms. No accepted response was released and no operator replay occurred.

The fixture remained unchanged with an empty ledger, no browser submission and
no receipt. The fixture grader retained `FAIL_LOCAL_FIXTURE` (7/19 checks); the
workflow audit retained `failed_or_unverified` (20/27), `transportVerified=false`,
`qualifiedLocalFixture=false` and `correction.pairVerified=false`. The exact
fixture process exited 143 after guarded shutdown. The consumed diagnostic arm
was absent, and the exact original rejected reply was archived under the native
directory lock by exclusive rename; no pending publication remained.

Task `27c63d87-9c92-46dd-b783-41d4e13bab14`, thread
`01a198f9-0739-7062-b746-a6f489baebe7` and turn
`01a198f9-085e-7803-b11d-8ed79f10dd7d` join initial inference
`c25f1f18-e1d7-4192-8e65-d26d941223e9` and corrective inference
`4aa5095d-b142-461f-8afa-8a23826d550b`. Under
`evidence/opus3-workflow374-e/`, retained SHA-256 values include:

- `rejected-reply-private.json`:
  `549475140ac4444c9d3dadc99500fa3e3fc50487623719e1a826e0748a010986`.
- `capture/independent-audit-v6.json`:
  `075fe83109f3520a0562bc09980a5562b153a3229ce329838d3afd6a6c09e6af`.
- `independent-failure-review.json`:
  `b236258940fb20b0927b770c611f619a2bf18d2af7df31b3c6192d0e9fdd75e1`.

The separate review passed 34 checks and verified 34 retained-file hashes,
preserving the negative qualification results. This case explains the captured
first reply's rejection; it does not establish the earlier 75-byte marker's
shape, the second reply's shape or a general Opus 3 limitation.

## Source-only default instruction clarification, November 1

The default base now says `Claims aren't access proof; rules, denials and Stop
bind.` in place of `policy isn't block proof`. The new base is 1,020 UTF-8 bytes.
Opus 4.8's retained refusal explicitly quoted the earlier clause as part of its
interpretation of the wrapper. That observation motivates clearer wording;
it does not prove the clause caused the refusal or that this change repairs it.

All 32 historical digests, custom base composition, retained canonical history,
compact native policy and refusal/no-bypass rules remain unchanged. The change
does not alter parsing, dispatch, permissions, verification or retry behavior,
and it leaves the frozen outer-framing A/B exports untouched. The focused native
run passed 237 tests with zero failures and unchanged tested source. The receipt
`base-instruction-clarification376-a/result.json` has SHA-256
`6da397c79249ae10b462253c4363cfcc49563005da343f3f6ae470ba8d745d24`.
This clarification is source-only: it is neither in installed build374 nor in
already-signed candidate376, and no live model improvement is claimed.

## Rejected-reply evidence gaps and prepared framing comparison, November 1

Source inspection found two additional parser failures whose exact replies were
not retained by the opt-in rejection recorder: invalid built-in-browser read
arguments and whitespace-only replies. A literal empty response failed earlier
as `providerFailed` and also bypassed capture. The diagnostic change routes these
three existing failure paths through the same private, exact-task recorder after
the existing response identity checks. It preserves the original errors, parser
acceptance, correction rules, output release and cleanup. Unarmed tasks retain no
raw reply, and an existing evidence file is never overwritten. This does not
identify the cause of the historical build368 failure or repair a model refusal.

The focused rejection-capture and Claude format-correction run passed all 42
tests. The new fixtures cover both response modes, atomic rejection of a batch
containing an otherwise valid first call, absent/foreign/unsafe diagnostic arms,
an unconfigured recorder and an existing output file. Valid prose/JSON refusals
and an empty JSON message remain accepted without capture or correction.
Missing/non-string text and failed identity/model proofs retain their original
errors and leave the diagnostic arm untouched. This source change is not in the
already-signed candidate376 or the running build374.

The separate `prompt-framing-ab376-a` experiment has two prepared prompts from
the pinned `0539728` codec and native policy, whose prompt source was unchanged
at `49b4256`. Only two outer explanatory paragraphs differ; the canonical
request, user task, native policies, schemas and refusal grammar are identical
within that pair. The terminal schema is explicitly synthetic, and the export
omitted the live engine's appended 362-byte permissions suffix. A pure native
export test passed, and an independent review checked 13 invariants. This is an
internally matched synthetic first-proposal comparison, not the exact historical
payload or a full workflow test. The later base clarification requires a fresh
export before either prompt can represent the current source; the old artifacts
remain unchanged and unsent.

Neither prompt has been sent. In the ordinary build374 Incognito tab, the
desktop AX setter reported success for the 43,725-byte original but readback
and a screenshot showed only 3,196 bytes. A bounded shorter insertion verified
2,000 characters plus the editor's trailing newline; selected-text insertion
did not append, and a 4,000-character replacement again stopped at 3,196 bytes.
The incomplete draft was cleared and its empty readback verified. The cause of
this manual diagnostic-input limitation remains unknown; it is not evidence
that Computa's separate production prompt-insertion path truncates requests.
The empty test tab was closed. The full comparison requires verified complete
insertion before either Send.

## Installed build368 results, November 1

These fresh cases ran on source `2dea3d291cc414f76c1f0687b2e141cdafa5b4f1`,
process 27615. Each result retains its own model, submission and cleanup records.
The later installation and launch of build370, source `d87792b`, do not change
these results or resolve historical failures.

| Case | Duration | Inferences / tool calls | Result |
| --- | ---: | ---: | --- |
| `sonnet55-workflow368-c` | 53.033 s | 9 / 8 | Full local fixture passed: permitted function edit, six protected tests, reference, exactly one accepted browser POST, fresh receipt observed/reported, and exact task-created tab closure. |
| `opus5-marker368-c` | 4.934 s | 1 / 0 | Exact model and first-user submission verified, then `trigger_remount_timeout`. No accepted answer; saved session cleanup closed. |
| `opus46-marker368-c` | 8.767 s | 1 / 0 | Exact marker passed with selection, first-user/document, completed response and saved closure/release evidence. |
| `opus46-workflow368-c` | 56.185 s | 4 / 3 | Two reads and a function-only patch succeeded. The fourth inference failed with `invalid_model_output`; no model-dispatched tests/reference, browser action, POST, receipt or final answer. All four sessions have saved closed cleanup. |
| `opus47-marker368-c` | 25.702 s | 1 / 0 | Verified response contained the nonce plus prose rejecting relay framing. Exact-marker check failed; session cleanup closed. |
| `opus3-marker368-c` | 9.626 s | 1 / 0 | `malformed_website_reply`, `invalid_json`, `json_fenced=false`, 75 reply bytes. No accepted answer or correction; saved session cleanup closed. |

Sonnet 5.5's independent audit joined all nine distinct website inferences to
the eight native calls and their outputs. All 27 scenario checks and 19 fixture
checks passed, without a tool error or correction. Protected files were unchanged;
the loopback ledger contains exactly one accepted submission and a fresh receipt
matching browser output and the final answer. A separate native browser-cleanup
receipt identifies the exact task-created tab as closed. The fixture server was
stopped. This is one bounded local workflow pass.

Opus 4.6's independent auditor subsequently ran six passing tests and the correct
reference on its patched function. These verify the edit, but are not
model-dispatched tests or workflow completion. Protected files were unchanged.
No task browser tab was opened or form submitted. The saved failure code does not
establish the rejected reply's exact shape or cause. The marker pass remains
separate from the failed workflow.

Opus 5's finite log reports a disconnected, previously recognized model button
and zero current recognized trigger candidates at `trigger_remount_timeout`.
The submission record already contains exact Opus 5 selection and the bound
first-user fingerprint. Its failed inference joins its own saved closure 95 ms
later; `not_created` is the temporary-conversation cleanup reason, not evidence
that no prompt was sent. The finite log has no task/session IDs, so its exact
process/time correlation is not exclusive session identity. It does not prove
continuous header absence, why the site detached the control, or a quota,
background-rendering or caller-ordering cause. No repair is established by this
case and no uncertain prompt was replayed.

In the earlier Opus 4.7 marker case, the only failed scenario check was
`markerExact`. The installed instructions
explicitly preserve the website model's identity and governing rules, distinguish
host proposals from execution, and apply user exact-output requirements to
decoded `message.text`. No contradictory identity-reassignment instruction was
found. The precise whole outgoing request was not retained; the response does
not establish unavailable host tools. It must not be trimmed into a marker pass.
Opus 3's exact case retains the finite malformed-response diagnostic but no raw
75-byte reply or correction record. Its exact syntax error and the reason no
correction was admitted remain unproved. Generic native high-demand text is not
evidence of the provider-side cause.

Catalog freshness is not established for this batch. The operator observed 12
cached app choices while a separate ordinary Claude picker showed ten eligible
choices and both Fable rows marked `Buy credits`. This does not negate build365's
recorded successful refresh, but it prevents claiming a persistent catalog fix.
Current picker eligibility does not qualify inference or tools. Earlier model
failures and the historical unconfirmed quota-cleanup case remain open.

Private records are retained under the named cases in
`work/claude-qualification-20261031/evidence/`. The Sonnet workflow review has
SHA-256 `eb95eb74d78423867fc02473a1036ff353e99cbe630fe6dad02495febaf7d1eb`;
Opus 4.6's `partial-negative-audit.json` has
`bfb231e7a95f6e4d578f4ad6782d916d1e25facb64e8924e0c29162ec06d893f`.
Original failed verdicts and raw private evidence remain separate from this
summary. Build370's install and launch receipts are retained under
`work/sidebar-activity-20261101/`; they are artifact/process evidence only.

## Build363 failures and build364 changes

Opus 5.5's marker passed in 6.048 seconds and its safe full workflow passed in
73.365 seconds. Independent checks joined nine verified, closed website
inferences and ten tool calls to the function-only edit, six protected tests,
one accepted loopback submission, the unpredictable receipt in browser output
and the final answer, and a model-issued close. This is one bounded pass.

Sonnet 4.6's `sonnet46-workflow363-x` case passed its code tests but failed after
six tool calls and eight inferences. Its first single-block response with outside
narration used the existing one-correction allowance; a later malformed response
ended the task before form submission or a final answer. All eight website
sessions have saved closed cleanup receipts. A fresh `sonnet46-workflow363-y`
diagnostic case instead failed its first inference in 9.593 seconds, before the
post-browser-open recorder could arm. No tools executed. Its finite structure
reported one invalid JSON code block, but did not retain the raw reply.

The distinct `sonnet46-workflow363-z` case captured that first-response timing
with an exact-task recorder. It failed in 9.899 seconds with zero tools executed.
The 1,130-byte code body contains three proposed `exec_command` calls and extra
closing braces after the first two objects. The 1,139-byte rendered response
includes only the observed code-block chrome around it. The whole reply remains
invalid JSON; neither code extraction nor a tool dispatch occurred. Exact model,
submission, session identity and saved closed cleanup records agree. The raw
capture's SHA-256 is
`49ac6ff37f70c36febaa306e007fab62d0c4df5bbfd258a4626f4e5f0be6c183`.
Both failed fixture servers and their one-shot diagnostic slots were retired.

Candidate364 admits this narrowly isolated malformed JSON-block case to the
existing one-attempt format correction. Structural evidence must identify one
bounded JSON code block with only recognized provider chrome and no outside
prose. It does not repair the JSON, execute a recovered prefix, or increase the
correction allowance. The fresh same-model response must independently pass
strict parsing, submission/ownership verification and saved cleanup within the
original turn budget. Missing or contradictory evidence remains terminal.

The candidate also replaces provisional catalog accumulation with the final
complete owned-picker snapshot and rechecks eligibility while closing menus.
Removed, disabled or newly purchase-gated rows cannot survive from an earlier
read. Exact menu/control identity and context guards still apply. This addresses
a reproduced catalog defect; live Fable 5.1 retirement still needs verification.

Opus 5's owned-session failure occurred about one second after its verified
submission: no recognized model trigger or candidate remained in the read.
A separate normal-browser Incognito marker on build363 completed with the exact
`Model: Opus 5 High` control visible before and after. That direct control does
not qualify the harness or establish the cause of the earlier loss. Candidate364
adds finite diagnostics for the last positively verified trigger: attachment,
visibility, label category, scan membership and context. The cached node never
supplies model, response, action or cleanup authority. No wait or retry is added.

Candidate364 passed all 951 adapter and version tests (40,479 assertions) and
208 selected native tests, with unchanged source throughout both runs. The
native checks include real WebKit extraction of isolated malformed JSON and
rejection of surrounding prose or a different language label, strict Boolean
projection, preserved canonical tool history, fresh corrected-call release,
valid refusals, cleanup and the one-correction limit. Diagnostic exceptions and
empty extra controls have dedicated regressions. Log hashes are
`46f14212003a3cde482bff6a477a65beeb46a6e4cf43eec710b706220b9f3730`
for adapter/version tests and
`3eeeaf79338474d9e012f99a2b8fad932a01f91f9d294b1ca692fb16fe720616`
for native tests. Build364 was subsequently installed from `06b9463`; its
separate live results follow.

The published build363 package does not contain these candidate changes. Private evidence is
retained under `work/claude-qualification-20261031/evidence/` in the named cases
and `opus5-layout363-a/`; raw provider text is not included in this repository.

## Installed build364 results, November 1

These are separate, fresh tasks on installed source `06b9463`. Durations are
native task durations. A successful transport or cleanup record does not make
a failed marker or workflow pass.

| Case | Duration | Inferences / tool calls | Result |
| --- | ---: | ---: | --- |
| `sonnet55-marker364-b` | 4.538 s | 1 / 0 | Exact marker passed; selection, submission, response and saved closed cleanup verified. |
| `sonnet55-workflow364-b` | 52.510 s | 9 / 8 | Full local fixture passed: permitted function edit, six protected tests, exact reference, one accepted POST, receipt observed and reported, and model-issued tab close. |
| `sonnet46-workflow364-a` | 18.225 s | 2 / 0 | One isolated malformed JSON response used the single correction allowance. The fresh response was a valid refusal; no proposed call executed and the workflow failed. Both sessions have saved closed cleanup. |
| `opus5-marker364-a` | 3.822 s | 1 / 0 | After verified submission, current model proof failed because the previously verified header was detached. No answer was released; owned-session cleanup was verified closed. |
| `opus48-marker364-b` | 11.232 s | 1 / 0 | Selection, submission, response and cleanup verified, but the answer added prose to the requested marker. Exact-marker qualification failed. |

Sonnet 5.5's independent workflow audit joined all nine distinct website
inferences and their saved cleanup receipts to the eight native calls. It
verified that only the permitted function changed, all six protected tests
passed, the loopback ledger contained exactly one accepted submission, the
unpredictable receipt appeared in browser output and the final answer, and only
the task's browser tab was closed. No correction or native tool error occurred.
The fixture server was stopped before its independent audit. This is one bounded
workflow pass, not an all-model or arbitrary-website reliability claim.

Sonnet 4.6's captured first reply proposed two read-only `exec_command` calls
but contained an extra brace. The original whole reply stayed rejected. Its
fresh same-model correction returned a valid message refusing the external-tool
handoff; neither original call was dispatched. Retained correction records join
the rejected first inference, its saved closure and the distinct second
inference. They do not independently establish exact paired canonical-request
bytes or cumulative budget usage. The refusal's cause remains unproved; current
source explicitly distinguishes Claude's JSON proposals from host execution.

Opus 5's finite diagnostic reports zero current trigger candidates and a
same-context previous button with `connected=false`, `physical=false`,
`visible=false`, a still-recognized label category and an unsaturated scan.
This identifies detachment rather than a label change. It does not establish
why the site detached the header or whether it would have returned. Opus 4.8's
normal response shows the loss is not universal; its additional prose remains
a separate model-behavior failure.

Startup catalog discovery also remains unverified. Settings reported that
Claude's selected model could not be verified, and the existing cached choices,
including Fable 5.1 and Fable 5, remained visible. Keeping that cache is failure
behavior, not successful catalog refresh or evidence that purchase-gated choices
are currently usable. No manual refresh was used to relabel this result.

Evidence is retained privately under `work/claude-qualification-20261031/`:
the named `evidence/` cases contain summaries, native/website/cleanup journals
and independent v5 audits; the workflow oracle is
`fixtures/cases/sonnet55-364-b/audit/result.json` (SHA-256
`34befb0469027dade5fb2105903c3f5e5136d0410659bed5c5301528590a33c3`).
The detached-header facts are in
`evidence/opus5-marker364-a/finite-native-diagnosis/decoded-diagnostics.json`,
and startup failure is recorded in `catalog364-initial-settings.txt`.
Used and unused diagnostic arms were retained and retired without replay.

## Candidate365: bounded read-only header-remount observation

Candidate365 proposes bounded observation of the detached-header state. Only a
post-submission `inspect` or `verifyModel` read with verified first-user state
and a disconnected, previously verified node in the same owner/document/URL
may wait for DOM changes, within the existing 1.8-second read deadline. The
remembered node permits this bounded observation only; it supplies no model,
response, action or cleanup proof.

A newly observed header must independently prove the exact requested selection:
one enabled, closed control, an unsaturated candidate scan, and no foreign or
open popup. The ordinary fresh verification path checks it again, including
after its asynchronous close check and before returning. Observed owner,
route, first-user, mode, ambiguous-control or model changes remain terminal,
even if restored before the wait resumes. Missing headers and expired deadlines
still fail. This path opens no picker, dismisses no popup, selects no model,
replays no Send and adds no correction allowance.

Build365 passed all 960 combined adapter/version tests (41,163 assertions) and
27 focused native Claude transport tests with unchanged source. The native
cases use real WebKit observers and the existing native deadline, verifying
fresh completion proof, model/body/owner rejection, timeout, one Send and no
picker actions. The first native run exposed two incorrect test expectations:
the existing post-action first-user guard takes precedence over the model error
for body/owner changes. The final tests require that exact ownership rejection;
no production guard was changed to satisfy them. Passing log hashes are
`2fb6034cf4d67e027d450f12bd79edc0d9922b02d27c16df5addd467472daa9c`
and `bc586ca832e06d49e0c23a0429d12a4eac8c71b665efe762eb76c5da30d54221`.
Build365 was installed from `ed8e86e`; its separate live results follow.
Refusal behavior and the historical unconfirmed quota-cleanup record remain
open issues. The bounded observation path does not establish their resolution.

## Installed build365 results, November 1

Automatic startup discovery persisted a fresh Claude catalog containing ten
eligible choices. The complete finite picker diagnostic agrees with the saved
catalog: both purchase-gated Fable entries were removed, while six Opus and four
Sonnet/Haiku choices remained. Other providers' cached choices did not change.
The native discovery path returns choices only after disposing its prompt-free
owned page, but discovery has no separate durable per-session closure receipt.
This establishes this launch's catalog refresh, not successful use of every
listed model or the cause of build364's startup failure.

| Case | Duration | Inferences / tool calls | Result |
| --- | ---: | ---: | --- |
| `opus5-marker365-a` | 4.960 s | 1 / 0 | Submission verified, then current model proof failed at `trigger_remount_timeout`. No answer was released; exact saved owned-session cleanup was closed. |
| `sonnet55-marker365-a` | 4.632 s | 1 / 0 | Exact marker passed with selected-model, fresh submission, response and saved closed-cleanup evidence. |
| `sonnet55-workflow365-a` | Not submitted | 0 / 0 | The selected chat changed before Send; the pre-send guard stopped the test. No fresh exact-prompt turn or diagnostic arm was created, and the fixture ledger remained empty. No model-failure or workflow-pass verdict applies. |

Opus 5's finite timeout diagnostic again found zero current recognized model
controls and a disconnected previous control. This confirms that the bounded
remount observation did not recover valid model proof for this case; it does not
prove continuous absence throughout the wait, distinguish an unrecognized new
control, or show that a header would never return. The last published inspection
had no complete answer. No uncertain prompt was replayed.

The interrupted Sonnet workflow's watcher and fixture server were stopped,
its original files were retained, and both diagnostic paths were clear. A later
workflow needs a fresh controlled baseline and binding. The successful marker
alone does not qualify browser, terminal or file tools on this installed build.

The retained records are `evidence/catalog365-startup-finite/`,
`evidence/opus5-marker365-a/`, `evidence/sonnet55-marker365-a/` and
`evidence/sonnet55-workflow365-a/interrupted-unsent-review.json`. A separate
ordinary-browser Groq inspection on build365 reproduced a full-length user body
with a sibling `Show more` span and returned its exact synthetic marker. That
inspection was cleared and its test tab closed, with developer settings restored;
it is not Groq harness qualification and does not resolve the original failed
Groq task or its cleanup warning.

An offline production-host rendering diagnostic was prepared to compare a
synthetic animation-frame header remount under an opaque sibling and without
that cover. The available display could not fit its required 1024 by 768
viewport, so the initial run stopped before creating the experiment. No frame
measurements were made and no conclusion about Claude or background rendering
is supported. The diagnostic now requires `COMPUTA_MODEL_RAF_DIAGNOSTIC=1`
and skips unsuitable displays; it changes no production configuration,
verification deadline or provider behavior.

## Build362: duplicate code blocks stop the Sonnet 4.6 workflow

The fresh `sonnet46-workflow362-v` case ran for 60.587 seconds. It edited only
`reconcile.py`, passed all six protected tests, printed the correct reference,
and submitted the loopback form exactly once. The browser click output and
independent fixture ledger agree on the accepted receipt and unpredictable nonce.
The eighth website response then contained two byte-identical `browser_close`
JSON blocks separated by narration. Strict whole-reply parsing rejected it as
`invalid_json`; neither rejected close call was dispatched. The task had no
final answer or model-issued tab close, so the complete workflow failed.

The captured reply's finite structure reports `preCount=2`, `codeCount=2`,
`extractionReason=multiple_pre`, and rendered fallback extraction. The existing
Claude format-correction guard requires a single valid tool block with
`outside_content`, so it did not admit this case. This identifies an eligibility
gap in the correction path, not duplicate execution or lost completed history.
All eight owned website sessions have saved closed cleanup receipts. App cleanup
closed the task-created fixture tab; that does not substitute for the requested
model action. The fixture server was stopped before its independent audit.

The rejected reply, exact task/turn/inference joins, native transcript, website
transactions, cleanup records and terminal UI are retained privately under
`work/claude-qualification-20261031/evidence/sonnet46-workflow362-v/`. The consumed
diagnostic output was retired with its identity and hash preserved. The failed
task was not replayed. Candidate363 will test a narrow extension of the existing
one-time correction; the original reply must remain rejected and no tool call
may be recovered directly from either code block.

Candidate363 records a finite Boolean only when an owned answer has exactly two
disjoint PRE elements, one CODE in each and no other CODE, with bounded,
byte-identical bodies that parse as `tool_calls` objects. It retains the whole
rendered response and `multiple_pre` rejection. This fact only admits the existing
single correction attempt after exact submission and saved cleanup verification.
The unchanged canonical request is sent in a fresh same-model session, under the
original turn deadline and budgets; rejected narration and calls are not added to
history. The corrected response must pass the ordinary strict parser, and a valid
refusal remains a refusal. Missing, conflicting or malformed evidence stays terminal.

The same candidate makes the purchase-row filter independent of the HTML tag
used for an exact visible `Buy credits` label. Bounded text collection excludes
hidden, inert and foreign-row descendants. Synthetic regressions check this
generic discovery gap; the exact markup of the live Fable rows has not yet been
captured, and installed catalog verification is still required.

Candidate363 validation passed all 893 ChatGPT/Claude/Gemini adapter tests,
including the shared purchase-filter regressions. The 263 selected native tests
have passing results across two retained runs. The first run passed 262 and
exposed an incorrect new test assumption: `fixtureInfer` throws a terminal
rejection before its caller performs cleanup. The test now invokes that normal
finish path and requires a saved closed receipt for the exact second session,
with only two sends. All 16 Claude correction tests passed on rerun; production
code was unchanged. Real WebKit tests confirmed that duplicate, conflicting and
message blocks retain their full text and remain rejected by the strict codec.
All nine version tests also passed. These checks do not establish a live
candidate363 workflow pass; installation and fresh model qualification follow.

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

### Installed build360 results, November 1

Each row is a separate native task with its own fixture/server and retained
evidence. All use the concrete Haiku 5.5 website choice. A browser-only control
does not replace the complete code/terminal/browser workflow.

| Case | Duration | Result |
| --- | ---: | --- |
| `haiku55-browser360-r` | 32.732 s | Open, tabs, read and fill succeeded. The fifth reply failed strict validation with `invalid_envelope_fields`; no submission or receipt. Five verified website cleanup receipts. |
| `haiku55-browser360-s` | 53.388 s | Browser fixture passed: seven calls, eight verified website inferences, one accepted form POST, unpredictable receipt read and reported exactly, and a model-issued close of only its task tab. |
| `haiku55-workflow360-t` | 53.277 s | Only the permitted function changed; six protected tests and the reference command passed. Browser open and fill succeeded, then an accepted final response claimed the tools were unavailable. No POST, receipt or model-issued close. Computa closed the task tab. Eight website inferences and cleanup receipts verified. Full workflow failed. |

The first control captured the exact post-tabs prompt, original canonical
request and all 22 offered/bound tools. Native call/output IDs and bytes matched,
and later submission/ownership records matched the captured prompt hash. This
rules out a missing catalog for that particular inference. It does not establish
the contents of the later failed request. The raw malformed reply was not
captured, so its unexpected top-level key remains unknown.

The next two cases armed private rejected-reply capture before the first
inference. Neither produced a rejected response: the browser control passed,
and the full workflow ended in a valid message envelope containing a refusal.
Both unused arms were preserved and removed after terminal verification. Their
fixture servers were stopped; all failed evidence remains retained.

The full workflow never called `browser_tabs`; `browser_open` and `browser_fill`
already returned current observations. Its refusal accurately recalls the edit,
tests, reference and filled field. The fill output contains current controls and
does not report a capability denial. No concrete instruction contradiction was
found. The exact final projected request still needs capture; fresh sessions or
different task histories remain hypotheses, not established causes. No response
was repaired, replayed or accepted with weaker validation.

## Candidate 361: catalog freshness and the post-fill diagnostic

The confirmed catalog defect is independent of the refusal: startup discovery
skips any provider with cached choices, and the refresh controls are hidden.
Consequently an existing Claude catalog cannot discover newly enabled Opus
choices or retire absent Haiku 4.5 merely by restarting.

The candidate preserves missing-provider discovery and requests one automatic
revalidation per launch for a selected provider. Other cached providers wait for
selection. Discovery waits for an idle app, retains the old catalog on failure,
and uses the existing blocked-provider gates without retry authority. A missing
saved selection remains disabled rather than silently switching the task's model.
Claude rows with a visible purchase control are excluded from selectable choices.

The manual request diagnostic also accepts `after_browser_fill`, with its own
`claude_post_browser_fill_request_v1` purpose. It requires the same exact native
task, turn, concrete model, bounded expiry and immediate unique call/output pair.
The original post-tabs arm remains compatible. This closes the diagnostic gap
for workflows that skip tab inventory; it does not change prompts, execution,
parsing, cleanup or refusal handling.

The combined native regression run passed 63 tests, including 29 catalog-state
cases, blocked-provider/no-page guards, the legacy post-tabs handoff and private
capture protections. The initial compile caught a test-only closure returning
the tuple from `Set.insert` instead of `Void`; the corrected run passed with
unchanged sources. All 880 adapter regressions across ChatGPT, Claude and Gemini
passed (39,585 assertions), as did nine version tests.

Signed candidate361, source `cf23323`, completed the fresh
`haiku55-workflow361-u` invoice workflow in 80.561 seconds. It changed only the
permitted function, passed six protected tests, printed the correct reference,
submitted the browser form exactly once, read its unpredictable receipt from
the click's current page observation, and closed its task-created tab. The
independent fixture audit passed. Twelve tool calls and twelve website
inferences had matching model, ownership and closed-session evidence. Three
pre-edit test invocations failed on the original fixture bug; the later test
invocation and independent audit passed. These were redundant model-selected
test runs, not transport retries.

The after-fill capture matched the immediate native call/output pair and the
same inference's submitted prompt fingerprint. An independent 26-check audit
confirmed the actual displayed request retained all 20 prior native call/output
items, all 22 offered tool names/kinds, bound browser capabilities and the
current execution handoff. The 152,768-byte prompt's SHA-256 was
`2d82dbf29a33a7233b5839e83164f034a92eeafa8ff5f526875641d5d8ca8a1d`.
No rejected reply was captured. The private capture and unused rejection arm
were retained and retired; the fixture server was stopped. An initial audit
run before server termination was preserved separately and failed only its
server-lifecycle check; the final audit verified both process and listener absent.

This is a successful control, not a demonstrated fix or explanation for the
earlier Haiku refusal. The prompt and response policy were unchanged.

The same installed check found two catalog issues. Restoring disk history after
the WebUI ready event can select Claude without issuing refresh demand. The
follow-up source fix reuses the existing once-per-launch queue after task
replacement; 31 focused state tests passed, including two new restoration and
idle/failure cases. Separately, explicit Haiku selection did open and close a
discovery session, but Settings reported model verification failures for both
ChatGPT and Claude, and retained the old catalog. This installed run does not
establish live catalog freshness.

## Candidate 362: discovery startup and nested-menu closure

The retained discovery diagnostics separate two failures. ChatGPT exposed one
visible, closed, disabled model trigger during fresh-page startup. Claude had
an enabled trigger and an unambiguous checked model, but its parent menu remained
open after the nested More models menu closed. A realistic fixture reproduced
the latter failure: the child consumes Escape and closes only itself, while the
old fixture incorrectly closed both menus from either event.

Claude discovery now dismisses each exact observed popup once, child before
parent, within the same 1.8-second deadline. It rechecks the current owner,
document, selected model, fresh conversation and physical menu association
before and after each dismissal. Observed invalidation remains latched even if
the page later reverts; late closure cannot revive an expired attempt. No model
row is selected, no prompt is sent, and the catalog is accepted only after both
menus are physically closed. A real WebKit integration fixture verifies this
sequence and preservation of an existing human tab.

ChatGPT discovery returns pending while its one fresh, closed model trigger is
disabled. Native DOM wakeups and the existing preparation deadline bound that
wait. It does not claim a selection attempt, click a disabled control, provide
model evidence, or relax ordinary selection/read-only verification. Once the
trigger enables, the existing selection proof still applies.

Validation: 31 state-restoration tests, two WebKit discovery tests, seven focused
adapter cases (208 assertions), and nine version tests passed. The three-adapter
run completed with 885 passes and one older ChatGPT assertion that expected an
immediate error for this newly permitted discovery wait. Only that assertion's
discovery branch was updated; its unknown, generic, read-only and retained-model
negative cases remain unchanged. With production code unchanged, the final
ChatGPT run passed all 573 tests (30,346 assertions); the preceding completed
run passed all 131 Claude and 182 Gemini tests. The earlier interrupted run and
failing reproductions are retained separately and are not passing evidence.
Independent review passed after adding the late-closure and restored-context
regressions. Candidate362 is not yet installed or released; live discovery and
the broader Claude qualification remain pending.

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

## Installed build377 live checks, November 1

The approved restart installed source
`481f6e1a84ad7626cb55c0ad16657d0aeac377e5`, process 90212. Retained build, signing
and installation receipts match the installed executable and resources. This
build includes the bounded no-output pending path, rejected-reply diagnostics,
provider-first selector and the default-instruction clarification. Including
these changes in one build does not isolate any one change's effect.

The operator separately verified installed provider-menu keyboard selection and
visually checked the provider icons and names, a Claude-only submenu containing
ten cached model choices, the selected Opus 4.8 checkmark and placement within
the window. Escape closed the menu without changing that selection. This is UI
behavior evidence, not current website eligibility, backend model attestation or
inference qualification. The screenshot is retained as
`work/provider-menu-20261101/installed377-provider-menu.png`, SHA-256
`3120fb4fa4156208b339c1a28bf07b2f7cf7bb2683e078d72d0a1614218ad487`.

### Opus 5: pending observation followed by the original deadline

Fresh case `opus5-marker377-a` failed with `provider_timeout` after 301.185
seconds, one inference, zero native tools and no accepted final response.
Before the failure, the native journal recorded exact Opus 5 website selection,
a verified first-user fingerprint, document generation and submitted sequence1.
A finite `phase=pending` observation matched that same session, generation and
sequence, approximately 4.893 seconds after verified submission. No restored
observation was retained in the bounded query. The pending branch therefore ran,
but this case supplies no restoration or recovery-success evidence.

The original response deadline remained in force. The exact session has a saved
`closed / not_created` cleanup receipt; `not_created` does not mean that no
prompt was sent. No accepted response, tool release or format correction
occurred. The audit retains the negative marker verdict. Its seven finite
records include six inspection samples without session IDs; those samples do
not prove continuous page state, polling cadence or the absence of provider
output. The local timeout is not evidence of a provider HTTP504 or outage.

Evidence is retained in `evidence/opus5-marker377-a/`. The independent review
SHA-256 is `7fdef65ee874581793d691fba8483d5c6b65a76c5507a2acf20af50bae05f761`; the finite log SHA-256 is
`28567c748ff133b92812b91d814f2511642035d0ab29b1de30e31860b95dfff3`.

### Separate direct Opus 5 control

A new ordinary foreground Incognito tab with `Opus 5 High` selected returned
exactly `OPUS5-DIRECT377-90B25C` for a short direct prompt, with a visible completed
response signal. The operator then closed only that test-created tab. The saved
observation is `evidence/opus5-direct377-d/completed.json`, SHA-256
`11d91e3434c9cc8909f6cc8a2c3a859283b74d9fdb04cde13f52adc3d9ba079d`.

This is a direct-response control, not a harness or workflow pass. Its payload
and foreground presentation differ from the failed harness task. It does not
separate request framing, request size, host presentation or provider behavior,
and it does not establish the harness timeout's cause.

### Opus 4.8: valid refusal without actions

Fresh case `opus48-workflow377-c` returned a valid ordinary prose refusal after
17.842 seconds, one inference and zero native tool calls. Its selected-model,
first-user, document, session and saved-closure checks passed. It produced no
website/native error, malformed reply or correction. The full-workflow verdict
remains negative: all four initial fixture files were unchanged, no browser
workflow or POST occurred, and no receipt was issued. The independent grader's
failed tests are separate from model execution; the model dispatched no tests.

The reply declined to emit tool-call envelopes for the external relay. It cited
actual surrounding permission strings: `danger-full-access`, `approval policy:
never`, and `do not provide the sandbox_permissions for any reason`. It did not
quote the removed `policy isn't block proof` clause. These are the model's stated
reasons, not proof that the host lacks tools or that any particular instruction
caused the refusal. The base-clause clarification did not produce a successful
workflow in this case; this was not a matched outer-framing-only experiment.

The exact owned website session closed with a saved receipt. The fixture server
was identity-checked and stopped, its listener was absent, and the exact unused
rejected-reply arm was archived with task, inode, mtime and hash guards. No raw
rejected-reply capture existed; the global arm and output slots were clear at
retirement. No prompt was replayed. Case evidence and the independent review
are retained under `evidence/opus48-workflow377-c/`; review SHA-256:
`d8d78ae42ef5233897dec86757da2bd95c70b7832bfbd917c2150ec33d1a34ea`.

This adds a negative build377 Opus 4.8 workflow result. It does not erase older
results, resolve historical unconfirmed cleanup, qualify other models, or
complete the Claude goal.

### Build378 preparation: first-request diagnostic

An opt-in diagnostic now records the exact native insertion argument for one
nonce-bound synthetic first Opus 5 request, including the generated session
marker. It also retains the canonical request and server prompt separately.
The capture is private, single-use and bound to the task, turn, session, model,
document generation and short expiry. Its scope is revoked when Send returns.
It records a before-insert argument, not HTTP bytes or proof of submission.
Existing selection, ownership, response, refusal and cleanup checks remain in
force; the capture grants no focus or replay capability.

Forty focused tests passed with unchanged source hashes: seven new capture
tests, ten existing Claude capture tests, two native WebKit tests, one server
lifecycle/noninterference test and twenty existing benchmark capture tests.
The retained receipt is
`work/claude-qualification-20261031/claude-first-request-capture-a/result.json`,
SHA-256 `cef772a4257c0eb9a770d5bbc7c464d9a151518d4e6ae01c6f7f27225930c1b7`.
These are local diagnostic checks, not a live provider repair or qualification.

## Build378: same-prompt foreground comparison, November 1

Build378 (`68ce26b`) was installed and verified at the installed application
path, PID7021. Launching by application name initially selected the build-folder
copy; that process was closed without sending a prompt. All results below use
the subsequently verified installed copy.

Case `opus5-payload378-a` sent one new 104-byte synthetic user request for `HI`
with no tools requested. The private capture retained the 47,462-byte canonical
request, 62,106-byte server prompt and 62,168-byte native insertion argument,
including its session marker. The later native first-user fingerprint matched
the captured argument's canonical fingerprint. The task timed out after 301.171
seconds with one inference, zero tools and no answer; the exact session has a
saved closed cleanup receipt. The diagnostic records insertion bytes, not HTTP
bytes. Its original global output was archived after exact identity/hash checks;
the arm and output slots were clear afterward.

Case `opus5-direct378-b` used an ordinary foreground Incognito tab with
`Opus 5 High` selected. The captured text was copied from its private text file;
Claude initially represented the paste as an attachment. Its existing
`Edit Pasted text` control restored the full inline composer. AX readback matched
the captured 62,168 bytes plus one trailing line feed before the single Send.
No harness tools or local actions were dispatched by this direct comparison.

The website displayed `Paused`, stated that Opus 5's safeguards flagged the
message, and showed `[reasoning_extraction]`. It also displayed `Claude finished
the response`; that live-region announcement is not evidence of an answer when
the provider has blocked the response. Neither Retry nor the offered alternate
model was selected. The test-created tab was closed and the unmodified text
document was closed afterward. No Inspector or developer settings changed.

This directly establishes a safeguard block for the foreground copy of the
captured prompt. The native timed-out page had already closed, so its exact
warning was not observed. The matching prompt and missing block handling explain
a concrete compatibility gap, but do not identify a uniquely causal token or
prove a provider-side root cause. The original canonical request includes
`include: ["reasoning.encrypted_content"]` and a reasoning-summary option. These
are API-only outputs that the website adapter does not produce; passing them
through the displayed JSON is distinct from the user's request for a greeting.
Any presentation fix must preserve the original request, user/history/tool
content, permissions and verification, and must respect provider refusals.

Evidence is retained under `evidence/opus5-payload378-a/` and
`evidence/opus5-direct378-b/`. The exact outbound SHA-256 is
`6f4ce7046c873abb1974da9eef67974aba2cbd4feacf7551e2e6f8646fab3f34`;
the direct-comparison result SHA-256 is
`b3e5a8f0de603f30874fd6712c9799ad47ed1feac3d992bf0a41909b7f4ff93e`.
These are negative qualification results, not a successful Claude workflow.

## Build379: website presentation and safeguard-pause handling

Website presentation now omits only eleven top-level API output/transport
fields: `include`, `reasoning`, `client_metadata`, `prompt_cache_key`, `metadata`,
`safety_identifier`, `stream`, `stream_options`, `store`, `background` and
`service_tier`. Validation still runs first. The canonical continuation request
and native response configuration remain unchanged; retained task/history,
permissions, tool schemas, nested matching keys, unknown fields, numeric lexemes
and escapes remain intact. The website contract requests an answer or permitted
action proposal and continues to allow refusals. This removes unsupported API
output requests, not provider safeguards or binding task restrictions.

Claude's adapter recognizes the observed pause only from the complete bounded
conjunction of visible non-authored labels and unique matching Retry/Continue
controls. It reports `website_response_blocked` with the allowlisted
`reasoning_extraction` category ahead of completion or the empty-model wait.
Quoted messages, hidden/partial/ambiguous controls and unrelated providers cannot
supply that result. Ownership failures retain priority. No Retry, fallback,
answer or tool execution is authorized by the warning.

Cleanup still requires the native submitted/first-body binding and ordinary
document, route, owner and Incognito proofs. Its narrow paused-response read
cannot click Stop; if the pause disappears, it fails closed. A missing model
header alone does not prevent closing an otherwise proven owned Incognito tab.

Validation passed 234 Claude adapter tests (6,473 assertions) and 234 affected
native tests. The native run includes nine real-WebKit pause/cleanup scenarios,
the request codec and projection suites, agent instructions, first-request and
existing capture tests, benchmark capture, and the server capture-scope test.
The initial native run's failures were corrected fixture assumptions: metadata
canaries now live under retained data without relaxing exact comparisons; route
drift uses an already-bound supported conversation; Send's existing first-body
proof is asserted rather than incorrectly treated as absent. Production did not
change during those fixture corrections.

## Installed build379 comparison and build380 detection fix, November 1

The `opus5-payload379-a` marker failed after 301.253 seconds with one verified
inference, no tools and no final answer. Its saved cleanup receipt is
`closed / not_created`; that reason does not mean the prompt was unsent. The
captured website prompt was 60,359 bytes. All eleven API-only keys were absent
from the display request while canonical input and response configuration were
preserved. The unchanged independent audit retained the failed result.

The separate `opus5-direct379-c` comparison submitted those exact bytes once
in ordinary foreground Incognito mode with Opus 5 High selected. It again
showed the explicit safeguards pause. No Retry or fallback control was used.
Read-only Inspector queries established `H4` / `Paused`, an exact warning Text
node inside `P > SPAN`, and `[reasoning_extraction]` as one Text child of `CODE`
inside `[data-testid="asl3-stop-warning"]`. The only retry button's DOM text
was `Edit and retry with Opus 5`, with no aria-label. Safari's developer setting
was restored to disabled; the test tab's Inspector setting was disabled and
only that synthetic tab and the unmodified payload document were closed.

Build380 preserves ordinary code, authored content, editor, hidden and tooltip
exclusions. Only the isolated exact reason token inside the observed warning
wrapper can satisfy the reason check. Retry recognition accepts either exact
observed label while requiring uniqueness across both variants. The complete
warning/control conjunction, ownership priority, no-click behavior and strict
cleanup checks remain required. This is an error-detection fix, not evidence
that Opus 5 accepts the harness prompt.

Private evidence remains under the two named cases in
`work/claude-qualification-20261031/evidence/`. The exact consumed request was
archived before further source changes; no failed request was replayed through
the harness.

Build380 validation passed 236 Claude adapter tests (6,544 assertions), including
the actual warning structure and negative cases for altered, duplicated, quoted
or hidden controls. Two native test methods passed all nine real-WebKit pause,
completion-race and ownership scenarios. The nine versioning tests also passed.
Product and test inputs stayed unchanged during the adapter/native runs. Live
qualification was pending at that checkpoint; the subsequent results follow.


## Installed build380 workflow round, November 1

All five fresh tasks used the same installed source e62bbbaf, process 35137.
Signed-package and installation receipts, process start identity and installed
executable hashes were retained. The binary did not change during the round.
Each case had a separate fixture, nonce and previously unused loopback port.
The native composer and selected Claude model were checked before one Send;
the adapter independently verified website selection for every accepted reply.
The UTC timestamps extend into November 2; local testing was November 1 EST.

The four fully audited passes appear in the opening table. Each passed all
19 functional-fixture checks and 27 transport checks. Independent review joined
the exact commands, scoped diff, protected test files, single accepted POST,
unpredictable browser receipt, final answer and native explicit-close receipt.
All website inference sessions have saved closed cleanup receipts and release
records. Task-browser closure was verified separately from provider cleanup.
No correction occurred in those four passes.

Haiku 5.5 ran the intentionally failing tests three times before its patch,
including two redundant reruns. Those three exit-one results are retained; the
subsequent six-test pass was model-dispatched and independently rerun. Sonnet
5.5 and Opus 5.5 had no recorded tool errors. The fresh Opus 4.6 pass also had
no recorded errors or correction. These observations are not an error-rate
estimate or arbitrary-website coverage.

The separate opus46-workflow380-e run completed its functional workflow in
153.929 s with 11 inferences and nine successful native tool calls. Its third
response was rejected as malformed_website_reply; the existing single format
correction then allowed progress. The exact durable claimed, first-closed and
finished records are retained, with distinct sessions and first closure before
the second start. Detailed rejected-reply capture was not armed for this case.
Consequently, the raw rejected text is absent and the strict correction capture
and V6 audit could not complete. No manifest was fabricated or auditor rule
relaxed. Its 19 functional checks and separate native tab-close proof passed,
but full transport/correction qualification remains incomplete.

The subsequent fresh opus46-workflow380-f had one task-bound diagnostic arm
created while its journal contained only the initial start request. It passed
without a malformed reply, so the capture remained unused. The exact arm was
archived and retired after terminal evidence; global arm/output slots were
clear. This new pass does not explain the earlier malformed response. The
incomplete earlier review is retained as independent-scope-review.json under
its own case, SHA-256
`fd3a81737195150f4a16a92575f80b32fdc3565b76524685cb432f00bcf874c8`.

All five fixture servers were identity-checked and stopped, with listeners
absent. Temporary Inspector/developer settings from the prior investigation
were restored before this round. No real account actions or failed provider
requests were replayed. The Opus 5 warning detector remains covered by local
regression tests; this round does not supply a live Opus 5 detection result or
a successful Opus 5 workflow. No merge or release is implied.

Private evidence is retained under
`work/claude-qualification-20261031/evidence/<case>/` and its corresponding
`fixtures/cases/<fixture>/audit/`. The immutable audit hashes are:

| Case | Transport audit SHA-256 | Fixture audit SHA-256 |
| --- | --- | --- |
| sonnet55-workflow380-b | b7712aff3c986549985039b4eececafc3c1f5f24187e4b67c4386615431014ec | cf13eb1fbb468b19da6f0786276813eef66bd4eae105966208b7a3c29bea7f5f |
| haiku55-workflow380-c | 4fc33d2fa7593f9f64794ed9fbac00b5097113831af47399a53eb25b5c83e4b2 | 633d0fa614cc0a0beb3df36113ac85b72dccc77cbae95e4cd22144eee46a66e1 |
| opus55-workflow380-d | 082fd39a6d1373e89a285fd8e97ac6483e8d4f1a3877ace8ee1ee696cabd81cd | 9ac13295edd8d92721f3e1c7407ed5fede3afffcd0c9a008498689f811d01d1b |
| opus46-workflow380-f | 69063bea9a5b7a7c245707042fe9fe94381a7720ddf044615ae7b5a9114bcf06 | 05b5ca984aacdd7bb31f340dff201056cf234f633302efb26b01f2a62c2c5082 |
