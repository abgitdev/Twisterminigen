#!/bin/bash
# Fail a release when source or the staged app leaks a workstation path, a credential signature,
# or violates the declared no-tracking/no-collected-data privacy policy.
set -euo pipefail

die() {
    echo "error: $*" >&2
    exit 1
}

require_path() {
    [ -e "$1" ] || die "required privacy scan input not found: $1"
}

TOOL_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ROOT="$TOOL_ROOT"
PRE_SIGN=0
POST_NOTARY=0
PUBLIC_SOURCE_CANDIDATE="${PRIVACY_SCAN_PUBLIC_CANDIDATE:-0}"
case "$PUBLIC_SOURCE_CANDIDATE" in
    0|1) ;;
    *) die "PRIVACY_SCAN_PUBLIC_CANDIDATE must be 0 or 1" ;;
esac
if [ "${1:-}" = "--self-test-source-root" ]; then
    [ "${PRIVACY_SCAN_SELF_TEST:-0}" = "1" ] \
        || die "--self-test-source-root is reserved for tools/privacy_scan_self_test.py"
    [ -n "${2:-}" ] || die "self-test source root is missing"
    ROOT="$(cd "$2" && pwd -P)"
    shift 2
fi
if [ "${1:-}" = "--pre-sign" ]; then
    PRE_SIGN=1
    shift
elif [ "${1:-}" = "--post-notary" ]; then
    POST_NOTARY=1
    shift
fi
APP_INPUT="${1:-}"

local_path_pattern="/""Users/[A-Za-z0-9._-]+"
secret_pattern='BEGIN [A-Z ]*PRIVATE KEY|(AKIA|ASIA)[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk_(live|test)_[A-Za-z0-9]{16,}|sk-(proj|svcacct)-[A-Za-z0-9_-]{16,}|hf_[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{20,}|xox[baprs]-[A-Za-z0-9-]{16,}'

for tool in git plutil shasum awk grep codesign find strings python3 mktemp; do
    command -v "$tool" >/dev/null 2>&1 || die "required command not found: $tool"
done

SOURCE_PATHS=(
    "$ROOT/app"
    "$ROOT/engine"
    "$ROOT/tools"
    "$ROOT/NOTICE"
    "$ROOT/PRIVACY.md"
    "$ROOT/CONTENT_SAFETY.md"
    "$ROOT/THIRD_PARTY_LICENSES.md"
)
for source_path in "${SOURCE_PATHS[@]}"; do
    require_path "$source_path"
done

