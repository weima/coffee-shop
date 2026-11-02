#!/bin/sh
# Station "typist": types a code fragment into dummy.odin one character at a
# time, at a human pace, with a pause at the end of each line.
#
# Usage: typist.sh <station-dir> <project-dir> <payload-file>
set -eu

dir=$1
project=$2
payload=$3
target="$project/dummy.odin"
char_delay=${RACHEL_TYPING_CHAR_DELAY:-0.09}
line_pause=${RACHEL_TYPING_LINE_PAUSE:-0.35}

mkdir -p "$dir"
# Both Stations must watch the same checkout, or Rachel cannot see the edits.
git -C "$project" rev-parse --show-toplevel >"$dir/worktree"

echo "[typist] station up in $(cat "$dir/worktree")"
echo "[typist] typing $(wc -c <"$payload" | tr -d ' ') characters into $target"

while IFS= read -r line || [ -n "$line" ]; do
	# Byte-at-a-time dd keeps this POSIX without a read -n; content is ASCII.
	printf '%s' "$line" >"$dir/line.txt"
	i=0
	while [ "$i" -lt "${#line}" ]; do
		dd if="$dir/line.txt" bs=1 skip="$i" count=1 2>/dev/null >>"$target"
		i=$((i + 1))
		sleep "$char_delay"
	done
	printf '\n' >>"$target"
	sleep "$line_pause"
done <"$payload"

echo "[typist] done"
