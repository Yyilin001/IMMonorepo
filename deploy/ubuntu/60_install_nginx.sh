#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"

IM_PUBLIC_HTTP_PORT="${IM_PUBLIC_HTTP_PORT:-${HTTP_PORT:-$(imserver_default_public_http_port)}}"
IM_GATEWAY_HTTP_PORT="${IM_GATEWAY_HTTP_PORT:-18080}"
IM_COMMAND_API_PORT="${IM_COMMAND_API_PORT:-8081}"
IM_QUERY_API_PORT="${IM_QUERY_API_PORT:-8082}"
NGINX_SERVER_NAME="${NGINX_SERVER_NAME:-_}"
NGINX_DISABLE_DEFAULT_SITE="${NGINX_DISABLE_DEFAULT_SITE:-true}"
NGINX_SNIPPET_DIR="${NGINX_SNIPPET_DIR:-/etc/nginx/snippets}"
NGINX_HTTP_CONF_PATH="${NGINX_HTTP_CONF_PATH:-/etc/nginx/conf.d/imserver.conf}"
NGINX_DEFAULT_SITE_PATH="${NGINX_DEFAULT_SITE_PATH:-/etc/nginx/sites-enabled/default}"
NGINX_CLIENT_MAX_BODY_SIZE="${NGINX_CLIENT_MAX_BODY_SIZE:-100m}"
NGINX_AUTH_RATE_LIMIT="${NGINX_AUTH_RATE_LIMIT:-50r/s}"
NGINX_AUTH_RATE_BURST="${NGINX_AUTH_RATE_BURST:-100}"
NGINX_API_RATE_LIMIT="${NGINX_API_RATE_LIMIT:-1000r/s}"
NGINX_API_RATE_BURST="${NGINX_API_RATE_BURST:-2000}"
NGINX_CONNECTION_LIMIT="${NGINX_CONNECTION_LIMIT:-1000}"
NGINX_INSTALL_SELF_TEST="${NGINX_INSTALL_SELF_TEST:-false}"
NGINX_INSTALL_REQUIRE_ROOT="${NGINX_INSTALL_REQUIRE_ROOT:-true}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

tmp_conf="$(mktemp)"
tmp_locations="$(mktemp)"
cleanup() {
  rm -f "${tmp_conf}" "${tmp_locations}"
}
trap cleanup EXIT

render_template() {
  local src="$1"
  local dst="$2"
  sed \
  -e "s/__HTTP_PORT__/${IM_PUBLIC_HTTP_PORT}/g" \
  -e "s/__GATEWAY_HTTP_PORT__/${IM_GATEWAY_HTTP_PORT}/g" \
  -e "s/__COMMAND_API_PORT__/${IM_COMMAND_API_PORT}/g" \
  -e "s/__QUERY_API_PORT__/${IM_QUERY_API_PORT}/g" \
  -e "s/__SERVER_NAME__/${NGINX_SERVER_NAME}/g" \
  -e "s#__SNIPPET_DIR__#${NGINX_SNIPPET_DIR}#g" \
  -e "s/__CLIENT_MAX_BODY_SIZE__/${NGINX_CLIENT_MAX_BODY_SIZE}/g" \
  -e "s#__AUTH_RATE_LIMIT__#${NGINX_AUTH_RATE_LIMIT}#g" \
  -e "s/__AUTH_RATE_BURST__/${NGINX_AUTH_RATE_BURST}/g" \
  -e "s#__API_RATE_LIMIT__#${NGINX_API_RATE_LIMIT}#g" \
  -e "s/__API_RATE_BURST__/${NGINX_API_RATE_BURST}/g" \
  -e "s/__CONNECTION_LIMIT__/${NGINX_CONNECTION_LIMIT}/g" \
    "${src}" > "${dst}"
}

