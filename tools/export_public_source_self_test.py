#!/usr/bin/env python3
"""Adversarial fixtures for the dirty-worktree public-source allowlist exporter."""

from __future__ import annotations

import base64
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path


def load_exporter(repository: Path):
    path = repository / "tools/export_public_source.py"
    spec = importlib.util.spec_from_file_location("twister_public_exporter", path)
    if spec is None or spec.loader is None:
        raise SystemExit("cannot load public-source exporter")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_file(path: Path, data: bytes, *, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(0o755 if executable else 0o644)


def write_fixture(root: Path, repository: Path, exporter) -> None:
    for relative in sorted(exporter.PUBLIC_EXACT_FILES):
        path = root / relative
        if relative == "tools/verify_release_source_state.py":
            data = (repository / relative).read_bytes()
        elif relative == ".gitignore":
            data = b"*.log\n*.jsonl\n"
        elif PureSuffix(relative) == ".json":
            data = b"{}\n"
        elif PureSuffix(relative) in {".sh", ".py"}:
            data = b"#!/bin/sh\n# public fixture\n"
        else:
            data = b"public fixture\n"
        write_file(path, data, executable=PureSuffix(relative) in {".sh", ".py"})

    directory_fixtures = {
        "screenshots/generate-glass-theme.jpg": b"JPEG fixture\n",
        "app/icon/AppIcon.png": b"PNG fixture\n",
        "app/Twisterminigen/Sources/App.swift": b"let value = 1\n",
        "app/Twisterminigen/Tests/AppTests.swift": b"let testValue = 1\n",
        "engine/Krea2Engine/Sources/Engine.swift": b"let engineValue = 1\n",
        "engine/Krea2Engine/Tests/EngineTests.swift": b"let engineTestValue = 1\n",
    }
    for relative, data in directory_fixtures.items():
        write_file(root / relative, data)


def PureSuffix(relative: str) -> str:
    return Path(relative).suffix.casefold()


def expect_rejected(exporter, root: Path, destination: Path, label: str) -> None:
    try:
        exporter.export_public_source(root, destination)
    except exporter.ExportError:
        return
    raise SystemExit(f"public-source exporter accepted forbidden fixture: {label}")


def main() -> None:
    repository = Path(__file__).resolve().parent.parent
    exporter = load_exporter(repository)
    with tempfile.TemporaryDirectory(prefix="twister-public-export-self-test-") as temporary:
        fixture_parent = Path(temporary)
        root = fixture_parent / "worktree"
        root.mkdir()
        write_fixture(root, repository, exporter)

        private_files = {
            ".git/private-object": b"private Git object\n",
            "." + "cl" + "aude.json": b'{"private":true}\n',
            "artifacts/local-output.txt": b"local artifact\n",
            "docs/private.txt": b"private notes\n",
            "tools/UI_SMOKE_RECEIPT.md": b"internal evidence\n",
            "tools/audit-results.json": b'{"private":true}\n',
        }
        for relative, data in private_files.items():
            write_file(root / relative, data)

        source_with_xattr = root / "app/Twisterminigen/Sources/App.swift"
        xattr_tool = Path("/usr/bin/xattr")
        private_xattr = "com.twisterminigen.private-fixture"
        if xattr_tool.is_file():
            result = subprocess.run(
                [
                    str(xattr_tool),
                    "-w",
                    private_xattr,
                    "private metadata fixture",
                    str(source_with_xattr),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if result.returncode != 0:
                raise SystemExit("public-source exporter self-test cannot create xattr fixture")

        destination = fixture_parent / "public"
        count = exporter.export_public_source(root, destination)
        if count <= len(exporter.PUBLIC_EXACT_FILES):
            raise SystemExit("public-source exporter omitted approved source directories")
        for relative in private_files:
            if (destination / relative).exists():
                raise SystemExit(f"public-source exporter copied private path: {relative}")
        if (destination / ".git").exists():
            raise SystemExit("public-source exporter copied Git metadata")
        exported_entries = [destination, *destination.rglob("*")]
        for path in exported_entries:
            attributes = exporter.extended_attributes(path)
            if private_xattr in attributes:
                raise SystemExit(
                    f"public-source exporter copied private extended attribute: {path}"
                )
            exporter.verify_export_metadata(path)

        existing = fixture_parent / "existing"
        existing.mkdir()
        expect_rejected(exporter, root, existing, "existing destination")

        chat_history_name = "chat-" + "history.txt"
        bad_path = root / "app/Twisterminigen/Sources" / chat_history_name
        write_file(bad_path, b"private chat\n")
        expect_rejected(exporter, root, fixture_parent / "bad-path", "chat history path")
        bad_path.unlink()

        encoded = root / "app/Twisterminigen/Sources/Encoded.swift"
        private_path = ("/" + "Users/local-owner/private").encode()
        write_file(encoded, base64.b64encode(private_path) + b"\n")
        expect_rejected(exporter, root, fixture_parent / "base64", "base64 local path")
        encoded.unlink()

        hex_encoded = root / "app/Twisterminigen/Sources/HexEncoded.swift"
        write_file(
            hex_encoded,
            private_path.hex().encode() + b"\n",
        )
        expect_rejected(exporter, root, fixture_parent / "hex", "hex local path")
        hex_encoded.unlink()

        policy = exporter.load_policy(root)
        local_tokens = policy.local_machine_identity_tokens()
        if not local_tokens:
            raise SystemExit("public-source exporter self-test cannot derive local identity token")
        bare_identity = root / "app/Twisterminigen/Sources/LocalIdentity.swift"
        write_file(bare_identity, local_tokens[0] + b"\n")
        expect_rejected(
            exporter,
            root,
            fixture_parent / "local-identity",
            "bare local identity",
        )
        bare_identity.unlink()

        volume = root / "app/Twisterminigen/Sources/Volume.swift"
        write_file(volume, ("/" + "Volumes/Work/private\n").encode())
        expect_rejected(exporter, root, fixture_parent / "volume", "Volumes path")
        volume.unlink()

        compressed = root / "app/Twisterminigen/Sources/Payload.swift"
        write_file(compressed, b"\x1f\x8b\x08\x00compressed")
        expect_rejected(exporter, root, fixture_parent / "gzip", "disguised gzip")
        compressed.unlink()

        link = root / "app/Twisterminigen/Sources/PublicLink.swift"
        link.symlink_to("App.swift")
        expect_rejected(exporter, root, fixture_parent / "symlink", "source symlink")
        link.unlink()

        appledouble = root / "app/Twisterminigen/Sources/._App.swift"
        write_file(appledouble, b"resource-fork sidecar fixture\n")
        expect_rejected(
            exporter,
            root,
            fixture_parent / "appledouble",
            "AppleDouble sidecar",
        )

    print(
        "✓ public-source exporter self-test passed: explicit allowlist + private/Git/UI evidence "
        "exclusion + xattr non-copy + destination/path/base64/hex/local-identity/"
        "volume-mount/gzip/symlink/AppleDouble rejection"
    )


if __name__ == "__main__":
    main()
