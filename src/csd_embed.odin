package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

// The Go host is built from `go/` and, for a normal build, embedded here so one user-facing
// command carries both implementations. `just build` compiles `csd` into `src/csd.bin`
// first and passes `-define:CSD_EMBEDDED=true`; a plain `odin check` or `odin test` does not
// set it, so those still work without the artifact.
//
// A dev run (`odin run src`) also lacks it: there the Go host is taken from CS_CSD or PATH,
// which is what the handover reports when neither is present.

when #config(CSD_EMBEDDED, false) {
	CSD_BINARY :: #load("csd.bin", []byte)
}

// csd_embedded reports whether this build carries the Go host.
csd_embedded :: proc() -> bool {
	when #config(CSD_EMBEDDED, false) {
		return len(CSD_BINARY) > 0
	}
	return false
}

// GO_HOST_EXTRACTED is where the embedded binary is written. It lives under the state
// directory so it is per-user and removable with the rest of the state.
GO_HOST_EXTRACTED :: "bin/csd"

// csd_extract writes the embedded Go host under the state root and returns its path.
csd_extract :: proc(state_root: string, allocator := context.allocator) -> (path: string, reason: string) {
	when #config(CSD_EMBEDDED, false) {
		return csd_install(CSD_BINARY, state_root, allocator)
	}
	return "", "this build does not embed the Go host; set CS_CSD or put csd on PATH"
}

// csd_install writes `binary` under <state>/host/bin and returns its path. The write is
// atomic: a temporary file, the executable bit, then a rename over the old one, so a host
// starting concurrently never execs a half-written binary.
csd_install :: proc(binary: []byte, state_root: string, allocator := context.allocator) -> (path: string, reason: string) {
	if len(binary) == 0 {
		return "", "the embedded Go host is empty"
	}
	host_dir, _ := filepath.join({state_root, "host"}, allocator)
	defer delete(host_dir, allocator)
	bin_dir, _ := filepath.join({host_dir, "bin"}, allocator)
	defer delete(bin_dir, allocator)
	if !os.is_directory(bin_dir) && os.make_directory_all(bin_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return "", "could not create the Go host directory"
	}
	target, _ := filepath.join({bin_dir, GO_HOST_NAME}, allocator)
	temp := fmt.tprintf("%s.tmp", target)
	if os.write_entire_file(temp, binary, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		return "", "could not write the Go host binary"
	}
	if os.rename(temp, target) != nil {
		_ = os.remove(temp)
		return "", "could not install the Go host binary"
	}
	return target, ""
}
