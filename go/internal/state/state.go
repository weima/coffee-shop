// Package state owns the on-disk layout the host and its consumers share.
//
// These paths are part of the contract: the Odin host writes them today, `status`,
// `log` and `reply` read them, and `csd` must not move them. Everything is rooted at
// CS_STATE_DIR when set, else ~/.coffee-shop.
package state

import (
	"fmt"
	"os"
	"path/filepath"
)

// EnvRoot is the variable that overrides the default state root.
const EnvRoot = "CS_STATE_DIR"

// Root resolves the state root. The Odin implementation refuses a relative
// CS_STATE_DIR, so this does too: a relative root would silently differ per process.
func Root() (string, error) {
	if root := os.Getenv(EnvRoot); root != "" {
		if !filepath.IsAbs(root) {
			return "", fmt.Errorf("%s must be an absolute path", EnvRoot)
		}
		return filepath.Clean(root), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}
	return filepath.Join(home, ".coffee-shop"), nil
}

// HostDir is where every host-owned artifact lives.
func HostDir(root string) string { return filepath.Join(root, "host") }

// ActivitySocket is the socket Stations report to.
func ActivitySocket(root string) string { return filepath.Join(HostDir(root), "activity.sock") }

// RequestsSocket is the socket a separate process sends one request to.
func RequestsSocket(root string) string { return filepath.Join(HostDir(root), "requests.sock") }

// SpoolDir holds reports written before they are relayed.
func SpoolDir(root string) string { return filepath.Join(HostDir(root), "spool") }

// RequestDir is one dispatch's directory: prompts, stations, logs, history.
func RequestDir(root, requestID string) string {
	return filepath.Join(HostDir(root), requestID)
}

// HistoryPath is the append-only event record for one request.
func HistoryPath(root, requestID string) string {
	return filepath.Join(RequestDir(root, requestID), "history.ndjson")
}

// PromptPath is where a Shot's prompt is written for the Station to read.
func PromptPath(root, requestID, shotID string) string {
	return filepath.Join(RequestDir(root, requestID), "prompts", shotID+".md")
}

// StationDir is the Shot's Git worktree.
func StationDir(root, requestID, shotID string) string {
	return filepath.Join(RequestDir(root, requestID), "stations", shotID)
}

// LogPath is the Shot's bounded Station log.
func LogPath(root, requestID, shotID string) string {
	return filepath.Join(RequestDir(root, requestID), "logs", shotID+".log")
}

// ReportsDir holds long report bodies, referenced on the wire as "file:<path>".
func ReportsDir(root string) string { return filepath.Join(HostDir(root), "reports") }

// EnsureDir creates a directory and, when private is set, restricts it to the owner.
// The host directory holds two sockets and a lock, so it is always private.
func EnsureDir(path string, private bool) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	if private {
		// MkdirAll does not change an existing directory's mode, and an older install
		// may have left it wider open.
		return os.Chmod(path, 0o700)
	}
	return nil
}
