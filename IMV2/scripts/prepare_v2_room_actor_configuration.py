#!/usr/bin/env python3
"""Generate a private local/test Room Actor deployment; never overwrites keys."""
from __future__ import annotations

import argparse
import base64
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import uuid


def command(*args: str) -> bytes:
    result = subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result.stdout


def node(value: str) -> tuple[str, str, int]:
    try:
        name, endpoint = value.split("=", 1)
        address, port_text = endpoint.rsplit(":", 1)
        port = int(port_text)
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected NAME=DNS:PORT") from error
    if not re.fullmatch(r"[a-z][a-z0-9_-]{0,62}", name):
        raise argparse.ArgumentTypeError("node name must use lowercase letters, digits, _ or -")
    if not re.fullmatch(r"[a-zA-Z0-9.-]{1,253}", address) or not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("invalid address or port")
    if all(part.isdigit() for part in address.split(".")):
        raise argparse.ArgumentTypeError("Cluster TLS requires a DNS name; use localhost for local processes")
    return name, address, port


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--host", action="append", type=node, required=True, dest="hosts")
    parser.add_argument("--caller", action="append", type=node, default=[], dest="callers")
    parser.add_argument("--shards", required=True, help="Comma separated configured shard IDs")
    parser.add_argument("--mount-root", help="Path of this node's own directory inside its container")
    args = parser.parse_args()
    nodes = args.hosts + args.callers
    shards = args.shards.split(",")
    if (not 1 <= len(nodes) <= 256 or len({n[0] for n in nodes}) != len(nodes)
            or len({(n[1], n[2]) for n in nodes}) != len(nodes)
            or not 1 <= len(shards) <= 256 or len(set(shards)) != len(shards)
            or any(not s or s != s.strip() for s in shards)):
        parser.error("node identities/endpoints and shard IDs must be unique, nonempty and bounded")
    # An explicit new output directory prevents accidental rotation of a live
    # host's signing identity or modification of an existing private CA.
    root = args.output_dir.resolve()
    if root.exists():
        parser.error("output directory already exists; keep existing identities or choose a new directory")
    os.umask(0o077)
    root.mkdir(parents=True, mode=0o700)
    ca = root / "ca"
    ca.mkdir(mode=0o700)
    command("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-keyout", str(ca / "key.pem"), "-out", str(ca / "cert.pem"),
            "-days", "365", "-subj", "/CN=IM V2 local Room Actor CA",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    host_names = {item[0] for item in args.hosts}
    host_ids = {name: str(uuid.uuid4()) for name in host_names}
    services = []
    for name, address, _ in nodes:
        directory = root / name
        directory.mkdir(mode=0o700)
        command("openssl", "genpkey", "-algorithm", "ED25519", "-out", str(directory / "signing.pem"))
        private_der = command("openssl", "pkey", "-in", str(directory / "signing.pem"), "-outform", "DER")
        public_der = command("openssl", "pkey", "-in", str(directory / "signing.pem"), "-pubout", "-outform", "DER")
        if (len(private_der) != 48 or private_der[:16] != bytes.fromhex("302e020100300506032b657004220420")
                or len(public_der) != 44 or public_der[:12] != bytes.fromhex("302a300506032b6570032100")):
            raise RuntimeError("OpenSSL emitted an unsupported Ed25519 DER encoding")
        (directory / "signing.key").write_bytes(private_der[-32:])
        (directory / "signing.pem").unlink()
        try:
            ipaddress.ip_address(address)
            san = "IP:" + address
        except ValueError:
            san = "DNS:" + address
        extensions = directory / "extensions.cnf"
        extensions.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n"
                              "extendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=" + san + "\n")
        command("openssl", "req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                "-nodes", "-keyout", str(directory / "tls.key"), "-out", str(directory / "tls.csr"),
                "-subj", "/CN=" + address)
        command("openssl", "x509", "-req", "-in", str(directory / "tls.csr"),
                "-CA", str(ca / "cert.pem"), "-CAkey", str(ca / "key.pem"), "-CAcreateserial",
                "-out", str(directory / "tls.pem"), "-days", "365", "-extfile", str(extensions))
        (directory / "tls.csr").unlink()
        extensions.unlink()
        shutil.copyfile(ca / "cert.pem", directory / "ca.pem")
        permissions = ["userRoomCalls", "roomCoordination"]
        if name in host_names:
            permissions += ["roomMaintenance", "trustedSafety", "specialAccountAudit"]
        services.append(dict(id=name, publicKeyBase64=base64.b64encode(public_der[-32:]).decode(),
                             permissions=permissions, hostIDs=[host_ids[name]] if name in host_names else [],
                             shardIDs=shards))
    peers = [dict(hostID=host_ids[name], serviceID=name, address=address, port=port,
                  shardIDs=shards, maximumRooms=10000) for name, address, port in args.hosts]
    for name, address, port in nodes:
        directory = root / name
        visible = Path(args.mount_root) if args.mount_root else directory
        write_json(directory / "configuration.json", dict(name="imv2-room-actors", address=address,
            port=port, threadPoolSize=2, serviceID=name, hostID=host_ids.get(name),
            signingKeyPath=str(visible / "signing.key"), certificatePath=str(visible / "tls.pem"),
            privateKeyPath=str(visible / "tls.key"), trustRootPath=str(visible / "ca.pem"),
            services=services, peers=peers))
    write_json(root / "topology.json", dict(hosts=args.hosts, callers=args.callers, shards=shards, hostIDs=host_ids))
    print(f"Created {len(nodes)} local/test node configurations in {root}")
    print("Mount only each process's own node directory; keep the CA private key outside application containers.")


if __name__ == "__main__":
    main()
