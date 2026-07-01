#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ENV_FILE="${ENV_FILE:-${IMSERVER_ETC_DIR}/common.env}"
IM_PUBLIC_HTTP_PORT="${IM_PUBLIC_HTTP_PORT:-${HTTP_PORT:-$(imserver_default_public_http_port)}}"
IM_TCP_PORT="${IM_TCP_PORT:-${TCP_PORT:-9000}}"
SSH_PORT="${SSH_PORT:-22}"
SSH_ALLOW_CIDR="${SSH_ALLOW_CIDR:-any}"
HTTP_ALLOW_CIDR="${HTTP_ALLOW_CIDR:-any}"
TCP_ALLOW_CIDR="${TCP_ALLOW_CIDR:-any}"
ENABLE_UFW="${ENABLE_UFW:-true}"
UFW_RESET="${UFW_RESET:-false}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
ENABLE_UNATTENDED_UPGRADES="${ENABLE_UNATTENDED_UPGRADES:-true}"
ENABLE_TIME_SYNC="${ENABLE_TIME_SYNC:-true}"
IM_HOST_SECURITY_PROFILE="${IM_HOST_SECURITY_PROFILE:-bootstrap}"
IM_HOST_SECURITY_ALLOW_WEAKENED="${IM_HOST_SECURITY_ALLOW_WEAKENED:-false}"
IM_HOST_SECURITY_DENY_RDP="${IM_HOST_SECURITY_DENY_RDP:-true}"
IM_HOST_SECURITY_PUBLIC_BROAD_IPV4_MAX_PREFIX="${IM_HOST_SECURITY_PUBLIC_BROAD_IPV4_MAX_PREFIX:-8}"
IM_HOST_SECURITY_PUBLIC_BROAD_IPV6_MAX_PREFIX="${IM_HOST_SECURITY_PUBLIC_BROAD_IPV6_MAX_PREFIX:-16}"
IM_HOST_SECURITY_SELF_TEST="${IM_HOST_SECURITY_SELF_TEST:-false}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_public_cidr() {
  local cidr="${1:-}"
  python3 - "${cidr}" "${IM_HOST_SECURITY_PUBLIC_BROAD_IPV4_MAX_PREFIX}" "${IM_HOST_SECURITY_PUBLIC_BROAD_IPV6_MAX_PREFIX}" <<'PY'
import ipaddress
import sys

cidr = (sys.argv[1] or "").strip().lower()
ipv4_limit = int(sys.argv[2])
ipv6_limit = int(sys.argv[3])
if cidr in {"", "any", "anywhere", "internet", "0.0.0.0/0", "::/0", "*"}:
    raise SystemExit(0)
try:
    network = ipaddress.ip_network(cidr, strict=False)
except ValueError:
    raise SystemExit(1)
if network.version == 4:
    if network.prefixlen > ipv4_limit:
        raise SystemExit(1)
    probes = (
        ipaddress.ip_address("1.1.1.1"),
        ipaddress.ip_address("8.8.8.8"),
        ipaddress.ip_address("101.6.6.6"),
        ipaddress.ip_address("223.5.5.5"),
    )
    raise SystemExit(0 if network.is_global or any(probe in network for probe in probes) else 1)
if network.version == 6:
    if network.prefixlen > ipv6_limit:
        raise SystemExit(1)
    probes = (
        ipaddress.ip_address("2606:4700:4700::1111"),
        ipaddress.ip_address("2001:4860:4860::8888"),
    )
    raise SystemExit(0 if network.is_global or any(probe in network for probe in probes) else 1)
raise SystemExit(1)
PY
}

