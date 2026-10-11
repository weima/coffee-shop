package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// Each test builds its own binary: parallel `odin run` calls share one output path
// and can run each other's build. The caller owns the returned path.
build_test_binary :: proc(t: ^testing.T, root: string) -> string {
	binary, _ := filepath.join({root, "coffee-shop"})
	build_state, _, build_stderr, build_err := os.process_exec(os.Process_Desc{
		command = {"odin", "build", "src", fmt.tprintf("-out:%s", binary)},
	}, context.allocator)
	defer delete(build_stderr)
	testing.expect_value(t, build_err, os.Error(nil))
	testing.expect(t, build_state.success, string(build_stderr))
	return binary
}

// Fake agent: logs each stdin line, then answers every prompt with one agent_end
// whose text counts the turns. It exits when its stdin closes.
FAKE_STATION_AGENT :: `#!/bin/sh
n=0
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$1"
  n=$((n+1))
  printf '%s\n' "{\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"turn $n\"}]}]}"
done
`

@(test)
test_station_reports_each_turn_and_relays_replies :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-station-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "report.sock"})
	defer delete(socket)
	agent, _ := filepath.join({root, "agent.sh"})
	defer delete(agent)
	received, _ := filepath.join({root, "received.log"})
	defer delete(received)
	write_err := os.write_entire_file(agent, FAKE_STATION_AGENT, os.Permissions{.Read_User, .Write_User, .Execute_User})
	testing.expect_value(t, write_err, os.Error(nil))

	binary := build_test_binary(t, root)
	defer delete(binary)
	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)

	// The reply reaches the Station on stdin; closing stdin then ends the session.
	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `printf '%s\n' "second question" | "$4" station --report "$1" --station shot-a --brew order-1 --prompt "first question" -- sh "$2" "$3"`, "station-test", socket, agent, received, binary},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state.success, string(stderr))

	turns: [dynamic]string
	defer {
		for turn in turns {
			delete(turn)
		}
		delete(turns)
	}
	exited := false
	for {
		result := activity_listener_receive(&listener)
		if result.kind == .Unavailable {
			break
		}
		if result.kind != .Message {
			continue
		}
		switch result.message.kind {
		case "turn_done":
			append(&turns, strings.clone(result.message.description))
		case "agent_exited":
			exited = true
		}
		destroy_struct(&result.message)
	}
	testing.expect_value(t, len(turns), 2)
	if len(turns) == 2 {
		testing.expect_value(t, turns[0], "turn 1")
		testing.expect_value(t, turns[1], "turn 2")
	}
	testing.expect(t, exited, "Station should report the agent exit")

	log_data, log_err := os.read_entire_file(received, context.allocator)
	defer delete(log_data)
	testing.expect_value(t, log_err, os.Error(nil))
	log := string(log_data)
	testing.expect(t, strings.contains(log, `"message":"first question"`), log)
	testing.expect(t, strings.contains(log, `"message":"second question"`) && strings.contains(log, `"streamingBehavior":"followUp"`), log)
	_ = fmt.tprintf
}

@(test)
test_station_reads_prompt_file_and_sends_exact_text :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-station-file-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "report.sock"})
	prompt_path, _ := filepath.join({root, "prompt.md"})
	agent, _ := filepath.join({root, "agent.sh"})
	received, _ := filepath.join({root, "received.log"})
	defer delete(socket)
	defer delete(prompt_path)
	defer delete(agent)
	defer delete(received)
	prompt := "first line\nit's from a file\nlast line"
	testing.expect_value(t, os.write_entire_file(prompt_path, prompt, os.Permissions{.Read_User, .Write_User}), os.Error(nil))
	prompt_check, prompt_check_err := os.read_entire_file(prompt_path, context.allocator)
	defer delete(prompt_check)
	testing.expect_value(t, prompt_check_err, os.Error(nil))
	testing.expect_value(t, string(prompt_check), prompt)
	testing.expect_value(t, os.write_entire_file(agent, FAKE_STATION_AGENT, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))

	binary := build_test_binary(t, root)
	defer delete(binary)
	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)
	parsed, parse_err := parse_args([]string{"station", "--report", socket, "--station", "shot-a", "--brew", "order-1", "--prompt-file", prompt_path, "--", "sh", agent, received})
	testing.expect_value(t, parse_err, "")
	testing.expect_value(t, parsed.prompt, "")
	testing.expect_value(t, parsed.prompt_file, prompt_path)

	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `printf '%s\n' "second question" | "$5" station --report "$1" --station shot-a --brew order-1 --prompt-file "$2" -- sh "$3" "$4"`, "station-file-test", socket, prompt_path, agent, received, binary},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state.success, string(stderr))
	log_data, log_err := os.read_entire_file(received, context.allocator)
	defer delete(log_data)
	testing.expect_value(t, log_err, os.Error(nil))
	testing.expect(t, strings.contains(string(log_data), `{"type":"prompt","message":"first line\nit's from a file\nlast line"}`), string(log_data))
}

