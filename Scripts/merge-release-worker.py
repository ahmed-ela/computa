#!/usr/bin/env python3
"""Run in the signing user's launchd session. Only build the default branch's first-parent history."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

REPO = "ahmed-ela/kolmogor"
REMOTE = "https://github.com/" + REPO + ".git"
BRANCH = "kolmogor"
ANCHOR = "c72bcdba2a9afdaed159e63cc8d722eb91c79dea"
LABEL = "wtf.computa.merge-release"
SERVICE = Path.home() / "Library/Application Support/ComputaRelease"


def output(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def save(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value) + "\n")
    temporary.replace(path)


def report(commit, state, description, url=None):
    args = ["gh", "api", "-X", "POST", f"repos/{REPO}/statuses/{commit}", "-f", f"state={state}",
            "-f", "context=Kolmogor / macOS release", "-f", f"description={description}"]
    if url:
        args += ["-f", f"target_url={url}"]
    subprocess.run(args, stdout=subprocess.DEVNULL, check=True)


def run(state):
    if not (state / "release-service").is_file() or (state / "source").is_symlink():
        raise RuntimeError("Expected a dedicated signing checkout")
    if state.stat().st_uid != os.getuid() or state.stat().st_mode & 0o077:
        raise RuntimeError("Release state must be private to the signing user")
    # Public app bundle files need normal read/execute modes inside the private workspace.
    os.umask(0o022)
    # launchd serializes this job; the lock also covers an operator's manual retry.
    with (state / "lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        checkout = state / "source"
        if not checkout.exists():
            subprocess.run(["git", "clone", "--no-checkout", "--single-branch", "-b", BRANCH, REMOTE, checkout], check=True)
        if output("git", "remote", "get-url", "origin", cwd=checkout) != REMOTE:
            raise RuntimeError("Unexpected signing checkout remote")
        git = lambda *args: output("git", *args, cwd=checkout)
        git("fetch", "--quiet", "--tags", "origin", f"refs/heads/{BRANCH}:refs/remotes/origin/{BRANCH}")
        history = git("rev-list", "--first-parent", "--reverse", f"origin/{BRANCH}").splitlines()
        checkpoint = state / "checkpoint.json"
        record = json.loads(checkpoint.read_text()) if checkpoint.exists() else {"cursor": ANCHOR}
        pending = history[history.index(record["cursor"]) + 1:]
        for commit in pending:
            if len(pending) == 1 and time.time() < record.get("retryAfter", 0):
                return
            git("checkout", "--quiet", "--force", "--detach", commit)
            git("clean", "-fdq")
            log = state / f"{commit}.log"
            try:
                tag = output("bun", "Scripts/version.ts", "alpha-tag", cwd=checkout)
                report(commit, "pending", f"Building and notarizing {tag}")
                with log.open("w") as stream:
                    subprocess.run([sys.executable, "-u", "Scripts/release-merged-mac.py", str(state), tag],
                                   cwd=checkout, check=True, stdout=stream, stderr=subprocess.STDOUT)
                report(commit, "success", f"Published {tag}", f"https://github.com/{REPO}/releases/tag/{tag}")
            except Exception as error:
                print(f"Release failed for {commit}: {error}; see {log}", file=sys.stderr)
                report(commit, "failure", "Release failed on signing Mac; see release service log")
                if commit == pending[-1]:
                    save(checkpoint, {"cursor": record["cursor"], "retryAfter": time.time() + 600})
                    raise
                # A later merged fix can ship even if an earlier source cannot build.
            record = {"cursor": commit}
            save(checkpoint, record)
            shutil.rmtree(state / "jobs" / commit, ignore_errors=True)


def install():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("state", type=Path, help="dedicated persistent release directory on the signing Mac")
    parser.add_argument("--identity", required=True)
    parser.add_argument("--notary-profile", required=True)
    parser.add_argument("--sparkle-signer", help="optional already-authorized copy of the pinned Sparkle sign_update")
    opts = parser.parse_args(sys.argv[2:])
    state = opts.state.expanduser().resolve()
    if state.exists() and any(state.iterdir()) and not (state / "release-service").is_file():
        raise RuntimeError("Choose an empty dedicated release directory")
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    state.chmod(0o700)
    (state / "release-service").touch(mode=0o600)
    SERVICE.mkdir(mode=0o700, parents=True, exist_ok=True)
    script = SERVICE / "worker.py"
    shutil.copyfile(__file__, script)
    cfg = {"PATH": os.environ["PATH"], "COMPUTA_SIGN_IDENTITY": opts.identity,
           "COMPUTA_NOTARY_PROFILE": opts.notary_profile, "GIT_TERMINAL_PROMPT": "0", "GH_PROMPT_DISABLED": "1", "TMPDIR": "/private/tmp"}
    for key in ("CARGO_HOME", "RUSTUP_HOME", "DEVELOPER_DIR"):
        if os.getenv(key):
            cfg[key] = os.environ[key]
    if opts.sparkle_signer:
        cfg["COMPUTA_SPARKLE_SIGNER"] = str(Path(opts.sparkle_signer).resolve(strict=True))
    agent = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    agent.parent.mkdir(parents=True, exist_ok=True)
    domain = f"gui/{os.getuid()}"
    if subprocess.run(["launchctl", "print", f"{domain}/{LABEL}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], check=True)
    agent.write_bytes(plistlib.dumps({"Label": LABEL, "ProgramArguments": [sys.executable, str(script), "run", str(state)],
        "EnvironmentVariables": cfg, "RunAtLoad": True, "StartInterval": 60, "ProcessType": "Background",
        "StandardOutPath": str(SERVICE / "worker.log"), "StandardErrorPath": str(SERVICE / "worker.log")}))
    subprocess.run(["launchctl", "bootstrap", domain, str(agent)], check=True)


if __name__ == "__main__":
    os.umask(0o077)
    if sys.argv[1:2] == ["install"]:
        install()
    elif len(sys.argv) == 3 and sys.argv[1] == "run":
        run(Path(sys.argv[2]).resolve(strict=True))
    else:
        sys.exit("Usage: merge-release-worker.py install --help | run STATE")
