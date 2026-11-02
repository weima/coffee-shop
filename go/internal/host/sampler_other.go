//go:build !linux && !(darwin && cgo)

package host

// Where no per-process reading is available — anything but Linux, or a macOS build without
// cgo — every field is reported unknown, so the gates say `not measured` with a reason
// instead of a zero that would read as a real measurement. The Linux run — WSL2 is one —
// is what currently closes gate 5.9.

func sampleTree(pid int) (station, tree ProcSample, alive bool) {
	return ProcSample{}, ProcSample{}, false
}

// samplingSupported is false where no per-process reading exists.
func samplingSupported() bool { return false }
