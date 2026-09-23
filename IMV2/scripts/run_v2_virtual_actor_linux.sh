#!/usr/bin/env bash
set -Eeuo pipefail

# Host-side entry point. All Swift artifacts live in Compose-owned /tmp volumes;
# the repository is mounted read-only by docker-compose.isolated-tests.yml.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
project="${IMV2_VA_LINUX_COMPOSE_PROJECT:-imv2-va-v1-linux}"
docker_cli=(docker)
if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
  docker_cli+=(--context "$DOCKER_CONTEXT")
fi
case "$project" in
  imv2-va-*) ;;
  *) printf 'IMV2_VA_LINUX_COMPOSE_PROJECT must begin imv2-va-: %s\n' "$project" >&2; exit 64 ;;
esac
compose=("${docker_cli[@]}" compose -p "$project" -f "$repo_root/IMV2/docker-compose.isolated-tests.yml")
if [[ -n "${IMV2_VA_LINUX_CACHE_DIR:-}" || -n "${IMV2_VA_LINUX_SCRATCH_DIR:-}" ]]; then
  [[ -n "${IMV2_VA_LINUX_CACHE_DIR:-}" && -n "${IMV2_VA_LINUX_SCRATCH_DIR:-}" ]] || {
    printf 'set both IMV2_VA_LINUX_CACHE_DIR and IMV2_VA_LINUX_SCRATCH_DIR\n' >&2; exit 64;
  }
  for path in "$IMV2_VA_LINUX_CACHE_DIR" "$IMV2_VA_LINUX_SCRATCH_DIR"; do
    [[ "$path" == /* && "$path" != / ]] || {
      printf 'cache/scratch bind must be an absolute path outside the source tree: %s\n' "$path" >&2
      exit 64
    }
    mkdir -p "$path"
    resolved="$(realpath "$path")"
    [[ "$resolved" != "$repo_root" && "$resolved" != "$repo_root"/* ]] || {
      printf 'cache/scratch bind resolves inside the source tree: %s\n' "$path" >&2
      exit 64
    }
  done
  [[ "$(realpath "$IMV2_VA_LINUX_CACHE_DIR")" != "$(realpath "$IMV2_VA_LINUX_SCRATCH_DIR")" ]] || {
    printf 'cache and scratch paths must differ\n' >&2; exit 64;
  }
  export IMV2_VA_LINUX_CACHE_DIR IMV2_VA_LINUX_SCRATCH_DIR
  compose+=(-f "$repo_root/IMV2/docker-compose.virtual-actor-linux-bind.yml")
fi

usage() {
  printf 'usage: %s build [release-product ...] | test <IMV2Core|IMV2Server> <filter-regex>\n' "$0" >&2
  exit 64
}

action="${1:-}"
case "$action" in
  build)
    shift
    if (( $# == 0 )); then
      set -- IMV2AccountServerApp IMV2OperatorServerApp IMV2ServerApp IMV2LocalGatewayProbe IMV2GatewayLoadGenerator
    fi
    for product in "$@"; do
      [[ "$product" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || usage
    done
    "${compose[@]}" \
      run --build --rm --no-deps --entrypoint bash swift-tests \
      /workspace/IMV2/scripts/v2_virtual_actor_linux_runner.sh build "$@"
    ;;
  test)
    (( $# == 3 )) || usage
    [[ "$2" == IMV2Core || "$2" == IMV2Server ]] || usage
    [[ -n "$3" ]] || usage
    "${compose[@]}" \
      run --build --rm --entrypoint bash swift-tests \
      /workspace/IMV2/scripts/v2_virtual_actor_linux_runner.sh test "$2" "$3"
    ;;
  *) usage ;;
esac
