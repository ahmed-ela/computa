"""Exercise the same authenticated RFB display used for human takeover."""
from contextlib import contextmanager
import socket
import struct
import subprocess

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes


@contextmanager
def connection(kube):
    forward = subprocess.Popen(kube + ['port-forward', '--address=127.0.0.1',
                                      'deployment/browser', ':5900'], stdout=subprocess.PIPE, text=True)
    try:
        line = forward.stdout.readline()
        port = int(line.split('127.0.0.1:')[1].split()[0])
        with socket.create_connection(('127.0.0.1', port), timeout=10) as sock:
            with sock.makefile('rb') as source:
                yield sock, source
    finally:
        forward.terminate()
        forward.wait(timeout=10)


def type_in_display(kube, password, text):
    with connection(kube) as (sock, source):
        assert source.read(12) == b'RFB 003.008\n'
        sock.sendall(b'RFB 003.008\n')
        mechanisms = source.read(source.read(1)[0])
        assert 2 in mechanisms and 1 not in mechanisms, 'Viewer requires VNC password authentication'
        sock.sendall(b'\x02')
        key = bytes(int(f'{byte:08b}'[::-1], 2) for byte in password)
        crypt = Cipher(algorithms.TripleDES(key), modes.ECB()).encryptor()
        sock.sendall(crypt.update(source.read(16)) + crypt.finalize())
        assert source.read(4) == bytes(4), 'Viewer authentication failed'
        sock.sendall(b'\x01')
        width, height = struct.unpack('!HH', source.read(4))
        assert (width, height) == (1366, 768)
        source.read(16)
        source.read(int.from_bytes(source.read(4), 'big'))
        for char in text:
            for down in (1, 0):
                sock.sendall(struct.pack('!BBHI', 4, down, 0, ord(char)))
        # A framebuffer update after the last key establishes the server processed input.
        sock.sendall(struct.pack('!BBHHHH', 3, 0, 0, 0, 5, 5))
        assert source.read(1) == bytes(1)
