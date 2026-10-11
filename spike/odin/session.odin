package main

// One idle session: an id, a 64 KB work buffer that is touched so it is resident,
// and a small history slice. Nothing else. No model, no network, no I/O.

WORK_BYTES :: 64 * 1024

Session :: struct {
	id:      int,
	work:    []u8,
	history: [dynamic]string,
}

make_session :: proc(id: int) -> ^Session {
	s := new(Session)
	s.id = id
	s.work = make([]u8, WORK_BYTES)
	for i in 0 ..< len(s.work) {
		s.work[i] = 0 // touch every page so it is resident
	}
	append(&s.history, "created")
	return s
}

free_session :: proc(s: ^Session) {
	delete(s.history)
	delete(s.work)
	free(s)
}
