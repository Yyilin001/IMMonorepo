#!/usr/bin/env python3
"""Real loopback checks for the verifier's owned encrypted-byte relay."""
import socket
import time
import unittest

from v2_live_author_faults import AuthorByteRelay


class ByteRelayTests(unittest.TestCase):
    def setUp(self):
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(2)
        self.relay = AuthorByteRelay(self.listener.getsockname()[1])
        self.client = socket.create_connection(('127.0.0.1', self.relay.port), timeout=2)
        self.upstream, _ = self.listener.accept()
        self.upstream.settimeout(2)
        self.client.sendall(b'hello')
        self.assertEqual(self.read(self.upstream, 5), b'hello')

    def tearDown(self):
        self.relay.close()
        self.client.close()
        self.upstream.close()
        self.listener.close()
        self.assertFalse(self.relay.snapshot()['threadAlive'])

    @staticmethod
    def read(stream, count):
        result = bytearray()
        while len(result) < count:
            data = stream.recv(count - len(result))
            if not data:
                raise EOFError('owned fixture closed before expected bytes')
            result.extend(data)
        return bytes(result)

    def test_pause_holds_gateway_bytes_but_allows_client_requests_and_resumes_exactly(self):
        self.relay.pause(2)
        # Let the relay finish any select already in flight before the pause.
        time.sleep(.04)
        self.upstream.sendall(b'a' * 65536)
        self.client.sendall(b'client-request')
        self.assertEqual(self.read(self.upstream, 14), b'client-request')
        self.client.settimeout(.1)
        with self.assertRaises(socket.timeout):
            self.client.recv(1)
        self.relay.resume()
        self.client.settimeout(2)
        self.assertEqual(self.read(self.client, 65536), b'a' * 65536)
        state = self.relay.snapshot()
        self.assertEqual(state['errorType'], None)
        self.assertLessEqual(state['peakBufferedBytes'], 128 * 1024)
        self.assertEqual(state['gatewayToClientBytes'], 65536)
        self.assertEqual(state['clientToGatewayBytes'], 19)

    def test_pause_expires_without_a_release_request(self):
        self.relay.pause(.2)
        time.sleep(.04)
        self.upstream.sendall(b'automatic-recovery')
        self.client.settimeout(.05)
        with self.assertRaises(socket.timeout):
            self.client.recv(1)
        self.client.settimeout(2)
        self.assertEqual(self.read(self.client, 18), b'automatic-recovery')
        self.assertFalse(self.relay.snapshot()['paused'])

    def test_unconnected_relay_drains_and_rejects_pause(self):
        relay = AuthorByteRelay(self.listener.getsockname()[1])
        try:
            with self.assertRaises(ValueError):
                relay.pause(1)
        finally:
            relay.close()
        self.assertFalse(relay.snapshot()['threadAlive'])
        with self.assertRaises(ValueError):
            relay.pause(1)

    def test_fault_duration_and_overlapping_pause_are_bounded(self):
        for duration in (0, -1, 11):
            with self.assertRaises(ValueError):
                self.relay.pause(duration)
        self.relay.pause(1)
        with self.assertRaises(ValueError):
            self.relay.pause(1)


if __name__ == '__main__':
    unittest.main()
