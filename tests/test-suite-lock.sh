#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/coffee-shop-suite-lock.XXXXXX")
trap 'rm -rf "$tmp"' 0
trap 'exit 1' HUP INT TERM

mkdir "$tmp/bin"
cat >"$tmp/bin/odin" <<'ODIN'
#!/bin/sh
: "${ODIN_STARTED:?}"
: "${ODIN_RELEASE:?}"
: "${ODIN_STATUS:?}"
: "${ODIN_PID_FILE:?}"
: "${ODIN_FINISHED:?}"
: "${ODIN_SIGNAL:?}"
printf '%s\n' "$$" >"$ODIN_PID_FILE"
trap 'printf finished >"$ODIN_FINISHED"' 0
trap 'printf HUP >"$ODIN_SIGNAL"; exit 129' HUP
trap 'printf INT >"$ODIN_SIGNAL"; exit 130' INT
trap 'printf TERM >"$ODIN_SIGNAL"; exit 143' TERM
printf 'started\n' >>"$ODIN_STARTED"
if [ "$ODIN_STATUS" -eq 0 ]; then
    while [ ! -e "$ODIN_RELEASE" ]; do sleep 0.02; done
fi
exit "$ODIN_STATUS"
ODIN
chmod +x "$tmp/bin/odin"

mkdir -p "$tmp/repo/scripts"
cp "$repo/scripts/test-suite.sh" "$tmp/repo/scripts/test-suite.sh"
git -C "$tmp/repo" init -q
git -C "$tmp/repo" -c user.name=test -c user.email=test@example.com add scripts/test-suite.sh
git -C "$tmp/repo" -c user.name=test -c user.email=test@example.com commit -qm test
git -C "$tmp/repo" worktree add -q "$tmp/other" -b other

