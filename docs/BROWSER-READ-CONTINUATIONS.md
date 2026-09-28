# Browser read continuation and evidence contract

`computer_v2_continue({"cursor": "<observed next_cursor>"})` is the preferred
continuation operation. The runtime, not model history, remembers whether the
cursor belongs to a Chrome inventory or a semantic page/native read. Legacy
`computer_v2_tabs(cursor: ...)` and `computer_v2_snapshot(cursor: ...)` remain
available, but reject cursors from the wrong source.

## New-thread interface

New model threads receive the following tools instead of the legacy snapshot,
AX action, follow-link, and set-text choices. Resumed legacy threads retain their
original definitions and validation; the aliases use the same execution,
approval, freshness, and verification paths after host resolution.

| Tool | Arguments | Purpose |
| --- | --- | --- |
| `computer_v2_read_page` | `view?`, `query?` | Obtain a fresh observation of the bound target. |
| `computer_v2_read_region` | `region_ref`, `view?`, `query?` | Read beneath an exposed region or readable result element. |
| `computer_v2_continue` | `cursor` | Continue the exact observed inventory or read selection. |
| `computer_v2_press` | `action_ref`, `postcondition?` | Propose the exact supported action bound to that reference. |
| `computer_v2_follow` | `link_ref` | Follow an eligible observed browser link. |
| `computer_v2_fill` | `field_ref`, `text` | Set an observed editable field without focus or submission. |

Fresh reads accept neither a cursor nor a reference; region reads require their
reference and accept no cursor. Continuation accepts only its observed cursor.

Inventory, binding, status, application, capture, and policy-gated foreground
tools retain their existing roles. `computer_v2_verify` remains available for
bounded read-only recovery of an existing operation. These tool names do not
grant foreground permission or bypass target-specific checks.

Published semantic rows are grouped into `CONTROLS` and `READABLE CONTEXT`,
omitting an empty group. Copy the opaque token for the intended operation; do not
construct a token, index, or native action name. A row can offer `link_ref`,
`field_ref`, and one or more action references. Each action reference binds one
exact supported action, so `press` can also represent a native increment or
other observed action. Native links use their observed action reference;
`follow` is browser-only. A `region_ref` is a read/result address, not a press
target or proof that the region qualifies for a postcondition.

References belong to the active turn, exact target binding and generation,
and currently published snapshot. Each new published semantic observation,
including a continuation or returned action observation, replaces the previous
menu. Only rows actually
published receive references; hidden source nodes and verification polling reads
cannot supply them. Resolution checks the stored reference type and current
scope before canonical legacy validation. Failed publication grants no new
references. Checkpoints and compacted text cannot restore them.

For `press`, browser non-link actions still require a predeclared postcondition;
eligible native controls retain their existing implicit plans. Postcondition
`region_ref` replaces the legacy result `element_index`; native `detail_ref`
copies the `region_ref` of a separate observed detail pane and replaces
`detail_element_index`. The existing `kind` and `expected` rules remain:
`region_changed` has a region but no expected text; `dialog_opened` has neither;
`value` and `region_text` require a region and exact expected value/text;
native `selection` expects `"true"` with an optional region. Browser
`detail_view` uses the observed heading; native `detail_view` requires the
separate detail reference and expected text. `document_url` uses the exact
observed destination. Only `value` permits an empty expected string. Schema
validity and a resolvable reference do not establish action eligibility or
successful verification.

## Scope and lifecycle

- A turn-local registry retains at most 128 host-issued routes. It never reads
  tokens out of assistant text or reconstructs them from a compacted transcript.
- Inventory routes carry the current connection and turn epoch. Page routes
  carry the turn and bound browser generation/handle/document epoch, or the
  native observation identity. Existing backend freshness and authorization
  checks remain decisive; routing is not authorization.
- A fresh inventory or page read replaces only that family's routes. Advancing
  a page preserves the backend's replay rules: inventory cursor replay is
  idempotent, whereas semantic page cursors can be single-use or age-bounded.
- Page routes are registered at the observation publication sites, including
  snapshots returned by automatic post-action verification. Full native
  verification reads without a continuation clear stale page routes.
- New turns obtain fresh inventory and references. Only existing authorized
  target hints may survive; old cursors never become current capabilities.
- A continuation routing failure does not reconnect, attach a different tab,
  create a tab, dispatch input, or silently refresh. It returns an actionable
  read error. The separate bounded alias recovery below does not reroute cursors.

## Requested-scope inventory ordering

