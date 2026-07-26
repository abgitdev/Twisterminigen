#!/usr/bin/env python3
"""Install and re-verify a release MLX metallib beside fresh SwiftPM executables."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


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


def scratch_directory(path: Path) -> Path:
    if path.is_symlink():
        fail(f"test scratch must not be a symbolic link: {path}")
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve test scratch {path}: {error}")
    if not resolved.is_dir():
        fail(f"test scratch is not a directory: {resolved}")
    return resolved


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        fail(f"cannot hash file {path}: {error}")
    return digest.hexdigest()


def validate_metallib(path: Path, expected_sha: str) -> Path:
    metallib = regular_file(path, "release MLX metallib")
    actual_sha = sha256_file(metallib)
    if actual_sha != expected_sha:
        fail(f"release MLX metallib SHA-256 mismatch: expected {expected_sha}, got {actual_sha}")
    try:
        with metallib.open("rb") as stream:
            header = stream.read(4)
        size = metallib.stat().st_size
    except OSError as error:
        fail(f"cannot inspect release MLX metallib: {error}")
    if header != b"MTLB" or size < 4096:
        fail("release MLX metallib is missing the MetalLib header or is implausibly small")
    return metallib


def find_test_bundles(scratch: Path) -> list[Path]:
    bundles: list[Path] = []

    def walk_error(error: OSError) -> None:
        fail(f"cannot enumerate fresh test scratch: {error}")

    for directory, dirnames, _ in os.walk(scratch, followlinks=False, onerror=walk_error):
        directory_path = Path(directory)
        if directory_path == scratch:
            dirnames[:] = [name for name in dirnames if name not in {"checkouts", "repositories"}]
        for name in list(dirnames):
            candidate = directory_path / name
            if name.endswith(".xctest"):
                if candidate.is_symlink():
                    fail(f"test bundle must not be a symbolic link: {candidate}")
                bundles.append(candidate)
                dirnames.remove(name)
    if not bundles:
        fail(f"fresh SwiftPM test build produced no .xctest bundles: {scratch}")
    return sorted(bundles, key=lambda path: os.fsencode(str(path.relative_to(scratch))))


def test_executable(test_bundle: Path) -> Path:
    contents = test_bundle / "Contents"
    macos = contents / "MacOS"
    if contents.is_symlink() or macos.is_symlink() or not macos.is_dir():
        fail(f"test bundle has no regular Contents/MacOS directory: {test_bundle}")
    try:
        entries = list(macos.iterdir())
    except OSError as error:
        fail(f"cannot enumerate test bundle executables in {macos}: {error}")
    for entry in entries:
        if entry.is_symlink():
            fail(f"symbolic links are forbidden beside the test executable: {entry}")
    executables = []
    for entry in entries:
        try:
            mode = entry.lstat().st_mode
        except OSError as error:
            fail(f"cannot inspect test bundle entry {entry}: {error}")
        if stat.S_ISREG(mode) and mode & 0o111:
            executables.append(entry)
    if len(executables) != 1:
        fail(
            f"expected exactly one regular executable in {macos}, found {len(executables)}"
        )
    return executables[0]


def contained_executable(path: Path, scratch: Path, label: str) -> Path:
    raw_candidate = Path(os.path.abspath(os.fspath(path)))
    try:
        candidate = raw_candidate.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve {label} {raw_candidate}: {error}")
    try:
        relative = candidate.relative_to(scratch)
    except ValueError:
        fail(f"{label} is outside the fresh test scratch: {raw_candidate}")
    if not relative.parts:
        fail(f"{label} must name a file below the fresh test scratch: {candidate}")
    if relative.parts[0] in {"checkouts", "repositories"}:
        fail(f"{label} cannot come from a dependency source/cache tree: {candidate}")

    raw_scratch = None
    for ancestor in raw_candidate.parents:
        try:
            if ancestor.resolve(strict=True) == scratch:
                raw_scratch = ancestor
                break
        except OSError:
            continue
    if raw_scratch is None:
        fail(f"{label} is not expressed below the fresh test scratch: {raw_candidate}")
    raw_relative = raw_candidate.relative_to(raw_scratch)
    cursor = raw_scratch
    for component in raw_relative.parts:
        cursor /= component
        if cursor.is_symlink():
            fail(f"{label} path contains a symbolic link: {raw_candidate}")
    try:
        mode = candidate.lstat().st_mode
    except OSError as error:
        fail(f"cannot inspect {label} {candidate}: {error}")
    if not stat.S_ISREG(mode) or not mode & 0o111:
        fail(f"{label} must be a regular executable file: {candidate}")
    return candidate


def executable_inventory(scratch: Path, additional: list[Path]) -> list[tuple[str, Path]]:
    consumers = [
        ("xctest", test_executable(bundle)) for bundle in find_test_bundles(scratch)
    ]
    for index, candidate in enumerate(additional, start=1):
        executable = contained_executable(
            candidate, scratch, f"additional SwiftPM executable #{index}"
        )
        if any(existing == executable for _, existing in consumers):
            fail(f"duplicate SwiftPM executable requested: {executable}")
        consumers.append(("standalone", executable))
    consumers = sorted(
        consumers,
        key=lambda item: os.fsencode(str(item[1].relative_to(scratch))),
    )
    destinations: set[Path] = set()
    for _, executable in consumers:
        destination = executable.parent / "mlx.metallib"
        if destination in destinations:
            fail(f"multiple SwiftPM executables share one metallib destination: {destination}")
        destinations.add(destination)
    return consumers


def manifest_consumers(
    scratch: Path, consumers: list[tuple[str, Path]]
) -> list[dict[str, str]]:
    return [
        {
            "destination": str(
                (executable.parent / "mlx.metallib").relative_to(scratch)
            ),
            "executable": str(executable.relative_to(scratch)),
            "kind": kind,
        }
        for kind, executable in consumers
    ]


def copy_exclusive(source: Path, destination: Path) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        source_flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            source_flags |= os.O_NOFOLLOW
        source_fd = os.open(source, source_flags)
        try:
            destination_fd = os.open(destination, flags, 0o644)
            try:
                while chunk := os.read(source_fd, 1024 * 1024):
                    view = memoryview(chunk)
                    while view:
                        written = os.write(destination_fd, view)
                        if written <= 0:
                            fail(f"short write while installing release metallib: {destination}")
                        view = view[written:]
                os.fchmod(destination_fd, 0o644)
            finally:
                os.close(destination_fd)
        finally:
            os.close(source_fd)
    except OSError as error:
        fail(f"cannot install release metallib at {destination}: {error}")


def install(
    source: Path,
    scratch: Path,
    manifest_path: Path,
    expected_sha: str,
    additional_executables: list[Path],
) -> None:
    metallib = validate_metallib(source, expected_sha)
    consumers = executable_inventory(scratch, additional_executables)
    for _, executable in consumers:
        destination = executable.parent / "mlx.metallib"
        if destination.is_symlink():
            fail(f"pre-existing test metallib must not be a symbolic link: {destination}")
        if destination.exists():
            regular_file(destination, "pre-existing test metallib")
            if sha256_file(destination) != expected_sha:
                fail(f"pre-existing test metallib differs from the release metallib: {destination}")
        else:
            copy_exclusive(metallib, destination)
        if sha256_file(destination) != expected_sha:
            fail(f"copied test metallib hash mismatch: {destination}")

    if manifest_path.is_symlink():
        fail(f"test metallib manifest must not be a symbolic link: {manifest_path}")
    manifest = {
        "consumers": manifest_consumers(scratch, consumers),
        "metallibSHA256": expected_sha,
        "schemaVersion": 2,
    }
    try:
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except OSError as error:
        fail(f"cannot write test metallib manifest {manifest_path}: {error}")
    print(f"installed release metallib beside {len(consumers)} SwiftPM executable(s)")


def verify(
    scratch: Path,
    manifest_path: Path,
    expected_sha: str,
    additional_executables: list[Path],
) -> None:
    manifest_file = regular_file(manifest_path, "test metallib manifest")
    try:
        manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot parse test metallib manifest: {error}")
    if (
        not isinstance(manifest, dict)
        or manifest.get("schemaVersion") != 2
        or manifest.get("metallibSHA256") != expected_sha
    ):
        fail("test metallib manifest schema or source SHA-256 mismatch")
    consumers = executable_inventory(scratch, additional_executables)
    expected_consumers = manifest_consumers(scratch, consumers)
    if manifest.get("consumers") != expected_consumers:
        fail("test metallib manifest does not match the exact SwiftPM executable inventory")
    for record, (_, executable) in zip(expected_consumers, consumers):
        relative_value = record["destination"]
        relative = Path(relative_value)
        if relative.is_absolute() or ".." in relative.parts:
            fail(f"test metallib manifest path is not contained: {relative_value}")
        destination = scratch / relative
        if destination != executable.parent / "mlx.metallib":
            fail(f"unexpected test metallib destination shape: {relative_value}")
        cursor = destination.parent
        while cursor != scratch:
            if cursor.is_symlink():
                fail(f"injected test metallib path contains a symbolic link: {relative_value}")
            if scratch not in cursor.parents:
                fail(f"injected test metallib path escapes scratch: {relative_value}")
            cursor = cursor.parent
        resolved_destination = regular_file(destination, "injected test metallib")
        if scratch not in resolved_destination.parents:
            fail(f"injected test metallib resolves outside scratch: {relative_value}")
        if sha256_file(destination) != expected_sha:
            fail(f"injected test metallib changed: {destination}")
    print(f"verified {len(consumers)} injected SwiftPM metallib(s)")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("install", "verify"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--scratch", required=True, type=Path)
        subparser.add_argument("--manifest", required=True, type=Path)
        subparser.add_argument("--expected-sha", required=True)
        subparser.add_argument(
            "--additional-executable", action="append", default=[], type=Path
        )
        if command == "install":
            subparser.add_argument("--source", required=True, type=Path)
    args = parser.parse_args()
    if not SHA256_RE.fullmatch(args.expected_sha):
        fail("expected metallib SHA-256 is invalid")
    scratch = scratch_directory(args.scratch)
    if args.command == "install":
        install(
            args.source,
            scratch,
            args.manifest,
            args.expected_sha,
            args.additional_executable,
        )
    else:
        verify(
            scratch,
            args.manifest,
            args.expected_sha,
            args.additional_executable,
        )


if __name__ == "__main__":
    main()
