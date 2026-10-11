# Harness validation notes

This appendix preserves the historical evidence and debugging detail moved from
[the workflow benchmark](HARNESS-WORKFLOW-BENCHMARK.md). The main page is the
current qualification checkpoint and contains the reusable method and commands.
Historical “pending” statements below describe their original checkpoint;
later results do not convert failed, interrupted, retried or diagnostic runs
into qualification. Receipt and private-helper filenames refer to the preserved
Codex validation workspace, not files shipped by this repository.

Build 41 source 11's full-workspace run remains unqualified. Its selection was
19,024 tests/275 binaries/56 skipped; the owned run was stopped after explicit
package-fixture `ENOSPC` errors. Its frozen terminal log records 3,404 tests run,
3,325 passes, 60 failures and 19 timeouts. Four failures were the intentional
interruption, leaving 75 substantive adverse outcomes; 15,620 tests were unrun,
including the core cohort. Source and SDK inputs were unchanged throughout.
Owned launch logs show XProtect clearing at 2026-10-09 18:15:33 UTC without
identifying its slow trigger or every failed case's cause. Other distinct
causes include Unix socket `SUN_LEN` errors, unsupported dash-encoded Cursor
temporary paths, and a compaction fork fixture whose effective 95-token window
cannot fit retained receipts and actual initial instructions.

Source 12 changed only that fork fixture's window to 32,768, retained its
90-token limit and mocked usage 96, and preserved every parent/child summary
and developer-instruction assertion. It additionally requires a completed
error-free turn and matching nonempty compaction start/completion IDs for the
same thread and turn. Production guards and provider handling are unchanged.
`just fmt` passed. The affected-package run used the explicitly recorded
short owned root `/Volumes/t7/Computa41Temp` and one worker; no assertion,
deadline or automatic-retry relaxation is used. Original failed receipts and
the earlier cumulative patch are preserved. Native, packaging, installation
and live-task gates remain pending.

Source 12's affected App Server run is terminal and failed: **1,703 tests run,
1,692 passed, 10 failed, one timed out and one skipped**, in **1,563.904 seconds**,
exit 100. Its sealed before/after source and SDK input trees match. The receipt
is `source-bound-build41-app-server-fork-short-temp-serial2-receipt.json`, SHA
`a118f20cd2b42d9240366653c686180ae7d47a898dd245f3ec0c4a0692e0a8e0`;
its log SHA is
`3694556154e922f278b5a28e4dd405dd78c56efa602a8b209df7bde34a0c7312`.
The unchanged Cursor session/plugin end-to-end fixture passed in **0.322
seconds** under the short root. Earlier code-mode host cases also passed.
Individual case results do not qualify the failed suite.
Exact-file security observations separately record assessment gates for the
bare App Server, `exec-server` and CLI helpers. The App Server's waiter release
followed its AMFI launch event by **65.521 seconds**; the CLI's release followed
by **71.992 seconds**. The remote analytics helper's AMFI launch event matches
its failed Rust thread ID; a kernel launch-policy denial follows ten seconds
later. The CLI denials align with its
ten-/twenty-second handshake and listen-URL failures, but exited-helper ancestry
was not captured. These observations identify distinct launch boundaries;
they do not prove every failure's cause, the scan trigger, or a cold-launch fix.
The renewed evidence is preserved in
`owned-bare-appserver-renewed-security-serial2-20261009T145424.txt`,
`app-server-remote-plugin-analytics-serial2-exact-helper-os-evidence1.json` and
`owned-bare-cli-renewed-security-serial2-20261009T150232.json`.

Four zsh fixture cases failed before their copied App Server answered
`initialize`. Exact copied paths show AMFI launch events followed by kernel
policy denials **10.206–10.207 seconds** later. Their temporary homes and times
align with the serial test failures, but live parent ancestry and copied-file
hashes were not captured. Later XProtect access found those copies already
deleted. The cached original zsh had a separate AMFI event; it does not explain
the copied App Server's initialize boundary. Evidence is
`owned-zsh-initializer-security-serial2-20261009T1524.json`, SHA
`b54c1f928da805dd08fec6180c7100ce6941038717bfaaaf49000b4121777e71`.
This establishes exact-file launch denials, not the underlying assessment
delay or a remedy.

The isolated copied-App-Server signing diagnostic finished with three
successful `initialize` responses inside the unchanged ten-second window:
the fresh ad-hoc copy took **3.3615 seconds**, and the two fresh Developer ID
copies took **4.2692 and 3.4007 seconds**. Every process exited zero without
cleanup signals, was reaped, and left no process group. All owned copies and
the owned root were removed. The original's metadata, SHA and signature were
unchanged; its SHA is
`1434d0efc4c68d4df8aa8fef86a459132930ce342df15297b49ab1b9e35a2444`.
The sealed receipt is `copied-appserver-launch-signing-build41-probe1.json`, SHA
`002bdc298a3136e5be5ee32f829ce42c36b7bcbbb21ea8254bb9330149137897`.
File-backed Mach-O section payloads matched the original for every copy;
this comparison excludes load commands, unsectioned link-edit data and the
signature policy. Fixed trial order, assessment caches, system load and the
signed copies' hardened-runtime policy limit causal interpretation. The
ad-hoc success supplies no evidence that signing is necessary, and the probe
does not resolve the earlier launch cause or qualify zsh, core or harness
tests.

Whole-file hashes, Mach-O section payload reads and `codesign` queries ran
before each initialize timer in that probe. The timing therefore describes
read-prepared copies, not untouched cold executable launches.

A separate bounded ordinary-startup preflight of the unchanged canonical
CI binaries passed: CLI `--version` returned in **0.0408 seconds** and exited
zero; no-argument `exec-server` announced its loopback WebSocket URL in
**0.0305 seconds**, with `lsof` confirming the listener belonged to the exact
owned PID. Owned `SIGTERM` cleanup exited -15, reaped the server and left no
process group. Both original binaries' metadata, hashes and signatures were
unchanged, and the private root was removed. The sealed receipt is
`unmodified-ci-startup-build41-preflight1.json`, SHA
`ec22c049764adae77ad59295625f18505df4c3f0c3df5acd13ba9b6a02ae5e08`.
This preflight warms ordinary startup only; it proves neither model execution
nor full-fixture behavior or cold-start reliability. Source 13's affected App
Server suite was interrupted after recurrent launch-gate failures, without
automatic retries or deadline changes. Its terminal log records **1,173 of
1,703 tests run: 1,165 passed, six failed plus one intentional `SIGINT` failure,
one timed out and one platform-skipped**; **530 tests were unrun**. The elapsed
time was **1,215.995 seconds**, child exit 100 and runner exit one. Source, tools
and SDK trees matched before and after. The runner, `just` and Nextest roots
were confirmed absent. The fork regression passed on its first attempt in
**0.457 seconds** as case 982; this does not qualify the interrupted suite.
Receipt `source-bound-build41-app-server-fork-threshold-warm-start-serial1-receipt.json`
has SHA `08e7099c73decb5af9313b3ffa65a18bc045dd5083ed3a74321f8f390ed0f377`;
the log SHA is
`3a9fbadf8474b1ef14262b2fbd2496487aca14faf13bee50d9fa43c527ead6eb`.

During that run, the canonical App Server had been published on inode
**32,295,834**, replacing the preflight original's **32,042,852**, with identical
whole-file bytes and ad-hoc signature/CDHash. An exact-path AMFI event at
**19:53:06.329 UTC** was followed by a kernel launch-policy denial for PID
**71823** at **19:54:06.187 UTC**, then a scan-result event at
**19:54:37.771 UTC**, **91.442 seconds** after the first event. The initial auth
fixture timed out at **60.010 seconds**; the next auth fixture passed in
**31.811 seconds**. The exited failed PID's live ancestry was not captured,
the numeric scan result is not decoded as a policy outcome, and inode renewal
is not established as the cause. The earlier preflight therefore does not
establish readiness of the subsequently published outputs. This diagnostic,
captured while the phase was active, is
`owned-bare-appserver-renewal-security-source13-20261009T2001.json`,
SHA `1ddebc954d5170656ae2ce33aa940d01ea9a861cd8de1148d60f36efb91cdd64`;
it supplies no test or packaging qualification. The reviewed ordinary-startup
gate runs after Cargo publishes its outputs and retains the test deadlines,
assertions and zero-retry policy. Its preparation-only scope allows one fixed
**240-second total readiness budget** and **30 seconds for cleanup**, with a
separate Nextest setup ceiling of **300 seconds plus 15 seconds' grace**.
It must validate all three published helpers and retain their identities
through the test phase. If an exited leader leaves a process group whose
survivors cannot be safely attributed, preparation fails and preserves its
private root; no unknown process group is signaled. External `SIGKILL` can
prevent Python cleanup or receipt sealing and requires owned-resource review.
The actual three-helper gate and Nextest setup seam require separate
qualification. Four private Python controls
passed in **0.052 seconds**, actual exit zero: interruption between spawn and
registration, first interruption during final cleanup, interruption during
receipt serialization, and invalid-plan rejection before any native trial.
They verified owned Python-child reap/group disappearance and failure receipts;
no canonical App Server, CLI or `exec-server` was launched. Receipt
`post-cargo-startup-preparation/controls-receipt.json` has SHA
`202757e89032c0bec5847c6e9fa5f74b1fa20f4403c075c6328e64a3fc40ffc6`;
its log SHA is
`fc6180e217e9799e2bb5a567732c605953345545511545ba86ce9615b203383b`.
Final success is rejected past the 270-second preparation/cleanup budget;
uninterruptible filesystem/sealing operations remain subject to Nextest's
separate 300-second ceiling and 15-second grace.

The reviewed post-Cargo configuration is frozen: plan SHA
`e2fe7a25265ad21e9b4d1475281e21dd59a09d8ce7b99d2a7f4a841066612a4a`,
config SHA `47c10d9c32b5d98e4563a19aed4895536d998589c77c953ab67d0c81e0e1ecc0`,
and preparation-only acceptance SHA
`daad1383ef42c9bd7169ccfc1570732c268b3661cfc14e776a0b21b3cd36d8a0`,
under `post-cargo-startup-preparation/`. The original Nextest config remains an
exact byte prefix with only the setup-script additions; parsed test settings
match after removing those additions. A new root-owned App Server phase
started at **20:28:00.081 UTC** with the same Source 13 freeze, one worker,
unchanged test deadlines and zero retries; no manual warmup preceded it.
Start receipt SHA is
`62e5c2e84e004a1351394f083f4135342bccdfbb3fd00219f1d8973ff76e005a`.
The actual Nextest setup passed in **45.184 seconds**; its sealed helper receipt
records **45.135 seconds**, including file/signature guards and cleanup.
App Server `initialize` returned in **3.176 seconds**, exited zero after EOF
without cleanup signals, and left no owned process group. CLI `exec-server`
listened in **3.662 seconds** and exited zero following owned `SIGTERM`;
standalone no-argument `exec-server` listened in **1.056 seconds** and exited
-15 following owned `SIGTERM`. Both listeners were verified against their exact
PIDs and loopback endpoints. All **11** owned native/utility children were
reaped with their groups gone, no cleanup errors were recorded, and the private
root's absence was independently checked. Declared input and binary metadata,
hashes and signatures matched before and after preparation. The helper
receipt's run ID matches the actual Nextest log. Receipt
`post-cargo-startup-preparation/startup-receipt.json` has SHA
`c6c0597b6785e3f07f9829f1ae71bb0e669de003f3703038961f121a27ea5187`.
This is actual post-publication startup preparation, not model execution,
cold-start reliability or test-suite qualification. The phase-end guard later
verified that all three prepared canonical helper identities were retained.

The phase finished naturally at **20:53:55.697 UTC**. Its terminal summary is
**1,703 tests run: 1,699 passed (five slow), four failed, one skipped**, in
**1,529.430 seconds**, child exit **100** and runner exit **one**. No test
retry or deadline change occurred. Source, tools and SDK records matched
before and after, the temporary-root identity was unchanged, and the runner,
`just` and Nextest roots were confirmed absent with the owned runner process
group empty. Receipt
`source-bound-build41-app-server-fork-threshold-postcargo-serial1-receipt.json`
has SHA `efb56f80d2d9b3ae819ddb5f9312f401ad003a517cb1f00d0ccf95f8afd30648`;
the log SHA is
`7cb86d313bc6e62ae36c389cd059379b9a0b2740bf89697a9c33d9274f04733e`.

The unchanged auth fixture passed on its first attempt in **2.565 seconds**,
the two remote analytics fixtures in **1.820/0.859 seconds**, all four
executor-MCP cases passed, and the fork regression passed in **0.558 seconds**.
These are narrow actual successes within a failed suite. The only failures
were the four `turn_start_zsh_fork` cases 1671–1674, in
**12.144/10.485/10.383/10.443 seconds**. Each logged initialize request ID zero
without a reply; no mock model request was received. Their shared fixture
copies the canonical App Server and cached zsh into each new test package,
then launches that custom App Server path with the unchanged ten-second
initialize deadline. Those new copied executable identities are outside the
three canonical paths prepared by the post-Cargo gate. The code does not
re-sign them; the current failures alone do not establish a signature defect
or security-assessment cause.

Source 13's full App Server suite remains unqualified. The separate
`core-net-postcargo-serial1` and `workspace-postcargo-serial1` plans/configs are
prepared and frozen, but their actual phases remain unlaunched and pending.
The canonical recovery and fork pass do not guarantee fresh copied-executable
startup or relabel earlier failed runs.

A separately authorized cleanup removed only four verified inactive,
noncanonical CI executables. The existing Cargo advisory lock was held;
canonical binaries, source pin/patch, fingerprints and lock identity remained
unchanged. The removed files accounted for **2.026 GiB of allocated bytes**;
the measured immediate net increase in free space was **215.641 MiB**
(approximately **216 MiB**), not 2.026 GiB. Filesystem reclaim timing and other
activity were not isolated. All four paths were absent at cleanup completion
and the lock was released. Receipt
`owned-noncanonical-ci-executables-cleanup-build41-threshold1.json`, SHA
`726190ae9eb31d3aea49535b5719265ce24ebd55fce5a9515dd8d5944b4a7e5f`,
qualifies this bounded cleanup only.

The separately owned grounding-fixture `target/debug` cache cleanup removed
**4,983 regular files and 651 directories**, accounting for **1.583 GiB of
allocated bytes**. The measured immediate net free-space increase was
**1.402 GiB** (approximately **1.40 GiB**). The existing profile advisory lock
was held through final checks and released; `target/debug`, its parent and
`.cargo-lock` were preserved, with only the lock remaining in the profile.
All **1,011** protected inputs were unchanged and open-holder/reference checks
were recorded. No Wasm removal occurred. Receipt
`owned-grounding-cache-cleanup-build41-2.json` has SHA
`767ca2f18d56712e68af563107d72055617eddc14eb802634f121a7e46aa65db`.
Allocated removal and measured free-space change are separate observations;
filesystem reclaim timing and other activity were not isolated. This is
cleanup evidence, not a build or test pass.

The fork fixture's first turn completed without error and its matching
nonempty `contextCompaction` start/completion assertions passed. The second
turn then failed during pre-sampling compaction: the fixed 90-token threshold
was below the retained context/instructions. The later child-fork assertions
were not reached. Source 13 corrects only this
fixture's threshold/mocked usage to **8,192/8,193**, preserving the
32,768-token window, forced mid-turn compaction, and all request-count,
parent/child instruction and compaction identity assertions. Actual `just fmt`
passed with unchanged before/after inputs; the receipt is
`compaction-fork-fixture-build41-format-threshold1-receipt.json`, SHA
`7b2a32b832c5d6ec5f0b4ddea63188a6088954961a6ef1f80f616d55e54bcc0a`.
Source 13 test qualification remains pending. Production compaction guards, provider behavior
and test deadlines are unchanged. This correction does not relabel source 12
or any earlier failed run.

## Current collector synthetic coverage

The four current collector modules passed together: **103 tests**, zero
failures, errors or skips, in **14.275 seconds**, actual exit zero. The collector
SHA is `947720293113b06b556ac0609771e0d7cae1b267c162cf993dfbb1a3c876304a`.
All **1,954** declared input records matched before and after, including the
current tests, oracles, final-answer/cleanup helpers, preview template, Python
runtime and declared command tools. All **160** distinct main-process loaded
module files were bound. The private fixture directories were restored, the
test root was reaped with its process group gone, and the control root was
removed. This closes the full-cohort coverage gap after the earlier 97-test
run; the previous 23-test targeted pass remains a separate result.

The immutable receipt is `collector-build41-v2-current-full1-receipt.json`, SHA
`d435826f2fe592dda2a8f768fc53fb7f9af2ba6d143e4c0266e62f017f9cd073`;
the log is `collector-build41-v2-current-full1-log.log`, SHA
`fb2c65672722759d4494b795cf80959aa16abd067b1cee14820e1cec9bbbfc3b`.
These are synthetic fixtures, disposable local Git operations and owned
loopback probes; no provider or installed app was exercised. Arithmetic
subprocess imports were not individually instrumented, though their generated
source literals and Python runtime were frozen. System libraries, all Git
transitive files, security state and machine load are outside the binding.
The browser final-answer matcher also permits conflicting or misassociated
multi-flight prose if the expected flight, gate and a matching time occur
independently; actual final answers still require independent review. This
run does not qualify natural coding, browsing or preview execution.

An earlier private build 41 native runner selection was corrected to include
the previously omitted **15 `FileEditingContractTests`**, **two
`AccessModeLiveTests`**, **19 `AppStateAccessModeTests`** and **two
`WebModelRuntimeRoutingTests`**; its existing four
`RuntimeIsolationTransportTests` remain required. Acceptance now requires
each exact suite summary, the real Full outside-workspace write followed by
Ask restoration on the same thread, and at least **538** zero-failure tests.
The 311 source inputs and engine pin/patch were unchanged; only private runner
and preparation bindings changed. Receipt
`native-selection-correction-build41-acceptance1.json`, SHA
`5bd239c4a1b481751da272d0f907057cbe0330eff6223bbbf0bcdf5611edbeb8`,
records preparation only: no native tests ran. This expanded native cohort
remains pending after actual engine packaging; instruction-protocol and
product/version checks still have separate bindings.

A further private guard review tightened native/stage acceptance without
changing the 311 source inputs, source pin/patch or existing filter terms.
It now requires the exact five unique provider/scenario workflow pairs with
verified owned-fixture removal and at least **26 unique cleanup identities**,
rejecting duplicate or malformed records. XCTest summaries account for skips:
only the optional `AccessModeLiveTests` case may skip, at most once, while the
critical same-thread Full-to-Ask boundary case must have exactly one actual
pass. All eight stage file bindings match. Receipt
`native-selection-correction-build41-acceptance2.json`, SHA
`f295994dc69a5c72d171fcbb81356faa21c863a48803c1637d4b5b101753c381`,
records historical-parser and synthetic negative/format checks only; no native
build, test, package or install ran. Previous private runner/preparation/stage
bytes remain preserved. The corrected native and stage gates remain pending.

The historical Acceptance 3 evidence review is recorded in
`native-selection-correction-build41-acceptance3.json`, SHA
`86fddbedcb545940fd5ab86a0811335d1364e87406b70c5a09ab9fcde966fa2e`.
That native runner required all six exact suite counts: file-editing
contracts **15**, live access **2**, app-state access **19**, web-model routing
**2**, runtime isolation **4**, and `RuntimeFileEditingLiveTests` **3**. The
last suite allows no skips; only the previously documented optional live
access case may skip. The zero-failure **538** minimum and exactly one actual
Full-to-Ask boundary pass remain required.

Native patch evidence must contain exactly these five passed records, with no
duplicates, malformed fields or retained failure-artifact records:

| Provider/scenario | Successful patch calls | Rejected patch calls | Command calls | Replayed calls |
| --- | ---: | ---: | ---: | ---: |
| ChatGPT normal | 1 | 0 | 1 | 0 |
| Claude normal | 1 | 0 | 1 | 0 |
| Gemini normal | 1 | 0 | 1 | 0 |
| ChatGPT rejection probe | 1 | 2 | 1 | 0 |
| ChatGPT fast-command probe | 1 | 0 | 32 | 0 |

Stage acceptance independently recomputes the six-suite counts, minimum,
critical boundary pass and patch matrix from the hash-bound native log. It
also captures the signed built app's main-executable identity and SHA before
`ditto`, requires the built identity/bytes to stay unchanged and the staged
SHA to match after copying, and repeats those checks after verification. The
verifier's main SHA must match, and the staged executable's post-copy identity
must remain unchanged through verification. These are required future checks,
not completed build or copy evidence.

All **106** in-memory/static controls and AST syntax checks passed. Historical
build 39/40 logs fail the current suite/patch requirements and cannot qualify
build 41. The receipt records all eight preparation bindings matching at that
snapshot, with the 311 source inputs and engine pin/patch unchanged. Historical private
native runner SHA is
`1d4bae3e6b93ae58fe1df75396432cd349cae9b59bc278fdde1d2f424c5f522b`;
stage runner SHA is
`99c93d5c4819c46d56ca48af5e8b4e7de81bbef104d9451c29266b949da79924`;
preparation SHA is
`209211c35ed35f16251aedd5e4ad4c7f44b2f8d2576a9b9a974cbeb8e35ae513`.
Their preceding bytes remain immutable in the
`before-final-evidence-guards3` backups. No native test, build, package,
installation or model execution occurred for this acceptance; native and stage
qualification remain pending.

The current successor-2 native and stage scripts require **587 tests with zero
failures** and **nine exact cohorts**. They retain the six Acceptance 3 cohorts
and add `AppStateReviewTests` (**8**), `EmbeddedBrowserSessionTests` (**38**) and
`EmbeddedBrowserTabTransportTests` (**11**). The last count includes three
new regressions covering synchronous and delayed popups from a tool-controlled
document, denied-action isolation and popup restoration after a replacement
document commits. They retain the same 311-input set, critical Full-to-Ask pass,
five workflow pairs, five patch-counter records and 26 cleanup identities.
The current preparation is `release-stage-candidate-build41-preparation2.json`
(SHA `7a36f54e344b68c8df14ec0768b63744edb1cd35c3b2720f854f708147ae2833`).
The additive source/configuration review is complete; native tests and stage
execution remain pending after the engine package is built.

## Combined-tool startup gap

An installed build 35 check exposed a startup gap: browser tools were emitted
in legacy form alongside canonical native definitions, so `thread/start` was
rejected before inference. Build 36 makes that manifest consistent. The
workflow now checks the complete combined payload and its actual native
acceptance, closing the earlier fixture gap.


## Build 39 native and scripted workflow results

Build 39's native validation on 2026-10-08 passed **535 selected tests with zero
failures in 361.278 seconds**. `native-build39-corrected.log` and
`native-build39-corrected-validation.json` are bound to the 311 unchanged input
hashes in `native-source-freeze-build39-corrected.json` for Computa **0.6.0 (39)**.
The native suite includes actual combined thread startup, editing/diffs,
protocol/streaming, isolated WebKit, approval/Stop, owned child-process and
signal-probe tests, and durable cleanup. All 26 selected streaming/child fixture
cleanup records verified removal. The three-provider adapter suite separately
passed **361 tests and 6,194 assertions**, and the strict live-evidence collector
passed **90 synthetic oracle tests**. Version checks passed nine tests.

Build 38 separately passed 512 native tests against 310 inputs. The extra C
signal-probe fixture is included in build 39's freeze because the selected child
process tests actually compile and execute it. An earlier build 39 run's one
failed assertion incorrectly expected a rejected private website lease to have
been closed; its log is retained. The corrected test requires the lease to remain
private while preserving the human tab, matching the production cleanup policy.

| Scripted provider ID | Scenario | Seconds | Inference requests | Matched tool outputs | Approvals | Outcome |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `browser/chatgpt` | Editing, tests, Git push, localhost, TTY | 6.300 | 13 | 12 | 3 | Passed |
| `browser/gemini` | Editing, tests, Git push, localhost, TTY | 6.158 | 13 | 12 | 3 | Passed |
| `browser/claude` | Editing, tests, Git push, localhost, TTY | 5.881 | 13 | 12 | 3 | Passed |
| `browser/chatgpt` | Declined command has no side effect | 1.666 | 2 | 1 | 1 | Passed |
| `browser/chatgpt` | Stop cancels inference and reaps server | 2.806 | 2 | 1 | 1 | Passed |

Every scenario confirmed removal of its owned fixture. The interrupted server's
exit remained unconfirmed in presentation, while its PID and port were
independently verified closed before shutdown. Five additional consecutive Stop
runs on build 37 passed; the maximum observed physical retirement latency after logical
acknowledgement was **98.275 ms**, with no extra signal or shutdown used to pass.
The original immediate-PID check exposed the pinned engine's asynchronous reap
boundary; finite structural diagnostics now survive failure cleanup.

Every scripted workflow uses fresh owned website leases while retaining the
same real native user turn. Long-history regressions verify more than 80 native
turns, 90-turn receipt retention, summary eviction, conflicting identities,
partial persistence failure, exact retry and storage bounds. Separate native
patch qualification passed for all three provider IDs; malformed/stale patches
were rejected before writes and were not replayed.

## Installed provider tasks and failed attempts

Build 36 installed coding attempts exposed ChatGPT's rendered whitespace change
and Claude's virtualized old website message roots. Their failures remain
separate records. Build 37 narrowly handles ASCII whitespace during guarded
first-message promotion and uses [fresh website inference
transactions](WEBSITE-INFERENCE-TRANSACTIONS.md).

Installed **0.6.0 (37)**, source
`cbf199d8bebc69b146b2a58af9bd4039ff1ec7db`, completed one fresh **Claude Sonnet
5.5** coding turn in **91.468 seconds**. The live collector verified **43/43
checks**, including nine distinct website leases, nine durable closures and
release before native tools, the next inference and the final response. Nine
matched tool calls produced nine outputs: eight `exec_command` calls and one
native `apply_patch`. The archived evidence matches the 310 frozen inputs with
zero mismatches; `live-claude-coding-build37-receipt.json` binds the exact turn,
process, model selection and transaction journals.

The model fixed addition, added test instructions, deleted the obsolete fixture
and renamed the helper without changing its content. Both Python tests passed
twice through native commands and again in the independent **15/15** filesystem
oracle. Commit `367667eb070c96378efc8ac8d36210a414d1444f` matched the disposable
bare remote; only the original user note remained dirty. The model recovered
from a shell glob error and sandbox Git denials before using explicit elevated
Git requests. The live run did not execute the broken baseline tests first.

Operator AX observations in `live-coding-build37-diff-ui-observations.json`
confirmed that Last Turn showed the three files changed by the native patch,
with 18 additions and two removals; the terminal rename was outside that
aggregate. Commit showed
four changes, including the 100% helper rename with zero line changes. Split
showed `return a - b` beside `return a + b`; Unstaged showed only `notes.txt`
with its one preserved addition. No stage or revert action was tested.

This live result is separate from scripted provider coverage. It proves an
observed Claude website selection, not an immutable backend revision; guarded
cleanup acknowledgements do not independently prove provider-side deletion.
The push used a local remote, so external Git hosting authentication remains
unqualified.

The same build completed a separate **Claude Sonnet 5.5** flight-browser turn
in **102.777 seconds**. The collector passed **37/37** checks: thirteen matched
browser calls (one open, seven reads, four clicks and one fill), fourteen fresh
website transactions and fourteen durable closures. The synthetic board
recorded one matching flight search and one gate reveal. Fresh DOM observations
supported the final **18:37 EDT, gate B49** answer. Expected facts were absent
from the natural-language prompt. This exercises navigation, forms and dynamic
page results in Computa's own WebKit browser; it does not access a real United
account or establish personal booking data.

A subsequent Claude combined preview attempt stopped on its actual website
usage limit before any tool ran. Its exact cleanup receipt confirmed an
untouched session was closed; no preview server or run directory was created.
A separate build 37 ChatGPT flight attempt stopped before tools on first-message
verification after a permitted initial chat route change, without replaying
the prompt. Its cleanup remained unconfirmed. A fixture reproduced a consumed
expansion claim that could not continue across an accepted route change; build
38 corrects that specific regression with native-certified route continuations.
The build 37 coarse diagnostic cannot establish which predicate failed live.

A fresh build 38 ChatGPT attempt also stopped before tools. Its finite
diagnostic identifies `expansionContextFailure=product`, with the full first
message and final marker present. A read-only fixture reproduced a false
product revocation at 513 message-only mutations: the observer was counting
conversation rendering against its product-control limit. The live batch count
was not recorded, so this is a likely cause rather than proven causation.
Build 39 excludes verified message-only records from that budget while retaining
tracked product-control mutations, including controls moved into a message and
transient Work selection. The first revocation reason and bounded counts are
latched and logged without message content. Historical failed attempts retain
their exact evidence and cannot become successful qualification through a later
fix. The combined localhost preview remains pending.

## Owned historical cleanup and ChatGPT prefix recovery

Final cleanup also archived and removed 275 historical, exactly owned streaming
fixture roots. The immutable cleanup receipt verifies 1,914 archived regular
files, every byte hash and mode, no live processes or open files, and final
absence of each root. Roots without sufficient ownership evidence were preserved.
Successful streaming and child-process tests now remove only their unchanged
owned directory after confirmed process shutdown and successful assertions;
failure evidence remains available.

A fresh build 39 ChatGPT GPT-5.6 Sol attempt stopped before tools with
`expansionOutcome=text_mismatch`. Its full rendered body, unique final marker,
and exact failed-turn journals were preserved; cleanup remained unconfirmed.
The diagnostic did not identify product-mode or route failure. Raw rendered
lengths cannot establish whether content changed: the existing expansion check
also required an exact captured prefix despite allowing ASCII whitespace runs
for the complete prompt. Build 40's controlled prefix fixtures passed the
corrected ASCII-whitespace boundary and finite mismatch diagnostics; its
three-provider adapter suite passed **364 tests and 6,321 assertions**.
This does not establish the cause of the earlier live failure or a new installed
ChatGPT pass. The build 39 attempt remains failed and was not replayed.

## Producer transcript repair and early Rust qualification

Build 40's native qualification caught a separate command-output race: a
fast successful assertion returned `PATCH_TEST_OK` to the model, while the
completed command item and persisted native history had an empty aggregate.
The model-output and completed-item records establish the mismatch; source
inspection identified a subscriber-owned aggregate that could miss output
already captured for the poll result. The failed run had no protocol trace, so
its exact wire ordering is not claimed. Build 40 executed **537 selected native
tests with two failures in that one test**; it is not an overall pass.