// Fake agent that asks a select dialog for its first prompt and answers the reply
// with agent_end. Every stdin line is logged to $1.
FAKE_DIALOG_AGENT :: `#!/bin/sh
n=0
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$1"
  case "$line" in
  *'"extension_ui_response"'*)
    n=$((n+1))
    printf '%s\n' "{\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"answered $n\"}]}]}"
    ;;
  *)
    printf '%s\n' '{"type":"extension_ui_request","id":"d1","method":"select","title":"Pick one","options":["Allow","Block"]}'
    ;;
  esac
done
`

@(test)
test_station_forwards_dialog_and_applies_reply :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-dialog-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "report.sock"})
	agent, _ := filepath.join({root, "agent.sh"})
	received, _ := filepath.join({root, "received.log"})
	defer delete(socket)
	defer delete(agent)
	defer delete(received)
	testing.expect_value(t, os.write_entire_file(agent, FAKE_DIALOG_AGENT, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	binary := build_test_binary(t, root)
	defer delete(binary)

	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)

	// The answer is typed one second after start, once the dialog is pending.
	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `( sleep 1; printf '%s\n' "Allow"; sleep 1 ) | "$4" station --report "$1" --station shot-a --brew order-1 --prompt "first question" -- sh "$2" "$3"`, "dialog-test", socket, agent, received, binary},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state.success, string(stderr))

	needs_input: string
	turn: string
	for {
		result := activity_listener_receive(&listener)
		if result.kind == .Unavailable {
			break
		}
		if result.kind != .Message {
			continue
		}
		switch result.message.kind {
		case "needs_input":
			needs_input = strings.clone(result.message.description)
		case "turn_done":
			turn = strings.clone(result.message.description)
		}
		destroy_struct(&result.message)
	}
	defer delete(needs_input)
	defer delete(turn)
	testing.expect_value(t, needs_input, "Pick one [Allow / Block]")
	testing.expect_value(t, turn, "answered 1")

	log_data, log_err := os.read_entire_file(received, context.allocator)
	defer delete(log_data)
	testing.expect_value(t, log_err, os.Error(nil))
	log := string(log_data)
	testing.expect(t, strings.contains(log, `{"type":"extension_ui_response","id":"d1","value":"Allow"}`), log)
}

@(test)
test_dialog_response_matches_method :: proc(t: ^testing.T) {
	options := []string{"Allow", "Block"}
	select_dialog := Station_Dialog{active = true, id = "d1", method = "select", options = options}
	testing.expect_value(t, station_dialog_response(select_dialog, "Block"), `{"type":"extension_ui_response","id":"d1","value":"Block"}`)
	testing.expect_value(t, station_dialog_response(select_dialog, "Maybe"), `{"type":"extension_ui_response","id":"d1","cancelled":true}`)

	confirm_dialog := Station_Dialog{active = true, id = "d2", method = "confirm"}
	testing.expect_value(t, station_dialog_response(confirm_dialog, "YES"), `{"type":"extension_ui_response","id":"d2","confirmed":true}`)
	testing.expect_value(t, station_dialog_response(confirm_dialog, "n"), `{"type":"extension_ui_response","id":"d2","confirmed":false}`)
	testing.expect_value(t, station_dialog_response(confirm_dialog, "later"), `{"type":"extension_ui_response","id":"d2","cancelled":true}`)

	input_dialog := Station_Dialog{active = true, id = "d3", method = "input"}
	testing.expect_value(t, station_dialog_response(input_dialog, "hello"), `{"type":"extension_ui_response","id":"d3","value":"hello"}`)
}

