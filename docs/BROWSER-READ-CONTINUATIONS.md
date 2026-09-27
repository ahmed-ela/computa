# Browser read continuation and evidence contract

`computer_v2_continue({"cursor": "<observed next_cursor>"})` is the preferred
continuation operation. The runtime, not model history, remembers whether the
cursor belongs to a Chrome inventory or a semantic page/native read. Legacy
`computer_v2_tabs(cursor: ...)` and `computer_v2_snapshot(cursor: ...)` remain
available, but reject cursors from the wrong source.

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
- A routing failure does not reconnect, attach a different tab, create a tab,
  dispatch input, or silently refresh. It returns an actionable read error.

## Recovery is not action verification

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

## Candidate metadata is not content proof

Inventory titles/URLs and a successful bind establish only candidate metadata
and attachment. Browser observations label each exposed node's structural
`content_scope` and report counts for document, navigation/sidebar, and unknown
regions. These scopes come from observed ancestry, not site-specific selectors
or keywords; missing, ambiguous, cyclic, or excessively deep ancestry remains
unknown. Counts describe only the exposed page, not all content at the source.

App-owned instructions require a short observed document excerpt and source
URL for content-match claims. A sidebar/title match or a filtered read with
zero elements cannot establish relevance or an exhaustive negative result.
Structural provenance is **not** a semantic truth verifier. This patch does
not guarantee that a small model will correctly identify every requested page;
that still requires live model/task evaluation.

## Deterministic validation

From the repository root:

```sh
swift test --jobs 4 --filter 'ComputerReadContinuationTests|ComputerActionEvidenceTests|ComputerExecutionSafetyTests|ComputerV2ToolContractTests|BorrowedChromeSessionOwnerTests|BrowserTabSessionBrokerTests|BorrowedChromeRuntimeRoutingTests'
```

Production-Core tests use an inert browser adapter and scripted App Server:
cross-turn stale cursor recovery, page/inventory cursor confusion, unknown
generic continuation recovery, and bounded unchanged retries. They assert one
authorized connection, no input/activation/approval, preserved bound targets,
and a usable next turn. Separate tests cover authorization/revocation, content
provenance, forged recovery receipts, checkpoint round trips, and output budgets.
Opt-in real-Qwen/Chrome tests are not implied by these deterministic results.
