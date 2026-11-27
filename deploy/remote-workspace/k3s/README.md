# U01 workspace and macOS worker

U01 runs a single-node K3s cluster with three deployments. The CLI serves Codex over a private Unix socket. The browser runs sandboxed Chrome with its own persistent profile. The gateway stores jobs in SQLite on a persistent volume. The Mac mini runs Tart and one macOS guest. The guest polls U01 over outbound SSH and handles one read-only operation, `system-info`. A Mac login or an Apple Account is unnecessary for the installed worker to answer after boot.

## Deploy on Linux

Use an x86-64 systemd host with Podman, curl, OpenSSL, Python 3 and a filesystem with user-namespace and idmapped mount support. Run from this directory. The example uses the default K3s kubelet data path. The pilot is a single-owner private workspace.

```sh
sudo ./install-k3s
./build-images "$HOME/kolmogor-images"
sudo ./deploy "$HOME/kolmogor-images"
sudo k3s kubectl -n kolmogor get pods,pvc
```

Keep the node and its Kubernetes API private. The browser and gateway use ClusterIP services. Deploy creates the worker token once and retains it across rollouts. Preserve the volumes to keep the browser profile, jobs and CLI state.

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