run_self_test() {
  local self_test_dir fake_bin prod_env actual
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' RETURN
  prod_env="${self_test_dir}/production.env"
  printf 'APP_ENV=production\n' >"${prod_env}"
  actual="$(ENV_FILE="${prod_env}" APP_ENV= IMSERVER_RUN_ENV=development imserver_default_public_http_port)"
  [[ "${actual}" == "80" ]] || {
    printf 'nginx-install-self-test result=fail reason=production_default_http_port_invalid value=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(ENV_FILE="${self_test_dir}/missing.env" APP_ENV= IMSERVER_RUN_ENV=development imserver_default_public_http_port)"
  [[ "${actual}" == "8080" ]] || {
    printf 'nginx-install-self-test result=fail reason=development_default_http_port_invalid value=%s\n' "${actual}" >&2
    return 1
  }
  fake_bin="${self_test_dir}/bin"
  mkdir -p "${fake_bin}" "${self_test_dir}/nginx/snippets" "${self_test_dir}/nginx/conf.d" "${self_test_dir}/nginx/sites-enabled"
  cat >"${fake_bin}/nginx" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-t" ]]
EOF
  cat >"${fake_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"http://127.0.0.1:18088/nginx-health"*) exit 0 ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "${fake_bin}/nginx" "${fake_bin}/systemctl" "${fake_bin}/curl"
  PATH="${fake_bin}:${PATH}" \
  NGINX_INSTALL_SELF_TEST=false \
  NGINX_INSTALL_REQUIRE_ROOT=false \
  IM_PUBLIC_HTTP_PORT=18088 \
  IM_GATEWAY_HTTP_PORT=18080 \
  IM_COMMAND_API_PORT=18081 \
  IM_QUERY_API_PORT=18082 \
  NGINX_SERVER_NAME=im.example.test \
  NGINX_SNIPPET_DIR="${self_test_dir}/nginx/snippets" \
  NGINX_HTTP_CONF_PATH="${self_test_dir}/nginx/conf.d/imserver.conf" \
  NGINX_SSL_CONF_PATH="${self_test_dir}/nginx/conf.d/imserver_ssl.conf" \
  NGINX_DEFAULT_SITE_PATH="${self_test_dir}/nginx/sites-enabled/default" \
    bash "${BASH_SOURCE[0]}" >"${self_test_dir}/install.log"

  grep -q 'limit_req_zone .*zone=im_auth' "${self_test_dir}/nginx/conf.d/imserver.conf" || {
    printf 'nginx-install-self-test result=fail reason=auth_rate_zone_missing\n' >&2
    return 1
  }
  grep -q 'add_header X-Content-Type-Options "nosniff" always;' "${self_test_dir}/nginx/conf.d/imserver.conf" || {
    printf 'nginx-install-self-test result=fail reason=security_header_missing\n' >&2
    return 1
  }
  grep -q 'limit_req zone=im_auth burst=100 nodelay;' "${self_test_dir}/nginx/snippets/imserver_locations.conf" || {
    printf 'nginx-install-self-test result=fail reason=auth_location_limit_missing\n' >&2
    return 1
  }
  grep -q 'allow 127.0.0.1;' "${self_test_dir}/nginx/snippets/imserver_locations.conf" || {
    printf 'nginx-install-self-test result=fail reason=internal_metrics_allow_missing\n' >&2
    return 1
  }
  grep -q 'deny all;' "${self_test_dir}/nginx/snippets/imserver_locations.conf" || {
    printf 'nginx-install-self-test result=fail reason=internal_metrics_deny_missing\n' >&2
    return 1
  }
  printf 'nginx-install-self-test result=pass\n'
}

if bool_enabled "${NGINX_INSTALL_SELF_TEST}"; then
  run_self_test
  exit 0
fi

if bool_enabled "${NGINX_INSTALL_REQUIRE_ROOT}"; then
  require_root
fi

render_template "${SCRIPT_DIR}/nginx/imserver.conf" "${tmp_conf}"
render_template "${SCRIPT_DIR}/nginx/imserver_locations.conf" "${tmp_locations}"

if bool_enabled "${NGINX_DISABLE_DEFAULT_SITE}"; then
  rm -f "${NGINX_DEFAULT_SITE_PATH}"
fi

install -d -m 0755 "${NGINX_SNIPPET_DIR}"
install_file_mode "${tmp_locations}" "${NGINX_SNIPPET_DIR}/imserver_locations.conf" 0644
install_file_mode "${tmp_conf}" "${NGINX_HTTP_CONF_PATH}" 0644
NGINX_VERIFY_RUN_NGINX_TEST=false \
NGINX_VERIFY_REQUIRE_SSL=false \
NGINX_HTTP_CONF_PATH="${NGINX_HTTP_CONF_PATH}" \
NGINX_LOCATIONS_CONF_PATH="${NGINX_SNIPPET_DIR}/imserver_locations.conf" \
  bash "${SCRIPT_DIR}/62_verify_nginx_config.sh"
nginx -t
systemctl enable --now nginx
systemctl reload nginx

curl -fsS --max-time 5 "http://127.0.0.1:${IM_PUBLIC_HTTP_PORT}/nginx-health" >/dev/null

echo "Nginx is configured on port ${IM_PUBLIC_HTTP_PORT}. TCP IM gateway still listens on port 9000."
echo "Run deploy/ubuntu/65_verify_entrypoint.sh after IMServer services are started."
