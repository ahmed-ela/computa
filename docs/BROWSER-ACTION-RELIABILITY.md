# Browser action reliability

An Outlook follow-up exposed several independent failures. The model reused a
task tab that cleanup had closed, mixed continuation cursors with changed read
filters, and attempted stale or non-actionable targets. A later documentation
request was restricted to chatgpt.com merely because its text mentioned ChatGPT.
Finally, an explicitly requested message send was refused without any tool call:
the model described background-only operation as a read-only permission policy.

The saved runtime evidence distinguishes these failures. The browser recovery
stop belonged to the earlier search turn, not the later message request. Turn
scope and retry counters were already reset correctly. On reload, however, the
old stop notice was appended after every subsequent turn, making it appear current.

## Changes

- Fresh per-turn instructions distinguish input delivery from authorized effects.
  Background operation forbids activation and global input; offered background
  tools can perform user-authorized actions. Read-only work still permits search
  inputs and navigation, while account/content changes need authorization.
- Historical assistant refusals and outcome corrections do not establish current
  permissions. Actual denials, Stop, approval checks and ongoing user constraints
  remain binding. Each user turn reacquires browser handles and observations.
  This lifecycle guidance is refreshed even in resumed chats retaining older
  developer instructions; it is not limited to newly created conversations.
- A missing current-turn binding is a typed lifecycle error, not a permission or
  sign-in failure. Empty inventory guidance permits reopening a supplied or
  previously observed task URL, including local test pages. No old binding is
  silently reconnected and no automatic navigation or input is dispatched.
- Known-service restrictions require destination language. A documentation topic
  does not create an exclusive service-host restriction. Explicit destination,
  URL, title and browser constraints remain enforced.
- A changed-filter continuation remains rejected, but its exact current,
  unexpired cursor can return one separate fresh read of the explicitly requested
  view/query. This prevents recovery from repeatedly returning an overview when
  content was requested. Unknown, foreign, replaced or navigation-stale cursors
  grant no recovery read. Failed capture preserves the previous valid capability;
  success replaces it. Recovery shares the existing three-read turn limit.
- Read failures are scoped to the verified browser binding and native committed-document
  identity. A genuinely new binding or observed committed document cannot inherit
  the previous page's failures. Same-document retries still stop at three;
  fresh snapshots/cursors, URL changes alone, declined navigation and no-op binds
  do not reset it. Mutation/native failures and the shared three-read recovery
  limit remain unchanged across documents and bindings.
- Completed reads omit the `next_cursor` field instead of displaying `none` as
  a token. A live model had copied that placeholder into a continuation request.
  Genuine cursor values remain exact, and invented cursors remain rejected
  without a read or input dispatch. Page text containing the same words is not
  rewritten.
- The optional `browser_read.cursor` explicitly accepts null as a fresh read,
  with the same default overview, binding checks and budgets as omission. Finite
  diagnostics from an installed GPT-OSS documentation task identified two
  consecutive pre-dispatch failures from `cursor: null` under the former
  string-only schema. Recognized saved native catalogs receive the new contract;
  completed history retains its original argument bytes. Nonnull cursors remain
  exact and nonempty; custom and required-cursor schemas are unchanged. This is
  a field-specific public contract, not generic argument repair or extra retries.
- Navigation-related stale preflight errors can return a bounded fresh read,
  like other stale snapshot errors. They remain failed, undispatched actions;
  input is never replayed. Approval, ownership and unchanged-attempt limits remain.
- Saved stop notices retain their turn identity and appear beside that turn after
  reload rather than below an unrelated later reply.
- Browser reads identify their counts as a selection of captured UI elements,
  not a website search result count. Query-match provenance distinguishes input
  value echoes from exposed readable text. Partial overviews cannot establish
  mailbox absence. Fresh search guidance requires actual result content and
  refinement when an overly literal query returns irrelevant results.
- The supported engine compaction prompt separates historical attempts from the
  current request and preserves the source/scope of genuine user restrictions.
  An observed automatic summary had imported an earlier attempt's targets and
  claimed that a current search had already finished. API inferences now receive
  fresh native policy and execution counts outside history. Counts are bound to
  task/thread/turn/preparation, versioned against out-of-order actor updates, and
  cleared on retirement. They describe actual tool execution, never website
  result semantics, output exposure or permission grants. Actual observations
  remain necessary for content claims. The engine's history is not rewritten.
- A build-223 documentation run exposed an authority error in the external
  provider projection: generated summaries were tagged `compaction.summary` in
  canonical history but sent as ordinary user messages after that tag was
  removed. The run's six summaries propagated invented restrictions, and the
  model repeatedly restarted browser inspection within the same turn.
  Projection now sends fully proven summary
  messages as assistant history, preserving genuine user messages and leaving
  mixed or unclassified content untouched. No text-prefix heuristic, permission
  change or larger history budget is used.
- API turns keep only the exact human text in durable user input. Current host
  policy and the last three native outcome corrections are supplied through the
  existing per-inference developer checkpoint. A build-224 historical chat
  retained 43.6 KB of repeated host instructions alongside 5.1 KB of human text;
  one new read could therefore trigger another compaction. Website and local
  provider delivery retain their existing behavior. Existing history is not
  stripped by matching text prefixes: older messages lack reliable origin
  metadata, and genuine user text must remain intact.
- Ordinary browser reads page within the runtime's existing latest-observation
  limit. The exact page, references and truthful continuation are kept together
  through compaction, or retention stops at the existing aggregate limit.
  Build-224 evidence showed middle truncation removing a relevant article's URL
  and click reference while preserving an unrelated link. The new producer
  chooses the page before issuing references and its cursor; it never truncates
  a finished page while retaining a cursor that skips omitted content. This
  changes evidence delivery, not action authorization or target validation.
- An unissued continuation now reports that only the current `next_cursor` may
  continue a page and that a fresh read omits `cursor` (or uses null). Build-225
  evidence showed a model passing a snapshot ID, then a tab handle, as a cursor;
  the generic stale-snapshot message did not identify that mistake. This error
  performs no capture or input, consumes no action references, and does not
  refund failure budgets. Real expiry and document changes retain their checks.
- Current API checkpoints also refresh concise troubleshooting and sign-in
  evidence rules. A build-225 fresh chat invented a diagnostic command and
  attributed a search snippet to a different article; a separate Outlook run
  assumed a password was required without trying the displayed matching account.
  Suggested checks are not executed diagnostics, and an account picker is not an
  observed credential challenge. The rules also reach website handoffs without
  raising prompt limits. They guide the model; they are not proof of adherence,
  a semantic answer validator, or permission to change settings.
- A subsequent live lookup reached relevant ODE results, then compaction changed
  the task into a request to write a historical summary. The host now retains the
  exact original request and accepted in-turn user messages outside compacted
  history. Ordinary API inferences repeat these as user messages, with host
  guidance to continue unfinished work without replaying completed actions.
  Explicit native `request_kind=compaction` metadata keeps maintenance distinct
  from task execution; prompt wording is never used to guess the purpose. During
  maintenance, exact active user inputs appear immediately before the final
  runtime maintenance instruction, which remains last. This keeps older tasks
  from displacing the current request while preserving historical restrictions
  and user-level authority. Maintenance still has no tools and only writes notes.
  Steering gates new inference admission until its acknowledgment is validated.
  An uncertain acknowledgment retires the turn rather than reopening inference
  with an outdated restriction. Stop, turn replacement and shutdown discard the
  pending update. The supported compaction prompt also identifies itself as
  maintenance, not a new human request.
- Fresh content reads wait for content readiness, rather than treating an
  already-loaded toolbar as proof that asynchronous message results have arrived.
  The built-in transport uses its existing page-event observer and bounded
  deadline. Readable results, listbox options and explicit empty-result text can
  establish readiness; search-field echoes and navigation controls cannot.
  Broad reads, continuations and input preflight retain their existing behavior.
  Deadline expiration remains an incomplete observation, never proof of absence.
- Fill receipts distinguish replacing a field and dispatching its input/change
  events from pressing Enter or a submit control. A separate observed submit
  control remains available within the user's scope. No-replay guidance refers
  to the same input, so it does not discourage a needed Search after field entry.
  Page event handlers may still react to a fill; observed outcomes remain required.
- Captured native form fields expose compact, passive HTML constraint state on
  their own published row: `required=true`, `constraint=valid`,
  `constraint=invalid[value_missing]` (or other fixed native flags), and
  `constraint=not_candidate`. This makes an empty required Message field visible
  before and after a premature Send. Reads never invoke `checkValidity` or
  `reportValidity`, traverse the form, or expose `validationMessage`; hidden and
  password fields remain excluded. The metadata shares existing row byte limits.
  It cannot establish that submission was blocked or that no page handler ran:
  invalid controls can coexist with click side effects or validation bypass.
  Dispatch, no-replay, approval and receipt verification semantics are unchanged.
- Submission guidance requires completing all requested and exposed required
  fields before submission and checking a new result tied to the action. A build-223
  local form run pressed the correct Send control before filling a visibly
  required body, then mistook the pre-existing Sent navigation link for a new
  notification. The independent fixture recorded no delivery. This was a model
  planning/evidence failure, not an incorrect reference resolution.
- Post-input overview reads share the ordinary fresh-read navigation recovery.
  When navigation invalidates the first read, one additional fresh read may run
  on the same lease, with the same identity, scope and cancellation checks.
  Cursor and subtree reads cannot switch documents, and unrelated failures do
  not retry. A second failure remains an unavailable observation. The input is
  never replayed, and a recovered observation does not verify its outcome.
- Overview interleaves controls, headings, readable main/article body text, and
  navigation in one captured selection. It keeps the existing 18-row maximum,
  exact field exposures, and immutable continuation. Compact pages also fit the
  existing complete-observation envelope limits before publication.
  A long sidebar cannot by itself hide all document text; a heading does not
  substitute for the body. Selection uses observed structure, never success
  keywords. This is a bounded sample, not complete document coverage or proof
  that an action succeeded. Additional evidence may still require a read.
- Successful click/fill tool outputs include a separate compact dispatch
  receipt. It preserves the operation and the control label through item-wise
  history truncation; snapshot IDs and indices alone cannot explain an older
  action. The serialized receipt fits 128 UTF-8 bytes, including JSON escaping,
  and copies only a label span already exposed by the validated input snapshot.
  A partial flag identifies clipped or unavailable labels. A complete post-input
  output contains the retention marker, dispatch receipt and observation as
  separate items. Failed dispatches have no such receipt,
  and existing turn, lease and generation checks still gate publication. This
  historical cue provides no new action reference and explicitly leaves the
  outcome unverified. Compaction's total history limits are unchanged.
- Click guidance permits choosing an observed existing account within the
  authorized task and approvals. The model must not infer that a password or MFA
  is required before observing that requirement. Actual credential requirements,
  account ambiguity and approval boundaries still require appropriate help.
- New clicks use `click_ref`; fills use `fill_ref` and `text`. Only eligible
  currently published rows with exposed labels issue these typed references.
  The host retains the exact snapshot, row, role and exposed UTF-8 label instead
  of requiring the model to copy a long label and a separate snapshot/index.
  An absent label is not an explicitly empty label, and a continuation grants
  only its exposed fragment. References never search for a substitute target.
- Each fresh read replaces the reference menu. A token survives only when that read
  explicitly republishes the same native node with identical field exposures
  and action semantics in the same binding and committed document/generation/URL.
  Fresh reads retire changed or omitted rows; admitted input consumes all refs.
  Cursor-only continuation within the same immutable capture retains already
  exposed targets within the existing 120-reference FIFO limit. A broker-minted
  witness preserves the original row, exposure spans and target semantics;
  neither pagination nor approval renews its original capture lifetime.
  The target is frozen before approval and retry accounting, then checked again
  before dispatch. A later read cannot silently update an approved target.
  Existing physical checks, permissions and outcome verification remain intact;
  a model can still choose the wrong currently exposed control.
- Recognized saved browser catalogs migrate to the strict current schema for
  inference. Completed v1 snapshot/index, v2 role/label assertion and v3 reference
  calls retain their original argument bytes and require matching outputs.
  Current calls accept only v3; custom/MCP schemas remain unchanged. An old chat
  with no browser tools still needs a new chat to obtain them.
- Mutation retry keys use native target identity and operation/value, so new
  tokens or row numbers cannot refund the budget. Unknown or wrong-type refs
  share a routing-only failure counter and trigger no automatic capture. A
  successfully published current-ref input clears that counter only; reads,
  rebinds and failed inputs do not. Other intent counters and unresolved outcomes
  remain separate. Known stale references retain only bounded read-only recovery,
  never input replay.
- DOM capture traverses `display: contents` wrappers even though those wrappers
  have no layout box. Visible descendants and direct text retain their semantic
  ancestry; the wrapper itself receives no input capability. Hidden, inert and
  `aria-hidden` descendants remain excluded. WebKit can include hidden text in
  a boxless wrapper's aggregate `innerText`, so those wrappers retain explicit
  labels while their visible child text is captured individually. Ordinary
  boxed-element labels and capture limits are unchanged.
- Final captures log bounded native diagnostics for traversal limits, frame and
  shadow boundaries, clipping, page visibility, viewport and native attachment.
  `clippedFields` counts captured nodes with at least one clipped field. These
  records contain no page text or URLs and do not expand model tool results.
  An incomplete capture alone does not identify why relevant results are absent.

The follow-up Outlook check proved that field entry and Search activation worked.
Its incorrect negative answer came after reading an incomplete overview; the host
had not reported an empty mailbox. An independent search with the shorter term
`ODE` exposed course announcements. Changing WebKit or synthesizing extra input
events was therefore not justified. A real-WebKit regression separately verifies
that isolated-world fills reach delegated, controlled application state for text,
search and textarea controls before an observed submit button is pressed.

## Reproduction and qualification

`Tests/Fixtures/browser_action_mailbox.py` serves an isolated loopback mailbox.
It cannot send external mail. Start it with a new `--evidence-dir` and use the
origin in its `connection.json` through Computa's installed model-driven browser.

1. Ask the model to read the ODE announcement and attachment filename, with an
   explicit read-only constraint. Confirm no POST delivery in `events.jsonl`.
2. After the app closes its task-created tab, ask in the same chat to send
   `course-staff@example.invalid` a message about the Teams screenshot and exam
   change, with a unique subject. Supply no tool names or navigation instructions.
3. Require a fresh binding, one delivery with the requested fields, a browser
   observation of the server-generated receipt, a matching final answer, and
   cleanup of owned tabs. A model's success claim alone is not a pass.
4. Repeat after a previously failed/refusing turn to check recovery from history.
5. Open `/search` for search qualification. HTTP query receipts distinguish actual
   website searches from local snapshot filters. Read a positive announcement,
   then check an unrelated subject whose search returns an explicit empty state.
   An echoed query or zero captured elements alone is never a successful check.

