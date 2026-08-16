#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
compose_file="${repo_root}/IMV2/docker-compose.integration.yml"
project_name="imv2integration"

cleanup() {
  docker compose --project-name "${project_name}" --file "${compose_file}" down --volumes --remove-orphans
}
trap cleanup EXIT

docker compose --project-name "${project_name}" --file "${compose_file}" up --detach --wait
IMV2_POSTGRES_TEST_DATABASE_URL='postgres://im_v2_test:im_v2_test@127.0.0.1:55432/im_v2_test' \
IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL='postgres://im_v2_test:im_v2_test@127.0.0.1:55433/im_v2_test' \
IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1 \
IMV2_REQUIRE_CROSS_STORE_POSTGRES_TESTS=1 \
swift test --package-path "${repo_root}/IMV2Server"
