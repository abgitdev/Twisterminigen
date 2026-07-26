#!/usr/bin/env python3
"""Fail closed when a Git commit is not a safe, complete release source."""

from __future__ import annotations

import argparse
import base64
import binascii
import codecs
import functools
import json
import os
import posixpath
import re
import socket
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import NoReturn


RELEASE_PATHS = (
    ".gitignore",
    "app/icon",
    "app/Twisterminigen/Package.swift",
    "app/Twisterminigen/Package.resolved",
    "app/Twisterminigen/Release.entitlements",
    "app/Twisterminigen/Sources",
    "app/Twisterminigen/Tests",
    "engine/Krea2Engine/Package.swift",
    "engine/Krea2Engine/Package.resolved",
    "engine/Krea2Engine/Sources",
    "engine/Krea2Engine/Tests",
    "tools",
    "LICENSE",
    "README.md",
    "RELEASING.md",
    "SECURITY.md",
    "NOTICE",
    "KREA-2-COMMUNITY-LICENSE.txt",
    "THIRD_PARTY_LICENSES.md",
    "PRIVACY.md",
    "CONTENT_SAFETY.md",
)

PUBLIC_ROOT_MARKDOWN = {
    "README.md",
    "RELEASING.md",
    "SECURITY.md",
    "PRIVACY.md",
    "CONTENT_SAFETY.md",
    "THIRD_PARTY_LICENSES.md",
}
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
SOURCE_RELEASE_REQUIRED_PATHS = PUBLIC_EXACT_FILES

# The first public source import deliberately uses the same pseudonymous GitHub identity as the
# owner's existing Cyclonminigen source-only repository. A different identity is a policy change,
# not something a workstation's global Git configuration may choose implicitly.
PUBLIC_GIT_NAME = "abgitdev"
PUBLIC_GIT_EMAIL = "266600699+abgitdev@users.noreply.github.com"
ALLOWED_PUBLIC_EMAILS = {
    PUBLIC_GIT_EMAIL.encode("ascii"),
    b"opensource" + b"@krea.ai",
}
ALLOWED_PUBLIC_EMAILS_BY_PATH = {
    "app/Twisterminigen/Tests/TwisterminigenTests/ResumableDownloaderTests.swift": {
        b"//embedded-user" + b"@huggingface.co",
    },
}

FORBIDDEN_DIRECTORY_NAMES = {
    ".build",
    ".build-xcode",
    ".cl" + "aude",
    ".co" + "dex",
    ".continue",
    ".cursor",
    ".hermes",
    ".idea",
    ".local-assistant-state",
    ".vscode",
    "__pycache__",
    "artifacts",
    "audits",
    "deriveddata",
    "docs",
    "memory",
    "notes",
    "private",
    "reference",
    "research",
    "scratch",
    "temp",
    "tmp",
    "upstream",
    "video_edit",
}
FORBIDDEN_ROOT_DIRECTORIES = {
    "caches",
    "gallery",
    "images",
    "inputimages",
    "logs",
    "models",
    "quarantine",
    "recipes",
}
FORBIDDEN_DIRECTORY_PREFIXES = (".aider", ".derived", ".work")
FORBIDDEN_DIRECTORY_SUFFIXES = (
    ".app",
    ".dsym",
    ".mlmodelc",
    ".mlpackage",
    ".xcarchive",
    ".xcresult",
    ".xcuserdata",
)
FORBIDDEN_BASENAMES = {
    ".cursorrules",
    ".ds_store",
    ".netrc",
    ".npmrc",
    ".pypirc",
    "agents.md",
    "cl" + "aude.md",
    "co" + "dex.md",
    "gemini.md",
    "memory.md",
    "project_memory.md",
    "release_readiness_baseline.md",
}
FORBIDDEN_EXACT_PATHS = {
    "tools/UI_SMOKE_OPERATOR_JOURNAL.md",
    "tools/UI_SMOKE_RECEIPT.md",
    "tools/assemble_ui_smoke_evidence.py",
    "tools/local_release_gate.sh",
    "tools/release_snapshot_self_test.py",
    "tools/ui_smoke_control_manifest.json",
    "tools/ui_smoke_evidence_assembler_self_test.py",
    "tools/ui_smoke_schema_self_test.py",
    "tools/verify_ui_smoke_receipt.py",
}
FORBIDDEN_FILE_SUFFIXES = {
    ".7z",
    ".bin",
    ".bz2",
    ".cer",
    ".ckpt",
    ".crash",
    ".db",
    ".dat",
    ".dmg",
    ".dmp",
    ".gguf",
    ".gz",
    ".gzip",
    ".har",
    ".ipa",
    ".ips",
    ".jsonl",
    ".key",
    ".keychain-db",
    ".log",
    ".mobileprovision",
    ".mlmodel",
    ".ndjson",
    ".npy",
    ".npz",
    ".onnx",
    ".p12",
    ".pcap",
    ".pcapng",
    ".pem",
    ".pfx",
    ".pkg",
    ".profdata",
    ".profraw",
    ".provisionprofile",
    ".pt",
    ".pth",
    ".rar",
    ".safetensors",
    ".sqlite",
    ".sqlite3",
    ".tar",
    ".tgz",
    ".trace",
    ".xcactivitylog",
    ".xz",
    ".zip",
    ".zst",
}
FORBIDDEN_FILE_ENDINGS = (
    ".db-shm",
    ".db-wal",
    ".dsym.zip",
    ".sqlite-shm",
    ".sqlite-wal",
    ".sqlite3-shm",
    ".sqlite3-wal",
)
FORBIDDEN_ROOT_DOC_TOKEN = re.compile(
    (
        r"(?:audit|baseline|brief|investigation|journal|plan|private|research|"
        r"stage[0-9]|trans" + r"cript)"
    ),
    re.IGNORECASE,
)
PRIVATE_ARTIFACT_BASENAME = re.compile(
    r"(?:^|[._-])(?:"
    r"audit(?:-report|-results?)?|"
    r"chat(?:-history)?|"
    r"cl" + r"aude|co" + r"dex|conversation|history|"
    r"private|research|session|trans" + r"cript"
    r")(?:[._-]|$)",
    re.IGNORECASE,
)
PRIVATE_ARTIFACT_FILE_SUFFIXES = {
    "",
    ".json",
    ".jsonl",
    ".log",
    ".md",
    ".ndjson",
    ".plist",
    ".text",
    ".txt",
    ".yaml",
    ".yml",
}
MAX_PUBLIC_FILE_BYTES = 16 * 1024 * 1024
PUBLIC_TEXT_SUFFIXES = {
    ".c",
    ".entitlements",
    ".gitignore",
    ".json",
    ".md",
    ".metal",
    ".plist",
    ".py",
    ".resolved",
    ".sh",
    ".strings",
    ".swift",
    ".txt",
    ".xcconfig",
    ".xcprivacy",
    ".yaml",
    ".yml",
}
PUBLIC_TEXT_BASENAMES = {".gitignore", "LICENSE", "NOTICE"}
CYRILLIC_TEXT_PATTERN = re.compile(r"[\u0400-\u04ff]")

