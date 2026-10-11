#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKOUT="$ROOT_DIR/IMV2Server/.build/checkouts/swift-protobuf"
if [[ -n "${PROTOC_GEN_SWIFT:-}" ]]; then
  PLUGIN="$PROTOC_GEN_SWIFT"
else
  swift build --package-path "$CHECKOUT" -c release --product protoc-gen-swift >/dev/null
  PLUGIN="$(swift build --package-path "$CHECKOUT" -c release --product protoc-gen-swift --show-bin-path)/protoc-gen-swift"
fi
OUT="${ACTOR_PROTOBUF_OUT:-$ROOT_DIR/IMV2Server/Sources/IMV2ActorContracts/Protobuf}"
mkdir -p "$OUT"
protoc --plugin="protoc-gen-swift=$PLUGIN" --proto_path="$ROOT_DIR/Protocol/im_actor/v1" --swift_opt=Visibility=Package --swift_out="$OUT" "$ROOT_DIR/Protocol/im_actor/v1/actor_value.proto"
