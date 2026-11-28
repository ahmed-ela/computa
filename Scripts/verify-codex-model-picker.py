"""Run the optional two-app test with disposable profiles and a loopback model.
Requires the official macOS app and Accessibility for inspecting the fixture window.
Run from the repo root. Supply --scratch-path and --temporary-root to choose disks.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--shared-owner", action="store_true", help="Keep the optional desktop owner attached while sending")
parser.add_argument("--cli", type=Path, default=shutil.which("codex"))
parser.add_argument("--app", type=Path, default=Path("/Applications/ChatGPT.app"))
parser.add_argument("--temporary-root", type=Path)
parser.add_argument("--scratch-path", type=Path)
options = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
app = options.app.resolve()
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "com.openai.codex"
main = app / "Contents/MacOS" / info["CFBundleExecutable"]
if not options.cli:
    parser.error("Install the standalone Codex CLI or supply --cli")
cli = Path(options.cli).resolve()
if any(part.endswith(".app") for part in cli.parts):
    parser.error("The standalone check requires a CLI installed outside an app bundle")


def until(action, seconds=60):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        result = action()
        if result:
            return result
        time.sleep(0.3)
    raise TimeoutError(action.__name__)


def stop(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def seed(profile, env):
    process = subprocess.Popen([cli, "app-server", "--stdio"], env=env, cwd=profile,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    seq = 0

    def receive(match):
        end = time.monotonic() + 45
        while time.monotonic() < end and select.select([process.stdout], [], [], end - time.monotonic())[0]:
            raw = process.stdout.readline()
            if not raw:
                break
            frame = json.loads(raw)
            if match(frame):
                return frame
        raise TimeoutError("Codex fixture RPC")

    def rpc(method, params):
        nonlocal seq
        seq += 1
        process.stdin.write((json.dumps(dict(id=seq, method=method, params=params)) + "\n").encode())
        frame = receive(lambda f: f.get("id") == seq and "method" not in f)
        if "error" in frame:
            raise RuntimeError(frame["error"]["message"])
        return frame["result"]

    try:
        rpc("initialize", {"clientInfo": {"name": "kolmogor_picker_fixture", "version": "1"},
                           "capabilities": {"experimentalApi": True}})
        process.stdin.write(b'{"method":"initialized"}\n')
        thread = rpc("thread/start", {"cwd": str(profile), "model": "gpt-6.2-sol",
                                      "approvalPolicy": "never", "sandbox": "read-only"})["thread"]["id"]
        turn = rpc("turn/start", {"threadId": thread, "input": [{"type": "text", "text": "Fixture one"}]})["turn"]["id"]
        ended = receive(lambda f: f.get("method") == "turn/completed" and f["params"]["turn"]["id"] == turn)
        assert ended["params"]["turn"]["status"] == "completed"
        rpc("thread/name/set", {"threadId": thread, "name": "Kolmogor model switch qualification"})
        return thread, process
    except BaseException:
        stop(process)
        raise


with tempfile.TemporaryDirectory(prefix="kolmogor-picker-", dir=options.temporary_root) as tmp:
    root = Path(tmp).resolve()
    profile, electron, inspector = root / "profile", root / "electron", root / "window-check"
    profile.mkdir(mode=0o700)
    electron.mkdir(mode=0o700)
    env = {**os.environ, "CODEX_HOME": str(profile), "HOME": str(root)}
    # Only this disposable desktop sees the socket override. All model traffic goes to the recorder.
    endpoint = profile / "app-server-control/app-server-control.sock"
    desktop_env = {"CODEX_HOME": str(profile), "CODEX_ELECTRON_USER_DATA_PATH": str(electron),
                   "CODEX_APP_SERVER_WS_URL": "ws+unix://localhost" + str(endpoint) + ":/rpc"}
    server = subprocess.Popen([sys.executable, repo / "Tests/Fixtures/CodexPickerResponses.py", root])
    tests = None
    seed_writer = None

    def desktop_pids():
        lines = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True).splitlines()
        prefix = f"{main} --user-data-dir={electron} "
        return [int(s.split()[0]) for s in lines if s.split(None, 1)[1].startswith(prefix)]

    def desktop_pid():
        pids = desktop_pids()
        # A second invocation briefly forwards its deep link to the existing
        # instance. Wait for the one actual window before inspecting it.
        return pids[0] if len(pids) == 1 else None

    def close_desktop():
        for pid in desktop_pids():
            if pid in desktop_pids():
                os.kill(pid, signal.SIGTERM)
        try:
            until(lambda: not desktop_pids(), 12)
        except TimeoutError:
            for pid in desktop_pids():
                os.kill(pid, signal.SIGKILL)
            until(lambda: not desktop_pids(), 10)

    def open_desktop():
        if not (profile / ".codex-global-state.json").exists():
            # Model switching is exercised on an existing chat. Give the disposable
            # app a single synthetic project so first-run personalization is independent.
            (profile / ".codex-global-state.json").write_text(json.dumps({
                "electron-saved-workspace-roots": [str(profile)],
                "active-workspace-roots": [str(profile)],
                "electron-persisted-atom-state": {
                    "electron:onboarding-projectless-completed": True,
                    "last_completed_onboarding": int(time.time()),
                },
            }))
        launch = ["open", "-gn"]
        for key, value in desktop_env.items():
            launch += ["--env", f"{key}={value}"]
        subprocess.run([*launch, app, "--args", f"--user-data-dir={electron}", f"codex://threads/{thread}"], check=True)

    def visible(*lines):
        pid = desktop_pid()
        if not pid:
            return False
        try:
            status = subprocess.run([inspector, str(pid), *lines], timeout=8).returncode
        except subprocess.TimeoutExpired:
            return False  # An Electron window can be unresponsive during initial launch.
        if status == 2:
            raise RuntimeError("Accessibility is required for the isolated desktop check")
        return status == 0

    try:
        subprocess.run(["swiftc", repo / "Tests/Fixtures/CodexPickerWindow.swift", "-o", inspector], check=True)
        until(lambda: (root / "endpoint").is_file())
        (profile / "auth.json").write_text(json.dumps({"OPENAI_API_KEY": "sk-loopback-fixture"}))
        (profile / "config.toml").write_text('model="gpt-6.2-sol"\nopenai_base_url=' + json.dumps((root / "endpoint").read_text()) +
            '\nweb_search="disabled"\n[features]\nplugins=false\nhooks=false\napps=false\n[desktop]\nexternal-agent-import-sync-enabled=false\n')
        thread, seed_writer = seed(profile, env)
        assert (root / "initial-model").read_text() == "gpt-6.2-sol"
        (root / "thread").write_text(thread)
        # First-run onboarding can consume the launch URL. Act only in this
        # synthetic account, then ask the same Electron instance to open the thread.
        def ready():
            if visible("PROBE-REPLY-1") or visible("Kolmogor model switch qualification"):
                return True
            if visible("Which best describes your work?"):
                if visible("--press", "Engineering"):
                    visible("--press", "Continue")
                return False
            return visible("--press", "Skip")
        if options.shared_owner:
            stop(seed_writer)
            subprocess.run([cli, "app-server", "daemon", "start"], env=env, check=True, stdout=subprocess.DEVNULL)
            open_desktop()
            until(ready, 120)
            if not visible("PROBE-REPLY-1"):
                open_desktop()
                until(lambda: visible("PROBE-REPLY-1"))
        else:
            assert not desktop_pids() and not endpoint.exists()
            (root / "holding-writer").touch()
        command = ["swift", "test"]
        if options.scratch_path:
            command += ["--scratch-path", str(options.scratch_path)]
        command += ["--filter", "CodexDesktopSidebarTests.testSwitchModelOnOfficialDesktopAndReopenSameConversation"]
        test_env = {**os.environ, "CODEX_HOME": str(profile), "KOLMOGOR_FIXTURE_CLI": str(cli), "KOLMOGOR_MODEL_PICKER_FIXTURE": str(root)}
        tests = subprocess.Popen(command, cwd=repo, env=test_env)
        def waiting():
            if tests.poll() is not None:
                raise RuntimeError("Kolmogor finished before verifying the switched reply")
            return (root / "reopen-desktop").exists()
        if not options.shared_owner:
            def waiting_for_contention_check():
                if tests.poll() is not None:
                    raise RuntimeError("Kolmogor failed the competing-writer check")
                return (root / "release-writer").exists()
            until(waiting_for_contention_check, 900)
            assert not (root / "switch-receipt").exists(), "A busy writer received a duplicate submission"
            stop(seed_writer)
            (root / "writer-released").touch()
        until(waiting, 900)
        receipt = json.loads((root / "switch-receipt").read_text())
        messages = ["PROBE-REPLY-1", receipt["prompt"], "PROBE-REPLY-AFTER-SWITCH"]
        if options.shared_owner:
            until(lambda: visible(*messages))
            close_desktop()
        else:
            assert not desktop_pids() and not endpoint.exists(), "Sending unexpectedly launched a desktop or shared daemon"
            desktop_env.pop("CODEX_APP_SERVER_WS_URL")
        open_desktop()
        until(ready, 120)
        if not visible(*messages):
            open_desktop()
        until(lambda: visible(*messages))
        (root / "desktop-reopened").write_text(thread)
        if tests.wait(90):
            raise RuntimeError("Reopen check failed")
        subprocess.run(command, cwd=repo, env={**test_env, "KOLMOGOR_FIXTURE_REOPEN_ONLY": "1"}, check=True, timeout=180)
    finally:
        stop(tests)
        stop(seed_writer)
        try:
            close_desktop()
        finally:
            try:
                if endpoint.exists():
                    subprocess.run([cli, "app-server", "daemon", "stop"], env=env, timeout=45, stdout=subprocess.DEVNULL)
            finally:
                stop(server)
