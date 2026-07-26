#!/bin/bash
# Validate the machine-readable receipt embedded by `bundle_app.sh --final`.
# `--pre-sign` additionally verifies the unsigned executable hash recorded before codesign.
set -euo pipefail

die() {
    echo "error: $*" >&2
    exit 1
}

require_file() {
    [ -s "$1" ] || die "missing or empty release receipt input: $1"
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

hash_file_set() {
    local directory="$1"
    python3 "$TOOL_ROOT/tools/hash_file_set.py" "$directory"
}

receipt_value() {
    plutil -extract "$1" raw "$RECEIPT" 2>/dev/null \
        || die "release receipt is missing field: $1"
}

require_sha256() {
    local field="$1"
    local value
    value="$(receipt_value "$field")"
    printf '%s\n' "$value" | grep -Eq '^[0-9a-f]{64}$' \
        || die "release receipt field is not SHA-256: $field"
}

verify_file_hash() {
    local field="$1"
    local file="$2"
    local expected actual
    require_file "$file"
    expected="$(receipt_value "$field")"
    actual="$(sha256_file "$file")"
    [ "$actual" = "$expected" ] \
        || die "$field mismatch for ${file#"$APP"/}: expected $expected, got $actual"
}

APP_INPUT="${1:-}"
TOOL_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VERIFY_UNSIGNED=0
VERIFY_NOTARIZED=0
case "${2:-}" in
    "") ;;
    --pre-sign) VERIFY_UNSIGNED=1 ;;
    --post-notary) VERIFY_NOTARIZED=1 ;;
    *) die "usage: tools/verify_release_receipt.sh /path/Twisterminigen.app [--pre-sign|--post-notary]" ;;
esac

[ -n "$APP_INPUT" ] \
    || die "usage: tools/verify_release_receipt.sh /path/Twisterminigen.app [--pre-sign|--post-notary]"
[ -d "$APP_INPUT" ] || die "app bundle not found: $APP_INPUT"
[ ! -L "$APP_INPUT" ] || die "app bundle must not be a symbolic link"
APP_PARENT="$(cd "$(dirname "$APP_INPUT")" && pwd -P)"
APP="$APP_PARENT/$(basename "$APP_INPUT")"
RESOURCES="$APP/Contents/Resources"
RECEIPT="$RESOURCES/ReleaseReceipt.json"
INFO_PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/Twisterminigen"
APP_RESOLVED="$RESOURCES/ReleaseMetadata/App.Package.resolved"
ENGINE_RESOLVED="$RESOURCES/ReleaseMetadata/Engine.Package.resolved"
CHECKOUT_INVENTORY="$RESOURCES/ReleaseMetadata/ResolvedCheckoutInventory.json"
RUNTIME_PAYLOAD_INVENTORY="$RESOURCES/ReleaseMetadata/RuntimePayloadInventory.json"
SIGNING_ENTITLEMENTS="$RESOURCES/ReleaseMetadata/SigningEntitlements.plist"
THIRD_PARTY_LICENSES="$RESOURCES/Licenses/ThirdParty"

for tool in plutil shasum awk grep find sort python3; do
    command -v "$tool" >/dev/null 2>&1 || die "required command not found: $tool"
done
require_file "$RECEIPT"
require_file "$INFO_PLIST"
require_file "$EXECUTABLE"
[ -d "$THIRD_PARTY_LICENSES" ] || die "missing third-party license directory"
python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$RECEIPT" \
    || die "ReleaseReceipt.json is not valid JSON"

[ "$(receipt_value ReceiptSchemaVersion)" = "1" ] || die "unsupported release receipt schema"
[ "$(receipt_value ReleaseMode)" = "final" ] || die "receipt is not for a final release"
[ "$(receipt_value SourceState)" = "clean-local-commit" ] \
    || die "receipt SourceState is not the exact final release policy"
[ "$(receipt_value SourceSnapshotPolicy)" = "read-only-disk-image-commit-clean-env-v2" ] \
    || die "receipt source snapshot policy is not an OS-enforced read-only commit snapshot"
[ "$(receipt_value BuildEnvironmentPolicy)" = "env-i-explicit-allowlist-v1" ] \
    || die "receipt build environment policy is not fail-closed"
[ "$(receipt_value SourceSnapshotCommit)" = "$(receipt_value GitCommit)" ] \
    || die "receipt source snapshot commit differs from GitCommit"
[ "$(receipt_value PackageResolutionPolicy)" = "only-Package.resolved" ] \
    || die "receipt PackageResolutionPolicy is not locked"
[ "$(receipt_value ResolvedCheckoutPolicy)" = "all-pins-head-match-clean-no-extras" ] \
    || die "receipt checkout policy is not exhaustive"
[ "$(receipt_value RuntimePayloadPolicy)" = "complete-normalized-runtime-inventory-with-modes-v2" ] \
    || die "receipt runtime payload policy is not exhaustive"
