"""Temporary, operator-granted RFB access over a user's SSH command channel."""
import fcntl
import os
import signal
from pathlib import Path
import selectors
import socket
import subprocess
import sys
import time

SOCKETS = Path('/run/kolmogor-view')
# The executable in the pod can only connect to the workspace's fixed RFB endpoint.
RFB = """
const s = require('node:net').connect(5900, '127.0.0.1');
s.on('error', () => process.exit(1));
s.on('close', () => process.exit());
process.stdin.pipe(s).pipe(process.stdout);
"""


def share_display(kubectl, namespace, uid, seconds):
    if os.geteuid() != 0:
        sys.exit('Run the display grant as a node administrator.')
    SOCKETS.mkdir(mode=0o711, exist_ok=True)
    SOCKETS.chmod(0o711)
    path = SOCKETS / f'{uid}-{namespace}.sock'
    def stop(_signum, _frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    with path.with_suffix('.lock').open('a') as lock, socket.socket(socket.AF_UNIX) as listener:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit('A display grant is already active for this user and workspace.')
        # A crash can leave a socket behind. The root-owned directory and lock
        # keep cleanup from touching another grant.
        os.umask(0o077)
        path.unlink(missing_ok=True)
        listener.bind(str(path))
        try:
            os.chown(path, uid, -1)
            os.chmod(path, 0o600)
            listener.listen(1)
            deadline = time.monotonic() + seconds
            print(f'Display granted to uid {uid} for {seconds // 60} minutes.', flush=True)
            while time.monotonic() < deadline:
                listener.settimeout(max(.01, deadline-time.monotonic()))
                try:
                    peer, _ = listener.accept()
                except TimeoutError:
                    break
                with peer:
                    try:
                        subprocess.run(kubectl + ['exec','-i','deploy/browser','-c','browser','--','node','-e',RFB],
                                       stdin=peer, stdout=peer, timeout=max(.01, deadline-time.monotonic()))
                    except subprocess.TimeoutExpired:
                        break
        finally:
            path.unlink(missing_ok=True)


def stream_display(namespace):
    path = SOCKETS / f'{os.getuid()}-{namespace}.sock'
    with socket.socket(socket.AF_UNIX) as display, selectors.DefaultSelector() as ready:
        display.connect(str(path))
        ready.register(display, selectors.EVENT_READ)
        ready.register(sys.stdin.fileno(), selectors.EVENT_READ)
        while True:
            for event, _ in ready.select():
                if event.fileobj is display:
                    data = display.recv(65536)
                    if not data:
                        return
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                else:
                    data = os.read(sys.stdin.fileno(), 65536)
                    if not data:
                        return
                    display.sendall(data)
