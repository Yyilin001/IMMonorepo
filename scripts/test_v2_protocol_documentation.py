#!/usr/bin/env python3
"""Exercise the documentation gate with contradictory copies of current sources."""

import pathlib
import re
import tempfile
import unittest

from check_v2_protocol_documentation import check


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROTOCOL = "Protocol/im_realtime/v2/protocol_version.txt"
STATUS = "IMV2/docs/implementation-status.md"
SCHEMA = "IMV2/sql/schema.sql"
READINESS = "IMV2Server/Sources/IMV2ServerInfrastructure/V2SchemaReadiness.swift"
SHELL_CONTRACT = "IMV2/scripts/current_v2_schema_contract.sql"
REGISTRY = "IMV2ClientKit/Sources/IMV2ClientKit/Networking/V2NetworkEntryRegistry.swift"
SEND = "docs/reviews/message-send-contract.md"
CONFIGURATION = "IMV2Server/Sources/IMV2Server/V2GatewayRuntimeConfiguration.swift"


class CurrentDocumentationTests(unittest.TestCase):
    def test_current_contracts_match(self):
        check(ROOT)

    def assert_rejected(self, path, replacement, error):
        with tempfile.TemporaryDirectory(prefix="imv2-documentation-") as directory:
            root = pathlib.Path(directory)
            for name in (PROTOCOL, STATUS, SCHEMA, READINESS, SHELL_CONTRACT, REGISTRY, SEND, CONFIGURATION):
                source = (ROOT / name).read_text()
                if name == path:
                    changed = replacement(source)
                    self.assertNotEqual(source, changed, "mutation must change its fixture")
                    source = changed
                destination = root / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(source)
            with self.assertRaisesRegex(ValueError, error):
                check(root)

    def test_protocol_and_schema_drift_is_rejected(self):
        next_schema = lambda source: re.sub(
            r"im-v2-current-(\d+)", lambda match: f"im-v2-current-{int(match[1]) + 1}", source)
        cases = (
            (PROTOCOL, lambda source: str(int(source) + 1), "protocol claims"),
            (STATUS, lambda source: source + "\n当前 schema current999999\n", "schema claims"),
            (SCHEMA, next_schema, "schema.sql IDs"),
            (READINESS, next_schema, "schema.sql IDs"),
            (SHELL_CONTRACT, next_schema, "shell schema contract IDs"),
            (SHELL_CONTRACT, lambda source: re.sub(r"im-v2-current-\d+", "unversioned", source), "shell schema contract IDs"),
            (SHELL_CONTRACT, lambda source: source + "\n-- im-v2-current-999999\n", "shell schema contract IDs"),
        )
        for path, replacement, error in cases:
            with self.subTest(path=path):
                self.assert_rejected(path, replacement, error)

    def test_transport_and_default_drift_is_rejected(self):
        cases = [
            (SEND, lambda source: source.replace("| 普通消息提交 | TCP（TLS） |", "| 普通消息提交 | HTTPS |"), "普通消息提交"),
            (REGISTRY, lambda source: source.replace("case .sendMessage: [.tcp]", "case .sendMessage: [.tcp, .accountHTTP]"), "普通消息提交"),
            (CONFIGURATION, lambda source: source.replace("else { authorPresentationsEnabled = false }", "else { authorPresentationsEnabled = true }"), "documented default"),
        ]
        for key in ("IM_V2_MESSAGE_SEND_OPERATIONS_ENABLED", "IM_V2_AUTHOR_PRESENTATIONS_ENABLED"):
            def flip_default(source, key=key):
                return re.sub(
                    rf"(\| `{key}` \| `)(true|false)(` \|)",
                    lambda match: match[1] + ("false" if match[2] == "true" else "true") + match[3], source)
            cases.append((STATUS, flip_default, key))
        for index, (path, replacement, error) in enumerate(cases):
            with self.subTest(case=index, path=path):
                self.assert_rejected(path, replacement, error)


if __name__ == "__main__":
    unittest.main()
