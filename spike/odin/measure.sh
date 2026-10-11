#!/bin/sh
# Footprint floor for an Odin program, at the same N values as the pi baseline.
# Method: macOS `footprint -f bytes -p <pid>`, total "Footprint: N B" line, in MB (2^20 B).
# Available memory: (free + inactive pages) x 16384 from vm_stat.
# Limits: at most 50 measured children (one growing run), each started after a vm_stat
# check against a 2.0 GB guard, with a 0.3 s pause. Every process started is killed on exit.
# See README.md for the run, the table format, and the caveats.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/odin-footprint.XXXXXX") || exit 1
BIN="$WORK/sessions"
PAGE=16384
GUARD_BYTES=2147483648   # 2.0 GiB
MAX_CHILDREN=50
PAUSE=0.3
SETTLE=1
HOLD=15                  # idle and in-process hold, seconds (task spec)
CHILD_HOLD=60            # growing child run: must outlive the 10, 25, 50 steps (README)
PIDS=""                  # every process started and not yet killed
SEQ=0
SINGLES=0                # idle and in-process programs started (not counted as children)
CHILDREN=0               # child processes started in the growing run
STOPPED=0
FLOOR_BYTES=0
AVAIL=0
FP=0
LAST_PID=0

fail() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
	for p in $PIDS; do kill "$p" 2>/dev/null; done
	for p in $PIDS; do wait "$p" 2>/dev/null; done
	PIDS=""
	rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# Free + inactive bytes, from vm_stat. Dies if the page size is not 16384.
read_avail() {
	AVAIL=$(vm_stat | awk -v want="$PAGE" '
		/page size of/ { if ($8 + 0 != want) bad = 1 }
		/^Pages free:/ { f = $3; sub(/\./, "", f) }
		/^Pages inactive:/ { i = $3; sub(/\./, "", i) }
		END { if (bad || f == "" || i == "") exit 1; printf "%.0f", (f + i) * want }') || AVAIL=""
	[ -n "$AVAIL" ] || fail "vm_stat parse failed"
}

# Total physical footprint of one pid, in bytes.
read_footprint() {
	FP=$(footprint -f bytes -p "$1" 2>/dev/null | sed -n 's/.*Footprint: \([0-9][0-9]*\) B.*/\1/p' | head -1)
	[ -n "$FP" ] || fail "footprint gave no total line for pid $1"
}

gb() { awk -v b="$1" 'BEGIN { printf "%.2f", b / 1073741824 }'; }
mb() { awk -v b="$1" 'BEGIN { printf "%.2f", b / 1048576 }'; }
below_guard() { awk -v b="$1" -v g="$GUARD_BYTES" 'BEGIN { exit !(b < g) }'; }

# Starts "$BIN" with the given arguments in the background, and waits for its ready line.
# Sets LAST_PID. The pid in the ready line must equal $!.
start() {
	SEQ=$((SEQ + 1))
	out="$WORK/out.$SEQ"
	"$BIN" "$@" >"$out" 2>&1 &
	pid=$!
	PIDS="$PIDS $pid"
	tries=0
	until grep -q ready "$out" 2>/dev/null; do
		tries=$((tries + 1))
		[ "$tries" -le 100 ] || fail "pid $pid not ready after 10 s"
		kill -0 "$pid" 2>/dev/null || fail "pid $pid exited before it was ready"
		sleep 0.1
	done
	reported=$(sed -n 's/^pid \([0-9][0-9]*\) ready.*/\1/p' "$out" | head -1)
	[ "$reported" = "$pid" ] || fail "pid mismatch: started $pid, reported $reported"
	LAST_PID=$pid
}

# Kills every process this script started, and waits for each to exit.
stop_all() {
	for p in $PIDS; do kill "$p" 2>/dev/null; done
	for p in $PIDS; do wait "$p" 2>/dev/null; done
	PIDS=""
}

echo "building sessions"
odin build "$HERE" -out:"$BIN" || fail "odin build failed"

# Table A1: bare floor, one process, nothing held.
read_avail; before=$AVAIL
start idle; pid=$LAST_PID; SINGLES=$((SINGLES + 1))
sleep $SETTLE
read_footprint "$pid"; FLOOR_BYTES=$FP
stop_all
read_avail; after=$AVAIL
printf 'A floor idle pid=%s footprint_MB=%s avail_before_GB=%s avail_after_GB=%s\n' \
	"$pid" "$(mb "$FLOOR_BYTES")" "$(gb "$before")" "$(gb "$after")"

# Table A2: in-process N sessions, ONE process per N.
for n in 10 50 100; do
	read_avail; before=$AVAIL
	start in-process "$n"; pid=$LAST_PID; SINGLES=$((SINGLES + 1))
	sleep $SETTLE
	read_footprint "$pid"; fp=$FP
	stop_all
	read_avail; after=$AVAIL
	per=$(awk -v f="$fp" -v z="$FLOOR_BYTES" -v n="$n" 'BEGIN { printf "%.3f", (f - z) / n / 1048576 }')
	printf 'A in-process N=%s pid=%s footprint_MB=%s per_session_MB=%s avail_before_GB=%s avail_after_GB=%s\n' \
		"$n" "$pid" "$(mb "$fp")" "$per" "$(gb "$before")" "$(gb "$after")"
done

# Table B: one child per session. One growing run: 10, then 25, then 50 children alive.
# Each step measures every child alive at that point. The guard is checked before each start.
for target in 10 25 50; do
	read_avail; before=$AVAIL
	while [ "$CHILDREN" -lt "$target" ]; do
		[ "$CHILDREN" -lt "$MAX_CHILDREN" ] || fail "child cap of $MAX_CHILDREN reached"
		read_avail
		if below_guard "$AVAIL"; then
			echo "B guard: available $(gb "$AVAIL") GB is below 2.00 GB; no child $((CHILDREN + 1)) started"
			STOPPED=1
			break
		fi
		start child "$CHILD_HOLD"
		CHILDREN=$((CHILDREN + 1))
		sleep $PAUSE
	done
	sleep $SETTLE
	sizes=""
	for p in $PIDS; do
		read_footprint "$p"
		sizes="$sizes $FP"
	done
	read -r total avg count <<EOF
$(echo $sizes | awk '{ for (i = 1; i <= NF; i++) s += $i; if (NF) printf "%.2f %.2f %d", s / 1048576, s / 1048576 / NF, NF; else print "0 0 0" }')
EOF
	read_avail; after=$AVAIL
	printf 'B target=%s reached=%s footprint_total_MB=%s footprint_avg_MB=%s avail_before_GB=%s avail_after_GB=%s stopped_early=%s\n' \
		"$target" "$count" "$total" "$avg" "$(gb "$before")" "$(gb "$after")" "$([ "$STOPPED" -eq 1 ] && echo yes || echo no)"
	[ "$STOPPED" -eq 0 ] || break
done

stop_all
read_avail
printf 'summary children_started=%s cap=%s single_programs_started=%s avail_after_cleanup_GB=%s\n' \
	"$CHILDREN" "$MAX_CHILDREN" "$SINGLES" "$(gb "$AVAIL")"

left=$(pgrep -f "$BIN" || true)
[ -z "$left" ] || fail "processes still running after cleanup: $left"
echo "check: no sessions process left (pgrep empty)"