The failed fixture and rollout were subsequently archived before removing the
exact inactive root. The receipt verifies **5,550 files, 89,036,351 input bytes**,
all archived hashes, modes and ZIP CRCs, final root absence and zero signals.
The original failed result remains preserved in the archive and validation log.

The proposed engine repair moves a bounded cumulative transcript to the
producer, independent of the destructively drained poll buffer. Completion
paths read that canonical transcript; streaming consumes broadcast deltas
without capturing chunks again. Local ingress still uses upstream lossy
broadcast; the lag regression saturates only downstream UI delivery, so bounded
transcript capture does not establish lossless OS output. Qualification retains
the original command-marker assertion and adds
**32 fast commands** with distinct markers and call IDs, model-output matching,
successful timeline transcripts and the same identities after reopening saved
history. Initial and reopened runtimes use separate private protocol traces.
Corrected Swift compilation and test discovery passed; no native tests ran in
that check.

The first Rust compile attempt stopped on `E0603`, a private import in the new
regression test, before any tests executed. Importing the crate-owned type
directly corrected it without changing production behavior. Its failed receipt
also contained a source-verification bookkeeping error; independent hash checks
confirmed the original source and patch were unchanged before correction.
Standard formatting passed with unchanged source.

The subsequent core test compile finished under the release profile in
**52 minutes 50 seconds**, but test discovery aborted with `SIGABRT` and exit
**104** before any tests executed. The test initializer creates a temporary
`CODEX_HOME`; the unchanged arg0 guard in builds without debug assertions
correctly refuses helper binaries there. Selecting release for these tests was
incorrect. The receipt records unchanged source and no test qualification.
The next attempt used the upstream `ci-test` profile, which inherits the test
profile; full-workspace validation will use it too. Production packaging still
uses release, with no source or security-guard change.

The first `ci-test` core attempt compiled in **21 minutes 30 seconds** and ran
**4,423 tests in 552.210 seconds: 4,166 passed, 256 failed and one timed out**.
An additional **28 were skipped**. Source hashes remained unchanged. The four required unit
regressions, two local completion/lifecycle tests and seventeen mocked remote
process-event cases passed on their first attempt, but the overall core run
failed. Mocked event cases do not qualify a real remote Linux or Windows executor.

Four required cross-package binaries were absent: `test_stdio_server`,
`test_streamable_http_server`, `codex-code-mode-host` and `codex`. Missing helpers
appear directly in failure diagnostics and can also prevent dependent tool and
mock-server assertions from completing. Eight Git-context assertions failed
because the owned temporary directory was inside Computa's Git repository;
fixtures intended to be outside Git inherited its root and metadata. A separate
deferred-executor compaction case produced two requests where three were required.
`shell_snapshot::tests::snapshot_discovers_and_redacts_shell_initialized_credentials`
timed out on both attempts at **60.005 seconds**, without diagnostic output that
establishes the underlying cause. These failures remain preserved.

The next helper preparation used an owned temporary directory outside Git. Both
RMCP test servers built successfully in **6 minutes 18 seconds**, but
`codex-code-mode-host` failed when V8 150.4.0's requested pointer-compression and
sandbox archive returned **HTTP 404**. The CLI build did not run. Source hashes
remained unchanged; the overall helper preparation failed. V8's bundled upstream
README documents that `v8_enable_sandbox` has no prebuilt archives and requires
`V8_FROM_SOURCE=1` or a custom archive. A source-build route is being prepared
with the existing sandbox feature, security settings and dependencies preserved.

The compaction fixture subsequently changed its context window from **100 to
32,768 tokens**, retaining the automatic compaction threshold of **90**, reported
usage of **96**, three-request assertion, feature flags, environment ordering and
rollout assertions. It now reports an unexpected error while awaiting the
continuation. The impossible original context budget is an inferred explanation;
the failed run did not capture the emitted error. All four engine source files
are unchanged, and removing this test-only diff reproduces the prior patch
exactly. The new **202,392-byte** patch is `9da371b8…`, with source freeze
`095b34a4…`. Standard `just fmt` passed with unchanged source.

Three serialized commands built the four normal core helper binaries:
`test_stdio_server`, `test_streamable_http_server`, `codex-code-mode-host` and
`codex`, with `ci-test` and an owned `TMPDIR` outside Git.
The pinned V8 sandbox archive's HTTP 404 required the supported
`V8_FROM_SOURCE=1` route with pinned `PYTHON`. Only the exact pinned little-endian
ICU data and Chromium Rust vendor subtree were restored into the task-owned
cache after verifying their Git blob/tree identities and bytes; the original
crate archive, existing package files, dependency versions and sandbox features
were preserved. Helper run `core-helper-v8-source-ci4` reused the preserved cache
and qualified prerequisite builds only, with unchanged source and tool guards
(receipt `11975f23…`). The full core run that began at **2026-10-09 06:50:01 UTC**
ran **4,423 tests in 775.788 seconds: 4,415 passed, seven failed and one timed
out**, with **28 skipped**. All new transcript regressions, both compaction cases
and both completion/lifecycle cases passed on their first attempt. The overall
run failed; its source and tools remained unchanged. Four CLI deadlines, a
hidden dynamic-tool deadline, a stdio initialization deadline and a network-denial
case failed; the credential snapshot test again timed out on both attempts.
Subsequent isolated runs of the CLI, dynamic-tool, stdio and network-denial cases
passed. Those diagnostic passes do not replace the failed complete run or prove
its cause. Production `Scripts/build-agent-runtime.ts` builds only
`codex-app-server`; Computa's built-in browser remains WebKit.

Bounded credential diagnostics showed repeated finite snapshot preparation,
rather than a proven infinite loop. A metadata-only optimization still timed
out on both attempts and was rejected. Computing each credential sort tuple
once per invocation passed the unchanged credential test on its first attempt
in **40.282 seconds**, retaining the original sortable references, tuple ordering
and unstable-sort tie behavior. That small registry optimization was accepted;
no cross-call cache, credential policy, test deadline or retry behavior changed.
The unused `body_json` import was also removed. The accepted seven-file source
freeze is `2d18cb42…`, with a **206,507-byte** cumulative patch `25331a31…`.
Formatting passed with unchanged source. The subsequent helper and affected-package
results are below. Full-workspace tests, final scoped linting, engine packaging,
build 41 native and installed live qualification remain pending.

## Core/network qualification and executable-startup diagnostics

The accepted source's fresh helper build qualified all four binaries with
unchanged source and tools (receipt `7d3a8369…`). Its first complete core and
network-proxy run executed **4,717 tests in 681.302 seconds: 4,712 passed and five
failed**, with **28 skipped**, no flaky results and no leaked tests. The credential
test passed on its first attempt in **52.097 seconds**; the three new transcript
regressions and the previously failing stdio fallback case also passed. The four
CLI cases failed both 30-second attempts; the hidden dynamic-tool case failed
both ten-second attempts. This complete run remains failed (receipt `424dd878…`).

Narrow macOS diagnostics recorded executable scanning during startup. The core
test-list binary's waiters were released after roughly **161 seconds**. The CLI
helper's validation spanned **69.4 seconds**, and the V8 helper's spanned **25.9
seconds**, exceeding the failed cases' deadlines. The exact helper paths and
validation times were observed, but individual failed-test PID/thread mappings
were unavailable; per-case causality is therefore an inference. The diagnostic
receipt `3b6e18ee…` preserves that limitation and the tool-output-only system-log
evidence. No executable was warmed manually, re-signed or exempted from scanning.
A fresh complete run of the unchanged source and original deadlines ran
**4,717 tests in 631.922 seconds: 4,716 passed and one failed**, with **28
skipped** (receipt `34371775…`). All five previously failing cases passed their
first attempt, and the credential test passed in **51.011 seconds**. The
extension-permissions image test timed out once at its existing ten-second
event wait and passed its retry. The strict flaky-result policy still rejects
the whole run. Its generic timeout does not identify which of its two event
waits stalled. That permissions/image filesystem path bypasses the changed
unified-exec transcript pipeline; the original timeout's phase and cause remain
unproven.

A private seven-line overlay labeled only that test's two existing waits. The
exact case passed its first attempt in **0.519 seconds**: permission request at
**32 ms**, image generation begin/end at **69/145 ms**, and final completion at
**164 ms**. The diagnostic reporter rejected nextest's singular `1 test run`
summary, so it stopped before the four-case cohort. Original source bytes and
modes were restored, with a fresh modification time and unchanged tools. This
isolated pass does not identify the earlier timeout's phase or cause, and does
not qualify the failed full run. The narrow reporter correction passed **30
parser checks**. A fresh diagnostic passed its exact case and all **four cohort
tests** on their first attempts; the cohort completed in **1.203 seconds**. Its
permission and completion waits returned at **45/241 ms**. Source and tools were
restored and unchanged (receipt `853ba596…`). No production timeout or assertion
was changed. The next complete run was interrupted during compilation, without
any test summary or captured exit code; its stopped process and unchanged source
were verified separately (observation `d6098639…`). That incomplete run provides
no qualification result. A fresh complete run uses the same original test policy.

That fresh complete core/network run passed: **4,717 passed in 669.254 seconds**,
with **28 skipped**, three slow tests, no failures, no flaky results and no leaked
tests (receipt `a9ea1345…`). No retry rows appeared. The credential test passed in
**36.868 seconds**, the three producer-transcript regressions passed, and all six
previously failing CLI/dynamic-tool/extension cases passed on their first attempts.
The extension-permissions case took **3.187 seconds**. Full source, tool and
evidence checks remained unchanged. This qualifies the affected packages; the
complete workspace, scoped lint, packaging and installed live gates remain separate.

## Voice SDK and V8 workspace prerequisites

Full-workspace preflight found a separate missing prerequisite: the default
workspace includes `codex-voice-host`, whose macOS bindings require GStreamer
core/app/audio **1.28 or newer**. The selected core/network packages do not
build that native audio dependency. Upstream documents a small, task-owned SDK
recipe; its eleven pinned archives were downloaded and hash-verified (receipt
`f79053fc…`). Native SDK compilation, relocation and a focused voice-host loader
check remain pending. This test-only SDK is separate from Computa's shipped
runtime. The later complete-workspace receipt must be bound to the actual SDK
inventory and explicit environment, in addition to the existing strict source,
tool and first-attempt pass checks.
The private package9 contract adds that mandatory SDK attestation and passed
**109 read-only contract assertions**; it has not packaged an engine. The first
native SDK build failed during libffi configuration because the standalone linker
could not locate macOS `libSystem` (receipt `e4f016ee…`). Source and tools stayed
unchanged. A small compiler experiment reproduced that failure without an SDK
path; explicit `-isysroot` flags let both C and C++ programs compile and run
(receipt `c8c84ed8…`). This diagnoses the build prerequisite, not harness behavior.
A fresh private SDK plan pins the selected Apple SDK directory and four marker
files, supplies those flags through upstream's supported C/C++/link arguments,
and checks the SDK selection before and after execution. The failed plan and
receipt remain preserved. That fresh native SDK build completed successfully:
all seven pkg-config version probes passed, its exported SDK has 649 files
(29,448,856 bytes), and its runtime projection has 44 files (13,028,244 bytes).
Source, tools, selected macOS SDK and the exported inventories stayed unchanged
(receipt `ef8d8bbe…`). The private package10 contract binds that new plan and
passed **168 read-only assertions**. The first focused loader preflight compiled
the voice helper successfully, then rejected its unit binary because it had
native `@rpath` imports with no `LC_RPATH` search path (receipt `428c59b7…`). No
tests executed, and all source/tool/SDK/terminal checks passed. Two test-environment
issues were identified: system-deps expects `-rpath,<path>` and adds `-Wl,` itself,
while dependency build-script linker arguments do not establish a final binary's
runpath. A fresh SDK plan corrects that format and supplies a task-owned Cargo
target linker wrapper. It invokes the pinned compiler with the original arguments,
adds the exact projected runtime path, and explicitly pins `DEVELOPER_DIR` and
`SDKROOT`. Its bytes and environment must match the actual SDK and workspace
receipts. Prepared plan3 was not executed; plan4 includes the explicit SDKROOT
pin. The corrected SDK build passed (receipt `85dd15a6…`). Its first focused run
passed all four Mach-O inspections and the actual test command: **52 passed in
11.257 seconds**, with two explicitly ignored tests and no retries. The reporting
adapter then rejected nextest's padded counters, such as `( 1/52)`, because its
pass-row grammar only accepted unpadded counters (receipt `63a37be7…`). All
source/tool/SDK/terminal/evidence guards passed. The actual passing test log and
failed report are preserved. The successor accepts only horizontal counter
padding and explicitly enables `NEXTEST_STATUS_LEVEL=all` so both skipped case
names can be checked. **34 pure parser checks passed**, including adverse,
duplicate, missing-case and malformed-padding controls; the old log still fails
strict qualification because it lacks skip names. The fresh focused run passed:
**52 passed in 10.984 seconds**, the two expected ignored cases were identified,
and all four Mach-O, compiled-program, source/tool/SDK/temporary-directory and
terminal-process guards passed (receipt `f0e703bd…`). The full-workspace gate ran
in this explicitly bound SDK environment. The fresh package12 parser
also reads all **4,717** core4 pass rows, including the first 999 padded counters;
**247 read-only assertions** passed and all existing source/SDK/release guards
remain unchanged. That workspace attempt stopped during compilation of
`codex-v8-poc`, before any tests ran: source-built V8's macOS partition allocator
references both CoreFoundation and Security, but neither framework was present
in that test binary's link command. The pinned `rusty_v8` build script emits the
V8 archive and C++ library without those framework directives. The failed
workspace receipt is `d13b1f0e…`, with its separate SDK attestation `4e6ece4f…`;
source, tools, SDK inventories and Apple SDK markers stayed unchanged. Fresh
private plan5 adds those two system frameworks to its final linker. Its SDK
build passed (receipt `5163b30f…`) with all seven version probes and unchanged
source, tools and Apple SDK markers. Package13 changes only the selected plan
path/hash and builder hash; **266 read-only assertions passed**. The focused
three-package run then linked successfully, but exposed two separate failures:
the V8 proof-of-concept expected its own sandbox feature to be disabled while
the shared V8 dependency already had sandbox support, and voice negotiation
timed out. An explicit `--features codex-v8-poc/sandbox` aligns that expectation
without changing V8's existing dependency features. The fresh workspace and
package14 contracts record this command change; **362 read-only assertions
passed**. V8 cases passed after alignment, but the concurrent voice cohort
remains unqualified: focused3 failed the ordinary negotiation twice, and
focused4 passed the ordinary case but failed the delayed case on its first
attempt before passing its retry. The existing policy correctly rejects that
retry pass as flaky (receipt `d8207ed2…`). Both cases passed individually on
their first attempts, in 1.930 and 7.699 seconds; these isolated checks do not
prove concurrent robustness. The ordinary isolated run's reporter incorrectly
rejected its singular summary; its raw test output and exit code record the
pass, and the later diagnostic parser accepts singular summaries. A temporary
failure-context diagnostic confirmed `tcp=false` in both negotiation cases;
all modified source bytes and modes were restored. A later bounded snapshot
after the delayed case timed out showed both peers still in ICE `Checking`,
with DTLS `Unspecified` and no selected candidate pair (receipt `68e223a0…`).
That locates the observed stall before DTLS/channel establishment, without
proving the cause or absence of STUN traffic. An earlier snapshot diagnostic
failed compilation because it used an unavailable JSON dependency; no tests
ran, and its source was also restored. A controlled experiment bound both peers
to loopback and passed **134 tests on their first attempts in 18.813 seconds**,
including ordinary negotiation in 1.271 seconds and delayed negotiation in
7.362 seconds (receipt `13f083d0…`). Its two expected ignored cases were retained,
and original source bytes and modes were restored before recording the result.
This is diagnostic evidence, not a workspace or installed-app qualification.

## Loopback fixture successor

The accepted successor now adds a private shared bind-address constructor and
uses loopback only for the negotiation fixture. Production retains the original
IPv4/IPv6 wildcard defaults. Candidate admission, packet loss, TCP delay,
ordered-channel/audio assertions and deadlines are unchanged. The original
seven source hashes are preserved; the successor freeze is `76426402…` and
cumulative patch is `4d0b7a5a…`. Formatting passed with unchanged source. Workspace
compilation finished in **64 minutes 57 seconds**, but that run was intentionally
stopped during test discovery to apply the large-edit fix below. Its exit **143**,
unchanged source/SDK and empty test summary are preserved; no workspace test pass
is claimed. Existing receipts keep their original source
identity. None of these prerequisite checks qualifies an installed app or live
harness task.

## Large-call compaction successor

The same-model local benchmark exposed an independent compaction defect: valid
code-writing calls of **8,511 and 8,767 bytes** executed, then failed the old
**1 KiB per-call limit**. The accepted fix preserves exact completed calls under
the existing **24 KiB canonical** and **12 KiB provider-input** aggregate budgets
and the final context-fit check. It adds cross-provider/recompaction coverage and
a native file-write regression with an append-only execution marker, exact
call/result retention and one history replacement. Its source freeze is
`c2fa89bd…`, with cumulative patch `bef22018…`; that patch rewrites three existing
sections rather than claiming append-only lineage. Both new regressions passed
on their first attempt: the unit case in **0.017 seconds** and the real native
write/compaction case in **1.264 seconds**. The affected-package run as a whole
failed: **4,709 passed, 10 failed, 28 skipped**, exit **100**, with unchanged
source and SDK. Five failures passed only on retry and remain failures under the
qualification policy.

The CLI and MCP readiness failures used helper executables from the preceding
workspace build; selecting only the affected packages did not rebuild those
helpers. Their older dependency fingerprints are verified, but this does not
prove the timeout cause. The successor fixture asserts successful feature
setup rather than ignoring its result. Its freeze is `171d62f5…`, with patch
`c0e566f9…`; production compaction code is unchanged. Formatting passed with
unchanged source. The verifier now uses the actual Rust unit-test namespace,
rejects inherited helper-path overrides and disables automatic retries.
Full-workspace tests, scoped lint, packaging, native and installed live checks
remain pending. Individual regression passes do not qualify the failed suite.

## Full access and frontend/adapter component checks

The access-policy audit found that build39's **Full access** selection only
automatically approved requests while retaining the workspace sandbox. The
candidate now binds the persisted native selection to each submission and
explicitly sends the corresponding engine sandbox and approval policy on every
turn. This also restores Ask restrictions when continuing an already-loaded
chat after Full access. Engine permissions instructions now describe that
actual policy. Native action approval changes immediately; an active turn or
command retains its execution policy until stopped. Transport, native-state
and real-engine permission-boundary checks are pending for this candidate.
The frontend type check, **123 frontend tests** and production frontend build
passed on 2026-10-09. The generated client contains the final access explanation
and persisted-choice wording. `frontend-full-access-build41-validation1.json`
records those actual commands and resource hashes observed afterward; it does
not claim a before/after source freeze or native/installed qualification.

The three provider-adapter suites also passed together on 2026-10-09:
**364 tests and 6,321 assertions**, zero failures, in **25.55 seconds**.
`embedded-provider-adapters-build41-independent1-receipt.json` records the
actual command and unchanged hashes for all nine exercised JS/TS files and
the Bun executable. These fixtures exercise synthetic DOM and model-selection
behavior; they do not qualify live website responses or installed resources.

## Release runtime scope

V8 belongs to upstream's separate code-mode host, not Computa's built-in browser.
Our release script selects only `codex-app-server`; its code-mode dependency is
the host client and has no dependency path to the V8 runtime. Installed build39
contains no code-mode host. Complete upstream workspace validation builds and
tests that host independently of the release packaging. Computa's browser
continues to use WebKit.

## MLX failure classification

The local-model comparison exposed a separate failure-classification defect:
reasoning-only or blank output below the generation budget was labeled
`max_output_tokens`. The Responses boundary now distinguishes that case with
the fixed `missing_generated_public_output` diagnostic. Genuine token
exhaustion stays incomplete, and a validated tool-only reply stays executable
only after EOF. The diagnostic contains bounded counters and a fixed reason;
it does not include generated reasoning or reply contents.

The complete offline MLX suite passed **107 tests in 2.252 seconds** on
2026-10-09. `mlx-missing-output-build41-tests1-receipt.json` records the actual
command, output-log hash and unchanged Python inputs. These protocol checks
are separate from the Swift input freeze and installed-app qualification.

## Interrupted browser-fixture closure observations

Interrupted flight-fixture observations remain separate from task cleanup.
The earlier server's PID and socket were absent without a recorded closure
event. The first build 41 server journal recorded `server_closed` at
**2026-10-09 01:33:24 UTC**, and its PID/socket were later verified absent.
That records closure, but does not attribute it to a qualified cleanup action;
neither interrupted fixture establishes a passing live browser task.

## Controlled copied-AppServer diagnostic (build 41)

The one direct invocation of `turn_start_shell_zsh_fork_executes_command_v2` on 2026-10-09 failed (native exit **101**, **12.47 seconds**): it sent `initialize`, reached the unchanged **10-second** deadline, received no initialization response and issued no thread-start request; it did not skip. The read-only observer retained the fresh copied AppServer FD **4.55 seconds** after outer launch and read its contents only after test termination and verified root-PGID disappearance. The **488,703,488-byte** copy matched the prepared canonical SHA `1434d0ef…2444` and embedded CDHash `9a03c644…9e3e`, with no CMS wrapper or xattr names; post-analysis FD metadata remained stable. Original executable identities remained unchanged; originals were not wholly rehashed after the trial. `copied-appserver-direct-fixture-build41-trial1/receipt.json` (`5dec7163…b91d`) and its log (`9e467668…18de`) record diagnostic completion (wrapper exit **0**), zero signals, absence of captured processes/root PGID/temporary directory, and restored temporary entries. Unobserved descendants in other groups are not proven absent. This controlled environment differs from the original Nextest environment, and both qualification flags remain false. Byte/signature equality does not establish the assessment cause, signing necessity, or a cold-copy fix.

## Source 14 startup and fixture checkpoint

At **2026-10-09 21:42 UTC**, the full App Server phase `direct-staging-postcargo-serial1` is still running. Its Source 14 freeze is `223230542985781a09aeab54b73361f7fc442596657925bbedbdd4bff04219d3`; the public patch SHA is `401a0d7b0677a3f0be67a260f6fa48f46712bf3881f24da2e0291ae741a561a9`. Ordinary formatting passed with changes confined to `turn_start_zsh_fork.rs`. The fixture uses hard links on the same filesystem and the original copy/permissions behavior on `EXDEV`; other hard-link errors fail. Two new Rust controls and exact completion/staging evidence are required, while the four original assertions and deadlines remain intact. This is test-only staging of prepared canonical executable identities, not a cold-copy or production security-policy fix.

The post-Cargo three-helper setup passed in **44.686 seconds**, retaining exact before/after identities and removing its owned groups/root. The phase subsequently reported `daybreak_access_respects_plugin_provenance::api_key_direct_call` as **FAIL** at case **628/1,705**, in **11.007 seconds**. App Server initialization and `thread/start` succeeded; the local `sample` MCP helper remained `starting` until the existing **10-second** outer request deadline. No entitlement assertion was reached. The following installed-plugin case passed in **8.236 seconds**. The helper is canonical `target/ci-test/test_stdio_server`, omitted from the current startup plan; its MCP initializer has a separate 30-second budget. All eight reviewed test/launcher/manager source files match the prior Source 13 receipt, whose API-key case passed in **1.732 seconds**. The prior compiled helper identity was not bound, so binary equality across these runs is not established.

The read-only diagnostic `test-stdio-readiness-diagnostic-build41-1.json` has SHA `bb8a7391bbbf535de5fcc0973c717f108012169d6e7504377431d5ee3f9a0e62`. Its after-failure helper is **12,118,640 bytes**, inode **32740406**, SHA `83bea9a2537ad45a6c392e597367f4c5abb9fcf71713e7d5d2bab6a90ecce6f7`. An exact-image security-log query recorded AMFI events at **17:37:34.764 local** and an ASP event naming PID **86209** at **17:37:44.743**. That final event overlaps the deadline teardown; it does not establish a permanent denial or assessment cause. Missing helper INFO stderr also does not prove pre-main execution. No test/helper launch, process signal, signing change or security change occurred in this diagnostic. A new fourth-helper ordinary readiness preparation is being designed; it has no execution or qualification evidence yet. Source 14, packaging, installation and push remain unqualified/pending.

The Source 14 phase then completed naturally: **1,705 tests run, 1,704 passed (four slow), one failed and one platform skip**, in **1,474.775 seconds**, child exit **100** and wrapper exit **1**. Its terminal receipt `source-bound-build41-app-server-direct-staging-postcargo-serial1-receipt.json` has SHA `3a21627f1f3d3e4ab0ca172c5958b4ced11b7c6ee5a4dc5cf7fa15ca973eb378`; log SHA is `0829b283c91469b48d10a96c7d27675f8648725b3ba09bc8bf914dcf79fcb9fb`. The failure is `phase_exit_nonzero`, and qualification remains false. Source/tools/SDK and temporary-root identities were unchanged. The four real zsh cases 1673–1676 passed in **2.810/2.705/0.486/12.699 seconds**, with four correct completion markers and eight hard-link records matching App Server inode **32740398** and zsh inode **28841467**. Both staging controls passed in **0.016/0.015 seconds**. Stable identities, signatures and original final link counts were retained; only the declared App Server/zsh ctime exception applied. Exact-image holder queries returned no holders, all post-phase utilities were reaped/groups gone, and no interruption or utility-cleanup error occurred. Nextest repeats successful and failed headings in final captured output; the actual counts come from the unique summary and first results before it.

The frozen v4 helper adds unchanged canonical `test_stdio_server` as a fourth ordinary startup trial. It requires correlated MCP initialize and tool-list replies, the intervening initialized notification, and clean EOF exit zero. Only this helper receives **six seconds** of EOF grace for rmcp's five-second drain, within the unchanged aggregate **30-second** cleanup budget. All test, readiness and Nextest setup deadlines stay unchanged, with zero per-test retries. Its complete inode/device/owner/mode/mtime/ctime/nlink/whole-SHA/signature identity must remain equal through the phase; no additional hard-link exception applies. The helper/runner SHAs are `25339b4e7039a21cc6b4c48844be8c574d332afa26219b447864bf919fc45fa8` and `ace52fef09140dafbf191f9a6bb27a69236bb20bd99475200c2e6179a8b4fd19`. All **24 offline controls** passed, including an independent root run in **0.008 seconds**; these are synthetic protocol/parser/cleanup checks, not native startup qualification. The application receipt SHA is `6a632e49a4a18d62dd5fa5ed583ef91ecb6b5180ff17db768ed3a9b7cba361f1`.

A fresh actual App Server phase `mcp-ready-direct-staging-app-server-serial1` began at **2026-10-09 21:55:46.709 UTC**, child PID **19926**, with **four test workers** (root still serializes all Cargo phases). Its frozen plan SHA is `44eacc6c7f4fa24a5c3eeca82bd23221167994bd198583fabe7146c3e33832b1`. Root independently verified all **31 App Server / 29 core-net / 31 workspace** input bindings and private-config parity; the two future plans remain unlaunched. Actual v4 startup and suite results are pending. Prepared-helper behavior does not qualify the first cold launch or resolve a production security-policy cause, and no failed earlier run is relabeled as a pass.

The actual v4 setup subsequently passed in **44.759 seconds**. App Server/CLI-exec-server/exec-server/MCP readiness took **3.057/3.618/0.995/0.264 seconds**. MCP initialize and tool listing completed, then EOF produced exit zero without a signal; all four owned groups were gone and the private root was removed. The exact four-helper and zsh identities and input bindings remained unchanged before/after startup. The receipt still declares test/packaging/cold-start qualification false: it prepares these same canonical images for the running suite. The fresh full-suite result remains pending.

The v4 startup receipt SHA is `56762177838af4c5a77604601dc79b60f975c5160dfac90d2133335bfc5a47c1`, bound to Nextest run `96fefc12-2469-4833-b590-f78994def9a8`. The previous MCP API-key case then passed in **0.395 seconds**. As of **22:03:33 UTC**, the fresh suite had **1,207 passes and two failures**, with its full result still pending. Both failures are `code_mode_model_output_uses_structured_host_timing::{exec_stdio,wait_stdio}`, at **10.346/10.306 seconds**, awaiting a `codex.code_mode.host_timing` log event; the same cases passed in **0.817/0.658 seconds** in the serial Source 14 run. The gRPC shared/exec/wait cases passed in **26.013/26.124/18.022 seconds**, but their fixture awaits the host URL before starting the timed App Server operation. This difference does not establish a transport defect or four-worker contention.

The separate lazily started canonical image is `target/ci-test/codex-code-mode-host`, **217,732,936 bytes**, inode **32978322**, SHA `e0d4f161b4ba975b86807bf6e706cef4ad39d5465dc66c9ad20b7dbb571dc19c`. Its stdio handshake permits **30 seconds**, while the test JSON-log capture permits **10 seconds**; gRPC URL readiness permits **60 seconds** on macOS. All nine relevant fixture/capture/session/connection/install-context/telemetry/handler/main source files match the completed Source 14 receipt, but that earlier compiled host's identity/cache state was not retained. The `9,944/9,943 ms` tool-handler records are emitted from `ToolCallTimingGuard::Drop`, including cancellation, so they do not establish completed host execution. No per-stage spawn/handshake/session/cell breadcrumbs were retained, and a missing timing event cannot distinguish those boundaries.

The read-only diagnostic `code-mode-host-readiness-diagnostic-build41-1.json` has SHA `9f1d5c0e5e07e8e8aeac116f4fec6582539d9c18711680f067069f3460626fbd`. It preserves both failed segments, prior first-result rows, current unchanged image metadata/hash, and four exact-image security-log events. It lacks live case-to-PID ancestry and establishes no security-policy cause. No helper/test launch, process signal, signing/security change or source/timeout change occurred in the diagnostic. A new private preparation of this fifth canonical host's ordinary length-prefixed stdio `connection/hello` → `connection/ready` exchange is being designed, with frame-boundary EOF and owned clean shutdown. It has no execution evidence yet; all full-suite and product qualification remains pending.

## Source 14 four-worker terminal result and assertion diagnosis

