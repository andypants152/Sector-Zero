#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
artifact=${1:-reset-smoke}
output=${2:-"$script_dir/$artifact.bin"}
variant=${3:-default}
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/sector-zero-diagnostic.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM
developer_dir=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}
toolchain_bin="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
clang="$toolchain_bin/clang"
swift="$toolchain_bin/swift"
macos_sdk="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

case "$artifact" in
    reset-smoke) expected_size=512 ;;
    platform-diagnostic) expected_size=65536 ;;
    *)
        echo "unknown diagnostic firmware artifact: $artifact" >&2
        exit 2
        ;;
esac

case "$artifact:$variant" in
    reset-smoke:default) assembler_flags="-Wa,-defsym,FORCE_ROM_WRITE=0" ;;
    reset-smoke:rom-write) assembler_flags="-Wa,-defsym,FORCE_ROM_WRITE=1" ;;
    platform-diagnostic:default) assembler_flags="" ;;
    *)
        echo "unknown $artifact variant: $variant" >&2
        exit 2
        ;;
esac

if [ ! -x "$clang" ] || [ ! -x "$swift" ] || [ ! -d "$macos_sdk" ]; then
    echo "Xcode default toolchain not found under $developer_dir" >&2
    exit 1
fi

"$clang" -target i386-apple-macos10.6 -c -I "$script_dir" \
    $assembler_flags "$script_dir/$artifact.s" \
    -o "$temporary_dir/$artifact.o"
"$swift" -sdk "$macos_sdk" \
    -module-cache-path "$temporary_dir/module-cache" \
    "$script_dir/extract-mach-o-text.swift" \
    "$temporary_dir/$artifact.o" \
    "$output"

byte_count=$(wc -c < "$output" | tr -d ' ')
if [ "$byte_count" -ne "$expected_size" ]; then
    echo "$artifact must be exactly $expected_size bytes; got $byte_count" >&2
    exit 1
fi
