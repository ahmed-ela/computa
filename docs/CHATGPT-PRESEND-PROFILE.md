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
