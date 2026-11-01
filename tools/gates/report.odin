package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

NM :: "not measured"

ReportArgs :: struct {
	request, events, state_dir, trace, out: string,
	top: int,
}

line :: proc(b: ^strings.Builder, f: string, args: ..any) {
	fmt.sbprintfln(b, f, ..args)
}

// list_dir returns the names of regular files in dir whose name starts with prefix, sorted.
list_dir :: proc(dir, prefix: string) -> []string {
	infos, err := os.read_directory_by_path(dir, 0, context.allocator)
	names := make([dynamic]string)
	if err != nil {
		return names[:]
	}
	for fi in infos {
		if fi.type != .Directory && strings.has_prefix(fi.name, prefix) {
			append(&names, fi.name)
		}
	}
	slice.sort(names[:])
	return names[:]
}

// ---- 5.8 trace ---------------------------------------------------------------
trace_section :: proc(b: ^strings.Builder, trace: string, top: int) {
	cut := strings.last_index_byte(trace, '/')
	dir, prefix := ".", trace
	if cut >= 0 {
		dir, prefix = trace[:max(cut, 1)], trace[cut + 1:]
	}
	files := list_dir(dir, prefix) if trace != "" else nil
	if len(files) == 0 {
		line(b, "%s: no trace files match `%s*` (was CS_SPALL_FILE set for the host?)", NM, trace)
		return
	}
	total := make(map[string]Span)
	bad := make([dynamic]string)
	for f in files {
		spans, err := parse_spall(strings.concatenate({dir, "/", f}))
		if err != "" {
			append(&bad, tprint("%s: %s", f, err))
			continue
		}
		for n, s in spans {
			t := total[n]
			t.ns += s.ns
			t.count += s.count
			total[n] = t
		}
	}
	delete_key(&total, "Spall Trace Buffer Flush") // the tracer's own flush, not Coffee Shop work
	trace_table(b, files, rank_spans(total), top)
	for x in bad {
		line(b, "unreadable: %s", x)
	}
}

trace_table :: proc(b: ^strings.Builder, files: []string, rows: []Ranked, top: int) {
	line(b, "%d trace file(s): %s", len(files), strings.join(files, ", "))
	line(b, "Totals are inclusive (nested spans are also counted in their parent), summed over all processes.\n")
	line(b, "| rank | span | total ms | count | mean ms |")
	line(b, "|---|---|---|---|---|")
	for r, i in rows[:min(top, len(rows))] {
		ms := r.span.ns / 1e6
		line(b, "| %d | %s | %.3f | %d | %.3f |", i + 1, r.name, ms, r.span.count, ms / f64(r.span.count))
	}
	if len(rows) == 0 {
		line(b, "%s: trace files hold no finished spans", NM)
	}
}

// ---- 5.9 resources -----------------------------------------------------------
metric_text :: proc(v: json.Value, mib := false) -> string {
	m := metric_of(v)
	switch {
	case !m.ok:   return NM
	case mib:     return tprint("%.1f", m.value / 1048576)
	case m.is_int: return tprint("%d", i64(m.value))
	}
	return tprint("%v", m.value)
}

// find_resource looks for <state>/**/workers/<shot>.resource.
find_resource :: proc(state, shot: string) -> string {
	w := os.walker_create(state)
	defer os.walker_destroy(&w)
	want := strings.concatenate({shot, ".resource"})
	for fi in os.walker_walk(&w) {
		if fi.type != .Directory && fi.name == want && strings.has_suffix(fi.fullpath, strings.concatenate({"workers/", want})) {
			return strings.clone(fi.fullpath) // the walker reuses its buffer
		}
	}
	return ""
}

resources_section :: proc(b: ^strings.Builder, state: string, ids: []string) {
	line(b, "| shot | scope | cpu ms | rss MiB | fds | children | samples |")
	line(b, "|---|---|---|---|---|---|---|")
	rss_sum: f64
	found := 0
	for id in ids {
		path := find_resource(state, id)
		if path == "" {
			line(b, "| %s | - | %s: no .resource file | | | | |", id, NM)
			continue
		}
		rec, err := parse_file(path)
		if err != "" {
			line(b, "| %s | - | %s: %s | | | | |", id, NM, err)
			continue
		}
		found += 1
		rss_sum += resource_rows(b, id, rec)
	}
	if found == 0 {
		line(b, "\n%s: no resource records. `record_resource_use` is called only from the Brew settle path (src/settle.odin:147); this report cannot show host-dispatched Stations' peaks until the host calls it.", NM)
		return
	}
	line(b, "\nSum of every known rss peak above (Station + tree, peaks not simultaneous): %.1f MiB. A sum of peaks is an upper bound, not a measured simultaneous total.", rss_sum / 1048576)
}

