package main

import "core:os"
import "core:strings"
import "core:testing"

// Installing the Go host must work from a fresh state directory, land under host/bin, be
// executable, and replace an older copy atomically.
@(test)
test_csd_install_writes_an_executable_binary :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-embed-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	binary := transmute([]byte)string("#!/bin/sh\necho stand-in\n")
	path, reason := csd_install(binary, root, context.allocator)
	defer delete(path)
	testing.expect_value(t, reason, "")
	testing.expect(t, strings.has_suffix(path, "/host/bin/csd"), path)

	info, stat_err := os.stat(path, context.temp_allocator)
	testing.expect_value(t, stat_err, os.Error(nil))
	testing.expect(t, .Execute_User in info.mode, "the extracted host must be executable")
	testing.expect(t, info.size == i64(len(binary)), "the whole binary is written")

	// A second install replaces the first, and leaves no temporary file behind.
	replacement := transmute([]byte)string("#!/bin/sh\necho second\n")
	second, second_reason := csd_install(replacement, root, context.allocator)
	defer delete(second)
	testing.expect_value(t, second_reason, "")
	testing.expect(t, second == path, "the path is stable across installs")
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, read_err, os.Error(nil))
	testing.expect_value(t, string(data), string(replacement))
	testing.expect(t, !os.exists(strings.concatenate({path, ".tmp"}, context.temp_allocator)), "no temporary file is left behind")
}

// An empty binary is refused rather than installed, so a bad build fails loudly.
@(test)
test_csd_install_refuses_an_empty_binary :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-embed-empty-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	_, reason := csd_install(nil, root, context.allocator)
	testing.expect(t, strings.contains(reason, "empty"), reason)
}

// A build without the define must say what to do instead of returning a path that is not
// there.
@(test)
test_csd_extract_explains_an_unembedded_build :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-embed-none-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	path, reason := csd_extract(root, context.allocator)
	defer delete(path)
	when #config(CSD_EMBEDDED, false) {
		testing.expect_value(t, reason, "")
	} else {
		testing.expect(t, strings.contains(reason, "CS_CSD") || strings.contains(reason, "PATH"), reason)
		testing.expect_value(t, path, "")
	}
}
