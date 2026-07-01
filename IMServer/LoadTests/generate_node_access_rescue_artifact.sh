#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NODE_ACCESS_RESCUE_ARTIFACT_SELF_TEST="${NODE_ACCESS_RESCUE_ARTIFACT_SELF_TEST:-false}"
NODE_ACCESS_RESCUE_ARTIFACT_DIR="${NODE_ACCESS_RESCUE_ARTIFACT_DIR:-${SCRIPT_DIR}/results/current-node-access-rescue}"
NODE_ACCESS_RESCUE_ARTIFACT_PACKAGE="${NODE_ACCESS_RESCUE_ARTIFACT_PACKAGE:-true}"
NODE_ACCESS_RESCUE_ARTIFACT_TARBALL="${NODE_ACCESS_RESCUE_ARTIFACT_TARBALL:-}"
SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_ALLOW_CIDR="${SSH_ALLOW_CIDR:-0.0.0.0/0}"

default_rescue_http_port() {
  local url="${1:-}"
  python3 - "${url}" <<'PY'
from urllib.parse import urlparse
import sys

parsed = urlparse(sys.argv[1])
if parsed.scheme == "http" and parsed.port:
    print(parsed.port)
elif parsed.scheme == "http":
    print("80")
elif parsed.scheme == "https":
    # The rescue script repairs the public HTTP entrypoint, not TLS termination.
    print("80")
else:
    print("8080")
PY
}

CONFIGURED_PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${BASE_URL:-}}"
HTTP_PORT="${HTTP_PORT:-$(default_rescue_http_port "${CONFIGURED_PUBLIC_BASE_URL}")}"
PUBLIC_BASE_URL="${CONFIGURED_PUBLIC_BASE_URL:-http://127.0.0.1:${HTTP_PORT}}"
BASE_URL="${BASE_URL:-${PUBLIC_BASE_URL}}"
TCP_HOST="${TCP_HOST:-}"
TCP_PORT="${TCP_PORT:-9000}"
IM_TCP_PORT="${IM_TCP_PORT:-${TCP_PORT}}"
ACCOUNT_FILE="${ACCOUNT_FILE:-${IM_ACCOUNT_FILE:-}}"
PRODUCT_TEST_PHASES="${PRODUCT_TEST_PHASES:-entrypoint real-world-smoke}"
PRODUCT_TEST_RUN_FULL_PROFILE="${PRODUCT_TEST_RUN_FULL_PROFILE:-false}"
PRODUCT_TEST_STOP_ON_FAILURE="${PRODUCT_TEST_STOP_ON_FAILURE:-true}"
PERF_DRY_RUN="${PERF_DRY_RUN:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

tree_contains_regex() {
  local root="$1"
  local pattern="$2"
  local exclude_name="${3:-}"
  if command -v rg >/dev/null 2>&1; then
    if [[ -n "${exclude_name}" ]]; then
      rg -n --glob "!${exclude_name}" -- "${pattern}" "${root}" >/dev/null
    else
      rg -n -- "${pattern}" "${root}" >/dev/null
    fi
    return $?
  fi

  if [[ -n "${exclude_name}" ]]; then
    grep -R -n -E --exclude="${exclude_name}" -- "${pattern}" "${root}" >/dev/null
  else
    grep -R -n -E -- "${pattern}" "${root}" >/dev/null
  fi
}

tree_contains_fixed() {
  local root="$1"
  local value="$2"
  if command -v rg >/dev/null 2>&1; then
    rg -n -F -- "${value}" "${root}" >/dev/null
    return $?
  fi

  grep -R -n -F -- "${value}" "${root}" >/dev/null
}

resolve_path() {
  python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "$1"
}

host_from_url() {
  python3 - "${BASE_URL}" <<'PY'
from urllib.parse import urlparse
import sys

print(urlparse(sys.argv[1]).hostname or "")
PY
}

derive_public_key() {
  if [[ -n "${SSH_AUTHORIZED_KEY//[[:space:]]/}" ]]; then
    printf '%s\n' "${SSH_AUTHORIZED_KEY}"
    return 0
  fi
  if [[ -z "${SSH_PRIVATE_KEY_PATH}" ]]; then
    printf 'node_access_rescue_artifact result=fail reason=missing_ssh_key_source\n' >&2
    printf 'Set SSH_AUTHORIZED_KEY or SSH_PRIVATE_KEY_PATH.\n' >&2
    return 1
  fi
  if [[ ! -f "${SSH_PRIVATE_KEY_PATH}" ]]; then
    printf 'node_access_rescue_artifact result=fail reason=ssh_private_key_missing path=%s\n' "${SSH_PRIVATE_KEY_PATH}" >&2
    return 1
  fi
  ssh-keygen -y -f "${SSH_PRIVATE_KEY_PATH}"
}

write_summary() {
  local runbook_json="$1"
  local summary_path="$2"
  local external_probe_json="${3:-}"
  local im_tcp_status="${4:-}"
  local ssh_status="${5:-}"
  python3 - "${runbook_json}" "${summary_path}" "${external_probe_json}" "${im_tcp_status}" "${ssh_status}" <<'PY'
import json
import sys
from pathlib import Path

runbook_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
external_probe_path = Path(sys.argv[3]) if sys.argv[3] else None
im_tcp_status = sys.argv[4]
ssh_status = sys.argv[5]
runbook = json.loads(runbook_path.read_text(encoding="utf-8"))
external_probe = {}
if external_probe_path is not None and external_probe_path.exists():
    external_probe = json.loads(external_probe_path.read_text(encoding="utf-8"))
recovery = ((runbook.get("entrypoint") or {}).get("recovery") or {})
signals = external_probe.get("signals") or recovery.get("signals") or {}
tcp_status = external_probe.get("tcpStatus") or signals.get("tcpStatus") or ""
edge_intercept = external_probe.get("edgeIntercept") or signals.get("edgeIntercept") or ""
port_protocols = external_probe.get("portProtocols") or signals.get("portProtocols") or []
diagnosis = external_probe.get("diagnosis") or recovery.get("diagnosis") or ""
entrypoint_failed = bool(external_probe.get("failed")) if external_probe else bool(recovery.get("needed"))
blocker = external_probe.get("blocker") if isinstance(external_probe.get("blocker"), dict) else {}
local_network_warning = str(external_probe.get("localNetworkWarning") or signals.get("localNetworkWarning") or "")
local_proxy_blocked = blocker.get("action") == "disable_local_proxy_or_test_from_clean_network" or bool(local_network_warning)
if entrypoint_failed and local_proxy_blocked:
    rescue_action = "disable_local_proxy_or_test_from_clean_network"
elif entrypoint_failed and ssh_status != "ok":
    rescue_action = "cloud_console_rescue_required"
elif entrypoint_failed:
    rescue_action = "ssh_or_cloud_console_repair_required"
elif im_tcp_status != "open":
    rescue_action = "tcp_entrypoint_repair_required"
else:
    rescue_action = "post_rescue_validation"
lines = [
    f"status={runbook.get('status')}",
    f"productPlanStatus={runbook.get('status')}",
    f"productPlanReason={runbook.get('reason') or '-'}",
    f"rescuePlanAction={rescue_action}",
    f"entrypointDiagnosis={diagnosis or '-'}",
    f"entrypointFailed={external_probe.get('failed') if external_probe else '-'}",
    f"entrypointDetail={external_probe.get('detail') or recovery.get('detail') or '-'}",
    f"nginxHealthStatus={signals.get('nginxHealthStatus') or '-'}",
    f"nginxHealthBodyBytes={signals.get('nginxHealthBodyBytes') if signals.get('nginxHealthBodyBytes') is not None else '-'}",
    f"healthStatus={signals.get('healthStatus') or '-'}",
    f"loginStatus={signals.get('loginStatus') or '-'}",
    f"entrypointTcpStatus={tcp_status or '-'}",
    f"httpPortStatus={tcp_status or '-'}",
    f"sshPortProtocol={signals.get('sshPortProtocol') or '-'}",
    f"httpPortProtocol={signals.get('httpPortProtocol') or '-'}",
    f"imTcpPortProtocol={signals.get('imTcpPortProtocol') or '-'}",
    f"edgeIntercept={edge_intercept or '-'}",
    f"portProtocolCount={len(port_protocols) if isinstance(port_protocols, list) else '-'}",
    f"localNetworkWarning={local_network_warning or '-'}",
    f"localRouteInterface={signals.get('localRouteInterface') or external_probe.get('localRouteInterface') or '-'}",
    f"localRouteGateway={signals.get('localRouteGateway') or external_probe.get('localRouteGateway') or '-'}",
    "localProxyEnvNames=" + ",".join(signals.get("localProxyEnvNames") or external_probe.get("localProxyEnvNames") or []),
    f"imTcpStatus={im_tcp_status or '-'}",
    f"sshStatus={ssh_status or '-'}",
    "commands=" + ",".join(command.get("name", "") for command in recovery.get("commands") or []),
]
summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print("\n".join(lines))
PY
}

write_entrypoint_rescue_plan() {
  local output_json="$1"
  local output_md="$2"
  local external_probe_json="$3"
  local summary_file="$4"
  local rescue_script="$5"
  local post_rescue_script="$6"
  local resume_script="$7"
  local verify_script="$8"
  python3 - \
    "${output_json}" \
    "${output_md}" \
    "${external_probe_json}" \
    "${summary_file}" \
    "${rescue_script}" \
    "${post_rescue_script}" \
    "${resume_script}" \
    "${verify_script}" <<'PY'
import json
import sys
import time
from pathlib import Path

(
    output_json,
    output_md,
    external_probe_json,
    summary_file,
    rescue_script,
    post_rescue_script,
    resume_script,
    verify_script,
) = sys.argv[1:9]

rescue_name = Path(rescue_script).name
post_rescue_name = Path(post_rescue_script).name
resume_name = Path(resume_script).name
verify_name = Path(verify_script).name
external_probe_name = Path(external_probe_json).name
summary_name = Path(summary_file).name
probe = json.loads(Path(external_probe_json).read_text(encoding="utf-8"))
summary = {}
for raw in Path(summary_file).read_text(encoding="utf-8").splitlines():
    if "=" in raw:
        key, value = raw.split("=", 1)
        summary[key] = value

diagnosis = str(probe.get("diagnosis") or "")
failed = bool(probe.get("failed"))
ssh_status = summary.get("sshStatus") or ""
im_tcp_status = summary.get("imTcpStatus") or ""
http_port_status = summary.get("httpPortStatus") or ""
entrypoint_tcp_status = summary.get("entrypointTcpStatus") or http_port_status
edge_intercept = summary.get("edgeIntercept") or ""
port_protocol_count = summary.get("portProtocolCount") or "-"
blocker = probe.get("blocker") if isinstance(probe.get("blocker"), dict) else {}
probe_signals = probe.get("signals") or {}
ssh_port_protocol = str(summary.get("sshPortProtocol") or probe_signals.get("sshPortProtocol") or "")
local_network_warning = str(probe.get("localNetworkWarning") or summary.get("localNetworkWarning") or "")
local_proxy_blocked = blocker.get("action") == "disable_local_proxy_or_test_from_clean_network" or bool(local_network_warning and local_network_warning != "-")

if failed and local_proxy_blocked:
    action = "disable_local_proxy_or_test_from_clean_network"
    reason = "The local route or proxy environment may be intercepting public probes; disable the local TUN/proxy or rerun from a clean network before changing server-side cloud routing."
elif failed and (ssh_port_protocol in {"http_403_intercepted", "http_intercepted"} or edge_intercept == "ssh_port_http_intercepted"):
    action = "cloud_console_rescue_required"
    reason = "SSH port 22 returned an HTTP response instead of an SSH banner; fix cloud routing/security group/WAF/NAT or public IP binding from the provider console before troubleshooting SSH keys or sshd."
elif failed and ssh_status != "ok":
    action = "cloud_console_rescue_required"
    reason = "Public HTTP is unhealthy and SSH is not usable from this machine; use the cloud console rescue script first."
elif failed:
    action = "ssh_or_cloud_console_repair_required"
    reason = "Public HTTP is unhealthy; repair the node entrypoint through SSH if available, otherwise use cloud console rescue."
elif im_tcp_status != "open":
    action = "tcp_entrypoint_repair_required"
    reason = "Public HTTP probe is not the primary blocker, but IM TCP is not open."
else:
    action = "post_rescue_validation"
    reason = "Entrypoint probes do not show a hard exposure failure; run post-rescue validation and product validation."

commands = [
    {
        "name": "verify-artifact",
        "when": "Before copying or executing any rescue command.",
        "command": f"./{verify_name}",
    },
]
if action in {"cloud_console_rescue_required", "ssh_or_cloud_console_repair_required", "tcp_entrypoint_repair_required"}:
    commands.append({
        "name": "cloud-console-rescue",
        "when": "Paste the full file into the cloud provider console or rescue shell.",
        "command": f"cat ./{rescue_name}",
    })
verify_when = "After the cloud-console rescue reports node_access_rescue result=pass."
if action == "disable_local_proxy_or_test_from_clean_network":
    verify_when = "After disabling the local TUN/proxy or moving to a clean network."
commands.extend([
    {
        "name": "post-rescue-verify",
        "when": verify_when,
        "command": f"SSH_PRIVATE_KEY_PATH=${{SSH_PRIVATE_KEY_PATH:-<private-key-path>}} ./{post_rescue_name}",
    },
    {
        "name": "resume-product-validation",
        "when": "After SSH, /nginx-health, /health, and TCP probes pass.",
        "command": f"SSH_PRIVATE_KEY_PATH=${{SSH_PRIVATE_KEY_PATH:-<private-key-path>}} ./{resume_name}",
    },
])

payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "action": action,
    "reason": reason,
    "diagnosis": diagnosis,
    "failed": failed,
    "signals": {
        "tcpStatus": entrypoint_tcp_status,
        "edgeIntercept": edge_intercept,
        "portProtocolCount": port_protocol_count,
        "localNetworkWarning": local_network_warning,
        "httpPortStatus": http_port_status,
        "imTcpStatus": im_tcp_status,
        "sshStatus": ssh_status,
        **(probe.get("signals") or {}),
    },
    "commands": commands,
    "artifacts": {
        "externalProbeJSON": f"./{external_probe_name}",
        "summary": f"./{summary_name}",
        "rescueScript": f"./{rescue_name}",
        "postRescueVerify": f"./{post_rescue_name}",
        "resumeProductValidation": f"./{resume_name}",
        "artifactVerify": f"./{verify_name}",
    },
}
Path(output_json).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")

