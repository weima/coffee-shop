package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

Odin_File_Stamp :: struct {
	path: string,
	package_dir: string,
	size: i64,
	modified_at: time.Time,
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

odin_test_result_success :: proc(result: Odin_Command_Result) -> bool {
	return odin_command_succeeded(result) && !odin_test_has_allocator_leak(result)
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
			_ = previous // the snapshot is a change check now, not a parse cache
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
	file^ = Odin_File_Stamp{}
}

delete_string_slice :: proc(values: [dynamic]string, allocator := context.allocator) {
	for value in values {
		delete(value, allocator)
	}
	delete(values)
}






