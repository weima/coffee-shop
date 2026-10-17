#!/usr/bin/env python3
"""Gate evidence for 5.8 / 5.9 / 5.10. See five-station-gates.md.

Never starts a host, never touches Herdr. `request` writes a request line;
`report` reads the host's event log, the state dir and the Spall traces.
"""
import argparse, glob, json, os, struct, sys, tempfile
from collections import defaultdict

NM = "not measured"

def request(a):
    ids = [f"gate-s{i}" for i in range(1, a.shots + 1)]
    prompt = open(a.prompt_file).read() if a.prompt_file else a.prompt
    req = {"type": "dispatch", "request_id": a.request_id, "repo": os.path.abspath(a.repo),
           "recipe": {"shots": [{"id": i, "prompt": prompt, "kind": "research"} for i in ids]}}
    with open(a.out, "w") as f:
        f.write(json.dumps(req) + "\n")  # one JSON request per line (host.odin:73)
    print(f"wrote {a.out}: {a.shots} shots {ids[0]}..{ids[-1]}")

def parse_spall(path):
    """Return {name: [total_ns, count]} for one trace file (inclusive time)."""
    d = open(path, "rb").read()
    if len(d) < 32 or struct.unpack_from("<Q", d, 0)[0] != 0x0BADF00D:
        raise ValueError("not a Spall manual-format file")
    scale = struct.unpack_from("<d", d, 16)[0]  # ns per tick
    out = defaultdict(lambda: [0.0, 0])
    pos = 32
    while pos + 20 <= len(d):
        size = struct.unpack_from("<I", d, pos)[0]
        pos += 20
        end, stack = min(pos + size, len(d)), []
        while pos < end:
            t = d[pos]
            if t == 3:
                ts, nl, al = struct.unpack_from("<QBB", d, pos + 1)
                stack.append((d[pos + 11:pos + 11 + nl].decode("utf8", "replace"), ts))
                pos += 11 + nl + al
            elif t == 4:
                ts = struct.unpack_from("<Q", d, pos + 1)[0]
                if stack:
                    n, b = stack.pop()
                    out[n][0] += (ts - b) * scale; out[n][1] += 1
                pos += 9
            elif t == 7:
                pos += 5 + struct.unpack_from("<I", d, pos + 1)[0]
            else:
                raise ValueError(f"unknown event type {t} at {pos}")
    return out

def trace_section(trace, top):
    files = sorted(glob.glob(trace + "*")) if trace else []
    if not files:
        return [f"{NM}: no trace files match `{trace}*` (was CS_SPALL_FILE set for the host?)"]
    tot, bad = defaultdict(lambda: [0.0, 0]), []
    for f in files:
        try:
            for n, (ns, c) in parse_spall(f).items():
                tot[n][0] += ns; tot[n][1] += c
        except (ValueError, struct.error) as e:
            bad.append(f"{os.path.basename(f)}: {e}")
    tot.pop("Spall Trace Buffer Flush", None)  # the tracer's own flush, not Coffee Shop work
    rows = sorted(tot.items(), key=lambda kv: -kv[1][0])
    lines = [f"{len(files)} trace file(s): " + ", ".join(os.path.basename(f) for f in files),
             "Totals are inclusive (nested spans are also counted in their parent), summed over all processes.", "",
             "| rank | span | total ms | count | mean ms |", "|---|---|---|---|---|"]
    for i, (n, (ns, c)) in enumerate(rows[:top], 1):
        lines.append(f"| {i} | {n} | {ns/1e6:.3f} | {c} | {ns/1e6/c:.3f} |")
    if not rows:
        lines.append(f"{NM}: trace files hold no finished spans")
    return lines + [f"unreadable: {b}" for b in bad]

def metric(m, fmt=str):
    return fmt(m["value"]) if m and m.get("known") else NM

