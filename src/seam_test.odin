package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

seam_test_repo :: proc(t: ^testing.T, root: string) -> string {
	repo, _ := filepath.join({root, "beans"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(repo), os.Error(nil))
	init_out, init_ok := exec_reaped({"sh", "-c", `git init -q "$1" && git -C "$1" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init`, "seam-test", repo})
	defer delete(init_out)
	testing.expect(t, init_ok, string(init_out))
	return repo
}

seam_branch_exists :: proc(repo, branch: string) -> bool {
	out, ok := exec_reaped({"git", "-C", repo, "rev-parse", "--verify", "--quiet", strings.concatenate({"refs/heads/", branch}, context.temp_allocator)})
	defer delete(out)
	return ok
}

@(test)
test_prepare_then_release_a_worktree :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-seam-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	repo := seam_test_repo(t, root)
	dir, _ := filepath.join({root, "stations", "shot-a"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(fmt_dir(dir)), os.Error(nil))

	testing.expect_value(t, prepare_worktree(repo, "cs-host-req-1-shot-a", dir), "")
	testing.expect(t, os.exists(dir), "the worktree directory exists")
	testing.expect(t, seam_branch_exists(repo, "cs-host-req-1-shot-a"), "the branch exists")

	// Releasing removes the worktree and succeeds again on a second call.
	testing.expect_value(t, release_worktree(repo, dir), "")
	testing.expect(t, !os.exists(dir), "the worktree directory is gone")
	testing.expect_value(t, release_worktree(repo, dir), "")
}

@(test)
test_prepare_rejects_bad_input_without_touching_the_repository :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-seam-bad-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	repo := seam_test_repo(t, root)
	dir, _ := filepath.join({root, "stations", "shot-b"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(fmt_dir(dir)), os.Error(nil))

	cases := []struct{ repo, branch, dir, want: string }{
		{"relative/repo", "cs-host-a", dir, "repo must be an absolute path"},
		{repo, "cs-host-a", "relative/dir", "dir must be an absolute path"},
		{repo, "bad branch", dir, "branch must be 1 to 64 characters using letters, digits, - or _"},
		{repo, "-leading-dash", dir, "branch must be 1 to 64 characters using letters, digits, - or _"},
		{repo, strings.repeat("a", 65, context.temp_allocator), dir, "branch must be 1 to 64 characters using letters, digits, - or _"},
	}
	for c in cases {
		testing.expect_value(t, prepare_worktree(c.repo, c.branch, c.dir), c.want)
	}
	testing.expect(t, !seam_branch_exists(repo, "cs-host-a"), "a rejected prepare creates no branch")
}

@(test)
test_prepare_refuses_an_existing_directory :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-seam-exists-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	repo := seam_test_repo(t, root)
	dir, _ := filepath.join({root, "stations", "shot-c"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(dir), os.Error(nil))

	testing.expect_value(t, prepare_worktree(repo, "cs-host-req-2-shot-c", dir), "dir already exists")
	testing.expect(t, !seam_branch_exists(repo, "cs-host-req-2-shot-c"), "nothing was created")
}

@(test)
test_prepare_rejects_a_non_repository :: proc(t: ^testing.T) {
	root, make_err := os.make_directory_temp(TEMP_DIR, "coffee-shop-seam-norepo-*", context.allocator)
	testing.expect_value(t, make_err, os.Error(nil))
	if make_err != nil {
		return
	}
	defer os.remove_all(root)
	defer delete(root)

	plain, _ := filepath.join({root, "plain"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(plain), os.Error(nil))
	dir, _ := filepath.join({root, "stations", "shot-d"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(fmt_dir(dir)), os.Error(nil))

	testing.expect_value(t, prepare_worktree(plain, "cs-host-a", dir), "repo is not a Git repository")
}

// fmt_dir returns the parent directory of path, so a worktree can be created below it.
fmt_dir :: proc(path: string) -> string {
	cut := strings.last_index_byte(path, '/')
	if cut <= 0 {
		return path
	}
	return path[:cut]
}

@(test)
test_parse_prepare_and_release_arguments :: proc(t: ^testing.T) {
	parsed, err := parse_args([]string{"prepare", "--repo", "/tmp/beans", "--branch", "cs-host-a", "--dir", "/tmp/wt"})
	testing.expect_value(t, err, "")
	testing.expect_value(t, parsed.kind, Command_Kind.Prepare)
	testing.expect_value(t, parsed.repo, "/tmp/beans")
	testing.expect_value(t, parsed.branch, "cs-host-a")
	testing.expect_value(t, parsed.worktree_dir, "/tmp/wt")

	released, release_err := parse_args([]string{"release", "--repo", "/tmp/beans", "--dir", "/tmp/wt"})
	testing.expect_value(t, release_err, "")
	testing.expect_value(t, released.kind, Command_Kind.Release)
	testing.expect_value(t, released.repo, "/tmp/beans")
	testing.expect_value(t, released.worktree_dir, "/tmp/wt")

	_, missing_dir := parse_args([]string{"prepare", "--repo", "/tmp/beans", "--branch", "b"})
	testing.expect(t, missing_dir != "", "prepare needs --dir")
	_, missing_repo := parse_args([]string{"release", "--dir", "/tmp/wt"})
	testing.expect(t, missing_repo != "", "release needs --repo")
}
