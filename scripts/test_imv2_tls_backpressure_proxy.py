"""Exercise the owned relay through a verified TLS connection on ephemeral ports."""
import queue
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

from imv2_tls_backpressure_proxy import TLSBackpressureProxy


class TLSBackpressureProxyTests(unittest.TestCase):
    def test_disconnect_releases_paused_workers_and_accepts_a_new_connection(self):
        failures = queue.Queue()
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen(2)
            listener.settimeout(5)

            def serve():
                try:
                    for _ in range(2):
                        connection, _ = listener.accept()
                        with connection:
                            connection.settimeout(5)
                            while data := connection.recv(4096):
                                connection.sendall(data)
                except BaseException as error:
                    failures.put(error)

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            relay = TLSBackpressureProxy(listener.getsockname()[1], listen_port=0)
            try:
                with socket.create_connection(('127.0.0.1', relay.port), timeout=5) as first:
                    first.sendall(b'first')
                    self.assertEqual(first.recv(5), b'first')
                    relay.pause()
                    relay.disconnect_current()
                    self.assertEqual(first.recv(1), b'')
                    deadline = time.monotonic() + 5
                    while any(item.is_alive() for item in relay.workers) and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertFalse(any(item.is_alive() for item in relay.workers))
                    self.assertEqual(relay.snapshot()['activeSockets'], 0)
                    self.assertFalse(relay.snapshot()['paused'])
                with socket.create_connection(('127.0.0.1', relay.port), timeout=5) as second:
                    second.sendall(b'next')
                    self.assertEqual(second.recv(4), b'next')
            finally:
                relay.close()
                worker.join(timeout=5)
            self.assertFalse(worker.is_alive())
            if not failures.empty():
                raise failures.get()

    def test_pause_after_handshake_and_exact_resume(self):
        with tempfile.TemporaryDirectory(prefix='imv2-relay-test-') as directory:
            root = Path(directory)
            certificate, key = root / 'certificate.pem', root / 'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-days', '1', '-subj', '/CN=localhost',
                            '-addext', 'subjectAltName=DNS:localhost',
                            '-keyout', str(key), '-out', str(certificate)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(certificate, key)
            client_context = ssl.create_default_context(cafile=str(certificate))
            payload = bytes(range(256)) * 1024
            failures = queue.Queue()
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                listener.listen(1)
                listener.settimeout(10)

                def serve():
                    try:
                        raw, _ = listener.accept()
                        raw.settimeout(10)
                        with server_context.wrap_socket(raw, server_side=True) as connection:
                            if connection.recv(1) != b'G':
                                raise AssertionError('missing client start signal')
                            connection.sendall(payload)
                            if connection.recv(1) != b'A':
                                raise AssertionError('missing client completion signal')
                    except BaseException as error:
                        failures.put(error)

                worker = threading.Thread(target=serve, daemon=True)
                worker.start()
                relay = TLSBackpressureProxy(listener.getsockname()[1], listen_port=0)
                try:
                    with socket.create_connection(('127.0.0.1', relay.port), timeout=10) as raw:
                        with client_context.wrap_socket(raw, server_hostname='localhost') as connection:
                            # The TLS handshake and its normal network reads have
                            # completed before injecting the receive stall.
                            relay.pause()
                            state = relay.snapshot()
                            self.assertTrue(state['paused'])
                            self.assertEqual(state['upstreamReceiveBuffers'], [4096])
                            connection.sendall(b'G')
                            connection.settimeout(.2)
                            with self.assertRaises(socket.timeout):
                                connection.recv(1)
                            relay.resume()
                            connection.settimeout(10)
                            received = bytearray()
                            while len(received) < len(payload):
                                chunk = connection.recv(min(16384, len(payload) - len(received)))
                                self.assertTrue(chunk, 'relay truncated the TLS payload')
                                received.extend(chunk)
                            self.assertEqual(received, payload)
                            connection.sendall(b'A')
                            worker.join(timeout=10)
                            self.assertFalse(worker.is_alive())
                finally:
                    relay.close()
                    worker.join(timeout=10)
                self.assertEqual(relay.snapshot()['activeSockets'], 0)
                self.assertFalse(worker.is_alive())
                if not failures.empty():
                    raise failures.get()


if __name__ == '__main__':
    unittest.main()
