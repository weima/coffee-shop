package main

// The thin entry point the pi extension spawns: no arguments, one bridge stream
// on stdin and stdout. The library owns the store path and the exit status.

import "core:os"
import oreo "oreo:."

main :: proc() {
	os.exit(oreo.host_run("", os.to_reader(os.stdin), os.to_writer(os.stdout)))
}
