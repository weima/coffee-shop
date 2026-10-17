package main

import "core:fmt"
import "core:os"
import "core:time"

// One machine-wide concurrency limit shared by every Brew and Station process.
// Slot i is the file <state root>/machine-limit/slot-i.lock; holding the slot means
// holding an exclusive advisory flock on it. The kernel drops the lock when the holder
// exits, however it exits, so no pid or timestamp decides that a slot is free.

MACHINE_LIMIT_DIRECTORY :: "machine-limit"
MACHINE_LIMIT_POLL :: 100 * time.Millisecond

Machine_Slot :: struct {
	file:  ^os.File, // nil when the slot is not held
	index: int,
}

// Takes the first free slot of `limit`, without waiting. On failure `reason` says why.
machine_limit_try_acquire :: proc(root: string, limit: int) -> (slot: Machine_Slot, reason: string, ok: bool) {
	directory := state_file_path(root, MACHINE_LIMIT_DIRECTORY)
	defer delete(directory)
	if !os.exists(directory) && os.make_directory_all(directory, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return {}, fmt.aprintf("machine limit: cannot create %s", directory), false
	}
	for index in 0 ..< limit {
		if file, taken := machine_slot_try(directory, index); taken {
			return Machine_Slot{file = file, index = index}, "", true
		}
	}
	return {}, fmt.aprintf("machine limit: all %d slots are in use by other Brews or Stations", limit), false
}

// Waits up to `timeout` for a slot, sleeping between attempts. The last reason is returned on timeout.
machine_limit_acquire :: proc(root: string, limit: int, timeout: time.Duration) -> (slot: Machine_Slot, reason: string, ok: bool) {
	deadline := time.time_add(time.now(), timeout)
	for {
		slot, reason, ok = machine_limit_try_acquire(root, limit)
		if ok || time.diff(time.now(), deadline) <= 0 {
			return
		}
		delete(reason)
		time.sleep(MACHINE_LIMIT_POLL)
	}
}

machine_limit_release :: proc(slot: ^Machine_Slot) {
	if slot.file != nil {
		file_lock_release(slot.file)
		slot.file = nil
	}
}

machine_slot_try :: proc(directory: string, index: int) -> (file: ^os.File, ok: bool) {
	name := fmt.aprintf("slot-%d.lock", index)
	defer delete(name)
	path := state_file_path(directory, name)
	defer delete(path)
	opened, err := os.open(path, os.O_RDWR | os.O_CREATE, private_file_permissions())
	if err != nil {
		return nil, false
	}
	if !server_lock_try(opened) {
		_ = os.close(opened)
		return nil, false
	}
	return opened, true
}
