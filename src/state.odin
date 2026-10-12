package main

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

REGISTER_FILE_NAME :: "register.json"
REGISTER_TEMP_FILE_NAME :: "register.json.tmp"
RECEIPT_FILE_NAME :: "receipt.ndjson"
STATE_SCHEMA_VERSION :: 1

SHOT_QUEUED :: "queued"
SHOT_RUNNING :: "running"
SHOT_COMPLETED :: "completed"
SHOT_FAILED :: "failed"
SHOT_CANCELLED :: "cancelled"
SHOT_INTERRUPTED :: "interrupted"
SHOT_INCOMPLETE :: "incomplete"

State_Error_Kind :: enum {
	None,
	Invalid_Register,
	Already_Exists,
	Corrupt_Register,
	Corrupt_Receipt,
	Malformed_Receipt,
	Conflicting_Records,
	Invalid_Transition,
	Cancellation_Pending,
	Shot_Not_Found,
	IO_Error,
	Server_Unavailable,
	Server_Refused,
	Out_Of_Memory,
}

State_Error :: struct {
	kind: State_Error_Kind,
	line: int,
}

Register_Shot :: struct {
	id: string,
	prompt: string,
	status: string,
	cancel_requested: bool,
	station_path: string,
	model: string,
	thinking: string,
	expect_changes: bool,
	prompt_source: string,
	herdr_tab_id: string,
	herdr_pane_id: string,
	// Why the Shot last changed state, as recorded in the Receipt.
	detail: string,
	// What the Station reported about its own run, and the outcome it reported
	// when it finished (a Pull's commit hash or a failure reason). Both are
	// evidence from the Receipt; recording them never changes a status.
	usage:   Station_Usage,
	outcome: string,
}

// What a Station reported about its own run, from Pi's get_session_stats.
// `recorded` separates a reported all-zero session from no report at all, and
// `cost_known` is false when Pi could not price the model, so the cost must be
// shown as unavailable rather than as zero.
Station_Usage :: struct {
	input:       i64,
	output:      i64,
	cache_read:  i64,
	cache_write: i64,
	total:       i64,
	cost:        f64,
	cost_known:  bool,
	recorded:    bool,
}

Register :: struct {
	schema_version: int,
	brew_id: string,
	beans_path: string,
	repository_name: string,
	// Random, fixed for the Brew's life. Workers present it so a Worker from another
	// Brew on the same resource cannot be mistaken for one of this Brew's.
	brew_token: string,
	workers: int,
	model: string,
	thinking: string,
	review_model: string,
	review_thinking: string,
	completion_marker_required: bool,
	// Beans HEAD when the Brew started; Stations branch from it and the Filter
	// reviews changes against it. Empty in Registers written before it existed.
	base_commit: string,
	// Paths in the Beans repository linked into every Station (the Recipe's share list).
	share: [dynamic]string,
	herdr_workspace_id: string,
	order: string,
	order_source: string,
	preamble: string,
	preamble_source: string,
	event_sequence: int,
	shots: [dynamic]Register_Shot,
}

State_Event :: struct {
	sequence: int,
	kind: string,
	shot_id: string,
	from_state: string,
	to_state: string,
	detail: string,
	// A station_report carries the Station's usage and/or terminal outcome. The
	// flat fields and omitempty leave every transition line byte-for-byte as it
	// was, so a Receipt written before this existed still validates.
	usage_recorded:    bool   `json:"usage_recorded,omitempty"`,
	usage_input:       i64    `json:"usage_input,omitempty"`,
	usage_output:      i64    `json:"usage_output,omitempty"`,
	usage_cache_read:  i64    `json:"usage_cache_read,omitempty"`,
	usage_cache_write: i64    `json:"usage_cache_write,omitempty"`,
	usage_total:       i64    `json:"usage_total,omitempty"`,
	usage_cost:        f64    `json:"usage_cost,omitempty"`,
	usage_cost_known:  bool   `json:"usage_cost_known,omitempty"`,
	outcome:           string `json:"outcome,omitempty"`,
}

Replay_Shot :: struct {
	status: string,
	cancel_requested: bool,
	usage: Station_Usage,
}

