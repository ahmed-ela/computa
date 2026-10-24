# Browser initiative and tool contracts

Computa can start a task for a named, known website without requiring the user
to supply its URL. In installed 0.7.0 (206), remote Cerebras `gpt-oss-120b` opened
Outlook, searched for the requested sender, inspected the relevant message and
attachment metadata, and reported the attachment in 43.380 seconds. The test
supplied the service, account, sender and subject matter, but no URL, navigation
steps or filename. No operator navigation or follow-up coaching was provided.

This establishes autonomous retrieval in that controlled run, not error-free or
general browser reliability. It recovered from three cursor/filter mismatches,
one stale-document read and two stale-snapshot clicks. Its final answer changed
five ASCII hyphens in the observed filename to nonbreaking hyphens; the attachment
identity was grounded, but byte-for-byte filename fidelity failed. The application
closed its one task-created tab. No send, forward, download or delete was dispatched.
Later user turns appended to the same chat are excluded from this test.

## Causes and changes

The original failure combined an optional app-query schema that permitted an
empty string with instructions the model interpreted as requiring a supplied
URL. After an empty tab inventory, it asked for access instead of opening the
named service. The current contract says to omit unused filters and allows the
official homepage or sign-in entrypoint of a user-named, known service. Subsequent
navigation uses observed controls or exact observed URLs. Unknown services,
ambiguous accounts and actual password/MFA prompts still require clarification.
Background-only operation limits native focus and global input; it does not
prohibit offered browser navigation or account selection.

The pinned engine also drops some JSON Schema constraints. Current API tool
projection restores native bounds on already-offered browser fields and refreshes
the optional app-query schema. Native validation remains authoritative. Historical
calls are parsed against their original catalog before projecting current tools.
Tool-free compaction accepts bounded, completed historical call/result pairs
without making their names callable. The unavailable Default-mode structured
question tool is hidden; ordinary text questions remain available.

Live trials exposed additional integration defects. The browser now supports the
narrow observed Outlook sign-in routes, waits for meaningful DOM content rather
than treating a title/footer as a loaded inbox, focuses and revalidates a field
before filling it, and exposes actionable ARIA selection controls. Content reads
retain non-navigation listbox options and prioritize main/article text. Filtered
or truncated reads cannot establish absence. Exact cursor-only continuation
metadata preserves the original read's filters.

A stale snapshot rejected before input may return one fresh observation within
the same turn, scope and lease. This is bounded to three distinct rejected
snapshots per turn, once per snapshot. The original action remains failed and
undispatched; no input is replayed, approval is not bypassed, and failure accounting
is unchanged. The model must issue a separate action using the new observation.
Cancellation, document generation, tab ownership and final publication checks
remain in place. Failed task-tab cleanup quarantines that exact tab incarnation.

## Validation and retained limits

The installed executable was built from `70481881cf49ec4c558f804dc646730f0d2029f6`.
All 57 bundle files and 53 resources matched the installation receipt, the signature
verified, the existing engine was preserved, and native-focus/Gemini diagnostic
compiler flags were off. This is a signed, non-notarized test installation, not a
published release. Later documentation commits do not change its executable source.

- **490 selected native tests passed**, zero failures, 77.001 seconds wall time.
  Coverage includes schema projection/history, instruction delivery, semantic
  readiness, routes, cursor isolation, stale recovery, approvals, cancellation,
  ownership, cleanup and failure diagnostics. This is not the entire project suite.
- **27 JavaScript tests / 282 expectations passed**, zero failures. These ran for
  build 197; browser source and test bytes are unchanged through 206. They were not
  rerun for 206.
- Fourteen earlier controlled attempts failed across builds 190–203. Their retained
  evidence covers schema rejection, navigation races, incomplete reads, compaction,
  search submission, unsupported filename claims and stale-reference reuse.
- Build 204 retrieved a grounded, responsive attachment. Its initial rejection
  based on a different older filename was incorrect: the prompt specified no
  unique filename or date. The original assessment and its correction are both
  retained. No unique-intended-file claim is made.
- A build-205 high-reasoning experiment failed argument validation without a final
  answer. Build 206 restores the original medium default. This single experiment
  does not establish a causal quality or speed comparison.

Private mailbox content, filenames and authenticated URLs remain outside the
repository. Local evidence retains the first-turn trace boundary, route, current
attachment observations, tool failures, terminal answer and cleanup. Reproduction
uses a fresh app chat and the same plain-language retrieval request, with no URL
or filename coaching; qualify actual tool observations and cleanup separately
from the final answer. Do not treat a visually similar filename as an exact copy.

Validation receipt SHA-256 values:

| Evidence | SHA-256 |
| --- | --- |
| Selected native tests | `5ace8d957b8f6f45fb91ca3d87444102ed206b2da988964920998a47b36bbbc2` |
| JavaScript tests | `059655e97931b4a0e43a131675cafbe92fdd37e84b9f5439451a79029d8c36db` |
| Installed artifact verification | `ea5b3fee6cd9113f141f1f782566010010f41b60471cffd6989a3e51c1776008` |
| Independent build-206 first-turn qualification | `ffa921c0b8280fa5b0d94e3d8027f0b2d03f64f7672448c1408ca21f843e210a` |
| Corrected build-204 qualification | `06436ecc1bc0bb9806114d8c84b1954f1d8ec368ae680f548265382d7336ba9d` |

Earlier [ChatGPT completion validation](CHATGPT-COMPLETION-SIGNAL.md) remains
separate. These API-provider trials do not establish a new ChatGPT latency result.
