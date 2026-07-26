#!/bin/bash

#
#   tools/bundle_app.sh [Debug|Release] [/path/to/Twisterminigen.app]
#   RELEASE_GATE_PHASE=prepare tools/local_release_gate.sh [/path/to/Twisterminigen.app]
#







#


set -euo pipefail

die() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_file() {
    [ -s "$1" ] || die "required file is missing or empty: $1"
}

require_directory() {
    [ -d "$1" ] || die "required directory is missing: $1"
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

hash_file_set() {
    local directory="$1"
    python3 "$ROOT/tools/hash_file_set.py" "$directory"
}

require_tracked_file() {
    local path="$1"
    local relative="${path#"$ROOT"/}"
    git -C "$ROOT" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 \
        || die "final release input is not tracked by Git: $relative"
}

verify_final_source_state() {
    local expected_commit="${1:-}"
    local arguments=(--root "$ROOT")
    if [ -n "$expected_commit" ]; then
        arguments+=(--expected-commit "$expected_commit")
    fi
    if [ "${RELEASE_SNAPSHOT_READ_ONLY:-0}" = "1" ]; then
        arguments+=(--require-read-only)
    fi
    python3 "$ROOT/tools/verify_release_source_state.py" "${arguments[@]}"
}

create_final_release_receipt() {
    local receipt_plist="$STAGING_ROOT/ReleaseReceipt.plist"
    local receipt_json="$STAGING/Contents/Resources/ReleaseReceipt.json"
    local third_party_set_hash unsigned_executable_hash signing_normalized_executable_hash

    third_party_set_hash="$(hash_file_set "$STAGING/Contents/Resources/Licenses/ThirdParty")"
    unsigned_executable_hash="$(sha256_file "$STAGING/Contents/MacOS/Twisterminigen")"
    signing_normalized_executable_hash="$(python3 "$ROOT/tools/signing_normalized_macho.py" \
        "$STAGING/Contents/MacOS/Twisterminigen")"

    plutil -create xml1 "$receipt_plist"
    plutil -insert ReceiptSchemaVersion -integer 1 "$receipt_plist"
    plutil -insert ReleaseMode -string final "$receipt_plist"
    plutil -insert SourceState -string clean-local-commit "$receipt_plist"
    plutil -insert SourceSnapshotPolicy -string \
        "read-only-disk-image-commit-clean-env-v2" "$receipt_plist"
    plutil -insert SourceSnapshotCommit -string \
        "$RELEASE_SNAPSHOT_COMMIT" "$receipt_plist"
    plutil -insert BuildEnvironmentPolicy -string \
        "env-i-explicit-allowlist-v1" "$receipt_plist"
    plutil -insert PackageResolutionPolicy -string only-Package.resolved "$receipt_plist"
    plutil -insert GitCommit -string "$FINAL_COMMIT" "$receipt_plist"
    plutil -insert SourceDateEpoch -string "$SOURCE_DATE_EPOCH" "$receipt_plist"
    plutil -insert AppVersion -string "$VERSION" "$receipt_plist"
    plutil -insert AppBuild -string "$BUILD" "$receipt_plist"
    plutil -insert BuildConfiguration -string "$CONFIG" "$receipt_plist"
    plutil -insert XcodeVersion -string "$XCODE_VERSION" "$receipt_plist"
    plutil -insert MacOSProductVersion -string "$MACOS_PRODUCT_VERSION" "$receipt_plist"
    plutil -insert MacOSBuildVersion -string "$MACOS_BUILD_VERSION" "$receipt_plist"
    plutil -insert AppPackageResolvedSHA256 -string \
        "$(sha256_file "$APP_PACKAGE_RESOLVED")" "$receipt_plist"
    plutil -insert EnginePackageResolvedSHA256 -string \
        "$(sha256_file "$ENGINE_PACKAGE_RESOLVED")" "$receipt_plist"
    plutil -insert ResolvedCheckoutInventorySHA256 -string \
        "$(sha256_file "$FINAL_CHECKOUT_INVENTORY")" "$receipt_plist"
    plutil -insert ResolvedCheckoutPolicy -string \
        "all-pins-head-match-clean-no-extras" "$receipt_plist"
    plutil -insert RuntimePayloadPolicy -string \
        "complete-normalized-runtime-inventory-with-modes-v2" "$receipt_plist"
    plutil -insert RuntimePayloadInventorySHA256 -string \
        "$(sha256_file "$RUNTIME_PAYLOAD_INVENTORY")" "$receipt_plist"
    plutil -insert EntitlementsPolicy -string \
        "tracked-default-release-entitlements-v1" "$receipt_plist"
    plutil -insert EntitlementsSHA256 -string \
        "$(sha256_file "$ENTITLEMENTS_SOURCE")" "$receipt_plist"
    plutil -insert NoticeSHA256 -string "$(sha256_file "$NOTICE_SOURCE")" "$receipt_plist"
    plutil -insert KreaLicenseSHA256 -string \
        "$(sha256_file "$KREA_LICENSE_SOURCE")" "$receipt_plist"
    plutil -insert ThirdPartyLicensesIndexSHA256 -string \
        "$(sha256_file "$THIRD_PARTY_SOURCE")" "$receipt_plist"
    plutil -insert BundledThirdPartyLicenseSetSHA256 -string \
        "$third_party_set_hash" "$receipt_plist"
    plutil -insert PrivacyNoticeSHA256 -string \
        "$(sha256_file "$PRIVACY_NOTICE_SOURCE")" "$receipt_plist"
    plutil -insert ContentSafetySHA256 -string \
        "$(sha256_file "$CONTENT_SAFETY_SOURCE")" "$receipt_plist"
    plutil -insert PrivacyManifestSHA256 -string \
        "$(sha256_file "$PRIVACY_MANIFEST_SOURCE")" "$receipt_plist"
    plutil -insert ReleaseComplianceSourceSHA256 -string \
        "$(sha256_file "$RELEASE_COMPLIANCE_SOURCE")" "$receipt_plist"
    plutil -insert OutputReviewGateSourceSHA256 -string \
        "$(sha256_file "$OUTPUT_REVIEW_GATE_SOURCE")" "$receipt_plist"
    plutil -insert MLXDefaultMetallibSHA256 -string \
        "$(sha256_file "$STAGING/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")" \
        "$receipt_plist"
    plutil -insert UnsignedExecutableSHA256 -string "$unsigned_executable_hash" "$receipt_plist"
    plutil -insert UnsignedExecutableHashScope -string \
        "Contents/MacOS/Twisterminigen after strip, before codesign" "$receipt_plist"
    plutil -insert SigningNormalizedExecutableSHA256 -string \
        "$signing_normalized_executable_hash" "$receipt_plist"
    plutil -insert SigningNormalizedExecutableHashScope -string \
        "Mach-O code bytes with LC_CODE_SIGNATURE and signing-dependent __LINKEDIT fields normalized, recomputed pre/post sign" \
        "$receipt_plist"
    plutil -convert json -o "$receipt_json" "$receipt_plist"
    chmod 644 "$receipt_json"
    require_file "$receipt_json"
    python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$receipt_json" \
        || die "failed to create a valid ReleaseReceipt.json"
}

read_build_number() {
    sed -n 's/.*static let build = "\([0-9]*\)".*/\1/p' "$VERSION_FILE"
}

replace_build_number() {
    local from="$1"
    local to="$2"
    local matches
    matches="$(sed -n "s/.*static let build = \"$from\".*/match/p" "$VERSION_FILE" | wc -l | tr -d ' ')"
    [ "$matches" = "1" ] || die "expected one build line $from in AppVersion.swift, found: $matches"
    sed -i '' "s/static let build = \"$from\"/static let build = \"$to\"/" "$VERSION_FILE"
    VERSION_DIRTY=1
    [ "$(read_build_number)" = "$to" ] || die "could not write build $to in AppVersion.swift"
}

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APPROOT="$ROOT/app/Twisterminigen"
VERSION_FILE="$APPROOT/Sources/Twisterminigen/App/AppVersion.swift"
APP_PACKAGE_RESOLVED="$APPROOT/Package.resolved"
ENGINE_PACKAGE_RESOLVED="$ROOT/engine/Krea2Engine/Package.resolved"
NOTICE_SOURCE="$ROOT/NOTICE"
KREA_LICENSE_SOURCE="$ROOT/KREA-2-COMMUNITY-LICENSE.txt"
THIRD_PARTY_SOURCE="$ROOT/THIRD_PARTY_LICENSES.md"
PRIVACY_NOTICE_SOURCE="$ROOT/PRIVACY.md"
CONTENT_SAFETY_SOURCE="$ROOT/CONTENT_SAFETY.md"
PRIVACY_MANIFEST_SOURCE="$APPROOT/Sources/Twisterminigen/Resources/PrivacyInfo.xcprivacy"
RELEASE_COMPLIANCE_SOURCE="$APPROOT/Sources/Twisterminigen/Models/KreaReleaseCompliance.swift"
OUTPUT_REVIEW_GATE_SOURCE="$APPROOT/Sources/Twisterminigen/Services/OutputReviewGate.swift"
DEFAULT_ENTITLEMENTS_SOURCE="$APPROOT/Release.entitlements"
RUNTIME_PRODUCTS_ALLOWLIST="$ROOT/tools/release_runtime_products.json"
EXCLUSIVE_RENAME_SOURCE="$ROOT/tools/exclusive_rename.c"
MODE="${BUNDLE_MODE:-incremental}"
if [ "${1:-}" = "--final" ]; then
    MODE="final"
    shift