register_from_recipe :: proc(
	brew_id, beans_path: string,
	recipe: Recipe,
	allocator := context.allocator,
) -> (register: Register, err: State_Error) {
	register.schema_version = STATE_SCHEMA_VERSION
	register.event_sequence = 0

	brew_id_copy, alloc_err := strings.clone(brew_id, allocator)
	register.brew_id = brew_id_copy
	if alloc_err != nil {
		return Register{}, State_Error{kind = .Out_Of_Memory}
	}
	beans_path_copy, beans_path_err := strings.clone(beans_path, allocator)
	register.beans_path = beans_path_copy
	if beans_path_err != nil {
		destroy_struct(&register, allocator)
		return Register{}, State_Error{kind = .Out_Of_Memory}
	}
	order_copy, order_err := strings.clone(recipe.order, allocator)
	register.order = order_copy
	if order_err != nil {
		destroy_struct(&register, allocator)
		return Register{}, State_Error{kind = .Out_Of_Memory}
	}

	register.workers = recipe.workers
	register.brew_token = brew_token(brew_id, allocator)
	register.completion_marker_required = true
	register.order_source, alloc_err = strings.clone(recipe.order_file, allocator)
	if alloc_err != nil { destroy_struct(&register, allocator); return Register{}, State_Error{kind = .Out_Of_Memory} }
	register.preamble, alloc_err = strings.clone(recipe.preamble, allocator)
	if alloc_err != nil { destroy_struct(&register, allocator); return Register{}, State_Error{kind = .Out_Of_Memory} }
	register.preamble_source, alloc_err = strings.clone(recipe.preamble_file, allocator)
	if alloc_err != nil { destroy_struct(&register, allocator); return Register{}, State_Error{kind = .Out_Of_Memory} }
	register.model, alloc_err = strings.clone(recipe.model, allocator)
	if alloc_err != nil { destroy_struct(&register, allocator); return Register{}, State_Error{kind = .Out_Of_Memory} }
	register.thinking, alloc_err = strings.clone(recipe.thinking, allocator)
	if alloc_err != nil { destroy_struct(&register, allocator); return Register{}, State_Error{kind = .Out_Of_Memory} }
	register.review_model, alloc_err = strings.clone(recipe.review_model, allocator)
	if alloc_err != nil { destroy_struct(&register, allocator); return Register{}, State_Error{kind = .Out_Of_Memory} }
	register.review_thinking, alloc_err = strings.clone(recipe.review_thinking, allocator)
	if alloc_err != nil { destroy_struct(&register, allocator); return Register{}, State_Error{kind = .Out_Of_Memory} }
	register.shots, alloc_err = make([dynamic]Register_Shot, 0, len(recipe.shots), allocator)
	if alloc_err != nil {
		destroy_struct(&register, allocator)
		return Register{}, State_Error{kind = .Out_Of_Memory}
	}

	for path in recipe.share {
		path_copy, path_err := strings.clone(path, allocator)
		if path_err != nil {
			destroy_struct(&register, allocator)
			return Register{}, State_Error{kind = .Out_Of_Memory}
		}
		_, append_err := append(&register.share, path_copy)
		if append_err != nil {
			delete(path_copy, allocator)
			destroy_struct(&register, allocator)
			return Register{}, State_Error{kind = .Out_Of_Memory}
		}
	}

	for shot in recipe.shots {
		id, clone_err := strings.clone(shot.id, allocator)
		if clone_err != nil {
			destroy_struct(&register, allocator)
			return Register{}, State_Error{kind = .Out_Of_Memory}
		}
		prompt, prompt_err := strings.clone(shot.prompt, allocator)
		if prompt_err != nil {
			delete(id, allocator)
			destroy_struct(&register, allocator)
			return Register{}, State_Error{kind = .Out_Of_Memory}
		}

		status, status_err := strings.clone(SHOT_QUEUED, allocator)
		if status_err != nil {
			delete(id, allocator)
			delete(prompt, allocator)
			destroy_struct(&register, allocator)
			return Register{}, State_Error{kind = .Out_Of_Memory}
		}
		model_value := shot.model
		if model_value == "" { model_value = recipe.model }
		thinking_value := shot.thinking
		if thinking_value == "" { thinking_value = recipe.thinking }
		model, model_err := strings.clone(model_value, allocator)
		thinking, thinking_err := strings.clone(thinking_value, allocator)
		if model_err != nil || thinking_err != nil {
			delete(id, allocator); delete(prompt, allocator); delete(status, allocator); delete(model, allocator); delete(thinking, allocator)
			destroy_struct(&register, allocator)
			return Register{}, State_Error{kind = .Out_Of_Memory}
		}
		prompt_source, source_err := strings.clone(shot.prompt_file, allocator)
		if source_err != nil { delete(id, allocator); delete(prompt, allocator); delete(status, allocator); delete(model, allocator); delete(thinking, allocator); destroy_struct(&register, allocator); return Register{}, State_Error{kind = .Out_Of_Memory} }
		_, append_err := append(&register.shots, Register_Shot{
			id = id,
			prompt = prompt,
			status = status,
			model = model,
			thinking = thinking,
			expect_changes = shot.expect_changes,
			prompt_source = prompt_source,
		})
		if append_err != nil {
			delete(id, allocator)
			delete(prompt, allocator)
			delete(status, allocator)
			destroy_struct(&register, allocator)
			return Register{}, State_Error{kind = .Out_Of_Memory}
		}
	}

	return register, State_Error{}
}

