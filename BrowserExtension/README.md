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

The first release supports existing HTTP(S) page inventory, exact tab binding,
AX observation, and the native broker's guarded semantic press/set-text actions.
It does **not** add navigation, creating/closing tabs, activating windows,
physical input, screenshot capture, subframe actions, arbitrary JavaScript,
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
| `authorizeSession` | `installationId`, `pairingToken` | `{generation,bridgeEpoch}` |
| `revokePair` | `installationId`, `pairingToken` | `{paired:false,disconnected:true}` |
| `ping` | `{}` | `{generation,bridgeEpoch}` |
| `inventory` | `{}` | `{generation,candidates:[{targetID,title,url}]}` |
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

`revokePair` is authenticated, revocation-only, and also works when the grant is
suspended or no active generation exists. The app must capture the token before
deleting its Keychain record, send this request, then close its link. A failed
delivery must still remove the app-side authority; the popup's Disconnect and
forget can clear any remaining stale extension pairing.

Extension events:

- `hello`: `version`, `event`, `installationId`, `extensionId`, `bridgeEpoch`,
  `paired`, `suspended`; includes `pairingToken` only when paired. Secret-bearing
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