@(test)
test_station_report_rejects_invalid_name_before_creating_reports :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-report-name-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "activity.sock"})
	defer delete(socket)
	path, ok := station_write_report_file(socket, "order-1", "../escape", "turn_done", "report")
	defer delete(path)
	testing.expect(t, !ok, "an invalid station id must not write a report")
	reports, _ := filepath.join({root, "reports"})
	defer delete(reports)
	testing.expect(t, !os.exists(reports), "invalid names must not create the reports directory")
}

@(test)
test_station_report_paths_include_unique_names :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-report-collision-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "activity.sock"})
	defer delete(socket)
	first, first_ok := station_write_report_file(socket, "order-1", "shot-a", "turn_done", "first")
	defer delete(first)
	second, second_ok := station_write_report_file(socket, "order-1", "shot-a", "turn_done", "second")
	defer delete(second)
	testing.expect(t, first_ok && second_ok, "both reports should be written")
	testing.expect(t, first != second, "report paths must be unique")
	if first_ok {
		first_data, first_err := os.read_entire_file(first, context.allocator)
		defer delete(first_data)
		testing.expect_value(t, first_err, os.Error(nil))
		testing.expect_value(t, string(first_data), "first")
	}
	if second_ok {
		second_data, second_err := os.read_entire_file(second, context.allocator)
		defer delete(second_data)
		testing.expect_value(t, second_err, os.Error(nil))
		testing.expect_value(t, string(second_data), "second")
	}
}

@(test)
test_station_report_falls_back_when_reports_directory_is_unwritable :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-report-fallback-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "activity.sock"})
	reports, _ := filepath.join({root, "reports"})
	defer delete(socket)
	defer delete(reports)
	testing.expect_value(t, os.make_directory_all(reports, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	testing.expect_value(t, os.change_mode(reports, os.Permissions{.Read_User, .Execute_User}), os.Error(nil))

	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)
	sender, sender_ok := activity_sender_open(socket)
	testing.expect(t, sender_ok)
	defer activity_sender_close(&sender)

	long := strings.repeat("x", ACTIVITY_MAX_DESCRIPTION+100, context.temp_allocator)
	station_report(&sender, "order-1", "shot-a", "turn_done", long)
	result := activity_listener_receive(&listener)
	fallback := ""
	if result.kind == .Message {
		fallback = strings.clone(result.message.description)
	}
	destroy_struct(&result.message)
	defer delete(fallback)
	testing.expect(t, fallback != "" && !strings.has_prefix(fallback, STATION_FILE_PREFIX), fallback)
	testing.expect_value(t, len(fallback), ACTIVITY_MAX_DESCRIPTION)
}

// Fake agent whose every turn answers with a 3000-character report.
FAKE_LONG_AGENT :: `#!/bin/sh
while IFS= read -r line; do
  text=$(head -c 3000 /dev/zero | tr '\0' 'x')
  printf '%s\n' "{\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"$text\"}]}]}"
done
`

@(test)
test_station_writes_long_report_to_file :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-long-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "activity.sock"})
	agent, _ := filepath.join({root, "agent.sh"})
	defer delete(socket)
	defer delete(agent)
	testing.expect_value(t, os.write_entire_file(agent, FAKE_LONG_AGENT, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	binary := build_test_binary(t, root)
	defer delete(binary)

	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)

	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `(sleep 1) | "$2" station --report "$1" --station shot-a --brew order-1 --prompt "hi" -- sh "$3"`, "long-test", socket, binary, agent},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state.success, string(stderr))

	description: string
	for {
		result := activity_listener_receive(&listener)
		if result.kind == .Unavailable {
			break
		}
		if result.kind == .Message && result.message.kind == "turn_done" {
			description = strings.clone(result.message.description)
		}
		destroy_struct(&result.message)
	}
	defer delete(description)
	testing.expect(t, strings.has_prefix(description, STATION_FILE_PREFIX), description)
	if !strings.has_prefix(description, STATION_FILE_PREFIX) {
		return
	}
	report, read_err := os.read_entire_file(description[len(STATION_FILE_PREFIX):], context.allocator)
	defer delete(report)
	testing.expect_value(t, read_err, os.Error(nil))
	testing.expect_value(t, len(report), 3000)
}

// Fake agent that writes changed.txt in its working directory, then exits when stdin closes.
FAKE_WRITING_AGENT :: `#!/bin/sh
printf 'changed\n' > changed.txt
cat > /dev/null
`

