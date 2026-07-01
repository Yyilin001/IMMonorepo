#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SSH_ACCESS_SELF_TEST="${SSH_ACCESS_SELF_TEST:-false}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-root}"
SSH_ALLOW_CIDR="${SSH_ALLOW_CIDR:-any}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
SSH_PASSWORD_AUTHENTICATION="${SSH_PASSWORD_AUTHENTICATION:-no}"
SSH_PERMIT_ROOT_LOGIN="${SSH_PERMIT_ROOT_LOGIN:-prohibit-password}"
SSH_REPAIR_CONFIG_FILE="${SSH_REPAIR_CONFIG_FILE:-/etc/ssh/sshd_config.d/99-imserver-access.conf}"
SSH_REPAIR_REPORT="${SSH_REPAIR_REPORT:-/var/log/imserver/ssh-access-repair.log}"

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

ssh_service_name() {
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    printf 'ssh\n'
  elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
    printf 'sshd\n'
  else
    printf 'ssh\n'
  fi
}

render_sshd_config() {
  cat <<EOF
Port ${SSH_PORT}
PubkeyAuthentication yes
PasswordAuthentication ${SSH_PASSWORD_AUTHENTICATION}
PermitRootLogin ${SSH_PERMIT_ROOT_LOGIN}
AuthorizedKeysFile .ssh/authorized_keys
KbdInteractiveAuthentication no
UsePAM yes
EOF
}

user_home_dir() {
  local user="$1"
  getent passwd "${user}" | awk -F: '{ print $6; exit }'
}

install_authorized_key() {
  local user="$1"
  local key="$2"
  local home ssh_dir authorized_keys
  [[ -n "${key//[[:space:]]/}" ]] || return 0
  home="$(user_home_dir "${user}")"
  if [[ -z "${home}" || ! -d "${home}" ]]; then
    printf 'ssh_access_repair result=fail reason=user_home_missing user=%s\n' "${user}" >&2
    return 1
  fi
  ssh_dir="${home}/.ssh"
  authorized_keys="${ssh_dir}/authorized_keys"
  install -d -m 0700 -o "${user}" -g "$(id -gn "${user}")" "${ssh_dir}"
  touch "${authorized_keys}"
  chown "${user}:$(id -gn "${user}")" "${authorized_keys}"
  chmod 0600 "${authorized_keys}"
  if ! grep -qxF "${key}" "${authorized_keys}"; then
    printf '%s\n' "${key}" >>"${authorized_keys}"
  fi
}

ufw_allow_ssh() {
  if ! command -v ufw >/dev/null 2>&1; then
    printf 'ssh_access_repair ufw=skipped reason=missing\n'
    return 0
  fi
  if [[ "${SSH_ALLOW_CIDR}" == "any" || "${SSH_ALLOW_CIDR}" == "0.0.0.0/0" ]]; then
    ufw allow "${SSH_PORT}/tcp" comment "ssh"
  else
    ufw allow from "${SSH_ALLOW_CIDR}" to any port "${SSH_PORT}" proto tcp comment "ssh"
  fi
}

tcp_listener_open() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk -v port=":${port}" 'NR > 1 && index($4, port) > 0 { found=1 } END { exit found ? 0 : 1 }'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn | awk -v port=":${port}" 'NR > 2 && index($4, port) > 0 { found=1 } END { exit found ? 0 : 1 }'
  else
    return 2
  fi
}

run_self_test() {
  local output
  output="$(SSH_PORT=2222 SSH_PASSWORD_AUTHENTICATION=no SSH_PERMIT_ROOT_LOGIN=prohibit-password render_sshd_config)"
  grep -q '^Port 2222$' <<<"${output}" || {
    printf 'ssh_access_self_test result=fail reason=port_missing\n' >&2
    return 1
  }
  grep -q '^PubkeyAuthentication yes$' <<<"${output}" || {
    printf 'ssh_access_self_test result=fail reason=pubkey_missing\n' >&2
    return 1
  }
  grep -q '^PasswordAuthentication no$' <<<"${output}" || {
    printf 'ssh_access_self_test result=fail reason=password_auth_mismatch\n' >&2
    return 1
  }
  grep -q '^PermitRootLogin prohibit-password$' <<<"${output}" || {
    printf 'ssh_access_self_test result=fail reason=root_login_mismatch\n' >&2
    return 1
  }
  printf 'ssh_access_self_test result=pass\n'
}

if bool_enabled "${SSH_ACCESS_SELF_TEST}"; then
  run_self_test
  exit 0
fi

require_root
install -d -m 0755 "$(dirname "${SSH_REPAIR_REPORT}")"
{
  printf 'ssh_access_repair startedAt=%s sshPort=%s sshUser=%s allowCIDR=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${SSH_PORT}" \
    "${SSH_USER}" \
    "${SSH_ALLOW_CIDR}"

  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    apt-get update
    apt-get install -y openssh-server
  fi

  install -d -m 0755 "$(dirname "${SSH_REPAIR_CONFIG_FILE}")"
  render_sshd_config >"${SSH_REPAIR_CONFIG_FILE}"
  chmod 0644 "${SSH_REPAIR_CONFIG_FILE}"
  sshd -t

  install_authorized_key "${SSH_USER}" "${SSH_AUTHORIZED_KEY}"
  service_name="$(ssh_service_name)"
  systemctl enable --now "${service_name}"
  systemctl restart "${service_name}"
  ufw_allow_ssh

  if tcp_listener_open "${SSH_PORT}"; then
    printf 'ssh_access_repair result=pass service=%s port=%s config=%s\n' \
      "${service_name}" \
      "${SSH_PORT}" \
      "${SSH_REPAIR_CONFIG_FILE}"
  else
    printf 'ssh_access_repair result=fail reason=listener_not_open service=%s port=%s\n' \
      "${service_name}" \
      "${SSH_PORT}" >&2
    exit 1
  fi
} 2>&1 | tee "${SSH_REPAIR_REPORT}"
