#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: reconcile_kafka_topics.sh --validate <inventory.env>
       reconcile_kafka_topics.sh --apply <inventory.env>

Validates the versioned Kafka topic specification in a multi-node inventory.
--apply creates missing topics and applies their initial retention/min-ISR
configuration. Existing topics are inspected only; any drift fails closed.

Required for --apply:
  KAFKA_ADMIN_BOOTSTRAP       Kafka bootstrap endpoint
Optional for --apply:
  KAFKA_TOPICS_BIN            kafka-topics.sh path (default: kafka-topics.sh)
  KAFKA_CONFIGS_BIN           kafka-configs.sh path (default: kafka-configs.sh)
  KAFKA_ADMIN_COMMAND_CONFIG  Kafka client properties file
USAGE
}

fail() {
  printf 'kafka-topic-spec result=fail reason=%s\n' "$1" >&2
  exit 1
}

mode="${1:-}"
inventory="${2:-}"
[[ "${mode}" == "--validate" || "${mode}" == "--apply" ]] || { usage >&2; exit 2; }
[[ -f "${inventory}" ]] || fail "inventory_missing"

# Inventory parsing and its full semantic validation remain owned by the
# renderer so this command cannot be used to bypass the deployment gate.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDER="${ROOT_DIR}/deploy/multinode/render_env.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
"${RENDER}" "${inventory}" "${tmp_dir}/rendered" >/dev/null

# shellcheck source=/dev/null
source "${inventory}"

declare -a topic_names=("${IM_KAFKA_TOPIC}" "${IM_KAFKA_DEAD_LETTER_TOPIC}")
declare -a topic_partitions=("${IM_KAFKA_EVENT_TOPIC_PARTITIONS}" "${IM_KAFKA_DEAD_LETTER_TOPIC_PARTITIONS}")
declare -a topic_replication=("${IM_KAFKA_EVENT_TOPIC_REPLICATION_FACTOR}" "${IM_KAFKA_DEAD_LETTER_TOPIC_REPLICATION_FACTOR}")
declare -a topic_min_isr=("${IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS}" "${IM_KAFKA_DEAD_LETTER_TOPIC_MIN_IN_SYNC_REPLICAS}")
declare -a topic_retention_hours=("${IM_KAFKA_EVENT_TOPIC_RETENTION_HOURS}" "${IM_KAFKA_DEAD_LETTER_TOPIC_RETENTION_HOURS}")

printf 'kafka-topic-spec result=pass mode=%s eventTopic=%s eventPartitions=%s deadLetterTopic=%s deadLetterPartitions=%s\n' \
  "${mode#--}" "${topic_names[0]}" "${topic_partitions[0]}" "${topic_names[1]}" "${topic_partitions[1]}"

[[ "${mode}" == "--apply" ]] || exit 0

bootstrap="${KAFKA_ADMIN_BOOTSTRAP:-}"
[[ -n "${bootstrap}" ]] || fail "missing_KAFKA_ADMIN_BOOTSTRAP"
topics_bin="${KAFKA_TOPICS_BIN:-kafka-topics.sh}"
configs_bin="${KAFKA_CONFIGS_BIN:-kafka-configs.sh}"
command_config="${KAFKA_ADMIN_COMMAND_CONFIG:-}"
if [[ -n "${command_config}" ]]; then
  [[ -f "${command_config}" ]] || fail "kafka_admin_command_config_missing"
fi
command -v "${topics_bin}" >/dev/null 2>&1 || fail "kafka_topics_binary_missing"
command -v "${configs_bin}" >/dev/null 2>&1 || fail "kafka_configs_binary_missing"

run_topics() {
  if [[ -n "${command_config}" ]]; then
    "${topics_bin}" --bootstrap-server "${bootstrap}" --command-config "${command_config}" "$@"
  else
    "${topics_bin}" --bootstrap-server "${bootstrap}" "$@"
  fi
}

run_configs() {
  if [[ -n "${command_config}" ]]; then
    "${configs_bin}" --bootstrap-server "${bootstrap}" --command-config "${command_config}" "$@"
  else
    "${configs_bin}" --bootstrap-server "${bootstrap}" "$@"
  fi
}

for index in "${!topic_names[@]}"; do
  topic="${topic_names[index]}"
  partitions="${topic_partitions[index]}"
  replication="${topic_replication[index]}"
  min_isr="${topic_min_isr[index]}"
  retention_ms=$(( topic_retention_hours[index] * 60 * 60 * 1000 ))
  description_file="${tmp_dir}/topic-${index}.describe"
  if run_topics --describe --topic "${topic}" >"${description_file}" 2>&1; then
    description="$(<"${description_file}")"
    observed_partitions="$(sed -n 's/.*PartitionCount: *\([0-9][0-9]*\).*/\1/p' <<<"${description}" | head -n 1)"
    observed_replication="$(sed -n 's/.*ReplicationFactor: *\([0-9][0-9]*\).*/\1/p' <<<"${description}" | head -n 1)"
    [[ "${observed_partitions}" == "${partitions}" ]] || fail "existing_topic_partition_drift_${topic}"
    [[ "${observed_replication}" == "${replication}" ]] || fail "existing_topic_replication_drift_${topic}"
    config_file="${tmp_dir}/topic-${index}.config"
    run_configs --entity-type topics --entity-name "${topic}" --describe >"${config_file}" 2>&1 \
      || fail "topic_config_describe_failed_${topic}"
    grep -Eq "(^|[,[:space:]])min\.insync\.replicas=${min_isr}([,[:space:]]|$)" "${config_file}" || fail "existing_topic_min_isr_drift_${topic}"
    grep -Eq "(^|[,[:space:]])retention\.ms=${retention_ms}([,[:space:]]|$)" "${config_file}" || fail "existing_topic_retention_drift_${topic}"
    printf 'kafka-topic-spec topic=%s action=verified partitions=%s replication=%s minISR=%s retentionHours=%s\n' \
      "${topic}" "${partitions}" "${replication}" "${min_isr}" "${topic_retention_hours[index]}"
    continue
  fi

  grep -Eqi "does not exist|unknown topic|unknown_topic_or_partition" "${description_file}" || fail "topic_describe_failed_${topic}"

  run_topics --create --if-not-exists --topic "${topic}" --partitions "${partitions}" --replication-factor "${replication}"
  run_configs --entity-type topics --entity-name "${topic}" --alter \
    --add-config "min.insync.replicas=${min_isr},retention.ms=${retention_ms},cleanup.policy=delete"
  printf 'kafka-topic-spec topic=%s action=created partitions=%s replication=%s minISR=%s retentionHours=%s\n' \
    "${topic}" "${partitions}" "${replication}" "${min_isr}" "${topic_retention_hours[index]}"
done
