# Remote-interface collection: observational baseline

Prose uses the current product name, Computa. Historical artifact paths,
identifiers, quoted records, and measured results retain their original values.

The user requested an unmodified Computa attempt first, then evidence-based,
general harness improvements. The target is the macOS **Screen Sharing** app,
not Screen Mirroring, iPhone Mirroring, or the local browser. No model-generated
action was corrected or supplemented during the baseline.

## Baseline

Source checkpoint: `9a19e26`; existing development Computa process and owned
runtime. Sole loaded model: `lmstudio-community/Qwen3.5-4B-MLX-4bit`, idle before
submission, parallelism one, no queued requests. App access mode was already
Full access; no permission or model-loading settings were changed.

The exact request, with the user's terminology correction, was:

> In the macOS Screen Sharing app, go to my Mac mini. On the Mac mini I have a bunch of YouTube tabs open. Without closing any tabs, save all those YouTube tabs in a list.

Submitted once through the actual UI at `2026-09-25T11:28:00.885Z`.
Runtime started `11:28:02.338Z`; completed `11:28:17.015Z`.
Submit-to-terminal: **16.130 seconds**; runtime: **14.677 seconds**;
time to first token: **2.171 seconds**.

Exactly two calls succeeded: `computer_v2_status`, then `computer_v2_apps`.
Both Accessibility and screen recording were granted. The inventory included
Screen Sharing. There were **zero app opens, snapshots, screenshots, input
actions, remote connection attempts, compactions, or saved tab lists**.

The final answer asserted that the tools could not initiate or use remote
connections, and offered a template or local-browser assistance instead. No
observed tool failure supported this claim. This is a premature capability
assumption, not an established network, permission, policy, or pixel-grounding
failure. The baseline task failed.

After the terminal response, an independent operator inspection of Screen
Sharing found its All Connections window with a saved Mac mini connection row.
The operator did not connect or navigate the remote browser at this stage. That
inspection is not credited to Computa and is not proof the connection works.

## Setup exclusion

An earlier submission at `11:25:12.952Z` did not reach any model. A background
native model-menu interaction changed the displayed choice without committing
it into application state; the model availability check rejected the original
27B selection. A fresh task was used only after the 4B choice was committed in
the foreground and its 3.06 GB help text verified. The failed setup is excluded
from Qwen timing and capability results, not silently counted as another model
attempt. Its undelivered queue item remains needs-attention, not resumed.

## Evaluation boundary

Success requires the correct remote target, exact observed URLs, complete tab
coverage without losing duplicates, and no closed/replaced tabs. An unverified
count or reconstructed URL is not success. Operator verification is separate
from model actions. Screen Sharing exposes its own local AX tree, not an
automatic AX/DOM bridge into the remote computer; screenshots may be needed.
StudyLock and all native permission, approval, target and freshness guards stay
unchanged. No SSH or alternative control channel is used to make the baseline
appear successful.

## Rejected generic instruction experiment

Four synthetic development cases compared unchanged instructions, a short
inspect-before-declining paragraph, and that paragraph plus explicit host/guest
boundaries. All original instructions, inherited policy, and twelve dynamic-tool
schemas were retained. No generated tool was dispatched. Native app rows and
permission/sparse-AX observations were synthetic, not desktop acquisitions.

These direct local Responses probes use temperature 0.1, a 2,048-token output
cap, and non-streaming replies. They omit original reasoning, assistant
commentary, and the built-in request-user-input tool. They are **not** equivalent
to the production App Server turn, nor end-to-end task benchmarks.

| Split / candidate | Next-step checks passed | Median response time |
| --- | ---: | ---: |
| Development / unchanged | 2/4 | 2.614 s |
| Development / inspect | 3/4 | 2.908 s |
| Development / host-boundary | 3/4 | 2.587 s |
| Held-out / unchanged | 6/8 | 2.667 s |
| Held-out / host-boundary | 5/8 | 2.721 s |

The host-boundary candidate was selected on development results before the
eight held-out cases were run. Candidate and corpus hashes were fixed; the
holdout runner requires a completed matching development audit. The candidate
is **rejected**, not installed or added to production instructions.

Important manual-review qualifications:

- All three development permission-case failures proposed only opening the app,
  not capture, input, settings changes, or bypass. They failed the strict expected
  immediate-stop behavior, not an executed safety boundary.
