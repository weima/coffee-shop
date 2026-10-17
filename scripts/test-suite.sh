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
while ! mkdir "$lock_dir" 2>/dev/null; do
    owner=$(cat "$lock_dir/pid" 2>/dev/null || printf unknown)
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
        rm -f "$lock_dir/pid"
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