lines = [
    "# Entrypoint Rescue Plan",
    "",
    f"- action: `{action}`",
    f"- reason: {reason}",
    f"- diagnosis: `{diagnosis or '-'}`",
    f"- failed: `{failed}`",
    f"- entrypointTcpStatus: `{entrypoint_tcp_status or '-'}`",
    f"- httpPortStatus: `{http_port_status or '-'}`",
    f"- sshPortProtocol: `{summary.get('sshPortProtocol') or '-'}`",
    f"- httpPortProtocol: `{summary.get('httpPortProtocol') or '-'}`",
    f"- imTcpPortProtocol: `{summary.get('imTcpPortProtocol') or '-'}`",
    f"- edgeIntercept: `{summary.get('edgeIntercept') or '-'}`",
    f"- portProtocolCount: `{port_protocol_count}`",
    f"- localNetworkWarning: `{local_network_warning or '-'}`",
    f"- localRouteInterface: `{summary.get('localRouteInterface') or '-'}`",
    f"- localRouteGateway: `{summary.get('localRouteGateway') or '-'}`",
    f"- imTcpStatus: `{im_tcp_status or '-'}`",
    f"- sshStatus: `{ssh_status or '-'}`",
    "",
    "## Commands",
    "",
]
for command in commands:
    lines.extend([
        f"### {command['name']}",
        "",
        command["when"],
        "",
        "```bash",
        command["command"],
        "```",
        "",
    ])
Path(output_md).write_text("\n".join(lines), encoding="utf-8")
PY
}

probe_tcp_port() {
  local host="$1"
  local port="$2"
  local protocol
  if [[ -z "${host}" || -z "${port}" ]]; then
    printf 'skipped_missing_target\n'
    return 0
  fi
  protocol="$(probe_port_protocol "${host}" "${port}")"
  case "${protocol}" in
    http_403_intercepted|http_intercepted|ssh_banner)
      printf '%s\n' "${protocol}"
      return 0
      ;;
  esac
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w 5 "${host}" "${port}" >/dev/null 2>&1; then
      printf 'open\n'
    else
      printf 'closed_or_filtered\n'
    fi
  else
    printf 'skipped_nc_missing\n'
  fi
}

