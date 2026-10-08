package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

Recipe :: struct {
	order: string,
	order_file: string,
	preamble: string,
	preamble_file: string,
	model: string,
	thinking: string,
	review_model: string,
	review_thinking: string,
	workers: int,
	share: [dynamic]string,
	shots: [dynamic]Shot,
}

Shot :: struct {
	id: string,
	prompt: string,
	prompt_file: string,
	model: string,
	thinking: string,
	expect_changes: bool,
}

RECIPE_TEXT_MAX_BYTES :: 131071

MAX_SHOT_ID_LENGTH :: 64

load_recipe :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	recipe: Recipe,
	err: string,
) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		delete(data, allocator)
		return Recipe{}, "could not read Recipe file"
	}
	defer delete(data, allocator)

	parsed, parse_err := parse_recipe(transmute(string)data, allocator)
	if parse_err != "" { return parsed, parse_err }
	if input_err := resolve_recipe_inputs(&parsed, path, allocator); input_err != "" { destroy_struct(&parsed, allocator); return Recipe{}, input_err }
	return parsed, ""
}

is_git_repository :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	valid: bool,
	err: string,
) {
	state, stdout, stderr, run_err := os.process_exec(
		os.Process_Desc {
			command = []string{"git", "-C", path, "rev-parse", "--is-inside-work-tree"},
		},
		allocator,
	)
	defer delete(stdout, allocator)
	defer delete(stderr, allocator)

	if run_err != nil {
		return false, "could not run git to validate Beans repository"
	}
	if state.success && state.exit_code == 0 {
		return strings.trim_space(transmute(string)stdout) == "true", ""
	}

	// Git also fails for reasons other than "not a repository" (missing path,
	// permissions, unsafe ownership). Keep its message so the cause is visible.
	reason := strings.trim_space(transmute(string)stderr)
	if strings.contains(reason, "not a git repository") {
		return false, ""
	}
	if reason == "" {
		reason = "Git exited unsuccessfully"
	}
	return false, fmt.tprintf("Git could not inspect the Beans path: %s", reason)
}

parse_recipe :: proc(
	data: string,
	allocator := context.allocator,
) -> (
	recipe: Recipe,
	err: string,
) {
	previous_allocator := context.allocator
	context.allocator = allocator
	defer context.allocator = previous_allocator

	if json.unmarshal_string(data, &recipe, .JSON, allocator) != nil || !recipe_fields_known(data, allocator) {
		destroy_struct(&recipe, allocator)
		return Recipe{}, "recipe must be valid JSON with no unknown fields"
	}

	if (strings.trim_space(recipe.order) == "") == (recipe.order_file == "") {
		destroy_struct(&recipe, allocator)
		return Recipe{}, "recipe must have exactly one of order or order_file"
	}
	if len(recipe.order) > RECIPE_TEXT_MAX_BYTES {
		destroy_struct(&recipe, allocator)
		return Recipe{}, "inline order is over the 131071-byte limit; use order_file for longer text"
	}
	if recipe.workers == 0 {
		recipe.workers = 2
	}
	if recipe.workers < 1 || recipe.workers > 5 || !valid_model(recipe.model) || !valid_thinking(recipe.thinking) || !valid_model(recipe.review_model) || !valid_thinking(recipe.review_thinking) {
		destroy_struct(&recipe, allocator)
		return Recipe{}, "recipe model, thinking, or workers setting is invalid"
	}
	if recipe.preamble != "" && recipe.preamble_file != "" {
		destroy_struct(&recipe, allocator)
		return Recipe{}, "recipe preamble must use one input form"
	}
	if len(recipe.preamble) > RECIPE_TEXT_MAX_BYTES {
		destroy_struct(&recipe, allocator)
		return Recipe{}, "inline preamble is over the 131071-byte limit; use preamble_file for longer text"
	}
	if len(recipe.shots) == 0 {
		destroy_struct(&recipe, allocator)
		return Recipe{}, "recipe must contain at least one shot"
	}

	for path, index in recipe.share {
		if !valid_share_path(path) {
			destroy_struct(&recipe, allocator)
			return Recipe{}, "share paths must be relative paths inside the repository"
		}
		for previous in recipe.share[:index] {
			if previous == path {
				destroy_struct(&recipe, allocator)
				return Recipe{}, "share paths must be unique"
			}
		}
	}

	for shot, i in recipe.shots {
		if !valid_shot_id(shot.id) {
			destroy_struct(&recipe, allocator)
			return Recipe{}, "shot IDs must be safe path segments"
		}
		if len(shot.prompt) > RECIPE_TEXT_MAX_BYTES || (strings.trim_space(shot.prompt) == "") == (shot.prompt_file == "") {
			destroy_struct(&recipe, allocator)
			return Recipe{}, "each shot must have exactly one of prompt or prompt_file"
		}
		if !valid_model(shot.model) || !valid_thinking(shot.thinking) {
			destroy_struct(&recipe, allocator)
			return Recipe{}, "shot model or thinking setting is invalid"
		}
		for previous in recipe.shots[:i] {
			if previous.id == shot.id {
				destroy_struct(&recipe, allocator)
				return Recipe{}, "shot IDs must be unique"
			}
		}
	}

	return recipe, ""
}

