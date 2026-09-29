#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_DIR="$ROOT_DIR/IMV2ClientKit/Sources/IMV2ClientKit/Generated"
SERVER_DIR="$ROOT_DIR/IMV2Server/Sources/IMV2ServerGateway/Generated"
SERVER_INTERNAL_DIR="$ROOT_DIR/IMV2Server/Sources/IMV2ServerInfrastructure/Generated"

python3 "$ROOT_DIR/scripts/check_v2_protocol_documentation.py"

[[ -d "$CLIENT_DIR/Protobuf" && -d "$SERVER_DIR/Protobuf" \
   && -f "$SERVER_INTERNAL_DIR/Protobuf/im_realtime/internal/v1/group_event_notification.pb.swift" ]] || {
  echo "V2 generated protobuf is missing. Run scripts/generate_v2_protobuf.sh." >&2
  exit 1
}
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
V2_PROTOBUF_CLIENT_OUT="$TMP_DIR/client/Protobuf" \
V2_PROTOBUF_SERVER_OUT="$TMP_DIR/server/Protobuf" \
V2_PROTOBUF_SERVER_INTERNAL_OUT="$TMP_DIR/server-internal/Protobuf" \
V2_PROTOBUF_CLIENT_VERSION="$TMP_DIR/client/IMV2ProtocolVersion.swift" \
V2_PROTOBUF_SERVER_VERSION="$TMP_DIR/server/IMV2ProtocolVersion.swift" \
V2_PROTOBUF_PLUGIN_SCRATCH_PATH="$TMP_DIR/protoc-gen-swift-build" \
"$ROOT_DIR/scripts/generate_v2_protobuf.sh"
diff -ru "$TMP_DIR/client" "$CLIENT_DIR"
diff -ru "$TMP_DIR/server" "$SERVER_DIR"
diff -ru "$TMP_DIR/server-internal" "$SERVER_INTERNAL_DIR"
echo "V2 protobuf generated check passed."
