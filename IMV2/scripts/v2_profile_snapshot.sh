#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:-}"
snapshot_path="${2:-}"
database_url="${IM_V2_PROFILE_DATABASE_URL:-}"

if [[ -z "${database_url}" || -z "${snapshot_path}" ]]; then
  printf 'usage: IM_V2_PROFILE_DATABASE_URL=... %s capture|restore snapshot.dump\n' "$0" >&2
  exit 1
fi
if [[ "${action}" != 'capture' && "${action}" != 'restore' ]]; then
  printf 'action must be capture or restore\n' >&2
  exit 1
fi
command -v psql >/dev/null 2>&1 || {
  printf 'missing required command: psql\n' >&2
  exit 1
}
command -v pg_dump >/dev/null 2>&1 || {
  printf 'missing required command: pg_dump\n' >&2
  exit 1
}
command -v pg_restore >/dev/null 2>&1 || {
  printf 'missing required command: pg_restore\n' >&2
  exit 1
}

if [[ "${action}" == 'capture' ]]; then
  if [[ -e "${snapshot_path}" ]]; then
    printf 'refusing to overwrite existing snapshot: %s\n' "${snapshot_path}" >&2
    exit 1
  fi
  pg_dump "${database_url}" \
    --format=custom --no-owner --no-privileges --file="${snapshot_path}"
  printf 'Profile snapshot captured at %s\n' "${snapshot_path}"
  exit 0
fi

if [[ "${IM_V2_PROFILE_DATABASE_IS_DISPOSABLE:-}" != '1' ]]; then
  printf 'restore requires IM_V2_PROFILE_DATABASE_IS_DISPOSABLE=1\n' >&2
  exit 1
fi
if [[ ! -f "${snapshot_path}" ]]; then
  printf 'snapshot does not exist: %s\n' "${snapshot_path}" >&2
  exit 1
fi
active_connections="$(
  psql "${database_url}" -v ON_ERROR_STOP=1 -Atc \
    "SELECT COUNT(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()"
)"
if [[ ! "${active_connections}" =~ ^[0-9]+$ || "${active_connections}" != '0' ]]; then
  printf 'restore requires zero other database sessions; found %s\n' "${active_connections}" >&2
  exit 1
fi

psql "${database_url}" -v ON_ERROR_STOP=1 \
  -c 'DROP SCHEMA IF EXISTS im_v2 CASCADE'
pg_restore "${snapshot_path}" --dbname="${database_url}" \
  --clean --if-exists --no-owner --no-privileges --exit-on-error
printf 'Disposable profile database restored from %s\n' "${snapshot_path}"
