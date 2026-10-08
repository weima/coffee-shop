package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_discover_package_scripts_and_package_manager_precedence :: proc(t: ^testing.T) {
	root := discover_test_root(t)
	defer discover_remove_root(root)
	discover_write(root, "package.json", `{"packageManager":"pnpm@9.0.0","scripts":{"test":"vitest","test:e2e":"playwright"}}`)
	discover_write(root, "bun.lock", "")

	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 2)
	discover_expect_command(t, result.commands[:], .Unit, []string{"pnpm", "run", "test"}, "package.json scripts.test")
	discover_expect_command(t, result.commands[:], .E2E, []string{"pnpm", "run", "test:e2e"}, "package.json scripts.test:e2e")
}

@(test)
test_discover_package_manager_lockfiles_and_ambiguous_manager :: proc(t: ^testing.T) {
	discover_expect_lock_manager(t, "npm", "package-lock.json")
	discover_expect_lock_manager(t, "yarn", "yarn.lock")
	discover_expect_lock_manager(t, "pnpm", "pnpm-lock.yaml")
	discover_expect_lock_manager(t, "bun", "bun.lock")
	discover_expect_lock_manager(t, "bun", "bun.lockb")

	root := discover_test_root(t)
	defer discover_remove_root(root)
	discover_write(root, "package.json", `{"scripts":{"test":"test"}}`)
	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 0)
	testing.expect(t, discover_has_note(result, "package manager is ambiguous"))
}

@(test)
test_discover_makefile_unit_and_e2e_targets :: proc(t: ^testing.T) {
	root := discover_test_root(t)
	defer discover_remove_root(root)
	discover_write(root, "Makefile", "test:\n\techo test\ne2e:\n\techo e2e\ntest-e2e:\n\techo e2e\n")
	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 1)
	testing.expect_value(t, result.commands[0].kind, Check_Kind.Unit)
	testing.expect(t, discover_strings_equal(result.commands[0].argv, []string{"make", "test"}))
	testing.expect_value(t, len(result.notes), 1)
	testing.expect(t, discover_has_note(result, "ambiguous e2e test commands"))
	testing.expect(t, discover_has_note(result, "Makefile e2e"))
	testing.expect(t, discover_has_note(result, "Makefile test-e2e"))
}

@(test)
test_discover_single_manifest_candidates :: proc(t: ^testing.T) {
	root_go := discover_test_root(t)
	defer discover_remove_root(root_go)
	discover_write(root_go, "go.mod", "")
	go_result := discover_checks(root_go)
	defer destroy_struct(&go_result)
	testing.expect_value(t, len(go_result.commands), 1)
	testing.expect_value(t, go_result.commands[0].kind, Check_Kind.Unit)
	testing.expect(t, discover_strings_equal(go_result.commands[0].argv, []string{"go", "test", "./..."}))

	root_cargo := discover_test_root(t)
	defer discover_remove_root(root_cargo)
	discover_write(root_cargo, "Cargo.toml", "")
	cargo_result := discover_checks(root_cargo)
	defer destroy_struct(&cargo_result)
	testing.expect_value(t, len(cargo_result.commands), 1)
	testing.expect_value(t, cargo_result.commands[0].kind, Check_Kind.Unit)
	testing.expect(t, discover_strings_equal(cargo_result.commands[0].argv, []string{"cargo", "test"}))

	root := discover_test_root(t)
	defer discover_remove_root(root)
	discover_write(root, "package.json", `{"packageManager":"npm@10","scripts":{"test":"test"}}`)
	discover_write(root, "Makefile", "test:\n")
	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 0)
	testing.expect_value(t, len(result.notes), 1)
	testing.expect(t, strings.contains(result.notes[0], "package.json scripts.test"))
	testing.expect(t, strings.contains(result.notes[0], "Makefile test"))
}

@(test)
test_discover_script_aliases_and_makefile_single_targets :: proc(t: ^testing.T) {
	discover_expect_script(t, `{"packageManager":"npm@10","scripts":{"test:unit":"run"}}`, Check_Kind.Unit)
	discover_expect_script(t, `{"packageManager":"npm@10","scripts":{"e2e":"run"}}`, Check_Kind.E2E)
	discover_expect_script(t, `{"packageManager":"npm@10","scripts":{"test:playwright":"run"}}`, Check_Kind.E2E)

	root := discover_test_root(t)
	defer discover_remove_root(root)
	discover_write(root, "Makefile", "test-e2e:\n")
	discover_write(root, "playwright.config.ts", "")
	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 1)
	testing.expect(t, discover_strings_equal(result.commands[0].argv, []string{"make", "test-e2e"}))
	testing.expect_value(t, len(result.notes), 0)
}

@(test)
test_discover_script_alias_ambiguity :: proc(t: ^testing.T) {
	root := discover_test_root(t)
	defer discover_remove_root(root)
	discover_write(root, "package.json", `{"packageManager":"npm@10","scripts":{"test":"unit","test:unit":"unit"}}`)
	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 0)
	testing.expect(t, discover_has_note(result, "package.json scripts.test"))
	testing.expect(t, discover_has_note(result, "package.json scripts.test:unit"))
}

@(test)
test_discover_e2e_ambiguity_and_playwright_config_note :: proc(t: ^testing.T) {
	root := discover_test_root(t)
	defer discover_remove_root(root)
	discover_write(root, "package.json", `{"packageManager":"npm@10","scripts":{"test:e2e":"pw"}}`)
	discover_write(root, "Makefile", "e2e:\n")
	discover_write(root, "playwright.config.mts", "")
	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 0)
	testing.expect_value(t, len(result.notes), 2)
	testing.expect(t, discover_has_note(result, "ambiguous e2e test commands"))
	testing.expect(t, discover_has_note(result, "Playwright configuration exists but no e2e script is declared"))
}