def resources_section(state, ids):
    lines = ["| shot | scope | cpu ms | rss MiB | fds | children | samples |", "|---|---|---|---|---|---|---|"]
    rss_sum, found = 0, 0
    for sid in ids:
        hits = glob.glob(os.path.join(state, "**", "workers", sid + ".resource"), recursive=True)
        if not hits:
            lines.append(f"| {sid} | - | {NM}: no .resource file | | | | |"); continue
        r = json.load(open(hits[0])); found += 1
        for scope in ("station_peak", "tree_peak"):
            p = r.get(scope, {})
            mib = lambda v: f"{v/1048576:.1f}"
            lines.append(f"| {sid} | {scope} | {metric(p.get('cpu_ms'))} | {metric(p.get('rss'), mib)} | "
                         f"{metric(p.get('fds'))} | {metric(p.get('children'))} | {r.get('samples', 0)} |")
        for scope in ("station_peak", "tree_peak"):
            m = r.get(scope, {}).get("rss")
            if m and m.get("known"): rss_sum += m["value"]
    if not found:
        lines += ["", f"{NM}: no resource records. `record_resource_use` is called only from the Brew settle path "
                  "(src/settle.odin:147); this report cannot show host-dispatched Stations' peaks until the host calls it."]
    else:
        lines += ["", f"Sum of every known rss peak above (Station + tree, peaks not simultaneous): {rss_sum/1048576:.1f} MiB. "
                  "A sum of peaks is an upper bound, not a measured simultaneous total."]
    return lines

def events_section(events, ids, limit_files):
    ev = [json.loads(l) for l in open(events) if l.strip().startswith("{")] if events and os.path.exists(events) else None
    if ev is None:
        return [f"{NM}: events file `{events}` not found"]
    idx = lambda typ, s: next((i for i, e in enumerate(ev) if e.get("type") == typ and e.get("shot_id") == s), None)
    sixth = ids[-1]
    started, queued, deq = idx("session_started", sixth), idx("dispatch_queued", sixth), idx("dispatch_dequeued", sixth)
    before = sum(1 for e in ev[:queued if queued is not None else len(ev)] if e.get("type") == "session_started")
    if queued is None and started is not None:
        verdict = f"FAIL: `{sixth}` started without being queued (it did not wait)"
    elif queued is None:
        verdict = f"{NM}: `{sixth}` was neither queued nor started in the log"
    elif deq is None or started is None or not (queued < deq < started):
        verdict = f"`{sixth}` was queued (event {queued}) but no later dequeue+start was logged: still waiting, or log cut short"
    else:
        verdict = f"PASS: `{sixth}` queued at event {queued}, dequeued at {deq}, started at {started}"
    bad = [e for e in ev if e.get("type") in ("session_failed", "error", "warning")]
    return [f"- Sixth Shot: {verdict}",
            f"- Stations started before the sixth was queued: {before}",
            f"- session_failed/error/warning events: {len(bad)}" + "".join(f"\n  - {e.get('type')} {e.get('shot_id','')}: {e.get('reason','')}" for e in bad),
            f"- Pane-pool capacity is 5 (src/host_dispatch_queue.odin:53); machine-limit slot files seen: {limit_files}",
            "- Interference between Stations: judged only by the failure events above and the per-Station peaks; "
            "this script cannot observe cross-talk directly."]

def report(a):
    ids = [s["id"] for s in json.loads(open(a.request).readline())["recipe"]["shots"]]
    slots = len(glob.glob(os.path.join(a.state_dir, "machine-limit", "slot-*.lock")))
    body = ["# Five-Station gates", "", f"Request: `{a.request}` ({len(ids)} shots)  ", f"State dir: `{a.state_dir}`  ",
            f"Events: `{a.events}`  ", f"Trace: `{a.trace}*`", "",
            "## 5.10 Sixth Shot waits", ""] + events_section(a.events, ids, slots) + \
           ["", "## 5.9 Peak CPU, memory, descriptors, children", ""] + resources_section(a.state_dir, ids) + \
           ["", f"## 5.8 Top {a.top} spans by total time", ""] + trace_section(a.trace, a.top)
    with open(a.out, "w") as f:
        f.write("\n".join(body) + "\n")
    print(f"wrote {a.out}")

# ---- dry mode: build a fixture, run report, assert on the result -------------
def fx_trace(path, spans):
    def b(n, ts): n = n.encode(); return struct.pack("<BQBB", 3, ts, len(n), 0) + n
    ev = b"".join(b(n, s) + struct.pack("<BQ", 4, e) for n, s, e in spans)
    ev += struct.pack("<BI", 7, 3) + b"\0\0\0"  # a Pad_Skip, as the real writer may emit
    with open(path, "wb") as f:
        f.write(struct.pack("<QQdQ", 0x0BADF00D, 1, 1.0, 0) + struct.pack("<IIIQ", len(ev), 1, 1, 0) + ev)

