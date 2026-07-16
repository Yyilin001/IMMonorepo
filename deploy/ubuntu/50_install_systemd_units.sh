#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SYSTEMD_UNITS_RENDER_SELF_TEST="${SYSTEMD_UNITS_RENDER_SELF_TEST:-false}"

if [[ "${SYSTEMD_UNITS_RENDER_SELF_TEST}" == "true" ]]; then
  python3 - "${BASH_SOURCE[0]}" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")

required = {
    "IMSERVER_TASKS_MAX": "tasks_max_config_missing",
    "CPUAccounting=true": "cpu_accounting_missing",
    "MemoryAccounting=true": "memory_accounting_missing",
    "TasksMax=${IMSERVER_TASKS_MAX}": "tasks_max_missing",
    "NoNewPrivileges=true": "no_new_privileges_missing",
    "PrivateTmp=true": "private_tmp_missing",
    "PrivateDevices=true": "private_devices_missing",
    "ProtectSystem=full": "protect_system_missing",
    "ProtectHome=true": "protect_home_missing",
    "ProtectKernelTunables=true": "protect_kernel_tunables_missing",
    "ProtectKernelModules=true": "protect_kernel_modules_missing",
    "ProtectControlGroups=true": "protect_control_groups_missing",
    "RestrictSUIDSGID=true": "restrict_suid_sgid_missing",
    "RestrictRealtime=true": "restrict_realtime_missing",
    "RestrictNamespaces=true": "restrict_namespaces_missing",
    "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6": "restrict_address_families_missing",
    "LockPersonality=true": "lock_personality_missing",
    "SystemCallArchitectures=native": "system_call_arch_missing",
    "CapabilityBoundingSet=": "capability_bounding_set_missing",
    "AmbientCapabilities=": "ambient_capabilities_missing",
}
for needle, reason in required.items():
    if needle not in text:
        raise SystemExit(f"systemd-units-render-self-test result=fail reason={reason}")

for unit in (
    "imserver-gateway",
    "imserver-command-api",
    "imserver-query-api",
    "imserver-outbox-relay",
    "imserver-stream-consumer",
    "imserver-stream-consumer@",
    "imserver-domain-delivery-consumer",
):
    if f"/etc/systemd/system/{unit}.service" not in text:
        raise SystemExit(f"systemd-units-render-self-test result=fail reason=unit_missing unit={unit}")

print("systemd-units-render-self-test result=pass")
PY
  exit 0
fi

require_root

ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
IM_PUBLIC_HTTP_PORT="${IM_PUBLIC_HTTP_PORT:-${HTTP_PORT:-$(imserver_default_public_http_port)}}"
IM_GATEWAY_HTTP_PORT="${IM_GATEWAY_HTTP_PORT:-18080}"
IM_COMMAND_API_PORT="${IM_COMMAND_API_PORT:-8081}"
IM_QUERY_API_PORT="${IM_QUERY_API_PORT:-8082}"
IM_TCP_PORT="${IM_TCP_PORT:-9000}"
IMSERVER_LIMIT_NOFILE="${IMSERVER_LIMIT_NOFILE:-1048576}"
IMSERVER_TASKS_MAX="${IMSERVER_TASKS_MAX:-65535}"
IMSERVER_HEALTHCHECK_RETRIES="${IMSERVER_HEALTHCHECK_RETRIES:-30}"
IMSERVER_HEALTHCHECK_INTERVAL_SECONDS="${IMSERVER_HEALTHCHECK_INTERVAL_SECONDS:-1}"
IMSERVER_ENABLE_DEFAULT_UNITS="${IMSERVER_ENABLE_DEFAULT_UNITS:-true}"

ensure_user "${IMSERVER_USER}" "${IMSERVER_GROUP}" "${IMSERVER_HOME}"
install -d -o root -g root -m 0750 "${IMSERVER_ETC_DIR}" "${IMSERVER_ETC_DIR}/roles"
install -d -o "${IMSERVER_USER}" -g "${IMSERVER_GROUP}" -m 0755 "${IMSERVER_LOG_DIR}" "${IMSERVER_HOME}"

common_env="${IMSERVER_ETC_DIR}/common.env"
if [[ ! -f "${common_env}" ]]; then
  jwt_secret="$(random_secret)"
  internal_secret="$(random_secret)"
  cat > "${common_env}" <<EOF
APP_ENV=${IMSERVER_RUN_ENV}
LOG_LEVEL=info
JWT_SECRETS=active:${jwt_secret}
JWT_ACTIVE_KID=active
IM_INTERNAL_SHARED_SECRET=${internal_secret}

