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
    parser.add_argument("--placement-voter", action="append", type=node, required=True, dest="voters",
                        help="Exactly three independent control nodes, name=DNS:port")
    parser.add_argument("--caller", action="append", type=node, default=[], dest="callers")
    parser.add_argument("--worker-caller", action="append", default=[],
                        help="Caller identity also running authorized room maintenance/safety workers")
    parser.add_argument("--exclusion-supervisor", action="append", default=[],
                        help="Explicit caller with only placement read/write/exclusion authority")
    parser.add_argument("--shards", required=True, help="Comma separated configured shard IDs")
    parser.add_argument("--user-buckets", default="users-primary", help="Comma separated authorized user owner buckets")
    parser.add_argument("--mount-root", help="Path of this node's own directory inside its container")
    parser.add_argument("--policy-partitions", type=int, default=16,
                        help="Memory policy owner partition count: power of two (1..4096); default 16")
    parser.add_argument("--policy-endpoint", help="Configured shard alias used for the policy control RPC")
    args = parser.parse_args()
    if len(args.voters) != 3:
        parser.error("exactly three placement voters are required")
    nodes = args.hosts + args.callers + args.voters
    shards = args.shards.split(",")
    user_buckets = args.user_buckets.split(",")
    if not 1 <= len(user_buckets) <= 256 or len(set(user_buckets)) != len(user_buckets) or any(
            not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", bucket) for bucket in user_buckets):
        parser.error("user buckets must be unique bounded owner IDs")
    if (not 1 <= len(nodes) <= 64 or len({n[0] for n in nodes}) != len(nodes)
            or len({(n[1], n[2]) for n in nodes}) != len(nodes)
            or not 1 <= len(shards) <= 256 or len(set(shards)) != len(shards)
            or any(not s or s != s.strip() for s in shards)):
        parser.error("node identities/endpoints and shard IDs must be unique, nonempty and bounded")
    if not set(args.worker_caller).issubset({n[0] for n in args.callers}):
        parser.error("worker-caller must name an explicitly configured caller")
    if (not set(args.exclusion_supervisor).issubset({n[0] for n in args.callers})
            or set(args.exclusion_supervisor).intersection(args.worker_caller)):
        parser.error("exclusion-supervisor must be a dedicated caller, not a worker")
    count = args.policy_partitions
    if count < 1 or count > 4096 or count & (count - 1) or len(args.hosts) > count:
        parser.error("policy partitions must be a power of two (1..4096), with at least one per host")
    if args.policy_endpoint is not None and args.policy_endpoint not in shards:
        parser.error("policy endpoint must be a configured shard alias")
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
    voter_names = {item[0] for item in args.voters}
    voter_ids = {name: str(uuid.uuid4()) for name in voter_names}
    occupied = {(address, port) for _, address, port in nodes}
    client_ports = {}
    for name, address, port in args.hosts + args.callers:
        candidate = port + 1
        while candidate <= 65535 and (address, candidate) in occupied:
            candidate += 1
        if candidate > 65535:
            parser.error("no free control-client port following this endpoint")
        client_ports[name] = candidate
        occupied.add((address, candidate))
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
        permissions = ["userRoomCalls", "roomCoordination", "realtimePublish", "realtimeReceive"]
        if name in host_names or name in args.worker_caller:
            permissions += ["roomMaintenance", "trustedSafety", "specialAccountAudit"]
        permissions += ["policyMutation"]
        if name in host_names:
            permissions += ["policyRegistration"]
        permissions += ["placementRead"]
        if name in host_names:
            permissions += ["placementWrite"]
        if name in voter_names:
            permissions = ["placementVote", "placementRead", "realtimePublish", "realtimeReceive"]
        if name in args.exclusion_supervisor:
            permissions = ["placementRead", "placementWrite", "placementExclude"]
        services.append(dict(id=name, publicKeyBase64=base64.b64encode(public_der[-32:]).decode(),
                             permissions=permissions, hostIDs=[host_ids[name]] if name in host_names else ([voter_ids[name]] if name in voter_names else []),
                             shardIDs=shards, userBucketIDs=user_buckets, gatewayNodeIDs=[name]))
    peers = [dict(hostID=host_ids[name], serviceID=name, address=address, port=port,
                  shardIDs=shards, maximumRooms=10000) for name, address, port in args.hosts]
    # Only Gateway hosts run realtime discovery/voting. A caller such as Account
    # remains trusted for RPC, but must not create an unreachable quorum vote.
    realtime_peers = [dict(nodeID=name, serviceID=name, address=address, port=port)
                      for name, address, port in sorted(args.hosts)]
    ordered_hosts = sorted(host_names)
    placement = dict(revision=1, partitionCount=args.policy_partitions, owners=[
        dict(hostID=host_ids[name], endpoint=args.policy_endpoint or shards[0],
             partitions=list(range(index, args.policy_partitions, len(ordered_hosts))))
        for index, name in enumerate(ordered_hosts)])
    control_peers = [dict(hostID=voter_ids[name], serviceID=name, address=address, port=port, shardIDs=shards)
                     for name, address, port in args.voters]
    for name, address, port in nodes:
        directory = root / name
        visible = Path(args.mount_root) if args.mount_root else directory
        # Caller configurations retain their required local identity. Gateway
        # hosts share only the Gateway voter roster; callers do not vote there.
        local_realtime_peers = realtime_peers if name in host_names or name in args.exclusion_supervisor else realtime_peers + [
            dict(nodeID=name, serviceID=name, address=address, port=port)]
        document = dict(name="imv2-room-actors", address=address,
            port=port, threadPoolSize=2, serviceID=name, hostID=host_ids.get(name),
            signingKeyPath=str(visible / "signing.key"), certificatePath=str(visible / "tls.pem"),
            privateKeyPath=str(visible / "tls.key"), trustRootPath=str(visible / "ca.pem"),
            services=services, peers=peers, realtimePeers=local_realtime_peers)
        storage_paths = {}
        if name in voter_names:
            (directory / "placement").mkdir(mode=0o700)
            storage_paths = {shard: str(visible / "placement" / (str(index) + ".pb"))
                             for index, shard in enumerate(shards)}
        document["placementControl"] = dict(port=port if name in voter_names else client_ports[name],
            threadPoolSize=1, localVoterID=voter_ids.get(name), storagePaths=storage_paths, voters=control_peers)
        if name not in voter_names and name not in args.exclusion_supervisor:
            document["policyPlacement"] = placement
        write_json(directory / "configuration.json", document)
    write_json(root / "topology.json", dict(hosts=args.hosts, callers=args.callers, voters=args.voters, shards=shards, hostIDs=host_ids, voterIDs=voter_ids, policyPlacement=placement, exclusionSupervisors=args.exclusion_supervisor))
    print(f"Created {len(nodes)} local/test node configurations in {root}")
    print("Mount only each process's own node directory; keep the CA private key outside application containers.")


if __name__ == "__main__":
    main()
