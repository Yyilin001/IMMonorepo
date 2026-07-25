#!/usr/bin/env bash
set -euo pipefail

# SwiftPM test bundles may inherit stale local signing/load state from a shared
# .build directory. Use one disposable native scratch directory per run: this
# keeps the client on macOS while leaving no test bundle or dependency checkout
# in the repository or a long-lived user build directory.
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_scratch="$(mktemp -d "${TMPDIR:-/tmp}/imv2-clientkit-tests.XXXXXX")"
trap 'rm -rf -- "$task_scratch"' EXIT

# `swiftpm-xctest-helper` is supplied by Xcode on macOS. Keep the compiler,
# test runner, and helper in that same toolchain instead of inheriting a
# separately selected Swiftly toolchain from PATH.
xcrun --toolchain XcodeDefault swift test \
  --package-path "$task_root/IMV2ClientKit" \
  --scratch-path "$task_scratch" \
  --jobs "${IMV2_CLIENTKIT_TEST_JOBS:-4}" \
  "$@"
