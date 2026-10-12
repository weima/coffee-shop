package oreo

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"

// SCRIPT_IMPORT_ALLOWLIST is the complete set of packages a code-mode script
// may import. "oreo:script" is the typed tool-calling surface.
SCRIPT_IMPORT_ALLOWLIST :: []string{
	"core:fmt",
	"core:os",
	"core:strings",
	"core:strconv",
	"core:slice",
	"core:sort",
	"core:encoding/json",
	"core:math",
	"oreo:script",
}

@(private)
SCRIPT_GATE_SOURCE_NAME :: "<oreo-script>"

// What the AST walk found. It is read back through context.user_ptr because
// Odin procedures have no closures.
@(private)
Script_Gate_Findings :: struct {
	foreign_decl: bool,
	load:         bool,
}

// script_gate parses source as an Odin file and rejects imports outside
// SCRIPT_IMPORT_ALLOWLIST, foreign declarations, and #load. The check runs on
// the parsed program, so comments and string literals cannot trip it. The
// caller owns reason; it is empty when ok is true.
script_gate :: proc(source: string, allocator := context.allocator) -> (ok: bool, reason: string) {
	// The parser allocates AST nodes on context.allocator, so parse into one
	// arena and release the whole tree at once.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&arena)

	diagnostics: strings.Builder
	strings.builder_init(&diagnostics, allocator)
	defer strings.builder_destroy(&diagnostics)

	state := parser.default_parser()
	state.err = script_gate_diagnostic
	state.warn = nil

	saved_context := context
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.user_ptr = &diagnostics

	file := ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
	file.src = source
	file.fullpath = SCRIPT_GATE_SOURCE_NAME
	parsed := parser.parse_file(&state, file)

	context = saved_context

	// parse_file can return true after a later syntax error, so the error count
	// and the collected diagnostics are checked as well.
	if !parsed || file.syntax_error_count > 0 || strings.builder_len(diagnostics) > 0 {
		return false, script_gate_parse_reason(&diagnostics, allocator)
	}

	for decl in file.imports {
		path := script_gate_import_path(decl.relpath.text)
		if !script_import_allowed(path) {
			return false, fmt.aprintf(
				"script import %q is not allowed; allowed imports are %v",
				path,
				SCRIPT_IMPORT_ALLOWLIST,
				allocator = allocator,
			)
		}
	}

	findings: Script_Gate_Findings
	context.user_ptr = &findings
	ast.inspect(&file.node, script_gate_visit)
	context = saved_context

	if findings.foreign_decl {
		return false, strings.clone("script contains a foreign declaration, which is not allowed", allocator)
	}
	if findings.load {
		return false, strings.clone("script contains a #load directive, which is not allowed", allocator)
	}
	return true, ""
}

// script_import_allowed reports whether path is one of SCRIPT_IMPORT_ALLOWLIST.
@(private)
script_import_allowed :: proc(path: string) -> bool {
	for allowed in SCRIPT_IMPORT_ALLOWLIST {
		if path == allowed {
			return true
		}
	}
	return false
}

// The parser stores an import's path as the raw string token, quotes included.
@(private)
script_gate_import_path :: proc(literal: string) -> string {
	if len(literal) >= 2 {
		first, last := literal[0], literal[len(literal) - 1]
		if (first == '"' && last == '"') || (first == '`' && last == '`') {
			return literal[1:len(literal) - 1]
		}
	}
	return literal
}

// script_gate_parse_reason turns the collected parser messages into a caller
// owned diagnostic.
@(private)
script_gate_parse_reason :: proc(diagnostics: ^strings.Builder, allocator: runtime.Allocator) -> string {
	message := strings.trim_space(strings.to_string(diagnostics^))
	if message == "" {
		message = "script is not a valid Odin file"
	}
	return strings.clone(message, allocator)
}

// script_gate_diagnostic appends one parser message to the builder held in
// context.user_ptr.
@(private)
script_gate_diagnostic :: proc(pos: tokenizer.Pos, format: string, args: ..any) {
	diagnostics := cast(^strings.Builder)context.user_ptr
	if diagnostics == nil {
		return
	}
	if strings.builder_len(diagnostics^) > 0 {
		strings.write_string(diagnostics, "; ")
	}
	fmt.sbprintf(diagnostics, "%s(%d:%d): ", pos.file, pos.line, pos.column)
	fmt.sbprintf(diagnostics, format, ..args)
}

// script_gate_visit rejects foreign declarations and #load from the AST. A
// forbidden word in a comment or string is not a node of these kinds.
@(private)
script_gate_visit :: proc(node: ^ast.Node) -> bool {
	if node == nil {
		return true
	}
	findings := cast(^Script_Gate_Findings)context.user_ptr
	if findings == nil {
		return true
	}
	#partial switch n in node.derived {
	case ^ast.Foreign_Block_Decl:
		findings.foreign_decl = true
	case ^ast.Foreign_Import_Decl:
		findings.foreign_decl = true
	case ^ast.Basic_Directive:
		// #load, #load_directory, and #load_hash all read files while compiling.
		if strings.has_prefix(n.name, "load") {
			findings.load = true
		}
	}
	return true
}
