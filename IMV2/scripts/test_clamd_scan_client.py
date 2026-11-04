"""Protocol regression tests for the private resident ClamAV adapter."""
import contextlib
import datetime
import importlib.util
import io
from pathlib import Path
import socket
import struct
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1] / "clamd"
spec = importlib.util.spec_from_file_location("scan_client", ROOT / "scan-client.py")
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
ARGS = ("--stdout --no-summary --database=/var/lib/clamav --official-db-only=yes "
        "--fail-if-cvd-older-than=2 --bytecode-unsigned=no --heuristic-alerts=yes "
        "--alert-encrypted=yes --alert-exceeds-max=yes --max-filesize=268435456 "
        "--max-scansize=536870912 --max-files=10000 --max-recursion=16 --max-scantime=90000 "
        "--follow-dir-symlinks=0 --follow-file-symlinks=0 --tempdir=/tmp -").split()


class Connection:
    def __init__(self, data):
        self.response = io.BytesIO(data)
        self.sent = bytearray()

    def recv(self, n):
        return self.response.read(min(n, 9))

    def sendall(self, data):
        self.sent.extend(data)


class ScanTests(unittest.TestCase):
    def perform(self, reply, days=0, args=ARGS):
        stamp = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)).ctime()
        version = Connection(f"ClamAV 1.5.4/28173/{stamp}\0".encode())
        scanning = Connection(reply)
        data = b'x' * 65537
        with patch.object(client, "CONFIG", ROOT / "clamd.conf"), patch.object(client, "connect",
                side_effect=[contextlib.nullcontext(version), contextlib.nullcontext(scanning)]), contextlib.redirect_stdout(io.StringIO()):
            code = client.scan(args, io.BytesIO(data))
        self.assertEqual(version.sent, b'zVERSION\0')
        self.assertEqual(scanning.sent, b'zINSTREAM\0' + struct.pack('!I', 65536) + data[:-1]
                         + struct.pack('!I', 1) + data[-1:] + bytes(4))
        return code

    def test_scan_and_detection(self):
        self.assertEqual(self.perform(b'stream: OK\0'), 0)
        self.assertEqual(self.perform(b'stream: Eicar-Test-Signature FOUND\0'), 1)

    def test_indeterminate_and_expired_are_never_clean(self):
        for reply in [b'', b'stream: OK', b'stream: OK\nERROR\0', b'INSTREAM size limit exceeded. ERROR\0']:
            with self.subTest(reply=reply), self.assertRaises(ValueError):
                self.perform(reply)
        with self.assertRaises(ValueError):
            self.perform(b'stream: OK\0', days=3)

    def test_weaker_policy_and_unreachable_daemon_are_never_clean(self):
        with self.assertRaises(ValueError):
            self.perform(b'stream: OK\0', args=[x for x in ARGS if x != '--alert-encrypted=yes'])
        with patch.object(client, "CONFIG", ROOT / "clamd.conf"), patch.object(client, "connect", side_effect=socket.timeout):
            with self.assertRaises(OSError):
                client.scan(ARGS, io.BytesIO(b'x'))


if __name__ == "__main__":
    unittest.main()
