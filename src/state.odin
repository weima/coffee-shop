package main

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

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
}

Register :: struct {
	schema_version: int,
	brew_id: string,
	beans_path: string,
	order: string,
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
}

Replay_Shot :: struct {
	status: string,
	cancel_requested: bool,
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
		destroy_register(&register, allocator)
		return Register{}, State_Error{kind = .Out_Of_Memory}
	}
	order_copy, order_err := strings.clone(recipe.order, allocator)
	register.order = order_copy
	if order_err != nil {
		destroy_register(&register, allocator)
		return Register{}, State_Error{kind = .Out_Of_Memory}
	}

	register.shots, alloc_err = make([dynamic]Register_Shot, 0, len(recipe.shots), allocator)
	if alloc_err != nil {
		destroy_register(&register, allocator)
		return Register{}, State_Error{kind = .Out_Of_Memory}
	}

	for shot in recipe.shots {
		id, clone_err := strings.clone(shot.id, allocator)
		if clone_err != nil {
			destroy_register(&register, allocator)
			return Register{}, State_Error{kind = .Out_Of_Memory}
		}
		prompt, prompt_err := strings.clone(shot.prompt, allocator)
		if prompt_err != nil {
			delete(id, allocator)
			destroy_register(&register, allocator)
			return Register{}, State_Error{kind = .Out_Of_Memory}
		}

		status, status_err := strings.clone(SHOT_QUEUED, allocator)
		if status_err != nil {
			delete(id, allocator)
			delete(prompt, allocator)
			destroy_register(&register, allocator)
			return Register{}, State_Error{kind = .Out_Of_Memory}
		}
		_, append_err := append(&register.shots, Register_Shot{
			id = id,
			prompt = prompt,
			status = status,
		})
		if append_err != nil {
			delete(id, allocator)
			delete(prompt, allocator)
			delete(status, allocator)
			destroy_register(&register, allocator)
			return Register{}, State_Error{kind = .Out_Of_Memory}
		}
	}

	return register, State_Error{}
}

destroy_register :: proc(register: ^Register, allocator := context.allocator) {
	previous_allocator := context.allocator
	context.allocator = allocator
	defer context.allocator = previous_allocator

	for shot in register.shots {
		delete(shot.id, allocator)
		delete(shot.prompt, allocator)
		delete(shot.status, allocator)
		if len(shot.station_path) > 0 {
			delete(shot.station_path, allocator)
		}
	}
	delete(register.shots)
	delete(register.brew_id, allocator)
	delete(register.beans_path, allocator)
	delete(register.order, allocator)
	register^ = Register{}
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
		return Register{}, State_Error{kind = .Corrupt_Register}
	}
	defer delete(register_data, allocator)

	if json.unmarshal_string(transmute(string)register_data, &register, .JSON, allocator) != nil || !valid_register(register) {
		destroy_register(&register, allocator)
		return Register{}, State_Error{kind = .Corrupt_Register}
	}

	receipt_data, receipt_io_err := os.read_entire_file(receipt_path, allocator)
	if receipt_io_err != nil {
		destroy_register(&register, allocator)
		delete(receipt_data, allocator)
		return Register{}, State_Error{kind = .Corrupt_Receipt}
	}
	defer delete(receipt_data, allocator)

	if conflict := validate_receipt(register, transmute(string)receipt_data, allocator); conflict.kind != .None {
		destroy_register(&register, allocator)
		return Register{}, conflict
	}
	return register, State_Error{}
}

transition_shot :: proc(
	directory: string,
	register: ^Register,
	shot_id, to_state, detail: string,
) -> State_Error {
	index := find_shot(register^, shot_id)
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
		return err
	}

	old_state := shot.status
	old_sequence := register.event_sequence
	shot.status = new_state
	register.event_sequence = event.sequence
	register_path := state_file_path(directory, REGISTER_FILE_NAME)
	defer delete(register_path)
	if err := write_register_atomic(register_path, register^); err.kind != .None {
		shot.status = old_state
		register.event_sequence = old_sequence
		delete(new_state)
		return err
	}
	delete(old_state)
	return State_Error{}
}

request_shot_cancel :: proc(directory: string, register: ^Register, shot_id, detail: string) -> State_Error {
	index := find_shot(register^, shot_id)
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
		if shot.status != expected[i].status || shot.cancel_requested != expected[i].cancel_requested {
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
	case:
		return false
	}
	return true
}

verify_current_state :: proc(directory: string, register: Register) -> State_Error {
	current, err := read_state(directory)
	defer destroy_register(&current)
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

valid_register :: proc(register: Register) -> bool {
	if register.schema_version != STATE_SCHEMA_VERSION || register.event_sequence < 0 || !valid_shot_id(register.brew_id) || strings.trim_space(register.beans_path) == "" || strings.trim_space(register.order) == "" || len(register.shots) == 0 {
		return false
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
	case: return ""
	}
}

valid_shot_status :: proc(status: string) -> bool {
	return status == SHOT_QUEUED || status == SHOT_RUNNING || status == SHOT_COMPLETED || status == SHOT_FAILED || status == SHOT_CANCELLED || status == SHOT_INTERRUPTED
}

valid_transition :: proc(from, to: string) -> bool {
	switch from {
	case SHOT_QUEUED:
		return to == SHOT_RUNNING || to == SHOT_FAILED || to == SHOT_CANCELLED
	case SHOT_RUNNING:
		return to == SHOT_COMPLETED || to == SHOT_FAILED || to == SHOT_CANCELLED || to == SHOT_INTERRUPTED
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
