#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rules_path="${repo_root}/IMV2/observability/prometheus/imv2-alerts.yml"
config_path="${repo_root}/IMV2/observability/prometheus/prometheus.yml.example"

if command -v promtool >/dev/null 2>&1; then
  promtool check rules "${rules_path}"
  promtool check config "${config_path}"
  exit 0
fi

if command -v docker >/dev/null 2>&1; then
  prometheus_image="prom/prometheus:v2.54.1"
  # Pull before creating the isolated validator container. Some Docker
  # implementations apply `--network none` early enough that an implicit
  # pull becomes unreliable; the validator itself remains networkless.
  docker image inspect "${prometheus_image}" >/dev/null 2>&1 || docker pull "${prometheus_image}"
  docker run --rm --network none --entrypoint /bin/promtool \
    -v "${repo_root}/IMV2/observability/prometheus:/rules:ro" \
    "${prometheus_image}" \
    check rules /rules/imv2-alerts.yml
  docker run --rm --network none --entrypoint /bin/promtool \
    -v "${repo_root}/IMV2/observability/prometheus:/rules:ro" \
    "${prometheus_image}" \
    check config /rules/prometheus.yml.example
  exit 0
fi

printf 'promtool or docker is required to validate V2 Prometheus rules.\n' >&2
exit 1