create_state :: proc(directory: string, register: ^Register) -> State_Error {
	if !valid_initial_register(register^) {
		return State_Error{kind = .Invalid_Register}
	}

	if !os.is_directory(directory) {
		if err := os.make_directory_all(directory, os.Permissions{.Read_User, .Write_User, .Execute_User}); err != nil {
			return State_Error{kind = .IO_Error}
		}
	}
	register_path := state_file_path(directory, REGISTER_FILE_NAME)
	defer delete(register_path)
	receipt_path := state_file_path(directory, RECEIPT_FILE_NAME)
	defer delete(receipt_path)
	temp_path := state_file_path(directory, REGISTER_TEMP_FILE_NAME)
	defer delete(temp_path)
	if os.exists(register_path) || os.exists(receipt_path) || os.exists(temp_path) {
		return State_Error{kind = .Already_Exists}
	}

	if err := os.write_entire_file(receipt_path, "", private_file_permissions()); err != nil {
		return State_Error{kind = .IO_Error}
	}
	return write_register_atomic(register_path, register^)
}

read_state :: proc(directory: string, allocator := context.allocator) -> (register: Register, err: State_Error) {
	register_path := state_file_path(directory, REGISTER_FILE_NAME, allocator)
	defer delete(register_path, allocator)
	receipt_path := state_file_path(directory, RECEIPT_FILE_NAME, allocator)
	defer delete(receipt_path, allocator)

	register_data, io_err := os.read_entire_file(register_path, allocator)
	if io_err != nil {
		delete(register_data, allocator)
		// A missing file means incomplete state; any other failure is an I/O
		// problem and must not be mistaken for corrupt content.
		if io_err == os.General_Error.Not_Exist {
			return Register{}, State_Error{kind = .Corrupt_Register}
		}
		return Register{}, State_Error{kind = .IO_Error}
	}
	defer delete(register_data, allocator)

	if json.unmarshal_string(transmute(string)register_data, &register, .JSON, allocator) != nil || !valid_register(register) {
		destroy_struct(&register, allocator)
		return Register{}, State_Error{kind = .Corrupt_Register}
	}

	receipt_data, receipt_io_err := os.read_entire_file(receipt_path, allocator)
	if receipt_io_err != nil {
		destroy_struct(&register, allocator)
		delete(receipt_data, allocator)
		if receipt_io_err == os.General_Error.Not_Exist {
			return Register{}, State_Error{kind = .Corrupt_Receipt}
		}
		return Register{}, State_Error{kind = .IO_Error}
	}
	defer delete(receipt_data, allocator)

	if conflict := validate_receipt(register, transmute(string)receipt_data, allocator); conflict.kind != .None {
		destroy_struct(&register, allocator)
		return Register{}, conflict
	}
	return register, State_Error{}
}

