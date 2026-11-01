# Groq website adapter qualification

## Compact tool loading candidate

New Groq chats register the read-only `computa_load_tools` tool alongside the
existing native tools. The website initially receives a complete compact
inventory. Loading one to four exact inventory names exposes their full current
schemas in the next request and returns a small receipt. It executes nothing.
Commands, patching, browser operations and approvals continue through the
existing native engine and its checks.

The catalog is scoped to the task, thread, turn, preparation, runtime generation,
model, schema revision and tool-choice policy. A changed catalog discards the
loaded selection. Browser binding and current action references remain separate.
Forced tool choices are preloaded when the loader is not allowed; `none`,
parallel-call limits and maximum-call limits retain their meaning. A successful
new-thread registration receipt supports restart/resume; older threads are not
silently migrated. Original canonical requests and continuation history remain
unchanged.

Schema loading previews the next presentation against the current request and
an additional 256-unit estimate for the pending loader call and receipt. A
selection that does not fit returns a read-only tool error and preserves the
previous selection. Catalog preparation and its cached request commit together
after admission. The estimate cannot promise that future tool results fit;
the complete final request is always checked again before opening a provider page.

Only this native compact path substitutes a concise version of a complete,
byte-matching current Computa instruction block in a trusted instruction role.
The default text-only background runtime base is also matched as a whole;
custom policies and other runtime modes retain their original text. Shared base
composition remains byte-identical across all existing configuration axes.
User messages, foreign instructions, tool results and action evidence are not
truncated. The outer response contract is also concise. Every reply still passes
the existing envelope, model, ownership and cleanup verification.

The final GPT-OSS 120B/20B prompt is counted with a pinned local ordinary-text
`o200k_harmony` tokenizer. The local body limit is 6,000 tokens, with 2,000
reserved for unmeasured website framing/output and the native session-marker
suffix appended by the transport. Other Groq selections use a
conservative 6,000 UTF-8-byte bound, not an asserted GPT-OSS token count. Missing
or incompatible tokenizer resources fail before submission. Growing history
that exceeds admission is reported explicitly; this feature does not silently
summarize or discard it.

A shared local rolling allowance charges the counted body plus the reserve and
holds each charge for 65 seconds after Send returns, including uncertain Send
failures. Small requests can share the allowance. Waiting is cancellable and
rechecks the native turn before Send. This accounts only for Computa requests;
manual use, other clients, changed provider limits and provider-side accounting
can still produce a quota error. Charges are in memory and reset when the server
or app restarts; this is not an account-wide or persistent quota ledger.
No quota failure authorizes replay.

Candidate validation on 2026-11-01: 294 focused native regression tests and two
private offline measurement cases passed, with source hashes unchanged during
the run. The regression coverage includes catalog scope/revision changes,
transactional oversized-selection rejection, literal continuation preservation,
32 unchanged base-instruction configurations, tokenizer parity and cancellable
quota pacing. The earlier 27 native Groq transport tests also passed; the
website adapter's ownership, model and cleanup acceptance rules are unchanged.

The retained complete synthetic fixture was measured without provider requests.
Its initial unbound prompt fell from 11,892 to 3,187 ordinary-body tokens. With
the original post-tabs history retained, the bound prompt is 4,364 tokens for
inventory only and 5,159 with the exact `browser_read` schema loaded. Loading
`exec_command`, `apply_patch` and `browser_read` together at that later point is
6,056 tokens and remains rejected. The same three schemas fit the initial
request at 4,834 tokens. The loader preflight also reserves 256 units for its
pending history; measurements below 6,000 do not by themselves guarantee a
selection will pass that stricter preflight. These are source/fixture results,
not yet installed-build or live Groq qualification.

Private evidence: `groq368-compact-native-e-receipt.json` (log SHA-256
`2b7ee6d1c0ab5607c7239028a23976e73425d1bf8e34c873bf308a159fb6ca27`),
`offline-prompt369-f/manifest.json` and `offline-prompt369-g/manifest.json`.

## Scope and status — 2026-11-01

