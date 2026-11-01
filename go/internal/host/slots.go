package host

import "sync"

// SlotCapacity is the per-host concurrency limit, matching the Odin host's five.
const SlotCapacity = 5

// slots bounds how many Stations run at once. A Shot that finds no slot waits in the
// queue rather than failing: the host starts it when a slot frees.
//
// Two limits apply, and both must be taken: the per-host count and one machine-wide slot
// from <state root>/machine-limit, which the Odin host and its Brews also hold. Taking
// only the first would let two hosts exceed the budget together.
type slots struct {
	mu      sync.Mutex
	held    map[string]struct{}
	limit   int
	machine *machineSlots
}

func newSlots(limit int) *slots {
	if limit <= 0 {
		limit = SlotCapacity
	}
	return &slots{held: make(map[string]struct{}), limit: limit, machine: newMachineSlots("", limit)}
}

// withMachineLimit joins the machine-wide budget under a state root.
func (s *slots) withMachineLimit(root string) *slots {
	s.machine = newMachineSlots(root, s.limit)
	return s
}

// refusal is the last reason a machine slot could not be taken, for a queued Shot's log.
func (s *slots) releaseAll() { s.machine.releaseAll() }

func slotKey(requestID, shotID string) string { return requestID + "/" + shotID }

// acquire takes a slot for a Shot, reporting false when the host or the machine is full.
func (s *slots) acquire(requestID, shotID string) bool {
	_, ok := s.acquireWithReason(requestID, shotID)
	return ok
}

// acquireWithReason is acquire with the machine's explanation, so a refusal can say why.
func (s *slots) acquireWithReason(requestID, shotID string) (reason string, ok bool) {
	s.mu.Lock()
	key := slotKey(requestID, shotID)
	if _, held := s.held[key]; held {
		s.mu.Unlock()
		return "", true
	}
	if len(s.held) >= s.limit {
		s.mu.Unlock()
		return "", false
	}
	s.held[key] = struct{}{}
	s.mu.Unlock()

	// The machine slot is taken outside the lock: it is a syscall, and a slow filesystem
	// must not serialize every other Slot decision.
	reason, machineOK := s.machine.acquire(requestID, shotID)
	if !machineOK {
		s.mu.Lock()
		delete(s.held, key)
		s.mu.Unlock()
		return reason, false
	}
	return "", true
}

// release frees a Shot's slot. It reports whether the Shot held one, so a double release
// (a terminal report and a process exit) cannot free someone else's slot.
func (s *slots) release(requestID, shotID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := slotKey(requestID, shotID)
	if _, ok := s.held[key]; !ok {
		return false
	}
	delete(s.held, key)
	s.machine.release(requestID, shotID)
	return true
}

func (s *slots) inUse() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.held)
}
