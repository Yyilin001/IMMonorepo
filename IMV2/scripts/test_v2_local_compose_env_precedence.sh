#!/usr/bin/env bash
set -Eeuo pipefail

# Regression for Docker Compose's environment precedence. It is read-only: a
# conflicting shell export must not change the rendered local account stack.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
v2_dir="$(cd "${script_dir}/.." && pwd)"
env_file="${v2_dir}/.env.local"
compose_file="${v2_dir}/docker-compose.local-account.yml"
compose_project="${V2_LOCAL_COMPOSE_PROJECT:-imv2localaccount}"

source "${script_dir}/local_compose.sh"

command -v docker >/dev/null 2>&1 || {
  printf 'missing required command: docker\n' >&2
  exit 1
}
test -f "${env_file}" || {
  printf 'missing local V2 environment: %s\n' "${env_file}" >&2
  exit 1
}

rendered_secret_hash() {
  v2_local_compose "${env_file}" --project-name "${compose_project}" --file "${compose_file}" config |
    awk -F': ' '/IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64:/ {
      value = $0
      sub(/^[^:]+:[[:space:]]*/, "", value)
      gsub(/["[:space:]]/, "", value)
      print value
    }' |
    shasum -a 256 |
    awk '{print $1}'
}

expected="$(rendered_secret_hash)"
actual="$(IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' rendered_secret_hash)"
test "${actual}" = "${expected}" || {
  printf 'local Compose unexpectedly allowed a shell IM_V2_* value to override %s\n' "${env_file}" >&2
  exit 1
}

printf 'local Compose environment precedence: verified\n'
