#!/usr/bin/env bash
set -euo pipefail

services=(
  postgresql
  redis-server
  kafka
  imserver-gateway
  imserver-command-api
  imserver-query-api
  imserver-outbox-relay
  imserver-stream-consumer
  nginx
)

for service in "${services[@]}"; do
  printf "%-32s " "${service}"
  systemctl is-active "${service}" || true
done

echo
echo "Recent IMServer logs:"
journalctl -u imserver-gateway -u imserver-command-api -u imserver-query-api -u imserver-outbox-relay -u imserver-stream-consumer -n 80 --no-pager

