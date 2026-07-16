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
  imserver-domain-delivery-consumer
  nginx
)

for service in "${services[@]}"; do
  printf "%-32s " "${service}"
  systemctl is-active "${service}" || true
done

echo
echo "Stream consumer instances:"
systemctl --no-pager --plain --type=service --all list-units 'imserver-stream-consumer@*.service' || true

echo
echo "Recent IMServer logs:"
journalctl -u imserver-gateway -u imserver-command-api -u imserver-query-api -u imserver-outbox-relay -u imserver-stream-consumer -u imserver-domain-delivery-consumer -n 80 --no-pager
while IFS= read -r unit; do
  [[ -n "${unit}" ]] || continue
  journalctl -u "${unit}" -n 80 --no-pager
done < <(
  systemctl list-units --all --type=service --no-legend --plain 'imserver-stream-consumer@*.service' 2>/dev/null \
    | awk '{print $1}'
)
