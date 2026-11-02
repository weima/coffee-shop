package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

HOST_TEST_TEMP_DIR :: "/private/tmp" when ODIN_OS == .Darwin else "/tmp"
Host_Contract_Run :: struct {
	root:  string,
	state: string,
	out:   string,
}

// Runs the foreground host in a temporary Git repository. The fake Pi prevents
// tests from contacting an AI service while still exercising the Station boundary.
run_host_requests :: proc(t: ^testing.T, prefix, requests: string) -> (run: Host_Contract_Run) {
	root, make_err := os.make_directory_temp(HOST_TEST_TEMP_DIR, prefix, context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	run.root = root
	repo := fmt.aprintf("%s/beans", root)
	bin := fmt.aprintf("%s/bin", root)
	run.state = fmt.aprintf("%s/state", root)
	defer delete(repo)
	defer delete(bin)
	rwx := os.Permissions{.Read_User, .Write_User, .Execute_User}
	testing.expect_value(t, os.make_directory_all(repo), os.Error(nil))
	testing.expect_value(t, os.make_directory_all(bin), os.Error(nil))
	pi := fmt.aprintf("%s/pi", bin)
	defer delete(pi)
	testing.expect_value(t, os.write_entire_file(pi, HOST_FAKE_PI, rwx), os.Error(nil))

	git_state, _, git_stderr, git_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `git init -q "$1" && git -C "$1" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init`, "host-test", repo},
	}, context.allocator)
	defer delete(git_stderr)
	testing.expect_value(t, git_err, os.Error(nil))
	testing.expect(t, git_state.success, string(git_stderr))

	input, _ := strings.replace_all(requests, "@REPO@", repo, context.temp_allocator)
	input_path := fmt.aprintf("%s/requests.ndjson", root)
	pi_args_path := fmt.aprintf("%s/pi-args", root)
	defer delete(input_path)
	defer delete(pi_args_path)
	testing.expect_value(t, os.write_entire_file(input_path, input, rwx), os.Error(nil))
	binary := build_test_binary(t, root)
	defer delete(binary)
	state_run, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `export PATH="$2:$PATH" CS_STATE_DIR="$3" CS_TEST_PI_ARGS="$5"; cat "$1" | "$4" host --impl=odin`, "host-test", input_path, bin, run.state, binary, pi_args_path},
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, exec_err, os.Error(nil))
	testing.expect(t, state_run.success, string(stderr))
	run.out = strings.clone(string(stdout), context.allocator)
	return
}

host_contract_destroy :: proc(run: Host_Contract_Run) {
	os.remove_all(run.root)
	delete(run.root)
	delete(run.state)
	delete(run.out)
}

