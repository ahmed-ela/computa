# Remote workspace pilot

The Compose pilot runs one private workspace on a Linux x86-64 machine. The Codex CLI owns its chat history, approvals, files, and terminal. A second container owns a persistent Google Chrome for Testing profile and serves browser tools over MCP. SSH authenticates clients. The Compose stack publishes no host ports.

This is an experimental deployment for one trusted owner per VM. It uses the official Codex CLI. Connecting Kolmogor’s native Mac or phone UI, provider-website sign-in handoff, and a macOS Messages worker are separate work. Keep machine inventory, SSH configuration, and account data in your own deployment repository.

The K3s deployment runs a headful Chrome window per workspace, supports private viewer access, and starts separate Codex and Claude Code workers on demand. It also routes jobs to a Tart macOS guest. Follow the [K3s setup and verification guide](k3s/README.md).

## Start and connect

Use Docker Compose v2 or Podman with a Compose provider, service-name DNS, and Chromium user-namespace sandbox support. The live check used rootless Podman and crun on Ubuntu 24.04. Use the same Compose project name and directory for each invocation. If using Podman, substitute `podman compose` for `docker compose`.

```sh
cd deploy/remote-workspace
docker compose up -d --build
docker compose ps
docker compose exec agent codex login --device-auth
docker compose exec agent codex --remote unix:///home/node/run/codex.sock
```

Run those commands on the Linux host. From another machine, use a terminal SSH session for the interactive client. A program can instead run `ssh -T HOST 'cd /path/to/deploy/remote-workspace && ./connect'`. Its stdin and stdout carry a **WebSocket byte stream**, starting with the HTTP Upgrade handshake. Send Codex app-server requests over that WebSocket. A second client can resume an existing thread ID. The remote Unix account needs permission to operate the stack and can control the whole workspace. Keep engine sockets and account files off public listeners.

Named volumes retain the workspace files, Codex state and login, Chrome profile, and browser outputs. The agent can read browser outputs under `/workspace/browser-output`. To read the current page inline use `browser_snapshot`. Preserve those volumes when replacing workers. For a rootless engine, run the stack under a service manager that keeps running after the SSH session closes. Host reboot behavior depends on that manager. Stop with `docker compose stop`; the same project can be started again with `docker compose up -d`.

## Verify without a provider account

Use a **disposable Compose project**. The test uses an internal fixture web page and a delayed, scripted model reply. It drives the actual Chrome process, edits a uniquely named file through the app server and shell, disconnects during a turn, and checks the result from a second client. It archives its test chat. No provider credentials are required. The Mac UI and live inference are outside this check.

```sh
export COMPOSE_PROJECT_NAME=kolmogor-check
docker compose -f compose.yaml -f tests/compose.yaml up -d --build
python3 -m venv /tmp/kolmogor-check-venv
/tmp/kolmogor-check-venv/bin/pip install websockets==15.0.1
/tmp/kolmogor-check-venv/bin/python tests/check.py ./connect
docker compose -f compose.yaml -f tests/compose.yaml down
```

You can pass an SSH command and its arguments to `check.py` in place of `./connect` to verify the actual network path. Supply the same project name on the remote end. Remove the disposable project's volumes once you have finished inspecting the test.

If the browser tool fails, first check whether the agent container resolves the `browser` service and whether Chrome can start its namespace and seccomp sandboxes. The default configuration runs both containers as a non-root user. A host unable to provide the browser sandbox needs a compatible container runtime or security profile. [Chrome for Testing](https://googlechromelabs.github.io/chrome-for-testing/) · [Playwright's container guidance](https://playwright.dev/docs/docker) · [Workspace design discussion](https://github.com/ahmed-ela/kolmogor/issues/130)

Signed-in Mac clients can provision a private U01 workspace through the [Google account service](accounts/README.md).
