package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestFindRepoRootFromNestedDirectory(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "go"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "go", "go.mod"), []byte("module test\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "src", "tools")
	if err := os.MkdirAll(nested, 0o700); err != nil {
		t.Fatal(err)
	}
	got, err := findRepoRoot(nested)
	if err != nil || got != root {
		t.Fatalf("findRepoRoot(%q) = %q, %v; want %q", nested, got, err, root)
	}
}

func TestMeasurementShotTerminalWaitsPastAgentExitForTaste(t *testing.T) {
	for _, kind := range []string{"pulled", "taste_passed", "taste_failed", "incomplete", "session_failed"} {
		if !measurementShotTerminal(kind) {
			t.Fatalf("%s should end a Taste measurement", kind)
		}
	}
	for _, kind := range []string{"", "turn_done", "agent_exited", "needs_input", "usage", "ready"} {
		if measurementShotTerminal(kind) {
			t.Fatalf("%q should not end a Taste measurement", kind)
		}
	}
}

func TestMeasurementAgentScriptExitsAfterAgentEnd(t *testing.T) {
	cmd := exec.Command("sh", "-c", measurementAgentScript())
	cmd.Stdin = strings.NewReader("first prompt\nget_session_stats\n")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("fake agent did not exit after one prompt: %v", err)
	}
	for _, event := range []string{`"type":"message_start"`, `"type":"text_delta"`, `"type":"message_end"`, `"type":"agent_end"`} {
		if !strings.Contains(string(out), event) {
			t.Fatalf("fake agent did not emit %s: %s", event, out)
		}
	}
}

func TestShellQuotePreservesEmbeddedApostrophe(t *testing.T) {
	if got, want := shellQuote("/path/with space/it's"), "'/path/with space/it'\\''s'"; got != want {
		t.Fatalf("shellQuote() = %q, want %q", got, want)
	}
	if got, want := shellQuote(""), "''"; got != want {
		t.Fatalf("shellQuote(empty) = %q, want %q", got, want)
	}
}

func TestFindRepoRootFailsOutsideRepository(t *testing.T) {
	if _, err := findRepoRoot(t.TempDir()); err == nil {
		t.Fatal("expected an error when no repository root is present")
	}
}

// Negative timestamps must not crash the per-Shot derivation; a malformed `at` is a real
// shape a future event could produce.
func TestParseStampBadInput(t *testing.T) {
	if _, err := parseStamp("not-a-timestamp"); err == nil {
		t.Fatal("expected an error on a malformed timestamp")
	}
}

// terminalKind matches the contract's terminal set plus agent_exited.
func TestMeasurementShotTerminal(t *testing.T) {
	for _, kind := range []string{"pulled", "taste_passed", "taste_failed", "incomplete", "session_failed"} {
		if !measurementShotTerminal(kind) {
			t.Fatalf("%s should end the measurement Shot", kind)
		}
	}
	for _, kind := range []string{"", "turn_done", "agent_exited", "needs_input", "usage", "ready"} {
		if measurementShotTerminal(kind) {
			t.Fatalf("%q should not end the measurement Shot", kind)
		}
	}
}

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
