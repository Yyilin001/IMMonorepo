#!/usr/bin/env bash
set -euo pipefail

# Self-contained emergency script for cloud console / rescue shell use.
# It intentionally does not source deploy/ubuntu/common.sh, so it can be copied
# to a host even when the repository checkout is missing or stale.

NODE_ACCESS_RESCUE_SELF_TEST="${NODE_ACCESS_RESCUE_SELF_TEST:-false}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-root}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
SSH_ALLOW_CIDR="${SSH_ALLOW_CIDR:-0.0.0.0/0}"
IMSERVER_ETC_DIR="${IMSERVER_ETC_DIR:-/etc/imserver}"
IMSERVER_RUN_ENV="${IMSERVER_RUN_ENV:-development}"
ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"

read_env_file_value() {
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

rescue_app_env() {
  if [[ -n "${APP_ENV:-}" ]]; then
    printf '%s\n' "${APP_ENV}"
    return 0
  fi
  local file_value
  file_value="$(read_env_file_value "${ENV_FILE}" "APP_ENV")"
  if [[ -n "${file_value}" ]]; then
    printf '%s\n' "${file_value}"
    return 0
  fi
  printf '%s\n' "${IMSERVER_RUN_ENV}"
}

default_public_http_port() {
  case "$(rescue_app_env)" in
    production) printf '80\n' ;;
    *) printf '8080\n' ;;
  esac
}

HTTP_PORT="${HTTP_PORT:-${IM_PUBLIC_HTTP_PORT:-$(default_public_http_port)}}"
IM_TCP_PORT="${IM_TCP_PORT:-${TCP_PORT:-9000}}"
GATEWAY_HTTP_PORT="${GATEWAY_HTTP_PORT:-${IM_GATEWAY_HTTP_PORT:-18080}}"
COMMAND_API_PORT="${COMMAND_API_PORT:-${IM_COMMAND_API_PORT:-8081}}"
QUERY_API_PORT="${QUERY_API_PORT:-${IM_QUERY_API_PORT:-8082}}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
RESCUE_REPORT="${RESCUE_REPORT:-/var/log/imserver/node-access-rescue.log}"
RESCUE_INSTALL_PACKAGES="${RESCUE_INSTALL_PACKAGES:-true}"
RESCUE_ENABLE_UFW="${RESCUE_ENABLE_UFW:-true}"
RESCUE_VERIFY_PUBLIC="${RESCUE_VERIFY_PUBLIC:-true}"
RESCUE_TIMEOUT_SECONDS="${RESCUE_TIMEOUT_SECONDS:-5}"
PUBLIC_PROTOCOL_PORTS="${PUBLIC_PROTOCOL_PORTS:-${SSH_PORT} ${HTTP_PORT} ${IM_TCP_PORT}}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root, for example: sudo $0" >&2
    exit 1
  fi
}

write_sshd_config() {
  cat <<EOF
Port ${SSH_PORT}
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin prohibit-password
AuthorizedKeysFile .ssh/authorized_keys
KbdInteractiveAuthentication no
UsePAM yes
EOF
}

