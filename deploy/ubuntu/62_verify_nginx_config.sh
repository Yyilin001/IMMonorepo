#!/usr/bin/env bash
set -euo pipefail

NGINX_VERIFY_SELF_TEST="${NGINX_VERIFY_SELF_TEST:-false}"
NGINX_HTTP_CONF_PATH="${NGINX_HTTP_CONF_PATH:-/etc/nginx/conf.d/imserver.conf}"
NGINX_LOCATIONS_CONF_PATH="${NGINX_LOCATIONS_CONF_PATH:-/etc/nginx/snippets/imserver_locations.conf}"
NGINX_SSL_CONF_PATH="${NGINX_SSL_CONF_PATH:-/etc/nginx/conf.d/imserver_ssl.conf}"
NGINX_VERIFY_REQUIRE_SSL="${NGINX_VERIFY_REQUIRE_SSL:-false}"
NGINX_VERIFY_RUN_NGINX_TEST="${NGINX_VERIFY_RUN_NGINX_TEST:-true}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

failures=0

fail() {
  printf 'nginx-config-verify result=fail check=%s reason=%s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'nginx-config-verify result=pass check=%s %s\n' "$1" "${2:-}"
}

require_file() {
  local path="$1"
  local label="$2"
  if [[ -f "${path}" ]]; then
    pass "${label}" "file=${path}"
  else
    fail "${label}" "file_missing path=${path}"
    return 1
  fi
}

require_contains() {
  local path="$1"
  local needle="$2"
  local check="$3"
  local reason="$4"
  if grep -Fq "${needle}" "${path}"; then
    pass "${check}" "field=${reason}"
  else
    fail "${check}" "missing_${reason}"
  fi
}

require_regex() {
  local path="$1"
  local pattern="$2"
  local check="$3"
  local reason="$4"
  if grep -Eq "${pattern}" "${path}"; then
    pass "${check}" "field=${reason}"
  else
    fail "${check}" "missing_${reason}"
  fi
}

reject_placeholders() {
  local path="$1"
  local check="$2"
  if grep -Eq '__[A-Z0-9_]+__' "${path}"; then
    fail "${check}" "unrendered_placeholder"
  else
    pass "${check}" "placeholders=none"
  fi
}

verify_http_config() {
  require_file "${NGINX_HTTP_CONF_PATH}" "nginx-http-config" || return
  reject_placeholders "${NGINX_HTTP_CONF_PATH}" "nginx-http-config"
  require_contains "${NGINX_HTTP_CONF_PATH}" "server_tokens off;" "nginx-http-config" "server_tokens_off"
  require_contains "${NGINX_HTTP_CONF_PATH}" "limit_req_zone \$binary_remote_addr zone=im_auth" "nginx-http-config" "auth_rate_zone"
  require_contains "${NGINX_HTTP_CONF_PATH}" "limit_req_zone \$binary_remote_addr zone=im_api" "nginx-http-config" "api_rate_zone"
  require_contains "${NGINX_HTTP_CONF_PATH}" "limit_conn_zone \$binary_remote_addr zone=im_conn" "nginx-http-config" "conn_zone"
  require_contains "${NGINX_HTTP_CONF_PATH}" "add_header X-Content-Type-Options \"nosniff\" always;" "nginx-http-config" "content_type_options"
  require_contains "${NGINX_HTTP_CONF_PATH}" "add_header X-Frame-Options \"DENY\" always;" "nginx-http-config" "frame_options"
  require_contains "${NGINX_HTTP_CONF_PATH}" "add_header Referrer-Policy \"no-referrer\" always;" "nginx-http-config" "referrer_policy"
  require_regex "${NGINX_HTTP_CONF_PATH}" 'client_max_body_size[[:space:]]+[^;]+;' "nginx-http-config" "client_max_body_size"
  require_regex "${NGINX_HTTP_CONF_PATH}" 'limit_conn[[:space:]]+im_conn[[:space:]]+[0-9]+;' "nginx-http-config" "connection_limit"
  require_regex "${NGINX_HTTP_CONF_PATH}" 'include[[:space:]]+.+imserver_locations\.conf;' "nginx-http-config" "locations_include"
}