// Shot IDs are path-safe segments: 1–64 ASCII characters, starting with a
// letter or digit; later characters may also be '-' or '_'. A direct check is
// clearer here than compiling a regex for this small, fixed rule.
valid_shot_id :: proc(id: string) -> bool {
	// 1. Strict length bounds check
	if len(id) == 0 || len(id) > MAX_SHOT_ID_LENGTH {
		return false
	}

	// 2. Validate the first character (must be ASCII letter or digit)
	// Accessing id[0] returns a single u8 byte
	switch id[0] {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
	// Valid first character
	case:
		return false
	}

	// 3. Validate remaining characters (treating string safely as bytes)
	for i := 1; i < len(id); i += 1 {
		switch id[i] {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_':
		// Valid character sequence
		case:
			return false
		}
	}

	return true
}

recipe_fields_known :: proc(data: string, allocator := context.allocator) -> bool {
	value, err := json.parse_string(data, .JSON, false, allocator)
	if err != .None { return false }
	defer json.destroy_value(value, allocator)
	root, ok := value.(json.Object)
	if !ok { return false }
	for key in root {
		if !slice.contains(RECIPE_ROOT_KEYS, key) { return false }
	}
	shots_value, found := root["shots"]
	shots, shots_ok := shots_value.(json.Array)
	if !found || !shots_ok { return true }
	for item in shots {
		object, ok := item.(json.Object)
		if !ok { return false }
		for key in object {
			if !slice.contains(RECIPE_SHOT_KEYS, key) { return false }
		}
	}
	return true
}

resolve_recipe_inputs :: proc(recipe: ^Recipe, recipe_path: string, allocator := context.allocator) -> string {
	absolute, abs_err := filepath.abs(recipe_path, allocator)
	if abs_err != nil { return "could not resolve Recipe directory" }
	defer delete(absolute, allocator)
	directory := absolute
	for i := len(absolute)-1; i >= 0; i -= 1 { if absolute[i] == '/' { directory = absolute[:i]; break } }
	if recipe.order_file != "" {
		text, err := read_recipe_text(directory, recipe.order_file, "order", allocator)
		if err != "" { return err }; recipe.order = text
	}
	if recipe.preamble_file != "" {
		text, err := read_recipe_text(directory, recipe.preamble_file, "preamble", allocator)
		if err != "" { return err }; recipe.preamble = text
	}
	for &shot in recipe.shots {
		if shot.prompt_file != "" {
			text, err := read_recipe_text(directory, shot.prompt_file, shot.id, allocator)
			if err != "" { return err }; shot.prompt = text
		}
	}
	return ""
}

read_recipe_text :: proc(directory, source, label: string, allocator := context.allocator) -> (text, err: string) {
	if source == "" || filepath.is_abs(source) || strings.contains_rune(source, '\\') { return "", fmt.tprintf("%s file path is invalid: %s", label, source) }
	segments := strings.split(source, "/", context.temp_allocator)
	for segment in segments { if segment == ".." || segment == "" || segment == "." { return "", fmt.tprintf("%s file path escapes the Recipe directory: %s", label, source) } }
	current := strings.clone(directory, allocator)
	defer delete(current, allocator)
	for segment in segments {
		next, part_err := filepath.join([]string{current, segment}, allocator)
		if part_err != nil { return "", fmt.tprintf("could not resolve %s file: %s", label, source) }
		delete(current, allocator); current = next
		info, stat_err := os.lstat(current, allocator)
		if stat_err == nil {
			is_link := info.type == .Symlink
			os.file_info_delete(info, allocator)
			if is_link { return "", fmt.tprintf("%s file path cannot traverse a symbolic link: %s", label, source) }
		}
	}
	path, join_err := filepath.join([]string{directory, source}, allocator)
	if join_err != nil { return "", fmt.tprintf("could not resolve %s file: %s", label, source) }
	defer delete(path, allocator)
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil { delete(data, allocator); return "", fmt.tprintf("%s file could not be read: %s", label, source) }
	if len(data) == 0 || len(data) > RECIPE_TEXT_MAX_BYTES || !utf8.valid_string(transmute(string)data) {
		delete(data, allocator); return "", fmt.tprintf("%s file is empty, over the 131071-byte limit, or not UTF-8: %s", label, source)
	}
	return transmute(string)data, ""
}

valid_thinking :: proc(level: string) -> bool {
	return level == "" || level == "off" || level == "minimal" || level == "low" || level == "medium" || level == "high" || level == "xhigh" || level == "max"
}

valid_model :: proc(model: string) -> bool {
	if model == "" { return true }
	for c in model {
		if c <= ' ' || c == '\'' || c == '"' || c == '\\' || c == '/' && model[0] == '/' {
			return false
		}
	}
	return true
}

// A share path is linked into every Station, so it must stay inside the
// repository: relative, made of plain segments, and never inside .git.
valid_share_path :: proc(path: string) -> bool {
	if path == "" || strings.contains_rune(path, '\\') || strings.has_prefix(path, "/") {
		return false
	}
	segments := strings.split(path, "/", context.temp_allocator)
	for segment, index in segments {
		if segment == "" || segment == "." || segment == ".." {
			return false
		}
		if index == 0 && segment == ".git" {
			return false
		}
	}
	return true
}

// Every key a Recipe or a Shot may contain. recipe.schema.json must declare exactly
// these; recipe_schema_test.odin checks that they agree.
RECIPE_ROOT_KEYS :: []string{"order", "order_file", "preamble", "preamble_file", "model", "thinking", "review_model", "review_thinking", "workers", "share", "shots"}
RECIPE_SHOT_KEYS :: []string{"id", "prompt", "prompt_file", "model", "thinking", "expect_changes"}
