#!/usr/bin/env python3
"""Measure the HTTPS edge with an echo upstream; never business capacity."""
import argparse
import asyncio
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


async def client_worker(args):
    context = ssl.create_default_context(cafile=str(args.actor_directory/'ca/cert.pem'))
    clients = await asyncio.gather(*(asyncio.open_connection('127.0.0.1', args.client_worker,
                             ssl=context, server_hostname='localhost') for _ in range(16)))
    await asyncio.sleep(max(0, args.start_at-time.time()))
    started = time.monotonic()
    end = started+5
    async def requests(pair):
        reader, writer = pair
        count = 0
        try:
            while time.monotonic() < end:
                writer.write(b'POST /benchmark-echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 128\r\n\r\n'+b'x'*128)
                await writer.drain()
                raw = await reader.readuntil(b'\r\n\r\n')
                assert raw.startswith(b'HTTP/1.1 200 OK')
                assert await reader.readexactly(11) == b'{"ok":true}'
                count += 1
                if not args.keepalive:
                    writer.close();await writer.wait_closed()
                    if time.monotonic() < end:
                        reader, writer = await asyncio.open_connection('127.0.0.1', args.client_worker,
                                            ssl=context, server_hostname='localhost')
            return count
        finally:writer.close()
    counts = await asyncio.gather(*(requests(pair) for pair in clients))
    print(json.dumps(dict(requests=sum(counts),seconds=time.monotonic()-started)),flush=True)


async def calibration(args):
    os.umask(0o077)
    output = args.output_dir.resolve();output.mkdir(mode=0o700)
    async def echo(reader, writer):
        try:
            while True:
                raw = await reader.readuntil(b'\r\n\r\n')
                length = int(next(x.split(b':')[1] for x in raw.split(b'\r\n') if x.lower().startswith(b'content-length:')))
                await reader.readexactly(length)
                writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: keep-alive\r\n\r\n{"ok":true}')
                await writer.drain()
        except Exception:pass
        finally:writer.close()
    upstream = await asyncio.start_server(echo,'127.0.0.1',0)
    upstream_port = upstream.sockets[0].getsockname()[1]
    processes, streams = [], []
    ports = [free_port() for _ in range(6)]
    try:
        for index, port in enumerate(ports):
            config = output/f'config-{index}.json'
            config.write_text(json.dumps(dict(listenPort=port,upstreamPort=upstream_port,
                   certificate=str(args.actor_directory/'gateway-0/tls.pem'),
                   key=str(args.actor_directory/'gateway-0/tls.key'),edgeAuthorizationSecret='calibration-secret')))
            stream=(output/f'edge-{index}.log').open('x');streams.append(stream)
            processes.append(subprocess.Popen(['python3',str(ROOT/'IMV2/scripts/v2_benchmark_https_edge.py'),
                   '--configuration',str(config),'--metrics',str(output/f'metrics-{index}.jsonl')],stdout=stream,stderr=stream))
        await asyncio.sleep(.5)
        workers=[]
        start_at=time.time()+3
        for port in ports:
            command=[sys.executable,str(Path(__file__).resolve()),'--actor-directory',str(args.actor_directory),
                     '--client-worker',str(port),'--start-at',str(start_at)]
            if args.keepalive:command.append('--keepalive')
            workers.append(await asyncio.create_subprocess_exec(*command,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE))
        worker_reports=[]
        for worker in workers:
            stdout,stderr=await worker.communicate()
            if worker.returncode:raise RuntimeError('calibration client failed: '+stderr.decode())
            worker_reports.append(json.loads(stdout))
        seconds=max(r['seconds'] for r in worker_reports)
        result=dict(kind='proxy-only-echo-calibration-NOT-business-benchmark',edgeProcesses=6,clientProcesses=6,
                    tlsMode='keepalive' if args.keepalive else 'fresh-per-request',connections=96,
                    seconds=seconds,requests=sum(r['requests'] for r in worker_reports),workers=worker_reports)
        result['requestsPerSecond']=result['requests']/seconds
        (output/'result.json').write_text(json.dumps(result,indent=2))
        print(json.dumps(result),flush=True)
    finally:
        for proc in processes:
            if proc.poll() is None:proc.send_signal(signal.SIGTERM)
        await asyncio.sleep(.3)
        for proc in processes:
            try:proc.wait(timeout=5)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        for stream in streams:stream.close()
        upstream.close();await upstream.wait_closed()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--actor-directory',required=True,type=Path)
    parser.add_argument('--output-dir',type=Path,help='must not exist')
    parser.add_argument('--keepalive',action='store_true',help='default fresh TLS matches scoped HTTP client')
    parser.add_argument('--client-worker',type=int,help=argparse.SUPPRESS)
    parser.add_argument('--start-at',type=float,default=0,help=argparse.SUPPRESS)
    args=parser.parse_args();args.actor_directory=args.actor_directory.resolve()
    if not args.client_worker and not args.output_dir:parser.error('--output-dir is required')
    asyncio.run(client_worker(args) if args.client_worker else calibration(args))