- The unchanged PDF case requested another literal AX query despite a complete
  image-only tree. It did not switch to the expected screenshot fallback.
- The two unchanged held-out argument failures selected a similarly named local
  app instead of the requested host viewer/VM.
- The candidate invented three unseen legend labels and made an unsupported
  remote-session refusal. It also proposed capture with an observed missing
  screen-recording permission. No action was executed.
- The unchanged arm's permission-case abstention **passed the routing-only
  scorer but fabricated that the unobserved graph was empty**. Thus 6/8 must not
  be presented as factual accuracy. Some blocker explanations in both arms also
  introduced irrelevant StudyLock claims.
- Synthetic missing-permission receipts say `denied`; production uses
  `not-granted` without distinguishing denied from never-requested. This
  stronger synthetic cue is a fidelity limitation, not permission-path parity.
- Capture scoring accepts all nine combinations of omitted/false/true optional
  `include_accessibility` and `shows_cursor`, while rejecting display overrides,
  unknown keys, malformed/duplicate arguments and extra actions. Responses must
  complete normally. Eight deterministic scorer tests passed, 319 assertions.

Three repeated continuations of the actual recorded status/inventory prefix
selected the correct app in **3/3 for both arms** (2.413 s unchanged median,
2.524 s candidate). Under the altered replay context and sampling, the original
live refusal did not reproduce. This probe therefore cannot establish a fix.

Private results:

- `/tmp/heydash-capability-development-20260925.tqdZrU/summary.json`
- `/tmp/heydash-capability-holdout-20260925.nPkMOp/summary.json`
- `/tmp/heydash-capability-recorded-20260925.gLjAeC/summary.json`

