package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// A Brew is as finished as its least finished Shot. Terminal Brews report the
// worst outcome so a failure is never hidden behind completed Shots.
brew_status :: proc(register: Register) -> string {
	any_queued, any_failed, any_interrupted, any_cancelled, any_incomplete := false, false, false, false, false
	any_running := false
	for shot in register.shots {
		switch shot.status {
		case SHOT_QUEUED: any_queued = true
		case SHOT_RUNNING: any_running = true
		case SHOT_FAILED: any_failed = true
		case SHOT_INTERRUPTED: any_interrupted = true
		case SHOT_CANCELLED: any_cancelled = true
		case SHOT_INCOMPLETE: any_incomplete = true
		}
	}
	switch {
	case any_running: return SHOT_RUNNING
	case any_queued:
		// Queued Shots next to finished ones are waiting for a free slot.
		for shot in register.shots {
			if shot.status != SHOT_QUEUED {
				return SHOT_RUNNING
			}
		}
		return SHOT_QUEUED
	case any_incomplete: return SHOT_INCOMPLETE
	case any_failed: return SHOT_FAILED
	case any_interrupted: return SHOT_INTERRUPTED
	case any_cancelled: return SHOT_CANCELLED
	}
	return SHOT_COMPLETED
}

run_status :: proc(brew_id: string) -> int {
	state_root, err := default_state_root()
	if err != "" {
		write_error(err)
		return 2
	}
	defer delete(state_root)
	output, status_err := render_status(state_root, brew_id)
	if status_err != "" {
		write_error(status_err)
		return 1
	}
	defer delete(output)
	fmt.print(output)
	return 0
}

run_cancel :: proc(brew_id: string) -> int {
	state_root, err := default_state_root()
	if err != "" {
		write_error(err)
		return 2
	}
	defer delete(state_root)
	output, cancel_err := cancel_brew(state_root, "herdr", brew_id)
	if cancel_err != "" {
		write_error(cancel_err)
		return 1
	}
	defer delete(output)
	fmt.print(output)
	return 0
}

run_collect :: proc(brew_id: string) -> int {
	state_root, err := default_state_root()
	if err != "" {
		write_error(err)
		return 2
	}
	defer delete(state_root)
	if settle_err := settle_orphaned_brew(state_root, "herdr", brew_id); settle_err != "" {
		write_error(settle_err)
		return 1
	}
	output, complete, collect_err := render_collect(state_root, brew_id)
	if collect_err != "" {
		write_error(collect_err)
		return 1
	}
	defer delete(output)
	fmt.print(output)
	if !complete {
		write_error("Brew is not fully completed; see the Shot outcomes above")
		return 1
	}
	return 0
}

// Asks the Brew to cancel. A live supervisor does the work; if it is gone,
// this process settles the Brew itself. Repeating the command is safe.
cancel_brew :: proc(state_root, herdr, brew_id: string) -> (output: string, err: string) {
	register, brew_dir, load_err := load_brew(state_root, brew_id)
	if load_err != "" {
		return "", load_err
	}
	defer delete(brew_dir)
	if all_terminal(register) {
		status := brew_status(register)
		destroy_struct(&register)
		return fmt.aprintf("Brew %s already finished: %s\n", brew_id, status), ""
	}
	if !request_cancel(brew_dir) {
		destroy_struct(&register)
		return "", "could not record the cancellation request"
	}
	if !supervisor_gone(brew_dir) {
		destroy_struct(&register)
		return fmt.aprintf("Cancellation requested for Brew %s; its supervisor will stop the Workers.\n", brew_id), ""
	}
	if settle_err := settle_brew(brew_dir, &register, herdr, .Cancel); settle_err.kind != .None {
		destroy_struct(&register)
		return "", fmt.tprintf("could not settle Brew: %s", state_error_message(settle_err))
	}
	destroy_struct(&register)
	return render_status(state_root, brew_id)
}