Fresh `computer_v2_tabs` inventories reuse the existing host-owned
`ComputerTaskScope.candidateViolation` predicate on complete native URLs and
titles. When the user request supplies an unambiguous target restriction,
`inventory_order=requested_scope_first` places matching candidates first while
preserving the relative order within both groups. No entry is filtered out:
`total_count` still covers the complete captured inventory, and continuations
expose every remaining candidate.

Each row has `request_scope_match`: `true` passes those request-target checks,
`false` fails them, and `null` means unclassified. Unknown and ambiguous requests
retain `inventory_order=transport_order` with null labels. Matching expresses
target eligibility only; it proves neither authorization nor content relevance.
Existing bind-time and live-target checks remain required.

Ordering and labels are frozen with the inventory before pagination. A cursor
replay cannot rerank from changed metadata or a different supplied host scope;
a fresh inventory invalidates old tokens as before. Display-title clipping and
URL omission cannot alter matching against the full retained metadata. The exact
JSON renderer includes the new labels and envelope in its unchanged 12 KiB page
limit; titles remain bounded to 200 UTF-8 bytes and URLs over 4,000 bytes are
omitted entirely. Page size remains a maximum, not a completeness claim.

## Recovery is not action verification

A rejected reference-tool call with a typed argument or stale-reference
prerequisite may include one host-managed fresh read of the same bound target:
browser `overview` or native `all`. This is allowed only in the same active,
unstopped turn, with no in-flight computer operation and no unresolved
dispatched or uncertain action requiring verification. The original tool call
still reports failure; `HOST_READ_RECOVERY` identifies the separate read and
states that no input was sent or replayed.

The allowance is claimed before the read and is bounded per current reference
scope. A failed recovery, explicit read, or changed argument does not refund
the allowance or reset unchanged-intent retry limits. A successful fresh read
can correct an existing typed pre-input prerequisite only under its original
scope and completeness constraints. Its receipt remains
`preflight_corrected_not_performed`, never verified action success. It cannot
clear dispatched action debt. Any later action needs a newly selected reference
and its own admission, approval, and verification. A later verified or
already-satisfied operation may release the recovery allowance; ordinary reads
do not.

A rejected legacy inventory cursor is a `freshInventoryRequired` preflight
failure, not an uncertain click. A successful cursorless inventory refresh can
correct it only using a newer live observation for the exact same scoped target.
A cached next page, another connection, a page snapshot, or an unrelated
successful action cannot clear it. The original rejection remains in the audit
as corrected/not performed. Correction receipts survive ledger checkpoints.

An unknown generic continuation is rejected before backend admission, so it
does not manufacture an action receipt. Repeated failures remain bounded by
the runtime retry guard. Changing a cursor or page size cannot reset an
inventory retry's identity. Existing uncertain/dispatched actions retain their
verification obligations through all read recovery.

A browser action index absent from its cited current snapshot is rejected
before approval or input. This specific rejection carries a host-owned hash of
the turn session, browser generation, binding handle, target identity/instance,
document epoch, loader, and URL. Only a later successful live snapshot with the
same scope and a complete host source capture can correct it. A retained page,
a cut source, another binding/document, or a later action cannot supply that
correction. The original receipt remains `preflight_corrected_not_performed`;
the host does not infer what nonexistent index the model intended. Any later
valid action requires its own exposed reference, approval, and verification.
The scope and source-completeness constraint survive checkpoint restoration.

Here, source completeness describes the captured host tree, not the portion
published to the model. A filtered or paginated read may repair this reference
prerequisite while leaving published read coverage partial. Neither correction
nor the underlying capture fills a `SemanticReadReceipt` exposure gap or proves
that requested content was found or absent.

`computer_v2_verify` can return bounded `HISTORICAL_ACTION_STATUS` for an exact
operation in the current task and active turn. An already verified operation
reports `original_property_verified`; a typed rejection before input or an
already-satisfied operation reports `not_performed`. These replies explicitly
set `live_observation=false`, perform no read/input/replay, supply no snapshot
capability, and do not validate caller-supplied property or expected-value
claims. Historical lookup alone never corrects an unresolved prerequisite.
Ordinary failures and unknown/dispatched outcomes keep their original
verification obligations; pending plans retain their fixed intent and bounded
read budget. Unknown or prior-turn operation IDs cannot retrieve a receipt.

## Structure and claim support

Inventory titles/URLs and a successful bind establish candidate metadata and
attachment. Browser body rows expose two independent classifications:

- `content_scope` describes observed landmark ancestry: main, article,
  navigation, complementary, banner, contentinfo, or unknown. Missing,
  ambiguous, cyclic, or excessively deep ancestry stays unknown.
- `content_kind` distinguishes readable text, controls, navigation, metadata,
  and unknown structure. Control ancestry takes precedence: a toolbar inside
  main is still a control. Container names are metadata; clickability alone
  does not decide whether text is readable.

