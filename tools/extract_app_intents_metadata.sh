#!/bin/bash
# Produce the Metadata.appintents bundle that a manually packaged SwiftPM executable does not
# receive automatically. Xcode emits the required *.swiftconstvalues during xcodebuild; this step
# runs Apple's metadata processor over those exact Release/Debug products.
set -euo pipefail

CONFIG="${1:?configuration required}"
DERIVED="${2:?derived-data path required}"
OUTPUT_ROOT="${3:?output directory required}"

case "$CONFIG" in
    Debug|Release) ;;
    *) echo "error: configuration must be Debug or Release" >&2; exit 2 ;;
esac

ARCH="arm64"
BUILD_DIR="$DERIVED/Build/Intermediates.noindex/Twisterminigen.build/$CONFIG/Twisterminigen.build"
OBJECTS="$BUILD_DIR/Objects-normal/$ARCH"
SOURCE_LIST="$OBJECTS/Twisterminigen.SwiftFileList"
DEPENDENCY_LIST="$BUILD_DIR/Twisterminigen.DependencyMetadataFileList"
STATIC_DEPENDENCY_LIST="$BUILD_DIR/Twisterminigen.DependencyStaticMetadataFileList"

[ -s "$SOURCE_LIST" ] || { echo "error: missing Swift source list: $SOURCE_LIST" >&2; exit 3; }
[ -f "$DEPENDENCY_LIST" ] || { echo "error: missing dependency metadata list" >&2; exit 3; }
[ -f "$STATIC_DEPENDENCY_LIST" ] || { echo "error: missing static metadata list" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/twister-appintents.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CONST_VALUES_LIST="$WORK/Twisterminigen.SwiftConstValuesFileList"
find "$OBJECTS" -maxdepth 1 -type f -name '*.swiftconstvalues' -print \
    | LC_ALL=C sort > "$CONST_VALUES_LIST"
[ -s "$CONST_VALUES_LIST" ] || { echo "error: Xcode emitted no Swift const-value metadata" >&2; exit 3; }

DEVELOPER_DIR="$(xcode-select -p)"
TOOLCHAIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
XCODE_BUILD_VERSION="$(xcodebuild -version | sed -n 's/^Build version //p')"
[ -n "$XCODE_BUILD_VERSION" ] || { echo "error: cannot read Xcode build version" >&2; exit 3; }

rm -rf "$OUTPUT_ROOT/Metadata.appintents"
mkdir -p "$OUTPUT_ROOT"
xcrun appintentsmetadataprocessor \
    --output "$OUTPUT_ROOT" \
    --toolchain-dir "$TOOLCHAIN" \
    --module-name Twisterminigen \
    --sdk-root "$SDK_ROOT" \
    --xcode-version "$XCODE_BUILD_VERSION" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --target-triple "$ARCH-apple-macos14.0" \
    --source-file-list "$SOURCE_LIST" \
    --swift-const-vals-list "$CONST_VALUES_LIST" \
    --metadata-file-list "$DEPENDENCY_LIST" \
    --static-metadata-file-list "$STATIC_DEPENDENCY_LIST" \
    --force

[ -s "$OUTPUT_ROOT/Metadata.appintents/extract.actionsdata" ] || {
    echo "error: App Intents metadata processor produced no actions data" >&2
    exit 4
}
