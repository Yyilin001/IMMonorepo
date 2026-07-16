#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECONCILE="${ROOT_DIR}/deploy/multinode/reconcile_kafka_topics.sh"
INVENTORY="${ROOT_DIR}/deploy/multinode/inventory.example.env"
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'kafka-topic-reconcile-test result=fail reason=%s\n' "$1" >&2
  exit 1
}

[[ -x "${RECONCILE}" ]] || fail "reconciler_not_executable"

state_dir="${TMP_DIR}/state"
mkdir -p "${state_dir}"
topics_bin="${TMP_DIR}/mock-kafka-topics.sh"
configs_bin="${TMP_DIR}/mock-kafka-configs.sh"

cat >"${topics_bin}" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

arg_value() {
  local expected="$1"
  shift
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "${expected}" ]]; then
      [[ $# -ge 2 ]] || return 1
      printf '%s' "$2"
      return 0
    fi
    shift
  done
  return 1
}

topic="$(arg_value --topic "$@")"
topic_file="${MOCK_KAFKA_STATE}/${topic}.topic"
if [[ " $* " == *" --describe "* ]]; then
  if [[ -n "${MOCK_KAFKA_DESCRIBE_FAILURE:-}" ]]; then
    printf '%s\n' "${MOCK_KAFKA_DESCRIBE_FAILURE}" >&2
    exit 1
  fi
  [[ -f "${topic_file}" ]] || { printf 'Unknown topic %s\n' "${topic}" >&2; exit 1; }
  cat "${topic_file}"
  exit 0
fi

[[ " $* " == *" --create "* ]] || exit 2
partitions="$(arg_value --partitions "$@")"
replication="$(arg_value --replication-factor "$@")"
printf 'Topic: %s PartitionCount: %s ReplicationFactor: %s\n' \
  "${topic}" "${partitions}" "${replication}" >"${topic_file}"
SCRIPT

cat >"${configs_bin}" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

arg_value() {
  local expected="$1"
  shift
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "${expected}" ]]; then
      [[ $# -ge 2 ]] || return 1
      printf '%s' "$2"
      return 0
    fi
    shift
  done
  return 1
}

topic="$(arg_value --entity-name "$@")"
config_file="${MOCK_KAFKA_STATE}/${topic}.config"
if [[ " $* " == *" --describe "* ]]; then
  [[ -f "${config_file}" ]] || exit 1
  cat "${config_file}"
  exit 0
fi

[[ " $* " == *" --alter "* ]] || exit 2
printf '%s\n' "$(arg_value --add-config "$@")" >"${config_file}"
SCRIPT
chmod 0755 "${topics_bin}" "${configs_bin}"

run_apply() {
  local inventory="$1" command_config="${2:-}"
  MOCK_KAFKA_STATE="${state_dir}" \
    KAFKA_ADMIN_BOOTSTRAP=mock-kafka.internal:9092 \
    KAFKA_TOPICS_BIN="${topics_bin}" \
    KAFKA_CONFIGS_BIN="${configs_bin}" \
    KAFKA_ADMIN_COMMAND_CONFIG="${command_config}" \
    bash "${RECONCILE}" --apply "${inventory}"
}

first_apply="$(run_apply "${INVENTORY}")"
grep -Fq 'topic=conversation-domain-events action=created' <<<"${first_apply}" \
  || fail "event_topic_not_created"
grep -Fq 'topic=conversation-domain-events-dead-letter action=created' <<<"${first_apply}" \
  || fail "dead_letter_topic_not_created"

second_apply="$(run_apply "${INVENTORY}")"
grep -Fq 'topic=conversation-domain-events action=verified' <<<"${second_apply}" \
  || fail "event_topic_not_verified"
grep -Fq 'topic=conversation-domain-events-dead-letter action=verified' <<<"${second_apply}" \
  || fail "dead_letter_topic_not_verified"

command_config="${TMP_DIR}/admin.properties"
printf 'security.protocol=PLAINTEXT\n' >"${command_config}"
command_config_apply="$(run_apply "${INVENTORY}" "${command_config}")"
grep -Fq 'topic=conversation-domain-events action=verified' <<<"${command_config_apply}" \
  || fail "command_config_apply_not_verified"

drift_inventory="${TMP_DIR}/partition-drift.env"
cp "${INVENTORY}" "${drift_inventory}"
perl -0pi -e 's/^IM_KAFKA_EVENT_TOPIC_PARTITIONS=48$/IM_KAFKA_EVENT_TOPIC_PARTITIONS=49/m' "${drift_inventory}"
if run_apply "${drift_inventory}" >"${TMP_DIR}/partition-drift.log" 2>&1; then
  fail "existing_partition_drift_accepted"
fi
grep -Fq 'existing_topic_partition_drift_conversation-domain-events' "${TMP_DIR}/partition-drift.log" \
  || fail "existing_partition_drift_reason_missing"

if MOCK_KAFKA_DESCRIBE_FAILURE='broker transport unavailable' \
  MOCK_KAFKA_STATE="${state_dir}" \
  KAFKA_ADMIN_BOOTSTRAP=mock-kafka.internal:9092 \
  KAFKA_TOPICS_BIN="${topics_bin}" \
  KAFKA_CONFIGS_BIN="${configs_bin}" \
  bash "${RECONCILE}" --apply "${INVENTORY}" >"${TMP_DIR}/broker-error.log" 2>&1; then
  fail "broker_describe_error_accepted_as_missing_topic"
fi
grep -Fq 'topic_describe_failed_conversation-domain-events' "${TMP_DIR}/broker-error.log" \
  || fail "broker_describe_error_reason_missing"

printf 'kafka-topic-reconcile-test result=pass\n'
