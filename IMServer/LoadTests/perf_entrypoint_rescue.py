#!/usr/bin/env python3
from __future__ import annotations

import json
import shlex
from pathlib import Path


def entrypoint_rescue_failed(entrypoint_rescue: dict[str, str]) -> bool:
    return (
        str(entrypoint_rescue.get("entrypointFailed") or "").lower() == "true"
        or str(entrypoint_rescue.get("status") or "").upper() == "BLOCKED"
        or str(entrypoint_rescue.get("rescuePlanAction") or "") == "cloud_console_rescue_required"
    )


def entrypoint_rescue_next_command(summary_path: str | None, entrypoint_rescue: dict[str, str]) -> str:
    if not entrypoint_rescue_failed(entrypoint_rescue) or not summary_path:
        return ""
    try:
        artifact_dir = Path(summary_path).resolve().parent
    except Exception:
        return ""
    action = str(entrypoint_rescue.get("rescuePlanAction") or "")
    if action in {"disconnect_local_tun_or_use_clean_network", "disable_local_proxy_or_test_from_clean_network"}:
        readiness_json = artifact_dir / "current-production-readiness.json"
        try:
            readiness = json.loads(readiness_json.read_text(encoding="utf-8"))
        except Exception:
            readiness = {}
        target = readiness.get("target") if isinstance(readiness.get("target"), dict) else {}
        base_url = str(target.get("baseURL") or "")
        tcp_host = str(target.get("tcpHost") or "")
        tcp_port = str(target.get("tcpPort") or "")
        script_dir = Path(__file__).resolve().parent
        command = [f"cd {shlex.quote(str(script_dir))}"]
        if base_url:
            command.append(f"BASE_URL={shlex.quote(base_url)}")
        if tcp_host:
            command.append(f"TCP_HOST={shlex.quote(tcp_host)}")
        if tcp_port:
            command.append(f"TCP_PORT={shlex.quote(tcp_port)}")
        command.append("CURRENT_PRODUCTION_FAIL_ON_LOCAL_NETWORK=true")
        command.append("./run_current_production_readiness.sh")
        return " && ".join([command[0], " ".join(command[1:])])
    verify_script = artifact_dir / "verify-artifact.sh"
    rescue_plan = artifact_dir / "entrypoint-rescue-plan.md"
    if verify_script.exists() and rescue_plan.exists():
        return f"cd {shlex.quote(str(artifact_dir))} && ./verify-artifact.sh && cat ./entrypoint-rescue-plan.md"
    post_rescue = artifact_dir / "post-rescue-verify.sh"
    if post_rescue.exists():
        return f"cd {shlex.quote(str(artifact_dir))} && ./post-rescue-verify.sh"
    return ""
