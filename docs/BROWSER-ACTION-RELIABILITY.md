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
`c1d9a916ec665601a811b42aee956b82cdebb8cf486489f39919d235a887ef8f`;
binary SHA-256 is
`fb02b8498b2b0359829923fce055ccc5d6cde9979c0acdd28e2c81d4db9edcab`.
Validation receipts are retained under the task's
`work/action-reliability-20261023/` evidence directory.

Unsuccessful attempts remain recorded: a Rust test incorrectly assumed small
receipts triggered ledger packing; the first Swift compile used a nonexistent
trace-loader method; the next Swift run had stale wording/null assertions and
overlapped runtime signing. The new bundled fixture initially used a symlinked
`/var` path, correctly rejected by the naming store before provider dispatch;
using the canonical temporary directory fixed that fixture without weakening
the store. Final tests supersede these attempts; the initial logs remain.

Installation and live model acceptance are still pending at this checkpoint.
Build 239's account-picker, ODE follow-up and same-chat send failures are not
claimed fixed by source tests. The split removes a known invalid-argument choice;
live evidence must establish whether it improves task completion.
