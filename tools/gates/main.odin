// Gate evidence for 5.8 / 5.9 / 5.10. See scripts/five-station-gates.md.
//
// Never starts a host, never touches Herdr. `request` writes a request line;
// `report` reads the host's event log, the state dir and the Spall traces.
package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

USAGE :: `usage:
  gates request --repo R --out FILE [--shots N] [--request-id ID] [--prompt TEXT | --prompt-file F]
  gates report  --request FILE --events FILE --state-dir DIR --trace PREFIX --out FILE [--top N]
  gates selftest`

// tprint formats a message that lives until the process exits.
tprint :: proc(f: string, args: ..any) -> string {
	return fmt.aprintf(f, ..args)
}

// parse_flags turns `--key value` pairs into a map; unknown or valueless flags are errors.
parse_flags :: proc(args: []string, allowed: []string) -> (flags: map[string]string, err: string) {
	for i := 0; i < len(args); i += 2 {
		key := strings.trim_prefix(args[i], "--")
		ok := strings.has_prefix(args[i], "--")
		known := false
		for a in allowed {known ||= a == key}
		if !ok || !known {return nil, tprint("unknown flag `%s`", args[i])}
		if i + 1 >= len(args) {return nil, tprint("flag `%s` needs a value", args[i])}
		flags[key] = args[i + 1]
	}
	return
}

need :: proc(flags: map[string]string, names: ..string) -> string {
	for n in names {
		if n not_in flags {return tprint("missing --%s", n)}
	}
	return ""
}

int_flag :: proc(flags: map[string]string, key: string, def: int) -> (n: int, err: string) {
	s, ok := flags[key]
	if !ok {return def, ""}
	v, pok := strconv.parse_int(s)
	if !pok || v < 1 {return 0, tprint("--%s must be a positive integer, got `%s`", key, s)}
	return v, ""
}

// gate-five-YYYYMMDD-HHMMSS-mmm (UTC): readable, sorts by time, unique per run.
default_request_id :: proc() -> string {
	now := time.now()
	y, mo, d := time.date(now)
	h, mi, sec := time.clock(now)
	ms := (time.to_unix_nanoseconds(now) / 1_000_000) % 1000
	return tprint("gate-five-%04d%02d%02d-%02d%02d%02d-%03d", y, int(mo), d, h, mi, sec, ms)
}

cmd_request :: proc(args: []string) -> string {
	flags, err := parse_flags(args, {"repo", "out", "shots", "request-id", "prompt", "prompt-file", "kind", "taste", "message", "model"})
	if err != "" {return err}
	if m := need(flags, "repo", "out"); m != "" {return m}
	a := RequestArgs{repo = flags["repo"], out = flags["out"], request_id = default_request_id(), prompt = DEFAULT_PROMPT}
	if v, ok := flags["request-id"]; ok {a.request_id = v}
	if v, ok := flags["prompt"]; ok {a.prompt = v}
	if v, ok := flags["prompt-file"]; ok {
		data, rerr := os.read_entire_file(v, context.allocator)
		if rerr != nil {return tprint("cannot read `%s`: %v", v, rerr)}
		a.prompt = string(data)
	}
	if v, ok := flags["kind"]; ok {a.kind = v}
	if v, ok := flags["taste"]; ok {a.taste = v}
	if v, ok := flags["message"]; ok {a.message = v}
	if v, ok := flags["model"]; ok {a.model = v}
	a.shots, err = int_flag(flags, "shots", 6)
	if err != "" {return err}
	return write_request(a)
}

cmd_report :: proc(args: []string) -> string {
	flags, err := parse_flags(args, {"request", "events", "state-dir", "trace", "out", "top"})
	if err != "" {return err}
	if m := need(flags, "request", "events", "state-dir", "trace", "out"); m != "" {return m}
	a := ReportArgs{flags["request"], flags["events"], flags["state-dir"], flags["trace"], flags["out"], 0}
	a.top, err = int_flag(flags, "top", 10)
	if err != "" {return err}
	return write_report(a)
}

main :: proc() {
	// One growing arena owns everything; the process is short-lived.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {os.exit(1)}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	args := os.args[1:]
	err: string
	switch {
	case len(args) == 0:           err = USAGE
	case args[0] == "request":     err = cmd_request(args[1:])
	case args[0] == "report":      err = cmd_report(args[1:])
	case args[0] == "selftest":    err = "" if selftest() else "selftest failed"
	case:                          err = USAGE
	}
	if err != "" {
		fmt.eprintln(err)
		os.exit(1)
	}
}
