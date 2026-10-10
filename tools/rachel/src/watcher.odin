package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

Procedure_Declaration :: struct {
	name: string,
	line: int,
	has_intent_comment: bool,
	is_test: bool,
}

Odin_File_Stamp :: struct {
	path: string,
	package_dir: string,
	size: i64,
	modified_at: time.Time,
	procedures: [dynamic]Procedure_Declaration,
}

Project_Snapshot :: struct {
	files: [dynamic]Odin_File_Stamp,
}

Odin_Command_Result :: struct {
	state: os.Process_State,
	stdout: []byte,
	stderr: []byte,
	process_error: os.Error,
}

run_odin_check :: proc(package_dir, odin_executable: string, allocator := context.allocator) -> Odin_Command_Result {
	return run_odin_command(package_dir, []string{odin_executable, "check", "-no-entry-point", "."}, allocator)
}

run_odin_test :: proc(package_dir, odin_executable: string, allocator := context.allocator) -> Odin_Command_Result {
	return run_odin_command(package_dir, []string{odin_executable, "test", "."}, allocator)
}

@(private)
run_odin_command :: proc(package_dir: string, argv: []string, allocator: runtime.Allocator) -> Odin_Command_Result {
	state, stdout, stderr, process_err := os.process_exec(
		os.Process_Desc{working_dir = package_dir, command = argv},
		allocator,
	)
	return Odin_Command_Result{state = state, stdout = stdout, stderr = stderr, process_error = process_err}
}

odin_test_has_allocator_leak :: proc(result: Odin_Command_Result) -> bool {
	return strings.contains(transmute(string)result.stdout, "+++ leak") ||
		strings.contains(transmute(string)result.stderr, "+++ leak")
}

odin_command_result_destroy :: proc(result: ^Odin_Command_Result, allocator := context.allocator) {
	delete(result.stdout, allocator)
	delete(result.stderr, allocator)
	result^ = Odin_Command_Result{}
}

scan_odin_project :: proc(
	root: string,
	allocator := context.allocator,
	previous: ^Project_Snapshot = nil,
) -> (snapshot: Project_Snapshot, err: os.Error) {
	if !os.is_dir(root) {
		return {}, os.Error(.Invalid_Dir)
	}
	snapshot.files = make([dynamic]Odin_File_Stamp, 0, allocator)
	if err = scan_odin_directory(root, &snapshot, previous, allocator); err != nil {
		project_snapshot_destroy(&snapshot, allocator)
		return {}, err
	}
	return snapshot, nil
}

@(private)
scan_odin_directory :: proc(
	directory: string,
	snapshot: ^Project_Snapshot,
	previous: ^Project_Snapshot,
	allocator: runtime.Allocator,
) -> os.Error {
	entries, read_err := os.read_all_directory_by_path(directory, allocator)
	if read_err != nil {
		return read_err
	}
	defer os.file_info_slice_delete(entries, allocator)

	for entry in entries {
		#partial switch entry.type {
		case .Directory:
			if should_skip_directory(entry.name) {
				continue
			}
			if err := scan_odin_directory(entry.fullpath, snapshot, previous, allocator); err != nil {
				return err
			}
		case .Regular:
			if !strings.has_suffix(entry.name, ".odin") {
				continue
			}
			path, path_err := strings.clone(entry.fullpath, allocator)
			if path_err != nil {
				return os.Error(path_err)
			}
			package_dir, dir_err := strings.clone(filepath.dir(entry.fullpath), allocator)
			if dir_err != nil {
				delete(path, allocator)
				return os.Error(dir_err)
			}
			stamp := Odin_File_Stamp{
				path = path,
				package_dir = package_dir,
				size = entry.size,
				modified_at = entry.modification_time,
			}
			previous_file: Odin_File_Stamp
			previous_found := false
			if previous != nil {
				previous_file, previous_found = find_odin_file(previous^, path)
			}
			if previous_found && same_odin_file(previous_file, stamp) {
				cloned_procedures, clone_err := clone_procedure_declarations(previous_file.procedures, allocator)
				if clone_err != nil {
					odin_file_stamp_destroy(&stamp, allocator)
					return os.Error(clone_err)
				}
				stamp.procedures = cloned_procedures
			} else if !strings.has_suffix(entry.name, "_test.odin") {
				data, file_err := os.read_entire_file(entry.fullpath, allocator)
				if file_err != nil {
					odin_file_stamp_destroy(&stamp, allocator)
					return file_err
				}
				procedures, parse_err := scan_procedure_declarations(transmute(string)data, allocator)
				delete(data, allocator)
				if parse_err != nil {
					odin_file_stamp_destroy(&stamp, allocator)
					return parse_err
				}
				stamp.procedures = procedures
			}
			_, append_err := append(&snapshot.files, stamp)
			if append_err != nil {
				odin_file_stamp_destroy(&stamp, allocator)
				return os.Error(append_err)
			}
		case:
			// Ignore symlinks and special files; only follow real directories.
		}
	}
	return nil
}

