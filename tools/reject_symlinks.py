#!/usr/bin/env python3
"""Fail closed when any symbolic link exists below a release bundle root."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    if args.root.is_symlink():
        fail(f"release bundle root must not be a symbolic link: {args.root}")
    try:
        root = args.root.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve release bundle root: {error}")
    if not root.is_dir():
        fail(f"release bundle root is not a directory: {root}")
    count = 0

    def walk_error(error: OSError) -> None:
        fail(f"cannot enumerate release bundle for symbolic links: {error}")

    for directory, dirnames, filenames in os.walk(root, followlinks=False, onerror=walk_error):
        directory_path = Path(directory)
        for name in [*dirnames, *filenames]:
            candidate = directory_path / name
            try:
                is_link = candidate.is_symlink()
            except OSError as error:
                fail(f"cannot inspect release bundle entry {candidate}: {error}")
            if is_link:
                fail(f"release app bundle contains a forbidden symbolic link: {candidate}")
            count += 1
    print(f"verified symlink-free release bundle: {count} entries")


if __name__ == "__main__":
    main()
