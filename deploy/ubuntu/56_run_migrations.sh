#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
ROLE_ENV_FILE="${ROLE_ENV_FILE:-${IMSERVER_ETC_DIR}/roles/ops.env}"
MIGRATION_TIMEOUT_SECONDS="${MIGRATION_TIMEOUT_SECONDS:-600}"
MIGRATION_NODE_ID="${MIGRATION_NODE_ID:-ops-migration}"
IMSERVER_BINARY="${IMSERVER_BINARY:-${IMSERVER_BIN_DIR}/IMServer}"

if [[ ! -r "${ENV_FILE}" ]]; then
  echo "Migration environment file is not readable: ${ENV_FILE}" >&2
  exit 1
fi

if [[ ! -x "${IMSERVER_BINARY}" ]]; then
  echo "IMServer binary is not executable: ${IMSERVER_BINARY}" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
if [[ -r "${ROLE_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ROLE_ENV_FILE}"
fi
set +a

export IM_RUNTIME_ROLE=ops
export IM_AUTO_MIGRATE_ON_START=true
export IM_NODE_ID="${IM_NODE_ID:-${MIGRATION_NODE_ID}}"

printf 'migration gate starting binary=%s env=%s roleEnv=%s timeoutSeconds=%s nodeID=%s\n' \
  "${IMSERVER_BINARY}" \
  "${ENV_FILE}" \
  "$([[ -r "${ROLE_ENV_FILE}" ]] && printf '%s' "${ROLE_ENV_FILE}" || printf '<none>')" \
  "${MIGRATION_TIMEOUT_SECONDS}" \
  "${IM_NODE_ID}"

if command -v timeout >/dev/null 2>&1; then
  timeout "${MIGRATION_TIMEOUT_SECONDS}" "${IMSERVER_BINARY}" ops
else
  echo "timeout command not found; running migration without a process timeout." >&2
  "${IMSERVER_BINARY}" ops
fi

printf 'migration gate result=pass binary=%s\n' "${IMSERVER_BINARY}"
