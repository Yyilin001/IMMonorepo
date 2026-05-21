#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_file() {
  local path="$1"
  [[ -f "${ROOT_DIR}/${path}" ]] || {
    echo "Missing required governance file: ${path}" >&2
    exit 1
  }
}

require_match() {
  local pattern="$1"
  local path="$2"
  rg -q "${pattern}" "${ROOT_DIR}/${path}" || {
    echo "Missing required governance pattern '${pattern}' in ${path}" >&2
    exit 1
  }
}

require_file ".github/CODEOWNERS"
require_file ".github/pull_request_template.md"
require_file "docs/architecture-boundaries.md"

require_match "/IMServer/Sources/IMServer/IM/" ".github/CODEOWNERS"
require_match "/IMApp/" ".github/CODEOWNERS"
require_match "/IMClientKitAndroid/" ".github/CODEOWNERS"
require_match "AI stream message/index writes go through the stream state store" ".github/pull_request_template.md"
require_match "App/UI layers must not directly parse TCP packets" "docs/architecture-boundaries.md"
require_match "real Redis staging and capacity data" "docs/architecture-boundaries.md"

echo "Governance boundary checks passed."
