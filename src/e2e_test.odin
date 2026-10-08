package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// End-to-end tests drive the real binary as separate processes, with fake
// `herdr` and `pi` scripts standing in for the external tools. They need Git,
// a POSIX shell and the Odin compiler, but no network, AI service or Herdr.

FAKE_HERDR :: `#!/bin/sh
d="$FAKE_HERDR_DIR"
if [ -n "$FAKE_HERDR_DOWN" ]; then
  echo '{"id":"x","error":{"code":"server_not_running","message":"no herdr server is running"}}' >&2
  exit 1
fi
case "$1 $2" in
"workspace create")
  echo '{"id":"x","result":{"type":"workspace_created","workspace":{"workspace_id":"w1"},"tab":{"tab_id":"t0"},"root_pane":{"pane_id":"p0"}}}' ;;
"tab create")
  n=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 )); echo $n > "$d/n"
  echo "{\"id\":\"x\",\"result\":{\"type\":\"tab_created\",\"tab\":{\"tab_id\":\"t$n\"},\"root_pane\":{\"pane_id\":\"p$n\"}}}" ;;
"pane run")
  # Like a real pane: a session of its own, so closing the tab can end the Worker
  # and everything it started.
  pane="$3"; shift 3
  setsid sh -c "exec $*" >"$d/worker-$pane.log" 2>&1 &
  echo $! > "$d/pid-$pane"
  echo '{}' ;;
"tab close")
  pid=$(cat "$d/pid-p${3#t}" 2>/dev/null)
  if [ -n "$pid" ] && [ -n "$FAKE_HERDR_CLOSE_DELAY" ]; then
    # The tab closes at once, but its Worker exits only after the delay.
    (sleep "$FAKE_HERDR_CLOSE_DELAY"; kill -s TERM -- "-$pid" 2>/dev/null) >/dev/null 2>&1 &
  elif [ -n "$pid" ]; then
    kill -s TERM -- "-$pid" 2>/dev/null
  fi
  echo '{}' ;;
*) echo '{}' ;;
esac
`

// A review call is recognised by --no-extensions; otherwise this is a Worker,
// whose prompt says either "FAIL" or "write <name>".
FAKE_PI :: `#!/bin/sh
for last; do :; done
case " $* " in
*" --no-extensions "*) echo "No findings"; exit 0 ;;
esac
printf '%s' "$last" > prompt.record
printf '%s\n' '{"type":"turn_start"}'
printf '%s\n' '{"type":"tool_execution_start","toolName":"read","args":{}}'
sleep "${FAKE_PI_SLEEP:-0}"
case "$last" in
*FAIL*) echo "boom" >&2; exit 3 ;;
esac
name=$(printf '%s' "$last" | sed -n 's/.*Shot: write \([a-z]*\).*/\1/p')
echo "created $name" > "out-$name.txt"
printf '{"type":"agent_end","messages":[{"role":"assistant",'\
'"content":[{"type":"text","text":"report for %s\\nCS-DONE"}]}]}\n' "$name"
`

E2E :: struct {
	root, repo, state, binary: string,
	env: []string,
}

