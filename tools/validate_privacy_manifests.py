#!/usr/bin/env python3
"""Validate Twisterminigen's no-tracking/no-collected-data privacy policy."""

from __future__ import annotations

import argparse
import os
import plistlib
import sys
from pathlib import Path


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_manifest(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        fail(f"privacy manifest must be a regular non-symlink file: {path}")
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"invalid privacy manifest {path}: {error}")
    if not isinstance(value, dict):
        fail(f"privacy manifest root must be a dictionary: {path}")
    return value


def validate_policy(path: Path, manifest: dict, *, root: bool) -> None:
    if root:
        if manifest.get("NSPrivacyTracking") is not False:
            fail(f"root privacy manifest must declare NSPrivacyTracking=false: {path}")
        if manifest.get("NSPrivacyTrackingDomains") != []:
            fail(f"root privacy manifest must contain an empty NSPrivacyTrackingDomains array: {path}")
        if manifest.get("NSPrivacyCollectedDataTypes") != []:
            fail(f"root privacy manifest must contain an empty NSPrivacyCollectedDataTypes array: {path}")

    if "NSPrivacyTracking" in manifest and manifest["NSPrivacyTracking"] is not False:
        fail(f"nested privacy manifest declares tracking or an invalid tracking value: {path}")
    if "NSPrivacyTrackingDomains" in manifest:
        domains = manifest["NSPrivacyTrackingDomains"]
        if not isinstance(domains, list) or domains:
            fail(f"privacy manifest contains tracking domains contrary to policy: {path}")
    if "NSPrivacyCollectedDataTypes" in manifest:
        collected = manifest["NSPrivacyCollectedDataTypes"]
        if not isinstance(collected, list) or collected:
            fail(f"privacy manifest contains collected data types contrary to policy: {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root-manifest", required=True, type=Path)
    parser.add_argument("--search-root", required=True, type=Path)
    args = parser.parse_args()

    root_manifest_input = args.root_manifest
    if root_manifest_input.is_symlink():
        fail(f"root privacy manifest must not be a symbolic link: {root_manifest_input}")
    root_manifest = root_manifest_input.resolve(strict=True)
    search_root = args.search_root.resolve(strict=True)
    if not search_root.is_dir():
        fail(f"privacy manifest search root is not a directory: {search_root}")

    manifests: list[Path] = []

    def walk_error(error: OSError) -> None:
        fail(f"cannot read privacy manifest search tree: {error}")

    for directory, dirnames, filenames in os.walk(
        search_root, followlinks=False, onerror=walk_error
    ):
        directory_path = Path(directory)
        for dirname in dirnames:
            if (directory_path / dirname).is_symlink():
                fail(f"symbolic-link directory encountered during privacy manifest scan: {directory_path / dirname}")
        if "PrivacyInfo.xcprivacy" in filenames:
            manifests.append(directory_path / "PrivacyInfo.xcprivacy")
    if root_manifest not in [path.resolve() for path in manifests]:
        fail(f"root privacy manifest is outside the scanned bundle/source tree: {root_manifest}")

    for path in sorted(manifests):
        resolved = path.resolve(strict=True)
        manifest = load_manifest(path)
        validate_policy(resolved, manifest, root=resolved == root_manifest)
    print(f"✓ privacy manifest policy verified: {len(manifests)} manifest(s)")


if __name__ == "__main__":
    main()
