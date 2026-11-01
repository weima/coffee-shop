package host

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"

	"github.com/weima/coffee-shop/go/internal/state"
)

// HostLockFile is the lock the host holds while it runs. `coffee-shop status --stations`
// and `reply` use it to tell a running host from a dead one, and a second host refuses to
// start while it is held.
const HostLockFile = "host.lock"

// hostLock is an exclusive advisory lock on <state>/host/host.lock.
type hostLock struct {
	file *os.File
}

// acquireHostLock takes the lock without waiting. A second host must not start: two hosts
// on one state root would double-dispatch and interleave history.
func acquireHostLock(root string) (*hostLock, error) {
	if err := state.EnsureDir(state.HostDir(root), true); err != nil {
		return nil, fmt.Errorf("create host directory: %w", err)
	}
	path := filepath.Join(state.HostDir(root), HostLockFile)
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open host lock: %w", err)
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("another host is already running")
	}
	return &hostLock{file: file}, nil
}

func (l *hostLock) release() {
	if l == nil || l.file == nil {
		return
	}
	_ = syscall.Flock(int(l.file.Fd()), syscall.LOCK_UN)
	_ = l.file.Close()
	l.file = nil
}