This work adds the signed-in `https://chat.groq.com/` website as an embedded
provider. It does not configure Groq API access or substitute another provider.
Build 367 (0.8.0) is installed from `45ec979`. Its fresh GPT-OSS 120B marker
passed submission and an initial first-user binding observation, then failed a
later `user_count` ownership check: the rejected read matched zero user and
answer rows where one user was required. No completed answer was accepted;
cleanup is unconfirmed and live support remains unqualified. A separate normal
website test returned an error for a longer synthetic prompt. One approved
resend captured HTTP 413: the provider reported a tokens-per-minute limit of
8,000 and a request of 9,085 tokens. This confirms that direct request's budget
failure, not the original harness request's status or token count. Direct
website probes below are not harness qualification.

The observed menu contains these general chat choices:

| Website key | Website label | Direct website evidence | Harness evidence |
| --- | --- | --- | --- |
| `qwen/qwen3.8-27b` | Qwen/Qwen3.8-27B | Exact marker returned | Pending |
| `openai/gpt-oss-120b` | GPT OSS 120B | Requested structured response returned | Build367: zero matching rows after initial binding |
| `openai/gpt-oss-20b` | GPT OSS 20B | Completed; malformed JSON rejected | Pending |

The same menu also exposes `meta-llama/llama-prompt-guard-2-22m`,
`meta-llama/llama-prompt-guard-2-86m`, and `openai/gpt-oss-safeguard-20b`.
These specialized classifier/safety models are excluded from general agent
selection. Discovery reads the current menu; these observations are not a
fallback catalog or an assertion about future account availability.

## Observed controls and identity

- The selected model appears in the model button and the single URL `model`
  query. The associated dialog supplies exact `data-value` keys and labels.
  Menu `aria-selected` indicates keyboard focus and is not model identity.
- The page includes mobile and desktop copies of `textarea#chat`; only one is
  visible. Its own form contains the Send button. Duplicate visible editors
  must be rejected instead of selecting the first DOM match.
- User text sits in a `group/input` block with a `line-clamp-5` body; the CSS
  clamp is not evidence that the text itself is truncated.
- The same turn container holds the assistant body. GPT-OSS also shows a
  Reasoning control and a code block. The answer is a scoped `div.font-inter`;
  its separate sibling footer contains the response Copy button. Reasoning is
  a separate sibling, not part of the authored answer.
- Both GPT-OSS responses used a nested `PRE > DIV > PRE > CODE.language-json`
  shape, with an icon-only copy decoration beside the inner PRE. The adapter
  must preserve authored text outside this block and never repair malformed JSON.

The 120B probe disabled the composer and Send during generation, then restored
both and displayed response controls and throughput after completion. The
inspection console did not successfully install its observer for this probe;
it supplies two UI observations, not a complete mutation trace. A bounded
MutationObserver successfully captured the 20B probe: the unique editor and
same-form Send became disabled at submission; 973 ms later the answer and
enabled footer Copy appeared together with an enabled, empty editor and Send.
No intermediate answer snapshot occurred in this small probe. These scoped
terminal controls, rather than throughput text or a timer, supply completion
evidence.

The 120B code contained valid JSON with the exact marker and integers 1–180.
The 20B code contained an extra closing bracket (`180]]}}]}`) and failed
`JSON.parse` with “Expected '}'”. Its completed response is a format failure,
not a passing tool invocation. No tool was executed by either direct probe.

## Cleanup contract

Groq did not expose a Temporary Chat or Incognito control in this check.
After the Qwen marker, **Clear chat** removed the test transcript and its
response controls, restored the empty composer, and remained empty after a
normal reload. The 120B exchange was also cleared after inspection; the 20B
exchange was cleared and remained empty after reload. This establishes visible
UI cleanup for these exchanges, not a claim about Groq's server-side data retention.

The implementation therefore uses a separate `explicit_clear` lifecycle:

1. Own a fresh private view and pin its document, URL, observed model and exact
   first submitted body.
2. Dispatch the unique eligible Clear chat control once, bound to a native
   operation nonce and the existing ownership proof.
3. Verify that same operation removed the owned message nodes, left an empty
   transcript and fresh composer, and preserved document/model identity.
4. Close the exact private view and persist a lease-bound
   `transcript_cleared` receipt before releasing model output or tool calls.

Ambiguous cleanup retains the surviving owned view. A cleanup retry may observe
the already-dispatched clear; it cannot blindly click again. Existing providers
retain their temporary/incognito checks. Read-only model discovery can still
close its never-submitted private view without claiming transcript deletion.

