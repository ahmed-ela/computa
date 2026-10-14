# Google verification recovery

## October 8, 2026: explicit refresh

Google search and signed-in Gemini recovered in Computa 0.5.0 (34), compiled from `b6e60b77162e73a1f6ebd038b40650b820dec6a3`, without changing WebKit, the user agent, cookies, the browser profile or network settings. One **Refresh website models** action then removed Computa's saved Gemini verification checkpoint. No CAPTCHA was completed.

**Refresh cleared a stale local block; Google was already healthy before it ran.** The original cause of Google's unusual-traffic challenge remains unknown. This result establishes current browser access and local admission recovery, not a permanent CAPTCHA fix or a successful post-recovery model/harness turn.

## Issue and controlled experiments

Earlier Gemini attempts were blocked by a recognized verification checkpoint, and controlled human browsing showed Google's unusual-traffic page. Computa correctly persisted a profile-scoped checkpoint and stopped automated sessions. Restarting preserved that checkpoint. The local block subsequently outlived the external challenge: normal human browsing worked, but the checkpoint still prevented new model sessions.

The recovery experiments stopped after the first verified recovery. They used the already-installed, signed build34 and its existing browser profile.

| Step | Action | Observation | Supported conclusion |
| --- | --- | --- | --- |
| 1 | Navigate one human tab to a normal Google search for `computing`. | Actual search results appeared, including the Computing heading and Wikipedia link; no CAPTCHA. | Google search was currently accessible in the existing WebKit runtime. |
| 2 | Navigate that same human tab directly to `https://gemini.google.com/app`. | The signed-in Gemini composer appeared without CAPTCHA. A bounded preferences read still found the saved Gemini checkpoint. | The website had recovered, but Computa's local gate had not. |
| 3 | Click **Refresh website models** once at 15:53:33 UTC. | Refresh completed, its button returned enabled, the saved Gemini checkpoint disappeared, and the human composer stayed healthy. | Explicit revalidation cleared the stale local gate. |

No model task was submitted during these experiments. Refresh discovers catalogs for all website providers sequentially; it is not a Gemini-only action. The Gemini clearing result is correlated with the guarded source path, rather than a captured network trace.

Read-only audits found a persistent shared browser profile, the default WebKit user agent, and no enabled system or shell proxies. A VPN service was connected, but the ordinary route was not through its scoped tunnel and the actual Google traffic route was not established. VPN presence therefore does not establish causation. Neither network configuration nor browser identity changed during recovery.

We did not experiment with cookie deletion, profile replacement, user-agent overrides, an engine upgrade, proxy/VPN changes or repeated automated navigation: the existing environment recovered before those interventions were needed. A pause/cooldown is consistent with the result, but was not isolated as its cause. Google's [unusual-traffic guidance](https://support.google.com/websearch/answer/86640) describes several possible traffic sources; none was proven here.

## Why refresh works

Two independent states are involved: Google's current verification requirement and Computa's remembered checkpoint. The checkpoint intentionally survives app restarts so opening the app or starting more tasks cannot repeatedly revisit a known challenge.

Normal human navigation records trusted Google `/sorry` verification pages, but navigating away does not clear the saved checkpoint. A healthy human tab alone is not proof that a separate owned inference page is ready or that an earlier website conversation was cleaned up.

The explicit refresh reaches `discoverModels(..., retryBlocked: true)` in `EmbeddedWebModelTransport`. It allows one owned, prompt-free recovery probe while ordinary sessions remain blocked. Clearing requires all of the following:

1. The owned provider page becomes ready and returns a valid, nonempty catalog with unique model keys and labels.
2. Disposal of that exact discovery session returns `cleanup: not_created`.
3. No newer in-memory gate is present, and the persisted checkpoint ID still equals its value captured before the probe. A newer failure takes precedence.

Only then does the transport remove the saved checkpoint and in-memory gate. The refresh does not replay a failed prompt, resolve historical unconfirmed cleanup, or prove that a chosen model can execute Computa tools.

The relevant implementation is in [EmbeddedWebModelTransport.swift](../Sources/Computa/Browser/EmbeddedWebModelTransport.swift), [EmbeddedBrowserSession.swift](../Sources/Computa/Browser/EmbeddedBrowserSession.swift), [EmbeddedHumanVerificationStore.swift](../Sources/Computa/Browser/EmbeddedHumanVerificationStore.swift) and [AppState.swift](../Sources/Computa/State/AppState.swift). The behavior described here was verified against committed build34, separately from unfinished ChatGPT message-expansion work.

## Current recovery and deferred follow-up

When a recognized challenge appears, stop automated attempts. Once Google and signed-in Gemini work again in the human browser, use one **Refresh website models** action. A successful refresh permits a new task; it does not revive the failed task automatically. If verification persists, retain the block instead of looping.