// Fake agent that changes nothing and exits when stdin closes.
FAKE_SILENT_AGENT :: `#!/bin/sh
cat > /dev/null
`

Station_Kind_Run :: struct {
	exit_code:  int,
	incomplete: string, // empty when no incomplete report arrived; owned by the caller
}

// Runs one Station of the given kind inside a fresh Git repository, the Station's
// working directory, and collects the incomplete report, if any.
run_station_kind :: proc(t: ^testing.T, root, kind, agent_script: string) -> (run: Station_Kind_Run) {
	repo, _ := filepath.join({root, "beans"}, context.temp_allocator)
	socket, _ := filepath.join({root, "report.sock"}, context.temp_allocator)
	agent, _ := filepath.join({root, "agent.sh"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(repo), os.Error(nil))
	testing.expect_value(t, os.write_entire_file(agent, agent_script, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	init_state, _, init_stderr, init_err := os.process_exec(os.Process_Desc{
		command = {"git", "init", "-q", repo},
	}, context.allocator)
	defer delete(init_stderr)
	testing.expect_value(t, init_err, os.Error(nil))
	testing.expect(t, init_state.success, string(init_stderr))

	binary := build_test_binary(t, root)
	defer delete(binary)
	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)

	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `cd "$1" && "$2" station --kind "$3" --report "$4" --station shot-a --brew order-1 --prompt "hi" -- sh "$5" </dev/null`, "station-kind-test", repo, binary, kind, socket, agent},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	run.exit_code = state.exit_code

	for {
		result := activity_listener_receive(&listener)
		if result.kind == .Unavailable {
			break
		}
		if result.kind == .Message && result.message.kind == "incomplete" {
			run.incomplete = strings.clone(result.message.description)
		}
		destroy_struct(&result.message)
	}
	return
}

@(test)
test_research_station_reports_incomplete_when_agent_writes :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-research-write-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	run := run_station_kind(t, root, "research", FAKE_WRITING_AGENT)
	defer delete(run.incomplete)
	testing.expect_value(t, run.incomplete, "Cupping Station changed 1 paths")
	testing.expect_value(t, run.exit_code, 1)
}

@(test)
test_research_station_sends_no_incomplete_when_agent_writes_nothing :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-research-clean-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	run := run_station_kind(t, root, "research", FAKE_SILENT_AGENT)
	defer delete(run.incomplete)
	testing.expect_value(t, run.incomplete, "")
	testing.expect_value(t, run.exit_code, 0)
}

@(test)
test_execute_station_sends_no_incomplete_when_agent_writes :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-execute-write-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	run := run_station_kind(t, root, "execute", FAKE_WRITING_AGENT)
	defer delete(run.incomplete)
	testing.expect_value(t, run.incomplete, "")
	testing.expect_value(t, run.exit_code, 0)
}

Pull_Run :: struct {
	exit_code:        int,
	kind:             string, // last Taste report kind, empty when none arrived; owned by the caller
	description:      string, // owned by the caller
	taste_after_exit: bool,   // a Taste report arrived after agent_exited
}

// Runs one execute Station with a Taste and message in a fresh repository with one
// commit. An empty taste runs the Shot without one, with no Taste flags at all.
run_station_pull :: proc(t: ^testing.T, root, agent_script, taste, message: string) -> (run: Pull_Run) {
	repo, _ := filepath.join({root, "beans"}, context.temp_allocator)
	socket, _ := filepath.join({root, "report.sock"}, context.temp_allocator)
	agent, _ := filepath.join({root, "agent.sh"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(repo), os.Error(nil))
	testing.expect_value(t, os.write_entire_file(agent, agent_script, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	init_state, _, init_stderr, init_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `git init -q "$1" && git -C "$1" config user.name test && git -C "$1" config user.email test@example.com && git -C "$1" commit -q --allow-empty -m init`, "pull-test", repo},
	}, context.allocator)
	defer delete(init_stderr)
	testing.expect_value(t, init_err, os.Error(nil))
	testing.expect(t, init_state.success, string(init_stderr))

	binary := build_test_binary(t, root)
	defer delete(binary)
	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)

	command := `cd "$1" && "$2" station --kind execute --report "$3" --station shot-a --brew order-1 --prompt "hi" -- sh "$4" </dev/null`
	if taste != "" {
		command = `cd "$1" && "$2" station --kind execute --report "$3" --station shot-a --brew order-1 --prompt "hi" --taste "$5" --message "$6" -- sh "$4" </dev/null`
	}
	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", command, "station-pull-test", repo, binary, socket, agent, taste, message},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	run.exit_code = state.exit_code

	exited := false
	for {
		result := activity_listener_receive(&listener)
		if result.kind == .Unavailable {
			break
		}
		if result.kind == .Message {
			switch result.message.kind {
			case "agent_exited":
				exited = true
			case "taste_failed", "taste_passed", "pulled":
				delete(run.kind)
				delete(run.description)
				run.kind = strings.clone(result.message.kind)
				run.description = strings.clone(result.message.description)
				run.taste_after_exit = exited
			}
		}
		destroy_struct(&result.message)
	}
	return
}

