#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

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
JWT_SECRET=${jwt_secret}
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
# MEDIA_STORAGE_S3_ENDPOINT=https://oss.example
# MEDIA_STORAGE_S3_BUCKET=im-media
# MEDIA_STORAGE_S3_ACCESS_KEY_ID=replace-me
# MEDIA_STORAGE_S3_SECRET_ACCESS_KEY=replace-me
# MEDIA_STORAGE_S3_REGION=cn-shenzhen
# MEDIA_STORAGE_S3_FORCE_PATH_STYLE=true
MEDIA_STORAGE_PROVIDER=local
MEDIA_STORAGE_DIRECTORY=${IMSERVER_HOME}/media
EOF
  chmod 0640 "${common_env}"
else
  echo "${common_env} already exists; leaving it unchanged."
fi

cat > "${IMSERVER_ETC_DIR}/roles/gateway.env" <<EOF
IM_NODE_ID=gateway-1
IM_COMMAND_API_INTERNAL_BASE_URL=http://127.0.0.1:8081
IM_GATEWAY_RELAY_MODE=local
EOF

cat > "${IMSERVER_ETC_DIR}/roles/command-api.env" <<EOF
IM_NODE_ID=command-api-1
IM_GATEWAY_RELAY_MODE=http
IM_GATEWAY_INTERNAL_BASE_URL=http://127.0.0.1:8080
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

chmod 0640 "${IMSERVER_ETC_DIR}"/roles/*.env

cat > /etc/systemd/system/imserver-gateway.service <<EOF
[Unit]
Description=IMServer gateway
After=network-online.target postgresql.service redis-server.service
Wants=network-online.target

[Service]
User=${IMSERVER_USER}
Group=${IMSERVER_GROUP}
WorkingDirectory=${IMSERVER_HOME}
EnvironmentFile=${common_env}
EnvironmentFile=${IMSERVER_ETC_DIR}/roles/gateway.env
ExecStart=${IMSERVER_BIN_DIR}/IMServer serve --role gateway --hostname 127.0.0.1 --port 18080
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/imserver-command-api.service <<EOF
[Unit]
Description=IMServer command-api
After=network-online.target postgresql.service redis-server.service kafka.service
Wants=network-online.target kafka.service

[Service]
User=${IMSERVER_USER}
Group=${IMSERVER_GROUP}
WorkingDirectory=${IMSERVER_HOME}
EnvironmentFile=${common_env}
EnvironmentFile=${IMSERVER_ETC_DIR}/roles/command-api.env
ExecStart=${IMSERVER_BIN_DIR}/IMServer serve --role command-api --hostname 127.0.0.1 --port 8081
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/imserver-query-api.service <<EOF
[Unit]
Description=IMServer query-api
After=network-online.target postgresql.service redis-server.service
Wants=network-online.target

[Service]
User=${IMSERVER_USER}
Group=${IMSERVER_GROUP}
WorkingDirectory=${IMSERVER_HOME}
EnvironmentFile=${common_env}
EnvironmentFile=${IMSERVER_ETC_DIR}/roles/query-api.env
ExecStart=${IMSERVER_BIN_DIR}/IMServer serve --role query-api --hostname 127.0.0.1 --port 8082
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/imserver-outbox-relay.service <<EOF
[Unit]
Description=IMServer outbox relay
After=network-online.target postgresql.service kafka.service
Wants=network-online.target kafka.service

[Service]
User=${IMSERVER_USER}
Group=${IMSERVER_GROUP}
WorkingDirectory=${IMSERVER_HOME}
EnvironmentFile=${common_env}
EnvironmentFile=${IMSERVER_ETC_DIR}/roles/outbox-relay.env
ExecStart=${IMSERVER_BIN_DIR}/IMServer outbox-relay
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/imserver-stream-consumer.service <<EOF
[Unit]
Description=IMServer stream consumer
After=network-online.target postgresql.service kafka.service
Wants=network-online.target kafka.service

[Service]
User=${IMSERVER_USER}
Group=${IMSERVER_GROUP}
WorkingDirectory=${IMSERVER_HOME}
EnvironmentFile=${common_env}
EnvironmentFile=${IMSERVER_ETC_DIR}/roles/stream-consumer.env
ExecStart=${IMSERVER_BIN_DIR}/IMServer stream-consumer
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable imserver-gateway imserver-command-api imserver-query-api imserver-outbox-relay imserver-stream-consumer

echo "Installed systemd units. Start them with:"
echo "  systemctl start imserver-gateway imserver-command-api imserver-query-api imserver-outbox-relay imserver-stream-consumer"
echo "Review ${common_env} before switching APP_ENV to production."
