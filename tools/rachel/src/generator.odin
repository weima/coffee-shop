package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

RACHEL_TEST_GENERATOR_ENV :: "RACHEL_TEST_GENERATOR"
GENERATOR_PROTOCOL_VERSION :: 1
GENERATOR_TIMEOUT :: 2 * time.Minute

Test_Generator_Request :: struct {
	protocol_version: int,
	kind: string,
	package_dir: string,
	source_path: string,
	procedure_name: string,
	procedure_line: int,
	source_text: string,
	test_path: string,
	existing_test_source: string,
}

Test_Generator_Response :: struct {
	protocol_version: int,
	imports: []string,
	test_source: string,
}

Test_Generator_Process_Result :: struct {
	state: os.Process_State,
	stdout: []byte,
	stderr: []byte,
	process_error: os.Error,
}

generate_tests_for_changed_procedures :: proc(
	generator_executable: string,
	before, after: Project_Snapshot,
	package_dir: string,
	allocator := context.allocator,
) -> (generated_count: int, err: os.Error) {
	for file in after.files {
		if file.package_dir != package_dir || strings.has_suffix(file.path, "_test.odin") || !odin_file_changed(before, file) {
			continue
		}
		for procedure in file.procedures {
			if procedure.is_test || !procedure.has_intent_comment {
				continue
			}
			generated, generate_err := generate_test_for_procedure(
				generator_executable,
				package_dir,
				file.path,
				procedure,
				allocator,
			)
			if generate_err != nil {
				err = generate_err
				return generated_count, err
			}
			if generated {
				generated_count += 1
			}
		}
	}
	return
}

generate_test_for_procedure :: proc(
	generator_executable, package_dir, source_path: string,
	procedure: Procedure_Declaration,
	allocator := context.allocator,
) -> (generated: bool, err: os.Error) {
	test_path, path_err := companion_test_path(source_path, allocator)
	if path_err != nil {
		return false, path_err
	}
	defer delete(test_path, allocator)
	existing_test_bytes, test_read_err := os.read_entire_file(test_path, allocator)
	if test_read_err != nil {
		fmt.eprintfln("[WARN] cannot generate a test for %s: its companion test file is not available", procedure.name)
		return false, nil
	}
	defer delete(existing_test_bytes, allocator)
	existing_test_source := transmute(string)existing_test_bytes
	if test_file_covers_procedure(existing_test_source, procedure.name, allocator) {
		return false, nil
	}
	if generator_executable == "" {
		fmt.eprintfln(
			"[WARN] no test generator configured; documented procedure %s in %s has no matching test (set %s)",
			procedure.name,
			source_path,
			RACHEL_TEST_GENERATOR_ENV,
		)
		return false, nil
	}

	source_bytes, source_read_err := os.read_entire_file(source_path, allocator)
	if source_read_err != nil {
		return false, source_read_err
	}
	defer delete(source_bytes, allocator)
	request := Test_Generator_Request{
		protocol_version = GENERATOR_PROTOCOL_VERSION,
		kind = "generate_odin_test",
		package_dir = package_dir,
		source_path = source_path,
		procedure_name = procedure.name,
		procedure_line = procedure.line,
		source_text = transmute(string)source_bytes,
		test_path = test_path,
		existing_test_source = existing_test_source,
	}
	request_json, marshal_err := json.marshal(request, json.Marshal_Options{spec = .JSON}, allocator)
	if marshal_err != nil {
		return false, os.Error(.Invalid_Command)
	}
	defer delete(request_json, allocator)

	generator_result, invoke_err := invoke_test_generator(generator_executable, package_dir, request_json, allocator)
	defer test_generator_process_result_destroy(&generator_result, allocator)
	if invoke_err != nil {
		fmt.eprintfln("[ERROR] test generator failed for %s: %s", procedure.name, os.error_string(invoke_err))
		if len(generator_result.stderr) > 0 {
			fmt.eprintln(transmute(string)generator_result.stderr)
		}
		return false, invoke_err
	}
	if !generator_result.state.success {
		fmt.eprintfln("[ERROR] test generator exited %d for %s", generator_result.state.exit_code, procedure.name)
		if len(generator_result.stderr) > 0 {
			fmt.eprintln(transmute(string)generator_result.stderr)
		}
		return false, os.Error(.Invalid_Command)
	}

	response: Test_Generator_Response
	unmarshal_err := json.unmarshal(generator_result.stdout, &response, .JSON, allocator)
	defer test_generator_response_destroy(&response, allocator)
	if unmarshal_err != nil {
		fmt.eprintfln("[ERROR] test generator returned invalid JSON for %s: %v", procedure.name, unmarshal_err)
		return false, os.Error(.Invalid_Command)
	}
	if response.protocol_version != GENERATOR_PROTOCOL_VERSION {
		fmt.eprintfln("[ERROR] test generator protocol version %d is unsupported", response.protocol_version)
		return false, os.Error(.Invalid_Command)
	}
	if !generated_test_source_valid(response.test_source, procedure.name, allocator) {
		fmt.eprintfln("[ERROR] test generator returned invalid test source for %s", procedure.name)
		return false, os.Error(.Invalid_Command)
	}

	current_source, current_source_err := os.read_entire_file(source_path, allocator)
	if current_source_err != nil {
		return false, current_source_err
	}
	defer delete(current_source, allocator)
	if string(current_source) != string(source_bytes) {
		fmt.eprintfln("[WARN] source %s changed during test generation; leaving its test file untouched", source_path)
		return false, nil
	}
	current_test, current_test_err := os.read_entire_file(test_path, allocator)
	if current_test_err != nil {
		fmt.eprintfln("[WARN] companion test %s changed during test generation; leaving it untouched", test_path)
		return false, nil
	}
	defer delete(current_test, allocator)
	if string(current_test) != existing_test_source {
		fmt.eprintfln("[WARN] companion test %s changed during test generation; leaving it untouched", test_path)
		return false, nil
	}
	if test_file_covers_procedure(transmute(string)current_test, procedure.name, allocator) {
		return false, nil
	}

	combined, combine_err := append_generated_test(
		transmute(string)current_test,
		response.imports,
		response.test_source,
		allocator,
	)
	if combine_err != nil {
		return false, combine_err
	}
	defer delete(combined, allocator)
	written, write_err := replace_test_file_if_unchanged(test_path, transmute(string)current_test, combined, allocator)
	if write_err != nil {
		fmt.eprintfln("[ERROR] cannot write generated test to %s: %s", test_path, os.error_string(write_err))
		return false, write_err
	}
	if written {
		fmt.eprintfln("[RACHEL] Generated test for %s in %s", procedure.name, test_path)
	}
	return written, nil
}