// Returns the Git output for the repository; the caller owns it.
pull_git :: proc(t: ^testing.T, repo: string, args: ..string) -> string {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "git", "-C", repo)
	append(&command, ..args)
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = command[:]}, context.allocator)
	defer delete(stderr)
	testing.expect_value(t, err, os.Error(nil))
	testing.expect(t, state.success, string(stderr))
	return string(stdout)
}

@(test)
test_pull_with_passing_taste_commits_with_message :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-pull-pass-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	run := run_station_pull(t, root, FAKE_WRITING_AGENT, "true", "Add the change")
	defer delete(run.kind)
	defer delete(run.description)
	testing.expect_value(t, run.exit_code, 0)
	testing.expect_value(t, run.kind, "pulled")
	testing.expect(t, run.taste_after_exit, "the Taste must report after agent_exited")

	repo, _ := filepath.join({root, "beans"}, context.temp_allocator)
	subject := pull_git(t, repo, "log", "-1", "--format=%s")
	defer delete(subject)
	testing.expect_value(t, strings.trim_space(subject), "Add the change")
	count := pull_git(t, repo, "rev-list", "--count", "HEAD")
	defer delete(count)
	testing.expect_value(t, strings.trim_space(count), "2")
}

@(test)
test_pull_with_failing_taste_sends_taste_failed_and_makes_no_commit :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-pull-fail-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	run := run_station_pull(t, root, FAKE_WRITING_AGENT, "false", "Add the change")
	defer delete(run.kind)
	defer delete(run.description)
	testing.expect_value(t, run.exit_code, 1)
	testing.expect_value(t, run.kind, "taste_failed")
	testing.expect_value(t, run.description, "Taste exited with code 1")

	repo, _ := filepath.join({root, "beans"}, context.temp_allocator)
	count := pull_git(t, repo, "rev-list", "--count", "HEAD")
	defer delete(count)
	testing.expect_value(t, strings.trim_space(count), "1")
}

@(test)
test_pull_with_passing_taste_and_no_changes_sends_taste_passed :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-pull-clean-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	run := run_station_pull(t, root, FAKE_SILENT_AGENT, "true", "Add the change")
	defer delete(run.kind)
	defer delete(run.description)
	testing.expect_value(t, run.exit_code, 0)
	testing.expect_value(t, run.kind, "taste_passed")
	testing.expect_value(t, run.description, "Taste passed with no changes")

	repo, _ := filepath.join({root, "beans"}, context.temp_allocator)
	count := pull_git(t, repo, "rev-list", "--count", "HEAD")
	defer delete(count)
	testing.expect_value(t, strings.trim_space(count), "1")
}

@(test)
test_shot_without_taste_sends_no_taste_report_and_makes_no_commit :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-pull-none-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	run := run_station_pull(t, root, FAKE_WRITING_AGENT, "", "")
	defer delete(run.kind)
	defer delete(run.description)
	testing.expect_value(t, run.exit_code, 0)
	testing.expect_value(t, run.kind, "")

	repo, _ := filepath.join({root, "beans"}, context.temp_allocator)
	count := pull_git(t, repo, "rev-list", "--count", "HEAD")
	defer delete(count)
	testing.expect_value(t, strings.trim_space(count), "1")
}

