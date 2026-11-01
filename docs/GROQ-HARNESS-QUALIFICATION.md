# Groq website adapter qualification

## Scope and status — 2026-10-31

This work adds the signed-in `https://chat.groq.com/` website as an embedded
provider. It does not configure Groq API access or substitute another provider.
The installed app remains build 354 until a complete adapter passes validation.
Direct website probes below are not yet Computa harness qualification.

The observed menu contains these general chat choices:

| Website key | Website label | Direct website evidence | Harness evidence |
| --- | --- | --- | --- |
| `qwen/qwen3.8-27b` | Qwen/Qwen3.8-27B | Exact marker returned | Pending |
| `openai/gpt-oss-120b` | GPT OSS 120B | Requested structured response returned | Pending |
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

No Groq-enabled package, live harness pass, or release is claimed yet.
