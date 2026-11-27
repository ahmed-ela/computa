# U01 workspace and macOS worker

U01 runs the gateway, provider CLIs and headful Chrome on single-node K3s. The Mac mini runs Tart and one macOS guest. The guest polls the gateway over outbound SSH and handles the read-only `system-info` operation, including at the macOS login screen.

Each workspace belongs to one trusted owner and gets a Kubernetes namespace. Its browser pod runs Chrome for Testing on an Xvfb display. Chrome owns the persistent profile, so disconnecting an MCP client or stopping a CLI leaves the browser open. Codex and Claude Code have separate images and persistent account state. They share the workspace directory and browser MCP endpoint. The gateway starts a selected provider on demand. Explicitly stopping that provider frees its pod and keeps its data.

## Deploy on Linux

Use an x86-64 systemd host with Podman, curl, OpenSSL, Python 3 and a filesystem with user-namespace and idmapped mount support. Run from this directory. The example uses the default K3s kubelet data path. Run the operator commands on the node. The `kolmogor` namespace is the original workspace and also hosts the shared gateway.

```sh
sudo ./install-k3s
./build-images "$HOME/kolmogor-images"
sudo ./deploy "$HOME/kolmogor-images"
sudo k3s kubectl -n kolmogor get pods,pvc
```

Keep the node and its Kubernetes API private. The browser and gateway use ClusterIP services. Deploy creates the worker token once and retains it across rollouts. Preserve the volumes to keep the browser profile, jobs and CLI state.

## Start a workspace and switch CLIs

```sh
sudo ./workspace kolmogor-ws-demo provision
sudo ./workspace kolmogor-ws-demo run codex -- --version
sudo ./workspace kolmogor-ws-demo run claude -- mcp get browser
sudo ./workspace kolmogor-ws-demo run claude
sudo ./workspace kolmogor-ws-demo stop claude
sudo ./workspace kolmogor-ws-demo run antigravity -- models
sudo ./workspace kolmogor-ws-demo stop codex
```

Use `run codex -- login` or `run claude -- auth login` after provisioning to link an account through that provider’s own CLI. Use **Antigravity CLI → Connect** in the account window to authorize Google’s personal-account CLI. Its isolated worker registers this workspace’s browser MCP and persists its own home volume. Finish active turns before stopping a worker. Users switching providers can keep their CLI workers running. Reprovisioning preserves an existing worker’s scale. The browser stays running while the workspace exists. Its profile persists across pod replacement. Restoring tabs after a Chrome crash follows Chrome’s own session behavior.

The private gateway authenticates start and stop requests with a separate token for each workspace. Its Kubernetes service account can read only that routing secret and scale only the named provider deployments in enrolled namespaces. Network policies allow provider-to-browser MCP within the workspace, DNS and public web traffic. The provider pods receive no cluster credentials. Workspace code and shared files are trusted by the providers belonging to the same owner. Administration uses SSH and Kubernetes authorization. These commands do not provision end-user accounts or connect the shipping Kolmogor client.

## View and control the real Chrome window

Pause any active agent browser task before entering private information. The viewer and agent operate the same pages. In your private terminal on U01, read the viewer password and grant your Linux SSH user access for 15 minutes.

```sh
sudo ./workspace kolmogor viewer-password
sudo ./workspace kolmogor share --user "$(id -un)" --minutes 15
```

On the Mac, run the following from this repository. Substitute the node’s SSH host alias and the absolute remote path to the workspace command.

```sh
./open-display U01 /path/to/remote-workspace/k3s/workspace kolmogor
```

This opens macOS Screen Sharing. Enter the workspace viewer password. The SSH command streams the selected browser’s display. The temporary grant opens a Unix socket usable only by the named Linux user and node administrators. It expires automatically and also ends when the operator presses Control-C. This works on U01 with SSH TCP forwarding disabled. The browser Service exposes only MCP to its workspace’s CLI workers. Chrome debugging and VNC bind to pod loopback. For a local Kubernetes operator, `./workspace NAMESPACE view --port 5901` also supports a node-local viewer.

## Verify browser handoff and isolation

Run `sudo ./tests/check-workspace` on U01 with Python 3 and its `cryptography` package installed. It provisions a randomly named namespace, starts the actual provider binaries through the gateway, and uses a scripted model endpoint. Codex focuses an input, an authenticated VNC client types a fresh random marker, and Claude Code’s own browser tool reads that marker. The test also checks shared files, private homes, cross-workspace access denial, provider scaling and browser profile persistence after replacing the pod. It removes only its disposable namespace. The qualification uses no paid inference or provider account credentials.

