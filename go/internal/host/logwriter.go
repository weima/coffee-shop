package host

import (
	"os"
	"sync"
)

// LogLimit is the per-Shot Station log bound. It matches the Odin headless backend's
// order of magnitude: enough for a report, small enough that a runaway agent cannot fill
// a disk.
const LogLimit = 1 << 20

// boundedLog keeps the newest bytes of a Station's output, rotating one generation aside.
// It keeps the newest, not the oldest: a log exists so a person can see how a run ended.
type boundedLog struct {
	mu       sync.Mutex
	path     string
	limit    int
	file     *os.File
	written  int
	writeErr error
}

func openBoundedLog(path string, limit int) (*boundedLog, error) {
	if limit <= 0 {
		limit = LogLimit
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return nil, err
	}
	return &boundedLog{path: path, limit: limit, file: file}, nil
}

func (b *boundedLog) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.file == nil {
		return len(p), nil // closed: swallow the child's remaining output
	}
	chunk := p
	if len(chunk) > b.limit {
		// One write can exceed the whole bound. Keep its tail, because that is the part
		// a reader needs, and the Odin host learned this the hard way in v0.5.
		chunk = chunk[len(chunk)-b.limit:]
	}
	if b.written+len(chunk) > b.limit {
		_ = b.file.Close()
		_ = os.Rename(b.path, b.path+".1")
		file, err := os.OpenFile(b.path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		if err != nil {
			b.writeErr = err
			b.file = nil
			return len(p), nil
		}
		b.file, b.written = file, 0
	}
	if _, err := b.file.Write(chunk); err != nil {
		b.writeErr = err
	}
	b.written += len(chunk)
	return len(p), nil
}

func (b *boundedLog) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.file == nil {
		return nil
	}
	err := b.file.Close()
	b.file = nil
	return err
}
