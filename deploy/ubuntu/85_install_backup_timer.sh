#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

BACKUP_TIMER_RENDER_SELF_TEST="${BACKUP_TIMER_RENDER_SELF_TEST:-false}"
BACKUP_TIMER_REQUIRE_ROOT="${BACKUP_TIMER_REQUIRE_ROOT:-true}"
BACKUP_TIMER_ENABLE="${BACKUP_TIMER_ENABLE:-true}"
BACKUP_SYSTEMD_DIR="${BACKUP_SYSTEMD_DIR:-/etc/systemd/system}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/imserver}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
BACKUP_CALENDAR="${BACKUP_CALENDAR:-*-*-* 03:15:00}"
BACKUP_RANDOMIZED_DELAY_SEC="${BACKUP_RANDOMIZED_DELAY_SEC:-900}"
BACKUP_LOG_FILE="${BACKUP_LOG_FILE:-${IMSERVER_LOG_DIR}/backup.log}"
OFFSITE_BACKUP_DESTINATION="${OFFSITE_BACKUP_DESTINATION:-}"
OFFSITE_BACKUP_RECEIPT_FILE="${OFFSITE_BACKUP_RECEIPT_FILE:-/var/lib/imserver/offsite-backup/latest.json}"
AUDIT_ALERT_ENV_FILE="${AUDIT_ALERT_ENV_FILE:-${IMSERVER_ETC_DIR}/operational-alert.env}"
repo="$(repo_root)"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

