package main

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

HOST_PROTOCOL :: 1
HOST_REQUEST_ID_MAX :: 128

// Foreground host: reads one JSON request per line from stdin and answers on
// stdout. It exits on shutdown or end of input; it never daemonizes.
// shortcut: dispatches are acknowledged but not validated or run yet; Recipe
// validation and Herdr dispatch come in phase C.
run_host :: proc() -> int {
	fmt.printfln(`{{"type":"ready","protocol":%d}}`, HOST_PROTOCOL)

	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, os.to_reader(os.stdin))
	defer bufio.scanner_destroy(&scanner)
	for bufio.scanner_scan(&scanner) {
		if host_handle_line(bufio.scanner_text(&scanner)) {
			break
		}
	}
	return 0
}

// Returns true when the host must stop.
host_handle_line :: proc(line: string) -> bool {
	value, parse_err := json.parse_string(line, .JSON, false, context.temp_allocator)
	if parse_err != .None {
		fmt.println(`{"type":"error","reason":"invalid json"}`)
		return false
	}
	defer json.destroy_value(value, context.temp_allocator)

	root, is_object := value.(json.Object)
	if !is_object {
		fmt.println(`{"type":"error","reason":"request must be an object"}`)
		return false
	}

	request_id := host_request_id(root)
	if request_id == "" {
		fmt.println(`{"type":"error","reason":"request_id must be 1-128 characters of [A-Za-z0-9._-]"}`)
		return false
	}

	type_name, _ := root["type"].(json.String)
	switch type_name {
	case "dispatch":
		fmt.printfln(`{{"type":"dispatch_accepted","request_id":"%s"}}`, request_id)
	case "shutdown":
		fmt.printfln(`{{"type":"stopped","request_id":"%s"}}`, request_id)
		return true
	case:
		fmt.printfln(`{{"type":"error","request_id":"%s","reason":"unknown request type"}}`, request_id)
	}
	return false
}

// The ID is echoed into JSON unescaped, so only a restricted character set is accepted.
host_request_id :: proc(root: json.Object) -> string {
	value, found := root["request_id"]
	if !found {
		return ""
	}
	id, is_string := value.(json.String)
	if !is_string || len(id) == 0 || len(id) > HOST_REQUEST_ID_MAX {
		return ""
	}
	for c in id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			return ""
		}
	}
	return id
}
