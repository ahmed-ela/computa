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

The candidate passed 457 browser-adapter tests. A real WebKit and finite-diagnostic cohort executed 22 native tests: 21 passed, while one new mixed-frame fixture accidentally framed all its nonblank rows and therefore represented a valid message. Correcting only that fixture predicate produced a passing rerun of the affected method. The positive test verified two submissions in one owned view and preserved user spacing; changed prior messages, malformed headers, controls and genuinely mixed frames were rejected.

Installed build96 measured the actual framing: 149 text rows each began and ended with a space, 20 rows contained BR, and all 169 frame-stripped rows equaled the trusted prompt. First-message binding and the initial submitted-prompt digest were verified. A later read-only model check rejected `observe_body` after 8.025 seconds, before any native tool call; cleanup remained unconfirmed. No CAPTCHA appeared. The available diagnostic combines missing payload, payload limit and changed object-pointer predicates, so it does not yet identify which caused this later rejection. Raw `innerText` equality in that diagnostic remains false because it includes presentation markup; it cannot diagnose the projected prompt.

The ownership implementation covers a framework replacing a first message during an awaited read, but not an identical replacement completed between reads: the next invocation captures the current first-message nodes while the submission record retains older pointers. The build97 candidate certifies only a disconnected whole first-message replacement using the existing exact private/native first fingerprint, full canonical and owner/document/temporary-route checks. It discards that read and requires a fresh full inspection; it neither proves an answer nor replays Send. Body-only replacements and later-message aliases remain rejected. Finite cause and pointer booleans will distinguish the remaining branches in installed testing.

Build97 passed 460 browser-adapter tests. The initial full adapter run hit the five-second timeout of an existing seven-round, 169-line stress fixture while native compilation was active; giving that single test a ten-second bound produced a complete passing rerun without changing production or assertions. The native cohort executed 25 methods: 24 passed, and the new positive fixture inspected the provisional discard too early. Correcting only the observer timing let it verify the discard certificate and the subsequent consumed receipt/current pointers; the affected method passed. Full canonical hashes, model, generation, one Send and cleanup assertions were preserved, and body-only/changed-content negatives passed. Installed qualification remains pending.

Installed build97 used one physical website session for two verified submissions. Its first inference completed and yielded a native `browser_open` call; the second submission was verified before a subsequent model check rejected a whole-root replacement. Finite diagnostics confirmed both old nodes were disconnected and both current nodes connected at sequence2. The normal reader's current-message hint requires the original pointers, so its false projected-match flag at that rejection was an unavailable comparison, not evidence of changed prompt bytes. The task stopped after 16.036 seconds with one tool call, unconfirmed website cleanup and no CAPTCHA.

The strict task audit also found that Gemini changed `_` to `-` in the requested fixture URL. Navigation completed on an unsupported route; no flight lookup or form submission occurred. This is a separate model-copying failure, retained in the qualification evidence without aliases or normalization.

The build98 candidate supplies at most two native outbound-digest pins for the already-dispatched current and previous submissions; prepared, unsent text supplies no recovery pin. A verified, disconnected whole-root replacement can be compared against its matching private canonical only within the bounded recovery helper. The actual literal bytes, native and private digest, unique marker, owner/document, first-message pin, root order and pending parent are checked again across hashing. The helper returns a discard receipt; one fresh inspection must consume that exact certificate before current or pending proof can be exposed. It retains the previous-body check when the next body is absent or appends during recovery. Body-only, connected-old-node, wrong-pin and changed-content cases remain rejected. A separate read-only continuation preflight runs before preparation can focus the editor; later editor races still fail without replay.

Build98 passed all 463 browser-adapter tests and all 27 selected native ownership and Gemini transport tests. These include three-round lineage, read-only preflight before editor focus, pending-body arrival during hashing, and rejection of changed content or invalid native pins. Installed qualification remains pending. These healthy-page observations do not prove permanent CAPTCHA prevention or identify Google's original trigger. Conversation reuse reduces session creation; a completed provider task and confirmed final closure remain separately required.