LOCAL_PATH_PATTERN = re.compile(
    rb"(?:/" + rb"Users/[A-Za-z0-9._-]+(?:/|\b)|"
    rb"/ho" + rb"me/[A-Za-z0-9._-]+(?:/|\b)|"
    rb"/Vol" + rb"umes/[^/\r\n]+(?:/|\b)|"
    rb"/(?:private/)?var/fol" + rb"ders/[A-Za-z0-9._/-]+|"
    rb"(?:sm" + rb"b|af" + rb"p)://[^ \t\r\n\"'<>]+|"
    rb"[A-Za-z]:\\Users\\[^\\\r\n]+)"
)
EMAIL_PATTERN = re.compile(
    rb"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@"
    rb"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\.[A-Za-z]{2,63}"
)
PRIVATE_KEY_PATTERN = re.compile(
    rb"-----BEGIN (?:RSA |EC |OPENSSH )?" + rb"PRIVATE KEY-----"
)
SECRET_PATTERNS = {
    "AWS access-key ID": re.compile(rb"(?:AKIA|ASIA)[0-9A-Z]{16}"),
    "GitHub token": re.compile(
        rb"(?<![A-Za-z0-9_-])(?:gh"
        + rb"[pousr]_[A-Za-z0-9]{36,255}|github_"
        + rb"pat_[A-Za-z0-9_]{20,255})(?![A-Za-z0-9_-])"
    ),
    "GitLab token": re.compile(
        rb"(?<![A-Za-z0-9_-])glpat-" + rb"[A-Za-z0-9_-]{20,255}(?![A-Za-z0-9_-])"
    ),
    "Google API key": re.compile(
        rb"(?<![A-Za-z0-9_-])AIza" + rb"[0-9A-Za-z_-]{20,100}(?![A-Za-z0-9_-])"
    ),
    "Hugging Face token": re.compile(
        rb"(?<![A-Za-z0-9_-])hf_" + rb"[A-Za-z0-9]{20,255}(?![A-Za-z0-9_-])"
    ),
    "OpenAI/secret-key token": re.compile(
        rb"(?<![A-Za-z0-9_-])sk-"
        + rb"(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,255}(?![A-Za-z0-9_-])"
    ),
    "Slack token": re.compile(
        rb"(?<![A-Za-z0-9_-])xox" + rb"[baprs]-[A-Za-z0-9-]{20,255}(?![A-Za-z0-9_-])"
    ),
    "Stripe secret": re.compile(
        rb"(?<![A-Za-z0-9_-])sk_"
        + rb"(?:live|test)_[A-Za-z0-9]{16,255}(?![A-Za-z0-9_-])"
    ),
}
AI_STATE_MARKERS = (
    b"/.co" + b"dex/",
    b"~/.co" + b"dex",
    b"/.cl" + b"aude/",
    b"~/.cl" + b"aude",
    b"CODEX_" + b"HOME",
    b"CLAUDE_" + b"CODE",
)
PRIVATE_AI_TEXT_PATTERNS = {
    "AI assistant/session marker": re.compile(
        rb"\b(?:chat" + rb"gpt|cl" + rb"aude|co" + rb"dex)\b|"
        rb"\b(?:mcpSession" + rb"ID|toolCall" + rb"ID|conversation[_-]?id|"
        rb"chat[_-]?history)\b",
        re.IGNORECASE,
    ),
    "conversation " + "trans" + "cript marker": re.compile(
        rb"\btrans" + rb"cript\b", re.IGNORECASE
    ),
    "audit artifact marker": re.compile(
        rb"\b(?:audit (?:report|results?)|release readiness base" + rb"line)\b",
        re.IGNORECASE,
    ),
}
JSON_USER_ROLE = re.compile(
    rb'"ro' + rb'le"\s*:\s*"us' + rb'er"', re.IGNORECASE
)
JSON_ASSISTANT_ROLE = re.compile(
    rb'"ro' + rb'le"\s*:\s*"assi' + rb'stant"', re.IGNORECASE
)
PLAIN_USER_ROLE = re.compile(
    rb"(?m)^[ \t]*(?:hum" + rb"an|us" + rb"er):[ \t]+\S", re.IGNORECASE
)
PLAIN_ASSISTANT_ROLE = re.compile(
    rb"(?m)^[ \t]*assi" + rb"stant:[ \t]+\S", re.IGNORECASE
)
HEADING_USER_ROLE = re.compile(
    rb"(?m)^[ \t]*(?:#{1,6}[ \t]+|[-*>][ \t]+)?(?:hum"
    + rb"an|us"
    + rb"er)[ \t]*$",
    re.IGNORECASE,
)
HEADING_ASSISTANT_ROLE = re.compile(
    rb"(?m)^[ \t]*(?:#{1,6}[ \t]+|[-*>][ \t]+)?assi"
    + rb"stant[ \t]*$",
    re.IGNORECASE,
)
BASE64_RUN = re.compile(
    rb"(?<![A-Za-z0-9+/_-])[A-Za-z0-9+/_-]{24,}={0,2}(?![A-Za-z0-9+/_=-])"
)
HEX_RUN = re.compile(rb"(?<![0-9A-Fa-f])[0-9A-Fa-f]{24,}(?![0-9A-Fa-f])")
COMPRESSED_MAGIC = (
    (b"\x1f\x8b", "gzip"),
    (b"PK\x03\x04", "ZIP"),
    (b"BZh", "bzip2"),
    (b"\xfd7zXZ\x00", "xz"),
    (b"7z\xbc\xaf'\x1c", "7-Zip"),
    (b"Rar!\x1a\x07", "RAR"),
    (b"\x28\xb5\x2f\xfd", "Zstandard"),
    (b"\x04\x22\x4d\x18", "LZ4"),
)
PRIVATE_COMMIT_WORDS = re.compile(
    rb"\b(?:(?:private|assistant) conversation|chat history export)\b",
    re.IGNORECASE,
)
ALLOWED_SANITIZED_REF = re.compile(
    r"(?:refs/heads/main|refs/remotes/origin/(?:HEAD|main)|refs/tags/v[0-9][0-9A-Za-z._-]*)"
)
ENCODED_ASCII_RUNS = (
    (re.compile(rb"(?:[\x20-\x7e]\x00){3,}"), 2, 0),
    (re.compile(rb"(?:\x00[\x20-\x7e]){3,}"), 2, 1),
    (re.compile(rb"(?:[\x20-\x7e]\x00\x00\x00){3,}"), 4, 0),
    (re.compile(rb"(?:\x00\x00\x00[\x20-\x7e]){3,}"), 4, 3),
)
PROTECTIVE_GITIGNORE_LINES = {
    b"**/." + b"co" + b"dex/",
    b"**/." + b"cl" + b"aude/",
    b"**/CLA" + b"UDE.md",
    b"**/CO" + b"DEX.md",
    b"**/." + b"cl" + b"aude.json",
    b"**/." + b"co" + b"dex.json",
    b"**/*chat-" + b"history*",
    b"**/*co" + b"dex-session*",
    b"**/*cl" + b"aude-session*",
    b"**/trans" + b"cript.*",
    (
        b"# Internal trans" + b"cript-anchored UI evidence tooling is not part of the "
        b"public source product."
    ),
}