// When the supervisor has died, evidence-backed outcomes (finished Workers,
// vanished Workers) still need recording before results can be collected.
settle_orphaned_brew :: proc(state_root, herdr, brew_id: string) -> string {
	register, brew_dir, load_err := load_brew(state_root, brew_id)
	if load_err != "" {
		return load_err
	}
	defer destroy_struct(&register)
	defer delete(brew_dir)
	if all_terminal(register) || !supervisor_gone(brew_dir) {
		return ""
	}
	if err := settle_brew(brew_dir, &register, herdr, .Observe); err.kind != .None {
		return fmt.tprintf("could not settle Brew: %s", state_error_message(err))
	}
	return ""
}

// The name shown for a Brew. A derived name is returned as owned, so the caller
// frees it; a stored name is borrowed from the Register.
report_repository :: proc(register: Register) -> (name, derived: string) {
	if register.repository_name != "" {
		return register.repository_name, {}
	}
	derived = repository_name(register.beans_path)
	return derived, derived
}

render_status :: proc(state_root, brew_id: string) -> (output: string, err: string) {
	register, brew_dir, load_err := load_brew(state_root, brew_id)
	if load_err != "" {
		return "", load_err
	}
	defer destroy_struct(&register)
	defer delete(brew_dir)

	builder := strings.builder_make()
	repository, derived := report_repository(register)
	defer delete(derived)
	fmt.sbprintfln(&builder, "Brew %s (%s): %s", register.brew_id, repository, brew_status(register))
	running := 0
	queued := 0
	total_tokens: i64
	total_cost: f64
	unavailable_costs := 0
	any_usage := false
	for shot in register.shots {
		if shot.status == SHOT_RUNNING { running += 1 }
		if shot.status == SHOT_QUEUED { queued += 1 }
		if !shot.usage.recorded { continue }
		any_usage = true
		total_tokens += shot.usage.total
		if shot.usage.cost_known { total_cost += shot.usage.cost } else { unavailable_costs += 1 }
	}
	fmt.sbprintfln(&builder, "Workers: %d of %d running, %d queued", running, workers_limit(register), queued)
	if register.preamble_source != "" { fmt.sbprintfln(&builder, "Preamble: %s (%d bytes)", register.preamble_source, len(register.preamble)) }
	// Whether a supervisor is watching is per Brew, so every in-flight Station is
	// labelled with the same answer rather than left to be assumed working.
	supervision := ""
	if !all_terminal(register) {
		switch supervisor_liveness(brew_dir) {
		case .Alive: supervision = "supervised"
		case .Gone: supervision = "no supervisor"
		case .Unknown: supervision = "supervisor unknown"
		}
	}
	now_ns := time.now()._nsec
	for shot in register.shots {
		suffix := ""
		if shot.cancel_requested && shot.status == SHOT_RUNNING {
			suffix = " (cancel requested)"
		}
		if shot.status == SHOT_RUNNING && render_shot_activity(
			&builder, brew_dir, shot, suffix, supervision, now_ns,
		) {
			continue
		}
		reason := ""
		if is_terminal(shot.status) {
			// The outcome is shown without opening the Tray, so acting on a
			// completion does not require polling it again.
			outcome := shot.outcome
			if outcome == "" { outcome = shot.detail }
			reason = detail_suffix(outcome)
		}
		fmt.sbprintf(&builder, "  %s  %s%s%s", shot.id, shot.status, suffix, reason)
		if shot.status == SHOT_RUNNING {
			append_shot_location(&builder, shot)
			append_usage(&builder, shot.usage)
			if supervision != "" { fmt.sbprintf(&builder, "  %s", supervision) }
		} else {
			append_usage(&builder, shot.usage)
		}
		fmt.sbprintln(&builder)
	}
	if any_usage {
		fmt.sbprintf(&builder, "Usage: tokens=%d", total_tokens)
		switch {
		case unavailable_costs == 0:
			fmt.sbprintf(&builder, " cost=%.4f", total_cost)
		case total_cost == 0:
			fmt.sbprint(&builder, " cost=unavailable")
		case:
			fmt.sbprintf(&builder, " cost=%.4f (%d unavailable)", total_cost, unavailable_costs)
		}
		fmt.sbprintln(&builder)
	}
	if !all_terminal(register) && supervisor_gone(brew_dir) {
		fmt.sbprintln(&builder, "Supervisor is not running; `collect` or `cancel` will settle unfinished Shots.")
	}
	return strings.to_string(builder), ""
}

