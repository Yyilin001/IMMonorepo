"""Bounded, owned fault injection for the local author acceptance fixture.

The relay forwards encrypted bytes unchanged and retains at most 128 KiB. It
does not inspect credentials, TLS records, messages or profiles. Pausing its
upstream reads lets the real Gateway encounter TCP backpressure even when the
native client's networking framework reads ahead internally.
"""
import select
import socket
import threading
import time
import uuid


class AuthorByteRelay:
    buffer_limit = 64 * 1024

    def __init__(self, upstream_port):
        if not isinstance(upstream_port, int) or not 0 < upstream_port < 65536:
            raise ValueError('invalid relay destination')
        self.upstream_port = upstream_port
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.pause_until = 0.0
        self.accepted = False
        self.error_type = None
        self.forwarded = [0, 0]
        self.peak_buffered = 0
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.setblocking(False)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self._run, name='owned-author-byte-relay')
        self.thread.start()

    def pause(self, seconds):
        if not 0 < seconds <= 10:
            raise ValueError('invalid relay pause')
        with self.lock:
            if not self.accepted or self.stop.is_set() or not self.thread.is_alive():
                raise ValueError('relay is not connected')
            if self.pause_until > time.monotonic():
                raise ValueError('relay is already paused')
            self.pause_until = time.monotonic() + seconds

    def resume(self):
        with self.lock:
            self.pause_until = 0.0

    def snapshot(self):
        with self.lock:
            return dict(connected=self.accepted, paused=time.monotonic() < self.pause_until,
                clientToGatewayBytes=self.forwarded[0], gatewayToClientBytes=self.forwarded[1],
                peakBufferedBytes=self.peak_buffered, errorType=self.error_type,
                threadAlive=self.thread.is_alive())

    def close(self):
        self.stop.set()
        self.thread.join(timeout=3)
        if self.thread.is_alive():
            raise RuntimeError('owned relay did not drain')

    def _run(self):
        client = upstream = None
        try:
            while not self.stop.is_set():
                if select.select([self.listener], [], [], 0.05)[0]:
                    client, _ = self.listener.accept()
                    break
            if client is None:
                return
            upstream = socket.socket()
            upstream.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8192)
            upstream.settimeout(2)
            upstream.connect(('127.0.0.1', self.upstream_port))
            upstream.setblocking(False)
            client.setblocking(False)
            with self.lock:
                self.accepted = True
            sources, destinations = [client, upstream], [upstream, client]
            buffers = [bytearray(), bytearray()]
            while not self.stop.is_set():
                with self.lock:
                    paused = time.monotonic() < self.pause_until
                enabled = [0] if paused else [0, 1]
                readers = [sources[i] for i in enabled if len(buffers[i]) < self.buffer_limit]
                writers = [destinations[i] for i in enabled if buffers[i]]
                readable, writable, _ = select.select(readers, writers, [], 0.02)
                for i in enabled:
                    if sources[i] in readable:
                        try:
                            data = sources[i].recv(min(16 * 1024, self.buffer_limit - len(buffers[i])))
                        except BlockingIOError:
                            continue
                        if not data:
                            return
                        buffers[i].extend(data)
                    if destinations[i] in writable and buffers[i]:
                        try:
                            sent = destinations[i].send(buffers[i])
                        except BlockingIOError:
                            continue
                        del buffers[i][:sent]
                        with self.lock:
                            self.forwarded[i] += sent
                with self.lock:
                    self.peak_buffered = max(self.peak_buffered, sum(map(len, buffers)))
        except (OSError, ValueError) as error:
            if not self.stop.is_set():
                with self.lock:
                    self.error_type = type(error).__name__
        finally:
            with self.lock:
                self.accepted = False
            for owned in [client, upstream, self.listener]:
                if owned is not None:
                    owned.close()


class AuthorProfileLock:
    """One bounded transaction against the verifier's disposable PostgreSQL.

    Only the profile-specific aliases relation is locked. Login and ordinary
    message authorization must continue through their real production paths.
    The caller must supply the verifier's private SQL function, never a shared
    or deployed database connection.
    """
    def __init__(self, sql):
        self.sql = sql
        self.marker = 'owned_author_fault_' + uuid.uuid4().hex
        self.lock = threading.Lock()
        self.thread = None
        self.error_type = None
        self.completed = threading.Event()

    def start(self, seconds=8):
        if not isinstance(seconds, int) or not 1 <= seconds <= 10:
            raise ValueError('invalid profile lock duration')
        with self.lock:
            if self.thread is not None:
                raise ValueError('profile fault already started')
            self.thread = threading.Thread(target=self._run, args=(seconds,), name='owned-author-profile-lock')
            self.thread.start()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if self.is_held():
                return
            if self.completed.wait(0.025):
                break
        raise RuntimeError('profile fault lock was not acquired')

    def is_held(self):
        if self.thread is None or self.completed.is_set():
            return False
        return self.sql("""SELECT EXISTS (
            SELECT 1 FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid
            WHERE a.application_name='%s' AND a.datname=current_database()
              AND l.relation='im_v2.user_contact_aliases'::regclass
              AND l.mode='AccessExclusiveLock' AND l.granted)::int;""" % self.marker,
            timeout=2).strip() == '1'

    def close(self):
        if self.thread is not None:
            self.thread.join(timeout=14)
            if self.thread.is_alive():
                raise RuntimeError('owned profile fault did not drain')

    def snapshot(self):
        with self.lock:
            return dict(started=self.thread is not None, completed=self.completed.is_set(),
                errorType=self.error_type, threadAlive=self.thread is not None and self.thread.is_alive())

    def _run(self, seconds):
        try:
            # The generated marker and bounded integer are the only inputs.
            self.sql("""BEGIN;
                SET LOCAL application_name='%s';
                SET LOCAL lock_timeout='1s';
                SET LOCAL statement_timeout='12s';
                LOCK TABLE im_v2.user_contact_aliases IN ACCESS EXCLUSIVE MODE;
                SELECT pg_sleep(%d);
                ROLLBACK;""" % (self.marker, seconds), timeout=14)
        except Exception as error:
            with self.lock:
                self.error_type = type(error).__name__
        finally:
            self.completed.set()
