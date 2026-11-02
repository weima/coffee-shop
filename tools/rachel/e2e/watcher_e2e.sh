#!/bin/sh
# End-to-end checks of the real rachel binary: build it, run it against
# temporary Odin projects, edit files, and assert the watcher reacts.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/rachel-e2e-XXXXXX")
bin="$work/rachel"
pid=""

cleanup() {
	stop_watcher
	rm -rf "$work"
}
trap cleanup EXIT INT TERM

stop_watcher() {
	[ -n "$pid" ] || return 0
	if kill -0 "$pid" 2>/dev/null; then
		# SIGTERM: a background job in a non-interactive shell ignores SIGINT.
		kill -TERM "$pid" 2>/dev/null || true
		i=0
		while [ "$i" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
			sleep 0.1
			i=$((i + 1))
		done
		if kill -0 "$pid" 2>/dev/null; then
			kill -KILL "$pid" 2>/dev/null || true
			fail "watcher did not exit within 3s"
		fi
	fi
	wait "$pid" 2>/dev/null || true
	pid=""
}

fail() {
	echo "FAIL: $1"
	echo "--- watcher output ---"
	cat "$log" 2>/dev/null || true
	exit 1
}

# grep -F: watcher messages contain [OK] and [WARN], which are regex syntax.
wait_for() {
	pattern=$1
	limit=$2
	i=0
	while [ "$i" -lt "$limit" ]; do
		grep -F -q -- "$pattern" "$log" 2>/dev/null && return 0
		sleep 0.1
		i=$((i + 1))
	done
	fail "timed out waiting for: $pattern"
}

start_watcher() {
	project=$1
	log="$work/$(basename "$project").log"
	"$bin" "$project" >"$log" 2>&1 &
	pid=$!
}

echo "building rachel"
odin build "$root/src" -out:"$bin" >"$work/build.log" 2>&1 || {
	cat "$work/build.log"
	exit 1
}

echo "scenario 1: project justfile, watch loop, contract warning, companion test"
project="$work/custom-justfile"
mkdir -p "$project"
printf 'check:\n    odin check -no-entry-point .\n\ntest:\n    TZ=UTC odin test .\n' >"$project/justfile"
cat >"$project/main.odin" <<'ODIN'
package demo

// add returns the sum of two integers.
add :: proc(a, b: int) -> int {
	return a + b
}
ODIN
start_watcher "$project"
wait_for '[OK] just check' 100

cat >>"$project/main.odin" <<'ODIN'

multiply :: proc(a, b: int) -> int {
	return a * b
}
ODIN
wait_for '[WARN] new procedure multiply' 100
wait_for 'Created companion test file' 100
wait_for '[OK] just test' 100

[ -f "$project/main_test.odin" ] || fail "companion test file was not created"
[ "$(grep -F -c 'Created companion test file' "$log")" -eq 1 ] ||
	fail "companion test file was recreated; the watcher is looping"
stop_watcher

echo "scenario 2: no justfile, starter justfile created and run"
project="$work/starter-justfile"
mkdir -p "$project"
cat >"$project/module.odin" <<'ODIN'
package demo

// twice returns n doubled.
twice :: proc(n: int) -> int {
	return n * 2
}
ODIN
start_watcher "$project"
wait_for 'Created default justfile' 100
wait_for '[OK] just check' 100

[ -f "$project/justfile" ] || fail "starter justfile was not created"
grep -F -q 'check package=' "$project/justfile" || fail "starter justfile has no check recipe"
grep -F -q 'test package=' "$project/justfile" || fail "starter justfile has no test recipe"
stop_watcher

echo "scenario 3: one-shot check narrows to a package and reports one line"
project="$work/one-shot"
mkdir -p "$project"
printf 'check:\n    odin check -no-entry-point .\n\ntest:\n    TZ=UTC odin test .\n' >"$project/justfile"
cat >"$project/module.odin" <<'ODIN'
package demo

// one returns 1.
one :: proc() -> int {
	return 1
}
ODIN
verdict=$("$bin" check "$project" 2>"$work/check-ok.err") || fail "one-shot check failed on valid code"
case "$verdict" in
"rachel: ok"*) ;;
*) fail "unexpected ok verdict: $verdict" ;;
esac

printf 'package demo\n\none :: proc() -> int {\n\treturn\n}\n' >"$project/module.odin"
if "$bin" check "$project" >"$work/check-fail.out" 2>"$work/check-fail.err"; then
	fail "one-shot check passed on invalid code"
fi
grep -F -q 'rachel: fail' "$work/check-fail.out" || fail "no fail verdict on invalid code"
grep -F -q 'module.odin' "$work/check-fail.out" || fail "fail verdict does not name the file"

verdict=$("$bin" check "$project" "$project/module.odin" 2>/dev/null || true)
case "$verdict" in
"rachel: fail"*) ;;
*) fail "unexpected narrowing verdict: $verdict" ;;
esac

echo "PASS: watch loop, contract warning, companion test creation, starter justfile, shutdown, and one-shot check"
