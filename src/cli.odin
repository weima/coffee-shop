package main

import "core:flags"

Command_Kind :: enum {
	Help,
	Server,
	Brew,
	Status,
	Cancel,
	Collect,
	Worker,
	Host,
	Station,
}

Command :: struct {
	kind:    Command_Kind,
	repo:    string,
	recipe:  string,
	brew_id: string,
	shot_id: string,
	state_root: string,
	token: string,
	report_path: string,
	prompt: string,
	prompt_file: string,
	agent: []string,
}

Brew_Arguments :: struct {
	repo:   string `args:"required" usage:"Beans Git repository path."`,
	recipe: string `args:"required" usage:"Recipe JSON file path."`,
}

Brew_ID_Arguments :: struct {
	brew_id: string `args:"pos=0,required" usage:"Brew identifier."`,
}

Server_Arguments :: struct {
	state_root: string `args:"required" usage:"Coffee Shop state directory."`,
	repository: string `args:"required" usage:"Beans Git repository path."`,
}

Station_Arguments :: struct {
	report:      string `args:"required" usage:"Parent Coffee Shop activity socket."`,
	station:     string `args:"required" usage:"Station identifier."`,
	brew:        string `args:"required" usage:"Parent Brew or request identifier."`,
	prompt:      string `usage:"First prompt for the agent."`,
	prompt_file: string `usage:"File containing the first prompt for the agent."`,
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
  coffee-shop host
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
	case "host":
		return Command{kind = .Host}, ""
	case "station":
		return parse_station_args(args[1:])
	case "__server":
		options: Server_Arguments
		if flags.parse(&options, args[1:], .Unix) != nil {
			return Command{kind = .Help}, "invalid server arguments"
		}
		return Command{kind = .Server, state_root = options.state_root, repo = options.repository}, ""
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

// The agent command follows "--" and is passed through unparsed.
parse_station_args :: proc(args: []string) -> (command: Command, err: string) {
	split := -1
	for arg, i in args {
		if arg == "--" {
			split = i
			break
		}
	}
	if split < 0 || split == len(args)-1 {
		return Command{kind = .Help}, "station needs an agent command after --"
	}
	prompt_given := false
	prompt_file_given := false
	for arg in args[:split] {
		switch arg {
		case "--prompt":
			prompt_given = true
		case "--prompt-file":
			prompt_file_given = true
		}
	}
	if prompt_given == prompt_file_given {
		return Command{kind = .Help}, "station needs exactly one of --prompt or --prompt-file"
	}
	options: Station_Arguments
	if flags.parse(&options, args[:split], .Unix) != nil || prompt_file_given && options.prompt_file == "" {
		return Command{kind = .Help}, "invalid station arguments"
	}
	return Command{kind = .Station, report_path = options.report, shot_id = options.station, brew_id = options.brew, prompt = options.prompt, prompt_file = options.prompt_file, agent = args[split+1:]}, ""
}

has_help_flag :: proc(args: []string) -> bool {
	for arg in args {
		if arg == "--help" || arg == "-h" {
			return true
		}
	}
	return false
}