@(test)
test_station_parse_requires_execute_taste_and_message_together :: proc(t: ^testing.T) {
	with_taste, taste_err := parse_args({"station", "--report", "/tmp/r.sock", "--station", "shot-a", "--brew", "order-1", "--prompt", "hi", "--taste", "just test", "--message", "Add it", "--", "pi"})
	testing.expect_value(t, taste_err, "")
	testing.expect_value(t, with_taste.taste, "just test")
	testing.expect_value(t, with_taste.message, "Add it")

	_, message_err := parse_args({"station", "--report", "/tmp/r.sock", "--station", "shot-a", "--brew", "order-1", "--prompt", "hi", "--message", "Add it", "--", "pi"})
	testing.expect(t, message_err != "", "a message without a taste must be refused")
	_, taste_only_err := parse_args({"station", "--report", "/tmp/r.sock", "--station", "shot-a", "--brew", "order-1", "--prompt", "hi", "--taste", "just test", "--", "pi"})
	testing.expect(t, taste_only_err != "", "a taste without a message must be refused")
	_, research_err := parse_args({"station", "--report", "/tmp/r.sock", "--station", "shot-a", "--brew", "order-1", "--prompt", "hi", "--kind", "research", "--taste", "just test", "--message", "Add it", "--", "pi"})
	testing.expect(t, research_err != "", "a research Station must not take a taste")
}

// Fake agent that answers each prompt with one agent_end and stays alive until its
// input closes. Its first answer is the only one a one-turn Shot receives.
FAKE_ONE_TURN_AGENT :: `#!/bin/sh
while IFS= read -r line; do
  printf '%s\n' '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"turn 1"}]}]}'
done
`

// Same as FAKE_ONE_TURN_AGENT, but each turn first writes changed.txt.
FAKE_ONE_TURN_WRITING_AGENT :: `#!/bin/sh
while IFS= read -r line; do
  printf 'changed\n' > changed.txt
  printf '%s\n' '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"turn 1"}]}]}'
done
`

Held_Station_Run :: struct {
	exit_code:    int,
	timed_out:    bool,       // the Station was still alive at the timeout and was killed
	kinds:        [dynamic]string, // report kinds in arrival order; owned
	descriptions: [dynamic]string, // parallel to kinds; owned
}

held_station_destroy :: proc(run: ^Held_Station_Run) {
	for kind in run.kinds {
		delete(kind)
	}
	delete(run.kinds)
	for description in run.descriptions {
		delete(description)
	}
	delete(run.descriptions)
}

// Runs one execute or research Station in a fresh one-commit repository, with its stdin
// held open by the test. Only the Station can end the run: a Station still alive after
// the timeout is killed and marked timed_out. extra holds the Station's own flags.
run_station_held_open :: proc(t: ^testing.T, root, agent_script: string, extra: ..string) -> (run: Held_Station_Run) {
	repo, _ := filepath.join({root, "beans"}, context.temp_allocator)
	socket, _ := filepath.join({root, "report.sock"}, context.temp_allocator)
	agent, _ := filepath.join({root, "agent.sh"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(repo), os.Error(nil))
	testing.expect_value(t, os.write_entire_file(agent, agent_script, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	init_state, _, init_stderr, init_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `git init -q "$1" && git -C "$1" config user.name test && git -C "$1" config user.email test@example.com && git -C "$1" commit -q --allow-empty -m init`, "held-test", repo},
	}, context.allocator)
	defer delete(init_stderr)
	testing.expect_value(t, init_err, os.Error(nil))
	testing.expect(t, init_state.success, string(init_stderr))

	binary := build_test_binary(t, root)
	defer delete(binary)
	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)

	command := make([dynamic]string, context.temp_allocator)
	append(&command, binary, "station", "--report", socket, "--station", "shot-a", "--brew", "order-1", "--prompt", "hi")
	append(&command, ..extra)
	append(&command, "--", "sh", agent)

	stdin_read, stdin_write, pipe_err := os.pipe()
	testing.expect_value(t, pipe_err, os.Error(nil))
	defer os.close(stdin_write)
	process, start_err := os.process_start(os.Process_Desc{command = command[:], working_dir = repo, stdin = stdin_read, stderr = os.stderr})
	_ = os.close(stdin_read)
	testing.expect_value(t, start_err, os.Error(nil))
	if start_err != nil {
		return
	}
	state, wait_err := os.process_wait(process, 10*time.Second)
	if wait_err == .Timeout {
		run.timed_out = true
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
	}
	run.exit_code = state.exit_code

	for {
		result := activity_listener_receive(&listener)
		if result.kind == .Unavailable {
			break
		}
		if result.kind == .Message {
			append(&run.kinds, strings.clone(result.message.kind))
			append(&run.descriptions, strings.clone(result.message.description))
		}
		destroy_struct(&result.message)
	}
	return
}

