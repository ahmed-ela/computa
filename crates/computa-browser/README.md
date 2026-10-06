# Computa browser transports

The native messaging helper verifies the exact Google Chrome vendor signature and
the app/helper signing relationship. The app accepts only an owned same-account
Unix socket, verifies the helper and its Chrome parent, bounds messages and pending
requests, and retires uncertain connections without replay. Pairing material uses
the existing Keychain service. Socket and private-profile roots use the OS account
home returned by `getpwuid_r`, independently of inherited `HOME`.

`BrowserControl` exposes two distinct ownership modes. `BrowserController` operates
explicitly paired borrowed tabs and exact temporary-copy receipts. Borrowed access
supports HTTP(S) and fixed DOM operations only. Cleanup retains receipts until a
confirmed close and never terminates the user's Chrome process.

`OwnedBrowserController::launch` accepts the installed Chrome executable resolved
by the native application layer. It starts a foreground Chrome process in a fresh
0700 task profile, reads only that profile's bounded non-symlink DevToolsActivePort,
verifies the signed exact PID and its loopback listener, and connects only to that
owned browser WebSocket. HTTP(S) and file URLs are allowed in this owned mode.
Frame loaders, execution contexts and resolved objects are bound to each attachment;
navigation retires those references before dispatch. Uncertain or cancelled CDP
requests invalidate the connection. Shutdown targets only the owned process group
and removes its profile after the group is gone. Startup cancellation uses an
inode-bound profile guard and the child process's kill-on-drop lifecycle.

`CleanupProofStore` lets an old website-provider transport settle cleanup after a
verified reconnect. Keep one store across native links and call `observe(&link)`
on every accepted hello. Only exact original-session terminal receipts from the
same installation and pairing can confirm a close; a new session or generation
cannot replace the old one. Capacity is bounded and unresolved ownership is retained.

Tests cover IPC framing/cancellation, signing-requirement construction, endpoint
validation, document-reference retirement and authenticated cleanup proofs. Signed
app/helper integration, isolated Chrome launch/termination and actual web-provider
tool turns require separate installed-product qualification.
