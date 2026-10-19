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

The build-173 follow-up preserved a 510-second-old page through New Task, but
fresh claim validation refused it and the request fell back to a cold page
(4.372 seconds before Send). No physical-identity failure was logged. Cookie
changes in the shared profile are a leading explanation, not a confirmed
diagnosis of that particular miss. Both native requests completed with owned
cleanup; one direct control completed, a second unsent control was closed, and
the remaining planned samples were not run.

Build 174 adds a read-only cookie check when an existing unused page resumes.
A mismatch may replace that page before the user submits. This is triggered
only by the explicit resume, with the existing admission and capacity limits;
it is not a periodic refresh. A matching preflight never authorizes adoption:
the independent fresh claim-time cookie read remains mandatory. Cancellation,
expiry, pause, disable and shutdown cannot revive the page or refill it from a
late callback. Outstanding callbacks retain their capacity reservation until
drained. Diagnostics record only the finite phase and outcome, without cookie
names or values.

The fresh build-174 comparison prespecifies three native samples followed by
three direct controls using each native request's exact captured payload.
This avoids direct controls changing shared-profile cookies before the next
native sample. It is a blocked comparison, not an interleaved experiment; the
ordering limitation remains explicit when reporting its results.

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

Build 174 passed all 66 focused native cases, including resume preflight,
post-preflight cookie drift, replacement, superseded reads and outstanding
callback capacity. The first compile rejected an unannotated local closure
under Swift 6; adding its explicit main-actor/sendable type resolved it. The
failed compile is retained separately from the successful run. Adapter and
adapter-test bytes are still identical to the 377-case build-171 execution.

## Installed build-174 result

Signed Computa 0.7.0 (174), source
`3a2422889d9956ffe998638c2ac7ea04445749cd`, passed the independent build,
signature, installation and complete 55-file/51-resource checks. The engine
and adapter resources remain unchanged; Gemini diagnostics are off. This is a
local signed test installation, not a notarized release or published tag.

All three native samples sent the full 51,657-byte payload and returned `HI`
with confirmed owned-session closure. The first postlaunch sample is included.

| Sample | UI click to page Send | UI click to native completion | Warm age |
| --- | ---: | ---: | ---: |
| C1 | 1.452 s | 9.357 s | 45.557 s |
| C2 | 1.378 s | 11.677 s | 42.328 s |
| C3 | 1.362 s | 8.117 s | 29.474 s |
| Mean | 1.397 s | 9.717 s | |

The pre-Send median is 1.378 seconds. Against the older build-168 estimate of
1.459 seconds, the observed mean difference is 62 ms (4.2%). This small,
nonconcurrent, blocked comparison does not establish a causal speedup.
End-to-end time did not improve against that older 8.244-second mean.

Fresh resume and claim-time cookie checks matched in all three requests. All
adopted their prepared pages, with no opening recovery or separate SendReady
action. Mean warm-hit to payload capture was 695 ms, including 44 ms to the
first product callback and 652 ms afterward. Capture to insert-chain completion
was 476 ms; the actual editor mutation took 14–16 ms. The native claim to page
Send interval averaged 54 ms. These spans include browser scheduling, model and
product verification, and other preparation; not every gap is independently
attributed or proven necessary. They are not additive JavaScript CPU profiles.

Three exact-payload direct controls completed and their owned tabs closed.
Two pairs passed the unchanged strict response-format checks. D3 returned a
43-byte inline fenced response and remains excluded; it was not replayed and
the parser was not relaxed. In the two eligible pairs, page Send to first
completion candidate averaged 6.907 seconds through Computa and 3.371 seconds
directly. That after-Send gap remains unexplained by this pre-Send change;
different response representations and fixed block/time effects remain. No
three-pair qualification or pure app-overhead claim is made.

Candidate to native completion averaged 2.247 seconds across the three native
samples under the same host-clock assumption. The native-clock candidate to
quiet-deadline span averaged 1.768 seconds, including the unchanged stability
guard; final full inspection averaged 159 ms. Server-clock cleanup persistence
averaged 100 ms. These clocks and nested spans must not be summed as separate
nonoverlapping overhead buckets.

One unsent direct-control model-proof read hit the operator's 30-second tool
timeout. The same tab recovered with zero sends/users/assistants, then passed
the complete checks and was sent once. Its setup artifact is retained. A first
collection-preparation attempt incorrectly treated host click dispatch return
as a page acknowledgement: the actual page Send followed it by 3–5 ms. A
separately reviewed measurement-boundary correction retains the original
markers/error, uses the actual after-model observation and closure as upper
bounds, and adds no timing tolerance. All original payload/model/response/
source/cleanup checks remain unchanged. UI/page/native clocks are distinct;
cross-clock estimates use an explicitly uncalibrated same-host assumption.