Transaction diagnostics label Groq `explicit_clear_per_inference`; they do not
label it a temporary conversation. The diagnostic schema and transaction version
remain unchanged, and the label itself grants no cleanup or output-release proof.

## Evidence

Private evidence is retained under the task's
`work/groq-qualification-20261031/` directory. It includes the observed picker
and control markup, Qwen marker screenshot, clear/reload observations, 120B
response, and source-hashed native/WebUI test receipts. Signed-in page evidence
is not copied into this repository.

- Selector tests: 13 passed; TypeScript check passed.
- First completed native baseline: 322/325 passed. The three failures were
  stale provider-count/order and diagnostic-phase-count assertions. Corrections
  passed in a later targeted run; this baseline is retained, not relabeled.
- Updated native subset: 121 tests passed, zero failures, source hashes
  unchanged. This includes read-only Groq discovery, pre-action hydration,
  exact model-query validation, no-Send disposal, origin/clock diagnostics,
  server transaction gating and cleanup-receipt validation.
- Dedicated Groq fixtures: 36 tests and 233 assertions passed after completing
  structured extraction and response completion. They cover model identity,
  fresh ownership, exact insertion, one-shot submission/clear, scoped terminal
  controls, premature Copy controls, literal malformed JSON, authored prose,
  and fresh evidence after an asynchronous fingerprint check.
- First complete Groq native run: 12 of 13 tests passed. Five assertions in one
  missing-acknowledgement test failed because its page-world method override
  did not affect the adapter in WebKit's private world. The receipt is retained
  as failed; correcting that test does not establish a production cleanup fix.
- Final focused native run: 19 tests passed, zero failures, with unchanged
  source hashes. This includes all 14 real-WebKit Groq transport cases and five
  server/receipt/verification-store cases. The final native completion read
  rejects changed answer bytes or resumed streaming after the model-verification
  await. Lost-clear-acknowledgement injection now runs in the actual private
  script world; the observed click occurs once and unconfirmed cleanup stays
  failed. Evidence: `native-groq-completion-i-receipt.json`, log SHA-256
  `64639ffdc3fbe0b8a62f0bb147fa3c6e4dc20d3782443310327f98845b093bdf`.
- Selector and TypeScript checks passed again after integration changes.
- Version checks: nine tests passed; the candidate is 0.8.0 (355). The production
  WebUI build and TypeScript check passed. No installed-build claim follows
  from these source/build-preparation checks.
- A subsequent focused native test passed after correcting Groq's transaction
  diagnostic to `explicit_clear_per_inference`. Its source hashes stayed
  unchanged; existing providers' labels, schema and versions remained covered.
- Composer-diagnostic native run J: 21 tests passed with zero failures in
  29.524 seconds, with unchanged source hashes. This covers 16 Groq native
  cases and five server, cleanup-receipt and verification-store cases. The new
  diagnostic admits only finite action/reason labels. A controlled oversized
  composer reproduced a center hit-test rejection at `sendReady`, with zero
  Send or Clear actions; this does not establish the live build355 failure's
  cause or change its rejection behavior. Evidence:
  `native-groq-diagnostic-j-receipt.json`, log SHA-256
  `50f61b8677cf819a6d9a834831a4d9f11e94133dcbbb672f6e715d57ab7a0524`.

These checks do not replace live per-model terminal, file-edit and browser-task
qualification. Three independent fixture cases have been prepared with the
same six-test invoice benchmark and individually bound browser receipts. They
have not been submitted to Groq.

The bounded direct inspection is complete. Safari's stuck menu/input state was
resolved by restarting Safari and using the user's explicitly authorized
activation-only AppleScript. The intended Inspector programs then executed;
this was an operator-tooling issue, not a Groq provider fix. The private DOM
observer was removed, the Groq tab's Inspector permission was restored off,
and Safari's “Show features for web developers” setting was verified off.
Only the three approved test exchanges were cleared. The root-created, empty
inspection tab was then closed. Evidence includes
`oss120-code-verified.txt`, `oss20-completion-trace.txt`,
`oss20-code-verified.txt`, `oss20-scope-verified.txt`,
`oss20-clear-reload-ui.txt`, and `safari-develop-restored-final.txt`.

## First installed check — build 355

