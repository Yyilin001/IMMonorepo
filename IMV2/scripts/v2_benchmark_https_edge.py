#!/usr/bin/env python3
"""Owned asyncio loopback HTTPS edge with bounded HTTP/1 requests and private metrics.

Used identically for both benchmark revisions. Does not replace Account business
logic: injects trusted edge headers and forwards every request to real Account.
"""
import argparse
import asyncio
import collections
import json
import signal
import ssl
import time
from pathlib import Path

MAX_BODY = 1024 * 1024
MAX_HEADER = 65536


def headers(raw):
    lines = raw.decode('iso-8859-1').split('\r\n')
    entries = []
    for line in lines[1:]:
        if line:
            key, value = line.split(':', 1)
            entries.append((key.strip(), value.strip()))
    return lines[0], entries


async def body(reader, entries, *, response=False):
    by_name = {k.lower():v for k,v in entries}
    lengths=[v for k,v in entries if k.lower()=='content-length']
    if len(lengths)>1 or ('transfer-encoding' in by_name and lengths):
        raise ValueError('ambiguous body framing')
    if response and not lengths and 'transfer-encoding' not in by_name:
        raise ValueError('response has no explicit body framing')
    if 'transfer-encoding' in by_name:
        if by_name['transfer-encoding'].lower() != 'chunked':
            raise ValueError('unsupported transfer encoding')
        chunks = bytearray()
        while True:
            size_line = await reader.readuntil(b'\r\n')
            size = int(size_line.split(b';')[0],16)
            if size < 0 or len(chunks)+size > MAX_BODY:
                raise ValueError('body too large')
            chunks.extend(size_line)
            if size == 0:
                # Preserve a bounded trailer block, including the final CRLF.
                while True:
                    trailer=await reader.readuntil(b'\r\n')
                    chunks.extend(trailer)
                    if len(chunks)>MAX_BODY:raise ValueError('trailers too large')
                    if trailer==b'\r\n':return bytes(chunks)
            data=await reader.readexactly(size+2)
            if not data.endswith(b'\r\n'):raise ValueError('invalid chunk terminator')
            chunks.extend(data)
    length = int(by_name.get('content-length','0'))
    if not 0 <= length <= MAX_BODY:raise ValueError('body too large')
    return await reader.readexactly(length)


class UpstreamPool:
    """Exclusive checkout; no request pipelining and no automatic body replay."""
    def __init__(self, port, counters, maximum=128):
        self.port=port;self.counters=counters;self.maximum=maximum
        self.slots=asyncio.Semaphore(maximum)
        self.idle=asyncio.LifoQueue(maxsize=maximum)
        self.closed=False

    async def acquire(self):
        await asyncio.wait_for(self.slots.acquire(),timeout=30)
        self.counters['upstreamCheckedOut']+=1
        try:
            if self.closed:raise ConnectionError('pool closed')
            while True:
                try:reader,writer,returned_at=self.idle.get_nowait()
                except asyncio.QueueEmpty:break
                if reader.at_eof() or writer.is_closing() or time.monotonic()-returned_at>30:
                    await self.discard((reader,writer));continue
                self.counters['upstreamReused']+=1
                return reader,writer
            connection=await asyncio.wait_for(asyncio.open_connection('127.0.0.1',self.port,limit=MAX_HEADER),timeout=5)
            self.counters['upstreamCreated']+=1
            self.counters['upstreamOpen']+=1
            self.counters['upstreamPeakOpen']=max(self.counters['upstreamPeakOpen'],self.counters['upstreamOpen'])
            return connection
        except BaseException:
            self.counters['upstreamCheckedOut']-=1;self.slots.release();raise

    async def discard(self, connection):
        writer=connection[1];writer.close()
        self.counters['upstreamDiscarded']+=1;self.counters['upstreamOpen']-=1
        try:await asyncio.wait_for(writer.wait_closed(),timeout=1)
        except (ConnectionError,asyncio.TimeoutError):pass

    async def release(self, connection, reusable):
        try:
            reader,writer=connection
            if reusable and not self.closed and not reader.at_eof() and not writer.is_closing():
                self.idle.put_nowait((reader,writer,time.monotonic()))
            else:await self.discard(connection)
        finally:
            self.counters['upstreamCheckedOut']-=1;self.slots.release()

    async def close(self):
        self.closed=True
        connections=[]
        while not self.idle.empty():
            reader,writer,_=self.idle.get_nowait();connections.append((reader,writer))
        # Close all sockets promptly, with a single bounded concurrent wait.
        await asyncio.gather(*(self.discard(connection) for connection in connections),return_exceptions=True)