The v4 phase completed naturally at **2026-10-09 22:06:45.272 UTC**: **1,705
tests run, 1,701 passed (four slow), four failed and one platform skip**, in
**633.572 seconds**, child exit **100** and wrapper exit **1**. Terminal receipt
SHA is `826845572d8c862b3bc25a089959c72cbfd541530854d744b29bf508e2de9b6c`;
log SHA is `58c6dafc29ba31b5edc2107e1ed860352a1f08b10465611f396a7c32f4c649b9`.
Source/tools/SDK and temporary-root identities remained equal before/after.
The phase's owned root child and post-phase utility groups were gone; there
was no interruption or utility-cleanup error. Qualification remains false.
The reporting guard failed on the missing fourth zsh success marker; its final
prepared-identity flag was not set, so that absent flag is not a success claim.

Besides the two code-mode timing failures above, the realtime accepted-steering
fixture failed in **5.218 seconds** and the zsh subcommand-cancel fixture failed
in **9.095 seconds**, reporting Failed where Declined was required. The other
three real zsh cases passed in **3.065/2.966/3.356 seconds**, and both staging
controls passed in **0.030/0.024 seconds**. Counts use the first results before
the unique summary, rather than repeated final captured-output headings.

The realtime timeline retains both exact speech fragments, separated by the
initial `Start work` user item. `turn/started` intentionally precedes startup
prewarm, while the reducer seals speech on user-item start or completion. The
fixture therefore needs an exact initial-user `item/completed` barrier before
sending speech, under its existing deadline. No production persistence defect
is established. Exact transcript, ordering, pagination and reopen assertions
remain required.

The zsh fixture sends Cancel, documented as denial plus interruption. Its active
parent suppresses the subcommand's synthetic Declined event; the independent
exit watcher later emits a canonical Failed parent without cancellation
provenance. The previous **12.699-second PASS** accepted an inherited timeout
fallback with an Interrupted turn but no observed parent Declined completion.
It did not establish equivalent cancellation-status coverage. The planned fix
retains the cancellation cause for canonical parent terminalization and tightens
the fixture to require both item and turn completion plus actual file effects.
Normal uncancelled exit 1 must remain Failed, and replay must retain the same
parent status. These diagnoses do not attribute either failure to worker count
or a security assessment. No fresh source, package or installed qualification
has completed yet.

## Source 15 cancellation ownership and realtime synchronization

The Source 15 freeze is `d69de0466ace48b80408f00ecb86fc373c51f6a4d6f82e6df4534a6c59992868`.
Its cumulative public patch is **290,289 bytes**, SHA
`3f97801ddd93ef34e04dabdd2da3fa4a4ff31025b1aca3f48c8b63afdf53a096`;
the pin SHA is `f9ff0a29e8a7038652713a6a9c905085fffa7c91e90dd8f38ca2e95a8a8794f0`.
The complete **8,104-file** inventory has SHA
`04575730f852c81f5873250d3cf441731ffb154d5de1bcf3228a55f79d5351b4`.
Compared with the retained SDK producer, exactly **22 existing Rust paths**
changed and **two modules** were added with intent-to-add. Filtering those two
empty-blob index entries retains the original index byte hash. All **27 native
SDK inputs** remained unchanged; the native SDK was not rebuilt.

Cancellation uses a private coordinator for each intercepted shell owner.
The exact UUID approval takes the active turn before waking cancellation;
abort settlement awaits the canonical completion outside the turn locks.
Only the winning completion claim owns its acknowledgement guard. Early
approval dispatch waits for the parent watcher to be installed, or for closed
startup, while the existing startup grace and sandbox classification remain.
Cancellation requests termination without immediately aborting PTY readers or
the transcript producer. Existing bounded drain/network/interaction settlement
precedes forced closure and the canonical Declined snapshot. An ordinary exit
one remains Failed. The strict real zsh fixture requires Declined before the
Interrupted turn, actual file effects, paginated history and replay equality;
the old timeout fallback has been removed.

Independent source review found no remaining actionable findings. The coherent
cancellation stage spans **17 paths, 771 changed lines before formatting**
(**428 production lines**); the independent realtime stage changes only its
fixture. That fixture awaits the exact initial user identity/content before
sending speech, under one unchanged timeout. Its later ordering, steering,
promotion, pagination and reopen assertions remain intact. Synthetic gate and
watcher regressions do not themselves prove real PTY reaping, failing-spawn UI
dispatch, remote cancellation or panic handling; integration results are still
required. No public API/model instruction, signing, security, retry or deadline
was changed by either stage.

Ordinary `just fmt` passed at **22:35:27.943 UTC**, with changes confined to the
reviewed paths and the old index retained. Its receipt SHA is
`605c80447825d2d053a15df72271fcc284cf3f2179539f03dd349d4df9410c9e`.
The fifth-helper ordinary code-mode stdio preparation passed **34 offline
controls**. The runner's fresh first-PASS guards require all **nine cancellation
regressions** as well as the prior compaction/fork/staging and realtime cases;
its narrow extension passed **seven additional offline controls**, independently
repeated by root. The published startup-helper and runner SHAs are
`f0e091f210f470018704e7ed8d15567d47a142d2aaa9b324961e05f920854c43`
and `c3d0ad7f5e106f7eeace802e6a2066d9106d42ae3b659ad95f23be8bc52c9c49`.
These controls launch no native helper and qualify no product behavior.

Before rebuilding, root removed six obsolete, owned core-dependent test
executables whose relinking is required. Exact file identities/hashes, empty
holder queries and the Cargo lock were checked. Libraries, fingerprints,
dependency metadata, five canonical images and evidence were retained.
The cleanup reclaimed **3,154,059,264 allocated bytes** and raised free external
space to **4,370,112,512 bytes**; receipt SHA is
`e632cbe65e73a04d9eabd44f16bb891d74bbfb9163ef6d5bea3b2cfddc718b03`.
The original Codex process remained alive. Fresh affected suites, full workspace,
scoped lint, ordinary release packaging, native tests and installed provider
tasks remain pending; build 41 is not installed or pushed.

The first compile-only preparation used upstream `just test --no-run`, which
Nextest rejected because the recipe supplies `--no-fail-fast`. It exited **2**
before Cargo compilation; source and temporary-root identities stayed equal.
That failed invocation and its receipt remain preserved. A fresh adapter uses
Nextest's `list --list-type binaries-only --message-format json` with the same
locked workspace/features/profile/target/compiler environment to prepare fresh
images. It does not execute test cases or replace the later upstream `just test`
suites. Its terminal compile result remains pending at this checkpoint.

During linking, free external space dropped below **600 MB**. Root verified all
**61 regular files** and permissions in each obsolete staged build **35–38**
against its existing preserved backup; proof SHA is
`22678e488f410d3895b67b9ed5637c1ae3fa7ab85bf7a167cd7656dae860a415`.
After two empty holder checks per stage and unchanged exact identities, only
those four duplicated stages were removed. Their backups, installed39, public
pin/patch and original Codex remained unchanged; no target/cache was deleted.
The removed files account for **1,020,669,952 allocated bytes**. Observed free
space rose from **769,228,800** to **1,793,712,128 bytes**, while compilation was
active; the free-space delta is not attributed solely to deletion. Cleanup
receipt SHA is `8ba1aa045cc3eb8ea15edf554f04b2c55d4e2030bc58b735782bb67b4272422d`.
Preserved backups supply recovery without new archive disk consumption.

The fresh compile graph subsequently completed: Cargo finished its unoptimized
`ci-test` profile in **33 minutes 40 seconds**, and Nextest produced complete
binary metadata for **275 binaries**. The compile child exited **0**. The adapter
then exited **1** during artifact collection because it looked for
`codex-exec-server`; the real canonical filename is `exec-server`. This wrapper
failure remains recorded and is separate from the successful compiler result.
A fresh read-only terminal collection corrected the filename without replaying
compilation or tests; source, tools, watched files and SDK state matched the
original pre-build state. Its receipt SHA is
`20c76d5d122ac01be62f92ae611c42fa270d5045561743b3e1e0127463898a9c`;
the compile log SHA is
`dcc0190663b3952f731380344038b414ce40e90e50d9ba9917e5ec96e7cba26b`.

The five canonical startup images are now bound: App Server **488,930,192 bytes**
(`c4f05b00…085f`), CLI **619,537,144** (`d00c133f…b8ab`), Exec Server
**144,454,400** (`4ce38575…3788`), MCP fixture **12,118,640**
(`83bea9a2…ce6f7`), and code-mode host **217,732,936** (`e0d4f161…dc19c`).
Full hashes are retained in the terminal collection. Compilation and image
collection execute no test cases and qualify no installed product behavior.
Fresh startup plans and suites remain required.

The fresh Source15 AppServer phase then used immutable V6 plans with all five
compiled helper hashes, four workers and zero retries. Nextest run
`e763c8e3-173c-4a3f-aaaa-60725fbdec85` discovered **1,705 tests across six
binaries**, with one platform test skipped. The actual startup check passed in
**187.916 seconds**; its receipt elapsed time is **187.844 seconds**, SHA
`ee5318fb1a2988e2fd8c0fa9f59334a643aa2c7a59a6e39e397109882ef0d402`.
All five ordinary readiness interactions succeeded, and all owned startup
process groups and the private startup root were removed without cleanup
errors. The AppServer, MCP fixture and framed code-mode host exited **0** after
stdin closure; the two loopback Exec Server listeners received their planned
owned **SIGTERM** cleanup. Code-mode stdout/stderr drained at EOF. This startup
receipt qualifies warm preparation only; its test, packaging and cold-start
qualification flags remain false. The AppServer suite is running and its
terminal result remains pending. Core/network, full workspace, scoped lint,
ordinary release, native tests, installation and fresh provider tasks are still
required.

The Source15 AppServer phase subsequently finished with **1,705 tests run:
1,701 passed (four slow), four failed and one platform skip**, in **815.855
seconds**, native child exit **100** and wrapper exit **1**. The two formerly
failing stdio host-timing cases passed in **1.266/0.772 seconds**, the promoted
realtime-history case in **1.410**, and compacted-fork instructions in **1.354**.
Both deterministic staging controls passed. All four real packaged zsh cases
failed at initialization in **10.246/10.749/13.661/13.456 seconds**, with exact
AppServer source/destination inode **33210783** and zsh inode **28841467** in
all eight hard-link records. No mocked model request was received, and no
command, approval or cancellation assertion was reached. The input-send log
precedes the actual write/newline/flush; it does not prove child receipt.

The startup check's canonical AppServer reply took **40.358 seconds**, so its
success under the separate preparation budget did not establish ten-second
packaged-fixture startup. A distinct terminal-verification error also occurred:
the private guard's **30-second** whole-file/signature budget expired after
four of the five images, before the remaining identity/holder checks. Its
utilities were reaped with all owned groups gone and no cleanup errors. Source,
tools and SDK before/after states remained equal, but final image validation
and fixture qualification are incomplete. The immutable failed receipt SHA is
`a2478f0dd42cc007fe6083a4b6f812d163949f376edc4004eb036a72f4bf165f`;
log SHA is `4bbf78f8591248eba57dbbd4939e6787fddd58fa56ee60c39628be03b0d11891`.
The source/runtime behavior and the startup/verification diagnostics remain
separate; no cold-launch, packaging, installed or provider success is claimed.

The private verification runner was subsequently corrected and independently
reviewed. It now gives whole-file/signature/holder verification **120 seconds**
for the five images totaling **1,482,773,312 bytes**, while retaining a separate
cumulative **30-second** cleanup reserve. The ordinary **240-second** startup
budget, **300 + 15-second** setup limit, original test deadlines and zero retries
are unchanged. Child exit and Nextest summaries are recorded before verification;
partial verification, changed bytes/signatures, holders, interruption or
unconfirmed cleanup cannot qualify a phase, even when its test child exits zero.
All **48 offline controls** passed, including both successful and failed test
children followed by verification failure; the root rerun passed in **0.037
seconds**. The new private helper/runner were frozen under acceptance receipt
SHA `59ce60ab4629e56c8979bb3307014b527a0a50cf915d86cfc4120d9024e4ce7f`.
This acceptance covers the private evidence checks only. The failed Source15
phase and its original receipts remain unchanged. At that checkpoint, the
corrected native phase had not yet run.

A fresh cleanup audit identified ten orphaned `test_stdio_server` fixtures from
the five owned AppServer phases. Each microsecond process birth was within its
phase window, with UID 501, PPID 1, a single-member process group/session, the
exact fixture executable vnode and a deleted cwd under the unchanged private
`Computa41Temp` parent. The deleted cwd directories were **0755**; their private
parent was **0700**. Historical image digests were available for six processes;
the four older processes were attributed by executable vnode, private cwd and
phase window, without claiming a historical digest or individual test name.
The root revalidated every identity immediately before targeted **SIGTERM**.
All ten original processes and groups were gone after **1.509 seconds**, with
no SIGKILL, no unknown fixture holders and unchanged protected Codex runtime
births. Cleanup receipt SHA is
`9f4760b404df1e58eec87dcac4891e1cff4bfe19c55935430b78063c9d65eef4`.
An earlier timeout-wrapper error stopped before any action; its failed receipt
SHA `5476d023f69a1aa08967e496451614552b9a1cb6ac484d133954a398e9ef4a59`
remains preserved. This cleanup is separate from test qualification.

A narrow source audit explains the two-per-phase pattern: the optional batched
and direct variants of `selected_plugin_mcp_startup_respects_explicit_mentions`
leave the test MCP initialization barrier closed, complete their existing
model/tool assertions, then kill the executor. The fixture's initialize handler
waits for that absent file before reaching normal EOF handling, and abrupt
executor death bypasses its shutdown handlers. Process timing supports this
attribution, without establishing an individual PID-to-test mapping. Normal
session/MCP shutdown cancellation and owned process cleanup are present in the
source; cleanup after forcibly killing an executor is not thereby proven. The
Source15 inputs remain unchanged; owned fixture cleanup stays a separate gate.

The subsequent initialize-only diagnostic is **partial**. Its packaged alias
completed the exact fixture initialize request and initialized acknowledgment
in **2.680 seconds**, with the receiver trace observed, no provider connections
and clean EOF exit **0**. The one-second passive sample captured Rust main and
Tokio startup, but symbol processing produced more than the private **64 KiB**
stream limit. The bounded prefix was retained, the owned sampler was terminated
and reaped, and the diagnostic stopped before the canonical control. Its
wrapper exited **1** for the collection bound; no full comparison or native
qualification is claimed. All six owned utility/backend/sampler groups and the
private root were gone; AppServer/zsh bytes, signatures and restored link counts
were verified, with the declared hardlink ctime changes retained separately.
Receipt SHA is
`12990ae380d0f018ac4aa4655080c05db99d8554d80baa0a953ec4502e4ab224`.
The successful alias handshake does not establish the cause of the earlier
four suite failures or cold startup under load.

The corrected runner was then used for the fresh original-policy run
`source15-postverify120-appserver-4workers1`, Nextest ID
`af5f364b-8b6a-4a63-a261-2046dcfa3618`. Compilation finished in **6.78 seconds**,
but the five-helper setup failed in **246.090 seconds**, before any of the
**1,705 selected tests** executed. Canonical AppServer initialization took
**78.759 seconds**, the CLI Exec Server listener **87.195**, standalone Exec
Server **17.300**, and MCP initialize/tool-list **1.517**. Those four interactions
succeeded; the unchanged cumulative **240-second** readiness budget expired
during the fifth, framed code-mode-host interaction. No host ready frame was
received. Owned cleanup took **6.139 seconds**; all owned groups and the private
root were removed with no cleanup errors. The setup receipt SHA is
`ab95392b68b91e9b47a12b20e7b86e40935d2a65d8cfa0118c4414d7ea6b3947`.

The native child exited **105** and the wrapper **1**. The wrapper retained
the child outcome separately, then rejected the missing setup PASS; the new
120-second post-phase verifier was not reached. Terminal receipt SHA is
`276913a2f7adab04ebec7e66afe85eb82591a1029e2c8103d433763b6347b8b9`.
This is a failed startup preparation with zero executed tests, rather than a
new result for the four packaged-shell assertions. No deadlines or test retries
were changed. At that checkpoint, the controlled canonical/alias startup
comparison remained pending; the complete AppServer, core/workspace, native
and installed provider qualifications remain pending.

### Source 15 obsolete executable cleanup and completed initialize comparison

The exact obsolete-executable cleanup removed **10 stale test executables**,
recovering **1,174,347,776 allocated bytes (1.094 GiB)** while protecting **280
current binaries**. All ten exact paths were absent afterward; canonical
binary identities and public source identities were unchanged. The cleanup
receipt `source15-obsolete-extra-test-executable-cleanup-receipt1.json` has SHA
`ef5d8d4368867d6f08062c272d34a9ae9f527f8850a5a06a25a68e41e8e23605`.
This cleanup supplies no test or packaging qualification.

The third initialize-only diagnostic completed both exact fixture
`initialize`/`initialized` exchanges within the original **10-second** request
deadline: **canonical first, 2.699582 seconds; packaged hard-link alias second,
0.167700 seconds**. Receiver traces were observed in both attempts. Their
samplers retained **181,401 / 279,272 bytes**, respectively, with Rust
`codex_app_server::main` and Tokio frames. Both backends closed through clean
EOF with exit **0**; all **eight** owned children exited zero, were reaped and
had their process groups removed, without signals. The private root was
removed, cleanup had no errors and no unexpected provider connection was
observed. Receipt `source15-alias-initialize-diagnostic-build41-3/initialize-diagnostic-receipt.json`
has SHA `fbc197aededa4874379a0c094d268a74a8a93ceea40b7cb0dc8c266279086caf`.

This diagnostic matched the fixture environment, including inherited `HOME`,
which differs from the minimal helper preparation environment. Fixed launch
order, prelaunch verification reads, trace logging and sampling prevent a
causal conclusion from the timing difference or a cold-start qualification.
It does not qualify the four complete packaged-shell fixtures, the suite or
the product. The earlier partial diagnostic and v7 setup failure remain
separate failed/incomplete evidence; complete AppServer, core/workspace,
native, packaging and installed provider qualification remain pending.

The subsequent actual four-fixture diagnostic used the unpruned **275-binary**
metadata, without compilation, canonical-inode publication or private warm
setup. It retained the original Nextest configuration: **four workers, zero
retries and 10-second initialization deadlines**. Nextest run
`bbe9b430-6b6b-465a-9e78-bc99202bcfc8` completed in **18.051 seconds**: **four
tests run, zero passed, four failed; 1,702 filtered out**. Every fixture logged
an `initialize` write attempt, without an observed reply; the client logs
before `write_all`/newline/flush, so this does not prove completed flush or
receiver delivery. No command/cancellation assertion was reached, no mocked
POST was received and no completion marker was produced.
The child and wrapper both exited **100**, and terminal session **37707**
closed. Source 15, the 27 SDK inputs, public pin/patch, all 275 binary metadata
records and the three protected process identities remained unchanged. The
manual post-run process check found no owned packaged-AppServer match; it
does not establish disappearance of every possible descendant. Receipt
`source15-four-fixture-diagnostic-build41-1/diagnostic-receipt1.json` has SHA
`c1ea35542b6448350d0064c32804a03037749cd56ae47e7f3d8a8ad26712a3d1`.
This reproduces the initialization failure without private warm setup or
Cargo republication, but does not establish its cause. The unresolved
difference is between the actual Nextest fixture and the successful standalone
initialize diagnostic; suite and product qualification remain pending.

The next actual diagnostic retained zero retries and the original **10-second**
initialization deadline while running only
`turn_start_shell_zsh_fork_executes_command_v2` with **one worker**. Nextest run
`0766c031-54e4-4883-a1fc-f5addb4d569e` completed in **13.507 seconds**: **one
test run, zero passed, one failed; 1,705 filtered out**, child exit **100**.
Initialization again timed out after a logged write attempt; there is no
completed-flush or receiver-delivery evidence from this fixture. The passive
observer failed before observing the target, recording a blank
`AssertionError` and `RuntimeError:owned app-server child not observed`;
**no target environment or sampler evidence was captured**. The phase exited
naturally without signals and its root was reaped/group gone. Bound source,
binary and protected-process identities remained unchanged. Receipt
`source15-single-fixture-startup-diagnostic-build41-1/diagnostic-receipt1.json`
has SHA `b9595591fed5bb9a09da730ab22904b1f542ebb4d4ca24a2161f5f0f11348b2c`.
This excludes four-worker concurrency as the sole explanation; it identifies
no loader, transport or other startup cause. All qualification remains pending.

The second single-fixture diagnostic then reported an actual **PASS**:
**one test run, one passed; 1,705 filtered out**, in **10.242 seconds**, Nextest
child exit **0**, with the expected
`turn_start_shell_zsh_fork_executes_command_v2` completion marker. The wrapper
still exited **1** and recorded `diagnostic_failed`: its observer assertion
at `controller.py:172` expected an executable path inside the temporary alias
root, but `proc_pidpath` returned the exact canonical AppServer image. The
recorded candidate had inode **33505773**, link count **2** and owned fixture
ancestry. This is an observer path-assumption failure, separate from the
actual fixture result; no target environment or sampler evidence was captured.
The phase output reached EOF, its root was reaped/group gone and no phase
signal was sent. Bound source/binary and protected-process identities remained
unchanged. Receipt
`source15-single-fixture-startup-diagnostic-build41-2/diagnostic-receipt1.json`
has SHA `14c0c93f95f03b508aaa557f803982575ce474472ffefed9a9c278030d247350`.
The earlier single-fixture and four-fixture failures remain preserved. This
pass identifies no startup cause or product fix and does not supply full-suite,
packaging, native or installed provider qualification.

The third single-fixture diagnostic returned to an actual **FAIL**: **one test
run, zero passed, one failed; 1,705 filtered out**, in **13.857 seconds**, Nextest
child exit **100**, at the unchanged **10-second** initialize deadline. The
corrected observer matched the owned target and captured its selected environment
keys, including a populated Nextest `DYLD_FALLBACK_LIBRARY_PATH`,
`RUST_MIN_STACK=8388608` and `RUST_LOG=warn`; it recorded no observer errors.
The sampler produced no stack body (**0 bytes** stdout; **83 bytes** stderr,
only its sampling notice). After the fixture ended, the independently owned
sampler did not complete within its **two-second** graceful EOF reserve and was
terminated with guarded `SIGTERM`: exit **-15**, drained EOF, root reaped and
group gone. The fixture phase itself reached EOF, was reaped/group gone and
received no signal. The wrapper exited **1** with `diagnostic_failed` because
the sampler did not finish cleanly. Bound source/binary and protected-process
identities remained unchanged. Receipt
`source15-single-fixture-startup-diagnostic-build41-3/diagnostic-receipt1.json`
has SHA `0dd6048ca14cf0842b6c0bc3a6a3c7230cba154f3134bea913442ca8acd84f20`.
The captured environment does not establish a loader or startup cause, and the
sampling perturbation prevents a causal conclusion. Prior passes and failures
remain preserved; all suite, packaging and product qualification remains pending.

The second **nonsampled four-fixture** recheck then reported **four tests run,
zero passed, four failed; 1,702 filtered out**, in **17.665 seconds**; session
**94947** closed with child/wrapper exit **100**. Two tests took **14.205 seconds**
and two took **17.652 seconds**. It retained the original **four workers**,
**zero retries**, original Nextest config, full **275-entry** binary metadata
and **10-second** initialize deadline, with no private warm setup. Logs again
show initialize write attempts without a completed flush or receiver proof;
the approval fixtures recorded **zero mocked POSTs**, and there were no
completion markers. The receipt's before/after assertions confirmed unchanged
bound source/binary and protected-process identities. Root's subsequent scoped
process query found no matches for the canonical or temporary-alias AppServer
paths (query exit **1**); this is not proof that every descendant was absent.
Receipt `source15-four-fixture-diagnostic-build41-2/diagnostic-receipt1.json`
has SHA `e6873870eeedb8632ce22048ce15b77f98d60558d8fe6a998329f3b1e3aa45e3`.
This recheck reproduces the four-fixture failure without sampling, but establishes
no startup cause or fix and leaves all qualification pending.

Root's subsequent **ABBA loader-environment experiment** completed in session
**23299**, exit **0**. Four fresh alias launches initialized within the original
**10-second** deadline: **A1 2.643994417 seconds**, **B1 0.221529625 seconds**,
**B2 2.419091542 seconds** and **A2 0.144182125 seconds**, measured through the
flushed `initialized` notification. A retained the captured
`DYLD_FALLBACK_LIBRARY_PATH`; B removed only that key. Selected environments
otherwise matched, apart from the declared fresh `CODEX_HOME`, `ZDOTDIR` and
managed-config paths. No tracing, sampling or canonical prewarming was used.
All four children exited **0** with drained EOF, root reaped/group gone and no
signals; provider-guard connections were **0**, cleanup errors were empty and
the owned root was removed. Bound source/binary and protected-process identities
remained unchanged. Receipt
`source15-loader-environment-experiment-build41-1/experiment-receipt1.json`
has SHA `3c339021a8197949651913f9b8f40f399f4f40d8f18f4ef8fe4c0c45ff714803`.
Both conditions passed, so this experiment establishes no startup cause or fix,
first-request reliability, full-fixture or suite qualification. All experiment
qualification flags remain false, and prior actual four-fixture failures remain
preserved.

Root then removed only the verified corrected build-39 staging duplicate,
`/Volumes/t7/computa-provider-qualification-2026-10-06/Computa-0.6.0-harness-build39-corrected.app`,
in session **89589**, exit **0**. Fresh audit 2 verified the **77-entry,
61-file** payload and stat/xattr snapshots against retained installed39; the
known root-only `com.apple.macl` difference remained explicitly recorded.
The candidate was an ordinary root on device **16777240**, inode **28585027**;
its exact-path holder check returned `lsof` exit **1** with empty stdout/stderr.
The retained installed39 full snapshot was exactly unchanged before/after,
as were the three protected processes and public pin/patch inputs; no signals
were sent. The original build-39 and build-40 staging apps, installed39,
opaque rollback backup, core SDK and 275-binary graph were outside removal scope.
Staging allocation was **255,336,448 bytes**; observed T7 free space changed
from **1,659,150,336** to **1,907,470,336 bytes** while core tests were ongoing,
so this is not an exclusive physical-reclaim measurement. Audit 2 SHA is
`9eac714c12f4b1a9d8e97e1af96393e087187c62b9084a2f3faaae82ce5d2df2`;
`corrected-build39-duplicate-cleanup1.json` has SHA
`2db9daa6fa1bc3ea0444f5331f30c3bb858ae0848da925246f4a7ee93f526552`.
Only this bounded cleanup is qualified; no native, provider or goal completion
claim follows from it. The core phase was still live at cleanup time.

The ordinary **core/network phase** subsequently finished: **4,728 tests run,
4,705 passed, 23 failed, 28 skipped**, in **863.902 seconds**. Session **88213**
closed with wrapper exit **1**; Nextest child exit was **100**. The phase used
the original config, **four workers** and **zero retries**, without a private
startup plan or warmer. Its receipt status is `failed`, with test and packaging
qualification false (`phase_exit_nonzero`). Three async-watcher tests failed
the trailing empty-queue assertion at `core/src/unified_exec/async_watcher_tests.rs:161`,
which ignores the intentional legacy `ExecCommandEnd` event:

- `exit_watcher_user_cancel_during_drain_marks_parent_declined`
- `exit_watcher_uncancelled_exit_one_remains_failed`
- `exit_watcher_user_cancel_preserves_transcript_and_completes_once`

That legacy-event test oracle has not yet been fixed. **Eight of the eleven
required regressions passed**: all six execution-completion tests and both
code-write compaction tests. The three watcher failures remain separate from
the other **20 observed failure points**:

- **Eight CLI tests:** the existing **30-second** `run_cli_command` process
  timeout (log lines 2794–2948).
- **Four CodeMode tests:** the generic `next_event` event-wait timeout at
  `core/tests/common/lib.rs:388` (log lines 3070–3148).
- **Six StreamableHTTP MCP tests:** the existing **five-second** OAuth-metadata
  readiness deadline (log lines 4332–4434).
- **One Bedrock test:** a request missing the expected `Authorization` header
  (log lines 2963–2987).
- **One cold-resume test:** `thread not found` (log lines 3880–3894).

These reviewed failure points do not establish a common cause; their underlying
causes remain unresolved. Receipt
`source-bound-build41-core-cancellation-realtime-core-ordinary-4workers1-receipt.json`
has SHA `55c9988256f4a9a1cdbaceba4e65863a9468138cbdc1ff6d31ad2fccb54c2044`.
All earlier receipts and failures remain preserved, and native/provider/goal
qualification does not follow from the 4,705 individual passes.

The frozen fourth single-fixture observer attempt stopped at preflight with
`canonical baseline changed` and `nativeLaunched=false`; no fixture result was
produced. Its preserved receipt SHA is
`9cfb9263f40a410313f8a0ff97d138fc1054a3a92d00a65308ec08c96a79018a`.
Root then audited a content-preserving canonical metadata refresh: AppServer
inode **33505773 → 33542377**, with unchanged SHA
`c4f05b006b7a943e3f81014738ea0f43d71f2c4aa557b42247bc2d3196d8085f`
and only the inode field changed; fixture metadata was unchanged. Audit
`source15-canonical-metadata-rebind-build41-5-root-audit.json` has SHA
`2fefaa09d739621a58a861780c5d41602650ca4c220ddf5da70d62d80827ef33`.
This refresh identifies no cause of the inode change or startup failure.

The fifth observer attempt then ran the original single fixture with **one
worker**, **zero retries** and its **10-second** initialize deadline: **one
test run, zero passed, one failed; 1,705 filtered out**, in **14.576 seconds**.
Root session **86320** and the native child ended **100**; no initialize response
or completion marker was observed. There were no observer errors, sampler or
signals; phase EOF, root reaping and group disappearance were recorded, with
bound source/binary and protected-process identities unchanged. Its read-only
stdin-pipe observer made **41 queries**, **40 available** and **38 positive**.
It found **220 queued bytes** from **01:53:49.050412** through the last available
query at **01:53:58.628248 UTC**. The two initial zero queues are ambiguous; the
final query was unavailable after target exit. Positive observations establish
unread kernel data, without exposing contents or proving an exact initialize
frame, completed Rust flush, parsing, startup stage or root cause. Receipt
`source15-single-fixture-startup-diagnostic-build41-5/diagnostic-receipt1.json`
has SHA `3b78bf966b4b58429ec7a4dd681e17fed23628b1800e4be3cd0b2259fd0791c3`.
This remains an actual initialization failure, with all qualification false;
neither the observer nor metadata refresh is a startup fix.

