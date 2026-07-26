#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() {
    echo "error: $*" >&2
    exit 1
}

[ "$(uname -m)" = "arm64" ] || die "Twisterminigen tests require an Apple Silicon Mac"
for tool in xcodebuild swift python3 shasum awk mktemp; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool is unavailable: $tool"
done

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/twisterminigen-tests.XXXXXX")"
cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DERIVED="$TEST_ROOT/DerivedData"
ENGINE_SCRATCH="$TEST_ROOT/EngineTests"
APP_SCRATCH="$TEST_ROOT/AppTests"
ENGINE_MANIFEST="$ENGINE_SCRATCH/injected-metallibs.json"
APP_MANIFEST="$APP_SCRATCH/injected-metallibs.json"

echo "▸ Build Twisterminigen and the MLX Metal library with Xcode"
(
    cd "$ROOT/app/Twisterminigen"
    xcodebuild \
        -quiet \
        -skipPackagePluginValidation \
        -skipMacroValidation \
        -scheme Twisterminigen-Distribution \
        -destination 'platform=macOS,arch=arm64' \
        -configuration Debug \
        -derivedDataPath "$DERIVED" \
        COMPILATION_CACHE_ENABLE_CACHING=NO \
        SDK_STAT_CACHE_ENABLE=NO \
        build
)

echo "▸ Build Engine tests"
swift build \
    --package-path "$ROOT/engine/Krea2Engine" \
    --build-tests \
    --scratch-path "$ENGINE_SCRATCH" \
    --disable-automatic-resolution \
    --skip-update

echo "▸ Build application tests"
swift build \
    --package-path "$ROOT/app/Twisterminigen" \
    --build-tests \
    --scratch-path "$APP_SCRATCH" \
    --disable-automatic-resolution \
    --skip-update

METALLIB="$DERIVED/Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
[ -s "$METALLIB" ] || die "Xcode did not produce the MLX default.metallib"
[ ! -L "$METALLIB" ] || die "the Xcode MLX metallib must not be a symbolic link"
METALLIB_SHA="$(shasum -a 256 "$METALLIB" | awk '{print $1}')"

python3 "$ROOT/tools/install_test_metallib.py" install \
    --source "$METALLIB" \
    --scratch "$ENGINE_SCRATCH" \
    --manifest "$ENGINE_MANIFEST" \
    --expected-sha "$METALLIB_SHA"
python3 "$ROOT/tools/install_test_metallib.py" install \
    --source "$METALLIB" \
    --scratch "$APP_SCRATCH" \
    --manifest "$APP_MANIFEST" \
    --expected-sha "$METALLIB_SHA"

echo "▸ Run Engine tests"
swift test \
    --package-path "$ROOT/engine/Krea2Engine" \
    --skip-build \
    --scratch-path "$ENGINE_SCRATCH" \
    --disable-automatic-resolution \
    --skip-update

echo "▸ Run application tests"
swift test \
    --package-path "$ROOT/app/Twisterminigen" \
    --skip-build \
    --scratch-path "$APP_SCRATCH" \
    --disable-automatic-resolution \
    --skip-update

python3 "$ROOT/tools/install_test_metallib.py" verify \
    --scratch "$ENGINE_SCRATCH" \
    --manifest "$ENGINE_MANIFEST" \
    --expected-sha "$METALLIB_SHA"
python3 "$ROOT/tools/install_test_metallib.py" verify \
    --scratch "$APP_SCRATCH" \
    --manifest "$APP_MANIFEST" \
    --expected-sha "$METALLIB_SHA"

echo "✓ Twisterminigen Engine and application tests passed"
