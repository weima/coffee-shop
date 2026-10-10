package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_parse_valid_recipe :: proc(t: ^testing.T) {
	recipe, err := parse_recipe(`{"order":"Improve the CLI","shots":[{"id":"cli-test","prompt":"Add a parser test"},{"id":"cli-impl","prompt":"Implement the parser"}]}`)
	defer destroy_struct(&recipe)

	testing.expect_value(t, err, "")
	testing.expect_value(t, recipe.order, "Improve the CLI")
	testing.expect_value(t, len(recipe.shots), 2)
	testing.expect_value(t, recipe.shots[0].id, "cli-test")
	testing.expect_value(t, recipe.shots[1].prompt, "Implement the parser")
}

@(test)
test_recipe_schema_is_valid_json_and_declares_2020_12 :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("recipe.schema.json", context.allocator)
	defer delete(data)
	testing.expect_value(t, err, os.Error(nil))
	value, parse_err := json.parse_string(transmute(string)data, .JSON, false, context.allocator)
	defer json.destroy_value(value)
	testing.expect_value(t, parse_err, json.Error.None)
	testing.expect(t, strings.contains(transmute(string)data, "https://json-schema.org/draft/2020-12/schema"))
}

@(test)
test_recipe_schema_review_model_pattern_agrees_with_parser :: proc(t: ^testing.T) {
	data, _ := os.read_entire_file("recipe.schema.json", context.allocator)
	defer delete(data)
	value, _ := json.parse_string(transmute(string)data, .JSON, false, context.allocator)
	defer json.destroy_value(value)
	root, _ := value.(json.Object)
	properties, _ := root["properties"].(json.Object)
	review_model, _ := properties["review_model"].(json.Object)
	pattern, _ := review_model["pattern"].(json.String)
	// Same rule as valid_model: no ASCII control or space, no quotes or backslash, no leading slash.
	testing.expect_value(t, pattern, `^(|[^/\u0000-\u0020'"\\][^\u0000-\u0020'"\\]*)$`)

	recipe, err := parse_recipe(`{"order":"o","review_model":"openai/gpt-4o","shots":[{"id":"a","prompt":"p"}]}`)
	defer destroy_struct(&recipe)
	testing.expect_value(t, err, "")
	testing.expect_value(t, recipe.review_model, "openai/gpt-4o")
}

