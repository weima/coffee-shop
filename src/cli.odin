package main

import "core:flags"

Command_Kind :: enum {
	Help,
	Brew,
	Status,
	Cancel,
	Collect,
	Worker,
}

Command :: struct {
	kind:    Command_Kind,
	repo:    string,
	recipe:  string,
	brew_id: string,
	shot_id: string,
	state_root: string,
	token: string,
}

Brew_Arguments :: struct {
	repo:   string `args:"required" usage:"Beans Git repository path."`,
	recipe: string `args:"required" usage:"Recipe JSON file path."`,
}

Brew_ID_Arguments :: struct {
	brew_id: string `args:"pos=0,required" usage:"Brew identifier."`,
}

Worker_Arguments :: struct {
	state_root: string `args:"required" usage:"Coffee Shop state directory."`,
	brew_id: string `args:"required" usage:"Brew identifier."`,
	shot_id: string `args:"required" usage:"Shot identifier."`,
	token: string `args:"required" usage:"Brew token from the Register."`,
}

USAGE :: `Coffee Shop - local Pi Workers for isolated repository changes

Usage:
  coffee-shop brew --repo <path> --recipe <recipe.json>
  coffee-shop status <brew-id>
  coffee-shop cancel <brew-id>
  coffee-shop collect <brew-id>
  coffee-shop --help
`

parse_args :: proc(args: []string) -> (command: Command, err: string) {
	if len(args) == 0 {
		return Command{kind = .Help}, "missing command"
	}

	name := args[0]
	if name == "--help" || name == "-h" || name == "help" || has_help_flag(args[1:]) {
		return Command{kind = .Help}, ""
	}

	switch name {
	case "brew":
		options: Brew_Arguments
		if flags.parse(&options, args[1:], .Unix) != nil {
			return Command{kind = .Help}, "invalid brew arguments"
		}
		return Command{kind = .Brew, repo = options.repo, recipe = options.recipe}, ""
	case "__worker":
		options: Worker_Arguments
		if flags.parse(&options, args[1:], .Unix) != nil {
			return Command{kind = .Help}, "invalid Worker arguments"
		}
		return Command{kind = .Worker, brew_id = options.brew_id, shot_id = options.shot_id, state_root = options.state_root, token = options.token}, ""
	case "status", "cancel", "collect":
		options: Brew_ID_Arguments
		if flags.parse(&options, args[1:], .Unix) != nil {
			return Command{kind = .Help}, "expected exactly one Brew ID"
		}

		kind := Command_Kind.Status
		switch name {
		case "cancel":
			kind = .Cancel
		case "collect":
			kind = .Collect
		}
		return Command{kind = kind, brew_id = options.brew_id}, ""
	case:
		return Command{kind = .Help}, "unknown command"
	}
}

has_help_flag :: proc(args: []string) -> bool {
	for arg in args {
		if arg == "--help" || arg == "-h" {
			return true
		}
	}
	return false
}
