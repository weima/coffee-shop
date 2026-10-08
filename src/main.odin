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
		recipe, recipe_err := load_recipe(command.recipe)
		if recipe_err != "" {
			write_error(recipe_err)
			return 2
		}
		defer destroy_recipe(&recipe)

		valid, repo_err := is_git_repository(command.repo)
		if repo_err != "" {
			write_error(repo_err)
			return 2
		}
		if !valid {
			write_error("Beans path is not a Git repository")
			return 2
		}
	}

	write_error("command not implemented yet")
	return 3
}

write_error :: proc(message: string) {
	stderr := os.to_stream(os.stderr)
	fmt.wprintfln(stderr, "coffee-shop: %s", message)
	fmt.wprintln(stderr, "Run `coffee-shop --help` for usage.")
}
