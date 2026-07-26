#!/bin/bash
# Fail closed when a distribution executable contains LLVM coverage instrumentation or when a
# release output tree contains runtime profile residue.
set -euo pipefail

die() {
    echo "error: $*" >&2
    exit 1
}

[ "$#" -ge 1 ] || die "usage: verify_release_coverage.sh EXECUTABLE [OUTPUT_ROOT ...]"
EXECUTABLE="$1"
shift

[ -f "$EXECUTABLE" ] && [ ! -L "$EXECUTABLE" ] \
    || die "distribution executable must be a regular non-symlink file: $EXECUTABLE"
command -v otool >/dev/null 2>&1 || die "required command not found: otool"
command -v find >/dev/null 2>&1 || die "required command not found: find"
command -v grep >/dev/null 2>&1 || die "required command not found: grep"

MACHO_LAYOUT="$(otool -l "$EXECUTABLE")" \
    || die "cannot inspect distribution executable: $EXECUTABLE"
if grep -Eq '^[[:space:]]*(segname __LLVM_COV|sectname __llvm_prf_[A-Za-z0-9_]*)$' \
    <<<"$MACHO_LAYOUT"; then
    die "distribution executable contains LLVM coverage/profile sections: $EXECUTABLE"
fi

for output_root in "$@"; do
    [ -e "$output_root" ] || die "coverage output root does not exist: $output_root"
    [ ! -L "$output_root" ] || die "coverage output root must not be a symlink: $output_root"
    PROFILE_RESIDUE="$(find "$output_root" -type f \
        \( -name 'default.profraw' -o -name '*.profraw' \) -print -quit)" \
        || die "cannot scan release output tree for profile residue: $output_root"
    [ -z "$PROFILE_RESIDUE" ] \
        || die "release output tree contains profile residue: $PROFILE_RESIDUE"
done

echo "✓ coverage-free distribution executable: $EXECUTABLE"