The native build passed 11 artifact checks and the signed derivative passed ten
checks. Signing initially failed with Code Signing subsystem internal error;
a retry passed after removing the failed stage and rebuildable test index and
binaries (about 494 MB). This is consistent with scratch-space pressure, not
proof that it was the only cause. Installed executable SHA-256:
`0a2d965dfe9e0e0f09bf7c0f25902f6ba52368b55031cf589ffb7c97db81b7e0`.
Build354 remains in the installer's rollback directory. The reproducible native
candidate was removed only after signed and installed bytes were verified;
its receipts and symbols remain. Before preparing diagnostic build356, the
duplicate signed355 artifact was also retired after every recorded bundle-file
hash matched installed355. Its complete inventory was retained in
`pre356-generated-prune.json`; installed355 and rollback354 were preserved.

Fresh case `groq-gptoss120b-marker355-a` selected GPT OSS 120B and failed in
2.139 seconds with `composer_unavailable`, before any Send or tool call. Its
owned view closed with a durable `not_created` receipt. The exact task, journal,
error and unchanged installed-process identity were retained. The unused,
exact-task rejected-reply diagnostic arm was verified and archived. No prompt
was replayed. This evidence does not distinguish the failed editor predicate
or preparation action; those require a focused diagnostic/regression before
another fresh check. Other model harness checks have not started.

## Composer diagnostic and visible-area repair — 2026-11-01

Build356 was installed from `309a451`, with all eleven native artifact and ten
signed-derivative checks passing. A user-created `hi` task on Groq/GPT OSS 120B
captured `composer_unavailable; action=sendReady; detail=editor_hit_test` at
04:01:56Z. Its native turn lasted 2,685 ms, invoked zero tools, and closed with
a saved `not_created` receipt. This is an incident record, not a controlled
qualification pass. Bounded logs and exact native task/thread/turn journals
are retained under `incidents/user-hi-groq120b356-01a19545-5cc1/`.

The prepared marker356-b was never dispatched and its diagnostic watcher was
never launched; it is retained as `not-dispatched.json`. No failed prompt was
replayed. The incident proves which predicate rejected the editor; it does not
record the live element's geometry. The real-WebKit regression independently
reproduced that predicate with a long, expanded textarea whose geometric center
fell outside the viewport while part remained visible.

The repair checks one point at the center of the control's intersection with
the viewport. It still requires a unique visible, enabled control and a hit on
that exact node or its descendant. It does not scroll, search alternative
points, or retry an action. Fully off-screen, invalid geometry and covered
controls still fail; model, ownership, exact prompt and one-send gates remain.
The targeted JavaScript suite passes 44 tests and 467 assertions, including
clipping, overlays, stale prompt/route/model and lost acknowledgement cases.
Installed verification of this repair remains pending.

Native run K passed 21 of 22 cases; its new positive geometry case failed on a
UUID-case assertion and cleanup in the synthetic layout. Run L captured the
cause: the fixture's unclamped body was 1,602 px high, scrolling reached its
1,042 px maximum, and Clear's center hit the fixed editor. Adding the observed
five-line visual clamp preserved all body bytes and allowed the unchanged
cleanup checks to pass. The corrected positive test passed in 2.203 seconds
with one Send and one Clear; the other 21 cases were unchanged. Both runs have
unchanged source snapshots, and the failed K evidence is retained. Log hashes:
K `02bd509caa1acbf56a7f9cb0a51def7cf6b037b38a1124d023d3a94082fc0c83`;
L `f1864c9bba68bb964f93e92ad87f52c01c44c25ae78253eaec7dceeb5350132d`.

Reproducible native/signed356 candidate copies were retired after verifying the
installed artifact and preserving full receipts/inventories. Installed356 and
the installer backups remain; this storage cleanup is not a release operation.

## Fresh installed check — build 357

Case `groq-gptoss120b-marker357-c` failed in 5,487 ms with
`send_unavailable`. It invoked zero tools; the private view closed with a
durable `not_created` receipt. The exact marker, selected model, unchanged
installed process and source, native task/thread/turn, journals and error are
retained in its evidence directory. Its unused diagnostic arm was verified and
archived. No prompt was replayed. The three prepared workflow357-d cases remain
unstarted, gated on a successful initial marker.

