#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

install -d -m 0755 /etc/redis
if [[ -f /etc/redis/redis.conf ]]; then
  cp /etc/redis/redis.conf /etc/redis/redis.conf.bak.$(date +%Y%m%d%H%M%S)
  sed -i 's/^supervised .*/supervised systemd/' /etc/redis/redis.conf
  sed -i 's/^bind .*/bind 127.0.0.1 ::1/' /etc/redis/redis.conf
  sed -i 's/^protected-mode .*/protected-mode yes/' /etc/redis/redis.conf
  sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/' /etc/redis/redis.conf
  sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
fi

systemctl enable --now redis-server
systemctl restart redis-server

redis-cli ping
echo "Redis is ready on 127.0.0.1:6379."

