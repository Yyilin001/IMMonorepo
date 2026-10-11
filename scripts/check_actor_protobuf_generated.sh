#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
ACTOR_PROTOBUF_OUT="$TEMP_DIR" "$ROOT_DIR/scripts/generate_actor_protobuf.sh"
diff -u "$ROOT_DIR/IMV2Server/Sources/IMV2ActorContracts/Protobuf/actor_value.pb.swift" "$TEMP_DIR/actor_value.pb.swift"