The three-second Send-readiness wait discards its false observations, so this
error does not distinguish a disabled, off-screen or covered button. A normal
Groq tab with a harmless, unsent synthetic long draft visibly expands the
editor, but this screenshot alone does not establish the exact predicate in the
failed owned session. The subsequently approved, read-only Inspector check found
the normal pane had a 360×527 mobile viewport: its expanded editor extended
above the viewport, while its Send button was enabled and hit-testable at
`[247,441,40,40]`. The model view is configured at 1024×768 and uses a separate
desktop form. These different layouts do not prove the owned-view cause.
The draft was never sent. Both developer settings were restored, and only the
root-created test tab was closed. Evidence: `layout358-inspector-results.txt`,
`layout358-safari-restored.txt`, `layout358-inspector-off.png` and
`layout358-tab-closed.txt`.

The next diagnostic preserves only the closed reason from the actual hit
decision, labels a timeout reason as `last_observation`, and keeps the same
deadline, event waits and Send gates. Missing/ambiguous controls have separate
finite labels. JavaScript checks pass 48 tests and 529 assertions. Native run M
failed compilation because a new test referenced a nonexistent fixture member;
no tests ran. That reference and an unrelated notification-wakeup test defect
were corrected. Native run N then passed all 26 tests in 49.584 seconds with
unchanged source hashes, including the existing ChatGPT readiness deadline
case. N log SHA-256:
`9cab63a14d5beadf40a2b1275a0e0610e884b5a757323911a1b0640c1799ca2e`.
## Owned-session Send diagnosis — build 358

Fresh case `groq-gptoss120b-marker358-e`, installed from `b83693d`, failed after
5,372 ms with `send_unavailable; action=sendReady; stage=last_observation;
detail=outside_viewport`. The bounded native log records that exact finite
reason at 04:30:05.901070Z. This establishes that the last completed readiness
read found Send outside the viewport after inserting the verified prompt; it
does not claim a new geometry measurement at timeout. No website Send or tool
call occurred, and the owned view closed with a durable `not_created` receipt.
The exact failure capture and unused-arm archive are retained. Native log
SHA-256: `3dadb0a556ac3c47e2fd6fb72d4da12c99f7590413bb72f068a2bc3a76953347`.

The resulting repair is being qualified: reveal only that exact verified Send
control once when its actual hit-test reason is `outside_viewport`, then repeat
the ownership/model/prompt/control and hit checks before allowing Send. Other
failure categories do not grant a scroll, and the original deadline remains.

No live harness pass or release is claimed yet.

## One-shot Send reveal — candidate build 359

Only a `sendReady` result of `outside_viewport` permits one reveal of the exact
same-form Send button. The attempt is claimed before scrolling. The adapter
then rechecks document, owner, URL, model, exact prompt, editor/form/button
identities, zero submitted messages, enabled editor and actual hit tests.
Lost acknowledgment or changed ownership/targets cannot repeat the scroll.
Submit remains a separate, fully checked one-shot action. No timeout is extended.
A finite before/after diagnostic records the actual attempt and grants no
action authority.

JavaScript validation passed 54 tests and 680 assertions. Native run O passed
28 of 29 tests, including the real-WebKit normal-flow long-editor test with
one insertion, one reveal, one Send, verified response and one Clear. Two
assertions in the negative replacement case expected the never-submitted page
to close. The production ownership error correctly remains terminal through
cleanup and retains the page. Only that test expectation was corrected; the
production cleanup contract was unchanged. O retained unchanged source hashes;
log SHA-256 `eff82f8e0f93e6e7b166ba069fd7551bb0ad4eeace6d78dbc97c1f13518587e8`.
Version checks passed nine tests.

The corrected seven-scenario negative test passed in native run P (8.618 seconds,
unchanged source hashes). The other 28 cases and all production sources remained
unchanged from O. P log SHA-256:
`acc62ee1df2c7982fbaea798bca29c4837b30b7cc56c6940f40a1b575d019d9f`.

## Fresh installed check — build 359

The clean `92b4b3e` source passed all eleven native artifact checks and ten
signed-derivative checks. Installed executable SHA-256:
`c278911ed3ceb69e4aa78f93380f26307e7571ce32cc3d977fd77efeb7a6e396`.
This is an installed diagnostic build, not a notarized/public release.

