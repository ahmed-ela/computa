# ChatGPT mail workflow investigation

An authorized short email task in the built-in browser exposed distinct
problems. The first run stopped after the provider became idle without returning
an assistant response. A later instrumented run received valid provider responses
but could not reach Gmail's minimized compose controls. No email was sent in
either run. Subsequent local fixtures distinguish these failures from successful
input dispatch or delivery.

## Capture and progress

The DOM discovery budget could be exhausted by a wide inbox before a deeply
nested, small control panel was visited. Such panels often have an accessible
name but no dialog or form role. Pagination cannot recover nodes omitted from
the original capture.

Discovery now shares its existing 4,096 structural-slot budget across branches
and compact-container checks. A completely inspected, explicitly named panel
with controls receives form priority. Editable branches receive that priority
without requiring autofocus or a form tag. Compact-container inspection is
bounded to 64 slots; incomplete or large application containers do not qualify.
Selection priority does not change the captured DOM order, action permission,
hidden/password handling, reference validation or capture size limits.

A second live fixture proved the controls were exposed but still failed: the
model repeatedly read the same partial page before selecting the already observed
Full screen control. It then filled three fields, but the next complete prompt
was 164,549 bytes, exceeding the 163,840-byte limit. The fixture recorded no draft
or send. Tool results appeared once in request history; repeated calls grew the
history. This failure is retained separately from the capture repair.

Progress guidance now makes pagination conditional on missing evidence. A current,
relevant control can be used without exhausting the page. Revealing a collapsed
panel may require an observed presentation control; unchanged reads are not
progress. Uncertain submissions still require read-only verification and must
never be replayed. The same guidance follows quoted history on every website
inference, while preserving the full address, approval and form-submission rules.

An unfiltered overview also keeps a small observed panel's passive context and
controls together. Eligibility requires complete captured ancestry around the
first source-prioritized control, a semantic form/dialog or explicitly named
group/region, at most 32 captured descendants and two to eight controls. Large,
ambiguous, actionable or navigation containers retain the ordinary ordering.
A readable sample remains near the front; the rest of the immutable selection
continues without dropping rows. This ordering is neither focus nor completeness
evidence and grants no new input authority.

## Ownership finalization

Build 304 completed the minimized-compose draft in 127.269 seconds: ten tools,
zero tool errors, one exact unsent draft, and eleven freshly verified and closed
ChatGPT Chat / Instant inference sessions. The receipt was read in full and the
task-created fixture tab closed while preserving the normal browser tab. This
is local draft evidence, not external email delivery or a controlled latency
comparison with earlier failed runs.

The subsequent real-mail task stopped after tab inventory, before any mail input.
Its second inference failed `website_ownership_unverified` with reason
`first_user_message`; cleanup remained unconfirmed. The native task UI showed
this typed error. A generic engine `internal_server_error` did not identify its
cause.

Finite diagnostics and a deterministic adapter reproduction isolated a URL
transition during finalization of an already granted replacement read. The
complete prompt and model had passed their checks. After the second permitted
route transition, the finalization path discarded the read without retaining
the existing recovery record; the next read rejected the spent claim. This is
separate from changed prompt bytes or an empty provider response.

Finalization now uses the existing bounded route-discard handoff for this case.
It retains the same replacement certificate and deadline, returns no response or
verified state from the discarded read, and requires the next native-certified
route read to repeat the complete prompt/model/temporary-session proof. It does
not create another certificate, click again, resend a prompt, or expand the
two-edge route budget.

The adapter regression fails on the immutable build-304 script and passes with
the handoff fix. All 512 adapter tests (24,181 assertions) pass, including exact
timing, invalidation during finalization, invalid continuation/certificate, and
no-resurrection cases after invalid state is restored. The failing real prompt
had matched its full canonical bytes; comparison with the successful draft also
rules out framing truncation as the cause of this reproduced case.

Seventeen focused native ownership/diagnostic tests also pass. The same compiled
native regression fails with the immutable build-304 adapter and passes with the
candidate adapter. It verifies the exact finalization ordering, fresh complete
proofs, the same certificate/deadline, and unchanged input counts. Wrong-model
and ownership negatives remain rejected on both the first and subsequent reads.

