#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

NODE_ACCESS_REPAIR_SELF_TEST="${NODE_ACCESS_REPAIR_SELF_TEST:-false}"
NODE_ACCESS_REPAIR_REPORT="${NODE_ACCESS_REPAIR_REPORT:-/var/log/imserver/node-access-repair.log}"
NODE_ACCESS_REPAIR_SSH="${NODE_ACCESS_REPAIR_SSH:-true}"
NODE_ACCESS_REPAIR_HTTP="${NODE_ACCESS_REPAIR_HTTP:-true}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

write_report_header() {
  install -d -m 0755 "$(dirname "${NODE_ACCESS_REPAIR_REPORT}")"
  {
    printf 'node_access_repair startedAt=%s ssh=%s http=%s sshPort=%s publicBaseURL=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "${NODE_ACCESS_REPAIR_SSH}" \
      "${NODE_ACCESS_REPAIR_HTTP}" \
      "${SSH_PORT:-22}" \
      "${PUBLIC_BASE_URL:-${IM_PUBLIC_BASE_URL:-<unset>}}"
  } | tee "${NODE_ACCESS_REPAIR_REPORT}"
}

append_report() {
  tee -a "${NODE_ACCESS_REPAIR_REPORT}"
}

run_step() {
  local name="$1"
  shift
  printf '\n==> %s\n' "${name}" | append_report
  if "$@" 2>&1 | append_report; then
    printf 'node_access_repair step=%s result=pass\n' "${name}" | append_report
    return 0
  fi
  printf 'node_access_repair step=%s result=fail\n' "${name}" | append_report
  return 1
}

run_self_test() {
  local tmpdir fake_script
  tmpdir="$(mktemp -d)"
  mkdir -p "${tmpdir}/deploy/ubuntu"
  fake_script="${tmpdir}/deploy/ubuntu/23_repair_node_access.sh"
  cp "${BASH_SOURCE[0]}" "${fake_script}"
  cat >"${tmpdir}/deploy/ubuntu/common.sh" <<'SH'
#!/usr/bin/env bash
require_root() { return 0; }
SH
  cat >"${tmpdir}/deploy/ubuntu/24_repair_ssh_access.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake ssh repair\n'
SH
  cat >"${tmpdir}/deploy/ubuntu/64_repair_http_entrypoint.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake http repair\n'
SH
  chmod +x "${tmpdir}/deploy/ubuntu/"*.sh
  NODE_ACCESS_REPAIR_SELF_TEST=false \
  NODE_ACCESS_REPAIR_REPORT="${tmpdir}/node-access.log" \
  bash "${fake_script}" >/dev/null
  grep -q 'step=ssh-access result=pass' "${tmpdir}/node-access.log" || {
    printf 'node_access_repair_self_test result=fail reason=ssh_step_missing\n' >&2
    rm -rf "${tmpdir}"
    return 1
  }
  grep -q 'step=http-entrypoint result=pass' "${tmpdir}/node-access.log" || {
    printf 'node_access_repair_self_test result=fail reason=http_step_missing\n' >&2
    rm -rf "${tmpdir}"
    return 1
  }
  rm -rf "${tmpdir}"
  printf 'node_access_repair_self_test result=pass\n'
}

if bool_enabled "${NODE_ACCESS_REPAIR_SELF_TEST}"; then
  run_self_test
  exit 0
fi

require_root
write_report_header

if bool_enabled "${NODE_ACCESS_REPAIR_SSH}"; then
  run_step "ssh-access" bash "${SCRIPT_DIR}/24_repair_ssh_access.sh"
else
  printf 'node_access_repair step=ssh-access result=skipped reason=disabled\n' | append_report
fi

if bool_enabled "${NODE_ACCESS_REPAIR_HTTP}"; then
  run_step "http-entrypoint" bash "${SCRIPT_DIR}/64_repair_http_entrypoint.sh"
else
  printf 'node_access_repair step=http-entrypoint result=skipped reason=disabled\n' | append_report
fi

printf '\nnode_access_repair result=pass report=%s\n' "${NODE_ACCESS_REPAIR_REPORT}" | append_report