apply_transition :: proc(
	directory: string,
	register: ^Register,
	shot_id, to_state, detail: string,
) -> State_Error {	index := find_shot(register^, shot_id)
	if index < 0 {
		return State_Error{kind = .Shot_Not_Found}
	}
	shot := &register.shots[index]
	if !valid_transition(shot.status, to_state) {
		return State_Error{kind = .Invalid_Transition}
	}
	if shot.cancel_requested && to_state != SHOT_CANCELLED && to_state != SHOT_INTERRUPTED {
		return State_Error{kind = .Cancellation_Pending}
	}
	if err := verify_current_state(directory, register^); err.kind != .None {
		return err
	}

	new_state, clone_err := strings.clone(to_state)
	if clone_err != nil {
		return State_Error{kind = .Out_Of_Memory}
	}
	new_detail, detail_err := strings.clone(detail)
	if detail_err != nil {
		delete(new_state)
		return State_Error{kind = .Out_Of_Memory}
	}
	event := State_Event{
		sequence = register.event_sequence + 1,
		kind = "shot_transition",
		shot_id = shot_id,
		from_state = shot.status,
		to_state = to_state,
		detail = detail,
	}
	if err := append_receipt_event(directory, event); err.kind != .None {
		delete(new_state)
		delete(new_detail)
		return err
	}

	old_state := shot.status
	old_detail := shot.detail
	old_sequence := register.event_sequence
	shot.status = new_state
	shot.detail = new_detail
	register.event_sequence = event.sequence
	register_path := state_file_path(directory, REGISTER_FILE_NAME)
	defer delete(register_path)
	if err := write_register_atomic(register_path, register^); err.kind != .None {
		shot.status = old_state
		shot.detail = old_detail
		register.event_sequence = old_sequence
		delete(new_state)
		delete(new_detail)
		return err
	}
	delete(old_state)
	delete(old_detail)
	return State_Error{}
}

apply_request_shot_cancel :: proc(directory: string, register: ^Register, shot_id, detail: string) -> State_Error {	index := find_shot(register^, shot_id)
	if index < 0 {
		return State_Error{kind = .Shot_Not_Found}
	}
	shot := &register.shots[index]
	if shot.status != SHOT_RUNNING {
		return State_Error{kind = .Invalid_Transition}
	}
	if err := verify_current_state(directory, register^); err.kind != .None {
		return err
	}
	if shot.cancel_requested {
		return State_Error{}
	}

	event := State_Event{
		sequence = register.event_sequence + 1,
		kind = "cancel_requested",
		shot_id = shot_id,
		from_state = SHOT_RUNNING,
		to_state = SHOT_RUNNING,
		detail = detail,
	}
	if err := append_receipt_event(directory, event); err.kind != .None {
		return err
	}

	old_sequence := register.event_sequence
	shot.cancel_requested = true
	register.event_sequence = event.sequence
	register_path := state_file_path(directory, REGISTER_FILE_NAME)
	defer delete(register_path)
	if err := write_register_atomic(register_path, register^); err.kind != .None {
		shot.cancel_requested = false
		register.event_sequence = old_sequence
		return err
	}
	return State_Error{}
}

// Records what a Station reported about itself: its usage, its terminal outcome,
// or both. It never changes a Shot's status, so the rule that a Shot is only
// completed by a recorded result still holds. A report that carries neither is
// ignored without an event.
apply_station_report :: proc(directory: string, register: ^Register, shot_id, kind, detail: string) -> State_Error {
	index := find_shot(register^, shot_id)
	if index < 0 {
		return State_Error{kind = .Shot_Not_Found}
	}
	usage, has_usage := usage_from_report(kind, detail)
	outcome := outcome_from_report(kind, detail)
	if !has_usage && outcome == "" {
		return State_Error{}
	}
	shot := &register.shots[index]
	if err := verify_current_state(directory, register^); err.kind != .None {
		delete(outcome)
		return err
	}

	new_usage := shot.usage
	if has_usage {
		new_usage = usage
	}
	event := State_Event{
		sequence = register.event_sequence + 1,
		kind = "station_report",
		shot_id = shot_id,
		detail = detail,
		outcome = outcome,
	}
	if has_usage {
		event.usage_recorded = true
		event.usage_input = new_usage.input
		event.usage_output = new_usage.output
		event.usage_cache_read = new_usage.cache_read
		event.usage_cache_write = new_usage.cache_write
		event.usage_total = new_usage.total
		event.usage_cost = new_usage.cost
		event.usage_cost_known = new_usage.cost_known
	}
	if err := append_receipt_event(directory, event); err.kind != .None {
		delete(outcome)
		return err
	}

	old_usage := shot.usage
	old_outcome := shot.outcome
	old_sequence := register.event_sequence
	shot.usage = new_usage
	if outcome != "" {
		shot.outcome = outcome
	}
	register.event_sequence = event.sequence
	register_path := state_file_path(directory, REGISTER_FILE_NAME)
	defer delete(register_path)
	if err := write_register_atomic(register_path, register^); err.kind != .None {
		shot.usage = old_usage
		shot.outcome = old_outcome
		register.event_sequence = old_sequence
		delete(outcome)
		return err
	}
	if outcome != "" {
		delete(old_outcome)
	}
	return State_Error{}
}

