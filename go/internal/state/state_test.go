package state

import (
	"path/filepath"
	"testing"
)

// The paths are a contract with the Odin host and the CLI, so pin them literally.
func TestPathsMatchTheContract(t *testing.T) {
	root := "/state"
	cases := map[string]string{
		ActivitySocket(root):            "/state/host/activity.sock",
		RequestsSocket(root):            "/state/host/requests.sock",
		SpoolDir(root):                  "/state/host/spool",
		ReportsDir(root):                "/state/host/reports",
		HistoryPath(root, "req-1"):      "/state/host/req-1/history.ndjson",
		PromptPath(root, "req-1", "s1"): "/state/host/req-1/prompts/s1.md",
		StationDir(root, "req-1", "s1"): "/state/host/req-1/stations/s1",
		LogPath(root, "req-1", "s1"):    "/state/host/req-1/logs/s1.log",
		HostDir(root):                   "/state/host",
	}
	for got, want := range cases {
		if got != filepath.Clean(want) {
			t.Fatalf("path %q, want %q", got, want)
		}
	}
}

// A relative CS_STATE_DIR is refused, as the Odin implementation refuses it.
func TestRootRejectsARelativeStateDir(t *testing.T) {
	t.Setenv(EnvRoot, "relative/state")
	if _, err := Root(); err == nil {
		t.Fatal("a relative state root must be an error")
	}
}

func TestRootUsesTheEnvironment(t *testing.T) {
	t.Setenv(EnvRoot, "/tmp/cs-state")
	root, err := Root()
	if err != nil {
		t.Fatalf("Root: %v", err)
	}
	if root != "/tmp/cs-state" {
		t.Fatalf("root %q, want /tmp/cs-state", root)
	}
}
