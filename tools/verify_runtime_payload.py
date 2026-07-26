#!/usr/bin/env python3
"""Verify final Xcode runtime products and the complete normalized app payload."""

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
MODE_RE = re.compile(r"^[0-7]{4}$")
EXCLUDED_PAYLOAD_FILES = {
    "Contents/Resources/ReleaseReceipt.json",
    "Contents/Resources/ReleaseMetadata/RuntimePayloadInventory.json",
}


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


def directory(path: Path, label: str) -> Path:
    if path.is_symlink():
        fail(f"{label} must not be a symbolic link: {path}")
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve {label} {path}: {error}")
    if not resolved.is_dir():
        fail(f"{label} is not a directory: {resolved}")
    return resolved


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        fail(f"cannot hash {path}: {error}")
    return digest.hexdigest()


def mode_string(mode: int, label: str) -> str:
    permissions = stat.S_IMODE(mode)
    if permissions & 0o7000:
        fail(f"{label} contains unsupported set-id/sticky permission bits")
    return f"{permissions:04o}"


def validate_mode(value: object, label: str) -> str:
    if not isinstance(value, str) or not MODE_RE.fullmatch(value):
        fail(f"{label} is not a canonical four-digit POSIX mode")
    if int(value, 8) & 0o7000:
        fail(f"{label} contains unsupported set-id/sticky permission bits")
    return value


def validate_inventory_path(value: object, label: str, *, allow_root: bool) -> str:
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        fail(f"{label} is not a safe relative path")
    if value == ".":
        if allow_root:
            return value
        fail(f"{label} cannot identify the payload root")
    parts = Path(value).parts
    if (
        not parts
        or any(part in {"", ".", ".."} for part in parts)
        or str(Path(value)) != value
    ):
        fail(f"{label} is not a canonical relative path")
    return value


def load_json(path: Path, label: str) -> dict:
    resolved = regular_file(path, label)
    try:
        value = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot parse {label} {resolved}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} root must be an object")
    return value


def sort_paths(paths: set[str] | list[str]) -> list[str]:
    return sorted(paths, key=os.fsencode)


def expected_directories(files: set[str]) -> set[str]:
    directories: set[str] = set()
    for value in files:
        parent = Path(value).parent
        while str(parent) != ".":
            directories.add(str(parent))
            parent = parent.parent
    return directories


