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

## Rendering an existing browser tab in the background

Build 306's real-mail attempt completed sixteen verified Chat / Instant inference
sessions, but reached the turn limit after one Compose click and no field fills
or Send. The next inference was rejected before opening a provider session. All
completed sessions closed. Current-reference checks passed; repeated searches and
valid pagination could not find compose controls absent from the retained capture.

Every Gmail capture used a detached existing user view with no window, a hidden
document, and a 360-by-665 viewport. Capture stopped at its byte budget after 241
nodes. The passing local draft fixtures had opened tool-owned pages in the attached
1,024-by-768 background host; they did not exercise a borrowed, narrow user tab.
Binding an existing tab had not acquired equivalent rendering support.

After the task stopped, selecting that same Gmail page in the narrow visible pane
still showed no compose controls. Widening the pane to approximately 480 pixels
immediately exposed the minimized compose panel and its Full screen control,
without navigation or website input. The empty panel was closed without filling
or sending anything. This confirms viewport sensitivity separately from the
bounded-discovery and overview-ordering defects covered by the earlier fixtures.

An active browser binding now leases rendering before its first capture. A hidden
borrowed tab attaches to the existing 1,024-by-768 background host; it remains a
user-owned tab with the same document and selection. Visible human presentation
takes precedence. Releasing the last render lease detaches the borrowed view and
restores its prior frame. The exact revocable binding lifetime prevents a late
acquisition or release from affecting a newer task. Native focus protection is
enabled only while a human tab is hosted in the background, then normal foreground
behavior resumes. Missing render hosts fail before page input. No discovery,
capture, permission or inference limit is increased.

The real WebKit regression captures the same document at 360 pixels without its
responsive fields, then acquires the binding and sees those fields on the very
first capture at 1,024 pixels, without a sleep or layout polling. Values, loader,
URL, selection and the user's unsent native text remain unchanged. Release restores
the original frame. Additional cases cover presentation, host replacement, missing
hosts, closed tabs, shutdown, Stop during acquisition and stale releases.

The browser session, transport and controller cohort passed 251 of 252 tests.
The remaining test used an unnamed passive gridcell that the existing content
view omits. Giving that synthetic wrapper the explicit same label preserves its
passive-wrapper versus actionable-child checks; the corrected test and the three
new lifecycle tests then passed. Thus all 252 unique checks have passing results,
without claiming a single 252-test zero-failure run. Older native controller
fixtures also now attach a real render host, matching the production requirement.

## Priority across capture branches

The installed build-307 retest confirmed attached, visible 1,024-by-768 Gmail
captures throughout. It still reached the turn limit after one Compose click and
no fills or Send. All sixteen completed Chat / Instant sessions verified and
closed. This preserves the rendering repair as a measured result while identifying
a remaining capture-selection failure.

A deterministic counterexample exposed another capture defect: discovery found a
later visible dialog within 606 structural slots, but capture exhausted its byte
budget inside an earlier focused ancestor's ordinary inbox descendants. Priority
sorted siblings only; depth-first traversal still drained that earlier branch.
An earlier form and later named panel produced the same failure at equal priority.

Capture now selects from four global priority frontiers. Propagated ancestor
priorities keep parents ahead of children, each frontier retains depth-first
ordering, and the published graph retains actual DOM child order. The same discovery,
visited-node, output-node and byte limits apply. Visibility, field protection,
current references and input authorization are unchanged. The reproduction proves
the scheduling defect; the exact live Gmail ancestry was not captured. A separate
adversarial discovery-exhaustion case remains outside this scheduling correction.

All 45 browser-control JavaScript tests pass (730 assertions). The two real WebKit
counterexamples fail with the immutable build-307 resource and pass with the
candidate in the same native test binary. All 45 native browser transport tests
pass, including unchanged byte limits, preserved ancestry and sibling order,
zero capture inputs, replaced-reference rejection and one separately observed
current-reference click. Live Gmail qualification remains separate.

Build 308's real-mail attempt stopped after 6.201 seconds before any browser
tool ran. Its first complete prompt matched, but a later conversation-URL
promotion failed in replacement-message certification before finalization.
The next read found the recovery claim spent and rejected `first_user_message`.
No mail fields or Send were
dispatched, and temporary-session cleanup remained unconfirmed. This attempt
does not qualify the browser capture change.

