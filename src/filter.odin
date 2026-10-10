package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// Filter evidence for one Shot: a read-only review plus the repository's own
// test commands. It is saved once per Shot so collecting again shows the same
// evidence instead of re-running Pi and the tests.
Filter_Check :: struct {
	kind:        string, // "unit" or "e2e"
	source:      string,
	command:     string,
	started:     bool,
	exit_code:   int,
	success:     bool,
	output_tail: string,
	detail:      string,
}

Filter_Evidence :: struct {
	review_performed: bool,
	review_findings:  string,
	review_detail:    string,
	checks:           [dynamic]Filter_Check,
	notes:            [dynamic]string,
}

filter_evidence_path :: proc(brew_dir, shot_id: string) -> string {
	directory := state_file_path(brew_dir, "filter")
	defer delete(directory)
	name, _ := strings.concatenate({shot_id, ".json"})
	defer delete(name)
	return state_file_path(directory, name)
}

// Returns saved evidence if it exists; otherwise runs the Filter once and saves it.
load_or_run_filter :: proc(brew_dir: string, register: Register, index: int, pi: string) -> (evidence: Filter_Evidence, err: string) {
	shot := register.shots[index]
	path := filter_evidence_path(brew_dir, shot.id)
	defer delete(path)

	if os.exists(path) {
		data, read_err := os.read_entire_file(path, context.allocator)
		defer delete(data)
		if read_err != nil || json.unmarshal(data, &evidence, .JSON) != nil {
			destroy_struct(&evidence)
			return Filter_Evidence{}, fmt.tprintf("saved Filter evidence for %s is unreadable: %s", shot.id, path)
		}
		return evidence, ""
	}

	evidence = run_filter(register, shot, pi)
	directory := state_file_path(brew_dir, "filter")
	defer delete(directory)
	data, marshal_err := json.marshal(evidence, json.Marshal_Options{spec = .JSON, pretty = true})
	defer delete(data)
	// The directory is shared by every Shot in the Brew, so it may already exist.
	if marshal_err != nil || !ensure_directory(directory) || !write_file_atomic(path, data) {
		destroy_struct(&evidence)
		return Filter_Evidence{}, "could not save Filter evidence"
	}
	return evidence, ""
}

run_filter :: proc(register: Register, shot: Register_Shot, pi: string) -> (evidence: Filter_Evidence) {
	if register.base_commit == "" {
		evidence.review_detail = strings.clone("the Beans base commit was not recorded; no review was performed")
	} else {
		review := review_station(shot.station_path, register.base_commit, pi, 60000, context.allocator, register.review_model, register.review_thinking)
		evidence.review_performed = review.performed
		evidence.review_findings = review.findings
		evidence.review_detail = review.detail
	}

	discovery := discover_checks(shot.station_path)
	defer discovery_destroy(&discovery)
	for note in discovery.notes {
		append(&evidence.notes, strings.clone(note))
	}
	suggestions := share_suggestions(register.beans_path, shot.station_path, register.share[:])
	for suggestion in suggestions {
		append(&evidence.notes, suggestion)
	}
	delete(suggestions)
	for command in discovery.commands {
		result := run_check(shot.station_path, command.argv)
		kind := "unit"
		if command.kind == .E2E {
			kind = "e2e"
		}
		append(&evidence.checks, Filter_Check{
			kind = strings.clone(kind),
			source = strings.clone(command.source),
			command = command_text(command.argv),
			started = result.started,
			exit_code = result.exit_code,
			success = result.success,
			output_tail = result.output_tail,
			detail = result.detail,
		})
	}
	return evidence
}

// Renders the Filter evidence for one Shot and appends anything the developer
// has to decide to `decisions`.
render_filter_evidence :: proc(builder: ^strings.Builder, decisions: ^[dynamic]string, shot_id: string, evidence: Filter_Evidence) {
	if evidence.review_performed {
		fmt.sbprintfln(builder, "Review:\n%s", evidence.review_findings)
		if !strings.contains(strings.to_lower(evidence.review_findings, context.temp_allocator), "no findings") {
			append(decisions, fmt.aprintf("Shot %s: review reported findings", shot_id))
		}
	} else {
		fmt.sbprintfln(builder, "Review:\nNot performed: %s", evidence.review_detail)
		append(decisions, fmt.aprintf("Shot %s: review was not performed (%s)", shot_id, evidence.review_detail))
	}

	if len(evidence.checks) > 0 {
		fmt.sbprintln(builder, "Checks:")
	}
	for check in evidence.checks {
		if check.success {
			fmt.sbprintfln(builder, "  [%s] %s (%s): passed", check.kind, check.command, check.source)
			continue
		}
		fmt.sbprintfln(builder, "  [%s] %s (%s): FAILED (%s)", check.kind, check.command, check.source, check.detail)
		if check.output_tail != "" {
			fmt.sbprintfln(builder, "%s", check.output_tail)
		}
		append(decisions, fmt.aprintf("Shot %s: a check failed: %s", shot_id, check.command))
	}
	for note in evidence.notes {
		fmt.sbprintfln(builder, "Note: %s", note)
		append(decisions, fmt.aprintf("Shot %s: %s", shot_id, note))
	}
}

ensure_directory :: proc(directory: string) -> bool {
	if os.is_dir(directory) {
		return true
	}
	return os.make_directory_all(directory, os.Permissions{.Read_User, .Write_User, .Execute_User}) == nil || os.is_dir(directory)
}
