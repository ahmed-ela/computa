# Gemini harness qualification

Gemini qualification resumed on October 29, 2026. Gemini uses Computa's
shared Responses interface and browser, terminal and file tools, retaining
one owned temporary website conversation across tool rounds. Claude and the
broader browser-engine expansion in issue #9 remain outside this work.

## Ownership failure and repair

The installed 0.7.0 (321) baseline displayed a healthy signed-in Gemini page.
A fresh 3.5 Flash-Lite marker task nevertheless failed with
`website_ownership_unverified` before any local tool call. Cleanup was
unconfirmed. Its evidence was retained and the prompt was not replayed.

Gemini's rich user-message scaffold contained the complete prompt and marker.
The parser rejected its accessibility heading because it required an exact
1-pixel CSS box. Captured facts established a semantic, absolutely positioned
heading with hidden overflow and a zero-area clip rectangle, but
`onePixelBox=false`. Actual dimensions were not collected. Rejecting this
heading caused canonical text extraction to return empty and the ownership
check to report `marker_not_final`.

Build 322 removes the box-size requirement for an otherwise fully clipped
heading. It retains semantic and structural checks, the absolute-position and
hidden-overflow requirements, complete clipping, noninteractive header
validation, exact full-payload reconstruction and equality, marker and
fingerprint verification, and the existing model/session ownership checks.
The `onePixelBox` diagnostic remains available.

## Local regression evidence

The candidate passes **150 Gemini JavaScript tests** with 5,429 assertions
and **31 focused native tests**. New JavaScript cases fail against the old
adapter and pass against the candidate for both zero-area rectangle clipping
and `inset(50%)` clipping with synthetic non-1-pixel dimensions.

Native WebKit cases also pass after replacing only the adapter resource in
the same test binary. The old-resource native failure remains recorded as
its actual `InvalidTransition(deinit)` error; it is not relabeled as the live
marker diagnostic. Visible or partially clipped headings, interactive header
contents, changed payloads and eligibility changes during digest evaluation
remain rejected. Synthetic dimensions are test inputs, not measurements of
the live page.

## Installed build 322 results

| Model | Controlled result | Qualification boundary |
| --- | --- | --- |
| Gemini 3.5 Flash-Lite | Exact marker returned in 7.476 seconds; model, full prompt and temporary-session cleanup verified | One completed marker run; no local tools requested |
| Gemini 3.8 Flash | Code, terminal and local-browser task completed in 91.145 seconds across 10 verified inference rounds and 9 tool calls | Successful composed workflow with one safely rejected and recovered patch-format error |
| Gemini 3.1 Pro | Fresh navigation reached Google's verification route before prompt submission or model-selection proof | Blocked; no model response or local tool qualification |
| Gemini 4 Argon | Not exercised in this qualification | Unqualified |
| Claude | Deferred by scope | Not tested |

The fixed Flash-Lite run verified a complete 61,456-character, 270-line
payload. Its live accessibility heading still reported `onePixelBox=false`
with complete rectangle clipping. The original marker failure therefore has
both a controlled reproducer and a live successful verification after the
repair. This does not establish broad repeatability across models or account
conditions.

The 3.8 Flash task read a local invoice exercise, repaired only its aggregation
helper, ran six passing Python tests and computed a reference. It opened the
loopback fixture in the built-in browser, filled the observed field, used the
fresh post-fill submit reference, read the receipt and closed its task-created
tab. The independent fixture audit confirmed unchanged protected inputs, the
code result, exactly one accepted POST and the matching receipt. No real mail
or external submission was involved.

The first `apply_patch` proposal had malformed hunk formatting and was rejected
before modification. The next proposal corrected the patch and succeeded.
This is evidence of safe rejection and automatic recovery, not zero tool
errors. The captured native proposal is downstream of adapter/codec processing;
raw website response bytes were not retained, so the precise origin of that
formatting error is not independently established.

All ten completed model responses retained the same session, document and
first-message fingerprint, while each completion recorded its own submitted
prompt fingerprint and advanced the response count by one. Completion proof
preceded each tool dispatch. Continuation `submission_verified` journal rows
can have an empty prompt fingerprint while pending; the completed-response
records contain the required proof. The final website release and cleanup
receipt were verified, separately from closing the task's local-browser tab.

## Remaining provider blocker

The later Pro attempt stopped after 1.299 seconds with
`website_verification_required` and zero tool calls. Its first native
inspection recorded a fresh server redirect to Google's `/sorry` route,
with a settled document and no Gemini document commit. The native classifier
uses the HTTPS Google checkpoint route, not a loose CAPTCHA keyword match.
The session was admitted before that first failure, so a stale saved block
alone does not explain this attempt. The failed untouched inference view was
closed with a saved cleanup receipt; no prompt was replayed.

A subsequent single reload of the normal human Gemini tab also displayed a
Google CAPTCHA. That UI observation is separate from the task's finite route
diagnostics. The reason Google selected the checkpoint remains unknown; the
evidence does not attribute it to WebKit version, request rate, IP reputation,
model choice or the heading repair. The task failed before the Gemini adapter
could submit a prompt or verify Pro selection.

Further Gemini live attempts remain paused at the verification boundary.
Resolving a displayed challenge and completing a fresh controlled qualification
are separate steps. The successful Flash-Lite and Flash runs do not establish
that the Google checkpoint is fixed, nor that Pro, Argon or Claude is qualified.

Both local fixture servers were stopped and their process/port shutdowns
verified. The second Flash-Lite tool fixture was prepared but never dispatched.
The installed app is signed Computa 0.7.0 (322), source `46da292`; its artifact
audit passed. It is not a notarized or published release.
