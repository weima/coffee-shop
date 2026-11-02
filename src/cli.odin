package main

import "core:flags"
import "core:fmt"

Command_Kind :: enum {
	Help,
	Status,
	Host,
	Station,
	Pr,
	Cleanup,
	Log,
	Reply,
	Prepare,
	Release,
	Blend,
}

Command :: struct {
	kind:    Command_Kind,
	repo:    string,
	recipe:  string,
	brew_id: string,
	shot_id: string,
	state_root: string,
	report_path: string,
	prompt: string,
	prompt_file: string,
	shot_kind: string,
	taste: string,
	message: string,
	interactive: bool,
	codemode: bool,
	watch:    string,
	agent: []string,
	run_id: string,
	branch: string,
	remote: string,
	blend: bool,
	stations: bool,
	tail: int,
	dump: bool,
	print_only: bool,
	worktree_dir: string,
	request_file: string,
}

Request_ID_Arguments :: struct {
	request_id: string `args:"pos=0,required" usage:"Host request identifier."`,
}

Pr_Arguments :: struct {
	run_id:  string `args:"pos=0,required" usage:"Run identifier."`,
	shot_id: string `args:"pos=1,required" usage:"Pull (Shot) identifier."`,
	branch:  string `usage:"Branch the Pull is based on; discovered from the run's workspace when omitted."`,
	remote:  string `usage:"Git remote to push to (default origin)."`,
	blend:   bool `usage:"Combine the run's 2 to 20 Pull commits into one commit before opening the PR."`,
	message: string `usage:"Commit message for --blend."`,
}

// The seam Go's orchestrator drives. Both take absolute paths; validation happens
// before any Git call, so a rejected command changes nothing.
Seam_Arguments :: struct {
	repo:   string `args:"required" usage:"Beans Git repository path (absolute)."`,
	branch: string `args:"required" usage:"New branch for the Shot's worktree."`,
	dir:    string `args:"required" usage:"Worktree directory to create (absolute)."`,
}

// Blend reads one request object from a file: the same request the host accepts, kept
// out of argv so no shell can see it.
Blend_Arguments :: struct {
	request: string `args:"required" usage:"File holding the blend request (one JSON object)."`,
}

Release_Arguments :: struct {
	repo: string `args:"required" usage:"Beans Git repository path (absolute)."`,
	dir:  string `args:"required" usage:"Worktree directory to remove (absolute)."`,
}

Log_Arguments :: struct {
	request_id: string `args:"pos=0,required" usage:"Request identifier."`,
	shot_id:    string `args:"pos=1,required" usage:"Shot identifier."`,
	tail:       int `usage:"Print the last N lines of the log."`,
	cat:        bool `usage:"Print the whole log."`,
}

Reply_Arguments :: struct {
	request_id: string `args:"pos=0,required" usage:"Request identifier."`,
	shot_id:    string `args:"pos=1,required" usage:"Shot identifier."`,
	message:    string `args:"pos=2,required" usage:"One line of text for the Station's agent."`,
	print:      bool `usage:"Only print the request line; send nothing."`,
}

Cleanup_Arguments :: struct {
	run_id: string `args:"pos=0,required" usage:"Run identifier."`,
	branch: string `usage:"Base branch whose worktree to remove; discovered from the PR record when omitted."`,
}

Station_Arguments :: struct {
	report:      string `args:"required" usage:"Parent Coffee Shop activity socket."`,
	station:     string `args:"required" usage:"Station identifier."`,
	brew:        string `args:"required" usage:"Parent Brew or request identifier."`,
	prompt:      string `usage:"First prompt for the agent."`,
	prompt_file: string `usage:"File containing the first prompt for the agent."`,
	kind:        string `usage:"Shot kind: execute (default) or research."`,
	taste:       string `usage:"Taste command a Pull must pass before it commits."`,
	message:     string `usage:"Commit message for a Pull that passes its Taste."`,
	interactive: bool `usage:"Keep the Shot open for typed replies after each turn."`,
	codemode:    string `usage:"true (default) or false: whether an execute Shot gets codemode."`,
	watch:       string `usage:"Shell command run beside the agent; distinct stdout lines are reported as rachel_verdict."`,
}

USAGE :: `Coffee Shop - local Pi Workers for isolated repository changes

Usage:
  coffee-shop status <request-id>
  coffee-shop status --stations
  coffee-shop log <request-id> <shot-id> [--tail <n> | --cat]
  coffee-shop reply <request-id> <shot-id> <text> [--print]
  coffee-shop pr <run-id> <shot-id> [--branch <name>] [--blend --message <text>]
  coffee-shop cleanup <run-id> [--branch <name>]
  coffee-shop prepare --repo <path> --branch <name> --dir <path>
  coffee-shop release --repo <path> --dir <path>
  coffee-shop blend --request <file>
  coffee-shop host
  coffee-shop --help
`

