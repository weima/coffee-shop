package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Blend tests drive the host over stdin and stdout with temporary Git repositories.
// No Herdr or Pi process runs: Blend only uses Git.
BLEND_TEST_SCRIPT :: `set -u
export CS_STATE_DIR="$2"
cat "$1" | "$3" host --impl=odin
`

// Runs git in repo and returns its trimmed stdout. ok is false when Git fails.
blend_test_git_try :: proc(repo: string, args: ..string) -> (out: string, ok: bool) {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "git", "-C", repo)
	append(&command, ..args)
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = command[:]}, context.temp_allocator)
	if err != nil || !state.success {
		return "", false
	}
	return strings.trim_space(string(stdout)), true
}

blend_test_git :: proc(t: ^testing.T, repo: string, args: ..string) -> string {
	out, ok := blend_test_git_try(repo, ..args)
	testing.expect(t, ok, fmt.tprintf("git %v failed", args))
	return out
}

// A repository on main with one base commit that holds shared.txt.
blend_test_repo :: proc(t: ^testing.T, repo: string) -> string {
	testing.expect_value(t, os.make_directory_all(repo), os.Error(nil))
	blend_test_git(t, repo, "init", "-q", "-b", "main")
	blend_test_git(t, repo, "config", "user.name", "test")
	blend_test_git(t, repo, "config", "user.email", "test@example.com")
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/shared.txt", repo), "base\n"), os.Error(nil))
	blend_test_git(t, repo, "add", "shared.txt")
	blend_test_git(t, repo, "commit", "-q", "-m", "base")
	return blend_test_git(t, repo, "rev-parse", "HEAD")
}

// Makes one commit that writes file on a new side branch from base, then returns to main.
blend_test_side_commit :: proc(t: ^testing.T, repo, base, side, file, content: string) -> string {
	blend_test_git(t, repo, "checkout", "-q", "-b", side, base)
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/%s", repo, file), content), os.Error(nil))
	blend_test_git(t, repo, "add", file)
	blend_test_git(t, repo, "commit", "-q", "-m", fmt.tprintf("change %s", file))
	hash := blend_test_git(t, repo, "rev-parse", "HEAD")
	blend_test_git(t, repo, "checkout", "-q", "main")
	return hash
}

// Writes the request lines, runs the host on them, and returns its stdout.
blend_test_host :: proc(t: ^testing.T, root, state, binary, input: string) -> string {
	input_path := fmt.tprintf("%s/requests.ndjson", root)
	testing.expect_value(t, os.write_entire_file(input_path, input), os.Error(nil))
	run, stdout, stderr, err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", BLEND_TEST_SCRIPT, "blend-test", input_path, state, binary},
	}, context.temp_allocator)
	testing.expect_value(t, err, os.Error(nil))
	testing.expect(t, run.success, string(stderr))
	return string(stdout)
}

@(test)
test_blend_combines_non_conflicting_pulls_into_one_commit :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(HOST_TEST_TEMP_DIR, "coffee-shop-blend-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	repo := fmt.tprintf("%s/beans", root)
	state := fmt.tprintf("%s/state", root)
	base := blend_test_repo(t, repo)
	one := blend_test_side_commit(t, repo, base, "side-one", "one.txt", "one\n")
	two := blend_test_side_commit(t, repo, base, "side-two", "two.txt", "two\n")
	binary := build_test_binary(t, root)
	defer delete(binary)

	input := fmt.tprintf(`{{"type":"blend","request_id":"blend-1","repo":"%s","base":"%s","commits":["%s","%s"],"branch":"blend-out","message":"Blend two Pulls"}}
{{"type":"shutdown","request_id":"done"}}
`, repo, base, one, two)
	stdout := blend_test_host(t, root, state, binary, input)

	short := blend_test_git(t, repo, "rev-parse", "--short", "blend-out")
	testing.expect(t, host_output_contains(stdout, fmt.tprintf(`{{"type":"blended","request_id":"blend-1","branch":"blend-out","commit":"%s"}}`, short)), stdout)
	testing.expect(t, !host_output_contains(stdout, `"type":"blend_failed"`), stdout)
	testing.expect_value(t, blend_test_git(t, repo, "ls-tree", "--name-only", "blend-out"), "one.txt\nshared.txt\ntwo.txt")
	testing.expect_value(t, blend_test_git(t, repo, "log", "-1", "--format=%s", "blend-out"), "Blend two Pulls")
	testing.expect_value(t, blend_test_git(t, repo, "rev-parse", "blend-out^"), base)
	testing.expect_value(t, blend_test_git(t, repo, "rev-parse", "main"), base)
	testing.expect(t, !os.exists(fmt.tprintf("%s/host/blend-1/blend", state)), "the temporary worktree must be removed")
	testing.expect(t, !strings.contains(blend_test_git(t, repo, "worktree", "list"), "host/blend-1/blend"), "the temporary worktree must be unregistered")
	history, history_err := os.read_entire_file(fmt.tprintf("%s/host/blend-1/history.ndjson", state), context.temp_allocator)
	testing.expect_value(t, history_err, os.Error(nil))
	testing.expect(t, strings.contains(string(history), `"type":"blended"`), string(history))
}

