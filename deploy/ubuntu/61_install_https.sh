#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

NGINX_TLS_DOMAIN="${NGINX_TLS_DOMAIN:-${NGINX_SERVER_NAME:-}}"
NGINX_TLS_EMAIL="${NGINX_TLS_EMAIL:-}"
NGINX_HTTPS_PORT="${NGINX_HTTPS_PORT:-443}"
IM_PUBLIC_HTTP_PORT="${IM_PUBLIC_HTTP_PORT:-${HTTP_PORT:-80}}"
IM_GATEWAY_HTTP_PORT="${IM_GATEWAY_HTTP_PORT:-18080}"
IM_COMMAND_API_PORT="${IM_COMMAND_API_PORT:-8081}"
IM_QUERY_API_PORT="${IM_QUERY_API_PORT:-8082}"
NGINX_SNIPPET_DIR="${NGINX_SNIPPET_DIR:-/etc/nginx/snippets}"
NGINX_HTTP_CONF_PATH="${NGINX_HTTP_CONF_PATH:-/etc/nginx/conf.d/imserver.conf}"
NGINX_LOCATIONS_CONF_PATH="${NGINX_LOCATIONS_CONF_PATH:-${NGINX_SNIPPET_DIR}/imserver_locations.conf}"
NGINX_CLIENT_MAX_BODY_SIZE="${NGINX_CLIENT_MAX_BODY_SIZE:-100m}"
NGINX_AUTH_RATE_LIMIT="${NGINX_AUTH_RATE_LIMIT:-50r/s}"
NGINX_AUTH_RATE_BURST="${NGINX_AUTH_RATE_BURST:-100}"
NGINX_API_RATE_LIMIT="${NGINX_API_RATE_LIMIT:-1000r/s}"
NGINX_API_RATE_BURST="${NGINX_API_RATE_BURST:-2000}"
NGINX_CONNECTION_LIMIT="${NGINX_CONNECTION_LIMIT:-1000}"
CERTBOT_STAGING="${CERTBOT_STAGING:-false}"
CERTBOT_REGISTER_UNSAFELY_WITHOUT_EMAIL="${CERTBOT_REGISTER_UNSAFELY_WITHOUT_EMAIL:-false}"
CERTBOT_REQUIRE_RENEWAL_TIMER="${CERTBOT_REQUIRE_RENEWAL_TIMER:-true}"
ACME_WEBROOT="${ACME_WEBROOT:-/var/www/imserver-acme}"
LETSENCRYPT_DIR="${LETSENCRYPT_DIR:-/etc/letsencrypt}"
CERTBOT_RENEWAL_HOOK_DIR="${CERTBOT_RENEWAL_HOOK_DIR:-${LETSENCRYPT_DIR}/renewal-hooks/deploy}"
NGINX_SSL_CONF_PATH="${NGINX_SSL_CONF_PATH:-/etc/nginx/conf.d/imserver_ssl.conf}"
HTTPS_INSTALL_SELF_TEST="${HTTPS_INSTALL_SELF_TEST:-false}"
HTTPS_INSTALL_SKIP_HTTP_NGINX_INSTALL="${HTTPS_INSTALL_SKIP_HTTP_NGINX_INSTALL:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

run_self_test() {
  local self_test_dir fake_bin output conf_path http_conf_path locations_conf_path hook_path certbot_log systemctl_log
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' RETURN
  fake_bin="${self_test_dir}/bin"
  mkdir -p "${fake_bin}" "${self_test_dir}/nginx/snippets" "${self_test_dir}/nginx/conf.d" "${self_test_dir}/acme"
  conf_path="${self_test_dir}/nginx/imserver_ssl.conf"
  http_conf_path="${self_test_dir}/nginx/conf.d/imserver.conf"
  locations_conf_path="${self_test_dir}/nginx/snippets/imserver_locations.conf"
  hook_path="${self_test_dir}/letsencrypt/renewal-hooks/deploy/imserver-nginx-reload.sh"
  certbot_log="${self_test_dir}/certbot.log"
  systemctl_log="${self_test_dir}/systemctl.log"

  cat >"${fake_bin}/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"${fake_bin}/certbot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${HTTPS_SELF_TEST_CERTBOT_LOG}"
case "$*" in
  *"certonly"*--webroot*"--domain im.example.test"*) exit 0 ;;
  *) exit 2 ;;
esac
EOF
  cat >"${fake_bin}/nginx" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-t" ]]
EOF
  cat >"${fake_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${HTTPS_SELF_TEST_SYSTEMCTL_LOG}"
case "$*" in
  *"enable --now certbot.timer"*|*"reload nginx"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  cat >"${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"https://im.example.test:443/nginx-health"*) exit 0 ;;
  *) exit 2 ;;
esac
EOF
  cat >"${fake_bin}/ufw" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "status" ]]; then
  printf 'Status: inactive\n'
fi
exit 0
EOF
  chmod +x "${fake_bin}/apt-get" "${fake_bin}/certbot" "${fake_bin}/nginx" "${fake_bin}/systemctl" "${fake_bin}/curl" "${fake_bin}/ufw"

  cat >"${http_conf_path}" <<EOF