Manual refresh is a brittle user experience because users must clear Computa's remembered state even after the website recovers. The deferred improvement is event-driven recovery with one bounded, coalesced revalidation per provider/profile on the next user request after a credible recovery signal. Hold the new request's prompt until the existing readiness, catalog, disposal and unchanged-checkpoint checks succeed. Preserve a newer checkpoint and fail promptly while an active challenge remains. Do not use periodic probing or repeat Send.

Before adopting that behavior, test stale-gate recovery on the first request, active challenges, concurrent requests sharing one probe, newer checkpoints appearing during recovery, restart persistence, failed probe disposal and uncertain older-session cleanup. Recovery of a stale local gate and prevention of Google's initial challenge are separate work: eliminating the first-request challenge still requires evidence about the external trigger. Further experiments were deliberately deferred after this recovery so other work can continue.

## Evidence

The checked-in [finite recovery receipt](evidence/google-verification-recovery-2026-10-08.json) records the installed candidate, observations, unchanged settings, limits and SHA-256 manifest of the original local experiment records. It is a curated summary, not a replacement for raw provider or network evidence. The originals remain under `work/google-captcha-experiments-20261008` in the local qualification workspace. All five manifest hashes were independently checked, and the unrelated working-file hashes were unchanged by the experiments.

The earlier candidate32 CAPTCHA observations remain historical in [WEBSITE-MODEL-CHOICES.md](WEBSITE-MODEL-CHOICES.md). No post-recovery model prompt was sent; per-model qualification and historical unconfirmed cleanup remain open.

## October 13, 2026: automatic recovery and a later recurrence

Installed Computa 0.7.0 (88) adds event-driven recovery for a stale Gemini checkpoint. A settled, ordinary human Gemini landing document can request one prompt-free discovery probe while the app is idle. The document must still belong to the human browser, have the same committed generation and URL, and have the same saved checkpoint. Borrowing the document for tools or changing it revokes that candidate. A newer checkpoint, active task, cancelled probe, invalid catalog or unconfirmed probe disposal prevents clearing. Explicit refresh remains available; neither path replays a stopped prompt.

The installed test seeded one disposable stale checkpoint while Google was already healthy, restarted the app, and navigated one human tab to Gemini. The checkpoint cleared automatically after guarded discovery and disposal. No manual refresh, prompt, CAPTCHA action, engine upgrade, user-agent change, profile reset, cookie deletion or network change was used. The seeded checkpoint was removed, the owned human tab closed, and the browser pane restored. The native cohort covering recovery passed 255 test executions; the seeded installed test establishes local recovery, not removal of a live Google challenge.

A subsequent Gemini 3.8 Flash browser task passed: it opened a local flight form, read it, filled the exact flight reference, submitted it, read the exact result and closed its task tab. All seven website inferences had verified model selection, first-message ownership and confirmed cleanup. The task took 63.638 seconds.

The next Gemini code task was blocked before its first website submission. It started about 11 minutes 38 seconds after the successful task's last verified release, rather than immediately after its seventh inference. The owned native page had reached Google's trusted `/sorry` route; one ordinary human navigation then showed the unusual-traffic page and CAPTCHA. Testing stopped. This recurrence means build88 does **not** establish permanent CAPTCHA prevention, and the timing does not identify a request-rate threshold.

The actual runtime was macOS 26.5.1 with system WebKit 21624.2.5.11.4. The compatibility tokens in the default user-agent string do not identify the installed engine version. The successful task and later challenge occurred on the same runtime and profile, so these observations do not establish that an old WebKit version caused the challenge. Seven fresh website sessions within one task are a concrete source of session/navigation traffic worth investigating; their causal role and Google's threshold remain unknown. Google's guidance lists possible traffic-related causes, but does not diagnose this Gemini session.

Local checkpoint recovery and prevention of an external challenge remain separate claims. The finite installed recovery and recurrence records are preserved in the private qualification workspace; no CAPTCHA was completed during either recorded observation.

On October 14 at 02:06 UTC, one ordinary human navigation in installed build90 again showed the signed-in Gemini composer without a CAPTCHA. The real recurrence checkpoint cleared through automatic recovery, with a finite `verified / healthy_human_document` report. No manual refresh, model task, CAPTCHA action, engine or profile change, cookie deletion, user-agent override or network change was used. The inspection tab closed and the browser pane returned to its previous state. This confirms recovery from that checkpoint, not prevention of another challenge or Google's original cause.

## Gemini conversation lifecycle

Gemini now retains one owned temporary conversation through a native user turn's tool loop, then closes it at completion or cancellation. A separate user follow-up starts fresh. ChatGPT and Claude retain their existing per-inference lifecycle. This reduces conversation creation and navigation; it does not reduce the number of model submissions or truncate the full request sent at each step.

