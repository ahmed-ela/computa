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
  navigation in one captured selection. It keeps the existing 18-row and
  6,000-byte row budget, exact field exposures, and immutable continuation.
  A long sidebar cannot by itself hide all document text; a heading does not
  substitute for the body. Selection uses observed structure, never success
  keywords. This is a bounded sample, not complete document coverage or proof
  that an action succeeded. Additional evidence may still require a read.
- Successful click/fill tool outputs begin with a separate compact dispatch
  receipt. It preserves the operation and the control label through item-wise
  history truncation; snapshot IDs and indices alone cannot explain an older
  action. The serialized receipt fits 128 UTF-8 bytes, including JSON escaping,
  and copies only a label span already exposed by the validated input snapshot.
  A partial flag identifies clipped or unavailable labels. The full post-input
  observation remains the second item. Failed dispatches have no such receipt,
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
- Each read replaces the reference menu. A token survives only when that read
  explicitly republishes the same native node with identical field exposures
  and action semantics in the same binding and committed document/generation/URL.
  Changed or omitted rows expire; admitted input consumes all current refs.
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
