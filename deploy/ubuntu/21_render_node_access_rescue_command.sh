#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
RESCUE_SCRIPT="${RESCUE_SCRIPT:-${SCRIPT_DIR}/22_node_access_rescue.sh}"
RENDER_NODE_ACCESS_RESCUE_SELF_TEST="${RENDER_NODE_ACCESS_RESCUE_SELF_TEST:-false}"

ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-root}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
SSH_ALLOW_CIDR="${SSH_ALLOW_CIDR:-0.0.0.0/0}"
HTTP_PORT="${HTTP_PORT:-${IM_PUBLIC_HTTP_PORT:-$(imserver_default_public_http_port)}}"
IM_TCP_PORT="${IM_TCP_PORT:-9000}"
GATEWAY_HTTP_PORT="${GATEWAY_HTTP_PORT:-18080}"
COMMAND_API_PORT="${COMMAND_API_PORT:-8081}"
QUERY_API_PORT="${QUERY_API_PORT:-8082}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
RESCUE_INSTALL_PACKAGES="${RESCUE_INSTALL_PACKAGES:-true}"
RESCUE_ENABLE_UFW="${RESCUE_ENABLE_UFW:-true}"
RESCUE_VERIFY_PUBLIC="${RESCUE_VERIFY_PUBLIC:-true}"

shell_quote() {
  python3 - "$1" <<'PY'
import shlex
import sys

print(shlex.quote(sys.argv[1]))
PY
}

rescue_b64() {
  if [[ ! -f "${RESCUE_SCRIPT}" ]]; then
    printf 'render_node_access_rescue result=fail reason=rescue_script_missing path=%s\n' "${RESCUE_SCRIPT}" >&2
    return 1
  fi
  base64 <"${RESCUE_SCRIPT}" | tr -d '\n'
}

emit_env_line() {
  local key="$1"
  local value="$2"
  printf '    %s=%s \\\n' "${key}" "$(shell_quote "${value}")"
}

emit_command() {
  local encoded
  encoded="$(rescue_b64)"
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

tmp_script="$(mktemp /tmp/im-node-access-rescue.XXXXXX.sh)"
cleanup() {
  rm -f "${tmp_script}"
}
trap cleanup EXIT

base64 -d >"${tmp_script}" <<'IM_NODE_ACCESS_RESCUE_B64'
EOF
  printf '%s\n' "${encoded}"
  cat <<'EOF'
IM_NODE_ACCESS_RESCUE_B64
chmod +x "${tmp_script}"

if [[ "$(id -u)" -eq 0 ]]; then
  env \
EOF
  emit_env_line "SSH_PORT" "${SSH_PORT}"
  emit_env_line "SSH_USER" "${SSH_USER}"
  emit_env_line "SSH_AUTHORIZED_KEY" "${SSH_AUTHORIZED_KEY}"
  emit_env_line "SSH_ALLOW_CIDR" "${SSH_ALLOW_CIDR}"
  emit_env_line "HTTP_PORT" "${HTTP_PORT}"
  emit_env_line "IM_TCP_PORT" "${IM_TCP_PORT}"
  emit_env_line "GATEWAY_HTTP_PORT" "${GATEWAY_HTTP_PORT}"
  emit_env_line "COMMAND_API_PORT" "${COMMAND_API_PORT}"
  emit_env_line "QUERY_API_PORT" "${QUERY_API_PORT}"
  emit_env_line "PUBLIC_BASE_URL" "${PUBLIC_BASE_URL}"
  emit_env_line "RESCUE_INSTALL_PACKAGES" "${RESCUE_INSTALL_PACKAGES}"
  emit_env_line "RESCUE_ENABLE_UFW" "${RESCUE_ENABLE_UFW}"
  emit_env_line "RESCUE_VERIFY_PUBLIC" "${RESCUE_VERIFY_PUBLIC}"
  cat <<'EOF'
    bash "${tmp_script}"
else
  sudo env \
EOF
  emit_env_line "SSH_PORT" "${SSH_PORT}"
  emit_env_line "SSH_USER" "${SSH_USER}"
  emit_env_line "SSH_AUTHORIZED_KEY" "${SSH_AUTHORIZED_KEY}"
  emit_env_line "SSH_ALLOW_CIDR" "${SSH_ALLOW_CIDR}"
  emit_env_line "HTTP_PORT" "${HTTP_PORT}"
  emit_env_line "IM_TCP_PORT" "${IM_TCP_PORT}"
  emit_env_line "GATEWAY_HTTP_PORT" "${GATEWAY_HTTP_PORT}"
  emit_env_line "COMMAND_API_PORT" "${COMMAND_API_PORT}"
  emit_env_line "QUERY_API_PORT" "${QUERY_API_PORT}"
  emit_env_line "PUBLIC_BASE_URL" "${PUBLIC_BASE_URL}"
  emit_env_line "RESCUE_INSTALL_PACKAGES" "${RESCUE_INSTALL_PACKAGES}"
  emit_env_line "RESCUE_ENABLE_UFW" "${RESCUE_ENABLE_UFW}"
  emit_env_line "RESCUE_VERIFY_PUBLIC" "${RESCUE_VERIFY_PUBLIC}"
  cat <<'EOF'
    bash "${tmp_script}"
fi
EOF
}

