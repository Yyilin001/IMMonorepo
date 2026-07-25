#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
compose_file="${repo_root}/IMV2/docker-compose.isolated-tests.yml"
project_name="imv2isolatedtests"

cleanup() {
  # Database data lives in its disposable container layer. Keep only the
  # named SwiftPM mirror cache inside the Colima VM for subsequent runs.
  docker compose --project-name "$project_name" --file "$compose_file" down --remove-orphans
}
trap cleanup EXIT

docker compose --project-name "$project_name" --file "$compose_file" up --build --abort-on-container-exit --exit-code-from swift-tests