[ "$(receipt_value EntitlementsPolicy)" = "tracked-default-release-entitlements-v1" ] \
    || die "receipt entitlements policy is not commit-bound"
[ "$(receipt_value UnsignedExecutableHashScope)" = \
    "Contents/MacOS/Twisterminigen after strip, before codesign" ] \
    || die "unexpected unsigned executable hash scope"
[ "$(receipt_value SigningNormalizedExecutableHashScope)" = \
    "Mach-O code bytes with LC_CODE_SIGNATURE and signing-dependent __LINKEDIT fields normalized, recomputed pre/post sign" ] \
    || die "unexpected signing-normalized executable hash scope"
[ "$(receipt_value BuildConfiguration)" = "Release" ] || die "receipt is not for Release"
[ "$(receipt_value AppVersion)" = "$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")" ] \
    || die "receipt app version does not match Info.plist"
[ "$(receipt_value AppBuild)" = "$(plutil -extract CFBundleVersion raw "$INFO_PLIST")" ] \
    || die "receipt app build does not match Info.plist"
APP_BUILD="$(receipt_value AppBuild)"
printf '%s\n' "$APP_BUILD" | grep -Eq '^[0-9]+$' \
    || die "receipt AppBuild is not numeric"
[ "$APP_BUILD" -ge 1 ] || die "final release receipt requires a positive build number"
printf '%s\n' "$(receipt_value GitCommit)" | grep -Eq '^[0-9a-f]{40}([0-9a-f]{24})?$' \
    || die "receipt GitCommit is not a complete commit object id"
[ -n "$(receipt_value XcodeVersion)" ] || die "receipt XcodeVersion is empty"
[ -n "$(receipt_value MacOSProductVersion)" ] || die "receipt MacOSProductVersion is empty"
[ -n "$(receipt_value MacOSBuildVersion)" ] || die "receipt MacOSBuildVersion is empty"
printf '%s\n' "$(receipt_value SourceDateEpoch)" | grep -Eq '^[0-9]+$' \
    || die "receipt SourceDateEpoch is invalid"

for field in \
    AppPackageResolvedSHA256 EnginePackageResolvedSHA256 ResolvedCheckoutInventorySHA256 \
    RuntimePayloadInventorySHA256 EntitlementsSHA256 \
    NoticeSHA256 KreaLicenseSHA256 \
    ThirdPartyLicensesIndexSHA256 BundledThirdPartyLicenseSetSHA256 PrivacyNoticeSHA256 \
    ContentSafetySHA256 PrivacyManifestSHA256 ReleaseComplianceSourceSHA256 \
    OutputReviewGateSourceSHA256 MLXDefaultMetallibSHA256 UnsignedExecutableSHA256 \
    SigningNormalizedExecutableSHA256; do
    require_sha256 "$field"
done

verify_file_hash AppPackageResolvedSHA256 "$APP_RESOLVED"
verify_file_hash EnginePackageResolvedSHA256 "$ENGINE_RESOLVED"
verify_file_hash ResolvedCheckoutInventorySHA256 "$CHECKOUT_INVENTORY"
verify_file_hash RuntimePayloadInventorySHA256 "$RUNTIME_PAYLOAD_INVENTORY"
verify_file_hash EntitlementsSHA256 "$SIGNING_ENTITLEMENTS"
plutil -lint "$SIGNING_ENTITLEMENTS" >/dev/null \
    || die "bundled signing entitlements is not a valid plist"
python3 - "$SIGNING_ENTITLEMENTS" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    entitlements = plistlib.load(stream)
if entitlements != {}:
    raise SystemExit("bundled release entitlements is not the exact empty safe-default dictionary")
PY
verify_file_hash NoticeSHA256 "$RESOURCES/NOTICE"
verify_file_hash KreaLicenseSHA256 "$RESOURCES/KREA-2-COMMUNITY-LICENSE.txt"
verify_file_hash ThirdPartyLicensesIndexSHA256 "$RESOURCES/THIRD_PARTY_LICENSES.md"
verify_file_hash PrivacyNoticeSHA256 "$RESOURCES/PRIVACY.md"
verify_file_hash ContentSafetySHA256 "$RESOURCES/CONTENT_SAFETY.md"
verify_file_hash PrivacyManifestSHA256 "$RESOURCES/PrivacyInfo.xcprivacy"
verify_file_hash MLXDefaultMetallibSHA256 \
    "$RESOURCES/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
[ "$(receipt_value SigningNormalizedExecutableSHA256)" = \
    "$(python3 "$TOOL_ROOT/tools/signing_normalized_macho.py" "$EXECUTABLE")" ] \
    || die "signing-normalized executable differs from the commit-built pre-sign Mach-O"

[ "$(receipt_value BundledThirdPartyLicenseSetSHA256)" = "$(hash_file_set "$THIRD_PARTY_LICENSES")" ] \
    || die "bundled third-party license set does not match the release receipt"
