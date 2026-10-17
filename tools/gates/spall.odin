package main

import "core:encoding/endian"
import "core:os"
import "core:slice"
import "core:strings"

SPALL_MAGIC :: 0x0BADF00D

Span :: struct {
	ns:    f64,
	count: int,
}

Open_Span :: struct {
	name: string,
	ts:   u64,
}

u32_at :: proc(d: []byte, p: int) -> (v: u32, ok: bool) {
	if p + 4 > len(d) {return}
	return endian.get_u32(d[p:], .Little)
}

u64_at :: proc(d: []byte, p: int) -> (v: u64, ok: bool) {
	if p + 8 > len(d) {return}
	return endian.get_u64(d[p:], .Little)
}

// parse_spall returns inclusive time per span name for one Spall manual-format file.
parse_spall :: proc(path: string) -> (out: map[string]Span, err: string) {
	d, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return nil, tprint("%v", rerr)
	}
	magic, _ := u64_at(d, 0)
	if len(d) < 32 || magic != SPALL_MAGIC {
		return nil, "not a Spall manual-format file"
	}
	scale, _ := endian.get_f64(d[16:], .Little) // ns per tick
	out = make(map[string]Span)
	pos := 32
	for pos + 20 <= len(d) {
		size, _ := u32_at(d, pos)
		pos += 20
		end := min(pos + int(size), len(d))
		if e := parse_chunk(d, &pos, end, scale, &out); e != "" {
			return nil, e
		}
	}
	return out, ""
}

parse_chunk :: proc(d: []byte, pos: ^int, end: int, scale: f64, out: ^map[string]Span) -> string {
	stack: [dynamic]Open_Span
	for pos^ < end {
		switch d[pos^] {
		case 3:
			if pos^ + 11 > len(d) {return "truncated begin event"}
			ts, _ := u64_at(d, pos^ + 1)
			nl, al := int(d[pos^ + 9]), int(d[pos^ + 10])
			if pos^ + 11 + nl + al > len(d) {return "truncated begin event"}
			name := string(d[pos^ + 11:pos^ + 11 + nl])
			append(&stack, Open_Span{strings.clone(name), ts})
			pos^ += 11 + nl + al
		case 4:
			ts, ok := u64_at(d, pos^ + 1)
			if !ok {return "truncated end event"}
			if len(stack) > 0 {
				top := pop(&stack)
				s := out[top.name]
				s.ns += f64(i64(ts) - i64(top.ts)) * scale
				s.count += 1
				out[top.name] = s
			}
			pos^ += 9
		case 7:
			n, ok := u32_at(d, pos^ + 1)
			if !ok {return "truncated pad event"}
			pos^ += 5 + int(n)
		case:
			return tprint("unknown event type %d at %d", d[pos^], pos^)
		}
	}
	return ""
}

Ranked :: struct {
	name: string,
	span: Span,
}

rank_spans :: proc(m: map[string]Span) -> []Ranked {
	rows := make([dynamic]Ranked)
	for k, v in m {
		append(&rows, Ranked{k, v})
	}
	slice.sort_by(rows[:], proc(a, b: Ranked) -> bool {
		if a.span.ns != b.span.ns {return a.span.ns > b.span.ns}
		return a.name < b.name
	})
	return rows[:]
}
