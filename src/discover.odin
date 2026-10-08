package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "base:runtime"
import "core:strings"

Check_Kind :: enum { Unit, E2E }

Check_Command :: struct {
	kind: Check_Kind,
	argv: []string,
	source: string,
}

Discovery :: struct {
	commands: [dynamic]Check_Command,
	notes: [dynamic]string,
}

discover_candidate :: struct {
	kind: Check_Kind,
	argv: []string,
	source: string,
}

discover_checks :: proc(station_path: string, allocator := context.allocator) -> Discovery {
	previous_allocator := context.allocator
	context.allocator = allocator
	defer context.allocator = previous_allocator

	result := Discovery{}
	candidates := make([dynamic]discover_candidate, allocator=allocator)
	defer {
		for candidate in candidates {
			for arg in candidate.argv do delete(arg, allocator)
			delete(candidate.argv, allocator)
			delete(candidate.source, allocator)
		}
		delete(candidates)
	}

	recognized := false
	package_path := fmt.tprintf("%s/package.json", station_path)
	package_data, package_err := os.read_entire_file(package_path, allocator)
	if package_err == nil {
		recognized = true
		discover_package_json(&result, &candidates, transmute(string)package_data, station_path, allocator)
		delete(package_data, allocator)
	} else if discover_path_exists(station_path, "package.json", allocator) {
		recognized = true
		discover_add_note(&result, fmt.tprintf("could not read package.json: %v", package_err), allocator)
	}

	make_path := fmt.tprintf("%s/Makefile", station_path)
	make_data, make_err := os.read_entire_file(make_path, allocator)
	if make_err == nil {
		recognized = true
		discover_recipes(&candidates, transmute(string)make_data, "make", "Makefile", allocator)
		delete(make_data, allocator)
	} else if discover_path_exists(station_path, "Makefile", allocator) {
		recognized = true
		discover_add_note(&result, fmt.tprintf("could not read Makefile: %v", make_err), allocator)
	}

	// Just accepts these three spellings; the first one present is the one used.
	for name in ([]string{"justfile", "Justfile", ".justfile"}) {
		just_path := fmt.tprintf("%s/%s", station_path, name)
		just_data, just_err := os.read_entire_file(just_path, allocator)
		if just_err == nil {
			recognized = true
			discover_recipes(&candidates, transmute(string)just_data, "just", name, allocator)
			delete(just_data, allocator)
			break
		} else if discover_path_exists(station_path, name, allocator) {
			recognized = true
			discover_add_note(&result, fmt.tprintf("could not read %s: %v", name, just_err), allocator)
			break
		}
	}

	if discover_path_exists(station_path, "go.mod", allocator) {
		recognized = true
		discover_add_candidate(&candidates, .Unit, []string{"go", "test", "./..."}, "go.mod", allocator)
	}
	if discover_path_exists(station_path, "Cargo.toml", allocator) {
		recognized = true
		discover_add_candidate(&candidates, .Unit, []string{"cargo", "test"}, "Cargo.toml", allocator)
	}

	playwright_config := discover_has_playwright_config(station_path, allocator)
	if playwright_config {
		recognized = true
	}
	for kind in Check_Kind {
		count := 0
		for candidate in candidates {
			if candidate.kind == kind do count += 1
		}
		if count == 1 {
			for candidate in candidates {
				if candidate.kind == kind {
					source_copy, _ := strings.clone(candidate.source, allocator)
					command := Check_Command{kind=kind, source=source_copy}
					command.argv = make([]string, len(candidate.argv), allocator)
					for arg, i in candidate.argv {
						command.argv[i], _ = strings.clone(arg, allocator)
					}
					append(&result.commands, command)
					break
				}
			}
		} else if count > 1 {
			label := "unit"
			if kind == .E2E do label = "e2e"
			list := ""
			for candidate in candidates {
				if candidate.kind == kind {
					separator := ""
					if list != "" do separator = ", "
					list = fmt.tprintf("%s%s%s", list, separator, candidate.source)
				}
			}
			discover_add_note(&result, fmt.tprintf("ambiguous %s test commands: %s; none will be run", label, list), allocator)
		}
	}

	if playwright_config {
		has_e2e_command := false
		for command in result.commands {
			if command.kind == .E2E do has_e2e_command = true
		}
		if !has_e2e_command {
			discover_add_note(&result, "Playwright configuration exists but no e2e script is declared", allocator)
		}
	}
	if !recognized {
		discover_add_note(&result, "no recognized test configuration found", allocator)
	}
	return result
}

