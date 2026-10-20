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

Build 177 was built and independently audited but not installed. Build 178 carries this change plus the timer precision fix below; actual matched measurements and mixed V83 workflow results are recorded below. The failed V81 workflow and generic extractor failure remain retained; the latter is not attributed to a particular guard. Future fixtures use literal GUI paste and record the actual submitted prompt. Their runtime boundary must precede draft creation as well as Send.

- Build-177 adapter test log: `981ee26fd807257f5a07dbb1f307e33762a0109a8e47a8710b5338b231e27103`.
- Build-177 native test log: `05d8e7626d56399c740e05c23c77d6ad063195882c12a2b366fc572fa8cc4a3f`.

## Build-178 deadline precision experiment

The native change channel used Swift's default sleep tolerance for an already chosen absolute deadline. The clock can add scheduling leeway after that deadline. In an eight-run counterbalanced probe derived from the actual channel source, the four default-tolerance 1.6-second waits completed in 1698.304–1704.804ms; the four zero-tolerance waits took 1603.375–1608.127ms. This isolates roughly 97ms of avoidable timer leeway in that controlled probe, not end-to-end provider latency.

The channel now requests `tolerance: .zero`. It retains the full absolute deadline and 1.6-second response stability requirement, and does not alter the 100ms DOM notification batch, ownership/model checks or cleanup. A timer wake returns the same revision; only a real page change increments it. A regression covers deadline-only wakes, expired deadlines, subsequent real signals and cancellation without inventing a change or consuming another waiter. Zero tolerance is a request to the scheduler, not a guarantee of immediate actor execution.

