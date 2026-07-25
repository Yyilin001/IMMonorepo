#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDER="${ROOT_DIR}/deploy/multinode/render_env.sh"
VALIDATE_SET="${ROOT_DIR}/deploy/multinode/validate_inventory_set.sh"
VALIDATE_MULTICELL_SET="${ROOT_DIR}/deploy/multinode/validate_multicell_inventory_set.sh"
PREFLIGHT_MULTICELL_SET="${ROOT_DIR}/deploy/multinode/preflight_multicell_inventory_set.sh"
PREFLIGHT_SET="${ROOT_DIR}/deploy/multinode/preflight_inventory_set.sh"
PREFLIGHT="${ROOT_DIR}/IMServer/scripts/production_env_preflight.sh"
KAFKA_RECONCILE="${ROOT_DIR}/deploy/multinode/reconcile_kafka_topics.sh"
KAFKA_RECONCILE_TEST="${ROOT_DIR}/deploy/multinode/reconcile_kafka_topics_test.sh"
INVENTORY="${ROOT_DIR}/deploy/multinode/inventory.example.env"
SYSTEMD_RENDER="${ROOT_DIR}/deploy/ubuntu/50_install_systemd_units.sh"
SYSTEMD_VERIFY="${ROOT_DIR}/deploy/ubuntu/52_verify_systemd_units.sh"
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'multinode-render-test result=fail reason=%s\n' "$1" >&2
  exit 1
}

expect_file() {
  [[ -f "$1" ]] || fail "missing_file_${1}"
}

expect_contains() {
  local file="$1" needle="$2"
  grep -Fqx "${needle}" "${file}" || fail "missing_value_${needle}"
}

run_preflight() {
  local output_dir="$1"
  "${PREFLIGHT}" \
    --command-api "${output_dir}/preflight/command-api.env" \
    --gateway "${output_dir}/preflight/gateway.env" \
    --query-api "${output_dir}/preflight/query-api.env" \
    --outbox-relay "${output_dir}/preflight/outbox-relay.env" \
    --ops "${output_dir}/preflight/maintenance.env" \
    --stream-consumer "${output_dir}/preflight/stream-consumer-summary_projection_consumer.env" \
    --stream-consumer "${output_dir}/preflight/stream-consumer-domain_delivery_consumer.env" \
    --stream-consumer "${output_dir}/preflight/stream-consumer-realtime_delivery_consumer.env" \
    --stream-consumer "${output_dir}/preflight/stream-consumer-changes_log_consumer.env" \
    --stream-consumer "${output_dir}/preflight/stream-consumer-search_index_consumer.env" \
    --stream-consumer "${output_dir}/preflight/stream-consumer-notification_consumer.env" \
    --stream-consumer "${output_dir}/preflight/stream-consumer-repair_replay_consumer.env" \
    --require-groups summary-projection-consumer,domain-delivery-consumer,realtime-delivery-consumer,changes-log-consumer,search-index-consumer,notification-consumer,repair-replay-consumer
}

bash -n "${RENDER}"
bash -n "${VALIDATE_SET}"
bash -n "${VALIDATE_MULTICELL_SET}"
bash -n "${PREFLIGHT_SET}"
bash -n "${PREFLIGHT}"
bash -n "${KAFKA_RECONCILE}"
bash -n "${KAFKA_RECONCILE_TEST}"
SYSTEMD_UNITS_RENDER_SELF_TEST=true bash "${SYSTEMD_RENDER}"
SYSTEMD_UNIT_VERIFY_SELF_TEST=true bash "${SYSTEMD_VERIFY}"

output_dir="${TMP_DIR}/rendered"
"${RENDER}" "${INVENTORY}" "${output_dir}"

for role in \
  gateway command-api query-api outbox-relay ops maintenance \
  stream-consumer-summary_projection_consumer \
  stream-consumer-realtime_delivery_consumer \
  stream-consumer-domain_delivery_consumer \
  stream-consumer-changes_log_consumer \
  stream-consumer-search_index_consumer \
  stream-consumer-notification_consumer \
  stream-consumer-repair_replay_consumer
do
  expect_file "${output_dir}/roles/${role}.env"
  expect_file "${output_dir}/preflight/${role}.env"
done

