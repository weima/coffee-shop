#!/bin/sh
# Two-Station end-to-end check: one Station types Odin code at human speed into
# a shared checkout, another Station runs Rachel on that same checkout, and the
# driver reports what Rachel said while the file was half-typed.
#
# Both Stations must share one worktree; the driver asserts that.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
rachel_root=$(cd "$here/.." && pwd)
worktree=$(git -C "$rachel_root" rev-parse --show-toplevel)
run="$worktree/.scratch/rachel-typing-e2e.$$"
project="$run/project"
bin="$run/rachel"
typist_dir="$run/station-typist"
rachel_dir="$run/station-rachel"
rachel_log="$rachel_dir/rachel.log"
rachel_pid=""

stop_rachel() {
	[ -n "$rachel_pid" ] || return 0
	if kill -0 "$rachel_pid" 2>/dev/null; then
		# SIGTERM: a background job in a non-interactive shell ignores SIGINT.
		kill -TERM "$rachel_pid" 2>/dev/null || true
		i=0
		while [ "$i" -lt 50 ] && kill -0 "$rachel_pid" 2>/dev/null; do
			sleep 0.1
			i=$((i + 1))
		done
		kill -KILL "$rachel_pid" 2>/dev/null || true
	fi
	wait "$rachel_pid" 2>/dev/null || true
	rachel_pid=""
}

cleanup() {
	stop_rachel
	rm -rf "$run"
}
trap cleanup EXIT INT TERM

fail() {
	echo "FAIL: $1"
	echo "--- rachel output (tail) ---"
	tail -30 "$rachel_log" 2>/dev/null || true
	exit 1
}

wait_for() {
	pattern=$1
	limit=$2
	i=0
	while [ "$i" -lt "$limit" ]; do
		grep -F -q -- "$pattern" "$rachel_log" 2>/dev/null && return 0
		sleep 0.1
		i=$((i + 1))
	done
	fail "timed out waiting for: $pattern"
}

mkdir -p "$project" "$typist_dir" "$rachel_dir"
printf 'check:\n    odin check -no-entry-point .\n\ntest:\n    TZ=UTC odin test .\n' >"$project/justfile"
printf 'package demo\n' >"$project/dummy.odin"

cat >"$run/payload.odin" <<'ODIN'

// add returns the sum of two integers.
add :: proc(a, b: int) -> int {
	return a + b
}

// double returns n doubled.
double :: proc(n: int) -> int {
	return n * 2
}
ODIN

echo "building rachel"
odin build "$rachel_root/src" -out:"$bin" >"$run/build.log" 2>&1 || {
	cat "$run/build.log"
	exit 1
}

echo "station 1: rachel watching $project"
"$here/stations/rachel_station.sh" "$rachel_dir" "$project" "$bin" >"$rachel_dir/out.log" 2>&1 &
rachel_pid=$!
wait_for 'Watching' 300

echo "station 2: typist writing dummy.odin at human speed"
"$here/stations/typist.sh" "$typist_dir" "$project" "$run/payload.odin" >"$typist_dir/out.log" 2>&1

echo "waiting for the last debounced check"
sleep 2
stop_rachel

[ -f "$typist_dir/worktree" ] || fail "typist station did not record its worktree"
[ -f "$rachel_dir/worktree" ] || fail "rachel station did not record its worktree"
typist_worktree=$(cat "$typist_dir/worktree")
rachel_worktree=$(cat "$rachel_dir/worktree")
[ "$typist_worktree" = "$rachel_worktree" ] ||
	fail "Stations are on different worktrees: $typist_worktree vs $rachel_worktree"
[ "$typist_worktree" = "$worktree" ] ||
	fail "Stations are not on the expected worktree: $typist_worktree vs $worktree"

checks=$(grep -c -E '^\[(OK|ERROR)\] just check' "$rachel_log" || true)
failed=$(grep -c -F '[ERROR] just check failed' "$rachel_log" || true)
warnings=$(grep -c -F '[WARN]' "$rachel_log" || true)
last_check=$(grep -E '^\[(OK|ERROR)\] just check' "$rachel_log" | tail -1)

echo
echo "=== what Rachel saw while the file was being typed ==="
echo "worktree:       $worktree"
echo "check runs:     $checks"
echo "failed checks:  $failed"
echo "warnings:       $warnings"
echo "last check:     ${last_check:-none}"

diagnostics=$(grep -E 'Error:|error:' "$rachel_log" | sed "s|$project/||; s/^[[:space:]]*//" | sort -u | head -5 || true)
if [ -n "$diagnostics" ]; then
	echo "distinct diagnostics:"
	printf '%s\n' "$diagnostics" | sed 's/^/  /'
fi

echo
echo "=== advice ==="
[ "$checks" -ge 1 ] || fail "Rachel never ran a check; the harness is broken"
[ -f "$project/dummy_test.odin" ] || fail "Rachel did not create the companion test file"

case "$last_check" in
\[OK\]*)
	if [ "$failed" -gt 0 ]; then
		echo "The file compiles now. Rachel reported $failed failed check(s) while the code"
		echo "was half-typed. The 350 ms pause is one fixed wait, not a quiet window that"
		echo "restarts per edit, so at roughly 11 characters per second Rachel still checks a"
		echo "partial line. Expect this noise while typing. Restarting the quiet window on"
		echo "each change, or widening it, would cut the noise without changing the result."
	else
		echo "The file compiles and Rachel never checked a broken state: the 350 ms quiet"
		echo "window held throughout typing, so partial lines were not sampled. That is the"
		echo "intended behaviour. A pause longer than 350 ms mid-edit still triggers a check."
	fi
	;;
*)
	echo "The file still does not compile after typing finished. Rachel is reporting a real"
	echo "failure, not typing noise: read the diagnostics above and fix the source."
	fail "final check did not pass"
	;;
esac

echo
echo "PASS: two Stations shared $worktree; Rachel ran $checks check(s) and the final state is green"
