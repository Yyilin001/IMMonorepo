#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

IMSERVER_LOGROTATE_RETENTION_DAYS="${IMSERVER_LOGROTATE_RETENTION_DAYS:-14}"
NGINX_LOGROTATE_RETENTION_DAYS="${NGINX_LOGROTATE_RETENTION_DAYS:-14}"
JOURNAL_SYSTEM_MAX_USE="${JOURNAL_SYSTEM_MAX_USE:-1G}"
JOURNAL_MAX_RETENTION_SEC="${JOURNAL_MAX_RETENTION_SEC:-14day}"

ensure_user "${IMSERVER_USER}" "${IMSERVER_GROUP}" "${IMSERVER_HOME}"
install -d -o "${IMSERVER_USER}" -g "${IMSERVER_GROUP}" -m 0755 "${IMSERVER_LOG_DIR}"
install -d -m 0755 /etc/systemd/journald.conf.d

cat > /etc/logrotate.d/imserver <<EOF
${IMSERVER_LOG_DIR}/*.log {
    daily
    rotate ${IMSERVER_LOGROTATE_RETENTION_DAYS}
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 ${IMSERVER_USER} ${IMSERVER_GROUP}
}

/var/log/nginx/imserver_*.log {
    daily
    rotate ${NGINX_LOGROTATE_RETENTION_DAYS}
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -s /run/nginx.pid ] && kill -USR1 \$(cat /run/nginx.pid)
    endscript
}
EOF

cat > /etc/systemd/journald.conf.d/imserver.conf <<EOF
[Journal]
SystemMaxUse=${JOURNAL_SYSTEM_MAX_USE}
MaxRetentionSec=${JOURNAL_MAX_RETENTION_SEC}
Compress=yes
EOF

systemctl restart systemd-journald
logrotate -d /etc/logrotate.d/imserver >/dev/null

printf 'Log rotation installed: /etc/logrotate.d/imserver\n'
printf 'Journald retention installed: /etc/systemd/journald.conf.d/imserver.conf\n'
