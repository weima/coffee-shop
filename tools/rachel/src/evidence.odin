package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// A failing stage leaves a run directory here; a passing stage writes nothing.
EVIDENCE_ROOT :: ".rachel/evidence"
EVIDENCE_KEEP :: 10

Evidence_Manifest :: struct {
	stage:         string   `json:"stage"`,
	status:        string   `json:"status"`,
	recipe:        string   `json:"recipe"`,
	exit_code:     int      `json:"exit_code"`,
	started_ns:    i64      `json:"started_ns"`,
	duration_ms:   i64      `json:"duration_ms"`,
	tests:         int      `json:"tests"`,
	failure_count: int      `json:"failure_count"`,
	verdict:       []string `json:"verdict"`,
	paths:         []string `json:"paths"`,
}

// make_directory_all reports Exist for a directory that is already there, which is
// not a failure for a run directory that shares its parent.
@(private)
ensure_directory :: proc(path: string) -> bool {
	err := os.make_directory_all(path)
	return err == nil || err == os.Error(.Exist)
}

@(private)
evidence_base :: proc(root: string, allocator := context.allocator) -> (string, os.Error) {
	joined, join_err := filepath.join({root, EVIDENCE_ROOT}, allocator)
	if join_err != nil {
		return "", os.Error(join_err)
	}
	return joined, nil
}

// evidence_write records one failing stage. The run id is zero-padded nanos so a
// directory listing sorts oldest to newest.
evidence_write :: proc(
	root, stage, recipe: string,
	exit_code: int,
	started: time.Time,
	duration: time.Duration,
	tests, failure_count: int,
	verdict: []string,
	paths: []string,
	allocator := context.allocator,
) -> (dir: string, ok: bool) {
	base, base_err := evidence_base(root, allocator)
	if base_err != nil {
		return "", false
	}
	defer delete(base, allocator)
	if !ensure_directory(base) {
		return "", false
	}
	id := fmt.aprintf("%020d-%s", started._nsec, stage, allocator = context.allocator)
	defer delete(id, context.allocator)
	created, created_err := filepath.join({base, id}, allocator)
	if created_err != nil {
		return "", false
	}
	if !ensure_directory(created) {
		delete(created, allocator)
		return "", false
	}
	manifest := Evidence_Manifest {
		stage         = stage,
		status        = "fail",
		recipe        = recipe,
		exit_code     = exit_code,
		started_ns    = started._nsec,
		duration_ms   = i64(duration) / i64(time.Millisecond),
		tests         = tests,
		failure_count = failure_count,
		verdict       = verdict,
		paths         = paths,
	}
	data, marshal_err := json.marshal(manifest, allocator = context.allocator)
	if marshal_err != nil {
		_ = os.remove_all(created)
		delete(created, allocator)
		return "", false
	}
	defer delete(data, context.allocator)
	manifest_path, manifest_err := filepath.join({created, "manifest.json"}, context.allocator)
	if manifest_err != nil {
		_ = os.remove_all(created)
		delete(created, allocator)
		return "", false
	}
	defer delete(manifest_path, context.allocator)
	if write_err := os.write_entire_file_from_string(manifest_path, string(data), os.Permissions{.Read_User, .Write_User}); write_err != nil {
		_ = os.remove_all(created)
		delete(created, allocator)
		return "", false
	}
	verdict_path, verdict_path_err := filepath.join({created, "verdict.txt"}, context.allocator)
	if verdict_path_err == nil {
		defer delete(verdict_path, context.allocator)
		if body, body_err := strings.join(verdict, "\n", context.allocator); body_err == nil {
			defer delete(body, context.allocator)
			_ = os.write_entire_file_from_string(verdict_path, body, os.Permissions{.Read_User, .Write_User})
		}
	}
	evidence_prune(root, EVIDENCE_KEEP, context.allocator)
	return created, true
}

// evidence_prune keeps the newest run directories. Names sort by run id.
@(private)
evidence_prune :: proc(root: string, keep: int, allocator := context.allocator) {
	base, base_err := evidence_base(root, allocator)
	if base_err != nil {
		return
	}
	defer delete(base, allocator)
	entries, read_err := os.read_all_directory_by_path(base, allocator)
	if read_err != nil {
		return
	}
	defer os.file_info_slice_delete(entries, allocator)
	count := 0
	for i := len(entries) - 1; i >= 0; i -= 1 {
		if entries[i].type != .Directory {
			continue
		}
		count += 1
		if count <= keep {
			continue
		}
		old, join_err := filepath.join({base, entries[i].name}, allocator)
		if join_err != nil {
			continue
		}
		_ = os.remove_all(old)
		delete(old, allocator)
	}
}

// evidence_last returns the newest run directory, or ok=false when none exists.
evidence_last :: proc(root: string, allocator := context.allocator) -> (dir: string, ok: bool) {
	base, base_err := evidence_base(root, allocator)
	if base_err != nil {
		return "", false
	}
	defer delete(base, allocator)
	entries, read_err := os.read_all_directory_by_path(base, allocator)
	if read_err != nil {
		return "", false
	}
	defer os.file_info_slice_delete(entries, allocator)
	newest := ""
	for entry in entries {
		if entry.type != .Directory {
			continue
		}
		if newest == "" || entry.name > newest {
			newest = entry.name
		}
	}
	if newest == "" {
		return "", false
	}
	joined, join_err := filepath.join({base, newest}, allocator)
	if join_err != nil {
		return "", false
	}
	return joined, true
}
