#!/usr/bin/env bash
set -euo pipefail

IMSERVER_USER="${IMSERVER_USER:-imserver}"
IMSERVER_GROUP="${IMSERVER_GROUP:-imserver}"
IMSERVER_HOME="${IMSERVER_HOME:-/opt/imserver}"
IMSERVER_BIN_DIR="${IMSERVER_BIN_DIR:-${IMSERVER_HOME}/bin}"
IMSERVER_RELEASES_DIR="${IMSERVER_RELEASES_DIR:-${IMSERVER_HOME}/releases}"
IMSERVER_CURRENT_LINK="${IMSERVER_CURRENT_LINK:-${IMSERVER_HOME}/current}"
IMSERVER_ETC_DIR="${IMSERVER_ETC_DIR:-/etc/imserver}"
IMSERVER_LOG_DIR="${IMSERVER_LOG_DIR:-/var/log/imserver}"
IMSERVER_RUN_ENV="${IMSERVER_RUN_ENV:-development}"

POSTGRES_DB="${POSTGRES_DB:-imserver}"
POSTGRES_USER="${POSTGRES_USER:-imserver}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-imserver_password_change_me}"

KAFKA_VERSION="${KAFKA_VERSION:-3.8.1}"
KAFKA_SCALA_VERSION="${KAFKA_SCALA_VERSION:-2.13}"
KAFKA_HOME="${KAFKA_HOME:-/opt/kafka}"
KAFKA_DATA_DIR="${KAFKA_DATA_DIR:-/var/lib/kafka}"
KAFKA_LOG_DIR="${KAFKA_LOG_DIR:-/var/log/kafka}"
KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS:--Xms256m -Xmx512m}"

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run this script as root, for example: sudo $0" >&2
    exit 1
  fi
}

repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${script_dir}/../.." && pwd
}

ensure_user() {
  local user="$1"
  local group="$2"
  local home="$3"

  if ! getent group "${group}" >/dev/null; then
    groupadd --system "${group}"
  fi
  if ! id "${user}" >/dev/null 2>&1; then
    useradd --system --gid "${group}" --home-dir "${home}" --create-home --shell /usr/sbin/nologin "${user}"
  fi
}

install_file_mode() {
  local src="$1"
  local dst="$2"
  local mode="$3"
  install -d "$(dirname "${dst}")"
  install -m "${mode}" "${src}" "${dst}"
}

random_secret() {
  openssl rand -hex 32
}

common_read_env_file_value() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 0
  awk -F= -v key="${key}" '
    $1 == key {
      value = substr($0, length(key) + 2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^["'\'']|["'\'']$/, "", value)
      found = value
    }
    END {
      if (found != "") {
        print found
      }
    }
  ' "${file}"
}

imserver_app_env() {
  if [[ -n "${APP_ENV:-}" ]]; then
    printf '%s\n' "${APP_ENV}"
    return 0
  fi
  local env_file="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
  local file_value
  file_value="$(common_read_env_file_value "${env_file}" "APP_ENV")"
  if [[ -n "${file_value}" ]]; then
    printf '%s\n' "${file_value}"
    return 0
  fi
  printf '%s\n' "${IMSERVER_RUN_ENV:-development}"
}

imserver_default_public_http_port() {
  case "$(imserver_app_env)" in
    production) printf '80\n' ;;
    *) printf '8080\n' ;;
  esac
}