// Parses the description the Station's usage report already sends:
// `input=N output=N cacheRead=N cacheWrite=N total=N cost=<number|unavailable>`.
usage_from_report :: proc(kind, detail: string) -> (usage: Station_Usage, ok: bool) {
	if kind != "usage" {
		return {}, false
	}
	parts := strings.split(detail, " ", context.temp_allocator)
	if len(parts) != 6 {
		return {}, false
	}
	names := [5]string{"input=", "output=", "cacheRead=", "cacheWrite=", "total="}
	values: [5]i64
	for name, index in names {
		if !strings.has_prefix(parts[index], name) {
			return {}, false
		}
		value, parsed := strconv.parse_i64(parts[index][len(name):])
		if !parsed {
			return {}, false
		}
		values[index] = value
	}
	cost_part := parts[5]
	if !strings.has_prefix(cost_part, "cost=") {
		return {}, false
	}
	cost := f64(0)
	cost_known := false
	cost_text := cost_part[len("cost="):]
	if cost_text != "unavailable" {
		value, parsed := strconv.parse_f64(cost_text)
		if !parsed {
			return {}, false
		}
		cost = value
		cost_known = true
	}
	return Station_Usage{
		input = values[0],
		output = values[1],
		cache_read = values[2],
		cache_write = values[3],
		total = values[4],
		cost = cost,
		cost_known = cost_known,
		recorded = true,
	}, true
}

// The Station's terminal reports. A Pull that passed Taste reports `pulled` with
// its short commit hash; the others report a failure reason. Anything else is not
// an outcome. The returned string is owned by the caller.
outcome_from_report :: proc(kind, detail: string) -> string {
	switch kind {
	case "pulled":
		return fmt.aprintf("pull %s", detail)
	case "taste_failed":
		return fmt.aprintf("taste failed: %s", detail)
	case "incomplete":
		return fmt.aprintf("incomplete: %s", detail)
	}
	return ""
}

// Reads the usage a station_report event carries. A transition event has none.
event_usage :: proc(event: State_Event) -> Station_Usage {
	if !event.usage_recorded {
		return {}
	}
	return Station_Usage{
		input = event.usage_input,
		output = event.usage_output,
		cache_read = event.usage_cache_read,
		cache_write = event.usage_cache_write,
		total = event.usage_total,
		cost = event.usage_cost,
		cost_known = event.usage_cost_known,
		recorded = true,
	}
}

validate_receipt :: proc(register: Register, receipt: string, allocator := context.allocator) -> State_Error {
	if len(receipt) > 0 && receipt[len(receipt)-1] != '\n' {
		line := 1
		for c in receipt {
			if c == '\n' {
				line += 1
			}
		}
		return State_Error{kind = .Malformed_Receipt, line = line}
	}

	expected, alloc_err := make([dynamic]Replay_Shot, 0, len(register.shots), allocator)
	if alloc_err != nil {
		return State_Error{kind = .Out_Of_Memory}
	}
	defer delete(expected)
	for _ in register.shots {
		_, alloc_err = append(&expected, Replay_Shot{status = SHOT_QUEUED})
		if alloc_err != nil {
			return State_Error{kind = .Out_Of_Memory}
		}
	}

	line_start := 0
	line_number := 1
	expected_sequence := 0
	for i := 0; i < len(receipt); i += 1 {
		if receipt[i] != '\n' {
			continue
		}
		line := receipt[line_start:i]
		if len(line) == 0 {
			return State_Error{kind = .Malformed_Receipt, line = line_number}
		}

		event: State_Event
		if json.unmarshal_string(line, &event, .JSON, allocator) != nil {
			destroy_state_event(&event, allocator)
			return State_Error{kind = .Malformed_Receipt, line = line_number}
		}
		if !apply_event(register, expected[:], event, expected_sequence+1) {
			destroy_state_event(&event, allocator)
			return State_Error{kind = .Conflicting_Records, line = line_number}
		}
		expected_sequence = event.sequence
		destroy_state_event(&event, allocator)
		line_start = i + 1
		line_number += 1
	}

	if expected_sequence != register.event_sequence {
		return State_Error{kind = .Conflicting_Records}
	}
	for shot, i in register.shots {
		if shot.status != expected[i].status || shot.cancel_requested != expected[i].cancel_requested || shot.usage != expected[i].usage {
			return State_Error{kind = .Conflicting_Records}
		}
	}
	return State_Error{}
}

