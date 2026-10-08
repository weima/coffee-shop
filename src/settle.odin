package main

import "core:os"
import "core:time"

// The supervisor is the only process that normally writes Brew state. Settling
// lets another process take over that job when the supervisor is gone.
SCALE :: 2
CANCEL_GRACE :: 10 * time.Second

Settle_Mode :: enum {
	// Record outcomes that are proven by evidence; leave live Workers alone.
	Observe,
	// Also cancel queued Shots and stop live Workers.
	Cancel,
}

is_terminal :: proc(status: string) -> bool {
	return status == SHOT_COMPLETED || status == SHOT_FAILED || status == SHOT_CANCELLED || status == SHOT_INTERRUPTED
}

all_terminal :: proc(register: Register) -> bool {
	for shot in register.shots {
		if !is_terminal(shot.status) {
			return false
		}
	}
	return true
}

cancel_marker_path :: proc(directory: string) -> string {
	return state_file_path(directory, "cancel.requested")
}

request_cancel :: proc(directory: string) -> bool {
	path := cancel_marker_path(directory)
	defer delete(path)
	return write_file_atomic(path, transmute([]byte)string("cancel requested\n"))
}

cancel_requested :: proc(directory: string) -> bool {
	path := cancel_marker_path(directory)
	defer delete(path)
	return os.exists(path)
}

supervisor_path :: proc(directory: string) -> string {
	return state_file_path(directory, "supervisor.json")
}

write_supervisor :: proc(directory: string) -> bool {
	path := supervisor_path(directory)
	defer delete(path)
	identity, ok := current_identity()
	if !ok {
		return false
	}
	return write_identity_file(path, identity)
}

// A missing supervisor file means a Brew with no supervisor to record Worker
// outcomes (a Brew from before the file existed, or one that crashed early), so
// that is Gone. A file that cannot be understood, or a /proc entry that cannot
// be read, is Unknown: it must not be taken as proof that the supervisor died.
supervisor_liveness :: proc(directory: string) -> Liveness {
	path := supervisor_path(directory)
	defer delete(path)
	identity, ok := read_identity_file(path)
	if !ok {
		if !os.exists(path) {
			return .Gone
		}
		return .Unknown
	}
	return identity_liveness(identity)
}

// True only on evidence that the supervisor is gone. Only then may another
// process take over its job of writing Brew state.
supervisor_gone :: proc(directory: string) -> bool {
	return supervisor_liveness(directory) == .Gone
}

// `liveness` decides whether a Worker's process is still there; tests substitute
// a stand-in to simulate a /proc entry that cannot be read.
Liveness_Proc :: proc(identity: Process_Identity) -> Liveness

settle_brew :: proc(directory: string, register: ^Register, herdr: string, mode: Settle_Mode, grace := CANCEL_GRACE, liveness: Liveness_Proc = identity_liveness) -> State_Error {
	for index in 0 ..< len(register.shots) {
		if err := settle_shot(directory, register, index, herdr, mode, grace, liveness); err.kind != .None {
			return err
		}
	}
	return State_Error{}
}

// Moves one Shot toward a terminal state using only evidence: the Worker's
// result file and its process identity. A Shot is never marked completed
// without a recorded successful result.
settle_shot :: proc(directory: string, register: ^Register, index: int, herdr: string, mode: Settle_Mode, grace: time.Duration, liveness: Liveness_Proc) -> State_Error {
	shot := &register.shots[index]
	if is_terminal(shot.status) {
		return State_Error{}
	}

	result_path := worker_result_path(directory, shot.id)
	defer delete(result_path)
	started_path := worker_started_path(directory, shot.id)
	defer delete(started_path)
	has_result := os.exists(result_path)
	has_started := os.exists(started_path)

	if shot.status == SHOT_QUEUED {
		if !has_result && !has_started {
			if mode != .Cancel {
				return State_Error{}
			}
			close_shot_tab(herdr, shot^)
			return transition_shot(directory, register, shot.id, SHOT_CANCELLED, "Brew cancelled before the Worker started")
		}
		if err := transition_shot(directory, register, shot.id, SHOT_RUNNING, "Worker started"); err.kind != .None {
			return err
		}
	}

	if has_result {
		return settle_from_result(directory, register, shot, result_path)
	}

	identity, has_identity := read_identity_file(started_path)
	// Record an exit only on evidence of one. A Worker whose liveness is unknown is
	// left running, never marked interrupted on a guess.
	if has_identity && liveness(identity) == .Gone {
		if shot.cancel_requested {
			return transition_shot(directory, register, shot.id, SHOT_CANCELLED, "Worker exited after cancellation was requested")
		}
		return transition_shot(directory, register, shot.id, SHOT_INTERRUPTED, "Worker exited without recording a result")
	}
	if mode != .Cancel {
		return State_Error{}
	}
	if !has_identity {
		return transition_shot(directory, register, shot.id, SHOT_INTERRUPTED, "Worker process could not be identified")
	}

	if !shot.cancel_requested {
		if err := request_shot_cancel(directory, register, shot.id, "Brew cancellation requested"); err.kind != .None {
			return err
		}
	}
	close_shot_tab(herdr, shot^)
	deadline := time.tick_now()
	for time.tick_diff(deadline, time.tick_now()) < grace {
		if liveness(identity) == .Gone || os.exists(result_path) {
			return transition_shot(directory, register, shot.id, SHOT_CANCELLED, "Worker exited after cancellation was requested")
		}
		time.sleep(50 * time.Millisecond)
	}
	return transition_shot(directory, register, shot.id, SHOT_INTERRUPTED, "Worker exit could not be confirmed after cancellation")
}

settle_from_result :: proc(directory: string, register: ^Register, shot: ^Register_Shot, result_path: string) -> State_Error {
	result, err := read_worker_result(result_path)
	defer destroy_worker_result(&result)
	if err != "" || result.brew_id != register.brew_id || result.shot_id != shot.id {
		return State_Error{kind = .Corrupt_Register}
	}
	// A pending cancellation may only resolve as cancelled or interrupted.
	if shot.cancel_requested {
		return transition_shot(directory, register, shot.id, SHOT_CANCELLED, "Worker finished after cancellation was requested")
	}
	next_state := SHOT_FAILED
	if result.started && result.success {
		next_state = SHOT_COMPLETED
	}
	return transition_shot(directory, register, shot.id, next_state, result.detail)
}

// Closing the Herdr tab hangs up the Worker's terminal, which ends Pi too.
close_shot_tab :: proc(herdr: string, shot: Register_Shot) {
	if shot.herdr_tab_id == "" {
		return
	}
	stdout, stderr, _ := run_herdr(herdr, []string{"tab", "close", shot.herdr_tab_id})
	delete(stdout)
	delete(stderr)
}
