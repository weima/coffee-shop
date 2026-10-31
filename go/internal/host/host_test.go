package host

import (
	"context"
	"strings"
	"testing"
	"time"
)

func fixedClock() func() time.Time {
	t := time.Date(2026, 10, 31, 20, 23, 4, 406_000_000, time.UTC)
	return func() time.Time { return t }
}

// The scaffolding slice must produce the contract's shapes and nothing else: ready first,
// one received per line with its byte length, then stopped on shutdown.
func TestRunServesShutdownAndAcknowledgesEveryLine(t *testing.T) {
	var out strings.Builder
	err := Run(context.Background(), Options{
		In:  strings.NewReader("{\"type\":\"shutdown\",\"request_id\":\"stop-1\"}\n"),
		Out: &out,
		Now: fixedClock(),
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	want := strings.Join([]string{
		`{"type":"ready","protocol":1,"at":"2026-10-31T20:23:04.406Z"}`,
		`{"type":"received","request_id":"stop-1","bytes":41,"at":"2026-10-31T20:23:04.406Z"}`,
		`{"type":"stopped","request_id":"stop-1","at":"2026-10-31T20:23:04.406Z"}`,
		"",
	}, "\n")
	if out.String() != want {
		t.Fatalf("stream mismatch\n got: %s\nwant: %s", out.String(), want)
	}
}

// An unknown request is answered with an error and the host keeps serving.
func TestRunKeepsServingAnUnknownRequest(t *testing.T) {
	var out strings.Builder
	err := Run(context.Background(), Options{
		In: strings.NewReader(
			"{\"type\":\"nonsense\",\"request_id\":\"r1\"}\n" +
				"{\"type\":\"shutdown\",\"request_id\":\"stop-1\"}\n"),
		Out: &out,
		Now: fixedClock(),
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	lines := strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n")
	if len(lines) != 5 {
		t.Fatalf("expected ready/received/error/received/stopped, got %d lines: %s", len(lines), out.String())
	}
	if !strings.Contains(lines[2], `"type":"error"`) || !strings.Contains(lines[2], "unknown request type") {
		t.Fatalf("third event should be the unknown-request error: %s", lines[2])
	}
}

// A malformed line still reports its length; it is not fatal and does not stop the host.
func TestRunAcknowledgesMalformedInput(t *testing.T) {
	var out strings.Builder
	err := Run(context.Background(), Options{
		In:  strings.NewReader("not json\n{\"type\":\"shutdown\",\"request_id\":\"s\"}\n"),
		Out: &out,
		Now: fixedClock(),
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(out.String(), `{"type":"received","request_id":"","bytes":8,`) {
		t.Fatalf("malformed line should be acknowledged with its length:\n%s", out.String())
	}
	if !strings.Contains(out.String(), `"reason":"invalid json"`) {
		t.Fatalf("malformed line should be reported:\n%s", out.String())
	}
	if !strings.Contains(out.String(), `"type":"stopped"`) {
		t.Fatalf("host should still stop on the following shutdown:\n%s", out.String())
	}
}

// End of input is a normal exit, not an error, and does not emit stopped.
func TestRunEndsAtEOF(t *testing.T) {
	var out strings.Builder
	if err := Run(context.Background(), Options{In: strings.NewReader(""), Out: &out, Now: fixedClock()}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if strings.Count(out.String(), "\n") != 1 || !strings.Contains(out.String(), `"type":"ready"`) {
		t.Fatalf("an empty stream should produce only ready:\n%s", out.String())
	}
}

// Timestamps keep exactly three fraction digits, including trailing zeros.
func TestStampKeepsThreeDigits(t *testing.T) {
	cases := map[string]string{
		"2026-10-31T20:23:04.81Z":   "2026-10-31T20:23:04.810Z",
		"2026-10-31T20:23:04.08Z":   "2026-10-31T20:23:04.080Z",
		"2026-10-31T20:23:04Z":      "2026-10-31T20:23:04.000Z",
		"2026-10-31T20:23:04.1234Z": "2026-10-31T20:23:04.123Z",
	}
	for in, want := range cases {
		parsed, err := time.Parse(time.RFC3339Nano, in)
		if err != nil {
			t.Fatalf("parse %s: %v", in, err)
		}
		if got := stamp(parsed); got != want {
			t.Fatalf("stamp(%s) = %s, want %s", in, got, want)
		}
	}
}

func TestValidShotID(t *testing.T) {
	ok := []string{"a", "shot-a", "gate-five-1", "A_1", "0"}
	bad := []string{"", "-lead", "_lead", "has space", "x/y", strings.Repeat("a", 65)}
	for _, id := range ok {
		if !validShotID(id) {
			t.Fatalf("%q should be valid", id)
		}
	}
	for _, id := range bad {
		if validShotID(id) {
			t.Fatalf("%q should be invalid", id)
		}
	}
}