Installed build98 opened the exact requested fixture route and completed two native tools (`browser_open` and `browser_read`). It reused one website session for three inferences and verified the first two submissions. The third Send failed after 16.144 seconds. The finite adapter log identifies the previous verified record at sequence2, requested sequence3, in the pending-parent append branch: the newly sent third body appeared while the adapter was hashing the previous body. The read-only append helper correctly refused a mutation action, but the post-Send fallback incorrectly revoked the session. This evidence does not establish another root replacement. No CAPTCHA appeared; the task and website cleanup remain unqualified.

The next candidate separates single-click dispatch from body verification. A successful Send acknowledgement carries no accepted answer or submission proof; only the next fresh read-only inspection may prove the current body. This keeps all pre-Send ownership checks and prevents a normal post-click append from being routed through the read-only helper during mutation acknowledgement. Build99 passed all 464 browser-adapter tests and all 73 selected native Gemini, ownership, API codec and API server tests. The focused Gemini acknowledgment cohort passed 31 tests. Installed qualification is pending.


Installed build99 was blocked after 0.694 seconds, before sending a task prompt or executing a native tool. A normal human navigation in Computa's persistent built-in browser confirmed a live Google `sorry` page with the unusual-traffic CAPTCHA. No CAPTCHA was completed. This recurrence means permanent prevention has not been established; the post-Send race fix remains unqualified live because this request never reached that path. Automated Gemini checks stopped and confirmation was requested under the computer-use CAPTCHA policy.

## October 14: one-session task passes; fresh checkpoint recurs

After restarting into build100, an ordinary human Gemini landing page was healthy again. Guarded discovery and disposal cleared the existing checkpoint without solving a CAPTCHA or changing the engine, profile, user agent, cookies or network. Restart, elapsed time and reopening the page were not isolated, so this observation does not identify what cleared Google's challenge.

A fresh Gemini 3.8 Flash flight-form task passed in 68.512 seconds. Six valid built-in browser calls opened, read, filled, submitted, read the result and closed the task tab. Seven verified website inferences reused one physical temporary conversation; all complete prompt hashes and model/ownership checks passed, and final website closure was confirmed. This qualifies the post-Send acknowledgment fix and one-session continuation for this task. One physical session is not a measurement of total network requests.

The next code task failed after 0.474 seconds, with zero tools. The exact installed process classified Google's trusted HTTPS `/sorry` route at native sequence0 before dispatching any provider adapter. Its new checkpoint ID differed from the recovered checkpoint. This was a fresh external challenge, not restoration of a stale app warning or a message-text false positive. No code editing or terminal behavior was exercised in that failed attempt. Automated Gemini testing stopped again.

The engine and persistent profile remained the same across recovery, successful inference and recurrence. These results do not establish an old WebKit cause or permanent CAPTCHA prevention; Google's specific trigger remains unknown. Conversation reuse reduces physical session creation but did not prevent the challenge between these tasks.

The next native cleanup candidate records whether any provider adapter was ever dispatched, including calls with lost replies. It can dispose of a private checkpoint view only when no adapter, preparation, model selection or submission occurred, and the captured view, lease, document generation and trusted checkpoint URL still match. It evaluates no checkpoint JavaScript and preserves the provider gate. Prior activity, replacement documents and foreign URLs retain unconfirmed cleanup. This repairs local disposal, not Google's verification decision.

The candidate passed eight selected real-WebKit transport tests, covering untouched Finish and Cancel, blocked admission after disposal, changed documents and checkpoint URLs, foreign pages, redirects during awaited adapter work and challenges after submission. All 468 browser-adapter tests passed. An older diagnostic fixture was updated to reject a second nested DIV because one sole immediate DIV is now readable for diagnostic purposes; ownership rejection remains mandatory. Installed build101 qualification is still pending.
