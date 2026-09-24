#!/usr/bin/env python3
import os
from pathlib import Path
import tempfile
import unittest

from v2_virtual_actor_bind_paths import validate_paths


class BindPathsTests(unittest.TestCase):
    def test_disjoint_paths_are_allowed(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root, "checkout", "repo")
            cache = Path(root, "artifacts", "cache")
            scratch = Path(root, "artifacts", "scratch")
            validate_paths(str(source), str(cache), str(scratch))

    def test_source_ancestor_and_descendant_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root, "checkout", "repo")
            scratch = Path(root, "scratch")
            for cache in (Path(root, "checkout"), source, source / ".build"):
                with self.subTest(cache=cache), self.assertRaises(ValueError):
                    validate_paths(str(source), str(cache), str(scratch))

    def test_nested_cache_and_scratch_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root, "checkout")
            cache = Path(root, "artifacts")
            scratch = cache / "scratch"
            with self.assertRaises(ValueError):
                validate_paths(str(source), str(cache), str(scratch))

    def test_symlink_to_source_ancestor_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root, "checkout", "repo")
            source.mkdir(parents=True)
            link = Path(root, "linked-parent")
            os.symlink(source.parent, link)
            with self.assertRaises(ValueError):
                validate_paths(str(source), str(link), str(Path(root, "scratch")))

    def test_relative_path_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError):
                validate_paths(str(Path(root, "repo")), "relative-cache", str(Path(root, "scratch")))


if __name__ == "__main__":
    unittest.main()