verify_locations_config() {
  require_file "${NGINX_LOCATIONS_CONF_PATH}" "nginx-locations-config" || return
  reject_placeholders "${NGINX_LOCATIONS_CONF_PATH}" "nginx-locations-config"
  require_contains "${NGINX_LOCATIONS_CONF_PATH}" "location = /internal/metrics" "nginx-locations-config" "internal_metrics_location"
  require_contains "${NGINX_LOCATIONS_CONF_PATH}" "allow 127.0.0.1;" "nginx-locations-config" "internal_metrics_allow_loopback"
  require_contains "${NGINX_LOCATIONS_CONF_PATH}" "deny all;" "nginx-locations-config" "internal_metrics_deny_all"
  require_contains "${NGINX_LOCATIONS_CONF_PATH}" "limit_req zone=im_auth" "nginx-locations-config" "auth_location_rate_limit"
  require_contains "${NGINX_LOCATIONS_CONF_PATH}" "limit_req zone=im_api" "nginx-locations-config" "api_location_rate_limit"
  require_contains "${NGINX_LOCATIONS_CONF_PATH}" "proxy_pass \$im_api_upstream;" "nginx-locations-config" "im_api_method_split"
}

verify_ssl_config() {
  if [[ ! -f "${NGINX_SSL_CONF_PATH}" ]]; then
    if bool_enabled "${NGINX_VERIFY_REQUIRE_SSL}"; then
      fail "nginx-ssl-config" "file_missing path=${NGINX_SSL_CONF_PATH}"
    else
      pass "nginx-ssl-config" "skipped=true"
    fi
    return
  fi

  pass "nginx-ssl-config" "file=${NGINX_SSL_CONF_PATH}"
  reject_placeholders "${NGINX_SSL_CONF_PATH}" "nginx-ssl-config"
  require_contains "${NGINX_SSL_CONF_PATH}" "server_tokens off;" "nginx-ssl-config" "server_tokens_off"
  require_contains "${NGINX_SSL_CONF_PATH}" "ssl_session_tickets off;" "nginx-ssl-config" "ssl_session_tickets_off"
  require_contains "${NGINX_SSL_CONF_PATH}" "ssl_protocols TLSv1.2 TLSv1.3;" "nginx-ssl-config" "ssl_protocols"
  require_contains "${NGINX_SSL_CONF_PATH}" "add_header Strict-Transport-Security" "nginx-ssl-config" "hsts"
  require_contains "${NGINX_SSL_CONF_PATH}" "add_header X-Content-Type-Options \"nosniff\" always;" "nginx-ssl-config" "content_type_options"
  require_contains "${NGINX_SSL_CONF_PATH}" "add_header X-Frame-Options \"DENY\" always;" "nginx-ssl-config" "frame_options"
  require_contains "${NGINX_SSL_CONF_PATH}" "add_header Referrer-Policy \"no-referrer\" always;" "nginx-ssl-config" "referrer_policy"
  require_regex "${NGINX_SSL_CONF_PATH}" 'client_max_body_size[[:space:]]+[^;]+;' "nginx-ssl-config" "client_max_body_size"
  require_regex "${NGINX_SSL_CONF_PATH}" 'limit_conn[[:space:]]+im_conn[[:space:]]+[0-9]+;' "nginx-ssl-config" "connection_limit"
  require_regex "${NGINX_SSL_CONF_PATH}" 'include[[:space:]]+.+imserver_locations\.conf;' "nginx-ssl-config" "locations_include"
}

run_nginx_test() {
  if ! bool_enabled "${NGINX_VERIFY_RUN_NGINX_TEST}"; then
    pass "nginx-syntax" "skipped=true"
    return
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    fail "nginx-syntax" "nginx_missing"
    return
  fi
  if nginx -t >/tmp/imserver-nginx-verify.log 2>&1; then
    pass "nginx-syntax" "nginx_t=true"
  else
    fail "nginx-syntax" "$(tr '\n' ' ' </tmp/imserver-nginx-verify.log)"
  fi
}