REDIS_URL=redis://127.0.0.1:6379
IM_REDIS_MAX_CONNECTIONS=16
IM_METRICS_ENABLED=true
IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT=200
IM_CONSISTENCY_REPAIR_ENABLED=false

DATABASE_HOST=127.0.0.1
DATABASE_PORT=5432
DATABASE_USERNAME=${POSTGRES_USER}
DATABASE_PASSWORD=${POSTGRES_PASSWORD}
DATABASE_NAME=${POSTGRES_DB}

DATABASE_PRIMARY_HOST=127.0.0.1
DATABASE_PRIMARY_PORT=5432
DATABASE_PRIMARY_USERNAME=${POSTGRES_USER}
DATABASE_PRIMARY_PASSWORD=${POSTGRES_PASSWORD}
DATABASE_PRIMARY_NAME=${POSTGRES_DB}

IM_CONVERSATION_SHARD_IDS=shard-0
DATABASE_CONVERSATION_SHARD_0_HOST=127.0.0.1
DATABASE_CONVERSATION_SHARD_0_PORT=5432
DATABASE_CONVERSATION_SHARD_0_USERNAME=${POSTGRES_USER}
DATABASE_CONVERSATION_SHARD_0_PASSWORD=${POSTGRES_PASSWORD}
DATABASE_CONVERSATION_SHARD_0_NAME=${POSTGRES_DB}

IM_SUMMARY_SHARD_IDS=summary-a
DATABASE_SUMMARY_SUMMARY_A_HOST=127.0.0.1
DATABASE_SUMMARY_SUMMARY_A_PORT=5432
DATABASE_SUMMARY_SUMMARY_A_USERNAME=${POSTGRES_USER}
DATABASE_SUMMARY_SUMMARY_A_PASSWORD=${POSTGRES_PASSWORD}
DATABASE_SUMMARY_SUMMARY_A_NAME=${POSTGRES_DB}
IM_SUMMARY_PROJECTION_WRITE_MODE=sharded
IM_SUMMARY_QUERY_READ_SOURCE=sharded

IM_EVENT_STREAM_DRIVER=kafka
IM_KAFKA_BROKERS=127.0.0.1:9092
IM_KAFKA_TOPIC=conversation-domain-events
IM_KAFKA_DEAD_LETTER_TOPIC=conversation-domain-events-dead-letter
IM_KAFKA_REQUIRED_ACKS=all
IM_KAFKA_COMPRESSION=none
IM_KAFKA_AUTO_CREATE_TOPICS=false
IM_KAFKA_SECURITY_PROTOCOL=plaintext

IM_SEARCH_DRIVER=database

SEED_USER_EMAILS=demo@example.com,alice@example.com,bob@example.com,carol@example.com,dave@example.com
SEED_USER_PASSWORD=password1234

# For APP_ENV=production, configure S3-compatible object storage before starting command-api.
# MEDIA_STORAGE_PROVIDER=s3compatible
# MEDIA_STORAGE_S3_ENDPOINT=https://<your-object-storage-domain>
# MEDIA_STORAGE_S3_BUCKET=im-media
# MEDIA_STORAGE_S3_ACCESS_KEY_ID=replace-me
# MEDIA_STORAGE_S3_SECRET_ACCESS_KEY=replace-me
# MEDIA_STORAGE_S3_REGION=cn-shenzhen
# MEDIA_STORAGE_S3_FORCE_PATH_STYLE=true
MEDIA_STORAGE_PROVIDER=local
MEDIA_STORAGE_DIRECTORY=${IMSERVER_HOME}/media
EOF
else
  echo "${common_env} already exists; leaving it unchanged."
fi
chown root:root "${common_env}"
chmod 0640 "${common_env}"

cat > "${IMSERVER_ETC_DIR}/roles/gateway.env" <<EOF
IM_NODE_ID=gateway-1
IM_COMMAND_API_INTERNAL_BASE_URL=http://127.0.0.1:${IM_COMMAND_API_PORT}
IM_GATEWAY_RELAY_MODE=local
IM_TCP_PORT=${IM_TCP_PORT}
IM_TCP_LISTEN_BACKLOG=${IM_TCP_LISTEN_BACKLOG:-8192}
IM_TCP_MAX_CONNECTIONS=${IM_TCP_MAX_CONNECTIONS:-20000}
IM_TCP_MAX_NEW_CONNECTIONS_PER_SECOND=${IM_TCP_MAX_NEW_CONNECTIONS_PER_SECOND:-500}
IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE=${IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE:-true}
EOF