@(test)
test_e2e_multi_shot_brew_status_collect_and_isolation :: proc(t: ^testing.T) {
	e2e := e2e_setup(t, "0")
	defer remove_fixture_root(e2e.root)
	recipe := e2e_write(e2e, "recipe.json", `{"order":"e2e order","shots":[{"id":"alpha","prompt":"write alpha"},{"id":"beta","prompt":"write beta"},{"id":"gamma","prompt":"FAIL now"}]}`)

	code, brew_out, brew_err := e2e_run(e2e, "brew", "--repo", e2e.repo, "--recipe", recipe)
	testing.expect_value(t, code, 0)
	testing.expect(t, brew_err == "" || !strings.contains(brew_err, "coffee-shop:"), brew_err)
	brew_id := strings.trim_space(brew_out)
	testing.expect(t, strings.has_prefix(brew_id, "brew-"), brew_out)

	// Each command below is a fresh process: nothing is held in memory between them.
	status_code, status, _ := e2e_run(e2e, "status", brew_id)
	testing.expect_value(t, status_code, 0)
	worker_logs := e2e_worker_logs(e2e)
	defer delete(worker_logs)
	debug_output := fmt.aprintf("Status:\n%s\nWorker logs:\n%s", status, worker_logs)
	defer delete(debug_output)
	testing.expect(t, strings.contains(status, fmt.tprintf("Brew %s (repo): failed", brew_id)), debug_output)
	for line in ([]string{"alpha  completed", "beta  completed", "gamma  failed"}) {
		testing.expect(t, strings.contains(status, line), status)
	}

	// The Register and Receipt survive and agree: three Shots started, three ended.
	register, state_err := read_state(fmt.tprintf("%s/%s", e2e.state, brew_id))
	defer destroy_struct(&register)
	testing.expect_value(t, state_err.kind, State_Error_Kind.None)
	testing.expect_value(t, register.event_sequence, 6)

	collect_code, oreo, collect_err := e2e_run(e2e, "collect", brew_id)
	testing.expect_value(t, collect_code, 1) // not every Shot completed
	testing.expect(t, strings.contains(collect_err, "not fully completed"), collect_err)
	alpha := e2e_section(oreo, "alpha")
	beta := e2e_section(oreo, "beta")
	gamma := e2e_section(oreo, "gamma")
	testing.expect(t, strings.contains(alpha, "?? out-alpha.txt"), alpha)
	testing.expect(t, strings.contains(alpha, "report for alpha"), alpha)
	testing.expect(t, strings.contains(alpha, "Review:\nNo findings"), alpha)
	testing.expect(t, strings.contains(alpha, "[unit] make test (Makefile test): passed"), alpha)
	testing.expect(t, strings.contains(beta, "?? out-beta.txt") && !strings.contains(beta, "out-alpha"), beta)
	testing.expect(t, strings.contains(gamma, "Detail: Pi exited with code 3"), gamma)
	testing.expect(t, strings.contains(oreo, "## Decisions for the developer"), oreo)
	testing.expect(t, strings.contains(oreo, "- Shot gamma is failed"), oreo)

	// Collecting again reuses the saved evidence and prints the same Oreo.
	_, again, _ := e2e_run(e2e, "collect", brew_id)
	testing.expect_value(t, again, oreo)

	// One Herdr workspace tab per Shot: the first Shot reuses the workspace's
	// initial tab, so the other two Shots each needed a new tab.
	tabs, _ := os.read_entire_file(fmt.tprintf("%s/fake-herdr/n", e2e.root), context.temp_allocator)
	testing.expect_value(t, strings.trim_space(string(tabs)), "2")

	// Stations are isolated from each other and from the Beans repository.
	stations := fmt.tprintf("%s/%s/stations", e2e.state, brew_id)
	testing.expect(t, os.exists(fmt.tprintf("%s/alpha/out-alpha.txt", stations)))
	testing.expect(t, !os.exists(fmt.tprintf("%s/beta/out-alpha.txt", stations)))
	testing.expect(t, !os.exists(fmt.tprintf("%s/out-alpha.txt", e2e.repo)))
	prompt, _ := os.read_entire_file(fmt.tprintf("%s/alpha/prompt.record", stations), context.temp_allocator)
	defer delete(prompt, context.temp_allocator)
	testing.expect(t, strings.contains(transmute(string)prompt, "Read the repository-root workers.md first"), transmute(string)prompt)
	testing.expect(t, strings.contains(transmute(string)prompt, "Read the repository-root standards.md first"), transmute(string)prompt)
	_, beans_changes, _ := e2e_exec([]string{"git", "-C", e2e.repo, "status", "--short"}, nil)
	testing.expect_value(t, strings.trim_space(beans_changes), "")
}

