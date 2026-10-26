package main

import "core:fmt"
import "core:strings"

// Concurrency for the headless backend. The pane pool is not used (nothing is kept,
// cleared or reused); what must survive is the limit: at most `capacity` Stations per
// host, and the same machine-wide limit as the pool (machine_limit_try_acquire), so
// headless and Herdr hosts share one budget. A slot is held from acquire until the Shot's
// terminal report (headless_slot_release), as a pool pane's slot was.

Headless_Slot :: struct {
	key:  string,
	slot: Machine_Slot,
}

Headless_Slots :: struct {
	held:         [dynamic]Headless_Slot,
	capacity:     int,
	machine_root: string, // "" means no machine-wide limit
	last_refusal: string,
}

headless_slots: Headless_Slots

headless_slots_init :: proc(machine_root: string, capacity: int) {
	headless_slots = Headless_Slots{capacity = capacity, machine_root = strings.clone(machine_root)}
}

headless_slots_destroy :: proc() {
	for &entry in headless_slots.held {
		machine_limit_release(&entry.slot)
		delete(entry.key)
	}
	delete(headless_slots.held)
	delete(headless_slots.machine_root)
	delete(headless_slots.last_refusal)
	headless_slots = {}
}

// Returns the session key to use for the Shot, or ok=false when at the per-host or machine limit.
headless_slot_acquire :: proc(request_id, shot_id: string) -> (key: string, ok: bool) {
	delete(headless_slots.last_refusal)
	headless_slots.last_refusal = ""
	if len(headless_slots.held) >= headless_slots.capacity {
		return "", false
	}
	slot: Machine_Slot
	if headless_slots.machine_root != "" {
		reason: string
		slot, reason, ok = machine_limit_try_acquire(headless_slots.machine_root, headless_slots.capacity)
		headless_slots.last_refusal = reason
		if !ok {
			return "", false
		}
	}
	key = fmt.aprintf("%s/%s", request_id, shot_id)
	append(&headless_slots.held, Headless_Slot{key = strings.clone(key), slot = slot})
	return key, true
}

// Idempotent: releasing a key that holds nothing is a no-op that reports false.
headless_slot_release :: proc(key: string) -> bool {
	for &entry, i in headless_slots.held {
		if entry.key == key {
			machine_limit_release(&entry.slot)
			delete(entry.key)
			unordered_remove(&headless_slots.held, i)
			return true
		}
	}
	return false
}