if bool_enabled "${BACKUP_TIMER_RENDER_SELF_TEST}"; then
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' EXIT
  BACKUP_TIMER_RENDER_SELF_TEST=false \
  BACKUP_TIMER_REQUIRE_ROOT=false \
  BACKUP_TIMER_ENABLE=false \
  BACKUP_SYSTEMD_DIR="${self_test_dir}/systemd" \
  BACKUP_ROOT="${self_test_dir}/backups" \
  BACKUP_RETENTION_DAYS=9 \
  BACKUP_CALENDAR="*-*-* 02:00:00" \
  BACKUP_RANDOMIZED_DELAY_SEC=123 \
  BACKUP_LOG_FILE="${self_test_dir}/logs/backup.log" \
  AUDIT_ALERT_ENV_FILE="${self_test_dir}/etc/operational-alert.env" \
    bash "${BASH_SOURCE[0]}" >"${self_test_dir}/render.log"
  service_file="${self_test_dir}/systemd/imserver-backup.service"
  alert_file="${self_test_dir}/systemd/imserver-backup-alert@.service"
  timer_file="${self_test_dir}/systemd/imserver-backup.timer"
  [[ -f "${service_file}" && -f "${alert_file}" && -f "${timer_file}" ]] || {
    printf 'backup_timer_render_self_test result=fail reason=unit_missing\n' >&2
    exit 1
  }
  grep -Fq "Environment=BACKUP_ROOT=${self_test_dir}/backups" "${service_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=backup_root_missing\n' >&2
    exit 1
  }
  grep -Fq 'Environment=BACKUP_RETENTION_DAYS=9' "${service_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=retention_missing\n' >&2
    exit 1
  }
  grep -Fq "ExecStart=/bin/bash ${repo}/deploy/ubuntu/80_backup_single_node.sh" "${service_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=backup_exec_missing\n' >&2
    exit 1
  }
  grep -Fq "ExecStartPost=/bin/bash ${repo}/deploy/ubuntu/81_verify_backup.sh" "${service_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=verify_exec_missing\n' >&2
    exit 1
  }
  if grep -Fq "ExecStartPost=/bin/bash ${repo}/deploy/ubuntu/86_sync_backup_offsite.sh" "${service_file}"; then
    printf 'backup_timer_render_self_test result=fail reason=offsite_exec_unexpected_without_destination\n' >&2
    exit 1
  fi
  grep -Fq 'OnFailure=imserver-backup-alert@%n.service' "${service_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=on_failure_missing\n' >&2
    exit 1
  }
  grep -Fq "StandardOutput=append:${self_test_dir}/logs/backup.log" "${service_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=stdout_log_missing\n' >&2
    exit 1
  }
  grep -Fq "StandardError=append:${self_test_dir}/logs/backup.log" "${service_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=stderr_log_missing\n' >&2
    exit 1
  }
  grep -Fq "EnvironmentFile=-${self_test_dir}/etc/operational-alert.env" "${alert_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=alert_env_missing\n' >&2
    exit 1
  }
  grep -Fq "Environment=AUDIT_ALERT_LOG_FILE=${self_test_dir}/logs/backup.log" "${alert_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=alert_log_missing\n' >&2
    exit 1
  }
  grep -Fq "ExecStart=/bin/bash ${repo}/deploy/ubuntu/79_send_operational_alert.sh %I" "${alert_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=alert_exec_missing\n' >&2
    exit 1
  }
  grep -Fq 'Nice=10' "${service_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=nice_missing\n' >&2
    exit 1
  }
  grep -Fq 'IOSchedulingClass=best-effort' "${service_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=io_scheduling_missing\n' >&2
    exit 1
  }
  grep -Fq 'OnCalendar=*-*-* 02:00:00' "${timer_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=calendar_missing\n' >&2
    exit 1
  }
  grep -Fq 'RandomizedDelaySec=123' "${timer_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=random_delay_missing\n' >&2
    exit 1
  }
  grep -Fq 'Persistent=true' "${timer_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=persistent_missing\n' >&2
    exit 1
  }
  grep -Fq 'Unit=imserver-backup.service' "${timer_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=unit_reference_missing\n' >&2
    exit 1
  }
  offsite_dir="${self_test_dir}/offsite"
  BACKUP_TIMER_RENDER_SELF_TEST=false \
  BACKUP_TIMER_REQUIRE_ROOT=false \
  BACKUP_TIMER_ENABLE=false \
  BACKUP_SYSTEMD_DIR="${self_test_dir}/systemd-offsite" \
  BACKUP_ROOT="${self_test_dir}/backups" \
  BACKUP_LOG_FILE="${self_test_dir}/logs/backup-offsite.log" \
  OFFSITE_BACKUP_DESTINATION="${offsite_dir}" \
  OFFSITE_BACKUP_RECEIPT_FILE="${self_test_dir}/receipt/offsite.json" \
  AUDIT_ALERT_ENV_FILE="${self_test_dir}/etc/operational-alert.env" \
    bash "${BASH_SOURCE[0]}" >"${self_test_dir}/render-offsite.log"
  offsite_service_file="${self_test_dir}/systemd-offsite/imserver-backup.service"
  grep -Fq "Environment=OFFSITE_BACKUP_DESTINATION=${offsite_dir}" "${offsite_service_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=offsite_destination_missing\n' >&2
    exit 1
  }
  grep -Fq "Environment=OFFSITE_BACKUP_RECEIPT_FILE=${self_test_dir}/receipt/offsite.json" "${offsite_service_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=offsite_receipt_missing\n' >&2
    exit 1
  }
  grep -Fq "ExecStartPost=/bin/bash ${repo}/deploy/ubuntu/86_sync_backup_offsite.sh" "${offsite_service_file}" || {
    printf 'backup_timer_render_self_test result=fail reason=offsite_exec_missing\n' >&2
    exit 1
  }
  printf 'backup_timer_render_self_test result=pass\n'
  exit 0
fi

if bool_enabled "${BACKUP_TIMER_REQUIRE_ROOT}"; then
  require_root
fi

if bool_enabled "${BACKUP_TIMER_REQUIRE_ROOT}"; then
  install -d -o root -g root -m 0700 "${BACKUP_ROOT}"
  install -d -o root -g root -m 0755 "$(dirname "${BACKUP_LOG_FILE}")"