Reuse requires the same native turn, transport generation, selected model, owned document and first-message fingerprint. The next request must contain the exact accepted history, the output items actually emitted to the native engine and one matching result for every tool call. Duplicate keys, forged IDs, altered arguments, changed configuration and extra user input fail before Send. Actual engine-assigned tool-result IDs remain part of the subsequent history.

Each submission has a new private marker and an exact outbound-body digest. While the next user bubble is absent, read-only checks can reverify the prior body but cannot expose an answer or prove the pending prompt. An append crossing an awaited digest discards that read; a fresh read must verify the current body. No insertion or Send is replayed.

The version2 transaction journal distinguishes `yield_verified` from physical closure. Intermediate tool handoffs retain the owned conversation and never count as cleanup. Final `release_verified` requires a saved receipt from closing that exact session. Uncertain delivery, cancellation or a changed proof revokes reuse; cleanup remains separately evidenced.

Native engine and browser fixtures establish the lifecycle and traffic reduction independently of live provider behavior. Preventing Google's external challenge still requires a bounded live comparison; the exact Google trigger and permanent CAPTCHA prevention remain unproven.

The build91 source passed 223 native tests and 441 browser-adapter tests. The bundled native engine completed six tool calls and a final answer using one start, seven Sends and one finish. The real WKWebView race fixture separately verified a distinct second answer against its current prompt digest after discarding the crossed read; changing the first body still failed ownership. These are offline qualification results, not installed or live Google evidence.

## October 14: distinguish prompt rendering from verification challenges

Controlled installed attempts in builds91 through94 reached Gemini without a CAPTCHA, then stopped before any native tool call because the new full-prompt ownership check rejected the rendered message. This was a different failure from Google's unusual-traffic page. No CAPTCHA was solved and no engine, user-agent, cookie, profile or network setting changed.

Build94's bounded diagnostic identified a `div.query-text.gds-body-l` inside the owned message: one `cdk-visually-hidden` element followed by 169 `p.query-text-line` elements. WebKit's `innerText` included the accessibility element and layout line breaks; `textContent` also included that element and omitted paragraph separators. Neither representation equaled the full outbound prompt. Earlier first-message checks pinned rendered text rather than comparing it with the outbound prompt, so the successful build88 task did not rule out this discrepancy.

The build95 candidate reads the literal query paragraphs, including empty BR rows, and joins them with one LF. It excludes the leading accessibility element only after fresh heading-semantics, absolute positioning, one-pixel box, hidden overflow and zero-rect or 50-percent-inset clipping checks. Unknown markup, extra content, altered rows and conflicting roles fail closed. The same reader serves first-message, current-submission, prior-submission and post-await checks; the complete canonical digest and unique final marker remain mandatory. There is no generic text stripping or response repair.

The candidate passed 454 browser-adapter tests. A real WKWebView cohort executed 154 native tests: 153 passed, and one new fixture exposed an extra terminal editor LF in three assertions. The fixture alone was corrected to remove exactly that LF after a complete private UUID marker; all three affected query tests then passed. The production reader and ownership checks were unchanged between those native runs. The real WebKit tests cover literal spaces and Unicode, two submissions in one owned view, malformed headings and controls, prior-message changes, and ownership-preserving cleanup.

Installed build95 reached the signed-in model page without a CAPTCHA, then rejected its first message before any native tool call. The literal reader passed the strict query/header structure checks and produced 169 lines, but its 52,054 characters exceeded the 51,758-character canonical prompt by 296. The final marker line was padded. That difference is consistent with one leading and one trailing ASCII space around each of 149 nonblank paragraphs, minus the two outer spaces removed by the existing whole-message normalization. This was a framing hypothesis, not yet a measurement of every actual row. Cleanup remained unconfirmed and no prompt was replayed.

The build96 candidate compares only two complete, literal observations: unchanged paragraph bytes, or exactly one U+0020 removed from both ends of every non-BR paragraph. It chooses the latter only when the entire result equals the trusted outbound canonical for that same physical message ordinal and private owner/document/nonce context. It returns the observed slice-derived bytes, never the expected string. Mixed framing, content changes and a borrowed prior-round canonical fail closed. User indentation, trailing spaces, NBSP and formatting characters are preserved. Finite diagnostics report row counts, text-node counts, frame counts and complete-match booleans without retaining prompt content.

The candidate passed 457 browser-adapter tests. A real WebKit and finite-diagnostic cohort executed 22 native tests: 21 passed, while one new mixed-frame fixture accidentally framed all its nonblank rows and therefore represented a valid message. Correcting only that fixture predicate produced a passing rerun of the affected method. The positive test verified two submissions in one owned view and preserved user spacing; changed prior messages, malformed headers, controls and genuinely mixed frames were rejected. Installed build96 qualification remains pending. These current healthy-page observations do not prove permanent CAPTCHA prevention or identify Google's original trigger. Conversation reuse reduces session creation; its installed traffic reduction and provider-task completion must be measured separately.
