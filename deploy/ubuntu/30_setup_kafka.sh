#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

if ! command -v java >/dev/null 2>&1; then
  apt-get update
  apt-get install -y openjdk-21-jre-headless
fi

ensure_user kafka kafka "${KAFKA_HOME}"
install -d -o kafka -g kafka -m 0755 "${KAFKA_HOME}" "${KAFKA_DATA_DIR}" "${KAFKA_LOG_DIR}" /etc/kafka/kraft

archive_name="kafka_${KAFKA_SCALA_VERSION}-${KAFKA_VERSION}.tgz"
download_url="https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${archive_name}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

if [[ ! -x "${KAFKA_HOME}/bin/kafka-server-start.sh" ]]; then
  curl -fSL "${download_url}" -o "${tmp_dir}/${archive_name}"
  tar -xzf "${tmp_dir}/${archive_name}" -C "${tmp_dir}"
  rsync -a --delete "${tmp_dir}/kafka_${KAFKA_SCALA_VERSION}-${KAFKA_VERSION}/" "${KAFKA_HOME}/"
  chown -R kafka:kafka "${KAFKA_HOME}"
fi

cluster_id_file="/etc/kafka/kraft/cluster.id"
if [[ ! -f "${cluster_id_file}" ]]; then
  "${KAFKA_HOME}/bin/kafka-storage.sh" random-uuid > "${cluster_id_file}"
fi
cluster_id="$(cat "${cluster_id_file}")"

cat > /etc/kafka/kraft/server.properties <<EOF
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@127.0.0.1:9093
listeners=PLAINTEXT://127.0.0.1:9092,CONTROLLER://127.0.0.1:9093
advertised.listeners=PLAINTEXT://127.0.0.1:9092
controller.listener.names=CONTROLLER
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
inter.broker.listener.name=PLAINTEXT
log.dirs=${KAFKA_DATA_DIR}
num.network.threads=2
num.io.threads=2
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
num.partitions=6
default.replication.factor=1
min.insync.replicas=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
log.retention.hours=72
log.segment.bytes=268435456
log.retention.check.interval.ms=300000
auto.create.topics.enable=false
EOF

cat > /etc/default/kafka <<EOF
KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS}"
KAFKA_JVM_PERFORMANCE_OPTS="-server -XX:+UseG1GC -XX:MaxGCPauseMillis=50 -XX:InitiatingHeapOccupancyPercent=35"
EOF

cat > /etc/systemd/system/kafka.service <<EOF
[Unit]
Description=Apache Kafka single-node KRaft broker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=kafka
Group=kafka
EnvironmentFile=/etc/default/kafka
ExecStartPre=${KAFKA_HOME}/bin/kafka-storage.sh format --ignore-formatted --cluster-id ${cluster_id} --config /etc/kafka/kraft/server.properties
ExecStart=${KAFKA_HOME}/bin/kafka-server-start.sh /etc/kafka/kraft/server.properties
ExecStop=${KAFKA_HOME}/bin/kafka-server-stop.sh
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now kafka
sleep 5

"${KAFKA_HOME}/bin/kafka-topics.sh" --bootstrap-server 127.0.0.1:9092 --create --if-not-exists --topic conversation-domain-events --partitions 6 --replication-factor 1
"${KAFKA_HOME}/bin/kafka-topics.sh" --bootstrap-server 127.0.0.1:9092 --create --if-not-exists --topic conversation-domain-events-dead-letter --partitions 3 --replication-factor 1

echo "Kafka is ready on 127.0.0.1:9092."
