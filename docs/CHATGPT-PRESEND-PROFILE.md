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

## ChatGPT after-send profiling — 2026-10-19

Completion now uses one fresh full answer/model proof after the owned response has stayed quiet, removing the immediately preceding deferred read. The 1.6-second stability interval, exact answer/body checks, model and normal-Chat/temporary-mode verification, route/generation guards, cancellation and cleanup checks remain in place. Passive resource timing adds finite request/response offsets without recording URLs, request bodies or response text.

The consistent native phase boundary, last quiet-wait wake to full-proof start, fell from **83.667ms** in build 174 to **0.667ms** in 175 and **0.333ms** in 176 recovery run 2. This measures about **83ms removed from that inclusive phase**, including queue/native work; it is not exclusive JavaScript CPU time. Across all three native requests per cohort, first candidate to transport completion averaged **1.927s → 1.987s → 1.996s**. Actual response changes that restarted stability checks remain included. These samples do not establish an overall completion-tail speedup. The `quietDeadlineReady` marker changed placement, so its absolute position is not a valid before/after comparison.

Each matched comparison used normal ChatGPT latest/Instant in a fresh temporary chat, the same captured **51,657-byte** whole payload within its pair, unchanged Probe5/Direct4 bindings, explicit model/mode verification and owned-tab closure. All three native requests preceded all three direct controls.

| Cohort | Eligible pairs | Native Send→first text | Direct Send→first text | Mean native minus direct |
| --- | ---: | ---: | ---: | ---: |
|175|2/3|5.946s|3.656s|+2.290s|
|176 recovery run 2|2/3|4.508s|4.077s|+0.431s|

175 D3 and 176 recovery D2 remain excluded by the strict response fence. The two eligible 176 differences were **+1.132s and −0.270s**. All attempts and exclusions are retained. Provider/session/time/order variation and output representation differences remain confounds; the lower observed gap is not proof that a particular browser setting caused an improvement.

The eligible request-start→response-start difference averaged **+1.303s** in 175 and **+0.186s** in 176 recovery. Approximate resource-end→first-text differences averaged **+0.942s** and **+0.466s**. Resource-internal intervals use each request's performance clock; resource-to-text residuals use distinct adjacent native/probe marks and the direct page-wall/performance reconstruction. They do not isolate decoding, rendering or pure application overhead. Missing entries remain unknown; no first decoded event was captured.

The model-view-only public `inactiveSchedulingPolicy = .none` experiment has **no established causal benefit**. All sampled 176 native views were attached, visible and unoccluded; native `document.hasFocus()` was not measured. A separate one-send direct focus diagnostic retained focus despite the attempted Task-prompt click. Its footer appeared empty at 3215ms and real text at 3310ms, with `hasFocus=true` throughout the recorded stages. The focus manipulation was not achieved, so the planned second control was not run and no focus comparison is valid.

The original 176 cohort stopped when the local **256-task receipt capacity** prevented evidence persistence. C2's website response was withheld, and its cleanup receipt could not initially be saved. Reversible archival of old owned benchmark receipts and a persist-only cleanup retry restored headroom; this was an operational recovery, **not a source-level capacity fix**. Its failed attempts remain separate from fresh 176 recovery measurements.

The earlier late/early/early/late clipped-user expansion crossover observed first text at 3.603/3.522/3.443/4.369 seconds. Both early expansions occurred before first text without scrolling. All four exact-payload/model/temporary/cleanup checks passed, but response representations varied. This did not reproduce a multi-second early-expansion penalty and cannot establish rendering causality. Its unsent install/readiness errors remain retained.