expect_contains "${output_dir}/preflight/gateway.env" "IM_REDIS_DEPLOYMENT_TOPOLOGY=cluster"
expect_contains "${output_dir}/preflight/gateway.env" "IM_NODE_DISPATCH_MODE=valkey-stream"
expect_contains "${output_dir}/preflight/gateway.env" "IM_NODE_ID=gateway-node-a"
expect_contains "${output_dir}/preflight/gateway.env" "IM_TCP_MAX_CONNECTIONS=20000"
expect_contains "${output_dir}/preflight/gateway.env" "IM_TCP_MAX_NEW_CONNECTIONS_PER_SECOND=500"
expect_contains "${output_dir}/preflight/gateway.env" "IM_KAFKA_EVENT_TOPIC_PARTITIONS=48"
expect_contains "${output_dir}/preflight/gateway.env" "IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS=2"
expect_contains "${output_dir}/preflight/gateway.env" "IM_CELL_INGRESS_COMMAND_ENDPOINTS=cell-shenzhen-a=https://command-api-cell-shenzhen-a.internal"
expect_contains "${output_dir}/preflight/gateway.env" "IM_CELL_INGRESS_QUERY_ENDPOINTS=cell-shenzhen-a=https://query-api-cell-shenzhen-a.internal"
expect_contains "${output_dir}/preflight/gateway.env" "IM_CELL_INGRESS_REALTIME_ENDPOINTS=cell-shenzhen-a=https://gateway-cell-shenzhen-a.internal"
expect_contains "${output_dir}/preflight/command-api.env" "IM_COMMAND_NODE_ID=node-a"
expect_contains "${output_dir}/preflight/stream-consumer-realtime_delivery_consumer.env" "IM_STREAM_CONSUMER_GROUPS=realtime-delivery-consumer"
expect_contains "${output_dir}/preflight/stream-consumer-domain_delivery_consumer.env" "IM_STREAM_CONSUMER_GROUPS=domain-delivery-consumer"
run_preflight "${output_dir}"
"${KAFKA_RECONCILE}" --validate "${INVENTORY}" >"${TMP_DIR}/kafka-topic-spec.log"
grep -Fq "eventPartitions=48" "${TMP_DIR}/kafka-topic-spec.log" || fail "kafka_topic_spec_validate_output"
bash "${KAFKA_RECONCILE_TEST}"

node_b_inventory="${TMP_DIR}/inventory.node-b.env"
cp "${INVENTORY}" "${node_b_inventory}"
perl -0pi -e 's/^IM_NODE_SUFFIX=node-a$/IM_NODE_SUFFIX=node-b/m; s/^IM_GATEWAY_NODE_ID=gateway-node-a$/IM_GATEWAY_NODE_ID=gateway-node-b/m; s/^IM_COMMAND_NODE_ID=node-a$/IM_COMMAND_NODE_ID=node-b/m; s/^IM_AVAILABILITY_ZONE=cn-south-1a$/IM_AVAILABILITY_ZONE=cn-south-1b/m' "${node_b_inventory}"
"${VALIDATE_SET}" "${INVENTORY}" "${node_b_inventory}"
"${PREFLIGHT_SET}" --allow-placeholders "${INVENTORY}" "${node_b_inventory}"
if "${PREFLIGHT_SET}" "${INVENTORY}" "${node_b_inventory}" >"${TMP_DIR}/strict-placeholders.log" 2>&1; then
  fail "strict_preflight_accepted_template_placeholders"
fi
grep -Fq "strict secrets requires" "${TMP_DIR}/strict-placeholders.log" || fail "strict_preflight_placeholder_reason"
if "${VALIDATE_SET}" "${INVENTORY}" "${INVENTORY}" >"${TMP_DIR}/duplicate-inventory.log" 2>&1; then
  fail "duplicate_inventory_accepted"
fi
grep -Fq "duplicate_node_suffix_node-a" "${TMP_DIR}/duplicate-inventory.log" || fail "duplicate_inventory_reason"

same_zone_inventory="${TMP_DIR}/inventory.node-b-same-zone.env"
cp "${node_b_inventory}" "${same_zone_inventory}"
perl -0pi -e 's/^IM_AVAILABILITY_ZONE=cn-south-1b$/IM_AVAILABILITY_ZONE=cn-south-1a/m' "${same_zone_inventory}"
if "${VALIDATE_SET}" "${INVENTORY}" "${same_zone_inventory}" >"${TMP_DIR}/same-zone.log" 2>&1; then
  fail "same_zone_replicas_accepted"
fi
grep -Fq "gateway_and_command_replicas_must_span_at_least_two_availability_zones" "${TMP_DIR}/same-zone.log" || fail "same_zone_replicas_reason"