Fresh case `groq-gptoss120b-marker359-f` failed in 2,352 ms with
`website_ownership_unverified` / `first_user_message`. The finite log records
one Send reveal from `outside_viewport` to a valid hit at 04:42:23.899552Z.
The journal then records submission acknowledgment at 04:42:23.952Z with an
empty first-user fingerprint; 26 ms later the first ownership read failed.
Thus the reveal was exercised successfully, but message ownership was never
established. No model result was released and zero tools ran.

Cleanup remains unconfirmed, with the failed page retained. The native trace,
task/model/source/process identity, UI, journals and an independent failed
qualification audit are saved under this case. The exact unused diagnostic arm
was archived; no prompt was replayed. Bounded native log SHA-256:
`1c7f98911c95aa09c14217b029cb14b2d5339c1b2037eb4493cf714c21732bb9`.
Those log lines are correlated by process and time; they carry no task ID.

The build359 adapter requires a one-child user-message wrapper and a leaf
`line-clamp-5` body. Different long-message markup is a hypothesis, not an
established cause. A separate harmless unsent long draft is prepared for a
bounded inspection; the failed owned page is untouched. All workflow359-g
cases remain unstarted pending an independently verified marker pass.

## Observed long-message structure — November 1, build365

The previously unsent layout359-H probe was recreated in a new ordinary Groq
tab under the user's bounded inspection approval. Its exact 5,313-byte,
80-line-break synthetic prompt was sent once to GPT OSS 120B and returned
`GROQ-LAYOUT-359-H-2B76`. The submitted body remained a leaf `DIV.line-clamp-5`
containing the full text. Its wrapper had two children: that body and a leaf
`SPAN.text-primaryaccent.cursor-pointer` containing `Show more`, with no role
or accessible label. The one-child predicate rejected this observed structure
before first-user fingerprint binding. This establishes a concrete long-message
ownership bug; the original failed `hi` task's submitted body was not captured,
so its exact historical cause remains unproved.

Only this test exchange was cleared, its tab closed, and both developer settings
restored. The direct website response is not harness qualification. The original
failed owned task and its cleanup warning were not replayed or cleared. The
inspection receipt is `layout365-recreated-evidence-receipt.json`, SHA-256
`ca48c6b8f12bc6e086e1f7cdad3d52a25d94822912d23b4d161acedb5a656430`.

Candidate build366 admits only that exact optional presentation sibling. It
continues hashing the complete leaf body, never clicks `Show more`, and retains
the existing model, document, owner, full-prompt and cleanup checks. Unexpected
extra content, controls, duplicate bodies and changes during hashing fail closed.
The integrated Groq and version JavaScript suites passed 66 tests with 855
assertions. All 25 native Groq tests passed in 57.793 seconds, including the
observed long body, one Send, exact full-prompt fingerprint, verified response,
one Clear and zero expansion clicks. Negative cases retained failures and did
not clear uncertain transcripts. The combined run's only failure was an
unrelated optional rendering experiment's unavailable display precondition;
the Groq test sources and production sources stayed unchanged throughout.
Log SHA-256:
`938ccf993201024eeb224f8fa326143029cf59dbe6f6020ed8952dbd326de4f4`.
The installed check below remains a failed qualification; this candidate is not
a public release.


## Fresh installed check — build366

Case `groq-gptoss120b-marker366-a` on source `27c3f9c` failed in 2,469 ms
with `website_ownership_unverified` / `user_count`. It had one inference,
zero tool calls and no accepted final answer. Selected GPT OSS 120B and Send
acknowledgment were recorded before the failure.

The submission journal initially contained an empty first-user fingerprint.
A later completed native inspection recorded one user, sequence one,
`pending=false`, `ownershipPending=false`, zero responses and `busy=true`.
Together with the exact built source's validation order, this supports an
initial first-user binding before the count rejection. The later fingerprint
value was not persisted. The finite inspection is correlated by exact app PID
and time window rather than its own task/session identifiers; it is not a
standalone fingerprint receipt.

The adapter uses `user_count` for multiple user nodes, multiple answer nodes,
an answer without a user, or a mismatch with the expected user count. This
build did not record the failing branch or its counts. The result therefore
does not establish duplication, a missing row, a selector mismatch or any
particular website rendering cause.