@(test)
test_foreground_host_accepts_dispatches_and_starts_sessions :: proc(t: ^testing.T) {
	long_prompt := fmt.aprintf("first line\nit's a long prompt\n%s", strings.repeat("x", 5000, context.temp_allocator))
	defer delete(long_prompt)
	json_prompt, _ := strings.replace_all(long_prompt, "\n", "\\n", context.temp_allocator)
	requests := fmt.aprintf(`{{"type":"dispatch","request_id":"order-1","repo":"@REPO@","recipe":{{"shots":[{{"id":"shot-a","prompt":"%s","model":"github-copilot/claude-haiku-5.5"}}]}}}}
{{"type":"dispatch","request_id":"order-2","repo":"@REPO@","recipe":{{"shots":[{{"id":"shot-b","prompt":"inspect the tests"}}]}}}}
{{"type":"dispatch","request_id":"order-3","repo":"@REPO@","recipe":{{"shots":[{{"id":"../escape","prompt":"x"}}]}}}}
{{"type":"dispatch","request_id":"order-4","repo":"@REPO@","recipe":{{"shots":[{{"id":"shot-c","prompt":"x","model":"bad model;"}}]}}}}
{{"type":"shutdown","request_id":"shutdown-1"}}
`, json_prompt)
	defer delete(requests)
	run := run_host_requests(t, "coffee-shop-host-*", requests)
	defer host_contract_destroy(run)
	out := run.out
	testing.expect(t, host_output_contains(out, `{"type":"ready","protocol":1}`), out)
	testing.expect(t, host_output_contains(out, `{"type":"dispatch_accepted","request_id":"order-1"}`), out)
	testing.expect(t, host_output_contains(out, `{"type":"session_started","request_id":"order-1","shot_id":"shot-a","pane_id":"order-1/shot-a"}`), out)
	testing.expect(t, host_output_contains(out, `{"type":"dispatch_accepted","request_id":"order-2"}`), out)
	testing.expect(t, host_output_contains(out, `{"type":"session_started","request_id":"order-2","shot_id":"shot-b","pane_id":"order-2/shot-b"}`), out)
	testing.expect(t, host_output_contains(out, `"request_id":"order-3"`) && host_output_contains(out, `each shot needs a valid id and a prompt`), out)
	testing.expect(t, !host_output_contains(out, `{"type":"dispatch_accepted","request_id":"order-3"}`), out)
	testing.expect(t, host_output_contains(out, `"request_id":"order-4","shot_id":"shot-c"`) && host_output_contains(out, `shot model must be`), out)
	testing.expect(t, !host_output_contains(out, `{"type":"dispatch_accepted","request_id":"order-4"}`), out)
	testing.expect(t, host_output_contains(out, `{"type":"stopped","request_id":"shutdown-1"}`), out)

	pi_args_path := fmt.tprintf("%s/pi-args", run.root)
	pi_args, pi_args_err := os.read_entire_file(pi_args_path, context.allocator)
	defer delete(pi_args)
	testing.expect_value(t, pi_args_err, os.Error(nil))
	testing.expect(t, strings.contains(string(pi_args), "--model github-copilot/claude-haiku-5.5"), string(pi_args))
	testing.expect(t, strings.contains(string(pi_args), "--model opencode-go/deepseek-v4.1-flash"), string(pi_args))

	prompt_path := fmt.aprintf("%s/host/order-1/prompts/shot-a.md", run.state)
	defer delete(prompt_path)
	prompt_data, prompt_err := os.read_entire_file(prompt_path, context.allocator)
	defer delete(prompt_data)
	testing.expect_value(t, prompt_err, os.Error(nil))
	testing.expect_value(t, string(prompt_data), fmt.tprintf("%s\n\n%s", HOST_REPLY_STYLE, long_prompt))
	shot_a_log := fmt.aprintf("%s/host/order-1/logs/shot-a.log", run.state)
	shot_b_log := fmt.aprintf("%s/host/order-2/logs/shot-b.log", run.state)
	testing.expect(t, os.exists(shot_a_log) && os.exists(shot_b_log), "each headless Station has a per-Shot log")
	delete(shot_a_log)
	delete(shot_b_log)
	testing.expect(t, !os.exists(fmt.tprintf("%s/host/order-4/stations/shot-c", run.state)), "invalid model must not create a worktree")
}