The fixture uses a threaded server because WebKit can open idle preconnections;
a serial HTTP server can block real navigation behind those sockets. Such a
fixture timeout is not evidence of a production browser navigation failure.
Its search accepts exact normalized keywords (`ode`, `exam`, `announcement`, or
`announcements`), not arbitrary title phrases. The unassisted title-search case
therefore tests recovery from an adverse search result; it is not a realistic
full-text search implementation. Preserve it separately from an explicitly
steered keyword control when comparing builds.

Synthetic mailbox qualification does not establish delivery through a real mail
provider. Real mailbox checks must preserve the user's task-specific limits.

For a refusal that happens before any tool call, the existing private API request
diagnostic can be armed once with `mode: "projection"` for an exact task/thread.
It compares the actual HTTP request body with the policy and active user inputs
retained by native admission, and records bounded match flags, counts, revisions,
HTTP status and the first decode outcome. It records no prompt, history, header,
URL, response text or content hash. Maintenance and correction requests cannot
consume that arm; cancellation or a superseded user revision suppresses
publication. The diagnostic is inactive unless explicitly armed. A matching
request and validated response still do not verify the requested task outcome.

## Build 226 failures and follow-up

The controlled build-226 tests used remote Cerebras GPT-OSS120b at medium effort.
They did not qualify the requested tasks, despite passing the native tests.

- A resumed Outlook chat refused without tools even though an exact-task private
  projection diagnostic confirmed fresh developer guidance and the active human
  request in the actual provider body. A fresh chat selected the matching account,
  searched and exposed attachment evidence, but stopped at the unchanged 32-call
  limit before answering. Three rejected references had been exposed earlier in
  the same immutable read, then retired solely because continuation omitted them.
- Both documentation cases exhausted the existing receipt limits. The fresh case
  performed broad recursive scans, including saved session transcripts, and used
  malformed paths. Neither produced a supported answer. Exit code 1 or a local
  search miss is not evidence that a product setting does not exist.
- The synthetic read stopped after a narrow search miss instead of refining it.
  In the same-chat send, all three fields were filled, but compaction shortened
  the last post-fill observation from 5,917 to 3,904 bytes. It removed the
  **Send message** label and reference while preserving an unlabeled **Sent**
  navigation reference. The model selected that dangling reference. The fixture
  recorded zero POSTs; the final claim of a send attempt was incorrect.

The follow-up treats ordinary and post-input browser observations as complete,
bounded evidence. The broker sizes the actual post-input JSON envelope, separate
dispatch cue, marker and reference reservations before publishing a page or
advancing its cursor. The native runtime retains the latest marked observation
intact through compaction. Historical excerpts retain whole native rows and a
separate dispatch cue, without old cursors or completeness claims. Their distinct
retention marker keeps subsequent compactions from splicing rows into dangling
references. An unavailable post-input observation still reports the dispatched
input without inviting replay. Nested JSON escaping reduces the row allowance
gradually within the same captured position, so an oversized first candidate does
not discard a smaller valid page or advance past unexposed bytes.
The existing text, serialized-output, receipt, reference and retry limits remain
unchanged. Exact-target validation and original capture expiry still apply before
input, including after an approval wait.

These changes address observed host failures. They do not turn a model's final
answer, search interpretation or selected control into verified task success.
Live qualification must still check actual outcomes and preserve failed attempts.

## Build 227 qualification

Controlled build 0.7.0 (227), commit `183ccad`, packages source-pinned runtime
`mactopus-9`. The final selected native union passed 561 tests with no remaining
failures or skips, including three enabled bundled-engine integration cases.
The runtime receipt suite passed 33 tests with one intentional diagnostic-export
skip; version/product-identity checks passed 20 tests. Initial failures remain in
the local evidence and are superseded only by recorded affected reruns. Xcode
Release packaging, Developer ID signature, copied resources and the installed
running executable were verified. This is not a published or notarized release.

Remote Cerebras GPT-OSS120b at medium effort produced mixed installed results:

- The unchanged adverse search prompt still stopped after one overly literal
  query: five calls, no native errors, no delivery. Its mailbox-wide absence claim
  was unsupported; pagination and retention fixes do not correct search reasoning.
- The same-chat send made thirteen calls with one missing-binding error. An
  earlier-page field reference correctly survived continuation. After two fills,
  however, the model reopened Compose and discarded its draft, never filled the
  message, and pressed Send with required fields empty. There was no compaction
  and zero POST deliveries. References remained attached to their actual labels.
- A fresh send-only control made nine calls, recovered from one consumed-reference
  rejection, filled all three exact fields, and produced exactly one local POST.
  The server-generated receipt was observed and copied correctly into the answer.
  The failed stale action dispatched nothing. This is a recovered outcome pass,
  not an error-free run or proof of real-provider mail delivery.
- Fresh Outlook lookup remained unqualified: it stopped at the unchanged receipt
  byte limit before a final answer. Its seventeen call/result pairs occupied
  12,982 provider-input bytes at the smallest existing retention candidate, above
  the 12,288-byte limit. The canonical total (17,946 bytes) and latest observation
  (3,905 text bytes) fit their separate limits. Eight historical reads repeated
  optional URL/title context; omitting those metadata lines alone saved 770
  serialized provider bytes. An offline replay then admitted the same genuine
  calls, results, dispatch cues and complete latest observation in 12,212 bytes.
  This identifies one avoidable stop, not a general task-capacity guarantee.

All four completed attempts closed their owned tabs and preserved existing user
tabs. Failed attempts remain part of qualification; a successful control does
not establish general reliability or resolve the goal.

A fifth, fresh read-only diagnostics test made five shell calls and failed before
answering. Three commands quoted tilde-prefixed paths, which the shell correctly
treated as literal paths; later commands scanned too broadly. An earlier schema
correction in the same turn was accepted. The final response contained valid JSON
with schema-invalid arguments and exhausted the existing correction allowance;
none of its tools executed. The finite diagnostic does not identify that rejected
field, so it is not attributed to a particular tool. No configuration changes or
browser actions were observed.

## Build 228 changes and qualification

Runtime `mactopus-10` adds one final bounded retention candidate after the existing
candidates fail. It omits optional URL/title lines from already selected historical
browser excerpts without refilling the freed space or altering rows, dispatch
cues, call/result identity or the complete latest observation. Recompaction is
idempotent and rejects malformed excerpt shapes. The existing aggregate limits
remain active; another large observation can still exhaust them.

Native submit-control clicks now observe trusted synchronous invalid events for
already captured, visible, nonsecure fields in that exact form. Bounded feedback
contains fixed validity reasons and labels drawn only from the fresh post-input
page's published spans with an equal known native document identity. Same-URL
reloads or unknown document identity cannot reassign old event reasons to new
field labels. It invokes no extra input or validation method. Native
invalid events do not establish that page handlers made no request; dispatch,
no-replay and unverified-outcome semantics remain unchanged. Retired or cancelled
contexts publish no feedback. The complete encoded feedback is included in the
existing page budget before cursor advancement.

The WebKit regression also exposed form named-property shadowing: a child field
named `hidden` made a visible form's `hidden` property truthy. Visibility now reads
the actual hidden attribute through the native Element prototype; the offending
fixture remains covered, alongside real hidden-subtree exclusion.

General terminal guidance now calls for observed absolute paths or correctly
expanded private HOME paths, locating files before bounded content searches,
scoping diagnostics to relevant files, and fixing observed path errors before
repeating them. It does not rewrite shell commands or change permissions, working
directories, retry allowances or the model's responsibility for valid arguments.

The final selected native/integration union passed 569 tests without skips,
including three enabled bundled-engine integration cases. The runtime receipt
suite passed 35 tests with one intentional private diagnostic-export skip, and
version/product-identity checks passed 20 tests. The initial native run's one
failure remains recorded; the fixed-source rerun passed all 299 affected tests.
Controlled build 0.7.0 (228), commit `a3ffb3d`, was Developer ID signed and installed;
the running executable and resources matched the validated build. Remote Cerebras
GPT-OSS120b at medium effort produced these outcomes:

- The unchanged adverse search task recovered from three rejected calls and found
  the exact announcement content and attachment filename. It reached the message
  through Inbox rather than submitting a refined search. Eighteen calls and one
  completed compaction; zero deliveries.
- The same-chat send recovered from two rejected calls, filled all three exact
  fields and produced exactly one fixture POST with an observed, matching receipt.
  Thirteen calls and one completed compaction.
- A fresh send control recovered from one consumed-reference rejection and
  produced exactly one new POST with all literal fields and its own matching
  observed receipt. Ten calls, no compaction. Neither successful send attempted an
  invalid form submission, so event-feedback coverage remains the native WebKit
  regression rather than a live-model claim.
- Fresh Outlook stopped before tools: both provider attempts sent
  `browser_tabs({"cursor":null})`, rejected by its string-only optional cursor
  schema. The finite same-turn diagnostic identifies this exact contract gap;
  it is separate from the prior receipt-capacity stop.
- The diagnostics retest reached browser work but made repeated continuation
  mistakes and stopped at the unchanged 32-call bound without an answer. Cursor
  provenance shows genuinely issued tokens reused after replacement, or combined
  with changed filters; it does not show snapshot or tab IDs used as cursors.
  Shell guidance was delivered but was not consistently followed, including
  quoted-tilde path mistakes and broad scans. No configuration write was observed.

Every attempt that created a tab closed its one owned tab and preserved existing
user tabs. Failed attempts remain recorded. These recovered local successes do
not qualify real-provider delivery, the Outlook lookup or the diagnostics task.

## Nullable inventory cursor follow-up

The built-in `browser_tabs.cursor` contract now matches `browser_read.cursor`:
null or omission starts a fresh read; only an exact issued nonempty cursor
continues a retained page. Required fields, other optional null values, foreign
schemas, cursor ownership and all existing limits remain strict. This changes
the explicit schema rather than silently rewriting invalid model arguments.

The read-cursor property and stale-cursor error now describe the latest-page
lifetime precisely: continuation advances the token, fresh reads and replacement
observations supersede old tokens, and admitted input invalidates them. The prior
"current turn" wording was too broad; the old error also suggested snapshot/tab
ID confusion even when a genuine older cursor had expired. This changes guidance,
not cursor admission, capture authority or the bounded recovery policy. Regression
coverage includes genuinely issued but consumed cursors rejected without capture.

Build 229's final-source regression run passed 281 selected Swift tests without
failures or skips, including all three enabled bundled API-engine integration
cases. An earlier run before the lifecycle wording change passed the same 281;
the unique count is 281, not 562. Version/product-identity checks passed 20 tests.
The runtime remains the identical pinned mactopus-10 artifact from build 228.
Installed live qualification for this follow-up is recorded separately.


### Build 229 live checks and observation-failure follow-up

Controlled 0.7.0 (229), source `fb65bf5`, was Developer ID signed, installed and
verified against its executable and resources. Retrying the original failed
Outlook chat successfully dispatched `browser_tabs({"cursor":null})` under its
saved string-only catalog. The next inference timed out in request transport:
142.857 seconds for the user turn, 136.062 seconds after inventory output. It
opened no tab and produced no attachment answer. This verifies the nullable
catalog repair, not the complete task or the cause of the transport stall.

A fresh Outlook control took 32.792 seconds and made five native calls without a
schema rejection or compaction. It clicked the observed matching account once;
the attached observation reported `read_not_authorized`. An explicit fresh read
then succeeded and exposed the account picker again. The model nevertheless
claimed a password/possible MFA and permission barrier without observing one.
The owned tab closed. This completed UI turn is a semantic failure.

Direct inspection in one owned normal Computa browser tab reached the mailbox by
clicking the same existing-account selector once, without a password or MFA.
The diagnostic tab was closed and the pane hidden again. This manual action
refreshed the shared sign-in session; later tests must disclose that condition.
It neither establishes autonomous sign-in success nor recovers the exact cause
of the earlier unavailable observation.

The error classification itself was incorrect: every generic `invalidRead` was
reported as `read_not_authorized`, including output-packing failures. Build 230
introduces typed scope-denial and output-limit causes, with fixed
`scope_denied`, `output_limit` and `invalid_read` observation reasons. This does
not change permission checks, dispatch, replay policy or output/recovery budgets.

The typed-cause follow-up passed 344 selected Swift tests without failures or
skips, including three enabled bundled API-engine integration cases. Native
preflight classification retains the original treatment for all three causes,
and regressions verify the existing three-failure stop without automatic reads
or additional approvals. Version/product-identity tests passed 20 checks. The
source-pinned mactopus-10 runtime is unchanged.

Controlled 0.7.0 (230), source `305203d`, was Developer ID signed, installed and
verified. Under the manually refreshed sign-in condition, the unchanged Outlook
task reached the mailbox and submitted the sender search. It still failed after
18.993 seconds and 25 calls (17 reads), with four native failures and one completed
compaction. Three genuine cursors were combined with changed filters. After
opening a message, five fresh all-view reads returned the same first 12 toolbar
rows of the 284 captured nodes, despite an available continuation. Another result
mentioned evidence, but the selected message's exposed label did not. Neither the
requested evidence-packet message nor its filename was verified. The generic
"Has attachments" control is not a filename. The owned tab closed, existing user
tabs were preserved, and the composer was empty at the terminal error.

The final retained candidate was 16,309 provider-input bytes against the unchanged
12,288-byte limit; canonical history was 23,880 bytes and individual output limits
fit. Repeated reads contributed avoidable receipts. This is an aggregate stop,
not a permission denial, individual observation overflow or the 32-call bound.

The separate build-229 documentation task also remains failed: 25 calls, including
14 shell calls, produced a minimum candidate of 15,092 provider-input bytes.
Historical debug identities were already omitted. Exact source-derived Chat
Completions projection is smaller at 13,716 bytes but still exceeds 12,288 bytes;
wire-accounting changes alone cannot resolve it. These measurements do not justify
raising limits or discarding completed actions.

## Build 231 disjoint read forms

The native contract keeps the `browser_read` tool name and distinguishes two
forms: a fresh read with optional view/query and absent or null cursor, or a
continuation with only a nonempty cursor. The model-facing schema rejects mixed
forms before native dispatch. Chat Completions keeps its existing single correction
allowance; Responses rejects the invalid reply atomically without an automatic retry.
Recognized saved catalogs receive the current form; completed historical calls
remain byte-for-byte under their frozen flat schema. Legacy native matching-filter
continuations, ownership checks and all budgets remain unchanged.

Refreshed guidance distinguishes content reads for messages/documents from
all-view structural reads that include toolbars. It states that fresh reads restart
page one and cursor-only calls advance. Guidance delivery and schema enforcement
are separate from a model following them; live qualification remains required.

