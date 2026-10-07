# Code editing and review

Computa uses its pinned Codex App Server for code editing. The app-owned model
catalog enables native freeform `apply_patch` for website model IDs; the engine parses patches,
applies sandbox and approval policy, writes files, and emits native file-change
items. `exec_command` and `write_stdin` remain available for inspection, Git, and
tests. Website providers receive a fresh description of the offered tools on
every inference. Custom tools use literal string inputs; function tools use
object arguments. The host validates the complete batch before dispatch.
The local MLX producer remains function-only in this version: local models can
edit through terminal tools, but native patch/event parity is not qualified for
them yet.

Choose **Choose a project folder** in a new, empty chat before sending its first
message. The runtime validates that directory and uses it for the native
thread. Existing conversations retain their original workspace; selecting
another chat cannot retarget an already-created thread.

## Changes panel

**Changes** keeps the conversation and unsent composer mounted. It offers a
changed-file list with status and addition/deletion counts, unified and split
views, wrapping, old/new line numbers, file and hunk collapse, viewed markers,
copy, refresh, and opening a text file in TextEdit. Viewed markers belong to a
specific snapshot and clear when its revision changes. Line feedback appends a
file/line reference to the existing composer draft and focuses it; it never
sends a message automatically.

| Scope | Contents | Actions |
| --- | --- | --- |
| Last turn | Engine aggregate patch and completed rename records from the latest actual user turn | Read and comment |
| Unstaged | Current tracked and untracked changes against the index | Stage or revert all, a file, or a supported text hunk |
| Staged | Current index changes against HEAD | Unstage all, a file, or a supported text hunk |
| Branch | Current committed changes since the merge base with the chosen reference | Read and comment |
| Commit | Chosen commit against its first parent, including root commits | Read and comment |

Last turn is a record of native patch operations, and current files can differ
from that record. Shell-based edits appear in Git scopes. A later turn with no
patch displays an empty Last turn instead of replaying an older change.
The pinned engine omits moves with identical contents from its aggregate diff.
Computa supplements those with metadata from successful file-change items in
that exact turn, showing each distinct recorded rename operation without
inventing a content diff. Chains and cycles retain their distinct operations;
repeated identical pairs are deduplicated. An open panel refreshes after native
patch completion and at turn completion, including changes made by terminal tools.
Current Git scopes include user edits as well as agent edits. Branch and Commit
accept a literal Git reference, defaulting to `HEAD`; **Compare** resolves and
loads it without interpolating it into a shell command.

## Native mutation boundary

The trusted local UI supplies opaque snapshot, file, and hunk IDs. The native
review service retains the exact patch and validates the workspace, repository,
HEAD, index bytes, dirty contents, modes, and symlinks before applying it. A stale
snapshot is rejected and requires Refresh. Git uses fixed argument arrays and
patch stdin, with hooks, external diff, textconv, and fsmonitor disabled.
Before status, diff, or apply, a config-only scan rejects configured clean or
process filters in repository, user/global, and system Git settings. Git scopes
require a repository without those filters; use its configured Git client when
conversion is required. Silently disabling conversion could compare the wrong
contents against transformed index blobs.

Stage and unstage change the index while preserving worktree contents. Revert
requires a native confirmation and discards only the displayed unstaged change,
preserving staged content. The app blocks model submission for that chat during a review
mutation and defers refresh until it finishes. Actions are disabled during an
active model turn. No action executes supplied UI paths or arbitrary Git flags.

Binary, renamed, added, and deleted files use whole-file actions. Hunk actions
are limited to complete modified text patches. Unmerged or truncated patches
cannot be mutated. File opening rejects binary files, `.git`, and paths or
symlinks escaping the selected project. Opening uses TextEdit explicitly so an
executable filename does not launch its associated command handler.

Review display is bounded to 200 files, 1 MiB per file, and 4 MiB in total, with
explicit truncation. Private turn-diff storage retains up to 256 recent turns,
2 MiB per turn and 16 MiB total. Older aggregate records can be evicted; native
file-change history remains in the engine transcript. Proposed, failed,
declined, or unconfirmed interrupted patches remain labeled with that status.

## Validation

The native contract tests cover catalog admission, event identity, failure
statuses, private history persistence, no-edit turns, and storage limits. Native
Git fixtures cover scope calculation, untracked and unusual paths, binary and
rename handling, file/hunk/all mutations, preserved staged data, stale receipts,
containment, size limits, and disabled repository helper execution.
WebUI tests and a live preview cover diff parsing, rendering, draft preservation,
feedback, controls, keyboard navigation, and narrow-window readability.

An opt-in real-engine test exercises all three website model IDs through a
deterministic loopback transport: native add/update/move/delete, command tests,
file-change events, aggregate diffs, malformed/stale-context patch failures,
no-edit follow-up, and reopening without replay. This validates the engine and
transport, not the behavior of Claude, Gemini, or ChatGPT's live websites.
Installed desktop website-model results are recorded separately below.

### Code-editing qualification, October 6, 2026

- 272 distinct Swift tests passed: 215 state/instruction/codec/snapshot regression
  tests, 15 native editing-contract tests, 40 Git-review service tests, and two
  opt-in tests using the actual bundled engine with scripted website transports.
- WebUI type checks, production build, and 112 tests with 459 assertions passed.
- ChatGPT's live website completed an ordinary-language coding request in the
  installed desktop app: fix a function, add a README, rename a module without
  changing its contents, delete a disposable file, preserve an existing user
  edit, and run the two unit tests. Native patch receipts, completed file-change
  events, actual command output with exit 0, final files and private aggregate
  history were verified for that exact turn.
- Gemini's initial live turn applied all four changes, preserved the existing
  user edit, and recovered from an unavailable `python` command by running the
  two tests successfully with `python3`. Its README still used `python`, so the
  initial documentation check failed and that failed receipt was retained.
  A plain-language follow-up in the final installed build patched only the
  README to the validated `python3 -m unittest discover` command, preserved the
  other files, and reran both tests with exit 0. All exact-turn receipt checks
  passed for that correction.
- Installed review checks verified staging and unstaging a text hunk preserve
  worktree contents, native confirmation before reverting a disposable file,
  and line feedback appending to an existing draft without sending it.
- The final signed 0.3.0 (5) app restored both live coding histories with all four
  changed files, including the unchanged-content rename at +0/-0. Hunk staging
  and unstaging passed again with the final Git filter guard. The installed
  executable matches the signed candidate; bundled WebUI/provider resources
  match source. Strict Developer ID verification and staged installation checks
  passed. This is a local signed update, not a notarized or public release.
- A fresh Claude coding attempt in the final installed app hit the typed website
  usage-limit error with zero local tool calls and no fixture changes. Cleanup
  could not be confirmed, so its owned session was retained; website Send count
  remains unverified. This does not qualify Claude's live code editing. The
  scripted engine tests cover its tool transport independently of the account limit.
