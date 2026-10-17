package main

import "core:encoding/json"
import "core:os"

// parse_file reads and parses a JSON file; the caller's allocator owns the result.
parse_file :: proc(path: string) -> (v: json.Value, err: string) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return nil, tprint("cannot read `%s`: %v", path, rerr)
	}
	return parse_text(string(data), path)
}

parse_text :: proc(text, what: string) -> (v: json.Value, err: string) {
	val, perr := json.parse(transmute([]byte)text, json.DEFAULT_SPECIFICATION, true)
	if perr != nil {
		return nil, tprint("cannot parse `%s`: %v", what, perr)
	}
	return val, ""
}

get :: proc(v: json.Value, key: string) -> json.Value {
	if o, ok := v.(json.Object); ok {
		return o[key]
	}
	return nil
}

get_str :: proc(v: json.Value, key: string) -> string {
	s, _ := get(v, key).(json.String)
	return s
}

// Metric mirrors the host's {known, value} record. ok is false unless known is true.
Metric :: struct {
	value:  f64,
	is_int: bool,
	ok:     bool,
}

metric_of :: proc(v: json.Value) -> (m: Metric) {
	known, _ := get(v, "known").(json.Boolean)
	if !known {
		return
	}
	switch n in get(v, "value") {
	case json.Integer:
		m = {f64(n), true, true}
	case json.Float:
		m = {n, false, true}
	case json.Null, json.Boolean, json.String, json.Array, json.Object:
	}
	return
}
