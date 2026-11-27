"""Local, fixed-operation broker. The account service cannot supply commands or Kubernetes manifests."""
import base64
from concurrent.futures import ThreadPoolExecutor
import pwd
import json
import os
from pathlib import Path
import re
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
K3S = ["/usr/local/bin/k3s", "kubectl"]
WORKSPACE = ROOT.parent / "k3s" / "workspace"
STATE = Path(os.environ.get("STATE_DIRECTORY", "/var/lib/kolmogor-broker"))
SOCKET = Path("/run/kolmogor-broker/accounts.sock")
NAMESPACE = re.compile(r"kolmogor-ws-u-[0-9a-f]{40}")
DEPLOYMENTS = {"codex": "cli", "claude": "claude"}
MAX_WORKSPACES = int(os.environ.get("MAX_WORKSPACES", "4"))
LOCK = threading.RLock()
POOL = ThreadPoolExecutor(max_workers=4)
preparing = {}
logins = {}
starting = set()
# The same page selection runs in the workspace and in the browser regression tests.
BROWSER = (ROOT / "browser-account.cjs").read_text() + """
const pw = require(require.resolve('playwright', {paths: ['/opt/workspace-tools']}));
(async () => {
  const browser = await pw.chromium.connectOverCDP('http://127.0.0.1:9222');
  try {
    console.log(JSON.stringify(await workspaceAccount(browser.contexts()[0], process.argv[1])));
  } finally {
    await browser.close();
  }
})().catch(() => process.exit(1));
"""
RFB = """
const s=require('node:net').connect(5900,'127.0.0.1');
s.on('error',()=>process.exit(1));s.on('close',()=>process.exit());
process.stdin.pipe(s).pipe(process.stdout);
"""


def run(args, *, data=None, check=True, timeout=25):
    return subprocess.run(args, input=data, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, check=check, timeout=timeout)


def kubectl(ns, *args):
    return K3S + ["-n", ns, *args]


def container(ns, provider, *args, interactive=False):
    name = DEPLOYMENTS.get(provider, "browser")
    return kubectl(ns, "exec", *(["-i"] if interactive else []),
                   "deployment/" + name, "-c", name, "--", *args)


def prepare(ns):
    # Allocation files are created before provisioning, survive restart, and bound capacity.
    current = run(K3S + ["get", "namespace", ns, "--ignore-not-found", "-o", "name"]).stdout.strip()
    if not current:
        run(K3S + ["create", "namespace", ns])
    run(kubectl(ns, "apply", "-f", str(ROOT / "limits.yaml")))
    run([str(WORKSPACE), ns, "provision"], timeout=240)
    (STATE / ns / "ready").touch()


def allocation(ns, ensure=False):
    directory = STATE / ns
    with LOCK:
        if not directory.exists():
            if not ensure:
                raise ValueError("Workspace is not allocated.")
            if sum(p.is_dir() and NAMESPACE.fullmatch(p.name) is not None for p in STATE.iterdir()) >= MAX_WORKSPACES:
                raise ValueError("This server has reached its workspace capacity.")
            directory.mkdir(mode=0o700)
        if (directory / "ready").is_file():
            return True
        if ensure:
            future = preparing.get(ns)
            if future and future.done():
                del preparing[ns]
                future.result()  # Surface a failed attempt before allowing the next retry.
            if ns not in preparing:
                preparing[ns] = POOL.submit(prepare, ns)
        return False


def provider_state(ns, provider):
    args = ["codex", "login", "status"] if provider == "codex" else ["claude", "auth", "status", "--json"]
    replicas = run(kubectl(ns, "get", "deployment", DEPLOYMENTS[provider], "-o", "jsonpath={.status.readyReplicas}")).stdout
    if replicas != "1":
        return False
    if provider == "codex":
        proc = subprocess.run(container(ns, provider, *args), capture_output=True, text=True, timeout=15)
        return proc.returncode == 0 and "logged in" in (proc.stdout + proc.stderr).lower()
    proc = run(container(ns, provider, *args), check=False, timeout=15)
    try:
        return proc.returncode == 0 and json.loads(proc.stdout).get("loggedIn") is True
    except (ValueError, AttributeError):
        return False


def browser_account(ns, action):
    proc = run(container(ns, "chrome", "node", "-e", BROWSER, action))
    return json.loads(proc.stdout) is True


def sign_in_details(provider, output):
    output = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", output)
    endpoints = {
        "codex": {("auth.openai.com", "/codex/device"), ("chatgpt.com", "/codex/device")},
        "claude": {("claude.ai", "/oauth/authorize")},
    }
    url = None
    for candidate in re.findall(r"(https://[^\s<>\x00-\x1f]+)(?=\s)", output):
        try:
            target = urlsplit(candidate)
            allowed = (target.hostname, target.path) in endpoints[provider]
            if allowed and target.username is None and target.password is None and target.port in (None, 443):
                url = candidate
                break
        except ValueError:
            continue
    if not url:
        return {"message": "Waiting for the provider’s sign-in page…"}
    if provider == "claude":
        return {"url": url, "acceptsCode": True, "message": "Open Claude, approve this connection, and enter the code Claude gives you."}
    match = re.search(r"(?<![A-Za-z0-9])([A-Z0-9]{4,6}-[A-Z0-9]{4,6})(?![A-Za-z0-9])", output)
    if not match:
        return {"message": "Waiting for the Codex device code…"}
    return {"url": url, "message": f"Open the Codex device page and enter {match[1]}."}


