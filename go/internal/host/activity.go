package host

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/weima/coffee-shop/go/internal/proto"
	"github.com/weima/coffee-shop/go/internal/state"
)

// Activity limits, from the Odin contract (src/activity_socket.odin).
const (
	MaxPayload     = 2048
	MaxID          = 64
	MaxKind        = 64
	MaxDescription = 1024
)

// StationPIDKind is the report a Station sends about itself. It is recorded, not
// relayed: it is plumbing for a cancel, not a user-facing report.
const StationPIDKind = "station_pid"

// ActivityReports is the buffer between Stations and the relay. A Station writes and
// leaves; the relay owns ordering, history and stdout, so one slow write cannot stall an
// accept loop and two reports can never interleave on stdout.
const ActivityReports = 64

// activityServer receives Station reports over the activity socket.
//
// One goroutine accepts connections and one reads each connection; a single relay
// goroutine owns the writer. Nothing here writes stdout except the relay, which is what
// keeps event lines whole.
type activityServer struct {
	listener net.Listener
	root     string
	reports  chan proto.Message
	readers  sync.WaitGroup
	relayed  chan struct{}
	stopped  sync.Once
}

// listenActivity binds <state>/host/activity.sock. The host directory is made private
// and the socket is 0600, because a report can carry a model's output.
func listenActivity(root string, w *writer) (*activityServer, error) {
	if err := state.EnsureDir(state.HostDir(root), true); err != nil {
		return nil, fmt.Errorf("create host directory: %w", err)
	}
	path := state.ActivitySocket(root)
	// A host that was killed leaves its socket behind, and bind would refuse it. The
	// host lock proves a leftover socket cannot belong to a live host.
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("remove stale socket: %w", err)
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("listen on %s: %w", path, err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		return nil, fmt.Errorf("restrict socket: %w", err)
	}
	return &activityServer{
		listener: listener,
		root:     root,
		reports:  make(chan proto.Message, ActivityReports),
		relayed:  make(chan struct{}),
	}, nil
}

// start begins relaying and accepting. Run must call stop when it is done.
func (s *activityServer) start(ctx context.Context, w *writer) {
	// The relay is the only writer of reports: it applies the history-then-stdout-then-
	// spool rule in order, one report at a time.
	go func() {
		defer close(s.relayed)
		for message := range s.reports {
			w.relayReport(message)
			s.removeSpool(message)
		}
	}()

	go func() {
		for {
			conn, err := s.listener.Accept()
			if err != nil {
				// Closing the listener is how this server stops, so it is not a failure.
				if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
					break
				}
				fmt.Fprintf(os.Stderr, "csd: activity: accept: %v\n", err)
				break
			}
			s.readers.Add(1)
			go s.readConn(ctx, conn)
		}
		// Readers must finish before the channel closes, or a send races the close.
		s.readers.Wait()
		close(s.reports)
	}()
}

// stop closes the listener and waits for every in-flight report to be relayed.
func (s *activityServer) stop() {
	s.stopped.Do(func() {
		_ = s.listener.Close()
		<-s.relayed
	})
}

// readConn reads reports until the Station closes the connection. A Station keeps one
// connection for its whole life, so reading a single line would strand every later
// report; an invalid report is dropped and the connection stays usable, because a
// Station is best-effort and a bad report must never end the host.
func (s *activityServer) readConn(ctx context.Context, conn net.Conn) {
	defer s.readers.Done()
	defer func() { _ = conn.Close() }()

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 4096), MaxPayload)
	for scanner.Scan() {
		message, ok := decodeMessage(scanner.Text())
		if !ok {
			continue
		}
		select {
		case s.reports <- message:
		case <-ctx.Done():
			return
		}
	}
}

// removeSpool drops the durable copy once the report has been relayed.
func (s *activityServer) removeSpool(message proto.Message) {
	if message.Spool == "" {
		return
	}
	_ = os.Remove(filepath.Join(state.SpoolDir(s.root), message.Spool))
}

// ReplaySpool relays every report a previous host spooled but never announced, oldest
// first. It runs before the listener starts serving, so it cannot race a live report.
func ReplaySpool(root string, w *writer) int {
	dir := state.SpoolDir(root)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		names = append(names, entry.Name())
	}
	sort.Strings(names)

	relayed := 0
	for _, name := range names {
		data, readErr := os.ReadFile(filepath.Join(dir, name))
		if readErr != nil {
			continue
		}
		message, ok := decodeMessage(string(data))
		if !ok {
			continue // unreadable stays on disk for inspection
		}
		message.Spool = name
		w.relayReport(message)
		_ = os.Remove(filepath.Join(dir, name))
		relayed++
	}
	return relayed
}

// decodeMessage parses and validates one report.
func decodeMessage(line string) (proto.Message, bool) {
	var message proto.Message
	if err := json.Unmarshal([]byte(line), &message); err != nil {
		return proto.Message{}, false
	}
	if !validShotID(message.BrewID) || !validShotID(message.ShotID) {
		return proto.Message{}, false
	}
	if message.Kind == "" || len(message.Kind) > MaxKind {
		return proto.Message{}, false
	}
	if message.Description == "" || len(message.Description) > MaxDescription {
		return proto.Message{}, false
	}
	if message.TimestampNS <= 0 {
		return proto.Message{}, false
	}
	if len(message.Spool) > MaxID*2 || strings.ContainsAny(message.Spool, `/\`) || message.Spool == ".." {
		return proto.Message{}, false
	}
	return message, true
}

// reportText keeps a "file:<path>" reference as-is and trims anything else.
func reportText(description string) string {
	if strings.HasPrefix(description, "file:") {
		return description
	}
	return strings.TrimSpace(description)
}