cat > "${IMSERVER_ETC_DIR}/roles/command-api.env" <<EOF
IM_NODE_ID=command-api-1
IM_GATEWAY_RELAY_MODE=http
IM_GATEWAY_INTERNAL_BASE_URL=http://127.0.0.1:${IM_GATEWAY_HTTP_PORT}
IM_KAFKA_CLIENT_ID=im-command-api
EOF

cat > "${IMSERVER_ETC_DIR}/roles/query-api.env" <<EOF
IM_NODE_ID=query-api-1
EOF

cat > "${IMSERVER_ETC_DIR}/roles/outbox-relay.env" <<EOF
IM_NODE_ID=outbox-relay-1
IM_KAFKA_CLIENT_ID=im-outbox-relay
IM_OUTBOX_BATCH_SIZE=100
IM_OUTBOX_POLL_INTERVAL_MS=500
IM_OUTBOX_MAX_RETRIES=5
IM_OUTBOX_CLAIM_TIMEOUT_MS=60000
EOF

cat > "${IMSERVER_ETC_DIR}/roles/stream-consumer.env" <<EOF
IM_NODE_ID=stream-consumer-1
IM_KAFKA_CLIENT_ID=im-stream-consumer
IM_STREAM_CONSUMER_GROUPS=summary-projection-consumer
EOF

cat > "${IMSERVER_ETC_DIR}/roles/domain-delivery-consumer.env" <<EOF
IM_NODE_ID=domain-delivery-consumer-1
IM_KAFKA_CLIENT_ID=im-domain-delivery-consumer
IM_STREAM_CONSUMER_GROUPS=domain-delivery-consumer
IM_GATEWAY_RELAY_MODE=http
IM_GATEWAY_INTERNAL_BASE_URL=http://127.0.0.1:${IM_GATEWAY_HTTP_PORT}
EOF

cat > "${IMSERVER_ETC_DIR}/roles/ops.env" <<EOF
IM_NODE_ID=ops-1
EOF

