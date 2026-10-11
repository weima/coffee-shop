package main

// Odin probe. Two modes:
//   probe test                 step 1: local tests only. Needs PROBE_TEST_BASE_URL=http://127.0.0.1:<port>.
//   probe run <path/auth.json> step 2: 3 sessions x 2 Copilot calls, first error stops the run.
// Read-only auth: auth.json is read BY PATH. It is never written, locked, or refreshed.
// Never printed: tokens, header values, auth.json content. Error text is redacted and cut.
// Transport: libcurl, one POST per call.

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"

foreign import curl "system:curl"

CURL :: rawptr
CURLcode :: c.int
Slist :: struct {
	data: cstring,
	next: ^Slist,
}

// Values from curl.h: OBJECTPOINT 10000, FUNCTIONPOINT 20000, LONG 0x200000 base.
OPT_WRITEDATA :: 10001
OPT_URL :: 10002
OPT_POSTFIELDS :: 10015
OPT_POSTFIELDSIZE :: 60
OPT_HTTPHEADER :: 10023
OPT_WRITEFUNCTION :: 20011
OPT_NOSIGNAL :: 99
OPT_TIMEOUT_MS :: 155
OPT_CONNECTTIMEOUT_MS :: 156
INFO_RESPONSE_CODE :: 0x200002
CURL_GLOBAL_ALL :: 3

