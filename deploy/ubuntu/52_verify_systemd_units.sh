#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SYSTEMD_UNIT_VERIFY_SELF_TEST="${SYSTEMD_UNIT_VERIFY_SELF_TEST:-false}"
SYSTEMD_UNIT_VERIFY_REQUIRE_ROOT="${SYSTEMD_UNIT_VERIFY_REQUIRE_ROOT:-true}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

if bool_enabled "${SYSTEMD_UNIT_VERIFY_SELF_TEST}"; then
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' EXIT
  fake_bin="${self_test_dir}/bin"
  mkdir -p "${fake_bin}" "${self_test_dir}/systemd" "${self_test_dir}/etc/roles"
  cat >"${fake_bin}/systemd-analyze" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "verify" ]]
SH
  chmod +x "${fake_bin}/systemd-analyze"
  printf 'APP_ENV=production\n' >"${self_test_dir}/etc/common.env"
  for unit in imserver-gateway imserver-command-api imserver-query-api imserver-outbox-relay imserver-stream-consumer imserver-domain-delivery-consumer; do
    role="${unit#imserver-}"
    printf 'IM_NODE_ID=%s\n' "${role}" >"${self_test_dir}/etc/roles/${role}.env"
    cat >"${self_test_dir}/systemd/${unit}.service" <<EOF
[Service]
EnvironmentFile=${self_test_dir}/etc/common.env
EnvironmentFile=${self_test_dir}/etc/roles/${role}.env
ExecStart=/opt/imserver/bin/IMServer serve
Restart=always
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
LimitNOFILE=1048576
CPUAccounting=true
MemoryAccounting=true
TasksMax=65535
EOF
  done
  cat >"${self_test_dir}/systemd/imserver-stream-consumer@.service" <<EOF
[Service]
EnvironmentFile=${self_test_dir}/etc/common.env
EnvironmentFile=${self_test_dir}/etc/roles/stream-consumer-%i.env
ExecStart=/opt/imserver/bin/IMServer stream-consumer
Restart=always
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
LimitNOFILE=1048576
CPUAccounting=true
MemoryAccounting=true
TasksMax=65535
EOF
  cat >"${self_test_dir}/systemd/kafka.service" <<EOF
[Service]
User=kafka
Group=kafka
ExecStart=/opt/kafka/bin/kafka-server-start.sh /etc/kafka/kraft/server.properties
Restart=always
LimitNOFILE=262144
CPUAccounting=true
MemoryAccounting=true
TasksMax=16384
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/kafka /var/log/kafka /etc/kafka/kraft
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
EOF
  PATH="${fake_bin}:${PATH}" \
  SYSTEMD_UNIT_VERIFY_SELF_TEST=false \
  SYSTEMD_UNIT_VERIFY_REQUIRE_ROOT=false \
  SYSTEMD_UNIT_DIR="${self_test_dir}/systemd" \
    IMSERVER_ETC_DIR="${self_test_dir}/etc" \
    bash "${BASH_SOURCE[0]}" >"${self_test_dir}/pass.log"
  python3 - "${self_test_dir}/systemd/imserver-gateway.service" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("PrivateDevices=true\n", ""), encoding="utf-8")
PY
  if PATH="${fake_bin}:${PATH}" \
    SYSTEMD_UNIT_VERIFY_SELF_TEST=false \
    SYSTEMD_UNIT_VERIFY_REQUIRE_ROOT=false \
    SYSTEMD_UNIT_DIR="${self_test_dir}/systemd" \
    IMSERVER_ETC_DIR="${self_test_dir}/etc" \
      bash "${BASH_SOURCE[0]}" >"${self_test_dir}/sandbox-fail.log" 2>&1; then
    printf 'systemd-unit-verify-self-test result=fail reason=missing_private_devices_accepted\n' >&2
    exit 1
  fi
  grep -q 'missing_PrivateDevices' "${self_test_dir}/sandbox-fail.log" || {
    printf 'systemd-unit-verify-self-test result=fail reason=missing_private_devices_reason_absent\n' >&2
    cat "${self_test_dir}/sandbox-fail.log" >&2
    exit 1
  }
  printf 'PrivateDevices=true\n' >>"${self_test_dir}/systemd/imserver-gateway.service"
  python3 - "${self_test_dir}/systemd/imserver-gateway.service" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("TasksMax=65535\n", ""), encoding="utf-8")
