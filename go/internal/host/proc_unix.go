//go:build unix

package host

import (
	"os/exec"
	"syscall"
	"time"
)

// waitDelay bounds how long Wait blocks on a child that inherited a pipe.
const waitDelay = 2 * time.Second

// setProcessGroup puts the Station in its own process group so a cancel can reach the
// agent it started, not just the Station.
func setProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// killProcessGroup signals the Station's whole group.
func killProcessGroup(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return nil
	}
	return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
}

// killProcessGroupHard is the escalation for a Station that ignored SIGTERM.
func killProcessGroupHard(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return nil
	}
	return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
}
