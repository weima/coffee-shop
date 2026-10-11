package oreo

import "core:os"
import "core:path/filepath"
import "core:testing"

CONFIG_TEST_TEMP_DIR :: "/private/tmp" when ODIN_OS == .Darwin else "/tmp"

@(test)
test_config_missing_file_uses_defaults :: proc(t: ^testing.T) {
	directory, path := config_test_directory(t)
	defer config_test_cleanup(directory, path)

	config, config_err := config_load(path)
	defer config_destroy(&config)
	defer config_error_destroy(&config_err)

	testing.expect_value(t, config_err.kind, Config_Error_Kind.None)
	testing.expect_value(t, config.provider, DEFAULT_PROVIDER)
	testing.expect_value(t, config.model, DEFAULT_MODEL)
	testing.expect_value(t, config.thinking, DEFAULT_THINKING)
}

@(test)
test_config_file_overrides_every_field :: proc(t: ^testing.T) {
	directory, path := config_test_directory(t)
	defer config_test_cleanup(directory, path)
	content := `{"provider": "anthropic", "model": "claude-haiku-5.5", "thinking": "xhigh", "extra": "ignored"}`
	testing.expect(t, os.write_entire_file(path, content) == nil)

	config, config_err := config_load(path)
	defer config_destroy(&config)
	defer config_error_destroy(&config_err)

	testing.expect_value(t, config_err.kind, Config_Error_Kind.None)
	testing.expect_value(t, config.provider, "anthropic")
	testing.expect_value(t, config.model, "claude-haiku-5.5")
	testing.expect_value(t, config.thinking, "xhigh")
}

@(test)
test_config_partial_file_keeps_other_defaults :: proc(t: ^testing.T) {
	directory, path := config_test_directory(t)
	defer config_test_cleanup(directory, path)
	testing.expect(t, os.write_entire_file(path, `{"model": "gpt-4.1"}`) == nil)

	config, config_err := config_load(path)
	defer config_destroy(&config)
	defer config_error_destroy(&config_err)

	testing.expect_value(t, config_err.kind, Config_Error_Kind.None)
	testing.expect_value(t, config.provider, DEFAULT_PROVIDER)
	testing.expect_value(t, config.model, "gpt-4.1")
	testing.expect_value(t, config.thinking, DEFAULT_THINKING)
}

@(test)
test_config_rejects_malformed_files :: proc(t: ^testing.T) {
	// A present field must be a non-empty string; the value itself is checked
	// against the provider/model/thinking rules only after all fields load.
	cases := []string{
		`{"provider": `,
		`not json`,
		`[1, 2, 3]`,
		`{"provider": ""}`,
		`{"model": 7}`,
		`{"thinking": null}`,
	}
	for content in cases {
		directory, path := config_test_directory(t)
		testing.expect(t, os.write_entire_file(path, content) == nil)

		config, config_err := config_load(path)
		testing.expect_value(t, config_err.kind, Config_Error_Kind.Malformed)

		config_destroy(&config)
		config_error_destroy(&config_err)
		config_test_cleanup(directory, path)
	}
}

@(test)
test_config_rejects_invalid_provider :: proc(t: ^testing.T) {
	directory, path := config_test_directory(t)
	defer config_test_cleanup(directory, path)
	testing.expect(t, os.write_entire_file(path, `{"provider": "bad model;"}`) == nil)

	_, config_err := config_load(path)
	defer config_error_destroy(&config_err)

	testing.expect_value(t, config_err.kind, Config_Error_Kind.Invalid_Argument)
}

@(test)
test_config_default_path_resolves_home_then_override :: proc(t: ^testing.T) {
	directory, path := config_test_directory(t)
	defer config_test_cleanup(directory, path)

	previous_override := os.get_env(CONFIG_PATH_ENV, context.allocator)
	defer {
		config_test_restore_env(CONFIG_PATH_ENV, previous_override)
		delete(previous_override)
	}

	_ = os.unset_env(CONFIG_PATH_ENV)
	home := os.get_env("HOME", context.allocator)
	defer delete(home)
	if len(home) > 0 {
		home_path, home_err := default_config_path()
		defer config_error_destroy(&home_err)
		testing.expect_value(t, home_err.kind, Config_Error_Kind.None)
		expected, join_err := filepath.join({home, DEFAULT_CONFIG_RELATIVE_PATH}, context.allocator)
		testing.expect(t, join_err == nil)
		defer delete(expected)
		testing.expect_value(t, home_path, expected)
		delete(home_path)
	}

	testing.expect(t, os.set_env(CONFIG_PATH_ENV, path) == nil)
	override_path, override_err := default_config_path()
	defer config_error_destroy(&override_err)
	testing.expect_value(t, override_err.kind, Config_Error_Kind.None)
	testing.expect_value(t, override_path, path)
	delete(override_path)

	// An empty path loads the override, so the resolved path is the one the
	// caller would get from default_config_path.
	testing.expect(t, os.write_entire_file(path, `{"thinking": "max"}`) == nil)
	config, config_err := config_load("")
	defer config_destroy(&config)
	defer config_error_destroy(&config_err)
	testing.expect_value(t, config_err.kind, Config_Error_Kind.None)
	testing.expect_value(t, config.provider, DEFAULT_PROVIDER)
	testing.expect_value(t, config.model, DEFAULT_MODEL)
	testing.expect_value(t, config.thinking, "max")
}

config_test_directory :: proc(t: ^testing.T) -> (directory, path: string) {
	err: os.Error
	directory, err = os.make_directory_temp(CONFIG_TEST_TEMP_DIR, "oreo-config-*", context.allocator)
	testing.expect_value(t, err, os.Error(nil))
	path, err = filepath.join({directory, "config.json"}, context.allocator)
	testing.expect(t, err == nil)
	return
}

config_test_cleanup :: proc(directory, path: string) {
	_ = os.remove_all(directory)
	delete(directory)
	delete(path)
}

config_test_restore_env :: proc(key, value: string) {
	if len(value) > 0 {
		_ = os.set_env(key, value)
	} else {
		_ = os.unset_env(key)
	}
}