`view=content` selects readable text. Controls and navigation remain available
through `all` and `links`; `headings` remains a separate view.
`document_content_shown` counts only readable rows with main/article provenance.
`readable_shown`, `controls_shown`, and `metadata_shown` describe kinds, while
navigation/sidebar counts describe provenance. These dimensions overlap; their
counts must not be added together as a partition of `shown`.

The evidence must support the requested conclusion: metadata can identify an
exact title, content lookup needs an observed passage and source URL, and a
detail-extraction answer needs the actual requested details. A short passage
can establish a match; an exhaustive negative needs coverage of the relevant
search space. Structure and exposure do not verify meaning, relevance, or truth.
No site-specific selectors, page names, or subject keywords define these rules.

## Initial browser overview

`computer_v2_read_page({"view":"overview"})` selects observed controls, headings,
links, and navigation landmarks. The legacy `computer_v2_snapshot` view uses
the same selection. It includes custom controls with observed
press/text capabilities, but does not promote inherited control/sidebar text
children into separate controls. Controls, headings, and navigation are
interleaved. Within the control lane, observed semantic-role controls and
settable fields precede weaker capability-only clickability, which can also
mark document roots and layout wrappers. Both groups retain source order;
headings and navigation retain their own source order. Weak custom candidates
remain in the same captured selection and are reachable through continuation;
no node is discarded by this priority change. No site, label keyword, or
requested answer determines selection. Ordinary body text remains available
through `view=content`.

An unfiltered browser `read_page` defaults to `overview`. Literal queries and
`read_region` default to `all`; continuations retain their original view, and
explicit `all` keeps source order and full structural selection. The legacy
model-facing snapshot default applies only when query, cursor, snapshot ID,
and element index are absent. Native defaults remain `all`; native `overview`
requests are rejected before observation. Internal legacy browser reads are
unchanged.

Overview pages contain at most 18 elements and 6,000 escaped body bytes within
the existing 16,384-byte total limit. Long fields retain exact UTF-8 fragments
and may require continuation before later elements appear. The retained
selection, capture identity, freshness checks, action guards, and exact emitted
field receipts use the normal browser read path. `READ view=overview` identifies
interface-selection coverage. Legacy output also carries an `OVERVIEW` notice;
the reference interface supplies its current-reference menu and read guidance.
Exhausting that selection does not read the document body, establish an
exhaustive search, authorize input, or prove task success. Inspect `content`
for supporting passages and `all` when action planning needs broader context.
This API description makes no installed-model validation claim.

## Bounded browser fields and capture identity

The browser text block retains the `AXSNAPSHOT`, `READ`, `CONTENT_EVIDENCE`
header order. `READ source_observation` identifies one immutable capture;
`consistency=immutable_capture` does not mean the live page is immutable.
Continuation and subtree reads reuse the retained capture for at most 120
seconds while revalidating the exact tab/document. Fresh reads receive a new
capture identity even at the same URL. Filters and subtree remain part of the
coverage scope; changing them cannot fill a different selection's gaps.

Each page contains at most 60 rows and 10,000 body UTF-8 bytes; the complete
browser text block must fit 16,384 UTF-8 bytes. Long label, value, and link fields
continue before later nodes. `label_utf8`, `value_utf8`, and
`href_fragment_utf8` use half-open `start:end/total` ranges in the original,
unescaped UTF-8 field. Fragments split at Unicode scalar boundaries; escaping
counts toward the output budget. Join decoded fragments in range order.
A partial link uses `href_fragment` plus `href_omitted=1`, never a clipped
`href` presented as a complete destination.

The reference menu reserves space within the same output budget. It preserves
the exact already-rendered field fragments while replacing row indices and
legacy action cues with typed references. Grouping controls separately from
readable context does not expose omitted tails or expand read coverage.

Truncation flags have separate meanings:

- `source_truncated`: the captured source tree is incomplete.
- `output_truncated`: another page or field fragment remains in this selection.
- `field_truncated`: a body field still has an unexposed tail; it clears after
  the final tail is emitted.
- `metadata_truncated`: the header title was clipped or its URL omitted.
  Header metadata is excluded from body-field coverage totals.

A displayed fragment never replaces the retained full action element. Input
proposals require current exposed references plus the existing approval and
live checks; mutations still compare the exact full target semantics, including
undisplayed tails. Exhausting a captured selection does not establish that
virtualized or uncaptured content is absent.

## Observed links and same-document dialogs