run_self_test() {
  local self_test_dir http_conf locations_conf ssl_conf bad_locations_conf
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' RETURN
  http_conf="${self_test_dir}/imserver.conf"
  locations_conf="${self_test_dir}/imserver_locations.conf"
  ssl_conf="${self_test_dir}/imserver_ssl.conf"
  bad_locations_conf="${self_test_dir}/bad_locations.conf"

  cat >"${http_conf}" <<'EOF'
limit_req_zone $binary_remote_addr zone=im_auth:20m rate=50r/s;
limit_req_zone $binary_remote_addr zone=im_api:50m rate=1000r/s;
limit_conn_zone $binary_remote_addr zone=im_conn:20m;
server {
  server_tokens off;
  add_header X-Content-Type-Options "nosniff" always;
  add_header X-Frame-Options "DENY" always;
  add_header Referrer-Policy "no-referrer" always;
  client_max_body_size 100m;
  limit_conn im_conn 1000;
  include /tmp/imserver_locations.conf;
}
EOF
  cat >"${locations_conf}" <<'EOF'
location = /internal/metrics {
  allow 127.0.0.1;
  deny all;
}
location ^~ /api/auth/ {
  limit_req zone=im_auth burst=100 nodelay;
}
location ^~ /api/im/ {
  limit_req zone=im_api burst=2000 nodelay;
  proxy_pass $im_api_upstream;
}
EOF
  cat >"${ssl_conf}" <<'EOF'
server {
  server_tokens off;
  ssl_session_tickets off;
  ssl_protocols TLSv1.2 TLSv1.3;
  add_header Strict-Transport-Security "max-age=15552000" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header X-Frame-Options "DENY" always;
  add_header Referrer-Policy "no-referrer" always;
  client_max_body_size 100m;
  limit_conn im_conn 1000;
  include /tmp/imserver_locations.conf;
}
EOF
  NGINX_VERIFY_SELF_TEST=false \
  NGINX_VERIFY_RUN_NGINX_TEST=false \
  NGINX_VERIFY_REQUIRE_SSL=true \
  NGINX_HTTP_CONF_PATH="${http_conf}" \
  NGINX_LOCATIONS_CONF_PATH="${locations_conf}" \
  NGINX_SSL_CONF_PATH="${ssl_conf}" \
    bash "${BASH_SOURCE[0]}" >"${self_test_dir}/pass.log"

  cp "${locations_conf}" "${bad_locations_conf}"
  python3 - "${bad_locations_conf}" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("deny all;\n", ""), encoding="utf-8")
PY
  if NGINX_VERIFY_SELF_TEST=false \
    NGINX_VERIFY_RUN_NGINX_TEST=false \
    NGINX_HTTP_CONF_PATH="${http_conf}" \
    NGINX_LOCATIONS_CONF_PATH="${bad_locations_conf}" \
    NGINX_SSL_CONF_PATH="${ssl_conf}" \
      bash "${BASH_SOURCE[0]}" >"${self_test_dir}/fail.log" 2>&1; then
    printf 'nginx-config-verify-self-test result=fail reason=bad_locations_accepted\n' >&2
    return 1
  fi
  grep -q 'missing_internal_metrics_deny_all' "${self_test_dir}/fail.log" || {
    printf 'nginx-config-verify-self-test result=fail reason=bad_locations_reason_missing\n' >&2
    cat "${self_test_dir}/fail.log" >&2
    return 1
  }
  printf 'nginx-config-verify-self-test result=pass\n'
}

if bool_enabled "${NGINX_VERIFY_SELF_TEST}"; then
  run_self_test
  exit 0
fi

verify_http_config
verify_locations_config
verify_ssl_config
run_nginx_test

if [[ "${failures}" != "0" ]]; then
  printf 'nginx-config-verify result=fail failures=%s\n' "${failures}" >&2
  exit 1
fi

printf 'nginx-config-verify result=pass\n'
