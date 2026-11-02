//go:build !linux

package host

// Outside Linux there is no dependency-free per-process reading: Darwin needs the
// `kern.proc.pid` sysctl, which the standard library does not expose. Every field is
// reported unknown, so the gates say `not measured` with a reason instead of a zero that
// would read as a real measurement. The Linux run — WSL2 is one — is what closes gate 5.9.

func sampleTree(pid int) (station, tree ProcSample, alive bool) {
	return ProcSample{}, ProcSample{}, false
}

// samplingSupported is false where no per-process reading exists.
func samplingSupported() bool { return false }
