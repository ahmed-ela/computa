# Claude harness qualification

Claude qualification resumed on October 31, 2026. The current live account offers
Sonnet 5.5, Haiku 5.5, Sonnet 5 and Sonnet 4.6; Fable and Opus choices are upgrade
gated. The prior cached Haiku 4.5 choice was absent from the observed menu.
These account-specific observations are not model qualification results.

## Baseline: completion remains unverified

Signed installed Computa 0.7.0 (340), source
`b8ffe5794793633c1f362e0db28cb8310d0b530d`, sent one fresh Sonnet 5.5 marker task.
Website selection and first-message ownership verified before submission. Within
about three seconds the native adapter saw one answer, 63 text bytes and
`busy=false`, but no scoped Copy controls and `answerComplete=false`.
The turn failed at its five-minute deadline after 301.305 seconds; no final
answer or local tool call was accepted.

An independent failure audit joined the started/failed inference, session,
preparation and runtime identities to its saved `closed/not_created` receipt,
recorded 119 ms after failure. Selection-only Sonnet 5.5 evidence was present at
submission; there is no completed-response model proof. The failed transcript,
native logs and screenshot are retained, and its prompt was not replayed.

A separate harmless direct Incognito control in the ordinary embedded browser
returned its exact marker. Its accessibility tree exposed a completed assistant
message, a Message actions toolbar with Copy/Read aloud/Retry, and the status
"Claude finished the response." That is a direct website result, not a repaired
harness result.

## Candidate 341: bounded structural diagnostics

The candidate records finite completion-landmark state and at most four nearby
ancestor shapes. It distinguishes missing scopes from observed zero counts,
contains no reply text, URLs, arbitrary identifiers or CSS classes, and retains
the existing completion and ownership checks. Native validation uses a closed
schema and bounded records. A reserved idle observation ensures streaming
changes cannot consume the diagnostic needed for this failure. Diagnostic
exceptions or invalid values cannot authorize or reject an otherwise valid
response.

Signed build341, source `7da9620e364924b21746d53d356380acb9bbaf1a`, passed 108
adapter tests and six native tests and was installed after all artifact checks.
Its fresh Sonnet 5.5 request captured the mismatch at the first idle read:
one article, one assistant, one reply body and one message-actions bar;
`data-is-streaming=false`; one Copy-labelled button in that bar; **zero** buttons
matching the old `data-testid="action-bar-copy"` requirement. The obsolete test
identifier prevented completion despite the semantically correct Copy control.
The diagnostic did not record whether the identifier was removed or renamed.

After preserving those facts, the operator stopped the diagnostic request at
77.050 seconds. Its genuine interrupted turn, zero tool calls and matching saved
closed cleanup receipt are captured separately. It is not a qualification pass.
No Web Inspector settings were enabled for these observations.

## Candidate 342: semantic Copy-control binding

The repair locates the unique Copy-labelled button in the latest owned response's
single message-actions bar instead of relying on the obsolete button test ID.
The response, article, model, first-user ownership, streaming/interruption,
visibility and cleanup checks remain required. Authored reply content, other
messages, ambiguous bars and duplicate, hidden or disabled controls cannot
supply completion. After the final awaited model proof, a synchronous check
requires the same latest answer, physical control and response text; changes
withdraw completion until a fresh read can establish it.

Signed build342, source `edd3a0e1f966a723cca27107d50faf7fbf8e72b7`, passed 113
adapter tests (1,670 assertions) and six native tests. Its installed fresh Sonnet
5.5 check reached verified completion but failed strict envelope parsing after
4.516 seconds with `malformed_website_reply/invalid_json`. No tools ran; the saved
closed cleanup receipt followed failure by 76 ms. This is a preserved failure,
not a model qualification pass.

The captured extraction diagnostic found one code body containing valid JSON of
type `message`, but returned `outside_content`. The website's language caption
had changed from `text-text-500 font-small pb-0` to
`text-secondary text-caption-regular font-sans pb-0`. The unrecognized caption
also prevented exclusion of the code block's Copy control, contaminating the
rendered reply. A separate direct Incognito control exposed the `json code`
container, exact `json` caption, Copy to clipboard control and completed literal
JSON in Accessibility. Its tab was closed. No Inspector settings were enabled.

## Candidate 343: current code-block caption

The next repair recognizes the observed caption structure while retaining exact
`json` text, a single leaf caption/control and PRE/CODE, strict code-wrapper scope,
whole-answer outside-prose rejection and literal JSON/envelope validation.
Signed build343, source `4922a4c35042292e2b46068ba2de69a99dd29aaf`, passed 114
adapter tests (1,786 assertions) plus both native completion/extraction regressions.
The installed artifact passed all source, signature and copied-resource checks.

| Fresh marker task | Result | Native duration |
| --- | --- | --- |
| Sonnet 5.5 | Exact marker, model/ownership and closed cleanup verified | 4.628 s |
| Haiku 5.5 | Invalid JSON: 235 characters of authored prose outside valid literal JSON; zero tools, closed cleanup | 4.470 s |
| Haiku 5.5, instrumented new task | Exact marker and complete proof; unused exact-task diagnostic arm disarmed and retained | 4.315 s |
| Sonnet 5 | Valid response envelope, but refused the wrapper instead of returning the marker; closed cleanup | 10.361 s |
| Sonnet 4.6 | Exact marker, model/ownership and closed cleanup verified | 6.073 s |

These samples establish two extraction fixes, not reliable qualification of all
Claude models. Haiku's later success does not erase its earlier format failure.
Sonnet 5 explicitly identified the app-owned phrases "You are Computa" and
"Assistant refusals are not policy," plus the unexplained session marker, as
conflicting authority cues. The outer relay disclaimer did not prevent that
misinterpretation. Its response is preserved as a failed marker result, despite
successful transport and cleanup.

## Candidate 344: clarify external relay instructions

Clarify the generated app-owned instructions at their source: Computa identifies
the local application, host permission modes do not override website governing
rules, prior capability speculation is not a host access result, and the session
marker is only an opaque correlation label. Preserve actual denials, Stop, the
message/refusal option, exact schemas, user data and canonical history. Do not
strip authored prose or add automatic correction attempts to Claude.
Installed/live qualification remains pending.

## Qualification contract

Each available family will receive an independent controlled response check and
a safe local browser/terminal/file-editing workflow. The workflow uses separate
fixture folders, immutable tests, a loopback form and a uniquely checkable
receipt. Code diffs, command exit statuses, browser actions, receipt observation
and task-tab closure must agree with the native transcript.

Claude currently uses a fresh owned Incognito website session for each inference,
including tool-result continuations. Every accepted inference must carry the
exact selected model and ownership proof plus a matching closed cleanup receipt
before its tool proposal is dispatched. Gemini's retained-session behavior must
not be assumed for Claude. Website selection does not attest an immutable
backend model version.

Private evidence is retained locally in `work/claude-qualification-20261031/`,
including `evidence/sonnet55-marker340/`, `sonnet55-marker340-timeout.log`,
`direct-control-ax.txt`, and the prepared `fixtures/` cases. No fixture server or
real-mail workflow was started for the failed baseline.
