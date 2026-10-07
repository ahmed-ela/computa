# Computa Browser Bridge

Manifest V3 companion for Computa's existing signed-in Chrome support. This is
an alternate transport behind the existing native tab broker, not a new model
tool surface and not a general-purpose CDP proxy.

## Consent and current scope

The extension is installed and paired explicitly in the intended Chrome
profile. Its permissions are `debugger`, `nativeMessaging`, and `storage` only.
Chrome warns that debugging can read/change website data. Chrome's visible
debugging indicator and Cancel control remain intact. This transport does not
use Chrome's remote-debugging WebSocket or its per-connection Allow dialog.
Routine reconnects are intended to reuse the installed extension grant; that
behavior still requires live qualification, and is not a promise that Chrome
will never show another permission prompt.

The existing-tab grant supports HTTP(S) page inventory, exact tab binding,
AX observation, and the native broker's guarded semantic press/set-text actions.
A **separate, versioned native-user grant** can additionally create a task-owned
inactive copy of an exactly observed, available source page. It can remove only
the exact unchanged tab established by that creation receipt. Existing grants
do not gain this capability merely because the extension is upgraded.
Neither grant adds arbitrary URL navigation, activating windows, physical
input, screenshot capture, subframe actions, arbitrary JavaScript,
cookies APIs, content scripts, remote code, or web-page messaging. Existing
native controls remain distinct. Browser restrictions, managed policies,
incognito/file-access limitations, and StudyLock protections are unchanged.

If Chrome reports a user cancellation or a DevTools conflict, the extension
revokes every attachment and remembers that access is paused. Only a native
user's extension-popup **Resume connection** action can resume that grant.
Reconnection never retries a previous action or silently switches browser tabs.

## Initial developer setup

1. Build/package Computa with its signed native host. Register the host for this
   user in Chrome's `NativeMessagingHosts` directory using a manifest with the
   exact `com.macndash.chrome_bridge` name, `stdio` type, signed helper path, and
   only the pinned extension origin below. Registration is currently an explicit
   developer install step; the app does not silently change Chrome settings.
2. In the intended Chrome profile, explicitly load this directory as an unpacked
   developer extension. Do not install it via a policy override or change
   unrelated Chrome settings. Packaged consumer distribution requires Chrome
   Web Store delivery and a corresponding pinned identity migration.
3. Keep Computa open. Open the extension popup and choose **Pair with Computa**.
4. Confirm the separate, explicit pairing proposal in Computa. Only this step
   issues the shared pairing token. Previously remembered remote-debugging
   consent does not automatically authorize the extension.
5. Run the integration gates before claiming installed-browser qualification.

Development extension ID: `gdghbmoiibghgkfmhjlckipjjlclnlbk`.
Native host: `com.macndash.chrome_bridge`.
Both identifiers remain unchanged across product renames so the installed Chrome profile
and its saved pairing continue to work with Computa. Keep the existing unpacked
extension installation and update the native-host manifest's helper path if the
application bundle moves to `/Applications/Computa.app`.

The manifest includes a public development key solely to stabilize the unpacked
extension ID. There is no private key in this directory; this is not a Chrome
Web Store signing identity or a production distribution package.

## Protocol v1

Chrome supplies native-messaging framing over the host's stdin/stdout. JavaScript
receives parsed JSON objects; it must not add newline framing. Each direction
is limited here to **512 KiB**, and at most 32 requests may be queued. Commands
are serialized. Browser calls time out after 15 seconds; best-effort detach
cleanup is separately bounded. No timed-out mutation is replayed.

Request envelope (all five fields required; no additional fields):

```json
{"version":1,"id":"unique-request-id","operation":"inventory","params":{},"generation":"fresh-session-uuid"}
```

Responses:

```json
{"version":1,"id":"unique-request-id","generation":"fresh-session-uuid","ok":true,"result":{"candidates":[],"generation":"fresh-session-uuid"}}
{"version":1,"id":"unique-request-id","generation":"fresh-session-uuid","ok":false,"error":{"code":"unauthorized","message":"The browser session is not authorized."}}
```