companion_test_path :: proc(source_path: string, allocator: runtime.Allocator) -> (string, os.Error) {
	if !strings.has_suffix(source_path, ".odin") || strings.has_suffix(source_path, "_test.odin") {
		return "", os.Error(.Invalid_Path)
	}
	return strings.concatenate({source_path[:len(source_path)-len(".odin")], "_test.odin"}, allocator)
}

test_file_covers_procedure :: proc(test_source, procedure_name: string, allocator: runtime.Allocator) -> bool {
	procedures, err := scan_procedure_declarations(test_source, allocator)
	if err != nil {
		return false
	}
	defer procedure_declarations_destroy(procedures, allocator)
	for procedure in procedures {
		if procedure.is_test && test_name_matches_procedure(procedure.name, procedure_name) {
			return true
		}
	}
	return false
}

@(private)
test_name_matches_procedure :: proc(test_name, procedure_name: string) -> bool {
	if !strings.has_prefix(test_name, "test_") {
		return false
	}
	suffix := test_name[len("test_"):]
	if suffix == procedure_name {
		return true
	}
	return len(suffix) > len(procedure_name) && strings.has_prefix(suffix, procedure_name) && suffix[len(procedure_name)] == '_'
}

@(private)
generated_test_source_valid :: proc(source, procedure_name: string, allocator: runtime.Allocator) -> bool {
	if strings.contains(source, "package ") || strings.contains(source, "import ") ||
		strings.contains(source, "#run") || strings.contains(source, "foreign import") {
		return false
	}
	procedures, err := scan_procedure_declarations(source, allocator)
	if err != nil {
		return false
	}
	defer procedure_declarations_destroy(procedures, allocator)
	if len(procedures) == 0 {
		return false
	}
	found_target_test := false
	for procedure in procedures {
		if !procedure.is_test {
			return false
		}
		if test_name_matches_procedure(procedure.name, procedure_name) {
			found_target_test = true
		}
	}
	return found_target_test
}

