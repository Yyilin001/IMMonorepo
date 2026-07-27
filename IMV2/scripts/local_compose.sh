#!/usr/bin/env bash

# Shared local-stack Compose boundary. Docker Compose gives a variable exported
# by the invoking shell precedence over `--env-file`. For this repository that
# is unsafe: account, gateway and Caddy must use one persisted local secret
# set, not an accidental terminal export left by another project. Strip only
# `IM_V2_*` variables from the Compose process; explicit `docker compose exec
# --env IM_V2_*` probe arguments still reach their target container normally.
v2_local_compose() {
  local env_file="$1"
  shift

  local -a unset_environment=()
  local name
  while IFS='=' read -r name _; do
    case "${name}" in
      IM_V2_*) unset_environment+=(-u "${name}") ;;
    esac
  done < <(env)

  if ((${#unset_environment[@]})); then
    command env "${unset_environment[@]}" docker compose --env-file "${env_file}" "$@"
  else
    command env docker compose --env-file "${env_file}" "$@"
  fi
}