`computer_v2_follow({"link_ref":"<observed reference>"})` resolves an eligible
link in the current published snapshot. Legacy `computer_v2_follow_link`
accepts the current `snapshot_id` and displayed link's `element_index` instead.
The new `link_ref` and legacy `follow_link=true` cue require an enabled semantic
link with supported press and an observed HTTP(S) destination; incidental URLs
on document roots or generic clickable nodes do not qualify. The host compiles
the exact destination postcondition automatically. Do not supply a URL,
`ax_action`, or `postcondition`. The existing approval and live target checks
still apply, and the link is pressed at most once. An already-held destination
is not proof that input occurred. Navigation verification proves the observed
URL, not the destination's contents or completion of the requested task.

For a browser button or menu item intended to open a same-page dialog, declare
`postcondition={"kind":"dialog_opened"}` on `computer_v2_press` with the
opener's `action_ref`. Omit `expected` and nested result references. Legacy
`AXPress` retains the outer control `element_index` and no nested result index.
The host requires an enabled, noneditable semantic opener without a link
destination, a complete live baseline, and no AX-exposed main-frame `dialog` or
`alertdialog`.
It freezes a bounded opener anchor and main-root identity and rechecks both,
plus dialog absence, before dispatch.

Verification requires a fresh complete observation of the same browser target,
instance, document epoch, loader, URL, and main-root identity with exactly one
newly AX-exposed semantic dialog. Ignored dialogs do not establish exposure;
subframe dialogs, ambiguous dialogs, stale reads, and incomplete sources cannot
prove this predicate. The opener may disappear or become inert after opening.
The result proves only AX dialog exposure, not pixel visibility, the intended
search, any dialog content, or task success. Read the returned dialog before
making those claims. Both operations remain browser-only and preserve approval,
current-reference checks, bounded verification, and at-most-once dispatch;
failed or pending verification never replays input.

## Explicit empty fields and historical search receipts

An absent AX field value is not an empty value. For eligible native text inputs
and textareas, the existing DOM snapshot can provide an explicit empty-value
entry. Native and extension projections retain only bounded exact-node markers
for those entries; they do not forward nonempty DOM values. The host intersects
the marker with the current editable AX field. Missing, protected, malformed,
truncated, or conflicting evidence cannot supply an empty baseline. Fresh
pre-action validation and exact post-action value verification still apply.

Search verification may use the complete captured main-frame hierarchy even
when the model receives only an overview. This is host query/results evidence,
not a claim that the model read omitted content. A verified search receipt
survives navigation to a record, separately from current-page search status.
New queries and exact binding scopes cannot inherit another query's receipt.
Empty-result evidence requires a complete, connected, consistent capture;
missing overview rows or filtered matches never establish an empty search.

## Reading after an unknown result change

A non-link browser press still requires a predeclared postcondition. When the
next displayed text is unknown, use
`{"kind":"region_changed","region_ref":"<observed result reference>"}`
without `expected`. The result container must be distinct from the pressed
control, noneditable, and present in the current observation. The outer
`action_ref` identifies the button; the nested `region_ref` identifies the
result. A region reference alone does not make that result eligible.

Browser rows expose their bounded `semantic_role`. Raw AX `node` and
`parent_node` IDs are omitted from model-facing rows.
The `READ` header uses `scope=document|subtree` instead of a raw subtree node ID;
the typed host receipt still retains its exact internal subtree identity.
`parent_ref` is supplied only when that exact published snapshot also exposes
the parent's region reference. It describes a read relationship, not a
substitute action target. Internal node identities, child membership, field
receipts, continuation scope, and preflight checks stay unchanged;
`child_count` and `expandable` remain visible. A
`region_changed_candidate=true` cue uses the same complete-source, read-only
text and stable-anchor validator as plan compilation. It is omitted on
retained/stale reads and does not authorize input.

Legacy rows retain `#N` as the current `element_index` and a `parent_index` only
for a unique exposed parent. Legacy `region_changed` uses the nested
`postcondition.element_index` for the result while the outer action index stays
on the button. Qualified validation paths distinguish those two indices.

The host freezes the region's complete displayed text before approval, checks
its identity again before dispatch, then compares a fresh observation of that
same region. Clipped, empty, stale, replaced, moved, or editable regions cannot
establish this proof;
unrelated page changes and metadata changes do not satisfy it.

A successful comparison establishes only that the declared region's displayed
text changed. The model must read the returned text to determine what changed;
this is not proof of pagination progress or task success. Approval, bounded
verification, and no-replay rules remain unchanged. This postcondition is
browser-only; native actions retain their existing postconditions.

## Host receipts and compaction

