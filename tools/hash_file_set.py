#!/usr/bin/env python3
"""Produce a deterministic, filename-safe SHA-256 for a directory tree."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
from pathlib import Path


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()

    if args.directory.is_symlink():
        fail(f"hashed file-set root must not be a symbolic link: {args.directory}")
    root = args.directory.resolve(strict=True)
    if not root.is_dir():
        fail(f"not a directory: {root}")

    entries: list[tuple[bytes, Path]] = []
    def walk_error(error: OSError) -> None:
        fail(f"cannot read hashed file set: {error}")

    for directory, dirnames, filenames in os.walk(root, followlinks=False, onerror=walk_error):
        directory_path = Path(directory)
        for name in [*dirnames, *filenames]:
            path = directory_path / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                fail(f"symbolic links are not allowed in hashed file sets: {path}")
        for name in filenames:
            path = directory_path / name
            mode = path.lstat().st_mode
            if not stat.S_ISREG(mode):
                fail(f"non-regular file in hashed file set: {path}")
            relative = path.relative_to(root)
            entries.append((os.fsencode(str(relative)), path))

    digest = hashlib.sha256()
    for relative_bytes, path in sorted(entries, key=lambda item: item[0]):
        content_digest = hashlib.sha256(path.read_bytes()).digest()
        digest.update(len(relative_bytes).to_bytes(8, "big"))
        digest.update(relative_bytes)
        digest.update(content_digest)
    print(digest.hexdigest())


if __name__ == "__main__":
    main()
