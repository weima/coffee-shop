package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

// A verdict taken while another suite is running is not a verdict: two Odin
// suites at once push fork/exec far enough that `git init` fails in fixtures. The
// lock makes "one verify at a time" a property of the tool instead of a habit.
RACHEL_LOCK_ENV :: "RACHEL_LOCK_PATH"
RACHEL_LOCK_DIR :: ".rachel"
RACHEL_LOCK_FILE :: "machine.lock"

Verify_Lock :: struct {
	file: ^os.File,
	path: string, // owned
	held: bool,
}

/**
 * lock_path is machine-wide on purpose: the load that corrupts a verdict comes
 * from verifying a *different* project at the same time.
 * RACHEL_LOCK_PATH overrides it, then $HOME/.rachel/machine.lock.
 */
lock_path :: proc(explicit: string, allocator := context.allocator) -> (path: string, ok: bool) {
	if len(explicit) > 0 {
		cloned, clone_err := strings.clone(explicit, allocator)
		if clone_err != nil {
			return "", false
		}
		return cloned, true
	}
	if override := os.get_env(RACHEL_LOCK_ENV, allocator); len(override) > 0 {
		return override, true
	}
	home := os.get_env("HOME", allocator)
	defer delete(home, allocator)
	if len(home) == 0 {
		return "", false
	}
	dir, dir_err := filepath.join({home, RACHEL_LOCK_DIR}, allocator)
	if dir_err != nil {
		return "", false
	}
	defer delete(dir, allocator)
	if err := os.make_directory_all(dir); err != nil && err != os.Error(.Exist) {
		return "", false
	}
	joined, join_err := filepath.join({dir, RACHEL_LOCK_FILE}, allocator)
	if join_err != nil {
		return "", false
	}
	return joined, true
}

@(private)
lock_try :: proc(file: ^os.File, blocking: bool) -> bool {
	description := posix.flock {
		l_type   = .WRLCK,
		l_whence = 0,
		l_start  = 0,
		l_len    = 0,
	}
	command := posix.FCNTL_Cmd.SETLK
	if blocking {
		command = .SETLKW
	}
	return posix.fcntl(posix.FD(os.fd(file)), command, &description) == 0
}

/**
 * lock_acquire takes the machine lock. With blocking=false it returns ok=false
 * immediately when another verify holds it; with blocking=true it waits and
 * reports waited=true so the caller can say why it paused.
 */
lock_acquire :: proc(path: string, blocking: bool) -> (lock: Verify_Lock, ok: bool, waited: bool) {
	file, open_err := os.open(path, {.Read, .Write, .Create})
	if open_err != nil {
		return {}, false, false
	}
	if lock_try(file, false) {
		return Verify_Lock{file = file, path = path, held = true}, true, false
	}
	if !blocking {
		os.close(file)
		return {}, false, false
	}
	if !lock_try(file, true) {
		os.close(file)
		return {}, false, false
	}
	return Verify_Lock{file = file, path = path, held = true}, true, true
}

lock_release :: proc(lock: ^Verify_Lock) {
	if lock.file == nil {
		return
	}
	description := posix.flock {
		l_type   = .UNLCK,
		l_whence = 0,
		l_start  = 0,
		l_len    = 0,
	}
	_ = posix.fcntl(posix.FD(os.fd(lock.file)), .SETLK, &description)
	os.close(lock.file)
	lock.file = nil
	lock.held = false
}

/**
 * verify_lock is the whole precondition for a trustworthy run. A missing HOME or
 * an unopenable path fails open: locking is a reliability aid, never a reason to
 * refuse to work.
 */
verify_lock :: proc(options: CLI_Options, allocator := context.allocator) -> (lock: Verify_Lock, refused: bool) {
	if options.no_lock {
		return {}, false
	}
	path, path_ok := lock_path(options.lock_path, allocator)
	if !path_ok {
		return {}, false
	}
	acquired, ok, waited := lock_acquire(path, !options.no_wait)
	if !ok {
		// The path is released with the process, so nothing to clean up here.
		fmt.printfln("rachel: fail (precondition): another verify is running (use --no-wait to fail, --no-lock to skip)")
		return {}, true
	}
	if waited {
		fmt.eprintln("rachel: wait another verify held the lock; started when it finished")
	}
	return acquired, false
}
