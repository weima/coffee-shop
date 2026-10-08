package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_shared_paths_must_exist_and_be_gitignored :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	repo := make_share_repo(t, root)

	testing.expect_value(t, validate_shared_paths(repo, []string{"node_modules", "packages/web/node_modules"}), "")
	testing.expect_value(t, validate_shared_paths(repo, []string{"vendor/bundle"}), `shared path "vendor/bundle" does not exist in the Beans repository`)
	// Tracked files are not ignored: sharing them would overwrite the Station's own copy.
	testing.expect_value(t, validate_shared_paths(repo, []string{"src"}), `shared path "src" must be gitignored so it never appears in a Station's changes`)
}

@(test)
test_brew_links_shared_paths_into_every_station_without_showing_changes :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	repo := make_share_repo(t, root)
	state_root := fmt.tprintf("%s/state", root)
	recipe_path := write_share_recipe(root, `["node_modules","packages/web/node_modules"]`)

	brew_id, err := run_brew_with(repo, recipe_path, state_root, "/nonexistent", "/nonexistent/herdr")
	defer delete(brew_id)
	testing.expect_value(t, err, "")

	brew_dir := fmt.tprintf("%s/%s", state_root, brew_id)
	register, state_err := read_state(brew_dir)
	defer destroy_register(&register)
	testing.expect_value(t, state_err.kind, State_Error_Kind.None)
	testing.expect_value(t, len(register.share), 2)
	for shot in register.shots {
		for path in register.share {
			link, link_err := os.read_link(fmt.tprintf("%s/%s", shot.station_path, path), context.allocator)
			testing.expect_value(t, link_err, os.Error(nil))
			testing.expect_value(t, link, fmt.tprintf("%s/%s", repo, path))
			delete(link)
		}
		testing.expect(t, os.exists(fmt.tprintf("%s/node_modules/pkg/index.js", shot.station_path)), "the shared content is readable through the link")
		changes := station_changes(shot.station_path)
		testing.expect_value(t, changes, "(none)")
		delete(changes)
	}
}

@(test)
test_brew_with_an_invalid_share_fails_before_creating_anything :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	repo := make_share_repo(t, root)
	state_root := fmt.tprintf("%s/state", root)
	recipe_path := write_share_recipe(root, `["src"]`)

	brew_id, err := run_brew_with(repo, recipe_path, state_root, "/nonexistent", "/nonexistent/herdr")
	testing.expect_value(t, brew_id, "")
	testing.expect_value(t, err, `shared path "src" must be gitignored so it never appears in a Station's changes`)
	testing.expect(t, !os.exists(state_root), "no Brew state may be created")
}

@(test)
test_filter_suggests_sharing_a_dependency_directory_the_station_lacks :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	repo := make_share_repo(t, root)
	station := fmt.tprintf("%s/station", root)
	make_fixture_repo(t, station)

	register := make_test_register(t)
	defer destroy_register(&register)
	delete(register.beans_path)
	register.beans_path = strings.clone(repo)
	shot := Register_Shot{id = "shot-a", station_path = station}

	evidence := run_filter(register, shot, "/nonexistent/pi")
	defer destroy_filter_evidence(&evidence)
	found := false
	for note in evidence.notes {
		if strings.contains(note, `Beans has "node_modules"`) && strings.contains(note, `"share"`) {
			found = true
		}
	}
	testing.expect(t, found, "a missing node_modules should produce a share suggestion")

	// Once it is shared, the suggestion goes away.
	append(&register.share, strings.clone("node_modules"))
	shared := run_filter(register, shot, "/nonexistent/pi")
	defer destroy_filter_evidence(&shared)
	for note in shared.notes {
		testing.expect(t, !strings.contains(note, `Beans has "node_modules"`), note)
	}
}

// A Beans repository whose node_modules directories are gitignored and whose src is tracked.
make_share_repo :: proc(t: ^testing.T, root: string) -> string {
	repo := fmt.tprintf("%s/repo", root)
	make_fixture_repo(t, repo)
	rw := os.Permissions{.Read_User, .Write_User}
	_ = os.make_directory_all(fmt.tprintf("%s/src", repo))
	_ = os.make_directory_all(fmt.tprintf("%s/node_modules/pkg", repo))
	_ = os.make_directory_all(fmt.tprintf("%s/packages/web/node_modules/x", repo))
	_ = os.write_entire_file(fmt.tprintf("%s/.gitignore", repo), "node_modules/\n", rw)
	_ = os.write_entire_file(fmt.tprintf("%s/src/a.txt", repo), "a\n", rw)
	_ = os.write_entire_file(fmt.tprintf("%s/node_modules/pkg/index.js", repo), "x\n", rw)
	_ = os.write_entire_file(fmt.tprintf("%s/packages/web/node_modules/x/y.js", repo), "y\n", rw)
	for args in ([][]string{{"git", "-C", repo, "add", "."}, {"git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "base"}}) {
		_, out, errout, _ := os.process_exec(os.Process_Desc{command = args}, context.allocator)
		delete(out)
		delete(errout)
	}
	return repo
}

write_share_recipe :: proc(root, share_json: string) -> string {
	path := fmt.tprintf("%s/recipe.json", root)
	data, _ := strings.concatenate({`{"order":"o","share":`, share_json, `,"shots":[{"id":"a","prompt":"pa"},{"id":"b","prompt":"pb"}]}`}, context.temp_allocator)
	_ = os.write_entire_file(path, data, os.Permissions{.Read_User, .Write_User})
	return path
}

@(test)
test_share_excludes_are_anchored_and_not_duplicated_across_brews :: proc(t: ^testing.T) {
	root := make_fixture_root(t)
	defer remove_fixture_root(root)
	repo := make_share_repo(t, root)
	state_root := fmt.tprintf("%s/state", root)
	recipe_path := write_share_recipe(root, `["node_modules"]`)

	for _ in 0 ..< 2 {
		brew_id, err := run_brew_with(repo, recipe_path, state_root, "/nonexistent", "/nonexistent/herdr")
		testing.expect_value(t, err, "")
		delete(brew_id)
	}
	data, _ := os.read_entire_file(fmt.tprintf("%s/.git/info/exclude", repo), context.allocator)
	defer delete(data)
	// "/node_modules" with no trailing slash also matches a symlink to the directory.
	testing.expect_value(t, strings.count(string(data), "\n/node_modules\n"), 1)
}