@(private)
should_skip_directory :: proc(name: string) -> bool {
	return name == ".git" || name == "build" || name == "dist" || name == "node_modules"
}

changed_package_dirs :: proc(
	before, after: Project_Snapshot,
	allocator := context.allocator,
) -> (directories: [dynamic]string, err: os.Error) {
	directories = make([dynamic]string, 0, allocator)
	transferred := false
	defer if !transferred { delete_string_slice(directories, allocator) }

	// ponytail: O(n²) snapshot comparison is adequate for local source trees; use a path index if measured scans become slow.
	for old_file in before.files {
		new_file, found := find_odin_file(after, old_file.path)
		if !found || !same_odin_file(old_file, new_file) {
			if err = append_unique_package(&directories, old_file.package_dir, allocator); err != nil {
				return nil, err
			}
		}
	}
	for new_file in after.files {
		_, found := find_odin_file(before, new_file.path)
		if !found {
			if err = append_unique_package(&directories, new_file.package_dir, allocator); err != nil {
				return nil, err
			}
		}
	}
	transferred = true
	return directories, nil
}

@(private)
find_odin_file :: proc(snapshot: Project_Snapshot, path: string) -> (Odin_File_Stamp, bool) {
	for file in snapshot.files {
		if file.path == path {
			return file, true
		}
	}
	return {}, false
}

same_odin_file :: proc(a, b: Odin_File_Stamp) -> bool {
	return a.size == b.size && a.modified_at == b.modified_at
}

odin_file_changed :: proc(before: Project_Snapshot, current: Odin_File_Stamp) -> bool {
	previous, found := find_odin_file(before, current.path)
	return !found || !same_odin_file(previous, current)
}

@(private)
append_unique_package :: proc(directories: ^[dynamic]string, package_dir: string, allocator: runtime.Allocator) -> os.Error {
	for existing in directories^ {
		if existing == package_dir {
			return nil
		}
	}
	cloned, clone_err := strings.clone(package_dir, allocator)
	if clone_err != nil {
		return os.Error(clone_err)
	}
	_, append_err := append(directories, cloned)
	if append_err != nil {
		delete(cloned, allocator)
		return os.Error(append_err)
	}
	return nil
}

clone_procedure_declarations :: proc(
	procedures: [dynamic]Procedure_Declaration,
	allocator: runtime.Allocator,
) -> (cloned: [dynamic]Procedure_Declaration, err: os.Error) {
	cloned = make([dynamic]Procedure_Declaration, 0, allocator)
	transferred := false
	defer if !transferred { procedure_declarations_destroy(cloned, allocator) }
	for procedure in procedures {
		name, clone_err := strings.clone(procedure.name, allocator)
		if clone_err != nil {
			return nil, os.Error(clone_err)
		}
		_, append_err := append(&cloned, Procedure_Declaration{
			name = name,
			line = procedure.line,
			has_intent_comment = procedure.has_intent_comment,
			is_test = procedure.is_test,
		})
		if append_err != nil {
			delete(name, allocator)
			return nil, os.Error(append_err)
		}
	}
	transferred = true
	return cloned, nil
}

project_snapshot_destroy :: proc(snapshot: ^Project_Snapshot, allocator := context.allocator) {
	for &file in snapshot.files {
		odin_file_stamp_destroy(&file, allocator)
	}
	delete(snapshot.files)
	snapshot^ = Project_Snapshot{}
}