discover_package_json :: proc(result: ^Discovery, candidates: ^[dynamic]discover_candidate, data, station_path: string, allocator: runtime.Allocator) {
	root_value, parse_err := json.parse_string(data, .JSON, false, allocator)
	if parse_err != .None {
		discover_add_note(result, fmt.tprintf("malformed package.json: %v", parse_err), allocator)
		return
	}
	defer json.destroy_value(root_value, allocator)
	root, ok := root_value.(json.Object)
	if !ok {
		discover_add_note(result, "malformed package.json: root must be an object", allocator)
		return
	}
	scripts_value, has_scripts := root["scripts"]
	if !has_scripts do return
	scripts, scripts_ok := scripts_value.(json.Object)
	if !scripts_ok {
		discover_add_note(result, "malformed package.json: scripts must be an object", allocator)
		return
	}
	manager := discover_package_manager(root, station_path, allocator)
	if manager == "" {
		discover_add_note(result, "package manager is ambiguous; no package.json command will be proposed", allocator)
		return
	}
	for script, value in scripts {
		script_value, is_string := value.(json.String)
		if !is_string || script_value == "" do continue
		kind, matched := discover_script_kind(script)
		if !matched do continue
		discover_add_candidate(candidates, kind, []string{manager, "run", script}, fmt.tprintf("package.json scripts.%s", script), allocator)
	}
}

discover_script_kind :: proc(script: string) -> (kind: Check_Kind, matched: bool) {
	switch script {
	case "test", "test:unit": return .Unit, true
	case "test:e2e", "e2e", "test:playwright": return .E2E, true
	}
	return .Unit, false
}

discover_package_manager :: proc(root: json.Object, station_path: string, allocator: runtime.Allocator) -> string {
	if value, found := root["packageManager"]; found {
		if manager_value, ok := value.(json.String); ok {
			if strings.has_prefix(manager_value, "npm@") do return "npm"
			if strings.has_prefix(manager_value, "yarn@") do return "yarn"
			if strings.has_prefix(manager_value, "pnpm@") do return "pnpm"
			if strings.has_prefix(manager_value, "bun@") do return "bun"
		}
	}
	if discover_path_exists(station_path, "package-lock.json", allocator) do return "npm"
	if discover_path_exists(station_path, "yarn.lock", allocator) do return "yarn"
	if discover_path_exists(station_path, "pnpm-lock.yaml", allocator) do return "pnpm"
	if discover_path_exists(station_path, "bun.lock", allocator) || discover_path_exists(station_path, "bun.lockb", allocator) do return "bun"
	return ""
}

// Reads the recipe/target names a Makefile or justfile declares at the start of
// a line. A recipe that takes parameters (`test target:`) is skipped: a bare
// `just test` could not run it.
discover_recipes :: proc(candidates: ^[dynamic]discover_candidate, data, runner, file_name: string, allocator: runtime.Allocator) {
	lines, _ := strings.split_lines(data, allocator)
	defer delete(lines, allocator)
	for line in lines {
		for target in ([]string{"test", "e2e", "test-e2e"}) {
			if !strings.has_prefix(line, target) || !strings.has_prefix(line[len(target):], ":") {
				continue
			}
			kind := Check_Kind.Unit
			if target != "test" {
				kind = .E2E
			}
			source := fmt.tprintf("%s %s", file_name, target)
			discover_add_candidate(candidates, kind, []string{runner, target}, source, allocator)
		}
	}
}

discover_add_candidate :: proc(candidates: ^[dynamic]discover_candidate, kind: Check_Kind, argv: []string, source: string, allocator: runtime.Allocator) {
	source_copy, _ := strings.clone(source, allocator)
	candidate := discover_candidate{kind=kind, source=source_copy}
	candidate.argv = make([]string, len(argv), allocator)
	for arg, i in argv {
		candidate.argv[i], _ = strings.clone(arg, allocator)
	}
	append(candidates, candidate)
}

discover_add_note :: proc(result: ^Discovery, note: string, allocator: runtime.Allocator) {
	owned, _ := strings.clone(note, allocator)
	append(&result.notes, owned)
}

discover_path_exists :: proc(root, name: string, allocator: runtime.Allocator) -> bool {
	path := fmt.tprintf("%s/%s", root, name)
	info, err := os.stat(path, allocator)
	if err != nil do return false
	os.file_info_delete(info, allocator)
	return true
}

discover_has_playwright_config :: proc(root: string, allocator: runtime.Allocator) -> bool {
	entries, err := os.read_all_directory_by_path(root, allocator)
	if err != nil do return false
	defer {
		for entry in entries do os.file_info_delete(entry, allocator)
		delete(entries)
	}
	for entry in entries {
		name := entry.name
		if name == "playwright.config.ts" || name == "playwright.config.js" || name == "playwright.config.mjs" || name == "playwright.config.cjs" || name == "playwright.config.mts" || name == "playwright.config.cts" do return true
	}
	return false
}