common=$(git -C "$tmp/repo" rev-parse --git-common-dir)
case "$common" in
    /*) ;;
    *) common="$tmp/repo/$common" ;;
esac
common=$(CDPATH= cd -- "$common" && pwd -P)
lock="$common/.coffee-shop-test.lock"
export PATH="$tmp/bin:$PATH"
export ODIN_STARTED="$tmp/started" ODIN_RELEASE="$tmp/release" ODIN_STATUS=0
export ODIN_PID_FILE="$tmp/runner.pid" ODIN_FINISHED="$tmp/runner.finished" ODIN_SIGNAL="$tmp/runner.signal"

(cd "$tmp/repo" && sh scripts/test-suite.sh) &
first=$!
tries=0
while [ ! -e "$ODIN_STARTED" ]; do
    tries=$((tries + 1))
    if [ "$tries" -ge 100 ]; then
        echo "first test suite did not start" >&2
        exit 1
    fi
    sleep 0.02
done

holder=$(cat "$lock/pid")
if (cd "$tmp/other" && COFFEE_SHOP_TEST_LOCK_TIMEOUT=1 sh scripts/test-suite.sh) >"$tmp/second.out" 2>&1; then
    echo "second concurrent suite unexpectedly succeeded" >&2
    exit 1
fi
for want in 'another Coffee Shop test suite is running' "PID $holder" "$lock" 'timed out'; do
    if ! grep -qiF "$want" "$tmp/second.out"; then
        cat "$tmp/second.out" >&2
        echo "timed-out suite did not report: $want" >&2
        exit 1
    fi
done
[ -d "$lock" ] || { echo "first suite lost its lock" >&2; exit 1; }
[ "$(wc -l <"$ODIN_STARTED")" -eq 1 ] || { echo "more than one underlying test runner started" >&2; exit 1; }
# A waiting second suite must run once the first finishes.
(cd "$tmp/other" && COFFEE_SHOP_TEST_LOCK_TIMEOUT=30 sh scripts/test-suite.sh) >"$tmp/waiter.out" 2>&1 &
waiter=$!
sleep 0.5
kill -0 "$waiter" 2>/dev/null || { echo "waiting suite did not wait" >&2; exit 1; }
[ "$(wc -l <"$ODIN_STARTED")" -eq 1 ] || { echo "waiter ran while the lock was held" >&2; exit 1; }
printf release >"$ODIN_RELEASE"
wait "$first"
wait "$waiter" || { cat "$tmp/waiter.out" >&2; echo "waiting suite failed after the lock freed" >&2; exit 1; }
[ "$(wc -l <"$ODIN_STARTED")" -eq 2 ] || { echo "waiting suite never ran its tests" >&2; exit 1; }
[ ! -e "$lock" ] || { echo "successful suite left its lock" >&2; exit 1; }

rm -f "$ODIN_STARTED" "$ODIN_RELEASE"
ODIN_STATUS=23
export ODIN_STATUS
if (cd "$tmp/repo" && sh scripts/test-suite.sh) >/dev/null 2>&1; then
    echo "failing suite unexpectedly succeeded" >&2
    exit 1
fi
[ ! -e "$lock" ] || { echo "failed suite left its lock" >&2; exit 1; }

rm -f "$ODIN_STARTED" "$ODIN_RELEASE"
ODIN_STATUS=0
export ODIN_STATUS
for signal in HUP INT TERM; do
    rm -f "$ODIN_STARTED" "$ODIN_RELEASE" "$ODIN_PID_FILE" "$ODIN_FINISHED" "$ODIN_SIGNAL"
    (
        tries=0
        while [ ! -e "$ODIN_PID_FILE" ]; do
            tries=$((tries + 1))
            if [ "$tries" -ge 100 ]; then
                echo "$signal test-suite wrapper did not start its runner" >&2
                : >"$ODIN_RELEASE"
                exit 0
            fi
            sleep 0.02
        done
        wrapper=$(cat "$lock/pid")
        kill -"$signal" "$wrapper"
        tries=0
        while [ ! -e "$ODIN_SIGNAL" ] && [ "$tries" -lt 100 ]; do
            tries=$((tries + 1))
            sleep 0.02
        done
        : >"$ODIN_RELEASE"
    ) &
    signaler=$!
    if (cd "$tmp/repo" && exec sh scripts/test-suite.sh) >"$tmp/$signal.out" 2>&1; then
        echo "$signal-interrupted suite unexpectedly succeeded" >&2
        exit 1
    fi
    wait "$signaler"
    runner=$(cat "$ODIN_PID_FILE")
    [ "$(cat "$ODIN_SIGNAL" 2>/dev/null || :)" = TERM ] || {
        echo "$signal did not stop the underlying test runner" >&2
        exit 1
    }
    [ -e "$ODIN_FINISHED" ] || { echo "$signal left the test runner unfinished" >&2; exit 1; }
    if kill -0 "$runner" 2>/dev/null; then
        echo "$signal left test runner PID $runner running" >&2
        exit 1
    fi
    [ ! -e "$lock" ] || { echo "$signal-interrupted suite left its lock" >&2; exit 1; }
done

# A holder killed by a signal releases the lock for a new acquirer.
rm -f "$ODIN_STARTED" "$ODIN_RELEASE" "$ODIN_PID_FILE"
(cd "$tmp/repo" && exec sh scripts/test-suite.sh) >/dev/null 2>&1 &
dying=$!
tries=0
while [ ! -e "$ODIN_STARTED" ] && [ "$tries" -lt 100 ]; do tries=$((tries + 1)); sleep 0.02; done
kill -TERM "$dying"
wait "$dying" 2>/dev/null || :
[ ! -e "$lock" ] || { echo "dead holder left its lock" >&2; exit 1; }
rm -f "$ODIN_STARTED"
: >"$ODIN_RELEASE"
(cd "$tmp/other" && COFFEE_SHOP_TEST_LOCK_TIMEOUT=5 sh scripts/test-suite.sh) >/dev/null 2>&1 \
    || { echo "new acquirer failed after the holder died" >&2; exit 1; }

echo "cross-worktree suite lock exclusion, bounded wait, timeout, failure, and interruption release passed"