@(test)
test_foreground_host_passes_shot_kind_and_rejects_unknown_kind :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-kind-*", `{"type":"dispatch","request_id":"order-5","repo":"@REPO@","recipe":{"shots":[{"id":"shot-r","prompt":"read the code","kind":"research"},{"id":"shot-e","prompt":"make the change","kind":"execute"}]}}
{"type":"dispatch","request_id":"order-6","repo":"@REPO@","recipe":{"shots":[{"id":"shot-w","prompt":"write a file","kind":"write"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `{"type":"session_started","request_id":"order-5","shot_id":"shot-r"`), run.out)
	testing.expect(t, host_output_contains(run.out, `{"type":"session_started","request_id":"order-5","shot_id":"shot-e"`), run.out)
	testing.expect(t, host_output_contains(run.out, `{"type":"error","request_id":"order-6","shot_id":"shot-w","reason":"shot kind must be execute or research"}`), run.out)
	testing.expect(t, !host_output_contains(run.out, `{"type":"dispatch_accepted","request_id":"order-6"}`), run.out)
	testing.expect(t, !os.exists(fmt.tprintf("%s/host/order-6/stations/shot-w", run.state)), "unknown kind must not create a worktree")
	testing.expect(t, os.exists(fmt.tprintf("%s/host/order-5/logs/shot-r.log", run.state)) && os.exists(fmt.tprintf("%s/host/order-5/logs/shot-e.log", run.state)), "valid Shots start headless sessions")
}

host_test_station_command :: proc(kind: string) -> string {
	return host_station_command("/coffee-shop", "/tmp/report", "/tmp/extension", "/oreo/bin/oreo-host", "shot", "brew", "/tmp/prompt", "", "", "", kind, SHOT_RUNTIME_PI, "", "")
}

@(test)
test_host_station_command_execute_includes_codemode :: proc(t: ^testing.T) {
	command := host_test_station_command(SHOT_KIND_EXECUTE)
	defer delete(command)
	testing.expect(t, strings.contains(command, "-- pi --mode rpc --tools +codemode -e"), command)
}

@(test)
test_host_station_command_research_gets_scratch_tools :: proc(t: ^testing.T) {
	command := host_test_station_command(SHOT_KIND_RESEARCH)
	defer delete(command)
	testing.expect(t, strings.contains(command, "-- pi --mode rpc --tools read,grep,find,ls,write,codemode -e"), command)
}

@(test)
test_host_station_command_passes_taste_and_message :: proc(t: ^testing.T) {
	command := host_station_command("/coffee-shop", "/tmp/report", "/tmp/extension", "/oreo/bin/oreo-host", "shot", "brew", "/tmp/prompt", "", "", "", SHOT_KIND_EXECUTE, SHOT_RUNTIME_PI, "just test", "Add the taste check")
	defer delete(command)
	testing.expect(t, strings.contains(command, "--taste 'just test' --message 'Add the taste check'"), command)
}

@(test)
test_host_station_command_passes_model_and_thinking :: proc(t: ^testing.T) {
	command := host_station_command("/coffee-shop", "/tmp/report", "/tmp/extension", "/oreo/bin/oreo-host", "shot", "brew", "/tmp/prompt", "github-copilot/claude-haiku-5.5", "", "low", SHOT_KIND_EXECUTE, SHOT_RUNTIME_PI, "", "")
	defer delete(command)
	testing.expect(t, strings.contains(command, "--model 'github-copilot/claude-haiku-5.5' --thinking 'low' -e"), command)
	without_thinking := host_station_command("/coffee-shop", "/tmp/report", "/tmp/extension", "/oreo/bin/oreo-host", "shot", "brew", "/tmp/prompt", DEFAULT_PI_STATION_MODEL, "", "", SHOT_KIND_EXECUTE, SHOT_RUNTIME_PI, "", "")
	defer delete(without_thinking)
	testing.expect(t, strings.contains(without_thinking, "--model 'opencode-go/deepseek-v4.1-flash' -e"), without_thinking)
	testing.expect(t, !strings.contains(without_thinking, "--thinking"), without_thinking)
}

@(test)
test_host_station_command_oreo_uses_transport_only :: proc(t: ^testing.T) {
	command := host_station_command("/coffee-shop", "/tmp/report", "/tmp/extension", "/oreo/bin/oreo-host", "shot", "brew", "/tmp/prompt", "gpt-6-luna", "openai-codex", "high", SHOT_KIND_EXECUTE, SHOT_RUNTIME_OREO, "", "")
	defer delete(command)
	testing.expect(t, strings.contains(command, "OREO_PROVIDER='openai-codex' OREO_MODEL='gpt-6-luna' OREO_THINKING='high' OREO_SESSION_ID=shot pi --mode rpc --no-tools --no-mcp --no-extensions --model 'openai-codex/gpt-6-luna' --thinking high -e"), command)
}

@(test)
test_host_station_command_codemode_option_controls_flag :: proc(t: ^testing.T) {
	for case_ in ([]struct{options: Shot_Options, codemode: bool}{{{codemode = true}, true}, {{codemode = false}, false}, {{interactive = true, codemode = true}, true}}) {
		command := host_station_command("/coffee-shop", "/tmp/report", "/tmp/extension", "/oreo/bin/oreo-host", "shot", "brew", "/tmp/prompt", "", "", "", SHOT_KIND_EXECUTE, SHOT_RUNTIME_PI, "", "", case_.options)
		defer delete(command)
		testing.expect_value(t, strings.contains(command, "+codemode"), case_.codemode)
		testing.expect_value(t, strings.contains(command, "--interactive"), case_.options.interactive)
		testing.expect_value(t, strings.contains(command, "--codemode false"), !case_.codemode)
	}
}

@(test)
test_foreground_host_passes_taste_and_message_to_station :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-taste-*", `{"type":"dispatch","request_id":"order-t1","repo":"@REPO@","recipe":{"shots":[{"id":"shot-t","prompt":"make the change","taste":"just test","message":"Add the taste check"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `"type":"session_started","request_id":"order-t1","shot_id":"shot-t"`), run.out)
}