The final-source selected suite passed 493 unique Swift tests without failures or
skips, including the three enabled bundled-engine integration cases. Correction
tests cover both wires, saved flat and engine-projected schemas, exact historical
argument bytes, and foreign/narrowed contracts. Version/product-identity checks
passed 20 tests. The initial failed test run remains recorded: the fixture Bun
path was omitted, two text checks needed alignment, and the new correction test
used noncanonical UUIDs and incorrectly assumed identical retry policy on both
wires. These were corrected without adding production retries. Runtime
`mactopus-10` remains unchanged.

Controlled 0.7.0 (231), source `a1f7a5d`, was Developer ID signed, installed and
verified. The unchanged fresh Outlook task failed after 30.781 seconds and eight
native calls, without compaction or a native tool failure. It opened the service
root, clicked the matching existing account once, and remained at the account
picker. The post-input observation reported `scope_denied`; a later fresh read
succeeded but still showed the picker. No mailbox search, attachment filename,
password prompt or MFA challenge was verified. Both the provider reply and its
single correction failed schema validation. The finite journal identifies tool
index 19 but no callable or field, so this evidence does not establish which
argument was invalid. Rejected calls were not dispatched. Cleanup confirmed one
owned tab closed and existing user tabs preserved.

## Correction feedback follow-up

Inspection found that corrective feedback for the recognized disjoint
`browser_read` schema listed its fields but omitted the mutually exclusive forms.
The follow-up adds fixed native descriptions of fresh and cursor-only reads. It
classifies a `read_mode_conflict` only after authoritative schema rejection, when
the exact recognized native contract's frozen flat schema accepts every field
and a nonempty cursor is combined with view/query. Other errors and foreign or
narrowed schemas retain their existing behavior. The finite journal can preserve
the known tool and root type without argument values. This is an independently
verified diagnostic gap, not a recovered explanation of build 231's rejection.
The existing single Chat Completions correction, no Responses automatic retry,
1,536-byte feedback cap and all action/history limits remain unchanged.

A separate read-order defect was found in source: fresh reads checked a tab's
current site before the transport's existing navigation-readiness wait. Native
tab metadata includes provisional addresses, so a transient address could stop
a read before that wait. Build 231's 45 ms post-click denial, followed by an
allowed snapshot on a new document generation, is consistent with this race;
the rejected address was not retained and its exact cause remains unproven.

The follow-up moves fresh-read scope authorization to after the same native
navigation wait and before driver capture. The required transport gate checks
the exact target, immutable task scope and revocable lifetimes. Enqueue checks
the gated URL and generation again. Post-capture scope and publication checks
remain; retained reads and mutation preflight keep their existing behavior. It
adds no wait, retry, route allowance, capture or input replay. The real Outlook
authentication outcome still requires a fresh live qualification.

Generic schema mismatches on a proven object root can now retain the exact
recognized built-in tool identity even when no field can be localized. This
keeps the constraint generic, preserves the closed diagnostic vocabulary, and
records no argument values. Foreign or narrowed contracts remain unidentified.

Build 232's selected final-source suite passed 573 unique Swift tests with no
failures or skips, including 34 real-WebKit transport cases and all three enabled
bundled API-engine cases. The new held-navigation fixture verifies one authorized
capture versus zero denied captures, with cancellation and tab closure stopping
before authorization. Controller cases cover exact-target replacement, lease
release with the user's tab preserved, persistent scope denial, and one dispatched
click/fill with no replay. Version/product-identity checks passed 20 tests. An
initial compiler failure on a conditional closure expression is retained in the
evidence; explicit conditional assignment resolved it without behavior changes.
The pinned mactopus-10 runtime remains unchanged. Live qualification is separate.


## Post-capture navigation ordering

Build 232 still failed the fresh Outlook attachment task: 15.964 seconds, five
native calls, and no verified mailbox or attachment. The account-selection
click dispatched once, but its following observation reported `scope_denied`.
The model incorrectly inferred a password/MFA requirement. Normal browser
navigation then reached the mailbox without credential entry; that diagnostic
refreshed the shared session and is not an autonomous qualification pass.

The bounded native log places a provisional main-frame navigation immediately
after the post-click capture and before publication. Source inspection found
that the publication guard checked the final target's scope before checking
whether its URL still matched the captured document. A changed provisional URL
could therefore mask document drift as a scope denial. The exact rejected URL
was not retained, so the live destination remains unproven.

The follow-up retains the captured-document scope check, validates the physical
target and lifetime, then compares URLs before evaluating the final target's
scope. Drift uses the existing single fresh-read recovery. Its settled target
must pass authorization before another capture. Persistent off-scope content,
a second drift, and an unauthorized captured document still fail. No timeout,
retry allowance, permitted route, input replay, or receipt limit is added.

A separate signed-in-tab diagnostic on build 232 reached message content but
no requested filename. It failed after 16.826 seconds and 21 calls. One API
read-mode conflict was corrected to a valid cursor-only continuation; a later
conflict exhausted the existing correction allowance. Compaction retained all
20 prior call/result pairs and the exact latest observation. This identifies a
separate contract/usability failure; it does not establish the rejected filter
values. The diagnostic tab was explicitly closed after testing.


## Read schema and stateful validation

The publication-order follow-up passed 574 unique Swift tests with no failures
or skips and 20 version/product-identity tests. Build 233 was signed, installed
and checked against source `1af8376`. Its fresh Outlook task reached the mailbox
through the previously refreshed shared sign-in session, without account-picker
or scope-denial events. That is not a live reproduction of the fixed race.
The task failed after 15.528 seconds and 18 native calls, with one compaction:
one `browser_read` mode conflict was corrected and a second exhausted the
existing allowance. No attachment filename was verified. Cleanup closed one
owned tab and preserved existing user tabs.

The disjoint API schema was stricter than the stateful browser contract: it
rejected every cursor-plus-filter call, including repeated filters that the
controller safely accepts. The next bounded experiment restores the flat read
schema. Field types remain validated before dispatch. Native validation still
checks the exact retained cursor, document/lease authority and captured filters.
Changed-filter continuations remain explicit failures with existing bounded
fresh-observation recovery; no arguments are rewritten and no allowance grows.

Exact legacy disjoint schemas are recognized against frozen branches, rather
than whichever definition is currently offered. Completed history stays intact;
foreign, narrowed or modified schemas do not migrate. The finite historical
`read_mode_conflict` journal vocabulary remains readable. This experiment removes
a proven schema/controller mismatch, but the rejected live arguments were not
retained, so it does not establish whether either live call repeated or changed
its filters. A new continuation tool would require saved-catalog and runtime
receipt migration and is outside this small contract correction.


The flat-schema source passed 574 unique Swift cases across the same twelve
suites, including the both-wire HTTP matrix and three enabled bundled-engine
cases, with no skips. The first run passed 573 cases and found one obsolete
guidance-string assertion. Only that assertion changed; its targeted rerun
passed with all production hashes unchanged. Both logs are retained. Version
and product identity checks passed 20 tests. Live qualification remains separate.

## Native read history and complete recovery observations

Build 235's fresh Outlook lookup reached the mailbox and actual search results,
then failed retention after 28 calls and 37.642 seconds. It did not verify the
requested filename. Local synthetic sends dispatched exactly one POST with the
requested fields, but a fresh-chat final reply attributed an older message to
the new send. A separate read changed ASCII hyphens in the filename. Those are
failed semantic acceptance checks, regardless of successful native dispatch.

The build 236 candidate preserves a failed operation and its separate successful
recovery read as one bounded, complete result. The rejection cue remains explicit
and the outer result stays failed, undispatched and unverified. The existing
producer limits include the complete escaped envelope before cursor publication.
The newest complete browser page remains intact even after a later inventory or
terminal result. No read, reference, action, correction or retry budget increases.

Runtime `mactopus-11` adds typed provenance for successful native reads and
inventories. When ordinary receipts cannot fit, only those older results can
become versioned read records with an explicit old-content omission notice.
Original IDs, raw arguments, timestamps and chronological call counts remain
local. Failures and mutations keep their ordinary receipts; current pages keep
their complete output. Adjacent serial reads can share a record, including
across same-turn reasoning that the existing compactor already omits. User or
assistant messages, other tool items, foreign/missing turn identities and
nondefault harness metadata remain boundaries. Existing run boundaries survive
reload and repeated compaction. These records cannot become prior assistant
answers or the model's compaction summary. External requests omit only optional
function item IDs, preserving exact `call_id` pairing and canonical history.

The initial serializer measurement retained the sanitized 75-position Outlook
history at **11,097 provider bytes / 21,496 canonical bytes** before history
assigned enclosing message IDs. Its 15 reasoning positions and all four message
boundaries preserve the original typed layout. Five representative 32-call
continuations initially appeared to fit, but later admission-path review found
an additional 48 bytes per retained run from those IDs. Two of those continuations
therefore exceeded the provider bound; the earlier 69-byte minimum headroom was
not a persisted-wire guarantee. The corrected admission counts real IDs before
checking the unchanged limits. Deliberate byte overflow and the 33rd genuine call
still stop. Initial fixture omissions, the first repeated-compaction grouping
defect and this sizing gap remain failed evidence, not discarded runs.

Source qualification passed 59 isolated retention, projection and restoration
checks (one private-rollout export intentionally skipped), five isolated native
provenance checks, four history checks and the two focused protocol checks.
The restoration harness uses a strict plain-user fixture parser with the actual
restoration/filter code; it is not a full Core-suite result. Stable and experimental
protocol exports were regenerated and independently checked. Native recovery
and RPC tests passed 159 cases after fixing the missing separate-read source
field and a test-helper mismatch. The final thirteen-suite run passed all 590
native cases without failures or skips, including all three bundled-engine API
tests. Version and product identity checks passed 20 cases. The production
runtime compiled successfully and its packaged binary and pinned patch were
verified. The signed app and fresh live acceptance results remain separate
required evidence.

The signed build 236 was installed and matched its committed source and packaged
runtime. Its first local mailbox read passed in 3.250 seconds with five tools and
no failures, including an exact filename. Same-chat and fresh synthetic sends
each produced exactly one local POST with the requested fields; their current
receipts were observed. The fresh final reply still changed punctuation in the
recipient and spacing in the body, so delivery and literal-copy fidelity remain
separate results. All three trials closed their owned tab and preserved user tabs.

The real Outlook lookup failed after 22.397 seconds. Its first compaction assigned
normal native message IDs to the retained read records; a later expansion compared
them to records with no enclosing message ID and incorrectly rejected the history.
This is a runtime defect, not missing site permission or an attachment result.
The build 237 candidate accepts that host-assigned enclosing ID while preserving
exact checks of the record's remaining fields and original call/output identities.

The read-only diagnostics trial also failed semantic acceptance. It read actual
documentation, then invented unsupported CLI syntax and a configuration field.
Three broad local-history searches returned running sessions and excessive output;
subsequent process inspection found none remaining. No unmatched process was killed.
The candidate adds an explicit unverified-command fallback to the shared guidance
within its existing byte limit. This is guidance, not a proof of grounded answers.
It also fixes the presentation-only error summary that exposed a retention marker
instead of explaining a recovered failure. Fresh build 237 live qualification is
still required; these build 236 failures remain part of the evidence.

The final build 237 isolated source run passed 61 checks, with one intentional
private export skip. Regressions first reproduced the message-ID error and the
post-admission byte increase, then exercised actual ID assignment,
serialization/reload and two more compactions. The unchanged build 236 checkpoint
now fits at 10,913 provider / 18,171 canonical bytes for 18 calls; the actual failed
29-call candidate fits at 11,767 / 22,750 bytes. Saving adds zero bytes afterward.
Four of five tested 32-call continuations fit, with the tightest leaving only
36 provider / 352 canonical bytes; the heavier failure case correctly rejects.
Altered record text, role, phase and provenance still reject. The presentation fix
passed 22 focused native tests. These source replays do not establish a new
website result or a grounded diagnostic answer.

The affected native source checks cover 189 unique cases. The first run found
two prompt-size assertions after expanding diagnostic guidance; shortening the
guidance, without increasing either limit, passed the 47-case instructions suite
on rerun. The other 142 cases passed unchanged. The initial packaging-identity
check ran before the new runtime was packaged and correctly rejected the old
artifact. After the final runtime rebuild, all three bundled-engine checks and
all 20 version/product-identity checks passed. Installed live qualification remains
separate.


### Build 237 live checks and filtered control visibility

The signed build 237 matched source `87d265e` and the final `mactopus-12`
runtime. The real Outlook lookup failed semantic acceptance in 36.556 seconds
with 13 calls, two recovered errors and no compaction. Its last `content` view
showed only “Pick an account” from a 17-node capture. It exposed no account
controls and no password/MFA requirement, but the model asked the user to sign
in instead of requesting controls. The natural ODE follow-up then repeated that
historical block without any tool calls. Neither result proves an access block.

Compact snapshots had weaker view guidance than full snapshots. The next
candidate reports the number of enabled input-capable nodes excluded by the
selected view/query from the same captured subtree. When positive, it directs
a fresh overview/all read before claiming an access block. This is a count of
filtered captured nodes, not hidden page content, pagination, or permission. It
exposes no omitted labels/references, changes no input authority, and preserves
all existing limits. The 90-case broker suite passed without failures or skips.
An installed retest remains required; this hint cannot itself guarantee that a
model will inspect the page or correct a historical false refusal.

The local read returned the requested attachment filename exactly. A same-chat
send follow-up failed after repeated page reopening and the unchanged 32-call
guard; no POST occurred. Two successful compactions preceded that guard, so
the repaired saved-read expansion was exercised without the earlier message-ID
validation error. The independent fresh-chat send reached a current receipt;
its single POST matched all requested fields, and its final reply copied that
current receipt exactly (8.028 seconds, 14 tools, three recovered errors). The diagnostic trial repeated
negative searches and launched broad home-directory scans. It was interrupted,
and the engine confirmed termination of its four owned command sessions. A
receipt-bound error was visible in the UI, but the canonical interrupted trace
does not establish whether that error preceded the stop action. These failed
trials remain part of qualification.


Build 238 installed the filtered-control change on the unchanged `mactopus-12`
runtime, with all 11 native build/signing/resource checks passing. The Outlook
lookup used the new hint, read broader controls, selected the matching account,
and reached signed-in Outlook without a password/MFA block. It still failed
after 20 calls and 56.799 seconds: repeated invalid content continuations
reached the existing recovery guard, without establishing the requested message
or attachment filename. The ODE follow-up submitted searches but repeated
queries instead of following relevant results; 37 calls, ten native failures and
two successful compactions ended at the unchanged 32-call retention guard.
Cleanup closed one and two owned tabs respectively and preserved user tabs.