@(test)
test_blend_conflict_fails_closed_and_leaves_nothing :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(HOST_TEST_TEMP_DIR, "coffee-shop-blend-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	repo := fmt.tprintf("%s/beans", root)
	state := fmt.tprintf("%s/state", root)
	base := blend_test_repo(t, repo)
	one := blend_test_side_commit(t, repo, base, "side-one", "shared.txt", "one\n")
	clash := blend_test_side_commit(t, repo, base, "side-clash", "shared.txt", "clash\n")
	binary := build_test_binary(t, root)
	defer delete(binary)

	input := fmt.tprintf(`{{"type":"blend","request_id":"blend-2","repo":"%s","base":"%s","commits":["%s","%s"],"branch":"blend-clash","message":"Blend clash"}}
{{"type":"shutdown","request_id":"done"}}
`, repo, base, one, clash)
	stdout := blend_test_host(t, root, state, binary, input)

	testing.expect(t, host_output_contains(stdout, `{"type":"blend_failed","request_id":"blend-2"`), stdout)
	testing.expect(t, host_output_contains(stdout, fmt.tprintf(`"commit":"%s"`, clash)), stdout)
	testing.expect(t, !host_output_contains(stdout, `"type":"blended"`), stdout)
	testing.expect(t, !os.exists(fmt.tprintf("%s/host/blend-2/blend", state)), "the temporary worktree must be removed")
	testing.expect(t, !strings.contains(blend_test_git(t, repo, "worktree", "list"), "host/blend-2/blend"), "the temporary worktree must be unregistered")
	_, branch_ok := blend_test_git_try(repo, "rev-parse", "--verify", "--quiet", "refs/heads/blend-clash")
	testing.expect(t, !branch_ok, "the new branch must be deleted after a failed Blend")
	testing.expect_value(t, blend_test_git(t, repo, "rev-parse", "main"), base)
}

@(test)
test_blend_rejects_invalid_requests_before_any_git_change :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(HOST_TEST_TEMP_DIR, "coffee-shop-blend-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	repo := fmt.tprintf("%s/beans", root)
	state := fmt.tprintf("%s/state", root)
	base := blend_test_repo(t, repo)
	one := blend_test_side_commit(t, repo, base, "side-one", "one.txt", "one\n")
	two := blend_test_side_commit(t, repo, base, "side-two", "two.txt", "two\n")
	binary := build_test_binary(t, root)
	defer delete(binary)

	input := fmt.tprintf(`{{"type":"blend","request_id":"bad-branch","repo":"%s","base":"%s","commits":["%s","%s"],"branch":"bad branch","message":"m"}}
{{"type":"blend","request_id":"one-commit","repo":"%s","base":"%s","commits":["%s"],"branch":"one-out","message":"m"}}
{{"type":"blend","request_id":"newline","repo":"%s","base":"%s","commits":["%s","%s"],"branch":"newline-out","message":"line one\nline two"}}
{{"type":"blend","request_id":"taken","repo":"%s","base":"%s","commits":["%s","%s"],"branch":"side-one","message":"m"}}
{{"type":"shutdown","request_id":"done"}}
`, repo, base, one, two, repo, base, one, repo, base, one, two, repo, base, one, two)
	stdout := blend_test_host(t, root, state, binary, input)

	testing.expect(t, host_output_contains(stdout, `{"type":"error","request_id":"bad-branch","reason":"branch must be`), stdout)
	testing.expect(t, host_output_contains(stdout, `{"type":"error","request_id":"one-commit","reason":"commits must list 2 to 20 commit hashes"}`), stdout)
	testing.expect(t, host_output_contains(stdout, `{"type":"error","request_id":"newline","reason":"message must be`), stdout)
	testing.expect(t, host_output_contains(stdout, `{"type":"error","request_id":"taken","reason":"branch already exists"}`), stdout)
	testing.expect(t, !host_output_contains(stdout, `"type":"blended"`) && !host_output_contains(stdout, `"type":"blend_failed"`), stdout)
	ids := []string{"bad-branch", "one-commit", "newline", "taken"}
	for id in ids {
		testing.expect(t, !os.exists(fmt.tprintf("%s/host/%s/blend", state, id)), "a rejected Blend must create no worktree")
	}
	_, bad_ok := blend_test_git_try(repo, "rev-parse", "--verify", "--quiet", "refs/heads/bad branch")
	testing.expect(t, !bad_ok, "a rejected Blend must create no branch")
}
