#!/bin/bash
# Verify a source-only public Git candidate. This never builds or publishes an app and requires no
# Apple signing identity, Developer Program membership, or notarization profile.
set -euo pipefail

die() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

ROOT="$(cd "$(/usr/bin/dirname "$0")/.." && /bin/pwd -P)"
[ "$#" -eq 0 ] || die "source release gate accepts no arguments"
for tool in git python3 bash; do
    require_command "$tool"
done

VERSION_FILE="$ROOT/app/Twisterminigen/Sources/Twisterminigen/App/AppVersion.swift"
HELP_FILE="$ROOT/app/Twisterminigen/Sources/Twisterminigen/Views/Help/HelpView.swift"
RELEASING_FILE="$ROOT/RELEASING.md"
APP_VERSION="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' "$VERSION_FILE")"
APP_BUILD="$(sed -n 's/.*static let build = "\([0-9]*\)".*/\1/p' "$VERSION_FILE")"
printf '%s\n' "$APP_VERSION" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    || die "AppVersion.current must be a public dotted numeric version"
printf '%s\n' "$APP_BUILD" | grep -Eq '^[1-9][0-9]*$' \
    || die "AppVersion.build must be a positive canonical integer"
[ "$(grep -Fxc "git tag \"v$APP_VERSION\" HEAD" "$RELEASING_FILE")" -eq 1 ] \
    || die "RELEASING.md tag does not match AppVersion.current"
[ "$(grep -Fxc "git push origin \"v$APP_VERSION\"" "$RELEASING_FILE")" -eq 1 ] \
    || die "RELEASING.md tag push does not match AppVersion.current"
[ "$(grep -Fxc "            title: \"What's new in $APP_VERSION\"," "$HELP_FILE")" -eq 1 ] \
    || die "Help release title does not match AppVersion.current"
echo "✓ public version verified: $APP_VERSION (build $APP_BUILD)"

SOURCE_RELEASE_HISTORY="${SOURCE_RELEASE_HISTORY:-sanitized-root}"
case "$SOURCE_RELEASE_HISTORY" in
    sanitized-root)
        SOURCE_HISTORY_ARGUMENTS=(--require-sanitized-root)
        ;;
    reviewed-public)
        SOURCE_HISTORY_ARGUMENTS=()
        ;;
    *)
        die "SOURCE_RELEASE_HISTORY must be sanitized-root or reviewed-public"
        ;;
esac

echo "▸ Public-source tree/history adversarial fixtures"
python3 "$ROOT/tools/release_source_state_self_test.py"
echo "▸ Public-source exporter adversarial fixtures"
python3 "$ROOT/tools/export_public_source_self_test.py"
echo "▸ Complete publish-tree privacy scanner adversarial fixtures"
python3 "$ROOT/tools/privacy_scan_self_test.py"
echo "▸ Source-release tool syntax"
bash -n "$ROOT/tools/privacy_scan.sh"
bash -n "$ROOT/tools/source_release_gate.sh"
python3 - \
    "$ROOT/tools/export_public_source.py" \
    "$ROOT/tools/export_public_source_self_test.py" \
    "$ROOT/tools/privacy_scan_self_test.py" \
    "$ROOT/tools/release_source_state_self_test.py" \
    "$ROOT/tools/verify_release_source_state.py" <<'PY'
from pathlib import Path
import sys

for argument in sys.argv[1:]:
    path = Path(argument)
    compile(path.read_bytes(), str(path), "exec")
PY

SOURCE_RELEASE_COMMIT="$(python3 "$ROOT/tools/verify_release_source_state.py" \
    --root "$ROOT" --source-only "${SOURCE_HISTORY_ARGUMENTS[@]}")"
PRIVACY_SCAN_PUBLIC_CANDIDATE=1 "$ROOT/tools/privacy_scan.sh"
git -C "$ROOT" diff --check HEAD --

echo "✓ source-only release gate passed"
echo "  source commit: $SOURCE_RELEASE_COMMIT"
echo "  history mode: $SOURCE_RELEASE_HISTORY"
echo "  no app bundle, signing, notarization, GitHub commit, tag, push, or release was performed"