@(test)
test_foreground_host_omits_taste_without_taste :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-no-taste-*", `{"type":"dispatch","request_id":"order-t2","repo":"@REPO@","recipe":{"shots":[{"id":"shot-n","prompt":"make the change"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `"type":"session_started","request_id":"order-t2","shot_id":"shot-n"`), run.out)
}

@(test)
test_foreground_host_rejects_invalid_tastes_before_start :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-bad-taste-*", `{"type":"dispatch","request_id":"taste-research","repo":"@REPO@","recipe":{"shots":[{"id":"shot-r","prompt":"read","kind":"research","taste":"just test","message":"commit"}]}}
{"type":"dispatch","request_id":"taste-no-message","repo":"@REPO@","recipe":{"shots":[{"id":"shot-m","prompt":"change","taste":"just test"}]}}
{"type":"dispatch","request_id":"message-no-taste","repo":"@REPO@","recipe":{"shots":[{"id":"shot-n","prompt":"change","message":"commit"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `"request_id":"taste-research","shot_id":"shot-r","reason":"shot taste needs an execute kind"`), run.out)
	testing.expect(t, host_output_contains(run.out, `"request_id":"taste-no-message","shot_id":"shot-m","reason":"shot message is required with a taste`), run.out)
	testing.expect(t, host_output_contains(run.out, `"request_id":"message-no-taste","shot_id":"shot-n","reason":"shot message needs a taste"`), run.out)
	testing.expect(t, !host_output_contains(run.out, `"type":"session_started"`), run.out)
}

@(test)
test_foreground_host_rejects_invalid_thinking_level :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-bad-thinking-*", `{"type":"dispatch","request_id":"order-h3","repo":"@REPO@","recipe":{"shots":[{"id":"shot-x","prompt":"make the change","thinking":"sometimes"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `"reason":"shot thinking must be off, minimal, low, medium, high, xhigh, or max"`), run.out)
	testing.expect(t, !host_output_contains(run.out, `"type":"session_started"`), run.out)
	testing.expect(t, !os.exists(fmt.tprintf("%s/host/order-h3/stations/shot-x", run.state)), "invalid thinking must not create a worktree")
}

@(test)
test_foreground_host_validates_oreo_runtime :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-oreo-*", `{"type":"dispatch","request_id":"oreo-good","repo":"@REPO@","recipe":{"shots":[{"id":"shot-o","prompt":"exact assignment","runtime":"oreo","model":"openai-codex/gpt-6-luna","thinking":"high"}]}}
{"type":"dispatch","request_id":"oreo-bad-runtime","repo":"@REPO@","recipe":{"shots":[{"id":"shot-u","prompt":"x","runtime":"other"}]}}
{"type":"dispatch","request_id":"oreo-no-route","repo":"@REPO@","recipe":{"shots":[{"id":"shot-m","prompt":"x","runtime":"oreo","thinking":"high"}]}}
{"type":"dispatch","request_id":"oreo-bad-route","repo":"@REPO@","recipe":{"shots":[{"id":"shot-b","prompt":"x","runtime":"oreo","model":"openai-codex/","thinking":"high"}]}}
{"type":"dispatch","request_id":"oreo-no-thinking","repo":"@REPO@","recipe":{"shots":[{"id":"shot-t","prompt":"x","runtime":"oreo","model":"openai-codex/gpt-6-luna"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `"type":"session_started","request_id":"oreo-good","shot_id":"shot-o"`), run.out)
	for request in ([]string{"oreo-bad-runtime", "oreo-no-route", "oreo-bad-route", "oreo-no-thinking"}) {
		testing.expect(t, host_output_contains(run.out, fmt.tprintf(`{{"type":"error","request_id":"%s"`, request)), run.out)
		testing.expect(t, !host_output_contains(run.out, fmt.tprintf(`{{"type":"dispatch_accepted","request_id":"%s"`, request)), run.out)
		testing.expect(t, !host_output_contains(run.out, fmt.tprintf(`{{"type":"session_started","request_id":"%s"`, request)), run.out)
	}
}

@(test)
test_foreground_host_keeps_pi_runtime_as_default :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-pi-default-*", `{"type":"dispatch","request_id":"pi-default","repo":"@REPO@","recipe":{"shots":[{"id":"shot-p","prompt":"keep current behavior"}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `"type":"session_started","request_id":"pi-default","shot_id":"shot-p"`), run.out)
}