foreign curl {
	curl_global_init :: proc(flags: c.long) -> CURLcode ---
	curl_easy_init :: proc() -> CURL ---
	curl_easy_cleanup :: proc(h: CURL) ---
	curl_easy_setopt :: proc(h: CURL, option: c.int, #c_vararg args: ..any) -> CURLcode ---
	curl_easy_getinfo :: proc(h: CURL, info: c.int, #c_vararg args: ..any) -> CURLcode ---
	curl_easy_perform :: proc(h: CURL) -> CURLcode ---
	curl_easy_strerror :: proc(code: CURLcode) -> cstring ---
	curl_slist_append :: proc(list: ^Slist, s: cstring) -> ^Slist ---
	curl_slist_free_all :: proc(list: ^Slist) ---
}

PROVIDER :: "github-copilot"
MESSAGES_PATH :: "/v1/messages"
DEFAULT_BASE :: "https://api.individual.githubcopilot.com"
// Wire format: pi's anthropic-messages route. Non-streaming, so usage is in the reply.
PROMPT_JSON :: `{"model":"claude-haiku-5.5","max_tokens":16,"messages":[{"role":"user","content":"Reply with the single word OK."}]}`
// pi-ai COPILOT_HEADERS (auth/oauth/github-copilot.js), the same values as the catalog entry.
// X-Initiator and Openai-Intent come from api/github-copilot-headers.js.
COPILOT_HEADERS := [?]string {
	"accept: application/json",
	"anthropic-version: 2023-06-01",
	"anthropic-dangerous-direct-browser-access: true",
	"content-type: application/json",
	"X-Initiator: user",
	"Openai-Intent: conversation-edits",
	"User-Agent: GitHubCopilotChat/0.35.0",
	"Editor-Version: vscode/1.107.0",
	"Editor-Plugin-Version: copilot-chat/0.35.0",
	"Copilot-Integration-Id: vscode-chat",
}

SESSIONS :: 3
CALLS_PER_SESSION :: 2
WAIT :: 1 * time.Second
PARSE_RETRIES :: 3 // retries after the first read: 4 reads in total
PARSE_RETRY_WAIT :: 200 * time.Millisecond
TIMEOUT_MS :: 60_000

// Exit codes: 0 done, 2 API or transport stop, 3 auth stop, 1 usage.
EXIT_API :: 2
EXIT_AUTH :: 3

FIXTURES :: #directory + "/fixtures/"

failures := 0

// Growing buffer for the response body. The write callback is C, so it sets its own context.
Body :: struct {
	data: [dynamic]u8,
}

write_body :: proc "c" (ptr: [^]u8, size, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	b := (^Body)(userdata)
	n := int(size * nmemb)
	append_elems(&b.data, ..ptr[:n])
	return c.size_t(n)
}

cs :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

Reply :: struct {
	status: int, // 0 when the transport failed
	body:   string,
	err:    string, // curl error text, no secret
	ms:     f64,
}

// One POST. The token only ever goes into the Authorization header and is never printed.
post_json :: proc(url, token, payload: string) -> Reply {
	h := curl_easy_init()
	if h == nil {return Reply{err = "curl init failed"}}
	defer curl_easy_cleanup(h)

	headers: ^Slist
	headers = curl_slist_append(headers, cs(fmt.tprintf("authorization: Bearer %s", token)))
	for hv in COPILOT_HEADERS {
		headers = curl_slist_append(headers, cs(hv))
	}
	defer curl_slist_free_all(headers)

	body: Body
	curl_easy_setopt(h, OPT_URL, cs(url))
	curl_easy_setopt(h, OPT_HTTPHEADER, headers)
	curl_easy_setopt(h, OPT_POSTFIELDS, cs(payload))
	curl_easy_setopt(h, OPT_POSTFIELDSIZE, c.long(len(payload)))
	curl_easy_setopt(h, OPT_WRITEFUNCTION, transmute(rawptr)write_body)
	curl_easy_setopt(h, OPT_WRITEDATA, &body)
	curl_easy_setopt(h, OPT_TIMEOUT_MS, c.long(TIMEOUT_MS))
	curl_easy_setopt(h, OPT_CONNECTTIMEOUT_MS, c.long(10_000))
	curl_easy_setopt(h, OPT_NOSIGNAL, c.long(1))

	start := time.tick_now()
	code := curl_easy_perform(h)
	ms := time.duration_milliseconds(time.tick_diff(start, time.tick_now()))
	if code != 0 {return Reply{err = string(curl_easy_strerror(code)), ms = ms}}

	status: c.long
	curl_easy_getinfo(h, INFO_RESPONSE_CODE, &status)
	return Reply{status = int(status), body = string(body.data[:]), ms = ms}
}

Credential :: struct {
	access:     string,
	expires_ms: f64,
}

str_of :: proc(o: json.Object, key: string) -> (string, bool) {
	v, has := o[key]
	if !has {return "", false}
	s, ok := v.(json.String)
	return string(s), ok
}

num_of :: proc(o: json.Object, key: string) -> (f64, bool) {
	v, has := o[key]
	if !has {return 0, false}
	#partial switch n in v {
	case json.Float:
		return f64(n), true
	case json.Integer:
		return f64(n), true
	}
	return 0, false
}

// Reads the github-copilot oauth entry BY PATH. Retries only when the JSON does not parse
// (a half-written file). The parse message is not printed: it can quote file content.
read_credential :: proc(path: string) -> (cred: Credential, attempts: int, err: string) {
	attempts = 0
	for {
		attempts += 1
		data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
		if rerr != nil {return {}, attempts, "auth file unreadable"}
		text := string(data)
		if strings.has_prefix(text, "\uFEFF") {text = text[3:]}

		root, perr := json.parse_string(text)
		if perr != nil {
			if attempts > PARSE_RETRIES {return {}, attempts, "auth file is not valid JSON after retries"}
			time.sleep(PARSE_RETRY_WAIT)
			continue
		}
		top, is_obj := root.(json.Object)
		if !is_obj {return {}, attempts, "auth file has no provider map"}
		entry_v, has := top[PROVIDER]
		entry, is_entry := entry_v.(json.Object)
		if !has || !is_entry {return {}, attempts, "no github-copilot entry in auth file"}
		typ, _ := str_of(entry, "type")
		access, has_access := str_of(entry, "access")
		expires, has_expires := num_of(entry, "expires")
		if typ != "oauth" || !has_access || !has_expires {
			return {}, attempts, "no usable github-copilot oauth credential in auth file"
		}
		return Credential{access = access, expires_ms = expires}, attempts, ""
	}
}

// Same rule as pi-ai: the host is the token's proxy-ep with proxy. replaced by api.
base_url_from_token :: proc(token: string) -> string {
	i := strings.index(token, "proxy-ep=")
	if i < 0 {return DEFAULT_BASE}
	host := token[i + len("proxy-ep="):]
	if j := strings.index_byte(host, ';'); j >= 0 {host = host[:j]}
	if strings.has_prefix(host, "proxy.") {return fmt.tprintf("https://api.%s", host[len("proxy."):])}
	return fmt.tprintf("https://%s", host)
}

// Replace the secret, then cut to 160 bytes. Used for every error text that is printed.
redact :: proc(text, secret: string) -> string {
	t := text
	if secret != "" {t, _ = strings.replace_all(t, secret, "[redacted]")}
	if len(t) > 160 {t = t[:160]}
	return t
}

now_ms :: proc() -> f64 {
	return f64(time.time_to_unix_nano(time.now())) / 1e6
}

// Input and output tokens from a 2xx Messages reply.
usage_of :: proc(body: string) -> (in_t, out_t: i64, ok: bool) {
	root, err := json.parse_string(body)
	if err != nil {return 0, 0, false}
	top, is_obj := root.(json.Object)
	if !is_obj {return 0, 0, false}
	u_v, has := top["usage"]
	u, is_u := u_v.(json.Object)
	if !has || !is_u {return 0, 0, false}
	i, has_i := num_of(u, "input_tokens")
	o, has_o := num_of(u, "output_tokens")
	return i64(i), i64(o), has_i && has_o
}

emit_stop :: proc(reason: string, session, call: int, status: int = 0, detail: string = "") {
	fmt.printfln(`{{"stop":%q,"session":%d,"call":%d,"status":%d,"detail":%q}}`, reason, session, call, status, detail)
}

// The run loop. base_override is "" in run mode, so the default never points at a fixture.
// Returns the exit code and the number of requests sent.
run_calls :: proc(auth_path, base_override: string) -> (code: int, sent: int) {
	t0 := time.tick_now()
	tokens := i64(0)
	for session in 1 ..= SESSIONS {
		cred, _, err := read_credential(auth_path) // fresh read at each session start
		if err != "" {
			emit_stop(err, session, sent + 1)
			return EXIT_AUTH, sent
		}
		for _ in 1 ..= CALLS_PER_SESSION {
			time.sleep(WAIT)
			call := sent + 1
			if now_ms() >= cred.expires_ms {
				emit_stop("token expired; re-login with pi (probe does not refresh)", session, call)
				return EXIT_AUTH, sent
			}
			sent += 1
			base := base_override
			if base == "" {base = base_url_from_token(cred.access)}
			url := strings.concatenate({base, MESSAGES_PATH}, context.temp_allocator)
			r := post_json(url, cred.access, PROMPT_JSON)
			if r.err != "" {
				emit_stop(redact(r.err, cred.access), session, call)
				return EXIT_API, sent
			}
			if r.status < 200 || r.status > 299 {
				emit_stop("http error", session, call, r.status, redact(r.body, cred.access))
				return EXIT_API, sent
			}
			in_t, out_t, ok := usage_of(r.body)
			if !ok {
				emit_stop("2xx reply is not a Messages reply", session, call, r.status)
				return EXIT_API, sent
			}
			tokens += in_t + out_t
			fmt.printfln(`{{"session":%d,"call":%d,"latency_ms":%.0f,"status":%d,"input_tokens":%d,"output_tokens":%d}}`, session, call, r.ms, r.status, in_t, out_t)
		}
	}
	wall := time.duration_milliseconds(time.tick_diff(t0, time.tick_now()))
	fmt.printfln(`{{"done":true,"calls":%d,"wall_ms":%.0f,"total_tokens":%d}}`, sent, wall, tokens)
	return 0, sent
}

expect :: proc(name: string, ok: bool) {
	if ok {
		fmt.printfln("PASS %s", name)
	} else {
		failures += 1
		fmt.printfln("FAIL %s", name)
	}
}

// Writes the second half of the file after 300 ms, so the reader sees a half-written file first.
Finish_Later :: struct {
	path, full: string,
}

finish_later :: proc(job: Finish_Later) {
	time.sleep(300 * time.Millisecond)
	_ = os.write_entire_file_from_string(job.path, job.full)
}

run_tests :: proc() -> int {
	base, has := os.lookup_env("PROBE_TEST_BASE_URL", context.temp_allocator)
	if !has || !strings.has_prefix(base, "http://127.0.0.1:") {
		fmt.println(`{"fail":"PROBE_TEST_BASE_URL must be http://127.0.0.1:<port>; refusing"}`)
		return 1
	}
	fmt.printfln("test base: %s (loopback only)", base)

	// Pure: the host rule, no network.
	expect("base url from proxy-ep", base_url_from_token("tid=x;exp=1;proxy-ep=proxy.individual.githubcopilot.com;sku=y") == "https://api.individual.githubcopilot.com")
	expect("base url default without proxy-ep", base_url_from_token("tid=x;exp=1") == DEFAULT_BASE)

	// Read by path: fixture only, never the user's file. Attempts counted.
	cred, attempts, err := read_credential(FIXTURES + "auth-ok.json")
	expect("read fixture by path", err == "" && attempts == 1 && cred.access == "fixture-ok-token")

	// Half-written, never completed: 4 reads, about 600 ms of waits, then a stop.
	t0 := time.tick_now()
	_, attempts, err = read_credential(FIXTURES + "auth-half.json")
	waited := time.duration_milliseconds(time.tick_diff(t0, time.tick_now()))
	expect("half-written file stops after 4 reads", err != "" && attempts == 4 && waited >= 600)

	// Half-written, then completed: the reader retries and succeeds.
	full, _ := os.read_entire_file_from_path(FIXTURES + "auth-ok.json", context.temp_allocator)
	tmp := "/tmp/probe-odin-test-half.json"
	_ = os.write_entire_file_from_string(tmp, string(full[:len(full) / 2]))
	writer := thread.create_and_start_with_poly_data(Finish_Later{tmp, string(full)}, finish_later)
	cred2, attempts2, err2 := read_credential(tmp)
	thread.join(writer)
	thread.destroy(writer)
	_ = os.remove(tmp)
	expect("half-written file is retried and then read", err2 == "" && attempts2 >= 2 && cred2.access == "fixture-ok-token")

	// One POST: the local fake checks the request shape and answers 200 with usage.
	r := post_json(strings.concatenate({base, MESSAGES_PATH}, context.temp_allocator), "fixture-ok-token", PROMPT_JSON)
	in_t, out_t, ok := usage_of(r.body)
	expect("POST 200 and JSON usage", r.err == "" && r.status == 200 && ok && in_t == 12 && out_t == 2)

	// Stops: the run ends at the first error, with the call count shown.
	code, sent := run_calls(FIXTURES + "auth-429.json", base)
	expect("429 detected and stops the run", code == EXIT_API && sent == 1)
	code, sent = run_calls(FIXTURES + "auth-401.json", base)
	expect("401 detected and stops the run", code == EXIT_API && sent == 1)
	code, sent = run_calls(FIXTURES + "auth-500.json", base)
	expect("5xx detected and stops the run", code == EXIT_API && sent == 1)
	code, sent = run_calls(FIXTURES + "auth-expired.json", base)
	expect("expired token stops before any request", code == EXIT_AUTH && sent == 0)

	// Full loop against the local fake: 3 sessions x 2 calls, all OK.
	code, sent = run_calls(FIXTURES + "auth-ok.json", base)
	expect("full loop: 6 calls, exit 0", code == 0 && sent == 6)

	fmt.printfln("failures: %d", failures)
	return failures == 0 ? 0 : 1
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: probe test | probe run <path/to/auth.json>")
		os.exit(1)
	}
	curl_global_init(CURL_GLOBAL_ALL)
	switch os.args[1] {
	case "test":
		os.exit(run_tests())
	case "run":
		if len(os.args) != 3 {
			fmt.eprintln("usage: probe run <path/to/auth.json>")
			os.exit(1)
		}
		// Run mode never reads PROBE_TEST_BASE_URL: the host comes only from the token.
		code, _ := run_calls(os.args[2], "")
		os.exit(code)
	case:
		fmt.eprintln("usage: probe test | probe run <path/to/auth.json>")
		os.exit(1)
	}
}