PY
  if PATH="${fake_bin}:${PATH}" \
    SYSTEMD_UNIT_VERIFY_SELF_TEST=false \
    SYSTEMD_UNIT_VERIFY_REQUIRE_ROOT=false \
    SYSTEMD_UNIT_DIR="${self_test_dir}/systemd" \
    IMSERVER_ETC_DIR="${self_test_dir}/etc" \
      bash "${BASH_SOURCE[0]}" >"${self_test_dir}/fail.log" 2>&1; then
    printf 'systemd-unit-verify-self-test result=fail reason=missing_tasks_max_accepted\n' >&2
    exit 1
  fi
  grep -q 'missing_TasksMax' "${self_test_dir}/fail.log" || {
    printf 'systemd-unit-verify-self-test result=fail reason=missing_tasks_max_reason_absent\n' >&2
    cat "${self_test_dir}/fail.log" >&2
    exit 1
  }
  python3 - "${self_test_dir}/systemd/kafka.service" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("PrivateDevices=true\n", ""), encoding="utf-8")
PY
  if PATH="${fake_bin}:${PATH}" \
    SYSTEMD_UNIT_VERIFY_SELF_TEST=false \
    SYSTEMD_UNIT_VERIFY_REQUIRE_ROOT=false \
    SYSTEMD_UNIT_DIR="${self_test_dir}/systemd" \
    IMSERVER_ETC_DIR="${self_test_dir}/etc" \
      bash "${BASH_SOURCE[0]}" >"${self_test_dir}/kafka-fail.log" 2>&1; then
    printf 'systemd-unit-verify-self-test result=fail reason=missing_kafka_private_devices_accepted\n' >&2
    exit 1
  fi
  grep -q 'unit=kafka.service reason=missing_PrivateDevices' "${self_test_dir}/kafka-fail.log" || {
    printf 'systemd-unit-verify-self-test result=fail reason=missing_kafka_private_devices_reason_absent\n' >&2
    cat "${self_test_dir}/kafka-fail.log" >&2
    exit 1
  }
  printf 'systemd-unit-verify-self-test result=pass\n'
  exit 0
fi

if bool_enabled "${SYSTEMD_UNIT_VERIFY_REQUIRE_ROOT}"; then
  require_root
fi

common_env="${IMSERVER_ETC_DIR}/common.env"

unit_names=(
  imserver-gateway
  imserver-command-api
  imserver-query-api
  imserver-outbox-relay
  imserver-stream-consumer
  imserver-domain-delivery-consumer
)
template_unit_names=(
  imserver-stream-consumer@
)
kafka_unit_names=(
  kafka
)

failures=0

fail() {
  printf 'systemd-unit-verify result=fail unit=%s reason=%s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'systemd-unit-verify result=pass unit=%s %s\n' "$1" "${2:-}"
}

check_unit_file() {
  local unit="$1"
  local unit_file="${SYSTEMD_UNIT_DIR}/${unit}.service"
  local role_file=""

  if [[ ! -f "${unit_file}" ]]; then
    fail "${unit}" "unit_file_missing"
    return
  fi

  if ! grep -Fq "EnvironmentFile=${common_env}" "${unit_file}"; then
    fail "${unit}" "missing_common_environment_file"
  fi

  role_file="$(awk -F= -v common="${common_env}" '$1 == "EnvironmentFile" && $2 != common { print $2; exit }' "${unit_file}")"
  if [[ -z "${role_file}" ]]; then
    fail "${unit}" "missing_role_environment_file"
  elif [[ ! -f "${role_file}" ]]; then
    fail "${unit}" "role_environment_file_missing_${role_file}"
  fi

  if ! grep -Eq '^ExecStart=.*IMServer' "${unit_file}"; then
    fail "${unit}" "missing_imserver_execstart"
  fi

  local required_directives=(
    "Restart=always"
    "NoNewPrivileges=true"
    "PrivateTmp=true"
    "PrivateDevices=true"
    "ProtectHome=true"
    "ProtectSystem=full"
    "ProtectKernelTunables=true"
    "ProtectKernelModules=true"
    "ProtectControlGroups=true"
    "RestrictSUIDSGID=true"
    "RestrictRealtime=true"
    "RestrictNamespaces=true"
    "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6"
    "LockPersonality=true"
    "SystemCallArchitectures=native"
    "CapabilityBoundingSet="
    "AmbientCapabilities="
    "LimitNOFILE="
    "CPUAccounting=true"
    "MemoryAccounting=true"
    "TasksMax="
  )
  local directive
  for directive in "${required_directives[@]}"; do
    if ! grep -Fq "${directive}" "${unit_file}"; then
      fail "${unit}" "missing_${directive%%=*}"
    fi
  done

  pass "${unit}" "file=${unit_file}"
}

