"""One owned loopback check; no Gateway, PostgreSQL, TLS, or process launch."""
import asyncio
import socket
import struct
import unittest
from v2_app_tcp_ack_cut_proxy import AppACKCutProxy


class AppACKCutProxyTests(unittest.IsolatedAsyncioTestCase):
    async def test_arm_during_read_blocks_ack_and_reset_closure_is_confirmed(self):
        request_seen = asyncio.Event()
        send_ack = asyncio.Event()
        ack_dispatched = asyncio.Event()
        backend_tasks = set()
        backend_writers = set()

        async def backend(reader, writer):
            task = asyncio.current_task()
            backend_tasks.add(task); backend_writers.add(writer)
            try:
                self.assertEqual(await reader.readexactly(7), b'request')
                request_seen.set()
                await send_ack.wait()
                writer.write(b'ACK'); await writer.drain()
                ack_dispatched.set()
                await reader.read()
            finally:
                writer.close()
                try: await writer.wait_closed()
                except OSError: pass
                backend_tasks.discard(task); backend_writers.discard(writer)

        server = await asyncio.start_server(backend, '127.0.0.1', 0)
        port = server.sockets[0].getsockname()[1]
        # Constructor-only unused ports; the test listener itself binds :0.
        unused = [p for p in (19141, 19142, 19143, 19144) if p != port][:3]
        proxy = AppACKCutProxy(unused[0], unused[1], port, unused[2])
        flow_started = asyncio.Event()
        flow_tasks = []

        async def accepted(reader, writer):
            task = asyncio.current_task(); flow_tasks.append(task)
            flow_started.set()
            await proxy.forward(reader, writer)

        listener = await asyncio.start_server(accepted, '127.0.0.1', 0)
        client = None
        try:
            reader, client = await asyncio.open_connection('127.0.0.1', listener.sockets[0].getsockname()[1])
            await asyncio.wait_for(flow_started.wait(), 2)
            client.write(b'request'); await client.drain()
            await asyncio.wait_for(request_seen.wait(), 2)
            # Both pumps have started. The downstream read is waiting for bytes;
            # arming now must block its later read result BEFORE writer.write.
            proxy.held = True; proxy.gate.clear()
            send_ack.set()
            await asyncio.wait_for(ack_dispatched.wait(), 2)
            with self.assertRaises(asyncio.TimeoutError):
                await asyncio.wait_for(reader.readexactly(3), .1)
            # A real peer RST makes CPython's wait_closed future raise although
            # its public captured socket is already closed. No synthetic writer.
            owned_socket = client.get_extra_info('socket')
            owned_socket.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
            client.transport.abort()
            await asyncio.wait_for(asyncio.gather(*flow_tasks), 2)
            self.assertEqual(proxy.flows, {})
            self.assertEqual(proxy.drained, 1)
            self.assertEqual(proxy.close_failures, 0)
            self.assertGreater(proxy.closure_errors['peer_reset'], 0)
            self.assertGreater(proxy.confirmed_closure_errors, 0)
        finally:
            if client is not None: client.close()
            listener.close(); server.close()
            await listener.wait_closed(); await server.wait_closed()
            await proxy.close()
            for writer in list(backend_writers): writer.close()
            for task in list(backend_tasks): task.cancel()
            await asyncio.gather(*list(backend_tasks), return_exceptions=True)


if __name__ == '__main__':
    unittest.main()
