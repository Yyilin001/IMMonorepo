#!/usr/bin/env python3
"""Run one real Gateway send against a disposable main/candidate capacity fixture.

This is a functional canary, not a throughput measurement. It never builds or
modifies a source checkout and never uses the developer's default Compose stack.
"""

from __future__ import annotations

import argparse
import base64
import binascii
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time
import uuid


RUNNER_ROOT = Path(__file__).resolve().parents[2]
IMAGE = "swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6"
POSTGRES_IMAGE = "postgres:16-alpine"
LAYOUTS = ("hot", "same-owner", "mixed", "cold")
HEX64 = re.compile(r"[a-f0-9]{64}\Z")
HEX40 = re.compile(r"[a-f0-9]{40}\Z")


class CanaryFailure(Exception):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require_regular(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise CanaryFailure(f"{label} must be a regular file")


def checked_uuid(raw: str, label: str) -> str:
    try:
        return str(uuid.UUID(raw))
    except ValueError as error:
        raise CanaryFailure(f"invalid {label}") from error


def verify_source(source: Path, expected_sha: str) -> dict[str, str]:
    if not HEX40.fullmatch(expected_sha):
        raise CanaryFailure("source SHA must be a full lowercase git SHA")
    head = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    root = Path(subprocess.check_output(["git", "-C", str(source), "rev-parse", "--show-toplevel"], text=True).strip()).resolve()
    status = subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"], text=True)
    if head != expected_sha or root != source or status.strip():
        raise CanaryFailure("source checkout SHA, root or tracked cleanliness mismatch")
    required = [source / "IMV2/sql/schema.sql", source / "IMV2/docker-compose.local-account.yml",
                source / "IMV2Server/Package.resolved"]
    for path in required:
        require_regular(path, path.name)
    return {
        "sourceSHA": head,
        "schemaSHA256": sha256(required[0]),
        "composeSourceSHA256": sha256(required[1]),
        "packageResolvedSHA256": sha256(required[2]),
    }


def verify_product(release: Path, product: str, expected: str) -> str:
    if not HEX64.fullmatch(expected):
        raise CanaryFailure(f"{product} requires an independently supplied SHA-256")
    path = release / product
    require_regular(path, product)
    with path.open("rb") as stream:
        magic = stream.read(4)
    if not os.access(path, os.X_OK) or magic != b"\x7fELF":
        raise CanaryFailure(f"{product} is not an executable Linux ELF")
    actual = sha256(path)
    if actual != expected:
        raise CanaryFailure(f"{product} binary SHA-256 mismatch")
    return actual


def read_build_result(path: Path) -> dict:
    result = json.loads(path.read_text())
    if (result.get("passed") is not True or result.get("exitCode") != 0
            or result.get("image") != IMAGE or not HEX40.fullmatch(result.get("sourceSHA", ""))
            or not HEX64.fullmatch(result.get("lockfileSHA256", ""))):
        raise CanaryFailure("Linux Release build result is incomplete or uses another image")
    return result


def verify_fixture(fixture: Path, layout: str) -> tuple[dict, set[str], set[str], dict[str, str]]:
    manifest_file = fixture / "manifest.json"
    require_regular(manifest_file, "fixture manifest")
    manifest = json.loads(manifest_file.read_text())
    if manifest.get("schemaVersion") != 1 or layout not in manifest.get("layouts", {}):
        raise CanaryFailure("unsupported fixture manifest or layout")
    fixture_id = checked_uuid(manifest.get("fixtureID", ""), "fixture ID")
    info = manifest["layouts"][layout]
    owners = manifest.get("owners")
    targets = manifest.get("targetsPerConnection")
    users = manifest.get("users")
    if not isinstance(owners, int) or not 1 <= owners <= 8 or not isinstance(targets, int) or not 1 <= targets <= 32 or not isinstance(users, int) or users < targets + 1:
        raise CanaryFailure("fixture has invalid owner/target/user counts")
    shards = info.get("shardIDs")
    if not isinstance(shards, list) or len(shards) != owners or len(set(shards)) != owners:
        raise CanaryFailure("fixture shard list is invalid")
    files = {
        "common.sql": manifest["commonSQLSHA256"],
        "auth-control.sql": manifest["authControlSQLSHA256"],
        f"{layout}/control.sql": info["controlSQLSHA256"],
        f"{layout}/credentials.jsonl": info["credentialFileSHA256"],
    }
    for index in range(owners):
        filename = f"owner-{index:02d}.sql"
        files[f"{layout}/{filename}"] = info["ownerSQLSHA256"][filename]
    for filename, expected in files.items():
        path = fixture / filename
        require_regular(path, filename)
        if not HEX64.fullmatch(expected) or sha256(path) != expected:
            raise CanaryFailure(f"fixture artifact hash mismatch: {filename}")
    key_file = fixture / "access-token-hmac-key.base64"
    require_regular(key_file, "fixture key")
    key = key_file.read_text().strip()
    try:
        if len(base64.b64decode(key, validate=True)) < 32:
            raise ValueError()
    except (ValueError, binascii.Error) as error:
        raise CanaryFailure("fixture HMAC key is invalid") from error
    for private_file in (key_file, fixture / layout / "credentials.jsonl"):
        if private_file.stat().st_mode & 0o077:
            raise CanaryFailure("fixture credential or key is group/world accessible")
    room_ids: set[str] = set()
    user_ids: set[str] = set()
    credentials = (fixture / layout / "credentials.jsonl").read_text().splitlines()
    if len(credentials) != users:
        raise CanaryFailure("fixture credential count mismatch")
    for line in credentials:
        credential = json.loads(line)
        user_ids.add(checked_uuid(credential["userID"], "credential user ID"))
        rooms = credential["targetRoomIDs"]
        if len(rooms) != targets or len(set(rooms)) != targets:
            raise CanaryFailure("fixture targetRoomIDs do not match generator slots")
        room_ids.update(checked_uuid(room, "target room ID") for room in rooms)
    if len(user_ids) != users or len(room_ids) != info["rooms"]:
        raise CanaryFailure("fixture identity/room counts mismatch")
    return manifest, room_ids, user_ids, {"manifestSHA256": sha256(manifest_file), "fixtureID": fixture_id, "tokenKey": key}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-checkout", required=True, type=Path)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--release-dir", required=True, type=Path)
    parser.add_argument("--build-result", required=True, type=Path,
                        help="completed independent Linux Release build result.json")
    parser.add_argument("--loader-products-dir", type=Path,
                        help="corrected Linux Release loader product directory, for both revisions")
    parser.add_argument("--loader-build-result", type=Path,
                        help="independent corrected-loader build result.json")
    parser.add_argument("--legacy-loader-net-admin", action="store_true",
                        help="diagnostic only: run the frozen SOL_SOCKET/SO_DEBUG loader with NET_ADMIN")
    parser.add_argument("--fixture-dir", required=True, type=Path)
    parser.add_argument("--layout", required=True, choices=LAYOUTS)
    parser.add_argument("--docker-context", required=True)
    parser.add_argument("--artifact-dir", required=True, type=Path)
    parser.add_argument("--preflight-only", action="store_true")
    args = parser.parse_args()
    for name in ("source_checkout", "release_dir", "fixture_dir"):
        path = getattr(args, name).expanduser().resolve()
        if not path.is_dir():
            parser.error(f"{name} must be an existing directory")
        setattr(args, name, path)
    args.artifact_dir = args.artifact_dir.expanduser().resolve()
    args.build_result = args.build_result.expanduser().resolve()
    require_regular(args.build_result, "build result")
    if (args.loader_products_dir is None) != (args.loader_build_result is None):
        parser.error("loader-products-dir and loader-build-result must be provided together")
    if args.loader_products_dir is not None:
        if args.legacy_loader_net_admin:
            parser.error("legacy NET_ADMIN is only for the frozen checkout's own loader")
        args.loader_products_dir = args.loader_products_dir.expanduser().resolve()
        args.loader_build_result = args.loader_build_result.expanduser().resolve()
        if not args.loader_products_dir.is_dir() or args.loader_products_dir.is_relative_to(args.source_checkout):
            parser.error("loader-products-dir must be an independent directory outside source checkout")
        require_regular(args.loader_build_result, "loader build result")
    else:
        args.loader_products_dir = args.release_dir
        args.loader_build_result = args.build_result
    if args.artifact_dir.exists() or args.artifact_dir.is_relative_to(args.source_checkout):
        parser.error("artifact-dir must be new and outside source checkout")
    if args.release_dir.is_relative_to(args.source_checkout):
        parser.error("release-dir must be an independently built directory outside source checkout")
    if not args.docker_context or args.docker_context == "default":
        parser.error("an explicit non-default Docker context is required")
    return args


