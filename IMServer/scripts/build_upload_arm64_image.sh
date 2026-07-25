#!/usr/bin/env bash
set -Eeuo pipefail

# Build the Linux ARM64 server image on an ARM Mac, transfer it to an ARM64
# Ubuntu host, then optionally start the existing production-smoke topology
# without compiling Swift on the host.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_TAG="${IMSERVER_IMAGE:-imserver:production-smoke}"
ARTIFACT_DIR="${IMSERVER_ARTIFACT_DIR:-${ROOT_DIR}/.artifacts/images}"
REMOTE_HOST="${IMSERVER_REMOTE_HOST:-}"
REMOTE_USER="${IMSERVER_REMOTE_USER:-root}"
REMOTE_PORT="${IMSERVER_REMOTE_PORT:-22}"
REMOTE_KEY="${IMSERVER_REMOTE_KEY:-}"
REMOTE_DIR="${IMSERVER_REMOTE_DIR:-/opt/IMMonorepo/IMServer}"
REMOTE_STAGING_DIR="${IMSERVER_REMOTE_STAGING_DIR:-/var/tmp/imserver-images}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 127
  fi
}

usage() {
  cat <<'USAGE'
Usage: build_upload_arm64_image.sh <build|upload|smoke-up|smoke-run>

Environment:
  IMSERVER_IMAGE                    image tag (default: imserver:production-smoke)
  IMSERVER_ARTIFACT_DIR             local image archive directory
  IMSERVER_REMOTE_HOST              required for upload/smoke commands
  IMSERVER_REMOTE_USER              SSH user (default: root)
  IMSERVER_REMOTE_PORT              SSH port (default: 22)
  IMSERVER_REMOTE_KEY               optional SSH private-key path
  IMSERVER_REMOTE_DIR               IMServer checkout on target host
                                   (default: /opt/IMMonorepo/IMServer)
  IMSERVER_REMOTE_STAGING_DIR       target image archive directory
                                   (default: /var/tmp/imserver-images)

Commands:
  build      Build a linux/arm64 Docker image and write a compressed tar archive.
  upload     Verify and load the most recent archive on the target host.
  smoke-up   Build, upload, then start the production-smoke roles without a host build.
  smoke-run  Build, upload, then run the full production smoke without a host build.

Examples:
  IMSERVER_REMOTE_HOST=120.77.236.2 \
  IMSERVER_REMOTE_KEY=~/Downloads/test01.pem \
  ./scripts/build_upload_arm64_image.sh smoke-run
USAGE
}

validate_configuration() {
  [[ "${IMAGE_TAG}" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]*$ ]] || {
    printf 'Invalid IMSERVER_IMAGE: %s\n' "${IMAGE_TAG}" >&2
    exit 2
  }
  [[ "${REMOTE_PORT}" =~ ^[0-9]{1,5}$ ]] && (( REMOTE_PORT >= 1 && REMOTE_PORT <= 65535 )) || {
    printf 'Invalid IMSERVER_REMOTE_PORT: %s\n' "${REMOTE_PORT}" >&2
    exit 2
  }
  [[ "${REMOTE_USER}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || {
    printf 'Invalid IMSERVER_REMOTE_USER: %s\n' "${REMOTE_USER}" >&2
    exit 2
  }
  [[ "${REMOTE_DIR}" =~ ^/[A-Za-z0-9._/-]*$ && "${REMOTE_STAGING_DIR}" =~ ^/[A-Za-z0-9._/-]*$ ]] || {
    printf 'Remote paths must be absolute paths without spaces or shell metacharacters.\n' >&2
    exit 2
  }
}

