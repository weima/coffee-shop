package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

DEFAULT_PROMPT :: "Read README.md, then run `sleep 90`, then report done."

Shot :: struct {
	id:     string,
	prompt: string,
	kind:    string,
	taste:   string,
	message: string `json:"message,omitempty"`,
}

Recipe :: struct {
	shots: []Shot,
}

Request :: struct {
	type:       string,
	request_id: string,
	repo:       string,
	recipe:     Recipe,
}

RequestArgs :: struct {
	repo, out, request_id, prompt: string,
	// kind and taste default to the research fixture the gate has always used. A
	// research Shot has no shell, so its prompt cannot sleep; an execute Shot with a
	// taste does the work and then ends instead of holding its session open.
	kind, taste, message: string,
	shots:               int,
}

shot_ids :: proc(n: int) -> []string {
	ids := make([]string, n)
	for i in 0 ..< n {
		ids[i] = fmt.aprintf("gate-s%d", i + 1)
	}
	return ids
}

write_request :: proc(a: RequestArgs) -> string {
	abs, aerr := os.get_absolute_path(a.repo, context.allocator)
	if aerr != nil {
		return tprint("bad --repo `%s`: %v", a.repo, aerr)
	}
	ids := shot_ids(a.shots)
	kind := a.kind
	if kind == "" {kind = "research"}
	shots := make([]Shot, len(ids))
	for id, i in ids {
		shots[i] = {id = id, prompt = a.prompt, kind = kind, taste = a.taste, message = a.message}
	}
	req := Request{"dispatch", a.request_id, abs, {shots}}
	data, merr := json.marshal(req)
	if merr != nil {
		return tprint("cannot encode request: %v", merr)
	}
	// One JSON request per line (host.odin:73).
	line := strings.concatenate({string(data), "\n"})
	if werr := os.write_entire_file(a.out, line); werr != nil {
		return tprint("cannot write `%s`: %v", a.out, werr)
	}
	fmt.printfln("wrote %s: request id %s, %d shots %s..%s", a.out, a.request_id, a.shots, ids[0], ids[len(ids) - 1])
	return ""
}
