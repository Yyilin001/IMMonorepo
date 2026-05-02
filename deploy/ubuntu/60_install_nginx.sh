#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

install_file_mode "${SCRIPT_DIR}/nginx/imserver.conf" /etc/nginx/conf.d/imserver.conf 0644
nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "Nginx is configured on port 8080. TCP IM gateway still listens on port 9000."
