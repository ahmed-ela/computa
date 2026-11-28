#!/usr/bin/env python3
"""Opt-in signed-in macOS check. Send only a generated marker to the three CLIs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
FILTER = "CodexDesktopSidebarTests.testRealImportAndProviderContinuation"


class Source:
    def __init__(self, cwd):
        self.process = subprocess.Popen(
            [shutil.which("codex") or "codex", "app-server", "--listen", "stdio://",
             "-c", "mcp_servers={}", "-c", "features.hooks=false", "-c", "features.apps=false",
             "-c", "features.plugins=false", "-c", 'web_search="disabled"'],
            cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.inbox = queue.Queue()
        self.sequence = 0

        def read():
            try:
                for line in self.process.stdout:
                    self.inbox.put(json.loads(line))
            finally:
                self.inbox.put(None)
        threading.Thread(target=read, daemon=True).start()

    def send(self, frame):
        self.process.stdin.write(json.dumps(frame) + "\n")
        self.process.stdin.flush()

    def until(self, match, timeout=120):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            frame = self.inbox.get(timeout=max(0.01, end - time.monotonic()))
            if frame is None:
                raise RuntimeError("Codex disconnected")
            if match(frame):
                return frame
        raise TimeoutError("Codex response timed out")

    def call(self, method, params):
        self.sequence += 1
        self.send({"id": self.sequence, "method": method, "params": params})
        frame = self.until(lambda f: f.get("id") == self.sequence and "method" not in f)
        if "error" in frame:
            raise RuntimeError(f"{method}: {frame['error'].get('message')}")
        return frame["result"]

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def initialize(cwd):
    source = Source(cwd)
    try:
        source.call("initialize", {"clientInfo": {"name": "kolmogor_import_test", "version": "1"},
                                   "capabilities": {"experimentalApi": True}})
        source.send({"method": "initialized"})
        return source
    except BaseException:
        source.close()
        raise


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-path", help="Reuse a SwiftPM build directory")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="kolmogor-import-") as folder:
        path = Path(folder).resolve()
        source = initialize(path)
        thread_id = None
        try:
            token = uuid.uuid4().hex[:8].upper()
            marker = "LANTERN-" + token
            title = "Kolmogor model check " + token
            result = source.call("thread/start", {"cwd": str(path), "model": "gpt-6.2-sol", "modelProvider": "openai",
                                                  "allowProviderModelFallback": False, "sandbox": "read-only",
                                                  "approvalPolicy": "never", "environments": []})
            thread_id = result["thread"]["id"]
            assert result["model"] == "gpt-6.2-sol"
            turn = source.call("turn/start", {"threadId": thread_id, "input": [{"type": "text", "text": "Reply with exactly " + marker}]})
            source.until(lambda f: f.get("method") == "turn/completed" and f["params"]["turn"]["id"] == turn["turn"]["id"])
            source.call("thread/name/set", {"threadId": thread_id, "name": title})
            (path / "thread.json").write_text(json.dumps({"id": thread_id, "title": title, "wordA": marker}))

            def fingerprint():
                thread = source.call("thread/read", {"threadId": thread_id, "includeTurns": True})["thread"]
                assert thread["id"] == thread_id and Path(thread["cwd"]).resolve() == path
                assert any(i.get("text") == marker for t in thread["turns"] for i in t["items"])
                return hashlib.sha256(json.dumps([thread["model"], thread["turns"]], sort_keys=True).encode()).digest()

            before = fingerprint()
            env = dict(os.environ, KOLMOGOR_IMPORT_LIVE=str(path))
            env.pop("KOLMOGOR_IMPORT_TEST_MODE", None)
            cmd = ["swift", "test", "--jobs", "5", "--filter", FILTER]
            if args.scratch_path:
                cmd.extend(["--scratch-path", str(Path(args.scratch_path).resolve())])
            subprocess.run(cmd, env=env, cwd=REPO, check=True)
            assert fingerprint() == before, "Import or continuation changed the source thread"
            source.call("thread/archive", {"threadId": thread_id})
            thread_id = None
            subprocess.run(cmd, env=dict(env, KOLMOGOR_IMPORT_TEST_MODE="reopen"), cwd=REPO, check=True)
        finally:
            try:
                if thread_id:
                    source.call("thread/archive", {"threadId": thread_id})
            finally:
                source.close()


if __name__ == "__main__":
    run()