The isolated **Source15 StreamableHTTP MCP plain** diagnostic subsequently
passed its one selected test: **4.284 seconds** for the test, **4.317 seconds**
for the summary, **one passed; 4,461 filtered out**. Root session **97050** closed
**0**. Strict skip-environment/placement preflight passed, with no early-skip
markers, adverse outcomes or retries; the existing **five-second** readiness
deadline and **one worker** were retained, with no private warm setup. The
existing echo, environment, `TurnComplete`, mock-verification and shutdown
assertions were reached. Source/binary and protected-process identities remained
unchanged within this diagnostic. Receipt
`source15-mcp-plain-diagnostic-build41-1/diagnostic-receipt1.json` has SHA
`e00909eb0b3990d0c7ae77edc66871c9ceb72100ae0c6392d0167094c02c1d1c`.
All qualification flags remain false: this isolated pass neither resolves the
six full-run MCP failures nor identifies a shared startup cause, and proves no
API/provider first-request behavior. The Source16 one-file mirror correction
was applied only after the MCP diagnostic ended; Source16 validation remains
pending. This Source15 binary diagnostic cannot be reused with Source16 bindings.

Source16 then corrected only
`codex-rs/core/src/unified_exec/async_watcher_tests.rs`. The three cancellation
tests retain the actual modern `ItemCompleted` event, assert its envelope/turn
and call IDs, derive its single complete `ExecCommandEnd` compatibility event,
and require that exact event after the existing completion barrier. All original
ordering, status, transcript/stdout, process ID, exit-code, closed-producer and
consumed-owner assertions remain; the final queue must still be empty. This
corrects the test oracle without changing production behavior, retries or
deadlines. Independent source review found no weakened duplicate/output check.

Root session **4478** completed ordinary `just fmt` with exit **0**. Only the
reviewed test file differs from Source15; the staged index, intent-add flags,
other source files and all **27** native SDK inputs are preserved. SDK source
lineage remains **22 changed and two added paths**, with no SDK rebuild. The
complete cumulative public patch is **291,728 bytes**, SHA
`b8bf63821665c5a7ed3c2ab873559da466f036fed19f0bb45eea1f1f29b5ebd1`;
the pin changes only its patch SHA. Source16 freeze
`engine-transcript-build41-source-freeze-legacy-mirror1.json` has SHA
`52bdd32e9dd22e5d845b8f1badd4ad1abb2feb2c764e2b3a6b2ff7d7a9f34964`.
Immutable originals remain under `legacy-mirror-source16-build41-applied1`;
its preservation receipt SHA is
`b5e8261b3c4fa46aca288357bb9c231da37d5274c3056ace20b42c6e62f1dac0`,
format receipt SHA is
`5cc659f5b7685d112a8e3bcf94a8e80c621d36ca1e344d7276970e6a0107b6c9`,
and freeze receipt SHA is
`3394a3cdffc64b4256cc7999a2df21e846439ee67f5cb0960ccbcf600b87cc7a`.
At that checkpoint, fresh compilation, affected tests and broader validation
remained required; review/format/freeze established no test, packaging, installed
or provider pass.

Source16 subsequently completed ordinary compilation: Cargo reported the
finished `ci-test` profile in **3 minutes 9 seconds**, and the actual log contains
the complete **275-binary** metadata. Native compile exit **0** is a control-flow
inference: the frozen adapter reaches image collection only after child success.
The original wrapper separately exited **1** because collection looked for the
obsolete `codex-exec-server` filename instead of `exec-server`. Root's read-only
collector session **87051** closed **0**, recovered that completed graph and
bound the actual five helper images without recompiling or running tests.
`source16-ordinary-graph-build41-compile1-terminal-collection1.json` has SHA
`a497fe18b2b620132d3d2432287a3da6d1d86f1c65e763b4a40ba6e3811b7c68`;
`source16-ordinary-graph-build41-binaries1.json` has SHA
`c0973136b75d03b62daff0c602c774d1cfdad919403a31112e6d249cb09b35ab`;
the original compile-log SHA is
`c03139b0475f546bff66fc25456b40ee3f6a078884fbda6aa7097c00f4a7e975`.
The original wrapper failure remains preserved separately from native success.

The actual Source16 focused run subsequently passed **11/11 selected core
regressions in 6.350 seconds**. Root session **60305** and its native child exited
**0**; Nextest run ID was `decefc8b-7d98-4f40-9a2d-272d0c7cfd07`. The full
log and receipt establish eleven unique first PASS rows, rather than counting
repeated final-output rows. Both code-edit compaction tests and all six
completion-order regressions passed. The three formerly failing watcher tests
now passed with their corrected legacy-mirror oracle:

- `exit_watcher_user_cancel_during_drain_marks_parent_declined`: **1.750 seconds**.
- `exit_watcher_uncancelled_exit_one_remains_failed`: **1.750 seconds**.
- `exit_watcher_user_cancel_preserves_transcript_and_completes_once`: **1.851 seconds**.

Original deadlines, **four workers** and **zero retries** were retained; no
private warm setup, selected skip, early-skip marker or adverse/retry outcome
was recorded. The summary's **4,451 skipped** tests were outside the selected
cohort. Bound source/binary and protected-process identities remained unchanged
within this diagnostic. Receipt
`source16-eleven-core-regressions-build41-template2/diagnostic-receipt1.json`
has SHA `894c1639b91a1313f6579f3242103e5e8c1f256a3d05aafba9c57acb25779fbb`;
its full-log SHA is
`26bb6b7168df9164bd33cd7974b9b049f5ef2548c940fc5871bda7a35a0403d2`.
`actualFocusedRegressionsPass` is true, while general test/full-suite, packaging,
provider, cold-start and first-request qualification flags remain false. The
prior **20** integrated core failures remain unresolved. No installed build 41,
provider, packaging, push or goal-completion qualification follows from this
focused pass; all older outcomes remain preserved.

The bound Source16 sixth single-fixture observer subsequently finished with
**one FAIL in 12.486 seconds**, native and root session **93758** exit **100**;
**1,705** other App Server tests were filtered out. Of **41** guarded fd0 pipe
observations, **39** reported a positive **220-byte** queue. This proves queued
input delivery and a length match only: it does not verify exact initialize
contents, read completion, protocol parsing, progress or a startup cause.
Thread-list flavor 6 returned **8 bytes** with a zero address on every query. The
validity guard therefore retained all recognized-name counts as null and their
presence as **unavailable**, without an absence inference or a name-info query.
There were no observer errors, sampler, interruption or phase signals. The
owned root was reaped and its group was gone; all bound source/binary and
protected-process identities remained unchanged. Receipt
`source16-single-fixture-startup-diagnostic-build41-6/diagnostic-receipt1.json`
has SHA `9b0a86528d653860424d641f11b424e83e12493a20eaec01951e03bc146c2737`.
This preserves the initialization failure and supplies no production-stage,
root-cause or fix claim; every qualification flag remains false.

The next Source16 diagnostic selected exactly the **20 remaining unique first
FAIL rows** from the prior Source15 core/network run, excluding only the three
watcher oracle failures covered by the eleven-test run. Root session **22494**
and native child exited **100** after **95.142 seconds**: **20 tests run, nine
passed, eleven failed**, with **4,442** unrelated tests filtered out. These
counts come from the unique first-result section and summary, not repeated
final-output headings.

| Selected group | Passed | Failed |
| --- | ---: | ---: |
| CLI stream | 1 | 7 |
| Code mode | 3 | 1 |
| HTTP-MCP | 3 | 3 |
| Bedrock command-auth/custom headers | 1 | 0 |
| Cold-root resume/identity restoration | 1 | 0 |

The remaining code-mode failure is `code_mode_can_call_hidden_dynamic_tools`.
The three HTTP-MCP failures are
`streamable_http_configured_auth_precedes_chatgpt_auth`,
`streamable_http_tool_call_round_trip::authorization_helper_refreshes_rejected_tool_call`
and `streamable_http_tool_call_round_trip::headers_helper`. Among CLI tests,
only `responses_mode_stream_cli` passed. The other passes were the three
remaining code-mode cases, HTTP-MCP plain, header-helper rejection refresh and
OAuth round trips, `amazon_bedrock_proxy_uses_command_auth_and_custom_headers`,
and `cold_root_resume_restores_agent_identity_and_role_on_followup`.

The actual Source16 full **275-binary** metadata, SDK overlays and original configuration
were retained, with **four workers**, **zero retries** and unchanged fixture and
Nextest deadlines. No selected skip, early-skip marker, retry/leak outcome,
private warm setup or source change was recorded. Bound source/binary and
protected-process identities remained unchanged. Receipt
`source16-twenty-prior-core-failures-build41-1/diagnostic-receipt1.json`
has SHA `897e4976c89bd9f69d2e4e7a794edcce9020b6c2e14841f6dba966346f5622bc`;
its full-log SHA is
`ddb61a941c94fd013a7a6dd87d81042a639ea55f3b4e2fba285f916ff0e72dc1`.
`actualFocusedRegressionsPass` is false, as are all broader qualification flags.
The prior full-run failures remain preserved; nine passes in this selected run
neither erase those outcomes nor establish a shared cause or production fix.
Full core/workspace, package, provider and installed qualification remain
pending; build 41 has not been installed or pushed.

Observer7 then completed the same packaged-zsh fixture with **one PASS in 6.012
seconds** (summary **6.032 seconds**, **1,705** filtered out), root session
**34637** and native exit **0**, within the unchanged **ten-second** initialize
boundary. The private kernel-ID lookup was actually supported: **17 of 18**
queries completed, with the final vanished-target query unavailable. The first
twelve complete queries reported one thread and no recognized names; subsequent
queries first observed `codex-main` and Tokio names at **02:35:10.455 UTC**, then
`app-server-stdin` at **02:35:10.710 UTC**. The fd0 queue changed from **220 bytes
to zero**. These momentary observations narrow the delay before the first
recognized `codex-main` name without identifying loader versus early `arg0`
work, proving consumption/parsing or establishing a production cause or fix.
Bound input/protected identities stayed unchanged; no observation errors,
interruption or phase signals occurred, and the owned root was reaped/group gone.
`source16-single-fixture-startup-diagnostic-build41-7/diagnostic-receipt1.json`
has SHA `91950fd784557c3310d235081de47f6a084a183df502407bee62084db42d77ff`.
All broader qualification flags remain false. The prior failures and the focused run's
**eleven failures** remain unresolved; build 41 remains uninstalled and unpushed.

Guarded cleanup removed only the exact owned `work/wasm-tools-target` build cache.
The bound inventory held **395.879 MiB** allocated across **1,797 entries**;
fresh approved metadata equality and an empty successful holder query preceded
removal. All three retained `work/wasm-tools/bin` CLI hashes and metadata stayed
identical. Free space increased **360.688 MiB** during concurrent filesystem
activity, a separate measurement from the removed inventory.
`wasm-tools-target-cache-cleanup-proposal1/cleanup1.json` has SHA
`31a174994bc0d4ab7ae9e52c7b5e1e9adb13ec70cc5a3a6690591835d9b40aeb`.
Cleanup alone is qualified; native/provider/goal qualification remains false.

Observer8's exact-owned one-second sample recorded **87 main-thread samples at
`_dyld_start+0`**, a **112K** footprint and no binary-image descriptions. Its
**966-byte** report matched the guarded PID, parent and launch-time header;
report SHA is `707af100931a145aaaeaa2f07d00495dc46c4bfc3f2c79660882ccf7ae79eea7`.
This is evidence at dyld entry during that window, without identifying a loader
policy, path-related cause or fix. Attachment remains non-atomic and sampling
can suspend or perturb the target. The sampler exited **0**, was reaped/group
gone, and the selected fixture passed in **5.104 seconds** (summary **5.116**),
root session **50049** exit **0**. Inputs/protected identities stayed unchanged
and no phase signals occurred. Receipt SHA is
`1e71cff4501f3684f69a3efd016448449708e88a8c691d09cefea61d89dab33c`.

The isolated one-worker `exec_cli_applies_model_instructions_file` rerun also
passed in **8.583 seconds** (summary **8.619**), exit **0**, with original
configuration/deadlines and zero retries. Inputs/protected identities stayed
unchanged; receipt SHA is
`e57602862ecd8d1127ea5b64f14837b39243679318a63cfe1f5814ab07146a0e`.
These single-test passes preserve the earlier four-worker **nine PASS/eleven
FAIL** result and do not establish its cause or qualify the full suite. Build
41 remains uninstalled and unpushed; broader qualification remains false.

A subsequent one-worker rerun of the same twenty selected tests produced
**20 unique first PASS outcomes** and a **75.802-second** summary, root session
**50551** exit **0**, with **4,442** unrelated tests filtered out. Source16,
original deadlines and zero retries were retained; input hashes, five-image
metadata and protected identities stayed unchanged. Image SHA evidence reused
the immediately preceding isolated CLI receipt: `nativeImageWholeRehashUsed`
was **false**, so this was not fresh whole-byte verification. Receipt SHA is
`0b44bd81cc5b80b9f3b2935bf024ebced6b58cdbc8a5f334c1933c59b1e031fb`.
The earlier four-worker **nine PASS/eleven FAIL** result remains preserved;
this serial contrast identifies no production fix or shared cause.

The direct `--version` matrix then completed **all ten** owned launches with
exact positive replies and natural exit **0**, root session **71013**. First
stdout was observed after **2.4097 seconds** for canonical serial, **0.0167**
for alias serial, **0.0091–0.0140** for canonical four-child and
**0.0069–0.0122** for alias four-child launches. Later canonical launches were
also fast. Fixed order, cache warming and non-atomic liveness checks prevent
an alias-fix, AMFI-cause or cold-start conclusion. All children were reaped,
owned groups were gone and the temporary root was removed; source/native
metadata and protected identities stayed unchanged, with no errors or signals.
Receipt SHA is
`f65204b765e2cc3d668f14a595bd5d418f14c4ded2a66fb33b8a5dff537428ff`.
This checks the existing version boundary, not initialize/model execution.
Broader qualification remains false; build 41 remains uninstalled and unpushed.

## Additional flight answer check: private version 2

The unchanged collector's **103-test** result remains separate from the additional private final-answer checker. Independent review found that version 1 crashed on lone-surrogate Unicode text; preserved version 2 returns a manual-review reason for invalid UTF-8 instead. Its actual offline run passed **8 methods covering 55 input cases**, with zero failures/errors/skips; an independent root rerun passed the eight methods in **0.011 seconds**. Direct and JSON-loaded high/low surrogates require review, while valid non-BMP text remains supported. Ten contradictory or misassociated answers that passed the old surface matcher now require review, and the bound prior answer still passes the added surface check. All 15 protected original/version-1 inputs retained their hashes.

Version 2 candidate SHA is `659dd29ec4d1554908412d5adffad21317ed830c817402925616fc7c56eeb18e`; tests SHA is `18087944a9cd1cc5d4f4144a2b3737cee1b6ca58c74d185b4a6453556a848baf`; `flight-final-answer-check-build41-2/validation-receipt.json` has SHA `db5824f339a58146fe92d0b2b3d5cf8cb16d7aff5da364cc82032d852b131d84`. Manual association review remains required for every answer; semantic/product/live qualification flags remain false. This checker changes no product code, prompt, fixture or collector, and proves no browser actions, model selection or cleanup.

## Source16 full workspace run: in-progress checkpoint

The serial full-workspace run remains live in root session **44246**. Its
starting header selected **19,035 tests across 275 binaries**, with **56
declared skips**; a final summary and pass total are pending. The original
deadlines and zero retries remain in place. Five observed first failures are
preserved at setup/initialization in
`source16-full-workspace-serial-build41-1/validation.log`:

- Analytics: `remote_unified_plugin_script_emits_measurement_analytics` and
  `remote_unified_background_plugin_script_emits_measurements_after_turn_completion`.
- Thread list: `thread_list_relation_filters_read_spawn_graph_from_state_db`
  and `thread_list_relation_filters_reject_invalid_requests`.
- Zsh: `turn_start_shell_zsh_fork_exec_approval_cancel_v2`.

The reviewed `source16-full-workspace-guard-audit-manifest1.json` separates
**22 conditional remote-only guard sites** from the 56 declared skips. It
binds 23 selected editing/terminal functions and four exact post-assertion zsh
markers. Effective inherited safety/environment values were not captured at
the original start; current values cannot establish their earlier absence.
The final successful-output guard and marker audit remains pending. The two
analytics failures are retained as failures, rather than local-environment
exclusions.

Isolated analytics, thread-list and zsh-cancel diagnostics have been prepared
and source-reviewed, but have not executed. They require the sealed terminal
full-run receipt/log and retain one worker, zero retries and the original
deadlines. These are fixed-order follow-ups with warmed images; later outcomes
must preserve the original first failures and cannot establish cold startup
or a causal fix.

Owned space recovery is recorded separately in
`closed-build-artifact-relocation-build41-receipt2.json` (four closed roots),
`closed-stage-shader-relocation-build41-receipt1.json`,
`closed-stage-shader-clone-build41-receipt1.json` (APFS clone), and
`closed-stage-worker-directory-relocation-build41-receipt1.json` (the whole old
worker stage). Bytes, modes, modification times and attributes were preserved,
with original paths retained through links and all three protected process
identities unchanged. The first partial copy failed only the payload's
`Applications` symlink timestamp check, before any original rename. Strict
repair and verified owned-partial cleanup remain recorded in
`closed-build-artifact-relocation-partial-copy-cleanup1.json`; the failed first
receipt is retained. These receipts are private BENCH evidence under
`work/harness-robustness-build35` in the qualification workspace.

