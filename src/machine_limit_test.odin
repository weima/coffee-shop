package main

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
limit_test_root :: proc(t: ^testing.T, name: string) -> string {
	root := fmt.aprintf("%s/cs-ml-%s-%d", os.get_env("TMPDIR", context.temp_allocator), name, os.get_pid())
	_ = os.remove_all(root)
	testing.expect(t, os.make_directory_all(root, os.Permissions{.Read_User, .Write_User, .Execute_User}) == nil)
	return root
}

@(test)
machine_limit_third_acquirer_waits_until_release :: proc(t: ^testing.T) {
	root := limit_test_root(t, "third")
	defer delete(root)
	defer os.remove_all(root)

	a, _, a_ok := machine_limit_try_acquire(root, 2)
	b, _, b_ok := machine_limit_try_acquire(root, 2)
	testing.expect(t, a_ok && b_ok)
	testing.expect(t, a.index != b.index)

	_, reason, third_ok := machine_limit_acquire(root, 2, 250 * time.Millisecond)
	testing.expect(t, !third_ok)
	testing.expect(t, reason != "", "a refused acquirer must say why")
	delete(reason)

	machine_limit_release(&a)
	c, reason2, c_ok := machine_limit_acquire(root, 2, 250 * time.Millisecond)
	testing.expect(t, c_ok, "a released slot must admit the third acquirer")
	delete(reason2)
	machine_limit_release(&b)
	machine_limit_release(&c)
}

@(test)
machine_limit_dead_holder_frees_slot :: proc(t: ^testing.T) {
	root := limit_test_root(t, "dead")
	defer delete(root)
	defer os.remove_all(root)

	pid := posix.fork()
	if pid == 0 {
		_, _, held := machine_limit_try_acquire(root, 1)
		posix._exit(held ? 0 : 1) // exits without releasing
	}
	testing.expect(t, pid > 0)
	status: i32
	_ = posix.waitpid(pid, &status, {})
	testing.expect(t, posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0, "child must take the only slot")

	slot, reason, ok := machine_limit_acquire(root, 1, 250 * time.Millisecond)
	testing.expect(t, ok, "a dead holder must not keep its slot")
	delete(reason)
	machine_limit_release(&slot)
}