@(private)
append_generated_test :: proc(
	existing: string,
	imports: []string,
	test_source: string,
	allocator: runtime.Allocator,
) -> (combined: string, err: os.Error) {
	package_line_end := strings.index_byte(existing, '\n')
	if package_line_end < 0 || !strings.has_prefix(strings.trim_space(existing[:package_line_end]), "package ") {
		return "", os.Error(.Invalid_Command)
	}
	import_builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&import_builder)
	for import_path in imports {
		if !valid_generator_import(import_path) {
			return "", os.Error(.Invalid_Command)
		}
		quoted_path := fmt.aprintf("\"%s\"", import_path, allocator=allocator)
		defer delete(quoted_path, allocator)
		if existing_has_import(existing, quoted_path) || strings.contains(strings.to_string(import_builder), quoted_path) {
			continue
		}
		fmt.sbprintfln(&import_builder, "import \"%s\"", import_path)
	}
	combined_builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&combined_builder)
	strings.write_string(&combined_builder, existing[:package_line_end+1])
	strings.write_string(&combined_builder, strings.to_string(import_builder))
	strings.write_string(&combined_builder, existing[package_line_end+1:])
	if !strings.has_suffix(existing, "\n") {
		strings.write_byte(&combined_builder, '\n')
	}
	strings.write_byte(&combined_builder, '\n')
	strings.write_string(&combined_builder, test_source)
	if !strings.has_suffix(test_source, "\n") {
		strings.write_byte(&combined_builder, '\n')
	}
	combined = strings.clone(strings.to_string(combined_builder), allocator)
	return combined, nil
}

@(private)
replace_test_file_if_unchanged :: proc(
	path, expected_contents, replacement: string,
	allocator: runtime.Allocator,
) -> (written: bool, err: os.Error) {
	link_info, link_err := os.lstat(path, allocator)
	if link_err != nil {
		return false, link_err
	}
	is_link := link_info.type == .Symlink
	os.file_info_delete(link_info, allocator)
	if is_link {
		fmt.eprintfln("[WARN] companion test %s is a symbolic link; leaving it untouched", path)
		return false, nil
	}
	current, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		fmt.eprintfln("[WARN] companion test %s changed while generation ran; leaving it untouched", path)
		return false, nil
	}
	if string(current) != expected_contents {
		delete(current, allocator)
		fmt.eprintfln("[WARN] companion test %s changed while generation ran; leaving it untouched", path)
		return false, nil
	}
	delete(current, allocator)

	mode := os.Permissions_Default_File
	info, stat_err := os.stat(path, allocator)
	if stat_err == nil {
		mode = info.mode
		os.file_info_delete(info, allocator)
	}
	temp_dir, temp_err := os.make_directory_temp(filepath.dir(path), ".rachel-write-*", allocator)
	if temp_err != nil {
		return false, temp_err
	}
	defer {
		_ = os.remove_all(temp_dir)
		delete(temp_dir, allocator)
	}
	temp_path, path_err := filepath.join({temp_dir, filepath.base(path)}, allocator)
	if path_err != nil {
		return false, os.Error(path_err)
	}
	defer delete(temp_path, allocator)
	if write_err := os.write_entire_file_from_string(temp_path, replacement, mode); write_err != nil {
		return false, write_err
	}

	latest, latest_err := os.read_entire_file(path, allocator)
	if latest_err != nil {
		fmt.eprintfln("[WARN] companion test %s changed while generation ran; leaving it untouched", path)
		return false, nil
	}
	unchanged := string(latest) == expected_contents
	delete(latest, allocator)
	if !unchanged {
		fmt.eprintfln("[WARN] companion test %s changed while generation ran; leaving it untouched", path)
		return false, nil
	}
	if rename_err := os.rename(temp_path, path); rename_err != nil {
		return false, rename_err
	}
	return true, nil
}