@(test)
test_foreground_host_refuses_invalid_interactive_and_codemode :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-bad-options-*", `{"type":"dispatch","request_id":"order-o1","repo":"@REPO@","recipe":{"shots":[{"id":"shot-i","prompt":"go","interactive":"yes"}]}}
{"type":"dispatch","request_id":"order-o2","repo":"@REPO@","recipe":{"shots":[{"id":"shot-c","prompt":"go","codemode":1}]}}
{"type":"dispatch","request_id":"order-o3","repo":"@REPO@","recipe":{"shots":[{"id":"shot-ok","prompt":"go","interactive":true,"codemode":false}]}}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `"request_id":"order-o1","shot_id":"shot-i","reason":"shot interactive must be true or false"`), run.out)
	testing.expect(t, host_output_contains(run.out, `"request_id":"order-o2","shot_id":"shot-c","reason":"shot codemode must be true or false"`), run.out)
	testing.expect(t, !host_output_contains(run.out, `"type":"session_started","request_id":"order-o1"`), run.out)
	testing.expect(t, !host_output_contains(run.out, `"type":"session_started","request_id":"order-o2"`), run.out)
	testing.expect(t, host_output_contains(run.out, `"type":"session_started","request_id":"order-o3","shot_id":"shot-ok"`), run.out)
}

@(test)
test_host_emits_received_for_every_request_line :: proc(t: ^testing.T) {
	sessions := `{"type":"sessions","request_id":"order-recv-1"}`
	shutdown := `{"type":"shutdown","request_id":"shutdown-1"}`
	requests := fmt.aprintf("%s\n%s\n", sessions, shutdown)
	defer delete(requests)
	run := run_host_requests(t, "coffee-shop-host-received-*", requests)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, fmt.tprintf(`{{"type":"received","request_id":"order-recv-1","bytes":%d}}`, len(sessions))), run.out)
	testing.expect(t, host_output_contains(run.out, fmt.tprintf(`{{"type":"received","request_id":"shutdown-1","bytes":%d}}`, len(shutdown))), run.out)
}

@(test)
test_host_receives_malformed_line_before_error :: proc(t: ^testing.T) {
	bad := "this is not json"
	requests := fmt.aprintf("%s\n%s\n%s\n", `{"type":"sessions","request_id":"order-recv-2"}`, bad, `{"type":"shutdown","request_id":"shutdown-1"}`)
	defer delete(requests)
	run := run_host_requests(t, "coffee-shop-host-received-bad-*", requests)
	defer host_contract_destroy(run)
	received := fmt.tprintf(`{{"type":"received","request_id":"","bytes":%d}}`, len(bad))
	error := `{"type":"error","reason":"invalid json"}`
	out := strip_all_event_timestamps(run.out)
	testing.expect(t, strings.contains(out, received), out)
	testing.expect(t, strings.contains(out, error), out)
	testing.expect(t, strings.index(out, error) > strings.index(out, received), out)
}

@(test)
test_host_reports_overlong_line_and_keeps_serving :: proc(t: ^testing.T) {
	long_line := strings.repeat("x", 70000, context.temp_allocator)
	after := `{"type":"sessions","request_id":"after-long"}`
	requests := fmt.aprintf("%s\n%s\n{\"type\":\"shutdown\",\"request_id\":\"shutdown-1\"}\n", long_line, after)
	defer delete(requests)
	run := run_host_requests(t, "coffee-shop-host-overlong-*", requests)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `{"type":"error"`) && host_output_contains(run.out, "65536") && host_output_contains(run.out, "70000"), run.out)
	testing.expect(t, !host_output_contains(run.out, fmt.tprintf(`"bytes":%d`, len(long_line))), run.out)
	testing.expect(t, host_output_contains(run.out, fmt.tprintf(`{{"type":"received","request_id":"after-long","bytes":%d}}`, len(after))), run.out)
	testing.expect(t, host_output_contains(run.out, `{"type":"sessions","sessions":[]}`), run.out)
}

