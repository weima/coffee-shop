package main

import "core:testing"

@(test)
test_parse_valid_recipe :: proc(t: ^testing.T) {
	recipe, err := parse_recipe(`{"order":"Improve the CLI","shots":[{"id":"cli-test","prompt":"Add a parser test"},{"id":"cli-impl","prompt":"Implement the parser"}]}`)
	defer destroy_recipe(&recipe)

	testing.expect_value(t, err, "")
	testing.expect_value(t, recipe.order, "Improve the CLI")
	testing.expect_value(t, len(recipe.shots), 2)
	testing.expect_value(t, recipe.shots[0].id, "cli-test")
	testing.expect_value(t, recipe.shots[1].prompt, "Implement the parser")
}

@(test)
test_load_recipe_file :: proc(t: ^testing.T) {
	recipe, err := load_recipe("testdata/valid-recipe.json")
	defer destroy_recipe(&recipe)

	testing.expect_value(t, err, "")
	testing.expect_value(t, recipe.order, "Add a command parser test")
	testing.expect_value(t, len(recipe.shots), 1)
}

@(test)
test_load_recipe_rejects_missing_file :: proc(t: ^testing.T) {
	_, err := load_recipe("testdata/missing-recipe.json")

	testing.expect(t, err != "")
}

@(test)
test_validates_git_repository_path :: proc(t: ^testing.T) {
	valid, err := is_git_repository(".")
	testing.expect_value(t, err, "")
	testing.expect(t, valid)

	valid, err = is_git_repository("/tmp")
	testing.expect_value(t, err, "")
	testing.expect(t, !valid)
}

@(test)
test_recipe_requires_strict_json :: proc(t: ^testing.T) {
	reject_recipe(t, `{'order':'not JSON','shots':[{'id':'shot-1','prompt':'work'}]}`)
	reject_recipe(t, `{"order":`)
}

@(test)
test_recipe_requires_order_shots_and_prompt :: proc(t: ^testing.T) {
	reject_recipe(t, `{"shots":[{"id":"shot-1","prompt":"work"}]}`)
	reject_recipe(t, `{"order":"work","shots":[]}`)
	reject_recipe(t, `{"order":"work","shots":[{"id":"shot-1","prompt":"  "}]}`)
}

@(test)
test_recipe_rejects_duplicate_shot_ids :: proc(t: ^testing.T) {
	reject_recipe(t, `{"order":"work","shots":[{"id":"same","prompt":"one"},{"id":"same","prompt":"two"}]}`)
}

@(test)
test_recipe_rejects_unsafe_shot_ids :: proc(t: ^testing.T) {
	reject_recipe(t, `{"order":"work","shots":[{"id":"../escape","prompt":"work"}]}`)
	reject_recipe(t, `{"order":"work","shots":[{"id":"-option","prompt":"work"}]}`)
}

reject_recipe :: proc(t: ^testing.T, data: string) {
	recipe, err := parse_recipe(data)
	defer destroy_recipe(&recipe)
	testing.expect(t, err != "")
}
