#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_TARGET_POLICY="${PRODUCTION_TARGET_POLICY:-${SCRIPT_DIR}/production_target_policy.py}"

PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${PRODUCTION_ACCEPTANCE_RECEIPT_JSON:-}"
PRODUCTION_EVIDENCE_PACKAGE="${PRODUCTION_EVIDENCE_PACKAGE:-${PRODUCTION_ACCEPTANCE_PACKAGE:-}}"
PRODUCTION_EVIDENCE_DIR="${PRODUCTION_EVIDENCE_DIR:-${PRODUCTION_ACCEPTANCE_EVIDENCE_DIR:-}}"
PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS="${PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS:-86400}"
PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS="${PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS:-300}"
PRODUCTION_ACCEPTANCE_VERIFIER="${PRODUCTION_ACCEPTANCE_VERIFIER:-${SCRIPT_DIR}/perf_production_acceptance_verify.py}"
VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST="${VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST:-false}"

BASE_URL="${BASE_URL:-${PUBLIC_BASE_URL:-${IM_PUBLIC_BASE_URL:-}}}"
TCP_HOST="${TCP_HOST:-${IM_PUBLIC_HOST:-}}"
TCP_PORT="${TCP_PORT:-${IM_TCP_PORT:-9000}}"

usage() {
  cat <<'EOF'
Usage:
  BASE_URL=https://chat.prod.company.com \
  TCP_HOST=tcp.prod.company.com \
  TCP_PORT=9000 \
  PRODUCTION_ACCEPTANCE_RECEIPT_JSON=results/.../production-acceptance.json \
  PRODUCTION_EVIDENCE_PACKAGE=results/.../production-evidence.tar.gz \
    ./verify_production_acceptance.sh

This verifies an already-generated final production acceptance receipt and its
matching evidence package. It does not run acceptance traffic. The target env is
required so stale evidence from another host cannot be accepted accidentally.
PRODUCTION_EVIDENCE_PACKAGE is required; final production verification must not
silently rely on a receipt path that happens to exist on the local machine.
EOF
}

bool_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

fail() {
  printf 'verify_production_acceptance result=fail reason=%s\n' "$1" >&2
  exit 1
}

require_env() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    printf 'verify_production_acceptance result=fail reason=missing_env name=%s\n' "${name}" >&2
    exit 1
  fi
}

verify_target_matches_receipt() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json
import sys
from pathlib import Path

receipt_path = Path(sys.argv[1])
expected = {
    "baseURL": sys.argv[2],
    "tcpHost": sys.argv[3],
    "tcpPort": sys.argv[4],
}
try:
    payload = json.loads(receipt_path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"verify_production_acceptance result=fail reason=receipt_read_failed path={receipt_path} error={exc}")

target = payload.get("target") or {}
for key, expected_value in expected.items():
    actual_value = str(target.get(key) or "")
    if actual_value != expected_value:
        raise SystemExit(
            "verify_production_acceptance result=fail "
            f"reason=target_mismatch field={key} expected={expected_value or '-'} actual={actual_value or '-'}"
        )
PY
}

verify_receipt_status() {
  python3 - "$1" <<'PY'
import json
import sys
from pathlib import Path

receipt_path = Path(sys.argv[1])

try:
    payload = json.loads(receipt_path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"verify_production_acceptance result=fail reason=receipt_read_failed path={receipt_path} error={exc}")

status = str(payload.get("status") or "")
if not status:
    raise SystemExit(f"verify_production_acceptance result=fail reason=receipt_status_missing path={receipt_path}")
if status != "PASS":
    raise SystemExit(
        "verify_production_acceptance result=fail "
        f"reason=receipt_status_mismatch expected=PASS actual={status} path={receipt_path}"
    )
PY
}

verify_receipt_freshness() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys
import time
from pathlib import Path

receipt_path = Path(sys.argv[1])
max_age_seconds = int(sys.argv[2])
max_future_skew_seconds = int(sys.argv[3])

def fail(reason: str, detail: str = "") -> None:
    suffix = f" {detail}" if detail else ""
    raise SystemExit(f"verify_production_acceptance result=fail reason={reason}{suffix}")

try:
    payload = json.loads(receipt_path.read_text(encoding="utf-8"))
except Exception as exc:
    fail("receipt_read_failed", f"path={receipt_path} error={exc}")

