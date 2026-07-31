#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
v2_dir="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${v2_dir}/.." && pwd)"
compose_file="${v2_dir}/docker-compose.local-account.yml"
env_file="${v2_dir}/.env.local"
compose_project="${V2_LOCAL_COMPOSE_PROJECT:-imv2localaccount}"
local_account_build_stage_label="com.imv2.local-account-build-stage=true"

# Keep `.env.local` authoritative even when the invoking terminal exported an
# unrelated `IM_V2_*` value.
source "${script_dir}/local_compose.sh"
# shellcheck source=local_admission_pool.sh
source "${script_dir}/local_admission_pool.sh"

compose() {
  v2_local_compose "${env_file}" --project-name "${compose_project}" --file "${compose_file}" "$@"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command docker
require_command openssl
require_command htpasswd
require_command rsync
require_command uuidgen

# `docker image prune` only removes dangling images. Narrow it further to this
# Dockerfile's build stage, so a repeated local rebuild cannot fill Docker's
# VM disk with compiler layers and it never deletes a tagged image, container,
# or volume owned by another project.
prune_unreferenced_local_build_stages() {
  docker image prune --force --filter "label=${local_account_build_stage_label}" >/dev/null
}

prune_unreferenced_local_build_stages

if [[ ! -f "${env_file}" ]]; then
  postgres_password="$(openssl rand -base64 24 | tr -d '\n' | tr '+/' '-_')"
  access_key="$(openssl rand -base64 32 | tr -d '\n')"
  replay_key="$(openssl rand -base64 32 | tr -d '\n')"
  push_endpoint_key="$(openssl rand -base64 32 | tr -d '\n')"
  edge_authorization_secret="$(openssl rand -base64 32 | tr -d '\n')"
  edge_client_rate_limit_key="$(openssl rand -base64 32 | tr -d '\n')"
  assertion_key="$(openssl rand -base64 32 | tr -d '\n')"
  local_media_signing_key="$(openssl rand -base64 32 | tr -d '\n')"
  operator_replay_bearer_token="$(openssl rand -base64 32 | tr -d '\n')"
  operator_account_disable_bearer_token="$(openssl rand -base64 32 | tr -d '\n')"
  dummy_hash="$(htpasswd -bnBC 12 '' 'v2-local-dummy-password' | tr -d ':\n')"
  # Compose interpolates `$name` even in an env file. Double each dollar so
  # the container receives the original bcrypt digest verbatim.
  dummy_hash_for_compose="${dummy_hash//$/\$\$}"

  umask 077
  {
    printf 'IM_V2_LOCAL_POSTGRES_PASSWORD=%s\n' "${postgres_password}"
    printf 'IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64=%s\n' "${access_key}"
    printf 'IM_V2_CREDENTIAL_REPLAY_ENVELOPE_KEY_BASE64=%s\n' "${replay_key}"
    printf 'IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64=%s\n' "${push_endpoint_key}"
    printf 'IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64=%s\n' "${edge_authorization_secret}"
    printf 'IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64=%s\n' "${edge_client_rate_limit_key}"
    printf 'IM_V2_ACCOUNT_ASSERTION_HMAC_KEY_BASE64=%s\n' "${assertion_key}"
    printf 'IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64=%s\n' "${local_media_signing_key}"
    printf 'IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64=%s\n' "${operator_replay_bearer_token}"
    printf 'IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64=%s\n' "${operator_account_disable_bearer_token}"
    printf 'IM_V2_PASSWORD_DUMMY_BCRYPT_HASH=%s\n' "${dummy_hash_for_compose}"
  } > "${env_file}"
  printf 'created local-only secret configuration: %s\n' "${env_file}"
fi

if ! grep -q '^IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64=' "${env_file}"; then
  local_media_signing_key="$(openssl rand -base64 32 | tr -d '\n')"
  umask 077
  printf 'IM_V2_LOCAL_MEDIA_SIGNING_KEY_BASE64=%s\n' "${local_media_signing_key}" >> "${env_file}"
  printf 'added local-only media signing key: %s\n' "${env_file}"
fi

# Existing local stacks predate Push endpoint encryption. Add this local-only
# secret once without replacing any developer-provided values.
if ! grep -q '^IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64=' "${env_file}"; then
  push_endpoint_key="$(openssl rand -base64 32 | tr -d '\n')"
  umask 077
  printf 'IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64=%s\n' "${push_endpoint_key}" >> "${env_file}"
  printf 'added local-only Push endpoint envelope key: %s\n' "${env_file}"
fi

if ! grep -q '^IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64=' "${env_file}"; then
  edge_authorization_secret="$(openssl rand -base64 32 | tr -d '\n')"
  umask 077
  printf 'IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64=%s\n' "${edge_authorization_secret}" >> "${env_file}"
  printf 'added local-only account-edge authorization secret: %s\n' "${env_file}"
fi

if ! grep -q '^IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64=' "${env_file}"; then
  edge_client_rate_limit_key="$(openssl rand -base64 32 | tr -d '\n')"
  umask 077
  printf 'IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64=%s\n' "${edge_client_rate_limit_key}" >> "${env_file}"
  printf 'added local-only account-edge client rate-limit key: %s\n' "${env_file}"
fi

if ! grep -q '^IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64=' "${env_file}"; then
  operator_replay_bearer_token="$(openssl rand -base64 32 | tr -d '\n')"
  umask 077
  printf 'IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64=%s\n' "${operator_replay_bearer_token}" >> "${env_file}"
  printf 'added local-only operator replay bearer token: %s\n' "${env_file}"
fi

if ! grep -q '^IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64=' "${env_file}"; then
  operator_account_disable_bearer_token="$(openssl rand -base64 32 | tr -d '\n')"
  umask 077
  printf 'IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64=%s\n' "${operator_account_disable_bearer_token}" >> "${env_file}"
  printf 'added local-only operator account-disable bearer token: %s\n' "${env_file}"
fi

# Older local Docker installations can lack Buildx and therefore ignore a
# Dockerfile-specific .dockerignore. Build from a temporary, allow-listed
# context so V1 sources and host compiler artifacts never enter the image.
build_context="$(mktemp -d)"
# A failed Docker build can leave the same dangling compiler stage as a
# successful one.  The exit trap makes that failure recoverable immediately,
# rather than requiring a second invocation to reclaim local Docker space.
# Cleanup is deliberately best-effort so it never hides the original failure.
cleanup_local_build() {
  local exit_status="$?"
  rm -rf -- "${build_context}"
  prune_unreferenced_local_build_stages || true
  return "${exit_status}"
}
trap cleanup_local_build EXIT
mkdir -p "${build_context}/IMV2" "${build_context}/IMV2Core" "${build_context}/IMV2Server"
rsync -a --exclude '.build' --exclude '.swiftpm' --exclude '.DS_Store' \
  "${repo_root}/IMV2Core/" "${build_context}/IMV2Core/"
rsync -a --exclude '.build' --exclude '.swiftpm' --exclude '.DS_Store' \
  "${repo_root}/IMV2Server/" "${build_context}/IMV2Server/"
cp "${v2_dir}/Dockerfile.account" "${build_context}/IMV2/Dockerfile.account"
docker build --tag imv2localaccount-v2server --file "${build_context}/IMV2/Dockerfile.account" "${build_context}"
prune_unreferenced_local_build_stages

# Recreate the PostgreSQL *container* so its read-only SQL bind mount is
# refreshed as well. The named data volume is retained, so this never drops
# local data, while preventing an older container from retaining an empty or
# stale migration mount after the repository's schema files change.
# Start it first so the retained volume can catch up through the local-only
# migration ledger before any V2 service runs its schema readiness gate.
compose up -d --wait --force-recreate postgres
"${script_dir}/apply_v2_local_schema_migrations.sh"
v2_seed_local_admission_pool
# Caddy's development leaf certificate is intentionally short-lived. Recreate
# the local TLS edge on every explicit start so a retained Compose project
# cannot stay "healthy" after its certificate expires. The local CA volume is
# retained, so simulators that trust its root do not need to be reconfigured.
# The image tag stays stable for convenient local use. Explicitly recreate all
# binaries after each build so a successful smoke test can never exercise a
# stale account, operator, or gateway process left behind by Compose.
compose up -d --wait --force-recreate account operator
compose up -d --force-recreate caddy
mkdir -p "${v2_dir}/local-ca"
ca_path="${v2_dir}/local-ca/root.crt"
for _ in {1..30}; do
  if compose cp caddy:/data/caddy/pki/authorities/local/root.crt "${ca_path}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
test -f "${ca_path}" || {
  printf 'Caddy did not generate its local CA certificate; inspect: docker compose --project-name %s --env-file %s --file %s logs caddy\n' "${compose_project}" "${env_file}" "${compose_file}" >&2
  exit 1
}
# The gateway reads Caddy's certificate files only at startup, so it must be
# recreated after the edge writes a replacement leaf certificate.
compose up -d --wait --force-recreate gateway

printf 'V2 local account stack ready at https://localhost:8443\n'
printf 'V2 local TLS gateway is ready at localhost:7443\n'
printf 'Trust %s in the iOS Simulator before using the app.\n' "${ca_path}"
printf 'To stop it: docker compose --project-name %s --env-file %s --file %s down\n' "${compose_project}" "${env_file}" "${compose_file}"
printf 'Repository root: %s\n' "${repo_root}"
