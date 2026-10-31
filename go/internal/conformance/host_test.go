package conformance

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// TestHostUnderTest runs a real host and checks the contract's structural promises:
// every line is one JSON object carrying `type` and `at`, the stream opens with ready
// and ends with stopped, and exit is clean.
//
// It is opt-in because it needs a repository and a state directory:
//
//	CS_CONFORMANCE_CMD='odin run src -- host' \
//	CS_CONFORMANCE_DIR=$PWD \
//	CS_CONFORMANCE_REPO=/abs/path/to/a/repo \
//	CS_CONFORMANCE_STATE=/tmp/cs-conformance \
//	go test ./internal/conformance -run TestHostUnderTest -v
//
// The command must compile the current source (or be a `just` recipe). This repository
// does not run previously built binaries, so a stale path here would test the wrong code.
func TestHostUnderTest(t *testing.T) {
	command := os.Getenv("CS_CONFORMANCE_CMD")
	if command == "" {
		t.Skip("set CS_CONFORMANCE_CMD to run a host under test")
	}
	dir := os.Getenv("CS_CONFORMANCE_DIR")
	repo := os.Getenv("CS_CONFORMANCE_REPO")
	state := os.Getenv("CS_CONFORMANCE_STATE")
	if repo == "" || state == "" {
		t.Fatal("CS_CONFORMANCE_REPO and CS_CONFORMANCE_STATE are required")
	}
	if err := os.MkdirAll(state, 0o700); err != nil {
		t.Fatalf("state dir: %v", err)
	}

	env := append(os.Environ(),
		"CS_PANE_BACKEND=headless",
		"CS_STATE_DIR="+state,
	)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// A shell here is the developer's own command, not a path built from user input.
	result, err := Run(ctx, HostRun{
		Argv:     []string{"sh", "-c", command},
		Dir:      dir,
		Env:      env,
		Requests: `{"type":"shutdown","request_id":"smoke"}` + "\n",
	})
	if err != nil {
		t.Fatalf("%v\nevents: %v", err, result.Events)
	}
	if len(result.Events) < 3 {
		t.Fatalf("expected at least ready/received/stopped, got %v", result.Events)
	}
	for i, line := range result.Events {
		var e map[string]any
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("event %d is not JSON: %s (%v)", i, line, err)
		}
		if _, ok := e["type"]; !ok {
			t.Fatalf("event %d has no type: %s", i, line)
		}
		if _, ok := e["at"]; !ok {
			t.Fatalf("event %d has no timestamp: %s", i, line)
		}
	}
	if !strings.Contains(result.Events[0], `"type":"ready"`) {
		t.Fatalf("first event is not ready: %s", result.Events[0])
	}
	if last := result.Events[len(result.Events)-1]; !strings.Contains(last, `"type":"stopped"`) {
		t.Fatalf("last event is not stopped: %s", last)
	}
}

// The harness itself must not pass a broken stream: this pins the comparison rules.
func TestCompareReportsFirstDifference(t *testing.T) {
	want := []string{`{"type":"ready","at":"AT"}`, `{"type":"stopped","at":"AT"}`}
	if err := Compare(want, want); err != nil {
		t.Fatalf("identical streams must compare equal: %v", err)
	}
	got := []string{`{"type":"ready","at":"AT"}`, `{"type":"stopped","request_id":"x","at":"AT"}`}
	if err := Compare(got, want); err == nil || !strings.Contains(err.Error(), "event 1 differs") {
		t.Fatalf("expected a first-difference error, got %v", err)
	}
	if err := Compare(want[:1], want); err == nil || !strings.Contains(err.Error(), "event count differs") {
		t.Fatalf("expected a count error, got %v", err)
	}
}

// Normalizing must strip the timestamp value and nothing else, or the comparison above
// would hide real differences.
func TestSplitLinesNormalizesOnlyTheTimestamp(t *testing.T) {
	stream := `{"type":"ready","protocol":1,"at":"2026-10-31T20:23:04.406Z"}
{"type":"received","request_id":"r","bytes":0,"at":"2026-10-31T20:23:04.407Z"}
`
	got := SplitLines(stream)
	want := []string{
		`{"type":"ready","protocol":1,"at":"AT"}`,
		`{"type":"received","request_id":"r","bytes":0,"at":"AT"}`,
	}
	if err := Compare(got, want); err != nil {
		t.Fatalf("%v", err)
	}
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skip("no shell")
	}
}