chown root:root "${IMSERVER_ETC_DIR}" "${IMSERVER_ETC_DIR}/roles" "${IMSERVER_ETC_DIR}"/roles/*.env
chmod 0750 "${IMSERVER_ETC_DIR}" "${IMSERVER_ETC_DIR}/roles"
chmod 0640 "${IMSERVER_ETC_DIR}"/roles/*.env

healthcheck_command() {
  local url="$1"
  printf "/bin/bash -lc 'for i in {1..%s}; do curl -fsS --max-time 2 %q >/dev/null && exit 0; sleep %s; done; exit 1'" \
    "${IMSERVER_HEALTHCHECK_RETRIES}" \
    "${url}" \
    "${IMSERVER_HEALTHCHECK_INTERVAL_SECONDS}"
}

write_service_common() {
  cat <<EOF
Restart=always
RestartSec=3
TimeoutStartSec=60
TimeoutStopSec=30
KillMode=mixed
KillSignal=SIGTERM
OOMPolicy=stop
LimitNOFILE=${IMSERVER_LIMIT_NOFILE}
CPUAccounting=true
MemoryAccounting=true
TasksMax=${IMSERVER_TASKS_MAX}
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${IMSERVER_HOME} ${IMSERVER_LOG_DIR} /tmp
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
EOF
}

service_common="$(write_service_common)"

cat > /etc/systemd/system/imserver-gateway.service <<EOF
[Unit]
Description=IMServer gateway
After=network-online.target postgresql.service redis-server.service imserver-command-api.service
Wants=network-online.target imserver-command-api.service
StartLimitIntervalSec=120
StartLimitBurst=10

[Service]
User=${IMSERVER_USER}
Group=${IMSERVER_GROUP}
WorkingDirectory=${IMSERVER_HOME}
EnvironmentFile=${common_env}
EnvironmentFile=${IMSERVER_ETC_DIR}/roles/gateway.env
ExecStart=${IMSERVER_BIN_DIR}/IMServer serve --role gateway --hostname 127.0.0.1 --port ${IM_GATEWAY_HTTP_PORT}
ExecStartPost=$(healthcheck_command "http://127.0.0.1:${IM_GATEWAY_HTTP_PORT}/health")
${service_common}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/imserver-command-api.service <<EOF
[Unit]
Description=IMServer command-api
After=network-online.target postgresql.service redis-server.service kafka.service
Wants=network-online.target kafka.service
StartLimitIntervalSec=120
StartLimitBurst=10

[Service]
User=${IMSERVER_USER}
Group=${IMSERVER_GROUP}
WorkingDirectory=${IMSERVER_HOME}
EnvironmentFile=${common_env}
EnvironmentFile=${IMSERVER_ETC_DIR}/roles/command-api.env
ExecStart=${IMSERVER_BIN_DIR}/IMServer serve --role command-api --hostname 127.0.0.1 --port ${IM_COMMAND_API_PORT}
ExecStartPost=$(healthcheck_command "http://127.0.0.1:${IM_COMMAND_API_PORT}/health")
${service_common}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/imserver-query-api.service <<EOF
[Unit]
Description=IMServer query-api
After=network-online.target postgresql.service redis-server.service
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=10

[Service]
User=${IMSERVER_USER}
Group=${IMSERVER_GROUP}
WorkingDirectory=${IMSERVER_HOME}
EnvironmentFile=${common_env}
EnvironmentFile=${IMSERVER_ETC_DIR}/roles/query-api.env
ExecStart=${IMSERVER_BIN_DIR}/IMServer serve --role query-api --hostname 127.0.0.1 --port ${IM_QUERY_API_PORT}
ExecStartPost=$(healthcheck_command "http://127.0.0.1:${IM_QUERY_API_PORT}/health")
${service_common}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/imserver-outbox-relay.service <<EOF
[Unit]
Description=IMServer outbox relay
After=network-online.target postgresql.service kafka.service
Wants=network-online.target kafka.service
StartLimitIntervalSec=120
StartLimitBurst=10

[Service]
User=${IMSERVER_USER}
Group=${IMSERVER_GROUP}
WorkingDirectory=${IMSERVER_HOME}
EnvironmentFile=${common_env}
EnvironmentFile=${IMSERVER_ETC_DIR}/roles/outbox-relay.env
ExecStart=${IMSERVER_BIN_DIR}/IMServer outbox-relay
${service_common}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/imserver-stream-consumer.service <<EOF
[Unit]
Description=IMServer stream consumer
After=network-online.target postgresql.service kafka.service
Wants=network-online.target kafka.service
StartLimitIntervalSec=120
StartLimitBurst=10

[Service]
User=${IMSERVER_USER}
Group=${IMSERVER_GROUP}
WorkingDirectory=${IMSERVER_HOME}
EnvironmentFile=${common_env}
EnvironmentFile=${IMSERVER_ETC_DIR}/roles/stream-consumer.env
ExecStart=${IMSERVER_BIN_DIR}/IMServer stream-consumer
${service_common}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/imserver-stream-consumer@.service <<EOF
[Unit]
Description=IMServer stream consumer (%i)
After=network-online.target postgresql.service kafka.service
Wants=network-online.target kafka.service
StartLimitIntervalSec=120
StartLimitBurst=10

[Service]
User=${IMSERVER_USER}
Group=${IMSERVER_GROUP}
WorkingDirectory=${IMSERVER_HOME}
EnvironmentFile=${common_env}
EnvironmentFile=${IMSERVER_ETC_DIR}/roles/stream-consumer-%i.env
ExecStart=${IMSERVER_BIN_DIR}/IMServer stream-consumer
${service_common}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/imserver-domain-delivery-consumer.service <<EOF
[Unit]
Description=IMServer domain delivery stream consumer
After=network-online.target postgresql.service redis-server.service kafka.service imserver-gateway.service
Wants=network-online.target kafka.service
StartLimitIntervalSec=120
StartLimitBurst=10

[Service]
User=${IMSERVER_USER}
Group=${IMSERVER_GROUP}
WorkingDirectory=${IMSERVER_HOME}
EnvironmentFile=${common_env}
EnvironmentFile=${IMSERVER_ETC_DIR}/roles/domain-delivery-consumer.env
ExecStart=${IMSERVER_BIN_DIR}/IMServer stream-consumer
${service_common}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
if bool_enabled "${IMSERVER_ENABLE_DEFAULT_UNITS}"; then
  systemctl enable imserver-gateway imserver-command-api imserver-query-api imserver-outbox-relay imserver-stream-consumer imserver-domain-delivery-consumer
else
  echo "Skipped enabling default units because IMSERVER_ENABLE_DEFAULT_UNITS=false."
fi

echo "Installed systemd units. Start them with:"
echo "  systemctl start imserver-gateway imserver-command-api imserver-query-api imserver-outbox-relay imserver-stream-consumer imserver-domain-delivery-consumer"
echo "  systemctl enable --now imserver-stream-consumer@realtime_delivery_consumer"
echo "Review ${common_env} before switching APP_ENV to production."
