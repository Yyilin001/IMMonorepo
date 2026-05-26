#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="$ROOT_DIR/Protocol/im_realtime/v1"
CLIENT_OUT="$ROOT_DIR/IMClientKit/Sources/IMClientKit/Generated/Protobuf"
SERVER_OUT="$ROOT_DIR/IMServer/Sources/IMServer/Generated/Protobuf"

mkdir -p "$CLIENT_OUT" "$SERVER_OUT"

protoc \
  --proto_path="$ROOT_DIR/Protocol" \
  --swift_out="$CLIENT_OUT" \
  "$PROTO_DIR/im_realtime.proto"

protoc \
  --proto_path="$ROOT_DIR/Protocol" \
  --swift_out="$SERVER_OUT" \
  "$PROTO_DIR/im_realtime.proto"
