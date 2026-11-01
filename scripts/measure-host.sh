#!/bin/sh
# The v0.6 host measurement driver. The logic is in Go (go/cmd/measure); this is a
# launcher so the docs can name one shell entry point.
#
# Usage: sh scripts/measure-host.sh <output-directory>
#
# The tool refuses to run when `herdr` is on PATH, because a measurement of the Go host
# is not a measurement of Go plus Herdr.

set -u

OUT="$1"
if [ -z "$OUT" ]; then
    echo "usage: $0 <output-directory>" >&2
    exit 2
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"

cd "$REPO/go" || exit 1
exec go run ./cmd/measure -out "$OUT"