@(test)
test_host_cancel_signals_the_named_shot :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-cancel-*", `{"type":"dispatch","request_id":"order-c1","repo":"@REPO@","recipe":{"shots":[{"id":"shot-a","prompt":"make the change"}]}}
{"type":"cancel","request_id":"cancel-1","shot_id":"shot-a"}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `"type":"session_started","request_id":"order-c1","shot_id":"shot-a","pane_id":"order-c1/shot-a"`), run.out)
	testing.expect(t, host_output_contains(run.out, `"type":"cancelled","request_id":"cancel-1","shot_id":"shot-a"}`), run.out)
	testing.expect(t, !host_output_contains(run.out, `"request_id":"cancel-1","shot_id":"shot-a","reason"`), run.out)
}

@(test)
test_host_cancel_reports_unknown_shot_and_keeps_serving :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-cancel-missing-*", `{"type":"dispatch","request_id":"order-c2","repo":"@REPO@","recipe":{"shots":[{"id":"shot-a","prompt":"make the change"}]}}
{"type":"cancel","request_id":"cancel-2","shot_id":"shot-missing"}
{"type":"sessions","request_id":"after-cancel"}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `{"type":"cancelled","request_id":"cancel-2","shot_id":"shot-missing","reason":"no Station is running for that shot"}`), run.out)
	testing.expect(t, host_output_contains(run.out, `"type":"sessions"`), run.out)
	testing.expect(t, host_output_contains(run.out, `"type":"stopped","request_id":"shutdown-1"`), run.out)
}

@(test)
test_host_cancel_without_shot_cancels_every_station :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-cancel-all-*", `{"type":"dispatch","request_id":"order-c3","repo":"@REPO@","recipe":{"shots":[{"id":"shot-a","prompt":"make the change"},{"id":"shot-b","prompt":"make the change"}]}}
{"type":"cancel","request_id":"cancel-3"}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `"type":"cancelled","request_id":"cancel-3","shot_id":"shot-a"`), run.out)
	testing.expect(t, host_output_contains(run.out, `"type":"cancelled","request_id":"cancel-3","shot_id":"shot-b"`), run.out)
}

@(test)
test_host_cancel_keeps_serving_a_following_request :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-cancel-after-*", `{"type":"dispatch","request_id":"order-c4","repo":"@REPO@","recipe":{"shots":[{"id":"shot-a","prompt":"make the change"}]}}
{"type":"cancel","request_id":"cancel-4","shot_id":"shot-a"}
{"type":"sessions","request_id":"after-cancel"}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	out := strip_all_event_timestamps(run.out)
	testing.expect(t, strings.contains(out, `"request_id":"cancel-4","shot_id":"shot-a"`), out)
	testing.expect(t, strings.contains(out, `"type":"sessions"`), out)
	testing.expect(t, strings.index(out, `"type":"sessions"`) > strings.index(out, `"request_id":"cancel-4"`), out)
	testing.expect(t, host_output_contains(out, `{"type":"stopped","request_id":"shutdown-1"}`), out)
}

@(test)
test_host_cancel_without_request_id_is_rejected :: proc(t: ^testing.T) {
	run := run_host_requests(t, "coffee-shop-host-cancel-noid-*", `{"type":"cancel"}
{"type":"shutdown","request_id":"shutdown-1"}
`)
	defer host_contract_destroy(run)
	testing.expect(t, host_output_contains(run.out, `{"type":"error","reason":"request_id must be a valid shot-style identifier (letters, digits, - or _, up to 64)"}`), run.out)
	testing.expect(t, !host_output_contains(run.out, `"type":"cancelled"`), run.out)
	testing.expect(t, host_output_contains(run.out, `{"type":"stopped","request_id":"shutdown-1"}`), run.out)
}
