# Gemini harness qualification

This work resumes Gemini qualification on October 29, 2026. Claude remains
deferred. The broader browser-engine expansion in issue #9 is also deferred.
Gemini already uses the shared Responses, browser, terminal and file tools;
it retains one owned temporary website conversation across tool rounds.

## Installed baseline

Computa 0.7.0 (321) displayed a healthy signed-in Gemini landing page without
a CAPTCHA. The observed model picker offered 3.5 Flash-Lite, 3.8 Flash,
3.1 Pro and 4 Argon. This observation alone does not qualify a model.

The 147 Gemini JavaScript tests passed with 5,298 assertions. A focused native
cohort passed 29 tests covering shared tool contracts, model evidence,
continuation, ownership and cleanup. These are local protocol checks.

A fresh 3.5 Flash-Lite exact-marker task failed first-message ownership before
any local tool call. Its website journal records `website_ownership_unverified`;
cleanup remained unconfirmed. No prompt was replayed. The native runtime also
recorded a generic provider error, which must not replace the more specific
website evidence or be treated as proof of provider demand or quota.

## Measured failure

The first-message parser recognized Gemini's rich query scaffold, including
the message text and marker, but rejected its accessibility heading. Finite
diagnostics showed a semantic heading with absolute positioning, hidden
overflow and an all-zero CSS clip rectangle. Its computed box did not meet
the adapter's strict 1-pixel requirement. The parser therefore returned no
canonical text and reported that the marker was not on the final line.

The actual width and height were not recorded. This evidence establishes a
specific parser rejection; it does not establish any other rendering defect.

The repair recognizes fully clipped accessibility headings without requiring
a particular box size. It retains the exact structural scope, clipping and
noninteractive-heading checks, complete literal-row reconstruction, full
outbound-prompt equality, session marker, hash, model and ownership checks.
Unrecognized markup and altered message contents must still fail closed.

The candidate passes 150 JavaScript tests with 5,429 assertions and 31 native
tests. The old JavaScript reproduces the measured marker rejection; changing
only the adapter resource makes the same native test binary pass both new
WebKit cases. The native old-resource failure is recorded as its actual
`InvalidTransition(deinit)` error, not relabeled as the live marker diagnostic.
Negative cases retain rejection for visible or partly clipped headings,
interactive heading content, changed payloads and changed eligibility during
an awaited digest. These checks do not replace live qualification.

## Live acceptance gates

Each claimed model needs a completed response matching its independent marker,
verified model/session evidence and confirmed cleanup. Tool qualification also
requires actual native tool calls and independently checked results.

The combined local fixture requires a code repair, unchanged test/sample
inputs, passing Python tests, and a computed reference submitted through the
built-in browser to a loopback form. A separate server ledger must contain
exactly one accepted submission and a receipt read matching the final answer.
The model must close its task-created tab and preserve existing user tabs.

Local fixture passes, installed artifacts, live provider results and external
account restrictions remain separate. No real mail or external submission is
part of this Gemini qualification.