else
  mkdir -p "${BACKUP_ROOT}"
  chmod 0700 "${BACKUP_ROOT}"
  mkdir -p "$(dirname "${BACKUP_LOG_FILE}")"
fi
touch "${BACKUP_LOG_FILE}"
if bool_enabled "${BACKUP_TIMER_REQUIRE_ROOT}"; then
  chown root:adm "${BACKUP_LOG_FILE}" 2>/dev/null || chown root:root "${BACKUP_LOG_FILE}"
fi
chmod 0640 "${BACKUP_LOG_FILE}"

mkdir -p "${BACKUP_SYSTEMD_DIR}"

cat > "${BACKUP_SYSTEMD_DIR}/imserver-backup.service" <<EOF
[Unit]
Description=IMServer single-node backup
Documentation=file://${repo}/deploy/ubuntu/README.md
Wants=network-online.target
After=network-online.target postgresql.service
OnFailure=imserver-backup-alert@%n.service

[Service]
Type=oneshot
Environment=BACKUP_ROOT=${BACKUP_ROOT}
Environment=BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS}
Environment=OFFSITE_BACKUP_DESTINATION=${OFFSITE_BACKUP_DESTINATION}
Environment=OFFSITE_BACKUP_RECEIPT_FILE=${OFFSITE_BACKUP_RECEIPT_FILE}
ExecStart=/bin/bash ${repo}/deploy/ubuntu/80_backup_single_node.sh
ExecStartPost=/bin/bash ${repo}/deploy/ubuntu/81_verify_backup.sh
$(if [[ -n "${OFFSITE_BACKUP_DESTINATION}" ]]; then printf 'ExecStartPost=/bin/bash %s/deploy/ubuntu/86_sync_backup_offsite.sh\n' "${repo}"; fi)
StandardOutput=append:${BACKUP_LOG_FILE}
StandardError=append:${BACKUP_LOG_FILE}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

cat > "${BACKUP_SYSTEMD_DIR}/imserver-backup-alert@.service" <<EOF
[Unit]
Description=Send IMServer backup alert for %I
Documentation=file://${repo}/deploy/ubuntu/README.md

[Service]
Type=oneshot
EnvironmentFile=-${AUDIT_ALERT_ENV_FILE}
Environment=AUDIT_ALERT_LOG_FILE=${BACKUP_LOG_FILE}
ExecStart=/bin/bash ${repo}/deploy/ubuntu/79_send_operational_alert.sh %I
EOF

cat > "${BACKUP_SYSTEMD_DIR}/imserver-backup.timer" <<EOF
[Unit]
Description=Run IMServer single-node backup daily

[Timer]
OnCalendar=${BACKUP_CALENDAR}
RandomizedDelaySec=${BACKUP_RANDOMIZED_DELAY_SEC}
Persistent=true
Unit=imserver-backup.service

[Install]
WantedBy=timers.target
EOF

if bool_enabled "${BACKUP_TIMER_ENABLE}"; then
  systemctl daemon-reload
  systemctl enable --now imserver-backup.timer
  systemctl list-timers --no-pager imserver-backup.timer || true
fi

printf 'Backup timer installed: OnCalendar=%s RandomizedDelaySec=%s BackupRoot=%s RetentionDays=%s LogFile=%s OffsiteEnabled=%s OffsiteReceipt=%s Enabled=%s\n' \
  "${BACKUP_CALENDAR}" \
  "${BACKUP_RANDOMIZED_DELAY_SEC}" \
  "${BACKUP_ROOT}" \
  "${BACKUP_RETENTION_DAYS}" \
  "${BACKUP_LOG_FILE}" \
  "$([[ -n "${OFFSITE_BACKUP_DESTINATION}" ]] && printf true || printf false)" \
  "${OFFSITE_BACKUP_RECEIPT_FILE}" \
  "${BACKUP_TIMER_ENABLE}"