probe_port_protocol() {
  local host="$1"
  local port="$2"
  local raw compact
  if [[ -z "${host}" || -z "${port}" ]]; then
    printf 'skipped_missing_target\n'
    return 0
  fi
  if ! command -v nc >/dev/null 2>&1; then
    printf 'skipped_nc_missing\n'
    return 0
  fi
  raw="$(printf '' | nc -w 3 "${host}" "${port}" 2>/dev/null | LC_ALL=C head -c 160 || true)"
  compact="$(printf '%s' "${raw}" | LC_ALL=C tr '\r\n\t ' '____' | sed 's/__*/_/g; s/^_//; s/_$//' | cut -c 1-120)"
  if [[ -z "${compact}" ]]; then
    printf 'no_banner\n'
  elif [[ "${compact}" == SSH-* ]]; then
    printf 'ssh_banner\n'
  elif [[ "${compact}" == HTTP/1.1_403* || "${compact}" == HTTP/1.0_403* || "${compact}" == HTTP/2_403* ]]; then
    printf 'http_403_intercepted\n'
  elif [[ "${compact}" == HTTP/* ]]; then
    printf 'http_intercepted\n'
  else
    printf 'unexpected_banner:%s\n' "${compact}"
  fi
}

probe_ssh_access() {
  local host="$1"
  local protocol
  if [[ -z "${host}" ]]; then
    printf 'skipped_missing_host\n'
    return 0
  fi
  protocol="$(probe_port_protocol "${host}" "${SSH_PORT}")"
  case "${protocol}" in
    http_403_intercepted|http_intercepted|unexpected_banner:*)
      printf '%s\n' "${protocol}"
      return 0
      ;;
  esac
  if [[ -z "${SSH_PRIVATE_KEY_PATH}" || ! -f "${SSH_PRIVATE_KEY_PATH}" ]]; then
    printf 'skipped_missing_private_key\n'
    return 0
  fi
  if ssh -i "${SSH_PRIVATE_KEY_PATH}" \
    -p "${SSH_PORT}" \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=no \
    "root@${host}" 'echo ok' >/dev/null 2>&1; then
    printf 'ok\n'
  else
    printf 'closed_or_failed\n'
  fi
}

write_external_entrypoint_probe() {
  local output_json="$1"
  local output_log="$2"
  local target_host ssh_protocol http_protocol im_tcp_protocol
  BASE_URL="${BASE_URL}" \
  ACCOUNT_FILE="${ACCOUNT_FILE}" \
  PROBE_FAIL_ON_ENTRYPOINT_ERROR=false \
  PROBE_TCP=true \
  PROBE_JSON_OUTPUT="${output_json}" \
    "${SCRIPT_DIR}/http_entrypoint_probe.sh" >"${output_log}" 2>&1 || true
  if [[ ! -f "${output_json}" ]]; then
    python3 - "${output_json}" "${BASE_URL}" <<'PY'
import json
import sys
import time
from pathlib import Path

output_path, base_url = sys.argv[1:3]
payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "baseURL": base_url.rstrip("/"),
    "diagnosis": "probe_not_written",
    "failed": True,
    "detail": "http_entrypoint_probe.sh did not write PROBE_JSON_OUTPUT; inspect external-entrypoint-probe.log.",
    "tcpStatus": "",
    "edgeIntercept": "",
    "additionalProtocolHosts": [],
    "portProtocols": [],
    "summary": {},
    "signals": {},
}
Path(output_path).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
  fi
  target_host="${TCP_HOST:-$(host_from_url)}"
  ssh_protocol="$(probe_port_protocol "${target_host}" "${SSH_PORT}")"
  http_protocol="$(probe_port_protocol "${target_host}" "${HTTP_PORT}")"
  im_tcp_protocol="$(probe_port_protocol "${target_host}" "${TCP_PORT}")"
  {
    printf 'external_port_probe host=%s port=%s label=ssh protocol=%s\n' "${target_host:-<missing>}" "${SSH_PORT}" "${ssh_protocol}"
    printf 'external_port_probe host=%s port=%s label=http protocol=%s\n' "${target_host:-<missing>}" "${HTTP_PORT}" "${http_protocol}"
    printf 'external_port_probe host=%s port=%s label=im-tcp protocol=%s\n' "${target_host:-<missing>}" "${TCP_PORT}" "${im_tcp_protocol}"
  } >>"${output_log}"
  python3 - \
    "${output_json}" \
    "${target_host}" \
    "${SSH_PORT}" \
    "${ssh_protocol}" \
    "${HTTP_PORT}" \
    "${http_protocol}" \
    "${TCP_PORT}" \
    "${im_tcp_protocol}" <<'PY'
import json
import sys
from pathlib import Path

(
    output_json,
    target_host,
    ssh_port,
    ssh_protocol,
    http_port,
    http_protocol,
    tcp_port,
    im_tcp_protocol,
) = sys.argv[1:9]

path = Path(output_json)
payload = json.loads(path.read_text(encoding="utf-8"))
signals = payload.setdefault("signals", {})
signals.update({
    "targetHost": target_host,
    "sshPort": ssh_port,
    "sshPortProtocol": ssh_protocol,
    "httpPort": http_port,
    "httpPortProtocol": http_protocol,
    "imTcpPort": tcp_port,
    "imTcpPortProtocol": im_tcp_protocol,
})
protocol_rows = payload.get("portProtocols")
if not isinstance(protocol_rows, list):
    protocol_rows = []
known = {
    (str(row.get("port") or ""), str(row.get("protocol") or ""))
    for row in protocol_rows
    if isinstance(row, dict)
}
for label, port, protocol in (
    ("ssh", ssh_port, ssh_protocol),
    ("http", http_port, http_protocol),
    ("im-tcp", tcp_port, im_tcp_protocol),
):
    key = (str(port), str(protocol))
    if key not in known:
        protocol_rows.append({"label": label, "port": str(port), "protocol": protocol})
        known.add(key)
payload["portProtocols"] = protocol_rows
if (
    ssh_protocol == "http_403_intercepted"
    and http_protocol == "http_403_intercepted"
    and im_tcp_protocol == "http_403_intercepted"
):
    signals["edgeIntercept"] = "http_403_all_sampled_ports"
    payload["failed"] = True
    payload["diagnosis"] = "cloud_edge_http_403_intercept"
    payload["detail"] = (
        "SSH, public HTTP, and IM TCP ports all return the same empty HTTP 403 "
        "banner. Public traffic is being intercepted before it reaches the "
        "instance; fix cloud security/WAF/NAT/public IP routing from the cloud "
        "console before running deploy or performance tests."
    )
elif ssh_protocol in {"http_403_intercepted", "http_intercepted"}:
    signals["edgeIntercept"] = "ssh_port_http_intercepted"
    payload["failed"] = True
    if ssh_protocol == "http_403_intercepted":
        payload["diagnosis"] = "ssh_port_http_403_intercept"
        payload["detail"] = (
            "SSH port 22 returned HTTP 403 instead of an SSH banner. The request "
            "is reaching a cloud edge/proxy/WAF/routing layer before the instance; "
            "fix public IP binding, security group, NAT, or forwarding rules in the "
            "cloud console before troubleshooting SSH keys or sshd."
        )
    else:
        payload["diagnosis"] = "ssh_port_http_intercept"
        payload["detail"] = (
            "SSH port 22 returned an HTTP response instead of an SSH banner. The "
            "request is not reaching sshd as raw SSH; fix cloud routing, security "
            "group, proxy, NAT, or forwarding rules from the provider console."
        )
elif im_tcp_protocol in {"http_403_intercepted", "http_intercepted"}:
    signals["edgeIntercept"] = "im_tcp_port_http_intercepted"
    payload["failed"] = True
    payload["diagnosis"] = "im_tcp_port_not_imserver"
    payload["detail"] = (
        "The IM TCP port returned an HTTP response instead of staying silent for "
        "the IM client handshake. TCP connect success alone is not valid capacity evidence."
    )
else:
    signals.setdefault("edgeIntercept", "")
payload["edgeIntercept"] = payload.get("edgeIntercept") or signals.get("edgeIntercept") or ""
payload["tcpStatus"] = payload.get("tcpStatus") or signals.get("tcpStatus") or ""
if not isinstance(payload.get("additionalProtocolHosts"), list):
    payload["additionalProtocolHosts"] = []
path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
}

write_post_rescue_verify() {
  local output="$1"
  cat >"${output}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="\${BASE_URL:-${BASE_URL}}"
TCP_HOST="\${TCP_HOST:-${TCP_HOST:-$(host_from_url)}}"
TCP_PORT="\${TCP_PORT:-${TCP_PORT}}"
SSH_HOST="\${SSH_HOST:-${TCP_HOST:-$(host_from_url)}}"
SSH_PORT="\${SSH_PORT:-${SSH_PORT}}"
SSH_USER="\${SSH_USER:-root}"
SSH_PRIVATE_KEY_PATH="\${SSH_PRIVATE_KEY_PATH:-}"
ACCOUNT_FILE="\${ACCOUNT_FILE:-${ACCOUNT_FILE}}"
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
POST_RESCUE_VERIFY_JSON="\${POST_RESCUE_VERIFY_JSON:-\${SCRIPT_DIR}/post-rescue-verify-result.json}"
REQUEST_TIMEOUT_SECONDS="\${REQUEST_TIMEOUT_SECONDS:-8}"
CONNECT_TIMEOUT_SECONDS="\${CONNECT_TIMEOUT_SECONDS:-5}"

require_cmd() {
  if ! command -v "\$1" >/dev/null 2>&1; then
    printf 'post_rescue_verify result=fail reason=missing_command command=%s\\n' "\$1" >&2
    exit 1
  fi
}

http_status() {
  local url="\$1"
  local body_file="\$2"
  curl -sS \\
    --connect-timeout "\${CONNECT_TIMEOUT_SECONDS}" \\
    --max-time "\${REQUEST_TIMEOUT_SECONDS}" \\
    -o "\${body_file}" \\
    -w '%{http_code}' \\
    "\$url" || true
}

url_port() {
  python3 - "\$1" <<'PY'
from urllib.parse import urlparse
import sys

url = urlparse(sys.argv[1])
print(url.port or (443 if url.scheme == "https" else 80))
PY
}

probe_port_protocol() {
  local host="\$1"
  local port="\$2"
  local raw compact
  if [[ -z "\${host}" || -z "\${port}" ]]; then
    printf 'skipped_missing_target\\n'
    return 0
  fi
  raw="\$(printf '' | nc -w "\${CONNECT_TIMEOUT_SECONDS}" "\${host}" "\${port}" 2>/dev/null | LC_ALL=C head -c 160 || true)"
  compact="\$(printf '%s' "\${raw}" | LC_ALL=C tr '\\r\\n\\t ' '____' | sed 's/__*/_/g; s/^_//; s/_$//' | cut -c 1-120)"
  if [[ -z "\${compact}" ]]; then
    printf 'no_banner\\n'
  elif [[ "\${compact}" == SSH-* ]]; then
    printf 'ssh_banner\\n'
  elif [[ "\${compact}" == HTTP/1.1_403* || "\${compact}" == HTTP/1.0_403* || "\${compact}" == HTTP/2_403* ]]; then
    printf 'http_403_intercepted\\n'
  elif [[ "\${compact}" == HTTP/* ]]; then
    printf 'http_intercepted\\n'
  else
    printf 'unexpected_banner:%s\\n' "\${compact}"
  fi
}

first_account_email() {
  if [[ -n "\${ACCOUNT_FILE}" && -f "\${ACCOUNT_FILE}" ]]; then
    awk -F',' 'NF >= 2 && \$1 !~ /^#/ { print \$1; exit }' "\${ACCOUNT_FILE}"
  else
    printf '%s\\n' "\${IM_EMAIL:-demo@example.com}"
  fi
}

first_account_password() {
  if [[ -n "\${ACCOUNT_FILE}" && -f "\${ACCOUNT_FILE}" ]]; then
    awk -F',' 'NF >= 2 && \$1 !~ /^#/ { print \$2; exit }' "\${ACCOUNT_FILE}"
  else
    printf '%s\\n' "\${IM_PASSWORD:-password1234}"
  fi
}

write_result_json() {
  local final_status="\$1"
  local reason="\$2"
  python3 - \\
    "\${POST_RESCUE_VERIFY_JSON}" \\
    "\${BASE_URL}" \\
    "\${TCP_HOST}" \\
    "\${TCP_PORT}" \\
    "\${SSH_HOST}" \\
    "\${SSH_PORT}" \\
    "\${nginx_status:-}" \\
    "\${nginx_body_bytes:-0}" \\
    "\${health_status:-}" \\
    "\${health_body_bytes:-0}" \\
    "\${auth_get_status:-}" \\
    "\${auth_get_body_bytes:-0}" \\
    "\${login_status:-}" \\
    "\${login_body_bytes:-0}" \\
    "\${tcp_status:-}" \\
    "\${ssh_status:-}" \\
    "\${edge_intercept:-}" \\
    "\${port_protocols_file:-}" \\
    "\${final_status}" \\
    "\${reason}" <<'PY'
import json
import sys
import time
from pathlib import Path

(
    output_json,
    base_url,
    tcp_host,
    tcp_port,
    ssh_host,
    ssh_port,
    nginx_status,
    nginx_body_bytes,
    health_status,
    health_body_bytes,
    auth_get_status,
    auth_get_body_bytes,
    login_status,
    login_body_bytes,
    tcp_status,
    ssh_status,
    edge_intercept,
    port_protocols_path,
    final_status,
    reason,
) = sys.argv[1:21]

def to_int(value: str) -> int:
    try:
        return int(value or 0)
    except ValueError:
        return 0

payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "status": final_status,
    "reason": reason,
    "target": {
        "baseURL": base_url,
        "tcpHost": tcp_host,
        "tcpPort": tcp_port,
        "sshHost": ssh_host,
        "sshPort": ssh_port,
    },
    "signals": {
        "nginxHealthStatus": nginx_status,
        "nginxHealthBodyBytes": to_int(nginx_body_bytes),
        "healthStatus": health_status,
        "healthBodyBytes": to_int(health_body_bytes),
        "authLoginGetStatus": auth_get_status,
        "authLoginGetBodyBytes": to_int(auth_get_body_bytes),
        "loginStatus": login_status,
        "loginBodyBytes": to_int(login_body_bytes),
        "tcpStatus": tcp_status,
        "sshStatus": ssh_status,
        "edgeIntercept": edge_intercept,
    },
}
port_protocols = []
if port_protocols_path:
    path = Path(port_protocols_path)
    if path.exists():
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = raw.split("\\t")
            if len(parts) != 3:
                continue
            label, port, protocol = parts
            port_protocols.append({"label": label, "port": port, "protocol": protocol})
payload["signals"]["portProtocols"] = port_protocols
payload["portProtocols"] = port_protocols
payload["edgeIntercept"] = edge_intercept
Path(output_json).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
}

require_cmd curl
require_cmd nc
require_cmd python3

printf 'post_rescue_verify target baseURL=%s tcpHost=%s tcpPort=%s sshHost=%s sshPort=%s\\n' \\
  "\${BASE_URL}" "\${TCP_HOST}" "\${TCP_PORT}" "\${SSH_HOST}" "\${SSH_PORT}"

tmp_dir="\$(mktemp -d "\${TMPDIR:-/tmp}/im-post-rescue-verify.XXXXXX")"
cleanup() {
  rm -rf "\${tmp_dir}"
}
trap cleanup EXIT

port_protocols_file="\${tmp_dir}/port-protocols.tsv"
: >"\${port_protocols_file}"
nginx_body="\${tmp_dir}/nginx-health.body"
health_body="\${tmp_dir}/health.body"
auth_get_body="\${tmp_dir}/auth-login-get.body"
login_body="\${tmp_dir}/login.body"
login_payload="\${tmp_dir}/login-payload.json"

nginx_status="\$(http_status "\${BASE_URL%/}/nginx-health" "\${nginx_body}")"
nginx_body_bytes="\$(wc -c <"\${nginx_body}" | tr -d ' ')"
health_status="\$(http_status "\${BASE_URL%/}/health" "\${health_body}")"
health_body_bytes="\$(wc -c <"\${health_body}" | tr -d ' ')"
auth_get_status="\$(http_status "\${BASE_URL%/}/api/auth/login" "\${auth_get_body}")"
auth_get_body_bytes="\$(wc -c <"\${auth_get_body}" | tr -d ' ')"
printf 'post_rescue_verify probe=nginx-health status=%s bodyBytes=%s\\n' "\${nginx_status}" "\${nginx_body_bytes}"
printf 'post_rescue_verify probe=health status=%s bodyBytes=%s\\n' "\${health_status}" "\${health_body_bytes}"
printf 'post_rescue_verify probe=auth-login-get status=%s bodyBytes=%s\\n' "\${auth_get_status}" "\${auth_get_body_bytes}"

base_http_port="\$(url_port "\${BASE_URL}")"
ssh_protocol="\$(probe_port_protocol "\${SSH_HOST}" "\${SSH_PORT}")"
http_protocol="\$(probe_port_protocol "\${TCP_HOST}" "\${base_http_port}")"
im_tcp_protocol="\$(probe_port_protocol "\${TCP_HOST}" "\${TCP_PORT}")"
printf 'ssh\\t%s\\t%s\\n' "\${SSH_PORT}" "\${ssh_protocol}" >>"\${port_protocols_file}"
printf 'http\\t%s\\t%s\\n' "\${base_http_port}" "\${http_protocol}" >>"\${port_protocols_file}"
printf 'im-tcp\\t%s\\t%s\\n' "\${TCP_PORT}" "\${im_tcp_protocol}" >>"\${port_protocols_file}"
printf 'post_rescue_verify protocol=ssh host=%s port=%s protocol=%s\\n' "\${SSH_HOST}" "\${SSH_PORT}" "\${ssh_protocol}"
printf 'post_rescue_verify protocol=http host=%s port=%s protocol=%s\\n' "\${TCP_HOST}" "\${base_http_port}" "\${http_protocol}"
printf 'post_rescue_verify protocol=im-tcp host=%s port=%s protocol=%s\\n' "\${TCP_HOST}" "\${TCP_PORT}" "\${im_tcp_protocol}"
http_403_protocols=0
for protocol in "\${ssh_protocol}" "\${http_protocol}" "\${im_tcp_protocol}"; do
  if [[ "\${protocol}" == "http_403_intercepted" ]]; then
    http_403_protocols=\$((http_403_protocols + 1))
  fi
done
edge_intercept=""
if [[ "\${http_403_protocols}" == "3" ]]; then
  edge_intercept="http_403_all_sampled_ports"
elif (( http_403_protocols >= 2 )); then
  edge_intercept="http_403_multiple_sampled_ports"
fi
printf 'post_rescue_verify protocolSummary sampled=3 http403=%s edgeIntercept=%s\\n' "\${http_403_protocols}" "\${edge_intercept:-<none>}"
if [[ "\${edge_intercept}" == "http_403_all_sampled_ports" ]]; then
  tcp_status="http_403_intercepted"
  ssh_status="http_403_intercepted"
  write_result_json "FAIL" "cloud_edge_http_403_intercept"
  printf 'post_rescue_verify result=fail reason=cloud_edge_http_403_intercept detail=sampled_ports_return_http_403\\n' >&2
  exit 1
elif [[ "\${edge_intercept}" == "http_403_multiple_sampled_ports" ]]; then
  tcp_status="\${im_tcp_protocol}"
  ssh_status="\${ssh_protocol}"
  write_result_json "FAIL" "cloud_edge_partial_http_403_intercept"
  printf 'post_rescue_verify result=fail reason=cloud_edge_partial_http_403_intercept detail=multiple_sampled_ports_return_http_403\\n' >&2
  exit 1
elif [[ "\${ssh_protocol}" == http_* || "\${ssh_protocol}" == unexpected_banner:* ]]; then
  tcp_status="\${im_tcp_protocol}"
  ssh_status="\${ssh_protocol}"
  if [[ "\${ssh_protocol}" == "http_403_intercepted" ]]; then
    write_result_json "FAIL" "ssh_port_http_403_intercept"
    printf 'post_rescue_verify result=fail reason=ssh_port_http_403_intercept protocol=%s detail=ssh_port_returned_http_403\\n' "\${ssh_protocol}" >&2
  elif [[ "\${ssh_protocol}" == "http_intercepted" ]]; then
    write_result_json "FAIL" "ssh_port_http_intercept"
    printf 'post_rescue_verify result=fail reason=ssh_port_http_intercept protocol=%s detail=ssh_port_returned_http\\n' "\${ssh_protocol}" >&2
  else
    write_result_json "FAIL" "ssh_port_not_ssh"
    printf 'post_rescue_verify result=fail reason=ssh_port_not_ssh protocol=%s\\n' "\${ssh_protocol}" >&2
  fi
  exit 1
elif [[ "\${im_tcp_protocol}" == http_* ]]; then
  tcp_status="\${im_tcp_protocol}"
  ssh_status="\${ssh_protocol}"
  write_result_json "FAIL" "im_tcp_port_not_imserver"
  printf 'post_rescue_verify result=fail reason=im_tcp_port_not_imserver protocol=%s\\n' "\${im_tcp_protocol}" >&2
  exit 1
fi

if nc -z -w 5 "\${TCP_HOST}" "\${TCP_PORT}" >/dev/null 2>&1; then
  tcp_status="open"
  printf 'post_rescue_verify probe=tcp status=%s\\n' "\${tcp_status}"
else
  tcp_status="closed_or_filtered"
  write_result_json "FAIL" "tcp_not_open"
  printf 'post_rescue_verify result=fail reason=tcp_not_open host=%s port=%s\\n' "\${TCP_HOST}" "\${TCP_PORT}" >&2
  exit 1
fi

if [[ -n "\${SSH_PRIVATE_KEY_PATH}" ]]; then
  if ssh -i "\${SSH_PRIVATE_KEY_PATH}" \\
    -p "\${SSH_PORT}" \\
    -o BatchMode=yes \\
    -o ConnectTimeout=8 \\
    -o StrictHostKeyChecking=no \\
    "\${SSH_USER}@\${SSH_HOST}" 'echo ok' >/dev/null; then
    ssh_status="ok"
    printf 'post_rescue_verify probe=ssh status=%s\\n' "\${ssh_status}"
  else
    ssh_status="closed_or_failed"
    write_result_json "FAIL" "ssh_not_ok"
    printf 'post_rescue_verify result=fail reason=ssh_not_ok host=%s port=%s\\n' "\${SSH_HOST}" "\${SSH_PORT}" >&2
    exit 1
  fi
else
  ssh_status="skipped_missing_private_key"
  printf 'post_rescue_verify probe=ssh status=%s\\n' "\${ssh_status}"
fi

if [[ "\${nginx_status}" != "200" || "\${health_status}" != "200" ]]; then
  write_result_json "FAIL" "http_not_healthy"
  printf 'post_rescue_verify result=fail reason=http_not_healthy nginx=%s health=%s\\n' "\${nginx_status}" "\${health_status}" >&2
  exit 1
fi

python3 - "\$(first_account_email)" "\$(first_account_password)" >"\${login_payload}" <<'PY'
import json
import sys

email, password = sys.argv[1:3]
print(json.dumps({
    "email": email,
    "password": password,
    "device": {
        "deviceID": "post-rescue-verify",
        "deviceName": "post-rescue-verify",
        "platform": "load-test",
        "appVersion": "load-test",
    },
}, separators=(",", ":")))
PY
login_status="\$(curl -sS \\
  --connect-timeout "\${CONNECT_TIMEOUT_SECONDS}" \\
  --max-time "\${REQUEST_TIMEOUT_SECONDS}" \\
  -o "\${login_body}" \\
  -w '%{http_code}' \\
  -H 'Content-Type: application/json' \\
  --data-binary "@\${login_payload}" \\
  "\${BASE_URL%/}/api/auth/login" || true)"
login_body_bytes="\$(wc -c <"\${login_body}" | tr -d ' ')"
printf 'post_rescue_verify probe=login status=%s bodyBytes=%s body=<redacted>\\n' "\${login_status}" "\${login_body_bytes}"

if [[ "\${login_status}" != "200" ]]; then
  write_result_json "FAIL" "login_not_ok"
  printf 'post_rescue_verify result=fail reason=login_not_ok status=%s\\n' "\${login_status}" >&2
  exit 1
fi

write_result_json "PASS" ""
printf 'post_rescue_verify result=pass\\n'
EOF
  chmod 0755 "${output}"
}

write_resume_product_validation() {
  local output="$1"
  local post_rescue_script="$2"
  cat >"${output}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="\$(cd "\${SCRIPT_DIR}/../../../.." && pwd)"

BASE_URL="\${BASE_URL:-${BASE_URL}}"
TCP_HOST="\${TCP_HOST:-${TCP_HOST:-$(host_from_url)}}"
TCP_PORT="\${TCP_PORT:-${TCP_PORT}}"
ACCOUNT_FILE="\${ACCOUNT_FILE:-${ACCOUNT_FILE}}"
IM_CONVERSATION_ID="\${IM_CONVERSATION_ID:-${IM_CONVERSATION_ID:-}}"
IM_INTERNAL_SECRET="\${IM_INTERNAL_SECRET:-\${IM_INTERNAL_SHARED_SECRET:-}}"
RESULT_ROOT="\${RESULT_ROOT:-\${REPO_ROOT}/IMServer/LoadTests/results/post-rescue-product-validation}"
PRODUCT_TEST_PHASES="\${PRODUCT_TEST_PHASES:-entrypoint real-world-smoke}"
PRODUCT_TEST_RUN_FULL_PROFILE="\${PRODUCT_TEST_RUN_FULL_PROFILE:-false}"
PRODUCT_TEST_FULL_PROFILE="\${PRODUCT_TEST_FULL_PROFILE:-normal-product-baseline}"
PRODUCT_TEST_PACKAGE_EVIDENCE="\${PRODUCT_TEST_PACKAGE_EVIDENCE:-true}"
PERF_STATUS_FILTER_TARGET="\${PERF_STATUS_FILTER_TARGET:-true}"
PERF_DRY_RUN="\${PERF_DRY_RUN:-false}"

"${post_rescue_script}"

RESULT_ROOT="\${RESULT_ROOT}" \\
BASE_URL="\${BASE_URL}" \\
TCP_HOST="\${TCP_HOST}" \\
TCP_PORT="\${TCP_PORT}" \\
ACCOUNT_FILE="\${ACCOUNT_FILE}" \\
IM_CONVERSATION_ID="\${IM_CONVERSATION_ID}" \\
IM_INTERNAL_SECRET="\${IM_INTERNAL_SECRET}" \\
PRODUCT_TEST_PHASES="\${PRODUCT_TEST_PHASES}" \\
PRODUCT_TEST_RUN_FULL_PROFILE="\${PRODUCT_TEST_RUN_FULL_PROFILE}" \\
PRODUCT_TEST_FULL_PROFILE="\${PRODUCT_TEST_FULL_PROFILE}" \\
PRODUCT_TEST_PACKAGE_EVIDENCE="\${PRODUCT_TEST_PACKAGE_EVIDENCE}" \\
PERF_STATUS_FILTER_TARGET="\${PERF_STATUS_FILTER_TARGET}" \\
PERF_DRY_RUN="\${PERF_DRY_RUN}" \\
  "\${REPO_ROOT}/IMServer/LoadTests/run_product_test_plan.sh"

verify_args=(
  "\${REPO_ROOT}/IMServer/LoadTests/perf_product_plan_artifacts_verify.py"
  --product-run-json "\${RESULT_ROOT}/product-test-plan-run.json"
  --plan-preview-json "\${RESULT_ROOT}/product-test-plan-preview.json"
  --require-prereq
)
case "\${PERF_DRY_RUN}" in
  1|true|TRUE|yes|YES|on|ON)
    verify_args+=(--allow-dry-run)
    ;;
esac
python3 "\${verify_args[@]}"

printf 'resume_product_validation result=pass resultRoot=%s\\n' "\${RESULT_ROOT}"
EOF
  chmod 0755 "${output}"
}

write_artifact_verify() {
  local output="$1"
  cat >"${output}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../../../.." && pwd 2>/dev/null || printf '')}"

require_file() {
  if [[ ! -f "${SCRIPT_DIR}/$1" ]]; then
    printf 'node_access_rescue_artifact_verify result=fail reason=missing_file file=%s\n' "$1" >&2
    exit 1
  fi
}

tree_contains_regex() {
  local root="$1"
  local pattern="$2"
  local exclude_name="${3:-}"
  if command -v rg >/dev/null 2>&1; then
    if [[ -n "${exclude_name}" ]]; then
      rg -n --glob "!${exclude_name}" -- "${pattern}" "${root}" >/dev/null
    else
      rg -n -- "${pattern}" "${root}" >/dev/null
    fi
    return $?
  fi

  if [[ -n "${exclude_name}" ]]; then
    grep -R -n -E --exclude="${exclude_name}" -- "${pattern}" "${root}" >/dev/null
  else
    grep -R -n -E -- "${pattern}" "${root}" >/dev/null
  fi
}

require_file SHA256SUMS
require_file cloud-console-node-access-rescue.sh
require_file post-rescue-verify.sh
require_file resume-product-validation.sh
require_file README.md
require_file artifact-manifest.json
require_file external-entrypoint-probe.json
require_file external-entrypoint-probe.log
require_file entrypoint-rescue-plan.json
require_file entrypoint-rescue-plan.md
require_file product-plan/product-test-plan-run.json
require_file product-plan/product-test-plan-preview.json
require_file product-plan/product-test-runbook.md

validate_checksum_file() {
  python3 - "${SCRIPT_DIR}" "${SCRIPT_DIR}/SHA256SUMS" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1]).resolve()
checksum_path = Path(sys.argv[2])
digest_re = re.compile(r"^[0-9a-fA-F]{64}$")
seen: set[str] = set()
count = 0

for line_number, raw in enumerate(checksum_path.read_text(encoding="utf-8").splitlines(), start=1):
    if not raw.strip():
        continue
    parts = raw.split(maxsplit=1)
    if len(parts) != 2 or not digest_re.match(parts[0]):
        raise SystemExit(
            "node_access_rescue_artifact_verify result=fail "
            f"reason=checksum_file_bad_line line={line_number}"
        )
    rel = parts[1]
    if rel.startswith("*"):
        rel = rel[1:]
    if not rel.startswith("./") or rel.startswith("//") or rel.startswith("\\"):
        raise SystemExit(
            "node_access_rescue_artifact_verify result=fail "
            f"reason=checksum_file_unsafe_path path={rel}"
        )
    if rel in {"./SHA256SUMS"}:
        raise SystemExit(
            "node_access_rescue_artifact_verify result=fail "
            f"reason=checksum_file_forbidden_path path={rel}"
        )
    posix = PurePosixPath(rel)
    if posix.is_absolute() or any(part in {"", ".", ".."} for part in posix.parts[1:]):
        raise SystemExit(
            "node_access_rescue_artifact_verify result=fail "
            f"reason=checksum_file_unsafe_path path={rel}"
        )
    if rel in seen:
        raise SystemExit(
            "node_access_rescue_artifact_verify result=fail "
            f"reason=checksum_file_duplicate_path path={rel}"
        )
    target = (root / rel[2:]).resolve()
    try:
        target.relative_to(root)
    except ValueError as exc:
        raise SystemExit(
            "node_access_rescue_artifact_verify result=fail "
            f"reason=checksum_file_unsafe_path path={rel}"
        ) from exc
    if not target.is_file():
        raise SystemExit(
            "node_access_rescue_artifact_verify result=fail "
            f"reason=checksum_file_missing_path path={rel}"
        )
    seen.add(rel)
    count += 1

if count <= 0:
    raise SystemExit("node_access_rescue_artifact_verify result=fail reason=checksum_file_empty")

print(f"node_access_rescue_artifact_verify step=checksum_file_safety result=pass count={count}")
PY
}

validate_checksum_file

if command -v sha256sum >/dev/null 2>&1; then
  (cd "${SCRIPT_DIR}" && sha256sum -c SHA256SUMS >/dev/null)
else
  (cd "${SCRIPT_DIR}" && shasum -a 256 -c SHA256SUMS >/dev/null)
fi

python3 - "${SCRIPT_DIR}/artifact-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
payload = json.loads(manifest_path.read_text(encoding="utf-8"))
if payload.get("schemaVersion") != 1:
    raise SystemExit("node_access_rescue_artifact_verify result=fail reason=bad_manifest_schema")
required = {
    "./README.md",
    "./cloud-console-node-access-rescue.sh",
    "./post-rescue-verify.sh",
    "./resume-product-validation.sh",
    "./verify-artifact.sh",
    "./entrypoint-rescue-plan.json",
    "./entrypoint-rescue-plan.md",
    "./external-entrypoint-probe.json",
    "./product-plan/product-test-plan-run.json",
    "./product-plan/product-test-plan-preview.json",
    "./product-plan/product-test-runbook.md",
    "./summary.txt",
}
files = {row.get("path") for row in payload.get("files") or []}
missing = sorted(required - files)
if missing:
    raise SystemExit(
        "node_access_rescue_artifact_verify result=fail "
        f"reason=manifest_missing_files files={','.join(missing)}"
    )
if not (payload.get("target") or {}).get("baseURL"):
    raise SystemExit("node_access_rescue_artifact_verify result=fail reason=manifest_missing_target")
if not payload.get("diagnosis"):
    raise SystemExit("node_access_rescue_artifact_verify result=fail reason=manifest_missing_diagnosis")
PY

bash -n "${SCRIPT_DIR}/cloud-console-node-access-rescue.sh"
bash -n "${SCRIPT_DIR}/post-rescue-verify.sh"
bash -n "${SCRIPT_DIR}/resume-product-validation.sh"

if tree_contains_regex "${SCRIPT_DIR}" 'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY|PRIVATE KEY-----|Proc-Type: 4,ENCRYPTED' "verify-artifact.sh"; then
  printf 'node_access_rescue_artifact_verify result=fail reason=private_key_marker_detected dir=%s\n' "${SCRIPT_DIR}" >&2
  exit 1
fi

fallback_secret_scan() {
  python3 - "${SCRIPT_DIR}" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
private_marker = re.compile("-" * 5 + r"BEGIN [A-Z0-9 ]*PRIVATE KEY" + "-" * 5)
sensitive_assignment = re.compile(
    r"""(?ix)
    ["']?
    ([a-z0-9_.-]*
      (?:token|password|secret|private[_-]?key|access[_-]?key)
      [a-z0-9_.-]*)
    ["']?
    \s*[:=]\s*
    ["']?
    ([^"',\s}]+)
    """
)

safe_values = {
    "",
    "null",
    "nil",
    "none",
    "false",
    "true",
    "<redacted>",
    "<private-key-path>",
    "IM_INTERNAL_SECRET",
    "IM_INTERNAL_SHARED_SECRET",
    "IM_PASSWORD",
    "IM_ACCOUNT_PASSWORD",
    "JWT_SECRET",
    "password",
    "account_password",
    "password1234",
}
safe_value_prefixes = ("$", "${", "<", "sys.argv")
safe_value_fragments = ("${", "?set-", ":-", "<redacted", "sys.argv", "password1234")
findings: list[str] = []
scanned = 0


def is_sensitive_key(key: str) -> bool:
    normalized = re.sub(r"[^a-z0-9]", "", key.lower())
    if normalized in {
        "token",
        "accesstoken",
        "refreshtoken",
        "password",
        "secret",
        "privatekey",
        "accesskey",
    }:
        return True
    return normalized.endswith(("token", "password", "secret", "privatekey", "accesskey"))


def is_binary(data: bytes) -> bool:
    return b"\x00" in data


def is_safe_value(value: str) -> bool:
    stripped = value.strip().strip("\"'")
    lowered = stripped.lower()
    if lowered in safe_values or stripped in safe_values:
        return True
    if stripped.startswith(safe_value_prefixes):
        return True
    if any(fragment in stripped for fragment in safe_value_fragments):
        return True
    if len(stripped) < 8:
        return True
    return False


for path in sorted(root.rglob("*")):
    if not path.is_file() or path.is_symlink():
        continue
    rel = path.relative_to(root).as_posix()
    try:
        data = path.read_bytes()
    except OSError as exc:
        findings.append(f"{rel}:read_error:{exc}")
        continue
    if is_binary(data):
        continue
    scanned += 1
    text = data.decode("utf-8", errors="ignore")
    if rel != "verify-artifact.sh" and private_marker.search(text):
        findings.append(f"{rel}:private_key_marker")
    if rel == "verify-artifact.sh":
        continue
    for line_no, line in enumerate(text.splitlines(), start=1):
        for match in sensitive_assignment.finditer(line):
            key, value = match.group(1), match.group(2)
            if not is_sensitive_key(key):
                continue
            if is_safe_value(value):
                continue
            findings.append(f"{rel}:{line_no}:sensitive_assignment:{key}")
            if len(findings) >= 20:
                break
        if len(findings) >= 20:
            break
    if len(findings) >= 20:
        break

if findings:
    print(
        "node_access_rescue_artifact_verify result=fail "
        f"reason=fallback_secret_scan findings={len(findings)} scanned={scanned}",
        file=sys.stderr,
    )
    for finding in findings[:10]:
        print(f"finding={finding}", file=sys.stderr)
    raise SystemExit(1)

print(f"node_access_rescue_artifact_verify secret_scan=fallback scanned={scanned}")
PY
}

if [[ -f "${REPO_ROOT}/IMServer/LoadTests/perf_secret_scan.py" ]]; then
  python3 "${REPO_ROOT}/IMServer/LoadTests/perf_secret_scan.py" --root "${SCRIPT_DIR}" >/dev/null
else
  fallback_secret_scan
fi

printf 'node_access_rescue_artifact_verify result=pass dir=%s\n' "${SCRIPT_DIR}"
EOF
  chmod 0755 "${output}"
}

write_readme() {
  local artifact_dir="$1"
  local public_key_file="$2"
  local rescue_script="$3"
  local summary_file="$4"
  local post_rescue_script="$5"
  local resume_script="$6"
  local verify_script="$7"
  local external_probe_json="$8"
  local external_probe_log="$9"
  local rescue_plan_json="${10}"
  local rescue_plan_md="${11}"
  local readme="${12}"
  cat >"${readme}" <<EOF
# Node Access Rescue Artifact

Target:

- publicBaseURL: \`${PUBLIC_BASE_URL}\`
- baseURL: \`${BASE_URL}\`
- tcpHost: \`${TCP_HOST:-$(host_from_url)}\`
- tcpPort: \`${TCP_PORT}\`
- sshPort: \`${SSH_PORT}\`

Status summary:

\`\`\`text
$(cat "${summary_file}")
\`\`\`

Use this when SSH closes or public HTTP returns empty 403. The generated script
repairs SSH, Nginx, UFW rules, and public HTTP/TCP entrypoints from a cloud
console or rescue shell.

## Files

- rescue script: \`./$(basename "${rescue_script}")\`
- post-rescue verifier: \`./$(basename "${post_rescue_script}")\`
- post-rescue product validation: \`./$(basename "${resume_script}")\`
- artifact verifier: \`./$(basename "${verify_script}")\`
- artifact manifest: \`./artifact-manifest.json\`
- external entrypoint probe: \`./$(basename "${external_probe_json}")\`
- external entrypoint probe log: \`./$(basename "${external_probe_log}")\`
- entrypoint rescue plan: \`./$(basename "${rescue_plan_md}")\`
- entrypoint rescue plan JSON: \`./$(basename "${rescue_plan_json}")\`
- public key: \`./$(basename "${public_key_file}")\`
- product runbook: \`./product-plan/product-test-runbook.md\`
- product receipt: \`./product-plan/product-test-plan-run.json\`
- product plan preview: \`./product-plan/product-test-plan-preview.json\`
- checksums: \`./SHA256SUMS\`

## Cloud Console Steps

1. Open the server provider's cloud console for the target instance.
2. Run the artifact commands from the artifact directory. If the directory was
   copied elsewhere, \`cd\` into the copied directory first.
3. Verify the artifact before copying anything into the cloud console:

\`\`\`bash
./$(basename "${verify_script}")
\`\`\`

4. Paste the full content of \`./$(basename "${rescue_script}")\` into the console.
5. Wait for \`node_access_rescue result=pass\`.
6. From this machine, run:

\`\`\`bash
SSH_PRIVATE_KEY_PATH=\${SSH_PRIVATE_KEY_PATH:-<private-key-path>} \\
./$(basename "${post_rescue_script}")
\`\`\`

7. Rerun product validation after SSH and HTTP recover:

\`\`\`bash
SSH_PRIVATE_KEY_PATH=\${SSH_PRIVATE_KEY_PATH:-<private-key-path>} \\
./$(basename "${resume_script}")
\`\`\`

By default this runs \`entrypoint real-world-smoke\`.
Set \`PRODUCT_TEST_RUN_FULL_PROFILE=true\` when you are ready to run the full
\`normal-product-baseline\` evidence path.

## Entrypoint Rescue Plan

The artifact includes a diagnosis-specific rescue plan generated from the
external entrypoint probe:

\`\`\`bash
cat ./$(basename "${rescue_plan_md}")
\`\`\`

If you received a \`.tar.gz\` package with a sibling \`.verify.sh\`, run the
verify script first. It checks the package checksum, extracts the archive, and
runs the artifact verifier in fallback mode before you copy anything into the
cloud console.

The rescue script contains the public key only. It must never contain local
secret-key material. The generated artifact verifier checks checksums, shell
syntax, private-key markers, and secret-like values. It uses the repository
\`perf_secret_scan.py\` when available and falls back to a self-contained scan
when the artifact is copied away from the repository:

\`\`\`bash
./$(basename "${verify_script}")
\`\`\`
EOF
}

write_sha256sums() {
  local artifact_dir="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${artifact_dir}" && find . -maxdepth 4 -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
  else
    (cd "${artifact_dir}" && find . -maxdepth 4 -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 >SHA256SUMS)
  fi
}

write_artifact_manifest() {
  local artifact_dir="$1"
  local manifest_file="$2"
  local external_probe_json="$3"
  local rescue_plan_json="$4"
  local summary_file="$5"
  python3 - \
    "${artifact_dir}" \
    "${manifest_file}" \
    "${external_probe_json}" \
    "${rescue_plan_json}" \
    "${summary_file}" \
    "${PUBLIC_BASE_URL}" \
    "${BASE_URL}" \
    "${TCP_HOST:-$(host_from_url)}" \
    "${TCP_PORT}" \
    "${SSH_PORT}" <<'PY'
import json
import sys
import time
from pathlib import Path

(
    artifact_dir,
    manifest_file,
    external_probe_json,
    rescue_plan_json,
    summary_file,
    public_base_url,
    base_url,
    tcp_host,
    tcp_port,
    ssh_port,
) = sys.argv[1:11]

artifact = Path(artifact_dir)
external_probe = json.loads(Path(external_probe_json).read_text(encoding="utf-8"))
rescue_plan = json.loads(Path(rescue_plan_json).read_text(encoding="utf-8"))
summary = {}
for raw in Path(summary_file).read_text(encoding="utf-8").splitlines():
    if "=" in raw:
        key, value = raw.split("=", 1)
        summary[key] = value

checksums = []
sha_path = artifact / "SHA256SUMS"
if sha_path.exists():
    for raw in sha_path.read_text(encoding="utf-8").splitlines():
        parts = raw.strip().split(maxsplit=1)
        if len(parts) != 2:
            continue
        digest, rel = parts
        if rel in {"./SHA256SUMS", "./artifact-manifest.json"}:
            continue
        checksums.append({"path": rel, "sha256": digest})

payload = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "target": {
        "publicBaseURL": public_base_url,
        "baseURL": base_url,
        "tcpHost": tcp_host,
        "tcpPort": tcp_port,
        "sshPort": ssh_port,
    },
    "diagnosis": external_probe.get("diagnosis") or summary.get("entrypointDiagnosis") or "",
    "tcpStatus": external_probe.get("tcpStatus") or summary.get("entrypointTcpStatus") or "",
    "edgeIntercept": external_probe.get("edgeIntercept") or summary.get("edgeIntercept") or "",
    "portProtocols": external_probe.get("portProtocols") or (external_probe.get("signals") or {}).get("portProtocols") or [],
    "rescuePlanAction": rescue_plan.get("action") or summary.get("rescuePlanAction") or "",
    "summary": summary,
    "signals": rescue_plan.get("signals") or external_probe.get("signals") or {},
    "commands": rescue_plan.get("commands") or [],
    "files": checksums,
    "artifacts": {
        "readme": "./README.md",
        "sha256sums": "./SHA256SUMS",
        "rescuePlan": "./entrypoint-rescue-plan.json",
        "externalProbe": "./external-entrypoint-probe.json",
        "summary": "./summary.txt",
    },
}
Path(manifest_file).write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
PY
}

safe_extract_artifact_archive() {
  local tarball_path="$1"
  local output_dir="$2"
  python3 - "${tarball_path}" "${output_dir}" <<'PY'
from __future__ import annotations

import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath

archive_path = Path(sys.argv[1])
extract_dir = Path(sys.argv[2])
max_member_bytes = int(__import__("os").environ.get("NODE_ACCESS_RESCUE_ARCHIVE_MEMBER_MAX_BYTES", str(64 * 1024 * 1024)))
max_total_bytes = int(__import__("os").environ.get("NODE_ACCESS_RESCUE_ARCHIVE_TOTAL_MAX_BYTES", str(256 * 1024 * 1024)))
root = extract_dir.resolve()
seen: set[str] = set()
total = 0

try:
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive.getmembers():
            name = str(member.name or "")
            path = PurePosixPath(name)
            if not name or name.startswith("/") or "\\" in name or path.is_absolute():
                raise SystemExit(f"node_access_rescue_artifact result=fail reason=archive_member_path_unsafe name={name or '-'}")
            if any(part in {"", ".", ".."} for part in path.parts):
                raise SystemExit(f"node_access_rescue_artifact result=fail reason=archive_member_path_unsafe name={name}")
            if name in seen:
                raise SystemExit(f"node_access_rescue_artifact result=fail reason=archive_member_duplicate name={name}")
            if not member.isfile() and not member.isdir():
                raise SystemExit(f"node_access_rescue_artifact result=fail reason=archive_member_not_file_or_dir name={name}")
            if member.size < 0:
                raise SystemExit(f"node_access_rescue_artifact result=fail reason=archive_member_size_invalid name={name} size={member.size}")
            if member.size > max_member_bytes:
                raise SystemExit(
                    "node_access_rescue_artifact result=fail "
                    f"reason=archive_member_too_large name={name} size={member.size} max={max_member_bytes}"
                )
            total += member.size
            if total > max_total_bytes:
                raise SystemExit(
                    "node_access_rescue_artifact result=fail "
                    f"reason=archive_total_too_large size={total} max={max_total_bytes}"
                )
            target = (root / name).resolve()
            try:
                target.relative_to(root)
            except ValueError as exc:
                raise SystemExit(f"node_access_rescue_artifact result=fail reason=archive_member_path_unsafe name={name}") from exc
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                target.chmod(member.mode & 0o777)
                seen.add(name)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit(f"node_access_rescue_artifact result=fail reason=archive_member_read_failed name={name}")
            with source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(member.mode & 0o777)
            seen.add(name)
except tarfile.TarError as exc:
    raise SystemExit(f"node_access_rescue_artifact result=fail reason=archive_invalid detail={exc}") from exc

if not seen:
    raise SystemExit("node_access_rescue_artifact result=fail reason=archive_empty")

print(f"node_access_rescue_artifact step=archive_safety result=pass members={len(seen)}")
PY
}

verify_artifact_archive() {
  local tarball_path="$1"
  local tmpdir extracted_count extracted_dir
  tmpdir="$(mktemp -d)"
  safe_extract_artifact_archive "${tarball_path}" "${tmpdir}" >/dev/null
  extracted_count="$(find "${tmpdir}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  if [[ "${extracted_count}" != "1" ]]; then
    rm -rf "${tmpdir}"
    printf 'node_access_rescue_artifact result=fail reason=archive_extract_unexpected_dir_count count=%s\n' "${extracted_count}" >&2
    return 1
  fi
  extracted_dir="$(find "${tmpdir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ ! -x "${extracted_dir}/verify-artifact.sh" ]]; then
    rm -rf "${tmpdir}"
    printf 'node_access_rescue_artifact result=fail reason=archive_missing_verifier\n' >&2
    return 1
  fi
  REPO_ROOT="${tmpdir}/missing-repo" "${extracted_dir}/verify-artifact.sh" >/dev/null
  rm -rf "${tmpdir}"
}

write_artifact_package_verify_script() {
  local tarball_path="$1"
  local sha_file="$2"
  local verify_script="${tarball_path}.verify.sh"
  local tarball_name sha_name expected_sha
  tarball_name="$(basename "${tarball_path}")"
  sha_name="$(basename "${sha_file}")"
  expected_sha="$(awk '{print $1; exit}' "${sha_file}")"
  cat >"${verify_script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
TARBALL="\${SCRIPT_DIR}/${tarball_name}"
SHA_FILE="\${SCRIPT_DIR}/${sha_name}"
EXPECTED_SHA256="${expected_sha}"

require_file() {
  if [[ ! -f "\$1" ]]; then
    printf 'node_access_rescue_package_verify result=fail reason=missing_file file=%s\\n' "\$1" >&2
    exit 1
  fi
}

require_cmd() {
  if ! command -v "\$1" >/dev/null 2>&1; then
    printf 'node_access_rescue_package_verify result=fail reason=missing_command command=%s\\n' "\$1" >&2
    exit 1
  fi
}

require_file "\${TARBALL}"
require_file "\${SHA_FILE}"
require_cmd tar
require_cmd python3

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha="\$(sha256sum "\${TARBALL}" | awk '{print \$1}')"
  (cd "\${SCRIPT_DIR}" && sha256sum -c "\$(basename "\${SHA_FILE}")" >/dev/null)
elif command -v shasum >/dev/null 2>&1; then
  actual_sha="\$(shasum -a 256 "\${TARBALL}" | awk '{print \$1}')"
  (cd "\${SCRIPT_DIR}" && shasum -a 256 -c "\$(basename "\${SHA_FILE}")" >/dev/null)
else
  printf 'node_access_rescue_package_verify result=fail reason=missing_command command=sha256sum_or_shasum\\n' >&2
  exit 1
fi

sha_file_value="\$(awk '{print \$1; exit}' "\${SHA_FILE}")"
if [[ "\${sha_file_value}" != "\${EXPECTED_SHA256}" ]]; then
  printf 'node_access_rescue_package_verify result=fail reason=sha_file_expected_mismatch expected=%s actual=%s\\n' "\${EXPECTED_SHA256}" "\${sha_file_value}" >&2
  exit 1
fi
if [[ "\${actual_sha}" != "\${EXPECTED_SHA256}" ]]; then
  printf 'node_access_rescue_package_verify result=fail reason=tarball_expected_mismatch expected=%s actual=%s\\n' "\${EXPECTED_SHA256}" "\${actual_sha}" >&2
  exit 1
fi

safe_extract_archive() {
  local output_dir="\$1"
  python3 - "\${TARBALL}" "\${output_dir}" <<'PY'
from __future__ import annotations

import os
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath

archive_path = Path(sys.argv[1])
extract_dir = Path(sys.argv[2])
max_member_bytes = int(os.environ.get("NODE_ACCESS_RESCUE_ARCHIVE_MEMBER_MAX_BYTES", str(64 * 1024 * 1024)))
max_total_bytes = int(os.environ.get("NODE_ACCESS_RESCUE_ARCHIVE_TOTAL_MAX_BYTES", str(256 * 1024 * 1024)))
root = extract_dir.resolve()
seen: set[str] = set()
total = 0

try:
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive.getmembers():
            name = str(member.name or "")
            path = PurePosixPath(name)
            if not name or name.startswith("/") or "\\\\" in name or path.is_absolute():
                raise SystemExit(f"node_access_rescue_package_verify result=fail reason=archive_member_path_unsafe name={name or '-'}")
            if any(part in {"", ".", ".."} for part in path.parts):
                raise SystemExit(f"node_access_rescue_package_verify result=fail reason=archive_member_path_unsafe name={name}")
            if name in seen:
                raise SystemExit(f"node_access_rescue_package_verify result=fail reason=archive_member_duplicate name={name}")
            if not member.isfile() and not member.isdir():
                raise SystemExit(f"node_access_rescue_package_verify result=fail reason=archive_member_not_file_or_dir name={name}")
            if member.size < 0:
                raise SystemExit(f"node_access_rescue_package_verify result=fail reason=archive_member_size_invalid name={name} size={member.size}")
            if member.size > max_member_bytes:
                raise SystemExit(
                    "node_access_rescue_package_verify result=fail "
                    f"reason=archive_member_too_large name={name} size={member.size} max={max_member_bytes}"
                )
            total += member.size
            if total > max_total_bytes:
                raise SystemExit(
                    "node_access_rescue_package_verify result=fail "
                    f"reason=archive_total_too_large size={total} max={max_total_bytes}"
                )
            target = (root / name).resolve()
            try:
                target.relative_to(root)
            except ValueError as exc:
                raise SystemExit(f"node_access_rescue_package_verify result=fail reason=archive_member_path_unsafe name={name}") from exc
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                target.chmod(member.mode & 0o777)
                seen.add(name)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit(f"node_access_rescue_package_verify result=fail reason=archive_member_read_failed name={name}")
            with source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(member.mode & 0o777)
            seen.add(name)
except tarfile.TarError as exc:
    raise SystemExit(f"node_access_rescue_package_verify result=fail reason=archive_invalid detail={exc}") from exc

if not seen:
    raise SystemExit("node_access_rescue_package_verify result=fail reason=archive_empty")

print(f"node_access_rescue_package_verify step=archive_safety result=pass members={len(seen)}")
PY
}

tmpdir="\$(mktemp -d)"
cleanup() {
  rm -rf "\${tmpdir}"
}
trap cleanup EXIT

safe_extract_archive "\${tmpdir}"
extracted_count="\$(find "\${tmpdir}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [[ "\${extracted_count}" != "1" ]]; then
  printf 'node_access_rescue_package_verify result=fail reason=archive_extract_unexpected_dir_count count=%s\\n' "\${extracted_count}" >&2
  exit 1
fi
artifact_dir="\$(find "\${tmpdir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [[ ! -x "\${artifact_dir}/verify-artifact.sh" ]]; then
  printf 'node_access_rescue_package_verify result=fail reason=archive_missing_verifier\\n' >&2
  exit 1
fi

REPO_ROOT="\${tmpdir}/missing-repo" "\${artifact_dir}/verify-artifact.sh"
python3 - "\${artifact_dir}/artifact-manifest.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
print(
    "node_access_rescue_package_verify manifest "
    f"diagnosis={payload.get('diagnosis')} "
    f"action={payload.get('rescuePlanAction')} "
    f"files={len(payload.get('files') or [])}"
)
PY

printf 'node_access_rescue_package_verify result=pass tarball=%s\\n' "\${TARBALL}"
EOF
  chmod 0755 "${verify_script}"
  bash -n "${verify_script}"
  "${verify_script}" >/dev/null
  printf 'node_access_rescue_artifact package_verify=pass script=%s\n' "${verify_script}"
}

write_artifact_package_sidecars() {
  local artifact_dir="$1"
  local tarball_path="$2"
  local sha_file="$3"
  local verify_script="$4"
  local readme_path="${tarball_path}.README.md"
  local receipt_path="${tarball_path}.receipt.json"
  python3 - \
    "${artifact_dir}/artifact-manifest.json" \
    "${tarball_path}" \
    "${sha_file}" \
    "${verify_script}" \
    "${readme_path}" \
    "${receipt_path}" <<'PY'
import json
import shlex
import sys
import time
from pathlib import Path

manifest_path, tarball_path, sha_file, verify_script, readme_path, receipt_path = map(Path, sys.argv[1:7])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
sha256 = sha_file.read_text(encoding="utf-8").split()[0]
target = manifest.get("target") or {}
diagnosis = str(manifest.get("diagnosis") or "")
action = str(manifest.get("rescuePlanAction") or "")

receipt = {
    "schemaVersion": 1,
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "package": {
        "tarball": tarball_path.name,
        "sha256File": sha_file.name,
        "verifyScript": verify_script.name,
        "readme": Path(readme_path).name,
        "receipt": Path(receipt_path).name,
        "tarballSha256": sha256,
    },
    "target": {
        "publicBaseURL": target.get("publicBaseURL") or "",
        "baseURL": target.get("baseURL") or "",
        "tcpHost": target.get("tcpHost") or "",
        "tcpPort": target.get("tcpPort") or "",
        "sshPort": target.get("sshPort") or "",
    },
    "diagnosis": diagnosis,
    "rescuePlanAction": action,
    "artifactManifest": {
        "insidePackage": "./artifact-manifest.json",
        "schemaVersion": manifest.get("schemaVersion"),
    },
    "firstCommand": f"./{verify_script.name}",
    "postVerifyCommands": [
        f"tar -xzf {shlex.quote(tarball_path.name)}",
        f"cd {shlex.quote(tarball_path.name.removesuffix('.tar.gz'))}",
        "./verify-artifact.sh",
        "cat ./entrypoint-rescue-plan.md",
    ],
    "cloudConsoleCommand": "cat ./cloud-console-node-access-rescue.sh",
    "postRescueVerifyCommand": "SSH_PRIVATE_KEY_PATH=${SSH_PRIVATE_KEY_PATH:-<private-key-path>} ./post-rescue-verify.sh",
    "resumeProductValidationCommand": "SSH_PRIVATE_KEY_PATH=${SSH_PRIVATE_KEY_PATH:-<private-key-path>} ./resume-product-validation.sh",
}
Path(receipt_path).write_text(json.dumps(receipt, indent=2, sort_keys=True), encoding="utf-8")

lines = [
    "# Node Access Rescue Package",
    "",
    "This sidecar file is outside the archive so the package can be verified and",
    "operated without first extracting it.",
    "",
    "## Package Files",
    "",
    f"- archive: `{tarball_path.name}`",
    f"- checksum: `{sha_file.name}`",
    f"- verifier: `{verify_script.name}`",
    f"- receipt: `{Path(receipt_path).name}`",
    "",
    "## Target",
    "",
    f"- publicBaseURL: `{target.get('publicBaseURL') or ''}`",
    f"- baseURL: `{target.get('baseURL') or ''}`",
    f"- tcpHost: `{target.get('tcpHost') or ''}`",
    f"- tcpPort: `{target.get('tcpPort') or ''}`",
    f"- sshPort: `{target.get('sshPort') or ''}`",
    f"- diagnosis: `{diagnosis}`",
    f"- rescuePlanAction: `{action}`",
    "",
    "## First Command",
    "",
    "Run this from the directory containing the package files:",
    "",
    "```bash",
    f"./{verify_script.name}",
    "```",
    "",
    "## After Verification",
    "",
    "```bash",
    f"tar -xzf {tarball_path.name}",
    f"cd {tarball_path.name.removesuffix('.tar.gz')}",
    "./verify-artifact.sh",
    "cat ./entrypoint-rescue-plan.md",
    "```",
    "",
    "If the action is `cloud_console_rescue_required`, open the cloud console and",
    "paste the content printed by:",
    "",
    "```bash",
    "cat ./cloud-console-node-access-rescue.sh",
    "```",
    "",
    "After the console script reports success, verify the target from this machine:",
    "",
    "```bash",
    "SSH_PRIVATE_KEY_PATH=${SSH_PRIVATE_KEY_PATH:-<private-key-path>} ./post-rescue-verify.sh",
    "```",
    "",
    "Then resume product validation:",
    "",
    "```bash",
    "SSH_PRIVATE_KEY_PATH=${SSH_PRIVATE_KEY_PATH:-<private-key-path>} ./resume-product-validation.sh",
    "```",
    "",
    "Production readiness is not proven until the post-rescue product validation",
    "and production evidence gates pass against the target runtime.",
    "",
]
Path(readme_path).write_text("\n".join(lines), encoding="utf-8")
PY
  printf 'node_access_rescue_artifact package_sidecars=pass readme=%s receipt=%s\n' "${readme_path}" "${receipt_path}"
}

write_artifact_archive() {
  local artifact_dir="$1"
  local tarball_path="$2"
  local parent_dir base_name sha_file
  if ! bool_enabled "${NODE_ACCESS_RESCUE_ARTIFACT_PACKAGE}"; then
    printf 'node_access_rescue_artifact archive=skipped reason=disabled\n'
    return 0
  fi
  parent_dir="$(dirname "${artifact_dir}")"
  base_name="$(basename "${artifact_dir}")"
  if [[ -z "${tarball_path}" ]]; then
    tarball_path="${artifact_dir}.tar.gz"
  else
    tarball_path="$(resolve_path "${tarball_path}")"
  fi
  sha_file="${tarball_path}.sha256"
  rm -f "${tarball_path}" "${sha_file}" "${tarball_path}.verify.sh" "${tarball_path}.README.md" "${tarball_path}.receipt.json"
  (cd "${parent_dir}" && tar -czf "${tarball_path}" "${base_name}")
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "${tarball_path}")" && sha256sum "$(basename "${tarball_path}")" >"${sha_file}")
  else
    (cd "$(dirname "${tarball_path}")" && shasum -a 256 "$(basename "${tarball_path}")" >"${sha_file}")
  fi
  verify_artifact_archive "${tarball_path}"
  write_artifact_package_verify_script "${tarball_path}" "${sha_file}"
  write_artifact_package_sidecars "${artifact_dir}" "${tarball_path}" "${sha_file}" "${tarball_path}.verify.sh"
  printf 'node_access_rescue_artifact archive=pass tarball=%s sha256=%s readme=%s receipt=%s\n' "${tarball_path}" "${sha_file}" "${tarball_path}.README.md" "${tarball_path}.receipt.json"
}

verify_no_private_key() {
  local artifact_dir="$1"
  if tree_contains_regex "${artifact_dir}" 'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY|PRIVATE KEY-----|Proc-Type: 4,ENCRYPTED' "verify-artifact.sh"; then
    printf 'node_access_rescue_artifact result=fail reason=private_key_marker_detected dir=%s\n' "${artifact_dir}" >&2
    return 1
  fi
}

verify_no_sensitive_values() {
  local artifact_dir="$1"
  local value name
  for name in IM_INTERNAL_SECRET IM_INTERNAL_SHARED_SECRET SSH_PRIVATE_KEY_PATH; do
    value="${!name:-}"
    if [[ ${#value} -lt 8 ]]; then
      continue
    fi
    if tree_contains_fixed "${artifact_dir}" "${value}"; then
      printf 'node_access_rescue_artifact result=fail reason=sensitive_value_leaked name=%s dir=%s\n' "${name}" "${artifact_dir}" >&2
      return 1
    fi
  done
}

generate_artifact() {
  local artifact_dir public_key public_key_file rescue_script post_rescue_script resume_script verify_script product_root summary_file readme_file manifest_file external_probe_json external_probe_log rescue_plan_json rescue_plan_md im_tcp_status ssh_status
  artifact_dir="$(resolve_path "${NODE_ACCESS_RESCUE_ARTIFACT_DIR}")"
  product_root="${artifact_dir}/product-plan"
  public_key_file="${artifact_dir}/node-access.pub"
  rescue_script="${artifact_dir}/cloud-console-node-access-rescue.sh"
  post_rescue_script="${artifact_dir}/post-rescue-verify.sh"
  resume_script="${artifact_dir}/resume-product-validation.sh"
  verify_script="${artifact_dir}/verify-artifact.sh"
  summary_file="${artifact_dir}/summary.txt"
  manifest_file="${artifact_dir}/artifact-manifest.json"
  external_probe_json="${artifact_dir}/external-entrypoint-probe.json"
  external_probe_log="${artifact_dir}/external-entrypoint-probe.log"
  rescue_plan_json="${artifact_dir}/entrypoint-rescue-plan.json"
  rescue_plan_md="${artifact_dir}/entrypoint-rescue-plan.md"
  readme_file="${artifact_dir}/README.md"

  rm -rf "${artifact_dir}"
  mkdir -p "${artifact_dir}" "${product_root}"

  public_key="$(derive_public_key)"
  printf '%s\n' "${public_key}" >"${public_key_file}"

  RESULT_ROOT="${product_root}" \
  BASE_URL="${BASE_URL}" \
  TCP_HOST="${TCP_HOST:-$(host_from_url)}" \
  TCP_PORT="${TCP_PORT}" \
  ACCOUNT_FILE="${ACCOUNT_FILE}" \
  PRODUCT_TEST_PHASES="${PRODUCT_TEST_PHASES}" \
  PRODUCT_TEST_STOP_ON_FAILURE="${PRODUCT_TEST_STOP_ON_FAILURE}" \
  PRODUCT_TEST_RUN_FULL_PROFILE="${PRODUCT_TEST_RUN_FULL_PROFILE}" \
  PRODUCT_TEST_PLAN_JSON="${product_root}/product-test-plan-run.json" \
  PRODUCT_TEST_PLAN_PREVIEW_JSON="${product_root}/product-test-plan-preview.json" \
  PRODUCT_TEST_STATUS_TSV="${product_root}/product-test-plan-phases.tsv" \
  PRODUCT_TEST_PREREQ_PLAN_JSON="${product_root}/product-test-prereq-plan.json" \
  PRODUCT_TEST_PREREQ_AUDIT_JSON="${product_root}/product-test-prereq-audit.json" \
  PRODUCT_TEST_PREREQ_AUDIT_MD="${product_root}/product-test-prereq-audit.md" \
  PRODUCT_TEST_SCENARIO_CATALOG_JSON="${product_root}/product-test-scenario-catalog.json" \
  PRODUCT_TEST_RUNBOOK_JSON="${product_root}/product-test-runbook.json" \
  PRODUCT_TEST_RUNBOOK_MD="${product_root}/product-test-runbook.md" \
  PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT=false \
  PERF_DRY_RUN="${PERF_DRY_RUN}" \
  IM_CONVERSATION_ID="${IM_CONVERSATION_ID:-}" \
  IM_INTERNAL_SECRET="${IM_INTERNAL_SECRET:-${IM_INTERNAL_SHARED_SECRET:-}}" \
    bash "${SCRIPT_DIR}/run_product_test_plan.sh" >"${artifact_dir}/product-plan.log" 2>&1 || true

  if [[ ! -f "${product_root}/product-test-plan-run.json" ]]; then
    printf 'node_access_rescue_artifact result=fail reason=product_plan_receipt_missing path=%s\n' "${product_root}/product-test-plan-run.json" >&2
    return 1
  fi

  local verify_args=(
    "${SCRIPT_DIR}/perf_product_plan_artifacts_verify.py"
    --product-run-json "${product_root}/product-test-plan-run.json"
    --plan-preview-json "${product_root}/product-test-plan-preview.json"
    --require-prereq
  )
  if bool_enabled "${PERF_DRY_RUN}"; then
    verify_args+=(--allow-dry-run)
  fi
  python3 "${verify_args[@]}" >"${artifact_dir}/product-plan-verify.log"

  SSH_AUTHORIZED_KEY="${public_key}" \
  PUBLIC_BASE_URL="${PUBLIC_BASE_URL}" \
  HTTP_PORT="${HTTP_PORT}" \
  IM_TCP_PORT="${IM_TCP_PORT}" \
  SSH_PORT="${SSH_PORT}" \
  SSH_ALLOW_CIDR="${SSH_ALLOW_CIDR}" \
    bash "${REPO_ROOT}/deploy/ubuntu/21_render_node_access_rescue_command.sh" >"${rescue_script}"
  chmod 0600 "${rescue_script}"
  bash -n "${rescue_script}"
  write_post_rescue_verify "${post_rescue_script}"
  bash -n "${post_rescue_script}"
  write_resume_product_validation "${resume_script}" "${post_rescue_script}"
  bash -n "${resume_script}"
  write_external_entrypoint_probe "${external_probe_json}" "${external_probe_log}"
  im_tcp_status="$(probe_tcp_port "${TCP_HOST:-$(host_from_url)}" "${TCP_PORT}")"
  ssh_status="$(probe_ssh_access "${TCP_HOST:-$(host_from_url)}")"
  write_artifact_verify "${verify_script}"
  bash -n "${verify_script}"

  write_summary "${product_root}/product-test-runbook.json" "${summary_file}" "${external_probe_json}" "${im_tcp_status}" "${ssh_status}" >/dev/null
  write_entrypoint_rescue_plan "${rescue_plan_json}" "${rescue_plan_md}" "${external_probe_json}" "${summary_file}" "${rescue_script}" "${post_rescue_script}" "${resume_script}" "${verify_script}"
  write_readme "${artifact_dir}" "${public_key_file}" "${rescue_script}" "${summary_file}" "${post_rescue_script}" "${resume_script}" "${verify_script}" "${external_probe_json}" "${external_probe_log}" "${rescue_plan_json}" "${rescue_plan_md}" "${readme_file}"
  verify_no_private_key "${artifact_dir}"
  verify_no_sensitive_values "${artifact_dir}"
  write_sha256sums "${artifact_dir}"
  write_artifact_manifest "${artifact_dir}" "${manifest_file}" "${external_probe_json}" "${rescue_plan_json}" "${summary_file}"
  write_sha256sums "${artifact_dir}"
  "${verify_script}" >/dev/null
  write_artifact_archive "${artifact_dir}" "${NODE_ACCESS_RESCUE_ARTIFACT_TARBALL}"

  printf 'node_access_rescue_artifact result=pass dir=%s rescue=%s summary=%s\n' \
    "${artifact_dir}" \
    "${rescue_script}" \
    "${summary_file}"
}

run_self_test() {
  local tmpdir account_file actual_port
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  actual_port="$(default_rescue_http_port "https://im.example.test")"
  [[ "${actual_port}" == "80" ]] || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=https_default_rescue_http_port_invalid value=%s\n' "${actual_port}" >&2
    return 1
  }
  actual_port="$(default_rescue_http_port "http://im.example.test:18080")"
  [[ "${actual_port}" == "18080" ]] || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=explicit_http_port_invalid value=%s\n' "${actual_port}" >&2
    return 1
  }
  account_file="${tmpdir}/accounts.csv"
  printf 'demo001@example.com,password1234\n' >"${account_file}"
  NODE_ACCESS_RESCUE_ARTIFACT_SELF_TEST=false \
  NODE_ACCESS_RESCUE_ARTIFACT_DIR="${tmpdir}/artifact" \
  SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA-self-test node-access-self-test" \
  SSH_PRIVATE_KEY_PATH="${tmpdir}/should-not-leak/test01.pem" \
  PUBLIC_BASE_URL="http://127.0.0.1:8080" \
  BASE_URL="http://127.0.0.1:8080" \
  TCP_HOST="127.0.0.1" \
  ACCOUNT_FILE="${account_file}" \
  IM_CONVERSATION_ID="00000000-0000-4000-8000-000000000001" \
  IM_INTERNAL_SECRET="node-access-self-test-secret-should-not-leak" \
  PRODUCT_TEST_PLAN_JSON="${tmpdir}/stale/product-test-plan-run.json" \
  PRODUCT_TEST_RUNBOOK_JSON="${tmpdir}/stale/product-test-runbook.json" \
  PRODUCT_TEST_RUNBOOK_MD="${tmpdir}/stale/product-test-runbook.md" \
  PERF_DRY_RUN=true \
    bash "${BASH_SOURCE[0]}" >"${tmpdir}/self-test.log"
  grep -q 'node_access_rescue_artifact result=pass' "${tmpdir}/self-test.log" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=missing_pass_log\n' >&2
    return 1
  }
  [[ -f "${tmpdir}/artifact/product-plan/product-test-plan-run.json" ]] || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=product_plan_receipt_not_written_inside_artifact\n' >&2
    return 1
  }
  [[ ! -e "${tmpdir}/stale/product-test-plan-run.json" ]] || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=inherited_product_plan_path_not_overridden\n' >&2
    return 1
  }
  grep -q 'node_access_rescue_artifact archive=pass' "${tmpdir}/self-test.log" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=missing_archive_pass_log\n' >&2
    return 1
  }
  [[ -f "${tmpdir}/artifact.tar.gz" && -f "${tmpdir}/artifact.tar.gz.sha256" ]] || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=archive_files_missing\n' >&2
    return 1
  }
  [[ -x "${tmpdir}/artifact.tar.gz.verify.sh" ]] || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=archive_verify_script_missing\n' >&2
    return 1
  }
  [[ -f "${tmpdir}/artifact.tar.gz.README.md" && -f "${tmpdir}/artifact.tar.gz.receipt.json" ]] || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=archive_sidecars_missing\n' >&2
    return 1
  }
  grep -q './artifact.tar.gz.verify.sh' "${tmpdir}/artifact.tar.gz.README.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=archive_readme_verify_command_missing\n' >&2
    return 1
  }
  grep -q 'cloud_console_rescue_required' "${tmpdir}/artifact.tar.gz.README.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=archive_readme_rescue_action_missing\n' >&2
    return 1
  }
  cat >"${tmpdir}/local-proxy-runbook.json" <<'JSON'
{
  "status": "FAILED",
  "reason": "entrypoint_failed",
  "entrypoint": {
    "recovery": {
      "needed": true,
      "diagnosis": "cloud_edge_http_403_intercept",
      "commands": []
    }
  }
}
JSON
  cat >"${tmpdir}/local-proxy-probe.json" <<'JSON'
{
  "schemaVersion": 1,
  "failed": true,
  "diagnosis": "cloud_edge_http_403_intercept",
  "detail": "sampled ports returned empty HTTP 403",
  "tcpStatus": "http_403_intercepted",
  "edgeIntercept": "http_403_all_sampled_ports",
  "localNetworkWarning": "tun_route",
  "blocker": {
    "action": "disable_local_proxy_or_test_from_clean_network",
    "preventsPerformanceEvidence": true,
    "severity": "P0",
    "type": "entrypoint"
  },
  "signals": {
    "localNetworkWarning": "tun_route",
    "localRouteInterface": "utun8",
    "localRouteGateway": "198.18.0.1",
    "sshPortProtocol": "http_403_intercepted",
    "httpPortProtocol": "http_403_intercepted",
    "imTcpPortProtocol": "http_403_intercepted",
    "portProtocols": [
      {"label": "port-22", "port": "22", "protocol": "http_403_intercepted"}
    ]
  }
}
JSON
  write_summary \
    "${tmpdir}/local-proxy-runbook.json" \
    "${tmpdir}/local-proxy-summary.txt" \
    "${tmpdir}/local-proxy-probe.json" \
    "http_403_intercepted" \
    "http_403_intercepted" >/dev/null
  grep -q 'rescuePlanAction=disable_local_proxy_or_test_from_clean_network' "${tmpdir}/local-proxy-summary.txt" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=local_proxy_summary_action_missing\n' >&2
    return 1
  }
  write_entrypoint_rescue_plan \
    "${tmpdir}/local-proxy-plan.json" \
    "${tmpdir}/local-proxy-plan.md" \
    "${tmpdir}/local-proxy-probe.json" \
    "${tmpdir}/local-proxy-summary.txt" \
    "${tmpdir}/cloud-console-node-access-rescue.sh" \
    "${tmpdir}/post-rescue-verify.sh" \
    "${tmpdir}/resume-product-validation.sh" \
    "${tmpdir}/verify-artifact.sh"
  grep -q 'action: `disable_local_proxy_or_test_from_clean_network`' "${tmpdir}/local-proxy-plan.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=local_proxy_plan_action_missing\n' >&2
    return 1
  }
  grep -q 'localNetworkWarning: `tun_route`' "${tmpdir}/local-proxy-plan.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=local_proxy_plan_warning_missing\n' >&2
    return 1
  }
  cat >"${tmpdir}/ssh-http403-probe.json" <<'JSON'
{
  "schemaVersion": 1,
  "failed": true,
  "diagnosis": "ssh_port_http_403_intercept",
  "detail": "SSH port 22 returned HTTP 403 instead of an SSH banner",
  "tcpStatus": "open",
  "edgeIntercept": "ssh_port_http_intercepted",
  "signals": {
    "sshPortProtocol": "http_403_intercepted",
    "httpPortProtocol": "no_banner",
    "imTcpPortProtocol": "no_banner",
    "portProtocols": [
      {"label": "ssh", "port": "22", "protocol": "http_403_intercepted"},
      {"label": "http", "port": "80", "protocol": "no_banner"},
      {"label": "im-tcp", "port": "9000", "protocol": "no_banner"}
    ]
  }
}
JSON
  write_summary \
    "${tmpdir}/local-proxy-runbook.json" \
    "${tmpdir}/ssh-http403-summary.txt" \
    "${tmpdir}/ssh-http403-probe.json" \
    "open" \
    "http_403_intercepted" >/dev/null
  grep -q 'entrypointDiagnosis=ssh_port_http_403_intercept' "${tmpdir}/ssh-http403-summary.txt" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=ssh_http403_summary_diagnosis_missing\n' >&2
    return 1
  }
  grep -q 'edgeIntercept=ssh_port_http_intercepted' "${tmpdir}/ssh-http403-summary.txt" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=ssh_http403_summary_edge_intercept_missing\n' >&2
    return 1
  }
  write_entrypoint_rescue_plan \
    "${tmpdir}/ssh-http403-plan.json" \
    "${tmpdir}/ssh-http403-plan.md" \
    "${tmpdir}/ssh-http403-probe.json" \
    "${tmpdir}/ssh-http403-summary.txt" \
    "${tmpdir}/cloud-console-node-access-rescue.sh" \
    "${tmpdir}/post-rescue-verify.sh" \
    "${tmpdir}/resume-product-validation.sh" \
    "${tmpdir}/verify-artifact.sh"
  grep -q 'action: `cloud_console_rescue_required`' "${tmpdir}/ssh-http403-plan.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=ssh_http403_plan_action_missing\n' >&2
    return 1
  }
  grep -q 'SSH port 22 returned an HTTP response' "${tmpdir}/ssh-http403-plan.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=ssh_http403_plan_reason_missing\n' >&2
    return 1
  }
  grep -q 'sshPortProtocol: `http_403_intercepted`' "${tmpdir}/ssh-http403-plan.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=ssh_http403_plan_protocol_missing\n' >&2
    return 1
  }
  python3 - "${tmpdir}/artifact.tar.gz.receipt.json" "${tmpdir}/artifact.tar.gz.sha256" <<'PY'
import json
import sys
from pathlib import Path

receipt_path, sha_path = map(Path, sys.argv[1:3])
payload = json.loads(receipt_path.read_text(encoding="utf-8"))
if payload.get("schemaVersion") != 1:
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=archive_receipt_schema_missing")
package = payload.get("package") or {}
if package.get("tarball") != "artifact.tar.gz":
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=archive_receipt_tarball_mismatch")
if package.get("verifyScript") != "artifact.tar.gz.verify.sh":
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=archive_receipt_verify_script_mismatch")
expected_sha = sha_path.read_text(encoding="utf-8").split()[0]
if package.get("tarballSha256") != expected_sha:
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=archive_receipt_sha_mismatch")
if not payload.get("firstCommand", "").endswith("artifact.tar.gz.verify.sh"):
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=archive_receipt_first_command_missing")
PY
  "${tmpdir}/artifact.tar.gz.verify.sh" >"${tmpdir}/archive-verify.log"
  grep -q 'node_access_rescue_package_verify result=pass' "${tmpdir}/archive-verify.log" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=archive_verify_script_failed\n' >&2
    return 1
  }
  tampered_dir="${tmpdir}/tampered-package"
  mkdir -p "${tampered_dir}"
  cp "${tmpdir}/artifact.tar.gz" "${tmpdir}/artifact.tar.gz.sha256" "${tmpdir}/artifact.tar.gz.verify.sh" "${tampered_dir}/"
  python3 - "${tampered_dir}/artifact.tar.gz.sha256" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
name = path.read_text(encoding="utf-8").split(maxsplit=1)[1]
path.write_text("0" * 64 + "  " + name, encoding="utf-8")
PY
  if "${tampered_dir}/artifact.tar.gz.verify.sh" >"${tmpdir}/tampered-archive-verify.log" 2>&1; then
    printf 'node_access_rescue_artifact_self_test result=fail reason=tampered_archive_verify_passed\n' >&2
    return 1
  fi
  grep -Eq 'sha_file_expected_mismatch|checksum|sha256' "${tmpdir}/tampered-archive-verify.log" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=tampered_archive_verify_reason_missing\n' >&2
    return 1
  }
  replaced_dir="${tmpdir}/replaced-package"
  mkdir -p "${replaced_dir}/fake"
  printf 'not the original artifact\n' >"${replaced_dir}/fake/README.md"
  (cd "${replaced_dir}" && tar -czf artifact.tar.gz fake)
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${replaced_dir}" && sha256sum artifact.tar.gz >artifact.tar.gz.sha256)
  else
    (cd "${replaced_dir}" && shasum -a 256 artifact.tar.gz >artifact.tar.gz.sha256)
  fi
  cp "${tmpdir}/artifact.tar.gz.verify.sh" "${replaced_dir}/artifact.tar.gz.verify.sh"
  if "${replaced_dir}/artifact.tar.gz.verify.sh" >"${tmpdir}/replaced-archive-verify.log" 2>&1; then
    printf 'node_access_rescue_artifact_self_test result=fail reason=replaced_archive_verify_passed\n' >&2
    return 1
  fi
  grep -Eq 'sha_file_expected_mismatch|tarball_expected_mismatch' "${tmpdir}/replaced-archive-verify.log" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=replaced_archive_verify_reason_missing\n' >&2
    return 1
  }
  verify_artifact_archive "${tmpdir}/artifact.tar.gz"
  python3 - "${tmpdir}/unsafe-member.tar.gz" <<'PY'
import io
import sys
import tarfile

payload = b"unsafe archive member\n"
with tarfile.open(sys.argv[1], "w:gz") as archive:
    info = tarfile.TarInfo("../evil.txt")
    info.size = len(payload)
    archive.addfile(info, io.BytesIO(payload))
PY
  if verify_artifact_archive "${tmpdir}/unsafe-member.tar.gz" >"${tmpdir}/unsafe-member-archive.log" 2>&1; then
    printf 'node_access_rescue_artifact_self_test result=fail reason=unsafe_archive_member_accepted\n' >&2
    return 1
  fi
  grep -q 'reason=archive_member_path_unsafe' "${tmpdir}/unsafe-member-archive.log" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=unsafe_archive_member_reason_missing\n' >&2
    return 1
  }
  bash -n "${tmpdir}/artifact/cloud-console-node-access-rescue.sh"
  bash -n "${tmpdir}/artifact/post-rescue-verify.sh"
  bash -n "${tmpdir}/artifact/resume-product-validation.sh"
  bash -n "${tmpdir}/artifact/verify-artifact.sh"
  "${tmpdir}/artifact/verify-artifact.sh" >/dev/null
  cp -R "${tmpdir}/artifact" "${tmpdir}/unsafe-checksum-artifact"
  printf '%064d  /etc/passwd\n' 0 >>"${tmpdir}/unsafe-checksum-artifact/SHA256SUMS"
  if REPO_ROOT="${tmpdir}/missing-repo" "${tmpdir}/unsafe-checksum-artifact/verify-artifact.sh" >"${tmpdir}/unsafe-checksum-verify.log" 2>&1; then
    printf 'node_access_rescue_artifact_self_test result=fail reason=unsafe_checksum_file_accepted\n' >&2
    return 1
  fi
  grep -q 'reason=checksum_file_unsafe_path' "${tmpdir}/unsafe-checksum-verify.log" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=unsafe_checksum_file_reason_missing\n' >&2
    return 1
  }
  cp -R "${tmpdir}/artifact" "${tmpdir}/duplicate-checksum-artifact"
  head -n 1 "${tmpdir}/duplicate-checksum-artifact/SHA256SUMS" >>"${tmpdir}/duplicate-checksum-artifact/SHA256SUMS"
  if REPO_ROOT="${tmpdir}/missing-repo" "${tmpdir}/duplicate-checksum-artifact/verify-artifact.sh" >"${tmpdir}/duplicate-checksum-verify.log" 2>&1; then
    printf 'node_access_rescue_artifact_self_test result=fail reason=duplicate_checksum_file_accepted\n' >&2
    return 1
  fi
  grep -q 'reason=checksum_file_duplicate_path' "${tmpdir}/duplicate-checksum-verify.log" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=duplicate_checksum_file_reason_missing\n' >&2
    return 1
  }
  grep -q 'POST_RESCUE_VERIFY_JSON' "${tmpdir}/artifact/post-rescue-verify.sh" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=post_rescue_json_output_missing\n' >&2
    return 1
  }
  grep -q 'probe_port_protocol' "${tmpdir}/artifact/post-rescue-verify.sh" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=post_rescue_protocol_probe_missing\n' >&2
    return 1
  }
  grep -q 'cloud_edge_http_403_intercept' "${tmpdir}/artifact/post-rescue-verify.sh" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=post_rescue_cloud_edge_reason_missing\n' >&2
    return 1
  }
  grep -q 'portProtocols' "${tmpdir}/artifact/post-rescue-verify.sh" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=post_rescue_protocol_json_missing\n' >&2
    return 1
  }
  if grep -q 'http_entrypoint_probe.sh' "${tmpdir}/artifact/post-rescue-verify.sh"; then
    printf 'node_access_rescue_artifact_self_test result=fail reason=post_rescue_repo_probe_dependency_present\n' >&2
    return 1
  fi
  [[ -f "${tmpdir}/artifact/README.md" && -f "${tmpdir}/artifact/SHA256SUMS" && -f "${tmpdir}/artifact/artifact-manifest.json" && -f "${tmpdir}/artifact/post-rescue-verify.sh" && -f "${tmpdir}/artifact/resume-product-validation.sh" && -f "${tmpdir}/artifact/verify-artifact.sh" && -f "${tmpdir}/artifact/external-entrypoint-probe.json" && -f "${tmpdir}/artifact/external-entrypoint-probe.log" && -f "${tmpdir}/artifact/entrypoint-rescue-plan.json" && -f "${tmpdir}/artifact/entrypoint-rescue-plan.md" ]] || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=artifact_files_missing\n' >&2
    return 1
  }
  grep -q 'artifact-manifest.json' "${tmpdir}/artifact/README.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=manifest_readme_missing\n' >&2
    return 1
  }
  grep -q 'verify-artifact.sh' "${tmpdir}/artifact/README.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=verify_artifact_readme_missing\n' >&2
    return 1
  }
  grep -q 'falls back to a self-contained scan' "${tmpdir}/artifact/README.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=fallback_scan_readme_missing\n' >&2
    return 1
  }
  grep -q 'external entrypoint probe' "${tmpdir}/artifact/README.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=external_probe_readme_missing\n' >&2
    return 1
  }
  grep -q 'entrypoint rescue plan' "${tmpdir}/artifact/README.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=rescue_plan_readme_missing\n' >&2
    return 1
  }
  grep -q '^rescuePlanAction=' "${tmpdir}/artifact/summary.txt" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=rescue_plan_action_summary_missing\n' >&2
    return 1
  }
  grep -q '^entrypointDiagnosis=' "${tmpdir}/artifact/summary.txt" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=entrypoint_diagnosis_summary_missing\n' >&2
    return 1
  }
  grep -q '^entrypointTcpStatus=' "${tmpdir}/artifact/summary.txt" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=entrypoint_tcp_status_summary_missing\n' >&2
    return 1
  }
  grep -q '^imTcpStatus=' "${tmpdir}/artifact/summary.txt" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=im_tcp_status_summary_missing\n' >&2
    return 1
  }
  grep -q '^sshPortProtocol=' "${tmpdir}/artifact/summary.txt" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=ssh_port_protocol_summary_missing\n' >&2
    return 1
  }
  grep -q '^imTcpPortProtocol=' "${tmpdir}/artifact/summary.txt" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=im_tcp_port_protocol_summary_missing\n' >&2
    return 1
  }
  grep -q '^edgeIntercept=' "${tmpdir}/artifact/summary.txt" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=edge_intercept_summary_missing\n' >&2
    return 1
  }
  grep -q '^portProtocolCount=' "${tmpdir}/artifact/summary.txt" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=port_protocol_count_summary_missing\n' >&2
    return 1
  }
  python3 - "${tmpdir}/artifact/external-entrypoint-probe.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
if not payload.get("diagnosis"):
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=external_probe_diagnosis_missing")
if "signals" not in payload:
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=external_probe_signals_missing")
if "tcpStatus" not in payload:
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=external_probe_tcp_status_missing")
if "edgeIntercept" not in payload:
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=external_probe_edge_intercept_missing")
if not isinstance(payload.get("portProtocols"), list):
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=external_probe_port_protocols_missing")
signals = payload.get("signals") or {}
for key in ("sshPortProtocol", "httpPortProtocol", "imTcpPortProtocol"):
    if key not in signals:
        raise SystemExit(f"node_access_rescue_artifact_self_test result=fail reason=external_probe_{key}_missing")
PY
  python3 - "${tmpdir}/artifact/entrypoint-rescue-plan.json" <<'PY'
import json
import sys

path = sys.argv[1]
payload = json.load(open(path, encoding="utf-8"))
if not payload.get("action"):
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=rescue_plan_action_missing")
if not payload.get("commands"):
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=rescue_plan_commands_missing")
if not any(command.get("name") == "verify-artifact" for command in payload.get("commands", [])):
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=rescue_plan_verify_command_missing")
signals = payload.get("signals") or {}
for key in ("tcpStatus", "edgeIntercept", "portProtocolCount"):
    if key not in signals:
        raise SystemExit(f"node_access_rescue_artifact_self_test result=fail reason=rescue_plan_{key}_missing")
for command in payload.get("commands", []):
    value = command.get("command", "")
    if "/artifact/" in value:
        raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=rescue_plan_absolute_command_present")
    if command.get("name") in {"verify-artifact", "post-rescue-verify", "resume-product-validation"} and "./" not in value:
        raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=rescue_plan_relative_command_missing")
for name, value in (payload.get("artifacts") or {}).items():
    if "/artifact/" in str(value):
        raise SystemExit(f"node_access_rescue_artifact_self_test result=fail reason=rescue_plan_absolute_artifact_present name={name}")
    if not str(value).startswith("./"):
        raise SystemExit(f"node_access_rescue_artifact_self_test result=fail reason=rescue_plan_relative_artifact_missing name={name}")
PY
  python3 - "${tmpdir}/artifact/artifact-manifest.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
if payload.get("schemaVersion") != 1:
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=manifest_schema_missing")
if not payload.get("diagnosis"):
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=manifest_diagnosis_missing")
if "tcpStatus" not in payload:
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=manifest_tcp_status_missing")
if "edgeIntercept" not in payload:
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=manifest_edge_intercept_missing")
if not isinstance(payload.get("portProtocols"), list):
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=manifest_port_protocols_missing")
if not (payload.get("target") or {}).get("baseURL"):
    raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=manifest_target_missing")
files = {row.get("path") for row in payload.get("files") or []}
for expected in {"./README.md", "./verify-artifact.sh", "./cloud-console-node-access-rescue.sh"}:
    if expected not in files:
        raise SystemExit(f"node_access_rescue_artifact_self_test result=fail reason=manifest_file_missing file={expected}")
for row in payload.get("files") or []:
    value = row.get("path", "")
    if not value.startswith("./"):
        raise SystemExit("node_access_rescue_artifact_self_test result=fail reason=manifest_file_not_relative")
PY
  if grep -q "^${tmpdir}/artifact/verify-artifact.sh$" "${tmpdir}/artifact/README.md"; then
    printf 'node_access_rescue_artifact_self_test result=fail reason=readme_absolute_verify_command_present\n' >&2
    return 1
  fi
  if grep -q "${tmpdir}/artifact/cloud-console-node-access-rescue.sh" "${tmpdir}/artifact/README.md"; then
    printf 'node_access_rescue_artifact_self_test result=fail reason=readme_absolute_file_reference_present\n' >&2
    return 1
  fi
  grep -q './verify-artifact.sh' "${tmpdir}/artifact/README.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=readme_relative_verify_command_missing\n' >&2
    return 1
  }
  grep -q 'cd.*into the copied directory' "${tmpdir}/artifact/README.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=readme_cd_instruction_missing\n' >&2
    return 1
  }
  grep -q '.verify.sh' "${tmpdir}/artifact/README.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=readme_package_verify_missing\n' >&2
    return 1
  }
  grep -q 'PRODUCT_TEST_RUN_FULL_PROFILE' "${tmpdir}/artifact/resume-product-validation.sh" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=resume_full_profile_toggle_missing\n' >&2
    return 1
  }
  grep -Fq 'PRODUCT_TEST_PHASES="${PRODUCT_TEST_PHASES:-entrypoint real-world-smoke}"' "${tmpdir}/artifact/resume-product-validation.sh" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=resume_real_world_default_missing\n' >&2
    return 1
  }
  grep -q 'entrypoint real-world-smoke' "${tmpdir}/artifact/README.md" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=readme_real_world_default_missing\n' >&2
    return 1
  }
  if tree_contains_regex "${tmpdir}/artifact" '-----BEGIN '; then
    printf 'node_access_rescue_artifact_self_test result=fail reason=private_key_marker_detected\n' >&2
    return 1
  fi
  if tree_contains_fixed "${tmpdir}/artifact" 'node-access-self-test-secret-should-not-leak'; then
    printf 'node_access_rescue_artifact_self_test result=fail reason=internal_secret_leaked\n' >&2
    return 1
  fi
  if tree_contains_fixed "${tmpdir}/artifact" "${tmpdir}/should-not-leak/test01.pem"; then
    printf 'node_access_rescue_artifact_self_test result=fail reason=ssh_private_key_path_leaked\n' >&2
    return 1
  fi
  REPO_ROOT="${tmpdir}/missing-repo" "${tmpdir}/artifact/verify-artifact.sh" >"${tmpdir}/fallback-verify.log"
  grep -q 'secret_scan=fallback' "${tmpdir}/fallback-verify.log" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=fallback_secret_scan_not_used\n' >&2
    return 1
  }
  cp -R "${tmpdir}/artifact" "${tmpdir}/leaky-artifact"
  printf '{"accessToken":"raw-access-token-0123456789"}\n' >"${tmpdir}/leaky-artifact/leak.json"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${tmpdir}/leaky-artifact" && sha256sum ./leak.json >>SHA256SUMS)
  else
    (cd "${tmpdir}/leaky-artifact" && shasum -a 256 ./leak.json >>SHA256SUMS)
  fi
  if REPO_ROOT="${tmpdir}/missing-repo" "${tmpdir}/leaky-artifact/verify-artifact.sh" >"${tmpdir}/leaky-fallback-verify.log" 2>&1; then
    printf 'node_access_rescue_artifact_self_test result=fail reason=fallback_secret_scan_missed_leak\n' >&2
    return 1
  fi
  grep -q 'reason=fallback_secret_scan' "${tmpdir}/leaky-fallback-verify.log" || {
    printf 'node_access_rescue_artifact_self_test result=fail reason=fallback_secret_scan_failure_reason_missing\n' >&2
    return 1
  }
  printf 'node_access_rescue_artifact_self_test result=pass\n'
}

if bool_enabled "${NODE_ACCESS_RESCUE_ARTIFACT_SELF_TEST}"; then
  run_self_test
  exit 0
fi

generate_artifact
