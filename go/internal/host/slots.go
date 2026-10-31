package host

import "sync"

// SlotCapacity is the per-host concurrency limit, matching the Odin host's five.
const SlotCapacity = 5

// slots bounds how many Stations run at once. A Shot that finds no slot waits in the
// queue rather than failing: the host starts it when a slot frees.
//
// This is the per-host limit only. The machine-wide limit the Odin host shares through
// <state>/machine-limit slot files is not implemented yet, so two Go hosts could exceed
// the budget together; that is recorded in PLAN.md as the remaining parity gap.
type slots struct {
	mu    sync.Mutex
	held  map[string]struct{}
	limit int
}

func newSlots(limit int) *slots {
	if limit <= 0 {
		limit = SlotCapacity
	}
	return &slots{held: make(map[string]struct{}), limit: limit}
}

func slotKey(requestID, shotID string) string { return requestID + "/" + shotID }

// acquire takes a slot for a Shot, reporting false when the host is full.
func (s *slots) acquire(requestID, shotID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := slotKey(requestID, shotID)
	if _, ok := s.held[key]; ok {
		return true
	}
	if len(s.held) >= s.limit {
		return false
	}
	s.held[key] = struct{}{}
	return true
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
	return true
}

func (s *slots) inUse() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.held)
}