[ "$(receipt_value KreaLicenseSHA256)" = \
    "7cd975008d1b944452d1fca9e9a6099e5cd4c46d36fdc283c7691da9307fc29e" ] \
    || die "release receipt does not contain the approved Krea license hash"
grep -Fqx \
    'Krea 2 is licensed under the Krea 2 Community License Agreement. For more information, visit https://krea.ai/krea-2-licensing.' \
    "$RESOURCES/NOTICE" || die "bundled Krea Notice is not exact"
python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$APP_RESOLVED" \
    || die "bundled app Package.resolved is invalid"
python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$ENGINE_RESOLVED" \
    || die "bundled engine Package.resolved is invalid"
python3 - "$APP_RESOLVED" "$ENGINE_RESOLVED" "$CHECKOUT_INVENTORY" <<'PY'
import hashlib
import json
import sys

resolved_path, engine_resolved_path, inventory_path = sys.argv[1:]
with open(resolved_path, encoding="utf-8") as stream:
    resolved = json.load(stream)
with open(engine_resolved_path, encoding="utf-8") as stream:
    engine_resolved = json.load(stream)
with open(inventory_path, encoding="utf-8") as stream:
    inventory = json.load(stream)
if inventory.get("schemaVersion") != 1:
    raise SystemExit("checkout inventory schema mismatch")
resolved_sha = hashlib.sha256(open(resolved_path, "rb").read()).hexdigest()
if inventory.get("packageResolvedSHA256") != resolved_sha:
    raise SystemExit("checkout inventory Package.resolved hash mismatch")
resolved_pin_list = [
    (
        pin.get("identity"),
        pin.get("location"),
        (pin.get("state") or {}).get("revision"),
        (pin.get("state") or {}).get("version") or "",
    )
    for pin in resolved.get("pins", [])
]
inventory_pin_list = [
    (pin.get("identity"), pin.get("location"), pin.get("revision"), pin.get("version") or "")
    for pin in inventory.get("pins", [])
]
engine_pin_list = [
    (
        pin.get("identity"),
        pin.get("location"),
        (pin.get("state") or {}).get("revision"),
        (pin.get("state") or {}).get("version") or "",
    )
    for pin in engine_resolved.get("pins", [])
]
checkout_directories = [pin.get("checkoutDirectory") for pin in inventory.get("pins", [])]
if (
    not resolved_pin_list
    or len(resolved_pin_list) != len(set(resolved_pin_list))
    or len(inventory_pin_list) != len(set(inventory_pin_list))
    or set(resolved_pin_list) != set(inventory_pin_list)
    or not set(engine_pin_list).issubset(set(resolved_pin_list))
    or any(not isinstance(name, str) or not name for name in checkout_directories)
    or len(checkout_directories) != len(set(checkout_directories))
):
    raise SystemExit("checkout inventory pins do not exactly match Package.resolved")
PY
plutil -lint "$RESOURCES/PrivacyInfo.xcprivacy" >/dev/null \
    || die "bundled privacy manifest is invalid"
[ "$(plutil -extract NSPrivacyTracking raw "$RESOURCES/PrivacyInfo.xcprivacy")" = "false" ] \
    || die "bundled privacy manifest unexpectedly declares tracking"

if [ "$VERIFY_UNSIGNED" -eq 1 ]; then
    [ "$(receipt_value UnsignedExecutableSHA256)" = "$(sha256_file "$EXECUTABLE")" ] \
        || die "unsigned executable does not match the release receipt"
    python3 "$TOOL_ROOT/tools/verify_runtime_payload.py" verify-inventory \
        --app "$APP" --inventory "$RUNTIME_PAYLOAD_INVENTORY" \
        --unsigned-executable-sha "$(receipt_value UnsignedExecutableSHA256)" --pre-sign
else
    command -v codesign >/dev/null 2>&1 || die "required command not found: codesign"
    codesign --verify --deep --strict "$APP"
    RUNTIME_ARGUMENTS=(
        verify-inventory
        --app "$APP"
        --inventory "$RUNTIME_PAYLOAD_INVENTORY"
        --unsigned-executable-sha "$(receipt_value UnsignedExecutableSHA256)"
    )
    if [ "$VERIFY_NOTARIZED" -eq 1 ]; then
        command -v xcrun >/dev/null 2>&1 || die "required command not found: xcrun"
        [ -s "$APP/Contents/CodeResources" ] \
            || die "notarized app has no non-empty stapled Contents/CodeResources ticket"
        [ ! -L "$APP/Contents/CodeResources" ] \
            || die "stapled notarization ticket must not be a symbolic link"
        xcrun stapler validate "$APP"
        RUNTIME_ARGUMENTS+=(--allow-stapled-ticket)
    fi
    python3 "$TOOL_ROOT/tools/verify_runtime_payload.py" "${RUNTIME_ARGUMENTS[@]}"
    python3 "$TOOL_ROOT/tools/verify_signed_entitlements.py" "$APP" "$SIGNING_ENTITLEMENTS"
fi

echo "✓ release receipt verified: $RECEIPT"
