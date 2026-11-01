package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"

Test_Span :: struct {
	name:       string,
	start, end: u64,
}

put_u64 :: proc(b: ^[dynamic]byte, v: u64) {
	buf: [8]byte
	endian.put_u64(buf[:], .Little, v)
	append(b, ..buf[:])
}

put_u32 :: proc(b: ^[dynamic]byte, v: u32) {
	buf: [4]byte
	endian.put_u32(buf[:], .Little, v)
	append(b, ..buf[:])
}

// fx_trace writes a Spall manual-format file holding the given finished spans.
fx_trace :: proc(path: string, spans: []Test_Span) {
	ev: [dynamic]byte
	for s in spans {
		append(&ev, 3)
		put_u64(&ev, s.start)
		append(&ev, u8(len(s.name)), 0)
		append(&ev, s.name)
		append(&ev, 4)
		put_u64(&ev, s.end)
	}
	append(&ev, 7)
	put_u32(&ev, 3) // a Pad_Skip, as the real writer may emit
	append(&ev, 0, 0, 0)
	f: [dynamic]byte
	put_u64(&f, SPALL_MAGIC)
	put_u64(&f, 1)
	put_u64(&f, 0x3FF0000000000000) // 1.0 ns per tick
	put_u64(&f, 0)
	put_u32(&f, u32(len(ev)))
	put_u32(&f, 1)
	put_u32(&f, 1)
	put_u64(&f, 0)
	append(&f, ..ev[:])
	_ = os.write_entire_file(path, f[:])
}

Checker :: struct {
	ok: bool,
}

check :: proc(c: ^Checker, cond: bool, msg: string) {
	c.ok &&= cond
	fmt.printfln("%s%s", "ok   " if cond else "FAIL ", msg)
}

join :: proc(dir, name: string) -> string {
	return strings.concatenate({dir, "/", name})
}

write_text :: proc(path, text: string) {
	_ = os.write_entire_file(path, text)
}

fx_events :: proc(path: string, ids: []string, waits: bool) {
	b := strings.builder_make()
	line(&b, `{{"type":"dispatch_accepted"}}`)
	for id in ids[:5] {
		line(&b, `{{"type":"session_started","shot_id":"%s","at":"2026-10-31T19:20:00.000Z"}}`, id)
		line(&b, `{{"type":"station_report","shot_id":"%s","kind":"taste_passed","at":"2026-10-31T19:21:30.125Z"}}`, id)
	}
	if waits {
		line(&b, `{{"type":"dispatch_queued","shot_id":"%s"}}`, ids[5])
		line(&b, `{{"type":"dispatch_dequeued","shot_id":"%s"}}`, ids[5])
	}
	line(&b, `{{"type":"session_started","shot_id":"%s","at":"2026-10-31T19:20:00.000Z"}}`, ids[5])
	line(&b, `{{"type":"station_report","shot_id":"%s","kind":"taste_passed","at":"2026-10-31T19:21:30.125Z"}}`, ids[5])
	write_text(path, strings.to_string(b))
}

fx_state :: proc(t: string, ids: []string) {
	_ = os.make_directory_all(join(t, "state/workers"))
	_ = os.make_directory_all(join(t, "state/machine-limit"))
	peak := `{"cpu_ms":{"known":true,"value":1500},"rss":{"known":true,"value":104857600},"fds":{"known":true,"value":12},"children":{"known":true,"value":2}}`
	tree := `{"cpu_ms":{"known":false,"value":0},"rss":{"known":true,"value":104857600},"fds":{"known":true,"value":12},"children":{"known":true,"value":2}}`
	for id in ids[:4] { // the fifth has no record, so it must say "not measured"
		rec := tprint(`{{"station_peak":%s,"tree_peak":%s,"samples":3}}`, peak, tree)
		write_text(join(t, tprint("state/workers/%s.resource", id)), rec)
	}
	fx_trace(join(t, "tr.host"), {{"a", 0, 5_000_000}, {"b", 0, 2_000_000}})
	fx_trace(join(t, "tr.st1"), {{"a", 0, 1_000_000}, {"c", 0, 9_000_000}})
	write_text(join(t, "tr.bad"), "junk")
}

selftest_waits :: proc(c: ^Checker, waits: bool) {
	t, _ := os.make_directory_temp("", "gates-", context.allocator)
	defer os.remove_all(t)
	req := join(t, "req.jsonl")
	if e := write_request({repo = t, out = req, request_id = "dry", prompt = "x", shots = 6}); e != "" {
		check(c, false, e)
		return
	}
	ids, _ := request_ids(req)
	fx_events(join(t, "ev.jsonl"), ids[:], waits)
	fx_state(t, ids[:])
	out := join(t, "r.md")
	if e := write_report({req, join(t, "ev.jsonl"), join(t, "state"), join(t, "tr"), out, 3}); e != "" {
		check(c, false, e)
		return
	}
	data, _ := os.read_entire_file(out, context.allocator)
	md := string(data)
	has := proc(md, s: string) -> bool {return strings.contains(md, s)}
	check(c, has(md, "PASS: `gate-s6` queued") == waits && has(md, "FAIL: `gate-s6` started without") == !waits,
		tprint("waits=%v: sixth-Shot verdict", waits))
	check(c, has(md, "| 1 | c | 9.000 | 1 | 9.000 |") && has(md, "| 2 | a | 6.000 | 2 | 3.000 |"), "trace totals summed across files, ranked")
	check(c, has(md, "tr.bad: not a Spall"), "unreadable trace named, not hidden")
	check(c, has(md, "gate-s1: 90.125 s"), "per-Shot elapsed time derived from RFC 3339 event timestamps")
	check(c, has(md, "| gate-s5 | - | not measured: no .resource file"), "missing record -> not measured")
	check(c, has(md, "| gate-s1 | station_peak | 1500 | 100.0 | 12 | 2 |") && has(md, "| gate-s1 | tree_peak | not measured |"), "known and unknown metrics kept apart")
	check(c, has(md, "Sum of every known rss peak above (Station + tree, peaks not simultaneous): 800.0 MiB"), "rss sum of known peaks")
}

selftest_empty :: proc(c: ^Checker) {
	t, _ := os.make_directory_temp("", "gates-", context.allocator)
	defer os.remove_all(t)
	req := join(t, "req.jsonl")
	write_text(req, `{"recipe":{"shots":[{"id":"x"}]}}` + "\n")
	if e := write_report({req, join(t, "none"), t, join(t, "none"), join(t, "r.md"), 3}); e != "" {
		check(c, false, e)
		return
	}
	data, _ := os.read_entire_file(join(t, "r.md"), context.allocator)
	md := string(data)
	check(c, strings.count(md, NM) >= 4 && strings.contains(md, "record_resource_use"), "everything absent -> not measured with reasons")
}

selftest :: proc() -> bool {
	c := Checker{true}
	selftest_waits(&c, true)
	selftest_waits(&c, false)
	selftest_empty(&c)
	return c.ok
}
