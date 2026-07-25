#!/usr/bin/env bash
set -Eeuo pipefail

# Applies the host-level limits required for high-concurrency IM capacity tests.
# Run as root on a temporary load generator or gateway host.

ROLE="${1:-}"
SYSCTL_FILE="/etc/sysctl.d/99-im-capacity-test.conf"
LIMITS_FILE="/etc/security/limits.d/99-im-capacity-test.conf"

fail() {
  echo "configure_capacity_host result=fail reason=$1" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || fail "must_run_as_root"
case "${ROLE}" in
  gateway|load-generator) ;;
  *) fail "usage=$0 gateway|load-generator" ;;
esac

cat >"${SYSCTL_FILE}" <<'EOF'
# IM capacity-test baseline. Keep this file scoped to disposable test hosts.
fs.file-max = 2097152
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
EOF

if [[ "${ROLE}" == "load-generator" ]]; then
  cat >>"${SYSCTL_FILE}" <<'EOF'
# One source IP needs enough ephemeral ports for tens of thousands of TCP clients.
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
EOF
fi

cat >"${LIMITS_FILE}" <<'EOF'
# The load driver and gateway both require more than the default 65k descriptors.
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

sysctl --system >/dev/null

echo "configure_capacity_host result=pass role=${ROLE}"
sysctl \
  fs.file-max \
  net.core.somaxconn \
  net.ipv4.tcp_max_syn_backlog \
  net.ipv4.tcp_max_tw_buckets \
  net.ipv4.ip_local_port_range \
  net.ipv4.tcp_fin_timeout \
  net.ipv4.tcp_tw_reuse 2>/dev/null || true
