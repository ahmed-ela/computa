# ChatGPT Instant preparation

The first Instant request previously performed a separate `sendReady` action
after insertion had already checked the exact editor text and enabled Send,
then completed the native model → product verification chain. Two fresh traces
measured that additional action at 104 ms and 108 ms. These are inclusive action
spans, not independent additive CPU costs. Both requests subsequently failed
first-message ownership; neither is a successful end-to-end latency sample.

The optimized path adds an optional readiness observation to insertion's
existing terminal product read. A call-local typed receipt is bound to the
session, web view, document generation, URL, Instant choice and exact prepared
submission. It is consumed only after the outer insertion and its verification
chain return successfully. It checks both raw editor equality and the existing
canonical submission identity. Missing, false or malformed observations retain
the original bounded, event-driven readiness loop. Retained rounds and other
models retain their existing path.

The final submit still independently verifies the model, product, temporary
mode, owned request, editor and enabled Send, and claims a single click. No
positive proof is cached across requests. Prompt, tool schemas, permissions,
response stability and cleanup admission are unchanged.

## Temporary Chat UI discovered during profiling

The first fresh build-168 baseline and the diagnostic-only build-169 request
both stopped before releasing a response: the website clipped the rendered
first message at 10,240 characters of the 51,657-character outbound body. Its
scoped expansion control was present, but expansion was refused because the
current physical Temporary indicator was not recognized. Both failures and
unconfirmed cleanup receipts remain retained; the prompts were not replayed.

A separate controlled normal-browser Temporary Chat returned `HI`. Its completed
page had neither the old off button nor Save button. It instead rendered the
observed dashed SVG outline as a direct child of the user bubble, with
`temporary-chat=true` still present in the URL. The owned direct tab was closed
and Safari's developer setting was restored to off. This was a UI diagnostic,
not a matched-payload benchmark.

The additive recognizer checks that specific physical SVG/rect structure,
placement, visibility and current owned body. It additionally requires the
already acknowledged owner/document-bound Temporary transition and exact
submitted-message pins. A clipped first body must match the prepared prefix;
binding still requires expansion and the complete rendered digest. Retained
reads require the existing complete first-message and current submission
proofs. A URL, private latch or outline alone cannot establish ownership.
The old off/Save paths retain their behavior. Unproven replacement shapes in
the new outline path are rejected.

## Measurement boundaries

The first build-170 matched request returned `HI` with confirmed owned-session
closure, but still took 1.545 seconds from the UI click to actual website Send.
It fell back to the separate readiness chain (113 ms). A second matched
pre-Send geometry observation found one enabled editor with a 51,012-pixel
height inside a 665-pixel viewport, with its center outside its clipping
ancestor. The single enabled Send button remained exposed and hit-testable.
The optional receipt had added an editor-center hit test that the existing
readiness and submit paths did not require. Build 171 removes only that extra
editor-center condition. It retains unique visible enabled controls, exposed
Send, exact raw and canonical body equality, the complete verification chain,
call-local receipt binding, fallback and independent submit checks.

All three build-171 native runs used the shortcut, but pre-Send times were
1.399, 2.585 and 2.553 seconds. The two slower requests adopted roots only
2.070 and 2.100 seconds old and waited 1.181 and 1.007 seconds for their first
product callback; the mature 18.326-second-old root waited 27 ms. Setup after
that callback was similar. The two-minute expiry had discarded the hydrated
standby during normal pauses, including the manual direct comparison.
Build 172 keeps the single unused, prompt-free root for ten minutes. It does
not refresh on a timer or add website traffic. Cookie validation, physical
page/generation/route checks, claim deadlines, fresh model/product/readiness
proofs and expiration/disable/shutdown cleanup are unchanged. Cold hydration
remains a real wait. The age diagnostic now covers the full bounded lifetime.

Build 172's second request was a counterexample to expiry as the sole cause:
only 256 seconds had passed since the preceding refill, but the adopted root
was again two seconds old. Opening a new draft uses the user's configured
default model. When that default is local Qwen, the draft transition disabled
prewarming and discarded the preceding blank page before Instant was selected
again. The two attempted native samples and direct controls remain retained;
the third planned pair was not run after this cause was identified.

The follow-up distinguishes that new-draft transition from hard revocation.
It pauses creation and adoption while preserving only the already existing,
bounded, unused page. Selecting ChatGPT again resumes the existing validation
path. Explicit provider changes, discovery refresh, provider blocking, expiry
and shutdown still discard the unused page. The user's default model is not
changed, and no transport session, prompt or conversation is preserved.

Compare the same full captured payload, model and turn through Computa and the
normal built-in browser. Keep failed attempts, first samples and incomplete
arms explicit. Distinguish native action spans, page performance clocks and
host UI timestamps. The end-to-end difference also includes website response
variation, response representation, stability and cleanup; it is not pure app
overhead. Installed benchmark results are recorded separately after execution.

## Offline validation of build 170

All nine focused native cases and 377 ChatGPT adapter cases passed. The broader
526-case native cohort initially passed 501 cases and explicitly skipped one
opt-in microbenchmark; 24 runtime fixture cases failed because the test runner
omitted `MACTOPUS_TEST_BUN`. Those exact 24 cases passed after supplying the
existing pinned Bun executable, with identical source inputs. The final union
is 525 unique passing cases, one explicit skip and no unresolved failures.
The original failed run is retained. An earlier compilation also stopped for
disk exhaustion and establishes no test result; obsolete products were
archived with verified file inventories and regenerable caches were cleared.

The build-171 follow-up passed all ten focused native cases, including a real
WebKit long-editor clipping regression, and all 377 adapter cases. The
regression proves an actual positive readiness receipt, no separate readiness
RPC, one insertion and one Send, verified completion and retained human tabs.
Existing malformed-receipt, delayed-enable, raw-text, disabled-Send,
cancellation and document-generation checks remain covered.

Build 172 passed 41 focused native tests covering cookie seeding/adoption,
expiry, cancellation, generation changes, exact readiness and Temporary
ownership. The build-171 run of 377 adapter cases is carried forward only
after checking that both the adapter and its test source are byte-identical.

Build 173 passed 62 focused native cases, including the actual new-draft
prewarm policy, physical-view retention/resume, no creation or adoption while
paused, cookie changes, in-flight seeding/claims, expiry and hard revocation.
Default-model persistence and active-turn model guards also passed. The
adapter and adapter-test bytes remain unchanged from the 377-case run.