The request-order investigation found that every ordinary provider continuation
currently appends a new user-role copy of the active request after tool results.
The failed build 237 send had received a current Send reference before reopening
a blank compose page. The copied request is a plausible restart signal, but the
trace alone does not establish causation: the build 238 same-chat send control
completed. A pending candidate will omit ordinary reminders only when native
provenance and exact byte/order checks establish that all admitted user inputs
remain intact at their original positions. Missing, truncated, dropped or
unsupported proof retains the existing fallback; maintenance reminders and
authorization remain unchanged.

Build 238's local read passed with the exact attachment filename. Both synthetic
sends delivered exactly once with the requested fields. However, the fresh-chat
send subsequently read Sent and attributed the older message's subject and
receipt to the new send. The mixed overview interleaved fields from separate
articles without preserving their parent associations. The correct current
receipt had already been observed; delivery therefore passed while the final
attribution failed. No repeated send or external email occurred. All owned tabs
were cleaned up, and the local fixture was stopped with its event log preserved.

### Build 239 candidate and qualification boundaries

The `mactopus-13` runtime emits an optional body-only retention proof for ordinary
inference. Native current-turn provenance selects single-text human messages in
the finalized outgoing history. The proof binds their exact bytes, order and raw
input positions to the thread, turn and request kind. The API bridge independently
matches the proof to all admitted human inputs and the translated user-message
sequence before omitting redundant reminders. It never finds inputs by searching
for matching prose or elevates user text to developer instructions. Missing or
invalid proof preserves the existing reminder behavior. WebSocket requests omit
the proof because incremental input positions can change. Existing request and
metadata limits remain unchanged, and the proof is removed before remote dispatch.
A bounded diagnostic reports proof acceptance and reminder counts without text,
identities, hashes or headers.

Compact browser rows now preserve observed semantic record ancestry using a
capture-qualified `record_path`. Each row remains attributable when a historical
excerpt omits its original header, including when two captures share the same
local ordinal. Missing, ambiguous, ignored, cyclic or overly deep ancestry yields
no association. Paths are passive read evidence, survive pagination, consume the
existing output budget, and do not participate in action-reference corroboration.
This addresses omitted structure; it cannot guarantee correct model attribution.

The proof implementation passed 53 API server tests and 11 exact-source native
checks. Three additional exact-source historical-row checks preserved distinct
capture identities through repeated compaction/reload and retained or omitted
whole UTF-8 rows at the byte boundary. The production runtime rebuilt successfully
with its pinned patch unchanged. Broker, bundled-engine and installed live
qualification are recorded separately below as they complete. These two changes
are tested together; the live comparison is not a single-variable experiment.

All 94 broker cases passed, including actual action-witness preservation across
record renumbering and partial-source UTF-8 pagination within unchanged limits.
All three bundled-engine API tests passed against the rebuilt `mactopus-13`
artifact. The upstream fixture observed exactly one original user message before
tool results, no trailing duplicate reminder, and both real user turns in the
correct order after cold resume. Existing file-edit, command, reasoning, rate-limit
and correction checks passed. All 20 version/product-identity checks passed.
Initial new-test argument-order compile errors and the old runtime-version
expectation failure were preserved, corrected and rerun; they are not hidden
passes.

Signed build 239 installed from `65595af`, matching all 11 signing, version,
resource and source checks. The local read passed (2.686 seconds, four calls,
no failures or compactions, no POST). The same-chat send failed: after one
recovered missing-binding error, the model incorrectly demanded later
authorization despite the explicit current send request. No POST occurred.
All five ordinary inferences in each of those turns accepted the native proof
and omitted reminders, so the refusal is not a fallback or proof-admission error.

The independent send passed delivery and attribution: exactly one POST matched
all three requested fields, and the final cited its current receipt. It still
took 22.572 seconds and 31 calls, with three recovered failures and two completed
compactions. It used an old Send reference after filling fields, restarted reads
instead of continuing them, and unnecessarily reopened compose. All 32 ordinary
inferences accepted the proof; both maintenance inferences retained their
reminder. The last observation, message IDs and exact active user text survived
both compactions. This is a successful individual task, not reliable acceptance.

The real attachment lookup failed in 47.652 seconds with 23 calls, three native
failures and one completed compaction. The model reached an account picker but
repeated filtered text reads after being told six input-capable controls were
omitted. No password/MFA block or attachment was established. The natural ODE
follow-up repeated that historical sign-in claim without inspecting the current
browser. The diagnostics trial was interrupted after repeated broad local
searches; all 16 command receipts were terminal, so historical session IDs found
inside search output were not evidence of leaked current commands. No settings
were changed. Owned tabs were cleaned up and the fixture stopped with its eight
events and single POST unchanged. These failures remain unresolved acceptance
work; request chronology and record association alone did not solve them.


### Build 240: separate fresh reads from continuation

New chats register `browser_read(view?, query?)` for fresh page selections and
`browser_continue(cursor)` for the latest retained page. The second tool accepts
only a nonempty cursor: changed filters cannot be attached to a continuation.
Saved chats retain their registered legacy read contract. Provider projection
adds no tool identity and preserves completed call names, arguments and IDs.
Custom schemas do not acquire native compatibility by name alone.

Both forms use the same native cursor path, freshness checks and failure family;
a successful fresh read on the same document cannot refund continuation failures.
Tool-neutral footer and error guidance work with either registered catalog. The
shared authority paragraph now explicitly distinguishes a current requested send
from a prior task-local read-only instruction, while preserving ongoing user
restrictions, actual approvals/denials and Stop.

Runtime `mactopus-14` adds typed `continue_v1` provenance bound to the successful
pending `browser_continue` and exact cursor-only arguments. Latest continuation
pages stay complete; older eligible pages retain their actual tool identity in
the existing historical ledger. Existing 32-call, 12 KiB provider and 24 KiB
canonical receipt limits, action-reference limits and approval checks remain.

Source qualification passed 623 focused Swift tests, 67 isolated exact-source
Rust checks and 20 version/product checks. The isolated Rust harness uses
import-only adapters and does not claim full app-server test execution. All four
actual bundled-engine API cases passed against the final runtime, including a
new six-inference loopback case: inventory, binding, fresh read, continuation,
completion and cold resume. It verifies exact native proof names, same captured
source, retained page offset, unchanged historical call arguments/output and no
browser mutations. Existing edit, command, reasoning, rate-limit and correction
coverage also passed. Both final Swift runs recorded unchanged source.

Final runtime patch SHA-256 is
`7b9a8323cbc848c82b3c7bd388f61dd8be1f905be4f5d4c6b1cdc6f15025525b`;
binary SHA-256 is
`5e442cf64a8f48c562f015f1deadf2573bff5562e6c7c0dbe0fad29de29afcc1`.
Validation receipts are retained under the task's
`work/action-reliability-20261023/` evidence directory.

Unsuccessful attempts remain recorded: a Rust test incorrectly assumed small
receipts triggered ledger packing; the first Swift compile used a nonexistent
trace-loader method; the next Swift run had stale wording/null assertions and
overlapped runtime signing. The new bundled fixture initially used a symlinked
`/var` path, correctly rejected by the naming store before provider dispatch;
using the canonical temporary directory fixed that fixture without weakening
the store. Final tests supersede these attempts; the initial logs remain.

Signed build 240 installed from `5ce105d` with runtime `mactopus-14`.
Remote Cerebras GPT-OSS120b at medium effort produced mixed completed results:

- Local read passed in 3.244 seconds with five calls, the exact attachment
  filename and zero POSTs. The same-chat explicit send failed in 0.543 seconds
  with zero tools or POSTs: the model incorrectly treated the earlier read-only
  task as a host prohibition despite current authorization. No native gate
  rejected the send.
- Fresh local send passed in 5.743 seconds with ten calls and one stale-reference
  rejection. Exactly one POST matched all three requested fields, and the answer
  cited the current observed receipt. No failed action dispatched input.
- Real Outlook reached the requested account's mailbox and used three successful
  cursor-only continuations, but failed after 40.017 seconds and 37 calls, with
  two native failures and two compactions. It never established the attachment
  filename before the unchanged 32-pair retention bound stopped the turn. A
  distinct eligible Search button was exposed after filling the site's search
  field; the model selected message options instead and never clicked Search.
- The ODE follow-up failed after 37.612 seconds and fourteen calls. It reported
  generic public web snippets as announcements for the user's class. Compaction
  retained the original Outlook/account request, but its generated summary
  described that task as unrelated. This is a context-interpretation failure,
  not proof that the original human context was removed.
- Read-only diagnostics failed semantic acceptance after 42.844 seconds and
  41 calls. Real official documentation supported general browser-policy controls,
  but the answer asserted an unobserved workspace setting, exact unobserved toggle
  wording and universal CLI absence. Fifteen shell commands were read-only and
  ultimately terminal; broad scans and unsupported command options added work.

`browser_continue` worked in the local send, Outlook and ODE trials. The local
trials had no compaction, so they do not qualify retention behavior. Successful
continuation transport does not prove correct search submission, target choice,
result interpretation or authorization adherence.

Owned-tab cleanup was separately observed: fresh send, ODE and diagnostics
preserved user tabs and left an empty composer with Send disabled; local read
preserved user tabs. The attachment trial closed one owned tab, without a separate
user-tab-preservation observation for that turn. The zero-tool refusal created no
owned tabs. No real mail send, forward, download or delete, or configuration
mutation, was observed.

A separate manual CUA diagnostic reached the mailbox in the same browser profile,
filled search and clicked the distinct Search button once. Results appeared
without Enter. Its owned tab was closed and the initial zero-tab/hidden-pane state
restored. This confirms that UI capability; it is not an autonomous lookup pass
or attachment verification. The finite audits and corrected exact prompt
comparisons are preserved in `work/action-reliability-20261023/audits240/`.
The draft goal remains incomplete.

The final packaging check also caught stale generated protocol exports. The real
source generator refreshed exactly five files: the TypeScript enum, two visible
JSON schemas and both embedded export archives. Decoded archive comparison proved
that only `continue_v1` was added, including the stable internal rollout schema.
Four schema consistency tests and three actual protocol decoder/serialization
tests passed. The runtime was rebuilt with those exports and its final identity
is recorded above; the initial pre-schema artifact and receipts are preserved.


### Build 241: source qualification and mixed live outcomes

The candidate qualifies read-only guidance to the user's task and diagnostic
checks to diagnostic tasks. It preserves current-send authorization, ongoing
user restrictions, approvals, denials and Stop. Compaction preserves needed
user-specified service/account/topic context unless explicitly changed, while
keeping earlier actions and results historical. Search guidance now directs one
click on the observed submit control only after inspecting results and finding
search still pending. It does not assume that filling cannot trigger page handlers
or permit blind input replay. The replacement is two bytes shorter; all instruction
limits remain unchanged. These edits do not prove model adherence.

For the known Cerebras GPT-OSS120b Chat Completions route, the dispatch copy omits
reasoning from completed turns only after an explicit final-answer phase with no
pending calls. All saved capsules and call pairs validate first. Active tool-cycle
reasoning, ordinary messages, calls/results and canonical history remain intact;
other routes preserve their existing behavior. Before the final search-guidance
edit, all 144 focused Swift tests passed, including four actual bundled-engine API
cases, 47 instruction tests and six new reasoning-history tests. After the final
edit, all 47 affected instruction tests passed again. The initial two schema-test failures from
an omitted Bun path are preserved; the correctly configured rerun passed.

A separate installed-runtime loopback using the GPT-OSS catalog passed 122
assertions across five requests. Explicit commentary/final-answer phases survived
active tool cycles, the next user turn and cold resume. The retained integration
suite passed four tests with 352 assertions over ten native requests, including
compaction and resume. Neither probe made a remote provider request. Initial
launcher failures and an incorrect empty-annotation expectation remain recorded;
the corrected harnesses passed without changing the runtime.

Installed live trials used remote Cerebras GPT-OSS120b at medium effort:

- The synthetic read passed in 3.277 seconds with four calls, no errors or
  compaction, and zero POSTs. The answer reported the observed change and copied
  the attachment filename exactly.
- Both authorized synthetic sends failed before any tool call: the same-chat
  follow-up in 0.520 seconds and an independent fresh task in 0.477 seconds. Both
  invented a host read-only prohibition; no native gate denied input and no POST
  occurred. The fresh failure does not require earlier read-only conversation
  history. Current user-proof checks accepted both requests and omitted duplicate
  reminders, but no separate raw remote-request capture was made. The refusal
  remains unresolved.
- The real Outlook attachment task passed in 29.401 seconds with seventeen calls,
  zero native errors and one compaction. It selected the matching account,
  submitted search, opened the relevant conversation and copied an actual
  attachment filename exactly from that conversation. This is one successful
  task, not a repeated-reliability claim; no attachment was opened or downloaded.
- The ODE follow-up preserved the intended service/account context but failed
  semantic acceptance in 14.037 seconds with nineteen calls, one native failure
  and one compaction. It submitted a query for the earlier task's sender, failed
  to replace it after a correctly rejected stale reference, and left its final
  query unsubmitted. It then treated autocomplete absence as mailbox absence and
  overstated which searches had run. Valid continuation transport and successful
  compaction did not establish the requested announcements or a justified absence.
- Read-only diagnostics were stopped through the UI after 38.033 seconds and
  47 shell calls: 34 listings, eight searches, three file-discovery commands and
  two file reads. Twenty-eight calls exited with code 1; 29 outputs explicitly
  reported missing paths. The model repeatedly appended application paths to its
  private HOME, including ten repetitions of one command, despite path-error
  guidance and successful absolute-path listings. One broad search remained
  running and was never polled. No supported setting or command was established,
  and there was no final answer. Native cancellation and termination of that
  owned session were separately confirmed. All commands were read-only.

The diagnostic trace retains all 47 matched call/result pairs, including the
short path-error receipts, with no compaction or orphaned outputs. Source review
found no result-dropping or tool-name mapping defect: the codec preserves these
strings as matched tool messages. This is canonical-history and source evidence,
not an independent capture of the remote request. The delivered instructions
already warned about private HOME, scoped searches and fixing errors before
repeating; no missing-instruction cause was proven.

Owned-tab cleanup was observed for the synthetic read, attachment lookup and ODE
follow-up; the zero-tool refusals created none. No real mail was sent, forwarded,
removed or downloaded. Finite evidence is preserved in `audits241/`; task status
and cleanup are recorded separately. No execution or retention budget, native
permission, runtime package or approval policy changed in build 241.

### Build 242: fresh delivery passed; same-chat refusal remains

Installed source `ce8a46e` uses the unchanged `mactopus-14` runtime. The code
change replaces only the first background-policy paragraph to state explicitly
that background-only permits user-authorized native AX/browser writes under
native checks. Existing restrictions on recovery, activation, global input and
image authority remain. The paragraph is 313 bytes, one byte shorter than before.
All 45 focused tool-contract tests passed with unchanged sources.