write_nginx_locations() {
  cat <<EOF
location = /nginx-health {
    access_log off;
    default_type text/plain;
    return 200 "nginx ok\n";
}

location = /health {
    proxy_pass http://127.0.0.1:${GATEWAY_HTTP_PORT}/health;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}

location = /internal/metrics {
    allow 127.0.0.1;
    deny all;
    proxy_pass http://127.0.0.1:${GATEWAY_HTTP_PORT}/internal/metrics;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}

location ^~ /api/auth/ {
    proxy_pass http://127.0.0.1:${GATEWAY_HTTP_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}

location ^~ /api/im/ {
    proxy_pass \$im_api_upstream;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}

location ^~ /api/ {
    proxy_pass http://127.0.0.1:${COMMAND_API_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}

location / {
    proxy_pass http://127.0.0.1:${GATEWAY_HTTP_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF
}

write_nginx_conf() {
  cat <<EOF
map \$request_method \$im_api_upstream {
    default http://127.0.0.1:${COMMAND_API_PORT};
    GET     http://127.0.0.1:${QUERY_API_PORT};
    HEAD    http://127.0.0.1:${QUERY_API_PORT};
}

server {
    listen ${HTTP_PORT} default_server;
    listen [::]:${HTTP_PORT} default_server;
    server_name _;

    server_tokens off;
    access_log /var/log/nginx/imserver_access.log;
    error_log /var/log/nginx/imserver_error.log warn;

    client_max_body_size 100m;
    proxy_http_version 1.1;
    proxy_connect_timeout 5s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
    proxy_buffering off;

    include /etc/nginx/snippets/imserver_locations.conf;
}
EOF
}

service_name_for_ssh() {
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    printf 'ssh\n'
  else
    printf 'sshd\n'
  fi
}

http_status() {
  local url="$1"
  local body_file status rc=0 size
  body_file="$(mktemp)"
  status="$(curl -sS --connect-timeout "${RESCUE_TIMEOUT_SECONDS}" --max-time "${RESCUE_TIMEOUT_SECONDS}" -o "${body_file}" -w '%{http_code}' "${url}" 2>/dev/null)" || rc=$?
  size="$(wc -c <"${body_file}" 2>/dev/null | tr -d ' ' || printf '0')"
  rm -f "${body_file}"
  if [[ "${rc}" != "0" ]]; then
    printf 'curl-error:%s %s\n' "${rc}" "${size:-0}"
  else
    printf '%s %s\n' "${status:-000}" "${size:-0}"
  fi
}

url_host() {
  python3 - "$1" <<'PY'
from urllib.parse import urlparse
import sys

print(urlparse(sys.argv[1]).hostname or "")
PY
}

classify_protocol_banner() {
  local raw="$1"
  local compact
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

probe_port_protocol() {
  local host="$1"
  local port="$2"
  local raw
  if [[ -z "${host}" || -z "${port}" ]]; then
    printf 'skipped_missing_target\n'
    return 0
  fi
  if ! command -v nc >/dev/null 2>&1; then
    printf 'skipped_nc_missing\n'
    return 0
  fi
  raw="$(printf '' | nc -w "${RESCUE_TIMEOUT_SECONDS}" "${host}" "${port}" 2>/dev/null | LC_ALL=C head -c 160 || true)"
  classify_protocol_banner "${raw}"
}

print_local_protocol_probes() {
  local protocol
  protocol="$(probe_port_protocol "127.0.0.1" "${SSH_PORT}")"
  echo "probe=local-protocol host=127.0.0.1 port=${SSH_PORT} protocol=${protocol} expected=ssh_banner"
  protocol="$(probe_port_protocol "127.0.0.1" "${HTTP_PORT}")"
  echo "probe=local-protocol host=127.0.0.1 port=${HTTP_PORT} protocol=${protocol} expected=http_or_no_banner"
  protocol="$(probe_port_protocol "127.0.0.1" "${IM_TCP_PORT}")"
  echo "probe=local-protocol host=127.0.0.1 port=${IM_TCP_PORT} protocol=${protocol} expected=tcp_open_or_no_banner"
}

print_public_protocol_probes() {
  local host port protocol seen_ports=""
  if [[ -z "${PUBLIC_BASE_URL}" ]]; then
    return 0
  fi
  host="$(url_host "${PUBLIC_BASE_URL}")"
  if [[ -z "${host}" ]]; then
    echo "probe=public-protocol host=<none> status=skipped_missing_host publicBaseURL=${PUBLIC_BASE_URL}"
    return 0
  fi
  for port in ${PUBLIC_PROTOCOL_PORTS}; do
    if [[ -z "${port}" || " ${seen_ports} " == *" ${port} "* ]]; then
      continue
    fi
    seen_ports="${seen_ports} ${port}"
    protocol="$(probe_port_protocol "${host}" "${port}")"
    echo "probe=public-protocol host=${host} port=${port} protocol=${protocol}"
  done
}

install_authorized_key() {
  local user="$1"
  local key="$2"
  local home group ssh_dir authorized_keys
  [[ -n "${key//[[:space:]]/}" ]] || return 0
  home="$(getent passwd "${user}" | awk -F: '{ print $6; exit }')"
  group="$(id -gn "${user}")"
  ssh_dir="${home}/.ssh"
  authorized_keys="${ssh_dir}/authorized_keys"
  install -d -m 0700 -o "${user}" -g "${group}" "${ssh_dir}"
  touch "${authorized_keys}"
  chown "${user}:${group}" "${authorized_keys}"
  chmod 0600 "${authorized_keys}"
  grep -qxF "${key}" "${authorized_keys}" || printf '%s\n' "${key}" >>"${authorized_keys}"
}

ufw_allow_tcp() {
  local cidr="$1"
  local port="$2"
  local comment="$3"
  command -v ufw >/dev/null 2>&1 || return 0
  if [[ "${cidr}" == "any" || "${cidr}" == "0.0.0.0/0" ]]; then
    ufw allow "${port}/tcp" comment "${comment}"
  else
    ufw allow from "${cidr}" to any port "${port}" proto tcp comment "${comment}"
  fi
}

run_self_test() {
  local sshd nginx locations tmpdir prod_env actual
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  prod_env="${tmpdir}/production.env"
  printf 'APP_ENV=production\n' >"${prod_env}"
  actual="$(ENV_FILE="${prod_env}" APP_ENV= IMSERVER_RUN_ENV=development default_public_http_port)"
  [[ "${actual}" == "80" ]] || { echo "node_access_rescue_self_test result=fail reason=production_default_http_port value=${actual}"; return 1; }
  actual="$(ENV_FILE="${tmpdir}/missing.env" APP_ENV= IMSERVER_RUN_ENV=development default_public_http_port)"
  [[ "${actual}" == "8080" ]] || { echo "node_access_rescue_self_test result=fail reason=development_default_http_port value=${actual}"; return 1; }
  sshd="$(SSH_PORT=2222 write_sshd_config)"
  nginx="$(HTTP_PORT=8088 GATEWAY_HTTP_PORT=18080 COMMAND_API_PORT=8081 QUERY_API_PORT=8082 write_nginx_conf)"
  locations="$(GATEWAY_HTTP_PORT=18080 COMMAND_API_PORT=8081 QUERY_API_PORT=8082 write_nginx_locations)"
  grep -q '^Port 2222$' <<<"${sshd}" || { echo "node_access_rescue_self_test result=fail reason=ssh_port"; return 1; }
  grep -q 'listen 8088 default_server;' <<<"${nginx}" || { echo "node_access_rescue_self_test result=fail reason=nginx_port"; return 1; }
  grep -q 'location = /nginx-health' <<<"${locations}" || { echo "node_access_rescue_self_test result=fail reason=nginx_health"; return 1; }
  grep -q 'proxy_pass http://127.0.0.1:18080/health;' <<<"${locations}" || { echo "node_access_rescue_self_test result=fail reason=health_proxy"; return 1; }
  [[ "$(classify_protocol_banner $'SSH-2.0-OpenSSH_9.6\r\n')" == "ssh_banner" ]] || { echo "node_access_rescue_self_test result=fail reason=ssh_protocol_classification"; return 1; }
  [[ "$(classify_protocol_banner $'HTTP/1.1 403 Forbidden\r\n\r\n')" == "http_403_intercepted" ]] || { echo "node_access_rescue_self_test result=fail reason=http_403_protocol_classification"; return 1; }
  [[ "$(classify_protocol_banner $'HTTP/1.1 200 OK\r\n\r\n')" == "http_intercepted" ]] || { echo "node_access_rescue_self_test result=fail reason=http_protocol_classification"; return 1; }
  [[ "$(classify_protocol_banner "")" == "no_banner" ]] || { echo "node_access_rescue_self_test result=fail reason=empty_protocol_classification"; return 1; }
  echo "node_access_rescue_self_test result=pass"
}

if bool_enabled "${NODE_ACCESS_RESCUE_SELF_TEST}"; then
  run_self_test
  exit 0
fi

require_root
install -d -m 0755 "$(dirname "${RESCUE_REPORT}")"
{
  echo "node_access_rescue startedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ) sshPort=${SSH_PORT} httpPort=${HTTP_PORT} tcpPort=${IM_TCP_PORT} publicBaseURL=${PUBLIC_BASE_URL:-<unset>}"

  if bool_enabled "${RESCUE_INSTALL_PACKAGES}"; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y openssh-server nginx curl ufw netcat-openbsd
  fi

  install -d -m 0755 /etc/ssh/sshd_config.d
  write_sshd_config >/etc/ssh/sshd_config.d/99-imserver-access.conf
  chmod 0644 /etc/ssh/sshd_config.d/99-imserver-access.conf
  sshd -t
  install_authorized_key "${SSH_USER}" "${SSH_AUTHORIZED_KEY}"
  ssh_service="$(service_name_for_ssh)"
  systemctl enable --now "${ssh_service}"
  systemctl restart "${ssh_service}"

  install -d -m 0755 /etc/nginx/snippets
  write_nginx_locations >/etc/nginx/snippets/imserver_locations.conf
  write_nginx_conf >/etc/nginx/conf.d/imserver.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx

  if bool_enabled "${RESCUE_ENABLE_UFW}"; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw_allow_tcp "${SSH_ALLOW_CIDR}" "${SSH_PORT}" "ssh"
    ufw_allow_tcp "0.0.0.0/0" "${HTTP_PORT}" "imserver-http"
    ufw_allow_tcp "0.0.0.0/0" "${IM_TCP_PORT}" "imserver-tcp"
    ufw --force enable
  fi

  local_nginx="$(http_status "http://127.0.0.1:${HTTP_PORT}/nginx-health")"
  local_health="$(http_status "http://127.0.0.1:${HTTP_PORT}/health")"
  echo "probe=local-nginx-health status=${local_nginx% *} bodyBytes=${local_nginx#* }"
  echo "probe=local-health status=${local_health% *} bodyBytes=${local_health#* }"
  print_local_protocol_probes

  if [[ -n "${PUBLIC_BASE_URL}" ]] && bool_enabled "${RESCUE_VERIFY_PUBLIC}"; then
    public_nginx="$(http_status "${PUBLIC_BASE_URL%/}/nginx-health")"
    public_health="$(http_status "${PUBLIC_BASE_URL%/}/health")"
    echo "probe=public-nginx-health status=${public_nginx% *} bodyBytes=${public_nginx#* }"
    echo "probe=public-health status=${public_health% *} bodyBytes=${public_health#* }"
    print_public_protocol_probes
  fi

  echo "node_access_rescue result=pass report=${RESCUE_REPORT}"
} 2>&1 | tee "${RESCUE_REPORT}"