fi
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi
case "$MODE" in
    incremental|final) ;;
    *) die "BUNDLE_MODE must be incremental or final: $MODE" ;;
esac
if [ "$MODE" = "final" ]; then
    [ "${RELEASE_SNAPSHOT_ACTIVE:-0}" = "1" ] \
        || die "final bundle must run through RELEASE_GATE_PHASE=prepare in a detached commit snapshot"
    [ -n "${RELEASE_SNAPSHOT_COMMIT:-}" ] \
        || die "final bundle snapshot commit binding is missing"
    [ "$ROOT" = "${RELEASE_SNAPSHOT_ROOT:-}" ] \
        || die "final bundle snapshot root binding differs from the source root"
    [ "${RELEASE_SNAPSHOT_READ_ONLY:-0}" = "1" ] \
        || die "final bundle source must be an OS-enforced read-only snapshot"
    [ -f "$ROOT/.git" ] && [ ! -L "$ROOT/.git" ] \
        || die "final bundle source must be a linked Git worktree"
    if /usr/bin/git -C "$ROOT" symbolic-ref -q HEAD >/dev/null 2>&1; then
        die "final bundle source worktree must have detached HEAD"
    fi
    [ "$(/usr/bin/git -C "$ROOT" rev-parse HEAD)" = "$RELEASE_SNAPSHOT_COMMIT" ] \
        || die "final bundle snapshot commit binding differs from HEAD"
fi

CONFIG="${1:-Release}"
APP_INPUT="${2:-$HOME/Desktop/Twisterminigen.app}"
DERIVED="$APPROOT/.build-xcode"
PRODUCTS="$DERIVED/Build/Products/$CONFIG"

case "$CONFIG" in
    Debug|Release) ;;
    *) die "configuration must be Debug or Release: $CONFIG" ;;
