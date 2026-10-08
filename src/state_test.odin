package main

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_state_round_trips_and_records_transitions :: proc(t: ^testing.T) {
	directory := make_test_state_directory(t)
	defer remove_test_state_directory(directory)

	register := make_test_register(t)
	defer destroy_register(&register)
	testing.expect_value(t, create_state(directory, &register).kind, State_Error_Kind.None)

	err := transition_shot(directory, &register, "shot-a", SHOT_RUNNING, "Worker started")
	testing.expect_value(t, err.kind, State_Error_Kind.None)
	err = transition_shot(directory, &register, "shot-a", SHOT_COMPLETED, "exit code 0")
	testing.expect_value(t, err.kind, State_Error_Kind.None)
	err = transition_shot(directory, &register, "shot-b", SHOT_FAILED, "Worker exited unsuccessfully")
	testing.expect_value(t, err.kind, State_Error_Kind.None)

	reloaded, read_err := read_state(directory)
	defer destroy_register(&reloaded)
	testing.expect_value(t, read_err.kind, State_Error_Kind.None)
	testing.expect_value(t, reloaded.event_sequence, 3)
	testing.expect_value(t, reloaded.shots[0].status, SHOT_COMPLETED)
	testing.expect_value(t, reloaded.shots[1].status, SHOT_FAILED)
}

@(test)
test_state_rejects_invalid_transition_without_mutation :: proc(t: ^testing.T) {
	directory := make_test_state_directory(t)
	defer remove_test_state_directory(directory)

	register := make_test_register(t)
	defer destroy_register(&register)
	testing.expect_value(t, create_state(directory, &register).kind, State_Error_Kind.None)

	err := transition_shot(directory, &register, "shot-a", SHOT_COMPLETED, "skip running")
	testing.expect_value(t, err.kind, State_Error_Kind.Invalid_Transition)
	testing.expect_value(t, register.shots[0].status, SHOT_QUEUED)

	reloaded, read_err := read_state(directory)
	defer destroy_register(&reloaded)
	testing.expect_value(t, read_err.kind, State_Error_Kind.None)
	testing.expect_value(t, reloaded.event_sequence, 0)
	testing.expect_value(t, reloaded.shots[0].status, SHOT_QUEUED)
}

@(test)
test_cancel_request_is_not_a_terminal_transition :: proc(t: ^testing.T) {
	directory := make_test_state_directory(t)
	defer remove_test_state_directory(directory)

	register := make_test_register(t)
	defer destroy_register(&register)
	_ = create_state(directory, &register)
	_ = transition_shot(directory, &register, "shot-a", SHOT_RUNNING, "Worker started")

	err := request_shot_cancel(directory, &register, "shot-a", "user requested cancellation")
	testing.expect_value(t, err.kind, State_Error_Kind.None)
	testing.expect_value(t, register.shots[0].status, SHOT_RUNNING)
	testing.expect(t, register.shots[0].cancel_requested)
	sequence := register.event_sequence
	err = request_shot_cancel(directory, &register, "shot-a", "repeated request")
	testing.expect_value(t, err.kind, State_Error_Kind.None)
	testing.expect_value(t, register.event_sequence, sequence)

	err = transition_shot(directory, &register, "shot-a", SHOT_COMPLETED, "exit code 0")
	testing.expect_value(t, err.kind, State_Error_Kind.Cancellation_Pending)
	err = transition_shot(directory, &register, "shot-a", SHOT_CANCELLED, "Worker exited")
	testing.expect_value(t, err.kind, State_Error_Kind.None)
}

@(test)
test_pending_cancel_can_become_interrupted_when_exit_is_unknown :: proc(t: ^testing.T) {
	directory := make_test_state_directory(t)
	defer remove_test_state_directory(directory)

	register := make_test_register(t)
	defer destroy_register(&register)
	_ = create_state(directory, &register)
	_ = transition_shot(directory, &register, "shot-a", SHOT_RUNNING, "Worker started")
	_ = request_shot_cancel(directory, &register, "shot-a", "user requested cancellation")

	err := transition_shot(directory, &register, "shot-a", SHOT_INTERRUPTED, "Worker exit could not be confirmed")
	testing.expect_value(t, err.kind, State_Error_Kind.None)
	reloaded, read_err := read_state(directory)
	defer destroy_register(&reloaded)
	testing.expect_value(t, read_err.kind, State_Error_Kind.None)
	testing.expect_value(t, reloaded.shots[0].status, SHOT_INTERRUPTED)
}

@(test)
test_transition_matrix_covers_all_terminal_outcomes :: proc(t: ^testing.T) {
	testing.expect(t, valid_transition(SHOT_QUEUED, SHOT_RUNNING))
	testing.expect(t, valid_transition(SHOT_QUEUED, SHOT_FAILED))
	testing.expect(t, valid_transition(SHOT_QUEUED, SHOT_CANCELLED))
	testing.expect(t, valid_transition(SHOT_RUNNING, SHOT_COMPLETED))
	testing.expect(t, valid_transition(SHOT_RUNNING, SHOT_FAILED))
	testing.expect(t, valid_transition(SHOT_RUNNING, SHOT_CANCELLED))
	testing.expect(t, valid_transition(SHOT_RUNNING, SHOT_INTERRUPTED))

	testing.expect(t, !valid_transition(SHOT_QUEUED, SHOT_COMPLETED))
	testing.expect(t, !valid_transition(SHOT_RUNNING, SHOT_QUEUED))
	testing.expect(t, !valid_transition(SHOT_COMPLETED, SHOT_FAILED))
	testing.expect(t, !valid_transition(SHOT_FAILED, SHOT_RUNNING))
	testing.expect(t, !valid_transition(SHOT_CANCELLED, SHOT_RUNNING))
	testing.expect(t, !valid_transition(SHOT_INTERRUPTED, SHOT_RUNNING))
}