apply_event :: proc(register: Register, expected: []Replay_Shot, event: State_Event, sequence: int) -> bool {
	if event.sequence != sequence {
		return false
	}
	index := find_shot(register, event.shot_id)
	if index < 0 {
		return false
	}
	state := &expected[index]

	switch event.kind {
	case "shot_transition":
		if event.from_state != state.status || !valid_transition(state.status, event.to_state) {
			return false
		}
		if state.cancel_requested && event.to_state != SHOT_CANCELLED && event.to_state != SHOT_INTERRUPTED {
			return false
		}
		state.status = canonical_shot_status(event.to_state)
	case "cancel_requested":
		if state.status != SHOT_RUNNING || state.cancel_requested || event.from_state != SHOT_RUNNING || event.to_state != SHOT_RUNNING {
			return false
		}
		state.cancel_requested = true
	case "station_report":
		if event.usage_recorded {
			state.usage = event_usage(event)
		}
	case:
		return false
	}
	return true
}

save_register_metadata :: proc(directory: string, register: Register) -> State_Error {	if err := verify_current_state(directory, register); err.kind != .None {
		return err
	}
	path := state_file_path(directory, REGISTER_FILE_NAME)
	defer delete(path)
	return write_register_atomic(path, register)
}

verify_current_state :: proc(directory: string, register: Register) -> State_Error {
	current, err := read_state(directory)
	defer destroy_struct(&current)
	if err.kind != .None {
		return err
	}
	if current.event_sequence != register.event_sequence || len(current.shots) != len(register.shots) {
		return State_Error{kind = .Conflicting_Records}
	}
	for shot, i in register.shots {
		if current.shots[i].id != shot.id || current.shots[i].status != shot.status || current.shots[i].cancel_requested != shot.cancel_requested {
			return State_Error{kind = .Conflicting_Records}
		}
	}
	return State_Error{}
}

append_receipt_event :: proc(directory: string, event: State_Event, allocator := context.allocator) -> State_Error {
	path := state_file_path(directory, RECEIPT_FILE_NAME, allocator)
	defer delete(path, allocator)

	data, marshal_err := json.marshal(event, json.Marshal_Options{spec = .JSON}, allocator)
	if marshal_err != nil {
		delete(data, allocator)
		return State_Error{kind = .IO_Error}
	}
	defer delete(data, allocator)

	line, alloc_err := make([]byte, len(data)+1, allocator)
	if alloc_err != nil {
		return State_Error{kind = .Out_Of_Memory}
	}
	defer delete(line, allocator)
	copy(line, data)
	line[len(data)] = '\n'

	return write_all_to_file(path, line, os.O_WRONLY|os.O_APPEND|os.O_CREATE)
}

write_register_atomic :: proc(path: string, register: Register, allocator := context.allocator) -> State_Error {
	directory, _ := filepath.split(path)
	temp_path := state_file_path(directory, REGISTER_TEMP_FILE_NAME, allocator)
	defer delete(temp_path, allocator)

	data, marshal_err := json.marshal(register, json.Marshal_Options{spec = .JSON, pretty = true}, allocator)
	if marshal_err != nil {
		delete(data, allocator)
		return State_Error{kind = .IO_Error}
	}
	defer delete(data, allocator)

	if err := write_all_to_file(temp_path, data, os.O_WRONLY|os.O_CREATE|os.O_TRUNC); err.kind != .None {
		_ = os.remove(temp_path)
		return err
	}
	if rename_err := os.rename(temp_path, path); rename_err != nil {
		_ = os.remove(temp_path)
		return State_Error{kind = .IO_Error}
	}
	return State_Error{}
}

