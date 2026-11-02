package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

// Reports are durably marked before relay and can be recovered after host restart.
host_report_make_durable :: proc(state_root, request_id, shot_id: string, report_kind: string) -> (ok: bool, err: string) {
	reports_dir, _ := filepath.join({state_root, "host", "reports"}, context.temp_allocator)
	if os.make_directory_all(reports_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil && !os.exists(reports_dir) {
		return false, "could not create reports directory"
	}
	report_file := fmt.aprintf("%s.%s.%s.json", request_id, shot_id, report_kind)
	defer delete(report_file)
	report_path, _ := filepath.join({reports_dir, report_file}, context.temp_allocator)
	if os.write_entire_file(report_path, "durable", private_file_permissions()) != nil {
		return false, "could not write durable report marker"
	}
	return true, ""
}

host_report_is_durable :: proc(state_root, request_id, shot_id, report_kind: string) -> bool {
	reports_dir, _ := filepath.join({state_root, "host", "reports"}, context.temp_allocator)
	report_file := fmt.aprintf("%s.%s.%s.json", request_id, shot_id, report_kind)
	defer delete(report_file)
	report_path, _ := filepath.join({reports_dir, report_file}, context.temp_allocator)
	return os.exists(report_path)
}
