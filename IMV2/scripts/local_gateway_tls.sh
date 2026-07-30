#!/usr/bin/env bash

# The local Caddy development leaf is intentionally short-lived, while the
# native gateway reads that PEM only at process startup. Call this after the
# local Compose stack is running and its CA file exists. `local_compose` must
# be supplied by the caller and must target only that local Compose project.
v2_ensure_local_gateway_tls() {
  local ca_path="$1"

  if local_compose exec -T gateway sh -c '
    openssl s_client \
      -connect 127.0.0.1:7443 \
      -servername localhost \
      -CAfile /caddy/caddy/pki/authorities/local/root.crt \
      -verify_return_error \
      </dev/null >/dev/null 2>&1
  '; then
    return 0
  fi

  printf '%s\n' 'local gateway TLS leaf is stale or unusable; refreshing only local Caddy and gateway.' >&2
  local_compose up -d --force-recreate caddy
  for _ in {1..30}; do
    if local_compose cp caddy:/data/caddy/pki/authorities/local/root.crt "${ca_path}" >/dev/null 2>&1 &&
      local_compose exec -T caddy test -s /data/caddy/pki/authorities/local/root.crt &&
      local_compose exec -T caddy test -s /data/caddy/certificates/local/localhost/localhost.crt &&
      local_compose exec -T caddy test -s /data/caddy/certificates/local/localhost/localhost.key; then
      break
    fi
    sleep 1
  done
  test -s "${ca_path}" || {
    printf 'local Caddy did not expose its CA while refreshing the gateway certificate\n' >&2
    return 1
  }
  local_compose up -d --wait --force-recreate gateway
  local_compose exec -T gateway sh -c '
    openssl s_client \
      -connect 127.0.0.1:7443 \
      -servername localhost \
      -CAfile /caddy/caddy/pki/authorities/local/root.crt \
      -verify_return_error \
      </dev/null >/dev/null 2>&1
  '
}