render_shot_activity :: proc(
	builder: ^strings.Builder,
	brew_dir: string,
	shot: Register_Shot,
	suffix, supervision: string,
	now_ns: i64,
) -> bool {
	started_at, has_started := read_worker_started_at(brew_dir, shot.id)
	activity, has_activity := read_activity_record(brew_dir, shot.id)
	defer destroy_struct(&activity)
	if !has_started && !has_activity {
		return false
	}

	fmt.sbprintf(builder, "  %s  %s%s", shot.id, SHOT_RUNNING, suffix)
	if has_started {
		elapsed := activity_duration_label(activity_age_seconds(now_ns, started_at))
		fmt.sbprintf(builder, "  %s elapsed", elapsed)
		delete(elapsed)
	}
	if has_activity {
		age := activity_duration_label(activity_age_seconds(now_ns, activity.observed_at_ns))
		if activity_is_quiet(activity.observed_at_ns, now_ns) {
			fmt.sbprintf(builder, "  quiet; last activity %s ago: %s", age, activity.description)
		} else {
			fmt.sbprintf(builder, "  active %s ago: %s", age, activity.description)
		}
		delete(age)
	} else {
		fmt.sbprint(builder, "  waiting for Pi activity")
	}
	append_shot_location(builder, shot)
	append_usage(builder, shot.usage)
	if supervision != "" { fmt.sbprintf(builder, "  %s", supervision) }
	fmt.sbprintln(builder)
	return true
}

// The Station's Herdr pane or tab, so a developer can find it.
append_shot_location :: proc(builder: ^strings.Builder, shot: Register_Shot) {
	if shot.herdr_tab_id == "" && shot.herdr_pane_id == "" {
		return
	}
	fmt.sbprint(builder, "  ")
	if shot.herdr_tab_id != "" { fmt.sbprintf(builder, "tab=%s", shot.herdr_tab_id) }
	if shot.herdr_pane_id != "" {
		if shot.herdr_tab_id != "" { fmt.sbprint(builder, " ") }
		fmt.sbprintf(builder, "pane=%s", shot.herdr_pane_id)
	}
}

// The Station's own tokens and cost. Cost is unavailable, never zero, when Pi
// could not price the model.
append_usage :: proc(builder: ^strings.Builder, usage: Station_Usage) {
	if !usage.recorded {
		return
	}
	if usage.cost_known {
		fmt.sbprintf(builder, "  tokens=%d cost=%.4f", usage.total, usage.cost)
	} else {
		fmt.sbprintf(builder, "  tokens=%d cost=unavailable", usage.total)
	}
}

Collect_Result :: struct {
	output:   string,
	complete: bool,
}

render_collect :: proc(state_root, brew_id: string) -> (output: string, complete: bool, err: string) {
	result, collect_err := render_collect_with_pi(state_root, brew_id, "pi")
	return result.output, result.complete, collect_err
}

