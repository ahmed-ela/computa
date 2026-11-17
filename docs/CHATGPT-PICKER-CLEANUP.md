# ChatGPT prepared picker recovery and unsent cleanup

## Cause

The Instant fast path obtained editor readiness during the final product-mode
read and skipped the separate `sendReady` action. That saved a round trip but
also skipped `sendReady`'s recording of the exact, already verified insertion.
Submit therefore could not use the existing bounded recovery when the first
model-picker opening received no acknowledgement. Saved build-570 diagnostics
show a submit precheck with `primaryOpened:true`, no menu, an intact selection
pin, and `recoveryEligible:false`.

Native code claims Send intent before dispatch so cancellation or a lost
callback cannot cause replay. If the page rejected the model precheck, that
native intent existed but the private page had never claimed Send. Cleanup
unconditionally waited for a first user message that could not arrive.

## Change

Both readiness paths now record the same exact editor, full raw draft, marker
and prepared insertion proof. Submit still performs the full selected-family
and power proof, product and temporary-mode checks, same-editor check, and
one-time Send claim. Recovery remains bounded to one additional reversible
picker opening within the existing deadline; no input or Send is replayed.

Cleanup can request a fresh private-world proof only for the first native Send
intent with no acknowledgement, no observed messages, and the current owned
view/document/root route. The page must still be temporary, contain the exact
original physical editor and canonical draft fingerprint, and retain a
`prepared` record with no page Send claim. This proof authorizes disposal only;
it does not establish first-message ownership, resume a task, or reset Send.
Changed drafts, editor replacement, fingerprint or route changes, foreign
messages, lost temporary mode, and ambiguous claimed Sends retain failed
cleanup. Prior unconfirmed receipts are not retroactively rewritten.

## Validation

Build 571 source validation: all 650 ChatGPT adapter tests pass (43,823
assertions). Fourteen existing native regression tests passed unchanged; the
three new/updated native tests passed after correcting their cleanup expectations.
The ten-case native fixture reproduces the former missing-readiness failure,
recovers one ignored opening with exactly one insertion/Send, closes a verified
never-sent draft, and retains seven altered or ambiguous cases. Existing tests
retain cancellation, generation, exact-draft, delayed readiness, model drift,
unbound-message and cleanup-expansion barriers.

Installed-app review qualification is pending. Local evidence: `work/picker-cleanup-20261117/`.

### Installed build 571 reproduction

The same Instant review made ten terminal tool calls and one compaction in
134.555 seconds. Eleven inference responses completed with verified GPT-6 /
Instant selection and Chat product evidence. The twelfth stopped at the submit
picker precheck. Unlike build 570, its diagnostic reports recovery eligible;
another guard rejects recovery after the acknowledgement wait. All twelve
sessions, including the unsent failed inference, have saved confirmed closure
receipts. No failed prompt was replayed. The source review remains incomplete.

Build 572 adds finite rejection diagnostics for this remaining case: draft
mutation category, acknowledgement sources, popup lifecycle, clock rejection
and whether the single recovery was claimed. It changes no verification policy.

### Build 572 reproduction and pre-input recovery

The next controlled review completed three tool calls before the first Instant
insertion's model precheck failed: the picker stayed closed and that phase had
no recovery allowance. The optimized insertion already creates its private
prepared submission record before this check, so the existing empty-editor
recovery (which requires no submission state) did not apply.

Build 573 gives that first Instant precheck its own single empty-editor opening
slot. It binds the exact private prepared record, prompt, fingerprint and marker
as well as the original physical editor, selected model, route, owner and mode.
The existing deadline and fresh full model proof remain mandatory. It cannot
repeat input or Send. Tests cover ignored and acknowledged-but-closed openings,
changed/restored drafts, ownership/route/model/header drift, replaced or claimed
submission records, fingerprint/marker changes, deadline expiry, and a picker
that never opens. Installed review qualification remains pending.


### Build 573 live result

The exact review ran seven tool calls and compacted once in 88.047 seconds.
Eight inference responses verified GPT-6 / Instant in Chat mode. The following
post-insert `verifyModel` check failed before Send; all nine sessions closed
with saved cleanup receipts. Build 574 adds the existing finite draft and
acknowledgement diagnostics to that prepared-verification phase, without
changing its proof policy. The full review is still incomplete.


### Prepared model verification: reproduced cause

Build 574 completed the review across two user turns: 17 tool calls, four
compactions and 22 fully verified GPT-6 / Instant responses, all with saved
closed-session receipts. The first turn stopped at its unchanged 16-inference
budget; a bounded continuation produced the review. This establishes transport
completion, not independent validation of the model's review findings.

An independent repeat reproduced the remaining picker failure after seven tool
calls and one compaction. Diagnostic `92C68025-9C93-48FF-B559-3A68BF745C30`
shows the prepared `verifyModel` phase: intact draft and model pin, no clock
failure, and both a menu-descendant removal and an expanded-to-closed header
acknowledgement. Recovery was eligible but not claimed. That phase rejected any
opening acknowledgement; unlike readiness and Submit, it did not collect the
existing proof that the exact associated popup had opened and detached.

Build 575 shares that existing structural lifecycle proof with prepared Instant
verification. Recovery still requires reciprocal menu/header IDs, overlapping
association/expanded/mount intervals, the original body, editor and enabled Send,
no ambiguous menu or identity mutation, zero messages, exact native grant and
full draft, and the original deadline. One fresh opening must then prove both
family and power; the transient popup supplies no model evidence and no Send
authority. The ordinary post-proof draft/ownership checks and later native
Submit verification remain mandatory. Unassociated or aria-only signals,
changed drafts, invalid intervals, duplicate IDs and cancellation still refuse.
