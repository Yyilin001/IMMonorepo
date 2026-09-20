#!/usr/bin/env bash
# macOS Debug test-host baseline, not an App/TLS capacity benchmark.
set -Eeuo pipefail

if [[ "${1:-}" == '--help' ]]; then
  cat <<'HELP'
Usage: bash scripts/measure_v2_client_recovery_resources.sh
Builds current ClientKit tests, then measures the already-built Swift Testing host
with /usr/bin/time -l. Runs the 1,000 and 10,000 room SQLite recovery cases.
Resource totals include both cases, fixtures and the test framework; they exclude
compilation and do not measure real networking or the iOS App.
HELP
  exit 0
fi
[[ $# == 0 ]] || { printf 'Unexpected arguments; use --help.\n' >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { printf 'Requires macOS and Xcode.\n' >&2; exit 1; }
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="${root_dir}/IMV2ClientKit"
swift test --package-path "$package_dir" --jobs 4 list >/dev/null
binary_dir="$(swift build --package-path "$package_dir" --show-bin-path)"
test_binary="${binary_dir}/IMV2ClientKitPackageTests.xctest/Contents/MacOS/IMV2ClientKitPackageTests"
swift_binary="$(xcrun --find swift)"
test_host="$(dirname "$swift_binary")/../libexec/swift/pm/swiftpm-testing-helper"
framework_dir="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
[[ -f "$test_binary" && -x "$test_host" && -d "${framework_dir}/Testing.framework" ]] || {
  printf 'Expected Xcode Swift Testing runtime or built test bundle is missing.\n' >&2
  exit 1
}
# Set DYLD after launching system time: macOS strips inherited DYLD variables
# when starting protected system executables.
exec /usr/bin/time -l /usr/bin/env \
  DYLD_FRAMEWORK_PATH="$framework_dir" IMV2_CLIENT_RECOVERY_SCALE=1 \
  "$test_host" --test-bundle-path "$test_binary" "$test_binary" \
  --testing-library swift-testing --filter V2RoomRecoveryScaleTests