On November 27, 2026 the U01 handoff passed with Codex CLI 0.172.0, Claude Code 2.1.332 and headful Chrome for Testing 158.0.8127.88. The Mac authenticated to the 1366 × 768 display over the temporary SSH grant. Direct connections from the CLI to another workspace’s MCP service and to the browser pod’s VNC and debugging ports failed as expected. The gateway also received a fresh receipt from the arm64 macOS guest after rollout. The client app’s remote UI and the previously observed Codex bubblewrap terminal restriction are outside this qualification.

## Enroll the Mac guest

On the Mac, prepare an empty private directory outside the checkout. Obtain the jump and node ED25519 host keys through a trusted channel and verify them before enrollment. The guest needs a route to the jump host. The jump host must reach the node using SSH. Look up the gateway IP with `sudo k3s kubectl -n kolmogor get svc gateway -o jsonpath='{.spec.clusterIP}'` on the node.

Pipe the worker token from the cluster to the enrollment helper through your authenticated administrator connection. A typical command follows. Substitute your own reachable hosts, private IPs, and SSH users. The known-host names are the aliases already verified in the Mac's known_hosts file.

```sh
umask 077
stage=$(mktemp -d)
ssh "$ADMIN_NODE" 'sudo k3s kubectl -n kolmogor get secret worker -o jsonpath="{.data.token}" | base64 -d' |
  ./prepare-enrollment "$stage/enroll" \
    --jump-ip "$JUMP_IP" --jump-user "$JUMP_USER" --jump-known-host "$JUMP_ALIAS" \
    --node-ip "$NODE_IP" --node-user "$NODE_USER" --node-known-host "$NODE_ALIAS" \
    --service-ip "$GATEWAY_IP"
```

Install only the generated **public** `jump.authorized` and `node.authorized` lines in the respective users' authorized_keys. Retain their forced commands and restrictions. Neither key entry gives the guest an interactive shell. The node command forwards a request only to the gateway's worker endpoint. If its Service IP changes, update the forced command.

With the guest shut down, set its memory and start it with the private enrollment directory shared read-only. These settings reproduce the pilot's five virtual CPUs and 8 GiB of memory on a 10-core, 16 GiB M4 Mac mini.

```sh
tart set "$VM" --cpu 5 --memory 8192
tart run --no-clipboard --no-audio --dir="Enrollment:$stage/enroll:ro" "$VM"
```

In the guest, run `/bin/sh "/Volumes/My Shared Files/Enrollment/Install.command"` from Terminal as the guest's local administrator. The installer runs once with sudo. The resulting launch daemon runs as nobody, with its private key and worker token readable only by its service identity and root. Shut down normally, then start Tart without the enrollment share. Keep credentials outside source control. To revoke the guest, remove both authorized_keys entries and rotate the gateway token.

## Test the complete route

Run `sudo ./check-job` on U01. It submits a new job, waits for the guest's response, and verifies the job ID, challenge, architecture, and boot UUID. To bind the check to this particular boot, pass the output of `sysctl -n kern.bootsessionuuid` from the guest as the sole argument. The installer also prints this UUID when it registers the launch daemon. Run it again after restarting the guest without its enrollment share to verify unattended startup.

On macOS, OpenSSH starts its configured proxy through the process’s `SHELL`. The `nobody` service account uses `/usr/bin/false`, which can leave a healthy-looking daemon retrying while jobs stay unclaimed. The worker sets `SHELL=/bin/sh` only for SSH to run the fixed proxy command. The account retains its non-login shell and both SSH key restrictions remain in force.

On November 27, 2026, U01 received three verified results from an arm64 macOS 26.3.1 guest (build 25D2128). The initial result matched the boot UUID printed by the guest installer. A job queued while the guest was shut down completed on a new boot with the enrollment share removed. A third job submitted by the node’s `check-job` then matched that new UUID while the guest remained at its login screen.

## First-boot keyboard check

Before entering a saved password in Tart, type `aB7-c` in the optional hint field and compare each character. On the M4 pilot, normal desktop typing, simulated Shift and Quartz events carrying only the generic Shift flag all produced `ab7-c`. The two password fields can match each other even when both differ from the saved login.

On this host, native hardware key events sent to foreground Tart preserved case when both the Shift flags-changed event and shifted key carried the generic Shift mask and the device-specific left-Shift bit (0x2). Send left Shift down, the key down and up, then left Shift up. Verify the sample and clear it before filling the two secure fields from the saved Apple Passwords entry. Check that Setup Assistant advances. Keep the password out of the hint, clipboard, logs and Git.