def verify_products(products_input: Path, allowlist_path: Path, derived_root_input: Path) -> None:
    products = directory(products_input, "Xcode Products")
    derived_root = directory(derived_root_input, "fresh DerivedData")
    if derived_root != products and derived_root not in products.parents:
        fail("Xcode Products is outside the fresh DerivedData root")
    allowlist = load_json(allowlist_path, "runtime products allowlist")
    if set(allowlist) != {"buildToolExecutables", "bundles", "executable", "schemaVersion"}:
        fail("runtime products allowlist top-level schema is not exact")
    if allowlist.get("schemaVersion") != 1:
        fail("unsupported runtime products allowlist schema")
    executable_name = allowlist.get("executable")
    bundles = allowlist.get("bundles")
    build_tool_executables = allowlist.get("buildToolExecutables")
    if not isinstance(executable_name, str) or not executable_name:
        fail("runtime products allowlist has no executable")
    if not isinstance(bundles, dict) or not bundles:
        fail("runtime products allowlist has no bundles")
    if (
        not isinstance(build_tool_executables, list)
        or any(not isinstance(value, str) or not value for value in build_tool_executables)
        or len(build_tool_executables) != len(set(build_tool_executables))
    ):
        fail("runtime products allowlist has invalid buildToolExecutables")

    executable = regular_file(products / executable_name, "Xcode runtime executable")
    if not executable.stat().st_mode & 0o111:
        fail(f"Xcode runtime executable is not executable: {executable}")

    try:
        product_entries = list(products.iterdir())
        bundle_entries = [entry for entry in product_entries if entry.name.endswith(".bundle")]
        invalid_bundles = [
            entry.name for entry in bundle_entries if entry.is_symlink() or not entry.is_dir()
        ]
        actual_bundles = {entry.name for entry in bundle_entries if entry.is_dir()}
        unexpected_product_entries: list[str] = []
        for entry in product_entries:
            name = entry.name
            if name == executable_name or name in bundles:
                continue
            if name in build_tool_executables:
                if entry.is_symlink() or not entry.is_file() or not entry.stat().st_mode & 0o111:
                    fail(f"allowlisted Xcode build tool is not a regular executable: {entry}")
                continue
            suffix = entry.suffix
            if suffix == ".o":
                if entry.is_symlink() or not entry.is_file():
                    fail(f"Xcode object product is not a regular file: {entry}")
                continue
            if suffix in {".swiftmodule", ".dSYM"} or name == "PackageFrameworks":
                if entry.is_symlink() or not entry.is_dir():
                    fail(f"Xcode auxiliary product is not a regular directory: {entry}")
                continue
            unexpected_product_entries.append(name)
    except OSError as error:
        fail(f"cannot enumerate Xcode Products: {error}")
    if invalid_bundles:
        fail(
            "runtime bundle products must be regular directories, not files/symlinks: "
            + ", ".join(sort_paths(invalid_bundles))
        )
    if unexpected_product_entries:
        fail(
            "unexpected top-level runtime products: "
            + ", ".join(sort_paths(unexpected_product_entries))
        )
    if actual_bundles != set(bundles):
        missing = sort_paths(set(bundles) - actual_bundles)
        extra = sort_paths(actual_bundles - set(bundles))
        fail(f"runtime bundle allowlist mismatch; missing={missing}, unexpected={extra}")

    for bundle_name, file_list in bundles.items():
        if (
            not isinstance(bundle_name, str)
            or not isinstance(file_list, list)
            or not file_list
            or any(not isinstance(value, str) or not value for value in file_list)
            or len(file_list) != len(set(file_list))
        ):
            fail(f"invalid runtime bundle allowlist entry: {bundle_name}")
        bundle = directory(products / bundle_name, f"runtime bundle {bundle_name}")
        allowed_files = set(file_list)
        allowed_directories = expected_directories(allowed_files)
        actual_files: set[str] = set()
        actual_directories: set[str] = set()

        def walk_error(error: OSError) -> None:
            fail(f"cannot enumerate runtime bundle {bundle_name}: {error}")

        for current, dirnames, filenames in os.walk(bundle, followlinks=False, onerror=walk_error):
            current_path = Path(current)
            for name in [*dirnames, *filenames]:
                candidate = current_path / name
                if candidate.is_symlink():
                    fail(f"runtime bundle contains a symbolic link: {candidate}")
            for name in dirnames:
                actual_directories.add(str((current_path / name).relative_to(bundle)))
            for name in filenames:
                candidate = current_path / name
                mode = candidate.lstat().st_mode
                if not stat.S_ISREG(mode):
                    fail(f"runtime bundle contains a non-regular file: {candidate}")
                actual_files.add(str(candidate.relative_to(bundle)))
        if actual_files != allowed_files or actual_directories != allowed_directories:
            fail(
                f"runtime bundle contents differ from allowlist: {bundle_name}; "
                f"files={sort_paths(actual_files)}, directories={sort_paths(actual_directories)}"
            )
    print(f"verified exact fresh Xcode runtime products: 1 executable + {len(bundles)} bundles")


def enumerate_payload(
    app: Path,
    *,
    post_sign: bool,
    allow_stapled_ticket: bool = False,
) -> tuple[dict[str, str], dict[str, tuple[str, int, str]]]:
    directories: dict[str, str] = {
        ".": mode_string(app.lstat().st_mode, "app runtime payload root")
    }
    files: dict[str, tuple[str, int, str]] = {}

    def walk_error(error: OSError) -> None:
        fail(f"cannot enumerate app runtime payload: {error}")

    for current, dirnames, filenames in os.walk(app, followlinks=False, onerror=walk_error):
        current_path = Path(current)
        relative_current = current_path.relative_to(app)
        for name in [*dirnames, *filenames]:
            candidate = current_path / name
            if candidate.is_symlink():
                fail(f"app runtime payload contains a symbolic link: {candidate}")
        if post_sign and relative_current == Path("Contents"):
            dirnames[:] = [name for name in dirnames if name != "_CodeSignature"]
        for name in dirnames:
            relative = str((relative_current / name))
            candidate = current_path / name
            mode = candidate.lstat().st_mode
            if not stat.S_ISDIR(mode):
                fail(f"app runtime payload contains a non-directory entry: {candidate}")
            directories[relative] = mode_string(mode, f"runtime directory {relative}")
        for name in filenames:
            candidate = current_path / name
            relative = str(relative_current / name)
            if relative in EXCLUDED_PAYLOAD_FILES:
                continue
            if allow_stapled_ticket and relative == "Contents/CodeResources":
                mode = candidate.lstat().st_mode
                if not stat.S_ISREG(mode) or candidate.stat().st_size <= 0:
                    fail("stapled notarization ticket must be a non-empty regular file")
                continue
            mode = candidate.lstat().st_mode
            if not stat.S_ISREG(mode):
                fail(f"app runtime payload contains a non-regular file: {candidate}")
            files[relative] = (
                mode_string(mode, f"runtime file {relative}"),
                candidate.stat().st_size,
                sha256_file(candidate),
            )
    return directories, files


