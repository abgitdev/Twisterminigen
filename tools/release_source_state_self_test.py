#!/usr/bin/env python3
"""Adversarial fixtures for the source-only Git tree, metadata, refs, and object policy."""

from __future__ import annotations

import base64
import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path


PUBLIC_NAME = "abgitdev"
PUBLIC_EMAIL = "266600699+abgitdev@users.noreply.github.com"


def run(
    command: list[str],
    *,
    cwd: Path,
    expect_success: bool = True,
    input_text: str | None = None,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=cwd,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
        env=environment,
    )
    if (result.returncode == 0) != expect_success:
        print(result.stdout, file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        raise SystemExit(
            f"source-state self-test command had unexpected status: {' '.join(command)}"
        )
    return result


def load_policy(verifier: Path):
    spec = importlib.util.spec_from_file_location("twister_source_state_policy", verifier)
    if spec is None or spec.loader is None:
        raise SystemExit("cannot load source-state policy")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def safe_fixture_bytes(relative: str) -> bytes:
    suffix = Path(relative).suffix.casefold()
    if relative == ".gitignore":
        return (
            b"*.log\n"
            + b"**/."
            + b"co"
            + b"dex/\n"
            + b"**/."
            + b"cl"
            + b"aude/\n"
        )
    if suffix in {".json", ".xcprivacy"}:
        return b"{}\n"
    if suffix in {".py", ".sh"}:
        return b"#!/bin/sh\n# public fixture\n"
    return b"public fixture\n"


def write_public_tree(root: Path, policy) -> None:
    for relative in sorted(policy.PUBLIC_EXACT_FILES):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(safe_fixture_bytes(relative))
    directory_files = {
        "app/icon/AppIcon.png": b"PNG fixture\n",
        "app/Twisterminigen/Sources/App.swift": b"let publicValue = 1\n",
        "app/Twisterminigen/Tests/AppTests.swift": b"let testValue = 1\n",
        "engine/Krea2Engine/Sources/Engine.swift": b"let engineValue = 1\n",
        "engine/Krea2Engine/Tests/EngineTests.swift": b"let engineTestValue = 1\n",
    }
    for relative, content in directory_files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)


def initialize(root: Path, policy, *, safe_identity: bool = True) -> None:
    run(["git", "init", "-q", "--template=", "-b", "main"], cwd=root)
    run(
        ["git", "config", "user.name", PUBLIC_NAME if safe_identity else "Local Developer"],
        cwd=root,
    )
    private_email = "developer" + "@workstation.invalid"
    run(
        [
            "git",
            "config",
            "user.email",
            PUBLIC_EMAIL if safe_identity else private_email,
        ],
        cwd=root,
    )
    run(["git", "config", "commit.gpgsign", "false"], cwd=root)
    run(["git", "config", "tag.gpgsign", "false"], cwd=root)
    write_public_tree(root, policy)


def commit_all(root: Path, message: str = "Initial public source release") -> None:
    run(["git", "add", "-A"], cwd=root)
    run(
        ["git", "commit", "-q", "--no-gpg-sign", "-m", message],
        cwd=root,
        environment=utc_git_environment(),
    )


def utc_git_environment() -> dict[str, str]:
    environment = dict(os.environ)
    environment["GIT_AUTHOR_DATE"] = "2001-01-01T00:00:00+0000"
    environment["GIT_COMMITTER_DATE"] = "2001-01-01T00:00:00+0000"
    return environment


def verify(
    verifier: Path,
    root: Path,
    *,
    sanitized_root: bool,
    expect_success: bool,
) -> subprocess.CompletedProcess[str]:
    command = [
        sys.executable,
        str(verifier),
        "--root",
        str(root),
        "--source-only",
    ]
    if sanitized_root:
        command.append("--require-sanitized-root")
    return run(command, cwd=root, expect_success=expect_success)


def fixture_root(parent: Path, name: str) -> Path:
    root = parent / name
    root.mkdir()
    return root


def committed_fixture(parent: Path, name: str, policy) -> Path:
    root = fixture_root(parent, name)
    initialize(root, policy)
    return root


def expect_failure_contains(
    verifier: Path,
    root: Path,
    marker: str,
    *,
    sanitized_root: bool = True,
) -> None:
    result = verify(
        verifier,
        root,
        sanitized_root=sanitized_root,
        expect_success=False,
    )
    if marker not in result.stderr:
        print(result.stderr, file=sys.stderr)
        raise SystemExit(
            f"source-state self-test did not distinguish expected finding: {marker}"
        )


