#!/usr/bin/env python3
"""Verify fresh SwiftPM checkouts against every Package.resolved pin."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def run_git(checkout: Path, *arguments: str, binary: bool = False) -> str | bytes:
    result = subprocess.run(
        ["git", "-C", str(checkout), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        fail(f"git {' '.join(arguments)} failed for {checkout.name}: {detail}")
    if binary:
        return result.stdout
    return result.stdout.decode("utf-8", "strict").strip()


def canonical_remote(value: str) -> str:
    value = value.strip()
    if value.startswith("git@") and ":" in value:
        host, path = value[4:].split(":", 1)
        value = f"https://{host}/{path}"
    parsed = urlparse(value)
    if parsed.scheme and parsed.netloc:
        path = parsed.path.rstrip("/")
        if path.endswith(".git"):
            path = path[:-4]
        return f"{parsed.netloc.lower()}{path}".lower()
    value = value.rstrip("/")
    if value.endswith(".git"):
        value = value[:-4]
    return value.lower()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("package_resolved", type=Path)
    parser.add_argument("checkouts", type=Path)
    parser.add_argument("--inventory-output", type=Path)
    args = parser.parse_args()

    resolved_path = args.package_resolved.resolve(strict=True)
    checkouts_root = args.checkouts.resolve(strict=True)
    if not checkouts_root.is_dir():
        fail(f"checkout root is not a directory: {checkouts_root}")

    try:
        document = json.loads(resolved_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot parse {resolved_path}: {error}")
    pins = document.get("pins")
    if not isinstance(pins, list) or not pins:
        fail(f"Package.resolved has no pins: {resolved_path}")

    checkout_directories = [path for path in checkouts_root.iterdir() if path.is_dir()]
    non_directories = [path.name for path in checkouts_root.iterdir() if not path.is_dir()]
    if non_directories:
        fail(f"unexpected files in checkout root: {', '.join(sorted(non_directories))}")
    by_identity: dict[str, list[Path]] = {}
    for checkout in checkout_directories:
        if checkout.is_symlink():
            fail(f"checkout must not be a symbolic link: {checkout}")
        by_identity.setdefault(checkout.name.casefold(), []).append(checkout)

    inventory_pins: list[dict[str, str]] = []
    expected_directories: set[Path] = set()
    seen_identities: set[str] = set()
    for pin in pins:
        if not isinstance(pin, dict):
            fail("Package.resolved contains a non-object pin")
        identity = pin.get("identity")
        location = pin.get("location")
        state = pin.get("state")
        if not isinstance(identity, str) or not identity:
            fail("Package.resolved pin has no identity")
        if identity.casefold() in seen_identities:
            fail(f"duplicate Package.resolved identity: {identity}")
        seen_identities.add(identity.casefold())
        if not isinstance(location, str) or not location:
            fail(f"Package.resolved pin has no location: {identity}")
        if not isinstance(state, dict) or not isinstance(state.get("revision"), str):
            fail(f"Package.resolved pin has no revision: {identity}")
        revision = state["revision"].lower()
        if len(revision) not in (40, 64) or any(character not in "0123456789abcdef" for character in revision):
            fail(f"invalid pinned revision for {identity}: {revision}")

        matches = by_identity.get(identity.casefold(), [])
        if len(matches) != 1:
            fail(f"expected exactly one checkout for {identity}, found {len(matches)}")
        checkout = matches[0]
        expected_directories.add(checkout)
        head = str(run_git(checkout, "rev-parse", "HEAD")).lower()
        if head != revision:
            fail(f"checkout HEAD mismatch for {identity}: expected {revision}, got {head}")
        status = run_git(
            checkout,
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            binary=True,
        )
        if status:
            fail(f"checkout is not clean (tracked or untracked files): {identity}")
        origin = str(run_git(checkout, "remote", "get-url", "origin"))
        origin_path = Path(origin)
        effective_origin = origin
        if origin_path.is_absolute() and origin_path.is_dir():
            effective_origin = str(run_git(origin_path, "config", "--get", "remote.origin.url"))
        if canonical_remote(effective_origin) != canonical_remote(location):
            fail(
                f"checkout origin mismatch for {identity}: expected {location}, "
                f"got {effective_origin} via {origin}"
            )

        inventory_pins.append(
            {
                "checkoutDirectory": checkout.name,
                "identity": identity,
                "location": location,
                "revision": revision,
                "version": str(state.get("version") or ""),
            }
        )

    extras = sorted(path.name for path in set(checkout_directories) - expected_directories)
    if extras:
        fail(f"checkouts not present in Package.resolved: {', '.join(extras)}")

    inventory = {
        "packageResolvedSHA256": hashlib.sha256(resolved_path.read_bytes()).hexdigest(),
        "pins": sorted(inventory_pins, key=lambda item: item["identity"]),
        "schemaVersion": 1,
    }
    encoded = (json.dumps(inventory, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if args.inventory_output:
        output = args.inventory_output.resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(encoded)
    print(hashlib.sha256(encoded).hexdigest())


if __name__ == "__main__":
    main()