@(test)
test_e2e_a_killed_supervisor_is_recovered_without_losing_results :: proc(t: ^testing.T) {
	e2e := e2e_setup(t, "2")
	defer remove_fixture_root(e2e.root)
	recipe := e2e_write(e2e, "recipe.json", `{"order":"e2e order","shots":[{"id":"alpha","prompt":"write alpha"},{"id":"beta","prompt":"write beta"}]}`)

	devnull, _ := os.open("/dev/null", {.Write})
	defer os.close(devnull)
	supervisor, start_err := os.process_start(os.Process_Desc{
		command = []string{e2e.binary, "brew", "--repo", e2e.repo, "--recipe", recipe},
		env = e2e.env,
		stdout = devnull,
		stderr = devnull,
	})
	testing.expect_value(t, start_err, os.Error(nil))

	brew_id := ""
	for _ in 0 ..< 80 { // up to 20 s for both Workers to be running
		brew_id = e2e_first_brew(e2e)
		if brew_id != "" {
			_, status, _ := e2e_run(e2e, "status", brew_id)
			if strings.contains(status, "alpha  running") && strings.contains(status, "beta  running") {
				break
			}
		}
		time.sleep(250 * time.Millisecond)
	}
	_, running, _ := e2e_run(e2e, "status", brew_id)
	testing.expect(t, strings.contains(running, "alpha  running") && strings.contains(running, "beta  running"), running)

	// Kill the supervisor with no chance to clean up; the Workers carry on.
	_ = os.process_kill(supervisor)
	_, _ = os.process_wait(supervisor)
	_, orphaned, _ := e2e_run(e2e, "status", brew_id)
	testing.expect(t, strings.contains(orphaned, "Supervisor is not running"), orphaned)

	for _ in 0 ..< 80 { // wait for both Workers to leave their results behind
		if os.exists(fmt.tprintf("%s/%s/results/alpha.json", e2e.state, brew_id)) && os.exists(fmt.tprintf("%s/%s/results/beta.json", e2e.state, brew_id)) {
			break
		}
		time.sleep(250 * time.Millisecond)
	}

	// With no supervisor, collect records what the evidence proves, then reports it.
	code, oreo, _ := e2e_run(e2e, "collect", brew_id)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(oreo, "## Shot alpha: completed"), oreo)
	testing.expect(t, strings.contains(oreo, "## Shot beta: completed"), oreo)
	register, state_err := read_state(fmt.tprintf("%s/%s", e2e.state, brew_id))
	defer destroy_struct(&register)
	testing.expect_value(t, state_err.kind, State_Error_Kind.None)
	testing.expect_value(t, register.event_sequence, 4)
}

@(test)
test_e2e_cancel_stops_running_workers_cancels_queued_shots_and_is_repeatable :: proc(t: ^testing.T) {
	// Workers sleep for 60 s, so only a working cancel can end the Brew quickly.
	e2e := e2e_setup(t, "60")
	defer remove_fixture_root(e2e.root)
	recipe := e2e_write(e2e, "recipe.json", `{"order":"e2e order","shots":[{"id":"alpha","prompt":"write alpha"},{"id":"beta","prompt":"write beta"},{"id":"gamma","prompt":"write gamma"}]}`)

	devnull, _ := os.open("/dev/null", {.Write})
	defer os.close(devnull)
	supervisor, start_err := os.process_start(os.Process_Desc{
		command = []string{e2e.binary, "brew", "--repo", e2e.repo, "--recipe", recipe},
		env = e2e.env,
		stdout = devnull,
		stderr = devnull,
	})
	testing.expect_value(t, start_err, os.Error(nil))
	defer {
		_ = os.process_kill(supervisor) // a no-op once it has exited; never leave it behind
		_, _ = os.process_wait(supervisor)
	}

	brew_id := ""
	for _ in 0 ..< 80 {
		brew_id = e2e_first_brew(e2e)
		if brew_id != "" {
			_, status, _ := e2e_run(e2e, "status", brew_id)
			if strings.contains(status, "alpha  running") && strings.contains(status, "beta  running") {
				break
			}
		}
		time.sleep(250 * time.Millisecond)
	}
	_, running, _ := e2e_run(e2e, "status", brew_id)
	testing.expect(t, strings.contains(running, "alpha  running") && strings.contains(running, "beta  running"), running)
	testing.expect(t, strings.contains(running, "gamma  queued"), running)

	// Cancel from a separate process; the live supervisor does the work.
	code, requested, _ := e2e_run(e2e, "cancel", brew_id)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(requested, "Cancellation requested"), requested)

	// The supervisor must exit promptly instead of waiting out the 60 s Workers.
	if _, wait_err := os.process_wait(supervisor, 15 * time.Second); wait_err != nil {
		testing.expect(t, false, "the supervisor did not exit after cancel")
	}
	_, status, _ := e2e_run(e2e, "status", brew_id)
	testing.expect(t, strings.contains(status, fmt.tprintf("Brew %s (repo): cancelled", brew_id)), status)
	for line in ([]string{"alpha  cancelled", "beta  cancelled", "gamma  cancelled"}) {
		testing.expect(t, strings.contains(status, line), status)
	}

	// The Workers are really gone, not just recorded as cancelled.
	for shot_id in ([]string{"alpha", "beta"}) {
		identity, ok := read_identity_file(fmt.tprintf("%s/%s/workers/%s.started", e2e.state, brew_id, shot_id))
		testing.expect(t, ok, shot_id)
		testing.expect(t, !identity_alive(identity), fmt.tprintf("Worker %s is still running", shot_id))
	}

	// The Receipt says why, and the Register agrees with it.
	register, state_err := read_state(fmt.tprintf("%s/%s", e2e.state, brew_id))
	defer destroy_struct(&register)
	testing.expect_value(t, state_err.kind, State_Error_Kind.None)
	receipt, _ := os.read_entire_file(fmt.tprintf("%s/%s/receipt.ndjson", e2e.state, brew_id), context.temp_allocator)
	testing.expect_value(t, strings.count(string(receipt), `"kind":"cancel_requested"`), 2)
	testing.expect(t, strings.contains(string(receipt), "Brew cancelled before the Worker started"), string(receipt))

	// Cancelling again changes nothing.
	sequence := register.event_sequence
	repeat_code, again, _ := e2e_run(e2e, "cancel", brew_id)
	testing.expect_value(t, repeat_code, 0)
	testing.expect(t, strings.contains(again, "already finished: cancelled"), again)
	after, _ := read_state(fmt.tprintf("%s/%s", e2e.state, brew_id))
	defer destroy_struct(&after)
	testing.expect_value(t, after.event_sequence, sequence)
}

