# Computa TODO and validation

## Rename checkpoint — 28 September 2026

The product and repository are now **Computa**:
[ahmed-wlb/computa](https://github.com/ahmed-wlb/computa),
[computa.wtf](https://computa.wtf). The app, executable, Swift targets,
`Computa.xcodeproj`, `Sources/Computa` and `Tests/ComputaTests` use that name.
Existing storage, bundle, preferences and pairing identifiers remain unchanged; `MACTOPUS_*` environment variables, `mactopus-5` source pin
and `mactopusClickability` protocol field remain unchanged. Installers can migrate
one compatible legacy `~/Applications/Mactopus.app` to `Computa.app`; they
reject both-present installations and either running process name. Backups
retain the original bundle name, rollback restores its original path, and
Computa chat and model data stay in their existing locations.

The Computa Release Xcode build and WebUI type check/production build passed.
Rename validation passed 58 selected Swift cases, 21 Bun identity/runtime-source
cases, with 10 additional opt-in signing tests skipped; 36 Bun source-installer/packaging/
signing cases, 16 Python packaging cases, and 67 extension cases. These separate
runs are not added to the historical overlapping totals below.

The signed `v0.1.0-preview.1` Computa DMG was created and verified. Its actual
mounted installer migrated `~/Applications/Mactopus.app` to
`~/Applications/Computa.app`, backing up the old bundle at
`~/Applications/Computa Backups/release-rsrkzkkt/Mactopus.app`. All 5,559 checked
pre-existing preferences, CodexHome and model files were byte-identical before
first launch. The UI launched as Computa with prior tasks populated, the Qwen
default retained, MLX connected and Accessibility granted, then quit normally.

Verified SHA-256 values:

| Artifact | SHA-256 |
| --- | --- |
| Signed Computa main | `86e28876f804c7aca7ce30781b784efd90548465c259639305dc3c15d76a3e69` |
| Signed agent runtime | `a639c86df85254f80beaa917d9245abbfa1a0041a184568c212b1df6a2415709` |
| Computa preview DMG | `49694579017535d160a05faea805fba9b80ecc8dbfac3d431f8e64d9b20db849` |

The Computa DMG, manifest and `SHA256SUMS` were uploaded to the draft release;
GitHub digests match the local files. The preview remains a draft and is **not notarized**. This existing-Mac
migration/startup check does not establish clean-Mac acceptance, repair the
model stream/final-answer failure, complete the original lookup, or establish
the controlled OS-process Stop check. Earlier app hashes, test counts and
live outcomes remain historical evidence; no renamed live CLI task is claimed.

## Earlier lookup checkpoint

Historical results below use the current product name, Computa. Original
artifact paths, runtime labels and hashes are preserved.

Earlier lookup checkpoint (28 September, before the CLI release): the reference interface was
implemented, tested and installed as
`fa90ee67d98f306d27195b113f5c2947d5218e13eacfd29594437d17f2a743a1`,
but the lookup is not fixed. The tenth original attempt ended after 184.751s,
with six valid calls and visible prose promising to continue, without the
requested conversation, title or source. Search was exposed in both overview
reads but unused. All ten original attempts remain unsuccessful. The latest
Lumen retest also failed; working safeguards do not establish task success.

## Pre-rename CLI and distribution checkpoint — 28 September 2026

CLI execution and command-session polling are implemented with live output,
exit status, exact task/turn ownership, existing approvals, and scoped Stop/quit
cleanup. A live command exposed inherited blocked signals at the Swift process
launch boundary. The child-only signal-mask/disposition fix is implemented;
its regressions prove parent state is unchanged and a spawned child runtime can
receive SIGCHLD and reap its own command. The same pinned engine completed a
standalone command in 11 ms when launched with signals unblocked.

Pre-rename source validation: 135 unique affected Swift cases passed after
corrections, including the two new signal regressions; 13 Bun packaging/signing
tests and 11 Python installer tests passed. UI type checking and production
build passed. These totals do not add overlapping reruns.

The earlier Computa signed preview DMG was built and verified before the rename, and its installer successfully
updated this Mac while preserving the previous app. It reused verified existing
MLX/model data and bootstrapped pinned uv/Python. Installed main SHA-256:
`2a481166b7d9a8540d0cb13ac0dc59d8ad677a54dd5da6bc15bbfdc97af0fbe6`.
Runtime SHA-256:
`3a11d1e7d222b76f077a06a7fc828c806544225a61844204db6ebf2b80242ff8`.
The app is Developer ID signed with secure timestamps, **not notarized**.
This is an existing-Mac update test, not a clean-Mac/Gatekeeper acceptance test.

Live command retest: on the installed signal-fixed build, Qwen invoked
`exec_command` with `/usr/bin/uname -m`; the runtime returned `arm64` and exit
code 0 at 14:35:30 UTC. The full task still failed because its final reply hit
`unstreamed_final_text` (18227 bytes, 6 events, 1 item). Command execution and
exit handling passed; final-answer publication did not. Controlled live Stop
with an independently observed OS process exit remains unrun on this build.
Finish that check before promoting the preview for distribution. Packaging and
command documentation are in `docs/DISTRIBUTION.md` and `docs/COMMANDS.md`.

## Remaining work

- [ ] **Complete the original blind lookup.** Address the measured behavior:
  the model skips an exposed Search control and ends with a promise instead of
  the requested result. Add a generic completion regression, then repeat the
  unchanged prompt without a known-answer tab, site-specific rules or hints.
  Acceptance requires a displayed answer supported by observed content and its
  source URL; all ten recorded original attempts remain unsuccessful.
- [ ] **Diagnose the MLX stream/final mismatch.** Trace the permitted producer
  and consumer event boundary behind `unstreamed_final_text`, including
  compaction. The rejecting guard is known; its exact producer cause and the
  cause of the older generic stream error remain unproven. Add a focused
  regression for the demonstrated cause without fabricating a terminal event
  or treating buffered text as a verified final answer.
- [ ] **Clarify recovery after invalid preflight requests.** Make the unresolved
  operation and valid correction clear to the model and user. A fresh menu or
  a successful action on a different target must not silently erase failed
  intent. Preserve exact target correlation, approval, single dispatch and
  verification requirements; distinguish corrected/not performed from success.
- [ ] **Finish live CLI acceptance in the packaged app.** `exec_command`
  and `write_stdin` are implemented with bounded live output, exit status,
  exact task/session correlation, existing sandbox/approval rules and scoped
  Stop/quit cleanup. The live command returned the right output and exit 0, but
  final-answer publication failed as recorded above. Resolve that known stream
  error and perform the controlled OS-process Stop check before promotion.
  [Command documentation](docs/COMMANDS.md) describes use and limits.
- [ ] **Verify remembered extension pairing.** Complete the normal extension
  setup and Pair and remember flow, then verify reconnection after restarting
  Chrome and Computa. Recorded live evidence covers only a one-time connection.
- [ ] **Finish notarization and verify a clean installation.** The
  [distribution workflow](docs/DISTRIBUTION.md) builds a DMG with a pinned
  Python/MLX/model installer and backed-up app upgrades. Submit/staple the
  Developer ID release using the maintainer's notarization credentials, then
  test launch, runtime/model setup and browser permission/pairing on a clean
  Mac. A local signed update is not clean-machine or Gatekeeper acceptance proof.
- [ ] **Promote the distribution preview after its remaining gates.** Keep the
  DMG as a draft until the live CLI/Stop acceptance checks pass. Notarization
  and clean-Mac validation remain separate gates for normal distribution.
  This checkpoint preserves the source, tests, packaging scripts and measured
  unsuccessful live results; it does not claim the original lookup is fixed.

## Pre-rename reference-interface validation and final outcomes

New threads advertise distinct fresh-page, region and continuation reads, and
`press`, `follow` and `fill` use typed host-issued references to published rows.
Legacy threads retain their original tools. Resolution still uses the existing
canonical target, approval, retry and verification paths; the menu supplies no
new action authority. A bounded same-target read can correct only an eligible
undispatched prerequisite as corrected/not performed. It does not replay input,
clear dispatched action debt or reset retry limits. The complete interface and
lifecycle contract is in [BROWSER-READ-CONTINUATIONS.md](docs/BROWSER-READ-CONTINUATIONS.md).

Interface and menu-correction validation covers 410 unique Swift cases:
408 passed, two optional real-Qwen tests skipped, zero remaining failures after
fixture-assumption corrections. The latest broker/reference run passed 72 cases:
71 overlap earlier coverage and one is a new regression. Broad/routing/targeted
runs overlap and are not summed as separate passes. The final typed-routing
check covers four scenarios. The separate Bun measurement run passed 37 tests/
213 assertions. These source checks are separate from installation and the failed live result.

The latest source guard gives enabled, settable browser textbox/searchbox rows
only a fill action in the model menu. Legacy, native and combobox presses are
preserved, with evidence and approval checks unchanged. Release, signature and
installed hash checks passed for `fa90ee67…`; other bundled components are
unchanged from `beef8fcc…`. Backup: `2026-09-28T13-33-18-815Z-yhGdb0`.
The app was running as PID 43332 at this checkpoint. The fresh unchanged Lumen
prompt was submitted at 13:34:11.919 UTC and started at 13:34:13.411 UTC on
28 September, with 52 user tabs plus one owned fixture and zero attachments.
Its completed failure and final cleanup are recorded below.

The first live interface task on `beef8fcc…` took 494.477s, 11 calls and one compaction. Four
approved inputs were verified. A malformed field press was rejected before
input, leaving unresolved invalidArguments evidence. The record supported a
correct 376-byte raw answer, but the app reported Outcome not verified. This
is a failed product result, distinct from the earlier Meridian visible pass.
The guarded-menu retest on `fa90ee67…` ran 579.092s, with 12 model calls,
two compactions and three approved, verified inputs. The fill-only field menu
was observed after filling. Call 8 reused a stale button reference after two
newer reads. One fresh host read corrected that undispatched prerequisite as
preflight_corrected_not_performed; later dialog opening and filling verified.
Call 11 selected the current Close button with dialog_opened while the dialog
already existed, so it was rejected before input. A fresh read in this new
recovery episode left its invalidArguments debt unresolved. Following Show
results then verified, but terminal unstreamed_final_text ended the run without
a final answer or matching-record read. This is a task failure. The finite
guard condition does not prove its producer cause or explain the older error.

The tenth original lookup started at 13:45:12.920 UTC on 28 September with the
exact prompt, a fresh neutral home, no hints and the known answer closed. It
ended after 184.751s by the runtime (184.752s by rollout timestamps), with six
valid model calls, zero compactions, no inputs or approvals, no rejections or
host recoveries, and no stream error. After reading the home page, binding
another existing chat and reading its overview, the model published a 179-byte
promise to check another tab, then ended. No requested chat, title, source or
supporting passage was returned. An enabled Search button with current action
references was exposed in both calls 3 and 6; neither Search nor the offered
overview continuations was used. This is skipped discovery and premature final
prose, not a hidden capability, publication failure or verified negative search.
All ten original attempts remain unsuccessful; original acceptance stays open.

Final cleanup verified all 52 baseline user tab identities and URLs unchanged.
The unattributed extra fixture-home tab that appeared at 13:36:28 UTC was
preserved; all three known owned test tabs were closed. Final Chrome state has
53 tabs and zero agent attachments. The owned fixture server session 81982 stopped with
exit 130 and no matching process remained. At that checkpoint Computa was running as PID
43332, with the unchanged fa90ee67 main, the one-time Chrome connection and
Ask Every Time. Remembered extension pairing remains unconfigured.
The redacted original and Lumen review files and reference-interface validation
are kept in the thread's outputs, outside this repository. The source patch is
implemented, tested and installed; the requested lookup remains unfixed.

## 1. Establish the result in Chrome

- [x] Use Chrome to perform the user's task:

  > there was a chat thread in chatgpt on chrome that had a list of all research papers that came out from openai can you find it

- [x] Verify the candidate from its actual displayed content and source URL,
  not its title or sidebar. A matching conversation does not establish that its
  paper list is exhaustive or factually complete.
- [x] Preserve existing tabs and drafts. Do not send website messages. Keep
  personal conversation content and URLs out of committed benchmark artifacts.

## 2. Measure unchanged Computa

- [x] Submit the same task to a fresh chat in the installed Computa with
  Qwen 3.5 4B. Do not provide the answer, candidate title/URL, or a tool sequence.
- [x] Avoid contaminating the starting state: do not leave the discovered
  conversation newly opened, selected, or attached by Codex as a shortcut or
  debugger conflict. Record any unavoidable starting-state differences.
- [x] Observe the production app's own tool calls and task-scoped recording.
  Record elapsed time, input/output successes and failures, inventory coverage,
  document coverage, continuation use, compactions, and final-answer support.
- [x] Distinguish failure to read/search from a verified negative result. Do
  not count listing tab metadata as reading those pages.

## 3. Implement the generalized fix from the measured gap

- [x] Distinguish metadata, navigation, UI controls, and readable content using
  observed structure. Main-region membership alone is not content evidence:
  toolbars can live inside main regions.
- [x] Expose useful content efficiently with explicit source, field, and output
  truncation. Keep controls/navigation reachable and preserve action authority.
- [x] Support bounded continued reading when the exposed evidence is insufficient.
  Do not hardcode ChatGPT, paper names, this thread, or a particular site.
- [x] Preserve host-owned read coverage across compaction so summaries cannot
  promote incomplete observations into an exhaustive inspection. Accumulate
  coverage only within the same immutable source observation, filters, and
  subtree; never combine different captures into apparent completeness.
- [x] Match evidence requirements to the conclusion: a title lookup can use
  metadata; content lookup needs supporting content; an itinerary answer needs
  observed itinerary details. Structural checks do not guarantee semantic truth.

## 4. Validate generalization

- [x] Repeat the original blind lookup and compare with the unchanged baseline.
  The fixed-app trials and instrumented recovery remain unsuccessful; completion
  of the comparison is not lookup success.
- [x] Test different task types: exact-title lookup, document-content lookup,
  email/detail extraction, and a native-app read, preferably with inert fixtures.
- [x] Evaluate misleading sidebar matches, controls inside main regions, absent
  landmarks, truncated fields/trees, virtualized content, stale/replaced source
  observations, pagination, and compaction without replaying completed actions.
  Record unit and live coverage separately: present decoys do not prove rejection,
  and the passing pagination run did not trigger scoped stale-reference recovery.
- [ ] Complete the original blind lookup with the requested conversation verified
  from observed content and source URL. Site candidates and the Search control
  are now exposed, but correct control selection, search progress, and supported
  completion remain unresolved; synthetic passes do not satisfy this criterion.
- [x] Report correctness, unsupported claims, refusals, latency, and coverage
  separately. Preserve background-only operation, permissions, pairing, chats,
  and existing user tabs. No production-readiness claim from one successful task.

## Historical lookup evidence

The prior host's read-continuation patch passed 1,580 tests (49 skipped) and a
signed Release build, and was installed on that host. Its read-only installed-app
trial retrieved all 42 then-current tab entries via the new inventory continuation
without the old cursor error. This is historical evidence, not reproduced on the
current Mac. That trial **failed** the lookup: Qwen consumed no page-content
continuations and relied on navigation/title information. Two later presses were
rejected before dispatch; the trial was stopped after 88.322 seconds. Two
compactions completed, but no verified matching answer was produced. This is a
pagination-path success, not a content-search success or the comparison above.

The independent Chrome lookup on this Mac is now verified through displayed
conversation content and its actual source URL after selecting another
already-signed-in account. This does not certify the bibliography's factual
exhaustiveness. The answer tab was closed, existing user tabs/drafts preserved,
and no website messages sent. The measured blind baseline recorded the account-selection change and used a
neutral home tab without reopening the answer. It began with 49 native Chrome
tabs and zero agent-owned/attached tabs; possible sidebar/history recency, Chrome
update/restart, and the live direct connection are additional recorded differences.

Current preparation added setup compatibility fixes, measurement tooling, and
inert fixtures. The signed Release build is installed; isolated Qwen text
readiness and a one-call Chrome inventory check passed. The fresh blind lookup
then issued eight calls and aborted after 230.716 seconds without an answer:
one inventory page (25 of reported 46), one truncated content page, two presses
rejected before dispatch, two malformed reads rejected, and a final interrupted
read. It used no continuation and produced no compaction records. This is an
unsuccessful lookup, not a verified negative result. Transport success flags are
unrecorded and remain unknown; explicit host rejections are documented separately.
The interruption's initiating cause is unmeasured. See the linked checkpoint for
artifact identity, starting-state differences, and detailed measurement scope.
Generalized source changes now add typed read receipts, bounded body-field
continuation, structural content kinds, host-owned coverage, and clearer read
recovery guidance. The first fixed-app trial completed in 114.785 seconds with
four calls and complete returned inventory pagination, but only read the neutral
home page and asked for already-authorized search guidance. It remains an
unsuccessful lookup, with no verified negative or refusal. After general autonomy
guidance, the final fresh blind comparison ran for 493.199 seconds, made 12 calls,
and ended with a generic stream-validation error and no answer. Two completed
compaction records retained coverage limits; provider attention is unmeasured.
Separate exact-title, document-content, email-detail, absent-landmark, and
long-field fixtures produced supported answers. The long field fit one read, so
live field continuation was not exercised. The sixth browser case, virtualized records, was supervisor-stopped after
312.356 seconds without observing the target or producing an answer; its pager
press was rejected before input for a missing postcondition. All 49 original
tabs were preserved and fixture tabs/server cleaned up at that checkpoint.
Native read attempts were then denied for TextEdit and the inert fixture app;
the later recovery below clears the fixture gate. Source changes and parser
tests do not by themselves complete the remaining generalization gates.
See [the current contract](docs/BROWSER-READ-CONTINUATIONS.md).

### Recovery update, 28 September

The earlier native access gate is cleared. A fresh exact-prompt task read the
separate inert native fixture and correctly reported both facts in 151.174s;
88.454s of that elapsed time was the observed request-to-approval interval.
The distinct TextEdit case remains untested. A new long-field task passed in
160.892s with two continuations over contiguous spans 0:4096, 4096:8192, and
8192:10740 from one immutable capture. Its answer was supported only by the final
fragment; coverage remained partial until then.

The first pagination recovery run lasted 391.845s and repeatedly selected a text
child instead of its unnamed status container. The second lasted 263.906s and
omitted required nested arguments despite visible candidate guidance. Both
stopped through the runtime's repeated-action guard with no input and no final
answer. Neither reproduced the stream-validation error. Recovery source adds
browser-only region-change verification, explicit semantic roles and validated
candidate cues, qualified argument errors and a full generic call shape. Safe
stream diagnostics are installed; completed automatic compactions now retain
their status after a later unrelated failure.

The third pagination recovery reached the target through two verified actions,
but ended at 643.386s with no final answer after stale-index failure debt and
redundant verification. The evaluator stopped it at its adjusted bound; this was
not a stream failure. The instrumented original lookup then ran 636.823s and was
stopped early for two wrong-site and one current-inventory-token bind rejections.
It read two conversations partially, used no content continuation, and produced
no answer. Three compactions completed without the earlier protocol error; its
historical cause is still unknown. All 51 pretrial user tabs were preserved after
the added neutral home was closed. The fourth pagination recovery then passed in 307.410s with seven calls, two
verified pager actions, one compaction, and a supported final answer. Its 62.952s
observed approval intervals are included in elapsed time. It incurred no stale
failure, so the scoped correction path was not exercised live. All 51 user tabs
were preserved, the fixture tab was closed, and the owned server was stopped.
Original lookup acceptance remained open at that checkpoint; the whole TODO was not complete.

The scope-first inventory trial completed in 292.426s with seven calls,
three valid ChatGPT bindings, two body reads, one inventory continuation, and one
compaction. All five eligible candidates were present on the first page. The
model still failed the lookup and made unsupported exhaustive-review/negative
claims despite preserved partial coverage. No input, approval, or stream failure
occurred. All 51 user tabs were preserved after cleanup. Original lookup
acceptance remained open at that checkpoint; later overview trials follow.

### Generic overview follow-up, 28 September

- [x] Install a bounded browser overview of observed controls, headings, and
  navigation, with semantic controls ahead of weak clickable wrappers. Preserve
  explicit views, immutable continuation, action checks, and native behavior;
  add no ChatGPT-specific rules.
- [x] Measure the original prompt on the initial and corrected overview builds,
  and a separate generic search-discovery fixture. Exposure is distinct from
  successful use of controls or a supported final answer.
- [ ] Resolve the newly diagnosed final-text/stream inconsistency without
  accepting unstreamed public text or relaxing executable-call validation. The
  new `unstreamed_final_text` condition is known; its cause and any relationship
  to the historical generic failure remain unproven.

The initial overview trial was stopped at 264.678s because weak clickable wrappers
crowded out controls. The corrected original trial exposed Search at index 7 but
Qwen pressed its nonpressable ancestor at index 6; it failed at 346.225s after two
completed compactions, with no input or answer. The generic fixture exposed a
valid Search records link at index 3, but three stale/unexposed-index presses were
rejected; it was stopped at 344.558s with no input or answer. Corrected control
exposure is proven, successful lookup generalization is not.

The preceding corrected-overview main was
`e5454ad43e9c0a585cdc908f54d9f70b69ee56b5fcaab5694c787d78096c2741`;
the owned runtime is unchanged. Overview Swift validation passed 276 cases with
two skips; the ordering correction then passed 62 focused cases. Bun checks passed
55 tests/435 assertions. These runs overlap and are not a unique summed total.
Final cleanup preserved all 51 user tab identities/URLs, with no extra or attached
tabs; the fixture server was stopped and its listener absent. At that checkpoint Computa was
idle with the approved one-time Chrome connection and Ask Every Time. Remembered
extension pairing remains unconfigured.

### Identifier-presentation follow-up: task still unsuccessful

The generic fixture's failed 17/18/18 indices matched raw parent/node IDs exposed
beside its actual element #3. This correlation is not a proven cause or model
limitation. The installed fix removes those raw IDs from model-facing rows and
subtree headers, preserving current element indices, same-page parent_index,
host identity, receipts, freshness, and action checks. No site-specific rule was
added. Independent source review found no actionable defect.

Signed installed main at that checkpoint:
`d889ff68b1fdf86ecc39645c3f412b9ecb4f120ef3ea40d112c40d6d6f3881d4`.
The runtime and MLX files are unchanged. Release/signature checks and 139 focused
Swift tests passed; these overlap earlier suites. The unchanged Meridian discovery
retest selected the actual Search link in all three attempts, unlike the preceding
raw-ID selections. One stale snapshot and invalid region-change requests still
prevented input. The app's automatic repeated-action failure guard ended the run
at 351.556s, ten calls, and one completed compaction. No supervisor Stop, approval,
input, search result, or answer occurred. The last tool's generic aborted-by-user
text is not evidence of user cancellation; its detailed rejection was unrecorded.
This single-run improvement does not prove causality or successful generalization.

Final cleanup preserved all 52 user tab identities and the original 51 URLs. A
new pre-existing user tab independently finalized its conversation URL. Only the
fixture was closed; no extras or agent attachments remain. The owned fixture
server was stopped and its listener absent. Original lookup acceptance remains
unchecked.

### Navigation/dialog and empty-field follow-up, 28 September

Build `163b7d2613dc01e8cf862a9a9e2de6b1ae6770245bd85952143ce8e57904d414`
added the two-argument host-verified link action, a generic same-document
`dialog_opened` predicate, and narrowly scoped correction between undispatched
AX/link argument failures. Explicit advanced verification, freshness, approval,
retry limits and single dispatch remain enforced.

The unchanged Meridian task verified navigation to its search page (618.983s,
15 calls, two compactions). Lumen corrected a missing predicate and verified its
same-page dialog (347.096s, nine calls, one compaction). Neither entered a query
or produced an answer: correct-field text requests lacked an observed baseline
value. Both were stopped by the supervisor; Lumen stopped after the first known
field failure, not exhausted recovery. Each completed cleanup preserved all 52
user tab IDs/URLs and left zero attachments.

Empty-field main used for the preceding trials:
`a72979ccf7b1929a38b7554c23b64ad01c969042e77f7526a51ea05c4d86be05`.
Backup: `2026-09-28T10-33-12-744Z-tG6JnT`. The owned runtime is unchanged.
Only explicitly observed empty native fields gain a baseline through bounded DOM
projection and exact AX-node eligibility; unknown values stay unknown. The
compiler and fresh preflight remain unchanged. Empty-field validation passed
100 Swift tests with two skips and 59 Bun tests/270 assertions, including ten new
boundary tests; overlapping suites are not summed. Release/signature/install
passed. Meridian retest completed in 528.367s with 11 calls, two compactions,
four verified inputs and a correct supported raw answer. The app withheld the
answer under pending search evidence despite cleared action debt; this is not an
end-to-end product pass. Cleanup preserved all 52 user IDs/URLs and zero
attachments. The new original task then failed after 461.853s, ten calls and
three compactions, with no input, approval or answer. Search was exposed but
unused; four final reads repeated the first 53 of 359 elements and ignored the
offered continuation. The supervisor stopped for lack of progress before its
15-minute ceiling. All 52 starting user IDs/URLs were preserved, with zero
extras or attachments; only the owned neutral home was closed. Original
acceptance stays unchecked after eight failures. Computa was quit for the
search-receipt follow-up build; the fixture server is retained for retests.

### Installed search-receipt follow-up

Search-receipt build used for the preceding Lumen trial: `94357ca6f2ae5394ed341c54b1b3faf370901c732dbdef1f9afda8151737be16`.
Backup: `2026-09-28T10-59-37-875Z-AJVccG`; owned runtime unchanged. Release,
strict signature and installation passed. Search-interface receipts now survive
subsequent detail navigation while current-page status stays separate; complete
host hierarchy validation does not grant model read coverage or action authority.
Focused Swift validation passed 90 tests, with two skips and zero failures.
The fresh exact-prompt Lumen trial completed autonomously in 849.088s, with
15 calls, three compactions and four approved verified inputs. No hints or
supervisor Stop occurred. It corrected two press requests and one malformed
content read, reached the actual record, and generated a correct 328-byte raw
answer with facts, supporting excerpt and observed source URL. The app showed
Completed but did not display the answer.

The same-turn persisted outcome diagnostic was written at 11:04:58.620716 UTC,
matching an early whitespace-only assistant item while a transient rejection
was unresolved. The runtime marks that diagnostic for the whole turn and rejects
later assistant items even after recovery. This is a publication defect separate
from the search-receipt gate; the resulting publication fix is installed below,
with its later app-visible Meridian pass recorded below.
Cleanup preserved all 52 user IDs and URLs, with zero extras or attachments;
only the owned fixture closed, and the server is retained for the next test.
The original task was not rerun on this build; its acceptance stays unchecked.

## Earlier publication fix; Meridian passed

Publication-fix main at that checkpoint: `7e7fb5d1d4b68832da13a012099d812afd957edf84c556c2198f65a2f735b6a1`. Backup: `2026-09-28T11-29-46-262Z-JcC43m`; the owned runtime is unchanged. Release, deep/strict signature and installation passed. The final focused Swift run executed 55 tests: **53 passed, two skipped, zero failures**. These overlap earlier suites and are not added to them. Independent review found no remaining issue in that focused change.

The unchanged Meridian task completed autonomously in 399.226s, nine calls and
one compaction, with four approved verified inputs and no hints or supervisor
Stop. The record body supported the 378-byte answer, and native app inspection
confirmed that its facts, excerpt and source URL were displayed. No request was
rejected in this run, so the pass does not itself exercise rejection recovery.
This is a supported product-visible fixture pass, not a general reliability claim.
Cleanup preserved all 52 user IDs and URLs, with zero extras or attachments;
only the fixture closed. The ninth original task on this same build failed as recorded below;
original acceptance stays unchecked.

## Ninth original lookup on the publication-fix build

The exact original prompt ran from a fresh neutral home with the known answer
closed and no hints. It ended automatically after 200.219s, seven calls and no
compactions. The overview exposed Search #7 with AXPress; the model instead
pressed nonpressable navigation #6, then repeated an all-view request containing
snapshot_id without element_index three times. Two explicit argument rejections
provided recovery guidance; the third identical attempt coincided with the
native repeated-failure guard. No approval, input, supervisor Stop or final
answer occurred. The generic aborted-by-user tool output does not establish
user cancellation. This was neither a completed search nor a verified negative.

At that checkpoint, all nine original attempts were unsuccessful. Cleanup verified all 52 starting
user tab IDs and URLs unchanged, with zero extras or attachments; only the owned
neutral home closed. The fixture server was already stopped and its listener
absent. Source validation and the separate supported Meridian pass do not satisfy
original lookup acceptance.