@(private)
odin_file_stamp_destroy :: proc(file: ^Odin_File_Stamp, allocator: runtime.Allocator) {
	delete(file.path, allocator)
	delete(file.package_dir, allocator)
	procedure_declarations_destroy(file.procedures, allocator)
	file^ = Odin_File_Stamp{}
}

delete_string_slice :: proc(values: [dynamic]string, allocator := context.allocator) {
	for value in values {
		delete(value, allocator)
	}
	delete(values)
}

test_file_looks_like_production :: proc(source: string, allocator := context.allocator) -> bool {
	lines, split_err := strings.split_lines(source, allocator)
	if split_err != nil {
		return false
	}
	defer delete(lines, allocator)

	has_odin_test_attribute := false
	has_procedure_definition := false
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "//") {
			continue
		}
		if strings.contains(trimmed, "@(test") {
			has_odin_test_attribute = true
		}
		if strings.contains(trimmed, "::") && strings.contains(trimmed, "proc") {
			has_procedure_definition = true
		}
	}
	return has_procedure_definition && !has_odin_test_attribute
}

scan_procedure_declarations :: proc(
	source: string,
	allocator := context.allocator,
) -> (procedures: [dynamic]Procedure_Declaration, err: os.Error) {
	lines, split_err := strings.split_lines(source, allocator)
	if split_err != nil {
		return nil, os.Error(split_err)
	}
	defer delete(lines, allocator)
	procedures = make([dynamic]Procedure_Declaration, 0, allocator)
	transferred := false
	defer if !transferred { procedure_declarations_destroy(procedures, allocator) }

	pending_test_attribute := false
	for line, line_index in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "//") {
			continue
		}
		if strings.has_prefix(trimmed, "@(test") {
			pending_test_attribute = true
			continue
		}
		separator := strings.index(trimmed, "::")
		if separator < 0 {
			continue
		}
		declaration := strings.trim_space(trimmed[separator+2:])
		if !strings.has_prefix(declaration, "proc") {
			continue
		}
		name := strings.trim_space(trimmed[:separator])
		if name == "" {
			continue
		}
		owned_name, name_err := strings.clone(name, allocator)
		if name_err != nil {
			return nil, os.Error(name_err)
		}
		procedure := Procedure_Declaration{
			name = owned_name,
			line = line_index + 1,
			has_intent_comment = procedure_has_adjacent_comment(lines, line_index),
			is_test = pending_test_attribute,
		}
		pending_test_attribute = false
		_, append_err := append(&procedures, procedure)
		if append_err != nil {
			delete(owned_name, allocator)
			return nil, os.Error(append_err)
		}
	}
	transferred = true
	return procedures, nil
}

@(private)
procedure_has_adjacent_comment :: proc(lines: []string, procedure_line: int) -> bool {
	for index := procedure_line - 1; index >= 0; index -= 1 {
		line := strings.trim_space(lines[index])
		if line == "" || strings.has_prefix(line, "@(") {
			continue
		}
		if strings.has_prefix(line, "//") {
			return strings.trim_space(line[2:]) != ""
		}
		return false
	}
	return false
}

procedure_declarations_destroy :: proc(procedures: [dynamic]Procedure_Declaration, allocator := context.allocator) {
	for &procedure in procedures {
		delete(procedure.name, allocator)
	}
	delete(procedures)
}

new_procedure_contract_warnings :: proc(
	before, after: [dynamic]Procedure_Declaration,
	allocator := context.allocator,
) -> [dynamic]string {
	warnings := make([dynamic]string, 0, allocator)
	transferred := false
	defer if !transferred { delete_string_slice(warnings, allocator) }
	for procedure in after {
		if procedure.is_test || procedure.has_intent_comment || procedure_was_present(before, procedure.name) {
			continue
		}
		warning := fmt.aprintf(
			"[WARN] new procedure %s (line %d) has no intent comment",
			procedure.name,
			procedure.line,
			allocator=allocator,
		)
		_, append_err := append(&warnings, warning)
		if append_err != nil {
			delete(warning, allocator)
			return nil
		}
	}
	transferred = true
	return warnings
}

@(private)
procedure_was_present :: proc(procedures: [dynamic]Procedure_Declaration, name: string) -> bool {
	for procedure in procedures {
		if procedure.name == name {
			return true
		}
	}
	return false
}
