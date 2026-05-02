#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
  build-essential \
  ca-certificates \
  curl \
  clang \
  git \
  gnupg \
  libcurl4-openssl-dev \
  libjemalloc-dev \
  libsasl2-dev \
  libssl-dev \
  libxml2-dev \
  libz-dev \
  nginx \
  openssl \
  pkg-config \
  postgresql \
  postgresql-contrib \
  redis-server \
  rsync \
  tar \
  unzip \
  uuid-runtime \
  zlib1g-dev

if ! command -v java >/dev/null 2>&1; then
  apt-get install -y openjdk-21-jre-headless
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift not found. Installing Swift with Swiftly under /opt/swiftly."
  apt-get install -y binutils libc6-dev libedit-dev libicu-dev libncurses-dev libpython3-dev libsqlite3-dev tzdata
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT
  cd "${tmp_dir}"
  swift_archive="swiftly-1.1.1-$(uname -m).tar.gz"
  curl -fsSLO "https://download.swift.org/swiftly/linux/${swift_archive}"
  tar -zxf "${swift_archive}"
  export SWIFTLY_HOME_DIR=/opt/swiftly
  export SWIFTLY_BIN_DIR=/usr/local/bin
  ./swiftly init --quiet-shell-followup
  . "${SWIFTLY_HOME_DIR}/env.sh"
  hash -r
fi

swift --version
systemctl enable --now postgresql
systemctl enable --now redis-server

echo "Base dependencies are installed."