limit_req_zone \$binary_remote_addr zone=im_auth:20m rate=50r/s;
limit_req_zone \$binary_remote_addr zone=im_api:50m rate=1000r/s;
limit_conn_zone \$binary_remote_addr zone=im_conn:20m;
server {
  server_tokens off;
  add_header X-Content-Type-Options "nosniff" always;
  add_header X-Frame-Options "DENY" always;
  add_header Referrer-Policy "no-referrer" always;
  client_max_body_size 100m;
  limit_conn im_conn 1000;
  include ${locations_conf_path};
}
EOF
  cat >"${locations_conf_path}" <<'EOF'
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

  output="$(
    PATH="${fake_bin}:${PATH}" \
    HTTPS_SELF_TEST_CERTBOT_LOG="${certbot_log}" \
    HTTPS_SELF_TEST_SYSTEMCTL_LOG="${systemctl_log}" \
    HTTPS_INSTALL_SELF_TEST=false \
    HTTPS_INSTALL_REQUIRE_ROOT=false \
    NGINX_TLS_DOMAIN=im.example.test \
    NGINX_TLS_EMAIL=ops@example.test \
    NGINX_HTTPS_PORT=443 \
    IM_PUBLIC_HTTP_PORT=80 \
    ACME_WEBROOT="${self_test_dir}/acme" \
    LETSENCRYPT_DIR="${self_test_dir}/letsencrypt" \
    CERTBOT_RENEWAL_HOOK_DIR="${self_test_dir}/letsencrypt/renewal-hooks/deploy" \
    NGINX_SNIPPET_DIR="${self_test_dir}/nginx/snippets" \
    NGINX_HTTP_CONF_PATH="${http_conf_path}" \
    NGINX_LOCATIONS_CONF_PATH="${locations_conf_path}" \
    NGINX_SSL_CONF_PATH="${conf_path}" \
    HTTPS_INSTALL_SKIP_HTTP_NGINX_INSTALL=true \
      bash "${BASH_SOURCE[0]}"
  )"

  [[ -f "${conf_path}" ]] || {
    printf 'https-install-self-test result=fail reason=ssl_conf_missing\n' >&2
    return 1
  }
  [[ -x "${hook_path}" ]] || {
    printf 'https-install-self-test result=fail reason=renewal_hook_missing\n' >&2
    return 1
  }
  grep -q 'ssl_certificate '"${self_test_dir}"'/letsencrypt/live/im.example.test/fullchain.pem;' "${conf_path}" || {
    printf 'https-install-self-test result=fail reason=ssl_cert_path_not_rendered\n' >&2
    return 1
  }
  grep -q 'add_header X-Content-Type-Options "nosniff" always;' "${conf_path}" || {
    printf 'https-install-self-test result=fail reason=ssl_security_header_missing\n' >&2
    return 1
  }
  grep -q 'limit_conn im_conn 1000;' "${conf_path}" || {
    printf 'https-install-self-test result=fail reason=ssl_connection_limit_missing\n' >&2
    return 1
  }
  grep -q -- '--webroot-path '"${self_test_dir}"'/acme' "${certbot_log}" || {
    printf 'https-install-self-test result=fail reason=certbot_webroot_missing\n' >&2
    return 1
  }
  grep -q 'enable --now certbot.timer' "${systemctl_log}" || {
    printf 'https-install-self-test result=fail reason=certbot_timer_not_enabled\n' >&2
    return 1
  }
  grep -q 'renewalTimerRequired=true' <<<"${output}" || {
    printf 'https-install-self-test result=fail reason=summary_missing_renewal_timer output=%s\n' "${output}" >&2
    return 1
  }
  printf 'https-install-self-test result=pass\n'
}

if bool_enabled "${HTTPS_INSTALL_SELF_TEST}"; then
  run_self_test
  exit 0
fi

if bool_enabled "${HTTPS_INSTALL_REQUIRE_ROOT:-true}"; then
  require_root
fi

if [[ -z "${NGINX_TLS_DOMAIN}" || "${NGINX_TLS_DOMAIN}" == "_" ]]; then
  echo "Set NGINX_TLS_DOMAIN to a real DNS name before installing HTTPS." >&2
  exit 1
fi

certbot_args=(
  certonly
  --webroot
  --webroot-path "${ACME_WEBROOT}"
  --domain "${NGINX_TLS_DOMAIN}"
  --agree-tos
  --non-interactive
  --keep-until-expiring
)
if [[ -n "${NGINX_TLS_EMAIL}" ]]; then
  certbot_args+=(--email "${NGINX_TLS_EMAIL}")
elif bool_enabled "${CERTBOT_REGISTER_UNSAFELY_WITHOUT_EMAIL}"; then
  certbot_args+=(--register-unsafely-without-email)
else
  echo "Set NGINX_TLS_EMAIL or CERTBOT_REGISTER_UNSAFELY_WITHOUT_EMAIL=true." >&2
  exit 1
fi
if bool_enabled "${CERTBOT_STAGING}"; then
  certbot_args+=(--staging)
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y certbot