@(test)
test_discover_playwright_config_without_declared_e2e_script :: proc(t: ^testing.T) {
	root := discover_test_root(t)
	defer discover_remove_root(root)
	discover_write(root, "playwright.config.js", "")
	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 0)
	testing.expect(t, discover_has_note(result, "Playwright configuration exists but no e2e script is declared"))
}

@(test)
test_discover_malformed_package_json_and_empty_directory :: proc(t: ^testing.T) {
	root := discover_test_root(t)
	defer discover_remove_root(root)
	discover_write(root, "package.json", `{"scripts":`)
	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 0)
	testing.expect(t, discover_has_note(result, "package.json"))

	empty := discover_test_root(t)
	defer discover_remove_root(empty)
	empty_result := discover_checks(empty)
	defer destroy_struct(&empty_result)
	testing.expect_value(t, len(empty_result.commands), 0)
	testing.expect_value(t, len(empty_result.notes), 1)
	testing.expect_value(t, empty_result.notes[0], "no recognized test configuration found")
}

discover_expect_script :: proc(t: ^testing.T, manifest: string, kind: Check_Kind) {
	root := discover_test_root(t)
	defer discover_remove_root(root)
	discover_write(root, "package.json", manifest)
	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 1)
	testing.expect_value(t, result.commands[0].kind, kind)
}

discover_expect_lock_manager :: proc(t: ^testing.T, manager, lockfile: string) {
	root := discover_test_root(t)
	defer discover_remove_root(root)
	discover_write(root, "package.json", `{"scripts":{"test":"test"}}`)
	discover_write(root, lockfile, "")
	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 1)
	testing.expect_value(t, result.commands[0].argv[0], manager)
}

discover_test_root :: proc(t: ^testing.T) -> string {
	root, err := os.make_directory_temp("", "coffee-shop-discover-*", context.allocator)
	testing.expect_value(t, err, os.Error(nil))
	return root
}

discover_remove_root :: proc(root: string) {
	_ = os.remove_all(root)
	delete(root)
}

discover_write :: proc(root, name, contents: string) {
	path := fmt.tprintf("%s/%s", root, name)
	_ = os.write_entire_file(path, contents, os.Permissions{.Read_User, .Write_User})
}

discover_has_note :: proc(result: Discovery, expected: string) -> bool {
	for note in result.notes {
		if strings.contains(note, expected) do return true
	}
	return false
}

discover_strings_equal :: proc(a, b: []string) -> bool {
	if len(a) != len(b) do return false
	for value, i in a {
		if value != b[i] do return false
	}
	return true
}

discover_expect_command :: proc(t: ^testing.T, commands: []Check_Command, kind: Check_Kind, argv: []string, source: string) {
	for command in commands {
		if command.kind == kind {
			testing.expect(t, discover_strings_equal(command.argv, argv), "argv mismatch")
			testing.expect_value(t, command.source, source)
			return
		}
	}
	testing.expect(t, false, fmt.tprintf("missing %v command", kind))
}

@(test)
test_discover_justfile_unit_and_e2e_recipes_under_every_accepted_name :: proc(t: ^testing.T) {
	for name in ([]string{"justfile", "Justfile", ".justfile"}) {
		root := discover_test_root(t)
		defer discover_remove_root(root)
		discover_write(root, name, "test: build\n    odin test src\ne2e:\n    echo e2e\n")
		result := discover_checks(root)
		defer destroy_struct(&result)
		testing.expect_value(t, len(result.commands), 2)
		discover_expect_command(t, result.commands[:], Check_Kind.Unit, []string{"just", "test"}, fmt.tprintf("%s test", name))
		discover_expect_command(t, result.commands[:], Check_Kind.E2E, []string{"just", "e2e"}, fmt.tprintf("%s e2e", name))
	}
}

@(test)
test_discover_justfile_ignores_recipe_bodies_comments_and_recipes_needing_arguments :: proc(t: ^testing.T) {
	root := discover_test_root(t)
	defer discover_remove_root(root)
	// `test target:` requires an argument, so a bare `just test` could not run it.
	discover_write(root, "justfile", "# test:\nbuild:\n    echo \"test: not a recipe\"\ntest target:\n    echo {{target}}\n")
	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 0)
}

@(test)
test_discover_justfile_and_makefile_test_targets_are_ambiguous :: proc(t: ^testing.T) {
	root := discover_test_root(t)
	defer discover_remove_root(root)
	discover_write(root, "justfile", "test:\n    echo a\n")
	discover_write(root, "Makefile", "test:\n\techo b\n")
	result := discover_checks(root)
	defer destroy_struct(&result)
	testing.expect_value(t, len(result.commands), 0)
	testing.expect(t, discover_has_note(result, "ambiguous unit test commands"))
	testing.expect(t, discover_has_note(result, "justfile test"))
	testing.expect(t, discover_has_note(result, "Makefile test"))
}

@(test)
test_this_repository_declares_its_own_test_command :: proc(t: ^testing.T) {
	// Tests run from the repository root. This keeps the Makefile's `test` target
	// discoverable, so the Filter can verify Coffee Shop's own Stations.
	discovery := discover_checks(".")
	defer destroy_struct(&discovery)
	testing.expect_value(t, len(discovery.commands), 1)
	if len(discovery.commands) == 1 {
		testing.expect_value(t, discovery.commands[0].kind, Check_Kind.Unit)
		testing.expect_value(t, strings.join(discovery.commands[0].argv, " ", context.temp_allocator), "just test")
	}
}
