#!/usr/bin/env python3
"""Reject bind mounts that overlap source or each other before Compose runs."""

import os
import sys


def _overlaps(first: str, second: str) -> bool:
    common = os.path.commonpath((first, second))
    return common == first or common == second


def validate_paths(source: str, cache: str, scratch: str) -> None:
    for label, path in (("source", source), ("cache", cache), ("scratch", scratch)):
        if not os.path.isabs(path) or "\n" in path or "\r" in path:
            raise ValueError(f"{label} must be an absolute path without newlines")
    source = os.path.realpath(source)
    cache = os.path.realpath(cache)
    scratch = os.path.realpath(scratch)
    if source == os.path.sep or cache == os.path.sep or scratch == os.path.sep:
        raise ValueError("source, cache, and scratch cannot be filesystem root")
    if _overlaps(source, cache) or _overlaps(source, scratch):
        raise ValueError("cache/scratch must neither contain nor be contained by the source tree")
    if _overlaps(cache, scratch):
        raise ValueError("cache and scratch must be separate, non-nested directories")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("usage: v2_virtual_actor_bind_paths.py SOURCE CACHE SCRATCH", file=sys.stderr)
        sys.exit(64)
    try:
        validate_paths(*sys.argv[1:])
    except ValueError as error:
        print(f"invalid Linux bind paths: {error}", file=sys.stderr)
        sys.exit(64)
