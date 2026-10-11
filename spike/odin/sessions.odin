package main

// Modes:
//   idle                 bare process: sleep HOLD, nothing else
//   in-process N         N sessions in ONE process, touched, sleep HOLD, then freed
//   child [SECONDS]      one session, touched, sleep SECONDS (default HOLD)
// Each mode prints "pid <pid> ready ..." once its sessions exist, so the caller
// knows when to run footprint.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

HOLD :: 15 * time.Second

usage :: proc() -> ! {
	fmt.eprintln("usage: sessions idle | sessions in-process N | sessions child [SECONDS]")
	os.exit(2)
}

main :: proc() {
	if len(os.args) < 2 {
		usage()
	}

	switch os.args[1] {
	case "idle":
		fmt.printfln("pid %d ready", os.get_pid())
		time.sleep(HOLD)

	case "in-process":
		if len(os.args) < 3 {
			usage()
		}
		n, ok := strconv.parse_int(os.args[2])
		if !ok || n < 0 {
			usage()
		}
		sessions := make([dynamic]^Session, 0, n)
		for i in 0 ..< n {
			append(&sessions, make_session(i))
		}
		fmt.printfln("pid %d ready sessions %d", os.get_pid(), n)
		time.sleep(HOLD)
		for s in sessions {
			free_session(s)
		}
		delete(sessions)

	case "child":
		hold := HOLD
		if len(os.args) >= 3 {
			secs, ok := strconv.parse_int(os.args[2])
			if !ok || secs < 0 {
				usage()
			}
			hold = time.Duration(secs) * time.Second
		}
		s := make_session(0)
		fmt.printfln("pid %d ready sessions 1", os.get_pid())
		time.sleep(hold)
		free_session(s)

	case:
		usage()
	}
}