validate_host_security_config() {
  case "${IM_HOST_SECURITY_PROFILE}" in
    bootstrap|production) ;;
    *)
      printf 'host-security result=fail reason=invalid_profile profile=%s\n' "${IM_HOST_SECURITY_PROFILE}" >&2
      return 2
      ;;
  esac

  if [[ "${IM_HOST_SECURITY_PROFILE}" != "production" ]]; then
    return 0
  fi

  if is_public_cidr "${SSH_ALLOW_CIDR}" && ! bool_enabled "${IM_HOST_SECURITY_ALLOW_WEAKENED}"; then
    printf 'host-security result=fail reason=ssh_cidr_required_for_production sshAllowCIDR=%s action=set SSH_ALLOW_CIDR=<admin-ip>/32 or IM_HOST_SECURITY_PROFILE=bootstrap for temporary recovery\n' "${SSH_ALLOW_CIDR}" >&2
    return 2
  fi

  if ! bool_enabled "${IM_HOST_SECURITY_ALLOW_WEAKENED}"; then
    if ! bool_enabled "${ENABLE_UFW}"; then
      printf 'host-security result=fail reason=ufw_required_for_production action=set ENABLE_UFW=true or IM_HOST_SECURITY_ALLOW_WEAKENED=true\n' >&2
      return 2
    fi
    if ! bool_enabled "${ENABLE_FAIL2BAN}"; then
      printf 'host-security result=fail reason=fail2ban_required_for_production action=set ENABLE_FAIL2BAN=true or IM_HOST_SECURITY_ALLOW_WEAKENED=true\n' >&2
      return 2
    fi
    if ! bool_enabled "${ENABLE_UNATTENDED_UPGRADES}"; then
      printf 'host-security result=fail reason=unattended_upgrades_required_for_production action=set ENABLE_UNATTENDED_UPGRADES=true or IM_HOST_SECURITY_ALLOW_WEAKENED=true\n' >&2
      return 2
    fi
    if ! bool_enabled "${ENABLE_TIME_SYNC}"; then
      printf 'host-security result=fail reason=time_sync_required_for_production action=set ENABLE_TIME_SYNC=true or IM_HOST_SECURITY_ALLOW_WEAKENED=true\n' >&2
      return 2
    fi
  fi
}

run_self_test() {
  local old_profile="${IM_HOST_SECURITY_PROFILE}"
  local old_ssh_allow="${SSH_ALLOW_CIDR}"
  local old_enable_ufw="${ENABLE_UFW}"
  local old_enable_fail2ban="${ENABLE_FAIL2BAN}"
  local old_enable_unattended="${ENABLE_UNATTENDED_UPGRADES}"
  local old_enable_time_sync="${ENABLE_TIME_SYNC}"
  local old_weakened="${IM_HOST_SECURITY_ALLOW_WEAKENED}"
  local self_test_dir prod_env actual

  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "${self_test_dir}"' RETURN
  prod_env="${self_test_dir}/production.env"
  printf 'APP_ENV=production\n' >"${prod_env}"
  actual="$(ENV_FILE="${prod_env}" APP_ENV= IMSERVER_RUN_ENV=development imserver_default_public_http_port)"
  [[ "${actual}" == "80" ]] || {
    printf 'host-security-self-test result=fail reason=production_default_http_port_invalid value=%s\n' "${actual}" >&2
    return 1
  }
  actual="$(ENV_FILE="${self_test_dir}/missing.env" APP_ENV= IMSERVER_RUN_ENV=development imserver_default_public_http_port)"
  [[ "${actual}" == "8080" ]] || {
    printf 'host-security-self-test result=fail reason=development_default_http_port_invalid value=%s\n' "${actual}" >&2
    return 1
  }

  IM_HOST_SECURITY_PROFILE=bootstrap
  SSH_ALLOW_CIDR=any
  IM_HOST_SECURITY_ALLOW_WEAKENED=false
  validate_host_security_config

  IM_HOST_SECURITY_PROFILE=production
  SSH_ALLOW_CIDR=203.0.113.10/32
  ENABLE_UFW=true
  ENABLE_FAIL2BAN=true
  ENABLE_UNATTENDED_UPGRADES=true
  ENABLE_TIME_SYNC=true
  IM_HOST_SECURITY_ALLOW_WEAKENED=false
  validate_host_security_config

  IM_HOST_SECURITY_PROFILE=production
  SSH_ALLOW_CIDR=0.0.0.0/0
  if validate_host_security_config >/tmp/im-host-security-self-test.log 2>&1; then
    printf 'host-security-self-test result=fail reason=public_ssh_allowed_in_production\n' >&2
    return 1
  fi
  grep -q 'reason=ssh_cidr_required_for_production' /tmp/im-host-security-self-test.log

  IM_HOST_SECURITY_PROFILE=production
  SSH_ALLOW_CIDR=47.0.0.0/8
  if validate_host_security_config >/tmp/im-host-security-self-test.log 2>&1; then
    printf 'host-security-self-test result=fail reason=broad_public_ssh_allowed_in_production\n' >&2
    return 1
  fi
  grep -q 'reason=ssh_cidr_required_for_production' /tmp/im-host-security-self-test.log

  IM_HOST_SECURITY_PROFILE=production
  SSH_ALLOW_CIDR=10.0.0.0/8
  validate_host_security_config

  IM_HOST_SECURITY_PROFILE=production
  SSH_ALLOW_CIDR=0.0.0.0/0
  IM_HOST_SECURITY_ALLOW_WEAKENED=true
  validate_host_security_config

  IM_HOST_SECURITY_PROFILE=production
  SSH_ALLOW_CIDR=203.0.113.10/32
  IM_HOST_SECURITY_ALLOW_WEAKENED=false
  ENABLE_UFW=false
  if validate_host_security_config >/tmp/im-host-security-self-test.log 2>&1; then
    printf 'host-security-self-test result=fail reason=ufw_skip_allowed_in_production\n' >&2
    return 1
  fi
  grep -q 'reason=ufw_required_for_production' /tmp/im-host-security-self-test.log
  ENABLE_UFW=true
  ENABLE_TIME_SYNC=false
  if validate_host_security_config >/tmp/im-host-security-self-test.log 2>&1; then
    printf 'host-security-self-test result=fail reason=time_sync_skip_allowed_in_production\n' >&2
    return 1
  fi
  grep -q 'reason=time_sync_required_for_production' /tmp/im-host-security-self-test.log
  rm -f /tmp/im-host-security-self-test.log

  IM_HOST_SECURITY_PROFILE="${old_profile}"
  SSH_ALLOW_CIDR="${old_ssh_allow}"
  ENABLE_UFW="${old_enable_ufw}"
  ENABLE_FAIL2BAN="${old_enable_fail2ban}"
  ENABLE_UNATTENDED_UPGRADES="${old_enable_unattended}"
  ENABLE_TIME_SYNC="${old_enable_time_sync}"
  IM_HOST_SECURITY_ALLOW_WEAKENED="${old_weakened}"
  printf 'host-security-self-test result=pass\n'
}