Build 305 then completed the installed minimized-compose draft in 98.721 seconds:
nine tools, one exact unsent draft, zero sends, and ten freshly verified and closed
Chat / Instant inference sessions. Independent receipt and current-reference
checks passed. The task-created fixture tab and fixture server were cleaned up.
These separate live runs do not constitute a controlled latency benchmark.

## Product-mode preparation

The next real-mail attempt stopped in 3.310 seconds during preparation, before
prompt submission or any tool call. After model selection, the product-mode proof
was invalidated with `mutation_uninspectable`. The recorded batch contained four
child-list mutations and one character-data mutation outside the tracked product,
composer and message scopes. No Work selection was recorded. Website cleanup
remained unconfirmed and the failed attempt was preserved without replay.
The mode switch may disappear after the owned temporary-chat transition; its
absence alone did not revoke the previously established proof.

The mutation validator accepted text-node character-data changes but rejected
comment-node changes, which also produce character-data records under the
[DOM Standard](https://dom.spec.whatwg.org/#interface-mutationrecord). A controlled reproduction
on the unchanged build-305 adapter produces the same finite failure signature.
The live diagnostics did not retain the target node type, so the reproduction
identifies a concrete matching defect without proving that the live node was a
comment. The correction admits valid comment records into the existing bounded
product-history analysis; it does not ignore the batch or reset product proof.
Two allowlisted diagnostic fields identify the first failed inspection rule and
node kind. They contain no page text or node references and cannot authorize a
request. Unknown values and incomplete diagnostic pairs are rejected.

The updated adapter suite passes 515 tests (24,266 assertions). Twelve focused
native product-mode and diagnostic tests pass. A real WebKit observer delivers
the five-record comment batch: the same compiled regression fails with the
immutable build-305 adapter and passes with the correction, then completes one
request and cleanup. Mixed transient Work and referenced-label changes remain
rejected before Send. These tests do not establish external email delivery.

## Diagnostics and limits

Completion-observer preparation and user-count rejection diagnostics retain only
bounded enumerated states, counts and booleans. They are stripped from provider
observations before inference-state processing and cannot authorize acceptance,
retry or input. The original provider's empty-response cause remains unproven;
later fixture success cannot reconstruct its closed response stream. A separate
user-count rejection also remains causally unresolved.

The website transport still stops at its complete-prompt byte limit and existing
inference limit. Website responses do not report token usage, so the engine's
usage-driven compaction does not reliably measure cumulative website history.
This investigation does not raise those limits or silently discard tool evidence.

## Reproduction and verification

`Tests/Fixtures/minimized_browser_mailbox.py` uses the existing loopback mailbox
server and `.invalid` recipient restriction. Its 5,001-row inbox precedes a
12-wrapper-deep named compose panel. Compose opens the minimized panel; Maximize
leaves it unchanged; Full screen reveals a draft form without autofocus.

Use a fresh task, ChatGPT Chat / Instant, and a unique synthetic recipient and
subject. Ask only to open the fixture and save a draft, explicitly without sending.
Success requires one exact draft ledger entry, zero sends, the new receipt read
through browser tools, a faithful final answer, current action references, verified
provider/model selection and confirmed task/session cleanup. A completed tool
call or automatic cleanup alone does not prove the draft was saved.

Private mailbox contents and authenticated URLs stay outside the repository.
Real-mail qualification additionally requires the exact recipient and body in a
new Sent message. Preserve uncertain outcomes and never replay a send to obtain
a cleaner test result.

Focused validation for build 304: 162 native instruction/broker tests passed.
The production compact post-fill envelope retains the panel context, three short
fields, submit control and a readable sample on its first page. Pagination tests
reconstruct every label/value/URL from contiguous UTF-8 fragments and preserve
all selected nodes. Separate cases cover ambiguous ancestry, navigation, large
containers, disabled controls, passive-container input rejection, explicit
filters, and missing/duplicate readable-sample IDs. These are deterministic
transport checks; live workflow qualification is recorded separately.
