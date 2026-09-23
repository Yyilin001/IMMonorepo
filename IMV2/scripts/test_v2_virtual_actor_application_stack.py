#!/usr/bin/env python3
"""Build and smoke-test real Account/Gateway/Operator in disposable containers.

Uses the existing local-stack configuration and black-box protocol checks with
private secrets, random loopback ports, and project-scoped volumes. It never
starts, recreates, or prunes the developer's local stack.
"""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
IMAGE = "swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6"
PRODUCTS = ["IMV2AccountServerApp", "IMV2ServerApp", "IMV2OperatorServerApp", "IMV2LocalGatewayProbe"]
PRODUCT_INPUTS = ["IMV2Server/Sources", "IMV2Server/Vendor", "IMV2Server/Package.swift",
                  "IMV2Server/Package.resolved", "IMV2Core", "IMV2Compression", "IMV2/sql"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-dir", type=Path,
                        help="Exclusive Linux SwiftPM scratch outside the checkout (required for building)")
    parser.add_argument("--run-root", type=Path,
                        default=Path.home() / ".codex/virtual-actor-builds/application")
    parser.add_argument("--context", default=os.environ.get("DOCKER_CONTEXT", "default"))
    parser.add_argument("--remote-gateway", action="store_true",
                        help="Run Gateway as a caller of a separate Room Actor Host process")
    parser.add_argument("--products-dir", type=Path,
                        help="Read-only directory containing prebuilt Linux Release products")
    parser.add_argument("--products-metadata", type=Path,
                        help="JSON with sourceSHA, lockfileSHA256 and per-product SHA-256")
    args = parser.parse_args()
    if (args.products_dir is None) != (args.products_metadata is None):
        parser.error("--products-dir and --products-metadata must be provided together")
    if args.products_dir is None and args.scratch_dir is None:
        parser.error("--scratch-dir is required unless verified prebuilt products are provided")
    scratch = args.scratch_dir.expanduser().resolve() if args.scratch_dir is not None else None
    if scratch is not None:
        if scratch.is_relative_to(ROOT):
            parser.error("scratch must be outside the checkout")
        scratch.mkdir(parents=True, exist_ok=True)
    run = args.run_root.expanduser().resolve() / ("run-" + uuid.uuid4().hex)
    run.mkdir(parents=True, mode=0o700)
    os.chmod(run, 0o700)
    project = "imv2-va-app-" + uuid.uuid4().hex[:12]
    builder = project + "-build"
    docker = ["docker", "--context", args.context]
    private = run / "private"
    private.mkdir(mode=0o700)
    env_file = private / ".env.local"
    compose_file = private / "compose.json"
    compose = docker + ["compose", "--project-name", project, "--env-file", str(env_file),
                        "--file", str(compose_file)]
    # Preserve the explicit Docker context while preventing shell exports from
    # overriding this disposable stack's independently generated credentials.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("IM_V2_")}
    environment["DOCKER_CONTEXT"] = args.context
    started = False
    result = {"revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "project": project, "swiftImage": IMAGE, "startedAt": time.time(), "passed": False,
              "mode": "remote-gateway" if args.remote_gateway else "local-gateway-host"}

    def execute(command: list[str], log: str, *, timeout: int = 180,
                input_text: str | None = None) -> None:
        with (run / log).open("a") as output:
            subprocess.run(command, cwd=ROOT, env=environment, input=input_text, text=True,
                           stdout=output, stderr=subprocess.STDOUT, timeout=timeout, check=True)

    try:
        resolved_sha = hashlib.sha256((ROOT / "IMV2Server/Package.resolved").read_bytes()).hexdigest()
        if args.products_dir is None:
            assert scratch is not None
            # Rebuild from this exact read-only checkout. Never trust a stale
            # binary merely because it exists in a shared compiler cache.
            execute(docker + ["run", "--name", builder, "--init", "--cpus", "2", "--memory", "6g",
                              "--mount", f"type=bind,source={ROOT},target=/workspace,readonly",
                              "--mount", f"type=bind,source={scratch},target=/build", IMAGE,
                              "bash", "-c", 'set -eu; for product in "$@"; do timeout --signal=TERM --kill-after=20s 7200s swift build --disable-automatic-resolution --jobs 2 -c release --package-path /workspace/IMV2Server --scratch-path /build --product "$product"; done',
                              "actor-app-build", *PRODUCTS], "build.log", timeout=28_900)
            source_dir = scratch / "release"
            expected_hashes = None
            result["productSource"] = "built-in-this-run"
        else:
            metadata = json.loads(args.products_metadata.expanduser().resolve().read_text())
            binary_revision = metadata.get("sourceSHA", metadata.get("revision"))
            binary_lock = metadata.get("lockfileSHA256", metadata.get("packageResolvedSHA256"))
            if not isinstance(binary_revision, str) or len(binary_revision) != 40 or \
                    binary_lock != resolved_sha or metadata.get("passed") is False or \
                    (metadata.get("image") is not None and metadata["image"] != IMAGE):
                raise RuntimeError("prebuilt products have invalid source, lockfile or image metadata")
            if subprocess.run(["git", "cat-file", "-e", binary_revision + "^{commit}"],
                    cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
                raise RuntimeError("prebuilt product source commit is unavailable locally")
            if subprocess.run(["git", "diff", "--quiet", binary_revision, "HEAD", "--", *PRODUCT_INPUTS],
                    cwd=ROOT).returncode != 0 or subprocess.run(
                        ["git", "diff", "--quiet", "HEAD", "--", *PRODUCT_INPUTS], cwd=ROOT).returncode != 0 or \
                    subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "--",
                        *PRODUCT_INPUTS], cwd=ROOT):
                raise RuntimeError("prebuilt products differ from current business source")
            expected_hashes = metadata.get("products")
            if not isinstance(expected_hashes, dict) or any(
                    not isinstance(expected_hashes.get(name), str) for name in PRODUCTS):
                raise RuntimeError("prebuilt product metadata is incomplete")
            source_dir = args.products_dir.expanduser().resolve()
            result["productSource"] = "verified-prebuilt"
            result["productSourceRevision"] = binary_revision
        runtime = private / "runtime"
        runtime.mkdir()
        result["products"] = {}
        for product in PRODUCTS:
            source = source_dir / product
            if not source.is_file():
                raise RuntimeError("prebuilt product is missing")
            target = runtime / product
            shutil.copy2(source, target)
            digest = hashlib.sha256(target.read_bytes()).hexdigest()
            if expected_hashes is not None and digest != expected_hashes[product]:
                raise RuntimeError("prebuilt product digest mismatch")
            result["products"][product] = digest
        result["packageResolvedSHA256"] = resolved_sha

        names = ["ACCESS_TOKEN_HMAC_KEY", "CREDENTIAL_REPLAY_ENVELOPE_KEY", "PUSH_ENDPOINT_ENVELOPE_KEY",
                 "ACCOUNT_EDGE_AUTHORIZATION_SECRET", "ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY",
                 "ACCOUNT_ASSERTION_HMAC_KEY", "GROUP_INVITE_TOKEN_HMAC_KEY", "LOCAL_MEDIA_SIGNING_KEY",
                 "OPERATOR_REPLAY_BEARER_TOKEN", "OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN"]
        env_file.write_text("IM_V2_LOCAL_POSTGRES_PASSWORD=" + secrets.token_urlsafe(24) + "\n" +
                            "".join("IM_V2_" + key + "_BASE64=" + base64.b64encode(secrets.token_bytes(32)).decode() + "\n"
                                    for key in names))
        os.chmod(env_file, 0o600)
        shutil.copytree(ROOT / "IMV2/sql", private / "sql")
        shutil.copytree(ROOT / "IMV2/local", private / "local")
        actor_configuration = [sys.executable, str(ROOT / "IMV2/scripts/prepare_v2_room_actor_configuration.py"),
            "--output-dir", str(private / "local-room-actors"),
            "--host", "actor-host=actor-host:7337" if args.remote_gateway else "gateway=gateway:7337",
            "--caller", "account=account:7338", "--shards", "rooms-primary",
            "--mount-root", "/run/im-v2-room-actor"]
        if args.remote_gateway:
            actor_configuration.extend(["--caller", "gateway=gateway:7337",
                                        "--worker-caller", "gateway"])
        execute(actor_configuration, "configuration.log")
        # Normalize YAML using Compose itself; the resulting document contains
        # disposable secrets and stays in the private directory until cleanup.
        with compose_file.open("w") as output:
            subprocess.run(docker + ["compose", "--project-directory", str(private), "--env-file", str(env_file),
                                     "--file", str(ROOT / "IMV2/docker-compose.local-account.yml"),
                                     "config", "--format", "json"], cwd=ROOT, env=environment,
                           stdout=output, stderr=subprocess.PIPE, text=True, timeout=60, check=True)
        document = json.loads(compose_file.read_text())
        document["name"] = project
        for name, product in zip(["account", "gateway", "operator"], PRODUCTS):
            service = document["services"][name]
            service["image"] = IMAGE
            service["command"] = ["/workspace/IMV2Server/.build/release/" + product]
            service.setdefault("volumes", []).append({"type": "bind", "source": str(runtime),
                "target": "/workspace/IMV2Server/.build/release", "read_only": True})
            service.pop("restart", None)
            for port in service.get("ports", []):
                port["published"] = "0"
                port["host_ip"] = "127.0.0.1"
        if args.remote_gateway:
            actor_host = copy.deepcopy(document["services"]["gateway"])
            actor_host["ports"] = []
            actor_host["environment"]["IM_V2_GATEWAY_NODE_ID"] = "local-actor-host-1"
            actor_host["volumes"] = [
                {**volume, "source": str(private / "local-room-actors" / "actor-host")}
                if volume.get("target") == "/run/im-v2-room-actor" else volume
                for volume in actor_host["volumes"]]
            document["services"]["actor-host"] = actor_host
        # Compose's normalized volume names otherwise retain the first config's
        # project name. Bind every named resource to this unique test project.
        for key, volume in document.get("volumes", {}).items():
            volume["name"] = project + "-" + key
        for key, network in document.get("networks", {}).items():
            network["name"] = project + "-" + key
        compose_file.write_text(json.dumps(document))
        started = True
        execute(compose + ["up", "-d", "--wait", "--wait-timeout", "90", "postgres"], "startup.log")
        expires = time.monotonic() + 60
        while True:
            contract = subprocess.run(compose + ["exec", "-T", "postgres", "psql", "-v", "ON_ERROR_STOP=1",
                "-U", "im_v2", "-d", "im_v2", "-tA"], env=environment, text=True,
                input=(ROOT / "IMV2/scripts/current_v2_schema_contract.sql").read_text(),
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15)
            if contract.returncode == 0 and contract.stdout.strip() == "t":
                break
            if time.monotonic() >= expires:
                raise RuntimeError("canonical PostgreSQL schema did not become ready")
            time.sleep(1)
        execute(compose + ["exec", "-T", "postgres", "psql", "-v", "ON_ERROR_STOP=1", "-U", "im_v2", "-d", "im_v2"],
                "seed.log", input_text="INSERT INTO im_v2.shard_admission_pools (room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit) VALUES ('rooms-primary','standard','" + str(uuid.uuid4()) + "',1,CURRENT_TIMESTAMP + INTERVAL '24 hours',1000);\n")
        execute(compose + ["up", "-d", "--wait", "--wait-timeout", "120", "account", "caddy", "operator"], "startup.log")
        ca = private / "root.crt"
        expires = time.monotonic() + 60
        while True:
            copied = subprocess.run(compose + ["cp", "caddy:/data/caddy/pki/authorities/local/root.crt", str(ca)],
                                    env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            if copied.returncode == 0 and ca.is_file():
                break
            if time.monotonic() >= expires:
                raise RuntimeError("Caddy did not initialize its private CA")
            time.sleep(1)
        if args.remote_gateway:
            execute(compose + ["up", "-d", "--wait", "--wait-timeout", "120", "actor-host"], "startup.log")
        execute(compose + ["up", "-d", "--wait", "--wait-timeout", "120", "gateway"], "startup.log")
        if args.remote_gateway:
            topology = json.loads((private / "local-room-actors" / "topology.json").read_text())
            expected_host = topology["hostIDs"]["actor-host"]
            gateway_actor_config = json.loads((private / "local-room-actors" / "gateway" /
                "configuration.json").read_text())
            actor_host_config = json.loads((private / "local-room-actors" / "actor-host" /
                "configuration.json").read_text())
            if gateway_actor_config.get("hostID") is not None or actor_host_config.get("hostID") != expected_host:
                raise RuntimeError("Gateway caller and Actor Host identities are not separated")
            containers = {}
            for service in ("actor-host", "gateway"):
                container_id = subprocess.check_output(compose + ["ps", "-q", service],
                    env=environment, text=True, timeout=15).strip()
                if not container_id:
                    raise RuntimeError("remote Actor topology has a missing process")
                inspected = json.loads(subprocess.check_output(docker + ["inspect", container_id],
                    env=environment, text=True, timeout=15))[0]
                if not inspected["State"]["Running"]:
                    raise RuntimeError("remote Actor topology has a stopped process")
                containers[service] = {"containerID": inspected["Id"],
                                       "startedAt": inspected["State"]["StartedAt"]}
            if containers["actor-host"]["containerID"] == containers["gateway"]["containerID"]:
                raise RuntimeError("remote Actor and Gateway share a container")
            result["remoteTopology"] = {"hostID": expected_host, "gatewayHostID": None,
                                        "containers": containers}
        def port(service: str, internal: int) -> str:
            address = subprocess.check_output(compose + ["port", service, str(internal)], env=environment,
                                               text=True, timeout=15).strip()
            if not address.startswith("127.0.0.1:"):
                raise RuntimeError("test port is not restricted to loopback")
            return address.rsplit(":", 1)[1]
        environment.update({"V2_LOCAL_COMPOSE_PROJECT": project, "V2_LOCAL_COMPOSE_FILE": str(compose_file),
                            "V2_LOCAL_ENV_FILE": str(env_file), "V2_LOCAL_CA_PATH": str(ca),
                            "V2_LOCAL_HTTP_BASE_URL": "https://localhost:" + port("account", 8443),
                            "V2_LOCAL_GATEWAY_TLS_ADDRESS": "localhost:" + port("gateway", 7443),
                            "V2_LOCAL_REGISTRATION_RECOVERY_DIRECTORY": str(private / "registration-recovery")})
        execute(["bash", str(ROOT / "IMV2/scripts/verify_v2_local_account_stack.sh")], "smoke.log", timeout=300)
        if args.remote_gateway:
            if "local V2 gateway direct chat: auth, open, accept, recipient room-log delivery verified" not in (
                    run / "smoke.log").read_text():
                raise RuntimeError("Gateway send/read black-box phase did not complete")
            # The black-box smoke has sent a direct message and read it through
            # Gateway TCP. Every persisted message room must still have a live
            # lease held by the separate Actor Host, never this caller.
            query = ("SELECT m.room_id::text, COALESCE(l.host_id, ''), "
                     "COALESCE(l.activation_epoch::text, ''), "
                     "COALESCE((l.expires_at > clock_timestamp())::text, 'false') "
                     "FROM (SELECT DISTINCT room_id FROM im_v2.messages) AS m "
                     "LEFT JOIN im_v2.room_activation_leases AS l ON l.room_id = m.room_id "
                     "ORDER BY m.room_id")
            rows = subprocess.check_output(compose + ["exec", "-T", "postgres", "psql",
                "-v", "ON_ERROR_STOP=1", "-U", "im_v2", "-d", "im_v2", "-tA", "-F", "|", "-c", query],
                env=environment, text=True, timeout=15).strip().splitlines()
            leases = [row.split("|") for row in rows if row]
            # UUID/epoch/liveness are safe to retain even on a failed run;
            # the private database and Compose configuration are discarded.
            result["remoteTopology"]["observedLeaseRows"] = leases
            if not leases or any(len(row) != 4 or row[1].lower() != expected_host.lower() or row[3] != "true"
                                 for row in leases):
                raise RuntimeError("message room lease was not held by the remote Actor Host")
            result["remoteTopology"]["messageRoomLeases"] = [
                {"roomID": room, "hostID": host, "activationEpoch": int(epoch)}
                for room, host, epoch, _ in leases]
        execute([sys.executable, str(ROOT / "IMV2/scripts/verify_v2_virtual_actor_http_paths.py"),
                 "--account-url", environment["V2_LOCAL_HTTP_BASE_URL"],
                 "--ca", str(ca), "--compose-file", str(compose_file), "--env-file", str(env_file),
                 "--project", project, "--context", args.context,
                 "--recovery-directory", environment["V2_LOCAL_REGISTRATION_RECOVERY_DIRECTORY"],
                 "--gateway-probe-path", "/workspace/IMV2Server/.build/release/IMV2LocalGatewayProbe"],
                "actor-http-smoke.log", timeout=300)
        result["passed"] = True
    except (subprocess.SubprocessError, OSError, RuntimeError, ValueError, KeyError, TypeError) as error:
        # Exception messages can include command arguments. Record only class
        # and failing phase logs; never print the normalized Compose document.
        result["failureType"] = type(error).__name__
    finally:
        if started:
            for arguments, log, timeout in [(["logs", "--no-color"], "services.log", 30),
                    (["down", "--volumes", "--remove-orphans", "--timeout", "180"], "cleanup.log", 240)]:
                try:
                    execute(compose + arguments, log, timeout=timeout)
                except (subprocess.SubprocessError, OSError):
                    result["cleanupFailed"] = True
                    result["passed"] = False
        try:
            subprocess.run(docker + ["rm", "--force", builder], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=30)
        except (subprocess.SubprocessError, OSError):
            result["cleanupFailed"] = True
            result["passed"] = False
        if not result.get("cleanupFailed"):
            shutil.rmtree(private)
        result["finishedAt"] = time.time()
        (run / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print("ACTOR_APPLICATION_STACK_" + ("OK" if result["passed"] else "FAILED") + " evidence=" + str(run))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