def selftest(_=None):
    ok = True
    def check(c, msg):
        nonlocal ok; ok &= bool(c); print(("ok   " if c else "FAIL ") + msg)
    for waits in (True, False):
        with tempfile.TemporaryDirectory() as t:
            ns = argparse.Namespace(repo=t, out=f"{t}/req.jsonl", shots=6, request_id="dry", prompt="x", prompt_file=None)
            request(ns)
            ids = [s["id"] for s in json.loads(open(ns.out).readline())["recipe"]["shots"]]
            ev = [{"type": "dispatch_accepted"}] + [{"type": "session_started", "shot_id": i} for i in ids[:5]]
            ev += [{"type": "dispatch_queued", "shot_id": ids[5]}, {"type": "dispatch_dequeued", "shot_id": ids[5]}] if waits else []
            ev += [{"type": "session_started", "shot_id": ids[5]}]
            open(f"{t}/ev.jsonl", "w").write("\n".join(map(json.dumps, ev)) + "\n")
            os.makedirs(f"{t}/state/workers"); os.makedirs(f"{t}/state/machine-limit")
            for i in ids[:4]:  # fifth has no record -> must say "not measured"
                m = lambda v: {"known": True, "value": v}
                p = {"cpu_ms": m(1500), "rss": m(104857600), "fds": m(12), "children": m(2)}
                p2 = dict(p, cpu_ms={"known": False, "value": 0})
                json.dump({"station_peak": p, "tree_peak": p2, "samples": 3}, open(f"{t}/state/workers/{i}.resource", "w"))
            fx_trace(f"{t}/tr.host", [("a", 0, 5_000_000), ("b", 0, 2_000_000)])
            fx_trace(f"{t}/tr.st1", [("a", 0, 1_000_000), ("c", 0, 9_000_000)])
            open(f"{t}/tr.bad", "w").write("junk")
            rp = argparse.Namespace(request=ns.out, state_dir=f"{t}/state", events=f"{t}/ev.jsonl", trace=f"{t}/tr", out=f"{t}/r.md", top=3)
            report(rp); md = open(rp.out).read()
            check(("PASS: `gate-s6` queued" in md) == waits and ("FAIL: `gate-s6` started without" in md) == (not waits),
                  f"waits={waits}: sixth-Shot verdict")
            check("| 1 | c | 9.000 | 1 | 9.000 |" in md and "| 2 | a | 6.000 | 2 | 3.000 |" in md, "trace totals summed across files, ranked")
            check("tr.bad: not a Spall" in md, "unreadable trace named, not hidden")
            check(f"| gate-s5 | - | {NM}: no .resource file" in md, "missing record -> not measured")
            check("| gate-s1 | station_peak | 1500 | 100.0 | 12 | 2 |" in md and f"| gate-s1 | tree_peak | {NM} |" in md, "known and unknown metrics kept apart")
            check("Sum of every known rss peak above (Station + tree, peaks not simultaneous): 800.0 MiB" in md, "rss sum of known peaks")
    with tempfile.TemporaryDirectory() as t:
        open(f"{t}/req.jsonl", "w").write(json.dumps({"recipe": {"shots": [{"id": "x"}]}}) + "\n")
        rp = argparse.Namespace(request=f"{t}/req.jsonl", state_dir=t, events=f"{t}/none", trace=f"{t}/none", out=f"{t}/r.md", top=3)
        report(rp); md = open(rp.out).read()
        check(md.count(NM) >= 4 and "record_resource_use" in md, "everything absent -> not measured with reasons")
    sys.exit(0 if ok else 1)

def main():
    p = argparse.ArgumentParser(description=__doc__); s = p.add_subparsers(dest="cmd", required=True)
    q = s.add_parser("request"); q.set_defaults(f=request)
    q.add_argument("--repo", required=True); q.add_argument("--out", required=True)
    q.add_argument("--shots", type=int, default=6); q.add_argument("--request-id", default="gate-five")
    q.add_argument("--prompt", default="Read README.md, then run `sleep 90`, then report done.")
    q.add_argument("--prompt-file")
    r = s.add_parser("report"); r.set_defaults(f=report)
    r.add_argument("--request", required=True); r.add_argument("--events", required=True)
    r.add_argument("--state-dir", required=True); r.add_argument("--trace", required=True)
    r.add_argument("--out", required=True); r.add_argument("--top", type=int, default=10)
    s.add_parser("selftest").set_defaults(f=selftest)
    a = p.parse_args(); a.f(a)

if __name__ == "__main__":
    main()
