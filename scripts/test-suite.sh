#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if ! git_common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null); then
    echo "Cannot locate the Git common directory for the Coffee Shop test lock." >&2
    exit 1
fi
case "$git_common" in
    /*) ;;
    *) git_common="$repo/$git_common" ;;
esac
git_common=$(CDPATH= cd -- "$git_common" && pwd -P)
lock_dir="$git_common/.coffee-shop-test.lock"

# Wait for the lock: the suite takes ~35s, and a Pull's Taste shares this lock,
# so a false failure costs more than a wait. 300s covers several queued suites.
wait_secs=${COFFEE_SHOP_TEST_LOCK_TIMEOUT:-300}
case "$wait_secs" in
    ''|*[!0-9]*) echo "COFFEE_SHOP_TEST_LOCK_TIMEOUT must be whole seconds." >&2; exit 1 ;;
esac
ticks=$((wait_secs * 10))
waited=0
nopid=0

# Start time of a pid, empty if it does not exist. A pid plus its start time
# names one process: a reused pid starts at a different time.
proc_start() {
    LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' ' ' | sed 's/^ //;s/ $//'
}

# True when the recorded holder is gone: no such pid, or the pid now belongs to
# a process with a different start time (pid reuse). A lock with no pid file is
# a holder between mkdir and its first write; only 2s of it counts as dead.
holder_is_dead() {
    h_pid=$(cat "$lock_dir/pid" 2>/dev/null || :)
    if [ -z "$h_pid" ]; then
        nopid=$((nopid + 1))
        [ "$nopid" -ge 20 ]
        return
    fi
    nopid=0
    h_start=$(cat "$lock_dir/start" 2>/dev/null || :)
    now_start=$(proc_start "$h_pid")
    [ -z "$now_start" ] && return 0
    # No recorded start (lock from an older script): a live pid is trusted.
    [ -n "$h_start" ] && [ "$now_start" != "$h_start" ]
}

# Move the dead holder's lock aside atomically (rename), so two reclaimers
# cannot both delete it. If what we moved is not the holder we judged dead,
# a live suite re-locked meanwhile: put it back instead of deleting it.
reclaim() {
    stale="$lock_dir.stale.$$"
    mv "$lock_dir" "$stale" 2>/dev/null || return 0
    if [ "$(cat "$stale/pid" 2>/dev/null || :)" = "$h_pid" ]; then
        rm -rf "$stale"
    else
        mv "$stale" "$lock_dir" 2>/dev/null || rm -rf "$stale"
    fi
}

while ! mkdir "$lock_dir" 2>/dev/null; do
    owner=$(cat "$lock_dir/pid" 2>/dev/null || printf unknown)
    if holder_is_dead; then
        printf 'Reclaiming the Coffee Shop test lock from dead PID %s.\n' "$owner" >&2
        reclaim
        nopid=0
        continue
    fi
    if [ "$waited" -ge "$ticks" ]; then
        printf 'Another Coffee Shop test suite is running (PID %s; lock: %s). Timed out after %ss waiting for it. If no suite is running, remove the stale lock directory.\n' "$owner" "$lock_dir" "$wait_secs" >&2
        exit 1
    fi
    if [ "$waited" -eq 0 ]; then
        printf 'Waiting up to %ss for the Coffee Shop test suite held by PID %s (lock: %s).\n' "$wait_secs" "$owner" "$lock_dir" >&2
    fi
    waited=$((waited + 1))
    sleep 0.1
done

build_dir=
runner_pid=
cleanup() {
    if [ -n "$build_dir" ]; then rm -rf "$build_dir"; fi
    owner=$(cat "$lock_dir/pid" 2>/dev/null || :)
    if [ "$owner" = "$$" ]; then
        rm -f "$lock_dir/pid" "$lock_dir/start"
        rmdir "$lock_dir" 2>/dev/null || :
    fi
}
trap cleanup 0
handle_signal() {
    signal=$1
    status=$2
    if [ -n "$runner_pid" ]; then
        kill -TERM "$runner_pid" 2>/dev/null || :
        wait "$runner_pid" 2>/dev/null || :
        runner_pid=
    fi
    exit "$status"
}
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM
proc_start "$$" >"$lock_dir/start"
printf '%s\n' "$$" >"$lock_dir/pid"

cd "$repo"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/coffee-shop-test.XXXXXX")
TZ=UTC odin test src -out:"$build_dir/src.bin" -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true &
runner_pid=$!
if wait "$runner_pid"; then
    runner_pid=
else
    status=$?
    runner_pid=
    exit "$status"
fi
