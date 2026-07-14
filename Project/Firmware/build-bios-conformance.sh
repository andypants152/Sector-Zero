#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$script_dir/bios-conformance.img"}
variant=${2:-default}
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/sector-zero-conformance.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM
developer_dir=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}
toolchain_bin="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
clang="$toolchain_bin/clang"
swift="$toolchain_bin/swift"
macos_sdk="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

case "$variant" in
    default) failure=0 ;;
    failure) failure=1 ;;
    *)
        echo "variant must be default or failure" >&2
        exit 2
        ;;
esac

"$clang" -target i386-apple-macos10.6 -c -I "$script_dir" \
    -Wa,-defsym,FORCE_CONFORMANCE_FAILURE="$failure" \
    "$script_dir/bios-conformance.s" \
    -o "$temporary_dir/bios-conformance.o"
"$swift" -sdk "$macos_sdk" \
    -module-cache-path "$temporary_dir/module-cache" \
    "$script_dir/extract-mach-o-text.swift" \
    "$temporary_dir/bios-conformance.o" \
    "$output"

byte_count=$(wc -c < "$output" | tr -d ' ')
if [ "$byte_count" -ne 1474560 ]; then
    echo "BIOS conformance image must be exactly 1474560 bytes; got $byte_count" >&2
    exit 1
fi