// Five Workers run and two Shots queue. Cancelling must settle the whole Brew within
// the grace period, not once per running Worker.
@(test)
test_e2e_cancel_of_a_full_brew_settles_within_the_grace_period :: proc(t: ^testing.T) {
	e2e := e2e_setup(t, "60")
	defer remove_fixture_root(e2e.root)
	// Each Worker exits 4 s after its tab closes, as a real Pi takes time to shut down.
	slow_exit := make([]string, len(e2e.env) + 1, context.temp_allocator)
	copy(slow_exit, e2e.env)
	slow_exit[len(e2e.env)] = "FAKE_HERDR_CLOSE_DELAY=4"
	e2e.env = slow_exit
	recipe := e2e_write(e2e, "recipe.json", `{"order":"e2e order","workers":5,"shots":[{"id":"alpha","prompt":"write alpha"},{"id":"bravo","prompt":"write bravo"},{"id":"charlie","prompt":"write charlie"},{"id":"delta","prompt":"write delta"},{"id":"echo","prompt":"write echo"},{"id":"foxtrot","prompt":"write foxtrot"},{"id":"golf","prompt":"write golf"}]}`)

	devnull, _ := os.open("/dev/null", {.Write})
	defer os.close(devnull)
	supervisor, start_err := os.process_start(os.Process_Desc{
		command = []string{e2e.binary, "brew", "--repo", e2e.repo, "--recipe", recipe},
		env = e2e.env,
		stdout = devnull,
		stderr = devnull,
	})
	testing.expect_value(t, start_err, os.Error(nil))
	defer {
		_ = os.process_kill(supervisor) // a no-op once it has exited; never leave it behind
		_, _ = os.process_wait(supervisor)
	}

	brew_id := ""
	for _ in 0 ..< 80 {
		brew_id = e2e_first_brew(e2e)
		if brew_id != "" {
			_, status, _ := e2e_run(e2e, "status", brew_id)
			if strings.contains(status, "Workers: 5 of 5 running, 2 queued") {
				break
			}
		}
		time.sleep(250 * time.Millisecond)
	}
	_, running, _ := e2e_run(e2e, "status", brew_id)
	testing.expect(t, strings.contains(running, "Workers: 5 of 5 running, 2 queued"), running)
	for line in ([]string{"alpha  running", "echo  running", "foxtrot  queued", "golf  queued"}) {
		testing.expect(t, strings.contains(running, line), running)
	}

	cancel_started := time.tick_now()
	code, requested, _ := e2e_run(e2e, "cancel", brew_id)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(requested, "Cancellation requested"), requested)

	wait_err: os.Error
	_, wait_err = os.process_wait(supervisor, 15 * time.Second)
	cancel_took := time.tick_since(cancel_started)
	testing.expect(t, wait_err == nil, "the supervisor did not exit within 15 s of cancel")
	testing.expect(t, cancel_took < 15 * time.Second, fmt.tprintf("cancel took %v", cancel_took))

	_, status, _ := e2e_run(e2e, "status", brew_id)
	testing.expect(t, strings.contains(status, fmt.tprintf("Brew %s (repo): cancelled", brew_id)), status)
	for line in ([]string{"alpha  cancelled", "bravo  cancelled", "charlie  cancelled", "delta  cancelled", "echo  cancelled", "foxtrot  cancelled", "golf  cancelled"}) {
		testing.expect(t, strings.contains(status, line), status)
	}
	for shot_id in ([]string{"alpha", "bravo", "charlie", "delta", "echo"}) {
		identity, ok := read_identity_file(fmt.tprintf("%s/%s/workers/%s.started", e2e.state, brew_id, shot_id))
		testing.expect(t, ok, shot_id)
		testing.expect(t, !identity_alive(identity), fmt.tprintf("Worker %s is still running", shot_id))
	}

	// Cancelling again changes nothing.
	register, state_err := read_state(fmt.tprintf("%s/%s", e2e.state, brew_id))
	defer destroy_struct(&register)
	testing.expect_value(t, state_err.kind, State_Error_Kind.None)
	sequence := register.event_sequence
	repeat_code, again, _ := e2e_run(e2e, "cancel", brew_id)
	testing.expect_value(t, repeat_code, 0)
	testing.expect(t, strings.contains(again, "already finished: cancelled"), again)
	after, _ := read_state(fmt.tprintf("%s/%s", e2e.state, brew_id))
	defer destroy_struct(&after)
	testing.expect_value(t, after.event_sequence, sequence)
}