def main() -> None:
    repository = Path(__file__).resolve().parent.parent
    verifier = repository / "tools/verify_release_source_state.py"
    policy = load_policy(verifier)
    with tempfile.TemporaryDirectory(prefix="twister-source-state-self-test-") as temporary:
        parent = Path(temporary)

        clean = committed_fixture(parent, "clean", policy)
        commit_all(clean)
        verify(verifier, clean, sanitized_root=True, expect_success=True)

        hidden_ref = "refs/" + "co" + "dex/private-state"
        run(["git", "update-ref", hidden_ref, "HEAD"], cwd=clean)
        expect_failure_contains(verifier, clean, "non-public local Git ref")
        run(["git", "update-ref", "-d", hidden_ref], cwd=clean)
        verify(verifier, clean, sanitized_root=True, expect_success=True)

        ignored_state = clean / (".co" + "dex/session.jsonl")
        ignored_state.parent.mkdir()
        ignored_state.write_text('{"kind":"ignored fixture"}\n', encoding="utf-8")
        verify(verifier, clean, sanitized_root=True, expect_success=True)
        ignored_state.unlink()
        ignored_state.parent.rmdir()
        (clean / "untracked-public.txt").write_text("not committed\n", encoding="utf-8")
        expect_failure_contains(verifier, clean, "clean tree")

        identity = committed_fixture(parent, "identity", policy)
        run(["git", "config", "user.name", "Local Developer"], cwd=identity)
        run(
            ["git", "config", "user.email", "developer" + "@workstation.invalid"],
            cwd=identity,
        )
        commit_all(identity)
        expect_failure_contains(verifier, identity, "non-public author identity")

        timezone = committed_fixture(parent, "local-timezone", policy)
        run(["git", "add", "-A"], cwd=timezone)
        local_time_environment = utc_git_environment()
        local_time_environment["GIT_AUTHOR_DATE"] = "2001-01-01T08:00:00+0800"
        local_time_environment["GIT_COMMITTER_DATE"] = "2001-01-01T08:00:00+0800"
        run(
            [
                "git",
                "commit",
                "-q",
                "--no-gpg-sign",
                "-m",
                "Initial public source release",
            ],
            cwd=timezone,
            environment=local_time_environment,
        )
        expect_failure_contains(verifier, timezone, "timestamp must use UTC")

        local_tokens = policy.local_machine_identity_tokens()
        if not local_tokens:
            raise SystemExit("source-state self-test cannot derive a local identity token")
        bare_identity = committed_fixture(parent, "bare-local-identity", policy)
        (bare_identity / "app/Twisterminigen/Sources/App.swift").write_bytes(
            b'let workstationName = "' + local_tokens[0] + b'"\n'
        )
        commit_all(bare_identity)
        expect_failure_contains(
            verifier,
            bare_identity,
            "local machine username/hostname token",
        )

        bad_paths = [
            "Sources/chat-" + "history.txt",
            "." + "cl" + "aude.json",
            "." + "co" + "dex.json",
            "audit.json",
            "audit-report.txt",
            "tools/audit-results.json",
            "tools/UI_SMOKE_RECEIPT.md",
            "docs/private.txt",
            "app/docs/session.json",
            "history.json",
            "co" + "dex-session.txt",
        ]
        for index, relative in enumerate(bad_paths):
            root = committed_fixture(parent, f"bad-path-{index}", policy)
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("forbidden fixture\n", encoding="utf-8")
            run(["git", "add", "-A"], cwd=root)
            run(["git", "add", "-f", "--", relative], cwd=root)
            run(
                ["git", "commit", "-q", "--no-gpg-sign", "-m", "Initial public source release"],
                cwd=root,
                environment=utc_git_environment(),
            )
            expect_failure_contains(verifier, root, relative)

        content_cases = [
            (
                "assistant-name",
                ("Conversation with " + "Co" + "dex\n").encode(),
                "AI assistant/session marker",
            ),
            (
                "structured-dialogue",
                (
                    '{"ro' + 'le":"us' + 'er","content":"hello"}\n'
                    '{"ro' + 'le":"assi' + 'stant","content":"reply"}\n'
                ).encode(),
                "structured user/assistant conversation",
            ),
            (
                "headed-dialogue",
                (
                    "## Us" + "er\nrequest\n## Assi" + "stant\nreply\n"
                ).encode(),
                "headed user/assistant conversation",
            ),
            (
                "audit-text",
                ("Release audit " + "report\n").encode(),
                "audit artifact marker",
            ),
            (
                "raw-volume",
                ("/Vol" + "umes/OwnerPrivate/project\n").encode(),
                "developer-local absolute path",
            ),
            (
                "terminal-local-path",
                ("/" + "Users/local-owner\n").encode(),
                "developer-local absolute path",
            ),
            (
                "user-temp-path",
                ("/private/var/fol" + "ders/ab/private\n").encode(),
                "developer-local absolute path",
            ),
            (
                "network-mount-path",
                ("sm" + "b://owner-nas/PrivateShare\n").encode(),
                "developer-local absolute path",
            ),
            (
                "base64-local-path",
                base64.b64encode(("/" + "Users/local-owner/private").encode()) + b"\n",
                "base64-encoded developer-local absolute path",
            ),
            (
                "base64-assistant-dialogue",
                base64.b64encode(
                    ("Co" + "dex trans" + "cript export").encode()
                )
                + b"\n",
                "base64-encoded AI assistant/session marker",
            ),
            (
                "hex-local-path",
                ("/" + "Users/local-owner/private").encode().hex().encode() + b"\n",
                "hex-encoded developer-local absolute path",
            ),
            (
                "disguised-gzip",
                b"\x1f\x8b\x08\x00compressed fixture",
                "gzip compressed/archive container",
            ),
        ]
        for label, payload, marker in content_cases:
            root = committed_fixture(parent, label, policy)
            leak = root / "app/Twisterminigen/Sources/Leak.swift"
            leak.write_bytes(payload)
            commit_all(root)
            expect_failure_contains(verifier, root, marker)

        dat_file = committed_fixture(parent, "dat-suffix", policy)
        payload = dat_file / "app/Twisterminigen/Sources/payload.dat"
        payload.write_bytes(b"opaque fixture\n")
        commit_all(dat_file)
        expect_failure_contains(verifier, dat_file, "artifact suffix")

        policy_leak = committed_fixture(parent, "policy-leak", policy)
        encoded_private_path = base64.b64encode(
            ("/" + "Users/policy-owner/private").encode()
        ).decode()
        (policy_leak / "tools/verify_release_source_state.py").write_text(
            "# public policy fixture\n" + encoded_private_path + "\n",
            encoding="utf-8",
        )
        commit_all(policy_leak)
        expect_failure_contains(
            verifier,
            policy_leak,
            "base64-encoded developer-local absolute path",
        )

        history = committed_fixture(parent, "history", policy)
        local_path = "/" + "Users/local-owner/private/model"
        (history / "app/Twisterminigen/Sources/App.swift").write_text(
            f'let path = "{local_path}"\n', encoding="utf-8"
        )
        commit_all(history)
        (history / "app/Twisterminigen/Sources/App.swift").write_text(
            "let publicValue = 2\n", encoding="utf-8"
        )
        commit_all(history, "Public source update")
        expect_failure_contains(
            verifier,
            history,
            "developer-local absolute path",
            sanitized_root=False,
        )

        multi_commit = committed_fixture(parent, "multi-commit", policy)
        commit_all(multi_commit)
        (multi_commit / "app/Twisterminigen/Sources/App.swift").write_text(
            "let publicValue = 2\n", encoding="utf-8"
        )
        commit_all(multi_commit, "Public source update")
        verify(verifier, multi_commit, sanitized_root=False, expect_success=True)
        expect_failure_contains(verifier, multi_commit, "one-commit sanitized root")

        symlink = committed_fixture(parent, "symlink", policy)
        (symlink / "app/Twisterminigen/Sources/PublicLink.swift").symlink_to("App.swift")
        commit_all(symlink)
        expect_failure_contains(verifier, symlink, "symbolic link")

        safe_lightweight_tag = committed_fixture(parent, "lightweight-tag", policy)
        commit_all(safe_lightweight_tag)
        run(["git", "tag", "v0.1.0", "HEAD"], cwd=safe_lightweight_tag)
        verify(verifier, safe_lightweight_tag, sanitized_root=True, expect_success=True)

        bad_tag_identity = committed_fixture(parent, "bad-tag-identity", policy)
        commit_all(bad_tag_identity)
        run(
            [
                "git",
                "-c",
                "user.name=Local Tagger",
                "-c",
                "user.email=tagger" + "@workstation.invalid",
                "tag",
                "-a",
                "--no-sign",
                "v0.1.0",
                "-m",
                "Public source tag",
            ],
            cwd=bad_tag_identity,
            environment=utc_git_environment(),
        )
        expect_failure_contains(verifier, bad_tag_identity, "non-public annotated-tag identity")

        bad_tag_message = committed_fixture(parent, "bad-tag-message", policy)
        commit_all(bad_tag_message)
        run(
            [
                "git",
                "tag",
                "-a",
                "--no-sign",
                "v0.1.0",
                "-m",
                "Co" + "dex trans" + "cript export",
            ],
            cwd=bad_tag_message,
            environment=utc_git_environment(),
        )
        expect_failure_contains(verifier, bad_tag_message, "in annotated tag")

        dangling = committed_fixture(parent, "dangling-object", policy)
        commit_all(dangling)
        run(
            ["git", "hash-object", "-w", "--stdin"],
            cwd=dangling,
            input_text="/" + "Users/dangling-owner/private\n",
        )
        expect_failure_contains(verifier, dangling, "unreachable/dangling Git object")

    print(
        "✓ source-only state self-test passed: exact allowlist + UTC identity/refs/history "
        "fixtures + path/content/base64/hex/local-machine/container/policy/tag/"
        "dangling-object rejection"
    )


if __name__ == "__main__":
    main()