| Operation | Exact `params` | Result |
| --- | --- | --- |
| `approvePair` | `installationId`, `pairingNonce`, `pairingToken` | `{paired:true}` |
| `authorizeSession` | `installationId`, `pairingToken`, optional `temporaryTabsVersion:1` after native approval | `{generation,bridgeEpoch}` |
| `revokePair` | `installationId`, `pairingToken` | `{paired:false,disconnected:true}` |
| `ping` | `{}` | `{generation,bridgeEpoch,capabilities:{temporaryTabsVersion:1}}` |
| `inventory` | `{}` | `{generation,candidates:[{targetID,title,url,availability}]}` |
| `createTemporary` | `sourceTargetID`, `expectedSourceURL`, `taskNonce` (UUID) | `{leaseToken,taskNonce,targetID,title,url,availability}` |
| `releaseTemporary` | `leaseToken`, `taskNonce` | `{released:true,closed:Boolean,retained:Boolean}` |
| `attach` | `targetID` | `{attachmentToken,targetID,title,url}` |
| `detach` | `attachmentToken` | `{detached:true}` |
| `command` | `attachmentToken`, `method`, `params` | Allowlisted CDP result or bounded semantic projection |
| `disconnect` | `forgetPairing` (Boolean) | `{disconnected:true}` |

Setup requests require a fresh request generation but do not grant an active
session. `approvePair` requires the exact popup-generated nonce. Pairing tokens
are 32–256 characters. `authorizeSession` requires the exact saved token and a
fresh generation, revokes old attachments first, and rejects suspended access.
The app must await this response before sending ordinary requests. Generations
and attachment tokens are never restored from disk.

### Task-owned temporary tabs (capability version 1)

`hello`, `pairRequested`, and `ping` advertise protocol support, not consent.
Native code checks the pre-authentication capability before adding the optional
grant version, preserving existing-tab compatibility with older strict-schema
extensions. The native app must separately
record the user's temporary-tab grant and include `temporaryTabsVersion:1` in
each new authenticated session. Omitting it preserves the old existing-tab-only
contract; no blanket `tabs`, host, or scripting permission was added.

The native runtime supplies an opaque current source token, resolving it to the
exact target and observed URL before `createTemporary`. The bridge verifies
that URL and positive debugger availability again before its single call to
`chrome.tabs.create({url,active:false,windowId})`. It uses the returned exact tab
ID to find the debugger target, never a title or URL search. Restricted, busy,
unknown-availability, changed, redirected or ambiguous source/receipt identities
fail closed. The model cannot provide an arbitrary URL, activate a tab/window,
choose a profile, or close an existing tab through this operation.

Creation does not imply that Chrome has committed the new document. A bounded
two-second read-only settling loop follows only the exact receipt tab ID while
it transitions from empty/`about:blank`/pending requested URL to the exact
requested URL. It never repeats creation or accepts an unrelated redirect;
activation, ownership changes and cancellation still invalidate the lease.

At most one creation is admitted per native task nonce, four live temporary
leases per session, and 128 task tombstones per session. An unchanged duplicate
returns the same live lease; a released or changed request cannot create another
tab. Cancellation and timeouts never replay creation. A late result is cleaned
only by its exact creation receipt while unchanged, inactive and unclaimed;
otherwise it is retained without returning usable authority.

Activation, pinning/grouping or uncertain navigation revokes temporary-tab
actions and retains the tab. A fixed broker semantic mutation gets a bounded
1.5-second navigation-settling window after its result, but any URL change still
removes automatic-close eligibility: Chrome's update event does not identify
the actor, so navigation alone cannot prove that closing remains safe. The
release result explicitly reports `retained:true` in that case. Callers must not
claim it was closed. Adopted tabs stay intact on later app disconnect, Cancel,
timeout or session replacement. Intentional cleanup removes attachment authority
before detach, so it does not turn a normal release into a Chrome Cancel pause.

Leases and task IDs are never persisted or reconstructed after worker restart.
An ambiguous orphan is retained. Cleanup checks exact target, current URL,
window, inactive state and observed takeover events before removing the single
receipt-owned tab; existing tabs with identical titles/URLs are never candidates.
The browser remains authoritative: Chrome restrictions and StudyLock enforcement
are unchanged. This capability is implemented and deterministically tested;
live installed qualification is a separate gate.

`revokePair` is authenticated, revocation-only, and also works when the grant is
suspended or no active generation exists. The app must capture the token before
deleting its Keychain record, send this request, then close its link. A failed
delivery must still remove the app-side authority; the popup's Disconnect and
forget can clear any remaining stale extension pairing.

Extension events:

- `hello`: `version`, `event`, `installationId`, `extensionId`, `bridgeEpoch`,
  `paired`, `suspended`, `capabilities:{temporaryTabsVersion:1}`; includes `pairingToken` only when paired. Secret-bearing
  hello data must never appear in diagnostic logs or prompts.
- `pairRequested`: same public identity/Boolean fields, plus `pairingNonce`.
  Emitted only after an explicit popup Pair action, or as the current proposal
  during a fresh host handshake. This event is a proposal, not approval.
- `detached`: `version`, `event`, `generation`, `attachmentToken`, `reason`.
- `bridgeError`: `version`, `event`, fixed `code` on request-capacity violations;
  authority is revoked before the event.

