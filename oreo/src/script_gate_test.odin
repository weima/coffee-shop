package oreo

import "core:strings"
import "core:testing"

@(test)
test_script_gate_allows_allowlisted_imports :: proc(t: ^testing.T) {
	ok, reason := script_gate(`
package script

import "core:fmt"
import "core:strings"

main :: proc() {
	fmt.println(strings.to_upper("ok"))
}
`)
	defer delete(reason)
	testing.expect(t, ok)
	testing.expect_value(t, reason, "")
}

@(test)
test_script_gate_allows_a_script_without_imports :: proc(t: ^testing.T) {
	ok, reason := script_gate(`
package script

value :: 1
`)
	defer delete(reason)
	testing.expect(t, ok)
	testing.expect_value(t, reason, "")
}

@(test)
test_script_gate_rejects_an_import_outside_the_allowlist :: proc(t: ^testing.T) {
	ok, reason := script_gate(`
package script

import "core:mem"

value :: 1
`)
	defer delete(reason)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(reason, "core:mem"))
}

@(test)
test_script_gate_rejects_a_foreign_block :: proc(t: ^testing.T) {
	ok, reason := script_gate(`
package script

foreign libc {
}
`)
	defer delete(reason)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(reason, "foreign"))
}

@(test)
test_script_gate_rejects_a_foreign_import :: proc(t: ^testing.T) {
	ok, reason := script_gate(`
package script

foreign import libc "system:libc"
`)
	defer delete(reason)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(reason, "foreign"))
}

@(test)
test_script_gate_rejects_load :: proc(t: ^testing.T) {
	ok, reason := script_gate(`
package script

data :: #load("payload.txt")
`)
	defer delete(reason)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(reason, "#load"))
}

@(test)
test_script_gate_reports_a_syntax_error :: proc(t: ^testing.T) {
	ok, reason := script_gate(`
package script

main :: proc() {
`)
	defer delete(reason)
	testing.expect(t, !ok)
	testing.expect(t, len(reason) > 0)
}

@(test)
test_script_gate_ignores_forbidden_text_in_comments_and_strings :: proc(t: ^testing.T) {
	ok, reason := script_gate(`
package script

import "core:fmt"

// foreign import "core:mem" and #load must not be rejected in a comment.

note :: "foreign, #load, and core:mem are words here, not declarations"

main :: proc() {
	fmt.println(note)
}
`)
	defer delete(reason)
	testing.expect(t, ok)
	testing.expect_value(t, reason, "")
}
