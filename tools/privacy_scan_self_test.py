#!/usr/bin/env python3
"""Exercise privacy-scan secret and privacy-manifest fixtures without a release build."""

from __future__ import annotations

import base64
import importlib.util
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path


def write_manifest(path: Path, *, tracking: bool = False, domains=None, collected=None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "NSPrivacyTracking": tracking,
        "NSPrivacyTrackingDomains": [] if domains is None else domains,
        "NSPrivacyCollectedDataTypes": [] if collected is None else collected,
    }
    path.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=True))


def main() -> None:
    tool_root = Path(__file__).resolve().parent.parent
    scanner = tool_root / "tools/privacy_scan.sh"
    policy_path = tool_root / "tools/verify_release_source_state.py"
    policy_spec = importlib.util.spec_from_file_location(
        "twister_privacy_self_test_policy",
        policy_path,
    )
    if policy_spec is None or policy_spec.loader is None:
        raise SystemExit("privacy self-test cannot load source policy")
    policy = importlib.util.module_from_spec(policy_spec)
    policy_spec.loader.exec_module(policy)
    with tempfile.TemporaryDirectory(prefix="twisterminigen-privacy-self-test-") as temporary:
        root = Path(temporary)
        (root / "app").mkdir()
        (root / "engine").mkdir()
        (root / "tools").mkdir()
        for name in ("NOTICE", "PRIVACY.md", "CONTENT_SAFETY.md", "THIRD_PARTY_LICENSES.md"):
            (root / name).write_text(f"fixture {name}\n", encoding="utf-8")
        root_manifest = root / "app/Twisterminigen/Sources/Twisterminigen/Resources/PrivacyInfo.xcprivacy"
        write_manifest(root_manifest)

        environment = dict(os.environ)
        environment["PRIVACY_SCAN_SELF_TEST"] = "1"

        def scan(expect_success: bool, label: str) -> subprocess.CompletedProcess[str]:
            result = subprocess.run(
                [str(scanner), "--self-test-source-root", str(root)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=environment,
                check=False,
            )
            if (result.returncode == 0) != expect_success:
                print(result.stdout, file=sys.stderr)
                print(result.stderr, file=sys.stderr)
                raise SystemExit(f"privacy self-test failed: {label}")
            return result

        scan(True, "clean fixture")

        cyrillic_source = root / "app/cyrillic-fixture.swift"
        forbidden_word = "".join(chr(value) for value in (1090, 1077, 1089, 1090))
        cyrillic_source.write_text(
            f'// Public release text must remain English-only.\nlet value = "{forbidden_word}"\n',
            encoding="utf-8",
        )
        scan(False, "Cyrillic public source")
        cyrillic_source.unlink()

        # Bundle mode must reject every symlink, including an ordinary resource link that is not a
        # privacy manifest. The fixture is unsigned and intentionally uses --pre-sign.
        fake_app = root / "Fixture.app"
        resources = fake_app / "Contents/Resources"
        third_party = resources / "Licenses/ThirdParty"
        third_party.mkdir(parents=True)
        exact_notice = (
            "Krea 2 is licensed under the Krea 2 Community License Agreement. "
            "For more information, visit https://krea.ai/krea-2-licensing.\n"
        )
        (resources / "NOTICE").write_text(exact_notice, encoding="utf-8")
        (resources / "KREA-2-COMMUNITY-LICENSE.txt").write_bytes(
            (tool_root / "KREA-2-COMMUNITY-LICENSE.txt").read_bytes()
        )
        for name in ("THIRD_PARTY_LICENSES.md", "PRIVACY.md", "CONTENT_SAFETY.md"):
            (resources / name).write_text(f"fixture {name}\n", encoding="utf-8")
        (third_party / "INDEX.md").write_text("fixture index\n", encoding="utf-8")
        write_manifest(resources / "PrivacyInfo.xcprivacy")
        resource_link = resources / "forbidden-resource-link"
        resource_link.symlink_to(resources / "NOTICE")
        bundle_result = subprocess.run(
            [
                str(scanner),
                "--self-test-source-root",
                str(root),
                "--pre-sign",
                str(fake_app),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
            check=False,
        )
        if (
            bundle_result.returncode == 0
            or "forbidden symbolic link" not in bundle_result.stderr
        ):
            print(bundle_result.stdout, file=sys.stderr)
            print(bundle_result.stderr, file=sys.stderr)
            raise SystemExit("privacy self-test failed: bundle symlink was not rejected")
        resource_link.unlink()

        secret_file = root / "app/secret-fixture.txt"
        secrets = {
            "Stripe live": "sk_" + "live_" + "A" * 24,
            "Stripe test": "sk_" + "test_" + "B" * 24,
            "OpenAI project": "sk-" + "proj-" + "C" * 24,
            "OpenAI service account": "sk-" + "svcacct-" + "D" * 24,
            "Hugging Face": "hf_" + "E" * 24,
            "AWS long-term access key": "AKIA" + "F" * 16,
            "AWS temporary access key": "ASIA" + "H" * 16,
            "Google API key": "AIza" + "G" * 32,
            "GitHub classic PAT": "ghp_" + "J" * 36,
            "GitHub fine-grained PAT": "github_pat_" + "K" * 24,
            "Slack bot token": "xoxb-" + "L" * 24,
            "private key": "-----BEGIN " + "PRIVATE KEY-----",
            "workstation path": "/" + "Users/release-engineer/private",
        }
        for label, secret in secrets.items():
            secret_file.write_text(secret + "\n", encoding="utf-8")
            scan(False, label)
        secret_file.unlink()

        artifact_names = [
            "chat-" + "history.txt",
            "." + "cl" + "aude.json",
            "." + "co" + "dex.json",
            "audit-report.txt",
            "history.json",
            "co" + "dex-session.txt",
        ]
        for index, name in enumerate(artifact_names):
            artifact = root / "app" / name
            artifact.write_text("forbidden artifact fixture\n", encoding="utf-8")
            scan(False, f"AI/history artifact path {index}")
            artifact.unlink()

        semantic_leak = root / "app/semantic-leak.txt"
        semantic_cases = {
            "assistant product marker": "Conversation with " + "Co" + "dex\n",
            "audit artifact text": "Release audit " + "report\n",
            "structured dialogue": (
                '{"ro' + 'le":"us' + 'er","content":"hello"}\n'
                '{"ro' + 'le":"assi' + 'stant","content":"reply"}\n'
            ),
            "headed dialogue": (
                "## Us" + "er\nrequest\n## Assi" + "stant\nreply\n"
            ),
        }
        for label, payload in semantic_cases.items():
            semantic_leak.write_text(payload, encoding="utf-8")
            scan(False, label)
        semantic_leak.unlink()

        encoded_leak = root / "app/encoded-leak.txt"
        encoded_cases = {
            "base64 local path": base64.b64encode(
                ("/" + "Users/local-owner/private").encode()
            ),
            "base64 assistant text": base64.b64encode(
                ("Co" + "dex trans" + "cript export").encode()
            ),
            "hex local path": (
                ("/" + "Users/local-owner/private").encode().hex().encode()
            ),
        }
        for label, payload in encoded_cases.items():
            encoded_leak.write_bytes(payload + b"\n")
            scan(False, label)
        encoded_leak.unlink()

        mounted_path = root / "app/mounted-path.txt"
        mounted_path.write_text(
            "/Vol" + "umes/OwnerPrivate/project\n",
            encoding="utf-8",
        )
        scan(False, "mounted-volume developer path")
        mounted_path.unlink()

        local_path_cases = {
            "terminal home path": "/" + "Users/local-owner\n",
            "per-user temp path": "/private/var/fol" + "ders/ab/private\n",
            "network mount URL": "sm" + "b://owner-nas/PrivateShare\n",
        }
        for label, payload in local_path_cases.items():
            mounted_path.write_text(payload, encoding="utf-8")
            scan(False, label)
        mounted_path.unlink(missing_ok=True)

        disguised_container = root / "app/disguised-container.swift"
        disguised_container.write_bytes(b"\x1f\x8b\x08\x00compressed fixture")
        scan(False, "disguised gzip container")
        disguised_container.unlink()

        opaque_container = root / "app/opaque.dat"
        opaque_container.write_bytes(b"opaque fixture\n")
        scan(False, "opaque container suffix")
        opaque_container.unlink()

        policy_leak = root / "tools/verify_release_source_state.py"
        policy_leak.write_bytes(
            base64.b64encode(("/" + "Users/policy-owner/private").encode()) + b"\n"
        )
        scan(False, "policy file is not content-exempt")
        policy_leak.unlink()

        local_tokens = policy.local_machine_identity_tokens()
        if not local_tokens:
            raise SystemExit("privacy self-test cannot derive a local identity token")
        bare_local_identity = root / "app/bare-local-identity.txt"
        bare_local_identity.write_bytes(local_tokens[0] + b"\n")
        scan(False, "bare local username/hostname")
        bare_local_identity.unlink()

        personal_email = root / "app/personal-email.txt"
        personal_email.write_text("owner" + "@example.com\n", encoding="utf-8")
        scan(False, "personal email")
        personal_email.write_text(
            "opensource" + "@krea.ai\n"
            "266600699+abgitdev" + "@users.noreply.github.com\n",
            encoding="utf-8",
        )
        scan(True, "reviewed public email allowlist")
        personal_email.unlink()

        encoded_path = root / "app/encoded-path.bin"
        encoded_path.write_bytes(
            ("/ho" + "me/release-engineer/private").encode("utf-16-le")
        )
        scan(False, "UTF-16 developer path")
        encoded_path.unlink()

        ai_state = root / ("app/.co" + "dex/session.json")
        ai_state.parent.mkdir()
        ai_state.write_text('{"role":"user","content":"private"}\n', encoding="utf-8")
        scan(False, "AI session-state path")
        ai_state.unlink()
        ai_state.parent.rmdir()

        personal_path = root / ("app/" + "Users/local-owner/private.txt")
        personal_path.parent.mkdir(parents=True)
        personal_path.write_text("private path component\n", encoding="utf-8")
        scan(False, "developer path in filename")
        personal_path.unlink()
        personal_path.parent.rmdir()
        personal_path.parent.parent.rmdir()

        icon_scale = root / ("app/icon_128x128" + "@2x.png")
        icon_scale.write_bytes(b"fixture\n")
        scan(True, "Apple icon scale filename is not an email")
        icon_scale.unlink()

        private_note = root / "app/research/findings.md"
        private_note.parent.mkdir()
        private_note.write_text("private findings\n", encoding="utf-8")
        scan(False, "research workspace path")
        private_note.unlink()
        private_note.parent.rmdir()

        model_weight = root / "app/checkpoint.safetensors"
        model_weight.write_bytes(b"not a real model\n")
        scan(False, "model-weight-shaped file")
        model_weight.unlink()

        write_manifest(root_manifest, tracking=True)
        scan(False, "root tracking=true")
        write_manifest(root_manifest, domains=["tracker.invalid"])
        scan(False, "root tracking domains")
        write_manifest(root_manifest, collected=[{"NSPrivacyCollectedDataType": "Email"}])
        scan(False, "root collected data")
        root_manifest.write_bytes(plistlib.dumps({"NSPrivacyTracking": False}))
        scan(False, "root missing empty policy arrays")
        write_manifest(root_manifest)

        nested = root / "app/Twisterminigen/Sources/Nested.bundle/PrivacyInfo.xcprivacy"
        write_manifest(nested, tracking=True)
        scan(False, "nested tracking=true")
        write_manifest(nested, domains=["tracker.invalid"])
        scan(False, "nested tracking domains")
        write_manifest(nested, collected=[{"NSPrivacyCollectedDataType": "Email"}])
        scan(False, "nested collected data")
        nested.unlink()
        scan(True, "restored clean fixture")

        unreadable = root / "app/unreadable"
        unreadable.mkdir()
        (unreadable / "payload.txt").write_text("clean\n", encoding="utf-8")
        unreadable.chmod(0)
        try:
            read_error = scan(False, "read error must fail closed")
            if not any(
                marker in read_error.stderr
                for marker in (
                    "cannot read publish candidate",
                    "source privacy scan could not enumerate files",
                )
            ):
                raise SystemExit("privacy self-test failed: read error was not distinguished")
        finally:
            unreadable.chmod(0o700)

    source = scanner.read_text(encoding="utf-8")
    for assertion in (
        "ls-files --cached --others --exclude-standard -z",
        "complete publish-tree",
        "policy.public_path_reason",
        "policy.privacy_findings_for_path",
        '[ "$STRINGS_STATUS" -eq 0 ]',
        'case "$STRING_SCAN_STATUS"',
        'strings failed for bundle file',
        'bundle string scan failed',
    ):
        if assertion not in source:
            raise SystemExit(f"privacy scanner error-handling assertion missing: {assertion}")
    print(
        f"✓ privacy scan self-test passed: {len(secrets)} secret/path fixtures + "
        "AI/history/base64/hex/volume/local-identity/container/policy-file rejection + "
        "public-tree/path/email/manifest policy + bundle symlink fixture"
    )


if __name__ == "__main__":
    main()