install -d -m 0755 "${ACME_WEBROOT}/.well-known/acme-challenge"

if ! bool_enabled "${HTTPS_INSTALL_SKIP_HTTP_NGINX_INSTALL}"; then
  NGINX_SERVER_NAME="${NGINX_TLS_DOMAIN}" \
  IM_PUBLIC_HTTP_PORT="${IM_PUBLIC_HTTP_PORT}" \
  IM_GATEWAY_HTTP_PORT="${IM_GATEWAY_HTTP_PORT}" \
  IM_COMMAND_API_PORT="${IM_COMMAND_API_PORT}" \
  IM_QUERY_API_PORT="${IM_QUERY_API_PORT}" \
  NGINX_SNIPPET_DIR="${NGINX_SNIPPET_DIR}" \
  NGINX_HTTP_CONF_PATH="${NGINX_HTTP_CONF_PATH}" \
  NGINX_CLIENT_MAX_BODY_SIZE="${NGINX_CLIENT_MAX_BODY_SIZE}" \
  NGINX_AUTH_RATE_LIMIT="${NGINX_AUTH_RATE_LIMIT}" \
  NGINX_AUTH_RATE_BURST="${NGINX_AUTH_RATE_BURST}" \
  NGINX_API_RATE_LIMIT="${NGINX_API_RATE_LIMIT}" \
  NGINX_API_RATE_BURST="${NGINX_API_RATE_BURST}" \
  NGINX_CONNECTION_LIMIT="${NGINX_CONNECTION_LIMIT}" \
  bash "${SCRIPT_DIR}/60_install_nginx.sh"
fi

certbot "${certbot_args[@]}"
install -d -m 0755 "${CERTBOT_RENEWAL_HOOK_DIR}"
cat > "${CERTBOT_RENEWAL_HOOK_DIR}/imserver-nginx-reload.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl reload nginx
EOF
chmod 0755 "${CERTBOT_RENEWAL_HOOK_DIR}/imserver-nginx-reload.sh"

if bool_enabled "${CERTBOT_REQUIRE_RENEWAL_TIMER}"; then
  systemctl enable --now certbot.timer
fi

tmp_ssl="$(mktemp)"
cleanup() {
  rm -f "${tmp_ssl}"
}
trap cleanup EXIT

sed \
  -e "s/__HTTPS_PORT__/${NGINX_HTTPS_PORT}/g" \
  -e "s/__SERVER_NAME__/${NGINX_TLS_DOMAIN}/g" \
  -e "s#__LETSENCRYPT_DIR__#${LETSENCRYPT_DIR}#g" \
  -e "s#__SNIPPET_DIR__#${NGINX_SNIPPET_DIR}#g" \
  -e "s/__CLIENT_MAX_BODY_SIZE__/${NGINX_CLIENT_MAX_BODY_SIZE}/g" \
  -e "s#__AUTH_RATE_LIMIT__#${NGINX_AUTH_RATE_LIMIT}#g" \
  -e "s/__AUTH_RATE_BURST__/${NGINX_AUTH_RATE_BURST}/g" \
  -e "s#__API_RATE_LIMIT__#${NGINX_API_RATE_LIMIT}#g" \
  -e "s/__API_RATE_BURST__/${NGINX_API_RATE_BURST}/g" \
  -e "s/__CONNECTION_LIMIT__/${NGINX_CONNECTION_LIMIT}/g" \
  "${SCRIPT_DIR}/nginx/imserver_ssl.conf" > "${tmp_ssl}"

install_file_mode "${tmp_ssl}" "${NGINX_SSL_CONF_PATH}" 0644
NGINX_VERIFY_RUN_NGINX_TEST=false \
NGINX_VERIFY_REQUIRE_SSL=true \
NGINX_HTTP_CONF_PATH="${NGINX_HTTP_CONF_PATH}" \
NGINX_SSL_CONF_PATH="${NGINX_SSL_CONF_PATH}" \
NGINX_LOCATIONS_CONF_PATH="${NGINX_LOCATIONS_CONF_PATH}" \
  bash "${SCRIPT_DIR}/62_verify_nginx_config.sh"
nginx -t
systemctl reload nginx

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${NGINX_HTTPS_PORT}/tcp" comment "imserver-https"
fi

curl -fsSk \
  --resolve "${NGINX_TLS_DOMAIN}:${NGINX_HTTPS_PORT}:127.0.0.1" \
  "https://${NGINX_TLS_DOMAIN}:${NGINX_HTTPS_PORT}/nginx-health" >/dev/null

printf 'HTTPS configured: domain=%s httpsPort=%s httpPort=%s cert=%s/live/%s/fullchain.pem renewalHook=%s/imserver-nginx-reload.sh renewalTimerRequired=%s\n' \
  "${NGINX_TLS_DOMAIN}" \
  "${NGINX_HTTPS_PORT}" \
  "${IM_PUBLIC_HTTP_PORT}" \
  "${LETSENCRYPT_DIR}" \
  "${NGINX_TLS_DOMAIN}" \
  "${CERTBOT_RENEWAL_HOOK_DIR}" \
  "${CERTBOT_REQUIRE_RENEWAL_TIMER}"
