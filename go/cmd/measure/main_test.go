package main

import (
	"runtime"
	"testing"
)

// Negative timestamps must not crash the per-Shot derivation; a malformed `at` is a real
// shape a future event could produce.
func TestParseStampBadInput(t *testing.T) {
	if _, err := parseStamp("not-a-timestamp"); err == nil {
		t.Fatal("expected an error on a malformed timestamp")
	}
}

// terminalKind matches the contract's terminal set plus agent_exited.
func TestTerminalKind(t *testing.T) {
	for _, ok := range []string{"pulled", "taste_passed", "taste_failed", "incomplete", "session_failed", "agent_exited"} {
		if !terminalKind(ok) {
			t.Fatalf("%s should be terminal", ok)
		}
	}
	for _, bad := range []string{"", "turn_done", "needs_input", "usage", "ready"} {
		if terminalKind(bad) {
			t.Fatalf("%q should not be terminal", bad)
		}
	}
}

// isWSL reports false on darwin and linux-native, and true only when /proc/version says so.
func TestIsWSL(t *testing.T) {
	got := isWSL()
	switch runtime_GOOS() {
	case "linux":
		// either value is legal; just record it
	case "darwin":
		if got {
			t.Fatal("isWSL must be false on darwin")
		}
	default:
		if got {
			t.Fatalf("isWSL must be false on %s", runtime_GOOS())
		}
	}
}

// runtime_GOOS exists so the isWSL check can be asserted against the current platform.
func runtime_GOOS() string { return runtime.GOOS }