Swift documents nil tolerance as clock-chosen leeway in [Clock](https://github.com/swiftlang/swift/blob/main/stdlib/public/Concurrency/Clock.swift) and [the clock proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0329-clock-instant-duration.md). This changes existing one-shot deadline waits; it adds no periodic background timer. Build 178 passed seventeen focused native channel/completion tests with unchanged source hashes. The unchanged adapter and adapter-test bytes retain the separate build-177 result of 387 passing cases. The actual installed-build measurements and workflow outcomes follow below.

- Build-178 native test log: `c18c7032203e16bc271f9c228564ffbe04af61cc3b72e042810dd45654815023`.

### Installed build-178 results

Signed Computa 0.7.0 (178), executable source `a692b96a5f7ec1327934d7e94948e4ec7e860f3b`, passed independent signed build/install checks for all 55 bundle files and 51 resources. The actual installed baseline was 176; the built/audited 177 artifact was never installed. The engine was preserved and Gemini diagnostics remained off. This is a controlled signed test installation, with no merge, release tag, notarization or release publication.

All three fresh normal Chat/latest Instant/Temporary matched pairs passed the unchanged strict reader. Each pair used the exact captured 51,657-byte whole payload and one user/assistant turn. Fixed order was C1,C2,C3,D1,D2,D3, and every owned session/tab closed. Send-to-first-text averaged **4.831s through Computa versus 3.390s direct** (+1.441s; paired differences 1.273–1.634s). Send-to-first-completed-answer candidate averaged **4.832s versus 3.612s** (+1.220s). Two output representations differed; the canonical-output-equal third pair still had a 1.634s first-text gap. Small sample, order, website variation, representation and distinct diagnostic anchors prevent a pure-integration-overhead claim.

The same-position last observed candidate-arm to quiet-entry phase fell from **1705.333ms in 176 recovery to 1601.667ms in 178**, a **103.667ms** saving, consistent with the controlled timer probe. The intentional 1600ms guard remains. The earlier redundant-read phase remains removed (83.667ms in 174 versus 0.333ms in 178, inclusive queue/native span). Full proof averaged 183ms. Across all three native requests, first candidate to transport completion averaged **1.996s before versus 1.991s now**; two observed response changes added about 310/308ms of stability rearming in 178. There is no established overall completion-tail speedup from these cohorts.

Public request-to-response-start intervals averaged 1.485s native versus 1.241s direct (+245ms). Approximate ended-resource-to-first-text residuals averaged 1.638s versus 0.298s (+1.340s). These residuals do not isolate rendering, decoded first-token arrival or application CPU; direct D3 text preceded resource end by 256ms. A compositor/focus/WebKit cause for the remaining body-observation gap has not been established. Native/server epochs and nested durable-cleanup spans remain separate.

The one-shot V83 extractor passed with both exact actual submitted prompts, including literal ASCII apostrophes; no quote normalization or matching relaxation was used. R1 passed all twelve workflow checks: code patch, four tests, helper output, exact browser form submission/result and model-issued close. R2 passed its code/tests/helper portion but ended with an unsupported claim that the local browser relay was unavailable, without attempting a browser tool. It failed the six browser/result checks. This is a failed workflow, not a browser-tool dispatch error or a qualified second pass. All sixteen website inferences across the two workflows completed and saved closed, with normal Instant proofs; zero provider errors do not establish task success.

Independent CLI verification passed all eight tests, both exact helper outputs, allowed helper-only diffs and protected/test/seed/reference checks. It does not repair R2's missing browser work. The loopback server was stopped and reaped, its PID was absent and port refused connections. Safari's temporary developer setting was restored off, and no owned human/tool tabs remained. Gemini/Claude live work remains halted. The V81 timeout, V83 capability refusal and dominant body-observation delay remain unresolved. The goal remains active while these causes are investigated.

The bounded collection was performed once and reused for artifact-only decomposition. A preexecution diagnostic reader review caught its rounded-second log-boundary assumption; v2 preserves the original rows and filters the exact runtime window like the strict reader. V1 was not invoked. The analyzer, eligibility, model, response, ownership and cleanup gates were unchanged. An abbreviated commit preflight, an incorrect unsent textarea AX assertion, and refused dynamic orchestration definition were retained as operator/setup errors, with no duplicate provider Send. Long fixture AX text was truncated; literal paste plus exact native-rollout matching supplies submitted-prompt proof.

| Artifact | SHA256 |
| --- | --- |
|`native178-prep/api178-metadata-installed-verification1.json`|`43152f98816d345c7e459b899717576954ad10286ff39b91dbd3b1d2583adb7b`|
|`optimized178-matched-block-report1.json`|`28c7c6286285cd458d87ac01195bb9388a930d4b683d994f5d7603ecce1e08fc`|
|`optimized178-native-after-send-profile2.json`|`4140db35b4b05c09bfe811f531d3ec337ca0527af05bd93ad0324cc8e9270da2`|
|`optimized178-after-send-decomposition1.json`|`bbb6011019c76d8bff413b25aeede27a56348ff4db4f4807fa2836023b040826`|
|`optimized178-fixtures-extraction1.json`|`9e88d2af5d6506e4627b2f720c63b3988606ff14ce5911da8c6151d4066d2e65`|
|`optimized178-fixtures1.json`|`183c3fcecfe14237b70ac14a31501ea7190a39b10d40f3da969461ab1ee8790a`|
|`candidate178-run/fixture-server-stopped1.json`|`8a858ce929d25455ad0f7467b12a5110ec3857d61f1a064fb0a2513cd8125c02`|

## Build-179 bounded observation diagnostic

Build 179 adds a synthetic-benchmark-only observation diagnostic to investigate the remaining resource-end to first-text residual. It records bounded raw text-count, scheduling and script-resource timing metadata without response text or URLs. The optional record is removed before ordinary observation validation; it grants no inference authority and changes no completion, ownership, permission or cleanup decision. Probe5 remains byte-identical. The diagnostic installs through the existing armed insertion RPC and performs no scheduled measurement work before the observed Send.

The frozen source passed **393 adapter tests** (13,542 assertions) and **44 focused native tests**, including four sanitizer cases, seventeen channel/completion cases, seventeen benchmark-capture cases and six dispatch-profile cases. Both runs verified unchanged source hashes. The regenerated native project also registers the two existing capture/profile test files already included by the authoritative project specification. These are scoped results, not an all-suite claim.

A fresh signed build and one explicitly diagnostic same-payload normal Chat/latest Instant/Temporary native/direct pair are pending. This diagnostic is not itself a latency optimization or a provider qualification. The dominant observation-delay cause and goal remain unresolved.

- Source test freeze: `bf5576e6e18d5cd729a3af8d9f201ee3f501b1818175fac1d8a9659bc8d7163f`.
- Adapter test log: `be16caf3b3d6afd1ee0a4c0e19d8e659a95204fcc6a7f8b2ec116be3e3b38879`.
- Focused native test log: `3a1f5373517678c0dc8930bb694808684daa8a91bb05fea35da046a0fd6f91f3`.

### Installed build-179 diagnostic result

Signed 0.7.0 (179), executable source `f2157f5cee710f66a887642c49ac6393638ee702`, passed the independent 56-file/52-resource installed check. The prespecified C1 then D1 diagnostic pair passed every original per-arm payload/model/Temporary/response/owned-cleanup check, with no exclusions. Both used the exact 51,657-byte input and returned the same ordinary two-byte canonical HI. This is one diagnostic pair, not a three-pair qualification.

Probe5 first text was **4527ms native versus 3689ms direct** (+838ms). Auxiliary raw text appeared at **4528ms versus 3689ms**, showing the delay was already present before raw response text became available; a large delay solely from native polling of already-present text does not explain this arm. The modern body appeared at 2934ms native versus 3163ms direct; body-to-raw was 1594ms versus 526ms. Equal auxiliary/Probe5 timing cannot exclude synchronous work before both observers.

The first body-triggered frame callback took 555ms native versus 501ms direct. The native eight-frame burst ended at 3649ms, 879ms before raw text; it did not cover the late delay. Twelve early nested timers completed by 1517ms native and 1332ms direct without a one-second deep-timer interval. This cannot rule out later scheduling. Native document focus was false and direct focus true; visibility was visible in both. Focus is a correlation, not an isolated cause. One same-origin script transferred about 18KB (50KB decoded) natively while the direct sizes were zero, but both resource entries ended around 1.2s, well before the body and raw text. That observation alone does not establish cache causality or explain the extra second.

All three native auxiliary snapshots reassembled with exact binding/session/sequence/chunk SHA checks. The direct auxiliary was installed 1834ms before its sole Send and expired at its fixed deadline; its frozen snapshot later passed full payload proof. Web Inspector was detached during both measured intervals. The native website session and exact direct tab closed, and Safari's developer setting was restored off. Two unsent model-picker/variable setup errors were retained, with no duplicate Send.

- Installed verifier: `95ee0c114cc86e16e4eb552e37d72a23bb3ee047fd808575f3460b911ddd8d3f`.
- Strict one-pair report: `ed5c37915ca0e8fbd1d87e8121f1a91c1334ddecbad7203ebacb16bb79d3ac8b`.
- Bounded auxiliary reconstruction: `0921152b338500c66c012aff3dc5b71aeb6f7f4dcf708529d1b7475dba70e5cb`.

## Build-180 avoidable extraction and diagnostic work

Build 180 defers the rendered-text fallback for already validated literal response envelopes and omits generic anatomy diagnostics on ordinary confirmed replies when the caller explicitly requests that. Actual empty user/answer sides and first-user failure diagnostics remain collected. Model/product mutation discovery remains unchanged: skipping message-only batches can miss an outside control labelled by text inside a message. These are source work reductions, not an established explanation or fix for the entire 179 raw-text residual. The frozen source passed 400 adapter tests (13,694 assertions) and 46 focused native tests, including two real WebKit traversal/failure cases. Both runs verified unchanged source hashes.

- Build-180 test freeze: `11e9914ecaf6d1bb00f84836a82a6129acb7ad9fb64fb823efd07cb36b819dff`.
- Build-180 adapter log: `defba6142dbbc46f29491584d9370f8d0646def573af2d26cec5e26c4f5b84ab`.
- Build-180 focused native log: `eafbf31286209545a071f495c06286175da06e428ef8ec4b6efd5eb2225fc53c`.

### Installed build-180 results

Signed 0.7.0 (180), executable source `8d2f75b1a32ff3fdd0c1f40d461548d744a2af07`, passed independent build/install verification for 56 bundle files and 52 resources, preserving the engine and keeping Gemini diagnostics off. This is a controlled test installation, with no release publication or notarization.

The prespecified three-pair C1,C2,C3,D1,D2,D3 block used the exact 51,657-byte payload in normal Chat/latest Instant/Temporary. All native answers were HI and all owned website sessions and direct tabs closed. The frozen benchmark reader excluded D1 and D2 because their complete JSON fences were inline rather than newline-delimited. The production codec accepts that complete inline form; this is a benchmark-contract mismatch, not evidence of a live parser failure. The old report remains unchanged: one eligible pair and two excluded pairs. There is no qualified three-pair average or demonstrated end-to-end improvement.

| Pair | Native first text | Direct first text | Frozen report |
| --- | --- | --- | --- |
| 1 | 4967ms | 3312ms | Excluded: direct inline fence |
| 2 | 4908ms | 3193ms | Excluded: direct inline fence |
| 3 | 4818ms | 2883ms | Eligible; both ordinary HI |

Both fresh V84 code/terminal/browser workflows passed all twelve original checks. Each model fixed only the helper, preserved the note and tests, ran four passing tests, obtained its reference from the helper, filled and submitted the built-in browser form, read the exact result receipt and closed its task-created tab. Independent verification also passed all eight tests and the helper-only edit checks. All 22 website inferences completed and saved/closed, with no failed inference rows. These are bounded workflow results, not an unrestricted provider qualification. The fixture server stopped, was reaped and left its loopback port closed. Safari's developer setting was restored off.

Four unsent benchmark setup errors and two unsent fixture UI errors were retained. No provider Send was replayed. The original V81 timeout and V83 R2 browser omission remain retained separately. Further profiling will measure synchronous call costs and late scheduling before attributing the remaining raw-text gap to DOM checks, focus or cold browser state.

- Installed verifier: `1728a30ea4f08239fbdd7b1ff9056fd8d428c4f34397481b2942a96025ec7f44`.
- Frozen matched report: `360e0c3c4e7dcaf1c84245de79df1605dab1eac035b81cc53953f704057b7e17`.
- Exact V84 extraction: `9c9a04e81dcc466835d4ae91461cd378831926e86027d992503c93b42320e825`.
- V84 workflow report: `edb725248038da7e2cecc0f532a1b4f4cfc5775534c32f0a6b9d5a252d637c9d`.
- Independent R1/R2 verification: `1e997d3772659bc61368b4caaa27223189f5f2fbfd55c841c8834564306c4aad`, `1922c71a48fe21c5fcdc0740c169772590cf81baf756107c996d31f9690724ae`.

The bounded artifact-only 180 reconstruction preserves all strict exclusions. Native body-to-raw intervals were 1591/1655/1582ms; direct intervals were 83/614/111ms. The native full final proofs took 180/171/189ms. These are per-arm observations from the retained nonpositive cohort, not a matched aggregate or an isolated explanation. Reconstruction SHA: `52e7c64f5855a26db0f07625930d04dfe9216b2265b21b32a525ebfe11411153`.

## Build-181 targeted synchronous-work diagnostic

The existing armed synthetic diagnostic now records five fixed, bounded call-cost rows for observer guard work, answer extraction, generic anatomy diagnostics, first-user rendered-text reads and synchronous expansion-candidate checks. Each original guard executes directly inside a local try/finally; optional recording supplies no result or authority. Timings measure synchronous wall time, may overlap across nested rows and are not exact CPU costs. A finite set of eight body-anchored 250ms timers covers the late interval omitted by the earlier short frame burst. Timer callbacks read no DOM, probe, snapshot or proof.

The existing 15-second window, per-row call caps, three-snapshot logging limit and 4096-byte payload budget remain unchanged. Invalid diagnostic fields are removed before ordinary validation. The maximal populated shape has round-trip and chunk-budget coverage. This adds measurements, not a claimed latency improvement. A separately prespecified one-pair normal Chat/latest Instant/Temporary experiment will use the exact same whole payload and the production complete-envelope grammar, retaining output representations and all failures without regrading build 180.

The final frozen source passed **406 adapter tests** (13,803 assertions) and **51 focused native tests**, including the existing production complete-fence acceptance/rejection cases. Both final runs retained unchanged input hashes. An initial adapter run exposed three test-slice harnesses missing the new passive timing helper definitions; the test-only fix and the initial input-freeze drift are retained, followed by the clean full runs. Signed installation and the new diagnostic pair are pending.

- Final test freeze: `5580f18d04aef66b24ecaf2901c4217f8ab2cfc0fa02f613ed5870083ef342f2`.
- Adapter log: `8259f18f7b175d8c763d205282b29dd69c7c168b51794d187c0afbcbbc7d05dc`.
- Focused native log: `6d4ac18a7df7758ddffbbc88ffafbb7a619059b996f49720b2bda518f4db79e6`.

### Installed build-181 diagnostic result

Signed 0.7.0 (181), source `ad4a12f2913ce07d98bdf55e6354d65e89d1354b`, passed independent 56-file/52-resource installation checks. Its separately prespecified C1→D1 pair passed the production-compatible complete-envelope reader, exact 51,657-byte payload/model/Temporary/one-turn checks and both owned closures. First text/candidate appeared at **4661ms native versus 4281ms direct** (+380ms). Native used a code envelope and direct an inline rendered fence; the different representations, one-pair sample and website variation remain confounds. No general speedup or pure-app-overhead claim follows.

Native body-to-raw was 1666ms versus 535ms direct. At the first-text checkpoint the native observer guard had accumulated 24ms (maximum call 5ms), answer extraction 1ms, generic anatomy work 3ms, user-text reads 2ms and synchronous expansion-candidate checks 2ms. These partial, potentially nested wall scopes do not explain the extra second and must not be summed as total CPU. The expansion row does not time an asynchronous click or wait. The native late 250ms timers recorded intervals 640/638/250/267ms followed by approximately 251ms intervals, including the late response window. There was no observed one-second clamp; these finite samples do not prove every browser scheduling path is unaffected. Final full proof took 184ms; first native candidate to transport completion was 2056ms, including an observed response change that rearmed the unchanged stability guard.

The collector retained four additional existing sanitized first-user prefixes in the same sole PID/window export, but no such records appeared; absence cannot establish that no expansion occurred. The auxiliary reader's first revision accidentally expected one snapshot after reducing the pair count to one. The corrected second revision restores exactly the required three snapshots, retaining the failed revision and all original phase/binding/size checks, without another query or provider request.

Existing build-180 logs also show the next cold standby page beginning about 48ms after submission, well before first text. That exposes a scheduling difference from the direct control, not causal proof. The next controlled candidate defers refill until the first validated nonempty response while preserving blank-root adoption before Send and all response proofs. Both 181 sessions closed and Safari's developer setting was restored off.

- Installed verifier: `89dd9ad6ec16d7ebbf10fc036588e8b238ebcb8365043779eea363dca7ac312c`.
- One-pair report: `5ed0b6917ab0f01363b4e2c36d90554b1b0e75bafbd0dfa3d9857d0b1def8ec0`.
- Bounded auxiliary reconstruction: `1328626f972eb081f75a291f8c4622ca5dc94303dc4e6377213e4ca99cb4e146`.

## Build-182 standby scheduling experiment

The next candidate moves the existing standby-refill call from acknowledged Send to the existing once-per-Send first-positive branch, after fresh owned-page/count/Temporary/nonempty checks. Blank-root adoption before the current Send remains unchanged. The standby keeps all provider/cancellation/cookie/isolation/capacity guards and remains unowned and prompt-free. This removes that automatic preload from the initial generation interval; explicit concurrent user demand can still create a standby through its existing path. It does not guarantee no overlap with later streaming, stability or final proof.

The frozen candidate passed **60 focused native tests** covering cookie admission, prewarm ownership and lifecycle, AppState demand, response stability and final proof. The new real-WebKit regression holds the acknowledged answer empty, verifies no standby, releases valid text while still busy, verifies one untouched separate private standby and no duplicates, then completes the original full proof and cleanup. Its initial human-only cleanup expectation failed because the desired standby remained; the corrected test first verifies that exact standby survives Finish, explicitly disables prewarming and then checks human-only cleanup. The initial failure is retained. The unchanged adapter and adapter-test bytes retain build 181's separate 406-case result. Signed installation, three new matched pairs and fresh V85 workflows are pending; no latency benefit is established yet.

- Final native test freeze: `0d094e09937f97477a5940880a24497e283e73f4cfea7f7146b557a98544cdae`.
- Native test log: `fe3c83ec313623dd7f90466bc54a1a70bd2324932d62ebbef26ff6e8f31b8b58`.

### Installed build-182 results

Signed 0.7.0 (182), executable source `a2b1b3c1b8c64bb8218c73aed10b1b6ae3295262`, passed the independent 56-file/52-resource install verification. The first installer copy failed with an unspecified `ditto` error; a diagnostic copy and the full install retry succeeded. The failure is retained; disk space was not established as its cause. This remains a controlled test installation without a published release.

All three prespecified native-first pairs passed the strict reader with identical whole 51,657-byte payloads per pair, normal Chat/latest Instant, fresh Temporary chats and confirmed owned-session closure:

| Pair | Native first text | Direct first text | Observed difference |
| --- | --- | --- | --- |
| 1 | 4363ms | 3961ms | 402ms |
| 2 | 4389ms | 3256ms | 1133ms |
| 3 | 4666ms | 4581ms | 85ms |
| Mean | 4473ms | 3933ms | 540ms |

All six responses resolved to HI, but only pair 2 had equal response representations and lengths. Provider variation, output representation and block order remain confounds. Standby creation moved to 47–50ms after first validated text, confirming the scheduling change. The direct control also became faster than build 181's single pair; these observations establish no native-specific speedup.

The same passive selector observed an assistant body before text in both arms. Body-to-text averaged 1336ms native versus 556ms direct, but body presence is an empty-or-nonempty scaffold observation, not a common first-token event: the native scaffold appeared about 242ms earlier while native text appeared about 540ms later. The 781ms interval difference therefore cannot all be attributed to delayed rendering of an equivalent event. Raw text and the independent first-text probe agreed within 1ms. Synchronous observer guard work accumulated only 28–31ms, with individual calls at most 5ms; these potentially nested partial wall scopes do not explain the gap. Focus, asynchronous expansion and cold page work remain unproven causes.

Native first-candidate-to-transport completion was 1785/1860/1886ms, including the retained 1600ms stability guard. Final full proofs took 185/259/184ms. Transport-to-native completion was 258/284/408ms, including cleanup receipt persistence of 176/188/318ms. These separate boundaries identify another measurable optimization candidate without weakening stability or final ownership proof.

Both fresh V85 code/terminal/browser workflows passed all twelve original checks with no native errors, failed commands or unverified browser calls. Each made only the intended helper edit, preserved the note/tests, passed four tests, looked up its generated reference through the built-in browser, reported the exact receipt and closed its created tab. Independent verification passed all eight tests and edit-preservation checks. All 22 website inferences completed and saved/closed. These are bounded workflow results, not unrestricted provider qualification. The fixture server exited cleanly and its port closed; Safari developer features were restored off. Two unsent benchmark setup failures were retained, with no provider Send replay.

- Installed verifier: `b07fab3da99a1625ad70bfd2248016c3dfca9e65af3a5e780fefd0249ed1e2ca`.
- Matched report: `c14cde67085a95a828515bd6c1b83a7f3689f5b1db6a9d76001543474f542e3a`.
- Auxiliary reconstruction: `bf4f94bcb8b046f0f672b8e86aa4fe38238444122eb4f23b1dac15928390137c`.
- V85 workflow report: `8cc79ae0dd7ab188dc4446b6120810ad821a2eb67c4f1c8b8b8572087a090fb1`.
- Independent R1/R2: `d57fdc62c337a59eae2c49205b3cf27d2353cdd474d8aca721201ea78f85af60`, `3df4d0d7129fc282032a70f175f96a8e41dd42f0f67e8eb363eb673711a99fd6`.

## Build-183 cleanup metadata optimization

The save microbenchmark now has an optional synchronous timing sink for five fixed scopes: inventory, record reads/validation, atomic writes, synchronization and readback. Production leaves it nil. The existing synthetic fixture still verifies exact persisted bytes, repeated saves, causal collision rejection and fresh corruption detection; timings do not decide functional success.

With 200 seeded journals, the original fresh save averaged 49.283ms: inventory took 18.300ms and record reads/validation 26.376ms. Both atomic writes, synchronizations and readbacks together cost less than 1ms. Omitting the UI summary would therefore remove little of the measured cost and was not implemented.

Metadata reads previously repeated `attributesOfItem`, existence and URL resource queries. The candidate performs one fresh `lstat` per path check, preserving regular-file/directory and nonnegative-size requirements. Only `ENOENT` means absent; symlinks, other file types and other errors fail closed. Every save still rereads historical bytes and executes both existing parsers and all identity, collision, capacity, durable-write and readback checks. No result is cached across calls.

| Synthetic store | Original fresh save | Foundation consolidation | Final lstat candidate |
| --- | --- | --- | --- |
| 100 seeded journals | 25.497ms | 22.803ms | 16.881ms |
| 200 seeded journals | 49.283ms | 42.494ms | 30.752ms |

Each mean uses five fresh saves at the stated starting size. At 200 journals, inventory fell to 8.566ms and record reads/validation to 17.427ms; exact-retry saves fell from 19.884 to 10.608ms. The 37.6% fresh-save reduction is a sequential synthetic measurement, not a demonstrated end-to-end improvement or direct attribution of the live 176–318ms phase. The final benchmark passed, and the store suite executed 30 tests with one opt-in benchmark skip and zero failures. Regressions cover missing versus empty/corrupt files, directories, dangling links and changed task-directory types. Installed validation and a new matched block remain pending.

- Final store source: `605a805bb102572b3e86ce9c05387a6aee791f95b5d88138fdbcc656aa5e0610`.
- Original scope report: `b288d6aa9bdc37f761dc1ab3c0bb5de03c10a3798c2cb1e7c59ae5f47e5e3f14`.
- Final scope report: `d4852b56c37fafea1db196fa62da3b7200a94ada6c5b068d3fd5a93b630c7b7c`.
- Final store test log: `dcbb0b8bfe4a42b8104b1b0f996e82daafb3f342977cf09c23f0f37746671aaa`.

An additional direct focus experiment stopped during CUA setup before Temporary selection, payload insertion or Send when the tool timed out and reset. Its unsent tab was closed and Safari's developer setting restored off. It provides no focus or latency evidence; the original three-pair report remains unchanged.

### Installed build-183 results

Signed 0.7.0 (183), executable source `82efceff24ef64734e6b386aa67e330c901f96d5`, passed independent verification of all 56 bundle files and 52 resources. The existing engine was preserved and Gemini diagnostics stayed off. This is a controlled test installation, without notarization or release publication.

All three prespecified native-first pairs passed the unchanged reader with exact whole 51,657-byte inputs, normal Chat/latest Instant, fresh Temporary chats and confirmed owned-session closure. All six responses resolved to HI.

| Page endpoint (ms) | Native 1 / direct 1 | Native 2 / direct 2 | Native 3 / direct 3 | Native / direct mean |
| --- | --- | --- | --- | --- |
| Send to first text | 5830 / 3438 | 4912 / 4445 | 4567 / 3995 | 5103 / 3959 |
| Send to first completion candidate | 5830 / 3439 | 4912 / 4896 | 4568 / 4558 | 5103 / 4298 |

The three-pair first-text difference is 1144ms, versus build 182's 540ms. Pair 1 has a 42-byte native extracted representation of unknown production-accepted format versus direct ordinary HI, so response format and length remain confounds. Pairs 2/3 have equal ordinary HI representations: first text differs by 467/572ms, but completion candidates differ by only 16/10ms because direct completion controls appeared 451/563ms after text. This describes different endpoints; it is not a post-hoc subgroup speedup claim. The complete three-pair report is retained, and no overall first-text improvement is established.

Native candidate-to-transport completion took 1764/1778/1771ms, including the unchanged 1600ms stability guard and final full-proof reads of 163/175/171ms. The previous mean was 1844ms versus 1771ms now; build 182 recorded one response change that rearmed stability, so that difference is not solely a source effect. Transport-to-physical-close took 79/72/77ms within the native timing epoch.

Cleanup persistence took 182/125/133ms, averaging **147ms versus 227ms** previously. Encoded response to cleanup receipt averaged 216ms versus 293ms. Transport acceptance to native completion on log wall timestamps averaged 230ms versus 317ms. These live reductions agree in direction with the controlled synthetic save improvement, but the store inventory changed after reversible archival of four closed synthetic tasks, and cache/load also differ. They do not isolate an 81ms source-only saving. Native/server elapsed epochs and page clocks are not subtracted across sources or summed into a calibrated end-to-end decomposition.

The remaining first-text difference is unresolved. Empty assistant scaffold to raw text averaged 1480ms native versus 231ms direct; first observed scaffold presence is not a common provider first-token event. Synchronous observer guards accumulated only 22–30ms, with individual calls at most 5ms. These partial wall timings do not explain the difference or establish WebKit, focus, cache or observer scheduling as its cause. Standby creation remained after first validated text.

The cleanup-store suite executed 30 tests with one opt-in skip and no failures; the separate opt-in benchmark passed. Seventeen integration tests also passed, covering cleanup failure, persistence-only retry, concurrent finish/shutdown, cancellation and synthetic AppState cases. The intended nine-test filter also selected eight AppState tests; all selected results are retained. The adapter was unchanged and retains its separate build-181 406-case result, not a rerun for 183.

Both fresh V86 code/terminal/browser workflows passed all twelve original checks, with no native errors, failed commands or unverified browser calls. Each changed only the helper, preserved the unrelated note/tests, ran four tests, submitted its generated reference in the built-in browser, read the exact receipt and closed its tab. Independent verification passed all eight tests and edit-preservation checks. All 22 website inferences completed and saved/closed. The fixture server exited cleanly and its port closed; Safari developer features were restored off. These are bounded workflow results, not unrestricted provider qualification. One unsent direct setup failure was retained; no provider Send was replayed.

- Installed verifier: `4876b4d6089c18089128614310da760de3f693ee0ab9be6fcc64ab1abeb9b731`.
- Matched report: `78ab99b53d1078a263f1f63ef79d6e722e025bb4bbeea23a43a7998db71c7ca6`.
- Auxiliary reconstruction: `2b0a48c364e916ca20c930fdbd293f9f4896ccbbfe84545e72f437f24a670421`.
- Integration test log: `69567ed507baee8f8b8d65233e62446e36fff59b0abda7cca30c9689e4a2bf04`.
- V86 workflow report: `38e59fbb9c4eab3f8657299098ee84fb46f373da293085a5a6c8a8282cea3581`.
- Exact V86 extraction: `29152db9dabfe0419bb51c099c8d9e3958df24a3b1ce04ca0e4e0eb5ff8df4d0`.
- Independent R1/R2: `8e1812d674987b51823c21bfba20721c233478febfc4d467d4c9db86ff7247e3`, `1ed0c8eeba518bc884a00b919e0d2516532c229bb776dd2ada609fb2b5c6848f`.

## Build-183 presentation and Send controls

Twelve controls used the same complete 51,657-byte captured payload
(`3067a360c298c8a72b9eda0c4f19879b4a2494f34bc3265cdd365677788b9050`),
normal Chat/GPT-6/Instant and a fresh acknowledged Temporary conversation each
time. All ran in the installed build-183 process and its human browser's default
persistent profile. The first six alternated visible/background conditions in
V/B, B/V, V/B order. The next six held the page visible and alternated trusted
website clicks/programmatic clicks in T/P, P/T, T/P order.

| Control | Send to first text, all three observations | Mean text | Mean completion candidate |
| --- | --- | --- | --- |
| Visible human tab | 3176 / 3770 / 4573ms | 3840ms | 4080ms |
| Detached background human tab | 8103 / 5834 / 5072ms | 6336ms | 6337ms |
| Normal Send click, visible | 3481 / 4560 / 3441ms | 3827ms | 4024ms |
| Programmatic Send click, visible | 3406 / 4231 / 3925ms | 3854ms | 4004ms |

These are page-observation endpoints, not native verified completion or provider
generation alone. Every response decoded to HI, but plain text, rendered inline
fences and code-block envelopes differed. All observations remain in the means;
there was no favorable-format selection or provider replay.

Detaching the human tab was associated with 2497ms longer mean first-text time.
Actual hidden onset preceded first text and persisted through the candidate in
each background trial. Attachment, focus and visibility changed together, so
this does not isolate focus or prove that Computa's native inference host has
the same delay. The native host uses an attached private view and an isolated
nonpersistent store; its previous observations reported visible but unfocused.

Programmatic Send was 27ms slower to first text on average and 20ms faster to a
completion candidate. Individual paired text differences were -75, -329 and
+484ms. This small block did not reproduce a consistent programmatic-Send
penalty. Both Send conditions started visible/unfocused with the editor active
and became focused about 1.34s afterward, unlike the sampled native condition.
Trust and transient user activation were verified for each actual click.

All twelve exact payload/model/product/current-turn proofs passed. Each trial
contained one Send, and its target and blank sibling were closed. Two unsent
Send setup failures and one unsent presentation setup failure were preserved.
One zero-Send observation window expired during an interruption; its supported
same-document reset and subsequent single Send were separately verified.
Safari's temporary developer feature was restored off.

The original native mean first-text gap of 1144ms remains unexplained. The next
test should change only actual native focus while preserving its view, host,
store, payload, model and Send path. A diagnostic-only native menu now prepares
that experiment under `DEBUG` or `COMPUTA_NATIVE_FOCUS_DIAGNOSTIC`. Its opt-in is
consumed by the next exact inspector lease, requires the existing key window,
and restores prior focus on revocation, cancellation, host removal or movement.
It never activates or reorders a window. Normal Release excludes the menu and
retains its existing focus policy. This source preparation is not an installed
optimization or live native-focus result.

The existing native UI cannot replay a byte-identical first-turn request: it
generates fresh message IDs and a session marker, and its capture capability is
read-only. The planned native qualification must preserve those guards, record
each real outbound payload and compare it with its own byte-identical direct
control. Repeated native conditions can hold the task contract and fresh-store
configuration constant, but their generated identities remain a declared
difference. The current inspector lease offers no pause or replay shortcut.

Twenty-two selected native tests passed: eight new focus-diagnostic cases, seven
existing inspector/lease cases and seven existing focus/host regressions.
Coverage includes exact-view scope, failed acquisition rollback, expired or
revoked leases, newer human focus, missing or detached original responders, and
restoration before host removal or movement. The tested source hashes remained
unchanged during the run. No live provider requests or OS window activation
occurred in these tests.

The separate completion audit found no current-request terminal signal tied to
the final committed answer text that could safely replace the 1600ms fallback.
Copy controls, nonbusy state, the named turn state and observed network events
do not supply that proof by themselves. The fallback and final full verification
remain unchanged. Thirteen focused adapter tests passed (2066 assertions),
including late text/footer changes, current-turn ambiguity, cancellation,
picker drift and retained tool rounds.

- Presentation ledger: `6d7073cad5ef438414d703e67cf3d9916a3c1101f35b96d5d0bffcfdc6c4dda8`.
- Send ledger: `090c8ed0311d85a4b13ab4d586e1488e9f14adb44fc8a0f532c3bfae0e7bdb98`.
- Native focus test receipt: `24d540a11b7ba1e66fa69f8d8d0d57846405d20abbc602ce2fb4f57fc8d6f57e`.
- Completion audit test receipt: `063f58c695b908de6fb21a6809264f96d193484de381cbdf9d360a7a1da42204`.