@(test)
test_corrupt_records_are_reported_without_repair :: proc(t: ^testing.T) {
	directory := make_test_state_directory(t)
	defer remove_test_state_directory(directory)

	register := make_test_register(t)
	defer destroy_register(&register)
	_ = create_state(directory, &register)

	receipt_path := state_file_path(directory, RECEIPT_FILE_NAME)
	defer delete(receipt_path)
	_ = os.write_entire_file(receipt_path, `{"broken":`, os.Permissions{.Read_User, .Write_User})
	before, _ := os.read_entire_file(receipt_path, context.allocator)
	defer delete(before)

	_, err := read_state(directory)
	testing.expect_value(t, err.kind, State_Error_Kind.Malformed_Receipt)
	testing.expect_value(t, err.line, 1)

	after, read_err := os.read_entire_file(receipt_path, context.allocator)
	defer delete(after)
	testing.expect_value(t, read_err, os.Error(nil))
	testing.expect_value(t, string(after), string(before))
}

@(test)
test_corrupt_register_is_preserved :: proc(t: ^testing.T) {
	directory := make_test_state_directory(t)
	defer remove_test_state_directory(directory)

	register := make_test_register(t)
	defer destroy_register(&register)
	_ = create_state(directory, &register)

	register_path := state_file_path(directory, REGISTER_FILE_NAME)
	defer delete(register_path)
	_ = os.write_entire_file(register_path, `{"broken":`, os.Permissions{.Read_User, .Write_User})
	before, _ := os.read_entire_file(register_path, context.allocator)
	defer delete(before)

	_, err := read_state(directory)
	testing.expect_value(t, err.kind, State_Error_Kind.Corrupt_Register)
	after, read_err := os.read_entire_file(register_path, context.allocator)
	defer delete(after)
	testing.expect_value(t, read_err, os.Error(nil))
	testing.expect_value(t, string(after), string(before))
}

@(test)
test_create_state_does_not_overwrite_existing_brew :: proc(t: ^testing.T) {
	directory := make_test_state_directory(t)
	defer remove_test_state_directory(directory)

	register := make_test_register(t)
	defer destroy_register(&register)
	testing.expect_value(t, create_state(directory, &register).kind, State_Error_Kind.None)
	original_status := register.shots[0].status
	register.shots[0].status = SHOT_RUNNING
	testing.expect_value(t, create_state(directory, &register).kind, State_Error_Kind.Invalid_Register)
	register.shots[0].status = original_status
	testing.expect_value(t, create_state(directory, &register).kind, State_Error_Kind.Already_Exists)
}

@(test)
test_receipt_and_register_conflicts_are_unknown :: proc(t: ^testing.T) {
	directory := make_test_state_directory(t)
	defer remove_test_state_directory(directory)

	register := make_test_register(t)
	defer destroy_register(&register)
	_ = create_state(directory, &register)
	_ = transition_shot(directory, &register, "shot-a", SHOT_RUNNING, "Worker started")

	register_path := state_file_path(directory, REGISTER_FILE_NAME)
	defer delete(register_path)
	original_status := register.shots[0].status
	tampered_status, _ := strings.clone(SHOT_FAILED)
	register.shots[0].status = tampered_status
	_ = write_register_atomic(register_path, register)
	register.shots[0].status = original_status
	delete(tampered_status)

	_, err := read_state(directory)
	testing.expect_value(t, err.kind, State_Error_Kind.Conflicting_Records)
}

make_test_register :: proc(t: ^testing.T) -> Register {
	recipe, recipe_err := parse_recipe(`{"order":"Test state transitions","shots":[{"id":"shot-a","prompt":"Update state safely"},{"id":"shot-b","prompt":"Check a second independent Shot"}]}`)
	defer destroy_recipe(&recipe)
	testing.expect_value(t, recipe_err, "")

	register, err := register_from_recipe("brew-test", "/tmp/beans", recipe)
	testing.expect_value(t, err.kind, State_Error_Kind.None)
	return register
}

make_test_state_directory :: proc(t: ^testing.T) -> string {
	directory, err := os.make_directory_temp("", "coffee-shop-state-*", context.allocator)
	testing.expect_value(t, err, os.Error(nil))
	return directory
}

remove_test_state_directory :: proc(directory: string) {
	register_path := state_file_path(directory, REGISTER_FILE_NAME)
	defer delete(register_path)
	receipt_path := state_file_path(directory, RECEIPT_FILE_NAME)
	defer delete(receipt_path)
	temp_path := state_file_path(directory, REGISTER_TEMP_FILE_NAME)
	defer delete(temp_path)
	_ = os.remove(register_path)
	_ = os.remove(receipt_path)
	_ = os.remove(temp_path)
	_ = os.remove(directory)
	delete(directory)
}
