package main

import "core:encoding/json"
import "core:os"
import "core:strings"

Recipe :: struct {
	order: string,
	shots: [dynamic]Shot,
}

Shot :: struct {
	id:     string,
	prompt: string,
}

MAX_SHOT_ID_LENGTH :: 64

load_recipe :: proc(path: string, allocator := context.allocator) -> (recipe: Recipe, err: string) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		delete(data, allocator)
		return Recipe{}, "could not read Recipe file"
	}
	defer delete(data, allocator)

	return parse_recipe(transmute(string)data, allocator)
}

is_git_repository :: proc(path: string, allocator := context.allocator) -> (valid: bool, err: string) {
	state, stdout, stderr, run_err := os.process_exec(os.Process_Desc{
		command = []string{"git", "-C", path, "rev-parse", "--is-inside-work-tree"},
	}, allocator)
	defer delete(stdout, allocator)
	defer delete(stderr, allocator)

	if run_err != nil {
		return false, "could not run git to validate Beans repository"
	}
	return state.success && state.exit_code == 0 && strings.trim_space(transmute(string)stdout) == "true", ""
}

parse_recipe :: proc(data: string, allocator := context.allocator) -> (recipe: Recipe, err: string) {
	previous_allocator := context.allocator
	context.allocator = allocator
	defer context.allocator = previous_allocator

	if json.unmarshal_string(data, &recipe, .JSON, allocator) != nil {
		destroy_recipe(&recipe, allocator)
		return Recipe{}, "recipe must be valid JSON"
	}

	if strings.trim_space(recipe.order) == "" {
		destroy_recipe(&recipe, allocator)
		return Recipe{}, "order must not be empty"
	}
	if len(recipe.shots) == 0 {
		destroy_recipe(&recipe, allocator)
		return Recipe{}, "recipe must contain at least one shot"
	}

	for shot, i in recipe.shots {
		if !valid_shot_id(shot.id) {
			destroy_recipe(&recipe, allocator)
			return Recipe{}, "shot IDs must be safe path segments"
		}
		if strings.trim_space(shot.prompt) == "" {
			destroy_recipe(&recipe, allocator)
			return Recipe{}, "shot prompts must not be empty"
		}
		for previous in recipe.shots[:i] {
			if previous.id == shot.id {
				destroy_recipe(&recipe, allocator)
				return Recipe{}, "shot IDs must be unique"
			}
		}
	}

	return recipe, ""
}

destroy_recipe :: proc(recipe: ^Recipe, allocator := context.allocator) {
	previous_allocator := context.allocator
	context.allocator = allocator
	defer context.allocator = previous_allocator

	for shot in recipe.shots {
		delete(shot.id, allocator)
		delete(shot.prompt, allocator)
	}
	delete(recipe.shots)
	delete(recipe.order, allocator)
	recipe^ = Recipe{}
}

// Shot IDs are path-safe segments: 1–64 ASCII characters, starting with a
// letter or digit; later characters may also be '-' or '_'. A direct check is
// clearer here than compiling a regex for this small, fixed rule.
valid_shot_id :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > MAX_SHOT_ID_LENGTH {
		return false
	}

	for c, index in id {
		is_alphanumeric := 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9'
		// Keep punctuation out of the first character; only later positions
		// may contain '-' or '_'.
		if index == 0 {
			if !is_alphanumeric {
				return false
			}
		} else if !is_alphanumeric && c != '-' && c != '_' {
			return false
		}
	}

	return true
}