esac
[ "$MODE" != "final" ] || [ "$CONFIG" = "Release" ] \
    || die "final mode requires the Release configuration"

# Guard the only user-controlled path before any staging or replacement operation.
[ -n "$APP_INPUT" ] || die "output .app path is empty"
APP_NAME="$(basename "$APP_INPUT")"
APP_PARENT_INPUT="$(dirname "$APP_INPUT")"
case "$APP_NAME" in
    *.app) ;;
    *) die "output path must end in .app: $APP_INPUT" ;;
esac
[ "$APP_NAME" != ".app" ] && [ "$APP_NAME" != "..app" ] || die "invalid output bundle name"
case "$APP_NAME" in
    *$'\n'*) die "output bundle name contains a newline" ;;
esac
[ -d "$APP_PARENT_INPUT" ] || die "parent directory does not exist: $APP_PARENT_INPUT"
APP_PARENT="$(cd "$APP_PARENT_INPUT" && pwd -P)"
[ "$APP_PARENT" != "/" ] || die "the bundle cannot be placed at the filesystem root"
[ -w "$APP_PARENT" ] || die "parent directory is not writable: $APP_PARENT"
APP="$APP_PARENT/$APP_NAME"
[ ! -e "$APP" ] && [ ! -L "$APP" ] \
    || die "output app path must not already exist; choose a new destination: $APP"

for tool in xcodebuild ditto plutil codesign mktemp install shasum awk grep strip python3 xcrun stat; do
    require_command "$tool"
done
if [ "$MODE" = "final" ]; then
    for tool in git sw_vers find sort python3; do
        require_command "$tool"
    done
fi
require_file "$VERSION_FILE"
require_file "$APP_PACKAGE_RESOLVED"
require_file "$ENGINE_PACKAGE_RESOLVED"
require_file "$DEFAULT_ENTITLEMENTS_SOURCE"
require_file "$RUNTIME_PRODUCTS_ALLOWLIST"
require_file "$EXCLUSIVE_RENAME_SOURCE"
[ ! -L "$EXCLUSIVE_RENAME_SOURCE" ] \
    || die "exclusive rename helper source must not be a symbolic link"
[ ! -L "$DEFAULT_ENTITLEMENTS_SOURCE" ] \
    || die "default release entitlements must not be a symbolic link"
ENTITLEMENTS_INPUT="${SIGN_ENTITLEMENTS:-$DEFAULT_ENTITLEMENTS_SOURCE}"
[ -s "$ENTITLEMENTS_INPUT" ] || die "release entitlements not found or empty: $ENTITLEMENTS_INPUT"
[ ! -L "$ENTITLEMENTS_INPUT" ] || die "release entitlements must not be a symbolic link"
ENTITLEMENTS_PARENT="$(cd "$(dirname "$ENTITLEMENTS_INPUT")" && pwd -P)"
ENTITLEMENTS_SOURCE="$ENTITLEMENTS_PARENT/$(basename "$ENTITLEMENTS_INPUT")"
[ "$ENTITLEMENTS_SOURCE" = "$DEFAULT_ENTITLEMENTS_SOURCE" ] \
    || die "SIGN_ENTITLEMENTS may only reference the tracked default: $DEFAULT_ENTITLEMENTS_SOURCE"
plutil -lint "$ENTITLEMENTS_SOURCE" >/dev/null \
    || die "release entitlements is not a valid plist"
python3 - "$ENTITLEMENTS_SOURCE" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    value = plistlib.load(stream)
if value != {}:
    raise SystemExit("safe default release entitlements must be an exact empty dictionary")
PY

CUR_BUILD="$(read_build_number)"
case "$CUR_BUILD" in
    ''|*[!0-9]*) die "could not read build from AppVersion.swift" ;;
esac
VERSION="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' "$VERSION_FILE")"
[ -n "$VERSION" ] || die "could not read version from AppVersion.swift"

FINAL_COMMIT=""
XCODE_VERSION=""
MACOS_PRODUCT_VERSION=""
MACOS_BUILD_VERSION=""
SOURCE_DATE_EPOCH=""
if [ "$MODE" = "final" ]; then
    FINAL_COMMIT="$(verify_final_source_state)"
    for release_input in \
        "$VERSION_FILE" "$APP_PACKAGE_RESOLVED" "$ENGINE_PACKAGE_RESOLVED" \
        "$NOTICE_SOURCE" "$KREA_LICENSE_SOURCE" "$THIRD_PARTY_SOURCE" \
        "$PRIVACY_NOTICE_SOURCE" "$CONTENT_SAFETY_SOURCE" "$PRIVACY_MANIFEST_SOURCE" \
        "$RELEASE_COMPLIANCE_SOURCE" "$OUTPUT_REVIEW_GATE_SOURCE" \
        "$ENTITLEMENTS_SOURCE" "$RUNTIME_PRODUCTS_ALLOWLIST" \
        "$ROOT/tools/bundle_app.sh" "$ROOT/tools/privacy_scan.sh" \
        "$ROOT/tools/verify_release_coverage.sh" \
        "$APPROOT/.swiftpm/xcode/xcshareddata/xcschemes/Twisterminigen-Distribution.xcscheme" \
        "$ROOT/tools/verify_release_receipt.sh" \
        "$ROOT/tools/verify_runtime_payload.py" \
        "$EXCLUSIVE_RENAME_SOURCE" \
        "$ROOT/tools/signing_normalized_macho.py" \
        "$ROOT/tools/verify_signed_entitlements.py" \
        "$ROOT/tools/reject_symlinks.py" \
        "$ROOT/tools/verify_release_source_state.py" \
        "$ROOT/tools/verify_resolved_checkouts.py" \
        "$ROOT/tools/hash_file_set.py" \
        "$ROOT/tools/validate_privacy_manifests.py"; do
        require_file "$release_input"
        require_tracked_file "$release_input"
    done
    [ "$(sha256_file "$ENTITLEMENTS_SOURCE")" = \
        "$(git -C "$ROOT" show "$FINAL_COMMIT:app/Twisterminigen/Release.entitlements" | shasum -a 256 | awk '{print $1}')" ] \
        || die "release entitlements differs from the committed allowed file"
    "$ROOT/tools/privacy_scan.sh"
    [ "$CUR_BUILD" -ge 1 ] || die "final release build must be a positive integer: $CUR_BUILD"
    NEW_BUILD="$CUR_BUILD"
    BUILD="$CUR_BUILD"
    XCODE_VERSION="$(xcodebuild -version)"
    MACOS_PRODUCT_VERSION="$(sw_vers -productVersion)"
    MACOS_BUILD_VERSION="$(sw_vers -buildVersion)"
    SOURCE_DATE_EPOCH="$(git -C "$ROOT" show -s --format=%ct "$FINAL_COMMIT")"