@(test)
test_e2e_status_receives_activity_before_pi_exits :: proc(t: ^testing.T) {
	e2e := e2e_setup(t, "3")
	defer remove_fixture_root(e2e.root)
	recipe := e2e_write(e2e, "recipe.json", `{
		"order":"activity",
		"shots":[{"id":"alpha","prompt":"write alpha"}]
	}`)
	stdout_path := e2e_write(e2e, "brew.stdout", "")
	stderr_path := e2e_write(e2e, "brew.stderr", "")
	stdout_file, stdout_err := os.create(stdout_path)
	testing.expect_value(t, stdout_err, os.Error(nil))
	if stdout_err != nil {
		return
	}
	stderr_file, stderr_err := os.create(stderr_path)
	testing.expect_value(t, stderr_err, os.Error(nil))
	if stderr_err != nil {
		_ = os.close(stdout_file)
		return
	}
	command := []string{e2e.binary, "brew", "--repo", e2e.repo, "--recipe", recipe}
	process, start_err := os.process_start(os.Process_Desc{
		command = command,
		env = e2e.env,
		stdout = stdout_file,
		stderr = stderr_file,
	})
	_ = os.close(stdout_file)
	_ = os.close(stderr_file)
	testing.expect_value(t, start_err, os.Error(nil))
	if start_err != nil {
		return
	}

	brew_id := ""
	for attempt in 0 ..< 20 {
		brew_id = e2e_first_brew(e2e)
		if brew_id != "" {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	if brew_id == "" {
		_, wait_err := os.process_wait(process)
		testing.expect_value(t, wait_err, os.Error(nil))
		testing.expect(t, false, "Brew state was not created")
		return
	}

	progress := ""
	for attempt in 0 ..< 20 {
		_, progress, _ = e2e_run(e2e, "status", brew_id)
		if strings.contains(progress, "Running tool: read") {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect(t, strings.contains(progress, "alpha  running"), progress)
	testing.expect(
		t,
		strings.contains(progress, "active") && strings.contains(progress, "Running tool: read"),
		progress,
	)

	state, wait_err := os.process_wait(process)
	testing.expect_value(t, wait_err, os.Error(nil))
	testing.expect(t, state.success, "Brew should finish after the delayed fake Pi exits")
	_, final_status, _ := e2e_run(e2e, "status", brew_id)
	testing.expect(t, strings.contains(final_status, "alpha  completed"), final_status)
}

@(test)
test_e2e_worker_with_the_wrong_token_is_refused :: proc(t: ^testing.T) {
	e2e := e2e_setup(t, "0")
	defer remove_fixture_root(e2e.root)
	recipe := e2e_write(e2e, "recipe.json", `{"order":"token","shots":[{"id":"alpha","prompt":"write alpha"}]}`)
	code, brew_out, _ := e2e_run(e2e, "brew", "--repo", e2e.repo, "--recipe", recipe)
	testing.expect_value(t, code, 0)
	brew_id := strings.trim_space(brew_out)

	// A Worker that does not carry this Brew's token must not run as one of its Shots.
	worker_code, _, stderr := e2e_run(e2e, "__worker", "--state-root", e2e.state, "--brew-id", brew_id, "--shot-id", "alpha", "--token", "not-the-token")
	testing.expect_value(t, worker_code, 2)
	testing.expect(t, strings.contains(stderr, "token does not match"), stderr)
}

@(test)
test_e2e_brew_exits_non_zero_when_no_shot_could_be_launched :: proc(t: ^testing.T) {
	e2e := e2e_setup(t, "0")
	defer remove_fixture_root(e2e.root)
	down := e2e
	down.env = make([]string, len(e2e.env) + 1, context.temp_allocator)
	copy(down.env, e2e.env)
	down.env[len(e2e.env)] = "FAKE_HERDR_DOWN=1"
	recipe := e2e_write(e2e, "recipe.json", `{"order":"e2e order","shots":[{"id":"alpha","prompt":"write alpha"},{"id":"beta","prompt":"write beta"}]}`)

	code, brew_out, brew_err := e2e_run(down, "brew", "--repo", e2e.repo, "--recipe", recipe)
	testing.expect_value(t, code, 1)
	// The Brew ID is still printed so the failure can be inspected.
	brew_id := strings.trim_space(brew_out)
	testing.expect(t, strings.has_prefix(brew_id, "brew-"), brew_out)
	testing.expect(t, strings.contains(brew_err, "no Shot could be launched (Herdr workspace launch failed: no herdr server is running)"), brew_err)

	_, status, _ := e2e_run(down, "status", brew_id)
	testing.expect(t, strings.contains(status, "alpha  failed") && strings.contains(status, "beta  failed"), status)
}

// A Beans repository with a standards.md and a Makefile `test` target, plus fake
// herdr and pi executables first on PATH.
e2e_setup :: proc(t: ^testing.T, pi_sleep: string) -> E2E {
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

	bin := fmt.tprintf("%s/bin", root)
	_ = os.make_directory_all(bin)
	fake_dir := fmt.tprintf("%s/fake-herdr", root)
	_ = os.make_directory_all(fake_dir)
	rwx := os.Permissions{.Read_User, .Write_User, .Execute_User}
	_ = os.write_entire_file(fmt.tprintf("%s/herdr", bin), FAKE_HERDR, rwx)
	_ = os.write_entire_file(fmt.tprintf("%s/pi", bin), FAKE_PI, rwx)

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
	append(&env, fmt.tprintf("PATH=%s:%s", bin, os.get_env("PATH", context.temp_allocator)))
	append(&env, fmt.tprintf("CS_STATE_DIR=%s", state))
	append(&env, fmt.tprintf("FAKE_HERDR_DIR=%s", fake_dir))
	append(&env, fmt.tprintf("FAKE_PI_SLEEP=%s", pi_sleep))
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

e2e_first_brew :: proc(e2e: E2E) -> string {
	// The state directory also holds servers/, and listing order is not sorted, so
	// only an entry named brew-... is a Brew.
	entries, err := os.read_all_directory_by_path(e2e.state, context.temp_allocator)
	if err != nil {
		return ""
	}
	for entry in entries {
		if strings.has_prefix(entry.name, "brew-") {
			return entry.name
		}
	}
	return ""
}

e2e_worker_logs :: proc(e2e: E2E) -> string {
	logs: [dynamic]string
	logs.allocator = context.temp_allocator
	for pane in ([]string{"p0", "p1", "p2"}) {
		path := fmt.tprintf("%s/fake-herdr/worker-%s.log", e2e.root, pane)
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err == nil && len(data) > 0 {
			_, _ = append(&logs, string(data))
		}
	}
	if len(logs) == 0 {
		return ""
	}
	joined, err := strings.join(logs[:], "\n")
	if err != nil {
		return ""
	}
	return joined
}

// The part of an Oreo belonging to one Shot, up to the next heading.
e2e_section :: proc(oreo, shot_id: string) -> string {
	marker := fmt.tprintf("## Shot %s:", shot_id)
	start := strings.index(oreo, marker)
	if start < 0 {
		return ""
	}
	rest := oreo[start + len(marker):]
	if end := strings.index(rest, "\n## "); end >= 0 {
		return oreo[start : start + len(marker) + end]
	}
	return oreo[start:]
}
