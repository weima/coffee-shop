package proto

import (
	"encoding/json"
	"testing"
)

// The event line's field order is part of the contract: consumers read the first keys
// and the timestamp is appended last so existing fields keep their positions.
func TestEventLineKeepsContractFieldOrder(t *testing.T) {
	zero := 0
	line, err := EventLine(Event{
		Type:        "station_report",
		RequestID:   "gate-five-1",
		Bytes:       &zero,
		ShotID:      "gate-s1",
		PaneID:      "gate-five-1/gate-s1",
		Kind:        "taste_passed",
		Description: "Taste passed with no changes",
		Reason:      "because",
		Branch:      "b",
		Commit:      "abc1234",
		At:          "2026-10-31T20:23:04.406Z",
	})
	if err != nil {
		t.Fatalf("EventLine: %v", err)
	}
	want := `{"type":"station_report","request_id":"gate-five-1","bytes":0,"shot_id":"gate-s1",` +
		`"pane_id":"gate-five-1/gate-s1","kind":"taste_passed",` +
		`"description":"Taste passed with no changes","reason":"because","branch":"b",` +
		`"commit":"abc1234","at":"2026-10-31T20:23:04.406Z"}` + "\n"
	if string(line) != want {
		t.Fatalf("event line mismatch\n got: %s\nwant: %s", line, want)
	}
}

// A zero byte count is a real value and must not be dropped; an absent one must be.
func TestEventOmitsAbsentFieldsButKeepsZeroBytes(t *testing.T) {
	zero := 0
	with, err := EventLine(Event{Type: "received", RequestID: "r", Bytes: &zero, At: "2026-10-31T20:23:04.406Z"})
	if err != nil {
		t.Fatalf("EventLine: %v", err)
	}
	want := `{"type":"received","request_id":"r","bytes":0,"at":"2026-10-31T20:23:04.406Z"}` + "\n"
	if string(with) != want {
		t.Fatalf("zero bytes line\n got: %s\nwant: %s", with, want)
	}

	plain, err := EventLine(Event{Type: "ready", RequestID: "", At: "2026-10-31T20:23:04.406Z"})
	if err != nil {
		t.Fatalf("EventLine: %v", err)
	}
	// request_id has no omitempty in the contract, so it is present even when empty.
	if got, want := string(plain), `{"type":"ready","request_id":"","at":"2026-10-31T20:23:04.406Z"}`+"\n"; got != want {
		t.Fatalf("plain line\n got: %s\nwant: %s", got, want)
	}
}

// These lines were captured from the real Odin host during the v0.5 headless gate, so
// decoding them is evidence about the contract rather than about this package.
func TestDecodeRecordedHostEvents(t *testing.T) {
	lines := []string{
		`{"type":"ready","protocol":1,"at":"2026-10-31T20:23:04.406Z"}`,
		`{"type":"received","request_id":"gate-five-20261031-202303-346","bytes":1203,"at":"2026-10-31T20:23:04.407Z"}`,
		`{"type":"dispatch_accepted","request_id":"gate-five-20261031-202303-346","at":"2026-10-31T20:23:04.419Z"}`,
		`{"type":"dispatch_queued","request_id":"gate-five-20261031-202303-346","shot_id":"gate-s6","at":"2026-10-31T20:23:04.820Z"}`,
		`{"type":"session_started","request_id":"gate-five-20261031-202303-346","shot_id":"gate-s1","pane_id":"gate-five-20261031-202303-346/gate-s1","at":"2026-10-31T20:23:04.475Z"}`,
		`{"type":"station_report","request_id":"gate-five-20261031-202303-346","shot_id":"gate-s2","kind":"turned","description":"x","at":"2026-10-31T20:23:20.038Z"}`,
		`{"type":"reply_sent","request_id":"gate-reply-20261031-202509","shot_id":"ask-s1","at":"2026-10-31T20:25:22.322Z"}`,
		`{"type":"stopped","request_id":"stop-1","at":"2026-10-31T20:25:32.019Z"}`,
	}
	for _, line := range lines {
		e, err := DecodeEvent([]byte(line))
		if err != nil {
			t.Fatalf("decode %s: %v", line, err)
		}
		if e.Type == "" || e.At == "" {
			t.Fatalf("decoded an empty type or timestamp: %+v", e)
		}
		if !isTimestampValue(e.At) {
			t.Fatalf("timestamp %q is not the contract shape", e.At)
		}
	}
}