@(test)
test_research_shot_ends_after_its_first_turn :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-one-turn-research-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	run := run_station_held_open(t, root, FAKE_ONE_TURN_AGENT, "--kind", "research")
	defer held_station_destroy(&run)
	testing.expect(t, !run.timed_out, "a research Station must end after its first turn")
	testing.expect_value(t, run.exit_code, 0)
	testing.expect(t, slice_contains(run.kinds[:], "turn_done"), "the first turn must be reported")
	testing.expect(t, slice_contains(run.kinds[:], "agent_exited"), "the agent exit must be reported")
	testing.expect(t, !slice_contains(run.kinds[:], "incomplete"), "a research Shot that changed nothing must not be incomplete")
}

@(test)
test_research_shot_reports_incomplete_after_its_first_turn_when_agent_writes :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-one-turn-incomplete-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	run := run_station_held_open(t, root, FAKE_ONE_TURN_WRITING_AGENT, "--kind", "research")
	defer held_station_destroy(&run)
	testing.expect(t, !run.timed_out, "an incomplete research Station must still end without waiting for input")
	testing.expect_value(t, run.exit_code, 1)
	testing.expect(t, slice_contains(run.kinds[:], "incomplete"), "a research Shot that changed a file must be incomplete")
	testing.expect(t, slice_contains(run.kinds[:], "agent_exited"), "the agent exit must be reported")
}

@(test)
test_pull_shot_ends_after_its_first_turn_and_commits :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-one-turn-pull-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	run := run_station_held_open(t, root, FAKE_ONE_TURN_WRITING_AGENT, "--kind", "execute", "--taste", "true", "--message", "Add the change")
	defer held_station_destroy(&run)
	testing.expect(t, !run.timed_out, "a Pull Station must end after its first turn")
	testing.expect_value(t, run.exit_code, 0)
	testing.expect(t, slice_contains(run.kinds[:], "agent_exited"), "the agent exit must be reported")
	testing.expect(t, slice_contains(run.kinds[:], "pulled"), "a passing Taste must report pulled")
	if len(run.kinds) > 0 {
		testing.expect_value(t, run.kinds[len(run.kinds)-1], "pulled")
	}

	repo, _ := filepath.join({root, "beans"}, context.temp_allocator)
	count := pull_git(t, repo, "rev-list", "--count", "HEAD")
	defer delete(count)
	testing.expect_value(t, strings.trim_space(count), "2")
}

// An interactive Shot stays open after its first turn, so a reply sent a second later
// still reaches the agent and gets its own turn.
@(test)
test_interactive_shot_keeps_input_open_after_its_first_turn :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-interactive-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	socket, _ := filepath.join({root, "report.sock"})
	agent, _ := filepath.join({root, "agent.sh"})
	received, _ := filepath.join({root, "received.log"})
	defer delete(socket)
	defer delete(agent)
	defer delete(received)
	testing.expect_value(t, os.write_entire_file(agent, FAKE_STATION_AGENT, os.Permissions{.Read_User, .Write_User, .Execute_User}), os.Error(nil))
	binary := build_test_binary(t, root)
	defer delete(binary)
	listener, listener_ok := activity_listener_open(socket)
	testing.expect(t, listener_ok)
	defer activity_listener_close(&listener)

	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `(sleep 1; printf '%s\n' "second question") | "$4" station --report "$1" --station shot-a --brew order-1 --prompt "first question" -- sh "$2" "$3"`, "interactive-test", socket, agent, received, binary},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state.success, string(stderr))

	turns: [dynamic]string
	defer {
		for turn in turns {
			delete(turn)
		}
		delete(turns)
	}
	for {
		result := activity_listener_receive(&listener)
		if result.kind == .Unavailable {
			break
		}
		if result.kind == .Message && result.message.kind == "turn_done" {
			append(&turns, strings.clone(result.message.description))
		}
		destroy_struct(&result.message)
	}
	testing.expect_value(t, len(turns), 2)
	if len(turns) == 2 {
		testing.expect_value(t, turns[1], "turn 2")
	}
}