Three live trials used remote Cerebras GPT-OSS120b at medium effort and exactly
matched their build 241 user prompts:

- Fresh synthetic send delivered the exact recipient, subject and body once in
  12.569 seconds with seventeen calls, one stale-reference rejection and one
  compaction. The stale Send reference had been consumed by later fills; it was
  rejected before input and returned a separate recovery read. Five subsequent
  `all` reads restarted page one instead of using the offered continuation. Send
  remained beyond those bounded pages, then a filtered fresh read exposed the
  current button and one click produced the single POST. The newest observation
  survived compaction byte-for-byte. The final answer changed the receipt and
  recipient hyphens to U+2011 and a body space to U+202F: delivery passed, literal
  final copying failed.
- Synthetic read passed in 3.440 seconds with five calls, no errors or compaction,
  and zero POSTs. It read the actual message and copied the attachment filename
  exactly. Its body quotation changed a space to U+202F; exact body transcription
  was not requested.
- Same-chat send failed in 2.512 seconds after three successful calls: open, read
  and Compose click. The current observation exposed all three editable fields
  with usable fill references and no access or permission denial. The model then
  falsely claimed background-only permits only read-only actions. No fill or POST
  occurred. The trace's base instructions contain the new write-authority wording;
  its retained developer instructions also explicitly authorize a current send
  after task-local read-only work. A raw remote request was not captured, so this
  does not independently establish downstream instruction processing.

Each trial closed one owned tab, preserved user tabs and left an empty composer
with Send disabled. The fixture recorded exactly one synthetic POST across these
trials, attributable to the fresh send. No real mail mutation occurred. Finite
per-turn audits are in `audits242/`; the earlier failures remain preserved. The
fresh success is one observation, not proof that the wording caused it or that
send reliability is repaired. Same-chat authorization adherence, literal copying,
search interpretation and useful diagnostics remain unresolved. The goal remains
active, with all execution, retention, permission and approval limits unchanged.

### Build 243: compact form observations and task scope

The build 242 source captured the entire fifteen-row synthetic Compose form.
Repeated metadata and conservative reference reserves split its model-facing
representation, leaving Send beyond the first page. The candidate shortens
presentation metadata without changing captured rows, field values, roles,
ancestry, reference checks or the 4,096-byte text/4,608-byte serialized limits.
The exact continuation remains in the READ header. Filtered match evidence keeps
its existing JSON shape; unfiltered compact reads state the same capture-only
facts more concisely. The native document epoch remains in the binding and
snapshot, while its already-hidden display copy is removed before sizing.

The shared authority paragraph now describes current and prior task scopes
without a generic list of forbidden effects. Ongoing user restrictions, actual
approvals/denials and Stop remain binding. Command guidance explicitly identifies
HOME as isolated rather than the macOS home. This clarifies an upfront environment
ambiguity; it does not explain away later repetition after the model had already
observed correct absolute paths and errors. Installed qualification is recorded below.

Validation passed 305 tests with zero failures or skips, including 34 isolated
WebKit transport tests. Source hashes remained stable throughout the final run.
All fifteen read rows occupy 3,840 raw / 4,081 serialized bytes; all twelve
post-fill rows occupy 3,996 / 4,427, and the rejected-input recovery occupies
4,009 / 4,436. Each exposes the current Send action within unchanged limits. Long
escaped field values still paginate and reconstruct exactly. The first failed
run is preserved with its stale wording assertions and an instruction-length
regression; both were corrected without increasing any limit. These are
representation and contract results, not live-model acceptance.

Installed source `568847a` uses unchanged runtime `mactopus-14`. The three
synthetic trials exactly matched the 241/242 prompts and used remote Cerebras
GPT-OSS120b at medium effort:

- Fresh send produced one exact POST in 5.081 seconds with eight calls, no native
  failures and no compaction. The final post-fill page exposed the current Send
  action, and the immediate confirmation exposed the new receipt. After visiting
  Sent, however, the model cited an older same-subject delivery's receipt and
  changed its hyphen to U+2011. The older and newer records had different
  capture-local record paths; the newer record continued beyond that bounded
  page. Recipient typography also changed. This is a current-record association
  failure as well as a literal-copy failure, despite correct new delivery.
- Read-only control passed in 2.455 seconds with four calls, no errors or
  compaction and zero POSTs. The observed message supported the reported change,
  and the attachment filename was copied exactly.
- Same-chat send produced one exact POST in 6.472 seconds with nine calls and no
  compaction. Its initial prior-turn click was correctly rejected as
  `browser_binding_required` before input. The model reopened, read, filled and
  sent successfully. The final accurately reported the local confirmation but
  omitted its receipt. The earlier false read-only refusal did not recur in
  this sampled turn; this does not establish repeated reliability or causality.

Real-mail and diagnostic acceptance remained unsuccessful:

- Attachment lookup stopped after 82.623 seconds and thirty-three calls at the
  unchanged thirty-two completed-call retention bound, without a final answer.
  Inventory was empty, so no existing Outlook tab was offered and ignored. Five
  repeated personal-route navigations and two duplicate content reads stayed on
  the public landing page before an observed Sign in link and matching account
  choice reached the mailbox. Three genuine continuations advanced successfully.
  The requested subject and filename were not exposed; truncated capture evidence
  does not establish their absence. No native tool failed, and one compaction
  completed before the terminal guard.
- The natural course-announcement follow-up completed in 15.774 seconds with
  sixteen calls, one stale fill rejection and two compactions, but answered the
  prior attachment task instead. Its current human request survived the later
  compaction byte-for-byte, and that summary explicitly identified the course
  request as active and the attachment search as unrelated. The summary also
  suggested an external web search instead of retaining the mailbox context.
  Finite API diagnostics accepted the current-user proof on all seventeen
  ordinary inferences, including the final one; maintenance requests retained
  the reminder. No dropped-user projection was established. The attachment
  filename was observed but altered typographically in the wrong-task answer.
- Diagnostics were stopped after 32.792 seconds and thirteen read-only commands:
  three listings, nine searches and one file read. The exact prompt matched 241.
  The private-HOME path error did not recur, but duplicate broad home-directory
  searches, two unpolled running-session receipts and another repeated search
  produced no supported setting or command and no final answer. Three owned
  commands were confirmed terminated after Stop.

Each synthetic trial and attachment lookup closed one owned tab; the course
follow-up closed two. User tabs were preserved and composers were empty. The two
synthetic sends each contributed one exact POST; no real mail mutation occurred.
Finite audits, exact event attribution, literal comparisons and separate UI
cleanup reports are in `audits243/`. The goal remains unresolved: correct delivery
alone does not satisfy current-record evidence, exact copying, task focus,
mailbox search or useful diagnostic acceptance. Earlier failures remain preserved,
and no execution, retention, retry, permission or approval limit was raised.

### Build 244: observations after browser lifecycle operations

The candidate returns one bounded current overview after successful
`browser_open`, `browser_bind` or `browser_navigate`. The existing fresh-read path
supplies it on the same owned or borrowed binding, including its existing bounded
stale-document recovery. It never repeats the lifecycle operation. This removes
the need for a separate read merely to observe the page reached by that operation;
it does not establish that the user’s website task succeeded.

The host enables this behavior only when the verified runtime manifest declares
`browserLifecycleObservationsV1`. Older runtimes retain their metadata-only
responses. An available overview is sized with its completion cue and full
envelope before references or a continuation are published. The runtime preserves
the newest complete browser observation byte-for-byte, including when a later
nonbrowser result or inventory follows it. Older lifecycle observations use the
existing whole-row historical representation while retaining the genuine
function name, call ID, raw arguments and completion cue. Lifecycle operations
never receive `nativeRead` provenance and cannot enter the successful-read ledger.

Stop, cancellation, lease retirement, scope and publication fences remain in
force. If the operation completes but its following capture fails, a live result
keeps the completion cue and reports the observation unavailable; references are
retired and the operation must not be replayed. A retired or cancelled result is
suppressed at the existing host publication fence. A held capture can leave
cleanup temporarily uncertain under the existing cleanup contract; this change
does not convert that state into confirmed cleanup.

Limits remain unchanged: 4,096 text bytes and 4,608 serialized native observation
bytes, 12 KiB provider / 24 KiB canonical retained receipts, thirty-two completed
calls, existing reference and recovery budgets, approvals and permissions.

Validation before installation:

- 429 distinct targeted Swift cases passed across the main run and its focused
  68-case rerun, including real isolated WebKit cases. The only changes between
  those runs were the new bundled runtime/manifest and a test-only expectation
  for the deliberately held capture's existing pending-cleanup report. Sources
  were stable within each run; the initial compile error and failed assertion
  are preserved in the task evidence.
- Five actual bundled-engine loopback integration cases passed with zero skips.
  The new case exercises four real compactions and a cold restart, checking the
  latest page bytes, genuine function name/call ID/raw arguments, absence from
  the successful-read ledger, and no replay. Existing patch/command, continuation,
  failed-batch and upstream-429 cases also pass.
- The actual-source isolated native retention suite passed 71 cases; direct tests
  of the complete Rust artifact validator passed all three cases. The isolated
  retention harness omits one private-export test and is supplementary to the
  bundled-engine integration, not a full upstream test-suite claim.
- All 29 runtime-source, product-identity and version Bun checks passed after
  packaging. The prepackaging mismatch against runtime14 remains recorded.
- Runtime15 uses patch `083202ea2ca3485652b2dd9e1356addde30e0a80cc8e3878eb477ec164a31af7`
  and packaged binary `74f7b89e6b23276f6795b8fa377019b73bc5d5ebe8b8f92436f978076fcbd96f`
  (292,294,624 bytes), schema2, declaring only `browserLifecycleObservationsV1`.
  The source pin and exact patch were checked before and after the build.

Installed build 244 was verified against source `9440287` and the packaged
runtime above. Live trials used remote Cerebras GPT-OSS 120B at medium effort.

| Local fixture trial | Seconds | Calls | Result |
| --- | ---: | ---: | --- |
| Fresh send | 4.841 | 7 | One exact POST; observed current receipt copied exactly. |
| Read control | 2.107 | 3 | Correct change and exact attachment filename; zero POSTs. |
| Same-chat send | 4.704 | 6 | One exact POST; current receipt and final fields copied exactly. |
| Fresh-send repetition | 4.281 | 7 | One exact POST; observed current receipt copied exactly. |

All four local trials had zero native tool errors and zero compactions. Each send
used the overview returned by open directly, with no separate initial read or
repeated delivery. The two fresh-send answers changed recipient/body typography,
although their actual submitted fields and returned receipts were exact. These
three deliveries are sampled successes, not a general reliability result.

Real-mail results diverged:

- The first attachment lookup took 22.626 seconds and ten calls, with one rejected
  stale click and no compaction. It submitted website search, opened a matching
  conversation and copied an observed attachment filename exactly. Truncated
  capture does not establish complete mailbox coverage or a unique intended match.
- The repeated lookup took 18.854 seconds and twenty-one calls, with no native
  failures and one compaction. Its different filename was genuinely published and
  copied exactly, but sender attribution was wrong. Independent manual inspection
  expanded the attachment-bearing message in the four-message conversation: its
  From heading identified the account owner, while the requested sender authored
  other messages. The model had treated a conversation-level attachment as that
  sender's attachment. Capture-local record ancestry is not message authorship;
  this was an attribution failure, not a fabricated filename or demonstrated
  compaction corruption. The diagnostic tab was closed without opening or
  downloading the attachment or changing mail.
- The natural course-announcement follow-up took 8.202 seconds and seven calls,
  with no native failures and one compaction. Website search was submitted, but
  the final mailbox-wide absence claim exceeded the partial results. A relevant
  option and continuation were available; the model selected another option and
  answered without reading its body. No zero-result evidence supported the claim.

Finite trace, fixture-event and separate UI cleanup evidence is in `audits244/`.
`outlook-repeat-independent-check.json` adds the manual ownership verification
without rewriting the original trace-only audit. No real mail was sent, forwarded,
deleted or downloaded. The goal remains unresolved: sender/message association,
negative-search grounding and literal copying still fail in these samples, and
diagnostics were not requalified in 244. Earlier failures and all existing limits
remain preserved.

## Build 245: individual-message evidence

The 244 repeated Outlook lookup exposed two separate gaps. The answer attributed
a genuine attachment to the wrong participant in a multi-author conversation.
The opened-conversation tool output also lacked per-message ancestry, while the
native accessibility view exposed individual message containers. The exact
Outlook DOM wrapper responsible was not inspected, so this is not a claim that
one site-specific selector was identified or fixed.

The generic capture now retains rendered DIV/SECTION containers with safe
explicit accessible names as passive groups. Named groups/regions carry internal
default-false naming provenance; only that provenance admits them to the existing
bounded record ancestry. Unnamed wrappers remain flattened. New container names
never aggregate arbitrary descendant text or hidden, inert or secure label
subtrees. Containers gain no click/fill capability; a child action still needs
its own current reference and unchanged semantic parent. Paths describe nesting,
not authorship or verified outcomes.

The existing refreshed evidence block now requires attachments to belong to the
requested sender's own message rather than matching a thread participant or
recipient. It reaches native instructions, resumed API checkpoints and website
handoffs without adding a new prompt surface. Search evidence remains bounded:
submission is conditional on pending results; captured-UI filtering is distinct
from website search; partial or narrow misses do not establish absence. The block
is 545 bytes, built-in guidance 4,522 bytes and the maximum combined checkpoint
9,964 bytes, all within unchanged limits.

Validation before installation: 346 focused Swift tests passed with zero failures
or skips and unchanged source hashes. Five new WebKit/broker cases cover passive
named containers, duplicate names across bounded pages/subtrees, strict Boolean
decoding with legacy absence, hidden/secure/malformed labels, and child actions
under the newly retained parent. Three isolated HTTP mailbox tests also passed.

Two mixed-author fixture trials already passed on build 244: 2.041 and 2.520
seconds, three calls each, zero tool errors or POSTs. Both expanded and read the
staff message, rather than using the learner's visible attachment. The missing
variant's final answer scoped absence correctly but changed a quoted address's
hyphen. These are baseline controls, not evidence of a 245 repair. The fixture
uses article roles and does not reproduce Outlook's ungrouped DOM output.

Installed signed-test build 245 matches validated source `e88febe` and unchanged
runtime `mactopus-15`; it is not a notarized or published release. Live trials used
remote Cerebras GPT-OSS-120B at medium effort. The two mixed-author controls passed
again in 2.235 and 2.351 seconds, three calls each, with no errors or POSTs. Their
244 baseline already passed, so these controls do not demonstrate a repair.