// A reply request line must match what the Odin CLI prints for `reply --print`.
func TestRequestLineMatchesReplyRequest(t *testing.T) {
	line, err := Line(Request{Type: "reply", RequestID: "req-1", ShotID: "shot-a", Message: "hello"})
	if err != nil {
		t.Fatalf("Line: %v", err)
	}
	want := `{"type":"reply","request_id":"req-1","shot_id":"shot-a","message":"hello"}` + "\n"
	if string(line) != want {
		t.Fatalf("request line\n got: %s\nwant: %s", line, want)
	}
}

func TestAckShape(t *testing.T) {
	ok, err := Line(Ack{OK: true})
	if err != nil {
		t.Fatalf("Line: %v", err)
	}
	if got, want := string(ok), `{"ok":true}`+"\n"; got != want {
		t.Fatalf("ok ack\n got: %s\nwant: %s", got, want)
	}
	refused, err := Line(Ack{OK: false, Reason: "no Station is running for that shot"})
	if err != nil {
		t.Fatalf("Line: %v", err)
	}
	want := `{"ok":false,"reason":"no Station is running for that shot"}` + "\n"
	if string(refused) != want {
		t.Fatalf("refused ack\n got: %s\nwant: %s", refused, want)
	}
}

// A spooled report is an Activity_Message; its field order is the durable format.
func TestMessageSpoolShape(t *testing.T) {
	line, err := Line(Message{
		BrewID:      "order-1",
		ShotID:      "shot-a",
		Kind:        "turn_done",
		Description: "pending shot-a",
		TimestampNS: 1,
		Spool:       "0001-a.json",
	})
	if err != nil {
		t.Fatalf("Line: %v", err)
	}
	want := `{"brew_id":"order-1","shot_id":"shot-a","kind":"turn_done","description":"pending shot-a","timestamp_ns":1,"spool":"0001-a.json"}` + "\n"
	if string(line) != want {
		t.Fatalf("spool line\n got: %s\nwant: %s", line, want)
	}
	if _, err := json.Marshal(Message{}); err != nil {
		t.Fatalf("marshal empty message: %v", err)
	}
}

// Only the timestamp value is normalized: a quote inside a string is escaped, so it
// cannot look like the key, and a shorter or malformed value is left alone.
func TestNormalizeTimestampTouchesOnlyRealTimestamps(t *testing.T) {
	cases := []struct{ in, want string }{
		{
			`{"type":"ready","protocol":1,"at":"2026-10-31T20:23:04.406Z"}`,
			`{"type":"ready","protocol":1,"at":"AT"}`,
		},
		{
			`{"type":"x","at":"not-a-timestamp"}`,
			`{"type":"x","at":"not-a-timestamp"}`,
		},
		{
			`{"type":"x","description":"says \"at\":\"inside\"","at":"2026-10-31T20:23:04.406Z"}`,
			`{"type":"x","description":"says \"at\":\"inside\"","at":"AT"}`,
		},
		{
			`{"type":"sessions","sessions":[{"type":"a","at":"2026-10-31T20:23:04.406Z"}],"at":"2026-10-31T20:23:05.000Z"}`,
			`{"type":"sessions","sessions":[{"type":"a","at":"AT"}],"at":"AT"}`,
		},
	}
	for _, c := range cases {
		if got := NormalizeTimestamp(c.in); got != c.want {
			t.Fatalf("normalize\n in: %s\ngot: %s\nwant: %s", c.in, got, c.want)
		}
		if twice := NormalizeTimestamp(NormalizeTimestamp(c.in)); twice != c.want {
			t.Fatalf("normalize is not idempotent: %s", twice)
		}
	}
}
