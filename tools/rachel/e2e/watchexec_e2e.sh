#!/bin/sh
# Drives `rachel check --from-env` from a real watchexec run.
# Skips (exit 0) when watchexec is not installed.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/rachel-wx-e2e-XXXXXX")
project="$work/project"
bin="$work/rachel"
log="$work/watch.log"
pid=""

cleanup() {
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		kill -TERM "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	fi
	rm -rf "$work"
}
trap cleanup EXIT INT TERM

if ! command -v watchexec >/dev/null 2>&1; then
	echo "SKIP: watchexec is not installed"
	exit 0
fi

fail() {
	echo "FAIL: $1"
	echo "--- watcher output ---"
	cat "$log" 2>/dev/null || true
	exit 1
}

# waits until the pattern appears at least $2 times
wait_for_count() {
	pattern=$1
	wanted=$2
	limit=${3:-150}
	i=0
	while [ "$i" -lt "$limit" ]; do
		[ "$(grep -F -c -- "$pattern" "$log" 2>/dev/null || true)" -ge "$wanted" ] && return 0
		sleep 0.1
		i=$((i + 1))
	done
	fail "timed out waiting for $wanted occurrence(s) of: $pattern"
}

echo "building rachel"
odin build "$root/src" -out:"$bin" >"$work/build.log" 2>&1 || {
	cat "$work/build.log"
	exit 1
}

# No justfile: Rachel generates one, which takes a package argument, so a narrowed
# check reports fewer packages than a whole-project check.
mkdir -p "$project/sub"
cat >"$project/module.odin" <<'ODIN'
package demo

// one returns 1.
one :: proc() -> int {
	return 1
}
ODIN
cat >"$project/sub/other.odin" <<'ODIN'
package sub

// two returns 2.
two :: proc() -> int {
	return 2
}
ODIN

echo "starting watchexec with the filter and the 300ms debounce"
(
	cd "$project" && exec watchexec -d 300ms -f '*.odin' --emit-events-to=environment -- \
		"$bin" check --from-env "$project"
) >"$log" 2>&1 &
pid=$!
wait_for_count 'rachel: ok (2 checked)' 1

echo "breaking sub/other.odin"
printf 'package sub\n\ntwo :: proc() -> int {\n\treturn\n}\n' >"$project/sub/other.odin"
# A narrowed check reports 1 of 1; a whole-project check would report 1 of 2.
wait_for_count 'rachel: fail (1 of 1)' 1
grep -F -q 'sub/other.odin' "$log" || fail "fail verdict does not name the changed file"

echo "fixing sub/other.odin"
cat >"$project/sub/other.odin" <<'ODIN'
package sub

// two returns 2.
two :: proc() -> int {
	return 2
}
ODIN
wait_for_count 'rachel: ok (1 checked)' 1

runs=$(grep -F -c 'rachel: ' "$log" || true)
[ "$runs" -le 12 ] || fail "watcher ran $runs times; it is looping on its own output"

echo "stopping watcher"
kill -TERM "$pid"
i=0
while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
	sleep 0.1
	i=$((i + 1))
done
kill -0 "$pid" 2>/dev/null && fail "watcher ignored SIGTERM"
wait "$pid" 2>/dev/null || true
pid=""

echo "PASS: watchexec batches reached rachel check --from-env; ok -> fail -> ok in $runs runs"