def write_private(path: Path, contents: str) -> None:
    with path.open("x", encoding="utf-8") as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(contents)


def make_tls(private: Path, execute: object) -> Path:
    tls = private / "tls"
    tls.mkdir(mode=0o700)
    execute(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "2",
             "-keyout", str(tls / "ca.key"), "-out", str(tls / "ca.pem"),
             "-subj", "/CN=VA capacity canary CA", "-addext", "basicConstraints=critical,CA:TRUE"], "tls.log", 30)
    execute(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
             "-keyout", str(tls / "gateway.key"), "-out", str(tls / "gateway.csr"),
             "-subj", "/CN=localhost"], "tls.log", 30)
    write_private(tls / "gateway.ext", "subjectAltName=DNS:localhost\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n")
    execute(["openssl", "x509", "-req", "-in", str(tls / "gateway.csr"),
             "-CA", str(tls / "ca.pem"), "-CAkey", str(tls / "ca.key"), "-CAcreateserial",
             "-days", "2", "-sha256", "-extfile", str(tls / "gateway.ext"),
             "-out", str(tls / "gateway.pem")], "tls.log", 30)
    for key in ("ca.key", "gateway.key"):
        (tls / key).chmod(0o600)
    return tls


def main() -> int:
    args = parse_args()
    phase = "preflight"
    source = verify_source(args.source_checkout, args.source_sha)
    build_result = read_build_result(args.build_result)
    if (build_result["sourceSHA"] != args.source_sha
            or build_result["lockfileSHA256"] != source["packageResolvedSHA256"]):
        raise CanaryFailure("Linux Release build result does not match source/lockfile/image")
    loader_build_result = read_build_result(args.loader_build_result)
    products = {
        "IMV2ServerApp": verify_product(args.release_dir, "IMV2ServerApp",
                                         build_result["products"]["IMV2ServerApp"]),
        "IMV2GatewayLoadGenerator": verify_product(args.loader_products_dir,
            "IMV2GatewayLoadGenerator", loader_build_result["products"]["IMV2GatewayLoadGenerator"]),
    }
    manifest, rooms, users, fixture_info = verify_fixture(args.fixture_dir, args.layout)
    scenario = RUNNER_ROOT / "IMV2/scripts/virtual-actor-fixtures/send-one-canary.json"
    require_regular(scenario, "single-send scenario")
    if args.preflight_only:
        print("VA_CAPACITY_CANARY_PREFLIGHT_OK source=" + args.source_sha + " layout=" + args.layout)
        return 0
    old_umask = os.umask(0o077)
    args.artifact_dir.mkdir(mode=0o700, parents=False)
    os.umask(old_umask)
    run = args.artifact_dir
    private = run / "private"
    private.mkdir(mode=0o700)
    project = "imv2-va-cap-" + uuid.uuid4().hex[:16]
    docker = ["docker", "--context", args.docker_context]
    environment = {key: value for key, value in os.environ.items() if not key.startswith("IM_V2_")}
    environment["DOCKER_CONTEXT"] = args.docker_context
    env_file = private / ".env.local"
    compose_file = private / "compose.json"
    compose = docker + ["compose", "--project-name", project, "--env-file", str(env_file), "--file", str(compose_file)]
    result: dict[str, object] = {
        "passed": False, "project": project, "layout": args.layout, "source": source,
        "productSHA256": products, "buildResultSHA256": sha256(args.build_result),
        "loaderBuildResultSHA256": sha256(args.loader_build_result),
        "loaderSourceSHA": loader_build_result["sourceSHA"],
        "loaderLockfileSHA256": loader_build_result["lockfileSHA256"],
        "fixtureManifestSHA256": fixture_info["manifestSHA256"],
        "fixtureID": fixture_info["fixtureID"],
        "credentialMappingSHA256": manifest["layouts"][args.layout]["credentialMappingSHA256"],
        "ownerRoomCounts": manifest["layouts"][args.layout]["ownerRoomCounts"],
        "ownerMembershipCounts": manifest["layouts"][args.layout]["ownerMembershipCounts"],
        "roomCount": manifest["layouts"][args.layout]["rooms"],
        "scenarioSHA256": sha256(scenario), "swiftImage": IMAGE, "postgresImage": POSTGRES_IMAGE,
        "legacyLoaderNETADMIN": args.legacy_loader_net_admin,
        "startedAt": time.time(),
    }
    started = False

    def execute(command: list[str], log: str, timeout: int = 180, input_text: str | None = None,
                record_stdout: bool = True) -> str:
        with (run / log).open("a", encoding="utf-8") as output:
            completed = subprocess.run(command, cwd=args.source_checkout, env=environment,
                                       text=True, input=input_text, stdout=subprocess.PIPE,
                                       stderr=output, timeout=timeout, check=True)
            if record_stdout:
                output.write(completed.stdout)
        return completed.stdout

    def psql(service: str, database: str, sql: str, *, log: str = "database.log") -> str:
        return execute(compose + ["exec", "-T", service, "psql", "-X", "-At", "-v", "ON_ERROR_STOP=1",
                                  "-U", "im_v2", "-d", database], log, 180, sql, False)

    try:
        phase = "image inspection"
        result["swiftImageID"] = execute(docker + ["image", "inspect", IMAGE, "--format", "{{.Id}}"], "image.log", 30).strip()
        result["postgresImageID"] = execute(docker + ["image", "inspect", POSTGRES_IMAGE, "--format", "{{.Id}}"], "image.log", 30).strip()
        phase = "private configuration"
        runtime = private / "products"
        runtime.mkdir(mode=0o700)
        for product in products:
            source_directory = (args.release_dir if product == "IMV2ServerApp"
                                else args.loader_products_dir)
            shutil.copy2(source_directory / product, runtime / product)
            if sha256(runtime / product) != products[product]:
                raise CanaryFailure("copied product hash changed")
        shutil.copytree(args.source_checkout / "IMV2/sql", private / "sql")
        shutil.copytree(args.source_checkout / "IMV2/local", private / "local")
        shutil.copy2(scenario, private / "send-one-canary.json")
        password = secrets.token_urlsafe(24)
        secret_names = ["CREDENTIAL_REPLAY_ENVELOPE_KEY", "PUSH_ENDPOINT_ENVELOPE_KEY",
                        "ACCOUNT_EDGE_AUTHORIZATION_SECRET", "ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY",
                        "ACCOUNT_ASSERTION_HMAC_KEY", "GROUP_INVITE_TOKEN_HMAC_KEY",
                        "LOCAL_MEDIA_SIGNING_KEY", "OPERATOR_REPLAY_BEARER_TOKEN",
                        "OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN"]
        write_private(env_file, "IM_V2_LOCAL_POSTGRES_PASSWORD=" + password + "\n"
                      + "IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64=" + fixture_info["tokenKey"] + "\n"
                      + "".join("IM_V2_" + name + "_BASE64=" + base64.b64encode(secrets.token_bytes(32)).decode() + "\n"
                                for name in secret_names))
        tls = make_tls(private, execute)
        shards = manifest["layouts"][args.layout]["shardIDs"]
        if "IMV2_ROOM_ACTOR_CONFIGURATION_FILE" in (args.source_checkout / "IMV2/docker-compose.local-account.yml").read_text():
            actor_tool = args.source_checkout / "IMV2/scripts/prepare_v2_room_actor_configuration.py"
            require_regular(actor_tool, "actor configuration generator")
            execute([sys.executable, str(actor_tool), "--output-dir", str(private / "local-room-actors"),
                     "--host", "gateway=gateway:7337", "--shards", ",".join(shards),
                     "--mount-root", "/run/im-v2-room-actor"], "actor-configuration.log", 60)
            # Compose normalization also resolves the unused Account mount.
            (private / "local-room-actors/account").mkdir(mode=0o700)
        phase = "compose configuration"
        config_command = docker + ["compose", "--project-directory", str(private), "--env-file", str(env_file),
                                   "--file", str(args.source_checkout / "IMV2/docker-compose.local-account.yml"),
                                   "config", "--format", "json"]
        document = json.loads(execute(config_command, "compose-config.log", 60, record_stdout=False))
        document["name"] = project
        base_pg = document["services"]["postgres"]
        gateway = document["services"]["gateway"]
        owners = manifest["owners"]
        db_names = {"postgres": "imv2_va_control"}
        services = {"postgres": base_pg, "gateway": gateway}
        for index in range(owners):
            service_name = f"owner{index:02d}"
            db_names[service_name] = f"imv2_va_owner{index:02d}"
            owner = deepcopy(base_pg)
            volume_name = f"owner{index:02d}-data"
            owner["volumes"][0]["source"] = volume_name
            document.setdefault("volumes", {})[volume_name] = {"name": project + "-" + volume_name}
            services[service_name] = owner
        for service_name in ["postgres"] + [f"owner{index:02d}" for index in range(owners)]:
            service = services[service_name]
            service["image"] = POSTGRES_IMAGE
            service["environment"]["POSTGRES_DB"] = db_names[service_name]
            service["healthcheck"]["test"] = ["CMD-SHELL", f"pg_isready -U im_v2 -d {db_names[service_name]}"]
        gateway["image"] = IMAGE
        gateway["command"] = ["/run/va-products/IMV2ServerApp"]
        gateway.pop("restart", None)
        gateway["depends_on"] = {name: {"condition": "service_healthy", "required": True}
                                 for name in db_names}
        gateway["ports"] = [{"mode": "ingress", "host_ip": "127.0.0.1", "target": 7443,
                             "published": "0", "protocol": "tcp"}]
        gateway["volumes"] = [mount for mount in gateway.get("volumes", []) if mount["target"] != "/caddy"]
        gateway["volumes"] += [
            {"type": "bind", "source": str(runtime), "target": "/run/va-products", "read_only": True},
            {"type": "bind", "source": str(tls), "target": "/run/va-tls", "read_only": True},
        ]
        control_url = f"postgres://im_v2:{password}@postgres:5432/{db_names['postgres']}"
        gateway_env = gateway["environment"]
        gateway_env.update({
            "IM_V2_DATABASE_URL": control_url,
            "IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64": fixture_info["tokenKey"],
            "IM_V2_TLS_CERTIFICATE_CHAIN_PATH": "/run/va-tls/gateway.pem",
            "IM_V2_TLS_PRIVATE_KEY_PATH": "/run/va-tls/gateway.key",
            "IM_V2_CAPACITY_PROFILE_ID": manifest["capacityProfileID"],
            "IM_V2_MAX_ELIGIBLE_MEMBERS": "100000",
            "IM_V2_MAX_COMMANDS_PER_WINDOW": str(manifest["commandWindowLimit"]),
            "IM_V2_USER_SHARD_BUCKET": manifest["userBucket"],
            "IM_V2_DIRECT_ROOM_SHARD_ID": shards[0],
            "IM_V2_GROUP_ROOM_SHARD_ID": ",".join(shards),
            "IM_V2_USER_SHARD_STORES_JSON": json.dumps([{"bucket": manifest["userBucket"],
                "database_url": control_url, "schema": "im_v2"}], separators=(",", ":")),
            "IM_V2_ROOM_SHARD_STORES_JSON": json.dumps([{"shard_id": shard,
                "database_url": f"postgres://im_v2:{password}@owner{index:02d}:5432/{db_names[f'owner{index:02d}']}",
                "schema": "im_v2"} for index, shard in enumerate(shards)], separators=(",", ":")),
        })
        connections = min(manifest["users"], max(4, manifest["targetsPerConnection"] + 1))
        services["loader"] = {
            "image": IMAGE,
            "command": ["/run/va-products/IMV2GatewayLoadGenerator", "--host", "gateway", "--port", "7443",
                        "--server-name", "localhost", "--ca-path", "/run/va-tls/ca.pem",
                        "--credentials", f"/run/va-fixture/{args.layout}/credentials.jsonl",
                        "--report", "/run/va-artifacts/load-report.json", "--revision", args.source_sha,
                        "--connections", str(connections), "--targets-per-connection", str(manifest["targetsPerConnection"]),
                        "--peer-topology", "ring", "--ramp-per-second", str(connections),
                        "--ramp-batch-size", str(connections), "--workload-ramp-per-second", str(connections),
                        "--sync-reads", "0", "--room-log-reads", "0", "--max-failure-percent", "0",
                        "--scenario", "/run/va-scenario/send-one-canary.json"],
            "volumes": [
                {"type": "bind", "source": str(runtime), "target": "/run/va-products", "read_only": True},
                {"type": "bind", "source": str(tls), "target": "/run/va-tls", "read_only": True},
                {"type": "bind", "source": str(args.fixture_dir), "target": "/run/va-fixture", "read_only": True},
                {"type": "bind", "source": str(private), "target": "/run/va-scenario", "read_only": True},
                {"type": "bind", "source": str(run), "target": "/run/va-artifacts"},
            ],
        }
        if args.legacy_loader_net_admin:
            # Diagnostic compatibility for the frozen main binary only. Its
            # socketOption(.tcp_nodelay) accidentally sets SO_DEBUG on Linux.
            # Formal canaries use one corrected Release loader for both builds
            # and do not grant NET_ADMIN to any service.
            services["loader"]["cap_add"] = ["NET_ADMIN"]
        document["services"] = services
        for key, volume in document.get("volumes", {}).items():
            volume["name"] = project + "-" + key
        for key, network in document.get("networks", {}).items():
            network["name"] = project + "-" + key
        write_private(compose_file, json.dumps(document, separators=(",", ":")))
        phase = "database startup"
        started = True
        execute(compose + ["up", "-d", "--wait", "--wait-timeout", "120", *db_names], "startup.log", 180)
        for service, database in db_names.items():
            deadline = time.monotonic() + 90
            while True:
                try:
                    if psql(service, database, "SELECT count(*) FROM im_v2.schema_contract;", log="readiness.log").strip() == "1":
                        break
                except subprocess.SubprocessError:
                    pass
                if time.monotonic() > deadline:
                    raise CanaryFailure("canonical schema readiness timed out")
                time.sleep(1)
        phase = "fixture install"
        marker = fixture_info["fixtureID"]
        for service, database in db_names.items():
            psql(service, database, "CREATE TABLE public.imv2_disposable_fixture_guard (fixture_id uuid PRIMARY KEY); "
                 f"INSERT INTO public.imv2_disposable_fixture_guard VALUES ('{marker}');")
            psql(service, database, (args.fixture_dir / "common.sql").read_text())
            if service == "postgres":
                pieces = ["auth-control.sql", f"{args.layout}/control.sql"]
            else:
                pieces = [f"{args.layout}/{service.replace('owner', 'owner-')}.sql"]
            for piece in pieces:
                psql(service, database, (args.fixture_dir / piece).read_text())
        phase = "gateway startup"
        execute(compose + ["up", "-d", "--wait", "--wait-timeout", "120", "gateway"], "startup.log", 180)
        phase = "native one-send canary"
        execute(compose + ["run", "--rm", "--no-deps", "loader"], "loader.log", 180)
        report_file = run / "load-report.json"
        require_regular(report_file, "load report")
        report_file.chmod(0o600)
        report = json.loads(report_file.read_text())
        result["loadReportSHA256"] = sha256(report_file)
        if not (report.get("authenticated") == connections and report.get("messagesSent") == 1
                and report.get("messagesAcknowledged") == 1 and report.get("workloadFailed") == 0
                and report.get("directRoomAttempted") == 0 and report.get("failed") == 0):
            raise CanaryFailure("native loader did not acknowledge exactly one preset-room send")
        phase = "durable SQL effect"
        messages: list[tuple[int, str, str, int]] = []
        for index in range(owners):
            service = f"owner{index:02d}"
            raw = psql(service, db_names[service], "SELECT room_id::text || '|' || sender_user_id::text || '|' || room_sequence::text FROM im_v2.messages ORDER BY room_id, room_sequence;")
            for line in raw.splitlines():
                room, user, sequence = line.split("|")
                messages.append((index, room, user, int(sequence)))
        if len(messages) != 1 or messages[0][1] not in rooms or messages[0][2] not in users or messages[0][3] != 1:
            raise CanaryFailure("owner databases did not persist one authorized room message")
        owner_index, room_id, _, sequence = messages[0]
        actual_shard = psql("postgres", db_names["postgres"],
            f"SELECT room_shard_id FROM im_v2.room_owner_routes WHERE room_id = '{room_id}'::uuid;").strip()
        if actual_shard != shards[owner_index]:
            raise CanaryFailure("message owner does not match authoritative room route")
        result["durableEffect"] = {"roomID": room_id, "ownerIndex": owner_index,
                                   "roomSequence": sequence, "messageRows": 1}
        result["loader"] = {"connections": connections, "messagesSent": 1,
                            "messagesAcknowledged": 1, "directRoomAttempted": 0}
        result["passed"] = True
    except (CanaryFailure, subprocess.SubprocessError, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        result["failureType"] = type(error).__name__
        result["failurePhase"] = phase
    finally:
        if started:
            try:
                execute(compose + ["down", "--volumes", "--remove-orphans", "--timeout", "180"], "cleanup.log", 240)
            except (subprocess.SubprocessError, OSError):
                result["cleanupFailed"] = True
                result["passed"] = False
        if not result.get("cleanupFailed"):
            shutil.rmtree(private)
        result["finishedAt"] = time.time()
        write_private(run / "result.json", json.dumps(result, indent=2, sort_keys=True) + "\n")
        print("VA_CAPACITY_CANARY_" + ("OK" if result["passed"] else "FAILED") + " evidence=" + str(run))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CanaryFailure, subprocess.SubprocessError, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print("VA_CAPACITY_CANARY_PREFLIGHT_FAILED type=" + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
