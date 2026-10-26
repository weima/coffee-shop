package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Persist pool state and recover owned panes after a crash.
// The pool persists the list of panes it owns so recovery can close
// exactly those panes, not inferring from process state or directory heuristics.

POOL_STATE_FILE :: "pool.json"

Pool_State :: struct {
	workspace_id:     string,
	capacity:         int,
	owned_pane_ids:   [dynamic]string,
	generation:       int, // Incremented on each startup for diagnosis
}

// Save pool state to disk before starting.
// This preserves which panes the host owns so recovery can close exactly those.
host_pool_persist :: proc(state_root: string) -> (ok: bool, err: string) {
	host_dir, _ := filepath.join({state_root, "host"}, context.temp_allocator)
	pool_state_path, _ := filepath.join({host_dir, POOL_STATE_FILE}, context.temp_allocator)

	// Serialize the pool state.
	owned_ids := host_pane_owned_ids()
	defer delete(owned_ids)

	state := Pool_State{
		workspace_id = strings.clone(host_pane_pool.workspace_id, context.temp_allocator),
		capacity = host_pane_pool.capacity,
		owned_pane_ids = owned_ids,
		generation = 1,
	}

	data, marshal_err := json.marshal(state)
	if marshal_err != nil {
		when ODIN_DEBUG {
			log.warnf("host_pool_persist: marshal error: %v", marshal_err)
		}
		return false, "could not serialize pool state"
	}
	defer delete(data)

	write_err := os.write_entire_file(pool_state_path, data, private_file_permissions())
	if write_err != nil {
		when ODIN_DEBUG {
			log.warnf("host_pool_persist: write error: %v", write_err)
		}
		return false, "could not write pool state"
	}

	when ODIN_DEBUG {
		log.debugf("host_pool_persist: saved pool state to %s (%d panes)", pool_state_path, len(owned_ids))
	}
	return true, ""
}

// Load persisted pool state and close owned panes that are still alive.
// Called at host startup to clean up from a previous crash.
host_pool_recover :: proc(state_root, herdr_exe: string) -> (ok: bool, err: string) {
	host_dir, _ := filepath.join({state_root, "host"}, context.temp_allocator)
	pool_state_path, _ := filepath.join({host_dir, POOL_STATE_FILE}, context.temp_allocator)

	// If no saved state, nothing to recover.
	if !os.exists(pool_state_path) {
		return true, ""
	}

	// Load and unmarshal the saved state.
	data, read_err := os.read_entire_file(pool_state_path, context.temp_allocator)
	if read_err != nil {
		when ODIN_DEBUG {
			log.warnf("host_pool_recover: read error: %v", read_err)
		}
		return true, "" // Non-fatal; just skip recovery
	}
	defer delete(data)

	state: Pool_State
	unmarshal_err := json.unmarshal(data, &state, .JSON, context.temp_allocator)
	if unmarshal_err != nil {
		when ODIN_DEBUG {
			log.warnf("host_pool_recover: unmarshal error: %v", unmarshal_err)
		}
		return true, "" // Non-fatal; malformed state is not an error
	}

	// Close all persisted owned panes.
	surface := session_surface_open(herdr_exe)
	closed_count := 0
	for j in 0..<len(state.owned_pane_ids) {
		pane_id := state.owned_pane_ids[j]
		if surface.ops.pane_close(surface, state.workspace_id, pane_id) {
			closed_count += 1
			when ODIN_DEBUG {
				log.debugf("host_pool_recover: closed pane %s", pane_id)
			}
		}
	}

	when ODIN_DEBUG {
		log.debugf("host_pool_recover: closed %d owned panes from previous session", closed_count)
	}

	// Clean up the saved state file.
	_ = os.remove(pool_state_path)

	return true, ""
}

// Mark a report as durable by writing it to a well-known location before relay.
// This ensures it survives a host crash and can be recovered on restart.
host_report_make_durable :: proc(state_root, request_id, shot_id: string, report_kind: string) -> (ok: bool, err: string) {
	// Report path: ~/.coffee-shop/host/reports/<request_id>.<shot_id>.<kind>.json
	reports_dir, _ := filepath.join({state_root, "host", "reports"}, context.temp_allocator)

	if os.make_directory_all(reports_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil && !os.exists(reports_dir) {
		return false, "could not create reports directory"
	}

	report_file := fmt.aprintf("%s.%s.%s.json", request_id, shot_id, report_kind)
	defer delete(report_file)

	report_path, _ := filepath.join({reports_dir, report_file}, context.temp_allocator)

	// Write a marker file to indicate the report is durable.
	// The full report is written separately by the caller.
	write_err := os.write_entire_file(report_path, "durable", private_file_permissions())
	if write_err != nil {
		return false, "could not write durable report marker"
	}

	when ODIN_DEBUG {
		log.debugf("host_report_make_durable: %s.%s.%s is durable", request_id, shot_id, report_kind)
	}
	return true, ""
}

// Check if a report is known to be durable (was written before the host crashed).
host_report_is_durable :: proc(state_root, request_id, shot_id, report_kind: string) -> bool {
	reports_dir, _ := filepath.join({state_root, "host", "reports"}, context.temp_allocator)
	report_file := fmt.aprintf("%s.%s.%s.json", request_id, shot_id, report_kind)
	defer delete(report_file)
	report_path, _ := filepath.join({reports_dir, report_file}, context.temp_allocator)
	return os.exists(report_path)
}
