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
