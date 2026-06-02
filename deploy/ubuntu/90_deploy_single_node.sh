#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo bash "${SCRIPT_DIR}/00_install_dependencies.sh"
sudo bash "${SCRIPT_DIR}/05_setup_swap.sh"
sudo bash "${SCRIPT_DIR}/10_setup_postgres.sh"
sudo bash "${SCRIPT_DIR}/20_setup_redis.sh"
sudo bash "${SCRIPT_DIR}/30_setup_kafka.sh"
sudo systemctl stop imserver-gateway imserver-command-api imserver-query-api imserver-outbox-relay imserver-stream-consumer imserver-domain-delivery-consumer 2>/dev/null || true
sudo systemctl stop kafka 2>/dev/null || true
sudo bash "${SCRIPT_DIR}/40_build_imserver.sh"
sudo bash "${SCRIPT_DIR}/50_install_systemd_units.sh"
sudo bash "${SCRIPT_DIR}/60_install_nginx.sh"

sudo systemctl start kafka
sudo systemctl start imserver-command-api
sudo systemctl start imserver-gateway imserver-query-api imserver-outbox-relay imserver-stream-consumer imserver-domain-delivery-consumer
sudo bash "${SCRIPT_DIR}/70_status.sh"
