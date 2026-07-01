#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

IM_TCP_SOMAXCONN="${IM_TCP_SOMAXCONN:-8192}"
IM_TCP_MAX_SYN_BACKLOG="${IM_TCP_MAX_SYN_BACKLOG:-8192}"
IM_TCP_IP_LOCAL_PORT_LOW="${IM_TCP_IP_LOCAL_PORT_LOW:-10000}"
IM_TCP_IP_LOCAL_PORT_HIGH="${IM_TCP_IP_LOCAL_PORT_HIGH:-65000}"
IM_TCP_FIN_TIMEOUT="${IM_TCP_FIN_TIMEOUT:-15}"
IM_TCP_KEEPALIVE_TIME="${IM_TCP_KEEPALIVE_TIME:-60}"
IM_TCP_KEEPALIVE_INTVL="${IM_TCP_KEEPALIVE_INTVL:-15}"
IM_TCP_KEEPALIVE_PROBES="${IM_TCP_KEEPALIVE_PROBES:-4}"
IM_FILE_MAX="${IM_FILE_MAX:-2097152}"
IM_NR_OPEN="${IM_NR_OPEN:-2097152}"
IMSERVER_LIMIT_NOFILE="${IMSERVER_LIMIT_NOFILE:-1048576}"

sysctl_conf="/etc/sysctl.d/99-imserver-long-connection.conf"
limits_conf="/etc/security/limits.d/99-imserver.conf"

cat > "${sysctl_conf}" <<EOF
# IMServer long-connection defaults.
# Keep these aligned with deploy/ubuntu/50_install_systemd_units.sh and capacity tests.
fs.file-max = ${IM_FILE_MAX}
fs.nr_open = ${IM_NR_OPEN}
net.core.somaxconn = ${IM_TCP_SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${IM_TCP_MAX_SYN_BACKLOG}
net.ipv4.tcp_synack_retries = 5
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.ip_local_port_range = ${IM_TCP_IP_LOCAL_PORT_LOW} ${IM_TCP_IP_LOCAL_PORT_HIGH}
net.ipv4.tcp_fin_timeout = ${IM_TCP_FIN_TIMEOUT}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = ${IM_TCP_KEEPALIVE_TIME}
net.ipv4.tcp_keepalive_intvl = ${IM_TCP_KEEPALIVE_INTVL}
net.ipv4.tcp_keepalive_probes = ${IM_TCP_KEEPALIVE_PROBES}
EOF

cat > "${limits_conf}" <<EOF
# IMServer service user file descriptor limits.
${IMSERVER_USER} soft nofile ${IMSERVER_LIMIT_NOFILE}
${IMSERVER_USER} hard nofile ${IMSERVER_LIMIT_NOFILE}
EOF

sysctl -p "${sysctl_conf}"

printf 'Kernel tuning installed: %s\n' "${sysctl_conf}"
printf 'Limits installed: %s\n' "${limits_conf}"
printf 'somaxconn=%s tcp_max_syn_backlog=%s nofile=%s\n' \
  "${IM_TCP_SOMAXCONN}" \
  "${IM_TCP_MAX_SYN_BACKLOG}" \
  "${IMSERVER_LIMIT_NOFILE}"