Free space is not a fixed readiness guarantee: the CLI four-image fixture can
occupy about **2.478 GB** internally in roughly 619 MB copies. Source16 and all
27 native SDK inputs remain unchanged. Build 41 has not been installed or
pushed; this checkpoint remains at repository HEAD `a406…` with draft
[PR #5](https://github.com/ahmed-ela/computa/pull/5) open. Full-suite, packaging,
installed, provider and goal qualification remain pending.

## Source16 full workspace run: subsequent evidence checkpoint

The native full suite is still live in root session **44246**, last observed
at **6,678 of 19,035** first outcomes. Seven first failures are preserved;
the two additions to the preceding checkpoint are
`packaged_daemon_start_and_explicit_replacement` (ordinal **2,807**, explicit
`No space left on device (os error 28)`) and
`remote_exec_server_gracefully_stops_when_parent_stdin_closes` (ordinal
**2,832**, 30-second rendezvous deadline before shutdown assertions).
There is no terminal summary, final native exit code or full-suite pass claim.

Separately, the synthetic provider-adapter run completed with **364 PASS,
zero FAIL and 6,321 assertions in 32.76 seconds**, root session **1891** exit
**0**. All 13 input hashes and three protected identities stayed unchanged;
evidence is `source16-current-provider-adapters-build41-1/receipt.json`.
This exercises synthetic adapters and does not qualify live providers.

The five isolated diagnostics remain prepared and unexecuted. Immutable
versions 1 and 2 are retained; version 3 corrects duplicate final-output
headers, singular summary wording, unrelated filtered SKIP rows and permitted
SLOW progress. Its actual extracted-parser/oracle controls passed **113
tests**, with zero failures/errors/skips and unchanged watched inputs
(`source16-isolated-parser-controls-build41-3-attempt2/receipt.json`). The
separate post-terminal guard/count collector passed **26 synthetic controls**
and remains unexecuted against the live suite. These checks change no native
fixture, deadline, retry policy, runtime, Source16 input or native SDK input.

Additional owned space work is recorded in
`closed-historical-shader-clones-build41-receipt1.json`: three historical
roots retained payload/source bytes, modes, mtimes and attributes; original
links and protected identities stayed unchanged. External free space was
observed at **784,044,032 →
1,075,331,072 bytes**. The whole four-entry old native9B stage was preserved
with an original-path link in
`closed-native9b-stage-relocation-build41-receipt1.json`. Its current scoped
quiescence proof is separate from historically unknown cleanup. Internal free
space was observed at **2,665,754,624 → 2,876,620,800 bytes**, and external
space at **1,065,775,104 → 842,657,792 bytes**. These are shared-disk
observations, not exclusive attribution or a continuing readiness guarantee.
The future packaged diagnostic's approximately **3.55 GB** internal reserve
has not been established. Build 41 remains uninstalled and unpushed; full
native, package, installed, provider and goal qualification remain pending.

## October 10 version and collector checks

The source version check reports **0.6.0 (41)**. Its version-contract run
passed **9 tests, 56 assertions, zero failures**, with all 17 bound inputs and
protected process identities unchanged and its owned temporary fixtures removed.
Receipt `version-contract-build41-1/receipt.json` has SHA
`d926b1bb0c3bb2c0763c860778b450570a7ffb17f7952266458a58cc67181591`.
This does not establish packaged or installed version identity.

The shared provider benchmark's four pure-data regression methods passed in
**0.022 seconds**, with watched inputs unchanged and no live fixtures created.
They cover the actual reviewed atime, TTY inspection/ordered-drain, final-fact
and cleanup-proof defects. Receipt
`provider-benchmark-data-regressions-build41-1/receipt.json` has SHA
`7fbbac49f6004a59505a738bcf8a5a534d593062c2af38877a7365ebbd4fa6e6`.
These are collector checks, not provider, model or installed-app qualification.

At the earlier October 10 checkpoint, the same full-workspace handle **44246**
was still active at **13,165/19,035**, with **17 original FAIL outcomes** and no
final summary. That checkpoint did not count the two TIMEOUT outcomes.
In addition to the earlier seven, these include remote-environment shutdown,
parallel-shell duration, two copied exec-server startup cases, two Git fsmonitor
cases, macOS user-agent format, permission-fixture layout and two seatbelt
parameter-order checks. Original failures remain retained. The reviewed
post-terminal diagnostics retain original deadlines and zero retries.

Two test-only corrections are proposed outside the watched source: the
user-agent regex must accept the exact compiled alpha version, and a workspace
boundary fixture must reside outside the temporary directory that both input
profiles explicitly allow writing. Neither correction has been applied or
tested; permission expectations have not been relaxed. Seatbelt parameter
ordering is under source review. No build-41 package, installation, live provider
qualification or PR push has occurred.

## Source16 full workspace: sealed terminal result and storage failure

Handle **44246** ended naturally with exit **100**, after **7,252.182 seconds**.
The original run selected all **19,035 tests across 275 binaries**, with one
worker, zero retries and unchanged deadlines. Its summary is **17,370 passed,
1,663 failed, two timed out and 56 skipped**. The sealed receipt SHA is
`5a04011fb505c402fb27e1511769c96461151d104f9f1acb7665d31f7f482a6d`;
the sealed log SHA is
`56ac13c221319e3433496267fdc34899112d609e97840e8960e684727a47561a`.
No controller interruption or phase signal occurred. Native metadata, watched
inputs and the three protected process identities remained unchanged.

At ordinal **14,179**, a test reported SQLite disk I/O errors in the controlled
test directory. Later tests explicitly reported `StorageFull` and `ENOSPC`;
the observed T7 free space had fallen to **33,533,952 bytes**. A signature-only
review of original failure output found **1,632 outcomes with ENOSPC text**,
eight with SQLite disk I/O text, one version-snapshot difference and 24 requiring
further review. These signatures do not prove every cause and do not turn any
original outcome into a pass. The earlier two add-directory tests timed out
before the large disk-error group and still need separate diagnosis.

Two closed historical artifact trees were preserved back on the internal disk.
Both original workspace and historical T7 paths still resolve to their verified
copies. Bytes, mode, modification time and extended attributes were checked;
the protected processes were unchanged. Recovery receipt SHA
`6276762b2c106078a711e61e89d26e530ab38d74d2a5cc1f877d07364a47e584`
records **669,306,880 bytes** free on T7 afterward. This does not erase the
preceding failures or establish the later packaging capacity gate.

The original `sourceUnchanged=false` remains preserved. The only difference
between the sealed source inventories is one generated **546-byte `.snap.new`**;
tracked files, HEAD, index and the cumulative patch are unchanged. The artifact
audit SHA is `d46dcde4c9fc8ef76c261509f5fc8559d7ee270d40d0def174bc9323c33f4cdb`.
It does not replace a fresh complete source check after artifact preservation.
Four test-only corrections are reviewed but unapplied: exact alpha-version
user-agent matching, a workspace fixture outside the inherited TMPDIR write
grant, stale Seatbelt exclusion indices and a stable replay-snapshot version.
Security and replay assertions remain intact; none has a changed-source native
test result yet.

The first count collector rejected legitimate one-MiB protocol payloads whose
envelopes exceed its one-MiB line cap. Its failed output remains retained.
Successor 2 retains a finite two-MiB cap and counts failures separately from
timeouts. **31 pure parser controls passed**, and collection of the same sealed
negative native result succeeded. Count audit SHA
`38e768333edbe7a7f3e18b002fe486d6734dfd1acaceba65b391cab59bc3382d`
matches the original result totals without qualifying the run. The controls and
collection receipt SHA is
`2bba3101c93afea440b58186a3c137c1802cf6d65affeaf47f441ddc6b38ad7f`.
Build 41 remains unpackaged, uninstalled and unpushed; installed provider and
goal-mode qualification remain pending.

The subsequent whole-temp archive attempt stopped at its internal-disk reserve
before verification or fixture cleanup. Receipt SHA
`085d56c8377d05e49c2f7711f982ce3f252ea893ae867905e71a2d2291cefbd4`
records `archiveVerified=false`, `cleanupStarted=false` and zero removed fixture
children. Its complete 148,564-entry manifest remains sealed. Only the unusable
859,109,846-byte partial gzip was removed after checking its exact identity,
byte hash, absence of holders and exclusion from the 300 keeper identities;
removal receipt SHA is
`3eaa74893b9fb9acda27d78358fba207f712672dcc0d64c939d36162da81343c`.
The original temporary data and negative native result remain intact. A new
archive destination and successful verification are required before cleanup or
the pending source-restoration and diagnostic runs.

The next archive completed and independently verified all 148,564 entries before
removing 8,888 temporary top-level children. The 1,079,951,112-byte archive and
sealed manifest remain preserved on T7; receipt SHA is
`9b8dc1c741cd696c95b280ceee94384bfb0c633a124974ae4f448d8a7ae3af9e`.
The 300 keeper identities and protected processes were unchanged. T7 had
3,236,651,008 bytes free afterward. The original negative suite result is retained.

The generated snapshot was separately archived and verified before its exact
original was removed. The complete current source inventory now matches the
original frozen inventory; restoration receipt SHA is
`71b1688915f0d093e9bf09e6fab466a9b9f822aa39f219d7b4c1fab4a68d635f`.
This does not change the original `sourceUnchanged=false` result.

Both unchanged cursor tests reproduced their failures in a fresh isolated run
(0 passed, two failed, 2.467 seconds). That run captured inherited and effective
`NO_COLOR=1` and `TERM=dumb`, with no environment overrides; parity with the
original full-run environment is not proven. Source, inputs, native metadata and
protected processes remained unchanged. Receipt SHA is
`da0201cab2c3f3492d8e50887b3e516d1cb7fa5b3741b740345dd432837439bc`.
The proposed test-only color correction still requires changed-source validation.

The task-owned Cargo source namespace was subsequently copied and fully verified
on T7 before its internal original was removed. The original namespace path
continues to resolve through an alias. Receipt SHA is
`d6176e7dd34d0338310f301c9383478c40857e7dfbc927285f263fb4f8881e72`;
source inputs, keeper metadata and protected processes were unchanged.

The two closed grounding payloads were then verified back onto T7, preserving
their historical path chains. Receipt SHA is
`ce8dadb34bf54bf516160990c5c9ba3cb53cc7c05f077bbcb1c8a1956c5cfe84`.
The initial download-cleanup controller stopped with zero removals because its
second holder check detected its own directory descriptor. A controlled open-
versus-closed descriptor check reproduced that behavior. The successor closes
that descriptor before checking for holders, then reopens and verifies the exact
directory identity before any journaled deletion. It removed exactly 1,123
regenerable downloads (179,646,464 allocated bytes), retained V8's archive and
preserved the unpacked sources and guarded inputs. Successful cleanup receipt
SHA is `a3f35797a489c029a2e28844e481e89ef5d6ada35f04463e7113899091223f3f`.
Internal free space reached 3,622,367,232 bytes, clearing the separately checked
packaged-fixture minimum. This is a launch-space observation, not a native test
pass or a guarantee of the entire later suite's capacity.

The eleven focused diagnostic runs then closed naturally with unchanged source,
SDK inputs, native metadata and protected process identities. They selected 17
tests: **11 passed and six failed**. Add-directory, terminal interaction, remote
plugin analytics, thread-list initialization, remote environment spawning and
shell parallelism passed. The packaged daemon replacement also passed in
119.588 seconds. Combined with the separate two failing cursor checks, this is
**11 passes and eight failures across 19 selected tests**, not a clean full-suite
qualification.

The six failures remain before their intended behavioral assertions. The Zsh
case did not complete initialization; Wiremock teardown masked the primary
error. Remote execution timed out waiting for TCP rendezvous. Both Git cases
returned `None` from a helper that combines spawn, wait and timeout failures.
Both exec-server cases spawned a copied test executable but received no listener
URL within the original ten-second deadline. These results do not establish a
shared cause or a cancellation, shutdown or Git configuration regression. The
next comparison will change only the controlled temporary directory for the Git
and exec-server fixtures; original assertions and deadlines stay intact.

The subsequent five-leaf generated-cache cleanup stopped before any deletion
because two orphaned task-owned `test_stdio_server` processes were still live.
Its receipt records `completed=false`, zero removed files, unchanged source and
unchanged protected processes. The helpers need separately verified retirement
before cleanup can continue. Build 41 remains uninstalled and unpushed.

Both helpers were traced to the original passing optional-plugin fixtures
(`optional_batched` and `optional_direct`). Each was blocked before initialization
on a fixture barrier whose parent directory had been removed. Neither configured
the server's exit-file mechanism, which also runs only after initialization.
Fresh UID, parent, birth time, executable and working-directory checks established
the two exact owned processes before SIGTERM retirement. Both disappeared;
the executable metadata and protected processes remained unchanged. No running
test or compiler was interrupted. The passing results remain recorded, while
this separate cleanup finding needs a fixture-teardown correction before the
next full suite.

The controlled internal-temporary-directory comparison completed: all four Git
and copied exec-server fixtures passed in 8.333 seconds. Source, native images,
SDK inputs and protected identities stayed unchanged; only effective `TMPDIR`
changed to a fresh owned directory under `/private/tmp`. Original assertions,
five- and ten-second startup deadlines, one worker and zero retries were kept.
Receipt SHA is
`f4f431a9444c9f7bfea1d4ce6d1fb59e645f42c04ba9a73f33ed2bcc9c9c8f23`.
This supports using an internal temporary directory in the next full-suite run.
The fixed-order follow-up does not distinguish warming, pathname and filesystem
effects, and does not rewrite the preceding failures or qualify the full suite.

After verified helper retirement, the fresh generated-cache cleanup completed.
It removed exactly the five reviewed older Cargo executable leaves (339,574,784
allocated bytes), preserving all 300 keeper, 281 current native and 27 SDK-input
identities. Source and protected processes stayed unchanged; the original
negative results and failed zero-removal cleanup receipt remain preserved.
T7 free space reached 2,156,556,288 bytes. This recovers build capacity without
qualifying a test or installed app.

The remaining Zsh cancellation and remote-server shutdown fixtures also passed
with internal temporary storage: two passes in 53.055 seconds. The cancellation
completion marker was present, and the remote case reached its stdin-close and
shutdown assertions. Receipt SHA is
`3a7f3433db27631c018b4c3c5b0ae9bb220b91c7503dbf83ddbf3916e1d25467`.
Source, inputs, native metadata and protected processes stayed unchanged; the
original deadlines and assertions were retained. No helper residue was found in
the shared target or either new temporary root after completion. This follow-up
also changed the Zsh fixture's cross-device staging from hardlink to copy, so it
does not isolate filesystem, pathname, staging and warming effects. Together,
these two runs provide six completed startup checks under the proposed internal
temporary-directory configuration, while the original failures remain retained.

### Source17 rendering correction

Source17 applies only the reviewed color-capture correction in the TUI test
backend: `CaptureBackend::new` explicitly enables color output. The two original
Cursor tests and their assertions remain unchanged. Ordinary formatting and
source preservation checks completed; the source freeze SHA is
`7605197be47a9033812fcef931b4924082a4333b77d644db36a2dcc5969462c3`.
Compilation completed with native and wrapper exit zero and all 275 binary
records. The fresh two-test comparison then passed both tests in 0.075 seconds,
retaining the previous `NO_COLOR=1`, `TERM=dumb`, T7 temporary directory, one
worker, zero retries and original deadline. Source, watched inputs, native
metadata and protected processes remained unchanged; no phase signals or
controller errors occurred. The receipt SHA is
`197304d945a7c95d10d0403d377e700e234d41b41c59ceb90d875c867c9904f0`.
The original negative pair remains preserved. This qualifies the focused
correction under the recorded environment; it does not qualify the full suite,
prove the original full run's environment, or establish cold-start behavior.

### Source18 reviewed test and fixture corrections

The five reviewed patches applied without errors: the macOS version assertion,
temporary-path permission fixture, Seatbelt exclusion-order assertions, TUI
replay version normalization and optional-MCP fixture teardown. They retain the
production code, original behavioral assertions and deadlines. The optional
MCP fixture now releases its artificial initialization barrier after semantic
assertions, waits for graceful owner shutdown and helper absence, then stops
the executor. This addresses fixture teardown; an ordinary product shutdown
defect has not been established.

Ordinary initial formatting and source/index/SDK preservation checks completed.
Source18 adds exactly five reviewed test paths, with 28 changed paths relative
to the SDK baseline and the same two added files. Its freeze SHA is
`d70b4dd32755080bd3662c3210391dd673c599058cbd1ccae771e7f26f564610`;
the cumulative public patch SHA is
`c279f54f869d6f83a2165022843bc0e74212d73b740ac6a64c6b403961dc5e58`.
Ordinary compilation completed with native and wrapper exit zero, unchanged
source/SDK state and the complete 275-binary graph. The collection receipt SHA
is `97df0d5790ec5794053c7577a2bbe6cf9ab6335304862d352a805a972698dd7c`.

The first affected run completed naturally with seven passes and six failures
in 150.920 seconds. The version, permission, Seatbelt, replay and Cursor cases
passed. All six MCP mention variants timed out at the initial app-server
`initialize` request, before their semantic or teardown assertions. Source,
watched inputs, native metadata, temporary-root identity and protected processes
remained unchanged; no helper processes remained. The negative receipt SHA is
`b168c5a09c71ba11ebe77451e941b00dff66eeb95f15d7ce8e3b3c83d1b3d2c8`.

A read-only sample of the owned app-server child during its deadline showed
only `_dyld_start +0`, with a 112 KiB footprint. Exact-process macOS policy logs
recorded execution assessment before entry into the application. Strict
signature verification passed, and a subsequent ordinary `--help` invocation
exited zero without changing the executable, signature or security settings.
These observations distinguish OS launch assessment from MCP behavior; they
do not prove a damaged signature, establish a cold-start fix or qualify the
MCP teardown assertions. The original failures remain preserved.

The subsequent affected run completed naturally with eleven passes and two
failures in 37.570 seconds. Four MCP mention variants passed. The two optional
variants completed app-server initialization and the turn, then failed the
original two-second helper PID-file readiness check, before the new teardown
assertions. All preservation checks passed and no owned helpers remained. The
receipt SHA is
`3ae328888a260b6c1cfbd6f26eea707095585c1322b88d18fafc360080d42bb8`.
The optional catalog grace omits pending tools without cancelling startup;
the helper writes its PID before its artificial initialization barrier.

macOS policy logs for the compiled `test_stdio_server` show assessment starting
at 03:57:03.083 and a Gatekeeper result at 03:57:08.696, overlapping the optional
cases. This is consistent with delayed native entry, but the missing exact
helper ancestry prevents attributing each failure to that assessment. No
assertion, deadline, executable signature or security policy was changed in
response. Full app-server coverage will exercise both optional fixtures with
their original deadlines. Full workspace coverage, release packaging, native
application checks and installed provider tasks remain pending.

Full Source18 discovery completed with exit zero and all preservation guards.
The actual listing contains 19,035 runnable and 56 excluded tests in 275
binaries across 133 packages. Four packages have no runnable tests; all their
binaries remain classified in the manifest. The discovery receipt SHA is
`9bed3908fb5781250a743ae4cb27beab6808e264ab0702baca747e11d2262830`;
the manifest SHA is
`5996103956dc53a48dd078a82e191c0beafd3682cdfdfa35b471f658964dcab4`.
Discovery is not a test-pass result. The four large packages are accounted for
separately; smaller packages use explicit, disjoint batches with unchanged test
deadlines.

The full Source18 App Server cohort subsequently completed naturally:
1,705 tests run, 1,704 passed, one failed and one excluded, in 1,310.665 seconds.
The receipt SHA is
`b777c0a99f1fe7e159709b3c6f93807ae5d695506c12b3a65e498e5e02441af8`;
its log SHA is
`08566ac703555e50fe17181e882cb3fff8a51cee1be304669db891f549f615c7`.
Exact selection, count reconciliation and all preservation guards passed.
All four Zsh completion markers matched their first passing test result, and
no owned helper processes remained. Both optional-MCP cases passed their
original PID readiness and corrected graceful teardown checks.

The remaining failure was the remote background-plugin analytics fixture.
Wiremock teardown reported zero of four expected requests. No initialize-write
trace preceded it, locating the failure before the first request, during remote
fixture construction. The exec-server listen-URL wait is a reachable ten-second
startup boundary, but teardown masks the primary error; its actual cause is
unconfirmed. The negative run remains unqualified. A diagnostics-only proposal
prints the original build error chain without altering assertions or deadlines;
it has not been applied.

The first closed-evidence live-copy attempt stopped before deleting or renaming
any original. On the external drive's OwnersDisabled mount, GID 0 appeared as
GID 20 in the copy. Byte content and all other compared fields matched, but
the strict preservation check rejected that metadata change. The negative
receipt SHA is
`507bec2fb9f30655a22a54665c142b40d234b6127b52f589bb7d80cf4cbfd994`.
The originals and failed copy remain. Subsequent temporary-evidence cleanup
uses a verified metadata-bearing archive rather than asserting that a live
copy on that drive preserves ownership.

The discovery temporary tree was subsequently archived and verified before
removal. Its 273 nodes included 137 directories, 34 empty files and 102 symlinks;
symlinks were recorded without following them. The archive retained ownership,
permissions, timestamps and extended attributes in its manifest. The original
temporary root and cleanup backup were confirmed absent, with source, native
and protected-process guards unchanged. Receipt SHA is
`562ad0b5fba2c3a0fb5f1ad24b3db814ad22ad713c20b6e50b9df2b22f9ac3cc`.
This qualifies that cleanup only, not the running App Server tests.

The App Server temporary tree was archived and independently verified before
removal: 5,156 nodes, 59,274,768 logical file bytes and a 39,359,919-byte compressed
archive. All preservation and helper-closure checks passed; the original
negative test receipt remains. Cleanup receipt SHA is
`3a95b5f1b37c054d7f2a76ecc00e8fc3ad21b7cc5a92ab397f27c6267431eb00`.

The first smaller-package cohort, B001, completed naturally with 953 tests run:
952 passed, one failed and six excluded, in 128.130 seconds. Exact selection,
count reconciliation, all seven preservation checks and helper closure passed,
with zero retries and no signals. Receipt SHA is
`60c888fd0c8ba9c099724db975ac822a639bb088d8899237b05c5ad79a47af15`;
log SHA is
`5ae8115efca970f270731bc3dc0372d0c172675ff7af2009c7740a034a919111`.

The failure, `remote_sandboxed_process_preserves_custom_arg0`, returned the exact
custom process name and empty stderr, but exited 42 instead of zero because
its supposed denied file was readable. Both fixture directories were under
`/private/tmp/C18B001`. With platform defaults enabled, the macOS process profile
explicitly allows recursive access to `/tmp`, `/private/tmp`, `/var/tmp` and
`/private/var/tmp`. Placing the denied file outside the workspace but within that
scratch grant contradicts the fixture's expectation. A correction must put the
denied file outside both workspace and scratch grants while retaining the exact
output/exit assertion and sandbox policy. No correction has been applied, and
the negative result is retained.

The B001 temporary tree was subsequently archived and verified before removal:
2,801 nodes, zero regular logical file bytes and a 262,975-byte compressed
archive. Its original failed result remains unchanged. All archive, source,
native and protected-process checks passed; cleanup receipt SHA is
`9f1ea3060e888e0e0a0129a49f861d3c8a74f9ff18254219f5cb1b3efe9487d8`.

Eight obsolete signed 0.2.0 build4 test applications were independently archived
and verified before removal, preserving bytes and original metadata. Current
native images, SDK inputs, installed build39, build40 backups, sibling artifacts
and protected processes were unchanged. The external drive gained
1,214,877,696 bytes after the archives were stored. Receipt SHA is
`6f28763454be1cbbebf6b637db8ac2b39455b32b5727bea2bef8e5213f5fed70`.
An earlier attempt passed a relative receipt path and failed preflight before
any archive or removal; that negative receipt remains recorded separately.

The first 27 exact terminal UI slices passed all 540 tests. Each naturally
closed slice retained its result and completed verified temporary-tree cleanup.
T028 then completed naturally with 20 tests run: 18 passed and two failed, in
15.740 seconds. The serial driver stopped without retrying or cleaning that
failed slice. Its terminal receipt SHA is
`d0681b3a4031e8e45601286ae0b7c5adb89cf0f1e12f92e241f5e105d15c0da5`;
the T028 receipt SHA is
`34b7aaa1f3fecf9f6b5198e0b1025a248ff1c62a26f1da773df21d4e10903ff4`.

Both voice snapshot differences are confined to the displayed compiled version
and its banner padding: expected `v0.0.0`, actual `v0.155.0-alpha.9.2`.
Caption bodies match. The generated `.snap.new` files correctly caused the
source/runtime preservation checks to reject that phase. Their exact bytes
were preserved before removing only those two generated files, restoring the
complete frozen source/compiler state. All 300 native images, protected
processes and helper closure matched before and after restoration. The original
negative receipt is unchanged; restoration receipt SHA is
`a96de4105b95b43f41b52d173edb414dcd417c98f8d6bba75066699df4875bbc`.
The failed-slice temporary tree was then archived and verified before removal:
1,999 nodes, 43,138,351 logical regular-file bytes and a 4,270,764-byte compressed
archive. The complete current source/compiler state matched its pre-test state,
and all native, protected-process, helper and bound-file checks passed. Its
receipt retains the original exit100 and failed outcome and joins the preserved
snapshot restoration; archive receipt SHA is
`c5d54508e8bd37d951ead5d9eb39ea8107d9ac6c90a10123cce175f34758a0fa`.
Source19 now applies six reviewed test-only source corrections: the denied-read
fixture moves outside the permitted temporary roots, version-dependent voice,
status and update/header snapshots validate the actual compiled version before
normalizing fixture output, and the analytics fixture logs its primary builder
error before teardown can obscure it. Existing golden snapshots, production
renderers, sandbox policy and test deadlines are unchanged. Ordinary `just fmt`
completed with exit0; the source freeze SHA is
`ee8f32f7e9f08b061cca9b692390b0c87eab5faf4bd766e1aa85614fb9ab9393`.
The cumulative SDK source delta is exactly 34 changed paths and the same two
added files, with all 27 native SDK producer inputs unchanged. Compilation of
the full ordinary test graph completed naturally with child exit 0 and controller
exit 0, producing all 275 binaries. The read-only terminal collection also
completed naturally with exit 0; its receipt SHA is
`b64423c303e9ae8531f856273dddac2d1b411246fce53290daae0d12af7bf01e`.
Source, SDK inputs and protected process identities remained unchanged.
Complete Source19 testing remains
required; the partial Source18 run and its four failures remain unqualified.

Git review had a potential unbounded wait after its 15-second process deadline:
an inherited output pipe could keep the blocking reader group alive after Git
exited. The runner now uses the shared owned process-group spawn, cooperative
nonblocking input/output, fair reads, and bounded group cleanup. Configuration
isolation, output limits and Git mutation checks remain in place.
The affected native suites completed naturally with exit 0: all 43 review tests
and 19 process-owner tests passed, with no failures or skips. Three new cases
exercise inherited output pipes, backpressured input and continuous output;
each confirms cleanup and successful subsequent service use. The source hashes
were unchanged during testing. The actual log SHA is
`13e6cf538a0da61e97f98af177045ae1ea77fffd25f7d43dc93d44b660bc6386`,
and its terminal receipt SHA is
`ef60207c36740a4a0f2eda8a728e38e1df9c67ae5c1ce2e78f2baaea18ea72b5`.
Final native candidate validation must still record a unique PASS for each new
case; this affected-suite result does not qualify installation or providers.

The first Source19 analytics diagnostic completed naturally with exit 100:
one failed test, no passes, and 1,349 tests filtered out. Its new primary error
is `timed out waiting for local exec-server listen URL`; the four-versus-zero
mock-request assertion follows during fixture cleanup. The original 10-second
startup deadline and all analytics assertions are unchanged. Receipt SHA is
`e34af323140b4a60bb753c551c3ab8ac2e7951b310a75ba34351ecc53430a658`.
All seven source/runtime/input/native/protected/temporary-root/owned-helper
guards passed. This diagnostic contributes no full-suite coverage, and its
negative result and temporary root remain preserved.
The exact exec-server image has a valid linker-generated ad-hoc signature.
Read-only system logs show an AMFI signature warning at 06:20:38.582 and an
AppleSystemPolicy denial for that path and PID 74291 at 06:20:48.585, within
the failed startup window. This supports an OS launch hypothesis; no signing
fix is established and the canonical executable has not been changed.

The subsequent startup-only experiment used two fresh private copies of the
same image and the original ten-second spawn, listen-URL and HTTP readiness
gate. The unchanged linker-signed control reached `/readyz` in 1.028 seconds;
the explicitly ad-hoc-signed copy took 0.928 seconds. Both owned children
were terminated, reaped, and verified to have no surviving process group or
open output pipe. Their internal homes acquired no files. Complete source,
index, SDK, all 300 native images, protected processes, bound inputs and the
canonical image stayed unchanged. Receipt SHA is
`629a173d43538e03161b62732fc8ae9746477c1555fd6492e1f4e61e23be5b21`.
One subsequent observation of the original canonical path reached readiness
in 0.034 seconds with the same deadline and verified cleanup. Its terminal
receipt SHA is
`df2164cac3ec0cb42951478949c82c6964f751164bb469c861f7400aee9c4603`.
These results do not establish signing as the cause or fix, nor reliable cold
first use: the observations were sequential and OS assessment state can change.
The original A001 failure remains negative and uncredited; its analytics
fixture and the complete Source19 suite still require a controlled run.

Three earlier probe attempts remain preserved. The first launched no arm
because the full-suite storage reserve was unmet. The startup-only successor
uses a separate 64 MiB internal reserve, with copies and bounded logs on T7;
the full-suite and CLI reserves remain unchanged. A macOS Python extended-
attribute API mismatch stopped the next attempt before launch. The following
attempt reached control readiness but failed its cleanup assertion because
macOS `waitid` reported UID0 for an owned UID501 child. A separate naturally
exiting child confirmed that discrepancy. The corrected probe checks UID501
in the process snapshot while retaining PID, parent, birth, process group,
unreaped-child and protected-process checks. No native-suite, installed-app or
provider qualification is granted by these probe results.

The next capacity step completed while Source18 was still frozen. A verified
archive retained all bytes and original-path metadata for 429 selected historical
data nodes before retiring 345 regular files and 68 empty directories. Seventeen
retained files and sixteen license ancestor directories stayed in place. The
current complete source/compiler state, 300 native images, SDK inputs, protected
processes, bound files and helper closure all matched before and after. Actual
internal free space increased by 457,973,760 bytes; this is measured reclaimed
space, not a guarantee of future peak usage. Receipt SHA is
`53b92e6ac6329c4c43b69609651043fe863c3fd73144c67e8943a3fa1ffac4c9`;
the verified 169,522,981-byte archive SHA is
`2e4e532335e2bb204d20499837db76d1ba1023a3ec4bc228d316ec9b42817f5e`.
This archive step launched no native tests and grants no test, package or
provider qualification.

A second verified data archive subsequently preserved twelve closed historical
phase receipts and one Build37 ZIP before retiring those exact thirteen leaves.
The catalog retains all ten original negative outcomes and two format-only
successes, including their original exit codes and restoration paths. All
current source, SDK, 300 native keepers, protected processes and bound inputs
remained unchanged; no native test or process signal was launched. The measured
internal free-space gain was 80,863,232 bytes. Receipt SHA is
`ac0e7b5b8049e5b573ccf51e7785e86824d1acc5d0dd39e18173ad2cc5819db1`;
the 37,202,589-byte verified archive SHA is
`7bdbc618a687d1cdc579c35cfe4bc4a7ff6d1a2f44af797ad3d8c77fc22d2b7a`.
The full-suite storage reserve remained unmet after this step.

Seven unneeded Cargo link-output copies were subsequently compared byte for
byte with their retained named executables. Their paths and inodes were outside
the complete current 300-file graph, source/tool inputs, current binding
documents and 414 public inputs. The first archive attempt reached its 512 MiB
compressed-output cap before verification and retired nothing; its negative
receipt, manifest and partial output remain preserved. A fresh attempt with a
1 GiB output cap completed independent archive and full-byte verification,
then retired only those seven exact leaves. All required native images,
source/index/SDK, input bindings, protected identities and helper closure
remained unchanged. No native test or process signal was launched.

The successful terminal receipt SHA is
`379a7f480db4b801705563d44f4d7fb89faba0e25c9b870c3cd030d077049b65`.
The complete 661,933,652-byte archive SHA is
`6543e83674de5e8ff1c1739ca76997b77c53ca17969a0ef377b3dd5ec21f3857`.
The selected files reported 2,659,872,768 allocated bytes, but measured external
free space decreased by 42,274,816 bytes across the operation. That measurement
includes concurrent disk activity and does not establish exclusive physical
allocation or a specific APFS-sharing cause. The nominal file sizes therefore
do not prove reclaimed capacity. Internal space remained below the full-suite
reserve, and no full regression run resumed as a result of this archive.

### Resource packaging correction

Inspection of installed build39 found all five `BrowserExtension/*.test.js`
fixtures in its bundle despite the project specification's exclusion. A folder
resource copies those leaves together with the extension. The project now has
a post-copy build step that removes those test fixtures from the built bundle
before signing; source fixtures remain available for tests. XcodeGen produced
the matching project phase after Resources. The release verifier requires the
exact eleven extension payload files and rejects additional leaves.

The generated `VisualGrounding/grounding_runtime/__pycache__` source cache was
also retired after preserving its exact bytes and metadata. Its retirement
receipt SHA is
`3bc48eb086517ef747e071b4ac05a8024064966534af8191afd7d6dbd96554af`.
Fresh build, bundle verification and installation are still required to prove
the packaging correction in build41.

### Storage recovery and fresh Source19 discovery

A bounded survey found 26,033,336 KiB of earlier staged apps and installation
backups under `computa-provider-qualification-2026-10-06`. Root retired **102**
ordinary Computa bundles with build numbers **1–34**, after recording their
node identities and main executable/Info.plist hashes and confirming no holders.
The installed app, staged builds **39 and 40**, all **300** required engine
executables, **414** public inputs and three protected process identities were
unchanged. Two incomplete bundles were excluded. This removed disposable old
application copies; it did not archive their entire payloads or remove chats,
browser profiles, source, model weights or validation receipts.

The observed T7 free-space increase was **25,881,518,080 bytes**, including
concurrent disk activity. Cleanup receipt SHA is
`e68618a0fc8406aa3ae3e4151b1b9bd5590007af2ae5494fa7dbfcead5c2382d`;
the retained node/identity manifest SHA is
`42c5a5cca33c36f33ce5fe5e5e4f954f4b61fa2f17453dc1f486783d66884eaf`.

The downloaded local model tree was then temporarily copied to
`/Volumes/t7/computa-mlx-model-storage-build41-1/models`. Every regular file was
verified by SHA-256 before its original copy was retired. The app's original
`LocalCodex/MLX/models` path is a symlink to that verified copy; the model's
3,061,144,105 bytes remain available. Observed internal free space increased
by **3,065,040,896 bytes**. Relocation receipt SHA is
`60e6a89e3c5b40ec31154e8256231690c68b53ef0e55f238010a0657d5c8dc06`.
**Restoring the model tree to its original internal location is required before
delivery.** The MLX Python runtime and current installation were retained.

A fresh storage proof verified the unchanged Source19 source/SDK/tool state,
all 300 graph keepers and no active owned native helper. It measured
**3,771,973,632 internal** and **24,583,094,272 external** free bytes, exceeding
the existing discovery launch reserves. Proof SHA is
`39ab41ec1d540e9d324871710cd3bbe5d7ab2f07a9793417546d942802cf8449`.
Actual fresh discovery in session **96996** naturally closed **0**, enumerating
**19,035 runnable tests**, **56 exclusions**, **275 binaries** and **133 packages**.
All seven source/runtime/input/native/protected/temp/helper guards passed;
controller errors and signals were empty. Receipt SHA is
`cab3ea2e95457cd7f9998d03ed5b6cc63a543599c8bf4d28dcdb36dee57e0fe1`.
The exact discovery cleanup naturally closed **0** in session **12549**: its
273-entry tree contained zero regular bytes and was removed, with all six
guards unchanged and no signals. Cleanup receipt SHA is
`819e33fcb7b7a685d7ecec21c3a7bac28a225da715d4171bc5756c4de942d366`.

During slow discovery, a one-second diagnostic sample of owned TUI listing
PID 42807 showed only `_dyld_start`, with a 112 KiB footprint. The matching
policy log recorded AMFI CT-signature warnings at launch and a later Gatekeeper
scan result. The process subsequently closed naturally. These observations
identify a pre-main wait in that sample; they establish no signing fix, general
cold-start guarantee or causal effect of sampling. No signing, policy/cache
reset or child signal was performed. The original logs and sample are retained.

The fresh 241-slice catalog covers all **4,820** TUI tests. Its serial preparation
is now sealed against actual discovery and cleanup evidence, SHA
`0c524fe0a9bac1f29e26ddc14aed365a2856757418bdf03c8928397e9fe54373`,
with 14 bindings. This is preparation, with no TUI test execution credited.
The **1,705-test** P007 App Server cohort was launched in session **17367** using
fresh 300-keeper/storage proof SHA
`849e18bfaececffad3f7e4b6d7fc9874128a16405b31aa12dc990b666315d852`.
Full test coverage remains pending until actual cohort results are collected.
The earlier A001 negative remains preserved.

The running P007 cohort subsequently reported a **60.009-second timeout** in
`suite::auth::get_auth_status_no_auth`, while awaiting initialization. The
matching startup-policy observation records an AMFI warning for the canonical
App Server image at 09:12:22 and a policy-denial message for PID 48722 at
09:13:21. Later initialization tests returned normally; these observations do
not establish a signing cause or fix.

Four `suite::v2::executor_mcp` cases also failed: guardian isolation, legacy
executor/browser compatibility, executor-only browser bearer-token discovery,
and per-thread plugin exposure. The guardian case reported an exec-server
initialization-handshake timeout after ten seconds, then observed two requests
instead of three; the other three reported elapsed deadlines. Their fixtures
launch the compiled `codex exec-server` CLI, whereas the background-analytics
case uses the standalone exec-server. That previously failing analytics case
passed in this run in **3.138 seconds**. The full cohort naturally closed
**100**, with **1,700 PASS, four FAIL and one TIMEOUT** among its 1,705 unique
first results; one declared exclusion was accounted separately. All seven
guards passed, selection was complete, controller errors were empty and no
owned native helper remained. Receipt SHA is
`e1e8e490e31960b16e6ce1af4086922a783b29d84011fb0ccceab51444801a3e`.
The failed run and its temporary data remain preserved.

Root then ran exactly those five adverse cases under the unchanged source,
compiled images, environment and original deadlines. A separate diagnostic
controller retained the original full-state/300-keeper checks and required
actual prior process closure, without claiming cleanup of failed data. Session
**83199** naturally closed **0**: **five unique PASS results**, no controller
errors or signals, and all seven guards passed. The 1,345 filtered identities
in that binary are outside this diagnostic selection. Receipt SHA is
`afc912d9a287a12e5f4f5d71599c350b2a9eebaa875d720117c5a961cbfc4dbf`.
This supports a transient startup explanation but establishes no general
cold-start guarantee or signing fix; diagnostic-only/full-coverage flags remain
true/false respectively.

A fresh full P007 follow-up was therefore launched in session **64912**, using
new output and temporary roots while retaining both original receipts. It
keeps the same 1,705 cases, one worker, zero retries and original deadlines.
The controller is restricted to P007; its SHA is
`7813e5a1b87f013cf42bf1054e21b1391f6adf8cadc877d9060635b786e24472`,
preparation SHA is
`d3f1f7dffcd0c386ddba7606b2f622b51ac6b7d2b29bc58f12e2bd102bd54b70`,
and measured 300-keeper/storage proof SHA is
`b2a294d674695b964c4481a1b623f21fe5e4b95d00786a4688ef65c89393043e`.
The follow-up naturally closed **0** in session **64912**: **1,705 unique
PASS results**, one declared exclusion outside that runnable selection, no
controller errors or signals, and all seven preservation guards passed.
Its terminal receipt SHA is
`0760163ef4583c136609d5f9c33bf12559ba12737a9396ad81c06bcbcd817a6d`.
This completes the current-source App Server cohort. The original adverse
run and five-case diagnostic remain separate evidence; the passing follow-up
does not establish a cold-start guarantee. Packaging, installed cold-start
checks and provider qualification remain pending.

Fresh Source19 small-package selections now cover exactly **125 packages and
7,618 runnable identities** in eight disjoint batches, each at most 16 packages
and 1,000 tests. Existing membership references were checked against the
actual Source19 discovery, then rebound to its manifest and terminal hashes;
no Source18 execution result is reused. The partition proof SHA is
`6750cd5fa235afbcc291565ff2cff98422db580e243c84aa329d64bf5be7021e`.
The selections themselves do not establish test execution. Root next extended
the existing successful-fixture cleanup to recompute the exact package/batch
selection against fresh Source19 discovery. Source, binary, process-holder,
hardlink and bounded manifest checks remain intact, and adverse phases remain
ineligible. Session **18403** naturally closed **0**, removing only
`/private/tmp/C19R2P007`; all preservation checks passed. Cleanup receipt SHA:
`944f31cabee3f7b57257e848f0a95857e377878ea0b95a26e988bcdf309a6394`.
The original failed P007 temporary tree remains preserved.

Fresh launch readiness for B001 verified the unchanged 300 graph keepers,
source/tool state, prior passing phase and completed cleanup. Its proof SHA is
`0453479e38f2a7986cb482f2b7961aba7a51eb1b2070fa4456d76c1dc1abf036`.
Session **56004** naturally closed **0** under the original one-worker,
zero-retry contract for B001's **953 runnable identities in 15 packages**.
All 953 passed; six declared exclusions are outside that runnable selection.
Selection completeness, all seven preservation guards, and absence of
controller errors/signals passed. The terminal receipt SHA is
`0793c6ebebde3d6b71d217bcc90c789d4507281272bc10ac1a866011afb6645c`.
The corrected custom-process-name scratch-directory fixture passed.

Session **62339** naturally closed **0** after removing only the passing
`/private/tmp/C19B001` tree: 2,801 recorded nodes and zero regular logical
bytes, with all preservation checks passed. Its cleanup receipt SHA is
`7cf1c3b70ad6fe6124971ad8c023e6437dc55d2070c3a56dea292c7aeac66c6c`.
The mechanically extended cleanup source is unchanged from the Root2 version;
its separate Root1 preparation binds the actual original cohort controller.

Root prepared a finite serial runner for **B002–B008**, binding the fresh
partition, original cohort controller, readiness producer and success-only
cleanup. Each phase requires natural exit, exact selected PASS identities,
unchanged required inputs and completed cleanup before the next batch.
It performs no retries and preserves the first adverse phase. Runner SHA is
`99cec36c3fd2146b0ab8aafd2f7e47c4717475998eb4894fc3e2651223412a3f`.
Session **24681** is live and has launched B002 after fresh readiness; remaining
batch results are pending. Current qualified Source19 scope is **2,658 of
19,035** runnable identities; **16,377** remain pending.

### Source19 B002: native success, header parser defect and separate re-audit

Session **24681** stopped naturally **1** at B002, before cleanup or B003.
The native B002 child exited **0** after **953 tests passed**, but the original
checker did not recognize Nextest's valid header
`Starting 953 tests across 25 binaries (250 binaries skipped)`. There was one
header; the parser required a skipped-test count even when that count was zero.
All seven source/input/binary/process preservation guards passed. The original
negative validation receipt remains sealed with SHA
`c575c23e0a2034c84f35698f207170fbf7e654fe44d604569353fc566ec469f5`,
and the stopped orchestration receipt has SHA
`b5cecdd122a2471dd1ab1392b54c0cd2e544ac6a0a85e9a3adc4bbb0ce71fd80`.

The new evidence parser adds only the binary-only skipped-header alternative
and normalizes its absent test count to zero. Seven controls passed, covering
all three supported header forms and rejecting duplicate headers/results,
missing results and malformed headers. Parser SHA:
`39e43df151429bdb0c630be90d75c725e0fbd3f8118646220f0db80ab40b8e57`.
No native source, executable, deadline, retry policy or test selection changed.

The separate re-auditor first stopped at a missing optional `audit` key before
publishing anything; that helper version remains preserved. After correcting
the preflight field access, session **41368** naturally closed **0**. It checked
the original sealed log, recomputed the exact selection, verified fresh source,
300 graph keepers and protected processes, and attributed **953 unique PASS
results with zero retries**. The 953 repeated final-output headers were excluded
from counts. The original validation receipt was not overwritten, and no test
was replayed. The separate `B002/revalidated-receipt-v3.json` has SHA
`fbe81a921382fa6af92a2c406a40567a23516bb8a57672e87a999cb3c645252a`;
its recovery provenance explicitly identifies the original checker failure.

Session **29151** then naturally closed **0**, removing only the now-verified
passing B002 temporary tree, which contained one directory and zero regular
bytes. Cleanup validated the re-audit's original-receipt provenance and retained
all preservation guards; receipt SHA:
`2cb52fc5c2ca5928d74337337f6e468397a1c3c456d1af28d12d0f5e31230f96`.
The corrected cohort controller/preparation hashes are respectively
`59f15ec356e70c7334b6e1104d28f1552eea38976d72cd971268b4da58bc992c`
and `56b88c60a112990bac6178d8702cb04dd34722cdcfd013270f728070f24d243e`.
The mechanically reviewed B003–B008 resume runner has SHA
`7079e2ce4388c38bf0ec6b3a16f76722964f25228e26189709ae0951be31e8af`.
Session **73362** is live from B003 readiness; its remaining results are
pending. Qualified current-source scope is now **3,611 of 19,035** runnable
identities, with **15,424** still pending.

### Source19 B003–B005 passed; B006 timeout remains under investigation

The resumed serial runner accepted B003, B004 and B005 under the unchanged
one-worker, zero-retry test contract. B003 passed **952**, B004 passed **952**
and B005 passed **951** selected identities. All seven preservation guards and
exact-selection audits passed; no controller errors or signals were recorded.
Their phase receipt hashes are respectively
`776099ed2bd5df7cef50f55c677daf5a61348f6d65e993c889077b7060bc1efc`,
`374645bbfc26b0a54ad3b17fb1467e3b60cb99fe834686e04375db8766d92e07`
and `caab0bb61a2f60ca321f0b1d54c9f1981926deb7f5c25ad2c1c49714772aa0b8`.
The zero-skipped-test B003 header exercised the corrected grammar in a fresh
native run, rather than only through the recovered B002 log.

Each passing temporary tree was removed with preservation checks. B003
recorded 139 nodes and zero regular bytes; B004 recorded 444 nodes and
70,967,992 regular bytes; B005 recorded ten nodes and 3,270 regular bytes.
Cleanup receipt hashes are respectively
`0933552e8cf6b56592f7799892daafb65dd74bf9acaa72c5b4793aac4b2853ba`,
`24c9c2c6e85c809037693f143e982b3504a894e88f06d0622e95e31769344575`
and `32f5ec901c0f21018c0adb021afa3ddd7a29c9bb2c796aa4a763a440d30a3842`.
Current qualified runnable scope is **6,466 of 19,035**, with **12,569** pending.

B006 is still live in session **73362**. It has reported a **60.008-second
TIMEOUT** for `codex-exec::all suite::add_dir::accepts_add_dir_flag` while later
CLI cases continue. This is a native adverse result, not a header-parser
failure. The runner will stop after collecting the phase; no B006 success,
cleanup or next-batch qualification is claimed. Its final captured output and
terminal preservation checks are pending. No deadline, native source or retry
policy was changed.

Read-only storage inspection also identified three old installer bootstrap
directories containing six byte-identical pinned public uv download files,
totalling **162,549,579 regular bytes**. The archive SHA matches the repository's
uv lock. Inventory preparation SHA is
`35fb0368f90eb697697c398e4313716696c86c9b2d9d7144a54b924dd1e16116`.
No cache was deleted. Cleanup must retain a verified payload pair and original
metadata mapping, wait for native process closure and verify no holders; the
installed app, MLX Python/venv/cache/model and user data remain outside scope.

### Source19 B006 terminal timeout, A003 diagnostic and full follow-up

Session **73362** naturally closed **1**, retaining the failed B006 phase and
stopping before B007. The native phase exited **100** with **952 PASS, one
TIMEOUT and one declared exclusion** outside its 953 runnable identities.
All seven preservation guards passed, no owned helper remained, and no
controller error or signal was recorded. The B006 receipt SHA is
`5b518322f749d10546a9d995911557f0f41a4ef37140c420c15506175963b110`;
the serial-runner receipt SHA is
`f456aed9a52391d9f09a3cf3750f57e3e228f6c373afd418112ac68d9e4a2f3b`.
The full original temporary tree remains preserved.

The timed-out directory-access test captured only its harness's `running 1
test` text and timeout notice, with no completed CLI response. The exact-image
system-log query recorded AMFI warnings at **10:36:11.746 local**, then an
Xprotect scan-result event at **10:37:07.707** for the unchanged
`ci-test/codex-exec` executable. This assessment overlaps most of the original
60-second case window. Log SHA:
`ba6194d85d2917fc605cf34540ee725a2719a1adcec576a6870d4cf2a8d72f13`.
Timing and absent captured output support a startup explanation but do not
prove causality, a permanent denial, or a signing fix. No signing, policy or
cache reset occurred.

Fresh A003 readiness verified current source/tool state, all 300 graph keepers
and actual prior closure while preserving failed fixtures. Producer session
**9861** closed **0**; proof SHA is
`b75c00727e449b036a523a5dd3579c3e69781a619b5f70afcc7cc83c745c85c4`.
Session **84553** then naturally closed **0** with the **single exact timed-out
case PASS**, original settings and all seven guards preserved. Diagnostic
receipt SHA:
`a9d3eb0537316eb1af712ac12dc43fa283be0dfe5f134d13e01b4f0c6cb06a0b`.
Its 92 filtered exclusions are outside this diagnostic selection; it credits
no complete batch or new cold-start guarantee.

The original full B006 selection is therefore being repeated in new output and
temporary roots, with unchanged source, deadlines, one worker and zero retries.
Readiness session **30967** closed **0** with proof SHA
`8712b4bd0dda5e6b9017734ae5d656e3705b123d4612d8b6670c64e92d973df5`.
The B006-only follow-up controller/preparation hashes are
`23d212dba9cb96333cb94405bf121c12b0c1ca61061a93fc28e36ad4dd88f52e`
and `2bdb303a8ffbfcfadf797dd52fc2af9380aa683cc7a6c7b998314f3fd7288543`.
Session **51935** is live under
`/Volumes/t7/computa-source19-full-suite-cohorts-build41-2/B006`, with temporary
root `/private/tmp/C19R2B006`. The original timed-out case has passed in this
full follow-up; its overall result remains pending. Qualified scope remains
**6,466 of 19,035** until complete passing phase evidence is collected.

The B007–B008 resume runner is prepared with SHA
`bedcbefae2cd2c4a900f2714a1d4c65f64a1baff9195f8acf0e80315b5a32956`.
It has not run and requires the actual B006 follow-up PASS and cleanup first.

The full B006 follow-up subsequently naturally closed **0** in session
**51935**: **953 unique PASS results**, one declared exclusion outside its
runnable selection, exact-selection completeness, all seven preservation
guards, and no controller errors or signals. The previously timed-out case
passed in **13.959 seconds**. Receipt SHA:
`a6523939390066621ea1a9f7f2eabe921f4ecaf3ce8016488eaf7ff1089afcb1`.
This qualifies the complete current-source batch in the recorded follow-up
order; the original timeout remains preserved and no cold-start fix is claimed.

Session **91140** naturally closed **0**, removing only the passing follow-up
temporary root after recording 1,232 nodes and 210,024,039 regular bytes, with
all preservation checks passed. Cleanup receipt SHA:
`8f6dbd9b643986748c36fc5e1ad4c67712973cfb217dc3ecefd0a7aa00a1f462`.
The original failed B006 root and empty A003 diagnostic root remain retained.
The finite B007–B008 runner is now being started from this actual passing
phase/cleanup pair. Qualified current-source scope is **7,419 of 19,035**;
the remaining **11,616** still require results.

### Additional final native Git deadline regression gate

Review found that Native Runner3's exact cohort checks do not individually
require the three new WorkspaceReview deadline cases. A separate pre-staging
gate now requires one ordered start/PASS and zero failed/skipped observations
for each inherited-pipe, backpressured-input and continuous-output regression.
It also requires the sealed final native validation to be verified, its log
hash to match, all 414 source inputs to be frozen, and the three affected source
files to match that final run. It does not infer these passes from total count.

Six controls passed using the actual earlier 62-test targeted log as the
positive input, then rejecting missing, duplicate, skipped, failed and reordered
evidence. This validates the checker only; it is not a new final native run.
Verifier SHA:
`059a415473bd32cfdf045156ed1d5937b5f5ded140961f855b078146ef599588`;
control SHA:
`65dacdbe10bce5f4ebe954aec2c19789985509b8301d09a1433c67bf0ea38c9a`;
preparation SHA:
`809a2f5fb7e987ba6b3f3828def01cba9379c86629446e932cf2203c9a73dff0`.
After Native Runner3 succeeds, root must run
`verify_git_deadline_final_native_build41_1.py` against its sealed
`native-build41-final-validation.json` and require the verified three-case
receipt **before invoking Release Stage3**. That final audit remains pending.

### Source19 B007 passed and cleaned

The finite B007–B008 runner started once and advanced after actual B007 completion
and cleanup. B007 passed all **952** selected identities, with no retries,
failures, timeouts, skipped identities, controller errors or phase signals.
Selection completeness and all seven source/runtime/input/ownership guards
passed. Its immutable receipt has SHA
`ab6dc94b7b75f85c8645afc8825c3b8f17eeae65858c4e85b7c3a672b82438c1`.
The actual cleanup receipt has SHA
`421521de19b9a39586d5ebcc6783191df7a23cafc503f6d233948a1f0de85cbb`;
the controlled B007 temporary root is absent and all cleanup guards passed.

Qualified current-source scope is **8,371 of 19,035**. B008 is running; CLI,
core and TUI remain pending. This progress does not qualify packaging, installed
app behavior or browser-backed providers.

### Source19 B008 passed and cleaned

B008 passed all **952** selected identities with zero failures, timeouts,
retries, leaked results or controller errors. One excluded identity was skipped
outside that selection. Selection completeness and all seven guards passed.
The phase receipt has SHA
`dac81727d9a56a8f97eae4fb7e69740022515903a8707241d1c2b673a8175a72`.
Its successful cleanup removed the 155-node empty-payload temporary tree;
the cleanup receipt has SHA
`9ff0cd5cb3dd52a8c5adad897eafe2504754379df888e5c4ccc50a4617c2f4b5`.

The finite two-batch runner completed and accepted all **1,904** selected
identities. Its terminal receipt has SHA
`8d1ae2b40ed7068df0abb641aac880642516ffcbfcbfa49f2112320d8a986ad9`.
Qualified current-source scope is now **9,323 of 19,035**. The remaining
**9,712** are CLI (458), core (4,434) and TUI (4,820). Final application checks,
packaging, installation and live provider benchmarks remain pending.

### Source19 core launch and remaining validation preparation

Core P033 launch readiness passed for the exact **4,434** discovered identities.
The readiness receipt has SHA
`4e6f6abe50492c4e8f6fdd2738382035a677f298a254d65ced245f88dd0a3580`.
The actual native run started with owned root PID **5073** and its log at
`computa-source19-full-suite-cohorts-build41-1/P033/validation.log`. It remains
in progress; partial PASS output does not qualify the complete package.

The original negative B006 and P007 temporary fixtures still occupy
**297,660,841** and **101,553,203** regular logical bytes. Root prepared
`archive_source19_negative_fixtures_build41_1.py` to archive each exact closed
tree on T7, verify every payload and the gzip CRC, recheck unchanged source,
SDK/tools, 300 native keepers, protected runtimes and absence of owned helpers,
then retire only its original private TMP root. Hard-linked, foreign, flagged,
special or keeper-alias entries are rejected. No fixture has been archived or
retired by this preparation. Its nine read-only controls passed.
Controller SHA:
`ff7b442376dd614425c12f6f2947a4bdba4690adbde8779b07534fdb8f20068e`;
control SHA:
`028e7016056f1360d18cf1918b5b60155384f33baa37ccd3f71390fd4146fb5f`;
preparation SHA:
`934b01bdd964b7740f46f0351636973ee060313b6614c3d26aee5dd09237c6e5`.
It may run only after the active native execution is terminal and its owned
helpers are absent.

### Source19 complete TUI package acceptance

The immutable cohort controller5 successor changes only whole-package TUI
selection and the final partition check. It accepts P099 only with all
**4,820** runnable identities and the **seven** exclusions from fresh discovery.
The final collector accepts either that complete package or all 241 original
20-case slices. It rejects mixed, partial or overlapping coverage and still
requires the exact 19,035-result union, 133 packages, completed native PASS
results, original semantic markers and unchanged Source19 lineage. The
original slice catalog is retained; no previous Source18 result is credited.

Nine read-only controls passed against the actual discovery manifest,
including exact equality between the whole-package selection and the union
of every original slice. Runnable/exclusion cardinality changes, missing or
extra slices, and mixed whole/slice evidence were rejected. Source, engine,
SDK, workers, retries, deadlines and launch reserves remain unchanged.
Whole-package temporary storage use is not yet certified; any adverse result
prevents qualification. The native TUI package has **not run**.

Controller5 SHA:
`e3126d2aa6d80d34dd37595b9894a7aa3713923de9635aec21a4553e9b8cd260`;
cohort preparation SHA:
`8554ad83f2b839b801a8b868265f7adff0142b888a9d74655ba08addc08cdbf3`;
readiness5 SHA:
`0cb5606da6d39b8ee0571754389acb6687ea9a810675f80e94524c8d0357d1bf`;
cleanup6 preparation SHA:
`44d9f87fc9216ea9078452def93373d969307753573ca6145a70c42a66b7fde8`;
control SHA:
`dc2d8a142b98b1559101193a280fefba1f5d543e6ee4ba65044440bfd3a0c80d`;
aggregate preparation SHA:
`c94c4cefc1ac01da70f33dcdee809bb9628edb2dbc4a75e5b2ed08c2c5469561`.
Final collection must use controller5 if P099 completes as a whole package;
the earlier controller3 intentionally requires all legacy slices.

### Source19 core P033 completed

The actual P033 native run and controller completed naturally with exit **0**.
All **4,434** unique first results passed; **28** declared excluded identities
were skipped outside that selection. There were no failures, timeouts, retries,
leaks, controller errors or phase signals. Exact selection completeness,
runtime/source/input preservation, native metadata, protected-runtime identity,
temporary-root identity and owned-helper absence all passed. Its receipt has SHA
`ebfbe0e8d921adeee569bdd88a1a7d5b3b190fcf71ae5b0ebedfa7df2f4f78d0`.

Current-source qualified scope is **13,757 of 19,035**. The remaining **5,278**
are CLI (458) and TUI (4,820). The exact passing P033 fixture cleanup has been
started using cleanup4 and its original readiness receipt. That cleanup's
terminal receipt remains pending; no unobserved cleanup is credited.

### Core cleanup and negative-fixture archive completed

P033 passing-fixture cleanup completed naturally with all six preservation
guards and owned-helper absence checks passing. Its exact temporary root is
absent. It removed **42,983** generated nodes and **119,030,057** regular logical
bytes. The cleanup receipt has SHA
`1d15fb6d1943d75f99ed9a2faefe9f09c273447c885890510626d51595d631be`.

The prepared negative-fixture archive then executed once and completed
naturally. B006's **9,184** nodes/**297,660,841** regular logical bytes and P007's
**6,540** nodes/**101,553,203** regular logical bytes were fully preserved in
private T7 archives, including symlinks, recorded metadata and xattrs. Every
regular payload and gzip CRC passed verification before retirement. Fresh
source/SDK/tool state, all 300 native keepers, protected identities and absence
of owned native helpers were equal before and after. Only the exact two
original private TMP roots were retired; their failure logs and receipts remain.

Archive receipt SHA:
`5ebba1eb5ac256cee2133c9a08c7b1ef8cfcb7b104b287667eeecab209efa663`.
B006 archive SHA:
`26afd7c22a3a3722865b6e35022abb9d4cbd4958c8fd117098984a2de997b286`
(63,412,914 bytes), manifest SHA:
`0e7fb3b011d198fe19f29269635d4756e8500391aef291ae0e26dd988f820b71`.
P007 archive SHA:
`2231bc4a65e94280719ec5a0348d7de435f65dbb64c2bca32fe02fbaf7144a34`
(74,226,980 bytes), manifest SHA:
`2a4fc562ba0b2943cad0a8f22d3051a1f5d05fadf734ee5bea70565daacfd878`.
Internal free space observed during the operation rose from **3,236,564,992**
to **3,667,308,544** bytes; this is an observed volume change, not a guaranteed
physical reclamation amount attributable solely to the helper.

P022 CLI launch readiness then passed for all **458** selected identities,
with **3,663,859,712** internal free bytes above its **3,551,890,400**-byte launch
reserve. Its readiness receipt has SHA
`0d55e5be2a16bd497249f7c41ffab6de5815c44336c20a61078763ba4d55cd0f`.
The CLI run is now starting under controller5; no CLI result is yet credited.

The CLI native execution has now started with owned root PID **66725**, under
the same single worker and unchanged Nextest configuration. Its log is
`computa-source19-full-suite-cohorts-build41-1/P022/validation.log`. Package
daemon cases have emitted SLOW observations followed by natural PASS results;
those observations are not timeouts or completed whole-package qualification.
The specific process and controller handle are still live. No test deadline,
retry count, environment or signature has been changed to accommodate them.

### Source19 CLI P022 passed and cleaned; TUI started

P022's native run and controller completed naturally with **458 PASS**, no
skipped identities, failures, timeouts, retries, leaks, controller errors or
phase signals. Its exact first-result identity set equals the fresh discovery
selection. All seven source/runtime/input/native/protected/ownership guards
passed. The phase receipt has SHA
`910690d3e1cdf8e18456fccf7304e64bbb765584f16948a6e2e40fd5314a8a2f`.
Cleanup6 then completed with all six guards; the one-node empty-payload CLI
temporary root is absent. Its receipt has SHA
`b3476db1d829972f13eaa4a965f6c8bac2e2bfb2908833dc06d95675eed6113a`.

P099 TUI readiness passed for the entire **4,820-case** package, with
**3,672,670,208** internal free bytes against the unchanged **2,684,354,560**-byte
non-CLI reserve. Its receipt has SHA
`5d0a902aa33fe32e098f53f44c52b394a41dbcb5737747953d9d72ca82df394a`.
The actual native TUI root PID **79657** is running; its log is
`computa-source19-full-suite-cohorts-build41-1/P099/validation.log`.
Completed first-pass scope is **14,215 of 19,035**; no partial TUI result is
credited to complete-package qualification.

The core audit attributes **37** unique inherited guard exits: **24**
`requires_remote` and **13** `core_execve_wrapper_missing`. All are attributed;
none is an unattributed guard occurrence. Twenty selected core coding/terminal
cases have first PASS results with no observed guard exit. This does not turn
regex absence into assertion proof or qualify remote/optional wrapper features.
The audit retains its explicit unexercised-scope and qualification limits;
installed native workflow and live provider outcomes remain separate gates.

### Source19 TUI P099 negative result and preserved snapshot output

P099 completed naturally with **4,813 PASS, seven FAIL and seven declared
SKIP**, with no Nextest timeouts, retries or leaks. Its complete 4,820-identity
selection executed. The phase receipt is
`bc2d4a3263e0a63c95b29bd64bee9eb875dec4dd9894ef2d485ba43ddb08e3d2`;
the validation log is
`66202a27324ac66137a00bfd17d059b911c53d99570b82c5a44499256d4cded4`.
This negative package is not credited as completed qualification.

The source guard correctly reported `canonical_source_changed`: Insta wrote
four untracked `.pending-snap`/`.snap.new` outputs. Comparison with the full
frozen inventory verified identical tracked files, HEAD, index and cumulative
patch. All four generated files (7,485 bytes) were copied with their metadata
and extended attributes to private evidence storage, verified before retirement,
and then removed only at their exact generated paths. The complete source
inventory again equals the frozen Source19 inventory. Preservation receipt:
`source19-P099-generated-snapshot-evidence1/receipt.json`, SHA
`f4662784645af8119a82af3e77974948a3410f51a4f9eb6fe8b474028017f7a5`.
The original failed phase, its fixture tree and logs remain preserved.

Four snapshot failures differ only in trailing header padding after replacing
the compiled prerelease version with `<VERSION>`. The Windows update-card
normalizer requires seven total rows although its golden fixture contains eight
rows, including a wrapped PowerShell command. Neither observation justifies
blindly accepting new snapshots; the raw layout and fixture invariants must be
checked before correcting the tests.

The directory-trust and focus-palette integration cases produced empty screens
within their original 30-second startup deadlines. The macOS system log records
an XProtect assessment of the exact `ci-test/codex-tui` executable during that
failure window (12:16:40 local); this is evidence of overlap, not proof of cause
or a cold-start fix. The first diagnostic attempt stopped during Cargo metadata
resolution before either case executed: its wrapper omitted the frozen Cargo
and SDK environment and downloaded dependencies into the default cache. It
also exhausted internal storage before its receipt could be written. The
original log remains immutable and a separate infrastructure-failure record
confirms that it contains no Nextest execution start. It contributes no test
result or qualification.

All 1,115 downloaded compressed packages were preserved and verified before
retiring only their newly created default-cache files and unpacked directories
(835,049,801 logical bytes across 53,617 nodes). The 46 preexisting cache entries
remain; the pinned build Cargo cache and user source were unchanged. The
preservation/cleanup receipt has SHA
`b213720b76b1459570a9f6f20985aed294eee2a7b7bb562d4289a3e3344b3a46`.

The closed P099 fixture tree was then fully archived with every payload,
metadata, extended attribute, symlink and gzip CRC verified: **94,577 nodes**,
**2,106,819,423 logical bytes**, archive **1,216,130,235 bytes**, SHA
`246662a91c51cc7cc4c8f29dedb870a519009d51198ff1d6434045ed6c1ff327`;
manifest SHA
`f535c8ebfdb9fcd93032c9e96782b773f87eebe18d9c2202ecd758e93c510197`.
The initial retirement attempt failed at atomic rename because storage was
exhausted and removed nothing. After cache recovery, the unchanged original
tree was checked again and retired using that verified archive. Final retirement
receipt SHA:
`bd96f2873cd8d97720ff576c83e597a4c981455eed683179ec5af0ec3cd6619b`.
Fresh source/SDK/tool state, all 300 native keepers, protected identities and
absence of owned native helpers were equal before and after. The original and
renamed fixture roots are absent; internal free space measured **3,384,020,992
bytes** at completion. The original seven test failures remain negative evidence.

The corrected startup diagnostic now applies the same bound Cargo/SDK overlay
as the ordinary test runs, preserves the original deadlines, worker and retry
settings, and changes only its owned TMP directory. Only the two failed PTY
cases are selected. That diagnostic cannot substitute for a complete passing
TUI package.

The corrected two-case startup diagnostic completed naturally with **2 PASS**
in **12.943 seconds**: directory trust **12.832 seconds**, focus handling
**0.110 seconds**. Original deadlines, images, signatures, retry settings and
terminal environment were unchanged; the bound Cargo/SDK overlay was applied.
All source/runtime/native/protected/owned-helper guards passed. Receipt SHA:
`a9220d8cc6a361d3411fe009f78405e49279ca25b4abc2d8ca67791706d4e3b4`;
log SHA:
`1ea58b6c58be4f162e385d82bba69f25247f208ecdeb52066329e2287186ccfd`.
This follow-up does not qualify the original failed TUI package or establish a
cold-start/signing guarantee. Five fixture failures still require correction
before another full TUI run. Both empty diagnostic TMP roots were removed with
ordinary-file ownership and exact empty-directory checks.


## Source20 TUI fixture corrections and terminal result

Source20 changes four TUI test files only. The shared session-header normalizer validates the raw title, borders and padding before replacing the compiled prerelease version. The update-card normalizer validates and reconstructs its wrapped Windows instruction. Production code, golden snapshots, test identities and original deadlines are unchanged. The first uncompiled candidate was corrected to accept the expected update action explicitly; it was superseded before compilation.

The compiled source freeze is `engine-transcript-build41-source-freeze-reviewed-tui20-2.json`, SHA `d479030409aba4f4473a2de72c4719f2f433656a79ae4b5cf2a3474990a95e24`. Compilation of all 275 test binaries completed naturally with exit 0. Receipt SHA `c24082bd78973a2e8db51bc69b2dc04ef866e3e7ad403ba1c9bd65ae538206e5`. The five mapped app-server, CLI, exec-server, stdio and code-mode helper images have identical bytes to Source19. This does not assert byte identity for every graph executable.

The complete TUI package run executed all 4,820 discovered runnable identities with one worker and zero retries. It finished with 4,817 PASS, three FAIL and seven exclusions in 389.723 seconds. All five corrected fixture cases passed. Source/runtime/native/protected/input/owned-helper guards passed, and no generated source deviation was observed. Terminal receipt SHA `2f615d5547123d27900aea666fc84c177c20a930c685c52815513cac08596443`; log SHA `577bc8943b77c931995036924db6cd29714315a874a783cf56783aaeae317b7d`.

Remaining failures: `kitty_local_file_pet_image_uses_file_reference_without_inline_payload` rejects the substring `cG5n` anywhere in the output. The same substring can occur in a base64-encoded file path, so this failure alone does not prove inline image payload; `connected_trust_cancellation_and_acceptance_control_task_creation` and `focus_gained_with_unanswered_palette_queries_preserves_immediate_input` produce empty startup screens. The earlier two-case startup diagnostic remains a separate passing observation. These failures mean the complete upstream workspace is not qualified. They do not replace installed Computa app-server, browser, editing, Git and localhost workflow checks. No further broad TUI rerun is used as a prerequisite for those app checks.

The closed Source20 negative fixture tree was fully archived and verified before retirement: 100,396 nodes and 2,067,455,665 logical bytes. The archive is 1,157,004,252 bytes. Cleanup receipt SHA `7488b99320ed744120e0463e370e013c1ad2be84b9f2d1c524c1349ee337d503`. All source, SDK, tool, native keeper and protected process checks matched before and after; no owned native helpers or fixture holders remained. Both original and renamed temporary roots are absent.


## Final lint review and Source21

A fresh log audit covers the exact 19,035 discovered runnable identities and all 56 declared exclusions without overlap. The separately attributed Source19/Source20 observations contain 19,032 PASS and three TUI FAIL. Conditional guard exits remain unexecuted feature scope, and these mixed revisions do not establish a green current workspace. All four App Server zsh-fork post-assertion markers are uniquely attributed to matching first PASS outcomes. Summary receipt SHA `210276fc632e2ae54ff766b36510c48910eb5f17948e11950119b174386af091`. All selected completed fixture roots are absent.

The scoped final `just fix` command covered core, network proxy, voice host, App Server and TUI. Its Cargo log finished the release profile in 14m27s, but the source guard failed because Clippy changed five files; the original runner did not durably capture its child exit code before that guard raised. This receipt is not claimed as a passing final lint phase: SHA `bf09b7bb409a5a59cde8442e234f1a1d25441174377bb48b9a870984da27e7f9`.

The reviewed changes replace a method-call closure with its method reference, remove a final-use String clone, and replace a fixed five-element Vec with an array. Release-mode Clippy also removed a mutable loader argument and an import that are needed under `debug_assertions`. The corrected code shadows the loader mutably only in debug builds and gates the PluginStartupTasks import and managed-config constants to debug builds. Debug configuration handling and release behavior are preserved. The five original Source20 files were reconstructed from its exact patch and verified against its frozen hashes before comparison; the automatic Clippy candidate is preserved separately.

Source21 freeze SHA `41c32a20bfefe3ff63370fdf22ec03e1bc37b13fe4928e624ed5b64fe0f27f26` binds the reviewed and formatted result: 39 modified and two added files relative to the immutable SDK source producer, with its 27 native inputs unchanged. Debug graph compilation is running to verify conditional branches. No Rust tests are replayed merely for lint/format changes; earlier test outcomes retain their original source attribution. Stable final lint, package, public/native checks and installed workflows remain pending.

Source21 ordinary debug graph compilation completed naturally with exit 0: all 275 test binaries, unchanged source/SDK/tool inputs and temporary-root identity, and no controller errors. Cargo duration: 24m35s. Receipt SHA `7a9c35b77b2251380e04f002fff7d56db664bb6605aac6a82bfca410b666e8f4`. No tests were executed by this compilation check. The stable scoped final lint phase is now running against the immutable Source21 freeze.

The stable Source21 scoped `just fix` phase subsequently completed naturally with exit 0 in 3m49s. Its source and bound inputs were unchanged; receipt SHA `effd0537b8ef929ced54518961b6630d90a3271a664345e6a38ae0311b316695`. The final `just fmt` phase also completed with exit 0 and unchanged source; receipt SHA `c85fbb80f26e5947b58d4874729fc9a63e745891a22c27f68982c8daef05df04`. These are successful lint and formatting checks, not additional test results. The release package is compiling the immutable Source21 result; public/native and installed workflow qualification remain pending.

Source21 release packaging subsequently completed naturally with exit 0 and unchanged bound inputs. Package receipt SHA `7a0b7a0f803125b4bd392ee3d4216021654805ca642b48b0e310b95f10b83047`; engine artifact freeze SHA `bfed5d5d9737db94b9e04f89cca1f4fb06b3edac2f8b2f203e5a43ca0958a9a0`. All five source-pin/patch/manifest/binary checks passed. The `mactopus-6` executable is arm64, 239,994,800 bytes, SHA `1004afd5cbd9d0422dc2befc150fd0dcb25363367caaaabb91d1d5c2e816583e`, and passes strict code-signature verification. Its imports are system libraries/frameworks; no private build-SDK library is imported. This qualifies the engine package, not the installed app or live providers. Fresh public validation has started against this package.

All seven public cohorts completed with exit 0 and passed independent source/resource/artifact validation. Public receipt SHA `5098ec8eac63708edbb9e645bdaae68d1bd91e3d1f62b78cde7d916e72097a43`. Results: frontend type-check and build passed; 123 frontend tests passed; MLX ran 107 tests with 106 passes and one skip; 364 provider-adapter tests, three persistent-instruction tests and 21 product-identity/version tests passed. This is 617 passing tests and one skip. The 400 validation inputs and packaged engine artifacts were unchanged, and generated resources match the declared inventory. Final native validation started using this public receipt and the current engine freeze. These checks do not establish live website qualification.


## Native failure diagnosis and corrected fixtures

The selected native run finished with 652 tests, one skip and three failures (two failing cases), exit 1. Receipt SHA `7768c32aacf45ebcb59e8888e88c8db1056d411f5debf61b1ad2442ec4733084`. Source/resource and engine bindings were unchanged. Its five scripted editing/Git/local-HTTP workflows, five patch scenarios, 26 unique cleanup identities and 43 workspace-review tests passed. This does not qualify the overall native candidate.

A focused diagnostic captured the actual tool output for the permission fixture. Full wrote the owned outside-workspace file with exit 0. Ordinary Ask returned exit 1 and `operation not permitted` for that exact file, and created no file. The explicit escalated call received its matching native decline. A sandbox-denied process can return its native tool result without a commandExecution lifecycle item; the old assertion required the latter. The corrected gate accepts only the matching offered call and arguments, native exit-code output, exact workdir/path, positive exit status and a sandbox denial, or a matching native lifecycle failure/approval decline. It retains same-thread policy assertions and independent file truth. Cleanup accepts NSFileNoSuchFileError only when the owned root is actually absent.

The website routing test now uses canonical UUID task, thread and turn identities in its private copy of the JSON-RPC fixture. The shared streaming fixture is unchanged, retaining its deliberately stale identities. The first correction misplaced an import above the executable shebang; that failed diagnostic remains preserved, and the import now follows the shebang. The follow-up passed all three selected permission/routing tests with zero failures in 23.909 seconds; fixture removal was confirmed. Receipt SHA `8cce6f62b2334721d9b920743c714b5ac6cc0f1b1d39fb4b744d679888bdfa7e`. Production permission and admission rules were not weakened.

The original public MLX skip used an LM Studio asset path even though Computa's managed tokenizer assets were present. The supplemental four-case run with an explicit model path recorded three passes and one parser error, receipt SHA `4a669539dc4e4400fee40dc1a0128be7f95ff6c3ab2307f84608eeb1057ab659`. The actual endpoint correctly rejected 12,917 prompt tokens plus a 4,096-token allowance against the 16,384-token window before generation. The stale assertion treated the boundary's multi-event SSE body as a single JSON object. The test now parses all body chunks and verifies response.created, error, response.failed, the terminal DONE marker, exact budget, empty output and no receipt leak. Local asset discovery prefers Computa's managed assets, preserves the explicit override and LM Studio fallback, and never downloads. All four checks passed in 4.348 seconds without an override, model weights, listener or GPU inference. Receipt SHA `21c2999cd044360f5b708bb2becf1aac99b1081adb9b2690d2ea7b14bc1ccf86`.

The new public run uses a fresh evidence namespace. The native successor will run the entire Swift suite instead of the prior selected filter, preserving the required cohort, permission, workflow, patch and cleanup gates. Original failed receipts and logs remain immutable. Installed/provider, UI and benchmark qualification is still pending.


## Complete Swift run and browser wait deadline

Public final2 passed all seven cohorts and independent guards with 622 passing tests and zero skips, including 111 MLX tests. Receipt SHA `e5e322f3940add87c6984be8707559bd0d882151043be36bea0384e6911b909f`. The complete Swift run then finished with 2,310 tests, 49 opt-in skips and 28 failure reports across nine cases in 537.385 seconds. Direct case records contain 2,252 passes, nine failures and 49 skips. Receipt SHA `3ba6cffa546733bf5d5060192c58bde56b918959a458e7718f27860e59c749b3`. Its permission/routing, scripted coding/Git/HTTP and workspace review checks passed. The overall candidate remains negative; these results do not qualify installation.

Eight failed WebsiteModelEvidenceTests cases still called infer without durable native turn binding, matching request metadata or cleanup storage. They also expected schema-1 flat sidecars and reused website conversations. The fixtures now use the existing explicit synthetic inference helpers and exercise the schema-2 per-turn transaction journal. Positive checks retain two inference pairs, require distinct session/document identities with sequence 1 and baseline 0, verify exact native task/thread/turn/generation mappings and five lifecycle records per inference, and prohibit prompt/tool/response canaries. Fast acknowledgments retain their actual count. Malformed contextual fields must throw invalidRequest and leave only bounded start/start/failure records. Invalid task paths, full 32-MiB journals and symlinked journal files must reject admission without opening another website session, while prior bytes and protected file contents remain unchanged. Production ownership, persistence, model and privacy validation were unchanged.

The 68-case focused follow-up passed those evidence cases but reproduced the browser failure. Error-only phase tracing located it at missing_result_wait: the transport returned browserUnavailable("The built-in page observation timed out.") before the caller's deadline. XCTest subsequently reported InvalidTransition during teardown. The wait calculates a remaining integer millisecond script budget by rounding down, then previously started a host timer with that shorter budget. The caller only treats expiration at its original deadline as an ordinary unmatched result. The host timer now sleeps until the same absolute ContinuousClock deadline supplied by wait; other operations retain their requested duration. Cancellation and early browser failures still propagate, and no action is replayed. The original failed diagnostic is preserved, SHA `e0bc8d3b975afedf1c776ea8df2a6b9d5f9f730ec1c92d1397107c82ecb9faeb`.

The corrected follow-up passed all 68 tests with zero failures or skips in 5.821 seconds. The flight case runs ten independent WebKit documents through read/fill/press/result wait, exact click count and short unmatched wait, and fails on the first thrown error. The evidence class passed all 19 cases. Receipt SHA `b52bdbf9d441aa97252df9f4d2a1fa6b899835effc15c2228aa62820ae345f02`. Fresh public final3 and complete native final3 evidence use new immutable names. The earlier full and focused failures remain negative; current installed/provider/UI/benchmark checks remain pending.

Public final3 completed with 622 passing tests, zero failures and zero skips; all seven cohort exits and independent source/resource/engine guards passed. Receipt SHA `2d3aa145f4c33871c37423da659034784f14996bdae74b29b1c9e2d17e809401`. Complete native final3 then ran 2,310 tests in 545.894 seconds: 2,261 passed, 49 opt-in checks skipped and zero failed. Receipt SHA `3de67a8dccee948b58c0e756b2232a262925260e27c017347a8f30bf41d164b6`; log SHA `cf85b11fc1e61762f3ec4b7f366e3577c6110812c739dc724a1f73116831932e`; 414-input source freeze SHA `9d92249aa5ac76fa6ec396f3e53c902512501905e5d725dd94462acf297111b6`. All nine required cohorts, same-thread permission boundary, exact five-pair scripted workflow matrix, five patch scenarios, 26 unique cleanup identities and source/resource/engine guards passed. The ten-cycle real WebKit flight case passed within this complete run. These are app/native checks with synthetic model replies where stated, not live provider qualification.

The independent Git deadline verifier matched the three unique passing regressions for inherited output pipes, backpressured input and continuous output in that same final3 log. Its immutable receipt SHA is `8885827916eb890857efa5ba4f678f4f29fcf1038d976b2a41677ab465d06aae`. No tests were replayed by this receipt audit. Installed signed-app parity, actual provider/model workflows, visible diff UI and the fresh benchmark remain pending. Historical negative results remain unchanged.

Eight cataloged obsolete installed backups (builds 13, 15–21) were archived and fully verified before retirement: 2,031,239,051 logical bytes in 690,743,404 archive bytes. The current installed build 39, all 414 validated inputs, the temporary model alias and protected processes were unchanged. Archive/cleanup receipt SHA `a8223fd50d5411ab0fbc3d358435a4fc75d5b3e53d00294b888d3798ff4c6590`. The original model storage was then restored: 46 nodes, 3,061,144,105 bytes, matching content and modes. Its external duplicate and held alias were retired only after internal verification; restoration receipt SHA `a410f91a8caadfd74de48411e51bc50bb87b12125eb846509f06039f2c437836`. No local-model inference or provider qualification is established by these storage operations.

The signed Release build from `8d208184e277043966124bdaf02dcd6c67ca389c` completed with exit 0, unchanged source/resource/engine inputs and passing main, bridge and runtime signatures. Staging then failed its exact AgentRuntime resource gate because Xcode's folder reference also copied the tracked `.gitignore`. No installer ran. The failed stage receipt and signed build remain separate negative packaging evidence. Ignore rules for the same four generated runtime files now live in the repository root, removing this source-control file from the copied resource directory. Application/test inputs and runtime bytes are unchanged; a fresh signed package must still pass the original exact resource and signature checks.


## Installed build 41 and first live ChatGPT failure

The fresh signed package from `2665e219a820bb6f966ebb4c57c5bfd9530b2d9b`
passed exact resource and signature checks, then installed as 0.6.0 (41).
Installed verification passed all 98 checks, receipt SHA
`055d78db562472783517358edbd704cbeced576e070b1a7ad518f676d62972dc`.
The loaded main image, process birth, runtime bytes and new runtime generation
were captured before the qualification prompt. The prior failed signed resource
bundle was preserved; its original negative result was not overwritten.

A fresh ChatGPT GPT-6 marker-read task sent one inference and failed at
`first_user_message` before any native tool call. Automatic website cleanup
returned unconfirmed; the task remains paused and the prompt was not replayed.
The rollout, transaction journal, cleanup journal and finite diagnostics were
retained in `chatgpt-qualification-installed41-r1/first-failure.json`.
The expanded body was 46,575 characters against a 46,593-character outbound
prompt. Exact unique final marker and captured prefix matched; ASCII-normalized
full text differed by 18 characters, with `text_mismatch` latched after one
expansion click. No CAPTCHA or quota classification was observed.

## Build 42 display-stable request experiment

The complete request JSON now replaces literal backticks with JSON Unicode
escapes. The response handoff describes its required JSON fence without literal
backticks. No request value, role, tool grammar, policy or custom patch input is
dropped, and no website ownership guard is relaxed. New regressions compare the
entire parsed request across all three providers, verify literal patch inputs,
include escape expansion in the prompt budget, and reproduce the 18-character
delimiter-loss rejection alongside a strictly verified escaped request.
Focused validation passed 69 Swift tests and 365 adapter tests with zero
failures. Seven public groups passed 623 tests without failures or skips,
receipt SHA `af1034dadc67456a3334ef661a6f5c64dec5ef224df4c9658272d085771e16bf`.
Complete native build 42 validation passed 2,263 tests with zero failures and 49
opt-in skips in 527.297 seconds. All required cohorts, permission boundaries,
workflow/patch matrices and source/resource/engine/cleanup guards passed.
Receipt SHA `f6ea7e75a957080fd3a46608c1c0480242f018707236aacfea129ba69bee9440`. This experiment does not yet prove the live failure's
cause or qualify a provider.


## Build 42 signed installation and ChatGPT qualification

The first packaging invocation stopped in preflight because an incorrect full
source commit ID was supplied; no build or installer ran. The fresh invocation
bound Git's exact `293e86d89a6d3f814c6aa5abdfecca4eef9a4f4c`, passed signed
packaging/resource checks and installed 0.6.0 (42), preserving build 41 as a
rollback. Installed verification passed 98 checks, receipt SHA
`2467c8b20419dc545eef10a16e8c0a476cfc9ac6450bd966d47548603040ed22`.
An initial capture helper incorrectly expected 424 inputs after a build-number
substitution; it failed before any prompt. The corrected helper retained the
414-input guard and passed with a fresh capture receipt, SHA
`d49b4e0377d1cf00108a6536ff7bd170a03b16e286f59e4ff4506cf8acb6001a`.
These helper failures did not change the validated application or engine.

One fresh ChatGPT GPT-6 task completed in 23 seconds. Its exact natural request
produced a real `exec_command` read, a matching output and the expected marker.
Both website inferences completed with normal Chat product/selected GPT-6
proof and durable closed leases before tool/final release. The first collector
passed 37 of 38 checks: its natural-prompt comparison incorrectly concatenated
the app's separate background-interaction policy with the user request. The
corrected check accepts only the exact prepared request and exact policy tied
to the frozen runtime source. Six wrong-content/source controls were rejected.
No model prompt or tool call was replayed during correction or collection.

Sealed copies of the terminal rollout and journals produced a verified
39-check qualification receipt, SHA
`dc63943fa9150193e5a0a03ccdebc6c95993fe7d2da797258272dec91f507960`.
The dependent-workflow qualifier accepted that receipt without creating another
fixture or contacting a model. This is one build/provider/model qualification;
backend model version remains unknown. Four workflows per provider, the two
other provider qualifications, installed diff UI and the fresh same-model
comparison remain pending. The failed build 41 case and its unconfirmed cleanup
remain retained separately.


## Build 42 live follow-ups and build 43 response/selector corrections

Claude Sonnet 5.5 completed the installed opaque-marker qualification in 15
seconds. One native `exec_command` read the actual fixture; the final response
matched its marker. Both inference leases closed with durable cleanup receipts.
The sealed collector passed all 39 checks, SHA
`8eefb284c32c5862b1275ab6a4de9c06181a4d665848ad06f35d0706ca5e6ee8`.
This qualifies the observed website selection, not a backend model version.

Gemini 3.1 Pro failed before verified prompt submission. The local finite error
was `browser_model_error` for unverified selection; no native tools ran and its
one website session closed. The collector remained `incomplete_or_failed`, SHA
`9656526deb2a6ea4cc0e9dd81f45b87e13979c0cd26e682e0faf9f01c7b1fbd9`.
The engine's generic high-demand wording is not a diagnosis of Google's service.
Refreshing the catalog retained the same choices and did not replay a prompt.
A separate normal built-in tab showed 3.1 Pro selected and a separate selected
Low thinking-effort row. That inspection tab was closed and the pane hidden.

The first ChatGPT GPT-6 coding attempt accepted an `exec_command` and a custom
`apply_patch`, then rejected its third inference reply as invalid JSON (716
bytes, no accepted fence). All three website sessions closed. The independent
file/Git oracle failed; the requested rename, tests, selective commit and push
were not fully verified. Its initial failure summary counted only function
calls and omitted the custom call. A sealed correction retains that mistake
and the actual two-call count, SHA
`16a00bb06bfd7a33ec538ed30d97fdb91781deab9276b7bbede90c05b5db1920`.
The exact-turn collector reported the missing requested rename as a
`collector_error`; it did not claim success.

One fresh diagnostic project used an exact-task, private one-shot rejected-reply
capture. After one real read command, the model returned progress prose outside
a code block containing otherwise valid tool-call JSON. The 916-byte reply was
rejected without dispatch; both sessions closed and the capture arm was
consumed. The private snapshot SHA is
`3db7e6388a98709e277a1dbe17828927242a6aae2cd8e59e46f3bebeebd9a045`.
The previous unrelated capture was preserved by a reversible private rename.
Raw replies and native histories are not included in this public ledger.

Build 43 adds optional `tool_calls.commentary`, mapped into the existing
Responses assistant-message phase before the validated calls. It does not
extract JSON from surrounding prose or weaken tool choice, call-count or
parallel-call restrictions. The response instructions demonstrate progress
inside this envelope. Three new codec regressions cover stream/output ordering,
function/custom calls across providers, malformed commentary, external prose
and dispatch restrictions. The existing native workflow now observes all 12
progress messages and still completes 13 inferences and 12 matched real tool
outputs for each provider route. Focused validation passed 114 Swift tests.

A Gemini fixture with a separately selected thinking row reproduced the original
`model_unverified` failure before the selector change. The shared helper now
excludes recognized Low/High effort rows from model-selection proof. The helper
prefix was copied into all three standalone adapters without modifying their
provider-specific bodies. All 366 adapter tests passed, including missing-model
proof and the prior contradictory/duplicate/unknown-indicator controls.

The first complete build 43 public run passed frontend checking, 123 frontend
tests and frontend build, then stopped on two MLX installer tests: the host had
only 466 MiB free, below the installer's disk-space guard. The other 109 MLX
tests passed. This failed receipt remains preserved and native validation was
not started by that invocation. Candidate installation and live verification
remain pending.

The owned temporary Cargo/Rustup toolchains were archived and byte-verified
before retirement; the archive SHA is
`39bc051fcf2cdd8249cd53b9987394e56071c3cfedffda6981cd55647cf19cc4`.
This recovered about 1.1 GiB on the host without touching model assets, user
toolchains or the qualified engine. The fresh public run passed all 624 tests.
Complete native validation executed 2,315 tests: 2,266 passed, 49 were skipped
and none failed in 509.268 seconds. Exact source/resource and engine seals,
required permission-boundary checks, five workflow scenarios, the native patch
matrix and actual cleanup identities all passed. The prior disk-space failure
is retained. This is offline evidence; installed build 43 remains pending.

Public receipt SHA: `ad4b410fb2823c4a1cefefdf8c40fe5094ee11b1548e630cbb9b6f4bea83f9aa`.
Native receipt SHA: `8340e99958d5d4b8949c21b0c6e7ab5aa1d22dce088255568b0c470ff423c6f1`.


## Installed build 43 follow-up and inline-wrapper candidate

Commit `8043da18cdc104532b78ede867f478d87120a116` was pushed to draft PR #5.
The signed build and installed bundle passed all 98 checks. A new process,
PID 49165, reported runtime generation `2c01e38c-a04a-4570-8f5a-23066484e690`;
the sealed runtime capture SHA is
`81321e6a27a358118f5d61589fccc8c764c34b1fb4921461eb12ad4144b6d416`.
The prior build 42 is retained as an installation rollback.

Claude Sonnet 5.5 and Gemini 3.1 Pro each passed all 39 exact qualification
checks, with a real marker-file read and two acknowledged/closed website
inference sessions. Their collector receipt SHAs are, respectively,
`db92779f98a7fc9203a60bdb29bd5e4ea8dee4c9ebf446ce1288f7fa075add35`
and `a148ccd90c76dfe15bd3bbb3789825822f33e1c07780434d1425bbeebf210b74`.
Gemini's selection failure did not recur in this controlled task.

Claude's coding workflow completed the edits, exact-content rename, deletion,
README, tests, selective commit and push to its disposable local bare origin.
The user-note bytes and public tests were preserved; the pushed head matches the
local commit. The independent coding oracle SHA is
`cb98ee7cb65d999dee562ddb66962a0b46ecb5c7d3e0acb211953ba35630dded`;
the exact-turn collector passed, SHA
`30ba8aad3180bc57e6cdfb89e8b64d2d2f85fefe9e9e63f4f22a1859cc962a7b`.
All ten inference sessions closed. The model recovered from a nonportable cat
flag, a rejected empty rename hunk and a stale path in git add by checking
actual state before retrying. This does not qualify external GitHub pushing.

The first build 43 ChatGPT qualification failed with a 532-byte malformed
response; no tool calls were dispatched and its one session closed. Its failed
collector SHA is
`3faab3550a918ca12f21fa9fb340ce4a8437d3842f0b8be8ac9d7f538c96a6d8`.
One fresh diagnostic qualification also failed, retaining an exact-task private
545-byte reply: a complete JSON tool envelope between triple backticks on one
line, rather than a newline-delimited fence. It had no code DOM nodes or outside
prose. Its private capture SHA is
`1c5e54623ad5dfd55562b21ceacdec3a6a3b92eb483b9fecd95612b5ce12885f`;
its failed collector SHA is
`0213a4ed3fe0e4617efb4b0d6cc060dd07e162bc70b60dd305f8ed274e2ce2f7`.
The capture arm was consumed and its single website session closed. Neither
failed attempt was replayed or counted as a qualification pass.

The build 44 candidate accepts only the complete inline JSON wrapper, retains
full-body JSON parsing and the existing tool dispatch restrictions, and asks
for canonical newlines explicitly. A synthetic reproduction failed against the
old parser. New regressions cover all provider routes, literal custom-patch
backticks, outside prose, multiple fences, malformed/unsupported labels, damaged
JSON and disallowed/unoffered tools. The first focused run passed the parser,
server and three real scripted workflows but failed six assertions tied to the
old prompt wording; these were updated to require the new newline instructions.
Complete build 44 validation and installed testing remain pending.


Claude's built-in-browser flight workflow also passed the exact-turn collector,
SHA `868d6ab525704477649d2d11be0cfb7b07e8aa39bf9b6a00d783fe066de75866`.
It used the synthetic site's search, details and gate-reveal actions through the
native browser tools. All thirteen website inference sessions closed. Root
stopped its exact owned loopback fixture server and observed normal exit 0
before sealing the browser/HTTP evidence. This does not test a real airline
account or booking service.

Claude's composition case then stopped on `website_usage_limit` after starting
the preview. All four website inference sessions closed. The exact-turn
collector remains failed, SHA
`d96075e110c36252b0243cbb05353ceba98f5259ec9fef9756c56783f6e67e47`.
The preview initially remained running; root verified its exact owned cwd and
listening socket, sent SIGTERM to PID 59173, then independently verified that
PID and port 57423 were closed. This is root fixture cleanup, not a successful
model-driven stop. No Claude prompt was retried; its remaining composition and
interactive checks require the provider quota to reset.

After updating the prompt assertions, focused instruction validation passed.
Complete build 44 validation executed 2,317 native tests: 2,268 passed, 49 were
explicitly skipped and none failed. The native duration was 525.444 seconds.
All required permission, workflow, patch, source/resource and engine/cleanup
guards passed. All 624 public tests passed too. Signed installation and fresh
ChatGPT qualification remain pending; prior failed captures stay retained.

Public build 44 receipt SHA: `9676bbfdecf3122075c9cef8238a702d4647d0e7ca0a9accafd2113b9a6c024c`.
Native build 44 receipt SHA: `865c910bdf8fa9ffa8caf24b425cbc7a6aef59beb1f94f0d47edea2bfa980ab2`.


### Installed build 44 and retained Gemini verification failure

Commit `4f4bf368be5cc189e691b609edd31ea74078c8a3` is pushed to draft PR #5.
The signed build 44 installation passed all 98 bundle/source checks. The
installed verification receipt SHA is
`4acdb923b9c5f37bb74fa3569550dd7e23f1b6f55ff769b8aba1b5fa1b7dedc4`.
The running build 44 process and fresh runtime generation were captured before
any benchmark prompt; capture SHA
`51dfbf0ee247e73db1d559c8ed3134975c021ec1a92202ff4b10086433e7dc8e`.
The first capture invocation used a relative receipt path and was rejected;
that failure is retained separately. The successful invocation used the
required exact absolute path. Build 43 is retained as an installation rollback.

Gemini's build 43 coding task stopped on `website_verification_required` with
zero native tool calls and zero verified submissions. Its website session
cleanup remains unconfirmed (`cleanup_unverified`); local receipts are retained.
No prompt was replayed, and no later Gemini workflow was submitted. The coding
collector also failed to produce a completed report because the requested
renamed file did not exist; this collector error is preserved, not counted as
a pass or as evidence of cleanup. Collector SHA:
`477913a356f7977fff5ee7d334ccf2fe8384362fbd9a7e3dbdb4d2750feb7116`.
An explicit first-failure record retains the task, turn and lease identifiers.
Automated Gemini testing requires controlled recovery of the verification
checkpoint and uncertain session. Claude remains stopped on quota.


Fresh ChatGPT GPT-6 qualification on installed build 44 passed all 39 checks.
It executed a real marker-file read, returned the exact marker, and acknowledged
and closed both website inference sessions. Exact-turn collector SHA:
`4e0ef0c68e04863cd113c47136c5ea6f00826de0603fb4f216d95191c8cc7a59`.
This qualifies this controlled provider/model task, not its broader workflows
or an independently attested provider backend version.


ChatGPT's installed build 44 coding/Git workflow passed the independent file
oracle and exact-turn collector. Both tests passed, the rename preserved exact
helper bytes, the dirty note and public tests were preserved, and local and
disposable bare-origin heads matched commit
`c01315fb0c9b133dec3adbbc737029afc227ddd4`. All nine inference sessions closed.
Oracle SHA: `c1be743be328349c2f9160e821da9a238ae67ec9a74994bb513aa947dd3be427`.
Collector SHA: `a60a8f16a13c03f89bbcce022edf84011e537ec94ca5a6ee8e460be5f042c978`.
The model caught and corrected its whitespace changes before committing.

The next ChatGPT browser case stopped on `browser_model_error` /
`first_user_message` before any native tool call. One lease was acknowledged
and none was confirmed closed. Its failed collector SHA is
`c333d2f627e766e297052b12b42b20aa27a86420cc8d4f3efc17c280ef2f4169`.
A bounded structural diagnostic confirmed one matching marker and an expanded
message mismatch; the exact rendering cause is not established. The original
failed attempt remains retained and was not replayed. Root stopped only the
owned flight fixture server and independently verified its PID and socket
closed. That local process cleanup does not prove website-session cleanup.
Further ChatGPT website tasks are paused pending diagnosis and controlled
recovery. Its earlier qualification and coding pass remain separate evidence.

### Installed diff checks and native select commit regression

A separate disposable build 44 review project passed exact local-model edits
and independent preservation of its pre-existing files, Git index and HEAD.
Installed checks then passed unified/split/wrapped views, hunk collapse and
expansion, selective stage/unstage/revert, stale-state mutation rejection,
binary notices, file filtering and read-only branch/commit comparisons. Each
mutation was checked against actual files and index contents. The stale
attempt preserved the concurrent edit and left the index unchanged.
The ChatGPT coding case also exposed its recorded last-turn patch changes as
read-only; that view is not a substitute for a current Git diff after later
shell edits.

Selecting a scope after switching tasks exposed a real inconsistency:
the dropdown showed Unstaged while the native state and explanation stayed
Last turn. The retained receipt is `scope-switch-failure.json`, SHA
`1a6369fafba13cf667b8f54f71f763e3e08bf7ad6d8de1ac234c8917560cc76b`.
An offscreen test of the actual bundled Octane UI and WebKit/native bridge
reproduces commit-only selections: all four scope selections failed to reach
native state with the old `onInput` handler. The select now listens to its
native `change` commit event. The same regression passes after rebuilding
the production bundle. Type checking, all 123 frontend tests, and all 16
native review/pane tests passed. This source correction still requires a new
installed artifact and the corresponding live UI check.

The task-created build 39 installed backup was archived to
`/Volumes/t7/computa-owned-backup-archive-build39-20261011`. All 77 members,
file contents, modes and symlinks matched before its internal duplicate was
retired. Archive SHA:
`d83749af87f251086e8581a2f25bce80f4b0bec0bbc03e057512d2b85a14edce`.
The installed build 44 and its build 43 rollback backup were retained.

### Candidate 45 validation and disk cleanup — 2026-10-10

The first candidate 45 public run stopped at two tiny fake-download installer
tests because the host had less free space than the production 512 MiB reserve.
The production guard remains unchanged. Successful fake downloads now use
controlled capacity. A regression checks one byte below the reserve, exact
capacity, staging cleanup, preservation of an unrelated file and reuse of a
verified existing model with zero free space. All ten installer tests passed.

The next public run passed every declared cohort: 123 frontend, 112 MLX,
366 provider-adapter, three instruction and 21 identity/version tests, plus
type checking and production frontend bundling. Its packaging check then
rejected a stale resource inventory naming the old JavaScript asset. The
successor inventory changes only that generated asset name; command definitions,
source-input membership and test requirements remain unchanged. A separate
sealed receipt reuses the seven successful immutable logs, verifies unchanged
audited source and checks the actual generated resources. Both original failed
receipts remain retained. Public receipt SHA-256:
`66592227ee9df243886f57ae93ea865425ecf80322e122ec53863202705b57db`.

Complete native validation executed 2,318 tests in 505.698 seconds: 2,269 passed,
49 were explicitly skipped and none failed. All required permission, workflow,
patch, source/resource and actual fixture-cleanup guards passed. The packaged
engine stayed byte-identical. Native receipt SHA-256:
`3148f894cb32a36564b43014808c7e6cf0de19e0d694f1be59c7802dbe6bbf44`.
Candidate 45 therefore has 2,894 passing public/native tests. Installation and
the native scope-selector UI recheck remain separate qualification steps.

The first-message diagnostic now reports a finite pair of syntax/spacing labels
at the first mismatch. It does not log raw characters, Unicode scalars, letters,
digits or prompt text. The actual WebKit expansion and native sanitizer tests
passed. This improves diagnosis; it does not change message ownership checks,
replay an inference or establish the cause of build 44's rendering mismatch.

At the user's cleanup request, seventeen obsolete Computa backups below build
43 were removed after checking their identity; installed build 44 and rollback
build 43 were kept. Regenerable Rust object/metadata/archive/dependency files
were removed from the owned test/release build directories. All 560 retained
runtime executables and libraries kept their file identities, and the packaged
engine hash stayed unchanged. Cleanup freed approximately 35 GiB across the
two disks. Source, active model files, test reports and benchmark traces were
preserved. Future Rust source changes will require recompiling those removed
intermediates.

All six build 44 local-model comparison trials are graded and failed the full
task. Their twelve disposable project/origin directories were archived,
member-hash verified and removed. The separate comparison report records these
failures and the limits of goal-mode evidence; passing regression tests do not
turn a failed model task into a pass.

### Installed build 45 and quote-rendering follow-up — 2026-10-10

Build 45 source `cdd13de7d41d81db5375aecf9677ac69cd1bf3d3` is signed, installed
and pushed to draft PR #5. Staged and installed verification each passed 98 checks.
The installed receipt SHA is
`6f04d4811e6bbc07688144c5e6e1ddf6778c4d116a6b5cc7122f9deaf2b75e4c`.
The running app is PID 32628, generation
`3f962ae1-8350-4f96-927d-dca3d7f762b6`; capture receipt SHA is
`f167957fbfdf8d92c88f59177f0ce832215f4300f9ea47a8960a5e00e9abaa50`.
An initial private capture helper still expected build 44 and failed before
startup capture. The corrected helper retains the same checks with build 45
identity guards; the original failed receipt is preserved.

The installed diff scope recheck passed Last turn, Unstaged, Staged and Against
branch, including Unstaged after switching chats. Independent snapshots retained
the same HEAD, index tree, status, files and diffs. Recheck receipt SHA is
`59e4d51ba48a9b9b92f3da55bec45887a058a8969e15c00d6a6d38df5d06f667`.
This rechecks scope selection; build 44's earlier hunk-mutation observations
remain separate evidence.

Fresh ChatGPT GPT-6 qualification `chatgpt-qualification-installed45-r1` passed
all 39 checks, a real marker read and two closed website sessions. Collector SHA:
`388495299745a8ecec0efdce072c34d92933a7156f0901a55a9674d5ccb2e1b5`.
The subsequent fresh browser case `chatgpt-browser-installed45-r1` failed
`first_user_message` before any native tool ran. Its one acknowledged lease
has no verified closure; collector SHA:
`a169d368aab1ff7c35ef735bcf6518dab6ec769da354832b50c2e92c314df133`.
The owned synthetic flight server PID 35836 exited zero and port 64669 closed;
that local cleanup does not confirm website cleanup. No failed prompt was replayed.

The bounded diagnostic was accepted. The first actual character was a backslash
where a double quote was expected, at offset 13764. ASCII-normalized prompt and
rendered lengths were 46882 and 46899; their 10108-character prefixes matched.
No extra Unicode space or format characters were counted. Diagnostic receipt SHA:
`b100ebc1ef01f28483e202a5593968ec130dde39ba1c3d5ac9ff4e464469203c`.
The two identical logged text observations are not two inferences. Read-only
queries initially omitted INFO or assumed a single observation; those collector
errors did not change the app or its result. The emitting website component
and full transformation have not been established.

Candidate 46 represents JSON string quotes as `\u0022`, alongside the existing
backtick escape. Complete escape pairs preserve literal backslashes, Unicode
escape text, quoted keys, history and parsed request values. Prompt limits count
the expanded bytes. A controlled WebKit fixture inserts the observed extra
backslash before 17 escaped quotes: the original request fails ownership, while
the equivalent encoded JSON completes after one insertion, one Send and one
expansion. This simulates the observed difference; it does not establish the
website's cause or a live fix. All ownership predicates remain unchanged.
The two new codec regressions fail against the old codec; after implementation,
59 focused codec/WebKit tests pass. An invalid first test fixture and a test-only
async assertion compile error were corrected, with original logs retained.
Full candidate validation, packaging, installation and fresh live verification
remain pending at this checkpoint.

Candidate 46's first full native run executed 2,321 tests with 49 skips and
two assertion failures in one instruction test. All other 2,271 cases passed.
The shared test helper still sliced the display payload using the original byte
length; quote escaping correctly changes that length. Its correction compares
the complete parsed request values and the exact following current-user and
response contracts. Production code is unchanged from the focused run. The
failed native receipt and source freeze remain preserved; they do not qualify
the candidate. All seven public groups will run again against the corrected
test source before the second complete native run.

Candidate 46's second complete run passed: 2,321 native tests executed,
2,272 passed, 49 explicitly skipped and zero failures in 526.946 seconds.
All four quote/instruction regression cases have one actual PASS record each.
The required permission boundary, provider workflow/patch matrices, 26 unique
fixture cleanup records, unchanged frozen engine and all 414 input bindings
passed. Native receipt SHA:
`5b9bf12f8d375616af76819cd4fc8b1401d300ba2df4bd5d4a85225d85a2fd66`.
The fresh public run passed all seven groups and 625 tests with zero failures
or skips; receipt SHA:
`c0bfee3ec266432e3c15aa15147dab32bb15424b551a28f644076709b584f64b`.
Together these are 2,897 passing app/public tests and 49 declared native skips.
The original failed run remains unchanged. Signing, installed identity and live
website behavior are separate gates and remain pending at this checkpoint.

### Installed build 46 and remaining markup mismatch — 2026-10-10

Source `dee317a1c70c7df10c9c12b1842762a3fdebfd8e` is pushed to draft PR #5.
The signed stage and installed bundle each passed 98 checks. Installed receipt
SHA: `50cd2c5c14c48de4c2f602de89cdcf1979111fb441b0ecd675f08312fb03a419`.
Running PID 63671, generation `9ea78cab-954b-4762-9462-0710fab0a0cf`,
passed strict capture; receipt SHA:
`003bc4912181a42717b926f3b641d01b5412b1a5cd81e4b094554366cf1036e0`.
The initial capture invocation omitted a required receipt argument and exited
before observation; the corrected invocation passed. Previous build 45 is
preserved as an installation backup. The three unrelated protected PIDs remain
running.

Fresh ChatGPT GPT-6 qualification `chatgpt-qualification-installed46-r1` passed
all 39 checks, a real marker read and two verified session closures. Collector
SHA: `e761b47953b44af2cbe118143a2beeab9e12f7d2ba133c73db451061f5420b33`.
The fresh browser case then failed first-message ownership before native tools.
Its one acknowledged session has no confirmed closure. Failed collector SHA:
`c3d8a0d421d60a7f641527807d3589394a7fae31887c5d7ebc7b72a79bb03da3`.
The owned synthetic server PID 65585 exited zero and port 50951 closed; local
cleanup does not establish website cleanup. No failed prompt was replayed.

The new first mismatch is an extra backslash at an expected less-than sign,
offset 13917. Normalized lengths are 47362 expected and 47367 actual, with the
10108-character prefix intact. The two identical text diagnostics are repeated
observations of one inference. Diagnostic SHA:
`15873802930b24b2fb27da7e53e6be60b4f67bf8a500b2da50a2802d9ecfe722`.
The quote encoding did not establish a live browser fix: the discrepancy moved
from 17 extra characters to five. The emitting website component is still unknown.

Candidate 47 also encodes literal HTML delimiters `<`, `>` and `&` inside the
validated JSON as equivalent Unicode escapes. Escaped quote handling, literal
backslashes and Unicode escape text are preserved. Round-trip checks cover all
three providers, message roles/history, quoted metadata keys, tool descriptions
and custom grammar. Both quote and HTML expansion count toward the prompt limit.
The controlled WebKit fixture now rejects a 17-character quote/markup alteration
and the five-character markup-only alteration, while the encoded request passes
after exactly one insertion, one Send and one expansion. This simulates the
observed patterns; it does not prove the website cause or live behavior. All
60 codec tests and this WebKit case passed. Full validation, signing, installation
and fresh live verification remain pending for candidate 47.

### Build 47 complete validation checkpoint

The canonical public receipt `public-validation-build47-final1.json` passed all
seven groups, with 625 tests and zero failures or skips. Native validation
`native-build47-final1-validation.json` executed 2,323 cases: 2,274 passed,
49 explicitly skipped, zero failed, in 540.888 seconds. Required permission,
provider/workflow, patch and cleanup guards passed; all 414 frozen inputs and
the packaged engine were unchanged. The three quote/HTML rendering cases and
two new HTML codec regressions passed in the complete run.

The first launcher invocation supplied a relative public receipt path and was
rejected before native tests or a source freeze were published. The unchanged
controller succeeded with the canonical absolute path. This is a validation
launcher error, not an application failure. All predecessor evidence remains.
Build 47 still requires signed staging, installed verification and a fresh live
qualification before any browser workflow can be claimed.

### Build 47 installed qualification and fresh browser failure

Source `26654e6a27a354276a45e63fdd18db2d410aebb3` was pushed to the draft PR.
Signed staging and installed bundle verification each passed all 98 checks.
The new installed process was PID 85324, runtime generation
`d4f2cc07-8962-437d-b071-5fa8d5f06cb1`; strict startup capture passed.

`chatgpt-qualification-installed47-r1` passed all 39 checks, a real native
marker-file read and two acknowledged/closed inference sessions. The fresh
`chatgpt-browser-installed47-r1` case failed first-message ownership before
any native tool call. Its receipt is `incomplete_or_failed`, with one
acknowledged lease and zero verified closures. No prompt was replayed.
Bounded exact-PID diagnostics show two extra ASCII characters, beginning with
a backslash at an expected underscore at offset 19,592. The first 10,108
characters match exactly; Unicode-space and format-character counts are zero.
The actual emitting website component remains unidentified. The previous
HTML mismatch is absent, but a live browser fix is not established.

Root independently verified and stopped only its owned fixture PID 86479 and
confirmed port 52528 closed and wrapper exit 0. This local cleanup does not
prove website conversation deletion. Failed provider evidence remains retained.

### Build 48 punctuation candidate

A small JSON string lexer now encodes all printable ASCII punctuation in string
keys/values, including underscores and literal backslashes. JSON structure,
control escapes and non-ASCII bytes remain intact; parsed request values and
strict ownership admission remain unchanged. The expanded byte limit still
applies before submission. Focused validation passed 81 tests: 62 codec,
18 instruction and one WebKit test with five controlled cases.

The first focused run retained old raw-text assertions and used an unsupported
non-default temperature in a new fixture; these were corrected to decoded-value
checks and a supported numeric field. Its simulated underscore mutation also
touched the fixed instruction prefix, unlike the live diagnostic, so the
mutation is now scoped to the complete request JSON. The original failed log
is retained. Complete candidate validation and installed/live checks remain.

### Build 48 complete validation checkpoint

All seven public groups passed with 625 tests, zero failures and zero skips.
Native validation executed 2,325 cases: 2,276 passed, 49 explicitly skipped,
zero failed, in 522.468 seconds. The five controlled WebKit cases and new
punctuation/value/byte-limit regressions passed in the full run. Required
permission, workflow, patch and cleanup guards passed, with 26 verified
cleanup records, all 414 frozen inputs unchanged and unchanged engine bytes.

Review caught an accidental run-ID regex-limit change in preparation helper 14
from a broad build-number replacement. Helper 15 restores the exact original
47-character suffix bound; its delta from qualified helper 13 allows only
explicit build/receipt identities. The initial shape-only audit's acceptance
parity statement is superseded by the correction and explicit-constant audit.
No live prompt or runtime capture used helper 14; its unused fixture is retained.
A fresh helper-15 qualification fixture is prepared. Shipping controller
acceptance checks and test floors were unchanged. Signed packaging, installed
verification and fresh live qualification remain required.

### Build 48 installed qualification and partial browser progress

Source `802499b776e12c6132210273f6bce0eedeae6e6e` is pushed to the draft PR.
Signed staging and installed verification each passed all 98 checks. Strict
runtime capture recorded PID 928 and generation
`cf8a4c4e-e324-40a9-b182-3bee8a218523`.

`chatgpt-qualification-installed48-r2` passed all 39 checks with an exact native
marker read and two acknowledged/closed inference sessions. Its fresh browser
case accepted the longer request and executed eight native browser calls. HTTP
logs independently confirm landing-page and search-page reads, exactly one
correct-flight search submission, and details navigation. It did not perform
the gate action or return a final supported response: a later native adapter
`inspect` exceeded its 10-second call deadline. The case remains failed; no
prompt was replayed. All eleven acknowledged website leases closed, and root
verified its exact fixture PID 1908 and socket 53757 closed with wrapper exit 0.
The string encoding resolves the observed ownership barrier for these
inferences; this partial task is not a qualified complete browser workflow.

### Build 48 Claude composition and interactive qualification

A fresh Claude Sonnet 5.5 marker case passed all 39 checks with two closed
inference sessions. Its localhost composition case observed the applied name,
revision and receipt through three fresh native built-in-browser reads, then
sent decoded Ctrl-C to the exact session observed in the real startup output.
Native completion recorded exit 0 and matching PREVIEW_STOPPED; root confirmed
PID 7741 absent and port 54285 closed. All twelve website leases closed.

The original composition grade failed two checks. Its stop regex omitted the
PTY's literal ^C echo before PREVIEW_STOPPED, and its blanket CLI/telemetry ban
also prohibited legitimate shutdown verification after the browser result and
native stop. Collector 15 admits only one optional ^C echo and a finite,
read-only PID/HTTP/closed-state probe after the exact observed stop. Browser
receipt evidence, actual native completion and independent fixture truth are
still mandatory. Twenty-six controls passed, including wrong-session/PID,
premature telemetry, fabricated browser results, HTTP writes, extra commands,
other origins/routes, altered state and nonzero native completion rejection.
The unchanged sealed case regrades verified (receipt SHA-256
f8a2490f85bd327284a2c0fee20ea5c2610271e1332477a279a9e6f9301d20be).
The original failed grade remains retained; no model request was replayed.

Claude's fresh interactive case used one observed TTY session, submitted both
requested inputs, observed both exact replies and native exit 0, then received
Unknown process id for real nonempty input on that retired session. All five
website leases closed. Its initial final-response grade required a contiguous
reply label and value, rejecting the model's paired Markdown code spans.
Additional oracle 4 preserves exact label/value identity while accepting a
paired code span; eight data-only controls passed, including previous ordered
transcript regressions, changed/reversed replies, incomplete spans, nonzero
exit and claimed acceptance rejection. Collector 17 regrades the unchanged
sealed case verified (SHA-256
efcc073393d6dbee7af89a1e88182159a847ec878e568de9b580099e43485e2a).
Native session, input, output and rejection checks were not relaxed.

### Additional owned space cleanup

The earlier cleanup removed seventeen obsolete app backups and 30,475
regenerable Rust compilation intermediates, about 35 GiB combined. A further
1,022,836,736 allocated bytes of build 43-46 backups were removed only after
complete relative file/type/hash/link equality with retained signed stages.
The installed build 48 and rollback build 47 were independently hashed before
and after and are unchanged. Source, model weights, evidence, retained runtime
executables and unrelated projects were preserved. The duplicate-backup
controller's first preflight encountered a historical empty backup directory;
it made no mutation, then was corrected to preserve that directory explicitly.

### Build 48 Gemini controlled recovery and readiness failure

Gemini's first fresh marker case stopped at the saved verification checkpoint
before any website submission or native tool. Its cleanup remains unconfirmed;
no absent transaction journal was fabricated when collector 14 could not seal
that nonexistent file. The bounded blocker receipt and three sealed evidence
files are retained. The normal built-in-browser Gemini page was signed in and
showed no challenge. One explicit, prompt-free model refresh completed and
cleared the persisted checkpoint through the production recovery path.

A distinct fresh marker case then passed all 39 checks, a real native marker
read and two acknowledged/closed website sessions (receipt SHA-256
7cefa6d581fd2ab2eef796dd202aaabf69429277da0e95f606db3be78afd9490).
Its subsequent fresh coding case stopped at the 45-second preparation deadline,
with zero verified submissions and zero native tool calls. The one startup
session closed with reason not_created. The fixture remains unchanged.
Collector 14's independent coding oracle raised FileNotFoundError for the
expected rename that never happened; its collector_error receipt is preserved
as a collection limitation, not a successful workflow. The website failure is
provider_timeout. No prompt was replayed, and remaining Gemini workflows are
stopped pending a concrete readiness correction and fresh qualification.

Exact-PID info logs show one initial coding-session readiness observation with
a composer present, temporary mode false and no temporary action available;
no later inspection observation appears before the deadline. This does not
identify the underlying cause. The DOM wake channel currently relies on a
100 ms JavaScript timer; timer starvation is a candidate for controlled testing,
not an established cause of this live failure or ChatGPT's inspection timeout.

### Build 49 native DOM notification batching

All three website adapters now post actual DOM changes immediately through
their existing private, owner-bound message handler. The native channel batches
bursts once per 100 ms on its monotonic clock. Closing the channel cancels the
pending batch; navigation and profile changes still signal synchronously.
There is no recurring poll. Existing origin, ownership, proof and action guards
remain unchanged. Model-proof waits still contain website timers; this change
does not establish the cause or resolution of the earlier live failures.

Focused validation passed all 366 adapter tests and five native signal tests.
The three notification tests each failed against the previous build 48 source
with its page timer queue undrained, and passed against build 49. This confirms
that the regressions detect the dependency being removed.

Complete validation passed 625 public tests and executed 2,328 native tests:
2,279 passed, 49 opt-in tests skipped, zero test failures. All 414 frozen inputs
and the packaged engine remained unchanged; the five provider/scenario
workflows, patch matrix, permission boundary and 26 unique cleanup records
passed. The original native receipt failed its coverage guard because it still
declared 38 browser-session tests rather than the new 41. The immutable log was
regraded with that exact count correction and six negative controls, without
replaying tests. The failed receipt and original log are retained. Corrected
receipt SHA-256: 47c60effdc49aef1b10da975606028de3f7367c2a0a4391d3e41dd9aca77d5c7.
Public receipt SHA-256: 54096323f640b3ca9c37e1a03d3279ff53cd6d115ad31116280ed6047576747a.
Signed staging and installed verification each passed 98 checks. Computa
0.6.0 (49), compiled from 4876590724eb495187a62ccff1967a99c44c3b25,
was installed with build 48 retained as a rollback. The running process and
runtime generation were captured independently.

Fresh marker qualifications passed for Gemini 3.1 Pro, ChatGPT GPT-6 and
Claude Sonnet 5.5. Each passed all 39 checks, including a real native marker
read and two acknowledged/closed website leases. These small qualifications
do not establish full workflow reliability.

All three subsequent workflow cases failed. Gemini coding performed an initial
terminal read, then its second inference hit the preparation deadline. No edits
or commit occurred; both leases closed. ChatGPT browser use performed nine
native actions and reached search/details navigation, then an inspect operation
hit its 10-second adapter deadline. All ten leases closed. The owned synthetic
HTTP server was separately stopped, with its exact PID absent and port closed.
Claude composition completed initial project reads, then hit a website usage
limit before starting its preview; all three leases closed. Gemini and Claude
collectors also raised missing-effect errors for work never performed. Those
original failed receipts and immutable traces remain intact; separate finite
projections verify the provider failure and cleanup without qualifying effects.

Exact-PID diagnostics show the Gemini second-inference readiness observation
with a composer, temporary mode false and no temporary action available, then
no further observation before its deadline. ChatGPT records an inspect timeout
without an await-phase diagnosis. Native DOM batching has not resolved either
live failure. Shared model-proof waits still use page timers, but their causal
role remains unproven. Further controlled diagnostics are required.

A subsequent normal Gemini browser tab showed Google's unusual-traffic CAPTCHA.
The persisted Gemini human-verification gate was independently confirmed.
That later observation does not prove the cause of the earlier readiness
timeout. No challenge was completed and no failed prompt was replayed. Gemini
is blocked on human recovery; Claude is blocked on quota reset. The current
full live workflow matrix remains unqualified.

### Build 50 bounded adapter diagnostics

Each native adapter evaluation now gets an ephemeral operation ID. A separate
notification-only handler in its existing private WebKit content world records
up to eight fixed phase names. It requires the exact view, main frame, owner,
operation, document generation and pinned HTTPS provider origin. Unknown fields,
unknown phases, stale operations and foreign frames/origins are rejected. The
handler neither advances the DOM revision nor grants page or tool authority.
Concurrent evaluations supersede diagnostic state without rejecting the existing
production operation. Closing the tab removes both native handlers.

Adapter and preparation deadline logs synchronously include the last phases,
bounded native dimensions, attachment/visibility flags and saturated DOM signal
counters. The snapshot requires no second JavaScript evaluation. It contains no
prompt, response, page text, URL, cookie or operation token. The existing one-shot
completion and deadline rules remain in place; this instrumentation does not
claim to fix the live inspection stall. Preparation errors now say that the
current website inference was not submitted, avoiding a misleading implication
that earlier inferences in the user's task never ran.

Focused validation passed all 372 adapter tests and three native diagnostic
tests. The native tests cover foreign, stale and same-origin child-frame
receipts, unchanged DOM revisions, bounded phase history, a deliberately stalled
first-message digest and ignored late completion. Initial fixture runs failed
because an unrooted promise was rejected before the timeout and production
navigation correctly rejected about:srcdoc. Those logs remain; the controlled
fixtures now retain the promise and allow only their local child-frame setup
while independently testing the production message handler. The three new
adapter diagnostic regressions fail against the previous build 49 source, with
zero website prompts sent. Missing/throwing diagnostic sinks leave adapter
results unchanged.

All seven public groups passed 631 tests with zero failures or skips. Receipt
SHA-256: a7834ab5ae3115607ecac4d822324c8e1eedb3fd0adccba536fbab49497aae5a.
Complete native validation executed 2,331 tests: 2,282 passed, 49 opt-in tests
skipped, zero failures, in 516.472 seconds. All 414 frozen inputs and the engine
artifacts matched. Required suite, permission, workflow and patch guards passed;
26 unique cleanup identities verified. The declared browser-session suite size
was updated to 43 before the run. An independent audit verified the original
receipt and immutable log without rerunning tests. Native receipt SHA-256:
ea9d50f90823807eb7df323bea9ca53db4256701dd9edb62a03de989a82e44ba.
Signed staging and installed verification each passed 98 checks. Computa
0.6.0 (50), compiled from afa950a921749579e3b720b32445cf2da355d006, was
installed with build 49 preserved as a rollback. Its fresh runtime generation
and process identity were captured before any benchmark prompt. A redundant
staging preflight expected the label verified rather than the verifier's actual
success label passed; the correction audit confirms all 98 checks passed and
the exact source/build matched. The canonical staging controller had already
verified the artifact.

The fresh installed ChatGPT GPT-6 marker qualification passed all 39 checks,
including a native file read, exact marker and two acknowledged/closed website
leases. Its subsequent browser experiment performed seven native browser
actions and submitted the synthetic flight search. The eighth inference then
failed at the inspect deadline before details navigation, gate observation or a
final answer. The original collector remains incomplete_or_failed. All eight
leases closed. The exact owned HTTP fixture PID was stopped, its port refused
connections, and one server_closed event was independently recorded.

The exact-PID timeout log reports phases adapter_entry, first_user_hash,
page_action, model_proof and model_wait. The native render surface was attached,
not hidden, and in a visible, nonoccluded window. All 70 DOM notifications were
accepted, with revision 37. This localizes the outstanding await to the shared
model-verification wait; it does not prove why that wait was still pending.
The current phase history lacks elapsed times, so it cannot distinguish a
delayed website timer from earlier evaluation work consuming the overall
deadline. No failed prompt was replayed. Further diagnosis and a bounded
native-clock wait mechanism remain under investigation. Gemini CAPTCHA and
Claude quota blocks remain external gates.


## Build 51: native one-shot deadlines for shared model verification

Build 50 localized the ChatGPT browser failure to a model-verification wait,
without elapsed phase times. Build 51 makes the shared verification deadline
independent of website timers through a private-world native one-shot clock.
DOM changes still wake the existing condition immediately. A clock reply only
expires a wait; model selection and conversation ownership must still provide
positive proof. The reply handler accepts exact owner/operation receipts from
the pinned provider main frame and document generation, bounds delay to
1–10,000 ms and outstanding clocks to 32, and cancels pending replies exactly
once when the operation is superseded, ends, or its tab closes. Native
operation/phase ages are bounded metadata and contain no page text.

All 378 adapter tests passed, including a fixture whose website timers never
run, DOM success before late clock expiry and rejected clocks failing closed.
Against the unchanged build 50 helper, the timer control deliberately fails
once per provider (three failures, zero passes); no production source mutation
or website prompt was used. Three focused native clock tests passed for all
provider origins, foreign origins, private-world isolation, child frames,
stale generations, receipt limits and cancellation. The initial compile probe
required the Swift 6 WebKit reply closure's MainActor/Sendable annotations;
its failed log is retained alongside the corrected successful run.

The seven public groups passed 637 tests with zero failures or skips. Receipt
SHA-256: a21240c25c53e8b4876ffba2d530f8d00a575dd87de3820907aed033b43a905f.
Complete native validation executed 2,334 tests: 2,285 passed, 49 opt-in skips,
zero failures, in 543.989 seconds. The browser-session suite declared 46 tests
before execution. All 414 frozen inputs and the unchanged engine matched;
permission, workflow and patch guards passed and 26 unique cleanup identities
verified. An independent audit verified the original immutable receipts and
log without replay. Native receipt SHA-256:
a9f0d461a20d3f77fb84d9d722a47405f22d8c6729b5239701b359a2bb4656c6.
Signed installation and fresh live qualification remain separate next steps.
The native clock control is not evidence that the prior live failure is fixed.

The successful build 50 marker project's exact owned directory was archived,
verified and removed. Its evidence and failed browser fixture remain retained.


Build 51 was signed, staged and installed from
e57628c6636d4effe648033345d2961b45a0a0de. Staged and installed
verification each passed 98 checks. The initial redundant installation
preflight read a check's field as passed instead of verified and stopped before
any installation; the corrected guard and canonical successful receipts are
retained. Build 50 is preserved as a rollback. A fresh process and runtime
generation were captured before the first model prompt.

ChatGPT GPT-6 passed fresh marker qualification, all 39 checks, with two
acknowledged/closed leases. The browser task then completed eight native
browser actions, submitted the flight search and read its results, but failed
before details navigation or the final answer. The original collector remains
incomplete_or_failed. All nine leases closed. The root-owned HTTP fixture's
exact process was stopped; its port refused connections and one server_closed
event was independently verified. The failed prompt was not replayed.

The exact-PID timeout snapshot reports phases=not_started,
operationAgeMs=10431, phaseAgeMs=0 and clocksPending=0. The view was attached,
visible and nonoccluded, with 120 accepted DOM receipts and revision 48.
This failure occurred before any adapter phase receipt was accepted. It does
not distinguish a stale generation/origin rejecting receipts from JavaScript
not entering the adapter or a receipt not reaching the native handler. The
native-clock change has not resolved the live failure. Further investigation
must discriminate those cases rather than assuming another verification timer
stall. Gemini CAPTCHA and Claude quota gates remain in place.


## Build 52: distinguish rejected receipts from missing JavaScript entry

The build 51 timeout accepted no phase receipt, which alone cannot show
whether JavaScript entered the adapter. Build 52 adds bounded per-operation
received/accepted counters and a fixed rejection category: frame, generation,
payload or origin. The snapshot also records current native generation/origin
booleans and DOM receipts received during that operation. These are diagnostic
metadata only; rejected receipts still cannot wake the inference, change a
revision or provide model/ownership proof. The operation supersession comment
now accurately describes cancellation of older native clock waits.

All 47 focused native checks passed, including provider/origin/frame/generation
rejection, counter reset, metadata bounds/privacy and a stalled digest's native
completion deadline. The seven public groups passed 637 tests without failures
or skips; receipt SHA-256:
e489d2498f21cb67d8431b480d975e278129af5b25055b66ddf0f0a98ac6ce73.
Complete native validation executed 2,334 tests: 2,285 passed, 49 opt-in skips,
zero failures in 537.870 seconds. All 414 frozen inputs and the unchanged engine
matched, all required permission/workflow/patch guards passed and 26 cleanup
identities verified. Independent original-receipt/log audit passed without
replay; native receipt SHA-256:
247d7042e1da89451ae7ca2a810c8b9f66d1e724c8599c07093f1f68a839200d.
Signed installation and fresh live qualification remain separate next steps.

Additional space cleanup removed exact duplicate build 47/48 backup apps,
retaining their complete staged copies, current build 51 and recent rollback
apps 49/50. The first deletion stopped after 16 members because its directory
identity guard included a link count changed by its own deletion. The saved
manifest and unchanged staged copy were verified before resuming with stable
device/inode/type/mode/owner checks. The resumed cleanup verified all retained
bundles and all frozen inputs, removing 511,418,368 allocated bytes across both
attempts (about 488 MiB). The original plan and partial failure remain recorded.
No process was signalled. Total space cleanup is approximately 36.5 GiB.
The successful build 51 marker project was archived, verified and removed;
its traces and failed browser project remain retained.

### Build 52 installed qualification and delayed WebKit dispatch

Build 52 was signed, staged and installed from
25a13850ce720231d6c180193fb51d7a21d86097, preserving build 51 as a rollback.
Staging and installed verification each passed 98 checks. Installed receipt
SHA-256: a77555754332282bb8513c4a7b30dad410f16b45b6d81e2b18377191f6e74d18.
The new process was PID 23872, runtime generation
c3e175df-8519-4768-967c-61a94580a562, captured before any model prompt.

ChatGPT GPT-6 marker qualification passed all 39 checks with two closed leases;
receipt SHA-256: afa6646d44bc184f0c6f25c71f7d3297366fea983e06437194ec1b4f62fb72a2.
The browser case recovered from an invalid snapshot identifier by reading a
fresh snapshot. Nine native browser actions succeeded, including one flight
search and a results read, but an inspection timeout stopped it before details
navigation or a final answer. Its collector remains incomplete_or_failed;
receipt SHA-256: 3c80bc0825be05b64ef30c8704740a6a6aa5e9b004aae8c54f51eab7ea1f2163.
All eleven website leases closed. The exact owned fixture server PID 25173
exited with code zero, its port refused connections and one server_closed event
was verified independently. No failed prompt was replayed.

The exact-PID timeout reported operationAgeMs=10665, clocksPending=0,
generationCurrent=true, originCurrent=true, diagnosticsReceived=0,
diagnosticsAccepted=0, diagnosticRejected=none and domDuringOperation=3.
The view remained attached, visible and nonoccluded. This rules out native
phase-receipt rejection as the observed failure and does not alone prove that
the adapter never entered JavaScript.

WebKit's correlated host/page/process logs show the native evaluation queued
at 02:36:43.563419 and WebContent PID 27039 entering it at 02:36:57.570422,
14.007003 seconds later. Computa's ten-second native inspection timeout fired
before that entry. The subsequent late evaluation completed without replay,
followed by guarded cleanup. The finite timeline projection has SHA-256
23993ed1102cd95a881bbe0ae4bf74baf81cf8f3cc37e5ae9ac08e64b1c964dd.
These logs identify a queue delay, not the website workload that caused it.
A controlled queue-delay fixture and bounded inspection-budget change are the
next investigation. Gemini CAPTCHA and Claude quota gates remain in place.