A real WebKit regression reproduces a missing certificate-return handoff:
the caller discards an already-installed certificate if the URL changes before
the awaited helper returns. It reproduces the same ownership-error boundary
with the immutable build-308 adapter, including root-to-local and local-to-public
route changes. It retains one installed replacement certificate, the original
deadline, one display expansion and one provider submission. The regression
establishes this boundary defect; its diagnostic context booleans do not prove
an identical live microtask ordering.

The correction retains that exact, unclaimed replacement certificate through
the existing route-discard validation and returns it to native's existing fresh
read. It requires the same old and new physical message nodes, complete prompt
fingerprint, owner, document, model, product mode, temporary mode and deadline.
It creates no certificate, route witness, prompt replay or additional recovery
allowance. The subsequent native read still proves the complete current message.

All 518 adapter tests pass (24,805 assertions), including three focused handoff
tests with concurrent-change, deadline and invalid/reused-continuation negatives.
All 19 native ownership tests pass with the candidate resource in the same binary
that failed against build 308. The two-route positive retains one certificate,
the original deadline, one expansion and one provider Send, and performs fresh
full-body hashes before pinning the current physical message. Changed body, model,
temporary mode and an invalid second local route remain rejected. Installed
real-mail validation is still separate from these deterministic results.

The signed, independently verified build 309 failed the original real-mail task
after 3.130 seconds, before any browser tool, field input or Send. Its first full
prompt bound successfully, followed by root-to-local and local-to-public route
changes. The remount certifier returned `snapshot_before_action` / `digest`, and
the next read rejected the spent recovery. This matches build 308's finite error
boundary; the retained diagnostics cannot identify which internal guard rejected
or whether the certificate had already been installed. The passing local fix
therefore does not establish reliable live behavior or the remaining root cause.
Temporary-session cleanup remains unconfirmed. No prompt was replayed, diagnostic
watchers and their exact unused arms were cleaned up, and the failed page and
historical evidence were retained. The real-email workflow remains **failed**,
with zero emails sent, and this PR remains draft pending a verified live result.

Build 310 adds diagnostic-only provenance for the remount certificate boundary.
It retains the first rejected stage and exact guard name, finite receipt-state
facts, and whether the native expected-model/deferred-verification fields were
present. Guard operands keep their original order and short-circuit behavior;
diagnostics do not re-evaluate proof getters, grant recovery or change acceptance.
The record persists across the same candidate's later failed reads and cleanup.
Native validation accepts only the closed enum/boolean shape and removes it
before ordinary inference processing. No page text, addresses, URLs or private
ownership values are included. This instruments the remaining failure; it does
not claim to fix it.

The diagnostic-only build passes 520 adapter tests (25,175 assertions) and eight
focused native tests. Real WebKit checks retain the identical first failure
through route discard, the later spent-recovery read and failed cleanup, with
one provider Send and one display expansion. Native tests reject malformed or
private diagnostic fields and verify that stripping them preserves the original
response/error fields. The existing certificate-return positive and concurrent
change negatives continue to pass.

The independently verified installed build 310 completed its first Chat / Instant
inference and one read-only `browser_tabs` call, then failed the next inference
after 13.646 seconds overall. No email fields were filled and no email was sent.
The failed inference crossed root-to-local during product verification and
local-to-public during the full-body hash. It rejected `pinned_fingerprint` before
entering the remount certifier, so the new certificate diagnostic was correctly
absent. That error combines context, canonical-text and fingerprint checks; it
does not by itself prove a changed fingerprint. Later reads matched the complete
61,990-character prompt, but cannot establish the state at the earlier rejection.
The exact earlier rejection remains unresolved. Failed evidence is retained,
diagnostic arms and the watcher were cleaned up, and website cleanup remains
unconfirmed. This result does not qualify the live email workflow.

Build 311 extends the same bounded first-failure diagnostic to the earlier
body-hash check. It distinguishes the already-evaluated context, rendered-text
and fingerprint predicates and records the exact route-helper rejection. The
shared result boundary also retains otherwise unreported terminal route-helper
refusals. The existing first record remains immutable, and its fourteen-field
shape, private-value exclusions and native stripping stay unchanged. Predicate
order and short-circuit evaluation are preserved; no proof is repeated solely
for diagnostics. This is further instrumentation, not a behavioral repair.

