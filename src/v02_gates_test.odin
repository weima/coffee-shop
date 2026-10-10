package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

// recipe.schema.json, compiled in so the test needs no working directory.
RECIPE_SCHEMA :: #load("../recipe.schema.json", string)

@(test)
test_recipe_schema_and_parser_declare_the_same_keys :: proc(t: ^testing.T) {
	value, err := json.parse_string(RECIPE_SCHEMA, .JSON, false, context.allocator)
	testing.expect(t, err == .None, "the schema must be valid JSON")
	defer json.destroy_value(value, context.allocator)

	root, root_ok := value.(json.Object)
	testing.expect(t, root_ok, "the schema root must be an object")
	props, props_ok := root["properties"].(json.Object)
	testing.expect(t, props_ok, "the schema must declare root properties")
	shots, shots_ok := props["shots"].(json.Object)
	testing.expect(t, shots_ok, "the schema must declare shots")
	items, items_ok := shots["items"].(json.Object)
	testing.expect(t, items_ok, "shots must declare items")
	shot_props, shot_props_ok := items["properties"].(json.Object)
	testing.expect(t, shot_props_ok, "a Shot must declare properties")

	testing.expect_value(t, len(props), len(RECIPE_ROOT_KEYS))
	for key in RECIPE_ROOT_KEYS {
		testing.expect(t, key in props, key)
	}
	testing.expect_value(t, len(shot_props), len(RECIPE_SHOT_KEYS))
	for key in RECIPE_SHOT_KEYS {
		testing.expect(t, key in shot_props, key)
	}
}

// Recipe file inputs are validated before any Station exists. Each bad file is
// refused with an error, and no text comes back.
@(test)
test_recipe_text_files_reject_empty_non_utf8_and_oversized_content :: proc(t: ^testing.T) {
	directory, make_err := os.make_directory_temp(TEMP_DIR, "cs-text-*", context.allocator)
	testing.expect(t, make_err == nil, "a temporary directory is needed")
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	rw := os.Permissions{.Read_User, .Write_User}
	empty_path := strings.concatenate({directory, "/empty.md"})
	defer delete(empty_path)
	bad_path := strings.concatenate({directory, "/bad.md"})
	defer delete(bad_path)
	big_path := strings.concatenate({directory, "/big.md"})
	defer delete(big_path)
	good_path := strings.concatenate({directory, "/good.md"})
	defer delete(good_path)
	big_text := strings.repeat("a", RECIPE_TEXT_MAX_BYTES+1)
	defer delete(big_text)
	_ = os.write_entire_file_from_string(empty_path, "", rw)
	_ = os.write_entire_file_from_bytes(bad_path, []byte{0xff, 0xfe, 0x41}, rw)
	_ = os.write_entire_file_from_string(big_path, big_text, rw)
	_ = os.write_entire_file_from_string(good_path, "ok\n", rw)

	for name in ([]string{"empty.md", "bad.md", "big.md"}) {
		text, err := read_recipe_text(directory, name, "prompt")
		testing.expect(t, err != "", name)
		testing.expect_value(t, text, "")
	}
	text, err := read_recipe_text(directory, "good.md", "prompt")
	defer delete(text)
	testing.expect_value(t, err, "")
	testing.expect_value(t, text, "ok\n")
}

// A path may not go through a symbolic link, even one inside the Recipe directory.
@(test)
test_recipe_text_refuses_to_traverse_a_symbolic_link :: proc(t: ^testing.T) {
	directory, make_err := os.make_directory_temp(TEMP_DIR, "cs-link-*", context.allocator)
	testing.expect(t, make_err == nil, "a temporary directory is needed")
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	real := strings.concatenate({directory, "/real"})
	defer delete(real)
	_ = os.make_directory(real)
	real_prompt_path := strings.concatenate({real, "/p.md"})
	defer delete(real_prompt_path)
	link_path := strings.concatenate({directory, "/link"})
	defer delete(link_path)
	_ = os.write_entire_file_from_string(real_prompt_path, "ok\n", os.Permissions{.Read_User, .Write_User})
	_ = os.symlink(real, link_path)

	text, err := read_recipe_text(directory, "link/p.md", "prompt")
	testing.expect(t, strings.contains(err, "symbolic link"), err)
	testing.expect_value(t, text, "")
}

// Each Worker prompt names each root rule file it has, once, and nothing else.
@(test)
test_worker_guidance_names_each_root_rule_file_once :: proc(t: ^testing.T) {
	station, make_err := os.make_directory_temp(TEMP_DIR, "cs-guidance-*", context.allocator)
	testing.expect(t, make_err == nil, "a temporary directory is needed")
	defer {
		_ = os.remove_all(station)
		delete(station)
	}
	rw := os.Permissions{.Read_User, .Write_User}

	neither := worker_guidance(station)
	defer delete(neither)
	testing.expect_value(t, neither, "")

	workers_path := strings.concatenate({station, "/workers.md"})
	defer delete(workers_path)
	_ = os.write_entire_file_from_string(workers_path, "x", rw)
	only_workers := worker_guidance(station)
	defer delete(only_workers)
	testing.expect_value(t, strings.count(only_workers, "workers.md"), 1)
	testing.expect_value(t, strings.count(only_workers, "standards.md"), 0)

	standards_path := strings.concatenate({station, "/standards.md"})
	defer delete(standards_path)
	_ = os.write_entire_file_from_string(standards_path, "y", rw)
	both := worker_guidance(station)
	defer delete(both)
	testing.expect_value(t, strings.count(both, "workers.md"), 1)
	testing.expect_value(t, strings.count(both, "standards.md"), 1)
}

// Repository names come from the final path component, cleaned so that they are
// safe in branch names and bounded in length.
@(test)
test_repository_names_are_sanitized_and_bounded :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"/work/gac/app", "app"},
		{"/work/gac/app/", "app"},
		{"/work/coffee-shop.v02-gates", "coffee-shop-v02-gates"},
		{"/work/my app!", "my-app"},
		{"/", "repository"},
	}
	for c in cases {
		name := repository_name(c[0])
		testing.expect_value(t, name, c[1])
		delete(name)
	}
	long_component := strings.repeat("a", 40)
	defer delete(long_component)
	long_path := strings.concatenate({"/work/", long_component})
	defer delete(long_path)
	long := repository_name(long_path)
	defer delete(long)
	testing.expect_value(t, len(long), 32)
}

// A Register written before repository names existed still shows a name.
@(test)
test_old_register_without_a_name_shows_the_derived_name :: proc(t: ^testing.T) {
	old := Register{beans_path = "/work/old-app"}
	name, derived := report_repository(old)
	defer delete(derived)
	testing.expect_value(t, name, "old-app")

	named := Register{beans_path = "/work/old-app", repository_name = "stored"}
	stored, no_derived := report_repository(named)
	testing.expect_value(t, stored, "stored")
	testing.expect_value(t, no_derived, "")
}
