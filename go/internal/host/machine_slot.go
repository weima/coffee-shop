package host

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"

	"github.com/weima/coffee-shop/go/internal/state"
)

// MachineLimitDir is the directory of slot files, shared with the Odin host so a Go host
// and an Odin Brew cannot together exceed the machine budget.
const MachineLimitDir = "machine-limit"

// machineSlot is one held slot: an exclusive advisory lock on slot-<n>.lock.
//
// The kernel drops the lock when the holder exits, however it exits, so no pid or
// timestamp decides whether a slot is free. This mirrors src/machine_limit.odin.
type machineSlot struct {
	file  *os.File
	index int
}

// tryAcquireMachineSlot takes the first free slot of limit, without waiting.
func tryAcquireMachineSlot(root string, limit int) (machineSlot, string, bool) {
	if root == "" {
		return machineSlot{}, "", true // no state root: the per-host limit is all there is
	}
	dir := filepath.Join(root, MachineLimitDir)
	if err := state.EnsureDir(dir, true); err != nil {
		return machineSlot{}, fmt.Sprintf("machine limit: cannot create %s", dir), false
	}
	for index := 0; index < limit; index++ {
		if slot, taken := tryMachineSlotFile(dir, index); taken {
			return slot, "", true
		}
	}
	return machineSlot{}, fmt.Sprintf("machine limit: all %d slots are in use by other Brews or Stations", limit), false
}

func tryMachineSlotFile(dir string, index int) (machineSlot, bool) {
	path := filepath.Join(dir, fmt.Sprintf("slot-%d.lock", index))
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return machineSlot{}, false
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = file.Close()
		return machineSlot{}, false
	}
	return machineSlot{file: file, index: index}, true
}

// release drops the lock and closes the file.
func (s *machineSlot) release() {
	if s.file == nil {
		return
	}
	_ = syscall.Flock(int(s.file.Fd()), syscall.LOCK_UN)
	_ = s.file.Close()
	s.file = nil
}

// machineSlots holds every slot this host owns, so a Shot's release returns exactly its
// own slot and shutdown returns the rest.
type machineSlots struct {
	mu    sync.Mutex
	root  string
	limit int
	held  map[string]machineSlot
}

func newMachineSlots(root string, limit int) *machineSlots {
	return &machineSlots{root: root, limit: limit, held: make(map[string]machineSlot)}
}

// acquire takes a machine slot for a Shot, reporting why when the machine is full.
func (m *machineSlots) acquire(requestID, shotID string) (reason string, ok bool) {
	key := slotKey(requestID, shotID)
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, already := m.held[key]; already {
		return "", true
	}
	slot, reason, ok := tryAcquireMachineSlot(m.root, m.limit)
	if !ok {
		return reason, false
	}
	if slot.file != nil {
		m.held[key] = slot
	}
	return "", true
}

func (m *machineSlots) release(requestID, shotID string) {
	key := slotKey(requestID, shotID)
	m.mu.Lock()
	defer m.mu.Unlock()
	if slot, ok := m.held[key]; ok {
		slot.release()
		delete(m.held, key)
	}
}

// releaseAll frees everything this host holds, for shutdown.
func (m *machineSlots) releaseAll() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for key, slot := range m.held {
		slot.release()
		delete(m.held, key)
	}
}