resource_rows :: proc(b: ^strings.Builder, id: string, rec: json.Value) -> (rss_sum: f64) {
	samples, _ := get(rec, "samples").(json.Integer)
	for scope in ([]string{"station_peak", "tree_peak"}) {
		p := get(rec, scope)
		line(b, "| %s | %s | %s | %s | %s | %s | %d |", id, scope, metric_text(get(p, "cpu_ms")),
			metric_text(get(p, "rss"), true), metric_text(get(p, "fds")), metric_text(get(p, "children")), samples)
		if m := metric_of(get(p, "rss")); m.ok {
			rss_sum += m.value
		}
	}
	return
}

// ---- 5.10 sixth Shot ---------------------------------------------------------
Event :: struct {
	type, shot_id, reason, kind, at: string,
}

// Event timestamps use the shared Coffee Shop RFC 3339 UTC millisecond format.
event_time :: proc(event: Event) -> (time.Time, bool) {
	// Odin's RFC 3339 parser rounds fractional precision. Parse the whole-second
	// timestamp, then add the exact three milliseconds written by log_timestamp.
	if len(event.at) != len("2026-10-31T19:20:01.123Z") || event.at[19] != '.' || event.at[23] != 'Z' {
		return {}, false
	}
	whole := strings.concatenate({event.at[:19], "Z"}, context.temp_allocator)
	parsed, consumed := time.rfc3339_to_time_utc(whole)
	if consumed != len(whole) { return {}, false }
	for i in 20..<23 {
		if event.at[i] < '0' || event.at[i] > '9' { return {}, false }
	}
	millis := int(event.at[20]-'0')*100 + int(event.at[21]-'0')*10 + int(event.at[22]-'0')
	parsed._nsec += i64(millis) * i64(time.Millisecond)
	return parsed, true
}

event_terminal :: proc(event: Event) -> bool {
	return event.type == "station_report" && (event.kind == "pulled" || event.kind == "taste_passed" || event.kind == "taste_failed" || event.kind == "incomplete" || event.kind == "session_failed")
}

shot_elapsed :: proc(events: []Event, shot: string) -> (text: string, ok: bool) {
	start := -1
	finish := -1
	for event, i in events {
		if event.shot_id != shot { continue }
		if event.type == "session_started" && start < 0 { start = i }
		if event_terminal(event) { finish = i }
	}
	if start < 0 || finish < 0 { return NM, false }
	began, began_ok := event_time(events[start])
	ended, ended_ok := event_time(events[finish])
	if !began_ok || !ended_ok { return NM, false }
	delta := time.diff(began, ended)
	if delta < 0 { return NM, false }
	return tprint("%.3f", f64(delta) / f64(time.Second)), true
}

request_elapsed :: proc(events: []Event) -> (start, finish: f64, ok: bool) {
	first_start := -1
	last_finish := -1
	for event, i in events {
		if event.type == "session_started" && first_start < 0 { first_start = i }
		if event_terminal(event) { last_finish = i }
	}
	if first_start < 0 || last_finish < 0 { return 0, 0, false }
	began, began_ok := event_time(events[first_start])
	ended, ended_ok := event_time(events[last_finish])
	if !began_ok || !ended_ok { return 0, 0, false }
	delta := time.diff(began, ended)
	if delta < 0 { return 0, 0, false }
	return 0, f64(delta) / f64(time.Second), true
}

load_events :: proc(path: string) -> (ev: [dynamic]Event, skipped: int, err: string) {
	if path == "" || !os.exists(path) {
		return nil, 0, tprint("events file `%s` not found", path)
	}
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return nil, 0, tprint("events file `%s` unreadable: %v", path, rerr)
	}
	for l in strings.split_lines(string(data)) {
		t := strings.trim_space(l)
		if !strings.has_prefix(t, "{") {continue}
		v, perr := parse_text(t, "event line")
		if perr != "" {
			skipped += 1
			continue
		}
		append(&ev, Event{get_str(v, "type"), get_str(v, "shot_id"), get_str(v, "reason"), get_str(v, "kind"), get_str(v, "at")})
	}
	return
}

find_event :: proc(ev: []Event, typ, shot: string) -> int {
	for e, i in ev {
		if e.type == typ && e.shot_id == shot {return i}
	}
	return -1
}

