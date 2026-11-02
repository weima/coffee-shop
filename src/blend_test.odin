package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Blend tests drive the `blend` seam with temporary Git repositories. No agent process
// runs and no host is needed: Blend only uses Git, and the seam is what the host drives.

// The seam stamps every event with `at`, which is the one field an assertion cannot know;
// this drops it, so a test compares the fields the event was about.
blend_output_contains :: proc(out, expected: string) -> bool {
	builder := strings.builder_make(context.temp_allocator)
	remaining := out
	for line in strings.split_lines_iterator(&remaining) {
		if cut := strings.index(line, `,"at":"`); cut >= 0 {
			strings.write_string(&builder, line[:cut])
			strings.write_string(&builder, "}")
		} else {
			strings.write_string(&builder, line)
		}
		strings.write_byte(&builder, '\n')
	}
	return strings.contains(strings.to_string(builder), expected)
}

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

// Writes the request, runs the seam on it, and returns its stdout. A rejected or failed
// Blend exits non-zero; the events on stdout say why.
blend_test_seam :: proc(t: ^testing.T, root, state, binary, request: string) -> string {
	request_path := fmt.tprintf("%s/request.json", root)
	testing.expect_value(t, os.write_entire_file(request_path, request), os.Error(nil))
	command := fmt.tprintf(`export CS_STATE_DIR="$2"; "$3" blend --request "$1"`, "", "")
	_ = command
	run, stdout, _, err := os.process_exec(os.Process_Desc{
		command = {"sh", "-c", `export CS_STATE_DIR="$2"; "$3" blend --request "$1"`, "blend-test", request_path, state, binary},
	}, context.temp_allocator)
	testing.expect_value(t, err, os.Error(nil))
	// A failed Blend exits 1; the event stream is the assertion, not the status.
	return string(stdout)
}

@(test)
test_blend_combines_non_conflicting_pulls_into_one_commit :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-blend-*", context.allocator)
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

	request := fmt.tprintf(`{{"type":"blend","request_id":"blend-1","repo":"%s","base":"%s","commits":["%s","%s"],"branch":"blend-out","message":"Blend two Pulls"}}`, repo, base, one, two)
	stdout := blend_test_seam(t, root, state, binary, request)

	short := blend_test_git(t, repo, "rev-parse", "--short", "blend-out")
	testing.expect(t, blend_output_contains(stdout, fmt.tprintf(`{{"type":"blended","request_id":"blend-1","branch":"blend-out","commit":"%s"}}`, short)), stdout)
	testing.expect(t, !blend_output_contains(stdout, `"type":"blend_failed"`), stdout)
	testing.expect_value(t, blend_test_git(t, repo, "ls-tree", "--name-only", "blend-out"), "one.txt\nshared.txt\ntwo.txt")
	testing.expect_value(t, blend_test_git(t, repo, "log", "-1", "--format=%s", "blend-out"), "Blend two Pulls")
	testing.expect_value(t, blend_test_git(t, repo, "rev-parse", "blend-out^"), base)
	testing.expect_value(t, blend_test_git(t, repo, "rev-parse", "main"), base)
	testing.expect(t, !os.exists(fmt.tprintf("%s/host/blend-1/blend", state)), "the temporary worktree must be removed")
	testing.expect(t, !strings.contains(blend_test_git(t, repo, "worktree", "list"), "host/blend-1/blend"), "the temporary worktree must be unregistered")
	// The seam prints events; the host is what records them, so history is asserted where
	// the host is (go/internal/host/blend_test.go).
}

@(test)
test_blend_conflict_fails_closed_and_leaves_nothing :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-blend-*", context.allocator)
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

	request := fmt.tprintf(`{{"type":"blend","request_id":"blend-2","repo":"%s","base":"%s","commits":["%s","%s"],"branch":"blend-clash","message":"Blend clash"}}`, repo, base, one, clash)
	stdout := blend_test_seam(t, root, state, binary, request)

	testing.expect(t, blend_output_contains(stdout, `{"type":"blend_failed","request_id":"blend-2"`), stdout)
	testing.expect(t, blend_output_contains(stdout, fmt.tprintf(`"commit":"%s"`, clash)), stdout)
	testing.expect(t, !blend_output_contains(stdout, `"type":"blended"`), stdout)
	testing.expect(t, !os.exists(fmt.tprintf("%s/host/blend-2/blend", state)), "the temporary worktree must be removed")
	testing.expect(t, !strings.contains(blend_test_git(t, repo, "worktree", "list"), "host/blend-2/blend"), "the temporary worktree must be unregistered")
	_, branch_ok := blend_test_git_try(repo, "rev-parse", "--verify", "--quiet", "refs/heads/blend-clash")
	testing.expect(t, !branch_ok, "the new branch must be deleted after a failed Blend")
	testing.expect_value(t, blend_test_git(t, repo, "rev-parse", "main"), base)
}

@(test)
test_blend_rejects_invalid_requests_before_any_git_change :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-blend-*", context.allocator)
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

	// Each rejected request is its own run: the seam takes one request per file, so a
	// rejection cannot hide behind a later one.
	cases := []struct{ id, request, reason: string }{
		{"bad-branch", fmt.tprintf(`{{"type":"blend","request_id":"bad-branch","repo":"%s","base":"%s","commits":["%s","%s"],"branch":"bad branch","message":"m"}}`, repo, base, one, two), "branch must be"},
		{"one-commit", fmt.tprintf(`{{"type":"blend","request_id":"one-commit","repo":"%s","base":"%s","commits":["%s"],"branch":"one-out","message":"m"}}`, repo, base, one), "commits must list 2 to 20 commit hashes"},
		{"newline", fmt.tprintf(`{{"type":"blend","request_id":"newline","repo":"%s","base":"%s","commits":["%s","%s"],"branch":"newline-out","message":"line one\nline two"}}`, repo, base, one, two), "message must be"},
		{"taken", fmt.tprintf(`{{"type":"blend","request_id":"taken","repo":"%s","base":"%s","commits":["%s","%s"],"branch":"side-one","message":"m"}}`, repo, base, one, two), "branch already exists"},
	}
	for case_ in cases {
		stdout := blend_test_seam(t, root, state, binary, case_.request)
		testing.expect(t, blend_output_contains(stdout, fmt.tprintf(`"type":"error","request_id":"%s"`, case_.id)), stdout)
		testing.expect(t, blend_output_contains(stdout, case_.reason), stdout)
		testing.expect(t, !blend_output_contains(stdout, `"type":"blended"`) && !blend_output_contains(stdout, `"type":"blend_failed"`), stdout)
		testing.expect(t, !os.exists(fmt.tprintf("%s/%s/blend", state, case_.id)), "a rejected Blend must create no worktree")
	}
	_, bad_ok := blend_test_git_try(repo, "rev-parse", "--verify", "--quiet", "refs/heads/bad branch")
	testing.expect(t, !bad_ok, "a rejected Blend must create no branch")
}