Two real Outlook attachment lookups returned exact observed filenames in 9.635
and 25.650 seconds (11 and 15 calls, zero native failures, zero and one
compactions). Each current capture placed the requested name heading, separate
recipient/date headings and attachment under one inner message path. This
supports message-level association, unlike the 244 wrong-owner result; partial
captures and shared filenames still do not prove a unique mailbox match or
independently authenticate a sender. The ODE follow-up failed after 27.744 seconds,
32 calls, four rejected actions and three compactions: it answered the previous
attachment task. The exact current user request and correct summary goals
survived all three compactions. This was a wrong final answer, not a call-limit
termination.

The local read took 2.338 seconds and three calls, correctly giving the change
and primary filename, but altered hyphens in an additional source quote. Same-chat
and fresh sends took 6.139 and 4.612 seconds (eight and six calls). Each produced
exactly one new POST with exact fields and an observed current receipt. The
same-chat run recovered from one old-binding rejection. Its receipt copy was
exact, while recipient/body echoes changed typography; the fresh run changed the
receipt and recipient hyphens. None of these local trials compacted.

UI checks confirmed one owned tab closed per trial, existing tabs preserved and
empty composers. Both owned fixture servers were stopped; their ports closed and
event evidence remained unchanged. No real-mail send, forward, deletion or
download was observed.
The goal remains unresolved: task continuity and literal copying still failed,
and diagnostics were not requalified. No limit, permission or approval boundary
was increased.

## Build 246: preserve interaction during startup

During the first build245 launch, creating a new draft while saved history loaded
was followed by a switch to an older saved chat and an empty composer. The UI
test's fresh-state check prevented sending the intended fixture prompt to that
wrong chat. Source inspection identified an unconditional history replacement
after the asynchronous startup load. This race is separate from the ODE model's
wrong answer; there is no evidence that it caused that completed task's drift.

Startup now reconciles saved history with task changes made while loading. New
drafts, changed models, streaming-message ownership and the current selection
survive. Explicit deselection is retained even when startup began with no tasks.
A newer authoritative task snapshot supersedes the pending load, and cancellation
or shutdown prevents late publication. Normal subsequent authoritative snapshots
keep their replacement behavior. This stays within the existing AppState and
SwiftUI/web workspace architecture.

The initial run passed 160 AppState tests. Independent review then found the
empty-baseline create-and-deselect edge case, which was fixed and covered before
the final run: 170 AppState/WebSnapshot tests passed, zero failures or skips, with
stable source hashes. Eight held-load regressions cover the startup race and its
selection, model, prompt, snapshot, streaming, cancellation and shutdown edges.
Version validation passed for 0.7.0 (246). The deterministic held-load tests prove
the race handling; live installation and UI checks are recorded separately.

Installed signed-test build246 matches source `60da065` and unchanged runtime15;
all eleven build, signing and source/resource checks passed. The live UI started
at “Connecting to runtime”. A new task and exact unsent test prompt were created
before history finished loading. After restoration, the prompt remained exact,
the new task stayed selected and Cerebras GPT-OSS120B remained selected. The test
text was cleared; Send was disabled and no request was dispatched. This validates
the observed startup overlap in addition to the deterministic held-load tests.
It does not requalify the unchanged browser/model behavior from build245. No
release, notarization or merge was performed.


## Build 247: offer browser actions only after binding

A build245 follow-up listed tabs and then attempted an old click before binding
the new turn. API and website inference now project the callable tool catalog
from the authenticated native turn's binding state. Before binding, recognized
native read, continue, click, fill, navigate, wait and close tools are omitted;
tabs, open and bind remain available. The next inference after binding restores
the registered dependent tools. The controller query captures no page and grants
no new authority; existing dispatch, approval and reference checks still apply.

Recognition uses original native schemas before refreshing constraints. Custom
or foreign declarations retain their existing treatment. Full original history
and raw arguments remain unchanged; current response decoding accepts only the
offered subset. Original wire identities remain stable, including numbered Chat
Completions aliases and Responses names. Corrective attempts retain the same
prepared catalog; only a new inference samples binding state again.

Core validates task/thread, turn, preparation, server generation, session epoch,
submission, Stop and cleanup state before and after the controller actor hop.
Both servers recheck their admitted context and provider revision. Missing or
retired state fails before provider work; empty catalogs require no availability
query. No retry, capture, history, reference, instruction or recovery limit grew.

Validation covered 543 distinct tests, all passing in their final recorded run,
with zero skips. The first 536-case run had three failures in new test setup or
assertions. A 106-case rerun fixed the invalid synthetic UUID cleanup fixture and
most naming assertions; one remaining assertion conflated Chat Completions and
Responses names. Its corrected rerun and all five bundled-engine tests passed
(six cases). Production sources stayed unchanged throughout these test-only
repairs, and source hashes were stable within each run. Original failures remain
in the evidence. The actual bundled-engine test checked two successive tasks,
three compactions, cold resume, exact current-user/history ordering, and changing
catalog subsets across eleven bounded loopback requests. Version validation
passed for 0.7.0 (247).

These checks establish host behavior under controlled binding states. They do
not establish that the model will keep the ODE task, select the correct message,
or copy identifiers exactly. Installed live qualification is recorded separately.


The signed build247 passed all eleven build/source/resource/signing checks and
was installed from `50b1364`. Its first fresh Cerebras GPT-OSS120B/medium UI trial
failed in 101 ms with `inference_context_required`, zero tool calls and zero
fixture HTTP requests. Further live trials stopped. The new callback passed the
API server's lowercase task UUID into Core's case-sensitive original-task maps;
new AgentTask IDs use uppercase UUID strings. The bundled tests all used
lowercase task IDs, missing the installed path. This regression is preserved and
must be fixed before qualifying the catalog change. No provider success is
claimed for build247.


## Build 248: preserve native task identity across API normalization

The availability callback now resolves the original task through the exact
registered thread mapping and requires UUID-value equality with the admitted
request. All preparation, reciprocal thread, active-turn, epoch, generation,
submission, Stop and cleanup checks continue to use the original native task key.
No dictionary scan, global ID rewrite or authority relaxation was introduced.

Two regression cases used uppercase alphabetic native task UUIDs and lowercase
admission UUIDs. Both failed against the unchanged build247 production code:
the actual engine sent zero provider requests and the direct Core query rejected.
After the narrow fix, all 183 targeted API/server/native/website and bundled-engine
tests passed with zero skips and stable source hashes. The exact same new tests
also check foreign UUID rejection and original native approval/cleanup identity.
The bundled case retains its two tasks, three compactions and cold resume.
Independent review found no identity or lifecycle-check relaxation. Version
validation passed for 0.7.0 (248). Live installation remains a separate check.


Installed build248 matches source `5ff0bde` and unchanged runtime15; all eleven
signed-build checks passed. The identical prompt that failed on247 completed on
a new app-created task in 2.253 seconds (three calls, no failures or POSTs), with
the observed change and exact filename. This demonstrates the native ID repair.
The same-chat and fresh sends took 9.187 and 8.778 seconds, producing exactly one
POST each with exact requested recipient, subject and body. They still needed
one and two rejected stale-reference recoveries; premature empty-body submits
produced validation feedback and no POST. The same-chat answer copied its fields
exactly and omitted the optional receipt. The fresh answer copied the current
receipt exactly but changed recipient/body typography. These were sequential
model choices, not evidence of concurrent native dispatch.

The real Outlook lookup took 21.944 seconds, eleven calls and one rejected stale
reference, with no compaction. The requested sender's header, recipient/date and
attachment shared the same inner message path, and the final 41-byte filename
matched exactly. It reused an older pre-search reference once, then recovered.
No real-mail send, forward, download or deletion was observed.

The ODE follow-up failed: after initially searching the current task, the model
returned to the previous sender and repeated a rejected fill. A navigation race
invalidated the first current Search reference; recovery returned a partial
current overview without any fill reference. The model reused the retired
reference without continuing or reading the Search field. Native recovery stopped
the attempt. No new fill authority was lost in that recovery output because none
was published. The goal remains active: current-task adherence and consumed-
reference selection still fail. Per-trial UI checks showed owned-tab cleanup and
empty composers; local fixture shutdown is recorded after remaining qualification.


## Build 249: retain exact current-user reminders on every inference

Build 248 retained the exact current request in native history, including after
compaction, but the ODE follow-up still returned to the previous task. The native
proof confirms chronology and bytes; it does not establish model attention. As
a controlled experiment, the API adapter now keeps its existing current-turn
user-role reminders even when that proof matches. Original history, tool receipts,
accepted-steer order and authority remain unchanged. The existing developer
instruction explicitly forbids treating reminders as a restart or replaying
completed or uncertain actions. Maintenance requests keep their final maintenance
instruction after the reminders, and a correction reuses the frozen request.

All 148 focused API/server/codec and actual bundled-engine tests passed, with
zero skips and stable source hashes. Both provider wire formats preserve the
complete original history prefix and exact whitespace, decomposed Unicode and
duplicate steer inputs. Tests retain the unchanged 2,000,000-byte projection
limit and fail closed when reminders make a request too large. The actual engine
checks two successive tasks, three compactions, cold resume, no accumulated wire
reminders and one canonical persisted human item per submission. Independent
review found no authority, lifecycle or correction-budget relaxation.

This is a salience experiment, not a demonstrated semantic repair. Added reminder
bytes can reach the existing payload limit sooner, and repeating the active
request may encourage model replay despite the explicit no-replay instruction.
Installed qualification must therefore check exact current-task answers, consumed
references and exactly one delivery per authorized synthetic send. No runtime,
reference, retry, capture, history or recovery limit changed. Live results follow
separately; the goal remains active.


Installed build249 matched source `ed44f8f`; all eleven signed-build checks passed.
The exact mailbox read took 2.175 seconds, three calls, no errors and no POSTs.
The same-chat send took 5.256 seconds and eight calls, recovering from one bind
attempt before current-turn inventory; the fresh send took 4.291 seconds and seven
calls without errors. Both produced exactly one POST with exact requested fields
and no compaction. The same-chat final changed the recipient and receipt hyphens;
the fresh final copied its receipt exactly and omitted the other fields. An audit
parser initially missed the plain-text bind failure; corrected reports correlate
typed native completion status and preserve the original reports unchanged.

The real attachment trial failed semantically after 29.867 seconds and six
successful tools. The model chose the personal Outlook entry point, reached a
public marketing page and refused at an observed actionable Sign in link. No
password or MFA requirement had been observed. Its follow-up failed in 2.388
seconds and two successful tools by searching public Google snippets instead of
the requested mailbox context. There was no compaction in either turn. These
results do not establish a task-continuity repair. Direct UI verification through
the previously working Office Outlook entry point selected the existing account
and reached its inbox without entering credentials or changing settings. That
separate probe is not a provider pass and changed the session state for later
trials. All five task-created tabs and the owned diagnostic tab were closed;
composers were empty and the browser pane was restored hidden. No real mail was
sent, forwarded, downloaded or deleted.

## Build 250: make API follow-up context explicit

The API checkpoint already preserves user authority and forbids restart/replay,
but its ordinary-inference wording lacked the website path's explicit instruction
to interpret follow-ups in conversation. Replace two existing sentences with a
shorter instruction to resolve follow-ups in the user's service/account/topic
unless changed and keep past actions historical. This is a wording experiment,
not evidence of missing user text or a guarantee of semantic model behavior. The
original history, active inputs, permissions, limits and correction behavior stay
unchanged. Authentication instructions already permit observed sign-in controls;
no security rule is weakened to address the model's unsupported refusal.


Build250 validation covered 149 distinct API/server/codec and bundled-engine
cases, all passing in their final recorded run with no skips. The initial run
passed 148 cases and failed one actual-engine continuation fixture because it
still expected the replaced sentence pair. Updating only that expected wording
preserved the no-replay, ordering, history and limit checks; all five actual-engine
cases then passed. Both runs had stable source hashes, and production code was
unchanged between them. Original failures are retained. Independent review
confirmed the complete reminder paragraph shrank from 432 to 429 UTF-8 bytes.
The new both-wire test verifies exact delivery for a same-service new-topic
follow-up and an explicit destination change; it does not prove model compliance.
Version validation passed for 0.7.0 (250). Installed qualification follows.


Installed build250 matched source `efb8125` and unchanged runtime15; all eleven
signed-build checks passed. The same local mailbox read took 2.319 seconds with
three calls and no errors. Same-chat and fresh sends took 4.388 and 3.850 seconds,
each with six calls, no errors and exactly one POST carrying the requested fields.
The same-chat final omitted fields/receipt rather than misquoting them; the fresh
final copied its receipt and subject but changed recipient/body typography.
Neither user prompt required a verbatim echo of delivered fields.

The real attachment lookup did not finish: 27.138 seconds, 33 calls (32 completed,
one rejected), two compactions and the unchanged completed-call guard. Repeated
clicks reopened a collapsed sender row; the last click reused a consumed reference.
The ODE follow-up reached a genuine announcement in 18.274 seconds with 21 calls,
zero tool failures and two compactions. Its final answer nevertheless combined
attachments from separate individual messages, invented a primary attachment,
changed filename punctuation and claimed an exhaustive negative from partial
observations. Tool completion is not semantic task success.

All five owned test tabs were closed and composers were empty. The local mailbox
server was stopped and its listener verified closed. No explicit real-mail send,
forward, download or deletion was observed; opening messages may affect read state.
The earlier direct account-session probe changed sign-in state before these trials,
so these runs do not support a causal speed or semantic improvement claim.

## Build 251: clean failed-turn commands and revert unqualified prompt experiments

The separate build249 read-only diagnostic stopped at the existing compaction
receipt-fit guard after 41.437 seconds and 25 calls, without a final answer. Its
broad shell searches produced large receipts and left one recursive grep pipeline
running after the app showed Waiting. Root verified the exact owned process group,
terminated only that group and verified it exited. This is distinct from normal
no-match grep results or an unavailable CLI; none establishes a settings diagnosis.

The cause was in terminal-status handling: native errors and failed/interrupted
turn completions waited for browser/inference cleanup but did not terminate their
surviving unified_exec sessions. Explicit Stop and shutdown already had bounded,
identity-checked native session cleanup. Terminal handling now uses that existing
list/terminate/re-list path for command items owned by the failed turn, before
publishing Waiting. Successful earlier-turn background sessions survive. Stop
shares an overlapping cleanup result, shutdown awaits pending cleanup, and failure
remains visible and retryable without inventing a process exit or command success.
No OS-wide process discovery, command replay, runtime rebuild or cap increase was
introduced.