invalid_kafka_spec_inventory="${TMP_DIR}/invalid-kafka-topic-spec.env"
cp "${INVENTORY}" "${invalid_kafka_spec_inventory}"
perl -0pi -e 's/^IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS=2$/IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS=4/m' "${invalid_kafka_spec_inventory}"
if "${RENDER}" "${invalid_kafka_spec_inventory}" "${TMP_DIR}/invalid-kafka-render" >"${TMP_DIR}/invalid-kafka.log" 2>&1; then
  fail "invalid_kafka_topic_spec_accepted"
fi
grep -Fq "IM_KAFKA_EVENT_TOPIC_MIN_IN_SYNC_REPLICAS_exceeds_replication_factor" "${TMP_DIR}/invalid-kafka.log" || fail "invalid_kafka_topic_spec_reason"

invalid_cross_cell_timeout_inventory="${TMP_DIR}/invalid-cross-cell-timeout.env"
cp "${INVENTORY}" "${invalid_cross_cell_timeout_inventory}"
perl -0pi -e 's/^IM_CROSS_CELL_REALTIME_OUTBOX_DELIVERY_TIMEOUT_SECONDS=5$/IM_CROSS_CELL_REALTIME_OUTBOX_DELIVERY_TIMEOUT_SECONDS=0/m' "${invalid_cross_cell_timeout_inventory}"
if "${RENDER}" "${invalid_cross_cell_timeout_inventory}" "${TMP_DIR}/invalid-cross-cell-timeout-render" >"${TMP_DIR}/invalid-cross-cell-timeout.log" 2>&1; then
  fail "invalid_cross_cell_timeout_accepted"
fi
grep -Fq "invalid_IM_CROSS_CELL_REALTIME_OUTBOX_DELIVERY_TIMEOUT_SECONDS" "${TMP_DIR}/invalid-cross-cell-timeout.log" || fail "invalid_cross_cell_timeout_reason"

invalid_cross_cell_retention_inventory="${TMP_DIR}/invalid-cross-cell-retention.env"
cp "${INVENTORY}" "${invalid_cross_cell_retention_inventory}"
perl -0pi -e 's/^IM_CLEANUP_CROSS_CELL_REALTIME_DISPATCH_RETENTION_DAYS=7$/IM_CLEANUP_CROSS_CELL_REALTIME_DISPATCH_RETENTION_DAYS=2/m' "${invalid_cross_cell_retention_inventory}"
if "${RENDER}" "${invalid_cross_cell_retention_inventory}" "${TMP_DIR}/invalid-cross-cell-retention-render" >"${TMP_DIR}/invalid-cross-cell-retention.log" 2>&1; then
  fail "short_cross_cell_retention_accepted"
fi
grep -Fq "IM_CLEANUP_CROSS_CELL_REALTIME_DISPATCH_RETENTION_DAYS_must_cover_event_topic_retention" "${TMP_DIR}/invalid-cross-cell-retention.log" || fail "short_cross_cell_retention_reason"

cell_b_inventory="${TMP_DIR}/inventory.cell-b.env"
cp "${INVENTORY}" "${cell_b_inventory}"
perl -0pi -e '
  s/^IM_NODE_SUFFIX=node-a$/IM_NODE_SUFFIX=cell-b-node-a/m;
  s/^IM_GATEWAY_NODE_ID=gateway-node-a$/IM_GATEWAY_NODE_ID=gateway-cell-b-node-a/m;
  s/^IM_COMMAND_NODE_ID=node-a$/IM_COMMAND_NODE_ID=cell-b-node-a/m;
  s/^IM_REALTIME_CELL_ID=cell-shenzhen-a$/IM_REALTIME_CELL_ID=cell-shenzhen-b/m;
  s/^IM_AVAILABILITY_ZONE=cn-south-1a$/IM_AVAILABILITY_ZONE=cn-south-1b/m;
  s#^IM_COMMAND_NODE_URLS=.*$#IM_COMMAND_NODE_URLS=cell-b-node-a=https://command-api-cell-b-node-a.internal:8081#m;
  s#^IM_CELL_INGRESS_COMMAND_ENDPOINTS=.*$#IM_CELL_INGRESS_COMMAND_ENDPOINTS=cell-shenzhen-a=https://command-api-cell-shenzhen-a.internal,cell-shenzhen-b=https://command-api-cell-shenzhen-b.internal#m;
  s#^IM_CELL_INGRESS_QUERY_ENDPOINTS=.*$#IM_CELL_INGRESS_QUERY_ENDPOINTS=cell-shenzhen-a=https://query-api-cell-shenzhen-a.internal,cell-shenzhen-b=https://query-api-cell-shenzhen-b.internal#m;
  s#^IM_CELL_INGRESS_REALTIME_ENDPOINTS=.*$#IM_CELL_INGRESS_REALTIME_ENDPOINTS=cell-shenzhen-a=https://gateway-cell-shenzhen-a.internal,cell-shenzhen-b=https://gateway-cell-shenzhen-b.internal#m;
  s/^DATABASE_CONVERSATION_SHARD_0_HOST=.*$/DATABASE_CONVERSATION_SHARD_0_HOST=postgres-conv-b-0.internal/m;
  s/^DATABASE_CONVERSATION_SHARD_0_NAME=.*$/DATABASE_CONVERSATION_SHARD_0_NAME=imserver_conv_b_0/m;
  s/^DATABASE_CONVERSATION_SHARD_1_HOST=.*$/DATABASE_CONVERSATION_SHARD_1_HOST=postgres-conv-b-1.internal/m;
  s/^DATABASE_CONVERSATION_SHARD_1_NAME=.*$/DATABASE_CONVERSATION_SHARD_1_NAME=imserver_conv_b_1/m;
