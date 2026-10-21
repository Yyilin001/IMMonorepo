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


def logical_ids(names, role, seed=None):
    """Freeze benchmark placement without reusing keys or process incarnations."""
    return {name: str(uuid.uuid5(seed, role + ':' + name) if seed else uuid.uuid4())
            for name in sorted(names)}


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
    parser.add_argument("--maximum-rooms-per-host", type=int, default=10000,
                        help="Advertised and actual active room capacity of each Host")
    parser.add_argument("--identity-seed", type=uuid.UUID,
                        help="Test-only namespace for repeatable logical Host/voter IDs; keys stay fresh")
    parser.add_argument("--placement-cluster-id", type=uuid.UUID,
                        help="Persistent deployment identity; reuse when adding hosts to an existing deployment")
    parser.add_argument("--extend-from", type=Path, help="Existing private deployment to extend without rotating identities or CA")
    parser.add_argument("--trust-admission-authority", help="Dedicated service ID for signing new-node trust grants; private key stays in deployment tools")
    parser.add_argument("--service-membership-shard", help="Existing placement shard holding the committed realtime member roster")
    parser.add_argument("--membership-controller", action="append", default=[], help="Dedicated caller authorized to commit service membership")
    parser.add_argument("--placement-controller", action="append", default=[], help="Dedicated caller authorized to drain and transfer room partitions")
    args = parser.parse_args()
    previous = None
    previous_docs = {}
    previous_root = args.extend_from.resolve() if args.extend_from else None
    if previous_root:
        previous = json.loads((previous_root / "topology.json").read_text())
        for item in previous["hosts"] + previous["callers"] + previous["voters"]:
            previous_docs[item[0]] = json.loads((previous_root / item[0] / "configuration.json").read_text())
        existing_id = uuid.UUID(previous["placementClusterID"])
        if args.placement_cluster_id and args.placement_cluster_id != existing_id:
            parser.error("extension must retain the existing placement cluster ID")
        args.placement_cluster_id = existing_id
    cluster_id = args.placement_cluster_id or (uuid.uuid5(args.identity_seed, 'placement-cluster')
                                               if args.identity_seed else uuid.uuid4())
    if not 128 <= args.maximum_rooms_per_host <= 65536:
        parser.error("maximum rooms per host must be within 128..65536")
    if len(args.voters) != 3:
        parser.error("exactly three placement voters are required")
    nodes = args.hosts + args.callers + args.voters
    authority_id = args.trust_admission_authority
    if previous:
        existing_authorities = {doc.get("trustAdmissionAuthorityServiceID") for doc in previous_docs.values()}
        if len(existing_authorities) != 1:
            parser.error("existing deployment configurations disagree on admission authority")
        existing_authority = existing_authorities.pop()
        if authority_id is not None and authority_id != existing_authority:
            parser.error("extension cannot replace or introduce an admission authority")
        authority_id = existing_authority
    if authority_id is not None and (not re.fullmatch(r"[a-z][a-z0-9_-]{0,62}", authority_id)
                                     or authority_id in {item[0] for item in nodes}):
        parser.error("admission authority must be a separate service identity")
    shards = args.shards.split(",")
    membership_shard = args.service_membership_shard
    if previous:
        previous_shards = {doc.get("serviceMembershipShard") for doc in previous_docs.values()}
        if len(previous_shards) != 1:
            parser.error("existing deployment configurations disagree on membership control shard")
        previous_shard = previous_shards.pop()
        if membership_shard is not None and membership_shard != previous_shard:
            parser.error("extension cannot change the authoritative membership control shard")
        membership_shard = previous_shard
    if membership_shard is not None and membership_shard not in shards:
        parser.error("membership control shard must be a configured placement shard")
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
    if (not set(args.membership_controller).issubset({n[0] for n in args.callers})
            or set(args.membership_controller).intersection(args.worker_caller + args.exclusion_supervisor)
            or (args.membership_controller and membership_shard is None)):
        parser.error("membership-controller requires a dedicated caller and membership control shard")
    if (not set(args.placement_controller).issubset({n[0] for n in args.callers})
            or set(args.placement_controller).intersection(args.worker_caller + args.exclusion_supervisor + args.membership_controller)
            or (args.placement_controller and membership_shard is None)):
        parser.error("placement-controller requires a dedicated caller and membership control shard")
    count = args.policy_partitions
    if count < 1 or count > 4096 or count & (count - 1) or len(args.hosts) > count:
        parser.error("policy partitions must be a power of two (1..4096), with at least one per host")
    if args.policy_endpoint is not None and args.policy_endpoint not in shards:
        parser.error("policy endpoint must be a configured shard alias")
    if previous:
        if set(args.placement_controller) != set(previous.get("placementControllers", [])):
            parser.error("extension cannot replace placement controllers")
        if set(args.membership_controller) != set(previous.get("membershipControllers", [])):
            parser.error("extension must retain the configured membership controllers")
        for role, requested in [("hosts", args.hosts), ("callers", args.callers), ("voters", args.voters)]:
            old = {item[0]: tuple(item) for item in previous[role]}
            current = {item[0]: tuple(item) for item in requested}
            if any(current.get(name) != item for name, item in old.items()):
                parser.error("extension cannot remove, change roles or move existing nodes")
        if (shards != previous["shards"] or args.policy_partitions != previous["policyPlacement"]["partitionCount"]
                or set(args.exclusion_supervisor) != set(previous.get("exclusionSupervisors", []))):
            parser.error("extension must retain shards, policy partition count and exclusion authority")
        reference_services = next(iter(previous_docs.values()))["services"]
        if any(doc["services"] != reference_services or doc["placementControl"]["clusterID"] != str(cluster_id)
               for doc in previous_docs.values()):
            parser.error("existing deployment configurations disagree on trust or cluster identity")
        if any(service.get("userBucketIDs", []) != user_buckets for service in reference_services
               if service["id"] in previous_docs):
            parser.error("extension must retain user buckets")
        if args.policy_endpoint is not None and any(
                owner["endpoint"] != args.policy_endpoint for owner in previous["policyPlacement"]["owners"]):
            parser.error("extension cannot change existing policy endpoints")
        old_control = {(doc["address"], doc["placementControl"]["port"]) for doc in previous_docs.values()}
        if any((address, port) in old_control for name, address, port in nodes if name not in previous_docs):
            parser.error("new endpoint collides with an existing control endpoint")
    # An explicit new output directory prevents accidental rotation of a live
    # host's signing identity or modification of an existing private CA.
    root = args.output_dir.resolve()
    if root.exists():
        parser.error("output directory already exists; keep existing identities or choose a new directory")
    os.umask(0o077)
    root.mkdir(parents=True, mode=0o700)
    ca = root / "ca"
    ca.mkdir(mode=0o700)
    if previous_root:
        for filename in ["key.pem", "cert.pem"]:
            shutil.copyfile(previous_root / "ca" / filename, ca / filename)
    else:
        command("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                "-nodes", "-keyout", str(ca / "key.pem"), "-out", str(ca / "cert.pem"),
                "-days", "365", "-subj", "/CN=IM V2 local Room Actor CA",
                "-addext", "basicConstraints=critical,CA:TRUE",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    host_names = {item[0] for item in args.hosts}
    host_ids = logical_ids(host_names, 'host', args.identity_seed)
    voter_names = {item[0] for item in args.voters}
    voter_ids = logical_ids(voter_names, 'voter', args.identity_seed)
    if previous:
        host_ids.update(previous["hostIDs"]); voter_ids.update(previous["voterIDs"])
    occupied = {(address, port) for _, address, port in nodes}
    if previous:
        occupied.update((doc["address"], doc["placementControl"]["port"]) for doc in previous_docs.values())
    client_ports = {}
    for name, address, port in args.hosts + args.callers:
        if name in previous_docs:
            client_ports[name] = previous_docs[name]["placementControl"]["port"]
            continue
        candidate = port + 1
        while candidate <= 65535 and (address, candidate) in occupied:
            candidate += 1
        if candidate > 65535:
            parser.error("no free control-client port following this endpoint")
        client_ports[name] = candidate
        occupied.add((address, candidate))
    services = list(reference_services) if previous else []
    # Never put the authority's private key inside a node directory.
    authority_directory = root / ".trust-admission"
    if authority_id and not previous:
        authority_directory.mkdir(mode=0o700)
        private_file = authority_directory / "signing.pem"
        command("openssl", "genpkey", "-algorithm", "ED25519", "-out", str(private_file))
        public_der = command("openssl", "pkey", "-in", str(private_file), "-pubout", "-outform", "DER")
        services.append(dict(id=authority_id, publicKeyBase64=base64.b64encode(public_der[-32:]).decode(),
                             permissions=[], hostIDs=[], shardIDs=[], userBucketIDs=[], gatewayNodeIDs=[]))
    elif authority_id and (previous_root / ".trust-admission/signing.pem").is_file():
        authority_directory.mkdir(mode=0o700)
        private_file = authority_directory / "signing.pem"
        shutil.copyfile(previous_root / ".trust-admission/signing.pem", private_file)
        public_der = command("openssl", "pkey", "-in", str(private_file), "-pubout", "-outform", "DER")
        authorities = [service for service in services if service["id"] == authority_id]
        if (len(authorities) != 1 or authorities[0]["publicKeyBase64"] != base64.b64encode(public_der[-32:]).decode()
                or any(authorities[0].get(field) for field in ["permissions", "hostIDs", "gatewayNodeIDs", "shardIDs", "userBucketIDs"])):
            raise RuntimeError("existing admission authority key or permissions are inconsistent")
    for name, address, _ in nodes:
        directory = root / name
        directory.mkdir(mode=0o700)
        if name in previous_docs:
            old_services = {service["id"]: service for service in previous_docs[name]["services"]}
            service = old_services[name]
            for filename in ["signing.key", "tls.key", "tls.pem", "ca.pem"]:
                shutil.copyfile(previous_root / name / filename, directory / filename)
            key = (directory / "signing.key").read_bytes()
            if len(key) != 32 or (directory / "ca.pem").read_bytes() != (ca / "cert.pem").read_bytes():
                raise RuntimeError("existing identity assets are inconsistent")
            # Reconstruct the public key without retaining a second private key file.
            der = directory / "signing-verify.der"
            der.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + key)
            try:
                public_der = command("openssl", "pkey", "-inform", "DER", "-in", str(der), "-pubout", "-outform", "DER")
            finally:
                der.unlink()
            if base64.b64encode(public_der[-32:]).decode() != service["publicKeyBase64"]:
                raise RuntimeError("existing signing key does not match trusted identity")
            command("openssl", "verify", "-CAfile", str(ca / "cert.pem"), str(directory / "tls.pem"))
            if command("openssl", "x509", "-in", str(directory / "tls.pem"), "-pubkey", "-noout") != command(
                    "openssl", "pkey", "-in", str(directory / "tls.key"), "-pubout"):
                raise RuntimeError("existing TLS key does not match certificate")
            continue
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
                "-CA", str(ca / "cert.pem"), "-CAkey", str(ca / "key.pem"), "-set_serial", "0x" + uuid.uuid4().hex,
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
        if name in args.membership_controller:
            permissions = ["placementRead", "placementWrite", "placementMembership"]
        if name in args.placement_controller:
            permissions = ["placementRead", "placementWrite", "roomCoordination"]
        services.append(dict(id=name, publicKeyBase64=base64.b64encode(public_der[-32:]).decode(),
                             permissions=permissions, hostIDs=[host_ids[name]] if name in host_names else ([voter_ids[name]] if name in voter_names else []),
                             shardIDs=shards, userBucketIDs=user_buckets, gatewayNodeIDs=[] if name in args.membership_controller + args.placement_controller else [name]))
    peers = [dict(hostID=host_ids[name], serviceID=name, address=address, port=port,
                  shardIDs=shards, maximumRooms=args.maximum_rooms_per_host) for name, address, port in args.hosts]
    if previous:
        old_peers = {peer["serviceID"]: peer for peer in next(iter(previous_docs.values()))["peers"]}
        peers = [old_peers.get(peer["serviceID"], peer) for peer in peers]
    # Only Gateway hosts run realtime discovery/voting. A caller such as Account
    # remains trusted for RPC, but must not create an unreachable quorum vote.
    realtime_peers = [dict(nodeID=name, serviceID=name, address=address, port=port)
                      for name, address, port in sorted(args.hosts)]
    ordered_hosts = sorted(host_names)
    placement = dict(revision=1, partitionCount=args.policy_partitions, owners=[
        dict(hostID=host_ids[name], endpoint=args.policy_endpoint or shards[0],
             partitions=list(range(index, args.policy_partitions, len(ordered_hosts))))
        for index, name in enumerate(ordered_hosts)])
    if previous:
        placement = previous["policyPlacement"]
    control_peers = [dict(hostID=voter_ids[name], serviceID=name, address=address, port=port, shardIDs=shards)
                     for name, address, port in args.voters]
    for name, address, port in nodes:
        directory = root / name
        visible = Path(args.mount_root) if args.mount_root else directory
        # Caller configurations retain their required local identity. Gateway
        # hosts share only the Gateway voter roster; callers do not vote there.
        local_realtime_peers = realtime_peers if name in host_names or name in args.exclusion_supervisor + args.membership_controller + args.placement_controller else realtime_peers + [
            dict(nodeID=name, serviceID=name, address=address, port=port)]
        document = dict(previous_docs.get(name, {}))
        if membership_shard is not None:
            document["serviceMembershipShard"] = membership_shard
        document.update(dict(name="imv2-room-actors", address=address,
            port=port, threadPoolSize=2, serviceID=name, hostID=host_ids.get(name),
            signingKeyPath=str(visible / "signing.key"), certificatePath=str(visible / "tls.pem"),
            privateKeyPath=str(visible / "tls.key"), trustRootPath=str(visible / "ca.pem"),
            services=services, peers=peers, realtimePeers=local_realtime_peers))
        if authority_id:
            document["trustAdmissionAuthorityServiceID"] = authority_id
            # A pinned signer alone does not enable runtime ingestion. New
            # nodes need a real directory and its process-visible path.
            if "trustAdmissionDirectory" not in document:
                (directory / "trust-admissions").mkdir(mode=0o700)
                document["trustAdmissionDirectory"] = str(visible / "trust-admissions")
            elif previous_root and (previous_root / name / "trust-admissions").is_dir():
                # Preserve immutable grants when the generated node directory
                # is installed at the same container mount point on restart.
                source = previous_root / name / "trust-admissions"
                if source.is_symlink():
                    raise RuntimeError("admission directory cannot be a symbolic link")
                destination = directory / "trust-admissions"
                destination.mkdir(mode=0o700)
                files = list(source.glob("*.pb"))
                if len(files) > 256:
                    raise RuntimeError("too many persisted admission packets")
                total = 0
                for packet in files:
                    if packet.is_symlink() or not packet.is_file() or not 0 < packet.stat().st_size <= 524288:
                        raise RuntimeError("invalid persisted admission packet")
                    total += packet.stat().st_size
                    if total > 16 * 1024 * 1024:
                        raise RuntimeError("persisted admission packets exceed size limit")
                    shutil.copyfile(packet, destination / packet.name)
        storage_paths = {}
        if name in voter_names:
            if name in previous_docs:
                storage_paths = previous_docs[name]["placementControl"]["storagePaths"]
            else:
                (directory / "placement").mkdir(mode=0o700)
                storage_paths = {shard: str(visible / "placement" / (str(index) + ".pb"))
                                 for index, shard in enumerate(shards)}
        document["placementControl"] = dict(clusterID=str(cluster_id), port=port if name in voter_names else client_ports[name],
            threadPoolSize=1, localVoterID=voter_ids.get(name), storagePaths=storage_paths, voters=control_peers)
        if name not in voter_names and name not in args.exclusion_supervisor + args.membership_controller + args.placement_controller:
            document["policyPlacement"] = placement
        write_json(directory / "configuration.json", document)
    write_json(root / "topology.json", dict(placementClusterID=str(cluster_id), hosts=args.hosts, callers=args.callers, voters=args.voters, shards=shards, hostIDs=host_ids, voterIDs=voter_ids, identitySeed=str(args.identity_seed) if args.identity_seed else None, policyPlacement=placement, exclusionSupervisors=args.exclusion_supervisor, membershipControllers=args.membership_controller, placementControllers=args.placement_controller))
    print(f"Created {len(nodes)} local/test node configurations in {root}")
    print("Mount only each process's own node directory; keep the CA private key outside application containers.")


if __name__ == "__main__":
    main()