Host-only control events:

- `{version:1,event:"requestHello"}` requests current identity and any pending
  pairing proposal. Prefer this to cached identity replay when the app connects.
- `{version:1,event:"appDisconnected"}` revokes all current capabilities before
  awaiting detach. The host should send this after an actual app link ends,
  **not** on every unsuccessful initial connection attempt. When pairing has
  been forgotten, the worker closes the native port after this acknowledgement.

An existing native port can remain while the app is closed; its relay performs
no browser actions. Fresh app authentication is required before further
commands. No browser/profile identities are inferred from page titles or URLs.

### Exact-node clickability observation

`DOMSnapshot.captureSnapshot` admits only the ordered styles
`{"computedStyles":["cursor","visibility","display","pointer-events"]}` after
the attachment has observed its main frame. The bridge selects the unique
matching frame and requires its complete document URL, including any fragment,
to match. It sends this projection instead of DOM text, attributes, styles,
geometry, or child-frame contents:

```json
{"mactopusClickability":{"frameId":"observed-main-frame","documentURL":"https://example.com/","clickableBackendNodeIds":[42],"pointerBackendNodeIds":[43],"sourceTruncated":false,"sourceNodeCount":120}}
```

`clickableBackendNodeIds` contains only exact backend IDs marked clickable by
Chrome. `pointerBackendNodeIds` is a separate **affordance heuristic**, not
event-handler proof: exact-node layout has `cursor:pointer`, `visibility:visible`,
non-`none` display and pointer events, and positive finite bounds. Native must
also require the same node's AX focusability before using this second route.
Multiple layout fragments are deduplicated; empty text styles grant nothing.
No ancestor or descendant inherits another node's capability. The source is
limited to 256 documents, 100,000 main-document nodes and 100,000 layout entries;
duplicate DOM identities, malformed indices and mismatched provenance fail
closed. At most 12,000 IDs per list fit the shared byte-bounded projection;
omissions set `sourceTruncated`. Missing optional `isClickable` data supplies no
positive evidence. The native broker must still revalidate the selected node
and document before its fixed semantic click and verify the resulting page
separately. An older bridge can reject the command; the native caller must not
infer clickability from that failure.

## Validation

Run `bun test` from this directory. Tests use an inert Chrome API fixture and
never connect to the user's browser. They cover pairing, reconnect authority,
revocation, exact-target selection, stale handles, duplicate requests, capacity
limits, timeout/late-result races, and byte-for-byte parity with the native
broker's two fixed JavaScript functions.

Still required for qualification: actual installation/pairing; repeated chats
and app/browser restarts without recurring remote-debugging prompts; another
foreground app receiving user input while background actions complete; Cancel,
DevTools conflict, sleep/wake, helper/worker termination; and idle CPU/RSS plus
action-latency measurements. Unit tests are not evidence of these live results.

### Website model transport

The native app can use `webProviderStart`, `webProviderSend`, `webProviderPoll`,
`webProviderFinish`, and `webProviderCancel` through the existing authenticated
bridge envelope. These commands use Chrome's existing signed-in profile. No
additional extension permissions or separate browser process are needed.

In Computa's Swift app, choose **Gemini · Chrome** or **Claude · Chrome** and
sign into that provider in the paired Chrome profile. **ChatGPT · Built-in
browser** instead uses the app-owned WebKit profile: sign into `chatgpt.com` in
Computa's Browser pane. That ChatGPT route does not require Chrome or this
extension. The bridge's `chatgpt` operation remains available to other transport
clients. No provider API key is needed.

The built-in ChatGPT adapter opens a separate owned Temporary Chat, preserves
the human tab, and closes the owned tab after verified cleanup at the end of the
native turn. It waits for navigation and private-world DOM-change notifications
coalesced over approximately 100 ms, while this extension retains its existing
polling contract. Both routes keep transcripts locally and support text,
Accessibility and terminal tools through Computa's harness; image/screenshot and
audio inputs remain unsupported. These transport descriptions do not establish
live end-to-end qualification.

After updating this unpacked developer extension, reload it once from Chrome's
Extensions page to activate the changed JavaScript. Reopening Computa reconnects
the remembered pairing but does not replace Chrome's loaded extension code.

The Rust bridge reconnects its authenticated native helper with one timer and
an attempt delay capped at 30 seconds. Opening Computa reuses the remembered
installation and Keychain pairing, and no pending website request is replayed.
An unsupported operation means Chrome still has an older extension worker
loaded; that update needs one developer-extension reload, not a reload per chat.

