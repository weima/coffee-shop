package main

import "core:c"
import "core:crypto"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import server_lock_lib "system:System"
	foreign server_lock_lib {
		@(link_name="flock")
		darwin_flock :: proc(fd: c.int, operation: c.int) -> c.int ---
	}
}

// flock(2) operations: an exclusive lock taken without waiting, and the release.
LOCK_EXCLUSIVE :: c.int(2)
LOCK_NONBLOCK  :: c.int(4)
LOCK_UNLOCK    :: c.int(8)

// Small helpers shared by the CLI, the Station, the host client and pr: paths under the
// state root, advisory locks, file writes, identifier rules and a repository check. They
// lived among the retired one-shot pipeline until that pipeline was deleted.

state_file_path :: proc(directory, name: string, allocator := context.allocator) -> string {
	path, err := filepath.join([]string{directory, name}, allocator)
	assert(err == nil, "could not build Coffee Shop state path")
	return path
}

private_file_permissions :: proc() -> os.Permissions {
	return os.Permissions{.Read_User, .Write_User}
}

// write_all_to_file writes and syncs a whole file. A failure is returned as an error the
// caller reports; there is no state to repair here.
write_all_to_file :: proc(path: string, data: []byte, flags: os.File_Flags) -> os.Error {
	file, open_err := os.open(path, flags, private_file_permissions())
	if open_err != nil {
		return open_err
	}

	written := 0
	for written < len(data) {
		count, write_err := os.write(file, data[written:])
		if write_err != nil {
			_ = os.close(file)
			return write_err
		}
		if count <= 0 {
			_ = os.close(file)
			return posix.Errno.EIO
		}
		written += count
	}
	if sync_err := os.sync(file); sync_err != nil {
		_ = os.close(file)
		return sync_err
	}
	return os.close(file)
}

// Sixteen random bytes as lowercase hex. Not a secret: it only tells apart Workers
// that share a resource.
random_token :: proc(allocator := context.allocator) -> string {
	bytes: [16]u8
	crypto.rand_bytes(bytes[:])
	digits := "0123456789abcdef"
	hex: [32]u8
	for b, i in bytes {
		hex[2*i] = digits[b>>4]
		hex[2*i+1] = digits[b&0xf]
	}
	token, _ := strings.clone(string(hex[:]), allocator)
	return token
}

file_lock_try :: proc(file: ^os.File) -> bool {
	when ODIN_OS == .Darwin {
		return darwin_flock(c.int(os.fd(file)), LOCK_EXCLUSIVE|LOCK_NONBLOCK) == 0
	} else {
		return linux.flock(linux.Fd(os.fd(file)), {.EX, .NB}) == .NONE
	}
}

// Releases the election lock. Closing the file is what lets a new server start.
file_lock_release :: proc(file: ^os.File) {
	file_lock_release(file)
	_ = os.close(file)
}

MAX_SHOT_ID_LENGTH :: 64

// Shot IDs are path-safe segments: 1–64 ASCII characters, starting with a
// letter or digit; later characters may also be '-' or '_'. A direct check is
// clearer here than compiling a regex for this small, fixed rule.
valid_shot_id :: proc(id: string) -> bool {
	// 1. Strict length bounds check
	if len(id) == 0 || len(id) > MAX_SHOT_ID_LENGTH {
		return false
	}

	// 2. Validate the first character (must be ASCII letter or digit)
	// Accessing id[0] returns a single u8 byte
	switch id[0] {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
	// Valid first character
	case:
		return false
	}

	// 3. Validate remaining characters (treating string safely as bytes)
	for i := 1; i < len(id); i += 1 {
		switch id[i] {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_':
		// Valid character sequence
		case:
			return false
		}
	}

	return true
}

is_git_repository :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	valid: bool,
	err: string,
) {
	state, stdout, stderr, run_err := os.process_exec(
		os.Process_Desc {
			command = []string{"git", "-C", path, "rev-parse", "--is-inside-work-tree"},
		},
		allocator,
	)
	defer delete(stdout, allocator)
	defer delete(stderr, allocator)

	if run_err != nil {
		return false, "could not run git to validate Beans repository"
	}
	if state.success && state.exit_code == 0 {
		return strings.trim_space(transmute(string)stdout) == "true", ""
	}

	// Git also fails for reasons other than "not a repository" (missing path,
	// permissions, unsafe ownership). Keep its message so the cause is visible.
	reason := strings.trim_space(transmute(string)stderr)
	if strings.contains(reason, "not a git repository") {
		return false, ""
	}
	if reason == "" {
		reason = "Git exited unsuccessfully"
	}
	return false, fmt.tprintf("Git could not inspect the Beans path: %s", reason)
}