' "${cell_b_inventory}"

cell_a_multicell_inventory="${TMP_DIR}/inventory.cell-a.env"
cp "${INVENTORY}" "${cell_a_multicell_inventory}"
perl -0pi -e '
  s#^IM_CELL_INGRESS_COMMAND_ENDPOINTS=.*$#IM_CELL_INGRESS_COMMAND_ENDPOINTS=cell-shenzhen-a=https://command-api-cell-shenzhen-a.internal,cell-shenzhen-b=https://command-api-cell-shenzhen-b.internal#m;
  s#^IM_CELL_INGRESS_QUERY_ENDPOINTS=.*$#IM_CELL_INGRESS_QUERY_ENDPOINTS=cell-shenzhen-a=https://query-api-cell-shenzhen-a.internal,cell-shenzhen-b=https://query-api-cell-shenzhen-b.internal#m;
  s#^IM_CELL_INGRESS_REALTIME_ENDPOINTS=.*$#IM_CELL_INGRESS_REALTIME_ENDPOINTS=cell-shenzhen-a=https://gateway-cell-shenzhen-a.internal,cell-shenzhen-b=https://gateway-cell-shenzhen-b.internal#m;
  s#^IM_COMMAND_NODE_URLS=.*$#IM_COMMAND_NODE_URLS=node-a=https://command-api-a.internal:8081#m;
' "${cell_a_multicell_inventory}"
"${VALIDATE_MULTICELL_SET}" "${cell_a_multicell_inventory}" "${cell_b_inventory}"
"${PREFLIGHT_MULTICELL_SET}" --allow-placeholders "${cell_a_multicell_inventory}" "${cell_b_inventory}"
if "${VALIDATE_MULTICELL_SET}" --require-ha "${cell_a_multicell_inventory}" "${cell_b_inventory}" >"${TMP_DIR}/single-node-cells.log" 2>&1; then
  fail "single_node_cells_accepted_for_ha"
fi
grep -Fq "cell_requires_at_least_two_node_inventories_cell-shenzhen-a" "${TMP_DIR}/single-node-cells.log" || fail "single_node_cells_ha_reason"

cell_a_ha_node_a="${TMP_DIR}/inventory.cell-a-ha-node-a.env"
cp "${cell_a_multicell_inventory}" "${cell_a_ha_node_a}"
perl -0pi -e 's#^IM_COMMAND_NODE_URLS=.*$#IM_COMMAND_NODE_URLS=node-a=https://command-api-a.internal:8081,node-b=https://command-api-b.internal:8081#m' "${cell_a_ha_node_a}"

cell_a_ha_node_b="${TMP_DIR}/inventory.cell-a-ha-node-b.env"
cp "${cell_a_ha_node_a}" "${cell_a_ha_node_b}"
perl -0pi -e '
  s/^IM_NODE_SUFFIX=node-a$/IM_NODE_SUFFIX=node-b/m;
  s/^IM_GATEWAY_NODE_ID=gateway-node-a$/IM_GATEWAY_NODE_ID=gateway-node-b/m;
  s/^IM_COMMAND_NODE_ID=node-a$/IM_COMMAND_NODE_ID=node-b/m;
  s/^IM_AVAILABILITY_ZONE=cn-south-1a$/IM_AVAILABILITY_ZONE=cn-south-1b/m;
' "${cell_a_ha_node_b}"

