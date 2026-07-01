#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

SWAP_FILE="${IMSERVER_SWAP_FILE:-/swapfile}"
SWAP_SIZE_GB="${IMSERVER_SWAP_SIZE_GB:-6}"
required_kb=$((SWAP_SIZE_GB * 1024 * 1024))

current_kb=0
if [[ -f "${SWAP_FILE}" ]]; then
  current_kb="$(stat -c '%s' "${SWAP_FILE}")"
  current_kb=$((current_kb / 1024))
fi

if (( current_kb < required_kb )); then
  if swapon --show=NAME --noheadings | grep -qx "${SWAP_FILE}"; then
    swapoff "${SWAP_FILE}"
  fi

  rm -f "${SWAP_FILE}"
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_FILE}"
  else
    dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=$((SWAP_SIZE_GB * 1024)) status=progress
  fi
  chmod 0600 "${SWAP_FILE}"
  mkswap "${SWAP_FILE}"
fi

if ! swapon --show=NAME --noheadings | grep -qx "${SWAP_FILE}"; then
  swapon "${SWAP_FILE}"
fi

if ! grep -qE "^[^#[:space:]]+[[:space:]]+none[[:space:]]+swap[[:space:]]" /etc/fstab; then
  echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
elif ! grep -qF "${SWAP_FILE} none swap sw 0 0" /etc/fstab; then
  sed -i.bak '/[[:space:]]none[[:space:]]swap[[:space:]]/d' /etc/fstab
  echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
fi

free -h
echo "Swap is ready at ${SWAP_FILE}."
