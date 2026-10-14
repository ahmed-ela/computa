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

The next Gemini code task was blocked before its first website submission. The owned native page had reached Google's trusted `/sorry` route; one ordinary human navigation then showed the unusual-traffic page and CAPTCHA. Testing stopped. This recurrence means build88 does **not** establish permanent CAPTCHA prevention.

The actual runtime was macOS 26.5.1 with system WebKit 21624.2.5.11.4. The compatibility tokens in the default user-agent string do not identify the installed engine version. The successful task and later challenge occurred on the same runtime and profile, so these observations do not establish that an old WebKit version caused the challenge. Seven fresh website sessions within one task are a concrete source of session/navigation traffic worth investigating; their causal role and Google's threshold remain unknown. Google's guidance lists possible traffic-related causes, but does not diagnose this Gemini session.

Local checkpoint recovery and prevention of an external challenge remain separate claims. The finite installed recovery and recurrence records are preserved in the private qualification workspace; no CAPTCHA was completed during either recorded observation.