// Builds the Tray: every Shot's outcome, Worker report and Filter evidence, then
// the decisions that need a human. Filter evidence is created once per completed
// Shot and reused by later collections.
render_collect_with_pi :: proc(state_root, brew_id, pi: string) -> (result: Collect_Result, err: string) {
	register, brew_dir, load_err := load_brew(state_root, brew_id)
	if load_err != "" {
		return Collect_Result{}, load_err
	}
	defer destroy_struct(&register)
	defer delete(brew_dir)

	details := last_details(brew_dir, register)
	defer delete_details(details)

	decisions: [dynamic]string
	defer {
		for decision in decisions {
			delete(decision)
		}
		delete(decisions)
	}

	builder := strings.builder_make()
	result.complete = true
	repository, derived := report_repository(register)
	defer delete(derived)
	fmt.sbprintfln(&builder, "# Brew %s (%s): %s", register.brew_id, repository, brew_status(register))
	fmt.sbprintfln(&builder, "Workers: %d", workers_limit(register))
	if register.model != "" { fmt.sbprintfln(&builder, "Default model: %s", register.model) }
	if register.thinking != "" { fmt.sbprintfln(&builder, "Default thinking: %s", register.thinking) }
	order_display := register.order
	if register.order_source != "" {
		if end := strings.index(register.order, "\n\n"); end >= 0 { order_display = register.order[:end] }
		fmt.sbprintfln(&builder, "Order: %s\nFull order: inputs/order.txt", order_display)
	} else {
		fmt.sbprintfln(&builder, "Order: %s", order_display)
	}
	fmt.sbprintfln(&builder, "Beans: %s", register.beans_path)
	if register.preamble_source != "" { fmt.sbprintfln(&builder, "Preamble: %s (%d bytes)", register.preamble_source, len(register.preamble)) }
	for shot, index in register.shots {
		fmt.sbprintfln(&builder, "\n## Shot %s: %s", shot.id, shot.status)
		if shot.status != SHOT_COMPLETED {
			result.complete = false
			if details[index] != "" {
				fmt.sbprintfln(&builder, "Detail: %s", details[index])
			}
			append(&decisions, fmt.aprintf("Shot %s is %s%s", shot.id, shot.status, detail_suffix(details[index])))
		}
		if shot.station_path == "" {
			continue
		}
		fmt.sbprintfln(&builder, "Station: %s", shot.station_path)
		for rule_file in ([]string{"workers.md", "standards.md"}) {
			rule_path := state_file_path(shot.station_path, rule_file); defer delete(rule_path)
			fmt.sbprintfln(&builder, "Repository guidance: %s %s", rule_file, os.exists(rule_path) ? "present" : "absent")
		}
		branch := ""
		if register.repository_name == "" { branch = fmt.aprintf("coffee-shop-%s-%s", register.brew_id, shot.id) } else {
			branch_repo := repository_slug(register.beans_path)
			branch = fmt.aprintf("cs-%s-%s-%s", branch_repo, register.brew_id, shot.id)
			delete(branch_repo)
		}
		fmt.sbprintfln(&builder, "Branch: %s", branch)
		delete(branch)
		if shot.model != "" { fmt.sbprintfln(&builder, "Model: %s", shot.model) }
		if shot.thinking != "" { fmt.sbprintfln(&builder, "Thinking: %s", shot.thinking) }
		if shot.status == SHOT_QUEUED {
			continue
		}
		changes := station_changes(shot.station_path)
		fmt.sbprintfln(&builder, "Changes:\n%s", changes)
		delete(changes)
		report := read_shot_report(brew_dir, shot.id)
		if report != "" {
			fmt.sbprintfln(&builder, "Report:\n%s", report)
			if shot.status == SHOT_INCOMPLETE { append(&decisions, fmt.aprintf("Shot %s final response: \"%s\"", shot.id, report_tail(report))) }
		}
		delete(report)

		if shot.status == SHOT_COMPLETED {
			evidence, filter_err := load_or_run_filter(brew_dir, register, index, pi)
			if filter_err != "" {
				delete(builder.buf)
				return Collect_Result{}, filter_err
			}
			render_filter_evidence(&builder, &decisions, shot.id, evidence)
			destroy_struct(&evidence)
		}
	}

	if len(decisions) > 0 {
		fmt.sbprintln(&builder, "\n## Decisions for the developer")
		for decision in decisions {
			fmt.sbprintfln(&builder, "- %s", decision)
		}
	}
	result.output = strings.to_string(builder)
	return result, ""
}

report_tail :: proc(report: string) -> string {
	start := 0
	newlines := 0
	for i := len(report)-1; i >= 0; i -= 1 {
		if report[i] == '\n' { newlines += 1; if newlines == 3 { start = i+1; break } }
	}
	return report[start:]
}

detail_suffix :: proc(detail: string) -> string {
	if detail == "" {
		return ""
	}
	return fmt.tprintf(" (%s)", detail)
}

