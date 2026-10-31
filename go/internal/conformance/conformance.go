// Package conformance is the black-box contract test for a Coffee Shop host.
//
// It feeds a request stream to a host process and compares the events it writes on
// stdout. Only the timestamp value is normalized, so a difference in any other field,
// in field order, or in the number and order of events is a failure. Anything that
// claims to implement the host — the Odin implementation today, `csd` next — is tested
// by the same code.
package conformance

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"

	"github.com/weima/coffee-shop/go/internal/proto"
)

// ReadLines splits a host's stdout into lines and normalizes each timestamp.
func ReadLines(r io.Reader) ([]string, error) {
	raw, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("read host output: %w", err)
	}
	return SplitLines(string(raw)), nil
}

// SplitLines normalizes a captured event stream.
func SplitLines(stream string) []string {
	trimmed := strings.TrimSuffix(stream, "\n")
	if trimmed == "" {
		return nil
	}
	lines := strings.Split(trimmed, "\n")
	for i, line := range lines {
		lines[i] = proto.NormalizeTimestamp(line)
	}
	return lines
}

// Compare reports the first difference between a host's events and the expected stream.
func Compare(got, want []string) error {
	for i := 0; i < len(got) && i < len(want); i++ {
		if got[i] != want[i] {
			return fmt.Errorf("event %d differs\n got: %s\nwant: %s", i, got[i], want[i])
		}
	}
	if len(got) != len(want) {
		return fmt.Errorf("event count differs: got %d, want %d", len(got), len(want))
	}
	return nil
}

// HostRun is everything needed to run one host under test.
type HostRun struct {
	// Argv is the command, already split: no shell, so nothing needs quoting.
	Argv []string
	// Dir is the working directory; it must contain the package to build or run.
	Dir string
	// Env is the full environment, in os/exec's KEY=value form.
	Env []string
	// Requests is the request stream written to stdin, ending with a shutdown line.
	Requests string
	// KeepStdinOpen leaves stdin open after the stream is written, for a host that
	// ignores its own shutdown; the caller must then rely on the context deadline.
	KeepStdinOpen bool
}

// Result is a finished run: normalized events, and the host's raw stderr.
type Result struct {
	Events []string
	Stderr string
}

// Run executes one host and returns its normalized event stream.
//
// The command must compile or run the current source (for example
// `odin run src -- host`, or a binary built by the same invocation), because this
// repository does not run previously built binaries.
func Run(ctx context.Context, run HostRun) (Result, error) {
	cmd := exec.CommandContext(ctx, run.Argv[0], run.Argv[1:]...)
	cmd.Dir = run.Dir
	cmd.Env = run.Env

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return Result{}, fmt.Errorf("host stdin: %w", err)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		return Result{}, fmt.Errorf("start host: %w", err)
	}
	_, writeErr := io.WriteString(stdin, run.Requests)
	if !run.KeepStdinOpen {
		_ = stdin.Close()
	}
	waitErr := cmd.Wait()
	_ = stdin.Close()

	result := Result{Events: SplitLines(stdout.String()), Stderr: stderr.String()}
	if waitErr != nil && !run.KeepStdinOpen {
		return result, fmt.Errorf("host failed: %w\nstderr: %s", waitErr, tail(result.Stderr, 2000))
	}
	if writeErr != nil && !errors.Is(writeErr, io.ErrClosedPipe) {
		return result, fmt.Errorf("write requests: %w", writeErr)
	}
	return result, nil
}

// Expected loads a recorded stream as the expected event list.
func Expected(stream string) []string { return SplitLines(stream) }

func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return "…" + s[len(s)-n:]
}