else
    NEW_BUILD=$((10#$CUR_BUILD + 1))
    BUILD="$NEW_BUILD"
fi

STAGING=""
STAGING_ROOT=""
EXCLUSIVE_RENAME_ROOT=""
EXCLUSIVE_RENAME_TOOL=""
PUBLISHED=0
PUBLISH_IDENTITY=""
VERSION_DIRTY=0
FINAL_PACKAGES_ROOT=""
FINAL_CHECKOUT_INVENTORY=""
FINAL_DERIVED_ROOT=""
RUNTIME_PAYLOAD_INVENTORY=""

cleanup() {
    local status=$?
    set +e
    trap - EXIT

    # An interrupt can arrive after renameatx_np made the app visible but before the shell records
    # PUBLISHED=1. Recover that state by inode identity. The public pathname is never removed or
    # replaced by cleanup after visibility, even when a subsequent verification fails.
    if [ "$PUBLISHED" -eq 0 ] && [ -n "$PUBLISH_IDENTITY" ] && [ -d "$APP" ] \
       && [ ! -L "$APP" ] \
       && [ "$(stat -f '%d:%i' "$APP" 2>/dev/null)" = "$PUBLISH_IDENTITY" ]; then
        PUBLISHED=1
    fi

    if [ "$PUBLISHED" -eq 0 ] && [ "$VERSION_DIRTY" -eq 1 ]; then
        if [ "$(read_build_number 2>/dev/null)" = "$NEW_BUILD" ]; then
            sed -i '' "s/static let build = \"$NEW_BUILD\"/static let build = \"$CUR_BUILD\"/" "$VERSION_FILE"
        else
            echo "warning: AppVersion.swift changed concurrently; build was not rolled back" >&2
        fi
    fi

    [ -z "$STAGING_ROOT" ] || rm -rf -- "$STAGING_ROOT"
    [ -z "$EXCLUSIVE_RENAME_ROOT" ] || rm -rf -- "$EXCLUSIVE_RENAME_ROOT"
    [ -z "$FINAL_PACKAGES_ROOT" ] || rm -rf -- "$FINAL_PACKAGES_ROOT"
    [ -z "$FINAL_DERIVED_ROOT" ] || rm -rf -- "$FINAL_DERIVED_ROOT"
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

EXCLUSIVE_RENAME_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/twisterminigen-exclusive-rename.XXXXXX")"
EXCLUSIVE_RENAME_TOOL="$EXCLUSIVE_RENAME_ROOT/exclusive-rename"
xcrun --sdk macosx clang -std=c11 -Os -Wall -Wextra -Werror \
    -o "$EXCLUSIVE_RENAME_TOOL" "$EXCLUSIVE_RENAME_SOURCE"
chmod 700 "$EXCLUSIVE_RENAME_TOOL"
[ -x "$EXCLUSIVE_RENAME_TOOL" ] || die "failed to compile the exclusive rename helper"

if [ "$MODE" = "final" ]; then
    FINAL_PACKAGES_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/twisterminigen-final-packages.XXXXXX")"
    [ -z "$(find "$FINAL_PACKAGES_ROOT" -mindepth 1 -print -quit)" ] \
        || die "fresh cloned source package directory is unexpectedly non-empty"
    FINAL_CHECKOUT_INVENTORY="$FINAL_PACKAGES_ROOT/ResolvedCheckoutInventory.json"
    FINAL_DERIVED_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/twisterminigen-final-derived.XXXXXX")"
    [ -z "$(find "$FINAL_DERIVED_ROOT" -mindepth 1 -print -quit)" ] \
        || die "fresh final DerivedData root is unexpectedly non-empty"
    DERIVED="$FINAL_DERIVED_ROOT/DerivedData"
    PRODUCTS="$DERIVED/Build/Products/$CONFIG"
fi

run_xcode_build() {
    (
        cd "$APPROOT"
        if [ "$MODE" = "final" ]; then
            XCODE_PACKAGE_WORKDIR="$APPROOT/.swiftpm/xcode"
            XCODE_PACKAGE_WORKDIR_ANCHOR="$XCODE_PACKAGE_WORKDIR/.release-workdir"
            [ -d "$XCODE_PACKAGE_WORKDIR" ] && [ ! -L "$XCODE_PACKAGE_WORKDIR" ] \
                || die "tracked Xcode package working directory is missing: $XCODE_PACKAGE_WORKDIR"
            require_file "$XCODE_PACKAGE_WORKDIR_ANCHOR"
        fi
        # Remove the local checkout path from Swift/C/C++ debug info and __FILE__ strings. All
        # final dependency checkouts use a fresh temporary root, mapped separately below.
        local canonical_source="/src/Twisterminigen"
        local swift_prefix_flags="-debug-prefix-map $ROOT=$canonical_source -file-prefix-map $ROOT=$canonical_source"
        local c_prefix_flags="-fdebug-prefix-map=$ROOT=$canonical_source -ffile-prefix-map=$ROOT=$canonical_source"
        # Keep this array non-empty: macOS still ships Bash 3.2, where expanding an empty local
        # array under `set -u` raises "unbound variable" in incremental builds.
        local package_args=(-skipPackagePluginValidation -skipMacroValidation)
        local action_args=(build)
        if [ "$MODE" = "final" ]; then
            package_args+=(
                -disableAutomaticPackageResolution
                -onlyUsePackageVersionsFromResolvedFile
                -clonedSourcePackagesDirPath "$FINAL_PACKAGES_ROOT"
            )
            action_args=(clean build)
            swift_prefix_flags+=" -debug-prefix-map $FINAL_PACKAGES_ROOT=/src/SwiftPackages -file-prefix-map $FINAL_PACKAGES_ROOT=/src/SwiftPackages"
            c_prefix_flags+=" -fdebug-prefix-map=$FINAL_PACKAGES_ROOT=/src/SwiftPackages -ffile-prefix-map=$FINAL_PACKAGES_ROOT=/src/SwiftPackages"
            swift_prefix_flags+=" -debug-prefix-map $FINAL_DERIVED_ROOT=/src/DerivedData -file-prefix-map $FINAL_DERIVED_ROOT=/src/DerivedData"
            c_prefix_flags+=" -fdebug-prefix-map=$FINAL_DERIVED_ROOT=/src/DerivedData -ffile-prefix-map=$FINAL_DERIVED_ROOT=/src/DerivedData"
            export SOURCE_DATE_EPOCH
        fi
        # A final build is always cold and commit-bound. Disable both compilation-result reuse and
        # Xcode's SDK stat-cache helper: the latter cannot be spawned reliably when the package
        # workspace is mounted from the OS-enforced read-only release image, and neither cache is
        # part of the release provenance we verify.
        xcodebuild "${package_args[@]}" \
            -scheme Twisterminigen-Distribution -destination 'platform=macOS' \
            -configuration "$CONFIG" -derivedDataPath "$DERIVED" \
            COMPILATION_CACHE_ENABLE_CACHING=NO \
            SDK_STAT_CACHE_ENABLE=NO \
            OTHER_SWIFT_FLAGS="\$(inherited) $swift_prefix_flags" \
            OTHER_CFLAGS="\$(inherited) $c_prefix_flags" \
            OTHER_CPLUSPLUSFLAGS="\$(inherited) $c_prefix_flags" \
            "${action_args[@]}" | tail -n 8
    )
}

# Incremental mode compiles before consuming a build number, then performs a cheap incremental
# rebuild with the new AppVersion.build. Final mode builds once from the already committed build.
if [ "$MODE" = "final" ]; then
    echo "▸ reproducible final build Twisterminigen $VERSION (build $BUILD, $CONFIG)…"
    run_xcode_build
    python3 "$ROOT/tools/verify_resolved_checkouts.py" \
        "$APP_PACKAGE_RESOLVED" "$FINAL_PACKAGES_ROOT/checkouts" \
        --inventory-output "$FINAL_CHECKOUT_INVENTORY" >/dev/null
    require_file "$FINAL_CHECKOUT_INVENTORY"
    verify_final_source_state "$FINAL_COMMIT" >/dev/null
    [ "$(sha256_file "$APP_PACKAGE_RESOLVED")" = "$(git -C "$ROOT" show "$FINAL_COMMIT:app/Twisterminigen/Package.resolved" | shasum -a 256 | awk '{print $1}')" ] \
        || die "app Package.resolved differs from the committed release input"
    [ "$(sha256_file "$ENGINE_PACKAGE_RESOLVED")" = "$(git -C "$ROOT" show "$FINAL_COMMIT:engine/Krea2Engine/Package.resolved" | shasum -a 256 | awk '{print $1}')" ] \
        || die "engine Package.resolved differs from the committed release input"
    python3 "$ROOT/tools/verify_runtime_payload.py" verify-products \
        --products "$PRODUCTS" --allowlist "$RUNTIME_PRODUCTS_ALLOWLIST" \
        --derived-root "$FINAL_DERIVED_ROOT"
else
    echo "▸ compilation check Twisterminigen $VERSION (build $CUR_BUILD, $CONFIG)…"
    run_xcode_build
    replace_build_number "$CUR_BUILD" "$NEW_BUILD"
    echo "▸ final build Twisterminigen $VERSION (build $BUILD, $CONFIG)…"
    run_xcode_build
fi

EXECUTABLE="$PRODUCTS/Twisterminigen"
MLX_BUNDLE="$PRODUCTS/mlx-swift_Cmlx.bundle"
HUB_BUNDLE="$PRODUCTS/swift-transformers_Hub.bundle"
ICON_SOURCE="$ROOT/app/icon/AppIcon.icns"
LOGO_SOURCE="$ROOT/app/icon/AppLogo.png"
if [ "$MODE" = "final" ]; then
    THIRD_PARTY_CHECKOUTS="$FINAL_PACKAGES_ROOT/checkouts"
else
    THIRD_PARTY_CHECKOUTS="$DERIVED/SourcePackages/checkouts"
fi

require_file "$EXECUTABLE"
"$ROOT/tools/verify_release_coverage.sh" "$EXECUTABLE" "$PRODUCTS"
require_directory "$MLX_BUNDLE"
require_file "$MLX_BUNDLE/Contents/Resources/default.metallib"
require_directory "$HUB_BUNDLE"
require_file "$HUB_BUNDLE/Contents/Resources/gpt2_tokenizer_config.json"
require_file "$HUB_BUNDLE/Contents/Resources/t5_tokenizer_config.json"
require_file "$ICON_SOURCE"
require_file "$LOGO_SOURCE"
require_file "$NOTICE_SOURCE"
require_file "$KREA_LICENSE_SOURCE"
require_file "$THIRD_PARTY_SOURCE"
require_directory "$THIRD_PARTY_CHECKOUTS"
require_file "$PRIVACY_NOTICE_SOURCE"
require_file "$CONTENT_SAFETY_SOURCE"
require_file "$PRIVACY_MANIFEST_SOURCE"
[ "$(shasum -a 256 "$KREA_LICENSE_SOURCE" | awk '{print $1}')" = \
    "7cd975008d1b944452d1fca9e9a6099e5cd4c46d36fdc283c7691da9307fc29e" ] \
    || die "Krea 2 Community License text changed; update the legal gate and acceptance receipt"
grep -Fqx \
    'Krea 2 is licensed under the Krea 2 Community License Agreement. For more information, visit https://krea.ai/krea-2-licensing.' \
    "$NOTICE_SOURCE" || die "NOTICE does not contain the required exact Krea statement"
plutil -lint "$PRIVACY_MANIFEST_SOURCE" >/dev/null \
    || die "PrivacyInfo.xcprivacy is not a valid plist"

if [ "$MODE" = "final" ]; then
    RESOURCE_BUNDLES=(
        "$PRODUCTS/Twisterminigen_Twisterminigen.bundle"
        "$PRODUCTS/mlx-swift_Cmlx.bundle"
        "$PRODUCTS/swift-crypto_Crypto.bundle"
        "$PRODUCTS/swift-transformers_Hub.bundle"
    )
else
    shopt -s nullglob
    RESOURCE_BUNDLES=("$PRODUCTS"/*.bundle)
    shopt -u nullglob
fi
[ "${#RESOURCE_BUNDLES[@]}" -gt 0 ] || die "no resource bundles were found in the build products"

# mktemp creates staging beside the destination, so the final rename stays on one filesystem.
# The nested directory keeps a real .app suffix for unambiguous bundle and codesign handling.
STAGING_ROOT="$(mktemp -d "$APP_PARENT/.${APP_NAME}.staging.XXXXXX")"
STAGING="$STAGING_ROOT/$APP_NAME"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
mkdir -p "$STAGING/Contents/Resources/Licenses/ThirdParty"
if [ "$MODE" = "final" ]; then
    mkdir -p "$STAGING/Contents/Resources/ReleaseMetadata"
fi

echo "▸ assembling staging bundle $STAGING"
install -m 755 "$EXECUTABLE" "$STAGING/Contents/MacOS/Twisterminigen"
# Remove local build paths and symbols from the staged executable before signing.
strip -S -x "$STAGING/Contents/MacOS/Twisterminigen"
for bundle in "${RESOURCE_BUNDLES[@]}"; do
    ditto "$bundle" "$STAGING/Contents/Resources/$(basename "$bundle")"
done
install -m 644 "$ICON_SOURCE" "$STAGING/Contents/Resources/AppIcon.icns"
install -m 644 "$LOGO_SOURCE" "$STAGING/Contents/Resources/AppLogo.png"
install -m 644 "$NOTICE_SOURCE" "$STAGING/Contents/Resources/NOTICE"
install -m 644 "$KREA_LICENSE_SOURCE" \
    "$STAGING/Contents/Resources/KREA-2-COMMUNITY-LICENSE.txt"
install -m 644 "$THIRD_PARTY_SOURCE" "$STAGING/Contents/Resources/THIRD_PARTY_LICENSES.md"
install -m 644 "$THIRD_PARTY_SOURCE" \
    "$STAGING/Contents/Resources/Licenses/ThirdParty/INDEX.md"

# Package.resolved is the inventory; every fetched checkout must contribute its complete top-level
# LICENSE and NOTICE payload. Including all pins is intentionally conservative for static linking.
EXPECTED_PIN_COUNT="$(python3 - "$APP_PACKAGE_RESOLVED" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    document = json.load(stream)
pins = document.get("pins")
if not isinstance(pins, list) or not pins:
    raise SystemExit("Package.resolved contains no pins")
print(len(pins))
PY
)"
THIRD_PARTY_CHECKOUT_COUNT=0
for checkout in "$THIRD_PARTY_CHECKOUTS"/*; do
    [ -d "$checkout" ] || continue
    checkout_name="$(basename "$checkout")"
    found_license=0
    shopt -s nullglob
    legal_files=("$checkout"/LICENSE "$checkout"/LICENSE.* "$checkout"/NOTICE "$checkout"/NOTICE.*)
    shopt -u nullglob
    for legal_file in "${legal_files[@]}"; do
        [ -f "$legal_file" ] || continue
        [ ! -L "$legal_file" ] || die "license file must not be a symlink: $legal_file"
        install -m 644 "$legal_file" \
            "$STAGING/Contents/Resources/Licenses/ThirdParty/${checkout_name}__$(basename "$legal_file")"
        found_license=1
    done
    [ "$found_license" -eq 1 ] || die "dependency checkout has no LICENSE/NOTICE: $checkout_name"
    THIRD_PARTY_CHECKOUT_COUNT=$((THIRD_PARTY_CHECKOUT_COUNT + 1))
done
[ "$THIRD_PARTY_CHECKOUT_COUNT" = "$EXPECTED_PIN_COUNT" ] \
    || die "third-party license inventory mismatch: $THIRD_PARTY_CHECKOUT_COUNT checkouts, $EXPECTED_PIN_COUNT pins"
install -m 644 "$PRIVACY_NOTICE_SOURCE" "$STAGING/Contents/Resources/PRIVACY.md"
install -m 644 "$CONTENT_SAFETY_SOURCE" "$STAGING/Contents/Resources/CONTENT_SAFETY.md"
install -m 644 "$PRIVACY_MANIFEST_SOURCE" "$STAGING/Contents/Resources/PrivacyInfo.xcprivacy"
if [ "$MODE" = "final" ]; then
    install -m 644 "$APP_PACKAGE_RESOLVED" \
        "$STAGING/Contents/Resources/ReleaseMetadata/App.Package.resolved"
    install -m 644 "$ENGINE_PACKAGE_RESOLVED" \
        "$STAGING/Contents/Resources/ReleaseMetadata/Engine.Package.resolved"
    install -m 644 "$FINAL_CHECKOUT_INVENTORY" \
        "$STAGING/Contents/Resources/ReleaseMetadata/ResolvedCheckoutInventory.json"
    install -m 644 "$ENTITLEMENTS_SOURCE" \
        "$STAGING/Contents/Resources/ReleaseMetadata/SigningEntitlements.plist"
fi

# A SwiftPM command-line product is packaged into .app manually, so Xcode emits const values but
# does not copy the executable target's App Intents metadata. Produce and verify it before signing.
"$ROOT/tools/extract_app_intents_metadata.sh" \
    "$CONFIG" "$DERIVED" "$STAGING/Contents/Resources"

INFO_PLIST="$STAGING/Contents/Info.plist"
plutil -create xml1 "$INFO_PLIST"
plutil -insert CFBundleExecutable -string Twisterminigen "$INFO_PLIST"
plutil -insert CFBundleIconFile -string AppIcon "$INFO_PLIST"
plutil -insert CFBundleIdentifier -string com.personal.twisterminigen "$INFO_PLIST"
plutil -insert CFBundleName -string Twisterminigen "$INFO_PLIST"
plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$INFO_PLIST"
plutil -insert CFBundleVersion -string "$BUILD" "$INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string 14.0 "$INFO_PLIST"
plutil -insert NSHighResolutionCapable -bool YES "$INFO_PLIST"
plutil -insert UTExportedTypeDeclarations -json '[{"UTTypeIdentifier":"com.twisterminigen.recipe","UTTypeDescription":"Twisterminigen Recipe","UTTypeConformsTo":["public.json"],"UTTypeTagSpecification":{"public.filename-extension":["twisterrecipe"],"public.mime-type":["application/vnd.twisterminigen.recipe+json"]}}]' "$INFO_PLIST"
plutil -insert CFBundleDocumentTypes -json '[{"CFBundleTypeName":"Twisterminigen Recipe","CFBundleTypeRole":"Editor","LSHandlerRank":"Owner","LSItemContentTypes":["com.twisterminigen.recipe"]}]' "$INFO_PLIST"

if [ "$MODE" = "final" ]; then
    verify_final_source_state "$FINAL_COMMIT" >/dev/null
    RUNTIME_PAYLOAD_INVENTORY="$STAGING/Contents/Resources/ReleaseMetadata/RuntimePayloadInventory.json"
    python3 "$ROOT/tools/verify_runtime_payload.py" create-inventory \
        --app "$STAGING" --output "$RUNTIME_PAYLOAD_INVENTORY" >/dev/null
    create_final_release_receipt
fi

# Verify the staged runtime payload rather than trusting wildcard copies.
require_file "$STAGING/Contents/MacOS/Twisterminigen"
require_file "$STAGING/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
require_file "$STAGING/Contents/Resources/swift-transformers_Hub.bundle/Contents/Resources/gpt2_tokenizer_config.json"
require_file "$STAGING/Contents/Resources/swift-transformers_Hub.bundle/Contents/Resources/t5_tokenizer_config.json"
require_file "$STAGING/Contents/Resources/AppIcon.icns"
require_file "$STAGING/Contents/Resources/AppLogo.png"
require_file "$STAGING/Contents/Resources/NOTICE"
require_file "$STAGING/Contents/Resources/KREA-2-COMMUNITY-LICENSE.txt"
require_file "$STAGING/Contents/Resources/THIRD_PARTY_LICENSES.md"
require_file "$STAGING/Contents/Resources/Licenses/ThirdParty/INDEX.md"
require_file "$STAGING/Contents/Resources/PRIVACY.md"
require_file "$STAGING/Contents/Resources/CONTENT_SAFETY.md"
require_file "$STAGING/Contents/Resources/PrivacyInfo.xcprivacy"
require_file "$STAGING/Contents/Resources/Metadata.appintents/extract.actionsdata"
if [ "$MODE" = "final" ]; then
    require_file "$STAGING/Contents/Resources/ReleaseReceipt.json"
    require_file "$STAGING/Contents/Resources/ReleaseMetadata/App.Package.resolved"
    require_file "$STAGING/Contents/Resources/ReleaseMetadata/Engine.Package.resolved"
    require_file "$STAGING/Contents/Resources/ReleaseMetadata/ResolvedCheckoutInventory.json"
    require_file "$STAGING/Contents/Resources/ReleaseMetadata/SigningEntitlements.plist"
    require_file "$STAGING/Contents/Resources/ReleaseMetadata/RuntimePayloadInventory.json"
fi
for bundle in "${RESOURCE_BUNDLES[@]}"; do
    require_directory "$STAGING/Contents/Resources/$(basename "$bundle")"
done
plutil -lint "$INFO_PLIST" >/dev/null
[ "$(plutil -extract CFBundleVersion raw "$INFO_PLIST")" = "$BUILD" ] || die "CFBundleVersion does not match build $BUILD"
[ "$(plutil -extract UTExportedTypeDeclarations.0.UTTypeIdentifier raw "$INFO_PLIST")" = "com.twisterminigen.recipe" ] || die ".twisterrecipe UTI is not embedded"
"$ROOT/tools/verify_release_coverage.sh" \
    "$STAGING/Contents/MacOS/Twisterminigen" "$STAGING"

if [ "$MODE" = "final" ]; then
    "$ROOT/tools/verify_release_receipt.sh" "$STAGING" --pre-sign
    [ "$(plutil -extract GitCommit raw "$STAGING/Contents/Resources/ReleaseReceipt.json")" = "$FINAL_COMMIT" ] \
        || die "release receipt commit mismatch"
    [ "$(plutil -extract ReleaseComplianceSourceSHA256 raw "$STAGING/Contents/Resources/ReleaseReceipt.json")" = \
        "$(sha256_file "$RELEASE_COMPLIANCE_SOURCE")" ] \
        || die "release compliance source hash mismatch"
    [ "$(plutil -extract OutputReviewGateSourceSHA256 raw "$STAGING/Contents/Resources/ReleaseReceipt.json")" = \
        "$(sha256_file "$OUTPUT_REVIEW_GATE_SOURCE")" ] \
        || die "output review gate source hash mismatch"
    verify_final_source_state "$FINAL_COMMIT" >/dev/null
    "$ROOT/tools/privacy_scan.sh" --pre-sign "$STAGING"
fi

SIGNING_IDENTITY="${SIGN_IDENTITY:--}"
[ "$CONFIG" != "Release" ] || [ "$SIGNING_IDENTITY" != "-" ] \
    || [ "${ALLOW_ADHOC:-0}" = "1" ] \
    || die "Release requires SIGN_IDENTITY=Developer ID Application; use ALLOW_ADHOC=1 only for local preflight"
if [ "$CONFIG" = "Release" ] && [ "$SIGNING_IDENTITY" != "-" ] \
   && [[ "$SIGNING_IDENTITY" != Developer\ ID\ Application:* ]] \
   && [ "${ALLOW_NON_DISTRIBUTION_SIGNING:-0}" != "1" ]; then
    die "distribution Release must use Developer ID Application (or explicitly set ALLOW_NON_DISTRIBUTION_SIGNING=1 for local preflight)"
fi
SIGNING_ARGS=(--force --deep --sign "$SIGNING_IDENTITY")
if [ "$SIGNING_IDENTITY" != "-" ]; then
    # Developer ID distribution requires the hardened runtime and a trusted timestamp. Apple
    # Development can use the same hardened runtime gate for local preflight builds.
    SIGNING_ARGS+=(--options runtime --timestamp)
fi
SIGNING_ARGS+=(--entitlements "$ENTITLEMENTS_SOURCE")

echo "▸ signing (${SIGNING_IDENTITY:--})"
"$ROOT/tools/verify_release_coverage.sh" \
    "$STAGING/Contents/MacOS/Twisterminigen" "$STAGING"
codesign "${SIGNING_ARGS[@]}" "$STAGING"
codesign --verify --deep --strict --verbose=2 "$STAGING"
"$ROOT/tools/verify_release_coverage.sh" \
    "$STAGING/Contents/MacOS/Twisterminigen" "$STAGING"
if [ "$MODE" = "final" ]; then
    SIGNED_ENTITLEMENTS_EXPECTED="$STAGING/Contents/Resources/ReleaseMetadata/SigningEntitlements.plist"
else
    SIGNED_ENTITLEMENTS_EXPECTED="$ENTITLEMENTS_SOURCE"
fi
python3 "$ROOT/tools/verify_signed_entitlements.py" "$STAGING" "$SIGNED_ENTITLEMENTS_EXPECTED"
if [ "$SIGNING_IDENTITY" != "-" ]; then
    SIGNING_DETAILS="$(codesign -d --verbose=4 "$STAGING" 2>&1)" \
        || die "cannot inspect the signed bundle hardened-runtime flags"
    grep -q 'flags=.*runtime' <<<"$SIGNING_DETAILS" \
        || die "signed bundle does not contain the hardened runtime"
fi

"$ROOT/tools/privacy_scan.sh" "$STAGING"

# The destination was required to be absent before any build work. RENAME_EXCL closes the remaining
# check-to-publish race without overwriting a path created concurrently. Once this call makes the
# app visible, no cleanup path removes or rolls it back; a verification failure leaves these exact
# bytes at the requested pathname for diagnosis.
STAGING_RELATIVE="${STAGING#"$APP_PARENT"/}"
[ "$STAGING_RELATIVE" != "$STAGING" ] \
    || die "staging app is not beneath the canonical output parent"
PUBLISH_IDENTITY="$(stat -f '%d:%i' "$STAGING")"
"$EXCLUSIVE_RENAME_TOOL" "$APP_PARENT" "$STAGING_RELATIVE" "$APP_NAME"
PUBLISHED=1
STAGING=""
[ -d "$APP" ] && [ ! -L "$APP" ] \
    && [ "$(stat -f '%d:%i' "$APP")" = "$PUBLISH_IDENTITY" ] \
    || die "published app identity differs from the verified staging bundle"

# Verify the exact publicly visible bundle. A failure is reported without deleting that bundle.
codesign --verify --deep --strict --verbose=2 "$APP"
"$ROOT/tools/verify_release_coverage.sh" "$APP/Contents/MacOS/Twisterminigen" "$APP"
if [ "$MODE" = "final" ]; then
    "$ROOT/tools/verify_release_receipt.sh" "$APP"
fi
[ "$(stat -f '%d:%i' "$APP")" = "$PUBLISH_IDENTITY" ] \
    || die "published app was substituted during post-visibility verification"

echo "✓ complete: $APP  (v$VERSION build $BUILD, $CONFIG)"