require_remote() {
  [[ "${REMOTE_HOST}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || {
    printf 'Set IMSERVER_REMOTE_HOST to an IPv4 address or hostname.\n' >&2
    exit 2
  }
  if [[ -n "${REMOTE_KEY}" && ! -r "${REMOTE_KEY}" ]]; then
    printf 'IMSERVER_REMOTE_KEY is not readable: %s\n' "${REMOTE_KEY}" >&2
    exit 2
  fi
}

safe_image_name() {
  printf '%s' "${IMAGE_TAG}" | tr '/:@' '---'
}

artifact_prefix() {
  local commit
  commit="$(git -C "${ROOT_DIR}" rev-parse --short=12 HEAD 2>/dev/null || date -u +%Y%m%dT%H%M%SZ)"
  printf 'imserver-%s-%s-linux-arm64' "$(safe_image_name)" "${commit}"
}

archive_path() {
  printf '%s/%s.tar.gz' "${ARTIFACT_DIR}" "$(artifact_prefix)"
}

checksum_path() {
  printf '%s.sha256' "$(archive_path)"
}

ssh_args=()
scp_args=()
configure_ssh() {
  ssh_args=(-o BatchMode=yes -o IdentitiesOnly=yes -p "${REMOTE_PORT}")
  scp_args=(-o BatchMode=yes -o IdentitiesOnly=yes -P "${REMOTE_PORT}")
  if [[ -n "${REMOTE_KEY}" ]]; then
    ssh_args+=(-i "${REMOTE_KEY}")
    scp_args+=(-i "${REMOTE_KEY}")
  fi
}

remote_target() {
  printf '%s@%s' "${REMOTE_USER}" "${REMOTE_HOST}"
}

build_image() {
  require_command docker
  docker info >/dev/null
  docker buildx version >/dev/null

  local archive checksum
  archive="$(archive_path)"
  checksum="$(checksum_path)"
  mkdir -p "${ARTIFACT_DIR}"

  echo "Building ${IMAGE_TAG} for linux/arm64"
  docker buildx build --platform linux/arm64 --load --tag "${IMAGE_TAG}" "${ROOT_DIR}"
  docker image inspect "${IMAGE_TAG}" --format '{{.Os}}/{{.Architecture}}' | grep -qx 'linux/arm64'

  echo "Exporting ${archive}"
  docker image save "${IMAGE_TAG}" | gzip -1 > "${archive}"
  (cd "$(dirname "${archive}")" && shasum -a 256 "$(basename "${archive}")" > "$(basename "${checksum}")")
  printf 'artifact=%s\nchecksum=%s\n' "${archive}" "${checksum}"
}

ensure_artifact() {
  local archive checksum
  archive="$(archive_path)"
  checksum="$(checksum_path)"
  [[ -s "${archive}" && -s "${checksum}" ]] || {
    printf 'Image archive is missing. Run the build command first: %s\n' "${archive}" >&2
    exit 2
  }
  (cd "$(dirname "${archive}")" && shasum -a 256 -c "$(basename "${checksum}")")
}

upload_image() {
  require_remote
  require_command ssh
  require_command scp
  ensure_artifact
  configure_ssh

  local archive checksum archive_name checksum_name target
  archive="$(archive_path)"
  checksum="$(checksum_path)"
  archive_name="$(basename "${archive}")"
  checksum_name="$(basename "${checksum}")"
  target="$(remote_target)"

  ssh "${ssh_args[@]}" "${target}" \
    "set -eu; docker info --format '{{.OSType}}/{{.Architecture}}' | grep -qx 'linux/arm64'; mkdir -p '${REMOTE_STAGING_DIR}'"
  scp "${scp_args[@]}" "${archive}" "${checksum}" "${target}:${REMOTE_STAGING_DIR}/"
  ssh "${ssh_args[@]}" "${target}" "set -eu
    cd '${REMOTE_STAGING_DIR}'
    sha256sum -c '${checksum_name}'
    docker load -i '${archive_name}'
    docker image inspect '${IMAGE_TAG}' >/dev/null
    printf 'loaded_image=%s\\n' '${IMAGE_TAG}'"
}

run_remote_smoke() {
  local action="$1"
  require_remote
  require_command ssh
  configure_ssh
  ssh "${ssh_args[@]}" "$(remote_target)" "set -eu
    cd '${REMOTE_DIR}'
    test -f docker-compose.production-smoke.yml
    test -x scripts/production_smoke.sh
    IMSERVER_IMAGE='${IMAGE_TAG}' IM_SMOKE_SKIP_IMAGE_BUILD=true \\
      bash scripts/production_smoke.sh '${action}'"
}

main() {
  validate_configuration
  case "${1:-}" in
    build)
      build_image
      ;;
    upload)
      upload_image
      ;;
    smoke-up)
      build_image
      upload_image
      run_remote_smoke up
      ;;
    smoke-run)
      build_image
      upload_image
      run_remote_smoke run
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
