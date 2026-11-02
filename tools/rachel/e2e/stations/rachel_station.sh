#!/bin/sh
# Station "rachel": runs the real Rachel binary against the shared checkout and
# keeps her output for the driver to analyse.
#
# Usage: rachel_station.sh <station-dir> <project-dir> <rachel-binary>
set -eu

dir=$1
project=$2
bin=$3

mkdir -p "$dir"
# Same worktree check as the typist Station: Rachel only sees what is written here.
git -C "$project" rev-parse --show-toplevel >"$dir/worktree"

echo "[rachel] station up in $(cat "$dir/worktree")"

pid=""
stop() {
	if [ -n "$pid" ]; then
		kill -TERM "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
		pid=""
	fi
}
trap 'stop; exit 0' TERM INT
trap stop EXIT

"$bin" "$project" >"$dir/rachel.log" 2>&1 &
pid=$!
wait "$pid" || true
pid=""
