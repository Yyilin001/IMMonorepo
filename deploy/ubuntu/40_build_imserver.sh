#!/usr/bin/env bash
set -euo pipefail
if [[ -f /opt/swiftly/env.sh ]]; then
  # Swiftly installs the toolchain for root during dependency setup. Non-login
  # scripts do not automatically inherit that environment.
  # shellcheck source=/dev/null
  source /opt/swiftly/env.sh
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

ROOT="$(repo_root)"
ensure_user "${IMSERVER_USER}" "${IMSERVER_GROUP}" "${IMSERVER_HOME}"
install -d -o "${IMSERVER_USER}" -g "${IMSERVER_GROUP}" -m 0755 "${IMSERVER_HOME}" "${IMSERVER_BIN_DIR}" "${IMSERVER_LOG_DIR}"

cd "${ROOT}"
build_configuration="${IMSERVER_BUILD_CONFIGURATION:-release}"
swift build -c "${build_configuration}" --package-path IMServer --jobs "${SWIFT_BUILD_JOBS:-1}"
install -o "${IMSERVER_USER}" -g "${IMSERVER_GROUP}" -m 0755 "IMServer/.build/${build_configuration}/IMServer" "${IMSERVER_BIN_DIR}/IMServer"

swift_runtime_dir="$(swift -print-target-info | sed -n 's/.*\"runtimeLibraryPaths\"[[:space:]]*:[[:space:]]*\\[\"\\([^\"]*\\)\".*/\\1/p' | head -1)"
if [[ -z "${swift_runtime_dir}" || ! -d "${swift_runtime_dir}" ]]; then
  swift_runtime_dir="$(dirname "$(find "${SWIFTLY_TOOLCHAINS_DIR:-/root/.local/share/swiftly/toolchains}" -name libswiftCore.so -print -quit 2>/dev/null)")"
fi
if [[ -n "${swift_runtime_dir}" && -d "${swift_runtime_dir}" ]]; then
  install -d -m 0755 /usr/local/lib/swift/linux
  cp -a "${swift_runtime_dir}"/*.so* /usr/local/lib/swift/linux/
  echo /usr/local/lib/swift/linux > /etc/ld.so.conf.d/swift-runtime.conf
  ldconfig
fi

if [[ -d "IMServer/Public" ]]; then
  rsync -a --delete "IMServer/Public/" "${IMSERVER_HOME}/Public/"
  chown -R "${IMSERVER_USER}:${IMSERVER_GROUP}" "${IMSERVER_HOME}/Public"
fi

echo "Installed IMServer binary to ${IMSERVER_BIN_DIR}/IMServer."