The exact cleanup receipt was saved with outcome `unconfirmed` and reason
`cleanup_unverified`. No rejected-reply payload existed because no completed
reply reached format parsing; the unused task-bound diagnostic arm was archived
separately. That retirement does not confirm provider-page cleanup. The prepared
full workflow was not started because the marker did not pass.

The native trace, model/source/process identity, journals, UI and finite logs
are retained under `evidence/groq-gptoss120b-marker366-a/`. Its
`independent-failure-review-v2.json` corrects the earlier report's assumption
that an empty dispatch-time fingerprint meant binding never succeeded; both
reports are preserved. This failure does not weaken the full-prompt ownership,
response, one-shot action or transcript-clearing requirements.

## Count-rejection diagnostics — candidate build367

The next candidate preserves each original rejection and adds a finite snapshot
of that exact decision: multiple users, multiple answers, an answer without a
user, or an unexpected user count. Total and visible counts come from the same
already-collected arrays; visibility failures are recorded as unknown. The
native transport accepts only a bounded, exact-field projection and logs it at
most once per owned session after its existing callback ownership checks.
No page text, second DOM query, retry, extended wait or new action is introduced.
The diagnostic cannot grant response or cleanup authority.

The Groq and version JavaScript suites passed 71 tests with 945 assertions.
All 27 native Groq tests passed in 58.163 seconds, including finite-field and
branch consistency checks; sources were unchanged during the run. Native log
SHA-256: `9d82b50c57bd959b15a734f9d3c1828a0780012b54a72e9cacfd12b82d06645e`.
The installed diagnostic run below identifies the rejected branch; the cause
of the missing matching rows remains unresolved.

## Fresh installed diagnostic check — build367

Case `groq-gptoss120b-marker367-b` on source `45ec979` failed in 2,553 ms
with one inference, zero tool calls and no accepted answer. A native inspection
at 07:48:30.960 UTC recorded one user, no pending submission or ownership check,
zero responses and a busy page. The following rejection recorded
`branch=expected_count`, `expectedUserCounts=[1]`, `userCount=0`, `answerCount=0`,
both visible counts zero, `submitted=true` and `adapterFirstBound=true`.

This proves the exact selector counts at the rejected read. It does not prove
whether the website removed the nodes, changed their markup or would restore
them. No remount retry or weaker ownership acceptance was added. Cleanup
remained unconfirmed. The unused diagnostic arm was retired and its watcher
exited; those actions do not confirm cleanup of the retained provider page.
The independent review is retained under
`evidence/groq-gptoss120b-marker367-b/independent-failure-review.json`, SHA-256
`939751529a4054617b82e0fbaa152a134d9bfbcb63fc04415822af45a5260023`.

A separate ordinary Groq tab on the same build submitted one harmless
30,729-byte synthetic prompt to GPT OSS 120B. The website displayed
“Something went wrong. Please, try again.” and restored the full draft. The
earlier 5,313-byte probe succeeded, but this is not a simultaneous size control
and no HTTP status or response error was captured for that first trial. Its
cause was initially unknown. The separately approved capture below records
that resend's concrete request error; it does not retroactively establish the
first experiment's or the harness request's HTTP result.

## Approved direct-request diagnosis — build367

One explicitly approved resend of the same harmless 30,729-byte synthetic
prompt captured a POST to `api.groq.com/openai/v1/chat/completions` returning
HTTP 413. The response identified `openai/gpt-oss-120b`, error type `tokens`,
code `rate_limit_exceeded`, a tokens-per-minute limit of **8,000** and
**9,085 requested tokens**. The inspected request's Content-Length was
**31,524 bytes**; the prompt and complete request body are different byte
measurements. The saved Preview text verifies the status and token figures;
the method, endpoint and byte counts are operator-recorded request metadata.

The website restored the draft. No further Send was performed. The synthetic
draft was cleared, the ordinary tab was left open and empty, its Web Inspector
setting was turned off, and Safari's developer setting was restored to off.
The original failed harness task and its unconfirmed cleanup remain separate.

This establishes a request-budget rejection for the controlled direct resend.
It does not prove that `groq-gptoss120b-marker367-b` received HTTP 413 or used
9,085 tokens; its complete outgoing payload and provider request were not
captured in this probe. No byte-to-token ratio, output-token contribution,
quota reset time, automatic replay or weaker verification is inferred. The
next change should measure the actual harness request before choosing a
lossless size reduction or reporting the provider limit.