SOURCE_FILE_LIST=""
FILE_LIST=""
STRINGS_FILE=""
cleanup() {
    [ -z "$SOURCE_FILE_LIST" ] || rm -f -- "$SOURCE_FILE_LIST"
    [ -z "$FILE_LIST" ] || rm -f -- "$FILE_LIST"
    [ -z "$STRINGS_FILE" ] || rm -f -- "$STRINGS_FILE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SOURCE_FILE_LIST="$(mktemp "${TMPDIR:-/tmp}/twisterminigen-source-files.XXXXXX")"
if [ "${PRIVACY_SCAN_SELF_TEST:-0}" = "1" ]; then
    (
        cd "$ROOT"
        find app engine tools NOTICE PRIVACY.md CONTENT_SAFETY.md THIRD_PARTY_LICENSES.md \
            \( -type f -o -type l \) -print0
    ) > "$SOURCE_FILE_LIST" || die "self-test source privacy scan could not enumerate files"
else
    git -C "$ROOT" ls-files --cached --others --exclude-standard -z > "$SOURCE_FILE_LIST" \
        || die "source privacy scan could not enumerate the complete publish candidate"
fi

python3 -I - "$ROOT" "$TOOL_ROOT/tools/verify_release_source_state.py" \
    "$SOURCE_FILE_LIST" "$PUBLIC_SOURCE_CANDIDATE" \
    "${PRIVACY_SCAN_SELF_TEST:-0}" <<'PY'
from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
policy_path = Path(sys.argv[2]).resolve()
list_path = Path(sys.argv[3])
public_candidate = sys.argv[4] == "1"
self_test = sys.argv[5] == "1"
spec = importlib.util.spec_from_file_location("twister_release_source_policy", policy_path)
if spec is None or spec.loader is None:
    raise SystemExit(f"error: cannot load public-source policy: {policy_path}")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

errors: list[str] = []
raw_names = [value for value in list_path.read_bytes().split(b"\0") if value]
for raw_name in raw_names:
    name = os.fsdecode(raw_name)
    if not public_candidate and not self_test:
        in_public_directory = any(
            name.startswith(f"{directory}/")
            for directory in policy.PUBLIC_DIRECTORY_SUFFIXES
        )
        if name not in policy.PUBLIC_EXACT_FILES and not in_public_directory:
            continue
    reason = policy.public_path_reason(
        name,
        require_allowlisted=public_candidate or not self_test,
    )
    if reason:
        errors.append(f"{reason}: {name}")
    errors.extend(
        f"{finding} in publishable path: {name}"
        for finding in policy.public_path_privacy_findings(name)
    )
    path = root / name
    if path.is_symlink():
        errors.append(f"symbolic link is not publishable: {name}")
        continue
    if not path.exists():
        errors.append(f"publish candidate is missing from the worktree: {name}")
        continue
    if not path.is_file():
        errors.append(f"publish candidate is not a regular file: {name}")
        continue
    try:
        size = path.stat().st_size
        if size > policy.MAX_PUBLIC_FILE_BYTES:
            errors.append(
                f"public-source file exceeds {policy.MAX_PUBLIC_FILE_BYTES} bytes: "
                f"{name} ({size})"
            )
            continue
        data = path.read_bytes()
    except OSError as error:
        errors.append(f"cannot read publish candidate {name}: {error}")
        continue
    errors.extend(
        f"{finding}: {name}"
        for finding in policy.privacy_findings_for_path(name, data)
    )

if errors:
    print("error: public-source privacy scan failed", file=sys.stderr)
    for error in sorted(set(errors)):
        print(f"  - {error}", file=sys.stderr)
    raise SystemExit(1)
label = "complete publish-tree" if public_candidate or self_test else "public release-input"
print(f"✓ {label} privacy scan passed ({len(raw_names)} enumerated files)")
PY

SOURCE_PRIVACY_MANIFEST="$ROOT/app/Twisterminigen/Sources/Twisterminigen/Resources/PrivacyInfo.xcprivacy"
require_path "$SOURCE_PRIVACY_MANIFEST"
python3 "$TOOL_ROOT/tools/validate_privacy_manifests.py" \
    --root-manifest "$SOURCE_PRIVACY_MANIFEST" \
    --search-root "$ROOT/app/Twisterminigen/Sources"

if [ -z "$APP_INPUT" ]; then
    echo "✓ source privacy scan passed"
    exit 0
fi

[ -d "$APP_INPUT" ] || die "app bundle not found: $APP_INPUT"
[ ! -L "$APP_INPUT" ] || die "app bundle must not be a symbolic link"
APP_PARENT="$(cd "$(dirname "$APP_INPUT")" && pwd -P)"
APP="$APP_PARENT/$(basename "$APP_INPUT")"
RESOURCES="$APP/Contents/Resources"
python3 "$TOOL_ROOT/tools/reject_symlinks.py" "$APP"

for required in NOTICE KREA-2-COMMUNITY-LICENSE.txt THIRD_PARTY_LICENSES.md PRIVACY.md \
    PrivacyInfo.xcprivacy CONTENT_SAFETY.md Licenses/ThirdParty/INDEX.md; do
    [ -s "$RESOURCES/$required" ] || die "missing release resource: $required"
done

# Incremental/local bundles predate the receipt and remain supported. A final bundle advertises
# itself by including ReleaseReceipt.json; once present, it is mandatory and fully verified.
if [ -e "$RESOURCES/ReleaseReceipt.json" ]; then
    if [ "$PRE_SIGN" -eq 1 ]; then
        "$TOOL_ROOT/tools/verify_release_receipt.sh" "$APP" --pre-sign
    elif [ "$POST_NOTARY" -eq 1 ]; then
        "$TOOL_ROOT/tools/verify_release_receipt.sh" "$APP" --post-notary
    else
        "$TOOL_ROOT/tools/verify_release_receipt.sh" "$APP"
    fi
fi

grep -Fqx \
    'Krea 2 is licensed under the Krea 2 Community License Agreement. For more information, visit https://krea.ai/krea-2-licensing.' \
    "$RESOURCES/NOTICE" || die "Krea Notice is not exact"
[ "$(shasum -a 256 "$RESOURCES/KREA-2-COMMUNITY-LICENSE.txt" | awk '{print $1}')" = \
    "7cd975008d1b944452d1fca9e9a6099e5cd4c46d36fdc283c7691da9307fc29e" ] \
    || die "bundled Krea agreement hash mismatch"

python3 "$TOOL_ROOT/tools/validate_privacy_manifests.py" \
    --root-manifest "$RESOURCES/PrivacyInfo.xcprivacy" \
    --search-root "$APP"

FILE_LIST="$(mktemp "${TMPDIR:-/tmp}/twisterminigen-privacy-files.XXXXXX")"
STRINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/twisterminigen-privacy-strings.XXXXXX")"
find "$APP" -type f -print0 > "$FILE_LIST" \
    || die "bundle privacy scan could not enumerate every file"

BUNDLE_MATCHES=()
while IFS= read -r -d '' bundle_file; do
    set +e
    strings -a "$bundle_file" > "$STRINGS_FILE"
    STRINGS_STATUS=$?
    set -e
    [ "$STRINGS_STATUS" -eq 0 ] \
        || die "strings failed for bundle file: $bundle_file (exit $STRINGS_STATUS)"

    set +e
    grep -Eq -- "$local_path_pattern|$secret_pattern" "$STRINGS_FILE"
    STRING_SCAN_STATUS=$?
    set -e
    case "$STRING_SCAN_STATUS" in
        0) BUNDLE_MATCHES+=("$bundle_file") ;;
        1) ;;
        *) die "bundle string scan failed for $bundle_file (grep=$STRING_SCAN_STATUS)" ;;
    esac
done < "$FILE_LIST"

[ "${#BUNDLE_MATCHES[@]}" -eq 0 ] || {
    printf '%s\n' "${BUNDLE_MATCHES[@]}" >&2
    die "bundle privacy scan found a local path or credential signature"
}

if [ "$PRE_SIGN" -eq 1 ]; then
    echo "✓ source + unsigned bundle privacy scan passed: $APP"
elif [ "$POST_NOTARY" -eq 1 ]; then
    codesign --verify --deep --strict --verbose=2 "$APP"
    echo "✓ source + notarized bundle privacy scan passed: $APP"
else
    codesign --verify --deep --strict --verbose=2 "$APP"
    echo "✓ source + bundle privacy scan passed: $APP"
fi