The signed Rust app can repair its native-host registration only when launched
from the OS account's `Applications/Computa.app`. It verifies that exact app and
its bundled `ChromeBridgeHost` have the required identities and signing Team,
then publishes only the fixed host name and installed extension origin. A
matching signed old registration gets a private backup. Foreign, changed or
unverifiable registrations are rejected. Staged apps and qualification fixtures
cannot repoint the live registration. These source checks do not constitute
proof that an installed extension has been activated or a live website chat has
completed.

| Operation | Parameters | Result |
| --- | --- | --- |
| `webProviderStart` | `{provider: "chatgpt" \| "gemini" \| "claude"}` | New inactive owned tab; `state: "loading"`, `sessionToken` |
| `webProviderPoll` | `{sessionToken}` | `loading`, `ready`, `running`, `complete`, `needs_sign_in`, or `failed`; bounded current response `text` and per-send `sequence` |
| `webProviderSend` | `{sessionToken, prompt}` | One submission; `state: "running"`. Call only after `ready` or `complete`. |
| `webProviderFinish` | `{sessionToken}` | Closes the owned temporary tab; `state: "finished"`, `cleanup: "not_created"` on success |
| `webProviderCancel` | `{sessionToken}` | Stops the owned response, then performs the same cleanup |

Every website session starts from an empty new conversation. Before sending,
ChatGPT's temporary-chat control, Gemini's visible temporary-chat notice, or
Claude's Incognito chat badge and Exit incognito control must be observed.
Continued temporary-mode evidence is checked again at cleanup.
Temporary sessions do not create entries in the provider's saved chat history;
`not_created` reports that fact, and does not claim immediate erasure from the
provider's internal retention systems. The app remains responsible for its local
transcript and for calling finish/cancel at the end of the logical native turn.
Multiple tool-result sends can share that same website session. Claude begins
at its empty `/new` page and enables Incognito before any prompt is entered;
existing saved `/chat` conversations are never adopted. Its reply body is read
without the screen-reader heading or message toolbar, and a streaming reply
cannot be considered complete even if a Copy control is already present.
Because Claude keeps its incognito `/new` URL throughout a chat, the bridge also
pins its CDP main-document loader identity at readiness and verifies the owned
user-message count before composer actions, polling, and cleanup. Each send must
add exactly one user message before its reply can complete. Reloads, resets, or
extra messages permanently revoke cleanup authority and leave the tab open;
worker recovery preserves these identity checks. A final Send whose acknowledgement
was lost can be cleaned up only with the previous confirmed count or its one
pending submission.
The first outbound Claude prompt also carries a fresh opaque session marker.
Only a rendered first user message containing that exact marker can establish
ownership; the bridge then pins its nearest DOM ancestor ID and a SHA-256 digest
of its normalized rendered body. Later actions, cleanup, and worker recovery
check both, so a replacement chat with the same document and message count
cannot acquire authority. Rendering Markdown does not need to reproduce the raw
prompt bytes. The digest operation rechecks the same message node and body after
its asynchronous wait, and the recovery ledger stores the marker, ID, and digest
without storing prompt or response text.
An interrupted reply fails before tool parsing, while cleanup can still close
its verified owned incognito tab.

Claude's [official incognito documentation](https://support.claude.com/en/articles/12260368-use-incognito-chats)
confirms that these chats are excluded from chat history and memory, with
provider-side retention of 30 days by default (Enterprise retention can differ).

Only extension-owned fixed DOM actions run. Prompt text is inserted with Chrome's
`Input.insertText`; arbitrary JavaScript, URLs, target IDs and model-supplied DOM
selectors are not accepted. Response extraction is restricted to the owned tab.
Completion requires a final-answer control, no stop-generation control, and
stable text for 1.6 seconds. Readiness is capped at 45 seconds and each response
at 180 seconds; polling requests never wait for the entire generation.
During Claude's initial navigation, a fresh, unsubmitted session can retry
read-only document inspection within that readiness deadline. It cannot send a
prompt until its stable empty page and Incognito mode are verified. Document
replacement after readiness still revokes ownership. A failed unsent session
can close only its positively inspected, stable, empty starting page.

A failed cleanup returns `cleanup: "failed"` with an error and leaves the owned
tab open for inspection. It never deletes preexisting conversations or falls
back to bulk history deletion. A Chrome session-storage ledger records only
owned tab identities and temporary-mode state, so worker restarts can clean up
verified owned temporary tabs without resubmitting prompts. It contains no
prompt, response, credentials, or pairing token, and expires with the browser
session. Unverified recovery is exposed as `webProviderCleanupFailures` in popup
status; disconnect cleanup failures also emit `webProviderCleanupFailed`.

The native transport interface can replace these website operations with a VM
implementation later; DOM adaptation and Chrome tab ownership remain confined
to this module.
