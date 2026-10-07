"""Small deterministic checks; actual DYLD/TLS coverage needs the owned fixture."""
import asyncio
import socket
import unittest
from v2_actor_network_partition_proxy import ActorPartitionProxy, _Flow


class _Writer:
    def __init__(self):
        self.data = []
        self.delivered = asyncio.Queue()
        self.closed = False
        self.transport = self
    def set_write_buffer_limits(self, high, low):
        pass
    def is_closing(self):
        return self.closed
    def close(self):
        self.closed = True
    async def wait_closed(self):
        pass
    def write(self, data):
        self.data.append(data)
        self.delivered.put_nowait(data)
    async def drain(self):
        pass


class ActorPartitionProxyTests(unittest.IsolatedAsyncioTestCase):
    async def test_ipv6_only_actor_backend_forwards_before_partition(self):
        # Native ClusterShell binds localhost to ::1 on the actual Darwin run.
        # A hardcoded IPv4 backend connected to no listener and caused TLS EOF.
        workers = []
        async def backend(reader, writer):
            workers.append(asyncio.current_task())
            try:
                self.assertEqual(await reader.readexactly(7), b'request')
                writer.write(b'response'); await writer.drain()
            finally:
                writer.close(); await writer.wait_closed()
        server = await asyncio.start_server(backend, '::1', 0)
        port = server.sockets[0].getsockname()[1]
        proxy_base = 19337 if not {port-1, port} & {19337, 19338} else 19340
        proxy = ActorPartitionProxy([port-1, port], proxy_base)
        reader, writer = asyncio.StreamReader(), _Writer()
        flow = _Flow(0, 1, [writer])
        proxy.flows.add(flow); proxy.stats[0, 1]['active'] = 1
        flow.task = asyncio.create_task(proxy._serve(flow, reader, writer))
        try:
            reader.feed_data(b'request')
            self.assertEqual(await asyncio.wait_for(writer.delivered.get(), 2), b'response')
            await asyncio.wait_for(flow.task, 2)
            self.assertEqual(proxy.stats[0, 1]['backendConnected'], 1)
            self.assertEqual(proxy.stats[0, 1]['backendConnectFailures'], 0)
            self.assertEqual(proxy.stats[0, 1]['forwardedBytes'], 15)
            self.assertEqual(proxy.stats[0, 1]['active'], 0)
        finally:
            await proxy.close()
            server.close(); await server.wait_closed()
            await asyncio.gather(*workers, return_exceptions=True)

    async def test_source_maps_and_existing_stream_partition_keep_majority_links(self):
        proxy = ActorPartitionProxy([18337, 18338, 18339], 19337, caller_actor_ports=[18340])
        # A close request alone proves nothing; the public owned FD must also
        # be gone. Preserve the error classification even when cleanup is proven.
        closed_writer = _Writer(); closed_writer.close()
        with socket.socket() as owned_socket:
            self.assertFalse(proxy._socket_closed(closed_writer, owned_socket))
            owned_socket.close()
            self.assertTrue(proxy._socket_closed(closed_writer, owned_socket))
            proxy._record_close_failure('normal', 'peer_reset', confirmed=True)
        self.assertEqual(proxy.snapshot()['confirmedClosureErrorCount'], 1)
        self.assertEqual(proxy.snapshot()['closeFailures']['normal']['peer_reset'], 1)
        self.assertEqual(proxy.snapshot()['unconfirmedClosureCount'], 0)
        self.assertTrue(proxy.snapshot()['fixtureAvailable'])
        maps = [dict(tuple(int(v) for v in pair.split('='))
                     for pair in proxy.port_map(source).split(',')) for source in range(3)]
        self.assertEqual([set(item) for item in maps],
                         [{18338, 18339, 18340}, {18337, 18339, 18340}, {18337, 18338, 18340}])
        self.assertEqual(len({v for item in maps for v in item.values()}), 9)
        caller = dict(tuple(int(v) for v in pair.split('=')) for pair in proxy.port_map(3).split(','))
        self.assertEqual(set(caller), {18337, 18338, 18339})
        self.assertFalse(set(caller.values()) & {v for item in maps for v in item.values()})
        self.assertEqual(proxy.snapshot()['voterCount'], 3)
        self.assertEqual(proxy.snapshot()['nonVotingCallerCount'], 1)
        old_reader = asyncio.StreamReader()
        old_writer = _Writer()
        majority_reader = asyncio.StreamReader()
        majority_writer = _Writer()
        old = asyncio.create_task(proxy._pump(_Flow(0, 1), old_reader, old_writer))
        majority = asyncio.create_task(proxy._pump(_Flow(1, 2), majority_reader, majority_writer))
        try:
            old_reader.feed_data(b'before')
            self.assertEqual(await asyncio.wait_for(old_writer.delivered.get(), 1), b'before')
            proxy.isolate(0)
            old_reader.feed_data(b'partition-existing')
            new_reader, new_writer = asyncio.StreamReader(), _Writer()
            new_reader.feed_data(b'partition-new')
            new_reader.feed_eof()
            await proxy._pump(_Flow(2, 0), new_reader, new_writer)
            caller_reader, caller_writer = asyncio.StreamReader(), _Writer()
            caller_reader.feed_data(b'caller-to-isolated'); caller_reader.feed_eof()
            await proxy._pump(_Flow(3, 0), caller_reader, caller_writer)
            self.assertEqual(caller_writer.data, [])
            reverse_reader, reverse_writer = asyncio.StreamReader(), _Writer()
            reverse_reader.feed_data(b'isolated-to-caller'); reverse_reader.feed_eof()
            await proxy._pump(_Flow(0, 3), reverse_reader, reverse_writer)
            self.assertEqual(reverse_writer.data, [])
            majority_reader.feed_data(b'healthy-majority')
            self.assertEqual(await asyncio.wait_for(majority_writer.delivered.get(), 1), b'healthy-majority')
            old_reader.feed_eof()
            majority_reader.feed_eof()
            await asyncio.gather(old, majority)
            self.assertEqual(old_writer.data, [b'before'])
            self.assertEqual(new_writer.data, [])
            self.assertFalse(old_writer.closed)
            self.assertFalse(majority_writer.closed)
            self.assertEqual(proxy.stats[0, 1]['discardedBytes'], len(b'partition-existing'))
            self.assertEqual(proxy.stats[2, 0]['discardedBytes'], len(b'partition-new'))
        finally:
            old.cancel(); majority.cancel()
            await asyncio.gather(old, majority, return_exceptions=True)
            await proxy.close()
        self.assertEqual(proxy.snapshot()['activeFlows'], 0)


if __name__ == '__main__':
    unittest.main()