async def main(args):
    config=json.loads(args.configuration.read_text())
    tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version=ssl.TLSVersion.TLSv1_2
    tls.set_alpn_protocols(['http/1.1'])
    tls.load_cert_chain(config['certificate'],config['key'])
    semaphore=asyncio.Semaphore(256)
    counters=collections.Counter()
    statuses=collections.Counter()
    durations=[]
    stopped=asyncio.Event()
    clients={}
    busy_tasks=set()
    pool=UpstreamPool(config['upstreamPort'],counters,config.get('maximumUpstreamConnections',128))
    loop=asyncio.get_running_loop()
    for sig in (signal.SIGTERM,signal.SIGINT):loop.add_signal_handler(sig,stopped.set)
    async def serve(reader,writer):
        task=asyncio.current_task();clients[task]=writer
        try:
            while not stopped.is_set():
                raw=await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'),timeout=300)
                if len(raw)>MAX_HEADER:raise ValueError('header too large')
                busy_tasks.add(task)
                started=time.monotonic()
                request_line, entries=headers(raw)
                method,path,version=request_line.split(' ')
                if method not in ('POST','GET') or not path.startswith('/') or version!='HTTP/1.1':
                    raise ValueError('unsupported request')
                payload=await asyncio.wait_for(body(reader,entries),timeout=30)
                excluded={'host','connection','proxy-connection','forwarded','x-forwarded-for','x-real-ip',
                          'x-im-v2-account-edge-authorization','x-im-v2-account-client-address'}
                entries=[(k,v) for k,v in entries if k.lower() not in excluded]
                entries.extend([('Host',f'127.0.0.1:{config["upstreamPort"]}'),
                                ('Connection','keep-alive'),
                                ('X-IM-V2-Account-Edge-Authorization',config['edgeAuthorizationSecret']),
                                ('X-IM-V2-Account-Client-Address','127.0.0.1')])
                encoded=(request_line+'\r\n'+''.join(k+': '+v+'\r\n' for k,v in entries)+'\r\n').encode('iso-8859-1')
                async with semaphore:
                    counters['active']+=1
                    counters['peakActive']=max(counters['peakActive'],counters['active'])
                    try:
                        upstream=await pool.acquire()
                        reusable=False
                        try:
                            up_reader,up_writer=upstream
                            up_writer.write(encoded+payload);await up_writer.drain()
                            response_header=await asyncio.wait_for(up_reader.readuntil(b'\r\n\r\n'),timeout=30)
                            if len(response_header)>MAX_HEADER:raise ValueError('response header too large')
                            status_line,response_entries=headers(response_header)
                            status=int(status_line.split(' ')[1])
                            response_body=await asyncio.wait_for(body(up_reader,response_entries,response=True),timeout=30)
                            close=any(k.lower()=='connection' and v.lower()=='close' for k,v in response_entries)
                            reusable=(status==200 and not close and any(k.lower()=='content-length' for k,v in response_entries)
                                      and not any(k.lower()=='transfer-encoding' for k,v in response_entries))
                            # The complete response is buffered before checkout ends.
                            # Any parse/read/downstream failure discards the connection.
                            writer.write(response_header+response_body);await writer.drain()
                            statuses[str(status)]+=1;counters['requests']+=1
                            durations.append((time.monotonic()-started)*1000)
                            if close:break
                        except BaseException:
                            reusable=False;raise
                        finally:await pool.release(upstream,reusable)
                    finally:
                        counters['active']-=1;busy_tasks.discard(task)
        except (asyncio.IncompleteReadError,ConnectionError,ssl.SSLError):
            counters['peerClosed']+=1
        except Exception as error:
            counters['errors']+=1
            counters[type(error).__name__]+=1
            try:
                writer.write(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');await writer.drain()
            except Exception:pass
        finally:
            busy_tasks.discard(task);clients.pop(task,None)
            writer.close()
    server=await asyncio.start_server(serve,'127.0.0.1',config['listenPort'],ssl=tls,limit=MAX_HEADER,backlog=4096,ssl_handshake_timeout=10)
    async def monitor():
        previous_time=time.monotonic();previous_count=0
        with args.metrics.open('x') as stream:
            while not stopped.is_set():
                try:await asyncio.wait_for(stopped.wait(),timeout=5)
                except asyncio.TimeoutError:pass
                now=time.monotonic();count=counters['requests']
                samples=sorted(durations);durations.clear()
                row=dict(time=time.time(),observedSeconds=now-previous_time,
                         requestsPerSecond=(count-previous_count)/(now-previous_time),
                         counters=dict(counters),statuses=dict(statuses),activeClients=len(clients),
                         latencySamples=len(samples),maximumLatencyMilliseconds=max(samples,default=0),
                         p95LatencyMilliseconds=samples[min(len(samples)-1,int(len(samples)*.95))] if samples else 0)
                stream.write(json.dumps(row)+'\n');stream.flush()
                previous_time=now;previous_count=count
    monitor_task=asyncio.create_task(monitor())
    await stopped.wait();server.close();await server.wait_closed()
    # Stop idle peers immediately; in-flight requests retain their exclusive
    # checkout until completion. Nothing is retried during shutdown.
    for task,writer in list(clients.items()):
        if task not in busy_tasks:writer.close()
    if clients:
        _,pending=await asyncio.wait(list(clients),timeout=35)
        if pending:
            counters['shutdownTimedOut']=len(pending)
            for task in pending:task.cancel()
            await asyncio.gather(*pending,return_exceptions=True)
    await pool.close()
    await monitor_task
    with args.metrics.open('a') as stream:
        stream.write(json.dumps(dict(time=time.time(),shutdown=True,counters=dict(counters),
                                     statuses=dict(statuses),activeClients=len(clients)))+'\n')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration',type=Path,required=True)
    parser.add_argument('--metrics',type=Path,required=True)
    asyncio.run(main(parser.parse_args()))
