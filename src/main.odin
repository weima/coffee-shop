package main

import "core:fmt"
import "core:os"

main :: proc() {
	exit_code := run_cli(os.args[1:])
	if exit_code != 0 {
		os.exit(exit_code)
	}
}

run_cli :: proc(args: []string) -> int {
	command, err := parse_args(args)
	if err != "" {
		write_error(err)
		return 2
	}

	if command.kind == .Help {
		fmt.println(USAGE)
		return 0
	}

	if command.kind == .Brew {
		brew_id, err := run_brew(command.repo, command.recipe)
		if err != "" {
			write_error(err)
			return 1
		}
		fmt.println(brew_id)
		return 0
	}
	if command.kind == .Worker {
		return run_worker(command.brew_id, command.shot_id)
	}

	write_error("command not implemented yet")
	return 3
}

write_error :: proc(message: string) {
	stderr := os.to_stream(os.stderr)
	fmt.wprintfln(stderr, "coffee-shop: %s", message)
	fmt.wprintln(stderr, "Run `coffee-shop --help` for usage.")
}