write_all_to_file :: proc(path: string, data: []byte, flags: os.File_Flags) -> State_Error {
	file, open_err := os.open(path, flags, private_file_permissions())
	if open_err != nil {
		return State_Error{kind = .IO_Error}
	}

	written := 0
	for written < len(data) {
		count, write_err := os.write(file, data[written:])
		if write_err != nil || count <= 0 {
			_ = os.close(file)
			return State_Error{kind = .IO_Error}
		}
		written += count
	}
	if os.sync(file) != nil {
		_ = os.close(file)
		return State_Error{kind = .IO_Error}
	}
	if os.close(file) != nil {
		return State_Error{kind = .IO_Error}
	}
	return State_Error{}
}

valid_initial_register :: proc(register: Register) -> bool {
	if register.event_sequence != 0 || !valid_register(register) {
		return false
	}
	for shot in register.shots {
		if shot.status != SHOT_QUEUED || shot.cancel_requested {
			return false
		}
	}
	return true
}

// Sixteen random bytes as lowercase hex. Not a secret: it only tells apart Workers
// that share a resource.
random_token :: proc(allocator := context.allocator) -> string {
	bytes: [16]u8
	crypto.rand_bytes(bytes[:])
	digits := "0123456789abcdef"
	hex: [32]u8
	for b, i in bytes {
		hex[2*i] = digits[b>>4]
		hex[2*i+1] = digits[b&0xf]
	}
	token, _ := strings.clone(string(hex[:]), allocator)
	return token
}

// The Brew token is the Brew ID with a random GUID appended.
brew_token :: proc(brew_id: string, allocator := context.allocator) -> string {
	guid := random_token(context.temp_allocator)
	token, _ := strings.concatenate({brew_id, "-", guid}, allocator)
	return token
}

valid_register :: proc(register: Register) -> bool {
	if register.schema_version != STATE_SCHEMA_VERSION || register.event_sequence < 0 || !valid_shot_id(register.brew_id) || strings.trim_space(register.beans_path) == "" || strings.trim_space(register.order) == "" || len(register.shots) == 0 {
		return false
	}
	for path in register.share {
		if !valid_share_path(path) {
			return false
		}
	}
	for shot, i in register.shots {
		if !valid_shot_id(shot.id) || strings.trim_space(shot.prompt) == "" || !valid_shot_status(shot.status) {
			return false
		}
		if shot.cancel_requested && shot.status != SHOT_RUNNING && shot.status != SHOT_CANCELLED && shot.status != SHOT_INTERRUPTED {
			return false
		}
		for previous in register.shots[:i] {
			if previous.id == shot.id {
				return false
			}
		}
	}
	return true
}

canonical_shot_status :: proc(status: string) -> string {
	switch status {
	case SHOT_QUEUED: return SHOT_QUEUED
	case SHOT_RUNNING: return SHOT_RUNNING
	case SHOT_COMPLETED: return SHOT_COMPLETED
	case SHOT_FAILED: return SHOT_FAILED
	case SHOT_CANCELLED: return SHOT_CANCELLED
	case SHOT_INTERRUPTED: return SHOT_INTERRUPTED
	case SHOT_INCOMPLETE: return SHOT_INCOMPLETE
	case: return ""
	}
}

valid_shot_status :: proc(status: string) -> bool {
	return status == SHOT_QUEUED || status == SHOT_RUNNING || status == SHOT_COMPLETED || status == SHOT_FAILED || status == SHOT_CANCELLED || status == SHOT_INTERRUPTED || status == SHOT_INCOMPLETE
}

valid_transition :: proc(from, to: string) -> bool {
	switch from {
	case SHOT_QUEUED:
		return to == SHOT_RUNNING || to == SHOT_FAILED || to == SHOT_CANCELLED
	case SHOT_RUNNING:
		return to == SHOT_COMPLETED || to == SHOT_FAILED || to == SHOT_CANCELLED || to == SHOT_INTERRUPTED || to == SHOT_INCOMPLETE
	case:
		return false
	}
}

find_shot :: proc(register: Register, shot_id: string) -> int {
	for shot, i in register.shots {
		if shot.id == shot_id {
			return i
		}
	}
	return -1
}

destroy_state_event :: proc(event: ^State_Event, allocator := context.allocator) {
	delete(event.kind, allocator)
	delete(event.shot_id, allocator)
	delete(event.from_state, allocator)
	delete(event.to_state, allocator)
	delete(event.detail, allocator)
	delete(event.outcome, allocator)
	event^ = State_Event{}
}

