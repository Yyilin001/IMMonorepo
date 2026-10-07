"""Task-owned Actor TLS byte-stream partition fixture, never a production proxy.

No TLS parsing, packet capture, payload log, process launch, compiler or signing.
Every ordered source/target pair, including a non-voting caller endpoint in both
directions, gets its own loopback listener and immutable
connect mapping. Only owned Gateways receive the dylib environment. Keep their
original Actor endpoints/TLS configuration; PG and client ports MUST be outside
all original/proxy Actor ports. Isolation silently discards existing/new TLS
bytes for links touching that node. Other links remain operational.
Read chunks and transport watermarks bound user-space buffering; kernel socket
buffers remain OS-managed. Bytes dispatched before isolation may still arrive. Healing
closes isolated old channels, then permits fresh authenticated connections.

This simulates silent Actor transport loss, not kernel packet-loss timing. A
loaded shim marker alone is insufficient: require proxy flows on every actual
Actor association, unchanged PG/client liveness, and healthy majority links.
Uninstrumented callers can bypass the proxies: restrict the fixture roster.
"""
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
from dataclasses import dataclass, field


@dataclass(eq=False)
class _Flow:
    source: int
    target: int
    writers: list = field(default_factory=list)
    task: asyncio.Task | None = None


class ActorPartitionProxy:
    def __init__(self, actor_ports: list[int], proxy_port_base: int, *,
                 maximum_flows: int = 128, buffer_bytes: int = 16_384,
                 caller_actor_ports: list[int] | None = None):
        if not 2 <= len(actor_ports) <= 6 or len(set(actor_ports)) != len(actor_ports):
            raise ValueError('invalid_node_roster')
        if any(type(p) is not int or not 1 <= p <= 65535 for p in actor_ports):
            raise ValueError('invalid_actor_ports')
        if not 1 <= maximum_flows <= 512 or not 1024 <= buffer_bytes <= 65_536:
            raise ValueError('invalid_fixture_bounds')
        caller_actor_ports = [] if caller_actor_ports is None else caller_actor_ports
        # Six voters plus one non-voting caller fits the immutable six-peer C
        # mapping bound. Caller endpoints participate in streams, never votes.
        if (len(caller_actor_ports) > 1 or len(set(actor_ports+caller_actor_ports)) != len(actor_ports)+len(caller_actor_ports)
                or any(type(p) is not int or not 1 <= p <= 65535 for p in caller_actor_ports)):
            raise ValueError('invalid_non_voting_callers')
        self.endpoint_ports = tuple(actor_ports+caller_actor_ports)
        self.source_count = len(self.endpoint_ports)
        pairs = [(s, t) for s in range(self.source_count) for t in range(self.source_count) if s != t]
        ports = list(range(proxy_port_base, proxy_port_base + len(pairs)))
        if not ports or ports[0] < 1 or ports[-1] > 65535 or set(ports) & set(self.endpoint_ports):
            raise ValueError('invalid_proxy_ports')
        self.actor_ports = tuple(actor_ports)
        self.proxy_ports = dict(zip(pairs, ports))
        self.maximum_flows = maximum_flows
        self.buffer_bytes = buffer_bytes
        self.isolated: set[int] = set()
        self.healing: set[int] = set()
        self.flows: set[_Flow] = set()
        self.servers: list[asyncio.Server] = []
        self.closed = False
        self.closed_codes: set[str] = set()
        # Fixed aggregate records survive forwarding-task removal. These are
        # failed confirmation attempts, never a claim about current OS FD count.
        self.unconfirmed_closures = 0
        self.confirmed_closure_errors = 0
        self.close_failures = {phase: {kind: 0 for kind in
            ('timeout', 'peer_reset', 'io_error', 'cancelled', 'other')}
            for phase in ('normal', 'healing', 'shutdown')}
        self.stats = {pair: {'opened': 0, 'active': 0, 'forwardedBytes': 0,
                             'discardedBytes': 0, 'backendFailures': 0, 'backendConnected': 0,
                             'backendConnectFailures': 0, 'streamFailures': 0} for pair in pairs}

    def port_map(self, source: int) -> str:
        if not 0 <= source < self.source_count:
            raise ValueError('invalid_node')
        return ','.join(f'{self.endpoint_ports[target]}={port}' for (node, target), port
                        in sorted(self.proxy_ports.items()) if node == source)

    def injection_environment(self, source: int, dylib: str | Path) -> dict[str, str]:
        path = Path(dylib)
        if not path.is_absolute() or not path.is_file():
            raise ValueError('missing_task_owned_dylib')
        return {'DYLD_INSERT_LIBRARIES': str(path), 'V2_ACTOR_PORT_MAP': self.port_map(source)}

    async def start(self) -> None:
        if self.closed or self.servers:
            raise ValueError('invalid_fixture_lifecycle')
        try:
            for (source, target), port in self.proxy_ports.items():
                def accepted(reader, writer, source=source, target=target):
                    self._accepted(source, target, reader, writer)
                # Two explicit listeners prevent localhost IPv6 from silently
                # bypassing the mapping or relying on dual-stack defaults.
                for host in ('127.0.0.1', '::1'):
                    self.servers.append(await asyncio.start_server(accepted, host, port,
                        limit=self.buffer_bytes, backlog=64))
        except Exception:
            self.closed_codes.add('proxy_bind_failed')
            await self.close()
            raise RuntimeError('fixture_unavailable') from None

    def _accepted(self, source, target, reader, writer):
        if source in self.healing or target in self.healing:
            # A finite repair phase closes attempts so no new blackholed flow
            # survives the old-flow drain and is mistaken for a repaired link.
            writer.close()
            return
        if self.closed or len(self.flows) >= self.maximum_flows:
            self.closed_codes.add('flow_capacity_exceeded' if not self.closed else 'late_accept')
            writer.close()
            return
        flow = _Flow(source, target, [writer])
        self.flows.add(flow)
        self.stats[source, target]['active'] += 1
        self.stats[source, target]['opened'] += 1
        flow.task = asyncio.create_task(self._serve(flow, reader, writer))

    async def _serve(self, flow, reader, writer):
        pumps = []
        connected = False
        try:
            remote_reader, remote_writer = await asyncio.wait_for(asyncio.open_connection(
                'localhost', self.endpoint_ports[flow.target], limit=self.buffer_bytes,
                happy_eyeballs_delay=0.05, interleave=1), timeout=3)
            connected = True
            self.stats[flow.source, flow.target]['backendConnected'] += 1
            flow.writers.append(remote_writer)
            for output in flow.writers:
                output.transport.set_write_buffer_limits(high=self.buffer_bytes, low=self.buffer_bytes // 2)
            pumps = [asyncio.create_task(self._pump(flow, reader, remote_writer)),
                     asyncio.create_task(self._pump(flow, remote_reader, writer))]
            done, _ = await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        except asyncio.CancelledError:
            pass
        except Exception:
            item = self.stats[flow.source, flow.target]
            item['backendFailures'] += 1
            item['streamFailures' if connected else 'backendConnectFailures'] += 1
        finally:
            for task in pumps:
                task.cancel()
            if pumps:
                await asyncio.gather(*pumps, return_exceptions=True)
            # Capture the public socket before close; asyncio may subsequently
            # clear its internal transport reference. No socket IDs are logged.
            sockets = []
            for output in flow.writers:
                try: sockets.append(output.get_extra_info('socket'))
                except (AttributeError, OSError): sockets.append(None)
                output.close()
            phase = ('shutdown' if self.closed else 'healing'
                     if flow.source in self.healing or flow.target in self.healing else 'normal')
            async def finished(output, owned_socket):
                try:
                    await asyncio.wait_for(output.wait_closed(), timeout=1)
                except asyncio.CancelledError:
                    self._record_close_failure(phase, 'cancelled')
                    raise
                except TimeoutError:
                    self._record_close_failure(phase, 'timeout')
                except ConnectionResetError:
                    self._record_close_failure(phase, 'peer_reset',
                        confirmed=self._socket_closed(output, owned_socket))
                except OSError:
                    self._record_close_failure(phase, 'io_error',
                        confirmed=self._socket_closed(output, owned_socket))
                except Exception:
                    self._record_close_failure(phase, 'other')
            await asyncio.gather(*(finished(output, owned_socket) for output, owned_socket in zip(flow.writers, sockets)), return_exceptions=True)
            self.flows.discard(flow)
            self.stats[flow.source, flow.target]['active'] -= 1

    @staticmethod
    def _socket_closed(output, owned_socket):
        try:
            return (owned_socket is not None and output.transport.is_closing()
                    and owned_socket.fileno() == -1)
        except (AttributeError, OSError): return False

    def _record_close_failure(self, phase, kind, *, confirmed=False):
        # connection_lost(exc) completes wait_closed with an error, but its
        # actual selector callback still closes the FD before awaiting resumes.
        # Preserve the error counts; only a public closed-FD witness confirms
        # ownership cleanup. Timeouts/cancellation never use this exception rule.
        self.close_failures[phase][kind] += 1
        if confirmed:
            self.confirmed_closure_errors += 1
        else:
            self.closed_codes.add('socket_close_not_confirmed')
            self.unconfirmed_closures += 1

    async def _pump(self, flow, reader, writer):
        while True:
            data = await reader.read(self.buffer_bytes)
            if not data:
                return
            item = self.stats[flow.source, flow.target]
            if flow.source in self.isolated or flow.target in self.isolated:
                # Read and discard without FIN/RST or unbounded retained bytes.
                item['discardedBytes'] += len(data)
            else:
                writer.write(data)
                await writer.drain()
                item['forwardedBytes'] += len(data)

    def isolate(self, node: int) -> None:
        if self.closed or not 0 <= node < len(self.actor_ports):
            raise ValueError('invalid_node_or_lifecycle')
        self.isolated.add(node)

    async def heal(self, node: int) -> None:
        if self.closed or not 0 <= node < len(self.actor_ports):
            raise ValueError('invalid_node_or_lifecycle')
        # Stay isolated while old connections actually finish; releasing the
        # blackhole first could forward residual ciphertext to old sessions.
        self.healing.add(node)
        selected = [f for f in self.flows if f.source == node or f.target == node]
        for flow in selected:
            if flow.task:
                flow.task.cancel()
        await asyncio.gather(*(f.task for f in selected if f.task), return_exceptions=True)
        self.isolated.discard(node)
        self.healing.discard(node)

    def snapshot(self) -> dict:
        return {'formatVersion': 1, 'fixtureAvailable': not self.closed_codes,
                'closedCodes': sorted(self.closed_codes), 'closed': self.closed,
                'voterCount': len(self.actor_ports), 'nonVotingCallerCount': self.source_count-len(self.actor_ports),
                'isolatedNodes': sorted(self.isolated), 'healingNodes': sorted(self.healing), 'maximumFlows': self.maximum_flows,
                'streamWatermarkBytes': self.buffer_bytes, 'activeFlows': len(self.flows),
                'unconfirmedClosureCount': self.unconfirmed_closures,
                'confirmedClosureErrorCount': self.confirmed_closure_errors,
                'closeFailures': {phase: dict(counts) for phase, counts in self.close_failures.items()},
                'closureObservation': 'failed confirmation attempts; activeFlows counts forwarding tasks, not OS descriptors',
                'links': [{'sourceNode': s, 'sourceRole': 'voter' if s < len(self.actor_ports) else 'caller',
                          'targetNode': t, 'targetRole': 'voter' if t < len(self.actor_ports) else 'caller', **item}
                          for (s, t), item in sorted(self.stats.items())]}

    async def close(self) -> None:
        self.closed = True
        for server in self.servers:
            server.close()
        await asyncio.gather(*(s.wait_closed() for s in self.servers), return_exceptions=True)
        self.servers.clear()
        tasks = [f.task for f in self.flows if f.task]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def _main(args):
    proxy = ActorPartitionProxy(args.actor_ports, args.proxy_port_base,
                                maximum_flows=args.maximum_flows, caller_actor_ports=args.caller_actor_ports)
    try:
        await proxy.start()
        print(json.dumps({'event': 'ready', 'nodePortMaps': [proxy.port_map(i)
                          for i in range(len(proxy.actor_ports))],
                          'callerPortMaps': [proxy.port_map(i) for i in range(len(proxy.actor_ports), proxy.source_count)], **proxy.snapshot()}), flush=True)
        # Control is task-owned stdin, not another public network service.
        while line := await asyncio.to_thread(input):
            command = json.loads(line)
            action = command.get('action')
            if action == 'isolate': proxy.isolate(command['node'])
            elif action == 'heal': await proxy.heal(command['node'])
            elif action == 'snapshot': pass
            elif action == 'close': break
            else: raise ValueError('invalid_control')
            print(json.dumps({'event': action, **proxy.snapshot()}), flush=True)
    except EOFError:
        pass
    except Exception:
        print(json.dumps({'event': 'fixture_unavailable', 'code': 'control_or_proxy_failed'}), flush=True)
        raise SystemExit(125) from None
    finally:
        await proxy.close()
        print(json.dumps({'event': 'closed', **proxy.snapshot()}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--actor-ports', type=lambda s: [int(p) for p in s.split(',')], required=True)
    parser.add_argument('--proxy-port-base', type=int, required=True)
    parser.add_argument('--maximum-flows', type=int, default=128)
    parser.add_argument('--caller-actor-ports', type=lambda s: [int(p) for p in s.split(',')], default=[])
    asyncio.run(_main(parser.parse_args()))
