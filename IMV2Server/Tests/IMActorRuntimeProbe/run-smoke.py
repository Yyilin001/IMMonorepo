#!/usr/bin/env python3
"""Two real processes over TLS 1.3. No database, containers, or load campaign.
Build IMActorRuntimeProbe first, then pass its executable path.
"""
import argparse
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("executable", type=Path)
args = parser.parse_args()
executable = str(args.executable.resolve())

def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]

with tempfile.TemporaryDirectory(prefix="im-actor-smoke-") as tmp:
    directory = Path(tmp)
    (directory / "tls.cnf").write_text("""[req]
distinguished_name=dn
prompt=no
x509_extensions=ext
[dn]
CN=localhost
[ext]
subjectAltName=DNS:localhost
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage=serverAuth,clientAuth
""")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-config", str(directory / "tls.cnf"), "-keyout", str(directory / "key.pem"),
                    "-out", str(directory / "cert.pem")], check=True, capture_output=True)
    reference = directory / "actor.json"
    server_port, client_port = free_port(), free_port()
    while client_port == server_port:
        client_port = free_port()
    server = subprocess.Popen([executable, "server", str(server_port), str(reference), tmp],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        deadline = time.monotonic() + 10
        while not reference.exists():
            if server.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("server failed to start: " + server.communicate(timeout=1)[0])
            time.sleep(0.02)
        # Reject a declared oversized frame before reading its body, over real mTLS.
        tls_command = ["openssl", "s_client", "-connect", f"localhost:{server_port}",
                       "-servername", "localhost", "-CAfile", str(directory / "cert.pem"),
                       "-tls1_3", "-verify_return_error", "-brief", "-ign_eof"]
        secured = subprocess.run(tls_command + ["-cert", str(directory / "cert.pem"),
                                  "-key", str(directory / "key.pem")],
                                 input=struct.pack("!I", 2 * 1_048_576 + 1), capture_output=True, timeout=5)
        assert b"TLSv1.3" in secured.stderr, secured.stderr.decode(errors="replace")
        assert secured.stdout == b"", "oversized frame was accepted"
        unauthenticated = subprocess.run(tls_command, input=b"\0\0\0\x20", capture_output=True, timeout=5)
        assert b"certificate required" in unauthenticated.stderr.lower(), unauthenticated.stderr.decode(errors="replace")
        client = subprocess.run([executable, "client", str(client_port), str(reference), tmp],
                                capture_output=True, text=True, timeout=15)
        if client.returncode:
            server.terminate()
            raise RuntimeError(client.stdout + client.stderr + server.communicate(timeout=3)[0])
        output = server.communicate(timeout=15)[0]
        if server.returncode:
            raise RuntimeError(output)
        print(client.stdout.strip())
        print("PASS: TLS 1.3 mutual authentication and header-only oversized-frame rejection")
    finally:
        if server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait()