run_self_test() {
  local tmpdir command_file decoded_file expected_sha decoded_sha prod_env actual
  tmpdir="$(mktemp -d)"
  prod_env="${tmpdir}/production.env"
  printf 'APP_ENV=production\n' >"${prod_env}"
  actual="$(ENV_FILE="${prod_env}" APP_ENV= IMSERVER_RUN_ENV=development imserver_default_public_http_port)"
  [[ "${actual}" == "80" ]] || {
    printf 'render_node_access_rescue_self_test result=fail reason=production_default_http_port_invalid value=%s\n' "${actual}" >&2
    rm -rf "${tmpdir}"
    return 1
  }
  command_file="${tmpdir}/rescue-command.sh"
  decoded_file="${tmpdir}/decoded.sh"
  PUBLIC_BASE_URL="http://example.test:8080" \
  SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA-test comment" \
    emit_command >"${command_file}"
  python3 - "${command_file}" "${decoded_file}" <<'PY'
import base64
import pathlib
import sys

command_path, output_path = map(pathlib.Path, sys.argv[1:3])
capture = False
chunks = []
for line in command_path.read_text(encoding="utf-8").splitlines():
    if "<<'IM_NODE_ACCESS_RESCUE_B64'" in line:
        capture = True
        continue
    if capture and line == "IM_NODE_ACCESS_RESCUE_B64":
        capture = False
        continue
    if capture:
        chunks.append(line.strip())
pathlib.Path(output_path).write_bytes(base64.b64decode("".join(chunks)))
PY
  expected_sha="$(python3 - "${RESCUE_SCRIPT}" <<'PY'
import hashlib
import pathlib
import sys

print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
  decoded_sha="$(python3 - "${decoded_file}" <<'PY'
import hashlib
import pathlib
import sys

print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
  if [[ "${expected_sha}" != "${decoded_sha}" ]]; then
    printf 'render_node_access_rescue_self_test result=fail reason=decoded_sha_mismatch\n' >&2
    rm -rf "${tmpdir}"
    return 1
  fi
  grep -q 'PUBLIC_BASE_URL=http://example.test:8080' "${command_file}" || {
    printf 'render_node_access_rescue_self_test result=fail reason=public_base_url_missing\n' >&2
    rm -rf "${tmpdir}"
    return 1
  }
  grep -q "SSH_AUTHORIZED_KEY='ssh-ed25519 AAAA-test comment'" "${command_file}" || {
    printf 'render_node_access_rescue_self_test result=fail reason=authorized_key_not_quoted\n' >&2
    rm -rf "${tmpdir}"
    return 1
  }
  rm -rf "${tmpdir}"
  printf 'render_node_access_rescue_self_test result=pass\n'
}

if [[ "${RENDER_NODE_ACCESS_RESCUE_SELF_TEST}" == "true" || "${RENDER_NODE_ACCESS_RESCUE_SELF_TEST}" == "1" ]]; then
  run_self_test
  exit 0
fi

emit_command
