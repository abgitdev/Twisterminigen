#!/usr/bin/env python3
"""Extract a signed app's entitlements and compare them exactly with the tracked policy plist."""

from __future__ import annotations

import argparse
import plistlib
import stat
import subprocess
import sys
from pathlib import Path


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def regular_file(path: Path, label: str) -> Path:
    if path.is_symlink():
        fail(f"{label} must not be a symbolic link: {path}")
    try:
        resolved = path.resolve(strict=True)
        mode = resolved.stat().st_mode
    except OSError as error:
        fail(f"cannot read {label} {path}: {error}")
    if not stat.S_ISREG(mode):
        fail(f"{label} must be a regular file: {resolved}")
    return resolved


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("expected", type=Path)
    args = parser.parse_args()

    if args.app.is_symlink():
        fail(f"app must not be a symbolic link: {args.app}")
    try:
        app = args.app.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve app: {error}")
    if not app.is_dir():
        fail(f"app is not a directory: {app}")
    expected_path = regular_file(args.expected, "expected entitlements")
    try:
        expected = plistlib.loads(expected_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"cannot parse expected entitlements: {error}")
    if not isinstance(expected, dict):
        fail("expected entitlements root must be a dictionary")
    if expected != {}:
        fail("release entitlements policy must be the exact empty safe-default dictionary")

    verification = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(app)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if verification.returncode != 0:
        fail(
            "cannot extract entitlements from an invalid signature: "
            + verification.stderr.decode("utf-8", "replace").strip()
        )
    extraction = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(app)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if extraction.returncode != 0 or not extraction.stdout.strip():
        fail(
            "codesign did not return embedded entitlements: "
            + extraction.stderr.decode("utf-8", "replace").strip()
        )
    try:
        actual = plistlib.loads(extraction.stdout)
    except plistlib.InvalidFileException as error:
        fail(f"codesign returned invalid embedded entitlements: {error}")
    if not isinstance(actual, dict) or actual != expected:
        fail(f"signed entitlements differ from tracked policy: expected={expected!r}, actual={actual!r}")
    print(f"verified exact signed entitlements: {expected_path}")


if __name__ == "__main__":
    main()
