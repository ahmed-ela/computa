# Existing Chrome default — 2026-09-24

## Outcome

HeyDash now defaults to the user's ordinary Chrome process and existing profile,
not a disposable project-owned Chrome profile. Opening without a URL activates
the existing session without navigating; a supplied URL opens a verified new tab.
The isolated browser broker remains available through explicit
`browser_mode: "isolated"`. Instructions and schema describe that mode as opt-in.

This is native foreground Accessibility/computer input, not background DOM/CDP
access to personal Chrome. No extension was installed, cookies copied, Chrome
debugging enabled, or macOS permissions changed.

## Cause and implementation

Previously, every Chrome URL in `computer_v2_open` entered `ChromeTabBroker`,
which launched a temporary user-data directory. The model instructions and tool
description reinforced that routing. It was application behavior, not Qwen
independently preferring a fresh profile.

- The contract defaults omitted `browser_mode` to `existing` for Chrome.
- Runtime dispatch uses the isolated broker only for explicit isolated mode.
- Both the V2 open and legacy Chrome open route use `ExistingChromeController`.
- Process selection rejects uninspectable/ambiguous processes and excludes custom
  user-data directories and remote-debugging instances. It never silently falls
  back to an isolated session. Ordinary Chrome can launch when none is running.
- Activation pins the exact PID and native window. A narrow, permission-checked
  AX raise/frontmost recovery handles AppKit activation refusal.
- URL entry proves all baseline tab identities remain, exactly one tab was added,
  and that new tab is selected. It checks the native editable omnibox, exact
  window/control/tab identity and URL readback before Return. Web-content fields
  cannot impersonate the native address bar. Transient post-new-tab settling
  retries only reads, never input; cancellation and permission denial stop work.
- Runtime shutdown does not own or terminate the user's Chrome.

The omnibox label check currently targets English Chrome. Unrecognized native
AX structure/localization fails closed; this is not a universal browser support
or task-reliability claim.

## Verification

All final runs used the already-running ordinary Chrome PID **52339**.
Only public `example.com` nonce fixtures were used by the automated gates.

| Check | Final result |
| --- | --- |
| Full Xcode test suite, including two opt-in Chrome checks | 546 passed, 23 skipped, 0 failures (569 discovered) |
| Exact process/tab/activation/entry helper regressions | 32 passed |
| Qwen3.5-4B MLX 4-bit production-runtime open + AX read + final response | Passed, 12.821 s |
| Native primitive immediately after the model gate | Passed, 844 ms |
| Three additional serial native primitive iterations | 3/3, 832 / 841 / 785 ms |
| Separate focused helper + native run | Passed; native 793 ms |
| Git whitespace check | Passed |

The Qwen gate asserts the actual App Server wire lifecycle and model identity,
exact open arguments, bound process, real AX heading, exact nonce address, final
response token, and successful runtime shutdown. The set of Chrome processes
must stay unchanged throughout and after shutdown. Timings are individual smoke
measurements, not a broad browser-task benchmark.

Earlier attempts exposed an AppKit activation refusal, Unicode key events that
left the address bar empty, and a transient post-new-tab focus change. Those
attempts failed rather than reporting success. The final code uses exact-window
AX activation recovery, verified AXValue entry, and retained-tab read settling;
the final results above were all obtained after those fixes.

Temporary public test pages and blank tabs created by failed attempts were closed
after verification; original user tabs were left intact. Closing tabs is
recoverable through Chrome's normal reopen-closed-tab behavior. The updated debug
HeyDash app was reopened and its UI reported `Local runtime connected` with
Qwen3.5-4B. Installed app unchanged; no commit or push performed.

## Local evidence

- Full run: `/tmp/heydash-existing-chrome-final-20260924-r2.log`
- Serial repeats: `/tmp/heydash-existing-chrome-serial-20260924.log`
- Focused run: `/tmp/heydash-existing-chrome-primitive-20260924-r4.log`
- Xcode result: `.build/HeyDash/Logs/Test/Test-HeyDash-2026.09.24_19-22-20--0700.xcresult`
- Opt-in wire trace: `/var/folders/r7/885nhb5j0nvbt691yqp4jzyw0000gn/T/LocalCodexChromeV2-126951DD-9C10-4220-BECC-B60F13D8DE9F/app-server-wire.jsonl`

Raw fixture traces stay local and are not included in this report. Temporary
evidence paths can be removed by macOS; hashes identify the tested bytes.

| Artifact | SHA-256 |
| --- | --- |
| Full run log | `4c78843964a0c11a72392d7df92da9908d478fed51ac05e8d199b0c799dee5b2` |
| Serial log | `bbd597af0f9b181bf6e21597788bee31e5d5111b68062f536a7713a56442a70f` |
| Wire trace | `5bf862b0497ef397ef29dee6e3766110927c36c21f3ae40243f5aa45b5cbbded` |
| ExistingChromeController.swift | `511d1e5a0d62638ac3720261df19908e80bdc478d53e27bb0c4b3f98f27e0d5c` |
| ExistingChromeTabInventory.swift | `1ddc90e72a85d0fd0a969348f44f8db0e7fdade6ffcdc7d2ee89935037ab40d5` |
| ComputerV2ToolContract.swift | `2119e9c85f8662e594050e0940cc6ed3fa2b5e94c9c0fc92592181aea80476b6` |
| CodexAppServerRuntime.swift | `e97646f7fface7af9945a21922db78696f0ec1610f068211fbcac8d5f9967937` |
| ExistingChromeControllerTests.swift | `3c576a3fd8316f7d1ef6191fc6d3f07f0e3a8ad0f1a1589854ddb5d53bc8b44b` |
| ChromeV2LiveTests.swift | `0647e887467ca779755b8e819892e08c271515c373480e728cc4de0cb325003c` |