class Login:
    def __init__(self, ns, provider):
        self.provider = provider
        self.output = b""
        self.lock = threading.Lock()
        self.written = False
        args = ["codex", "login", "--device-auth"] if provider == "codex" else ["claude", "auth", "login", "--claudeai"]
        self.proc = subprocess.Popen(container(ns, provider, *args, interactive=True), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.expire = threading.Timer(600, self.stop)
        self.expire.daemon = True
        self.expire.start()
        threading.Thread(target=self.read, daemon=True).start()

    def stop(self):
        if self.proc.poll() is None:
            self.proc.kill()

    def read(self):
        try:
            while chunk := self.proc.stdout.read1(4096):
                with self.lock:
                    self.output = (self.output + chunk)[-16_384:]
        finally:
            self.proc.wait()
            self.proc.stdout.close()
            self.proc.stdin.close()
            self.expire.cancel()
            with self.lock:
                self.output = b""

    def details(self):
        with self.lock:
            return sign_in_details(self.provider, self.output.decode(errors="replace"))

    def code(self, value):
        if self.provider != "claude" or not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9._~#/+=%-]{8,2048}", value):
            raise ValueError("Invalid authorization code.")
        with self.lock:
            if self.written or self.proc.poll() is not None:
                raise ValueError("Start a new sign-in.")
            self.proc.stdin.write(value.encode() + b"\n")
            self.proc.stdin.flush()
            self.written = True


def dispatch(ns, action, provider=None, code=None):
    if not isinstance(ns, str) or not NAMESPACE.fullmatch(ns):
        raise ValueError("Invalid workspace.")
    if action not in ("ensure", "status", "start", "code", "display") or (
            action in ("start", "code") and provider not in ("codex", "claude", "chrome")):
        raise ValueError("Unknown workspace operation.")
    ready = allocation(ns, ensure=action == "ensure")
    if action == "ensure" or not ready:
        return {"ready": ready}
    if action == "display":
        return None
    if action == "status":
        result = {}
        for p in DEPLOYMENTS:
            with LOCK:
                login = logins.get((ns, p))
                pending = (ns, p) in starting or login and login.proc.poll() is None
            result[p] = "pending" if pending else ("connected" if provider_state(ns, p) else "disconnected")
        result["chrome"] = "connected" if browser_account(ns, "status") else "ready"
        return {"ready": True, "providers": result}
    if provider == "chrome":
        if action != "start":
            raise ValueError("Use Chrome’s own sign-in page.")
        browser_account(ns, "start")
        secret = run(kubectl(ns, "get", "secret", "browser-viewer", "-o", "jsonpath={.data.password}")).stdout
        return {"password": base64.b64decode(secret).decode()}
    key = (ns, provider)
    with LOCK:
        login = logins.get(key)
        if action == "code":
            if not login:
                raise ValueError("Start a new sign-in.")
            login.code(code)
            return {"submitted": True}
        if login and login.proc.poll() is None:
            return login.details()
        if key in starting:
            return {"message": "Starting the workspace provider…"}
        starting.add(key)
    try:
        run([str(WORKSPACE), ns, "start", provider], timeout=140)
        if provider_state(ns, provider):
            return {"connected": True}
        login = Login(ns, provider)
        with LOCK:
            logins[key] = login
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline and login.proc.poll() is None:
            result = login.details()
            if result.get("url"):
                return result
            time.sleep(.15)
        if login.proc.poll() is not None:
            raise ValueError("The provider could not start sign-in.")
        return login.details()
    finally:
        with LOCK:
            starting.discard(key)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(12)
        try:
            line = self.rfile.readline(4097)
            if len(line) > 4096 or not line.endswith(b"\n"):
                return
            msg = json.loads(line)
            result = dispatch(msg.get("workspace"), msg.get("action"), msg.get("provider"), msg.get("code"))
            if msg.get("action") == "display" and result is None:
                self.wfile.write(b'{"display":true}\n')
                subprocess.run(container(msg["workspace"], "chrome", "node", "-e", RFB, interactive=True),
                               stdin=self.request, stdout=self.request, stderr=subprocess.DEVNULL, timeout=900)
                return
            self.wfile.write(json.dumps(result).encode() + b"\n")
        except ValueError as exc:
            # Only known, user-safe messages may cross this boundary.
            message = str(exc) if type(exc) is ValueError and str(exc) in SAFE_ERRORS else "Invalid workspace request."
            self.wfile.write(json.dumps({"error": message}).encode() + b"\n")
        except (OSError, subprocess.SubprocessError, TypeError, AttributeError):
            self.wfile.write(b'{"error":"The workspace service is unavailable."}\n')


SAFE_ERRORS = {"This server has reached its workspace capacity.", "Start a new sign-in.",
               "Invalid authorization code.", "The provider could not start sign-in."}


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    gate = threading.BoundedSemaphore(24)

    def verify_request(self, request, client_address):
        # The socket path alone is insufficient to identify its caller.
        credentials = request.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, _gid = struct.unpack("3i", credentials)
        return uid == self.account_uid

    def process_request(self, request, client_address):
        if not self.gate.acquire(blocking=False):
            request.close()
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.gate.release()


if __name__ == "__main__":
    os.umask(0o077)
    SOCKET.unlink(missing_ok=True)
    with Server(str(SOCKET), Handler) as server:
        account = pwd.getpwnam("kolmogor-accounts")
        server.account_uid = account.pw_uid
        os.chown(SOCKET, account.pw_uid, account.pw_gid)
        os.chmod(SOCKET, 0o600)
        server.serve_forever()