sixth_verdict :: proc(ev: []Event, sixth: string) -> string {
	started, queued, deq := find_event(ev, "session_started", sixth), find_event(ev, "dispatch_queued", sixth), find_event(ev, "dispatch_dequeued", sixth)
	switch {
	case queued < 0 && started >= 0:
		return tprint("FAIL: `%s` started without being queued (it did not wait)", sixth)
	case queued < 0:
		return tprint("%s: `%s` was neither queued nor started in the log", NM, sixth)
	case deq < 0 || started < 0 || !(queued < deq && deq < started):
		return tprint("`%s` was queued (event %d) but no later dequeue+start was logged: still waiting, or log cut short", sixth, queued)
	}
	return tprint("PASS: `%s` queued at event %d, dequeued at %d, started at %d", sixth, queued, deq, started)
}

events_section :: proc(b: ^strings.Builder, path: string, ids: []string, slots: int) {
	ev, skipped, err := load_events(path)
	if err != "" {
		line(b, "%s: %s", NM, err)
		return
	}
	sixth := ids[len(ids) - 1]
	q := find_event(ev[:], "dispatch_queued", sixth)
	before := 0
	for e in ev[:q if q >= 0 else len(ev)] {
		before += int(e.type == "session_started")
	}
	bad := make([dynamic]Event)
	for e in ev {
		if e.type == "session_failed" || e.type == "error" || e.type == "warning" {append(&bad, e)}
	}
	line(b, "- Sixth Shot: %s", sixth_verdict(ev[:], sixth))
	line(b, "- Stations started before the sixth was queued: %d", before)
	line(b, "- Per-Shot elapsed from session_started to terminal station_report:")
	for id in ids {
		elapsed, ok := shot_elapsed(ev[:], id)
		line(b, "  - %s: %s s", id, elapsed if ok else NM)
	}
	if start, finish, ok := request_elapsed(ev[:]); ok {
		line(b, "- Request elapsed (first session_started to last terminal report): %s s", tprint("%.3f", finish - start))
	} else {
		line(b, "- Request elapsed: %s (no valid start/terminal timestamp pair)", NM)
	}
	fmt.sbprintf(b, "- session_failed/error/warning events: %d", len(bad))
	for e in bad {
		fmt.sbprintf(b, "\n  - %s %s: %s", e.type, e.shot_id, e.reason)
	}
	line(b, "")
	if skipped > 0 {
		line(b, "- %s: %d event line(s) were not valid JSON and were skipped", NM, skipped)
	}
	line(b, "- Pane-pool capacity is 5 (src/host_dispatch_queue.odin:53); machine-limit slot files seen: %d", slots)
	line(b, "- Interference between Stations: judged only by the failure events above and the per-Station peaks; this script cannot observe cross-talk directly.")
}

// ---- report ------------------------------------------------------------------
request_ids :: proc(path: string) -> (ids: [dynamic]string, err: string) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return nil, tprint("cannot read `%s`: %v", path, rerr)
	}
	first, _, _ := strings.partition(string(data), "\n")
	v, perr := parse_text(first, path)
	if perr != "" {
		return nil, perr
	}
	shots, _ := get(get(v, "recipe"), "shots").(json.Array)
	for s in shots {
		append(&ids, get_str(s, "id"))
	}
	if len(ids) == 0 {
		return nil, tprint("`%s` has no recipe.shots", path)
	}
	return
}

write_report :: proc(a: ReportArgs) -> string {
	ids, err := request_ids(a.request)
	if err != "" {
		return err
	}
	slots := len(list_dir(strings.concatenate({a.state_dir, "/machine-limit"}), "slot-")) // *.lock only in practice
	b := strings.builder_make()
	line(&b, "# Five-Station gates\n")
	line(&b, "Request: `%s` (%d shots)  ", a.request, len(ids))
	line(&b, "State dir: `%s`  ", a.state_dir)
	line(&b, "Events: `%s`  ", a.events)
	line(&b, "Trace: `%s*`\n", a.trace)
	line(&b, "## 5.10 Sixth Shot waits\n")
	events_section(&b, a.events, ids[:], slots)
	line(&b, "\n## 5.9 Peak CPU, memory, descriptors, children\n")
	resources_section(&b, a.state_dir, ids[:])
	line(&b, "\n## 5.8 Top %d spans by total time\n", a.top)
	trace_section(&b, a.trace, a.top)
	if werr := os.write_entire_file(a.out, strings.to_string(b)); werr != nil {
		return tprint("cannot write `%s`: %v", a.out, werr)
	}
	fmt.printfln("wrote %s", a.out)
	return ""
}