The model-only scheduling policy uses Apple's public [inactiveSchedulingPolicy](https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.property). WebKit's [implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKPreferences.mm#L169-L194) changes background process assertions. Its [macOS visibility checks](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/PageClientImplMac.mm#L196-L246) include whole-window occlusion; the setting does not disable every timer policy. Human/tool views retain platform defaults. Three finite content-free native lifecycle observations per round log attachment, visibility and occlusion; they grant no page authority.

Build 175 passed 77 focused native behavior cases, three resource-timing cases and 382 adapter tests. Build 176 reran eleven targeted configuration, diagnostic and completion tests. Adapter/test bytes remained unchanged from the 382-pass execution. These are separate scoped runs, not an all-suite claim. Signed Computa 0.7.0 (176), executable source `1acbd9cb7544aeeba289bfd13634fb80d3c97710`, passed independent build/signature/install checks for all 55 bundle files and 51 resources, with the engine preserved and Gemini diagnostics off.

The extra diagnostic tab was closed and Safari's temporary developer setting was restored to off. This is a local signed test installation, with no release tag, notarization or publication. Gemini and Claude live work remains halted.

Two fresh V81 tool workflows produced mixed results. The first visibly completed the code repair, four tests, helper output and exact browser receipt, and issued its own `browser_close`. The second successfully edited the file, ran commands and submitted the accepted browser lookup, but its next website inference timed out at the existing five-minute deadline. App cleanup closed its task-created browser tab; that is not a model-issued close or a verified final answer. Both owned website sessions closed.

Independent CLI verification passed all eight tests, both helper outputs and both allowed-file/protected-note checks. The prescribed one-shot workflow extractor returned a generic failure and produced no grading input. It was not retried or relaxed; the twelve-check grader was not run. The first observed completion and the second failed workflow are not promoted to two qualified passes. The loopback server was stopped/reaped, its PID was absent and its port refused connections.

Separate finite stall/terminal captures show the failed inference was submitted with 71,135 UTF-8 bytes but had no first-positive observation. The cached last admitted inspection retained one verified user, an assistant scope with zero text, no active generation and no recognized notice; its age was not recorded. The bounded fresh failure diagnostic also ran and found a visible assistant, no Stop/Retry control and no alert. It did not measure assistant text length. This occurred before the completion consolidation path could run. An upstream empty response versus a recognition/scoping issue remains unresolved. No provider replay was performed. Overall website reliability remains unresolved; the safe phase optimization and completed benchmark do not establish a general tool-workflow reliability guarantee.

### Retained evidence

Paths below are relative to the off-repo `instant-aftersend-20261019-v1` evidence folder.

| Artifact | SHA256 |
| --- | --- |
|`optimized175-matched-block-report1.json`|`4ad9412b4bc2fe21f22b22abb70066263bc13700d6cd0eb825572d08d58d4fb5`|
|`optimized175-after-send-decomposition3.json`|`b0650c994ad2d957f5e461830eb7d468a9163e287de3bad612cb1c2da838abe3`|
|`optimized176r2-matched-block-report2.json`|`d30fbbd8144d192f4e32bd81821d7fbefdabb5267296b5f36e690ed40dac3d22`|
|`optimized176r2-after-send-decomposition4.json`|`2dbf9e3808664f46cba1201a9be220f2078d3054e423dc569da54f41885cdfb1`|
|`direct-focus-diagnostic-outcome1.json`|`6d91ccbc5facffb5bf8aa7aa6dd5eddfc70f81f8674e8bbd1cc5353675c38360`|
|`optimized176r2-d1-focusblur1-focus-result1.json`|`348793ea17d2e367ae7215e01cadc7ef2d0de24aed01b81b2b876d3c10bc0618`|
|`safari-restored-final176-1.json`|`83f37b88b45e94b58cb8641ad492874325a080f92134205771fde718d637983c`|
|`optimized176-fixtures-observed-outcomes1.json`|`a921796aa37af6a51d2bea1a6e5aaeece509beacec8761c411d46d026db6b658`|
|`candidate176-run/fixture-extractor-execution1.json`|`6f366a245429c85b8701c324b91ea6b1185d3af1ed6c7e53d0195c70e5b83799`|
|`candidate176-run/fixture2-terminal-native-log1.json`|`7b15f2a19e5cea284d3c74be87a83f1efa3c8dd440444c4be3cb960cde7ea1de`|
|`candidate176-run/fixture2-failure-classification2.json`|`947d41d83b586b63455d623d74d276079244ce5895da41c18f7680d9dce86cae`|

## Build-177 observation follow-up

The response notifier now observes the stable Document rather than its replaceable HTML child. The previous registration could miss both HTML replacement and later text mutations in the new subtree. The callback, current-owner/origin/frame checks, picker-noise filtering and native coalescing are unchanged. A notification only requests a new guarded read; it grants no response or model authority. This is a demonstrated latent observation bug, not a proven explanation of the V81 timeout.

The source passed 387 adapter tests and eleven focused native completion tests, including exact modern-only empty-answer and late-text cases. Empty text cannot publish, restart Send or extend the original deadline. Text that appears later must start its own quiet interval and pass the full proof. Both test runs retained unchanged source hashes.

A corrected one-send focus diagnostic physically moved native keyboard focus to Task prompt, verified by native accessibility. The page still reported focus at Send and first text, with no blur event. Its first text appeared at 3.629 seconds; full payload/model checks and owned-tab closure passed. The page-focus manipulation remained unachieved, so the second planned control was not sent. Safari's developer setting was restored off. This result provides no causal focus comparison.

Build-177 installation, fresh matched measurements and V82 workflow results are still required. The failed V81 workflow and generic extractor failure remain retained; the latter is not attributed to a particular guard. Future fixtures use literal GUI paste and record the actual submitted prompt. Their runtime boundary must precede draft creation as well as Send.

- Build-177 adapter test log: `981ee26fd807257f5a07dbb1f307e33762a0109a8e47a8710b5338b231e27103`.
- Build-177 native test log: `05d8e7626d56399c740e05c23c77d6ad063195882c12a2b366fc572fa8cc4a3f`.
