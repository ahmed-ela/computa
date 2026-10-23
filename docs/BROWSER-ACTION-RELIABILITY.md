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
