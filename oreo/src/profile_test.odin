package oreo

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"
import "core:time"

// The profile tests point OREO_CONFIG at one temp file for the whole test
// binary, so no real user config is read and the configuration test that owns
// OREO_CONFIG itself is never disturbed. Only the file contents change.
@(private)
profile_test_config_path: string

@(private)
profile_test_config_dir: string

@(private)
profile_test_lock: sync.Mutex

@(init)
profile_test_setup :: proc "contextless" () {
	context = runtime.default_context()
	allocator := runtime.default_allocator()
	directory, directory_err := os.make_directory_temp(CONFIG_TEST_TEMP_DIR, "oreo-profile-*", allocator)
	if directory_err != nil {
		panic("could not create the profile test directory")
	}
	path, join_err := filepath.join({directory, "config.json"}, allocator)
	if join_err != nil {
		panic("could not build the profile test config path")
	}
	profile_test_config_dir = directory
	profile_test_config_path = path
	if os.set_env(CONFIG_PATH_ENV, path) != nil {
		panic("could not set OREO_CONFIG for the profile tests")
	}
}

@(fini)
profile_test_teardown :: proc "contextless" () {
	context = runtime.default_context()
	allocator := runtime.default_allocator()
	if len(profile_test_config_dir) > 0 {
		_ = os.remove_all(profile_test_config_dir)
		delete(profile_test_config_dir, allocator)
	}
	delete(profile_test_config_path, allocator)
}

@(test)
test_profile_resolve_empty_uses_defaults_without_config :: proc(t: ^testing.T) {
	sync.mutex_lock(&profile_test_lock)
	defer sync.mutex_unlock(&profile_test_lock)
	profile_test_clear_config(t)

	profile_test_expect(t, "", "", "", DEFAULT_PROVIDER, DEFAULT_MODEL, DEFAULT_THINKING)
}

@(test)
test_profile_resolve_explicit_values_win :: proc(t: ^testing.T) {
	sync.mutex_lock(&profile_test_lock)
	defer sync.mutex_unlock(&profile_test_lock)
	profile_test_clear_config(t)

	profile_test_expect(t, "anthropic", "claude-haiku-5.5", "xhigh", "anthropic", "claude-haiku-5.5", "xhigh")
}

@(test)
test_profile_resolve_partial_override_keeps_defaults :: proc(t: ^testing.T) {
	sync.mutex_lock(&profile_test_lock)
	defer sync.mutex_unlock(&profile_test_lock)
	profile_test_clear_config(t)

	profile_test_expect(t, "", "gpt-4.1", "", DEFAULT_PROVIDER, "gpt-4.1", DEFAULT_THINKING)
}

@(test)
test_profile_resolve_fills_each_empty_field_from_config :: proc(t: ^testing.T) {
	sync.mutex_lock(&profile_test_lock)
	defer sync.mutex_unlock(&profile_test_lock)
	profile_test_write_config(t, `{"provider": "anthropic", "model": "claude-haiku-5.5", "thinking": "xhigh"}`)

	profile_test_expect(t, "", "explicit-model", "high", "anthropic", "explicit-model", "high")
	profile_test_expect(t, "explicit-provider", "", "high", "explicit-provider", "claude-haiku-5.5", "high")
	profile_test_expect(t, "explicit-provider", "explicit-model", "", "explicit-provider", "explicit-model", "xhigh")
}

@(test)
test_profile_resolve_rejects_invalid_explicit_provider :: proc(t: ^testing.T) {
	sync.mutex_lock(&profile_test_lock)
	defer sync.mutex_unlock(&profile_test_lock)
	profile_test_clear_config(t)

	profile, profile_err := profile_resolve("bad model;", "", "")
	defer profile_resolved_destroy(&profile)
	defer config_error_destroy(&profile_err)

	testing.expect_value(t, profile_err.kind, Config_Error_Kind.Invalid_Argument)
}

// profile_test_expect resolves the three inputs and checks the result. The
// configuration test that also uses OREO_CONFIG can briefly redirect it, so a
// mismatch is retried until that test restores the profile test path.
@(private)
profile_test_expect :: proc(t: ^testing.T, provider, model, thinking, want_provider, want_model, want_thinking: string) {
	start := time.now()
	for {
		profile, profile_err := profile_resolve(provider, model, thinking)
		if profile_err.kind == .None {
			matched := profile.provider == want_provider && profile.model == want_model && profile.thinking == want_thinking
			profile_resolved_destroy(&profile)
			if matched {
				return
			}
		} else {
			config_error_destroy(&profile_err)
		}
		if time.since(start) > 5 * time.Second {
			testing.expectf(
				t,
				false,
				"profile_resolve(%q, %q, %q) never resolved to %q/%q/%q",
				provider,
				model,
				thinking,
				want_provider,
				want_model,
				want_thinking,
			)
			return
		}
		time.sleep(time.Millisecond)
	}
}

@(private)
profile_test_clear_config :: proc(t: ^testing.T) {
	if os.exists(profile_test_config_path) {
		testing.expect(t, os.remove(profile_test_config_path) == nil)
	}
}

@(private)
profile_test_write_config :: proc(t: ^testing.T, content: string) {
	testing.expect(t, os.write_entire_file(profile_test_config_path, content) == nil)
}