@(test)
test_load_recipe_file :: proc(t: ^testing.T) {
	recipe, err := load_recipe("testdata/valid-recipe.json")
	defer destroy_struct(&recipe)

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
test_recipe_text_files_resolve_relative_to_recipe_and_are_loaded :: proc(t: ^testing.T) {
	root, _ := os.make_directory_temp(TEMP_DIR, "coffee-shop-recipe-*", context.allocator)
	defer os.remove_all(root); defer delete(root)
	_ = os.make_directory_all(fmt.tprintf("%s/prompts", root))
	_ = os.write_entire_file(fmt.tprintf("%s/order.md", root), "order from file", os.Permissions{.Read_User, .Write_User})
	_ = os.write_entire_file(fmt.tprintf("%s/preamble.md", root), "shared rules", os.Permissions{.Read_User, .Write_User})
	_ = os.write_entire_file(fmt.tprintf("%s/prompts/a.md", root), "task from file", os.Permissions{.Read_User, .Write_User})
	path := fmt.tprintf("%s/recipe.json", root)
	_ = os.write_entire_file(path, `{"order_file":"order.md","preamble_file":"preamble.md","shots":[{"id":"a","prompt_file":"prompts/a.md"}]}`, os.Permissions{.Read_User, .Write_User})
	recipe, err := load_recipe(path)
	defer destroy_struct(&recipe)
	testing.expect_value(t, err, "")
	testing.expect_value(t, recipe.order, "order from file")
	testing.expect_value(t, recipe.preamble, "shared rules")
	testing.expect_value(t, recipe.shots[0].prompt, "task from file")
}

@(test)
test_recipe_rejects_unknown_fields_and_file_escape :: proc(t: ^testing.T) {
	reject_recipe(t, `{"order":"o","thinkng":"high","shots":[{"id":"a","prompt":"p"}]}`)
	root, _ := os.make_directory_temp(TEMP_DIR, "coffee-shop-recipe-*", context.allocator)
	defer os.remove_all(root); defer delete(root)
	path := fmt.tprintf("%s/recipe.json", root)
	_ = os.write_entire_file(path, `{"order_file":"../outside","shots":[{"id":"a","prompt":"p"}]}`, os.Permissions{.Read_User, .Write_User})
	_, err := load_recipe(path)
	testing.expect(t, err != "")
	_ = os.write_entire_file(fmt.tprintf("%s/external.md", root), "outside", os.Permissions{.Read_User, .Write_User})
	_ = os.symlink(fmt.tprintf("%s/external.md", root), fmt.tprintf("%s/link.md", root))
	_ = os.write_entire_file(path, `{"order":"o","shots":[{"id":"a","prompt_file":"link.md"}]}`, os.Permissions{.Read_User, .Write_User})
	_, symlink_err := load_recipe(path)
	testing.expect(t, symlink_err != "")
}

@(test)
test_validates_git_repository_path :: proc(t: ^testing.T) {
	valid, err := is_git_repository(".")
	testing.expect_value(t, err, "")
	testing.expect(t, valid)

	valid, err = is_git_repository(TEMP_DIR)
	testing.expect_value(t, err, "")
	testing.expect(t, !valid)
}

@(test)
test_git_failure_reports_the_reason_instead_of_a_plain_invalid_path :: proc(t: ^testing.T) {
	valid, err := is_git_repository("/nonexistent/coffee-shop-beans")
	testing.expect(t, !valid)
	testing.expect(t, strings.contains(err, "Git could not inspect the Beans path"), err)
	testing.expect(t, strings.contains(err, "/nonexistent/coffee-shop-beans"), err)
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
test_recipe_model_thinking_and_workers_settings :: proc(t: ^testing.T) {
	recipe, err := parse_recipe(`{"order":"work","model":"openai/gpt-4o","thinking":"high","workers":5,"shots":[{"id":"a","prompt":"p","model":"anthropic/claude","thinking":"low","expect_changes":true}]}`)
	defer destroy_struct(&recipe)
	testing.expect_value(t, err, "")
	testing.expect_value(t, recipe.workers, 5)
	testing.expect_value(t, recipe.shots[0].model, "anthropic/claude")
	testing.expect_value(t, recipe.shots[0].thinking, "low")
	testing.expect(t, recipe.shots[0].expect_changes)
}

@(test)
test_recipe_rejects_bad_settings :: proc(t: ^testing.T) {
	reject_recipe(t, `{"order":"o","thinking":"sometimes","shots":[{"id":"a","prompt":"p"}]}`)
	reject_recipe(t, `{"order":"o","model":"bad model","shots":[{"id":"a","prompt":"p"}]}`)
	reject_recipe(t, `{"order":"o","workers":6,"shots":[{"id":"a","prompt":"p"}]}`)
}

@(test)
test_recipe_rejects_unsafe_shot_ids :: proc(t: ^testing.T) {
	reject_recipe(t, `{"order":"work","shots":[{"id":"../escape","prompt":"work"}]}`)
	reject_recipe(t, `{"order":"work","shots":[{"id":"-option","prompt":"work"}]}`)
}

@(test)
test_recipe_rejects_oversized_inline_order :: proc(t: ^testing.T) {
	long := strings.repeat("a", RECIPE_TEXT_MAX_BYTES + 1, context.temp_allocator)
	data, _ := strings.concatenate({`{"order":"`, long, `","shots":[{"id":"a","prompt":"p"}]}`}, context.temp_allocator)
	expect_recipe_error(t, data, "inline order is over the 131071-byte limit; use order_file for longer text")

	limit := strings.repeat("a", RECIPE_TEXT_MAX_BYTES, context.temp_allocator)
	at_limit, _ := strings.concatenate({`{"order":"`, limit, `","shots":[{"id":"a","prompt":"p"}]}`}, context.temp_allocator)
	expect_recipe_error(t, at_limit, "")
}

@(test)
test_recipe_rejects_oversized_inline_preamble :: proc(t: ^testing.T) {
	long := strings.repeat("a", RECIPE_TEXT_MAX_BYTES + 1, context.temp_allocator)
	data, _ := strings.concatenate({`{"order":"o","preamble":"`, long, `","shots":[{"id":"a","prompt":"p"}]}`}, context.temp_allocator)
	expect_recipe_error(t, data, "inline preamble is over the 131071-byte limit; use preamble_file for longer text")
}

@(test)
test_recipe_requires_exactly_one_order_form :: proc(t: ^testing.T) {
	expect_recipe_error(t, `{"order":"o","order_file":"o.md","shots":[{"id":"a","prompt":"p"}]}`, "recipe must have exactly one of order or order_file")
	expect_recipe_error(t, `{"shots":[{"id":"a","prompt":"p"}]}`, "recipe must have exactly one of order or order_file")
	expect_recipe_error(t, `{"order":"   ","shots":[{"id":"a","prompt":"p"}]}`, "recipe must have exactly one of order or order_file")
}

@(test)
test_recipe_rejects_preamble_with_both_input_forms :: proc(t: ^testing.T) {
	expect_recipe_error(t, `{"order":"o","preamble":"p","preamble_file":"p.md","shots":[{"id":"a","prompt":"p"}]}`, "recipe preamble must use one input form")
}

expect_recipe_error :: proc(t: ^testing.T, data, expected: string, loc := #caller_location) {
	recipe, err := parse_recipe(data)
	defer destroy_struct(&recipe)
	testing.expect_value(t, err, expected, loc)
}

reject_recipe :: proc(t: ^testing.T, data: string) {
	recipe, err := parse_recipe(data)
	defer destroy_struct(&recipe)
	testing.expect(t, err != "")
}

@(test)
test_recipe_accepts_an_optional_share_list :: proc(t: ^testing.T) {
	recipe, err := parse_recipe(`{"order":"o","share":["node_modules","packages/web/node_modules","vendor/bundle"],"shots":[{"id":"a","prompt":"p"}]}`)
	defer destroy_struct(&recipe)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(recipe.share), 3)
	testing.expect_value(t, recipe.share[1], "packages/web/node_modules")

	plain, plain_err := parse_recipe(`{"order":"o","shots":[{"id":"a","prompt":"p"}]}`)
	defer destroy_struct(&plain)
	testing.expect_value(t, plain_err, "")
	testing.expect_value(t, len(plain.share), 0)
}

@(test)
test_recipe_rejects_unsafe_share_paths :: proc(t: ^testing.T) {
	for path in ([]string{`/etc`, `../outside`, `a/../b`, `a//b`, `./node_modules`, `node_modules/`, `.git`, `.git/hooks`, ``, `a\\b`}) {
		// Concatenate: Odin's fmt treats `{` in a format string as a directive.
		data, _ := strings.concatenate({`{"order":"o","share":["`, path, `"],"shots":[{"id":"a","prompt":"p"}]}`}, context.temp_allocator)
		recipe, err := parse_recipe(data)
		destroy_struct(&recipe)
		testing.expect(t, err == "share paths must be relative paths inside the repository", fmt.tprintf("path %q gave: %s", path, err))
	}
	dup, dup_err := parse_recipe(`{"order":"o","share":["node_modules","node_modules"],"shots":[{"id":"a","prompt":"p"}]}`)
	destroy_struct(&dup)
	testing.expect_value(t, dup_err, "share paths must be unique")
}