A new regression failed first against unchanged production, then the first green
run passed 72 cases with zero failures or skips and stable source hashes. Mocked
fixtures cover native error, failed/interrupted completion, previous-turn session
preservation, unconfirmed cleanup retry and Stop overlap. The real bundled engine
started two isolated unified_exec children, completed the first turn, then injected
a provider failure on the second. Its failed child was absent before Waiting while
the earlier successful child remained alive; exact native identity and clean
shutdown were verified. This is actual-engine evidence, not yet installed-UI proof.

The API reminder and wording experiments from builds249/250 are reverted together
to the build248 behavior. Their tests proved delivery but their installed trials
did not establish a semantic improvement, and basic synthetic delivery already
worked on248. The revert does not claim that those experiments caused the errors
or that reverting repairs model reasoning. Their commits and failed results remain
in history. Native command cleanup and earlier browser/identity fixes are retained.


After reverting the experiments, 128 tests passed with no failures or skips and
stable source hashes, including all six actual-engine cases. Review then found a
public manual-compaction entry point could supersede the submission while command
cleanup was pending. A held-inventory regression reproduced that race against
unchanged production; compact now uses the same command-cleanup/shutdown admission
guard as submit. The final source cohort is recorded separately after that guard.


Final source validation after that guard passed 129 tests with zero failures or
skips and stable source hashes: 56 API-server, six actual-engine, 40 context,
two shutdown and 25 streaming tests. Both red reproductions and intermediate green
runs are preserved. This cohort covers the final rollback plus cleanup source.
Installed build validation follows separately.


Installed signed-test build251 matches `80c5933` and unchanged runtime15; all
11 build, signing and exact source/resource checks passed. A bounded loopback
provider drove two real UI turns with four scripted inference requests. The first
left a finite background child running; the second started a shell pipeline with
two children, then returned HTTP429. When Waiting was observed, the failed shell
and both children were gone, the earlier child remained alive, and the UI reported
one confirmed failed-turn cleanup. Normal Quit then disposed the earlier child.
All exact test PIDs and the loopback listener were absent afterward, and both
temporary provider configurations were removed through the UI.

The first fixture attempt rejected the native environment-context user message
before issuing any command. The human prompt was byte-exact. A new fixture instance
accepted that separately observed envelope by exact hash and byte length; the
failed instance and its evidence were preserved. No real provider was called.
The installed observation proves absence when Waiting was inspected; the direct
actual-engine test establishes ordering before status publication.

The live test also found a presentation defect: the later failure relabeled the
still-running earlier successful command as Failed. Process ownership was correct,
but task-wide transcript retirement was not. This remains open for build252;
source251 does not claim the row-labeling issue is repaired. Model adherence,
message association, literal copying and useful diagnostics also remain unresolved.


## Build 252: current API action choices and turn-scoped command presentation

The native browser registry already knew when input had consumed its action
references, but the API model still saw those old tokens in original history
without a current callable constraint. This allowed observed cases to reuse a
consumed click or fill reference and spend another native recovery call. API
inference now obtains one authenticated native snapshot containing binding state
and the currently retained, unexpired click/fill refs. Exactly recognized native
mutation schemas expose only those values as enum choices; an empty kind omits
that mutation tool for the inference. Original historical definitions, arguments,
results and wire identities stay unchanged.

The registry query is read-only and performs no browser capture. It preserves
valid earlier continuation-page refs and freshly corroborated refs with their
original expiry and FIFO age. It excludes consumed, retired, expired and foreign
publications. Core retains original task UUID identity and its turn, lease,
preparation, generation, submission, Stop and cleanup checks before and after the
controller hop. Custom, narrowed, foreign and partly modified dual-schema tools
do not acquire native constraints. A correction reuses the frozen snapshot; a
new inference samples again. Website inference retains its availability-only
contract, and native dispatch still validates the actual target immediately
before input.

This is a constraint on known-current choices, not a fresh DOM guarantee. A page
can change after inference or the first action in a multi-call reply can consume
the second action's ref. Native validation still rejects those cases. Rejection
of an already-retired choice moves to the existing API response validator, using
the same single correction allowance where supported, without inventing native
recovery or replay. Wrong but currently valid targets, message association and
literal answer copying are separate model behaviors. No limit grew; final encoded
requests including the enums must fit the existing two-million-byte bound.

The installed251 trial also showed task-wide command presentation marking a
successful prior turn's live background process Failed. Transcript settlement
now selects exact item IDs belonging to the terminal turn. Earlier running rows
survive and can later settle from their own actual completion. Explicit Stop,
disconnect and shutdown retain their task-wide presentation scope. A regression
covers native error followed by failed completion and failed completion alone,
then the earlier command's later successful exit on its original row.


The coordinated final-source suite passed all 659 cases, with no failures or
skips and stable source hashes. It covers both API wires, native registry/controller
and Core fences, command streaming/context/shutdown, website compatibility, and
six actual bundled-engine cases. The extended lifecycle fixture exercises nine
ordinary requests, five real compactions and a cold-resume request, verifying
current enums, consumed references, stable historical arguments/aliases and
unbound omission. The earlier251 failed-process test remains unchanged.

Measured final encoded request overhead at 60 native-shaped click refs plus
60 fill refs is 5,478 bytes on both wires: Chat Completions 3,511 to 8,989 bytes;
Responses 2,941 to 8,419 bytes for the controlled identical payload/catalog.
The worst-case 128-byte token shapes and exact two-million-byte/+1 boundary also
passed. These are payload measurements, not live model latency or semantic success.
No provider capture was rearmed. Installed qualification is recorded separately.

### Installed 252 command and mailbox controls

The signed build from `8ea2e01710d9c516e1d4faacabb70d9b54c8f1b5` passed all
11 build checks. The installed executable SHA-256 was
`cfc283dfd39c0f63c8c857349206ad2e45805f5e32464c0f3bad0632cf070458`.
The deterministic loopback command control completed four provider requests and
two native commands, with one start per child and no replay or API correction.
The prior turn completed in 1.350 seconds; the second reached the intentional
HTTP 429 in 1.307 seconds. The failed shell and both pipeline children were first
sampled absent 54.488 ms after the 429, while the earlier child remained alive.
When Waiting was inspected 4.582 seconds after that sample, the UI reported one
session cleaned and correctly kept the earlier row Running while the failed row
was Failed. Normal Quit disposed the earlier child; all exact PIDs and the
listener were absent afterward and the synthetic provider was removed. This
installed observation proves absence when Waiting was inspected, not its exact
publication instant. The earlier fixture-admission and build 251 presentation
failures remain preserved.

The three unchanged mailbox prompts ran on Cerebras `gpt-oss-120b`, medium, using
the same loopback origin with a fresh empty fixture store:

| Case | Duration | Native calls | Native errors | API corrections | Compactions | Observed result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Read | 2.266 s | 3 | 0 | 0 | 0 | Correct exam change and exact attachment filename; no POST |
| Same-chat send | 5.208 s | 7 | 0 | 0 | 0 | One exact POST and current receipt; final recipient copied with U+2011 instead of ASCII hyphen |
| Fresh send | 4.467 s | 6 | 0 | 0 | 0 | One exact POST; requested fields and current receipt copied exactly |

Both sends filled the three requested fields before pressing Send once. Every
input reference appeared in the immediately preceding published observation.
Delivery passed in 2/2 send controls; strict quoted-recipient copying passed in
1/2. API correction journals were checked separately, so zero native errors does
not conceal a corrected enum rejection in these samples. Each turn closed one
task-created tab, preserved user tabs and left an empty composer with no Stop
control. The fixture listener was then stopped.

Builds 248–250 also delivered both messages. Their same/fresh send native error
counts were 1/2, 1/0 and 0/0, compared with 0/0 here. These single samples are not
a latency benchmark or a causal reliability result: the earlier fixture retained
prior deliveries, and the reminder experiments in 249/250 were later reverted.
The same-chat literal-copy failure remains. Real mailbox and diagnostics
qualification are separate from these controls.

### Real Outlook 252: authentication claims remain unsupported

The unchanged attachment request used Cerebras `gpt-oss-120b`, medium, and ended
after 65.496 seconds with 14 native calls, no native errors, no API corrections
and no compaction. It did not reach message or attachment evidence and returned
no filename. The model followed a published Sign in link and then pressed the
published matching account selector. The account click dispatched once. Its
post-input observation arrived 48 ms later, still showing the account chooser;
it reported `result_verified:false` and directed waiting or reading again without
replaying the input. No password or MFA challenge was observed. The model took
no further observation and finalized about 1.3 seconds later, incorrectly treating
credentials as an established prerequisite. Current account-selection guidance
was present in the canonical developer instructions and click description.

The unchanged course-announcement follow-up completed in 0.725 seconds with
zero tools, errors or API corrections, repeating the unsupported authentication
claim. A separate maintenance compaction immediately before that user turn
preserved the original request and summarized the prior refusal as an access
block. The new follow-up text then entered history exactly. This is a failed
follow-up with inherited unsupported context; it is not evidence that the new
human request was lost. Neither turn performed a mail send, forward, deletion,
download or credential entry. Attachment association, exact filename copying
and announcement coverage were not established. UI cleanup closed the one
task-created tab, preserved user tabs and left the composer empty.

A separate controlled CUA diagnostic subsequently selected the matching account
and observed Outlook loading at 0.890 seconds and the mailbox at 25.449 seconds,
without a password/MFA prompt or credential entry. It opened no messages and
closed both diagnostic tabs. That different session and input route demonstrate
an available credential-free flow, not a model pass or proof that latency caused
the refusal. The observation times are sampling bounds, and the diagnostic may
have changed shared sign-in state. No wait, retry or permission change is
justified by this comparison alone. The real-mailbox acceptance failure remains
open despite the qualified host changes and synthetic delivery controls.


### Diagnostics 252: historical assistant text is not settings evidence

The unchanged read-only diagnostics request completed on Cerebras `gpt-oss-120b`,
medium, in 47.436 seconds with 29 calls (28 shell commands and one browser
inventory), one compaction, no browser errors and no API correction journals.
Shell receipts showed 18 exit-zero results, eight exit-one results and two
running sessions. Two exit-one results were normal empty grep searches; none
was a command-not-found exit 127. No mutating command was executed.

The answer nevertheless asserted an MDM `allowLocalBrowser` cause and advised
an unsupported `defaults write` remedy. The key appeared only in two repeated
recursive searches of saved session history, which quoted a prior assistant
answer. Current defaults, profile and plist outputs did not establish that key
or cause, and no official documentation was retrieved. The task therefore
failed its supported-settings requirement despite native completion; this is
not a claim that no such setting can exist. Private historical text is omitted.

The two broad filesystem searches remained alive after successful completion,
which preserves background commands. Normal UI Quit then disposed both exact
shell/find/head process groups and the native engine; all seven recorded PIDs
were absent afterward, with no manual signals. This is separate from the
failed-turn cleanup control. The app was reopened idle. Finite call ordinals,
correction counts and before/after process receipts are preserved in the private
`audits252/diagnostics-review` and cleanup artifacts. No runtime fix or broader
reliability claim follows from this failed diagnostic sample.

### Document-change wait and summary attribution (candidate 253)

A fresh installed build 252 control used the same plain attachment prompt and remote
Cerebras `gpt-oss-120b`, medium, against identical account pickers on one loopback
origin. The immediate redirect selected the matching account, but the model
returned the ODE message's attachment instead of the requested evidence packet.
The delayed case scheduled navigation 2.5 seconds after one account click. Its
`browser_wait(timeout_ms=10000)` returned `matched:true` in 9ms on the old readable
picker. After another unchanged read, two invalid wait-argument responses ended
the turn 2.288 seconds after account selection, before navigation started. The
finite journal records a schema mismatch, not the rejected argument values.
The same-chat follow-up recovered through an observed Inbox control and read the
correct ODE announcement. No mail POSTs occurred; both fixture servers and owned
tabs were cleaned up. These controls isolate readiness from future navigation;
they do not establish that every real account selector follows the same path.

`browser_wait(after_snapshot=...)` now takes the exact latest published page as
its native baseline. It waits on navigation events for document/URL change and
readiness under one existing deadline. It captures no page, refreshes no action
reference, replays no input, and does not claim task success. Expired, foreign or
superseded snapshots reject; changed observations retire old references; Stop,
release and shutdown cancel the owned wait, including borrowed tabs. Saved
native catalogs gain the optional mode; custom/narrowed/foreign contracts remain
unchanged. The post-click receipt suggests this concrete predicate. Existing
text/no-argument readiness and all call, byte, reference and timeout bounds stay
unchanged.

Runtime16 also replaces the known native compaction preamble on the external
provider wire with an explicit historical-assistant-claims label. The old
preamble claimed tool state was available even when pre-turn compaction retained
no receipts. The role was already assistant: this corrects source attribution,
not a role escalation. Canonical history, generated UTF-8 body, genuine receipts,
IDs and ordering remain unchanged. It saves 270 bytes for ordinary native
summaries and is not a semantic truth validator. In particular, it cannot by
itself fix a model mistaking an old assistant answer inside shell-search output
for official settings documentation.

Validation before installation: seven isolated actual-source Rust projection
checks, 29 Bun identity/version/runtime-source checks, and 625 distinct Swift
cases have passing latest results with no skips. The initial 580-case run had
579 passes and one stale pre-existing Chrome-catalog assertion. After correcting
that assertion and strengthening the bundled summary check to UTF-8 bytes,
53 targeted cases passed; production sources did not change between runs. The
suite includes 15 new wait/catalog/codec cases, real isolated WebKit navigation,
and actual bundled-engine compaction/cold-resume wire checks. Preserved private
receipts: `account253-baseline-review`, `native-summary253`,
`swift253-document-wait`, `swift253-final-contracts` and
`swift253-qualified-union`. Live semantic acceptance remains pending at this
source checkpoint; the prior failed runs are retained.

### Installed 253: navigation waits qualify; attachment selection still fails

Signed build 253, source `0549b71`, was installed and verified with runtime
`mactopus-16`. The immediate and delayed account-picker controls reused the exact
baseline prompts, fixture and loopback origin on Cerebras `gpt-oss-120b`, medium.
Each case started a fresh fixture instance. Neither attachment run compacted.

| Case | Attachment duration / native calls | Native errors | API corrections | Requested attachment |
| --- | ---: | ---: | ---: | --- |
| Immediate navigation | 9.251 s / 10 | 1 stale cursor | 0 | Wrong-topic attachment returned |
| Navigation delayed 2.5 s | 6.900 s / 7 | 0 | 1 corrected schema rejection | Wrong-topic attachment returned |

Both `after_snapshot` waits matched the native transition without replaying
input. The immediate wait returned in 9 ms after navigation was already ready.
The delayed wait remained pending for 2.107 seconds: it began 417 ms after account
selection and returned about 11 ms after the mailbox DOM-ready event. The
selection-to-mailbox-response interval was 2.507 seconds. No model/tool cycle ran
inside that pending wait. Both results reported `changed`, `navigation_ready`
and `matched` true, with `no_replay:true` and `result_verified:false`. These are
two qualified predicate cases, not a general latency or reliability benchmark.