def fail(message: str, paths: list[str] | None = None) -> NoReturn:
    if paths:
        for path in paths:
            print(path, file=sys.stderr)
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def git(root: Path, *arguments: str, check: bool = True) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        fail(f"git {' '.join(arguments)} failed: {detail}")
    return result.stdout


def decode_paths(payload: bytes) -> list[str]:
    return [os.fsdecode(value) for value in payload.split(b"\0") if value]


def tracked_paths(root: Path) -> list[str]:
    return sorted(decode_paths(git(root, "ls-files", "-z")))


def tracked_modes(root: Path, paths: tuple[str, ...] | None = None) -> dict[str, str]:
    arguments = ["ls-files", "-s", "-z"]
    if paths:
        arguments.extend(("--", *paths))
    payload = git(root, *arguments)
    modes: dict[str, str] = {}
    for record in payload.split(b"\0"):
        if not record:
            continue
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode, _object_id, stage = metadata.split(b" ", 2)
        except ValueError:
            fail("git ls-files returned a malformed tracked-input record")
        relative = os.fsdecode(raw_path)
        modes[relative] = f"{mode.decode('ascii', 'replace')}:{stage.decode('ascii', 'replace')}"
    return modes


def tracked_nonregular_inputs(root: Path) -> list[str]:
    """Return tracked binary-release inputs that are symlinks, gitlinks, or non-files."""
    invalid: list[str] = []
    for relative, mode_stage in tracked_modes(root, RELEASE_PATHS).items():
        mode, stage = mode_stage.split(":", 1)
        if mode not in {"100644", "100755"} or stage != "0":
            invalid.append(f"{relative} (git mode {mode}, stage {stage!r})")
    return sorted(invalid)


def tracked_nonregular_public_inputs(root: Path) -> list[str]:
    invalid: list[str] = []
    for relative, mode_stage in tracked_modes(root).items():
        mode, stage = mode_stage.split(":", 1)
        if mode not in {"100644", "100755"} or stage != "0":
            invalid.append(f"{relative} (git mode {mode}, stage {stage!r})")
    return sorted(invalid)


def public_path_allowlisted(name: str) -> bool:
    pure = PurePosixPath(name)
    normalized = pure.as_posix()
    if normalized != name:
        return False
    if normalized in PUBLIC_EXACT_FILES:
        return True
    suffix = pure.suffix.casefold()
    return any(
        normalized.startswith(f"{directory}/") and suffix in suffixes
        for directory, suffixes in PUBLIC_DIRECTORY_SUFFIXES.items()
    )


