#!/usr/bin/env python3
"""Export an explicit, privacy-scanned public source allowlist from the current worktree."""

from __future__ import annotations

import argparse
import importlib.util
import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path, PurePosixPath


PUBLIC_ROOT_FILES = {
    ".gitignore",
    "LICENSE",
    "README.md",
    "RELEASING.md",
    "SECURITY.md",
    "NOTICE",
    "KREA-2-COMMUNITY-LICENSE.txt",
    "THIRD_PARTY_LICENSES.md",
    "PRIVACY.md",
    "CONTENT_SAFETY.md",
}
PUBLIC_PACKAGE_FILES = {
    "app/Twisterminigen/Package.swift",
    "app/Twisterminigen/Package.resolved",
    "app/Twisterminigen/Release.entitlements",
    "app/Twisterminigen/.swiftpm/xcode/.release-workdir",
    (
        "app/Twisterminigen/.swiftpm/xcode/xcshareddata/xcschemes/"
        "Twisterminigen-Distribution.xcscheme"
    ),
    "engine/Krea2Engine/Package.swift",
    "engine/Krea2Engine/Package.resolved",
}
PUBLIC_WORKFLOW_FILES = {
    ".github/workflows/ci.yml",
}
PUBLIC_TOOL_FILES = {
    "tools/bundle_app.sh",
    "tools/exclusive_rename.c",
    "tools/export_public_source.py",
    "tools/export_public_source_self_test.py",
    "tools/extract_app_intents_metadata.sh",
    "tools/hash_file_set.py",
    "tools/install_test_metallib.py",
    "tools/privacy_scan.sh",
    "tools/privacy_scan_self_test.py",
    "tools/reject_symlinks.py",
    "tools/release_runtime_products.json",
    "tools/release_source_state_self_test.py",
    "tools/signing_normalized_macho.py",
    "tools/source_release_gate.sh",
    "tools/test_with_mlx_metallib.sh",
    "tools/validate_privacy_manifests.py",
    "tools/verify_release_coverage.sh",
    "tools/verify_release_receipt.sh",
    "tools/verify_release_source_state.py",
    "tools/verify_resolved_checkouts.py",
    "tools/verify_runtime_payload.py",
    "tools/verify_signed_entitlements.py",
}
PUBLIC_EXACT_FILES = (
    PUBLIC_ROOT_FILES
    | PUBLIC_PACKAGE_FILES
    | PUBLIC_TOOL_FILES
    | PUBLIC_WORKFLOW_FILES
)

PUBLIC_DIRECTORY_SUFFIXES = {
    "screenshots": {".jpg"},
    "app/icon": {".icns", ".json", ".png"},
    "app/Twisterminigen/Sources": {
        ".entitlements",
        ".icns",
        ".jpeg",
        ".jpg",
        ".json",
        ".md",
        ".metal",
        ".plist",
        ".png",
        ".strings",
        ".swift",
        ".xcconfig",
        ".xcprivacy",
    },
    "app/Twisterminigen/Tests": {".json", ".plist", ".swift"},
    "engine/Krea2Engine/Sources": {".json", ".metal", ".swift"},
    "engine/Krea2Engine/Tests": {".json", ".swift"},
}


class ExportError(RuntimeError):
    pass


