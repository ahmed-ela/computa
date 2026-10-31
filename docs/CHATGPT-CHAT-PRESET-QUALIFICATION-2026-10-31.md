# ChatGPT Chat preset qualification — October 31, 2026

Installed Computa **0.7.0 (339)** passed one fresh literal `hi` task for each of
the five advertised Chat presets. Each returned exactly `Hi.`, with one inference,
no runtime error or tool call, and confirmed website-session closure. The observed
website selection was **Chat / GPT-6** with the requested power. Work and Sol
remain excluded, and the family is selected automatically as the highest enabled
plain GPT version offered by the associated website menu.

| Preset | Native task duration | Response | Cleanup |
| --- | ---: | --- | --- |
| Instant | 8.028 s | `Hi.` | Closed |
| Medium | 8.880 s | `Hi.` | Closed |
| High | 11.890 s | `Hi.` | Closed |
| Extra High | 14.131 s | `Hi.` | Closed |
| Pro (displayed as GPT-6 Pro) | 26.344 s | `Hi.` | Closed |

These are five sampled executions, not a reliability estimate or a latency
comparison against direct ChatGPT. Website controls establish selection, not an
immutable backend model version. The earlier intermittent pending-first-message
ownership rejection remains unresolved by live evidence; these successful runs
must not be used to claim that timing case is permanently fixed.

## Causes and changes

The returned Chat/Work toggle was already recognized. The original Medium failure
came from intermediate picker state: the Power thumb acknowledged Medium while
the composite header still displayed Instant. Selection now waits for the same
header to acknowledge each owned, single-step power input within the existing
1.8-second deadline. It does not repeat the input or reopen the picker. Unexpected
transitions and change-and-restore still fail verification.

A second failure came from an initially disabled picker hydrating its remembered
label before any selection input. Disabled labels now describe readiness only.
After the same trigger becomes enabled, a fresh associated Power and family read
must agree before selection is accepted. Once bound, selection drift remains an
error. Chat product, owner, document, control identity and deadline checks remain
required throughout preparation, submission and response acceptance.

Pro exposed a separate reply-extraction bug. Both build338 attempts contained a
valid 31-character JSON candidate in one CODE node without PRE. Computa included
the widget heading and returned 38 invalid bytes. The PRE-free reader still
required obsolete border/header-height styling that the existing PRE reader no
longer required. Both now use the same structural header relationship, retaining
the sole code body, exact PRE-free content identity, preceding header, single JSON
label, enabled copy control and rejection of authored outside content. The strict
response/tool codec is unchanged.

The build339 Pro run exercised this repaired path: zero PRE nodes, one valid CODE
node, `accepted_literal_code`, and 31 accepted bytes. Its session joins to the
single Pro inference and the displayed `Hi.` reply. The earlier raw live reply
was not captured; regression greeting contents are synthetic.

## First-message timing findings and remaining limit

An Instant335 attempt failed after Send because its collapsed prompt's expand
control failed the immediate post-scroll hit test. The adapter now waits at most
1.8 seconds for that same control to become exposed, preserving the single scroll
and expansion claims. Before its sole click, it rechecks owner, document, model,
body and deadline. Full expanded-payload verification remains mandatory. The
regression covers delayed exposure and refusal on replacement, obstruction,
timeout or changed context. Subsequent live successes do not prove they exercised
the delayed-exposure path.

ExtraHigh336 failed during a body digest across a conversation-route promotion.
A bounded discarded-read guard was extended to the precise pending-private case:
matching private/native fingerprints, canonical body, original deadline and
native-certified route edges. It cannot grant final ownership or repeat Send or
expansion input; a fresh complete read must establish ownership. The native
regression passes, but **ExtraHigh337 still failed** with ownership unverified and
cleanup unconfirmed. That failure is retained and its uncertain prompt was not
replayed.

Build338 added finite first-rejected-condition diagnostics without changing
admission. Its two Extra High successes verified the first message before the
later route promotion, so they did not exercise the failing pending guard.
Build339 preserves the original certificate and pending-route facts as separate
diagnostic records, each under the unchanged 960-byte cap. The next recurrence
can identify the exact rejecting predicate without logging prompts, URLs,
fingerprints or other page contents. This is diagnostic coverage, not evidence
that the remaining race is solved.

## Validation and artifact identity

- Source commit: `404b8e39c01734b64f0a33ddd7177400b5f50b57`.
- Installed version: `0.7.0 (339)`; live test process: `52617`.
- Executable SHA-256: `d39fc1966b70f7f95ed0eacbe147a922e249673f1eb342250ab6d8812d59e3de`.
- 571 adapter tests and 10 Chat preset-policy tests passed.
- Real WebKit integration passed the new PRE-free widget test's four cases:
  literal greeting, unchanged escaped tool arguments, outside-prose rejection and
  malformed tool-JSON rejection. The existing single-Send and owned-cleanup
  assertions remained required.
- Ten focused native diagnostic tests passed, covering separate bounded records,
  ordinary and route-discard projection, private/unknown/foreign data rejection,
  unchanged observations and first-failure retention through cleanup.
- Earlier picker, ownership, selection-policy and cleanup regression results are
  retained separately; this qualification does not claim a new full-repository
  test run or live tool-use benchmark.
- Signed Release build passed all 11 source/identity/resource/signature checks.
  Installation verified the executable and every copied resource against that
  receipt and preserved build338 as a rollback copy. No release was published or
  notarized as part of this change.

An independent audit recomputed the five results from saved native turns and
evidence records, rather than trusting the collector's pass flag. It checked
literal lowercase `hi`, distinct task/thread/turn identities, one inference per
pass, exact preset and Chat/GPT-6 proof at submission/completion/release, stable
session/document/runtime/fingerprint joins, confirmed closed cleanup and capture
hashes. The source/build/install joins matched the artifact above.

Private local evidence is retained under
`work/chat-presets-20261031/`: `matrix339-independent-audit.json`, the five
`*339/capture/` directories, `native339-result.json`, `install339-result.json`,
`live339-native.log`, `pro339-native.log`, `pro-code-widget-regression/`, and
`split-route-diagnostics339-native.log`. Earlier failures remain preserved.
Raw application transcripts and private diagnostic payloads are not committed.

Only the approved model-picker test tab was exposed to Web Inspector. Inspector
and developer settings were restored and that human test tab was closed. The
user's existing Kimi tabs were preserved; successful model sessions were closed
through normal verified cleanup.