def public_path_reason(name: str, *, require_allowlisted: bool = False) -> str | None:
    pure = PurePosixPath(name)
    if pure.is_absolute() or ".." in pure.parts:
        return "unsafe path"
    if pure.as_posix() in FORBIDDEN_EXACT_PATHS:
        return "internal UI/audit/release-evidence tool"
    parts = tuple(component.casefold() for component in pure.parts)
    if not parts:
        return "empty path"

    basename = parts[-1]
    suffix = pure.suffix.casefold()
    if basename.startswith("._"):
        return "AppleDouble/resource-fork sidecar"
    if basename in FORBIDDEN_BASENAMES:
        return "AI/private/runtime filename"
    if (
        suffix in PRIVATE_ARTIFACT_FILE_SUFFIXES
        and PRIVATE_ARTIFACT_BASENAME.search(basename)
    ):
        return "AI conversation/audit/history artifact filename"
    if basename == ".env" or basename.startswith(".env."):
        return "environment/credential file"
    if basename.startswith("credentials") and pure.suffix.casefold() == ".json":
        return "credential file"
    if len(parts) == 1 and pure.suffix.casefold() == ".md":
        if pure.name not in PUBLIC_ROOT_MARKDOWN:
            return "root Markdown is private unless explicitly allowlisted"
        if FORBIDDEN_ROOT_DOC_TOKEN.search(pure.stem):
            return "internal audit/research/root document"
    if parts[0] in FORBIDDEN_ROOT_DIRECTORIES:
        return f"runtime/user-data root {parts[0]!r}"

    for component in parts[:-1]:
        if component in FORBIDDEN_DIRECTORY_NAMES:
            return f"private/runtime directory {component!r}"
        if component.startswith(FORBIDDEN_DIRECTORY_PREFIXES):
            return f"generated/private directory {component!r}"
        if component.endswith(FORBIDDEN_DIRECTORY_SUFFIXES):
            return f"bundle/build directory {component!r}"

    if suffix in FORBIDDEN_FILE_SUFFIXES or basename.endswith(FORBIDDEN_FILE_ENDINGS):
        return f"private/build/model artifact suffix {suffix or basename!r}"
    if require_allowlisted and not public_path_allowlisted(name):
        return "path is outside the exact public-source allowlist"
    return None


def tracked_private_inputs(root: Path) -> list[str]:
    """Return tracked paths that must never enter any release commit."""
    return sorted(
        path for path in tracked_paths(root) if public_path_reason(path) is not None
    )