// Brew IDs become path segments, so apply the same grammar as Shot IDs before
// touching the filesystem.
load_brew :: proc(state_root, brew_id: string) -> (register: Register, brew_dir: string, err: string) {
	if !valid_shot_id(brew_id) {
		return Register{}, "", "Brew ID is invalid"
	}
	brew_dir = state_file_path(state_root, brew_id)
	if !os.exists(brew_dir) {
		delete(brew_dir)
		return Register{}, "", fmt.tprintf("no Brew named %s", brew_id)
	}
	register, err = command_snapshot(state_root, brew_id)
	if err != "" {
		delete(brew_dir)
		return Register{}, "", err
	}
	return register, brew_dir, ""
}

// A Brew where no Worker ever started and some Shot failed could not run at all
// (for example, no Herdr server). That is an infrastructure problem the caller
// should hear about, unlike a Worker that ran and failed. Returns "" otherwise.
brew_launch_failure :: proc(state_root, brew_id: string) -> string {
	register, brew_dir, load_err := load_brew(state_root, brew_id)
	if load_err != "" {
		return ""
	}
	defer destroy_struct(&register)
	defer delete(brew_dir)

	failed_index := -1
	for shot, index in register.shots {
		if shot.status == SHOT_FAILED && failed_index < 0 {
			failed_index = index
		}
	}
	if failed_index < 0 || any_shot_started(brew_dir) {
		return ""
	}
	details := last_details(brew_dir, register)
	defer delete_details(details)
	if details[failed_index] == "" {
		return "no Shot could be launched"
	}
	return fmt.tprintf("no Shot could be launched (%s)", details[failed_index])
}

any_shot_started :: proc(brew_dir: string) -> bool {
	path := state_file_path(brew_dir, RECEIPT_FILE_NAME)
	defer delete(path)
	data, read_err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	if read_err != nil {
		return false
	}
	remaining := string(data)
	for line in strings.split_lines_iterator(&remaining) {
		event: State_Event
		started := json.unmarshal_string(line, &event, .JSON) == nil && event.kind == "shot_transition" && event.to_state == SHOT_RUNNING
		destroy_state_event(&event)
		if started {
			return true
		}
	}
	return false
}

// The Register keeps only current status; the reason for a failure is in the
// Receipt. Returns the latest event detail per Shot, aligned with register.shots.
last_details :: proc(brew_dir: string, register: Register) -> []string {
	details := make([]string, len(register.shots))
	path := state_file_path(brew_dir, RECEIPT_FILE_NAME)
	defer delete(path)
	data, read_err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	if read_err != nil {
		return details
	}
	remaining := string(data)
	for line in strings.split_lines_iterator(&remaining) {
		event: State_Event
		if json.unmarshal_string(line, &event, .JSON) != nil {
			destroy_state_event(&event)
			continue
		}
		if index := find_shot(register, event.shot_id); index >= 0 {
			delete(details[index])
			details[index] = strings.clone(event.detail)
		}
		destroy_state_event(&event)
	}
	return details
}

delete_details :: proc(details: []string) {
	for detail in details {
		delete(detail)
	}
	delete(details)
}

read_shot_report :: proc(brew_dir, shot_id: string) -> string {
	reports_dir := state_file_path(brew_dir, "reports")
	defer delete(reports_dir)
	name := strings.concatenate({shot_id, ".md"})
	defer delete(name)
	path := state_file_path(reports_dir, name)
	defer delete(path)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		delete(data)
		return ""
	}
	return strings.trim_space(string(data)) == "" ? "" : string(data)
}

// Lists uncommitted changes in a Station. A missing or unreadable Station is
// reported as such rather than as "no changes".
station_changes :: proc(station_path: string) -> string {
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{
		command = []string{"git", "-C", station_path, "status", "--short"},
	}, context.allocator)
	defer delete(stderr)
	if err != nil || !state.success {
		delete(stdout)
		return strings.clone("(could not read Station changes)")
	}
	if strings.trim_space(string(stdout)) == "" {
		delete(stdout)
		return strings.clone("(none)")
	}
	return string(stdout)
}
