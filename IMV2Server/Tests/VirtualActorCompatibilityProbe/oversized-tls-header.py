#!/usr/bin/env python3
"""Send only an oversized length header through the real ClusterSystem TLS socket."""
import argparse
import socket
import ssl
import struct
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--host", required=True)
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--maximum-frame-bytes", type=int, required=True)
args = parser.parse_args()

context = ssl.create_default_context(cafile=str(args.evidence / "ca.pem"))
context.load_cert_chain(str(args.evidence / "client.pem"), str(args.evidence / "client.key"))
with socket.create_connection((args.host, args.port), timeout=5) as plain:
    with context.wrap_socket(plain, server_hostname=args.host) as secured:
        secured.settimeout(5)
        print("TLS_ESTABLISHED", flush=True)
        secured.sendall(b"\x5a\xc7" + struct.pack("!I", args.maximum_frame_bytes + 1))
        try:
            received = secured.recv(1)
        except (ConnectionResetError, BrokenPipeError, ssl.SSLEOFError):
            received = b""
        if received != b"":
            raise RuntimeError(f"oversized header received a response instead of close: {received!r}")
        print("OVERSIZED_HEADER_CLOSED", flush=True)
