#!/usr/bin/env python3
"""Build and smoke-test real Account/Gateway/Operator in disposable containers.

Uses the existing local-stack configuration and black-box protocol checks with
private secrets, random loopback ports, and project-scoped volumes. It never
starts, recreates, or prunes the developer's local stack.
"""

from __future__ import annotations

import argparse
import base64
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-dir", required=True, type=Path,
                        help="Exclusive Linux SwiftPM scratch outside the checkout")
    parser.add_argument("--run-root", type=Path,
                        default=Path.home() / ".codex/virtual-actor-builds/application")
    parser.add_argument("--context", default=os.environ.get("DOCKER_CONTEXT", "default"))
    args = parser.parse_args()
    scratch = args.scratch_dir.expanduser().resolve()
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
              "project": project, "swiftImage": IMAGE, "startedAt": time.time(), "passed": False}

    def execute(command: list[str], log: str, *, timeout: int = 180,
                input_text: str | None = None) -> None:
        with (run / log).open("a") as output:
            subprocess.run(command, cwd=ROOT, env=environment, input=input_text, text=True,
                           stdout=output, stderr=subprocess.STDOUT, timeout=timeout, check=True)

    try:
        # Rebuild from this exact read-only checkout. Never trust a stale binary
        # merely because it exists in a shared compiler cache.
        execute(docker + ["run", "--name", builder, "--init", "--cpus", "2", "--memory", "6g",
                          "--mount", f"type=bind,source={ROOT},target=/workspace,readonly",
                          "--mount", f"type=bind,source={scratch},target=/build", IMAGE,
                          "bash", "-c", 'set -eu; for product in "$@"; do timeout --signal=TERM --kill-after=20s 7200s swift build --disable-automatic-resolution --jobs 2 -c release --package-path /workspace/IMV2Server --scratch-path /build --product "$product"; done',
                          "actor-app-build", *PRODUCTS], "build.log", timeout=28_900)
        runtime = private / "runtime"
        runtime.mkdir()
        result["products"] = {}
        for product in PRODUCTS:
            source = scratch / "release" / product
            target = runtime / product
            shutil.copy2(source, target)
            result["products"][product] = hashlib.sha256(target.read_bytes()).hexdigest()
        result["packageResolvedSHA256"] = hashlib.sha256((ROOT / "IMV2Server/Package.resolved").read_bytes()).hexdigest()

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
        execute([sys.executable, str(ROOT / "IMV2/scripts/prepare_v2_room_actor_configuration.py"),
                 "--output-dir", str(private / "local-room-actors"), "--host", "gateway=gateway:7337",
                 "--caller", "account=account:7338", "--shards", "rooms-primary",
                 "--mount-root", "/run/im-v2-room-actor"], "configuration.log")
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
        execute(compose + ["up", "-d", "--wait", "--wait-timeout", "120", "gateway"], "startup.log")
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
        execute([sys.executable, str(ROOT / "IMV2/scripts/verify_v2_virtual_actor_http_paths.py"),
                 "--account-url", environment["V2_LOCAL_HTTP_BASE_URL"],
                 "--ca", str(ca), "--compose-file", str(compose_file), "--env-file", str(env_file),
                 "--project", project, "--context", args.context,
                 "--recovery-directory", environment["V2_LOCAL_REGISTRATION_RECOVERY_DIRECTORY"],
                 "--gateway-probe-path", "/workspace/IMV2Server/.build/release/IMV2LocalGatewayProbe"],
                "actor-http-smoke.log", timeout=300)
        result["passed"] = True
    except (subprocess.SubprocessError, OSError, RuntimeError) as error:
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
