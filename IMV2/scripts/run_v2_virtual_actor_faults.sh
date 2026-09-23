#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
compose_file="$repo_root/IMV2/docker-compose.virtual-actor-tests.yml"
scenarios_file="$repo_root/IMV2/scripts/virtual-actor-fixtures/fault-scenarios.json"
artifact_dir="${IMV2_VA_FAULT_ARTIFACT_DIR:-/tmp/imv2-va-v1-fault-artifacts}"
[[ "$artifact_dir" == /* && "$artifact_dir" != / ]] || {
  printf 'IMV2_VA_FAULT_ARTIFACT_DIR must be an absolute path\n' >&2; exit 64;
}
export IMV2_VA_FAULT_ARTIFACT_DIR="$artifact_dir"
project="${IMV2_VA_COMPOSE_PROJECT:-imv2-va-v1}"
[[ "$project" =~ ^imv2-va-[a-z0-9-]+$ ]] || {
  printf 'project must be an isolated imv2-va-* name\n' >&2
  exit 64
}
docker_cli=(docker)
if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
  docker_cli+=(--context "$DOCKER_CONTEXT")
fi
compose=("${docker_cli[@]}" compose -p "$project" -f "$compose_file")

usage() {
  printf 'usage: %s config | up | inject <scenario-id> | isolate <host-a|host-b> <peer|owner-primary|owner-secondary|control> | restore <host-a|host-b> <link> | down | purge | run\n' "$0" >&2
  exit 64
}

require_tools() {
  command -v docker >/dev/null && command -v jq >/dev/null || {
    printf 'docker and jq are required\n' >&2
    exit 69
  }
}

# Future integration supplies this explicit proof of host/probe/barrier wiring.
# W0 has no real Actor host API, so an accidental `up` cannot pass as evidence.
require_integration() {
  local contract="${IMV2_VA_FAULT_CONTRACT_FILE:-}"
  [[ -n "${IMV2_VA_FAULT_HOST_IMAGE:-}" && -n "${IMV2_VA_FAULT_PROBE_IMAGE:-}" && -f "$contract" ]] || {
    printf 'pending integration: host image, probe image, and IMV2_VA_FAULT_CONTRACT_FILE are required\n' >&2
    exit 78
  }
  jq -e '.schemaVersion == 1 and .status == "integrated" and
         .hostExecutable == "/usr/local/bin/IMV2ServerApp" and
         .probeExecutable == "/usr/local/bin/IMV2VAFaultProbe" and
         .barrierProtocol == "file-v1" and .actorNetworkAddressOnly == true' "$contract" >/dev/null || {
    printf 'pending integration: fault host/probe/barrier contract is incomplete\n' >&2
    exit 78
  }
}

service_container() {
  local id
  id="$("${compose[@]}" ps -q "$1")"
  [[ -n "$id" && "$("${docker_cli[@]}" inspect -f '{{.State.Running}}' "$id")" == true ]] || {
    printf 'required service is not running: %s\n' "$1" >&2
    exit 69
  }
  printf '%s' "$id"
}

network_name() {
  local network="$1" matches
  matches="$("${docker_cli[@]}" network ls -q \
    --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.docker.compose.network=$network")"
  [[ -n "$matches" && "$matches" != *$'\n'* ]] || {
    printf 'expected exactly one project network for %s\n' "$network" >&2
    exit 69
  }
  "${docker_cli[@]}" network inspect -f '{{.Name}}' "$matches"
}

link_network() {
  local host="$1" link="$2" suffix
  case "$host" in host-a) suffix=a ;; host-b) suffix=b ;; *) usage ;; esac
  case "$link" in
    peer) printf 'actor' ;;
    owner-primary|owner-secondary|control) printf '%s-%s' "$link" "$suffix" ;;
    *) usage ;;
  esac
}

network_attached() {
  "${docker_cli[@]}" inspect "$1" | jq -e --arg network "$2" \
    '.[0].NetworkSettings.Networks[$network] != null' >/dev/null
}

record_fault() {
  jq -nc --arg action "$1" --arg host "$2" --arg link "$3" \
    --arg network "$4" --arg container "$5" --arg project "$project" \
    --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{time:$time,project:$project,action:$action,host:$host,link:$link,network:$network,container:$container}'
}

require_tools
action="${1:-}"
case "$action" in
  config)
    (( $# == 1 )) || usage
    "${compose[@]}" config --quiet
    # Hosts share only actor; DB links are per-host and DB processes are distinct.
    "${compose[@]}" config --format json | jq -e '
      .services["host-a"].networks | keys == ["actor","control-a","owner-primary-a","owner-secondary-a"]' >/dev/null
    "${compose[@]}" config --format json | jq -e '
      .services["host-b"].networks | keys == ["actor","control-b","owner-primary-b","owner-secondary-b"]' >/dev/null
    printf 'fault topology configuration valid (integration pending)\n'
    ;;
  up)
    (( $# == 1 )) || usage
    require_integration
    mkdir -p "$artifact_dir"
    resolved_artifact="$(realpath "$artifact_dir")"
    [[ "$resolved_artifact" != "$repo_root" && "$resolved_artifact" != "$repo_root"/* ]] || {
      printf 'fault artifacts must stay outside the source tree\n' >&2; exit 64;
    }
    [[ -z "$(find "$artifact_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
      printf 'fault artifact directory must be empty for a new run: %s\n' "$artifact_dir" >&2
      exit 65
    }
    "${compose[@]}" up -d --wait owner-primary owner-secondary control-db host-a host-b probe
    for service in owner-primary owner-secondary control-db host-a host-b probe; do
      service_container "$service" >/dev/null
    done
    printf 'fault topology running; real scenario/barrier verification remains required\n'
    ;;
  inject)
    (( $# == 2 )) || usage
    require_integration
    scenario="$2"
    [[ "$scenario" =~ ^[a-z0-9-]+$ ]] || usage
    scenario_json="$(jq -ec --arg id "$scenario" '.scenarios[] | select(.id == $id and .fault != null)' "$scenarios_file")" || {
      printf 'unknown or non-network scenario: %s\n' "$scenario" >&2; exit 64;
    }
    host="$(jq -r '.fault.host' <<<"$scenario_json")"
    link="$(jq -r '.fault.link' <<<"$scenario_json")"
    stage="$(jq -r '.barrier' <<<"$scenario_json")"
    barrier="$artifact_dir/barriers/$scenario.json"
    barrier_timeout="${IMV2_VA_BARRIER_TIMEOUT_SECONDS:-30}"
    [[ "$barrier_timeout" =~ ^[1-9][0-9]*$ ]] || {
      printf 'IMV2_VA_BARRIER_TIMEOUT_SECONDS must be positive\n' >&2; exit 64;
    }
    deadline="$(( $(date +%s) + barrier_timeout ))"
    while [[ ! -f "$barrier" ]]; do
      (( $(date +%s) < deadline )) || {
        printf 'probe barrier not reached: %s / %s\n' "$scenario" "$stage" >&2; exit 75;
      }
      sleep 0.1
    done
    jq -e --arg scenario "$scenario" --arg stage "$stage" '
      .schemaVersion == 1 and .scenario == $scenario and .stage == $stage and
      .phase == "blocked" and (.roomID | type == "string" and length > 0) and
      (.operationID | type == "string" and length > 0) and
      (.activationEpoch | type == "number" and . >= 1) and
      (.hostBootID | type == "string" and length > 0)' "$barrier" >/dev/null || {
      printf 'invalid probe barrier: %s\n' "$barrier" >&2; exit 65;
    }
    fault_record="$("$0" isolate "$host" "$link")"
    mkdir -p "$artifact_dir/injections" "$artifact_dir/releases"
    jq -n --slurpfile barrier "$barrier" --argjson fault "$fault_record" \
      '{barrier:$barrier[0],fault:$fault}' > "$artifact_dir/injections/$scenario.json.tmp"
    mv "$artifact_dir/injections/$scenario.json.tmp" "$artifact_dir/injections/$scenario.json"
    jq -n --arg scenario "$scenario" --arg operationID "$(jq -r '.operationID' "$barrier")" \
      '{schemaVersion:1,scenario:$scenario,operationID:$operationID,phase:"resume"}' \
      > "$artifact_dir/releases/$scenario.json.tmp"
    mv "$artifact_dir/releases/$scenario.json.tmp" "$artifact_dir/releases/$scenario.json"
    cat "$artifact_dir/injections/$scenario.json"
    ;;
  isolate|restore)
    (( $# == 3 )) || usage
    host="$2"
    link="$3"
    network="$(network_name "$(link_network "$host" "$link")")"
    container="$(service_container "$host")"
    if [[ "$action" == isolate ]]; then
      network_attached "$container" "$network" || {
        printf 'fault did not trigger: link already isolated\n' >&2; exit 65;
      }
      "${docker_cli[@]}" network disconnect -f "$network" "$container"
      if network_attached "$container" "$network"; then
        printf 'fault did not trigger: link remains attached\n' >&2; exit 65
      fi
    else
      if network_attached "$container" "$network"; then
        printf 'restore did not trigger: link already attached\n' >&2; exit 65
      fi
      "${docker_cli[@]}" network connect --alias "$host" "$network" "$container"
      network_attached "$container" "$network" || {
        printf 'restore did not trigger: link remains isolated\n' >&2; exit 65;
      }
    fi
    record_fault "$action" "$host" "$link" "$network" "$container"
    ;;
  down)
    (( $# == 1 )) || usage
    "${compose[@]}" down --remove-orphans
    ;;
  purge)
    (( $# == 1 )) || usage
    [[ "${IMV2_VA_FAULT_DATABASE_IS_DISPOSABLE:-}" == 1 ]] || {
      printf 'purge requires IMV2_VA_FAULT_DATABASE_IS_DISPOSABLE=1\n' >&2; exit 64;
    }
    "${compose[@]}" down --volumes --remove-orphans
    ;;
  run)
    (( $# == 1 )) || usage
    printf 'pending integration: probe phase-barrier and persistent-result adapter are not yet implemented\n' >&2
    exit 78
    ;;
  *) usage ;;
esac
