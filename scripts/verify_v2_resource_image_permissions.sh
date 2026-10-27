#!/usr/bin/env bash
set -euo pipefail

# Run against the final runtime image, including packages assembled from local
# release artifacts. Checks content usability rather than only image hashes.
if [[ $# -ne 1 || -z "$1" ]]; then
  echo "Usage: $0 IMAGE" >&2
  exit 2
fi

docker run --rm --network=none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --entrypoint /bin/sh "$1" -c '
    set -eu
    root=/workspace/IMV2Server/.build/release
    for product in IMV2AccountServerApp IMV2ServerApp IMV2OperatorServerApp \
        IMV2LocalGatewayProbe IMV2ResourceImageWorker IMV2PlacementControlApp \
        IMV2RoomHostSupervisorApp; do
      test -f "$root/$product" && test -r "$root/$product" && test -x "$root/$product" || {
        echo "Runtime product unavailable or not executable: $product" >&2
        exit 1
      }
    done
    for bundle in SwiftProtobuf_SwiftProtobuf.bundle swift-crypto_CXKCP.bundle; do
      test -r "$root/$bundle/Info.plist"
      test -r "$root/$bundle/PrivacyInfo.xcprivacy"
    done
    "$root/IMV2ResourceImageWorker" --check
    /usr/bin/ffprobe -version >/dev/null
    echo "Runtime executable permissions, bundles and media tools passed."
  '
