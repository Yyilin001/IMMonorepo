"""Opt-in, task-owned App TCP lost-ACK fixture. TLS stays end-to-end.

Only the sender uses this listener. Arm BEFORE submitting, observe the exact
PostgreSQL fact outside this process, then POST /switch. No SQL, certificates,
credentials, payload logging, process spawning, or automatic fault timing.
"""
from __future__ import annotations
import argparse
import asyncio
import json
import signal
import uuid


class AppACKCutProxy:
    def __init__(self, listen_port: int, control_port: int, gateway_a: int, gateway_b: int):
        ports = (listen_port, control_port, gateway_a, gateway_b)
        if len(set(ports)) != 4 or any(not 1 <= p <= 65535 for p in ports):
            raise ValueError('invalid_fixture_ports')
        self.listen_port, self.control_port = listen_port, control_port
        self.target = gateway_a
        self.gateway_b = gateway_b
        self.held = False
        self.closed = False
        self.gate = asyncio.Event(); self.gate.set()
        self.flows = {}
        self.servers = []
        self.control_tasks = set()
        self.fixture = None
        self.opened = 0
        self.drained = 0
        self.close_failures = 0
        self.confirmed_closure_errors = 0
        self.closure_errors = {kind: 0 for kind in ('timeout', 'cancelled', 'peer_reset', 'io_error', 'other')}
        self.switched = False

    async def start(self):
        try:
            for host in ('127.0.0.1', '::1'):
                self.servers.append(await asyncio.start_server(self.forward, host, self.listen_port,
                    limit=16_384, backlog=4))
                self.servers.append(await asyncio.start_server(self.control, host, self.control_port,
                    limit=8_192, backlog=4))
        except BaseException:
            await self.close()
            raise

    def snapshot(self):
        return {'fixture': self.fixture, 'held': self.held, 'switched': self.switched, 'closed': self.closed,
                'opened': self.opened, 'drained': self.drained, 'closeFailures': self.close_failures,
                'confirmedErrorCount': self.confirmed_closure_errors, 'closureErrors': dict(self.closure_errors),
                'flows': [{'physicalProxyID': key, 'gatewayPort': item[0]}
                          for key, item in self.flows.items()]}

    async def forward(self, reader, writer):
        # One sender, at most its old and successor socket. Never an unbounded
        # accepted-connection queue; readers/chunks are <=16KiB per direction.
        if self.closed or len(self.flows) >= 2:
            writer.close(); await writer.wait_closed(); return
        key, target = str(uuid.uuid4()), self.target
        task = asyncio.current_task()
        self.flows[key] = (target, writer, None, task)
        self.opened += 1
        upstream = None
        # Capture the public socket before /switch or a remote RST closes it;
        # get_extra_info after transport shutdown may no longer return it.
        owned_sockets = {writer: writer.get_extra_info('socket')}
        try:
            remote, upstream = await asyncio.wait_for(asyncio.open_connection('127.0.0.1', target,
                limit=16_384), 5)
            self.flows[key] = (target, writer, upstream, task)
            owned_sockets[upstream] = upstream.get_extra_info('socket')

            async def pump(source, destination, downlink=False):
                while True:
                    if downlink: await self.gate.wait()
                    chunk = await source.read(16_384)
                    if not chunk: return
                    # Arm can occur while read was suspended. Check again before
                    # dispatch: no post-arm application ACK reaches the client.
                    if downlink: await self.gate.wait()
                    destination.write(chunk)
                    await destination.drain()

            children = [asyncio.create_task(pump(reader, upstream)),
                        asyncio.create_task(pump(remote, writer, True))]
            try:
                await asyncio.wait(children, return_when=asyncio.FIRST_COMPLETED)
            finally:
                for child in children: child.cancel()
                await asyncio.gather(*children, return_exceptions=True)
        except (OSError, asyncio.TimeoutError, asyncio.CancelledError):
            pass
        finally:
            for stream in (writer, upstream):
                if stream is not None: stream.close()
            confirmed = True
            try:
                for stream in (writer, upstream):
                    if stream is not None:
                        if not await self._confirm_closed(stream, owned_sockets.get(stream)):
                            confirmed = False
            finally:
                self.flows.pop(key, None)
                if confirmed: self.drained += 1
                else: self.close_failures += 1

    @staticmethod
    def _socket_closed(writer, owned_socket):
        try:
            return (owned_socket is not None and writer.transport.is_closing()
                    and owned_socket.fileno() == -1)
        except (AttributeError, OSError): return False

    async def _confirm_closed(self, writer, owned_socket):
        try:
            await asyncio.wait_for(writer.wait_closed(), 5)
            return True
        except asyncio.TimeoutError: kind = 'timeout'
        except asyncio.CancelledError: kind = 'cancelled'
        except ConnectionResetError: kind = 'peer_reset'
        except OSError: kind = 'io_error'
        except Exception: kind = 'other'
        self.closure_errors[kind] += 1
        # CPython connection_lost(exc) can settle wait_closed with the original
        # RST/IO failure AFTER the actual socket was closed. Keep that error
        # observable; confirm only its captured public FD+transport witness.
        # Neither a timeout nor cancellation earns this terminal exception rule.
        if kind in ('peer_reset', 'io_error') and self._socket_closed(writer, owned_socket):
            self.confirmed_closure_errors += 1
            return True
        return False

    async def control(self, reader, writer):
        task = asyncio.current_task()
        if self.closed or len(self.control_tasks) >= 4:
            writer.close()
            try: await writer.wait_closed()
            except OSError: pass
            return
        self.control_tasks.add(task)
        status, response = 200, None
        try:
            header = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 5)
            if len(header) > 4_096: raise ValueError('header_bound')
            lines = header.decode('ascii').split('\r\n')
            method, path, _ = lines[0].split(' ')
            headers = dict(line.lower().split(':', 1) for line in lines[1:] if ':' in line)
            length = int(headers.get('content-length', '0'))
            if not 0 <= length <= 4_096: raise ValueError('body_bound')
            body = await asyncio.wait_for(reader.readexactly(length), 5)
            if method == 'GET' and path == '/status':
                pass
            elif method == 'POST' and path == '/arm':
                value = json.loads(body)
                allowed = {'nonce', 'accountID', 'roomID', 'clientMessageID', 'workID',
                           'fingerprintHex', 'fingerprintVersion', 'firstSubmissionDeadlineMilliseconds',
                           'connectionGeneration'}
                if self.fixture is not None or len(self.flows) != 1 or set(value) != allowed:
                    raise ValueError('invalid_arm')
                for field in ('nonce', 'accountID', 'roomID', 'clientMessageID', 'workID', 'connectionGeneration'):
                    uuid.UUID(value[field])
                if len(value['fingerprintHex']) != 64: raise ValueError('fingerprint')
                bytes.fromhex(value['fingerprintHex'])
                if value['fingerprintVersion'] != 1 or type(value['firstSubmissionDeadlineMilliseconds']) is not int:
                    raise ValueError('invalid_identity')
                self.fixture = value
                self.held = True; self.gate.clear()
            elif method == 'POST' and path == '/switch':
                value = json.loads(body)
                if not self.held or self.switched or value != {'nonce': self.fixture['nonce'], 'databaseFactConfirmed': True}:
                    raise ValueError('switch_requires_external_fact_gate')
                # Only the runner that has independently observed COMMIT calls
                # this endpoint. This flag is an assertion, never PG evidence.
                old_tasks = [item[3] for item in self.flows.values()]
                failures_before = self.close_failures
                self.target = self.gateway_b; self.switched = True
                for item in list(self.flows.values()):
                    item[1].close()
                    if item[2] is not None: item[2].close()
                    item[3].cancel()
                await asyncio.gather(*old_tasks, return_exceptions=True)
                self.held = False; self.gate.set()
                if self.close_failures != failures_before:
                    raise ValueError('old_flow_close_unconfirmed')
            else:
                raise ValueError('unknown_control')
            response = self.snapshot()
        except (ValueError, KeyError, TypeError, UnicodeError, asyncio.IncompleteReadError,
                asyncio.LimitOverrunError, asyncio.TimeoutError):
            status, response = 400, {'error': 'invalid_fixture_control'}
        finally:
            try:
                data = json.dumps(response, sort_keys=True).encode()
                writer.write(f'HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {len(data)}\r\nConnection: close\r\n\r\n'.encode() + data)
                try: await writer.drain()
                except OSError: pass
            finally:
                writer.close()
                try: await asyncio.wait_for(writer.wait_closed(), 5)
                except (OSError, asyncio.TimeoutError, asyncio.CancelledError): pass
                self.control_tasks.discard(task)

    async def close(self):
        self.closed = True
        for server in self.servers: server.close()
        for server in self.servers: await server.wait_closed()
        tasks = [item[3] for item in self.flows.values()]
        for task in tasks: task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        controls = list(self.control_tasks)
        for task in controls: task.cancel()
        await asyncio.gather(*controls, return_exceptions=True)


async def main():
    parser = argparse.ArgumentParser()
    for name in ('listen-port', 'control-port', 'gateway-a', 'gateway-b'):
        parser.add_argument('--' + name, type=int, required=True)
    args = parser.parse_args()
    proxy = AppACKCutProxy(args.listen_port, args.control_port, args.gateway_a, args.gateway_b)
    await proxy.start()
    print(json.dumps({'ready': True, 'listenPort': args.listen_port, 'controlPort': args.control_port}), flush=True)
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT): loop.add_signal_handler(sig, stopped.set)
    try: await stopped.wait()
    finally:
        await proxy.close()
        print(json.dumps({'stopped': True, **proxy.snapshot()}, sort_keys=True), flush=True)


if __name__ == '__main__':
    try: asyncio.run(main())
    except KeyboardInterrupt: pass