// `host` takes no arguments: there is one implementation, csd. Anything else, including
// the retired --impl, is named rather than ignored, so a stale script learns why.
parse_host_args :: proc(args: []string) -> (command: Command, err: string) {
	for arg in args {
		if arg == "--help" || arg == "-h" {
			return Command{kind = .Help}, ""
		}
		return Command{kind = .Help}, fmt.tprintf("host takes no arguments, got %q; the Odin host was deleted and csd is the only implementation", arg)
	}
	return Command{kind = .Host}, ""
}

parse_args :: proc(args: []string) -> (command: Command, err: string) {
	if len(args) == 0 {
		return Command{kind = .Help}, "missing command"
	}

	name := args[0]
	if name == "--help" || name == "-h" || name == "help" || has_help_flag(args[1:]) {
		return Command{kind = .Help}, ""
	}

	switch name {
	case "host":
		return parse_host_args(args[1:])
	case "station":
		return parse_station_args(args[1:])
	case "pr":
		options: Pr_Arguments
		if flags.parse(&options, args[1:], .Unix) != nil {
			return Command{kind = .Help}, "invalid pr arguments"
		}
		return Command{kind = .Pr, run_id = options.run_id, shot_id = options.shot_id, branch = options.branch, remote = options.remote, message = options.message, blend = options.blend}, ""
	case "cleanup":
		options: Cleanup_Arguments
		if flags.parse(&options, args[1:], .Unix) != nil {
			return Command{kind = .Help}, "invalid cleanup arguments"
		}
		return Command{kind = .Cleanup, run_id = options.run_id, branch = options.branch}, ""
	case "prepare":
		options: Seam_Arguments
		if flags.parse(&options, args[1:], .Unix) != nil {
			return Command{kind = .Help}, "invalid prepare arguments"
		}
		return Command{kind = .Prepare, repo = options.repo, branch = options.branch, worktree_dir = options.dir}, ""
	case "blend":
		options: Blend_Arguments
		if flags.parse(&options, args[1:], .Unix) != nil {
			return Command{kind = .Help}, "invalid blend arguments"
		}
		return Command{kind = .Blend, request_file = options.request}, ""
	case "release":
		options: Release_Arguments
		if flags.parse(&options, args[1:], .Unix) != nil {
			return Command{kind = .Help}, "invalid release arguments"
		}
		return Command{kind = .Release, repo = options.repo, worktree_dir = options.dir}, ""
	case "log":
		options: Log_Arguments
		if flags.parse(&options, args[1:], .Unix) != nil || options.tail < 0 || options.cat && options.tail > 0 {
			return Command{kind = .Help}, "invalid log arguments"
		}
		return Command{kind = .Log, brew_id = options.request_id, shot_id = options.shot_id, tail = options.tail, dump = options.cat}, ""
	case "reply":
		options: Reply_Arguments
		if flags.parse(&options, args[1:], .Unix) != nil {
			return Command{kind = .Help}, "invalid reply arguments"
		}
		return Command{kind = .Reply, brew_id = options.request_id, shot_id = options.shot_id, message = options.message, print_only = options.print}, ""
	case "status":
		if name == "status" && len(args) == 2 && args[1] == "--stations" {
			return Command{kind = .Status, stations = true}, ""
		}
		options: Request_ID_Arguments
		if flags.parse(&options, args[1:], .Unix) != nil {
			return Command{kind = .Help}, "expected exactly one host request ID"
		}

		return Command{kind = .Status, brew_id = options.request_id}, ""
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
	options := Station_Arguments{kind = SHOT_KIND_EXECUTE}
	if flags.parse(&options, args[:split], .Unix) != nil || prompt_file_given && options.prompt_file == "" {
		return Command{kind = .Help}, "invalid station arguments"
	}
	if !valid_shot_kind(options.kind) {
		return Command{kind = .Help}, "station kind must be execute or research"
	}
	if options.taste != "" || options.message != "" {
		if options.kind != SHOT_KIND_EXECUTE || !valid_shot_taste(options.taste) || !valid_commit_message(options.message) {
			return Command{kind = .Help}, "station taste needs an execute kind, a taste, and a message"
		}
	}
	if options.codemode != "" && options.codemode != "true" && options.codemode != "false" {
		return Command{kind = .Help}, "station codemode must be true or false"
	}
	return Command{kind = .Station, interactive = options.interactive, codemode = options.codemode != "false", watch = options.watch, report_path = options.report, shot_id = options.station, brew_id = options.brew, prompt = options.prompt, prompt_file = options.prompt_file, shot_kind = options.kind, taste = options.taste, message = options.message, agent = args[split+1:]}, ""
}

has_help_flag :: proc(args: []string) -> bool {
	for arg in args {
		if arg == "--help" || arg == "-h" {
			return true
		}
	}
	return false
}