The private final receipt is
`ordinary367-request-budget-probe/receipt.json`, SHA-256
`1bf533aab2f0a315c44d39b855f64cc08d2eb00a856ad1c4a28c9fcd24582f2f`.
It indexes the redacted response preview and cleanup evidence by hash without
copying credentials, organization identifiers or raw request content.

The captured native input-message text totals 19,379 bytes; it is not the full
outgoing prompt, which also contains schemas and framing. The next source
diagnostic records existing prompt-component counts and actual transport byte
counts without message content, URLs or authority tokens. It does not truncate
the request, alter tool instructions, replay Send or claim provider acceptance.
`finalPromptBytes` measures the prepared server prompt; the native
`outboundUTF8Count` also includes its session marker. The four JSON component
counts partition `compactRequestBytes`, not `presentedRequestBytes`; Groq's
presentation remains unchanged. Server records carry native task/turn/inference
identifiers. Transport counts have a sequence and require the existing journal,
PID and time-window evidence for correlation; counts alone are not identity
proof. This diagnostic has not yet been installed or exercised against Groq.
The native build and 110 prompt-projection/response-codec tests passed with zero
failures. Log SHA-256:
`92d49db8f95502bced7a52d86c4fcdd228c23d81fbbae682843e76b179d8d9d6`.

## Compact presentation and remaining request budget — candidate368

Groq alone now presents the complete projected request as compact JSON inside
one unlabelled code block. This removes JSON-structural whitespace and avoids
expanding string punctuation into Unicode escapes. The JSON remains one line,
so backticks in a valid JSON string cannot introduce a closing-fence line.
Every decoded value, schema and policy remains unchanged; original continuation
bytes remain retained. The existing exact-current-native-contract check also
omits duplicated outer guidance when the complete trusted developer contract
is already present. User/tool text, partial contracts and obsolete contracts
cannot activate that path. Other providers retain their previous prompt bytes.

The final native prompt/codec/instruction/fixture suites passed **177 tests**;
the version suite passed **9 tests**. An earlier combined run had one stale
test assertion expecting Groq's old presentation explanation; that assertion
was updated to require the complete provider-specific context. Its targeted
rerun and the final full focused suites passed. A separate private offline
comparison verified complete projected JSON equality, unchanged continuation
bytes and byte-identical other-provider controls against the prior codec.

The comparison uses a previously captured synthetic Claude task, changes only
its provider for measurement, and explicitly derives initial history prefixes.
It is not a replay or reconstruction of the failed Groq367 request. An isolated
`tiktoken` 0.12.0 counter with official `o200k_harmony` vocabulary counted the
exported prompts offline, verifying all twelve source hashes and UTF-8
roundtrips with zero network attempts during counting:

| Synthetic control | Browser unbound, before → after | Browser bound, before → after |
| --- | ---: | ---: |
| Complete initial prefix | 15,025 → 11,892 tokens | 17,194 → 13,640 tokens |
| Complete retained post-tabs request | 17,452 → 13,114 tokens | 19,621 → 14,862 tokens |

The incomplete first-user-only controls also remained above 8,000 tokens and
are not presented as complete initial tasks. These counts exclude provider
framing, the transport marker and any output reservation. The controlled
30,729-byte direct prompt alone counted 8,669 tokens, compared with the
provider-reported 9,085; the 416-token difference has no established component
attribution. Byte counts are not used as token estimates.

The full harness therefore remains unqualified: even the compact synthetic
request bodies exceed the observed allowance. Do not submit these same controls
again merely to reproduce the known budget failure. Supporting that website
budget requires a separate design for tools loaded on demand and history
budgeting, with full native execution/permission checks retained. A different
API route would require separate account configuration and limit verification;
this change does not switch providers or extract website credentials.

Candidate368 has not been packaged, installed or exercised live. Installed367
and the published alpha.363 release remain unchanged. The private finite count
receipt is `tokenizer368/offline-prompt368-counts.json`, SHA-256
`245a186ad02eb2801d12decefaadbdcf7266f11a0d3657553a70f5333a20c56d`.