A typed `SemanticReadReceipt` records the capture and target generation,
consistency, view/query/subtree, selected body counts, truncation flags, and exact
emitted field spans with kind/provenance. Only published fields count, including
only the returned verification observation rather than hidden polling reads.
The host commits coverage after successfully enqueueing the result. Typed
receipt metadata is removed before JSON serialization; model/page text cannot
supply a receipt.

`ComputerReadEvidence` merges spans only within the same immutable source,
generation, view, query, and subtree. It stores hashed identities rather than
page text, URLs, or query strings. Its bounds are 16 scopes, 256 receipts, 4,096
fields total (1,024 per scope), and 32 ranges per field. Overflow records
`dropped=1` and leaves additional coverage unknown. `captured` means the exact
captured selection was exposed, never that a whole live document was searched.

Native reads report `consistency=live_validated_page`, unknown selected totals,
and actual exposed spans. Each page remains separate: traversal exhaustion
cannot combine live pages into immutable completeness. Clipped or normalized
native fields retain their gaps; browser field-tail continuation is not a
native completeness guarantee. Read paths without a receipt remain unmeasured.

The host ledger survives automatic and managed compaction independently of
whether the model receives a particular history item. For text-only results,
the host prepends a separate `READ_COVERAGE` item of at most 128 UTF-8 bytes,
including on later actions/errors. The pinned runtime's genuine current-turn
receipt retention preserves this item at its minimum text budget and across
repeated compaction. This is bounded receipt retention, not unlimited history.
Mixed image/text results do not receive this prefix: image-omission markers can
consume that minimum budget, so equivalent model-visible retention is not
promised for those results.

Managed compaction restores an explicit historical host checkpoint as assistant
text and waits for injection acknowledgement before starting the queued prompt.
It restores no cursors, typed references, snapshot indices, approvals, or action
authority. A new user turn starts a fresh live coverage ledger; historical
coverage cannot grant current references or erase previously unmeasured content.

## Answer publication after recovery

An empty intermediate assistant message is not a final answer. Its completion
still retires the UI draft, but it must not create a whole-turn outcome warning
from temporary tool debt. A nonempty premature answer remains blocked while
host action, search, or native-message evidence is unresolved.

After a successful computer tool resolves all current evidence requirements,
the same active, unstopped turn may publish a newly generated answer. This does
not replay the rejected answer: discarded drafts and completed item identities
remain retired, including items completed while publication was blocked.
Native/context stops and normal final verification checks remain in force.

## Deterministic validation

From the repository root:

```sh
swift test --jobs 2 --filter 'BorrowedChromeSessionOwnerTests|BorrowedChromeInventoryPresentationTests|ComputerTaskScopeTests|ComputerV2ToolContractTests|BrowserTabSessionBrokerTests|ComputerActionEvidenceTests|ComputerExecutionSafetyTests|ComputerReadEvidenceTests|ComputerReadPublicationTests|ComputerReadContinuationTests|BorrowedChromeRuntimeRoutingTests|ManagedCompactionIntegrationTests|AccessibilitySnapshotTextFormatterTests|ComputaAgentInstructionsTests'
```

Production-Core tests use an inert browser adapter and scripted App Server:
cross-turn stale cursor recovery, page/inventory cursor confusion, unknown
generic continuation recovery, and bounded unchanged retries. They assert one
authorized connection, no input/activation/approval, preserved bound targets,
and a usable next turn. Separate tests cover authorization/revocation, content
provenance, forged recovery receipts, checkpoint round trips, exact Unicode
fragment reconstruction, output budgets, stale action rejection, and immutable
capture separation. Scoped missing-reference tests reject different binding or
document scopes, retained reads, and cut host sources; runtime tests distinguish
correction from an independently approved action and historical status from a
new observation. The managed-compaction coverage test holds history-injection
acknowledgement and checks partial coverage, prompt ordering, and no read/input
replay. Automatic lifecycle and minimum-budget publication checks are separate
from live inference through the pinned compactor. Opt-in real-Qwen/Chrome tests
and the task-comparison gates are not implied by these deterministic results.

The separate scope-ordering run selected 161 cases, skipped two opt-in cases,
and initially failed one new fixture assertion that expected two rows despite
its existing `page_size=1`. Correcting that assertion to require one returned
row, `total_count=2`, and a continuation produced a passing one-case rerun.
Together these overlapping runs cover 159 non-skipped cases; they are not two
independent full-suite passes. Coverage includes stable ordering before
pagination, all 49 candidate tokens exactly once, frozen cursor replay,
full-metadata matching despite clipped displays, unknown/ambiguous/no-match
inventories, exact byte caps, and unchanged bind rejection before attachment.
This is deterministic source-contract validation, not an installed-model result.
