"""Owned loopback TCP relay for TLS backpressure acceptance; never decrypts data."""
import select
import socket
import threading


class TLSBackpressureProxy:
    def __init__(self, upstream_port, listen_port=7443):
        self.upstream_port = upstream_port
        self.stopping = threading.Event()
        self.read_enabled = threading.Event()
        self.read_enabled.set()
        self.lock = threading.Lock()
        self.sockets = set()
        self.workers = []
        self.server_bytes = 0
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', listen_port))
        self.listener.listen(16)
        self.listener.settimeout(.2)
        self.port = self.listener.getsockname()[1]
        self.acceptor = threading.Thread(target=self._accept, daemon=True)
        self.acceptor.start()

    def pause(self):
        self.read_enabled.clear()
        # Apply at the fault boundary too: TCP/TLS setup and normal reads may
        # grow the receive buffer after the connection was established.
        with self.lock:
            for connection in self.sockets:
                try:
                    if connection.getpeername()[1] == self.upstream_port:
                        connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                except OSError:
                    continue  # A peer may close while the fixture pauses.

    def resume(self):
        self.read_enabled.set()

    def disconnect_current(self):
        """Drop owned live sockets, release a stall, and accept future reconnects."""
        with self.lock:
            for connection in self.sockets:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                connection.close()
            self.sockets.clear()
            self.read_enabled.set()

    def snapshot(self):
        with self.lock:
            receive_buffers = []
            for connection in self.sockets:
                try:
                    if connection.getpeername()[1] == self.upstream_port:
                        receive_buffers.append(connection.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF))
                except OSError:
                    continue
            return dict(paused=not self.read_enabled.is_set(), serverBytes=self.server_bytes,
                        activeSockets=len(self.sockets), upstreamReceiveBuffers=receive_buffers)

    def _accept(self):
        while not self.stopping.is_set():
            try:
                downstream, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                upstream = socket.socket()
                upstream.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                upstream.settimeout(5)
                upstream.connect(('127.0.0.1', self.upstream_port))
                # Darwin can replace the pre-connect receive size during TCP
                # setup. Reapply after connect so the paused relay is bounded.
                upstream.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                downstream.setblocking(False)
                upstream.setblocking(False)
            except OSError:
                downstream.close()
                upstream.close()
                continue
            with self.lock:
                self.sockets.update((downstream, upstream))
                for source, target, gated in [(downstream, upstream, False), (upstream, downstream, True)]:
                    worker = threading.Thread(target=self._copy, args=(source, target, gated), daemon=True)
                    self.workers.append(worker)
                    worker.start()

    def _copy(self, source, target, gated):
        try:
            while not self.stopping.is_set():
                if gated and not self.read_enabled.wait(.1):
                    continue
                readable, _, _ = select.select([source], [], [], .1)
                if not readable or (gated and not self.read_enabled.is_set()):
                    continue
                data = source.recv(4096)
                if not data:
                    return
                remaining = memoryview(data)
                # Retain at most one bounded chunk per direction, including when
                # the destination is blocked. Never drop a partially sent chunk.
                while remaining and not self.stopping.is_set():
                    _, writable, _ = select.select([], [target], [], .1)
                    if not writable:
                        continue
                    try:
                        count = target.send(remaining)
                    except BlockingIOError:
                        continue
                    if count == 0:
                        return
                    remaining = remaining[count:]
                    if gated:
                        with self.lock:
                            self.server_bytes += count
        except (OSError, ValueError):
            pass  # Expected when either owned endpoint is closed.
        finally:
            with self.lock:
                for connection in (source, target):
                    if connection in self.sockets:
                        self.sockets.remove(connection)
                        try:
                            connection.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass
                        connection.close()

    def close(self):
        self.stopping.set()
        self.read_enabled.set()
        self.listener.close()
        self.acceptor.join(timeout=6)
        with self.lock:
            for connection in self.sockets:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                connection.close()
            self.sockets.clear()
        for worker in self.workers:
            worker.join(timeout=1)
        if self.acceptor.is_alive() or any(worker.is_alive() for worker in self.workers):
            raise RuntimeError('owned TLS relay did not stop')
