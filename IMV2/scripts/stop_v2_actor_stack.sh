#!/usr/bin/env bash
set -euo pipefail

# Placement must remain available until the room Host has committed retirement.
# docker compose stop succeeds even when Docker had to SIGKILL the process.
if [[ $# != 2 || "$1" != "--compose" || ! -f "$2" ]]; then
  echo 'usage: stop_v2_actor_stack.sh --compose <compose-file>' >&2
  exit 64
fi
compose_file="$2"
project="${IM_V2_COMPOSE_PROJECT:-imtest}"
compose() { docker compose -p "$project" -f "$compose_file" "$@"; }
gateway_id="$(compose ps -aq gateway)"
if [[ -z "$gateway_id" || "$gateway_id" == *$'\n'* ]]; then
  echo 'Expected exactly one gateway Host; refusing to stop its Placement quorum.' >&2
  exit 1
fi
compose stop -t 120 gateway
state="$(docker inspect --format '{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}' "$gateway_id")"
if [[ "$state" != 'exited 0 false' ]]; then
  echo 'Gateway did not exit cleanly; Placement remains running for ownership recovery.' >&2
  exit 1
fi
compose stop -t 45 nginx account operator
compose stop -t 45 placement-a placement-b placement-c