generated_at = payload.get("generatedAtEpoch")
if not isinstance(generated_at, int) or isinstance(generated_at, bool):
    fail("receipt_generated_at_invalid", f"path={receipt_path}")
now = int(time.time())
age_seconds = now - generated_at
if age_seconds < -max_future_skew_seconds:
    fail("receipt_from_future", f"ageSeconds={age_seconds} maxFutureSkewSeconds={max_future_skew_seconds} path={receipt_path}")
if max_age_seconds >= 0 and age_seconds > max_age_seconds:
    fail("receipt_stale", f"ageSeconds={age_seconds} maxAgeSeconds={max_age_seconds} path={receipt_path}")
PY
}

verify_package_matches_receipt() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

receipt_path = Path(sys.argv[1])
package_path = Path(sys.argv[2])

def fail(reason: str, detail: str = "") -> None:
    suffix = f" {detail}" if detail else ""
    raise SystemExit(f"verify_production_acceptance result=fail reason={reason}{suffix}")

try:
    payload = json.loads(receipt_path.read_text(encoding="utf-8"))
except Exception as exc:
    fail("receipt_read_failed", f"path={receipt_path} error={exc}")

artifacts = payload.get("artifacts") or {}
if not isinstance(artifacts, dict):
    fail("package_artifacts_missing", f"path={receipt_path}")
if artifacts.get("packagePresent") is not True:
    fail("package_present_flag_invalid", f"path={receipt_path}")
try:
    expected_bytes = int(artifacts.get("packageBytes") or 0)
except Exception:
    fail("package_bytes_invalid", f"path={receipt_path}")
if expected_bytes <= 0:
    fail("package_bytes_missing", f"path={receipt_path}")
expected_sha = str(artifacts.get("packageSha256") or "")
if len(expected_sha) != 64 or any(char not in "0123456789abcdefABCDEF" for char in expected_sha):
    fail("package_sha256_missing", f"path={receipt_path}")
try:
    actual_bytes = package_path.stat().st_size
except OSError as exc:
    fail("package_read_failed", f"path={package_path} error={exc}")
if actual_bytes != expected_bytes:
    fail("package_bytes_mismatch", f"expected={expected_bytes} actual={actual_bytes} path={package_path}")
actual_sha = hashlib.sha256(package_path.read_bytes()).hexdigest()
if actual_sha.lower() != expected_sha.lower():
    fail("package_sha256_mismatch", f"expected={expected_sha} actual={actual_sha} path={package_path}")
PY
}

validate_public_target() {
  python3 "${PRODUCTION_TARGET_POLICY}" \
    --base-url "${BASE_URL}" \
    --tcp-host "${TCP_HOST}" \
    --tcp-port "${TCP_PORT}" \
    --result-prefix "verify_production_acceptance"
}