check_stream_consumer_template_unit_file() {
  local unit="$1"
  local unit_file="${SYSTEMD_UNIT_DIR}/${unit}.service"
  local directive

  if [[ ! -f "${unit_file}" ]]; then
    fail "${unit}" "unit_file_missing"
    return
  fi
  if ! grep -Fq "EnvironmentFile=${common_env}" "${unit_file}"; then
    fail "${unit}" "missing_common_environment_file"
  fi
  if ! grep -Fq "EnvironmentFile=${IMSERVER_ETC_DIR}/roles/stream-consumer-%i.env" "${unit_file}"; then
    fail "${unit}" "missing_instance_role_environment_file"
  fi
  if ! grep -Eq '^ExecStart=.*IMServer[[:space:]]+stream-consumer' "${unit_file}"; then
    fail "${unit}" "missing_stream_consumer_execstart"
  fi
  for directive in \
    "Restart=always" "NoNewPrivileges=true" "PrivateTmp=true" \
    "PrivateDevices=true" "ProtectHome=true" "ProtectSystem=full" \
    "ProtectKernelTunables=true" "ProtectKernelModules=true" \
    "ProtectControlGroups=true" "RestrictSUIDSGID=true" \
    "RestrictRealtime=true" "RestrictNamespaces=true" \
    "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" "LockPersonality=true" \
    "SystemCallArchitectures=native" "CapabilityBoundingSet=" \
    "AmbientCapabilities=" "LimitNOFILE=" "CPUAccounting=true" \
    "MemoryAccounting=true" "TasksMax="
  do
    if ! grep -Fq "${directive}" "${unit_file}"; then
      fail "${unit}" "missing_${directive%%=*}"
    fi
  done
  pass "${unit}" "file=${unit_file}"
}

check_kafka_unit_file() {
  local unit="$1"
  local unit_file="${SYSTEMD_UNIT_DIR}/${unit}.service"

  if [[ ! -f "${unit_file}" ]]; then
    fail "${unit}.service" "unit_file_missing"
    return
  fi

  if ! grep -Eq '^ExecStart=.*/kafka-server-start\.sh[[:space:]]+/etc/kafka/kraft/server\.properties' "${unit_file}"; then
    fail "${unit}.service" "missing_kafka_execstart"
  fi

  local required_directives=(
    "User=kafka"
    "Group=kafka"
    "Restart=always"
    "NoNewPrivileges=true"
    "PrivateTmp=true"
    "PrivateDevices=true"
    "ProtectHome=true"
    "ProtectSystem=full"
    "ReadWritePaths="
    "ProtectKernelTunables=true"
    "ProtectKernelModules=true"
    "ProtectControlGroups=true"
    "RestrictSUIDSGID=true"
    "RestrictRealtime=true"
    "RestrictNamespaces=true"
    "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6"
    "LockPersonality=true"
    "SystemCallArchitectures=native"
    "CapabilityBoundingSet="
    "AmbientCapabilities="
    "LimitNOFILE="
    "CPUAccounting=true"
    "MemoryAccounting=true"
    "TasksMax="
  )
  local directive
  for directive in "${required_directives[@]}"; do
    if ! grep -Fq "${directive}" "${unit_file}"; then
      fail "${unit}.service" "missing_${directive%%=*}"
    fi
  done

  pass "${unit}.service" "file=${unit_file}"
}

unit_files=()
for unit in "${unit_names[@]}"; do
  check_unit_file "${unit}"
  unit_files+=("${SYSTEMD_UNIT_DIR}/${unit}.service")
done
for unit in "${template_unit_names[@]}"; do
  check_stream_consumer_template_unit_file "${unit}"
  unit_files+=("${SYSTEMD_UNIT_DIR}/${unit}.service")
done
for unit in "${kafka_unit_names[@]}"; do
  check_kafka_unit_file "${unit}"
  unit_files+=("${SYSTEMD_UNIT_DIR}/${unit}.service")
done

if command -v systemd-analyze >/dev/null 2>&1; then
  if systemd-analyze verify "${unit_files[@]}" >/tmp/imserver-systemd-verify.log 2>&1; then
    pass "systemd-analyze" "verify=true"
  else
    cat /tmp/imserver-systemd-verify.log >&2 || true
    fail "systemd-analyze" "verify_failed"
  fi
else
  fail "systemd-analyze" "missing"
fi

if [[ "${failures}" != "0" ]]; then
  printf 'systemd-unit-verify result=fail failures=%s\n' "${failures}" >&2
  exit 1
fi

printf 'systemd-unit-verify result=pass units=%s\n' "${#unit_names[@]}"