All 523 adapter tests pass (25,428 assertions). Three new diagnostic cases fail
against the immutable build-310 resource because the first-failure record is
missing; the candidate passes all five focused diagnostic tests. Context drift,
an incorrect digest, missing expected-model input and a terminal route refusal
remain rejected. The tests distinguish those causes and retain the first record
through later spent reads and cleanup without admitting a response or replaying
an action.

Eleven focused native tests pass. The new real-WebKit case reaches the ordinary
poll's product-only verification, then the inherited inspect call, across two
actual URL changes. Both nested reads retain their original model-enforcement
flag; the expected-model input and deferred verification are present. A deliberate
temporary-control change at the full hash is rejected with the exact first cause,
retained through the spent read and failed cleanup, with one Send and one
initial display expansion plus one bound recovery expansion. The immutable
build-310 adapter fails only the new diagnostic assertion
in the same final native test binary. This proves diagnostic coverage and the
normal path's arguments, not the unknown cause of real run 310.

Installed build 311 reproduced the failed second inference after one successful
Chat / Instant response and one read-only browser inventory. The task failed in
14.696 seconds with zero email input or Send. Its first retained diagnostic is
`finalization_hash / route_guard / model_pins`: the route handoff rejected
`chatGPTFirstRouteModelPins`. The expected model and deferred-verification input
were present, and the replacement receipt matched and remained retained. The
identical first cause survived route discard, the spent read and failed cleanup.
This excludes missing expected-model input and missing or mismatched replacement
receipt for that rejection. The model-pin helper still combines several
predicates, so the record does not distinguish a disabled/replaced picker from
negative selection history or another model-control mismatch. No behavioral
repair is claimed. Exact evidence is retained, diagnostic arms are cleaned, and
website cleanup remains unconfirmed.

Build 312 names the individual model-pin rejection operands while preserving
their order and short-circuit evaluation. A bounded optional snapshot reuses the
already-computed picker presence/counts to distinguish missing or duplicate
triggers from a replacement. If the pin was invalidated, the diagnostic retains
the existing first invalidation history: either the finite header-mutation stage
and rejection rule or the semantic attribute and four comparison booleans. Header
mutation traversal records its original rejection without rereading text. No
model value, page text, URL, identifier or private proof is logged; native parsing
keeps a closed schema and removes diagnostics before response validation. These
changes supply evidence for the repair and do not change model verification.
All eight invalidation writers retain their finite source and first rejected
operand, including provisional-header and deferred-model paths. The shared
header helper is updated in its canonical source and regenerated consistently
into all three provider adapters; this does not claim live qualification of the
other providers.

The final affected adapter/shared-helper cohort passes all 792 tests (33,195
assertions), and all 14 focused native tests pass. Actual WebKit cases disable,
replace or change the model header at the existing product-verification and
route/hash boundary. They preserve the same rejection, one Send and the original
expansion/route budgets while retaining distinct model-pin details through the
spent read and failed cleanup. The immutable build-311 adapter fails the new
detail assertions in the same final native binary, with the existing safety
preconditions passing. Canonical-helper parity and unchanged Claude/Gemini
provider-specific bodies are checked separately from these ChatGPT regressions.

## Diagnostics and limits

Completion-observer preparation and user-count rejection diagnostics retain only
bounded enumerated states, counts and booleans. They are stripped from provider
observations before inference-state processing and cannot authorize acceptance,
retry or input. The original provider's empty-response cause remains unproven;
later fixture success cannot reconstruct its closed response stream. A separate
user-count rejection also remains causally unresolved.

Build 306's exact-response control returned the requested 27-byte synthetic marker
as plain text, outside the mandatory JSON envelope. Full submission verification
and cleanup passed, and no tools ran. The strict parser correctly rejected the
format; this is a retained model-format limitation, not a passing control. No
deterministic instruction omission was found, and no permissive parser fallback
or speculative prompt change was made. It is separate from the real-mail browser
workflow and its independently verified lack of Send.

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