def load_policy(root: Path):
    policy_path = root / "tools/verify_release_source_state.py"
    spec = importlib.util.spec_from_file_location("twister_public_source_policy", policy_path)
    if spec is None or spec.loader is None:
        raise ExportError(f"cannot load public-source policy: {policy_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_bytes(path: Path) -> tuple[bytes, int]:
    if path.is_symlink():
        raise ExportError(f"symbolic link is forbidden in public source: {path}")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ExportError(f"public source entry is not a regular file: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks), metadata.st_mode
    finally:
        os.close(descriptor)


def validate_candidate(policy, relative: str, data: bytes) -> None:
    reason = policy.public_path_reason(relative, require_allowlisted=True)
    if reason:
        raise ExportError(f"{reason}: {relative}")
    path_findings = policy.public_path_privacy_findings(relative)
    if path_findings:
        raise ExportError(f"{path_findings[0]} in publishable path: {relative}")
    if len(data) > policy.MAX_PUBLIC_FILE_BYTES:
        raise ExportError(
            f"public-source file exceeds {policy.MAX_PUBLIC_FILE_BYTES} bytes: {relative}"
        )
    findings = policy.privacy_findings_for_path(relative, data)
    if findings:
        raise ExportError(f"{findings[0]}: {relative}")


def walk_public_directory(root: Path, relative_root: str, suffixes: set[str], policy):
    source_root = root / relative_root
    if not source_root.is_dir() or source_root.is_symlink():
        raise ExportError(f"required public source directory is missing or unsafe: {relative_root}")
    selected: list[tuple[str, bytes, int]] = []
    for current, directories, filenames in os.walk(source_root, followlinks=False):
        current_path = Path(current)
        for directory in list(directories):
            absolute = current_path / directory
            relative = absolute.relative_to(root).as_posix()
            if absolute.is_symlink():
                raise ExportError(f"symbolic-link directory is forbidden: {relative}")
            reason = policy.public_path_reason(f"{relative}/public-source-probe")
            if reason:
                raise ExportError(f"{reason}: {relative}")
        for filename in filenames:
            absolute = current_path / filename
            relative = absolute.relative_to(root).as_posix()
            data, mode = source_bytes(absolute)
            # Scan every file found under an approved source directory. Unsupported but harmless
            # extensions are omitted; a disguised private/archive payload fails before omission.
            validate_candidate(policy, relative, data)
            if PurePosixPath(relative).suffix.casefold() in suffixes:
                selected.append((relative, data, mode))
    return selected


def collect_public_files(root: Path, policy) -> list[tuple[str, bytes, int]]:
    if PUBLIC_EXACT_FILES != policy.PUBLIC_EXACT_FILES:
        raise ExportError("exporter exact-file allowlist does not match the release verifier")
    if PUBLIC_DIRECTORY_SUFFIXES != policy.PUBLIC_DIRECTORY_SUFFIXES:
        raise ExportError("exporter directory allowlist does not match the release verifier")

    selected: list[tuple[str, bytes, int]] = []
    for relative in sorted(PUBLIC_EXACT_FILES):
        absolute = root / relative
        if not absolute.exists() or absolute.is_symlink():
            raise ExportError(f"required public source file is missing or unsafe: {relative}")
        data, mode = source_bytes(absolute)
        validate_candidate(policy, relative, data)
        selected.append((relative, data, mode))
    for relative_root, suffixes in sorted(PUBLIC_DIRECTORY_SUFFIXES.items()):
        selected.extend(walk_public_directory(root, relative_root, suffixes, policy))

    names = [relative for relative, _data, _mode in selected]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise ExportError(f"duplicate public allowlist entries: {duplicates}")
    return sorted(selected, key=lambda item: item[0])


def extended_attributes(path: Path) -> tuple[str, ...]:
    if hasattr(os, "listxattr"):
        return tuple(sorted(os.listxattr(path)))
    xattr_tool = Path("/usr/bin/xattr")
    if not xattr_tool.is_file():
        return ()
    result = subprocess.run(
        [str(xattr_tool), str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise ExportError(f"cannot inspect extended attributes on public export: {path}")
    return tuple(sorted(line for line in result.stdout.splitlines() if line))


def verify_export_metadata(path: Path) -> None:
    # macOS may attach its fixed two-byte provenance marker to any newly created file. It is not
    # copied from the source and Git does not store it. Every other xattr, including ResourceFork,
    # must be absent.
    unexpected = [
        attribute
        for attribute in extended_attributes(path)
        if attribute != "com.apple.provenance"
    ]
    if unexpected:
        raise ExportError(
            f"unexpected extended attributes on public export: {path} ({unexpected})"
        )


def write_export(destination: Path, selected: list[tuple[str, bytes, int]]) -> None:
    parent = destination.parent.resolve(strict=True)
    final = parent / destination.name
    if not destination.name or os.path.lexists(final):
        raise ExportError(f"destination must be absent: {final}")
    staging = Path(tempfile.mkdtemp(prefix=f".{destination.name}.staging-", dir=parent))
    try:
        for relative, data, source_mode in selected:
            target = staging / relative
            target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            with target.open("xb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            target.chmod(0o755 if source_mode & stat.S_IXUSR else 0o644)
        for current, directories, filenames in os.walk(staging, topdown=False):
            current_path = Path(current)
            for name in filenames:
                verify_export_metadata(current_path / name)
            for name in directories:
                verify_export_metadata(current_path / name)
        verify_export_metadata(staging)
        if os.path.lexists(final):
            raise ExportError(f"destination appeared during export: {final}")
        os.rename(staging, final)
    except BaseException:
        if staging.exists():
            shutil.rmtree(staging)
        raise


def export_public_source(root: Path, destination: Path) -> int:
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise ExportError(f"source root is not a directory: {root}")
    policy = load_policy(root)
    selected = collect_public_files(root, policy)
    write_export(destination, selected)
    return len(selected)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    try:
        count = export_public_source(args.root, args.destination)
    except (ExportError, OSError) as error:
        raise SystemExit(f"error: {error}")
    print(f"✓ exported {count} privacy-scanned public source files to {args.destination}")


if __name__ == "__main__":
    main()
