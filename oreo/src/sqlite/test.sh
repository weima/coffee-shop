#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/oreo-sqlite.XXXXXX")
cleanup() {
	rm -rf "$build_dir"
}
trap cleanup EXIT

cc -O2 \
	-DSQLITE_THREADSAFE=1 \
	-DSQLITE_OMIT_LOAD_EXTENSION \
	-c "$script_dir/vendor/sqlite3.c" \
	-o "$build_dir/sqlite3.o"

TZ=UTC odin test "$script_dir" -extra-linker-flags:"$build_dir/sqlite3.o"
