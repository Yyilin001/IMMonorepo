#!/usr/bin/env python3
"""Check declared current contracts against their source, excluding historical reports.

This guards explicit version, transport and default-value tables. It does not
interpret arbitrary prose or replace executable route and deployment tests.
"""

import pathlib
import re
import sys


def one(pattern: str, source: str, label: str) -> str:
    matches = re.findall(pattern, source)
    if len(matches) != 1:
        raise ValueError(f"{label}: expected one declaration, found {len(matches)}")
    return matches[0]


def check(root: pathlib.Path) -> None:
    version = (root / "Protocol/im_realtime/v2/protocol_version.txt").read_text().strip()
    if not re.fullmatch(r"[0-9]+", version):
        raise ValueError("protocol_version.txt must contain one integer")
    status = (root / "IMV2/docs/implementation-status.md").read_text()
    # Both the wire policy and the capability table are required claims.
    claims = re.findall(r"\bprotocol\s*(\d+)\b", status)
    if len(claims) < 2 or any(value != version for value in claims):
        raise ValueError(f"implementation-status.md protocol claims {claims!r} must match {version}")

    schema = (root / "IMV2/sql/schema.sql").read_text()
    schema_ids = set(re.findall(r"im-v2-current-(\d+)", schema))
    readiness = (root / "IMV2Server/Sources/IMV2ServerInfrastructure/V2SchemaReadiness.swift").read_text()
    schema_id = one(r'currentSchemaID\s*=\s*"im-v2-current-(\d+)"', readiness, "schema readiness")
    if schema_ids != {schema_id}:
        raise ValueError(f"schema.sql IDs {sorted(schema_ids)!r} must match readiness {schema_id}")
    shell_contract = (root / "IMV2/scripts/current_v2_schema_contract.sql").read_text()
    shell_schema_ids = set(re.findall(r"im-v2-current-(\d+)", shell_contract))
    if shell_schema_ids != {schema_id}:
        raise ValueError(f"shell schema contract IDs {sorted(shell_schema_ids)!r} must match readiness {schema_id}")
    # Historical introductions such as 'schema 19→20' are not current-ID claims.
    schema_claims = re.findall(r"(?:im-v2-current-|\bcurrent)(\d+)\b", status)
    if not schema_claims or any(value != schema_id for value in schema_claims):
        raise ValueError(f"implementation-status.md schema claims {schema_claims!r} must match {schema_id}")

    registry = (root / "IMV2ClientKit/Sources/IMV2ClientKit/Networking/V2NetworkEntryRegistry.swift").read_text()
    send_boundaries = []
    for kinds, boundaries in re.findall(r"case\s+([^:]+):\s*\[([^\]]+)\]", registry):
        if ".sendMessage" in [value.strip() for value in kinds.split(",")]:
            send_boundaries.append(boundaries)
    if len(send_boundaries) != 1:
        raise ValueError("network registry must declare sendMessage boundaries exactly once")
    labels = {".tcp": "TCP（TLS）", ".accountHTTP": "HTTPS"}
    boundary_values = {value.strip() for value in send_boundaries[0].split(",")}
    if not boundary_values or boundary_values - labels.keys():
        raise ValueError(f"unknown sendMessage boundary: {sorted(boundary_values)!r}")
    expected_transports = {labels[value] for value in boundary_values}
    send_contract = (root / "docs/reviews/message-send-contract.md").read_text()
    for operation in ("普通消息提交", "普通消息结果恢复"):
        declaration = one(
            rf"(?m)^\|\s*{operation}\s*\|\s*([^|\n]+)\|", send_contract, operation)
        transports = {value.strip() for value in declaration.split("、")}
        if transports != expected_transports:
            raise ValueError(f"{operation}: {sorted(transports)!r} must match registry {sorted(expected_transports)!r}")

    configuration = (root / "IMV2Server/Sources/IMV2Server/V2GatewayRuntimeConfiguration.swift").read_text()
    default_patterns = {
        "IM_V2_MESSAGE_SEND_OPERATIONS_ENABLED": (
            r'messageSendOperationsEnabled\s*=\s*try Self\.optional\("IM_V2_MESSAGE_SEND_OPERATIONS_ENABLED",\s*environment:\s*environment\)'
            r'\s*\.map\s*\{[^{}]*\}\s*\?\?\s*(true|false)\b'
        ),
        "IM_V2_AUTHOR_PRESENTATIONS_ENABLED": (
            r'if\s+Self\.optional\("IM_V2_AUTHOR_PRESENTATIONS_ENABLED",\s*environment:\s*environment\)\s*!=\s*nil\s*\{'
            r'\s*authorPresentationsEnabled\s*=\s*try Self\.explicitBoolean\("IM_V2_AUTHOR_PRESENTATIONS_ENABLED",\s*environment:\s*environment\)'
            r'\s*\}\s*else\s*\{\s*authorPresentationsEnabled\s*=\s*(true|false)\s*\}'
        ),
    }
    for key, pattern in default_patterns.items():
        actual_default = one(pattern, configuration, f"{key} source default")
        claimed_default = one(rf"(?m)^\|\s*`{key}`\s*\|\s*`(true|false)`\s*\|", status, f"{key} documented default")
        if claimed_default != actual_default:
            raise ValueError(f"{key}: documented default {claimed_default} must match source {actual_default}")


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parents[1]
    try:
        check(root)
    except (OSError, ValueError) as error:
        print(f"V2 current documentation mismatch: {error}", file=sys.stderr)
        sys.exit(1)
    print("V2 current protocol, schema, message transport and configuration defaults match their sources.")
