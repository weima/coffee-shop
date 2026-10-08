package main

import "core:fmt"
import "core:os"

main :: proc() {
	command, err := parse_args(os.args[1:])
	if err != "" {
		stderr := os.to_stream(os.stderr)
		fmt.wprintfln(stderr, "coffee-shop: %s", err)
		fmt.wprintln(stderr, "Run `coffee-shop --help` for usage.")
		os.exit(2)
	}

	if command.kind == .Help {
		fmt.println(USAGE)
		return
	}

	stderr := os.to_stream(os.stderr)
	fmt.wprintln(stderr, "coffee-shop: command not implemented yet")
	os.exit(3)
}