Two fresh V79 code/terminal/browser workflows passed all twelve checks each:
20 successful tool calls, 22 saved-and-closed website inferences and zero
failed inferences within the completed turns. Independent execution passed
eight unit tests and both helper outputs. Only the allowed helper changed;
tests, seeds, references and the unrelated note were preserved. The model
closed both created browser tabs. The fixture server was stopped and reaped,
its PID was absent and its port refused connections. Safari's temporary
developer setting was restored off. Gemini and Claude live work remains halted.

The retained content-free evidence hashes are:

- Focused native test log: `1e107cc218be9f1eb2ce784481f346f1062e4ce775e1688811f687db946b05f0`.
- Native pre-Send report: `4a2b466505ac25a709bd0340f28f843f58155cfc28e5b96d812fc35bc894f560`.
- All-six-attempt matched report, including D3 exclusion: `3699c7031e50e9732665cf7702533eb26263f131a44b21b0da04a598089ecbfb`.
- V79 workflow report: `550e3e51948c44b516e6d8eb8656f7d8bc06640ba7af7a4c1ecf0babcbfca6e0`.

## After-Send follow-up

The eligible build-174 pairs place 3.229 seconds of their 3.536-second page
candidate gap before first DOM response text. Native detection adds only
approximately 52–196 ms after the page candidate; it cannot explain that
earlier gap. Separate resource diagnostics place C1/C3 DOM text approximately
1.186/1.702 seconds after an ended conversation resource. These are untrusted
page observations with adjacent but different Send marks, not proof of stream
decoding, first-byte or rendering causality. C2 has no retained conversation
entry and remains inconclusive.

One mismatch in the earlier comparison is being tested explicitly: native
ownership verification expands the clipped 51 KB user body during generation,
while direct controls expanded it after completion. The experiment keeps the
same full captured payload, model and passive observer in both conditions,
with prespecified late/early/early/late order. It records finite page clocks,
visibility and resource timings. It grants no native ownership authority.

The production follow-up removes a separate deferred inspection immediately
before the already-required full completion inspection. A strictly bounded,
call-local candidate body/count precheck keeps the picker closed when text,
busy state or footer changes. Only the same candidate with a new full positive
model/product/body/ownership proof can complete. Changed candidates return to
the existing pending path and rearm the unchanged 1.6-second quiet interval.
No positive proof survives into a later poll, and deadlines remain unchanged.

The completed build-174 direct-profile crossover observed first text at
3.603/3.522/3.443/4.369 seconds (late/early/early/late). Both early runs expanded
once before first text, without scrolling; both late runs expanded once through
the normal UI after the candidate. Full payload, normal Chat/Instant/temporary
mode and owned-tab cleanup were verified in every run. This small experiment
does not reproduce a multi-second penalty from early expansion; it is not a
provider qualification or proof of rendering causality. One diagnostic install
syntax error and one first-load readiness observation were retained before any
Send and repaired in their same unsent tabs; no provider request was replayed.

The build-175 source passed 77 focused behavior tests, three resource-timing
tests and 382 adapter tests. The final source review found no material blockers.
Its passive Resource Timing v2 records nullable request/header/end offsets from
the existing owned Send mark, preserving the v1 parser, finite allowlist, four
rows, 256-entry scan and 2 KiB limit. It neither intercepts fetch nor records URLs,
request bodies or cookies. Missing entries remain inconclusive. Installed
build-175 measurements and fresh tool workflows are still required.


The installed build-175 native samples reduced the comparable last-wake to
full-proof-start gap from 83.667 ms to 0.667 ms. This includes queue/processing
time, not an exclusive JavaScript CPU measurement. Candidate-to-transport
completion averaged 1.927 seconds before and 1.987 seconds after; the new first
sample changed its response and correctly restarted stability. Overall tail
improvement is not established. The current three page candidates averaged
5.992 seconds after Send. Both pre-header wait and post-resource DOM delay
remain, and native window occlusion was not previously logged.

A separate build-176 experiment applies the public
[`WKPreferences.inactiveSchedulingPolicy`](https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.property)
`.none` policy only to model-owned configurations before construction. Human
and tool tabs retain their platform defaults. WebKit's
[implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKPreferences.mm#L169-L194)
changes background process assertions; its
[macOS visibility checks](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/PageClientImplMac.mm#L196-L246)
include whole-window occlusion, rather than opaque-sibling pixel coverage.
This is an unproven scheduling hypothesis; it does not disable every WebCore
timer policy. Three bounded native lifecycle snapshots per inference round
will expose attachment, hidden state, window visibility and occlusion without
recording page content or authorizing any action. Fresh installed measurements
are required before attributing a latency change to this policy.

The scheduling candidate passed eleven focused configuration, diagnostic and
completion-verification tests. Adapter bytes are unchanged from the 382-test
build-175 result; installed scheduling measurements remain pending.
