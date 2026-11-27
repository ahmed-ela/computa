# macOS development VM

Run a single-owner macOS guest on an Apple silicon Mac with [Tart](https://tart.run/quick-start/). The same script provisions a guest on another Mac. Each host keeps its own VM disk and account state.

## Prepare a guest

Install Tart on the host and put its CLI on your PATH, or set `TART_BIN` to its executable. Run the commands below from `deploy/macos-vm`. Tart stores VMs in `~/.tart` by default. To use another volume, create a private directory there and set `TART_HOME` to that directory for **every** command.

For a blank guest, pass a local Apple restore image. For a preconfigured guest, clone a stopped local template or a Tart registry image. Pick one of these commands.

```sh
./vm create /path/to/RestoreImage.ipsw
./vm clone my-stopped-template
./vm clone 'ghcr.io/cirruslabs/macos-tahoe-base@sha256:65c3133a633fda8753cf1f71f2d55727792d534a2125b0032466563dcc8e58fd'
```

The default name is `kolmgor-mac-vm` with two CPUs and 4096 MiB of RAM. Set `KOLMOGOR_VM_NAME` for a different name. Set `KOLMOGOR_VM_CPUS` and `KOLMOGOR_VM_MEMORY_MIB` before creating or cloning to change the allocation. Setup refuses an existing destination. Use `./vm status` to inspect an existing guest.

The pinned public image above was tested with Tart 2.42.0 and boots macOS 26.6.2. Its SSH login uses published test credentials. For an ongoing worker, use a private template with your own login and SSH key.

## Boot and connect

```sh
./vm open      # Interactive window for first-time setup
./vm start     # Alternative: run headless in the foreground
```

For SSH access, enable **System Settings → General → Sharing → Remote Login** in the guest and authorize your SSH public key for the guest user. In a second terminal on the VM host, with the same VM name and Tart environment, run:

```sh
./vm status
guest_ip=$(./vm ip) && ssh "guest-user@$guest_ip" sw_vers
./vm stop
```

`ip` waits up to two minutes for a DHCP address on Tart’s default network. The SSH command verifies guest login separately. An agent supervisor can own the foreground `start` process and call `stop` for shutdown.

For reusable images, prepare an account-free template, shut it down and record the image digest. Keep Apple Accounts, private keys and personal data out of the template. For testing Apple services, use a fresh supported IPSW and sign into the individual VM. Moving a VM to a different Mac changes its iCloud identity and requires reauthentication. [Apple’s VM identity documentation](https://developer.apple.com/documentation/virtualization/using-icloud-with-macos-virtual-machines)
