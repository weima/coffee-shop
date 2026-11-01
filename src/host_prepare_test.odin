package main

import "core:os"
import "core:strings"
import "core:testing"

// Both host implementations need the same start-up: a private host directory and the Pi
// extensions, which only this binary carries. A fresh state directory must work on the
// first try, so this test starts from nothing.
@(test)
test_host_prepare_installs_extensions_in_a_private_directory :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-prepare-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	prepared, reason := host_prepare_environment(root, context.allocator)
	defer {
		delete(prepared.host_dir)
		delete(prepared.extension_path)
		delete(prepared.oreo_extension_path)
		delete(prepared.oreo_protocol_path)
	}
	testing.expect_value(t, reason, "")

	testing.expect(t, os.exists(prepared.extension_path), "the Pi extension must exist")
	testing.expect(t, strings.has_suffix(prepared.extension_path, "/host/extensions/coffee-shop.ts"), prepared.extension_path)
	testing.expect(t, os.exists(prepared.oreo_extension_path), "the Oreo extension must exist")
	testing.expect(t, os.exists(prepared.oreo_protocol_path), "the Oreo protocol must exist")

	data, read_err := os.read_entire_file(prepared.extension_path, context.temp_allocator)
	testing.expect_value(t, read_err, os.Error(nil))
	testing.expect(t, len(data) > 0 && strings.contains(string(data), "coffee_shop_ask"), "the extension source is written, not a placeholder")

	info, stat_err := os.stat(prepared.host_dir, context.temp_allocator)
	testing.expect_value(t, stat_err, os.Error(nil))
	testing.expect_value(t, info.mode & os.Permissions{.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}, os.Permissions{})
}

// A widening left by an older install is corrected, not trusted.
@(test)
test_host_prepare_makes_an_existing_host_directory_private :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-prepare-mode-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	host_dir := strings.concatenate({root, "/host"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(host_dir, os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Read_Other}), os.Error(nil))
	testing.expect_value(t, os.chmod(host_dir, os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Read_Other}), os.Error(nil))

	prepared, reason := host_prepare_environment(root, context.allocator)
	defer {
		delete(prepared.host_dir)
		delete(prepared.extension_path)
		delete(prepared.oreo_extension_path)
		delete(prepared.oreo_protocol_path)
	}
	testing.expect_value(t, reason, "")

	info, stat_err := os.stat(host_dir, context.temp_allocator)
	testing.expect_value(t, stat_err, os.Error(nil))
	testing.expect_value(t, info.mode & os.Permissions{.Read_Group, .Read_Other}, os.Permissions{})
}
