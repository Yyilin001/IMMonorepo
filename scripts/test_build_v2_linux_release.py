#!/usr/bin/env python3
"""Reject malformed artifacts, wrong architectures and unreviewed SDK patches."""

import struct
import tempfile
import unittest
import hashlib
from pathlib import Path
from unittest.mock import patch

from build_v2_linux_release import verify_linux_elf, verify_load_segments, apply_dependency_patch


def elf(machine=62, segment_type=1, dynamic_tag=0):
    data = bytearray(136)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HH", data, 16, 2, machine)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<HH", data, 54, 56, 1)
    struct.pack_into("<I", data, 64, segment_type)
    struct.pack_into("<Q", data, 72, 120)
    struct.pack_into("<Q", data, 96, 16)
    struct.pack_into("<qQ", data, 120, dynamic_tag, 0)
    return data


class ArtifactAdmissionTests(unittest.TestCase):
    def inspect(self, data):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "server"
            path.write_bytes(data)
            return verify_linux_elf(path)

    def test_static_x86_64_is_accepted(self):
        self.assertTrue(self.inspect(elf())["static"])

    def test_arm64_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "x86_64"):
            self.inspect(elf(machine=183))

    def test_unknown_interpreter_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "interpreter"):
            self.inspect(elf(segment_type=3))

    def test_glibc_interpreter_is_accepted(self):
        data = elf(segment_type=3)
        interpreter = b"/lib64/ld-linux-x86-64.so.2\0"
        data[120:] = interpreter
        struct.pack_into("<Q", data, 96, len(interpreter))
        self.assertFalse(self.inspect(data)["static"])

    def test_empty_dynamic_table_is_accepted(self):
        self.assertTrue(self.inspect(elf(segment_type=2))["static"])

    def test_truncated_binary_is_rejected(self):
        for cut in (0, 6, 63, 90, 119, 135):
            with self.subTest(bytes=cut), self.assertRaises(ValueError):
                self.inspect(elf()[:cut])

    def test_corrupt_program_table_is_rejected(self):
        for offset in (0, 136, 2**63):
            data = elf()
            struct.pack_into("<Q", data, 32, offset)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                self.inspect(data)


class DependencyPatchAdmissionTests(unittest.TestCase):
    def test_patch_is_exact_and_idempotent(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "Source.swift"
            original = "import CNIOLinux\n"
            result = "#if os(Linux) && canImport(CDispatch)\nimport CDispatch\n#endif\n\n" + original
            metadata = {"revision": "expected", "files": {path.name: {
                "module": "CDispatch", "originalSHA256": hashlib.sha256(original.encode()).hexdigest(),
                "patchedSHA256": hashlib.sha256(result.encode()).hexdigest()}}}
            path.write_text(original)
            with patch("build_v2_linux_release.subprocess.check_output", return_value="expected\n"):
                apply_dependency_patch(Path(folder), metadata)
                apply_dependency_patch(Path(folder), metadata)
                self.assertEqual(path.read_text(), result)
                path.write_text("unexpected edit\n")
                with self.assertRaisesRegex(ValueError, "Unrecognized"):
                    apply_dependency_patch(Path(folder), metadata)

    def test_changed_revision_is_rejected_before_writing(self):
        with patch("build_v2_linux_release.subprocess.check_output", return_value="different\n"):
            with self.assertRaisesRegex(ValueError, "revision changed"):
                apply_dependency_patch(Path("/unused"), {"revision": "expected", "files": {}})


class StrippingIntegrityTests(unittest.TestCase):
    def test_runtime_bytes_must_match(self):
        with tempfile.TemporaryDirectory() as folder:
            original, stripped = Path(folder) / "original", Path(folder) / "stripped"
            original.write_bytes(elf())
            stripped.write_bytes(elf())
            verify_load_segments(original, stripped)
            changed = elf()
            changed[128] = 1
            stripped.write_bytes(changed)
            with self.assertRaisesRegex(ValueError, "load segments"):
                verify_load_segments(original, stripped)

    def test_section_table_metadata_may_change(self):
        with tempfile.TemporaryDirectory() as folder:
            original, stripped = Path(folder) / "original", Path(folder) / "stripped"
            data = elf()
            struct.pack_into("<Q", data, 72, 0)
            struct.pack_into("<Q", data, 96, len(data))
            original.write_bytes(data)
            struct.pack_into("<Q", data, 40, 1234)
            stripped.write_bytes(data)
            verify_load_segments(original, stripped)


if __name__ == "__main__":
    unittest.main()
