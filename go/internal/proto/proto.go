// Package proto is the wire contract between Coffee Shop's host and everything that
// talks to it: the Barista's request stream, Station reports, and the reply socket.
//
// Field order matters. Every type here declares fields in the order the Odin
// implementation marshals them, and `at` is always last, because a conformance test
// compares events byte for byte after normalizing only the timestamp value.
package proto

import (
	"encoding/json"
	"fmt"
	"strings"
)

// Event is one line on the host's stdout (Host_Event in src/host.odin).
//
// Bytes is a pointer because the Odin type is a union that is absent unless set, and
// encoding/json's omitempty cannot tell a legitimate zero from an absent field.
type Event struct {
	Type        string `json:"type"`
	RequestID   string `json:"request_id"`
	Bytes       *int   `json:"bytes,omitempty"`
	ShotID      string `json:"shot_id,omitempty"`
	PaneID      string `json:"pane_id,omitempty"`
	Kind        string `json:"kind,omitempty"`
	Description string `json:"description,omitempty"`
	Reason      string `json:"reason,omitempty"`
	Branch      string `json:"branch,omitempty"`
	Commit      string `json:"commit,omitempty"`
	At          string `json:"at"`
}

// Message is one Station report over the activity socket (Activity_Message).
type Message struct {
	BrewID      string `json:"brew_id"`
	ShotID      string `json:"shot_id"`
	Kind        string `json:"kind"`
	Description string `json:"description"`
	TimestampNS int64  `json:"timestamp_ns"`
	Spool       string `json:"spool,omitempty"`
}

// Request is one line the host reads on stdin, and one line the reply socket accepts.
// Only Type, RequestID, ShotID and Message are recognised for a reply; a dispatch
// request carries a repo and a recipe, which this type deliberately does not model.
type Request struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	ShotID    string `json:"shot_id"`
	Message   string `json:"message"`
}

// Ack is the host's answer to one reply-socket request.
type Ack struct {
	OK     bool   `json:"ok"`
	Reason string `json:"reason,omitempty"`
}

// EventLine encodes one event as the single line the host writes, newline included.
func EventLine(e Event) ([]byte, error) {
	raw, err := json.Marshal(e)
	if err != nil {
		return nil, fmt.Errorf("encode event: %w", err)
	}
	return append(raw, '\n'), nil
}

// DecodeEvent parses one event line, tolerating a trailing newline.
func DecodeEvent(line []byte) (Event, error) {
	var e Event
	if err := json.Unmarshal(line, &e); err != nil {
		return Event{}, fmt.Errorf("decode event: %w", err)
	}
	return e, nil
}

// Line encodes one value as a newline-terminated JSON line.
func Line(v any) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, fmt.Errorf("encode line: %w", err)
	}
	return append(raw, '\n'), nil
}

// TimestampLen is the exact length of the `at` value: RFC 3339 UTC with three
// fraction digits, e.g. 2026-10-31T19:20:01.123Z.
const TimestampLen = len("2026-10-31T19:20:01.123Z")

// TimestampKey is the key that carries that value.
const TimestampKey = `"at":"`

// NormalizeTimestamp replaces every `at` value with "AT", so two runs of the same
// request stream can be compared. The fixed shape (digits, T, dots, Z) is what makes a
// plain search safe here: a quote inside a JSON string is escaped as \", which cannot
// match the key pattern.
func NormalizeTimestamp(line string) string {
	var b strings.Builder
	rest := line
	for {
		i := strings.Index(rest, TimestampKey)
		if i < 0 {
			b.WriteString(rest)
			return b.String()
		}
		valueStart := i + len(TimestampKey)
		if valueStart+TimestampLen > len(rest) || !isTimestampValue(rest[valueStart:valueStart+TimestampLen]) {
			// Not a timestamp we wrote; copy through and keep looking after the key.
			b.WriteString(rest[:valueStart])
			rest = rest[valueStart:]
			continue
		}
		b.WriteString(rest[:valueStart])
		b.WriteString("AT")
		rest = rest[valueStart+TimestampLen:]
	}
}

func isTimestampValue(v string) bool {
	if len(v) != TimestampLen || v[4] != '-' || v[7] != '-' || v[10] != 'T' ||
		v[13] != ':' || v[16] != ':' || v[19] != '.' || v[23] != 'Z' {
		return false
	}
	for i, c := range []byte(v) {
		switch i {
		case 4, 7, 10, 13, 16, 19, 23:
			continue
		}
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