def create_inventory(app_input: Path, output_input: Path) -> None:
    app = directory(app_input, "staged app")
    output = output_input.resolve()
    expected_output = app / "Contents/Resources/ReleaseMetadata/RuntimePayloadInventory.json"
    if output != expected_output:
        fail(f"runtime inventory output must be exactly {expected_output}")
    if output.exists() or output.is_symlink():
        fail(f"runtime inventory output already exists: {output}")
    directories, files = enumerate_payload(app, post_sign=False)
    executable_path = "Contents/MacOS/Twisterminigen"
    if executable_path not in files:
        fail("staged runtime payload has no Twisterminigen executable")
    if int(files[executable_path][0], 8) & 0o111 == 0:
        fail("staged Contents/MacOS/Twisterminigen is not executable")
    inventory = {
        "directories": [
            {"mode": directories[path], "path": path}
            for path in sort_paths(set(directories))
        ],
        "excludedFiles": sort_paths(EXCLUDED_PAYLOAD_FILES),
        "files": [
            {
                "mode": files[path][0],
                "path": path,
                "sha256": files[path][2],
                "size": files[path][1],
            }
            for path in sort_paths(set(files))
        ],
        "hashPolicy": "sha256-complete-normalized-runtime-with-modes-v2",
        "modePolicy": "exact-posix-permission-bits-v1",
        "schemaVersion": 2,
    }
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(
            json.dumps(inventory, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except OSError as error:
        fail(f"cannot write runtime payload inventory: {error}")
    print(hashlib.sha256(output.read_bytes()).hexdigest())


def verify_inventory(
    app_input: Path,
    inventory_input: Path,
    unsigned_executable_sha: str,
    *,
    pre_sign: bool,
    allow_stapled_ticket: bool,
) -> None:
    app = directory(app_input, "app")
    inventory = load_json(inventory_input, "runtime payload inventory")
    if (
        set(inventory)
        != {"directories", "excludedFiles", "files", "hashPolicy", "modePolicy", "schemaVersion"}
        or inventory.get("schemaVersion") != 2
        or inventory.get("hashPolicy")
        != "sha256-complete-normalized-runtime-with-modes-v2"
        or inventory.get("modePolicy") != "exact-posix-permission-bits-v1"
        or inventory.get("excludedFiles") != sort_paths(EXCLUDED_PAYLOAD_FILES)
    ):
        fail("runtime payload inventory policy mismatch")
    expected_directories_list = inventory.get("directories")
    expected_files_list = inventory.get("files")
    if (
        not isinstance(expected_directories_list, list)
        or not expected_directories_list
        or not isinstance(expected_files_list, list)
        or not expected_files_list
    ):
        fail("runtime payload inventory has invalid directories or files")
    expected_directories: dict[str, str] = {}
    for entry in expected_directories_list:
        if not isinstance(entry, dict) or set(entry) != {"mode", "path"}:
            fail("runtime payload inventory contains an invalid directory entry")
        path = validate_inventory_path(
            entry.get("path"), "runtime payload directory path", allow_root=True
        )
        mode = validate_mode(entry.get("mode"), f"runtime directory mode for {path}")
        if path in expected_directories:
            fail(f"duplicate runtime payload directory entry: {path}")
        expected_directories[path] = mode
    if sort_paths(set(expected_directories)) != [
        entry["path"] for entry in expected_directories_list
    ]:
        fail("runtime payload inventory directory entries are not in canonical order")
    if "." not in expected_directories:
        fail("runtime payload inventory has no root directory entry")

    expected_files: dict[str, tuple[str, int, str]] = {}
    for entry in expected_files_list:
        if not isinstance(entry, dict) or set(entry) != {"mode", "path", "sha256", "size"}:
            fail("runtime payload inventory contains an invalid file entry")
        path = validate_inventory_path(
            entry.get("path"), "runtime payload file path", allow_root=False
        )
        mode = validate_mode(entry.get("mode"), f"runtime file mode for {path}")
        digest = entry.get("sha256")
        size = entry.get("size")
        if (
            path in EXCLUDED_PAYLOAD_FILES
            or not isinstance(digest, str)
            or not SHA256_RE.fullmatch(digest)
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size < 0
            or path in expected_files
        ):
            fail(f"invalid runtime payload file entry: {entry}")
        expected_files[path] = (mode, size, digest)
    if sort_paths(set(expected_files)) != [entry["path"] for entry in expected_files_list]:
        fail("runtime payload inventory file entries are not in canonical order")
    executable_path = "Contents/MacOS/Twisterminigen"
    if executable_path not in expected_files:
        fail("runtime payload inventory has no Twisterminigen executable")
    if int(expected_files[executable_path][0], 8) & 0o111 == 0:
        fail("runtime payload inventory marks Contents/MacOS/Twisterminigen non-executable")
    if expected_files[executable_path][2] != unsigned_executable_sha:
        fail("runtime payload executable hash differs from UnsignedExecutableSHA256")

    if pre_sign and allow_stapled_ticket:
        fail("a stapled notarization ticket cannot be allowed for pre-sign verification")
    actual_directories, actual_files = enumerate_payload(
        app,
        post_sign=not pre_sign,
        allow_stapled_ticket=allow_stapled_ticket,
    )
    if set(actual_directories) != set(expected_directories):
        fail(
            "runtime payload directory inventory mismatch; "
            f"expected={sort_paths(set(expected_directories))}, "
            f"actual={sort_paths(set(actual_directories))}"
        )
    for path, expected_mode in expected_directories.items():
        if actual_directories[path] != expected_mode:
            fail(
                f"runtime payload directory POSIX mode mismatch: {path}; "
                f"expected={expected_mode}, actual={actual_directories[path]}"
            )
    if set(actual_files) != set(expected_files):
        fail(
            "runtime payload file inventory mismatch; "
            f"missing={sort_paths(set(expected_files) - set(actual_files))}, "
            f"unexpected={sort_paths(set(actual_files) - set(expected_files))}"
        )
    actual_executable_mode = actual_files[executable_path][0]
    if int(actual_executable_mode, 8) & 0o111 == 0:
        fail("Contents/MacOS/Twisterminigen is not executable")
    for path, expected in expected_files.items():
        if not pre_sign and path == executable_path:
            if actual_files[path][0] != expected[0]:
                fail(
                    f"runtime payload file POSIX mode mismatch: {path}; "
                    f"expected={expected[0]}, actual={actual_files[path][0]}"
                )
            continue
        if actual_files[path] != expected:
            if actual_files[path][0] != expected[0]:
                fail(
                    f"runtime payload file POSIX mode mismatch: {path}; "
                    f"expected={expected[0]}, actual={actual_files[path][0]}"
                )
            fail(f"runtime payload file hash/size mismatch: {path}")
    print(
        f"verified complete {'pre-sign' if pre_sign else 'signed'} runtime payload: "
        f"{len(expected_files)} files"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    products = subparsers.add_parser("verify-products")
    products.add_argument("--products", required=True, type=Path)
    products.add_argument("--allowlist", required=True, type=Path)
    products.add_argument("--derived-root", required=True, type=Path)
    create = subparsers.add_parser("create-inventory")
    create.add_argument("--app", required=True, type=Path)
    create.add_argument("--output", required=True, type=Path)
    verify = subparsers.add_parser("verify-inventory")
    verify.add_argument("--app", required=True, type=Path)
    verify.add_argument("--inventory", required=True, type=Path)
    verify.add_argument("--unsigned-executable-sha", required=True)
    verify.add_argument("--pre-sign", action="store_true")
    verify.add_argument("--allow-stapled-ticket", action="store_true")
    args = parser.parse_args()

    if args.command == "verify-products":
        verify_products(args.products, args.allowlist, args.derived_root)
    elif args.command == "create-inventory":
        create_inventory(args.app, args.output)
    else:
        if not SHA256_RE.fullmatch(args.unsigned_executable_sha):
            fail("unsigned executable SHA-256 is invalid")
        verify_inventory(
            args.app,
            args.inventory,
            args.unsigned_executable_sha,
            pre_sign=args.pre_sign,
            allow_stapled_ticket=args.allow_stapled_ticket,
        )


if __name__ == "__main__":
    main()