def official_oracle_allowlist(root: Path) -> set[str]:
    manifest_path = root / "tools/golden/te_oracle_manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read text-encoder oracle manifest: {error}")
    oracle_files = manifest.get("oracle_files") if isinstance(manifest, dict) else None
    if not isinstance(oracle_files, dict) or not oracle_files:
        fail("text-encoder oracle manifest has no exact oracle_files map")
    allowed: set[str] = set()
    for name, digest in oracle_files.items():
        if (
            not isinstance(name, str)
            or not name
            or Path(name).name != name
            or not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            fail("text-encoder oracle manifest has an invalid oracle_files entry")
        allowed.add(f"tools/golden/te/{name}")
    return allowed


def allowed_ignored_input(root: Path, relative: str, oracle_allowlist: set[str]) -> bool:
    # Only disposable tool build directories and exact official oracle tensors are allowed.
    if relative.startswith("tools/venv/"):
        return True
    if "/__pycache__/" in f"/{relative}" or relative.startswith("tools/__pycache__/"):
        return True
    if relative in oracle_allowlist:
        path = root / relative
        return path.is_file() and not path.is_symlink()
    return False


def searchable_content_views(data: bytes) -> list[bytes]:
    """Return raw plus deterministic UTF-16/UTF-32 and embedded ASCII text views."""
    views = [data]
    bom_encodings = (
        (codecs.BOM_UTF32_LE, "utf-32-le"),
        (codecs.BOM_UTF32_BE, "utf-32-be"),
        (codecs.BOM_UTF16_LE, "utf-16-le"),
        (codecs.BOM_UTF16_BE, "utf-16-be"),
    )
    for bom, encoding in bom_encodings:
        if data.startswith(bom):
            decoded = data[len(bom) :].decode(encoding, errors="strict").encode("utf-8")
            if decoded and decoded not in views:
                views.append(decoded)
            break

    encoded_views: list[bytes] = []
    for pattern, stride, offset in ENCODED_ASCII_RUNS:
        for match in pattern.finditer(data):
            decoded = match.group(0)[offset::stride]
            if decoded and decoded not in encoded_views:
                encoded_views.append(decoded)
    for decoded in encoded_views:
        if any(decoded != other and decoded in other for other in encoded_views):
            continue
        if decoded not in views:
            views.append(decoded)
    return views


@functools.lru_cache(maxsize=1)
def local_machine_identity_tokens() -> tuple[bytes, ...]:
    candidates = {
        Path.home().name,
        os.environ.get("USER", ""),
        os.environ.get("LOGNAME", ""),
        os.environ.get("HOSTNAME", ""),
        socket.gethostname(),
    }
    for hostname in tuple(candidates):
        if "." in hostname:
            candidates.add(hostname.split(".", 1)[0])
    generic = {
        "admin",
        "builder",
        "localhost",
        "release",
        "root",
        "runner",
        "unknown",
        "user",
    }
    tokens: set[bytes] = set()
    for candidate in candidates:
        normalized = candidate.strip().casefold()
        if (
            len(normalized) < 6
            or normalized in generic
            or re.fullmatch(r"[a-z0-9][a-z0-9._-]*", normalized) is None
        ):
            continue
        tokens.add(normalized.encode("ascii"))
    return tuple(sorted(tokens))


def contains_local_machine_token(view: bytes) -> bool:
    folded = view.lower()
    for token in local_machine_identity_tokens():
        pattern = (
            rb"(?<![A-Za-z0-9._-])"
            + re.escape(token)
            + rb"(?![A-Za-z0-9._-])"
        )
        if re.search(pattern, folded):
            return True
    return False


def compressed_container_reason(data: bytes) -> str | None:
    for magic, label in COMPRESSED_MAGIC:
        if data.startswith(magic):
            return f"{label} compressed/archive container"
    if len(data) >= 262 and data[257:262] == b"ustar":
        return "tar archive container"
    return None


def protective_line_allowed(path: str | None, line: bytes) -> bool:
    return path == ".gitignore" and line.strip() in PROTECTIVE_GITIGNORE_LINES


def matched_line(view: bytes, start: int) -> bytes:
    line_start = view.rfind(b"\n", 0, start) + 1
    line_end = view.find(b"\n", start)
    if line_end < 0:
        line_end = len(view)
    return view[line_start:line_end]


def ai_artifact_findings(views: list[bytes], *, path: str | None) -> list[str]:
    findings: list[str] = []
    for label, pattern in PRIVATE_AI_TEXT_PATTERNS.items():
        for view in views:
            matches = list(pattern.finditer(view))
            if matches and not all(
                protective_line_allowed(path, matched_line(view, match.start()))
                for match in matches
            ):
                findings.append(label)
                break

    for view in views:
        json_users = list(JSON_USER_ROLE.finditer(view))
        json_assistants = list(JSON_ASSISTANT_ROLE.finditer(view))
        plain_users = list(PLAIN_USER_ROLE.finditer(view))
        plain_assistants = list(PLAIN_ASSISTANT_ROLE.finditer(view))
        heading_users = list(HEADING_USER_ROLE.finditer(view))
        heading_assistants = list(HEADING_ASSISTANT_ROLE.finditer(view))
        role_groups = (
            (json_users, json_assistants, "structured user/assistant conversation"),
            (plain_users, plain_assistants, "plain-text user/assistant conversation"),
            (heading_users, heading_assistants, "headed user/assistant conversation"),
        )
        for users, assistants, label in role_groups:
            if not users or not assistants:
                continue
            matches = users + assistants
            if all(
                protective_line_allowed(path, matched_line(view, match.start()))
                for match in matches
            ):
                continue
            findings.append(label)
    return findings


def privacy_content_findings(
    data: bytes,
    *,
    commit_message: bool = False,
    path: str | None = None,
    decode_base64: bool = True,
    decode_hex: bool = True,
) -> list[str]:
    findings: list[str] = []
    try:
        views = searchable_content_views(data)
    except UnicodeDecodeError:
        views = [data]
        findings.append("malformed BOM-tagged Unicode text")

    if any(LOCAL_PATH_PATTERN.search(view) for view in views):
        findings.append("developer-local absolute path")
    if any(contains_local_machine_token(view) for view in views):
        findings.append("local machine username/hostname token")
    if any(PRIVATE_KEY_PATTERN.search(view) for view in views):
        findings.append("embedded private key")
    for label, pattern in SECRET_PATTERNS.items():
        if any(pattern.search(view) for view in views):
            findings.append(f"{label}-shaped secret")
    allowed_emails = {
        address.lower()
        for address in (
            ALLOWED_PUBLIC_EMAILS
            | ALLOWED_PUBLIC_EMAILS_BY_PATH.get(path or "", set())
        )
    }
    unexpected_emails = sorted(
        {
            match.group(0).decode("utf-8", "replace")
            for view in views
            for match in EMAIL_PATTERN.finditer(view)
            if match.group(0).lower() not in allowed_emails
        }
    )
    findings.extend(f"non-public email address {email!r}" for email in unexpected_emails)
    for view in views:
        state_matches: list[int] = []
        for marker in AI_STATE_MARKERS:
            start = 0
            while True:
                index = view.find(marker, start)
                if index < 0:
                    break
                state_matches.append(index)
                start = index + 1
        if state_matches and not all(
            protective_line_allowed(path, matched_line(view, index))
            for index in state_matches
        ):
            findings.append("AI-agent local-state reference")
            break
    findings.extend(ai_artifact_findings(views, path=path))

    container = compressed_container_reason(data)
    if container:
        findings.append(container)

    if decode_base64:
        decoded_payloads: set[bytes] = set()
        for view in views:
            for match in BASE64_RUN.finditer(view):
                token = match.group(0)
                normalized = token.replace(b"-", b"+").replace(b"_", b"/")
                normalized += b"=" * (-len(normalized) % 4)
                try:
                    decoded = base64.b64decode(normalized, validate=True)
                except (binascii.Error, ValueError):
                    continue
                if len(decoded) < 6 or decoded in decoded_payloads:
                    continue
                decoded_payloads.add(decoded)
                decoded_findings = privacy_content_findings(
                    decoded,
                    path=None,
                    decode_base64=False,
                    decode_hex=False,
                )
                findings.extend(
                    f"base64-encoded {finding}" for finding in decoded_findings
                )
    if decode_hex:
        decoded_payloads: set[bytes] = set()
        for view in views:
            for match in HEX_RUN.finditer(view):
                token = match.group(0)
                if len(token) % 2:
                    continue
                try:
                    decoded = bytes.fromhex(token.decode("ascii"))
                except (UnicodeError, ValueError):
                    continue
                if len(decoded) < 6 or decoded in decoded_payloads:
                    continue
                decoded_payloads.add(decoded)
                decoded_findings = privacy_content_findings(
                    decoded,
                    path=None,
                    decode_base64=False,
                    decode_hex=False,
                )
                findings.extend(f"hex-encoded {finding}" for finding in decoded_findings)
    if commit_message and any(PRIVATE_COMMIT_WORDS.search(view) for view in views):
        findings.append("private/AI/audit terminology in commit message")
    return sorted(set(findings))


def privacy_findings_for_path(name: str, data: bytes) -> list[str]:
    findings = privacy_content_findings(data, path=name)
    path = PurePosixPath(name)
    if (
        path.suffix.casefold() in PUBLIC_TEXT_SUFFIXES
        or path.name in PUBLIC_TEXT_BASENAMES
    ):
        try:
            text = data.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            findings.append("public text file is not valid UTF-8")
        else:
            if CYRILLIC_TEXT_PATTERN.search(text):
                findings.append("Cyrillic text is forbidden in public source")
    return sorted(set(findings))


def public_path_privacy_findings(name: str) -> list[str]:
    raw_name = os.fsencode(name)
    # A repository-relative `Users/name/...` path becomes an absolute-path signature when prefixed
    # with a slash. Scan both forms so private data cannot hide in a filename.
    findings = [
        finding
        for finding in privacy_content_findings(raw_name + b"\n/" + raw_name)
        if not finding.startswith("non-public email address")
    ]
    allowed = {address.lower() for address in ALLOWED_PUBLIC_EMAILS}
    for component in PurePosixPath(name).parts:
        raw_component = os.fsencode(component)
        # Apple icon scale suffixes contain an at-sign but are not email addresses.
        if re.search(rb"@[0-9]+x\.(?:gif|jpe?g|pdf|png|tiff?|webp)$", raw_component, re.IGNORECASE):
            continue
        findings.extend(
            f"non-public email address {match.group(0).decode('utf-8', 'replace')!r}"
            for match in EMAIL_PATTERN.finditer(raw_component)
            if match.group(0).lower() not in allowed
        )
    return findings


def current_public_tree_findings(root: Path) -> list[str]:
    findings: list[str] = []
    paths = tracked_paths(root)
    path_set = set(paths)
    missing = sorted(SOURCE_RELEASE_REQUIRED_PATHS - path_set)
    findings.extend(f"required public-source path is not tracked: {path}" for path in missing)

    for path in paths:
        reason = public_path_reason(path, require_allowlisted=True)
        if reason:
            findings.append(f"{reason}: {path}")
        findings.extend(
            f"{finding} in publishable path: {path}"
            for finding in public_path_privacy_findings(path)
        )
        target = root / path
        if not target.exists() and not target.is_symlink():
            findings.append(f"tracked path is absent from the worktree: {path}")
            continue
        if target.is_symlink():
            findings.append(f"symbolic link is not publishable: {path}")
            continue
        if not target.is_file():
            findings.append(f"tracked entry is not a regular file: {path}")
            continue
        size = target.stat().st_size
        if size > MAX_PUBLIC_FILE_BYTES:
            findings.append(
                f"public-source file exceeds {MAX_PUBLIC_FILE_BYTES} bytes: {path} ({size})"
            )
            continue
        data = target.read_bytes()
        findings.extend(f"{finding}: {path}" for finding in privacy_findings_for_path(path, data))
    return findings


def reachable_commits(root: Path) -> list[str]:
    return [
        line
        for line in git(root, "rev-list", "--reverse", "HEAD").decode("ascii").splitlines()
        if line
    ]


def commit_metadata_findings(root: Path, commits: list[str]) -> list[str]:
    findings: list[str] = []
    for commit in commits:
        payload = git(
            root,
            "show",
            "-s",
            (
                "--format=format:%H%x00%P%x00%an%x00%ae%x00%aI%x00"
                "%cn%x00%ce%x00%cI%x00%B"
            ),
            commit,
        )
        fields = payload.split(b"\0", 8)
        if len(fields) != 9:
            findings.append(f"cannot parse commit metadata: {commit}")
            continue
        (
            _sha,
            parents,
            author_name,
            author_email,
            author_date,
            committer_name,
            committer_email,
            committer_date,
            message,
        ) = fields
        identities = (
            ("author", author_name, author_email),
            ("committer", committer_name, committer_email),
        )
        for role, raw_name, raw_email in identities:
            name = raw_name.decode("utf-8", "replace")
            email = raw_email.decode("utf-8", "replace")
            if name != PUBLIC_GIT_NAME or email != PUBLIC_GIT_EMAIL:
                findings.append(
                    f"{commit}: non-public {role} identity {name!r} <{email}>; "
                    f"expected {PUBLIC_GIT_NAME!r} <{PUBLIC_GIT_EMAIL}>"
                )
        for role, date in (("author", author_date), ("committer", committer_date)):
            if not (date.endswith(b"+00:00") or date.endswith(b"Z")):
                findings.append(
                    f"{commit}: {role} timestamp must use UTC (+0000), not a local timezone"
                )
        findings.extend(
            f"{commit}: {finding}"
            for finding in privacy_content_findings(message, commit_message=True)
        )
        if not parents and commit != commits[0]:
            findings.append(f"{commit}: additional root commit in public history")
    return findings


def history_tree_findings(root: Path, commits: list[str]) -> list[str]:
    """Scan every reachable historical tree so deleting a leak cannot make the gate pass."""
    findings: list[str] = []
    scanned_blobs: set[tuple[str, str]] = set()
    for commit in commits:
        tree = git(root, "ls-tree", "-r", "-z", "--full-tree", commit)
        for record in tree.split(b"\0"):
            if not record:
                continue
            try:
                metadata, raw_path = record.split(b"\t", 1)
                mode, object_type, object_id = metadata.split(b" ", 2)
            except ValueError:
                findings.append(f"{commit}: malformed Git tree record")
                continue
            path = os.fsdecode(raw_path)
            if mode not in {b"100644", b"100755"} or object_type != b"blob":
                findings.append(
                    f"{commit}: non-regular historical Git entry {path} "
                    f"(mode {mode.decode('ascii', 'replace')})"
                )
                continue
            reason = public_path_reason(path, require_allowlisted=True)
            if reason:
                findings.append(f"{commit}: {reason}: {path}")
            findings.extend(
                f"{commit}: {finding} in historical path: {path}"
                for finding in public_path_privacy_findings(path)
            )
            oid = object_id.decode("ascii")
            blob_key = (oid, path)
            if blob_key in scanned_blobs:
                continue
            scanned_blobs.add(blob_key)
            size_text = git(root, "cat-file", "-s", oid).decode("ascii").strip()
            try:
                size = int(size_text)
            except ValueError:
                findings.append(f"{commit}: cannot read historical blob size for {path}")
                continue
            if size > MAX_PUBLIC_FILE_BYTES:
                findings.append(
                    f"{commit}: historical blob exceeds {MAX_PUBLIC_FILE_BYTES} bytes: "
                    f"{path} ({size})"
                )
                continue
            data = git(root, "cat-file", "blob", oid)
            findings.extend(
                f"{commit}: {finding}: {path}"
                for finding in privacy_findings_for_path(path, data)
            )
    return findings


def require_clean_public_worktree(root: Path) -> None:
    status = git(
        root,
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--ignore-submodules=none",
    )
    if status:
        entries = [
            os.fsdecode(record).replace("\n", "\\n")
            for record in status.split(b"\0")
            if record
        ]
        fail(
            "source-only release requires a clean tree; every non-ignored file must be committed",
            entries,
        )
    diff_check = subprocess.run(
        ["git", "-C", str(root), "diff", "--check", "HEAD", "--"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if diff_check.returncode != 0:
        detail = diff_check.stdout.decode("utf-8", "replace").strip()
        fail(f"git diff --check failed: {detail}")


def annotated_tag_findings(root: Path, ref: str) -> list[str]:
    object_type = git(root, "cat-file", "-t", ref, check=False).decode().strip()
    if object_type != "tag":
        return []
    data = git(root, "cat-file", "tag", ref)
    header, separator, message = data.partition(b"\n\n")
    findings: list[str] = []
    if not separator:
        return [f"annotated tag object has no message separator: {ref}"]
    tagger_lines = [line for line in header.splitlines() if line.startswith(b"tagger ")]
    if len(tagger_lines) != 1:
        findings.append(f"annotated tag must have exactly one tagger: {ref}")
    else:
        match = re.fullmatch(
            rb"tagger (.*) <([^<>]+)> [0-9]+ ([+-][0-9]{4})",
            tagger_lines[0],
        )
        if match is None:
            findings.append(f"cannot parse annotated-tag identity: {ref}")
        else:
            name = match.group(1).decode("utf-8", "replace")
            email = match.group(2).decode("utf-8", "replace")
            if name != PUBLIC_GIT_NAME or email != PUBLIC_GIT_EMAIL:
                findings.append(
                    f"non-public annotated-tag identity {name!r} <{email}>: {ref}"
                )
            if match.group(3) != b"+0000":
                findings.append(f"annotated-tag timestamp must use UTC (+0000): {ref}")
    findings.extend(
        f"{finding} in annotated tag {ref}"
        for finding in privacy_content_findings(data, commit_message=True)
    )
    if not message.strip():
        findings.append(f"annotated tag has an empty message: {ref}")
    return findings


def unreachable_object_findings(root: Path) -> list[str]:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "fsck",
            "--full",
            "--strict",
            "--no-reflogs",
            "--unreachable",
            "--no-progress",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    output = result.stdout.decode("utf-8", "replace")
    findings = [
        f"unreachable/dangling Git object: {line}"
        for line in output.splitlines()
        if re.search(r"\b(?:unreachable|dangling|missing|broken)\b", line)
    ]
    if result.returncode != 0 and not findings:
        findings.append(f"git fsck failed while proving object closure: {output.strip()}")
    return findings


def public_repository_object_findings(
    root: Path,
    head_commit: str,
    commits: list[str],
    *,
    require_sanitized_root: bool,
) -> list[str]:
    """Reject hidden refs, tag leaks, indirection, and unreachable objects."""
    findings: list[str] = []
    branch = git(root, "symbolic-ref", "-q", "HEAD", check=False).decode().strip()
    if branch != "refs/heads/main":
        findings.append(f"sanitized candidate HEAD must be refs/heads/main, found {branch!r}")

    refs = [
        line
        for line in git(root, "for-each-ref", "--format=%(refname)").decode().splitlines()
        if line
    ]
    if "refs/heads/main" not in refs:
        findings.append("sanitized candidate has no refs/heads/main")
    for ref in refs:
        if not ALLOWED_SANITIZED_REF.fullmatch(ref):
            findings.append(f"non-public local Git ref in public candidate: {ref}")
            continue
        peeled = git(root, "rev-parse", "--verify", f"{ref}^{{commit}}", check=False)
        target = peeled.decode().strip()
        if ref.startswith("refs/tags/"):
            if target not in set(commits):
                findings.append(f"public tag does not resolve into HEAD history: {ref}")
            if require_sanitized_root and target != head_commit:
                findings.append(f"first-release tag does not resolve to sanitized HEAD: {ref}")
        elif target != head_commit:
            findings.append(f"public branch/ref does not resolve to HEAD: {ref}")
        if ref.startswith("refs/tags/"):
            findings.extend(annotated_tag_findings(root, ref))

    shallow = git(root, "rev-parse", "--is-shallow-repository").decode().strip()
    if shallow != "false":
        findings.append("sanitized candidate must not be a shallow repository")
    for git_relative in ("info/grafts", "objects/info/alternates"):
        raw_path = git(root, "rev-parse", "--git-path", git_relative).decode().strip()
        path = Path(raw_path)
        if not path.is_absolute():
            path = root / path
        try:
            if path.is_file() and path.stat().st_size > 0:
                findings.append(f"sanitized candidate uses forbidden Git history indirection: {git_relative}")
        except OSError as error:
            findings.append(f"cannot inspect Git history indirection {git_relative}: {error}")
    findings.extend(unreachable_object_findings(root))
    return findings


def verify_source_only(root: Path, *, require_sanitized_root: bool) -> str:
    require_clean_public_worktree(root)
    commit = git(root, "rev-parse", "--verify", "HEAD^{commit}").decode().strip()
    commits = reachable_commits(root)
    if not commits or commits[-1] != commit:
        fail("cannot resolve a linear reachable public history ending at HEAD")
    if require_sanitized_root and len(commits) != 1:
        fail(
            "first public upload must be a one-commit sanitized root; "
            f"found {len(commits)} reachable commits"
        )

    findings = current_public_tree_findings(root)
    findings.extend(
        public_repository_object_findings(
            root,
            commit,
            commits,
            require_sanitized_root=require_sanitized_root,
        )
    )
    findings.extend(commit_metadata_findings(root, commits))
    findings.extend(history_tree_findings(root, commits))
    if findings:
        fail(
            "source-only publish tree or reachable history violates the public-source policy",
            sorted(set(findings)),
        )
    return commit


def verify_binary_release_source(
    root: Path,
    *,
    expected_commit: str | None,
    require_read_only: bool,
) -> str:
    if require_read_only:
        try:
            flags = os.statvfs(root).f_flag
        except OSError as error:
            fail(f"cannot inspect release snapshot mount flags: {error}")
        if not flags & os.ST_RDONLY:
            fail("release source is not on an OS-enforced read-only filesystem")
    commit = git(root, "rev-parse", "--verify", "HEAD^{commit}").decode().strip()
    if expected_commit and commit != expected_commit:
        fail(f"HEAD changed during release gate: {expected_commit} -> {commit}")

    private_inputs = tracked_private_inputs(root)
    if private_inputs:
        fail(
            "local-only/private inputs are tracked and must be removed from the release commit",
            private_inputs,
        )

    unstaged = subprocess.run(
        ["git", "-C", str(root), "diff", "--quiet", "--ignore-submodules", "--"],
        check=False,
    ).returncode
    if unstaged != 0:
        fail("final mode requires a clean tracked tree (unstaged changes or git error)")
    staged = subprocess.run(
        ["git", "-C", str(root), "diff", "--cached", "--quiet", "--ignore-submodules", "--"],
        check=False,
    ).returncode
    if staged != 0:
        fail("final mode requires a clean tracked tree (staged changes or git error)")

    nonregular = tracked_nonregular_inputs(root)
    if nonregular:
        fail(
            "tracked release inputs must be regular Git files; symlinks/gitlinks are forbidden",
            nonregular,
        )

    untracked = decode_paths(
        git(root, "ls-files", "--others", "--exclude-standard", "-z", "--", *RELEASE_PATHS)
    )
    if untracked:
        fail("untracked release-impacting inputs must be committed locally", sorted(untracked))

    ignored = decode_paths(
        git(
            root,
            "ls-files",
            "--others",
            "--ignored",
            "--exclude-standard",
            "-z",
            "--",
            *RELEASE_PATHS,
        )
    )
    oracle_allowlist = official_oracle_allowlist(root)
    disallowed_ignored = sorted(
        path for path in ignored if not allowed_ignored_input(root, path, oracle_allowlist)
    )
    if disallowed_ignored:
        fail(
            "ignored release-impacting inputs are forbidden outside the exact build/oracle allowlist",
            disallowed_ignored,
        )
    return commit


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--expected-commit")
    parser.add_argument("--require-read-only", action="store_true")
    parser.add_argument(
        "--source-only",
        action="store_true",
        help="verify the complete publish tree and every commit reachable from HEAD",
    )
    parser.add_argument(
        "--require-sanitized-root",
        action="store_true",
        help="require the source-only candidate to contain exactly one root commit",
    )
    args = parser.parse_args()

    if args.require_sanitized_root and not args.source_only:
        parser.error("--require-sanitized-root requires --source-only")
    if args.source_only and args.require_read_only:
        parser.error("--require-read-only is reserved for the binary release snapshot")

    root = args.root.resolve(strict=True)
    git_root = Path(git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    if git_root != root:
        fail(f"unexpected Git root: {git_root}")

    if args.source_only:
        commit = verify_source_only(
            root,
            require_sanitized_root=args.require_sanitized_root,
        )
        if args.expected_commit and commit != args.expected_commit:
            fail(f"HEAD changed during source release gate: {args.expected_commit} -> {commit}")
    else:
        commit = verify_binary_release_source(
            root,
            expected_commit=args.expected_commit,
            require_read_only=args.require_read_only,
        )
    print(commit)


if __name__ == "__main__":
    main()