@(private)
existing_has_import :: proc(source, quoted_import: string) -> bool {
	lines, err := strings.split_lines(source, context.temp_allocator)
	if err != nil {
		return false
	}
	defer delete(lines, context.temp_allocator)
	for line in lines {
		if strings.has_prefix(strings.trim_space(line), "import ") && strings.contains(line, quoted_import) {
			return true
		}
	}
	return false
}

@(private)
valid_generator_import :: proc(import_path: string) -> bool {
	if import_path == "" || strings.index_byte(import_path, 0) >= 0 ||
		strings.contains_rune(import_path, '\n') || strings.contains_rune(import_path, '\r') ||
		strings.contains_rune(import_path, '"') {
		return false
	}
	return true
}

@(private)
invoke_test_generator :: proc(
	executable, working_dir: string,
	request_json: []byte,
	allocator: runtime.Allocator,
) -> (result: Test_Generator_Process_Result, err: os.Error) {
	temp_dir, temp_err := os.make_directory_temp("", "rachel-generator-*", allocator)
	if temp_err != nil {
		return {}, temp_err
	}
	defer {
		_ = os.remove_all(temp_dir)
		delete(temp_dir, allocator)
	}
	request_path, path_err := filepath.join({temp_dir, "request.json"}, allocator)
	if path_err != nil {
		return {}, os.Error(path_err)
	}
	defer delete(request_path, allocator)
	stdout_path, stdout_path_err := filepath.join({temp_dir, "stdout.json"}, allocator)
	if stdout_path_err != nil {
		return {}, os.Error(stdout_path_err)
	}
	defer delete(stdout_path, allocator)
	stderr_path, stderr_path_err := filepath.join({temp_dir, "stderr.txt"}, allocator)
	if stderr_path_err != nil {
		return {}, os.Error(stderr_path_err)
	}
	defer delete(stderr_path, allocator)
	if write_err := os.write_entire_file_from_bytes(request_path, request_json, os.Permissions{.Read_User, .Write_User}); write_err != nil {
		return {}, write_err
	}
	stdin_file, open_err := os.open(request_path, {.Read})
	if open_err != nil {
		return {}, open_err
	}
	stdout_file, stdout_open_err := os.open(stdout_path, {.Write, .Create, .Trunc})
	if stdout_open_err != nil {
		_ = os.close(stdin_file)
		return {}, stdout_open_err
	}
	stderr_file, stderr_open_err := os.open(stderr_path, {.Write, .Create, .Trunc})
	if stderr_open_err != nil {
		_ = os.close(stdin_file)
		_ = os.close(stdout_file)
		return {}, stderr_open_err
	}
	process, start_err := os.process_start(os.Process_Desc{
		working_dir = working_dir,
		command = []string{executable},
		stdin = stdin_file,
		stdout = stdout_file,
		stderr = stderr_file,
	})
	stdin_close_err := os.close(stdin_file)
	stdout_close_err := os.close(stdout_file)
	stderr_close_err := os.close(stderr_file)
	if start_err != nil {
		return {}, start_err
	}
	if stdin_close_err != nil || stdout_close_err != nil || stderr_close_err != nil {
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
		return {}, os.Error(.Invalid_File)
	}
	result.state, err = os.process_wait(process, GENERATOR_TIMEOUT)
	if err != nil {
		wait_err := err
		_ = os.process_kill(process)
		_, cleanup_err := os.process_wait(process)
		if cleanup_err != nil {
			return result, cleanup_err
		}
		return result, wait_err
	}
	result.stdout, err = os.read_entire_file(stdout_path, allocator)
	if err != nil {
		return result, err
	}
	result.stderr, err = os.read_entire_file(stderr_path, allocator)
	if err != nil {
		delete(result.stdout, allocator)
		result.stdout = nil
		return result, err
	}
	return result, nil
}

test_generator_process_result_destroy :: proc(result: ^Test_Generator_Process_Result, allocator := context.allocator) {
	delete(result.stdout, allocator)
	delete(result.stderr, allocator)
	result^ = Test_Generator_Process_Result{}
}

test_generator_response_destroy :: proc(response: ^Test_Generator_Response, allocator := context.allocator) {
	for import_path in response.imports {
		delete(import_path, allocator)
	}
	delete(response.imports, allocator)
	delete(response.test_source, allocator)
	response^ = Test_Generator_Response{}
}