cell_b_ha_node_a="${TMP_DIR}/inventory.cell-b-ha-node-a.env"
cp "${cell_b_inventory}" "${cell_b_ha_node_a}"
perl -0pi -e 's#^IM_COMMAND_NODE_URLS=.*$#IM_COMMAND_NODE_URLS=cell-b-node-a=https://command-api-cell-b-node-a.internal:8081,cell-b-node-b=https://command-api-cell-b-node-b.internal:8081#m' "${cell_b_ha_node_a}"

cell_b_ha_node_b="${TMP_DIR}/inventory.cell-b-ha-node-b.env"
cp "${cell_b_ha_node_a}" "${cell_b_ha_node_b}"
perl -0pi -e '
  s/^IM_NODE_SUFFIX=cell-b-node-a$/IM_NODE_SUFFIX=cell-b-node-b/m;
  s/^IM_GATEWAY_NODE_ID=gateway-cell-b-node-a$/IM_GATEWAY_NODE_ID=gateway-cell-b-node-b/m;
  s/^IM_COMMAND_NODE_ID=cell-b-node-a$/IM_COMMAND_NODE_ID=cell-b-node-b/m;
  s/^IM_AVAILABILITY_ZONE=cn-south-1b$/IM_AVAILABILITY_ZONE=cn-south-1a/m;
' "${cell_b_ha_node_b}"

"${VALIDATE_MULTICELL_SET}" --require-ha \
  "${cell_a_ha_node_a}" "${cell_a_ha_node_b}" \
  "${cell_b_ha_node_a}" "${cell_b_ha_node_b}"
"${PREFLIGHT_MULTICELL_SET}" --allow-placeholders --require-ha \
  "${cell_a_ha_node_a}" "${cell_a_ha_node_b}" \
  "${cell_b_ha_node_a}" "${cell_b_ha_node_b}"

same_zone_cell_b_inventory="${TMP_DIR}/inventory.cell-b-same-zone.env"
cp "${cell_b_inventory}" "${same_zone_cell_b_inventory}"
perl -0pi -e 's/^IM_AVAILABILITY_ZONE=cn-south-1b$/IM_AVAILABILITY_ZONE=cn-south-1a/m' "${same_zone_cell_b_inventory}"
if "${VALIDATE_MULTICELL_SET}" "${cell_a_multicell_inventory}" "${same_zone_cell_b_inventory}" >"${TMP_DIR}/cross-cell-same-zone.log" 2>&1; then
  fail "cross_cell_same_zone_accepted"
fi
grep -Fq "cells_must_span_at_least_two_availability_zones" "${TMP_DIR}/cross-cell-same-zone.log" || fail "cross_cell_same_zone_reason"

reused_shard_inventory="${TMP_DIR}/inventory.cell-b-reused-shard.env"
cp "${cell_b_inventory}" "${reused_shard_inventory}"
perl -0pi -e 's/^DATABASE_CONVERSATION_SHARD_0_HOST=.*$/DATABASE_CONVERSATION_SHARD_0_HOST=postgres-conv-0.internal/m; s/^DATABASE_CONVERSATION_SHARD_0_NAME=.*$/DATABASE_CONVERSATION_SHARD_0_NAME=imserver_conv_0/m' "${reused_shard_inventory}"
if "${VALIDATE_MULTICELL_SET}" "${cell_a_multicell_inventory}" "${reused_shard_inventory}" >"${TMP_DIR}/reused-shard.log" 2>&1; then
  fail "cross_cell_reused_conversation_shard_accepted"
fi
grep -Fq "conversation_shard_database_reused_across_cells" "${TMP_DIR}/reused-shard.log" || fail "cross_cell_reused_conversation_shard_reason"

inconsistent_map_inventory="${TMP_DIR}/inventory.cell-b-inconsistent-map.env"
cp "${cell_b_inventory}" "${inconsistent_map_inventory}"
perl -0pi -e 's#command-api-cell-shenzhen-a\.internal#different-command-api-cell-shenzhen-a.internal#' "${inconsistent_map_inventory}"
if "${VALIDATE_MULTICELL_SET}" "${cell_a_multicell_inventory}" "${inconsistent_map_inventory}" >"${TMP_DIR}/inconsistent-map.log" 2>&1; then
  fail "cross_cell_inconsistent_ingress_map_accepted"
fi
grep -Fq "shared_value_mismatch_IM_CELL_INGRESS_COMMAND_ENDPOINTS" "${TMP_DIR}/inconsistent-map.log" || fail "cross_cell_inconsistent_ingress_map_reason"

printf 'multinode-render-test result=pass\n'
