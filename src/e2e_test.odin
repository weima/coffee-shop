package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// End-to-end tests drive the real binary as separate processes. They need Git,
// a POSIX shell and the Odin compiler, but no network or AI service.

E2E :: struct {
	root, repo, state, binary: string,
	env: []string,
}

e2e_setup :: proc(t: ^testing.T) -> E2E {
	root := make_fixture_root(t)
	repo := fmt.tprintf("%s/repo", root)
	make_fixture_repo(t, repo)
	rw := os.Permissions{.Read_User, .Write_User}
	_ = os.write_entire_file(fmt.tprintf("%s/standards.md", repo), "# Standards\n", rw)
	_ = os.write_entire_file(fmt.tprintf("%s/workers.md", repo), "# Worker rules\n", rw)
	_ = os.write_entire_file(fmt.tprintf("%s/Makefile", repo), "test:\n\techo suite ok\n", rw)
	for args in ([][]string{{"git", "-C", repo, "add", "."}, {"git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "base"}}) {
		_, _, _ = e2e_exec(args, nil)
	}


	binary := fmt.tprintf("%s/coffee-shop", root)
	code, _, build_err := e2e_exec([]string{"odin", "build", "src", fmt.tprintf("-out:%s", binary)}, nil)
	testing.expect_value(t, code, 0)
	testing.expect(t, code == 0, build_err)

	state := fmt.tprintf("%s/state", root)
	env := make([dynamic]string, context.temp_allocator)
	if inherited, err := os.environ(context.temp_allocator); err == nil {
		for entry in inherited {
			if !strings.has_prefix(entry, "PATH=") {
				append(&env, entry)
			}
		}
	}
	append(&env, fmt.tprintf("PATH=%s", os.get_env("PATH", context.temp_allocator)))
	append(&env, fmt.tprintf("CS_STATE_DIR=%s", state))
	// Every process in the test writes debug messages to one file per fixture, kept after the test.
	log_dir := fmt.tprintf("%s/cs-e2e-logs", TEMP_DIR)
	_ = os.make_directory_all(log_dir, os.Permissions{.Read_User, .Write_User, .Execute_User})
	log_name := root[strings.last_index_byte(root, '/')+1:]
	append(&env, "CS_LOG_LEVEL=debug")
	append(&env, fmt.tprintf("CS_LOG_FILE=%s/%s.log", log_dir, log_name))
	return E2E{root = root, repo = repo, state = state, binary = binary, env = env[:]}
}

e2e_write :: proc(e2e: E2E, name, content: string) -> string {
	path := fmt.tprintf("%s/%s", e2e.root, name)
	_ = os.write_entire_file(path, content, os.Permissions{.Read_User, .Write_User})
	return path
}

e2e_run :: proc(e2e: E2E, args: ..string) -> (code: int, stdout, stderr: string) {
	command := make([]string, len(args) + 1, context.temp_allocator)
	command[0] = e2e.binary
	copy(command[1:], args)
	return e2e_exec(command, e2e.env)
}

e2e_exec :: proc(command: []string, env: []string) -> (code: int, stdout, stderr: string) {
	state, out, errout, _ := os.process_exec(os.Process_Desc{command = command, env = env}, context.temp_allocator)
	return state.exit_code, string(out), string(errout)
}



// The part of a Tray belonging to one Shot, up to the next heading.

// Two servers started for one repository at once: one takes the election lock,
// the other exits, and the winner stays until it is idle.
@(test)
test_e2e_two_simultaneous_server_starts_leave_one_server :: proc(t: ^testing.T) {
	e2e := e2e_setup(t)
	defer remove_fixture_root(e2e.root)

	devnull, _ := os.open("/dev/null", {.Write})
	defer os.close(devnull)
	start :: proc(e2e: E2E, devnull: ^os.File) -> (os.Process, os.Error) {
		return os.process_start(os.Process_Desc{
			command = []string{e2e.binary, "__server", "--state-root", e2e.state, "--repository", e2e.repo},
			env = e2e.env,
			stdout = devnull,
			stderr = devnull,
		})
	}
	first, first_err := start(e2e, devnull)
	second, second_err := start(e2e, devnull)
	testing.expect_value(t, first_err, os.Error(nil))
	testing.expect_value(t, second_err, os.Error(nil))

	// The loser exits at once; the winner keeps running for the idle timeout.
	_, first_wait := os.process_wait(first, 3 * time.Second)
	_, second_wait := os.process_wait(second, 3 * time.Second)
	winner := first
	survivors := 0
	if first_wait != nil {
		survivors += 1
	} else {
		winner = second
	}
	if second_wait != nil {
		survivors += 1
		winner = second
	}
	testing.expect_value(t, survivors, 1)
	_ = os.process_kill(winner)
	_, _ = os.process_wait(winner)
}

// A server with no active Brew on its repository exits after its idle timeout, and
// the next command starts a new one.
@(test)
test_e2e_server_exits_when_its_repository_is_idle :: proc(t: ^testing.T) {
	e2e := e2e_setup(t)
	defer remove_fixture_root(e2e.root)

	devnull, _ := os.open("/dev/null", {.Write})
	defer os.close(devnull)
	server, start_err := os.process_start(os.Process_Desc{
		command = []string{e2e.binary, "__server", "--state-root", e2e.state, "--repository", e2e.repo},
		env = e2e.env,
		stdout = devnull,
		stderr = devnull,
	})
	testing.expect_value(t, start_err, os.Error(nil))

	// The timeout is 30 seconds; allow generous slack for a loaded machine.
	_, wait_err := os.process_wait(server, 45 * time.Second)
	testing.expect_value(t, wait_err, os.Error(nil))
}