state_file_path :: proc(directory, name: string, allocator := context.allocator) -> string {
	path, err := filepath.join([]string{directory, name}, allocator)
	assert(err == nil, "could not build Coffee Shop state path")
	return path
}

private_file_permissions :: proc() -> os.Permissions {
	return os.Permissions{.Read_User, .Write_User}
}

// read_state, after bringing the Register forward if the Receipt is ahead of it.
// The server writes the Receipt before the Register, so a crash between the two
// leaves the Receipt one or more events ahead. Replaying those events is safe:
// each one is checked against the state before it, as validate_receipt does.
read_state_recovering :: proc(directory: string, allocator := context.allocator) -> (register: Register, err: State_Error) {
	register, err = read_state(directory, allocator)
	if err.kind != .Conflicting_Records && err.kind != .Malformed_Receipt {
		return register, err
	}
	if recover_err := recover_receipt_ahead(directory); recover_err.kind != .None {
		return Register{}, recover_err
	}
	return read_state(directory, allocator)
}

// Rolls the Register forward over complete Receipt lines it has not yet recorded.
// A final line without its newline was never fully written, so it is ignored.
recover_receipt_ahead :: proc(directory: string) -> State_Error {
	register_path := state_file_path(directory, REGISTER_FILE_NAME)
	defer delete(register_path)
	register_data, register_io_err := os.read_entire_file(register_path, context.allocator)
	defer delete(register_data)
	if register_io_err != nil {
		return State_Error{kind = .Corrupt_Register}
	}
	register: Register
	defer destroy_struct(&register)
	if json.unmarshal_string(transmute(string)register_data, &register, .JSON) != nil || !valid_register(register) {
		return State_Error{kind = .Corrupt_Register}
	}

	receipt_path := state_file_path(directory, RECEIPT_FILE_NAME)
	defer delete(receipt_path)
	receipt_data, receipt_io_err := os.read_entire_file(receipt_path, context.allocator)
	defer delete(receipt_data)
	if receipt_io_err != nil {
		return State_Error{kind = .Corrupt_Receipt}
	}

	complete_end := 0
	for i := len(receipt_data); i > 0; i -= 1 {
		if receipt_data[i-1] == '\n' {
			complete_end = i
			break
		}
	}
	complete := receipt_data[:complete_end]
	if complete_end < len(receipt_data) && !write_file_atomic(receipt_path, complete) {
		return State_Error{kind = .IO_Error}
	}

	expected := make([dynamic]Replay_Shot, 0, len(register.shots))
	defer delete(expected)
	for shot in register.shots {
		append(&expected, Replay_Shot{status = shot.status, cancel_requested = shot.cancel_requested, usage = shot.usage})
	}

	sequence := register.event_sequence
	line_start := 0
	for i := 0; i < len(complete); i += 1 {
		if complete[i] != '\n' {
			continue
		}
		line := string(complete[line_start:i])
		line_start = i + 1

		event: State_Event
		if json.unmarshal_string(line, &event, .JSON) != nil {
			destroy_struct(&event)
			return State_Error{kind = .Malformed_Receipt}
		}
		if event.sequence <= register.event_sequence {
			destroy_struct(&event)
			continue
		}
		if !apply_event(register, expected[:], event, sequence+1) {
			destroy_struct(&event)
			return State_Error{kind = .Conflicting_Records}
		}
		sequence = event.sequence
		index := find_shot(register, event.shot_id)
		if event.kind != "station_report" {
			delete(register.shots[index].detail)
			register.shots[index].detail = strings.clone(event.detail)
		}
		if event.outcome != "" {
			delete(register.shots[index].outcome)
			register.shots[index].outcome = strings.clone(event.outcome)
		}
		destroy_struct(&event)
	}
	if sequence == register.event_sequence {
		return State_Error{}
	}

	for &shot, index in register.shots {
		if shot.status != expected[index].status {
			delete(shot.status)
			shot.status = strings.clone(expected[index].status)
		}
		shot.cancel_requested = expected[index].cancel_requested
		shot.usage = expected[index].usage
	}
	register.event_sequence = sequence
	if write_err := write_register_atomic(register_path, register); write_err.kind != .None {
		return write_err
	}
	return State_Error{}
}
