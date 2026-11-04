#!/usr/bin/env bash

# Refresh only the standard local stack. Isolated callers supply their own CA.
v2_ensure_local_gateway_tls() {
  local ca_path="$1"
  local address="${V2_LOCAL_GATEWAY_TLS_ADDRESS:-localhost:7443}"
  if openssl s_client -connect "${address}" -servername localhost -verify_return_error \
      -CAfile "${ca_path}" </dev/null >/dev/null 2>&1; then
    return 0
  fi
  local default_ca
  default_ca="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/local-ca/root.crt"
  [[ "${ca_path}" == "${default_ca}" ]] || return 1
  python3 "$(dirname "${BASH_SOURCE[0]}")/prepare_local_edge_tls.py" "$(dirname "${ca_path}")" || return 1
  local_compose up -d --force-recreate nginx || return 1
  local_compose up -d --wait --force-recreate gateway || return 1
  openssl s_client -connect "${address}" -servername localhost -verify_return_error \
    -CAfile "${ca_path}" </dev/null >/dev/null 2>&1
}
