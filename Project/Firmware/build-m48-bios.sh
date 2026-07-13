#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$script_dir/m48-bios.bin"}
forced_failure=${2:-0}
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/sector-zero-bios.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

case "$forced_failure" in
    0|1|2|3|6|all) ;;
    *)
        echo "forced POST failure must be 0, 1, 2, 3, 6, or all" >&2
        exit 2
        ;;
esac

if [ "$forced_failure" = all ]; then
    mkdir -p "$output"
    set --
    for component in 1 2 3 6; do
        object="$temporary_dir/m48-bios-$component.o"
        binary="$output/m48-bios-failure-$component.bin"
        xcrun clang -target i386-apple-macos10.6 -c \
            -Wa,-defsym,FORCE_POST_FAILURE="$component" \
            "$script_dir/m48-bios.s" \
            -o "$object"
        set -- "$@" "$object" "$binary"
    done
    xcrun swift -module-cache-path "$temporary_dir/module-cache" \
        "$script_dir/extract-mach-o-text.swift" "$@"
    for binary in "$output"/*.bin; do
        byte_count=$(wc -c < "$binary" | tr -d ' ')
        if [ "$byte_count" -ne 65536 ]; then
            echo "M48 BIOS must be exactly 65536 bytes; got $byte_count" >&2
            exit 1
        fi
    done
    exit 0
fi

xcrun clang -target i386-apple-macos10.6 -c \
    -Wa,-defsym,FORCE_POST_FAILURE="$forced_failure" \
    "$script_dir/m48-bios.s" \
    -o "$temporary_dir/m48-bios.o"
xcrun swift -module-cache-path "$temporary_dir/module-cache" \
    "$script_dir/extract-mach-o-text.swift" \
    "$temporary_dir/m48-bios.o" \
    "$output"

byte_count=$(wc -c < "$output" | tr -d ' ')
if [ "$byte_count" -ne 65536 ]; then
    echo "M48 BIOS must be exactly 65536 bytes; got $byte_count" >&2
    exit 1
fi