run_self_test() {
  local tmpdir fake_verifier receipt package
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  fake_verifier="${tmpdir}/fake-verifier.py"
  receipt="${tmpdir}/production-acceptance.json"
  package="${tmpdir}/production-evidence.tar.gz"

  printf 'package' >"${package}"
  python3 - "${receipt}" "${package}" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

receipt = Path(sys.argv[1])
package = Path(sys.argv[2])
receipt.write_text(json.dumps({
    "schemaVersion": 1,
    "status": "PASS",
    "generatedAtEpoch": int(time.time()),
    "target": {
        "baseURL": "https://chat.myim-prod.com",
        "tcpHost": "tcp.myim-prod.com",
        "tcpPort": "9000",
    },
    "artifacts": {
        "package": str(package),
        "packagePresent": True,
        "packageBytes": package.stat().st_size,
        "packageSha256": hashlib.sha256(package.read_bytes()).hexdigest(),
    },
}), encoding="utf-8")
PY
  cat >"${fake_verifier}" <<'PY'
#!/usr/bin/env python3
import sys
from pathlib import Path

Path(sys.argv[-1]).write_text("\n".join(sys.argv[1:]), encoding="utf-8")
PY
  chmod +x "${fake_verifier}"

  BASE_URL=https://chat.myim-prod.com \
  TCP_HOST=tcp.myim-prod.com \
  TCP_PORT=9000 \
  PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
  PRODUCTION_EVIDENCE_PACKAGE="${package}" \
  PRODUCTION_ACCEPTANCE_VERIFIER="${fake_verifier}" \
  VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=false \
    bash "${BASH_SOURCE[0]}" "${tmpdir}/verifier.args"

  grep -q -- '--receipt-json' "${tmpdir}/verifier.args"
  grep -q -- '--package-file' "${tmpdir}/verifier.args"
  grep -q -- '--max-age-seconds' "${tmpdir}/verifier.args"
  grep -q -- '--max-future-skew-seconds' "${tmpdir}/verifier.args"
  grep -q -- '--require-pass' "${tmpdir}/verifier.args"

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_ACCEPTANCE_VERIFIER="${fake_verifier}" \
    VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" "${tmpdir}/missing-package.args" >"${tmpdir}/missing-package.log" 2>&1; then
    fail "self_test_missing_package_passed"
  fi
  grep -q 'reason=missing_env name=PRODUCTION_EVIDENCE_PACKAGE' "${tmpdir}/missing-package.log"

  if BASE_URL=https://other.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFIER="${fake_verifier}" \
    VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" "${tmpdir}/bad.args" >"${tmpdir}/bad.log" 2>&1; then
    fail "self_test_target_mismatch_passed"
  fi
  grep -q 'reason=target_mismatch field=baseURL' "${tmpdir}/bad.log"

  cp "${receipt}" "${tmpdir}/bad-status.json"
  python3 - "${tmpdir}/bad-status.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["status"] = "FAIL"
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${tmpdir}/bad-status.json" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFIER="${fake_verifier}" \
    VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" "${tmpdir}/bad-status.args" >"${tmpdir}/bad-status.log" 2>&1; then
    fail "self_test_receipt_status_mismatch_passed"
  fi
  grep -q 'reason=receipt_status_mismatch' "${tmpdir}/bad-status.log"

  cp "${receipt}" "${tmpdir}/stale.json"
  python3 - "${tmpdir}/stale.json" <<'PY'
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["generatedAtEpoch"] = int(time.time()) - 90000
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${tmpdir}/stale.json" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFIER="${fake_verifier}" \
    VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" "${tmpdir}/stale.args" >"${tmpdir}/stale.log" 2>&1; then
    fail "self_test_receipt_stale_passed"
  fi
  grep -q 'reason=receipt_stale' "${tmpdir}/stale.log"

  cp "${receipt}" "${tmpdir}/future.json"
  python3 - "${tmpdir}/future.json" <<'PY'
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["generatedAtEpoch"] = int(time.time()) + 600
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${tmpdir}/future.json" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFIER="${fake_verifier}" \
    VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" "${tmpdir}/future.args" >"${tmpdir}/future.log" 2>&1; then
    fail "self_test_receipt_from_future_passed"
  fi
  grep -q 'reason=receipt_from_future' "${tmpdir}/future.log"

  cp "${receipt}" "${tmpdir}/bad-package-sha.json"
  python3 - "${tmpdir}/bad-package-sha.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["artifacts"]["packageSha256"] = "0" * 64
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${tmpdir}/bad-package-sha.json" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFIER="${fake_verifier}" \
    VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" "${tmpdir}/bad-package-sha.args" >"${tmpdir}/bad-package-sha.log" 2>&1; then
    fail "self_test_package_sha_mismatch_passed"
  fi
  grep -q 'reason=package_sha256_mismatch' "${tmpdir}/bad-package-sha.log"

  cp "${receipt}" "${tmpdir}/bad-package-bytes.json"
  python3 - "${tmpdir}/bad-package-bytes.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["artifacts"]["packageBytes"] = int(payload["artifacts"]["packageBytes"]) + 1
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${tmpdir}/bad-package-bytes.json" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFIER="${fake_verifier}" \
    VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" "${tmpdir}/bad-package-bytes.args" >"${tmpdir}/bad-package-bytes.log" 2>&1; then
    fail "self_test_package_bytes_mismatch_passed"
  fi
  grep -q 'reason=package_bytes_mismatch' "${tmpdir}/bad-package-bytes.log"

  cp "${receipt}" "${tmpdir}/missing-package-artifacts.json"
  python3 - "${tmpdir}/missing-package-artifacts.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload.pop("artifacts", None)
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${tmpdir}/missing-package-artifacts.json" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFIER="${fake_verifier}" \
    VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" "${tmpdir}/missing-package-artifacts.args" >"${tmpdir}/missing-package-artifacts.log" 2>&1; then
    fail "self_test_package_artifacts_missing_passed"
  fi
  grep -q 'reason=package_present_flag_invalid' "${tmpdir}/missing-package-artifacts.log"

  if BASE_URL=http://127.0.0.1:8080 \
    TCP_HOST=127.0.0.1 \
    TCP_PORT=9000 \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFIER="${fake_verifier}" \
    VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" "${tmpdir}/local-target.args" >"${tmpdir}/local-target.log" 2>&1; then
    fail "self_test_local_target_passed"
  fi
  grep -q 'reason=base_url_https_required' "${tmpdir}/local-target.log"

  if BASE_URL=https://chat.myim-prod.com/api \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9000 \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFIER="${fake_verifier}" \
    VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" "${tmpdir}/path-target.args" >"${tmpdir}/path-target.log" 2>&1; then
    fail "self_test_path_target_passed"
  fi
  grep -q 'reason=base_url_origin_required' "${tmpdir}/path-target.log"

  if BASE_URL=https://chat.myim-prod.com \
    TCP_HOST=tcp.myim-prod.com \
    TCP_PORT=9443 \
    PRODUCTION_ACCEPTANCE_RECEIPT_JSON="${receipt}" \
    PRODUCTION_EVIDENCE_PACKAGE="${package}" \
    PRODUCTION_ACCEPTANCE_VERIFIER="${fake_verifier}" \
    VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST=false \
      bash "${BASH_SOURCE[0]}" "${tmpdir}/bad-port.args" >"${tmpdir}/bad-port.log" 2>&1; then
    fail "self_test_bad_tcp_port_passed"
  fi
  grep -q 'reason=tcp_port_required' "${tmpdir}/bad-port.log"

  printf 'verify_production_acceptance_self_test result=pass\n'
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
esac

if bool_enabled "${VERIFY_PRODUCTION_ACCEPTANCE_SELF_TEST}"; then
  run_self_test
  exit 0
fi

require_env "BASE_URL" "${BASE_URL}"
require_env "TCP_HOST" "${TCP_HOST}"
require_env "TCP_PORT" "${TCP_PORT}"
require_env "PRODUCTION_ACCEPTANCE_RECEIPT_JSON" "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}"
require_env "PRODUCTION_EVIDENCE_PACKAGE" "${PRODUCTION_EVIDENCE_PACKAGE}"

validate_public_target

if [[ ! -f "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" ]]; then
  printf 'verify_production_acceptance result=fail reason=receipt_missing path=%s\n' "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" >&2
  exit 1
fi
if [[ ! -f "${PRODUCTION_EVIDENCE_PACKAGE}" ]]; then
  printf 'verify_production_acceptance result=fail reason=package_missing path=%s\n' "${PRODUCTION_EVIDENCE_PACKAGE}" >&2
  exit 1
fi
if [[ ! -x "${PRODUCTION_ACCEPTANCE_VERIFIER}" && ! -f "${PRODUCTION_ACCEPTANCE_VERIFIER}" ]]; then
  printf 'verify_production_acceptance result=fail reason=verifier_missing path=%s\n' "${PRODUCTION_ACCEPTANCE_VERIFIER}" >&2
  exit 1
fi

verify_target_matches_receipt "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" "${BASE_URL}" "${TCP_HOST}" "${TCP_PORT}"
verify_receipt_status "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}"
verify_receipt_freshness \
  "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" \
  "${PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}" \
  "${PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}"
verify_package_matches_receipt "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}" "${PRODUCTION_EVIDENCE_PACKAGE}"

args=(
  "--receipt-json" "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}"
  "--max-age-seconds" "${PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS}"
  "--max-future-skew-seconds" "${PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS}"
  "--package-file" "${PRODUCTION_EVIDENCE_PACKAGE}"
  "--require-pass"
)
if [[ -n "${PRODUCTION_EVIDENCE_DIR}" ]]; then
  args+=("--evidence-dir" "${PRODUCTION_EVIDENCE_DIR}")
fi

python3 "${PRODUCTION_ACCEPTANCE_VERIFIER}" "${args[@]}" "$@"

printf 'verify_production_acceptance result=pass receipt=%s\n' "${PRODUCTION_ACCEPTANCE_RECEIPT_JSON}"