Both attachment answers substituted a real, exactly copied course-announcement
filename for the requested evidence-packet attachment. In the immediate case,
the evidence-topic label was visible but its actionable link was on the next
page; the model selected the other topic and later reused a cursor invalidated
by input and a fresh read. Native admission rejected that cursor without a read
or input. In the delayed case, the correct evidence-topic link was explicitly
actionable on the same page, yet the model again selected the other topic. The
single API correction is recorded separately from native errors; its finite
schema rejection does not identify the rejected field or argument values.
Neither attachment task passed, and the samples establish no host rewrite of
topic association or semantic cure from the new wait or summary attribution.

The two same-chat presence follow-ups completed in 0.747 and 0.621 seconds with
zero tools, errors, corrections or compactions. Their answers were grounded in
the previously observed course announcement and did not claim a fresh search,
repeat the filename or provide new coverage evidence. One task-created tab was
closed after each attachment turn; the follow-ups created none. UI checks
confirmed preserved user tabs, empty composers and no Stop control. Both exact
fixture processes were identity-checked, stopped and confirmed absent. No mail
POST occurred in either case.

The private `account253-post-review` and per-case directories preserve the
canonical indexes, semantic reviews, correction journals and cleanup receipts,
including the pagination-index correction. The wait mechanism passed these two
controls; requested attachment selection and broader acceptance remain open.


### Installed 253: real-task attribution and search limits

The unchanged real Outlook attachment task and its natural ODE follow-up ran on
Cerebras `gpt-oss-120b`, medium. Shared sign-in state had been refreshed during a
prior human diagnostic, so this was not a cold sign-in qualification.

| Task | Duration / native calls | Native errors | API corrections | Compactions | Outcome |
| --- | ---: | ---: | ---: | ---: | --- |
| Requested-sender attachment | 33.891 s / 22 | 1 stale snapshot | 0 | 1 | Filename observed; message attribution unqualified |
| ODE announcement follow-up | 29.531 s / 17 | 0 | 0 | 2 | Unsupported absence claim |
| Read-only settings diagnostic | 0.198 s / 0 | 0 | 0 | 0 | Provider transport failure before tools |

The attachment answer copied a published filename exactly. Its evidence was a
filtered result-card row, however, while the requested sender's opened-message
headings belonged to different records. A later sender filter created another
capture; matching record suffixes across captures do not establish ownership by
one individual message. Attribution remains unqualified, not conclusively
assigned to a wrong owner. The selected conversation option and resulting
heading agree, with matching bounded dispatch-label prefixes; no native target
substitution was demonstrated. The failed `after_snapshot` wait reused a page
from the earlier tab after a second open and several reads. Rejecting that stale
baseline was expected, not a failure of the delayed-navigation predicate.

The ODE follow-up filled and clicked distinct observed Search controls for two
queries. It exposed result options without establishing complete result coverage.
After filling its third query, it clicked **Search filters**, not **Search**; the
final read showed the filter form. No explicit site no-results message was
observed. Reading-pane placeholders such as “Nothing is selected” and a Message
list container do not establish search absence. The trace also does not establish
when asynchronous search results settled. Current human text and the latest
complete observation survived all three real-task compactions byte-for-byte;
these failures do not demonstrate loss of that evidence during compaction.

No send, forward, delete, attachment download/open, or shell mutation was observed
in the Outlook trials. UI checks confirmed cleanup of two task-created tabs for
the attachment turn and one for the follow-up, preserved user tabs, empty composers
and no Stop control. The diagnostic attempt produced no tool calls, commands or
model answer. Its existing finite log records `request_transport`, `unavailable`
and `retryable:false`; it contains no HTTP status. No retry was performed, and
this attempt supplies no semantic diagnostic qualification.

Private, local evidence: [attachment review](</Users/ahmed/Documents/Codex/2026-10-05/testing-testing-okay-the-mic-works/work/action-reliability-20261023/audits253/outlook-review.json>),
[ODE review](</Users/ahmed/Documents/Codex/2026-10-05/testing-testing-okay-the-mic-works/work/action-reliability-20261023/audits253/ode-review.json>),
and [diagnostic failure review](</Users/ahmed/Documents/Codex/2026-10-05/testing-testing-okay-the-mic-works/work/action-reliability-20261023/audits253/diagnostics-review.json>).
The adjacent indexes and correction journals retain finite counts, ordinals,
hashes and match booleans; these reports do not reproduce private addresses,
message bodies or filename literals. These samples do not qualify overall task
reliability.

### Build 254 source checkpoint: source grounding and finite transport errors

Four existing instruction passages now distinguish quoted claims from current
configuration evidence, preserve that distinction in compaction notes, attribute
attachment names to the requested sender and topic within one message, and
check every requested outcome against its source and all user constraints.
The replacements remove 59 instruction bytes in total. Existing tools,
permissions, history, user input, reference lifetimes and all execution/retry,
receipt and instruction limits remain unchanged. These are interpretation
guidelines, not a semantic verifier or a claim that model behavior is repaired.

The original diagnostic retest and a separate frozen synthetic provenance
baseline both failed at request transport before any tool call. The latter
terminated in 255 ms with its project unchanged; neither its true configuration
nor its conflicting assistant-attributed log was read. It supplies no semantic
baseline. The two prior errors cannot be retrospectively classified beyond
`unavailable`: existing finite logs contained no HTTP status or URL error code.

The HTTP client now distinguishes observed HTTP 402/5xx failures and known
offline, DNS, connection, connection-loss and TLS/certificate errors. Unknown
errors retain the generic fallback. Existing error envelopes and finite stage
logs carry the new codes without request/response contents, URLs, credentials,
or arbitrary error metadata. Local HTTP 400 and nonretryable behavior are
preserved; provider failures do not introduce an engine retry or replay.

Validation: 287 targeted instruction/projection/history tests passed, followed
by 73 transport/server/runtime-contract/settings tests after the error
classification change. Both runs had stable source hashes and no failures or
skips. The latter includes 17 injected URLSession/error cases and 12 loopback
HTTP statuses, checking one request, private-data exclusion, unknown fallback
and nonretryable projection. Counts overlap and must not be added as distinct
tests. Signed installation and planned candidate trials remain pending at this
source checkpoint. Private receipts: `swift254-grounding`,
`swift254-transport` and `diagnostic254-fixture/baseline253-review`.

### Installed 254: explicit provider-account blocker

Signed, non-notarized Computa 0.7.0 (254), source `dd68b98`, passed all eleven
build/source/identity/signature/resource checks and was installed with unchanged
runtime `mactopus-16`. The running executable and every resource matched the
validated build. Normal Quit first disposed the idle build253 app and engine;
the new app restored its history and connected to the runtime.

The single planned synthetic diagnostic candidate used the same exact prompt
and Cerebras GPT-OSS120b medium selection as its preserved baseline. It stopped
in 273 ms with the newly explicit `billing_required` error: the provider returned
HTTP 402. No tool, corrective request, compaction or final answer occurred. All
five project files retained their hashes and modes with no additions. Neither
trial reached the configuration, documentation or assistant-attributed claim,
so no semantic before/after comparison is established. The current HTTP status
is verified; its underlying account/billing cause has not been inspected, and
the older generic failures cannot retrospectively be called HTTP 402.

Further Cerebras live qualification is held pending restored API account
access. The two planned browser candidates remain unstarted: no model prompts
were submitted and no fixture servers were launched. The app is idle with an
empty composer and no Stop control. Goal completion and general web-task
reliability are not claimed. Private receipts: `installed254-live`,
`installed254-ui-blocker`, `diagnostic254-fixture/candidate254-review` and the
two `account254-*/blocked-before-start` records.

To preserve build capacity, cleanup removed only eight generated backup app
bundles, builds241–248, after exact path, identity and running-process checks.
It recovered approximately 2.325 GiB; installed253 (subsequently backed up during
installation), backups240 and249–252, source and all test evidence were preserved.
The exact inventory and deletion receipt are in private `backup-cleanup254/`.


### ChatGPT startup failure and build 255 diagnostics

The requested ChatGPT Instant continuation used the same read-only synthetic
diagnostic prompt on installed build 254. Its native turn failed in 130 ms, before any
tool call, website Send or verified provider response. The transaction journal
records `start_requested` then `internal_error`; native logs show a cold browser
start immediately before the failure. The generic high-demand message is not
evidence of ChatGPT overload. Startup ownership and website cleanup remain
unconfirmed. Project files are unchanged. Private evidence:
`chatgpt254/diagnostic-review.json`.

Two concrete local error families were missing from the website error boundary:
ChatGPT cookie-profile preparation and native browser-session failures. Build 255
projects those types into closed HTTP 400/nonretryable diagnostics and preserves
only exact canonical envelopes in failure history. It does not infer tab closure,
retry a prompt, relax ownership, or change the shared action instructions.
Cookie preparation now emits one bounded failure diagnostic with phase, reason,
counts and an optional 11-bit attribute mismatch mask. Cookie names, values,
identities, URLs and arbitrary error descriptions are excluded; selection,
readback equality, original profile contents and all limits are unchanged.

This checkpoint improves failure attribution; the concrete live preparation
failure and end-to-end ChatGPT task outcomes still require installed validation.
Cerebras remains separately blocked by its observed HTTP 402.

Validation: the initial targeted run passed 154 of 155 tests, including the
actual bundled-engine startup and cold-restoration regression. One new synthetic
cookie fixture exceeded Foundation's constructor limit before reaching the
subject. After a test-only correction, all 42 cookie tests passed; production
sources were unchanged. The 155 distinct tests have passing latest results, not
a full rerun after the fixture correction. Independent production review found
no blocker. Private receipts: `swift255-startup`, `swift255-cookie-refinement`
and `swift255-latest-results`.

### Build 256: scope cookie identity checks to the destination

Installed build 255 localized the prewarm failure to `source_selection`,
`invalid_source`, `duplicate_identity`: 354 source cookies, no selected cookies
and no destination writes. No prompt was submitted in this diagnostic. The
selector checked identity ambiguity across every website before filtering for
ChatGPT, although only ChatGPT cookies can enter the isolated destination.

Build 256 makes duplicate identities from unrelated sites nonfatal and records
only their bounded count. ChatGPT duplicates, including expired and excluded
conversation cookies, still fail before expiry filtering. All global field/count/
byte limits, malformed-field checks, original-object copying, source immutability
and exact destination readback remain unchanged. This fixes a concrete scope
defect; causal attribution to the live profile requires a positive ignored-
duplicate count followed by separately verified destination seeding.

All 45 cookie tests passed with unchanged sources, including three new scoped
regressions and the existing failure/cancellation/readback coverage. Independent
review found no blocker. Private receipt: `swift256-cookie-scope-result.json`.
ChatGPT task qualification and live startup verification remain pending at this
source checkpoint. Cerebras HTTP 402 remains a separate account-access blocker.

### Installed 256: cookie preparation repaired; model selection still blocked

Signed, non-notarized Computa 0.7.0 (256), source `57c8291`, passed all eleven
build/identity/signature/resource checks after the 45 passing cookie tests.
The installed executable matched `3f1e2065a228…`; runtime `mactopus-16` was
unchanged. These checks do not establish a successful website task.

The preserved build255 diagnostic recorded `duplicate_identity` among 354
source cookies, before destination writes. Installed256 observed the same source
count, ignored one out-of-scope duplicate, and selected 19 of 261 eligible
cookies after excluding 242 conversation cookies. The first inference separately
recorded `destinationVerified=true` and `sourceMutations=0`. This establishes
successful scoped selection and exact destination verification for this run;
it does not qualify model selection or a generated response.

The unchanged read-only synthetic diagnostic then failed in 685 ms. Its journal
advanced through `start_requested` and an owned `started` session, then recorded
`browser_model_error` before submission, response or tools. A matching saved
schema-2 cleanup receipt reported `closed/not_created`. All five fixture files,
modes and the file set remained unchanged. Neither current configuration nor
the false assistant-attributed log was read, so semantic acceptance was not
exercised.

The failed inference's bounded picker diagnostic shows an unrecognized closed
header and no opened model menu; it does not retain that header's exact text.
A separate ordinary-tab inspection showed the closed text `Thinking effort`,
then `Instant, 1 of 5` and checked `GPT-6` when opened. That inspection submitted
no prompt, changed no selection and closed its owned tab. It supports the next
adapter investigation, but does not prove the earlier inference had identical
text or that a repair is qualified. Browser/send trials remain unstarted;
Cerebras's observed HTTP 402 remains separate. Private evidence:
`chatgpt255/startup-diagnostic-last20m.json`,
`chatgpt256/startup-and-first-turn-logs.json`, `diagnostic-review.json`,
`first-turn-model-diagnostics.json` and `normal-chat-picker-inspection.json`.

### Build 257: verify Chat power behind generic picker chrome

The adapter now recognizes the exact generic closed `Thinking effort` label as
a reason to inspect the associated picker, never as evidence of a power or
family. It observes the real Power ordinal, verifies the checked newest plain
GPT family, closes and reopens once to recheck Power, and rejects a reset or
ambiguous result without repairing or replaying selection. The final observed
controls join the existing negative mutation history. Remounts require a fresh
full proof; ownership, input boundaries, deadlines and selection limits remain
unchanged. A picker that only reopens the family panel remains unverified.

A second normal-browser UI inspection independently observed the supported flow:
Power → Select model → Escape → reopen returns to Power, still Instant with
GPT-6 checked. No model selection or prompt was submitted; both task-created
inspection tabs were closed. This presentation evidence does not qualify an
owned model inference. The single earlier Refresh models action targets all
providers; no further global refresh was used, and other-provider live task
qualification remains held.

Validation: all 694 adapter/preset tests passed. The initial focused WebKit run
passed six of eight cases; two new fixtures had incorrect initial-state and
terminal-line-break expectations. After test-only corrections, all eight cases
passed, including selection, single insertion/Send and response proof for both
Instant and Medium, post-family power-reset rejection, unknown headers, drift,
input boundaries and deferred reads. Production/JS sources were unchanged
between runs. Independent review is clean. Private receipts: `bun257-model-
adapters-summary.json`, `swift257-generic-header-result.json` and
`swift257-generic-header-refined-result.json`. Installed qualification is pending
at this source checkpoint.

To preserve build capacity, two redundant generated app bundles (254 and 255)
were removed only after their executable, resources and signatures matched
retained backup copies. Source, receipts, backups and installed256 were kept;
623,872,972 logical bytes were removed. Receipt: `duplicate-build-output-
cleanup257.json`.
