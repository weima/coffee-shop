package host

// A Blend request is the one piece of host work that stays in Odin: it builds a single
// commit from 2 to 20 Pull commits. The host validates nothing about it and instead hands
// the request to the Odin CLI as a file, then relays the events that command prints, so
// the wire shape is the same one the host emits itself.
//
// The file, not argv, keeps the request text away from any shell.

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/weima/coffee-shop/go/internal/proto"
	"github.com/weima/coffee-shop/go/internal/state"
)

// blendRequestFile is where the request waits for the seam, under this request's state.
const blendRequestFile = "blend-request.json"

// blend runs one Blend request through the seam and relays its events. A request the seam
// rejects produces its own `error` event; a seam that fails without one is reported with
// its reason, so a caller always learns why nothing was blended.
func (d *dispatcher) blend(requestID string, raw json.RawMessage) {
	dir := state.RequestDir(d.root, requestID)
	if err := state.EnsureDir(dir, true); err != nil {
		d.w.emit(proto.Event{Type: "error", RequestID: requestID, Reason: "could not prepare the blend request: " + err.Error()})
		return
	}
	path := filepath.Join(dir, blendRequestFile)
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		d.w.emit(proto.Event{Type: "error", RequestID: requestID, Reason: "could not write the blend request: " + err.Error()})
		return
	}

	argv := append(append([]string{}, d.cli...), "blend", "--request", path)
	cmd := exec.CommandContext(context.Background(), argv[0], argv[1:]...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, runErr := cmd.Output()

	relayed := 0
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		var event proto.Event
		if json.Unmarshal([]byte(line), &event) != nil || event.Type == "" {
			continue
		}
		if d.w.emit(event) == nil {
			relayed++
		}
	}
	if relayed > 0 {
		return
	}
	reason := "the blend command failed"
	if runErr == nil {
		reason = "the blend command printed no event"
	}
	if detail := strings.TrimSpace(stderr.String()); detail != "" {
		reason = detail
	}
	d.w.emit(proto.Event{Type: "error", RequestID: requestID, Reason: reason})
}