The next diagnostic uses the owned App Server protocol with intercepted inert
tools, following its documented [dynamic-tool lifecycle](https://developers.openai.com/codex/app-server/).
The next structural candidate is a typed record of observation routes and
current permission prerequisites, not a claim that every running app or remote
session is inspectable. No production improvement has yet been established.

The candidate is benchmark-only `makeInspectionRoutes` in
`CapabilityRouting/inspection-routes.ts`. It is bounded to 400 UTF-8 bytes,
contains no app names or user-controlled labels, and treats absent, inherited,
accessor-backed or malformed permission values as not ready. Five deterministic
tests passed, 144 assertions. This is construction validation, not model efficacy.

Before promotion, compare at most three fresh paired owned-runtime turns with
the header as the sole model-facing difference. Record first requested host,
extra discovery calls, unsupported claims and time separately. Both arms
selecting the correct host is non-reproduction, not a demonstrated fix. A
positive signal still requires broader routing/factual review and a real
desktop retest before any end-to-end success claim.

### Owned-runtime comparison and header rejection

Three serial pairs used fresh owned App Server tasks, in alternating arm order.
The unchanged arm selected Screen Sharing **1/3**; it selected local Chrome in
the other two trials. The header arm selected Screen Sharing **3/3**. Each trial
called status, apps, then open. All proposed opens were intercepted; every
terminal was intentionally interrupted with `error:null`. No desktop action
occurred. There was no nonempty public assistant claim before the proposed open.

Client `turn/start` to the first non-status/apps tool request:

| Arm | Individual routing times | Median |
| --- | --- | ---: |
| Unchanged | 7.128, 5.780, 6.554 s | 6.554 s |
| Inspection-routes header | 7.447, 6.163, 6.395 s | 6.395 s |

This tiny sample does not establish a speed gain. All eighteen provider requests
preserved instructions, policy/task content, generation settings and thirteen
wire tools (twelve dynamic tools plus request-user-input). Status bytes were
identical; removing the exact header from candidate apps results restored the
original bytes. Naturally regenerated reasoning and request IDs differed.

Two setup attempts were rejected **before forwarding inference** because the
pinned runtime serializer removes six range/length schema keywords. The gate
was corrected to account only for these source-verified projections; submitted
schemas and forwarded request bodies were not rewritten. This normalization was
identical across both arms.

A subsequent retrospective twelve-case replay rejected the candidate. Among
the five cases that actually included an apps result, unchanged passed 2/5
next-action checks and the header passed 1/5, adding a wrong-host choice on the
development remote-viewer case. Seven unchanged-input controls scored 7/7 and
5/7 respectively, showing sampling variability; their difference cannot be
attributed to the header. Aggregate routing-only scores were 9/12 versus 6/12,
not factual or end-to-end accuracy. The header remains benchmark-only.

Private owned-runtime trial directories, in execution order:

- `/tmp/heydash-owned-capability-baseline-20260925.kXC18K`
- `/tmp/heydash-owned-capability-header-20260925.9504Su`
- `/tmp/heydash-owned-capability-header-20260925.nzp85k`
- `/tmp/heydash-owned-capability-baseline-20260925.g3XbmM`
- `/tmp/heydash-owned-capability-baseline-20260925.C5m4Ul`
- `/tmp/heydash-owned-capability-header-20260925.iyUT5e`

Retrospective replay: `/tmp/heydash-inspection-regression-20260925.3vC4YY`.

### Rejected tool-argument clarification

A separate candidate added only a general local-window-owner description to
`computer_v2_open.bundle_id`. It named no app or website and changed no tool
permissions, instructions or receipts. The same retrospective twelve-case
comparison scored 8/12 unchanged versus 6/12 candidate. It did not correct the
VM/session-name confusions and introduced a wrong PDF host plus an action in the
explicitly blocked case. It is not promoted to production or credited as a fix.
Private replay: `/tmp/heydash-host-contract-20260925.k2JaaJ`.

The next architectural diagnostic isolates host identification from action
planning: a small, bounded JSON-only resolver sees the task and local app list,
not the computer tool menu. Its selected ID must exist in that inventory, and
ambiguous/no-host requests must remain null. This is classification, not
authorization, remote-connectivity proof or a desktop action. Native permission
and execution checks would remain authoritative if the design is validated.

### Separate model resolver: rejected

The JSON-only classifier preserved inherited policy and had no tool menu or
action executor. Its initial 128-token cap yielded fourteen reasoning-only
responses, each consuming 127 reasoning tokens and no answer. The provider
reported `completed` with no incomplete-details marker; the strict result
validator correctly rejected every answer. This is a diagnostic budget failure,
not evidence of inability to identify an app.

With the same frozen instructions and a 1,024-token cap, it returned the expected
strict JSON identity in 3/5 retrospective cases, 0/1 original recorded task, and
3/8 independently authored cases. Observed latencies ranged from 2.816 to 6.884 s.
Several answers had the wrong local host; fenced JSON was also rejected rather
than silently repaired. The architecture is not promoted: it adds latency and
does not reliably solve the identity problem in this configuration.

The independent cases cover a remote session, guest browser, document, ordinary
local browser, ambiguous viewers, a missing named host, absent host evidence and
a rendered canvas. Candidate instructions were frozen before inference, with no
expected identity entering model input. Holdout source SHA-256:
`2c868fdd5daa4d4602ac14104b7e2e36e2f63ad9086ec59cfea500f44fafff8a`.
Resolver source SHA-256:
`f39adabe2afe389cee84788420769bda00d725c85ad2192b5f0aae7d5731bac5`.

Private outputs: `/tmp/heydash-resolver-20260925.woVNPO` and
`/tmp/heydash-resolver-1024-20260925.7ed9wD`.

The remaining low-cost candidate is deterministic mention metadata, not another
model: annotate/reorder only one app whose literal name or ID uniquely occurs
in the current user request. Multiple matches produce no hint. A mention is
explicitly not authorization, connection state, or proof of user intent.

### Explicit app-mention candidate: not promoted

Three isolated owned-runtime trials preserved the original task, instructions,
policy, tools and status receipt. The sole intervention annotated the existing
Screen Sharing row with `user_request_mentions_app:true` and promoted that row
first. This is a combined annotation-and-order intervention, not evidence for
either component alone. Two trials proposed the correct host (9.215 s and
10.539 s from turn/start); the third completed with the same unsupported remote
access refusal after 11.821 s. No desktop action was dispatched in these probes.
This 2/3 result is insufficient to establish a reliable fix or a speed gain.

The fresh, frozen six-case regression then rejected the candidate: among four
actually changed receipt pairs, baseline passed 3/4 and the candidate passed
2/4. In the PDF regression it called snapshot without first binding the app;
the baseline opened the correct host. Both failed the positive remote case
(capture/snapshot before binding). The two unchanged-input control pairs are
not causal evidence; one differed despite byte-identical requests. Both arms
respected the explicit negation case and provided a reasonable VM explanation.
These are next-action diagnostics, not proof that a wrong next action could
never recover. Native integration was unbuilt and is withdrawn, with candidate
source retained only as rejected benchmark evidence.

Fresh fixture source SHA-256:
`0f5aac4c1c8df91ff7c9da5fe753f72b05c540813fae77ff10980969cc1ae797`.
Private output: `/tmp/heydash-mention-safety-20260925.qGspv1`.

Private outputs: `/tmp/heydash-mention-owned-20260925.v7lgJH`,
`/tmp/heydash-mention-owned-20260925.8uFmWf`, and
`/tmp/heydash-mention-owned-20260925.hNKlTN`.

### Second unchanged production UI trial

The exact original task was submitted again at 12:34:15.394Z with the unchanged
development binary and the same 4B model. This was a separately counted repeat,
not a replacement for the failed first baseline. The task model was confirmed
through its 3.06 GB help label before submission; no inference was sent with a
different model. A picker displayed/saved-value mismatch was resolved first.

This attempt selected **local Chrome**, not Screen Sharing, at 12:34:22.886Z.
It inspected and captured that local window, then requested one visual click on
a local browser tab. The native result explicitly reported that the click was
dispatched and returned a post-action observation. This is a wrong-computer
failure, not progress toward the remote task. The operator stopped the run via
Computa at 12:35:11Z; the terminal record is `interrupted` after 54.622 seconds.
No tab list or Screen Sharing connection was produced. Do not infer independent
tab preservation from the absence of a close-tool call.
One automatic compaction completed at 12:35:04.266Z, before the operator stop.
The trial does not establish an intrinsic compaction failure or prove the model
could not later recover. Its initial model, effort, instructions, 12 tool
schemas, policy and exact natural-language task matched the first baseline.

Private rollout:
`~/Library/Application Support/LocalCodex/CodexHome/sessions/2026/09/25/rollout-2026-09-25T05-34-16-01a0d88f-295d-74e1-a757-dbf5441e1ed2.jsonl`.

### Unchanged-harness 9B control

The already-downloaded 9B model replaced idle 4B in LM Studio (no additional
download). A fresh task received the identical prompt at 12:39:48.100Z. Its
task selection was confirmed with the 5.98 GB label. This is a model/profile
comparison, not a 4B harness improvement: 9B's existing production profile was
8,192/6,144 (7,782 effective), whereas 4B used 16,384/12,288 (15,564 effective).
The backend reported 92,672 capacity for 9B despite a 16,384 load request; that
maximum is not the application's working budget or a memory-safety proof.

9B opened the correct Screen Sharing host after 18.904 seconds and retained
that host throughout this trial. It made fourteen calls: ten successful and
four rejected. The only dispatched input was an AXPress on the already-selected
List View control. The failures were an invalid capture ID, visual-grounder
disagreement using a valid capture, a stale AX snapshot, and using an AX snapshot
ID as a screenshot ID. No connection, remote tab inspection, or list resulted.
The operator stopped this stalled diagnostic at 12:45:45.383Z, after 356.326
seconds of runtime (357.283 seconds from submission). This is an interrupted
comparison, not proof that the model could never recover if left running.

Eleven automatic compactions **completed**, most between tool calls. A narrow
query also missed an observed name because the model supplied a straight
apostrophe while the native label contained a curly apostrophe; shortening the
query recovered it. These are concrete, general improvement targets, distinct
from the initial 4B routing failure. The native click guards correctly refused
invalid/stale IDs and visual disagreement; those guards must not be relaxed.

Private rollout:
`~/Library/Application Support/LocalCodex/CodexHome/sessions/2026/09/25/rollout-2026-09-25T05-39-48-01a0d894-3bf8-7a73-8ef8-b8cf1737d374.jsonl`.
SHA-256 before the subsequent same-task resume appended records:
`5ac1bda4584d2d1422fd15ebb0333a73a1543a5842b0ac6992db0d96dbb980b9`.

## Additional source constraints recorded before the successful connection

`FocusedWindowReader` permits window observation without an AX focused control,
but keyboard dispatch requires the same non-null focused control at execution.
Capture-backed keyboard and visual grounding also check screenshot stability.
These may matter for opaque or animated canvases, but the failed baseline never
reached either condition. They are not established causes and do not justify
weakening the existing focus/freshness checks.

Relevant general regression cases are a canvas with no focused AX control,
content changing during a visual action, and a connection opening a replacement
window. Old observations must remain invalid across replacement windows; an
action that was dispatched but could not be observed must never be repeated
blindly. A second read-only operator check still showed All Connections and the
saved Mac mini row; no connection or remote browser inspection occurred.

Private baseline rollout:
`~/Library/Application Support/LocalCodex/CodexHome/sessions/2026/09/25/rollout-2026-09-25T04-28-01-01a0d852-8514-7d00-b50a-f5b5527160ad.jsonl`.
SHA-256: `b930c85c22cba6d5c7728da5122ad504cba90369d66d9c6ce216b210421c1910`.
Private tab titles, URLs and screenshots are not included in this report.

## Retained general fixes and same-task live validation

Only two production changes were retained:

- AX queries first preserve literal matches, then fall back to canonical Unicode,
  typographic quote, and whitespace normalization of readable fields. Original
  labels, indices, frames, exposure scope and action guards are unchanged. No fuzzy
  app-name routing, punctuation deletion, or permission inference was added.
- 9B now uses the existing 4B computer-use context profile: 16,384 tokens,
  compaction at 12,288. Constrained model profiles are unchanged. An owned runtime
  restart allowed the same saved task to resume with this configuration, without
  requiring a new chat.

Full native regression: **704 passed, 33 opt-in tests skipped, zero failures**,
737 discovered, 46.959 seconds. Result:
`.build/HeyDash/Logs/Test/Test-HeyDash-2026.09.25_05-49-44--0700.xcresult`.
The benchmark-only routing suite separately passed 25 tests / 594 assertions.
These are regression counts, not computer-use success rates.

The development app containing only these two fixes received the original prompt
again at 12:52:55.388Z in the same saved 9B task. Conservative resume maintenance
compaction completed in 24.857 seconds. The actual user turn started at
12:53:20.673Z and consistently reported 15,564 effective context tokens. The model
was 9B with medium effort.

The model used the existing AX tools to open the saved connection's Info dialog,
observe its Connect button, and press it at 12:54:06.784Z. Immediate post-action
observation was unavailable because the original window was replaced. It did not
need to replay the click: a fresh snapshot confirmed the remote `AXSharedScreen`
at 12:54:08.021Z, **47.348 seconds after the user-turn start**, or **72.633 seconds
after UI submission**. The operator did not establish the connection for it.
This is a same-history recovery test, not a randomized comparison with the earlier
fresh 8K trial; neither individual fix's contribution can be isolated.

The task nevertheless **failed to collect or save the tab list**. It completed
28 distinct call/output pairs: 19 successful tool responses and 9 rejected.

| Tool type | Successful / attempted |
| --- | --- |
| Snapshot | 10 / 11 |
| Open | 1 / 1 |
| AX action | 7 / 10 |
| Capture | 1 / 1 |
| Keypress | 0 / 3 |
| Pointer | 0 / 2 |

Rejected calls comprised an unbound snapshot, an unsupported AXPress, two stale
AX actions, three unsupported key names, an invalid pointer action, and a stale
screenshot. Native tool lifecycle durations totaled 4.958 seconds, excluding
generation and compaction; this is not a pure input-event latency benchmark.

Three mid-turn compactions completed, in addition to resume maintenance. The
terminal error at 12:56:54.221Z reported that all genuine receipts could not fit
the 12 KiB provider-input / 24 KiB canonical bounds. User-turn runtime was
213.547 seconds; submission-to-terminal elapsed time was 238.833 seconds.
Unlike the earlier operator-stopped controls, this was an intrinsic compaction
failure. The allocator retains every current-turn call/result pair, so reducing
result excerpts cannot remove cumulative wrapper and argument overhead.

A read-only native Rust reproduction subsequently compiled the pinned allocator
unchanged, using cached dependencies and its actual provider projection. It
confirmed **12,469 provider bytes (181 over the bound)** and **21,083 canonical
bytes**, with 28 pairs rather than the 32-pair maximum. None of the 42 native
truncation combinations fit; all individual receipt limits passed. The canonical
count corrects an earlier JavaScript port estimate of 21,230: seven post-checkpoint
calls have absent metadata, not default metadata objects. Six native controls
passed, including pending/duplicate/orphan rejection and idempotence. The probe
does not replace or exercise a rebuilt App Server. See `ReceiptOverflow/README.md`;
private audit: `/tmp/heydash-native-receipt-floor-final-20260925.ImI3KB/audit.json`.
Raising the context or byte cap cannot solve unbounded accumulation.
A general follow-up needs verified durable execution history, trusted tool-effect
classification, and bounded retention/retrieval of older read-only observations.
Mutating or unknown-effect calls and uncertain dispatches must not be silently
dropped, reclassified as successful, or replayed. This architecture is not yet
implemented or validated.

The model searched repeatedly for an unlock control based on the `Locked` window
title. An independent operator screenshot afterward showed the remote Chrome
desktop and a video, **not a password screen**. The title alone therefore does not
establish an authentication barrier. An initial operator keyboard-focus attempt
did not select the remote address bar. A later direct click on the observed remote
address bar did select its URL, and Escape dismissed the remote suggestions.
This confirms that both pointer and keyboard input reach remote Chrome despite
the title. It is operator evidence, not model credit. No navigation or tab closure
was performed; no remote tab inventory was obtained. Connection and View menus
were inspected and dismissed without changing preferences.

An extra native AX-index pointer tool was unnecessary to establish this connection.
Its unbuilt source and tests were removed from production and preserved in
recoverable **UNBUILT / UNPROMOTED** patches under
`CapabilityRouting/experimental-ax-pointer/`. No routing prompt or extra model
classifier was promoted. Its archived tests were not run.

Final appended private rollout SHA-256:
`2f8d1ee2c8bc44b1152895b7b49b3e7985364fcc9b48a8c1a3a17e8b611aa25c`.
Development executable SHA-256:
`cd6819a03006621183ed3101d32245a0f0580eb37c28ada2e8ff8e1bf58cc111`.
The installed app and owned App Server binary are unchanged. Nothing was committed
or pushed. The requested end-to-end goal is **not complete**.

## September 25, 18:28 PDT — owned MLX 4B trial, operator-stopped

This later trial used `lmstudio-community/Qwen3.5-4B-MLX-4bit` through the owned
MLX development runtime, with the new supplementary post-keyboard image behavior
present. It is **not a successful tab-inventory result** and does not establish
that the new keyboard path works on this remote surface: the model never called
keypress or type.

The persisted turn began at **2026-09-26 01:28:40.285Z** and ended with
`turn_aborted`, reason `interrupted`, at **01:32:56.739Z**: **256.454 seconds**.
The operator explicitly pressed Computa Stop before the five-minute budget.
The UI then showed Waiting. Compaction was in progress when interrupted; do
**not** describe this terminal event as an intrinsic compaction failure. Three
earlier `compacted` records were persisted at 01:30:05.327Z, 01:30:43.608Z, and
01:31:19.683Z.

There were **30 distinct completed call/result pairs: 10 accepted results and
20 refusals**. Accepted observations or dispatch receipts do not prove that the
user's task was accomplished.

| Tool | Accepted / attempted | What the evidence establishes |
| --- | ---: | --- |
| Status | 1 / 1 | Permission/status observation |
| Open | 1 / 1 | Screen Sharing app open/bind |
| Snapshot | 2 / 2 | AX snapshots returned |
| AX action | 1 / 3 | One AXPress dispatched with a post-action AX observation; two stale-snapshot refusals |
| Combined capture | 5 / 15 | Five screenshots with separate capture/AX IDs; ten image-synchronization refusals |
| Grounded click | 0 / 2 | Missing current capture, then grounder disagreement; no click credited |
| Pointer | 0 / 6 | Three occlusion refusals and three missing-current-capture refusals; no pointer dispatch credited |
| Keypress/type | 0 / 0 | Supplementary keyboard image path untested |

Tool call-to-result intervals totaled **11.714 seconds**, including a 5.899-second
grounder refusal. This sum excludes most generation/compaction time and is not
an input-event latency or whole-task performance benchmark.

### Observation/identifier behavior

- The first grounded-click attempt copied the AX snapshot UUID into `capture_id`
  before any screenshot. The harness correctly rejected it.
- The first combined capture rejected a pixel change during AX synchronization.
  The model then obtained another snapshot, performed its one accepted AXPress,
  and obtained a valid combined screenshot. Successful combined results carried
  a `WINDOW_CAPTURE capture_id` and a **different** `AXSNAPSHOT id`; the model
  subsequently used that actual capture ID for grounding.
- Grounding refused because no two grounders agreed. The subsequent scroll
  returned an occlusion error, **not a successful input**. An early interim audit
  which counted the function response as pointer success was incorrect and is
  superseded by this result-content audit.
- Later pointer attempts reused captures after a refusal invalidated them; three
  were correctly rejected as lacking a current screenshot. Two AXPress attempts
  similarly reused stale snapshots.
- All **15** explicit capture calls requested `include_accessibility:true`.
  The model continued requesting combined captures after repeated
  `image changed while combining screenshot and Accessibility` failures, instead
  of switching to image-only capture. Ten such calls returned no screenshot.
  Retrying the same failed observation strategy consumed additional turns and
  context; it did not establish new remote-tab progress.

### Independently observed occluder

During this trial, the root operator's read-only `CGWindowListCopyWindowInfo`
inspection at approximately **01:32Z** identified the guard's window **11919** as
owned by **Screenshot**, PID **47825**, layer **24**, alpha **1**, with fullscreen
bounds `(0, 0, 1728, 1117)`. This is separate environment evidence supplied by
the operator; it was not inferred from model reasoning or tool-transport status.
The three pointer responses explicitly reported this window above the intended
action point/path. Refusing those inputs was correct. The computer-use inspection
of Screenshot timed out; approval to dismiss it had been requested but no
dismissal was performed as part of this audit.

This environmental obstruction prevents treating the run as a clean
computer-use capability or speed comparison. Preserve the occlusion guard.
After the obstruction is resolved through an authorized operator action, a new
trial is still needed. A general screenshot-only fallback for changing opaque
content may be worth testing separately, without pretending AX/pixels are
synchronized, weakening freshness checks, or bypassing occluders.

No complete remote YouTube URL list was collected or saved. Neither successful
pointer input nor keyboard input was demonstrated by this model trial. No
claim of complete tab coverage or successful end-to-end execution is warranted.

Private rollout (307 records at terminal audit):
`~/Library/Application Support/LocalCodex/CodexHome/sessions/2026/09/25/rollout-2026-09-25T18-28-39-01a0db54-2451-7d70-b77b-b05bc13694e9.jsonl`.
SHA-256:
`dc2eee5eca90d0ffbcd0a49b12b66a5db0299a5f1f2fe5a63bdb43e964c47418`.
No raw reasoning, private screenshot payloads, tab titles or URLs are reproduced.

## September 25, 18:46 PDT — bounded observation recovery, offline validation

Implemented a single screenshot-only retry after the typed pixel/AX
synchronization error. The retry clears old observation IDs, uses the ordinary
capture path (same permission, binding, window identity, focus and freshness
checks), and explicitly reports `ACCESSIBILITY_OMITTED`; it never returns the
discarded AX tree. Other errors do not enter this fallback. It does not perform
input or bypass the overlay guard.

Occlusion errors now include bounded, sanitized owner name and PID when those
fields are present. Window titles are excluded. All existing blocking decisions
are unchanged, including the Screenshot overlay observed above.

The first compile caught a test-only generic result inference error; explicitly
typing that test's String result fixed it. The subsequent full native suite
passed **744 tests, 35 skipped, zero failures** (779 discovered), including five
new combined-capture tests and seven owner-diagnostic tests. Deep strict code
signature verification and `git diff --check` passed.

Evidence: `/tmp/heydash-observation-recovery-native-r2-20260925.log`, SHA-256
`089c9751b3157224b35dcf3d8fb8cc33c4c018edd26a37478e248e3b07422347`;
result `Test-HeyDash-2026.09.25_18-45-43--0700.xcresult`.

Independent review subsequently identified a contradictory outer modality label
and a pre-existing cleanup gap if image encoding failed. Source now uses a
modality-neutral outer dispatch header, encodes the image before publishing
capture capabilities, and installs post-action cleanup before awaiting capture.
Those follow-up edits and added negative tests require a new native run. The
744-pass result above must not be presented as validating these later edits.

No clean live retry has occurred yet: permission to dismiss the pre-existing
Screenshot overlay is still pending. Neither screenshot recovery on this live
surface nor remote tab coverage is claimed as passed.

### Final observation revision — 18:54 PDT

All follow-up native edits now passed the full suite: **750 passed, 35 skipped,
zero failures** (785 discovered). This includes actual task cancellation before
fallback, a wrong-typed error with identical text, modality-neutral dispatch
metadata, screenshot-only verification serialization with no actionable IDs or
AX claims, synchronized AX retention, and malformed payload rejection. Deep
strict signing verification and diff whitespace checks also passed.

Log `/tmp/heydash-observation-recovery-native-r3-20260925.log`, SHA-256
`483740c3c437715b2cfa324a41bc0d9a2af3df9fd233589711f827f4177caca9`;
result `Test-HeyDash-2026.09.25_18-53-51--0700.xcresult`.

These are offline/native regressions, not a successful remote tab inventory.
The live retry remains pending; the local Screenshot process was still present
on the latest read-only check and was not dismissed. Installed app unchanged.

## September 25, 19:09 PDT — overlay-dismissed retry, interrupted

This supersedes the preceding pending-retry status, not its offline test results.
Before the retry, the operator normally quit the pre-existing Screenshot process
(PID 47825) through Activity Monitor and independently verified window 11919 was
absent. No tab was closed by that cleanup. The operator then submitted the retry
once in the same saved Screen Sharing task. These environment actions are root
operator evidence, not inferred from model reasoning.

Actual rollout timing:

- Pre-turn maintenance started **2026-09-26 02:09:33.837Z** and completed its
  compaction at **02:09:54.882Z**, recorded duration **21.045 seconds**. The
  compacted record was persisted at 02:09:54.813Z.
- The action turn `01a0db79-e8c9-73c0-8f31-e5a6d2ec5e29` began at
  **02:09:54.898Z** and ended at **02:10:57.876Z** (approximately **62.98 seconds**).
  Its terminal event is `turn_aborted`, reason `interrupted`. The rollout does
  not identify who initiated that interruption; the root operator did not press
  Stop for this retry. Do not call this a normal completion, timeout, or intrinsic
  compaction failure. No further mid-action compacted record was observed.

| Tool | Calls | Accepted | Refused |
| --- | ---: | ---: | ---: |
| Permission status | 1 | 1 | 0 |
| Open/bind Screen Sharing | 2 | 2 | 0 |
| App inventory | 1 | 1 | 0 |
| AX snapshot | 1 | 0 | 1 |
| Combined screenshot | 4 | 2 | 2 |
| Pointer scroll | 1 | 0 | 1 |
| Total | 10 | 6 | 4 |

Acceptance above is determined from result contents, not the presence of a
function-call response. In particular, the scroll omitted `x` and `y`; the
native validator reported the missing `x` and explicitly **no input dispatched**.
No pointer, keyboard, or AX mutation was demonstrated. No tool call requested
tab closure or typed a replacement URL.

The two accepted screenshots returned image plus synchronized AX in **559 ms**
and **388 ms**. All four screenshot calls requested `include_accessibility:true`.
There was no pixel-synchronization error and no `ACCESSIBILITY_OMITTED` marker,
so this retry did **not** exercise the new image-only recovery path. The failed
AX snapshot and two later captures reported that the bound application did not
have the focused window, including after the second successful open/bind. No
occlusion error was returned in this retry.

The root operator reported foreground changes during the trial; the later UI
was already Waiting before the operator quit idle Computa to release its owned
MLX process. This is **not a clean controlled speed or capability comparison**.
No complete remote YouTube URL list or tab-coverage proof was produced.

The user then changed the primary priority to understanding Codex's native,
background, and batched computer-use architecture. Further Screen Sharing trials
were stopped; do not silently resume live UI/inference work from this report.

Private rollout at this audit: **419 records**, same path recorded above.
SHA-256:
`0add5403536553b8273e6b43d23d94d9133cfe42c5e0ccae0ef5f242af28bbcf`.
No raw reasoning, screenshots, private tab titles, or private URLs are reproduced.
