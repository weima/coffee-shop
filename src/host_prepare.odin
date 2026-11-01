package main

import "core:os"
import "core:path/filepath"

// The Odin host's start-up: a private host directory and the Pi extensions, which are
// compiled into this binary. Only the Odin host itself calls it — the `--impl=go`
// handover no longer does: csd installs coffee-shop.ts at start (go/internal/extension),
// and the Oreo extension is written when the Odin host next prepares the same state
// directory.
//
// Returns the paths it wrote. The caller owns them.
Host_Prepare :: struct {
	host_dir:             string,
	extension_path:       string,
	oreo_extension_path:  string,
	oreo_protocol_path:   string,
}

host_prepare_environment :: proc(state_root: string, allocator := context.allocator) -> (prepared: Host_Prepare, reason: string) {
	host_dir, _ := filepath.join({state_root, "host"}, allocator)
	if !os.is_directory(host_dir) && os.make_directory_all(host_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return {}, "could not create the host directory"
	}
	// The request socket lives here, so only the user may enter it, whatever the umask or
	// an older install left.
	if !host_dir_make_private(host_dir) {
		return {}, "could not make the host directory private"
	}

	extension_dir, _ := filepath.join({host_dir, "extensions"}, allocator)
	defer if extension_dir != "" do delete(extension_dir, allocator)
	if !os.is_directory(extension_dir) && os.make_directory_all(extension_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return {}, "could not create the extension directory"
	}
	extension_path, _ := filepath.join({extension_dir, "coffee-shop.ts"}, allocator)
	if os.write_entire_file(extension_path, HOST_EXTENSION_SOURCE, os.Permissions{.Read_User, .Write_User}) != nil {
		return {}, "could not write the Coffee Shop extension"
	}

	oreo_dir, _ := filepath.join({extension_dir, "oreo"}, allocator)
	defer if oreo_dir != "" do delete(oreo_dir, allocator)
	if os.make_directory_all(oreo_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil && !os.is_directory(oreo_dir) {
		return {}, "could not create the Oreo extension directory"
	}
	oreo_extension_path, _ := filepath.join({oreo_dir, "index.ts"}, allocator)
	oreo_protocol_path, _ := filepath.join({oreo_dir, "protocol.ts"}, allocator)
	if os.write_entire_file(oreo_extension_path, HOST_OREO_EXTENSION_SOURCE, os.Permissions{.Read_User, .Write_User}) != nil ||
		os.write_entire_file(oreo_protocol_path, HOST_OREO_PROTOCOL_SOURCE, os.Permissions{.Read_User, .Write_User}) != nil {
		return {}, "could not write the Oreo extension"
	}

	return Host_Prepare{
		host_dir = host_dir,
		extension_path = extension_path,
		oreo_extension_path = oreo_extension_path,
		oreo_protocol_path = oreo_protocol_path,
	}, ""
}