ufw_allow() {
  local cidr="$1"
  local port="$2"
  local comment="$3"
  if [[ "${cidr}" == "any" || "${cidr}" == "0.0.0.0/0" ]]; then
    ufw allow "${port}/tcp" comment "${comment}"
  else
    ufw allow from "${cidr}" to any port "${port}" proto tcp comment "${comment}"
  fi
}

systemd_unit_exists() {
  local unit="$1"
  systemctl list-unit-files --type=service --no-legend "${unit}" 2>/dev/null | awk -v unit="${unit}" '$1 == unit { found=1 } END { exit found ? 0 : 1 }'
}

if bool_enabled "${IM_HOST_SECURITY_SELF_TEST}"; then
  run_self_test
  exit 0
fi

validate_host_security_config
require_root

if bool_enabled "${ENABLE_UFW}"; then
  if bool_enabled "${UFW_RESET}"; then
    ufw --force reset
  fi
  ufw default deny incoming
  ufw default allow outgoing
  if bool_enabled "${IM_HOST_SECURITY_DENY_RDP}"; then
    ufw --force delete allow 3389/tcp >/dev/null 2>&1 || true
    ufw deny 3389/tcp comment "deny-rdp"
  fi
  ufw_allow "${SSH_ALLOW_CIDR}" "${SSH_PORT}" "ssh"
  ufw_allow "${HTTP_ALLOW_CIDR}" "${IM_PUBLIC_HTTP_PORT}" "imserver-http"
  ufw_allow "${TCP_ALLOW_CIDR}" "${IM_TCP_PORT}" "imserver-tcp"
  ufw --force enable
  ufw status verbose
else
  printf 'host-security ufw=skipped\n'
fi

if bool_enabled "${ENABLE_FAIL2BAN}"; then
  install -d -m 0755 /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/imserver-sshd.conf <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban
else
  printf 'host-security fail2ban=skipped\n'
fi

if bool_enabled "${ENABLE_UNATTENDED_UPGRADES}"; then
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  systemctl enable --now unattended-upgrades
else
  printf 'host-security unattended-upgrades=skipped\n'
fi

if bool_enabled "${ENABLE_TIME_SYNC}"; then
  timedatectl set-ntp true || true
  if systemd_unit_exists systemd-timesyncd.service; then
    systemctl enable --now systemd-timesyncd
  elif systemd_unit_exists chrony.service; then
    systemctl enable --now chrony
  elif systemd_unit_exists chronyd.service; then
    systemctl enable --now chronyd
  else
    printf 'host-security result=fail reason=time_sync_service_missing action=install systemd-timesyncd or chrony\n' >&2
    exit 2
  fi
  timedatectl status || true
else
  printf 'host-security time-sync=skipped\n'
fi

printf 'host-security result=pass profile=%s sshPort=%s sshAllowCIDR=%s httpPort=%s tcpPort=%s denyRDP=%s\n' \
  "${IM_HOST_SECURITY_PROFILE}" \
  "${SSH_PORT}" \
  "${SSH_ALLOW_CIDR}" \
  "${IM_PUBLIC_HTTP_PORT}" \
  "${IM_TCP_PORT}" \
  "${IM_HOST_SECURITY_DENY_RDP}"
