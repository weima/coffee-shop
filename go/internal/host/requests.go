package host

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"sync"

	"github.com/weima/coffee-shop/go/internal/proto"
	"github.com/weima/coffee-shop/go/internal/state"
)

// HOST_REPLY_MAX is the longest reply the socket accepts, matching the Odin host.
const HOST_REPLY_MAX = 4096

// requestServer is the address other processes reach this host at: <state>/host/requests.sock.
// It accepts exactly one request type, `reply`, with exactly its four fields, so nothing
// arriving here can name a repository, command, path or shell.
type requestServer struct {
	listener   net.Listener
	dispatcher *dispatcher
	w          *writer
	stopped    sync.Once
}

func listenRequests(root string, dispatch *dispatcher, w *writer) (*requestServer, error) {
	if err := state.EnsureDir(state.HostDir(root), true); err != nil {
		return nil, fmt.Errorf("create host directory: %w", err)
	}
	path := state.RequestsSocket(root)
	// The host lock proves a leftover socket cannot belong to a live host.
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("remove stale request socket: %w", err)
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("listen on %s: %w", path, err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		return nil, fmt.Errorf("restrict request socket: %w", err)
	}
	return &requestServer{listener: listener, dispatcher: dispatch, w: w}, nil
}

func (s *requestServer) start(ctx context.Context) {
	go func() {
		for {
			conn, err := s.listener.Accept()
			if err != nil {
				if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
					return
				}
				fmt.Fprintf(os.Stderr, "csd: requests: accept: %v\n", err)
				return
			}
			s.handle(conn)
			_ = conn.Close()
		}
	}()
}

func (s *requestServer) stop() {
	s.stopped.Do(func() { _ = s.listener.Close() })
}

// handle reads one request line and answers with one ack line.
func (s *requestServer) handle(conn net.Conn) {
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 4096), MaxPayload)
	if !scanner.Scan() {
		return
	}
	ack := s.answer(scanner.Text())
	data, err := proto.Line(ack)
	if err != nil {
		return
	}
	_, _ = conn.Write(data)
}

// answer validates the request and performs it, returning the ack to send.
func (s *requestServer) answer(line string) proto.Ack {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(line), &fields); err != nil {
		// Distinguish "not JSON at all" from "valid JSON but not an object", because the
		// caller's next move differs.
		var anyValue any
		if json.Unmarshal([]byte(line), &anyValue) == nil {
			return proto.Ack{Reason: "request must be an object"}
		}
		return proto.Ack{Reason: "invalid json"}
	}
	if raw, ok := fields["type"]; !ok {
		return proto.Ack{Reason: "the request socket accepts only reply requests"}
	} else {
		var kind string
		if json.Unmarshal(raw, &kind) != nil || kind != "reply" {
			return proto.Ack{Reason: "the request socket accepts only reply requests"}
		}
	}
	for key := range fields {
		switch key {
		case "type", "request_id", "shot_id", "message":
		default:
			return proto.Ack{Reason: fmt.Sprintf("unexpected field %q", key)}
		}
	}

	requestID := stringField(fields, "request_id")
	if !validShotID(requestID) {
		return proto.Ack{Reason: "request_id must be a valid shot-style identifier (letters, digits, - or _, up to 64)"}
	}
	shotID := stringField(fields, "shot_id")
	message := strings.TrimSpace(stringField(fields, "message"))
	if !validShotID(shotID) {
		return proto.Ack{Reason: "reply needs a valid shot_id"}
	}
	if message == "" || len(message) > HOST_REPLY_MAX || strings.ContainsAny(message, "\r\n") {
		return proto.Ack{Reason: "reply must be one non-empty line"}
	}

	if reason := s.dispatcher.reply(requestID, shotID, message); reason != "" {
		return proto.Ack{Reason: reason}
	}
	return proto.Ack{OK: true}
}

func stringField(root map[string]json.RawMessage, key string) string {
	raw, ok := root[key]
	if !ok {
		return ""
	}
	var value string
	if json.Unmarshal(raw, &value) != nil {
		return ""
	}
	return value
}

// reply delivers one line to a running Station's input. The Station decides whether it
// answers a pending dialog or becomes a follow-up prompt.
func (d *dispatcher) reply(requestID, shotID, message string) string {
	d.mu.Lock()
	run, ok := d.running[slotKey(requestID, shotID)]
	d.mu.Unlock()
	if !ok {
		reason := "no Station is running for that shot"
		d.w.emit(proto.Event{Type: "error", RequestID: requestID, ShotID: shotID, Reason: reason})
		return reason
	}
	if run.stdin == nil {
		reason := "the Station's input is closed"
		d.w.emit(proto.Event{Type: "error", RequestID: requestID, ShotID: shotID, Reason: reason})
		return reason
	}
	if _, err := fmt.Fprintf(run.stdin, "%s\n", message); err != nil {
		reason := fmt.Sprintf("could not send the reply: %v", err)
		d.w.emit(proto.Event{Type: "error", RequestID: requestID, ShotID: shotID, Reason: reason})
		return reason
	}
	d.w.emit(proto.Event{Type: "reply_sent", RequestID: requestID, ShotID: shotID})
	return ""
}
